//! Table of live and recently exited instances, plus launch policy.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Instance = @import("instance.zig").Instance;

pub const Config = struct {
    claude_path: []const u8 = "claude",
    /// Absolute, canonical directories instances may run under.
    roots: []const []const u8 = &.{},
    max_live: usize = 8,
    allow_bypass: bool = false,
};

pub const StartOptions = struct {
    cwd: []const u8,
    model: ?[]const u8 = null,
    permission_mode: []const u8 = "default",
    allowed_tools: []const []const u8 = &.{},
    resume_session_id: ?[]const u8 = null,
};

pub const Registry = struct {
    gpa: Allocator,
    cfg: Config,
    mutex: std.Thread.Mutex = .{},
    /// Insertion-ordered, so eviction drops the oldest exited instance first.
    map: std.StringArrayHashMapUnmanaged(*Instance) = .empty,

    pub fn init(gpa: Allocator, cfg: Config) Registry {
        return .{ .gpa = gpa, .cfg = cfg };
    }

    pub fn deinit(self: *Registry) void {
        for (self.map.values()) |inst| {
            inst.stop(2 * std.time.ns_per_s);
            inst.release();
        }
        self.map.deinit(self.gpa);
    }

    /// Returned instance is retained; call `release`.
    pub fn start(self: *Registry, opts: StartOptions) !*Instance {
        const cwd = try self.resolveCwd(opts.cwd);
        defer self.gpa.free(cwd);

        self.mutex.lock();
        defer self.mutex.unlock();

        var live: usize = 0;
        for (self.map.values()) |inst| {
            if (!inst.isExited()) live += 1;
        }
        if (live >= self.cfg.max_live) return error.TooManyInstances;
        self.evictLocked(self.cfg.max_live * 4 - 1);

        var id: [8]u8 = undefined;
        while (true) {
            var bytes: [4]u8 = undefined;
            std.crypto.random.bytes(&bytes);
            id = std.fmt.bytesToHex(bytes, .lower);
            if (!self.map.contains(&id)) break;
        }

        try self.map.ensureUnusedCapacity(self.gpa, 1);
        const inst = try Instance.spawn(self.gpa, .{
            .id = id,
            .claude_path = self.cfg.claude_path,
            .cwd = cwd,
            .model = opts.model,
            .permission_mode = opts.permission_mode,
            .allowed_tools = opts.allowed_tools,
            .resume_session_id = opts.resume_session_id,
        });
        self.map.putAssumeCapacity(inst.id(), inst);
        inst.retain();
        return inst;
    }

    /// Returned instance is retained; call `release`.
    pub fn get(self: *Registry, id: []const u8) ?*Instance {
        self.mutex.lock();
        defer self.mutex.unlock();
        const inst = self.map.get(id) orelse return null;
        inst.retain();
        return inst;
    }

    /// Every returned instance is retained; release each.
    pub fn list(self: *Registry, arena: Allocator) ![]*Instance {
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = try arena.dupe(*Instance, self.map.values());
        for (out) |inst| inst.retain();
        return out;
    }

    fn evictLocked(self: *Registry, keep: usize) void {
        var i: usize = 0;
        while (self.map.count() > keep and i < self.map.count()) {
            const inst = self.map.values()[i];
            if (inst.isExited()) {
                self.map.orderedRemoveAt(i);
                inst.release();
            } else i += 1;
        }
    }

    /// Canonical path of `path` if it is an existing directory under an allowed root.
    pub fn resolveCwd(self: *Registry, path: []const u8) ![]u8 {
        if (!std.fs.path.isAbsolute(path)) return error.CwdNotAbsolute;
        const real = std.fs.cwd().realpathAlloc(self.gpa, path) catch return error.CwdNotFound;
        errdefer self.gpa.free(real);
        var dir = std.fs.cwd().openDir(real, .{}) catch return error.CwdNotDirectory;
        dir.close();
        for (self.cfg.roots) |root| {
            if (isUnder(real, root)) return real;
        }
        return error.CwdNotAllowed;
    }
};

pub fn isUnder(path: []const u8, root: []const u8) bool {
    if (root.len == 0 or path.len < root.len) return false;
    if (!eqlPath(path[0..root.len], root)) return false;
    if (path.len == root.len) return true;
    return isSep(root[root.len - 1]) or isSep(path[root.len]);
}

fn eqlPath(a: []const u8, b: []const u8) bool {
    return if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn isSep(c: u8) bool {
    return c == '/' or (builtin.os.tag == .windows and c == '\\');
}

test isUnder {
    try std.testing.expect(isUnder("/home/a", "/home/a"));
    try std.testing.expect(isUnder("/home/a/b", "/home/a"));
    try std.testing.expect(isUnder("/home/a/b", "/"));
    try std.testing.expect(!isUnder("/home/ab", "/home/a"));
    try std.testing.expect(!isUnder("/home", "/home/a"));
    try std.testing.expect(!isUnder("/x", ""));
}

test "resolveCwd enforces roots" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("inside");
    const root = try tmp.dir.realpathAlloc(gpa, ".");
    defer gpa.free(root);
    const inside = try std.fs.path.join(gpa, &.{ root, "inside" });
    defer gpa.free(inside);

    var reg = Registry.init(gpa, .{ .roots = &.{inside} });
    defer reg.deinit();

    const ok = try reg.resolveCwd(inside);
    gpa.free(ok);
    try std.testing.expectError(error.CwdNotAllowed, reg.resolveCwd(root));
    try std.testing.expectError(error.CwdNotAbsolute, reg.resolveCwd("relative/path"));
    const missing = try std.fs.path.join(gpa, &.{ inside, "nope" });
    defer gpa.free(missing);
    try std.testing.expectError(error.CwdNotFound, reg.resolveCwd(missing));
}

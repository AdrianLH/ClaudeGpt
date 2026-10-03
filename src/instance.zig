//! One headless `claude` CLI process in stream-json mode, plus its transcript.
const std = @import("std");
const builtin = @import("builtin");
const jsonx = @import("jsonx.zig");
const Allocator = std.mem.Allocator;
const json = std.json;

pub const State = enum { running, idle, exited };

const Event = struct {
    seq: u64,
    kind: []const u8, // static
    text: []u8, // owned by Instance.gpa
};

pub const EventView = struct { seq: u64, kind: []const u8, text: []const u8 };

pub const Page = struct {
    events: []EventView,
    next_cursor: u64,
    /// Events before the cursor that were already evicted from the ring.
    skipped: u64,
    /// More events are available after `next_cursor`.
    more: bool,
};

pub const Info = struct {
    id: []const u8,
    state: State,
    cwd: []const u8,
    model: ?[]const u8,
    permission_mode: []const u8,
    session_id: ?[]const u8,
    pending_turns: u32,
    completed_turns: u64,
    total_cost_usd: f64,
    last_result: ?[]const u8,
    last_result_is_error: bool,
    exit_code: ?i64,
    started_ms: i64,
    next_cursor: u64,
};

pub const Options = struct {
    id: [8]u8,
    claude_path: []const u8,
    /// Absolute, already validated against the allowed roots.
    cwd: []const u8,
    model: ?[]const u8 = null,
    permission_mode: []const u8 = "default",
    allowed_tools: []const []const u8 = &.{},
    resume_session_id: ?[]const u8 = null,
};

const max_events = 2000;
const max_event_text = 8 * 1024;
const max_detail_text = 2 * 1024;
const max_line = 16 * 1024 * 1024;

pub const Instance = struct {
    gpa: Allocator,
    id_buf: [8]u8,
    cwd: []u8,
    model: ?[]u8,
    permission_mode: []u8,
    started_ms: i64,
    child: std.process.Child,
    thread: ?std.Thread = null,
    refs: std.atomic.Value(u32) = .init(1),

    /// Guards child.stdin and next_request_id. Never held together with `mutex`:
    /// a blocking pipe write must not stall the reader thread, or claude can
    /// deadlock writing to a full stdout pipe.
    stdin_mutex: std.Thread.Mutex = .{},
    next_request_id: u32 = 0,

    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    state: State = .idle,
    session_id: ?[]u8 = null,
    events: std.ArrayList(Event) = .empty,
    next_seq: u64 = 0,
    pending_turns: u32 = 0,
    completed_turns: u64 = 0,
    total_cost_usd: f64 = 0,
    last_result: ?[]u8 = null,
    last_result_is_error: bool = false,
    exit_code: ?i64 = null,

    pub fn spawn(gpa: Allocator, opts: Options) !*Instance {
        const self = try gpa.create(Instance);
        errdefer gpa.destroy(self);

        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{
            opts.claude_path,     "-p",
            "--input-format",     "stream-json",
            "--output-format",    "stream-json",
            "--verbose",          "--permission-mode",
            opts.permission_mode,
        });
        if (opts.model) |m| try argv.appendSlice(gpa, &.{ "--model", m });
        if (opts.resume_session_id) |s| try argv.appendSlice(gpa, &.{ "--resume", s });
        // Variadic flag; keep it last so it cannot swallow other arguments.
        if (opts.allowed_tools.len > 0) {
            try argv.append(gpa, "--allowedTools");
            try argv.appendSlice(gpa, opts.allowed_tools);
        }

        // Don't leak the server's bearer token into the agent's environment.
        var env = try std.process.getEnvMap(gpa);
        defer env.deinit();
        env.remove("CLAUDEGPT_TOKEN");

        const cwd = try gpa.dupe(u8, opts.cwd);
        errdefer gpa.free(cwd);
        const model = if (opts.model) |m| try gpa.dupe(u8, m) else null;
        errdefer if (model) |m| gpa.free(m);
        const pm = try gpa.dupe(u8, opts.permission_mode);
        errdefer gpa.free(pm);

        self.* = .{
            .gpa = gpa,
            .id_buf = opts.id,
            .cwd = cwd,
            .model = model,
            .permission_mode = pm,
            .started_ms = std.time.milliTimestamp(),
            .child = std.process.Child.init(argv.items, gpa),
        };
        self.child.cwd = cwd;
        self.child.env_map = &env;
        self.child.stdin_behavior = .Pipe;
        self.child.stdout_behavior = .Pipe;
        self.child.stderr_behavior = .Pipe;
        try self.child.spawn();
        self.child.env_map = null;

        self.thread = std.Thread.spawn(.{}, readerMain, .{self}) catch |err| {
            _ = self.child.kill() catch null;
            return err;
        };
        return self;
    }

    pub fn id(self: *const Instance) []const u8 {
        return &self.id_buf;
    }

    pub fn retain(self: *Instance) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    /// Frees the instance when the last reference goes. The process must have
    /// exited by then (the registry only drops exited instances).
    pub fn release(self: *Instance) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.thread) |t| t.join();
        const gpa = self.gpa;
        for (self.events.items) |e| gpa.free(e.text);
        self.events.deinit(gpa);
        if (self.session_id) |s| gpa.free(s);
        if (self.last_result) |s| gpa.free(s);
        if (self.model) |s| gpa.free(s);
        gpa.free(self.permission_mode);
        gpa.free(self.cwd);
        gpa.destroy(self);
    }

    pub fn isExited(self: *Instance) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state == .exited;
    }

    pub const Sent = struct {
        /// Cursor of the echoed prompt event; read output from here.
        cursor: u64,
        /// The turn is done once completed_turns reaches this.
        target_turns: u64,
    };

    /// Queue a user turn. Claude Code processes queued turns in order.
    pub fn send(self: *Instance, prompt: []const u8) !Sent {
        const line = try json.Stringify.valueAlloc(self.gpa, .{
            .type = "user",
            .message = .{ .role = "user", .content = prompt },
        }, .{});
        defer self.gpa.free(line);

        var sent: Sent = undefined;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.state == .exited) return error.InstanceExited;
            sent.cursor = self.next_seq;
            // Count the turn before writing so a fast result can't underflow it.
            self.pending_turns += 1;
            sent.target_turns = self.completed_turns + self.pending_turns;
            self.state = .running;
            self.appendEventLocked("prompt", prompt);
        }
        self.writeStdin(line) catch |err| {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.pending_turns -|= 1;
            if (self.pending_turns == 0 and self.state == .running) self.state = .idle;
            return err;
        };
        return sent;
    }

    /// Ask claude to abort the current turn (same control message the Agent SDK uses).
    pub fn interrupt(self: *Instance) !void {
        {
            self.stdin_mutex.lock();
            defer self.stdin_mutex.unlock();
            const f = self.child.stdin orelse return error.InstanceExited;
            self.next_request_id += 1;
            var buf: [160]u8 = undefined;
            const line = try std.fmt.bufPrint(&buf,
                \\{{"type":"control_request","request_id":"claudegpt-{d}","request":{{"subtype":"interrupt"}}}}
                \\
            , .{self.next_request_id});
            try f.writeAll(line);
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        // An interrupted turn may not produce a `result`; don't leave waiters hanging.
        if (self.state != .exited) {
            self.pending_turns = 0;
            self.state = .idle;
        }
        self.appendEventLocked("interrupt", "interrupt requested");
    }

    /// Interrupt, close stdin, and kill the process if it hasn't exited after `grace_ns`.
    pub fn stop(self: *Instance, grace_ns: u64) void {
        self.interrupt() catch {};
        self.closeStdin();
        if (self.waitExited(grace_ns)) return;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.state != .exited) {
                self.appendEventLocked("kill", "process did not exit; killing it");
                killProcess(self.child.id);
            }
        }
        _ = self.waitExited(grace_ns);
    }

    pub fn waitExited(self: *Instance, timeout_ns: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var timer = std.time.Timer.start() catch return self.state == .exited;
        while (self.state != .exited) {
            const elapsed = timer.read();
            if (elapsed >= timeout_ns) return false;
            self.cond.timedWait(&self.mutex, timeout_ns - elapsed) catch {};
        }
        return true;
    }

    /// Wait until `target_turns` turns completed, the instance went idle, or it exited.
    pub fn waitTurns(self: *Instance, target_turns: u64, timeout_ns: u64) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        var timer = std.time.Timer.start() catch return false;
        while (self.completed_turns < target_turns and self.pending_turns > 0 and self.state != .exited) {
            const elapsed = timer.read();
            if (elapsed >= timeout_ns) return false;
            self.cond.timedWait(&self.mutex, timeout_ns - elapsed) catch {};
        }
        return true;
    }

    pub fn waitIdle(self: *Instance, timeout_ns: u64) bool {
        self.mutex.lock();
        const target = self.completed_turns + self.pending_turns;
        self.mutex.unlock();
        return self.waitTurns(target, timeout_ns);
    }

    pub fn info(self: *Instance, arena: Allocator) !Info {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{
            .id = self.id(),
            .state = self.state,
            .cwd = self.cwd,
            .model = self.model,
            .permission_mode = self.permission_mode,
            .session_id = if (self.session_id) |s| try arena.dupe(u8, s) else null,
            .pending_turns = self.pending_turns,
            .completed_turns = self.completed_turns,
            .total_cost_usd = self.total_cost_usd,
            .last_result = if (self.last_result) |s| try arena.dupe(u8, clip(s, max_detail_text)) else null,
            .last_result_is_error = self.last_result_is_error,
            .exit_code = self.exit_code,
            .started_ms = self.started_ms,
            .next_cursor = self.next_seq,
        };
    }

    /// Copy events with seq >= `since` into `arena`, stopping after roughly `max_bytes` of text.
    pub fn eventsSince(self: *Instance, arena: Allocator, since: u64, max_bytes: usize) !Page {
        self.mutex.lock();
        defer self.mutex.unlock();
        const first = if (self.events.items.len > 0) self.events.items[0].seq else self.next_seq;
        const start = @min(@max(since, first), self.next_seq);
        var out: std.ArrayList(EventView) = .empty;
        var bytes: usize = 0;
        var next = start;
        for (self.events.items[@intCast(start - first)..]) |e| {
            if (out.items.len > 0 and bytes + e.text.len > max_bytes) break;
            try out.append(arena, .{ .seq = e.seq, .kind = e.kind, .text = try arena.dupe(u8, e.text) });
            bytes += e.text.len;
            next = e.seq + 1;
        }
        return .{
            .events = out.items,
            .next_cursor = next,
            .skipped = if (since < first) first - since else 0,
            .more = next < self.next_seq,
        };
    }

    // ---- internals ----

    fn writeStdin(self: *Instance, line: []const u8) !void {
        self.stdin_mutex.lock();
        defer self.stdin_mutex.unlock();
        const f = self.child.stdin orelse return error.InstanceExited;
        try f.writeAll(line);
        try f.writeAll("\n");
    }

    fn closeStdin(self: *Instance) void {
        self.stdin_mutex.lock();
        defer self.stdin_mutex.unlock();
        if (self.child.stdin) |f| {
            f.close();
            self.child.stdin = null;
        }
    }

    fn readerMain(self: *Instance) void {
        {
            var poller = std.Io.poll(self.gpa, enum { stdout, stderr }, .{
                .stdout = self.child.stdout.?,
                .stderr = self.child.stderr.?,
            });
            defer poller.deinit();
            while (true) {
                const more = poller.poll() catch |err| {
                    self.pushEventFmt("error", "reading claude output failed: {s}", .{@errorName(err)});
                    break;
                };
                self.drainStdout(poller.reader(.stdout), !more);
                self.drainStderr(poller.reader(.stderr));
                if (!more) break;
            }
        }
        self.closeStdin();
        // Child.wait closes the remaining pipes and reaps the process.
        const term = self.child.wait() catch |err| blk: {
            self.pushEventFmt("error", "wait failed: {s}", .{@errorName(err)});
            break :blk null;
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        self.state = .exited;
        self.pending_turns = 0;
        if (term) |t| self.exit_code = switch (t) {
            .Exited => |c| c,
            .Signal => |s| -@as(i64, s),
            else => -1,
        };
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "process exited (code {?d})", .{self.exit_code}) catch "process exited";
        self.appendEventLocked("exit", msg);
        self.cond.broadcast();
    }

    fn drainStdout(self: *Instance, r: *std.Io.Reader, final: bool) void {
        while (true) {
            const buf = r.buffered();
            const nl = std.mem.indexOfScalar(u8, buf, '\n') orelse {
                if (buf.len > max_line or (final and buf.len > 0)) {
                    self.handleLine(buf);
                    r.toss(buf.len);
                }
                return;
            };
            self.handleLine(buf[0..nl]);
            r.toss(nl + 1);
        }
    }

    fn drainStderr(self: *Instance, r: *std.Io.Reader) void {
        const buf = r.buffered();
        if (buf.len == 0) return;
        const text = std.mem.trim(u8, buf, " \r\n\t");
        if (text.len > 0) self.pushEvent("stderr", text);
        r.toss(buf.len);
    }

    fn handleLine(self: *Instance, raw: []const u8) void {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len == 0) return;
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const v = json.parseFromSliceLeaky(json.Value, arena, line, .{}) catch {
            self.pushEvent("stdout", line);
            return;
        };
        self.handleMessage(arena, v, line) catch |err|
            self.pushEventFmt("error", "handling claude message failed: {s}", .{@errorName(err)});
    }

    /// Map a stream-json message onto transcript events and state changes.
    fn handleMessage(self: *Instance, arena: Allocator, v: json.Value, line: []const u8) !void {
        const typ = jsonx.getStr(v, "type") orelse return self.pushEvent("other", line);

        if (eql(typ, "system")) {
            const sub = jsonx.getStr(v, "subtype") orelse "";
            if (!eql(sub, "init")) return self.pushEvent("system", sub);
            self.mutex.lock();
            defer self.mutex.unlock();
            if (jsonx.getStr(v, "session_id")) |sid| try self.setSessionLocked(sid);
            const text = try std.fmt.allocPrint(arena, "session {s}, model {s}", .{
                jsonx.getStr(v, "session_id") orelse "?",
                jsonx.getStr(v, "model") orelse "?",
            });
            self.appendEventLocked("init", text);
        } else if (eql(typ, "assistant")) {
            const content = jsonx.getPath(v, &.{ "message", "content" }) orelse return;
            if (content != .array) return;
            for (content.array.items) |block| {
                const bt = jsonx.getStr(block, "type") orelse continue;
                if (eql(bt, "text")) {
                    self.pushEvent("text", jsonx.getStr(block, "text") orelse "");
                } else if (eql(bt, "tool_use")) {
                    const input = if (jsonx.get(block, "input")) |i|
                        try json.Stringify.valueAlloc(arena, i, .{})
                    else
                        "";
                    const text = try std.fmt.allocPrint(arena, "{s} {s}", .{
                        jsonx.getStr(block, "name") orelse "?",
                        clip(input, max_detail_text),
                    });
                    self.pushEvent("tool_use", text);
                }
            }
        } else if (eql(typ, "user")) {
            // Tool results fed back to the model.
            const content = jsonx.getPath(v, &.{ "message", "content" }) orelse return;
            if (content != .array) return;
            for (content.array.items) |block| {
                const bt = jsonx.getStr(block, "type") orelse continue;
                if (!eql(bt, "tool_result")) continue;
                const is_error = jsonx.getBool(block, "is_error") orelse false;
                const text = try toolResultText(arena, jsonx.get(block, "content"));
                self.pushEvent(if (is_error) "tool_error" else "tool_result", clip(text, max_detail_text));
            }
        } else if (eql(typ, "result")) {
            const result = jsonx.getStr(v, "result") orelse jsonx.getStr(v, "subtype") orelse "";
            const is_error = jsonx.getBool(v, "is_error") orelse false;
            self.mutex.lock();
            defer self.mutex.unlock();
            self.completed_turns += 1;
            self.pending_turns -|= 1;
            if (self.state != .exited) self.state = if (self.pending_turns == 0) .idle else .running;
            if (jsonx.getFloat(v, "total_cost_usd")) |c| self.total_cost_usd = c;
            if (jsonx.getStr(v, "session_id")) |sid| try self.setSessionLocked(sid);
            const owned = try self.gpa.dupe(u8, result);
            if (self.last_result) |old| self.gpa.free(old);
            self.last_result = owned;
            self.last_result_is_error = is_error;
            self.appendEventLocked(if (is_error) "result_error" else "result", result);
            self.cond.broadcast();
        } else if (eql(typ, "control_response")) {
            self.pushEvent("control", clip(line, max_detail_text));
        } else if (eql(typ, "stream_event")) {
            // Partial deltas; only emitted with --include-partial-messages.
        } else {
            self.pushEvent("other", clip(line, max_detail_text));
        }
    }

    fn setSessionLocked(self: *Instance, sid: []const u8) !void {
        if (self.session_id) |old| {
            if (eql(old, sid)) return;
            self.gpa.free(old);
            self.session_id = null;
        }
        self.session_id = try self.gpa.dupe(u8, sid);
    }

    fn pushEvent(self: *Instance, kind: []const u8, text: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.appendEventLocked(kind, text);
    }

    fn pushEventFmt(self: *Instance, kind: []const u8, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        self.pushEvent(kind, std.fmt.bufPrint(&buf, fmt, args) catch fmt);
    }

    fn appendEventLocked(self: *Instance, kind: []const u8, text: []const u8) void {
        const owned = clipDupe(self.gpa, text, max_event_text) catch return;
        if (self.events.items.len >= max_events) {
            const drop = max_events / 10;
            for (self.events.items[0..drop]) |e| self.gpa.free(e.text);
            const rest = self.events.items.len - drop;
            std.mem.copyForwards(Event, self.events.items[0..rest], self.events.items[drop..]);
            self.events.shrinkRetainingCapacity(rest);
        }
        self.events.append(self.gpa, .{ .seq = self.next_seq, .kind = kind, .text = owned }) catch {
            self.gpa.free(owned);
            return;
        };
        self.next_seq += 1;
        self.cond.broadcast();
    }
};

fn killProcess(id: std.process.Child.Id) void {
    // Racy only if the reader thread reaped the process in the instant between our
    // state check and this call; acceptable for a best-effort hard stop.
    if (builtin.os.tag == .windows) {
        std.os.windows.TerminateProcess(id, 1) catch {};
    } else {
        std.posix.kill(id, std.posix.SIG.KILL) catch {};
    }
}

fn toolResultText(arena: Allocator, content: ?json.Value) ![]const u8 {
    const c = content orelse return "";
    switch (c) {
        .string => |s| return s,
        .array => |arr| {
            var aw: std.Io.Writer.Allocating = .init(arena);
            for (arr.items) |item| {
                if (jsonx.getStr(item, "text")) |t| {
                    try aw.writer.writeAll(t);
                    try aw.writer.writeAll("\n");
                } else if (jsonx.getStr(item, "type")) |t| {
                    try aw.writer.print("[{s}]\n", .{t});
                }
            }
            return aw.written();
        },
        else => return json.Stringify.valueAlloc(arena, c, .{}),
    }
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Longest prefix of `s` that fits in `max` bytes without splitting a UTF-8 sequence.
pub fn clip(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return s[0..end];
}

/// Copy `s`, clipped to `max` bytes with a marker, with invalid UTF-8 replaced so
/// the text is always safe to put in a JSON string.
fn clipDupe(gpa: Allocator, s: []const u8, max: usize) ![]u8 {
    const head = clip(s, max);
    const out = if (head.len == s.len)
        try gpa.dupe(u8, s)
    else
        try std.fmt.allocPrint(gpa, "{s}... [+{d} bytes]", .{ head, s.len - head.len });
    if (!std.unicode.utf8ValidateSlice(out)) {
        for (out) |*c| {
            if (c.* >= 0x80) c.* = '?';
        }
    }
    return out;
}

test "clip respects utf-8 boundaries" {
    try std.testing.expectEqualStrings("ab", clip("ab\xc3\xa9", 3));
    try std.testing.expectEqualStrings("ab\xc3\xa9", clip("ab\xc3\xa9", 4));
}

test "clipDupe sanitizes invalid utf-8" {
    const out = try clipDupe(std.testing.allocator, "a\xffb", 100);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a?b", out);
}

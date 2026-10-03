const std = @import("std");
const http = @import("http.zig");
const mcp = @import("mcp.zig");
const Registry = @import("registry.zig").Registry;

pub const std_options: std.Options = .{ .log_level = .info };
const log = std.log.scoped(.server);

const max_body = 1 << 20;

const usage =
    \\Usage: claudegpt --root <dir> [--root <dir>...] [options]
    \\
    \\MCP server (Streamable HTTP, POST /mcp) that lets ChatGPT drive local
    \\Claude Code CLI instances. Requires CLAUDEGPT_TOKEN (>= 16 chars) in the
    \\environment; clients must send "Authorization: Bearer <token>".
    \\
    \\Options:
    \\  --root <dir>           Directory instances may run in (repeatable, required)
    \\  --port <n>             Listen port (default 8765)
    \\  --bind <ip>            Listen address (default 127.0.0.1)
    \\  --max-instances <n>    Max concurrently running instances (default 8)
    \\  --claude-path <path>   claude executable (default: "claude" from PATH)
    \\  --allow-bypass         Allow permission_mode=bypassPermissions
    \\  -h, --help             Show this help
    \\
;

const Server = struct {
    gpa: std.mem.Allocator,
    reg: *Registry,
    token: []const u8,
};

pub fn main() !void {
    const gpa = std.heap.smp_allocator;
    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var bind: []const u8 = "127.0.0.1";
    var port: u16 = 8765;
    var max_live: usize = 8;
    var claude_path: []const u8 = "claude";
    var allow_bypass = false;
    var roots: std.ArrayList([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "-h") or eql(a, "--help")) {
            std.debug.print("{s}", .{usage});
            return;
        } else if (eql(a, "--allow-bypass")) {
            allow_bypass = true;
        } else if (eql(a, "--root")) {
            const dir = nextArg(args, &i);
            const real = std.fs.cwd().realpathAlloc(gpa, dir) catch |err|
                fatal("--root {s}: {s}", .{ dir, @errorName(err) });
            try roots.append(gpa, real);
        } else if (eql(a, "--port")) {
            port = std.fmt.parseInt(u16, nextArg(args, &i), 10) catch fatal("invalid --port", .{});
        } else if (eql(a, "--bind")) {
            bind = nextArg(args, &i);
        } else if (eql(a, "--max-instances")) {
            max_live = std.fmt.parseInt(usize, nextArg(args, &i), 10) catch fatal("invalid --max-instances", .{});
            if (max_live == 0 or max_live > 256) fatal("--max-instances must be 1..256", .{});
        } else if (eql(a, "--claude-path")) {
            claude_path = nextArg(args, &i);
        } else {
            fatal("unknown argument '{s}' (see --help)", .{a});
        }
    }
    if (roots.items.len == 0) fatal("at least one --root <dir> is required (see --help)", .{});

    const token = std.process.getEnvVarOwned(gpa, "CLAUDEGPT_TOKEN") catch
        fatal("set CLAUDEGPT_TOKEN to a random secret of at least 16 characters", .{});
    if (token.len < 16) fatal("CLAUDEGPT_TOKEN must be at least 16 characters", .{});

    var reg = Registry.init(gpa, .{
        .claude_path = claude_path,
        .roots = roots.items,
        .max_live = max_live,
        .allow_bypass = allow_bypass,
    });
    var srv: Server = .{ .gpa = gpa, .reg = &reg, .token = token };

    const addr = std.net.Address.parseIp(bind, port) catch fatal("invalid --bind address '{s}'", .{bind});
    var listener = addr.listen(.{ .reuse_address = true }) catch |err|
        fatal("listen on {s}:{d}: {s}", .{ bind, port, @errorName(err) });
    defer listener.deinit();

    log.info("claudegpt {s} listening on http://{s}:{d}/mcp", .{ mcp.version, bind, port });
    for (roots.items) |r| log.info("allowed root: {s}", .{r});
    if (allow_bypass) log.warn("bypassPermissions is enabled", .{});

    while (true) {
        const conn = listener.accept() catch |err| {
            log.err("accept: {s}", .{@errorName(err)});
            continue;
        };
        const t = std.Thread.spawn(.{}, handleConn, .{ &srv, conn }) catch |err| {
            log.err("spawn connection thread: {s}", .{@errorName(err)});
            conn.stream.close();
            continue;
        };
        t.detach();
    }
}

fn handleConn(srv: *Server, conn: std.net.Server.Connection) void {
    defer conn.stream.close();
    var rbuf: [16 * 1024]u8 = undefined;
    var wbuf: [8 * 1024]u8 = undefined;
    var sr = conn.stream.reader(&rbuf);
    var sw = conn.stream.writer(&wbuf);
    const r = sr.interface();
    const w = &sw.interface;

    while (true) {
        var arena_state = std.heap.ArenaAllocator.init(srv.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const req = http.readRequest(r, arena, max_body) catch |err| {
            const status: http.Status = switch (err) {
                error.EndOfStream, error.ReadFailed => return,
                error.PayloadTooLarge => .payload_too_large,
                error.LengthRequired => .length_required,
                error.OutOfMemory => .internal_server_error,
                error.BadRequest, error.StreamTooLong => .bad_request,
            };
            http.writeResponse(w, status, "text/plain", &.{}, "request rejected\n", false) catch {};
            w.flush() catch {};
            return;
        };
        const keep_alive = handleRequest(srv, arena, req, w) catch return;
        w.flush() catch return;
        if (!keep_alive) return;
    }
}

fn handleRequest(srv: *Server, arena: std.mem.Allocator, req: http.Request, w: *std.Io.Writer) !bool {
    const ka = req.keep_alive;
    const path = req.path();
    if (eql(path, "/healthz")) {
        try http.writeResponse(w, .ok, "text/plain", &.{}, "ok\n", ka);
        return ka;
    }
    if (!eql(path, "/mcp")) {
        try http.writeResponse(w, .not_found, "text/plain", &.{}, "not found\n", ka);
        return ka;
    }
    if (!http.checkBearer(req.authorization, srv.token)) {
        log.warn("rejected unauthenticated {s} {s}", .{ req.method, path });
        try http.writeResponse(w, .unauthorized, "text/plain", &.{.{ .name = "WWW-Authenticate", .value = "Bearer" }}, "unauthorized\n", ka);
        return ka;
    }
    if (!eql(req.method, "POST")) {
        // No server-initiated SSE stream; JSON responses only.
        try http.writeResponse(w, .method_not_allowed, "text/plain", &.{.{ .name = "Allow", .value = "POST" }}, "use POST\n", ka);
        return ka;
    }

    const out = mcp.handle(srv.reg, arena, req.body) catch |err| {
        log.err("mcp handler: {s}", .{@errorName(err)});
        try http.writeResponse(w, .internal_server_error, "text/plain", &.{}, "internal error\n", false);
        return false;
    };
    if (out) |body| {
        try http.writeResponse(w, .ok, "application/json", &.{}, body, ka);
    } else {
        try http.writeResponse(w, .accepted, null, &.{}, "", ka);
    }
    return ka;
}

fn nextArg(args: []const [:0]u8, i: *usize) []const u8 {
    if (i.* + 1 >= args.len) fatal("{s} needs a value", .{args[i.*]});
    i.* += 1;
    return args[i.*];
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(2);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test {
    _ = @import("http.zig");
    _ = @import("mcp.zig");
    _ = @import("registry.zig");
    _ = @import("instance.zig");
    _ = @import("jsonx.zig");
}

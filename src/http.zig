//! Minimal HTTP/1.1: enough for a JSON-RPC endpoint behind a TLS tunnel.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Status = std.http.Status;

pub const Header = struct { name: []const u8, value: []const u8 };

pub const Request = struct {
    method: []const u8,
    target: []const u8,
    authorization: ?[]const u8 = null,
    keep_alive: bool = true,
    body: []const u8 = "",

    pub fn path(r: Request) []const u8 {
        const q = std.mem.indexOfScalar(u8, r.target, '?') orelse return r.target;
        return r.target[0..q];
    }
};

pub const ReadError = error{
    BadRequest,
    PayloadTooLarge,
    LengthRequired,
    OutOfMemory,
    ReadFailed,
    EndOfStream,
    StreamTooLong,
};

const max_headers = 100;

/// Strings in the result are allocated in `arena`; the reader's buffer is reused.
pub fn readRequest(r: *std.Io.Reader, arena: Allocator, max_body: usize) ReadError!Request {
    var line = trimEol(try r.takeDelimiterInclusive('\n'));
    // RFC 9112 2.2: tolerate a leading empty line.
    if (line.len == 0) line = trimEol(try r.takeDelimiterInclusive('\n'));

    var it = std.mem.splitScalar(u8, line, ' ');
    const method = it.next() orelse return error.BadRequest;
    const target = it.next() orelse return error.BadRequest;
    const version = it.next() orelse return error.BadRequest;
    if (it.next() != null or method.len == 0 or target.len == 0) return error.BadRequest;
    if (!std.mem.startsWith(u8, version, "HTTP/1.")) return error.BadRequest;

    var req: Request = .{
        .method = try arena.dupe(u8, method),
        .target = try arena.dupe(u8, target),
        .keep_alive = std.mem.eql(u8, version, "HTTP/1.1"),
    };

    var content_length: usize = 0;
    var n: usize = 0;
    while (true) {
        const h = trimEol(try r.takeDelimiterInclusive('\n'));
        if (h.len == 0) break;
        n += 1;
        if (n > max_headers) return error.BadRequest;
        const colon = std.mem.indexOfScalar(u8, h, ':') orelse return error.BadRequest;
        const name = std.mem.trim(u8, h[0..colon], " \t");
        const value = std.mem.trim(u8, h[colon + 1 ..], " \t");
        if (std.ascii.eqlIgnoreCase(name, "content-length")) {
            content_length = std.fmt.parseInt(usize, value, 10) catch return error.BadRequest;
        } else if (std.ascii.eqlIgnoreCase(name, "authorization")) {
            req.authorization = try arena.dupe(u8, value);
        } else if (std.ascii.eqlIgnoreCase(name, "connection")) {
            if (std.ascii.eqlIgnoreCase(value, "close")) req.keep_alive = false;
            if (std.ascii.eqlIgnoreCase(value, "keep-alive")) req.keep_alive = true;
        } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
            return error.LengthRequired;
        }
    }

    if (content_length > max_body) return error.PayloadTooLarge;
    if (content_length > 0) {
        const body = try arena.alloc(u8, content_length);
        try r.readSliceAll(body);
        req.body = body;
    }
    return req;
}

fn trimEol(s: []const u8) []const u8 {
    var end = s.len;
    if (end > 0 and s[end - 1] == '\n') end -= 1;
    if (end > 0 and s[end - 1] == '\r') end -= 1;
    return s[0..end];
}

/// Caller flushes.
pub fn writeResponse(
    w: *std.Io.Writer,
    status: Status,
    content_type: ?[]const u8,
    extra: []const Header,
    body: []const u8,
    keep_alive: bool,
) std.Io.Writer.Error!void {
    try w.print("HTTP/1.1 {d} {s}\r\n", .{ @intFromEnum(status), status.phrase() orelse "" });
    if (content_type) |ct| try w.print("Content-Type: {s}\r\n", .{ct});
    for (extra) |h| try w.print("{s}: {s}\r\n", .{ h.name, h.value });
    try w.print("Content-Length: {d}\r\nConnection: {s}\r\n\r\n", .{
        body.len,
        if (keep_alive) "keep-alive" else "close",
    });
    try w.writeAll(body);
}

pub fn checkBearer(header: ?[]const u8, token: []const u8) bool {
    const h = header orelse return false;
    const prefix = "Bearer ";
    if (h.len < prefix.len or !std.ascii.eqlIgnoreCase(h[0..prefix.len], prefix)) return false;
    return constantTimeEql(std.mem.trim(u8, h[prefix.len..], " "), token);
}

fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

const testing = std.testing;

test "parse POST with body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var r: std.Io.Reader = .fixed("POST /mcp?x=1 HTTP/1.1\r\nHost: a\r\nAuthorization: Bearer abc\r\n" ++
        "Content-Length: 4\r\n\r\n{}{}GET / HTTP/1.0\r\n\r\n");
    const req = try readRequest(&r, arena_state.allocator(), 1024);
    try testing.expectEqualStrings("POST", req.method);
    try testing.expectEqualStrings("/mcp", req.path());
    try testing.expectEqualStrings("Bearer abc", req.authorization.?);
    try testing.expectEqualStrings("{}{}", req.body);
    try testing.expect(req.keep_alive);

    const req2 = try readRequest(&r, arena_state.allocator(), 1024);
    try testing.expectEqualStrings("GET", req2.method);
    try testing.expect(!req2.keep_alive);
    try testing.expectError(error.EndOfStream, readRequest(&r, arena_state.allocator(), 1024));
}

test "reject oversized and chunked bodies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var r1: std.Io.Reader = .fixed("POST /mcp HTTP/1.1\r\nContent-Length: 999\r\n\r\n");
    try testing.expectError(error.PayloadTooLarge, readRequest(&r1, arena_state.allocator(), 10));
    var r2: std.Io.Reader = .fixed("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n");
    try testing.expectError(error.LengthRequired, readRequest(&r2, arena_state.allocator(), 10));
    var r3: std.Io.Reader = .fixed("garbage\r\n\r\n");
    try testing.expectError(error.BadRequest, readRequest(&r3, arena_state.allocator(), 10));
}

test "bearer check" {
    try testing.expect(checkBearer("Bearer secret", "secret"));
    try testing.expect(checkBearer("bearer secret", "secret"));
    try testing.expect(!checkBearer("Bearer secreT", "secret"));
    try testing.expect(!checkBearer("Basic secret", "secret"));
    try testing.expect(!checkBearer(null, "secret"));
}

test "write response" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeResponse(&w, .ok, "application/json", &.{}, "{}", true);
    try testing.expectEqualStrings(
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\n{}",
        w.buffered(),
    );
}

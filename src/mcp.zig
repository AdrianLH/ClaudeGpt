//! MCP (JSON-RPC 2.0) dispatch and the claude_* tools.
const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const jsonx = @import("jsonx.zig");
const Registry = @import("registry.zig").Registry;
const instance = @import("instance.zig");
const Instance = instance.Instance;

pub const version = "0.1.0";
const log = std.log.scoped(.mcp);

/// Newest first; the first entry is offered when the client asks for something unknown.
const protocol_versions = [_][]const u8{ "2025-06-18", "2025-03-26", "2024-11-05" };

const instructions =
    \\Controls Claude Code CLI instances running headless on the user's machine.
    \\Typical flow: claude_start (cwd + prompt) -> read the result -> claude_send follow-ups.
    \\If a call returns completed=false the turn is still running: call claude_output with
    \\since=next_cursor and wait_seconds to follow it. Use claude_list to find instances,
    \\claude_interrupt to abort a turn, claude_stop to end an instance.
    \\Claude Code cannot ask for permission here; tools outside permission_mode/allowed_tools are denied.
;

const default_wait_s = 25;
const max_wait_s = 120;
const default_max_bytes = 24 * 1024;

pub const tools_json =
    \\[
    \\{"name":"claude_start","title":"Start Claude Code",
    \\ "description":"Start a new Claude Code instance in a project directory on the user's machine and optionally send it a first prompt. Returns an instance id for the other tools. If wait_seconds elapses before the turn finishes, follow it with claude_output.",
    \\ "inputSchema":{"type":"object","properties":{
    \\  "cwd":{"type":"string","description":"Absolute path of the project directory; must be inside a root the server allows."},
    \\  "prompt":{"type":"string","description":"First message for Claude Code."},
    \\  "model":{"type":"string","description":"Model alias or id, e.g. 'sonnet' or 'opus'. Omit for the default."},
    \\  "permission_mode":{"type":"string","enum":["default","acceptEdits","plan","bypassPermissions"],"description":"default: only read-only and allowed_tools run; acceptEdits: file edits allowed; plan: read-only planning; bypassPermissions: everything (only if the server allows it)."},
    \\  "allowed_tools":{"type":"array","items":{"type":"string"},"description":"Permission rules to pre-approve, e.g. [\"Edit\",\"Bash(git status)\",\"Bash(npm test:*)\"]."},
    \\  "resume_session_id":{"type":"string","description":"Resume an earlier Claude Code session (session_id from a previous instance)."},
    \\  "wait_seconds":{"type":"integer","minimum":0,"maximum":120,"description":"How long to wait for the first prompt's turn to finish. Default 25."}},
    \\  "required":["cwd"],"additionalProperties":false},
    \\ "annotations":{"title":"Start Claude Code","readOnlyHint":false,"destructiveHint":false,"idempotentHint":false,"openWorldHint":false}},
    \\{"name":"claude_send","title":"Send prompt to Claude Code",
    \\ "description":"Send a follow-up prompt to a running Claude Code instance. Prompts sent while a turn is running are queued.",
    \\ "inputSchema":{"type":"object","properties":{
    \\  "id":{"type":"string","description":"Instance id from claude_start or claude_list."},
    \\  "prompt":{"type":"string"},
    \\  "wait_seconds":{"type":"integer","minimum":0,"maximum":120,"description":"How long to wait for the turn to finish. Default 25."}},
    \\  "required":["id","prompt"],"additionalProperties":false},
    \\ "annotations":{"title":"Send prompt","readOnlyHint":false,"destructiveHint":false,"idempotentHint":false,"openWorldHint":false}},
    \\{"name":"claude_output","title":"Read Claude Code output",
    \\ "description":"Read an instance's transcript events (prompts, assistant text, tool calls, tool results, final results) starting at a cursor. Optionally wait for the current turn to finish first.",
    \\ "inputSchema":{"type":"object","properties":{
    \\  "id":{"type":"string"},
    \\  "since":{"type":"integer","minimum":0,"description":"Cursor (next_cursor from a previous call). Default 0."},
    \\  "wait_seconds":{"type":"integer","minimum":0,"maximum":120,"description":"Wait up to this long for running turns to finish. Default 0."},
    \\  "max_bytes":{"type":"integer","minimum":1000,"maximum":200000,"description":"Approximate cap on returned text. Default 24576."}},
    \\  "required":["id"],"additionalProperties":false},
    \\ "annotations":{"title":"Read output","readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
    \\{"name":"claude_list","title":"List Claude Code instances",
    \\ "description":"List Claude Code instances with their state, directory, session id and cost.",
    \\ "inputSchema":{"type":"object","properties":{},"additionalProperties":false},
    \\ "annotations":{"title":"List instances","readOnlyHint":true,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
    \\{"name":"claude_interrupt","title":"Interrupt Claude Code",
    \\ "description":"Abort the turn an instance is currently running. The instance stays alive for further prompts.",
    \\ "inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false},
    \\ "annotations":{"title":"Interrupt turn","readOnlyHint":false,"destructiveHint":false,"idempotentHint":true,"openWorldHint":false}},
    \\{"name":"claude_stop","title":"Stop Claude Code",
    \\ "description":"Stop an instance: abort its turn and end the process. Its transcript stays readable and its session can be resumed with claude_start resume_session_id.",
    \\ "inputSchema":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"],"additionalProperties":false},
    \\ "annotations":{"title":"Stop instance","readOnlyHint":false,"destructiveHint":true,"idempotentHint":true,"openWorldHint":false}}
    \\]
;

/// Handle one JSON-RPC message. Returns the response body, or null for a
/// notification (HTTP 202, no body).
pub fn handle(reg: *Registry, arena: Allocator, body: []const u8) !?[]const u8 {
    const req = json.parseFromSliceLeaky(json.Value, arena, body, .{}) catch
        return try rpcError(arena, .null, -32700, "parse error");
    if (req != .object) return try rpcError(arena, .null, -32600, "expected a single JSON-RPC request object");

    const id = req.object.get("id");
    const method = jsonx.getStr(req, "method") orelse {
        // A response to a server->client request (we never send any) or junk.
        if (id) |i| return try rpcError(arena, i, -32600, "missing method");
        return null;
    };
    const params = req.object.get("params") orelse json.Value{ .null = {} };
    const rid = id orelse {
        log.debug("notification {s}", .{method});
        return null;
    };

    if (eql(method, "initialize")) {
        const asked = jsonx.getStr(params, "protocolVersion") orelse "";
        var chosen: []const u8 = protocol_versions[0];
        for (protocol_versions) |v| {
            if (eql(v, asked)) chosen = v;
        }
        log.info("initialize (client protocol {s}, using {s})", .{ asked, chosen });
        return try rpcResult(arena, rid, try json.Stringify.valueAlloc(arena, .{
            .protocolVersion = chosen,
            .capabilities = .{ .tools = .{ .listChanged = false } },
            .serverInfo = .{ .name = "claudegpt", .title = "Claude Code Control", .version = version },
            .instructions = instructions,
        }, .{}));
    }
    if (eql(method, "ping")) return try rpcResult(arena, rid, "{}");
    if (eql(method, "tools/list")) return try rpcResult(arena, rid, "{\"tools\":" ++ tools_json ++ "}");
    if (eql(method, "tools/call")) {
        const name = jsonx.getStr(params, "name") orelse
            return try rpcError(arena, rid, -32602, "missing tool name");
        const args = jsonx.get(params, "arguments") orelse json.Value{ .null = {} };
        const tool = std.meta.stringToEnum(Tool, name) orelse
            return try rpcError(arena, rid, -32602, "unknown tool");
        log.info("tools/call {s}", .{name});
        const result = callTool(reg, arena, tool, args) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => try toolError(arena, "internal error: {s}", .{@errorName(err)}),
        };
        return try rpcResult(arena, rid, result);
    }
    return try rpcError(arena, rid, -32601, "method not found");
}

const Tool = enum { claude_start, claude_send, claude_output, claude_list, claude_interrupt, claude_stop };

fn callTool(reg: *Registry, arena: Allocator, tool: Tool, args: json.Value) ![]const u8 {
    switch (tool) {
        .claude_start => return toolStart(reg, arena, args),
        .claude_list => return toolList(reg, arena),
        else => {},
    }
    const id = jsonx.getStr(args, "id") orelse return toolError(arena, "`id` is required", .{});
    const inst = reg.get(id) orelse
        return toolError(arena, "no instance with id '{s}'; use claude_list", .{instance.clip(id, 64)});
    defer inst.release();

    switch (tool) {
        .claude_send => {
            const prompt = jsonx.getStr(args, "prompt") orelse "";
            if (prompt.len == 0) return toolError(arena, "`prompt` is required", .{});
            return sendAndReport(arena, inst, prompt, waitArg(args, default_wait_s));
        },
        .claude_output => {
            const wait_s = waitArg(args, 0);
            const completed = if (wait_s > 0) inst.waitIdle(wait_s * std.time.ns_per_s) else null;
            const since: u64 = @intCast(std.math.clamp(jsonx.getInt(args, "since") orelse 0, 0, std.math.maxInt(i64)));
            const max_bytes: usize = @intCast(std.math.clamp(jsonx.getInt(args, "max_bytes") orelse default_max_bytes, 1000, 200_000));
            return report(arena, inst, since, max_bytes, completed);
        },
        .claude_interrupt => {
            const cursor = (try inst.info(arena)).next_cursor;
            inst.interrupt() catch |err| return toolError(arena, "interrupt failed: {s}", .{@errorName(err)});
            return report(arena, inst, cursor, default_max_bytes, null);
        },
        .claude_stop => {
            const cursor = (try inst.info(arena)).next_cursor;
            inst.stop(5 * std.time.ns_per_s);
            return report(arena, inst, cursor, default_max_bytes, null);
        },
        .claude_start, .claude_list => unreachable,
    }
}

fn toolStart(reg: *Registry, arena: Allocator, args: json.Value) ![]const u8 {
    const cwd = jsonx.getStr(args, "cwd") orelse
        return toolError(arena, "`cwd` (absolute path) is required", .{});

    const pm = jsonx.getStr(args, "permission_mode") orelse "default";
    const modes = [_][]const u8{ "default", "acceptEdits", "plan", "bypassPermissions" };
    for (modes) |m| {
        if (eql(m, pm)) break;
    } else return toolError(arena, "invalid permission_mode '{s}'", .{instance.clip(pm, 64)});
    if (eql(pm, "bypassPermissions") and !reg.cfg.allow_bypass)
        return toolError(arena, "bypassPermissions is disabled on this server (start it with --allow-bypass)", .{});

    const model = jsonx.getStr(args, "model");
    if (model) |m| if (!isSafeArg(m)) return toolError(arena, "invalid model '{s}'", .{instance.clip(m, 64)});

    const resume_id = jsonx.getStr(args, "resume_session_id");
    if (resume_id) |s| if (!isSessionId(s)) return toolError(arena, "invalid resume_session_id", .{});

    const allowed = stringList(arena, jsonx.get(args, "allowed_tools")) catch
        return toolError(arena, "allowed_tools must be an array of strings", .{});
    for (allowed) |t| {
        if (!isSafeArg(t)) return toolError(arena, "invalid allowed_tools entry '{s}'", .{instance.clip(t, 64)});
    }

    const inst = reg.start(.{
        .cwd = cwd,
        .model = model,
        .permission_mode = pm,
        .allowed_tools = allowed,
        .resume_session_id = resume_id,
    }) catch |err| return switch (err) {
        error.CwdNotAbsolute => toolError(arena, "cwd must be an absolute path", .{}),
        error.CwdNotFound => toolError(arena, "cwd does not exist: {s}", .{cwd}),
        error.CwdNotDirectory => toolError(arena, "cwd is not a directory: {s}", .{cwd}),
        error.CwdNotAllowed => toolError(arena, "cwd is outside the allowed roots: {s}", .{
            try std.mem.join(arena, ", ", reg.cfg.roots),
        }),
        error.TooManyInstances => toolError(arena, "too many running instances (max {d}); stop one first", .{reg.cfg.max_live}),
        error.OutOfMemory => error.OutOfMemory,
        else => toolError(arena, "failed to launch '{s}': {s}", .{ reg.cfg.claude_path, @errorName(err) }),
    };
    defer inst.release();

    if (jsonx.getStr(args, "prompt")) |prompt| {
        if (prompt.len > 0) return sendAndReport(arena, inst, prompt, waitArg(args, default_wait_s));
    }
    return report(arena, inst, 0, default_max_bytes, null);
}

fn toolList(reg: *Registry, arena: Allocator) ![]const u8 {
    const insts = try reg.list(arena);
    defer for (insts) |x| x.release();

    var infos: std.ArrayList(instance.Info) = .empty;
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    if (insts.len == 0) try w.writeAll("No Claude Code instances. Start one with claude_start.\n");
    for (insts) |inst| {
        const i = try inst.info(arena);
        try infos.append(arena, i);
        try writeInfoLine(w, i);
    }
    return toolOk(arena, aw.written(), .{ .instances = infos.items });
}

fn sendAndReport(arena: Allocator, inst: *Instance, prompt: []const u8, wait_s: u64) ![]const u8 {
    const sent = inst.send(prompt) catch |err| switch (err) {
        error.InstanceExited => return toolError(arena, "instance {s} has exited; start a new one (resume_session_id keeps the conversation)", .{inst.id()}),
        else => return toolError(arena, "sending prompt failed: {s}", .{@errorName(err)}),
    };
    const completed = if (wait_s > 0) inst.waitTurns(sent.target_turns, wait_s * std.time.ns_per_s) else false;
    return report(arena, inst, sent.cursor, default_max_bytes, completed);
}

/// Text: status line + transcript from `since`. structuredContent: instance info + cursors.
fn report(arena: Allocator, inst: *Instance, since: u64, max_bytes: usize, completed: ?bool) ![]const u8 {
    const page = try inst.eventsSince(arena, since, max_bytes);
    const info = try inst.info(arena);

    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try writeInfoLine(w, info);
    if (page.skipped > 0) try w.print("({d} older events were dropped)\n", .{page.skipped});
    for (page.events) |e| try w.print("[{d}] {s}: {s}\n", .{ e.seq, e.kind, e.text });
    if (page.more) {
        try w.print("More output available: call claude_output with since={d}.\n", .{page.next_cursor});
    } else if (completed != null and !completed.?) {
        try w.print("Turn still running: call claude_output with since={d} and wait_seconds to follow it.\n", .{page.next_cursor});
    }

    return toolOk(arena, aw.written(), .{
        .instance = info,
        .completed = completed,
        .next_cursor = page.next_cursor,
        .more = page.more,
    });
}

fn writeInfoLine(w: *std.Io.Writer, i: instance.Info) !void {
    try w.print("instance {s} [{s}] cwd={s} session={s} turns={d} pending={d} cost=${d:.4}", .{
        i.id,
        @tagName(i.state),
        i.cwd,
        i.session_id orelse "-",
        i.completed_turns,
        i.pending_turns,
        i.total_cost_usd,
    });
    if (i.exit_code) |c| try w.print(" exit={d}", .{c});
    try w.writeAll("\n");
}

fn toolOk(arena: Allocator, text: []const u8, structured: anytype) ![]const u8 {
    return json.Stringify.valueAlloc(arena, .{
        .content = .{.{ .type = "text", .text = text }},
        .structuredContent = structured,
        .isError = false,
    }, .{});
}

fn toolError(arena: Allocator, comptime fmt: []const u8, args: anytype) ![]const u8 {
    const msg = try std.fmt.allocPrint(arena, fmt, args);
    return json.Stringify.valueAlloc(arena, .{
        .content = .{.{ .type = "text", .text = msg }},
        .isError = true,
    }, .{});
}

fn rpcResult(arena: Allocator, id: json.Value, result: []const u8) ![]const u8 {
    const id_json = try json.Stringify.valueAlloc(arena, id, .{});
    return std.fmt.allocPrint(arena, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}", .{ id_json, result });
}

fn rpcError(arena: Allocator, id: json.Value, code: i64, msg: []const u8) ![]const u8 {
    return json.Stringify.valueAlloc(arena, .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{ .code = code, .message = msg },
    }, .{});
}

fn waitArg(args: json.Value, default: u64) u64 {
    const v = jsonx.getInt(args, "wait_seconds") orelse return default;
    return @intCast(std.math.clamp(v, 0, max_wait_s));
}

/// Accepts an array of strings, or a single comma-separated string.
fn stringList(arena: Allocator, v: ?json.Value) ![]const []const u8 {
    const val = v orelse return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    switch (val) {
        .null => {},
        .array => |arr| for (arr.items) |item| {
            if (item != .string) return error.InvalidArgument;
            const t = std.mem.trim(u8, item.string, " ");
            if (t.len > 0) try out.append(arena, t);
        },
        .string => |s| {
            var it = std.mem.splitScalar(u8, s, ',');
            while (it.next()) |part| {
                const t = std.mem.trim(u8, part, " ");
                if (t.len > 0) try out.append(arena, t);
            }
        },
        else => return error.InvalidArgument,
    }
    return out.items;
}

/// Values passed on claude's argv. No shell is involved, but reject anything
/// that could be read as a flag or that Windows .cmd shims can't quote safely.
fn isSafeArg(s: []const u8) bool {
    if (s.len == 0 or s.len > 256 or s[0] == '-') return false;
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9' => {},
        '.', '_', ':', '(', ')', '*', '/', '\\', ' ', '-', '~', '@', '=', ',', '[', ']', '+' => {},
        else => return false,
    };
    return true;
}

fn isSessionId(s: []const u8) bool {
    if (s.len == 0 or s.len > 64) return false;
    for (s) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-' => {},
        else => return false,
    };
    return true;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

const testing = std.testing;

fn testCall(reg: *Registry, arena: Allocator, body: []const u8) !json.Value {
    const out = (try handle(reg, arena, body)) orelse return error.NoResponse;
    return json.parseFromSliceLeaky(json.Value, arena, out, .{});
}

test "tools_json is valid and complete" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const v = try json.parseFromSliceLeaky(json.Value, arena_state.allocator(), tools_json, .{});
    try testing.expectEqual(@as(usize, std.meta.fields(Tool).len), v.array.items.len);
    for (v.array.items) |t| {
        const name = jsonx.getStr(t, "name").?;
        try testing.expect(std.meta.stringToEnum(Tool, name) != null);
        try testing.expect(jsonx.getPath(t, &.{ "annotations", "readOnlyHint" }) != null);
        try testing.expect(jsonx.getPath(t, &.{ "annotations", "destructiveHint" }) != null);
    }
}

test "initialize, list, errors, notifications" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var reg = Registry.init(testing.allocator, testing.io, .{});
    defer reg.deinit();

    const init = try testCall(&reg, arena,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}
    );
    try testing.expectEqualStrings("2025-03-26", jsonx.getStr(jsonx.get(init, "result").?, "protocolVersion").?);

    const init2 = try testCall(&reg, arena,
        \\{"jsonrpc":"2.0","id":"a","method":"initialize","params":{"protocolVersion":"1999-01-01"}}
    );
    try testing.expectEqualStrings("a", jsonx.getStr(init2, "id").?);
    try testing.expectEqualStrings(protocol_versions[0], jsonx.getStr(jsonx.get(init2, "result").?, "protocolVersion").?);

    const list = try testCall(&reg, arena,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    );
    try testing.expectEqual(@as(usize, 6), jsonx.getPath(list, &.{ "result", "tools" }).?.array.items.len);

    try testing.expect((try handle(&reg, arena,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    )) == null);

    const unknown = try testCall(&reg, arena,
        \\{"jsonrpc":"2.0","id":3,"method":"nope"}
    );
    try testing.expectEqual(@as(i64, -32601), jsonx.getInt(jsonx.get(unknown, "error").?, "code").?);

    const bad = try testCall(&reg, arena, "{not json");
    try testing.expectEqual(@as(i64, -32700), jsonx.getInt(jsonx.get(bad, "error").?, "code").?);
}

test "tool errors are reported as isError results" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var reg = Registry.init(testing.allocator, testing.io, .{});
    defer reg.deinit();

    const empty = try testCall(&reg, arena,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"claude_list","arguments":{}}}
    );
    try testing.expectEqual(false, jsonx.getBool(jsonx.get(empty, "result").?, "isError").?);

    const missing = try testCall(&reg, arena,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"claude_send","arguments":{"id":"deadbeef","prompt":"hi"}}}
    );
    try testing.expectEqual(true, jsonx.getBool(jsonx.get(missing, "result").?, "isError").?);

    const bypass = try testCall(&reg, arena,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"claude_start","arguments":{"cwd":"/","permission_mode":"bypassPermissions"}}}
    );
    try testing.expectEqual(true, jsonx.getBool(jsonx.get(bypass, "result").?, "isError").?);

    const outside = try testCall(&reg, arena,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"claude_start","arguments":{"cwd":"/"}}}
    );
    try testing.expectEqual(true, jsonx.getBool(jsonx.get(outside, "result").?, "isError").?);

    const unknown_tool = try testCall(&reg, arena,
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"rm_rf"}}
    );
    try testing.expectEqual(@as(i64, -32602), jsonx.getInt(jsonx.get(unknown_tool, "error").?, "code").?);
}

test "argument validation" {
    try testing.expect(isSafeArg("Bash(npm test:*)"));
    try testing.expect(isSafeArg("claude-sonnet-5-5"));
    try testing.expect(!isSafeArg("--dangerously-skip-permissions"));
    try testing.expect(!isSafeArg("a\"b"));
    try testing.expect(!isSafeArg("%PATH%"));
    try testing.expect(isSessionId("11111111-2222-4333-8444-555555555555"));
    try testing.expect(!isSessionId("../x"));
}

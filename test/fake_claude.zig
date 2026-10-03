//! Mimics `claude -p --input-format stream-json --output-format stream-json`
//! closely enough for the integration test: echoes each user turn.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);
    var session: []const u8 = "11111111-2222-4333-8444-555555555555";
    for (args, 0..) |a, i| {
        if (std.mem.eql(u8, a, "--resume") and i + 1 < args.len) session = args[i + 1];
    }

    var in_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(io, &in_buf);
    var out_buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;

    var inited = false;
    var turns: u32 = 0;
    while (true) {
        const line = stdin.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const msg = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch {
            std.debug.print("fake_claude: bad input line\n", .{});
            continue;
        };
        const typ = msg.object.get("type").?.string;

        if (std.mem.eql(u8, typ, "control_request")) {
            try emit(arena, out, .{
                .type = "control_response",
                .response = .{ .subtype = "success", .request_id = msg.object.get("request_id").?.string },
            });
            continue;
        }
        if (!std.mem.eql(u8, typ, "user")) continue;

        if (!inited) {
            inited = true;
            try emit(arena, out, .{ .type = "system", .subtype = "init", .session_id = session, .model = "fake-model" });
        }
        turns += 1;
        // Noise real claude emits; the server should drop it.
        try emit(arena, out, .{ .type = "rate_limit_event", .session_id = session });
        try emit(arena, out, .{ .type = "system", .subtype = "thinking_tokens", .session_id = session });
        const prompt = msg.object.get("message").?.object.get("content").?.string;
        const reply = try std.fmt.allocPrint(arena, "echo: {s}", .{prompt});
        std.debug.print("fake_claude: turn {d}\n", .{turns});

        try emit(arena, out, .{
            .type = "assistant",
            .message = .{ .role = "assistant", .content = .{
                .{ .type = "text", .text = reply },
                .{ .type = "tool_use", .id = "t1", .name = "Read", .input = .{ .file_path = "README.md" } },
            } },
            .session_id = session,
        });
        try emit(arena, out, .{
            .type = "user",
            .message = .{ .role = "user", .content = .{
                .{ .type = "tool_result", .tool_use_id = "t1", .content = "file contents", .is_error = false },
            } },
            .session_id = session,
        });
        try emit(arena, out, .{
            .type = "result",
            .subtype = "success",
            .is_error = false,
            .result = reply,
            .num_turns = turns,
            .total_cost_usd = 0.001 * @as(f64, @floatFromInt(turns)),
            .session_id = session,
        });
    }
}

fn emit(arena: std.mem.Allocator, out: *std.Io.Writer, value: anytype) !void {
    try out.writeAll(try std.json.Stringify.valueAlloc(arena, value, .{}));
    try out.writeAll("\n");
    try out.flush();
}

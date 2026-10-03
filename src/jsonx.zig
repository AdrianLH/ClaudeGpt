//! Small accessors for std.json.Value trees.
const std = @import("std");
const Value = std.json.Value;

pub fn get(v: Value, key: []const u8) ?Value {
    if (v != .object) return null;
    return v.object.get(key);
}

pub fn getPath(v: Value, keys: []const []const u8) ?Value {
    var cur = v;
    for (keys) |k| cur = get(cur, k) orelse return null;
    return cur;
}

pub fn getStr(v: Value, key: []const u8) ?[]const u8 {
    const x = get(v, key) orelse return null;
    return if (x == .string) x.string else null;
}

pub fn getBool(v: Value, key: []const u8) ?bool {
    const x = get(v, key) orelse return null;
    return if (x == .bool) x.bool else null;
}

pub fn getInt(v: Value, key: []const u8) ?i64 {
    const x = get(v, key) orelse return null;
    return switch (x) {
        .integer => |i| i,
        .float => |f| if (std.math.isFinite(f) and @abs(f) < 1e15) @as(i64, @intFromFloat(f)) else null,
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

pub fn getFloat(v: Value, key: []const u8) ?f64 {
    const x = get(v, key) orelse return null;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

test "accessors" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(Value, gpa,
        \\{"a":{"b":"x"},"n":3,"f":1.5,"t":true}
    , .{});
    defer parsed.deinit();
    const v = parsed.value;
    try std.testing.expectEqualStrings("x", getStr(getPath(v, &.{"a"}).?, "b").?);
    try std.testing.expectEqual(@as(i64, 3), getInt(v, "n").?);
    try std.testing.expectEqual(@as(f64, 1.5), getFloat(v, "f").?);
    try std.testing.expect(getBool(v, "t").?);
    try std.testing.expect(getStr(v, "missing") == null);
}

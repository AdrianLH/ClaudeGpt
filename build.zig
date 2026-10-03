const std = @import("std");
const builtin = @import("builtin");

comptime {
    // std.Io / std.net / std.json APIs used here are the 0.15 ones.
    if (builtin.zig_version.major != 0 or builtin.zig_version.minor != 15)
        @compileError("claudegpt targets Zig 0.15.x");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{ .name = "claudegpt", .root_module = mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the MCP server").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(tests).step);

    // Stand-in for the `claude` CLI, used by test/integration.sh.
    const fake = b.addExecutable(.{
        .name = "fake_claude",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/fake_claude.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.step("fake", "Build the fake claude CLI for integration tests")
        .dependOn(&b.addInstallArtifact(fake, .{}).step);
}

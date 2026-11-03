const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Fast and small builds drop what only debugging needs; safe builds keep
    // symbols and unwind tables so a panic has a stack trace.
    const release = optimize == .fast or optimize == .small;

    const mod = b.addModule("crystal", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .omit_frame_pointer = if (release) true else null,
        .unwind_tables = if (release) .none else null,
        .stack_check = if (release) false else null,
        .stack_protector = if (release) false else null,
        .error_tracing = if (release) false else null,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

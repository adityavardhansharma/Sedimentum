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

    // zig-out/bin/crystal-bench <agent|recall|hard|jargon|lanes> <new-dir> [memories] [meaning-model]
    const bench = b.addExecutable(.{
        .name = "crystal-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .omit_frame_pointer = if (release) true else null,
            .unwind_tables = if (release) .none else null,
            .stack_check = if (release) false else null,
            .stack_protector = if (release) false else null,
            .error_tracing = if (release) false else null,
            .strip = if (release) true else null,
            .link_libc = true,
            .imports = &.{.{ .name = "crystal", .module = mod }},
        }),
    });
    b.installArtifact(bench);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

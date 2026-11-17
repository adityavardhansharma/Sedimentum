const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Fast and small builds drop what only debugging needs; safe builds keep
    // symbols and unwind tables so a panic has a stack trace.
    const release = optimize == .fast or optimize == .small;

    const mod = b.addModule("loom", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .omit_frame_pointer = if (release) true else null,
        .unwind_tables = if (release) .none else null,
        .stack_check = if (release) false else null,
        .stack_protector = if (release) false else null,
        .error_tracing = if (release) false else null,
    });

    // zig-out/bin/loom-bench <agent|recall|hard|jargon|lanes> <new-dir> [memories] [meaning-model]
    const bench = b.addExecutable(.{
        .name = "loom-bench",
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
            .imports = &.{.{ .name = "loom", .module = mod }},
        }),
    });
    b.installArtifact(bench);

    // zig-out/bin/loom-flushbench <each|leader|fdatasync> <file>: the
    // durable turn rate of the disk alone (Linux).
    if (target.result.os.tag == .linux) b.installArtifact(b.addExecutable(.{
        .name = "loom-flushbench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/flushbench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    }));

    // zig-out/bin/loom-schema <store-dir> [name] [slots]: what a store learned.
    b.installArtifact(b.addExecutable(.{
        .name = "loom-schema",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/schema.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "loom", .module = mod }},
        }),
    }));

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

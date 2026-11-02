const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Release builds drop what only debugging needs: frame pointers,
    // unwind tables, stack probes, error return traces and symbols.
    const release = optimize != .debug;
    const lean: Lean = .{
        .omit_frame_pointer = if (release) true else null,
        .unwind_tables = if (release) .none else null,
        .stack_check = if (release) false else null,
        .stack_protector = if (release) false else null,
        .error_tracing = if (release) false else null,
        .strip = if (release) true else null,
    };

    const mod = b.addModule("sedimentum", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .omit_frame_pointer = lean.omit_frame_pointer,
        .unwind_tables = lean.unwind_tables,
        .stack_check = lean.stack_check,
        .stack_protector = lean.stack_protector,
        .error_tracing = lean.error_tracing,
    });

    // Benchmark: zig-out/bin/sedimentum-holo-bench <agent|recall|hard|jargon> <new-dir> [memories]
    const opts = b.addOptions();
    opts.addOption(bool, "stratum", false);
    b.installArtifact(exe(b, "sedimentum-holo-bench", "src/holo/bench.zig", target, optimize, lean, true, &.{
        .{ .name = "sedimentum", .module = mod },
        .{ .name = "bench_options", .module = opts.createModule() },
    }));

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

const Lean = struct {
    omit_frame_pointer: ?bool,
    unwind_tables: ?std.builtin.UnwindTables,
    stack_check: ?bool,
    stack_protector: ?bool,
    error_tracing: ?bool,
    strip: ?bool,
};

fn exe(b: *std.Build, name: []const u8, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, lean: Lean, libc: bool, imports: []const std.Build.Module.Import) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .omit_frame_pointer = lean.omit_frame_pointer,
            .unwind_tables = lean.unwind_tables,
            .stack_check = lean.stack_check,
            .stack_protector = lean.stack_protector,
            .error_tracing = lean.error_tracing,
            .strip = lean.strip,
            .link_libc = libc,
            .imports = imports,
        }),
    });
}

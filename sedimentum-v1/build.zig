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

    // C ABI shared library: zig-out/lib/libsedimentum.so (+ include/sedimentum.h)
    const lib = b.addLibrary(.{
        .name = "sedimentum",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
            .omit_frame_pointer = lean.omit_frame_pointer,
            .unwind_tables = lean.unwind_tables,
            .stack_check = lean.stack_check,
            .stack_protector = lean.stack_protector,
            .error_tracing = lean.error_tracing,
            .strip = lean.strip,
        }),
    });
    b.installArtifact(lib);
    b.installFile("include/sedimentum.h", "include/sedimentum.h");

    // Command-line tool: zig-out/bin/sedimentum
    const cli = b.addExecutable(.{
        .name = "sedimentum",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli.zig"),
            .target = target,
            .optimize = optimize,
            .omit_frame_pointer = lean.omit_frame_pointer,
            .unwind_tables = lean.unwind_tables,
            .stack_check = lean.stack_check,
            .stack_protector = lean.stack_protector,
            .error_tracing = lean.error_tracing,
            .strip = lean.strip,
            .imports = &.{.{ .name = "sedimentum", .module = mod }},
        }),
    });
    b.installArtifact(cli);

    // Head-to-head benchmark with kiban:
    //   zig build -Doptimize=ReleaseFast && zig-out/bin/sedimentum-bench <dir> [records]
    const bench = b.addExecutable(.{
        .name = "sedimentum-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .omit_frame_pointer = lean.omit_frame_pointer,
            .unwind_tables = lean.unwind_tables,
            .stack_check = lean.stack_check,
            .stack_protector = lean.stack_protector,
            .error_tracing = lean.error_tracing,
            .strip = lean.strip,
            // glibc malloc hands freed memory back to the OS, so RSS tracks
            // what the engine holds rather than allocator caches.
            .link_libc = true,
            .imports = &.{.{ .name = "sedimentum", .module = mod }},
        }),
    });
    b.installArtifact(bench);

    // Holo and Stratum benchmarks: the same workloads (agent, recall, hard,
    // jargon) against either engine.
    //   zig-out/bin/sedimentum-holo-bench    <agent|recall|hard|jargon> <new-dir> [memories]
    //   zig-out/bin/sedimentum-stratum-bench <agent|recall|hard|jargon> <new-dir> [memories]
    for ([_]struct { name: []const u8, stratum: bool }{
        .{ .name = "sedimentum-holo-bench", .stratum = false },
        .{ .name = "sedimentum-stratum-bench", .stratum = true },
    }) |e| {
        const opts = b.addOptions();
        opts.addOption(bool, "stratum", e.stratum);
        const exe = b.addExecutable(.{
            .name = e.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/holo/bench.zig"),
                .target = target,
                .optimize = optimize,
                .omit_frame_pointer = lean.omit_frame_pointer,
                .unwind_tables = lean.unwind_tables,
                .stack_check = lean.stack_check,
                .stack_protector = lean.stack_protector,
                .error_tracing = lean.error_tracing,
                .strip = lean.strip,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "sedimentum", .module = mod },
                    .{ .name = "bench_options", .module = opts.createModule() },
                },
            }),
        });
        b.installArtifact(exe);
    }

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

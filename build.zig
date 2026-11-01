const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("sedimentum", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // C ABI shared library: zig-out/lib/libsedimentum.so (+ include/sedimentum.h)
    const lib = b.addLibrary(.{
        .name = "sedimentum",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
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
            .imports = &.{.{ .name = "sedimentum", .module = mod }},
        }),
    });
    b.installArtifact(bench);

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

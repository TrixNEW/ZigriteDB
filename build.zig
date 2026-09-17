const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("zigritedb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const library = b.addLibrary(.{
        .name = "zigritedb",
        .linkage = .static,
        .root_module = module,
    });
    b.installArtifact(library);

    const native_module = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .link_libc = true,
        .target = target,
        .optimize = optimize,
    });
    const native = b.addLibrary(.{ .name = "zigritedb_native", .linkage = .dynamic, .root_module = native_module });
    b.installArtifact(native);
    b.installFile("include/zigritedb.h", "include/zigritedb.h");

    const smoke_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    smoke_module.addCSourceFile(.{ .file = b.path("tests/native/native_smoke.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    smoke_module.addIncludePath(b.path("include"));
    smoke_module.linkLibrary(native);
    const smoke = b.addExecutable(.{ .name = "native_smoke", .root_module = smoke_module });
    const native_tests = b.step("native-test", "Build the C API smoke test");
    native_tests.dependOn(&b.addInstallArtifact(smoke, .{}).step);
    native_tests.dependOn(&b.addInstallArtifact(native, .{}).step);

    if (target.result.os.tag == .linux) {
        const bench_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
        bench_module.addCSourceFile(.{ .file = b.path("tests/bench/native.c"), .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
        bench_module.addIncludePath(b.path("include"));
        bench_module.linkLibrary(native);
        const bench = b.addExecutable(.{ .name = "native_bench", .root_module = bench_module });
        const benchmark = b.step("bench", "Build the native workload benchmark");
        benchmark.dependOn(&b.addInstallArtifact(bench, .{}).step);
        benchmark.dependOn(&b.addInstallArtifact(native, .{}).step);
    }

    const unit_tests = b.addTest(.{ .root_module = module });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const integration_module = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigritedb", .module = module }},
    });
    const integration_tests = b.addTest(.{ .root_module = integration_module });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const fuzz_module = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        // Zig 0.16 fuzz error traces use an incompatible stack-trace type.
        .error_tracing = false,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigritedb", .module = module }},
    });
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_module, .use_llvm = true, .use_lld = true });
    b.step("fuzz", "Run the parser fuzz target").dependOn(&b.addRunArtifact(fuzz_tests).step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}

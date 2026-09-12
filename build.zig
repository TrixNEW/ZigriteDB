const std = @import("std");

pub fn build(b: *std.Build) void {
    const module = b.addModule("zigitedb", .{
        .root_source_file = b.path("src/root.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });
    b.installArtifact(b.addLibrary(.{ .name = "zigitedb", .linkage = .static, .root_module = module }));
    const tests = b.addRunArtifact(b.addTest(.{ .root_module = module }));
    b.step("test", "Run unit tests").dependOn(&tests.step);
}

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public Pollock module.
    const pollock_mod = b.addModule("pollock", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    pollock_mod.addImport("pollock", pollock_mod);

    // Pollock executable.
    const pollock_exe = b.addExecutable(.{
        .name = "pollock",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pollock", .module = pollock_mod },
            },
        }),
    });

    b.installArtifact(pollock_exe);

    // Run executable.
    const run_command = b.addRunArtifact(pollock_exe);
    const run_step = b.step("run", "Run Pollock");
    run_step.dependOn(&run_command.step);

    // Unit tests.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pollock", .module = pollock_mod },
            },
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests.");
    test_step.dependOn(&run_tests.step);
}

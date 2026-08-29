const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Main executable
    const exe = b.addExecutable(.{
        .name = "ac",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run ac calculator");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = exe_mod,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const posix_mod = b.createModule(.{
        .root_source_file = b.path("tests/posix/runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ac", .module = exe_mod },
        },
    });
    const posix_tests = b.addTest(.{
        .root_module = posix_mod,
    });
    const run_posix_tests = b.addRunArtifact(posix_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_posix_tests.step);
}

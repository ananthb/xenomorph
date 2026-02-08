const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main executable
    const exe = b.addExecutable(.{
        .name = "xenomorph",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run xenomorph");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests (separate step as they require root)
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const run_integration_tests = b.addRunArtifact(integration_tests);

    const integration_test_step = b.step("test-integration", "Run integration tests (requires root)");
    integration_test_step.dependOn(&run_integration_tests.step);

    // QEMU integration test executable
    const qemu_test_exe = b.addExecutable(.{
        .name = "qemu-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration/qemu_test.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    b.installArtifact(qemu_test_exe);

    // Run QEMU test
    const run_qemu_test = b.addRunArtifact(qemu_test_exe);
    run_qemu_test.step.dependOn(b.getInstallStep());

    const qemu_test_step = b.step("test-qemu", "Run QEMU integration test (requires kernel, busybox, qemu)");
    qemu_test_step.dependOn(&run_qemu_test.step);
}

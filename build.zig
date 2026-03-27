const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // OCI library dependency (../oci)
    const oci_dep = b.dependency("oci", .{});
    const oci_module = oci_dep.module("oci");

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
    exe.root_module.addImport("oci", oci_module);

    b.installArtifact(exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run xenomorph");
    run_step.dependOn(&run_cmd.step);

    // Inline tests (from src/)
    const inline_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    inline_tests.root_module.addImport("oci", oci_module);

    // Unit test suite (from tests/unit/)
    const unit_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const unit_xenomorph_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_xenomorph_module.addImport("oci", oci_module);
    unit_module.addImport("xenomorph", unit_xenomorph_module);
    unit_module.addImport("oci", oci_module);
    const unit_tests = b.addTest(.{
        .root_module = unit_module,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(inline_tests).step);
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Integration tests (separate step as they require root)
    const integration_module = b.createModule(.{
        .root_source_file = b.path("tests/integration/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const integration_xenomorph_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    integration_xenomorph_module.addImport("oci", oci_module);
    integration_module.addImport("xenomorph", integration_xenomorph_module);
    const integration_tests = b.addTest(.{
        .root_module = integration_module,
    });

    const integration_test_step = b.step("test-integration", "Run integration tests (requires root)");
    integration_test_step.dependOn(&b.addRunArtifact(integration_tests).step);

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

    const run_qemu_test = b.addRunArtifact(qemu_test_exe);
    run_qemu_test.step.dependOn(b.getInstallStep());

    const qemu_test_step = b.step("test-qemu", "Run QEMU integration test (requires kernel, busybox, qemu)");
    qemu_test_step.dependOn(&run_qemu_test.step);
}

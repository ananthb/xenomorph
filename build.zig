const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // OCI library dependency
    const oci_dep = b.dependency("oci", .{});
    const oci_module = oci_dep.module("oci");

    // Compile xenomorph-init binary (embedded into xenomorph at build time)
    const init_exe = b.addExecutable(.{
        .name = "xenomorph-init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/xenomorph-init.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Create a module that provides the init binary bytes via @embedFile.
    // We write a small Zig file that imports the binary, and add the binary
    // as a named resource so @embedFile can find it.
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(init_exe.getEmittedBin(), "xenomorph-init");
    const embed_mod = b.createModule(.{
        .root_source_file = wf.add("init_bin.zig",
            \\pub const data = @embedFile("xenomorph-init");
        ),
    });

    // Helper to create a xenomorph module with all dependencies
    const makeXenomorphModule = struct {
        fn f(
            b_: *std.Build,
            target_: std.Build.ResolvedTarget,
            optimize_: std.builtin.OptimizeMode,
            oci_mod: *std.Build.Module,
            embed: *std.Build.Module,
        ) *std.Build.Module {
            const m = b_.createModule(.{
                .root_source_file = b_.path("src/main.zig"),
                .target = target_,
                .optimize = optimize_,
                .link_libc = true,
            });
            m.addImport("oci", oci_mod);
            m.addImport("init_bin", embed);
            return m;
        }
    }.f;

    // Main executable
    const exe = b.addExecutable(.{
        .name = "xenomorph",
        .root_module = makeXenomorphModule(b, target, optimize, oci_module, embed_mod),
    });

    b.installArtifact(exe);
    b.installArtifact(init_exe);

    // Run command
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run xenomorph");
    run_step.dependOn(&run_cmd.step);

    // Inline tests
    const inline_tests = b.addTest(.{
        .root_module = makeXenomorphModule(b, target, optimize, oci_module, embed_mod),
    });

    // Unit test suite
    const unit_module = b.createModule(.{
        .root_source_file = b.path("tests/unit/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_module.addImport("xenomorph", makeXenomorphModule(b, target, optimize, oci_module, embed_mod));
    unit_module.addImport("oci", oci_module);
    unit_module.addImport("init_bin", embed_mod);
    const unit_tests = b.addTest(.{
        .root_module = unit_module,
    });

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(inline_tests).step);
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // Integration tests
    const integration_module = b.createModule(.{
        .root_source_file = b.path("tests/integration/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    integration_module.addImport("xenomorph", makeXenomorphModule(b, target, optimize, oci_module, embed_mod));
    const integration_tests = b.addTest(.{
        .root_module = integration_module,
    });

    const integration_test_step = b.step("test-integration", "Run integration tests (requires root)");
    integration_test_step.dependOn(&b.addRunArtifact(integration_tests).step);

    // QEMU test
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

    // Fuzz targets
    const fuzz_module = b.createModule(.{
        .root_source_file = b.path("tests/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    fuzz_module.addImport("xenomorph", makeXenomorphModule(b, target, optimize, oci_module, embed_mod));
    fuzz_module.addImport("oci", oci_module);
    const fuzz_tests = b.addTest(.{
        .root_module = fuzz_module,
    });

    const fuzz_step = b.step("fuzz", "Run fuzz tests (use -ffuzz for continuous fuzzing)");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);

    // Valgrind step
    const valgrind_step = b.step("valgrind", "Run tests under valgrind");
    const valgrind_run = b.addSystemCommand(&.{
        "valgrind",
        "--leak-check=full",
        "--error-exitcode=1",
        "--track-origins=yes",
    });
    valgrind_run.addArtifactArg(inline_tests);
    valgrind_step.dependOn(&valgrind_run.step);
}

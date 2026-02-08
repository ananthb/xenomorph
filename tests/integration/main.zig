const std = @import("std");

// Import all modules for integration testing
const main = @import("../../src/main.zig");
const log = main.log;
const rootfs_verify = main.rootfs_verify;
const rootfs_builder = main.rootfs_builder;
const pivot = main.pivot;
const process_scanner = main.process_scanner;
const init_detector = main.init_detector;

/// Integration tests for xenomorph
/// NOTE: Most of these tests require root privileges and should be run in a VM

test "integration: detect init system" {
    const allocator = std.testing.allocator;

    // This should work even without root
    const detection = init_detector.detect(allocator) catch |err| {
        std.debug.print("Init detection failed (expected in some environments): {}\n", .{err});
        return;
    };
    defer {
        var d = detection;
        d.deinit(allocator);
    }

    std.debug.print("Detected init system: {s}\n", .{detection.init_system.name()});
    std.debug.print("PID 1 comm: {s}\n", .{detection.pid1_comm});
}

test "integration: scan processes" {
    const allocator = std.testing.allocator;

    const processes = process_scanner.scanProcesses(allocator) catch |err| {
        std.debug.print("Process scan failed: {}\n", .{err});
        return;
    };
    defer {
        for (processes) |*p| {
            var proc = p.*;
            proc.deinit(allocator);
        }
        allocator.free(processes);
    }

    std.debug.print("Found {} processes\n", .{processes.len});
    try std.testing.expect(processes.len > 0);

    // Find init
    var found_init = false;
    for (processes) |p| {
        if (p.pid == 1) {
            found_init = true;
            std.debug.print("Init process: {s}\n", .{p.comm});
            break;
        }
    }
    try std.testing.expect(found_init);
}

test "integration: verify nonexistent rootfs fails" {
    const allocator = std.testing.allocator;

    const result = rootfs_verify.verify("/nonexistent/rootfs/path", allocator) catch {
        // Expected to fail
        return;
    };
    defer {
        var r = result;
        r.deinit(allocator);
    }

    try std.testing.expect(!result.valid);
}

test "integration: check if in container" {
    const in_container = main.process_namespace.inContainer();
    std.debug.print("Running in container: {}\n", .{in_container});
}

test "integration: parse image reference" {
    const allocator = std.testing.allocator;

    // Test various image formats
    const refs = [_][]const u8{
        "alpine",
        "alpine:3.18",
        "library/alpine:latest",
        "docker.io/library/alpine:latest",
        "ghcr.io/user/image:v1.0",
    };

    for (refs) |ref_str| {
        var ref = main.oci_image.ImageReference.parse(ref_str, allocator) catch |err| {
            std.debug.print("Failed to parse '{s}': {}\n", .{ ref_str, err });
            continue;
        };
        defer ref.deinit(allocator);

        std.debug.print("Parsed '{s}':\n", .{ref_str});
        std.debug.print("  Registry: {s}\n", .{ref.registry});
        std.debug.print("  Repository: {s}\n", .{ref.repository});
        std.debug.print("  Tag: {s}\n", .{ref.tag});
    }
}

// Tests below require root and a proper test environment

test "integration: create mount namespace (requires root)" {
    // Skip if not root
    if (std.os.linux.getuid() != 0) {
        std.debug.print("Skipping: requires root\n", .{});
        return;
    }

    main.pivot_mounts.createMountNamespace() catch |err| {
        std.debug.print("Failed to create mount namespace: {}\n", .{err});
        // May fail in containers
    };
}

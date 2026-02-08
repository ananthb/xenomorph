const std = @import("std");

// Unit tests that don't require special privileges

test "unit: log levels" {
    const log = @import("../../src/util/log.zig");

    // Test level comparisons
    try std.testing.expect(@intFromEnum(log.Level.debug) < @intFromEnum(log.Level.info));
    try std.testing.expect(@intFromEnum(log.Level.info) < @intFromEnum(log.Level.warn));
    try std.testing.expect(@intFromEnum(log.Level.warn) < @intFromEnum(log.Level.err));
}

test "unit: mount flags layout" {
    const syscall = @import("../../src/util/syscall.zig");

    // Verify flag struct sizes
    try std.testing.expectEqual(@sizeOf(syscall.MountFlags), 4);
    try std.testing.expectEqual(@sizeOf(syscall.UnshareFlags), 4);
    try std.testing.expectEqual(@sizeOf(syscall.UmountFlags), 4);
}

test "unit: image reference parsing" {
    const image = @import("../../src/oci/image.zig");
    const allocator = std.testing.allocator;

    // Simple image
    {
        var ref = try image.ImageReference.parse("alpine", allocator);
        defer ref.deinit(allocator);

        try std.testing.expectEqualStrings("registry-1.docker.io", ref.registry);
        try std.testing.expectEqualStrings("library/alpine", ref.repository);
        try std.testing.expectEqualStrings("latest", ref.tag);
    }

    // Image with tag
    {
        var ref = try image.ImageReference.parse("nginx:1.25", allocator);
        defer ref.deinit(allocator);

        try std.testing.expectEqualStrings("library/nginx", ref.repository);
        try std.testing.expectEqualStrings("1.25", ref.tag);
    }

    // Image with registry
    {
        var ref = try image.ImageReference.parse("quay.io/prometheus/prometheus:v2.45.0", allocator);
        defer ref.deinit(allocator);

        try std.testing.expectEqualStrings("quay.io", ref.registry);
        try std.testing.expectEqualStrings("prometheus/prometheus", ref.repository);
        try std.testing.expectEqualStrings("v2.45.0", ref.tag);
    }
}

test "unit: compression detection" {
    const layer = @import("../../src/oci/layer.zig");

    try std.testing.expectEqual(
        layer.Compression.gzip,
        layer.Compression.fromMediaType("application/vnd.oci.image.layer.v1.tar+gzip"),
    );

    try std.testing.expectEqual(
        layer.Compression.zstd,
        layer.Compression.fromMediaType("application/vnd.oci.image.layer.v1.tar+zstd"),
    );

    try std.testing.expectEqual(
        layer.Compression.none,
        layer.Compression.fromMediaType("application/vnd.oci.image.layer.v1.tar"),
    );
}

test "unit: essential process detection" {
    const essential = @import("../../src/process/essential.zig");

    // Known essential names
    try std.testing.expect(essential.isEssentialName("systemd"));
    try std.testing.expect(essential.isEssentialName("init"));
    try std.testing.expect(essential.isEssentialName("kthreadd"));
    try std.testing.expect(essential.isEssentialName("udevd"));

    // Non-essential
    try std.testing.expect(!essential.isEssentialName("nginx"));
    try std.testing.expect(!essential.isEssentialName("postgres"));
    try std.testing.expect(!essential.isEssentialName("node"));
}

test "unit: init system names" {
    const detector = @import("../../src/init/detector.zig");

    try std.testing.expectEqualStrings("systemd", detector.InitSystem.systemd.name());
    try std.testing.expectEqualStrings("OpenRC", detector.InitSystem.openrc.name());
    try std.testing.expectEqualStrings("SysV init", detector.InitSystem.sysvinit.name());
    try std.testing.expectEqualStrings("runit", detector.InitSystem.runit.name());
    try std.testing.expectEqualStrings("unknown", detector.InitSystem.unknown.name());
}

test "unit: namespace types" {
    const namespace = @import("../../src/process/namespace.zig");

    try std.testing.expectEqualStrings("mnt", namespace.NamespaceType.mount.toPath());
    try std.testing.expectEqualStrings("net", namespace.NamespaceType.network.toPath());
    try std.testing.expectEqualStrings("pid", namespace.NamespaceType.pid.toPath());
    try std.testing.expectEqualStrings("user", namespace.NamespaceType.user.toPath());
}

test "unit: layer cache path generation" {
    const cache = @import("../../src/oci/cache.zig");
    const allocator = std.testing.allocator;

    var layer_cache = cache.LayerCache.initWithDir(allocator, "/var/cache/test");

    const path = try layer_cache.getLayerPath("sha256:abc123def456");
    defer allocator.free(path);

    try std.testing.expectEqualStrings("/var/cache/test/blobs/sha256/abc123def456", path);
}

test "unit: config defaults" {
    const config = @import("../../src/config.zig");

    const cfg = config.Config{
        .image = "test:latest",
    };

    try std.testing.expectEqualStrings("/bin/sh", cfg.exec_cmd);
    try std.testing.expectEqualStrings("/mnt/oldroot", cfg.keep_old_root);
    try std.testing.expectEqual(@as(u32, 30), cfg.timeout);
    try std.testing.expect(!cfg.force);
    try std.testing.expect(!cfg.verbose);
    try std.testing.expect(!cfg.dry_run);
}

test "unit: pivot config defaults" {
    const pivot_mod = @import("../../src/pivot/pivot.zig");

    const config = pivot_mod.PivotConfig{
        .new_root = "/newroot",
        .allocator = std.testing.allocator,
    };

    try std.testing.expectEqualStrings("mnt/oldroot", config.old_root_mount);
    try std.testing.expect(config.keep_old_root);
    try std.testing.expect(config.exec_cmd == null);
}

test "unit: overlay config" {
    const overlay = @import("../../src/rootfs/overlay.zig");

    const config = overlay.OverlayConfig{
        .lower_dirs = &.{ "/layer1", "/layer2", "/layer3" },
        .upper_dir = "/upper",
        .work_dir = "/work",
        .mount_point = "/merged",
    };

    try std.testing.expectEqual(@as(usize, 3), config.lower_dirs.len);
    try std.testing.expectEqualStrings("/merged", config.mount_point);
}

test "unit: sysvinit runlevels" {
    const sysvinit = @import("../../src/init/sysvinit.zig");

    try std.testing.expectEqual(@as(u8, '0'), sysvinit.Runlevel.halt);
    try std.testing.expectEqual(@as(u8, '1'), sysvinit.Runlevel.single_user);
    try std.testing.expectEqual(@as(u8, '3'), sysvinit.Runlevel.multi_user);
    try std.testing.expectEqual(@as(u8, '5'), sysvinit.Runlevel.graphical);
    try std.testing.expectEqual(@as(u8, '6'), sysvinit.Runlevel.reboot);
}

test "unit: verify result structure" {
    const verify = @import("../../src/rootfs/verify.zig");
    const allocator = std.testing.allocator;

    var result = verify.VerifyResult{
        .valid = true,
        .errors = std.ArrayList([]const u8).init(allocator),
        .warnings = std.ArrayList([]const u8).init(allocator),
    };
    defer result.deinit(allocator);

    try std.testing.expect(result.valid);
    try std.testing.expectEqual(@as(usize, 0), result.errors.items.len);
}

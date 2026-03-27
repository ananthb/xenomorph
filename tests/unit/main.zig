const std = @import("std");
const xeno = @import("xenomorph");

// Aliases for commonly used modules
const config_mod = xeno.config;
const rootfs_builder = xeno.rootfs_builder;
const oci_layout_writer = xeno.oci_layout_writer;

// Unit tests that don't require special privileges

test "unit: log levels" {
    try std.testing.expect(@intFromEnum(xeno.log.Level.debug) < @intFromEnum(xeno.log.Level.info));
    try std.testing.expect(@intFromEnum(xeno.log.Level.info) < @intFromEnum(xeno.log.Level.warn));
    try std.testing.expect(@intFromEnum(xeno.log.Level.warn) < @intFromEnum(xeno.log.Level.err));
}

test "unit: mount flags produce correct u32" {
    // Verify the toU32 method produces correct bitmask values
    const flags = xeno.syscall.MountFlags{ .bind = true, .rec = true };
    try std.testing.expectEqual(flags.toU32(), xeno.syscall.MS_BIND | xeno.syscall.MS_REC);

    const private = xeno.syscall.MountFlags{ .private = true };
    try std.testing.expectEqual(private.toU32(), xeno.syscall.MS_PRIVATE);
}

test "unit: image reference parsing" {
    const image = xeno.oci_image;
    const allocator = std.testing.allocator;

    {
        var ref = try image.ImageReference.parse("alpine", allocator);
        defer ref.deinit(allocator);
        try std.testing.expectEqualStrings("registry-1.docker.io", ref.registry);
        try std.testing.expectEqualStrings("library/alpine", ref.repository);
        try std.testing.expectEqualStrings("latest", ref.tag);
    }
    {
        var ref = try image.ImageReference.parse("nginx:1.25", allocator);
        defer ref.deinit(allocator);
        try std.testing.expectEqualStrings("library/nginx", ref.repository);
        try std.testing.expectEqualStrings("1.25", ref.tag);
    }
    {
        var ref = try image.ImageReference.parse("quay.io/prometheus/prometheus:v2.45.0", allocator);
        defer ref.deinit(allocator);
        try std.testing.expectEqualStrings("quay.io", ref.registry);
        try std.testing.expectEqualStrings("prometheus/prometheus", ref.repository);
        try std.testing.expectEqualStrings("v2.45.0", ref.tag);
    }
}

test "unit: compression detection" {
    const C = xeno.oci_layer.Compression;
    try std.testing.expectEqual(C.gzip, C.fromMediaType("application/vnd.oci.image.layer.v1.tar+gzip"));
    try std.testing.expectEqual(C.zstd, C.fromMediaType("application/vnd.oci.image.layer.v1.tar+zstd"));
    try std.testing.expectEqual(C.none, C.fromMediaType("application/vnd.oci.image.layer.v1.tar"));
}

test "unit: essential process detection" {
    const essential = xeno.process_essential;
    try std.testing.expect(essential.isEssentialName("systemd"));
    try std.testing.expect(essential.isEssentialName("init"));
    try std.testing.expect(essential.isEssentialName("kthreadd"));
    try std.testing.expect(!essential.isEssentialName("nginx"));
    try std.testing.expect(!essential.isEssentialName("postgres"));
}

test "unit: init system names" {
    const detector = xeno.init_detector;
    try std.testing.expectEqualStrings("systemd", detector.InitSystem.systemd.name());
    try std.testing.expectEqualStrings("OpenRC", detector.InitSystem.openrc.name());
    try std.testing.expectEqualStrings("SysV init", detector.InitSystem.sysvinit.name());
    try std.testing.expectEqualStrings("unknown", detector.InitSystem.unknown.name());
}

test "unit: namespace types" {
    const ns = xeno.process_namespace;
    try std.testing.expectEqualStrings("mnt", ns.NamespaceType.mount.toPath());
    try std.testing.expectEqualStrings("net", ns.NamespaceType.network.toPath());
    try std.testing.expectEqualStrings("pid", ns.NamespaceType.pid.toPath());
    try std.testing.expectEqualStrings("user", ns.NamespaceType.user.toPath());
}

test "unit: layer cache path generation" {
    const allocator = std.testing.allocator;
    var layer_cache = xeno.oci_cache.LayerCache.init(allocator, "/var/cache/test");
    const path = try layer_cache.getLayerPath("sha256:abc123def456");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/var/cache/test/blobs/sha256/abc123def456", path);
}

// --- Config tests ---

test "unit: config defaults" {
    const cfg = config_mod.Config{};
    const t = std.testing;

    try t.expectEqual(@as(usize, 1), cfg.layers.len);
    try t.expectEqualStrings("docker.io/library/alpine:latest", cfg.layers[0].image);
    try t.expectEqualStrings("/bin/sh", cfg.entrypoint);
    try t.expectEqualStrings("/mnt/oldroot", cfg.keep_old_root);
    try t.expectEqual(@as(u32, 30), cfg.timeout);
    try t.expect(!cfg.force);
    try t.expect(!cfg.verbose);
    try t.expect(!cfg.dry_run);
    try t.expect(!cfg.entrypoint_explicit);
    try t.expect(cfg.output == null);
    try t.expect(cfg.rootfs_output == null);
}

test "unit: Layer type" {
    const t = std.testing;
    const image_layer = config_mod.Layer{ .image = "alpine:latest" };
    const rootfs_layer = config_mod.Layer{ .rootfs = "/path/to/rootfs" };

    try t.expectEqualStrings("alpine:latest", image_layer.image);
    try t.expectEqualStrings("/path/to/rootfs", rootfs_layer.rootfs);
}

test "unit: tailscale enabled logic" {
    const t = std.testing;
    const C = config_mod.Config;

    // No authkey = not enabled
    try t.expect(!(C{}).tailscaleEnabled());
    // Authkey = enabled (init script will be created)
    try t.expect((C{ .tailscale_authkey = "tskey-auth-x" }).tailscaleEnabled());
    // No authkey = not enabled (--tailscale just adds the image layer)
    try t.expect(!(C{ .tailscale_authkey = null }).tailscaleEnabled());
}

test "unit: subcommand types" {
    try std.testing.expect((config_mod.Config{}).subcommand == .pivot);
    try std.testing.expect((config_mod.Config{ .subcommand = .build }).subcommand == .build);
}

// --- Pivot config tests ---

test "unit: pivot config defaults" {
    const cfg = xeno.pivot.PivotConfig{
        .new_root = "/newroot",
        .allocator = std.testing.allocator,
    };
    const t = std.testing;

    try t.expectEqualStrings("mnt/oldroot", cfg.old_root_mount);
    try t.expect(cfg.keep_old_root);
    try t.expect(cfg.exec_cmd == null);
    try t.expect(cfg.exec_env == null);
}

// --- OCI layout writer tests ---

test "unit: hashBytes deterministic" {
    const t = std.testing;
    const hash1 = oci_layout_writer.hashBytes("hello world");
    const hash2 = oci_layout_writer.hashBytes("hello world");
    try t.expectEqualStrings(&hash1, &hash2);

    const hash3 = oci_layout_writer.hashBytes("different input");
    try t.expect(!std.mem.eql(u8, &hash1, &hash3));

    // Known sha256 of "hello world"
    try t.expectEqualStrings(
        "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
        &hash1,
    );
}

test "unit: hashBytes known vectors" {
    const t = std.testing;

    // Empty string
    const empty_hash = oci_layout_writer.hashBytes("");
    try t.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &empty_hash,
    );

    // Single char
    const a_hash = oci_layout_writer.hashBytes("a");
    try t.expectEqualStrings(
        "ca978112ca1bbdcafac231b39a23dc4da786eff8147c4e72b9807785afee48bb",
        &a_hash,
    );
}

test "unit: buildJsonStringArray" {
    const t = std.testing;

    {
        const result = try oci_layout_writer.buildJsonStringArray(t.allocator, &.{ "hello", "world" });
        defer t.allocator.free(result);
        try t.expectEqualStrings("[\"hello\",\"world\"]", result);
    }
    {
        const result = try oci_layout_writer.buildJsonStringArray(t.allocator, &.{"/bin/sh"});
        defer t.allocator.free(result);
        try t.expectEqualStrings("[\"/bin/sh\"]", result);
    }
    {
        const result = try oci_layout_writer.buildJsonStringArray(t.allocator, &.{});
        defer t.allocator.free(result);
        try t.expectEqualStrings("[]", result);
    }
}

test "unit: buildConfigJson without image config" {
    const t = std.testing;
    const json = try oci_layout_writer.buildConfigJson(t.allocator, "amd64", "abc123", null);
    defer t.allocator.free(json);

    try t.expect(std.mem.indexOf(u8, json, "\"architecture\":\"amd64\"") != null);
    try t.expect(std.mem.indexOf(u8, json, "\"os\":\"linux\"") != null);
    try t.expect(std.mem.indexOf(u8, json, "sha256:abc123") != null);
    try t.expect(std.mem.indexOf(u8, json, "\"config\":{}") != null);
}

test "unit: buildConfigJson with entrypoint and env" {
    const t = std.testing;
    const ImageConfig = rootfs_builder.BuildResult.ImageConfig;

    const cfg = ImageConfig{
        .entrypoint = &.{"/bin/sh"},
        .cmd = &.{"-c"},
        .env = &.{ "PATH=/usr/bin", "HOME=/root" },
        .working_dir = "/app",
    };

    const json = try oci_layout_writer.buildConfigJson(t.allocator, "arm64", "def456", cfg);
    defer t.allocator.free(json);

    try t.expect(std.mem.indexOf(u8, json, "\"Entrypoint\":[\"/bin/sh\"]") != null);
    try t.expect(std.mem.indexOf(u8, json, "\"Cmd\":[\"-c\"]") != null);
    try t.expect(std.mem.indexOf(u8, json, "\"Env\":[\"PATH=/usr/bin\",\"HOME=/root\"]") != null);
    try t.expect(std.mem.indexOf(u8, json, "\"WorkingDir\":\"/app\"") != null);
    try t.expect(std.mem.indexOf(u8, json, "\"architecture\":\"arm64\"") != null);
}

test "unit: buildConfigJson manifest hash is deterministic" {
    const t = std.testing;
    const ImageConfig = rootfs_builder.BuildResult.ImageConfig;

    const cfg = ImageConfig{
        .entrypoint = &.{"/sbin/init"},
        .cmd = null,
        .env = &.{"PATH=/usr/bin:/bin"},
        .working_dir = null,
    };

    const json1 = try oci_layout_writer.buildConfigJson(t.allocator, "amd64", "aaa", cfg);
    defer t.allocator.free(json1);
    const json2 = try oci_layout_writer.buildConfigJson(t.allocator, "amd64", "aaa", cfg);
    defer t.allocator.free(json2);

    try t.expectEqualStrings(json1, json2);

    const hash1 = oci_layout_writer.hashBytes(json1);
    const hash2 = oci_layout_writer.hashBytes(json2);
    try t.expectEqualStrings(&hash1, &hash2);
}

// --- Misc ---

test "unit: overlay config" {
    const overlay = xeno.rootfs_overlay;
    const cfg = overlay.OverlayConfig{
        .lower_dirs = &.{ "/layer1", "/layer2", "/layer3" },
        .upper_dir = "/upper",
        .work_dir = "/work",
        .mount_point = "/merged",
    };
    try std.testing.expectEqual(@as(usize, 3), cfg.lower_dirs.len);
}

test "unit: sysvinit runlevels" {
    const sysvinit = xeno.init_sysvinit;
    try std.testing.expectEqual(@as(u8, '0'), sysvinit.Runlevel.halt);
    try std.testing.expectEqual(@as(u8, '6'), sysvinit.Runlevel.reboot);
}

test "unit: build options defaults" {
    const opts = rootfs_builder.BuildOptions{
        .target_dir = "/tmp/rootfs",
    };
    try std.testing.expect(opts.use_cache);
    try std.testing.expect(opts.verify_digests);
    try std.testing.expect(!opts.skip_verify);
}

// --- SSH/firewall config tests ---

test "unit: ssh config defaults" {
    const t = std.testing;
    const C = config_mod.Config;

    // SSH disabled by default
    try t.expect((C{}).ssh_port == null);
    try t.expect((C{}).ssh_password == null);
    try t.expect((C{}).ssh_keyfile == null);

    // Setting password implies port 22
    const cfg = C{ .ssh_password = "test123" };
    try t.expectEqualStrings("test123", cfg.ssh_password.?);
}

test "unit: firewall default is flush" {
    const t = std.testing;
    try t.expect(!(config_mod.Config{}).keep_firewall);
}

test "unit: hasInitServices" {
    const t = std.testing;
    const C = config_mod.Config;

    // No services by default (but firewall flush is on)
    try t.expect((C{}).hasInitServices());

    // With keep_firewall and nothing else
    try t.expect(!(C{ .keep_firewall = true }).hasInitServices());

    // SSH enables services
    try t.expect((C{ .ssh_port = 22 }).hasInitServices());

    // Tailscale enables services
    try t.expect((C{ .tailscale_authkey = "tskey" }).hasInitServices());
}

// --- Initscript config tests ---

test "unit: initscript config hasServices" {
    const t = std.testing;
    const ISC = xeno.initscript.InitScriptConfig;

    try t.expect(!(ISC{}).hasServices());
    try t.expect((ISC{ .ssh = .{} }).hasServices());
    try t.expect((ISC{ .tailscale = .{ .authkey = "x", .args = "" } }).hasServices());
}

test "unit: embedded init binary is present" {
    const t = std.testing;
    // The init_bin module should have non-empty data
    const init_bin = @import("init_bin");
    try t.expect(init_bin.data.len > 0);
    // Should start with ELF magic
    try t.expectEqualStrings("\x7fELF", init_bin.data[0..4]);
}

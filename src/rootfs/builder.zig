const std = @import("std");
const log = @import("../util/log.zig");
const oci_image = @import("../oci/image.zig");
const oci_layer = @import("../oci/layer.zig");
const oci_registry = @import("../oci/registry.zig");
const oci_cache = @import("../oci/cache.zig");

const scoped_log = log.scoped("rootfs/builder");

pub const BuildError = error{
    InvalidImage,
    LayerExtractionFailed,
    ManifestParseError,
    ConfigParseError,
    DownloadFailed,
    IoError,
    OutOfMemory,
    VerificationFailed,
};

/// Options for building a rootfs
pub const BuildOptions = struct {
    /// Target directory for the rootfs
    target_dir: []const u8,

    /// Use cache for layers
    use_cache: bool = true,

    /// Verify layer digests
    verify_digests: bool = true,

    /// Skip rootfs verification
    skip_verify: bool = false,
};

/// Build result
pub const BuildResult = struct {
    /// Path to the built rootfs
    rootfs_path: []const u8,

    /// Number of layers extracted
    layer_count: usize,

    /// Total size in bytes
    total_size: u64,

    /// Image configuration
    config: ?ImageConfig,

    pub const ImageConfig = struct {
        entrypoint: ?[]const []const u8,
        cmd: ?[]const []const u8,
        env: ?[]const []const u8,
        working_dir: ?[]const u8,
    };

    pub fn deinit(self: *BuildResult, allocator: std.mem.Allocator) void {
        allocator.free(self.rootfs_path);
        if (self.config) |*cfg| {
            if (cfg.entrypoint) |ep| {
                for (ep) |e| allocator.free(e);
                allocator.free(ep);
            }
            if (cfg.cmd) |cmd| {
                for (cmd) |c| allocator.free(c);
                allocator.free(cmd);
            }
            if (cfg.env) |env| {
                for (env) |e| allocator.free(e);
                allocator.free(env);
            }
            if (cfg.working_dir) |wd| allocator.free(wd);
        }
    }
};

/// Rootfs builder
pub const RootfsBuilder = struct {
    allocator: std.mem.Allocator,
    cache: oci_cache.LayerCache,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .cache = oci_cache.LayerCache.init(allocator),
        };
    }

    pub fn initWithCache(allocator: std.mem.Allocator, cache_dir: []const u8) Self {
        return Self{
            .allocator = allocator,
            .cache = oci_cache.LayerCache.initWithDir(allocator, cache_dir),
        };
    }

    /// Build rootfs from an OCI image reference
    pub fn buildFromImage(
        self: *Self,
        image_ref: []const u8,
        options: BuildOptions,
    ) BuildError!BuildResult {
        scoped_log.info("Building rootfs from {s}", .{image_ref});

        // Check if local image
        if (oci_image.isLocalImage(image_ref)) {
            return self.buildFromLocalImage(image_ref, options);
        }

        // Parse image reference
        var ref = oci_image.ImageReference.parse(image_ref, self.allocator) catch
            return error.InvalidImage;
        defer ref.deinit(self.allocator);

        return self.buildFromRegistry(&ref, options);
    }

    /// Build from local tarball or OCI layout
    pub fn buildFromLocalImage(
        self: *Self,
        path: []const u8,
        options: BuildOptions,
    ) BuildError!BuildResult {
        scoped_log.info("Building rootfs from local image {s}", .{path});

        // Ensure target directory exists
        std.fs.makeDirAbsolute(options.target_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                scoped_log.err("Cannot create target directory: {}", .{err});
                return error.IoError;
            }
        };

        if (std.mem.endsWith(u8, path, ".tar") or
            std.mem.endsWith(u8, path, ".tar.gz") or
            std.mem.endsWith(u8, path, ".tgz"))
        {
            return self.buildFromTarball(path, options);
        } else {
            return self.buildFromOciLayout(path, options);
        }
    }

    /// Build from a tarball
    fn buildFromTarball(
        self: *Self,
        tarball_path: []const u8,
        options: BuildOptions,
    ) BuildError!BuildResult {
        scoped_log.info("Extracting tarball {s}", .{tarball_path});

        const compression: oci_layer.Compression = if (std.mem.endsWith(u8, tarball_path, ".tar.gz") or
            std.mem.endsWith(u8, tarball_path, ".tgz"))
            .gzip
        else
            .none;

        oci_layer.extractLayer(tarball_path, compression, .{
            .target = options.target_dir,
            .handle_whiteouts = true,
        }, self.allocator) catch return error.LayerExtractionFailed;

        // Get size
        const size = getDirSize(options.target_dir, self.allocator) catch 0;

        return BuildResult{
            .rootfs_path = self.allocator.dupe(u8, options.target_dir) catch return error.OutOfMemory,
            .layer_count = 1,
            .total_size = size,
            .config = null,
        };
    }

    /// Build from OCI layout directory
    fn buildFromOciLayout(
        self: *Self,
        layout_path: []const u8,
        options: BuildOptions,
    ) BuildError!BuildResult {
        scoped_log.info("Building from OCI layout {s}", .{layout_path});

        // Read index.json
        const index_path = std.fs.path.join(self.allocator, &.{ layout_path, "index.json" }) catch
            return error.OutOfMemory;
        defer self.allocator.free(index_path);

        const index_file = std.fs.openFileAbsolute(index_path, .{}) catch
            return error.InvalidImage;
        defer index_file.close();

        var index_buf: [16384]u8 = undefined;
        const n = index_file.readAll(&index_buf) catch return error.IoError;

        // Parse index to find manifest
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, index_buf[0..n], .{}) catch
            return error.ManifestParseError;
        defer parsed.deinit();

        const manifests = parsed.value.object.get("manifests") orelse return error.ManifestParseError;
        if (manifests.array.items.len == 0) return error.ManifestParseError;

        const first_manifest = manifests.array.items[0];
        const digest = first_manifest.object.get("digest") orelse return error.ManifestParseError;

        // Read manifest
        const manifest_path = try blobPath(self.allocator, layout_path, digest.string);
        defer self.allocator.free(manifest_path);

        return self.buildFromManifestFile(manifest_path, layout_path, options);
    }

    /// Build from a manifest file
    fn buildFromManifestFile(
        self: *Self,
        manifest_path: []const u8,
        blobs_base: []const u8,
        options: BuildOptions,
    ) BuildError!BuildResult {
        const manifest_file = std.fs.openFileAbsolute(manifest_path, .{}) catch
            return error.InvalidImage;
        defer manifest_file.close();

        var manifest_buf: [65536]u8 = undefined;
        const n = manifest_file.readAll(&manifest_buf) catch return error.IoError;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, manifest_buf[0..n], .{}) catch
            return error.ManifestParseError;
        defer parsed.deinit();

        const root = parsed.value;

        // Get layers
        const layers = root.object.get("layers") orelse return error.ManifestParseError;

        scoped_log.info("Extracting {} layers", .{layers.array.items.len});

        var layer_count: usize = 0;
        for (layers.array.items) |layer_desc| {
            const layer_digest = layer_desc.object.get("digest") orelse continue;
            const media_type = layer_desc.object.get("mediaType") orelse continue;

            const layer_path = try blobPath(self.allocator, blobs_base, layer_digest.string);
            defer self.allocator.free(layer_path);

            const compression = oci_layer.Compression.fromMediaType(media_type.string);

            scoped_log.debug("Extracting layer {s}", .{layer_digest.string});

            oci_layer.extractLayer(layer_path, compression, .{
                .target = options.target_dir,
            }, self.allocator) catch |err| {
                scoped_log.err("Failed to extract layer: {}", .{err});
                return error.LayerExtractionFailed;
            };

            layer_count += 1;
        }

        // Parse config for entrypoint/cmd
        var config: ?BuildResult.ImageConfig = null;
        if (root.object.get("config")) |config_desc| {
            if (config_desc.object.get("digest")) |config_digest| {
                config = self.parseImageConfig(blobs_base, config_digest.string) catch null;
            }
        }

        // Verify rootfs if requested
        if (!options.skip_verify) {
            if (!try verifyRootfs(options.target_dir, self.allocator)) {
                scoped_log.warn("Rootfs verification failed - missing essential files", .{});
            }
        }

        const size = getDirSize(options.target_dir, self.allocator) catch 0;

        return BuildResult{
            .rootfs_path = self.allocator.dupe(u8, options.target_dir) catch return error.OutOfMemory,
            .layer_count = layer_count,
            .total_size = size,
            .config = config,
        };
    }

    /// Build from registry
    fn buildFromRegistry(
        self: *Self,
        ref: *const oci_image.ImageReference,
        options: BuildOptions,
    ) BuildError!BuildResult {
        scoped_log.info("Pulling image from registry", .{});

        // Create temp directory for downloads
        const tmp_dir = "/tmp/xenomorph-pull";
        std.fs.deleteTreeAbsolute(tmp_dir) catch {};
        std.fs.makeDirAbsolute(tmp_dir) catch return error.IoError;
        defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

        // Pull image
        oci_registry.pullImage(self.allocator, ref, tmp_dir) catch return error.DownloadFailed;

        // Build from downloaded OCI layout
        return self.buildFromOciLayout(tmp_dir, options);
    }

    /// Parse image config to get entrypoint/cmd
    fn parseImageConfig(self: *Self, blobs_base: []const u8, digest: []const u8) !BuildResult.ImageConfig {
        const config_path = try blobPath(self.allocator, blobs_base, digest);
        defer self.allocator.free(config_path);

        const file = std.fs.openFileAbsolute(config_path, .{}) catch return error.ConfigParseError;
        defer file.close();

        var buf: [65536]u8 = undefined;
        const n = file.readAll(&buf) catch return error.IoError;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, buf[0..n], .{}) catch
            return error.ConfigParseError;
        defer parsed.deinit();

        const root = parsed.value;
        const config = root.object.get("config") orelse return error.ConfigParseError;

        var result = BuildResult.ImageConfig{
            .entrypoint = null,
            .cmd = null,
            .env = null,
            .working_dir = null,
        };

        if (config.object.get("Entrypoint")) |ep| {
            if (ep != .null) {
                var list: std.ArrayListUnmanaged([]const u8) = .{};
                for (ep.array.items) |item| {
                    try list.append(self.allocator, try self.allocator.dupe(u8, item.string));
                }
                result.entrypoint = try list.toOwnedSlice(self.allocator);
            }
        }

        if (config.object.get("Cmd")) |cmd| {
            if (cmd != .null) {
                var list: std.ArrayListUnmanaged([]const u8) = .{};
                for (cmd.array.items) |item| {
                    try list.append(self.allocator, try self.allocator.dupe(u8, item.string));
                }
                result.cmd = try list.toOwnedSlice(self.allocator);
            }
        }

        if (config.object.get("WorkingDir")) |wd| {
            if (wd != .null) {
                result.working_dir = try self.allocator.dupe(u8, wd.string);
            }
        }

        return result;
    }
};

/// Get path to blob from digest
fn blobPath(allocator: std.mem.Allocator, base: []const u8, digest: []const u8) ![]const u8 {
    const colon_idx = std.mem.indexOf(u8, digest, ":") orelse return error.InvalidImage;
    const algorithm = digest[0..colon_idx];
    const hash = digest[colon_idx + 1 ..];

    return std.fs.path.join(allocator, &.{ base, "blobs", algorithm, hash });
}

/// Verify a rootfs has required files
pub fn verifyRootfs(path: []const u8, allocator: std.mem.Allocator) !bool {
    _ = allocator;

    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    defer dir.close();

    // Check for essential directories
    const required_dirs = [_][]const u8{ "bin", "lib" };
    for (required_dirs) |req| {
        var sub_dir = dir.openDir(req, .{}) catch return false;
        sub_dir.close();
    }

    // Check for shell or init
    const executables = [_][]const u8{ "bin/sh", "bin/bash", "sbin/init" };
    var has_executable = false;
    for (executables) |exe| {
        if (dir.access(exe, .{})) |_| {
            has_executable = true;
            break;
        } else |_| {}
    }

    return has_executable;
}

/// Get directory size recursively
fn getDirSize(path: []const u8, allocator: std.mem.Allocator) !u64 {
    _ = allocator;

    var total: u64 = 0;

    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind == .file) {
            const stat = dir.statFile(entry.name) catch continue;
            total += stat.size;
        }
    }

    return total;
}

/// Build rootfs from image reference (convenience function)
pub fn build(
    allocator: std.mem.Allocator,
    image_ref: []const u8,
    target_dir: []const u8,
) !BuildResult {
    var builder = RootfsBuilder.init(allocator);
    return builder.buildFromImage(image_ref, .{ .target_dir = target_dir });
}

test "BuildOptions defaults" {
    const opts = BuildOptions{
        .target_dir = "/tmp/rootfs",
    };

    const testing = std.testing;
    try testing.expect(opts.use_cache);
    try testing.expect(opts.verify_digests);
    try testing.expect(!opts.skip_verify);
}

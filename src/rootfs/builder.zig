const std = @import("std");
const log = @import("../util/log.zig");
const memory = @import("../util/memory.zig");
const oci_image = @import("oci").image;
const oci_layer = @import("oci").layer;
const oci_registry = @import("oci").registry;
const oci_cache = @import("oci").cache;
const config_mod = @import("../config.zig");

pub const Layer = config_mod.Layer;

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
    InsufficientMemory,
    TmpfsMountFailed,
};

/// Options for building a rootfs
pub const BuildOptions = struct {
    /// Target directory for the rootfs (used as mount point for tmpfs)
    target_dir: []const u8,

    /// Use cache for layers
    use_cache: bool = true,

    /// Verify layer digests
    verify_digests: bool = true,

    /// Skip rootfs verification
    skip_verify: bool = false,

    /// Extra headroom multiplier for tmpfs size (e.g., 1.5 = 50% extra)
    tmpfs_headroom: f64 = 1.5,
};

/// Build result
pub const BuildResult = struct {
    /// Path to the built rootfs (in-memory tmpfs)
    rootfs_path: []const u8,

    /// Number of layers extracted
    layer_count: usize,

    /// Total size in bytes
    total_size: u64,

    /// Image configuration
    config: ?ImageConfig,

    /// Tmpfs mount - caller must keep this alive until after pivot
    tmpfs_mount: memory.TmpfsMount,

    pub const ImageConfig = @import("oci").layout_writer.ImageConfig;

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
        // Note: tmpfs_mount is intentionally NOT unmounted here
        // The caller is responsible for keeping it alive during pivot
    }

    /// Explicitly unmount tmpfs (call after pivot is complete or on error)
    pub fn unmountTmpfs(self: *BuildResult) void {
        self.tmpfs_mount.deinit();
    }
};

/// Rootfs builder
pub const RootfsBuilder = struct {
    allocator: std.mem.Allocator,
    cache: oci_cache.LayerCache,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, cache_dir: []const u8) Self {
        return Self{
            .allocator = allocator,
            .cache = oci_cache.LayerCache.init(allocator, cache_dir),
        };
    }

    /// Build rootfs from an OCI image reference
    pub fn buildFromImage(
        self: *Self,
        image_ref: []const u8,
        options: BuildOptions,
    ) BuildError!BuildResult {
        scoped_log.info("Building rootfs from {s}", .{image_ref});

        // Estimate required size
        const estimated_size: u64 = memory.estimateImageSize(image_ref) catch |err| blk: {
            scoped_log.warn("Cannot estimate image size: {}, using default 1GB", .{err});
            break :blk 1024 * 1024 * 1024;
        };

        const size_float = @as(f64, @floatFromInt(estimated_size)) * options.tmpfs_headroom;
        scoped_log.debug("Tmpfs size calculation: estimated={d}, headroom={d}, result={d}", .{
            estimated_size, options.tmpfs_headroom, size_float,
        });
        const tmpfs_size: u64 = if (size_float < 0 or size_float > @as(f64, @floatFromInt(std.math.maxInt(u64))))
            1024 * 1024 * 1024 // 1GB fallback
        else
            @intFromFloat(size_float);

        scoped_log.info("Estimated rootfs size: {d}MB, allocating {d}MB tmpfs", .{
            estimated_size / (1024 * 1024),
            tmpfs_size / (1024 * 1024),
        });

        // Check available memory
        _ = memory.checkAvailableMemory(tmpfs_size) catch |err| {
            if (err == error.InsufficientMemory) {
                const mem_info = memory.getMemInfo() catch {
                    scoped_log.err("Cannot read memory info", .{});
                    return error.InsufficientMemory;
                };
                scoped_log.err("Not enough RAM for in-memory rootfs", .{});
                scoped_log.err("Required: {d}MB, Available: {d}MB, Total: {d}MB", .{
                    tmpfs_size / (1024 * 1024),
                    mem_info.available / (1024 * 1024),
                    mem_info.total / (1024 * 1024),
                });
                return error.InsufficientMemory;
            }
            return error.InsufficientMemory;
        };

        scoped_log.info("Memory check passed", .{});

        // Create tmpfs mount
        var tmpfs_mount = memory.TmpfsMount.init(self.allocator, options.target_dir, tmpfs_size) catch |err| {
            scoped_log.err("Failed to create tmpfs: {}", .{err});
            return error.TmpfsMountFailed;
        };
        scoped_log.info("Tmpfs mounted at {s}", .{options.target_dir});
        errdefer tmpfs_mount.deinit();

        // Check if local image
        if (oci_image.isLocalImage(image_ref)) {
            return self.buildFromLocalImage(image_ref, options, &tmpfs_mount);
        }

        // Parse image reference
        var ref = oci_image.ImageReference.parse(image_ref, self.allocator) catch
            return error.InvalidImage;
        defer ref.deinit(self.allocator);

        return self.buildFromRegistry(&ref, options, &tmpfs_mount);
    }

    /// Build rootfs from a Layer (dispatches to local or registry based on tag)
    pub fn buildFromLayer(
        self: *Self,
        layer: Layer,
        options: BuildOptions,
    ) BuildError!BuildResult {
        return switch (layer) {
            .image => |ref| self.buildFromImage(ref, options),
            .rootfs => |path| self.buildFromImage(path, options),
        };
    }

    /// Merge a Layer into an existing rootfs (dispatches on tag).
    /// Returns the ImageConfig from the merged layer if it was an OCI image, null otherwise.
    pub fn mergeLayer(
        self: *Self,
        layer: Layer,
        target_dir: []const u8,
    ) BuildError!?BuildResult.ImageConfig {
        return switch (layer) {
            .image => |ref| self.mergeImage(ref, target_dir),
            .rootfs => |path| self.mergeLocalImage(path, target_dir),
        };
    }

    /// Build from local tarball, OCI layout, or plain directory
    fn buildFromLocalImage(
        self: *Self,
        path: []const u8,
        options: BuildOptions,
        tmpfs_mount: *memory.TmpfsMount,
    ) BuildError!BuildResult {
        scoped_log.info("Building rootfs from local image {s}", .{path});

        if (std.mem.endsWith(u8, path, ".tar") or
            std.mem.endsWith(u8, path, ".tar.gz") or
            std.mem.endsWith(u8, path, ".tgz"))
        {
            return self.buildFromTarball(path, options, tmpfs_mount);
        }

        // Check if it's an OCI layout (has index.json)
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const index_path = std.fmt.bufPrint(&buf, "{s}/index.json", .{path}) catch
            return error.InvalidImage;

        if (std.fs.accessAbsolute(index_path, .{})) |_| {
            return self.buildFromOciLayout(path, options, tmpfs_mount);
        } else |_| {
            // Plain directory - copy contents to tmpfs
            return self.buildFromDirectory(path, options, tmpfs_mount);
        }
    }

    /// Build from a plain directory by copying its contents to tmpfs
    fn buildFromDirectory(
        self: *Self,
        src_path: []const u8,
        options: BuildOptions,
        tmpfs_mount: *memory.TmpfsMount,
    ) BuildError!BuildResult {
        scoped_log.info("Copying directory {s} to tmpfs", .{src_path});

        copyDirRecursive(src_path, options.target_dir, self.allocator) catch |err| {
            scoped_log.err("Failed to copy directory: {}", .{err});
            return error.IoError;
        };

        // Verify copy worked by listing target
        scoped_log.debug("Verifying copy to {s}", .{options.target_dir});

        // Get size
        const size = getDirSize(options.target_dir, self.allocator) catch 0;

        // Verify rootfs if requested
        if (!options.skip_verify) {
            if (!try verifyRootfs(options.target_dir, self.allocator)) {
                scoped_log.warn("Rootfs verification failed - missing essential files", .{});
            }
        }

        return BuildResult{
            .rootfs_path = self.allocator.dupe(u8, options.target_dir) catch return error.OutOfMemory,
            .layer_count = 1,
            .total_size = size,
            .config = null,
            .tmpfs_mount = tmpfs_mount.*,
        };
    }

    /// Build from a tarball
    fn buildFromTarball(
        self: *Self,
        tarball_path: []const u8,
        options: BuildOptions,
        tmpfs_mount: *memory.TmpfsMount,
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
            .tmpfs_mount = tmpfs_mount.*,
        };
    }

    /// Build from OCI layout directory
    fn buildFromOciLayout(
        self: *Self,
        layout_path: []const u8,
        options: BuildOptions,
        tmpfs_mount: *memory.TmpfsMount,
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

        return self.buildFromManifestFile(manifest_path, layout_path, options, tmpfs_mount);
    }

    /// Build from a manifest file
    fn buildFromManifestFile(
        self: *Self,
        manifest_path: []const u8,
        blobs_base: []const u8,
        options: BuildOptions,
        tmpfs_mount: *memory.TmpfsMount,
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
            .tmpfs_mount = tmpfs_mount.*,
        };
    }

    /// Build from registry
    fn buildFromRegistry(
        self: *Self,
        ref: *const oci_image.ImageReference,
        options: BuildOptions,
        tmpfs_mount: *memory.TmpfsMount,
    ) BuildError!BuildResult {
        scoped_log.info("Pulling image from registry", .{});

        // Create temp directory for downloads as a sibling of target_dir
        const parent = std.fs.path.dirname(options.target_dir) orelse "/run";
        const tmp_dir = std.fs.path.join(self.allocator, &.{ parent, "pull" }) catch return error.OutOfMemory;
        defer self.allocator.free(tmp_dir);
        defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};
        std.fs.deleteTreeAbsolute(tmp_dir) catch {};
        {
            var root = std.fs.openDirAbsolute("/", .{}) catch return error.IoError;
            defer root.close();
            root.makePath(tmp_dir[1..]) catch return error.IoError;
        }

        // Pull image
        oci_registry.pullImage(self.allocator, ref, tmp_dir) catch return error.DownloadFailed;

        // Build from downloaded OCI layout
        return self.buildFromOciLayout(tmp_dir, options, tmpfs_mount);
    }

    /// Merge an additional OCI image into an existing rootfs directory.
    /// Extracts all layers on top of the existing files (later wins on conflict).
    /// Returns the ImageConfig from the merged image if available.
    pub fn mergeImage(
        self: *Self,
        image_ref: []const u8,
        target_dir: []const u8,
    ) BuildError!?BuildResult.ImageConfig {
        scoped_log.info("Merging image {s} into rootfs", .{image_ref});

        if (oci_image.isLocalImage(image_ref)) {
            return try self.mergeLocalImage(image_ref, target_dir);
        } else {
            return try self.mergeRegistryImage(image_ref, target_dir);
        }
    }

    fn mergeLocalImage(self: *Self, path: []const u8, target_dir: []const u8) BuildError!?BuildResult.ImageConfig {
        if (std.mem.endsWith(u8, path, ".tar") or
            std.mem.endsWith(u8, path, ".tar.gz") or
            std.mem.endsWith(u8, path, ".tgz"))
        {
            const compression: oci_layer.Compression = if (std.mem.endsWith(u8, path, ".tar.gz") or
                std.mem.endsWith(u8, path, ".tgz"))
                .gzip
            else
                .none;

            oci_layer.extractLayer(path, compression, .{
                .target = target_dir,
                .handle_whiteouts = true,
            }, self.allocator) catch return error.LayerExtractionFailed;
            return null;
        }

        // Check for OCI layout
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const index_path = std.fmt.bufPrint(&buf, "{s}/index.json", .{path}) catch
            return error.InvalidImage;

        if (std.fs.accessAbsolute(index_path, .{})) |_| {
            return try self.mergeOciLayout(path, target_dir);
        } else |_| {
            // Plain directory
            copyDirRecursive(path, target_dir, self.allocator) catch return error.IoError;
            return null;
        }
    }

    fn mergeRegistryImage(self: *Self, image_ref: []const u8, target_dir: []const u8) BuildError!?BuildResult.ImageConfig {
        var ref = oci_image.ImageReference.parse(image_ref, self.allocator) catch
            return error.InvalidImage;
        defer ref.deinit(self.allocator);

        const parent = std.fs.path.dirname(target_dir) orelse "/run";
        const tmp_dir = std.fs.path.join(self.allocator, &.{ parent, "merge" }) catch return error.OutOfMemory;
        defer self.allocator.free(tmp_dir);
        defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};
        std.fs.deleteTreeAbsolute(tmp_dir) catch {};
        {
            var root = std.fs.openDirAbsolute("/", .{}) catch return error.IoError;
            defer root.close();
            root.makePath(tmp_dir[1..]) catch return error.IoError;
        }

        oci_registry.pullImage(self.allocator, &ref, tmp_dir) catch return error.DownloadFailed;
        return try self.mergeOciLayout(tmp_dir, target_dir);
    }

    /// Extract layers from an OCI layout into an existing directory.
    /// Returns the ImageConfig from the manifest if available.
    fn mergeOciLayout(self: *Self, layout_path: []const u8, target_dir: []const u8) BuildError!?BuildResult.ImageConfig {
        // Read index.json
        const index_path = std.fs.path.join(self.allocator, &.{ layout_path, "index.json" }) catch
            return error.OutOfMemory;
        defer self.allocator.free(index_path);

        const index_file = std.fs.openFileAbsolute(index_path, .{}) catch
            return error.InvalidImage;
        defer index_file.close();

        var index_buf: [16384]u8 = undefined;
        const n = index_file.readAll(&index_buf) catch return error.IoError;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, index_buf[0..n], .{}) catch
            return error.ManifestParseError;
        defer parsed.deinit();

        const manifests = parsed.value.object.get("manifests") orelse return error.ManifestParseError;
        if (manifests.array.items.len == 0) return error.ManifestParseError;

        const digest = manifests.array.items[0].object.get("digest") orelse
            return error.ManifestParseError;

        // Read manifest
        const manifest_path = try blobPath(self.allocator, layout_path, digest.string);
        defer self.allocator.free(manifest_path);

        const manifest_file = std.fs.openFileAbsolute(manifest_path, .{}) catch
            return error.InvalidImage;
        defer manifest_file.close();

        var manifest_buf: [65536]u8 = undefined;
        const mn = manifest_file.readAll(&manifest_buf) catch return error.IoError;

        const manifest_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, manifest_buf[0..mn], .{}) catch
            return error.ManifestParseError;
        defer manifest_parsed.deinit();

        const layers = manifest_parsed.value.object.get("layers") orelse
            return error.ManifestParseError;

        scoped_log.info("Merging {} layers", .{layers.array.items.len});

        for (layers.array.items) |layer_desc| {
            const layer_digest = layer_desc.object.get("digest") orelse continue;
            const media_type = layer_desc.object.get("mediaType") orelse continue;

            const layer_path = try blobPath(self.allocator, layout_path, layer_digest.string);
            defer self.allocator.free(layer_path);

            const compression = oci_layer.Compression.fromMediaType(media_type.string);

            scoped_log.debug("Merging layer {s}", .{layer_digest.string});

            oci_layer.extractLayer(layer_path, compression, .{
                .target = target_dir,
                .handle_whiteouts = true,
            }, self.allocator) catch |err| {
                scoped_log.err("Failed to extract layer: {}", .{err});
                return error.LayerExtractionFailed;
            };
        }

        // Parse config for image config
        var img_config: ?BuildResult.ImageConfig = null;
        if (manifest_parsed.value.object.get("config")) |config_desc| {
            if (config_desc.object.get("digest")) |config_digest| {
                img_config = self.parseImageConfig(layout_path, config_digest.string) catch null;
            }
        }

        return img_config;
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

        if (config.object.get("Env")) |env_val| {
            if (env_val != .null) {
                var list: std.ArrayListUnmanaged([]const u8) = .{};
                for (env_val.array.items) |item| {
                    try list.append(self.allocator, try self.allocator.dupe(u8, item.string));
                }
                result.env = try list.toOwnedSlice(self.allocator);
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

/// Recursively copy directory contents from src to dst (like cp -a).
pub fn copyDirRecursive(src_path: []const u8, dst_path: []const u8, allocator: std.mem.Allocator) !void {
    var src_dir = try std.fs.openDirAbsolute(src_path, .{ .iterate = true });
    defer src_dir.close();

    var dst_dir = std.fs.openDirAbsolute(dst_path, .{}) catch {
        std.fs.makeDirAbsolute(dst_path) catch {};
        return copyDirRecursive(src_path, dst_path, allocator);
    };
    defer dst_dir.close();

    var iter = src_dir.iterate();
    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .directory => {
                const child_src = try std.fs.path.join(allocator, &.{ src_path, entry.name });
                defer allocator.free(child_src);
                const child_dst = try std.fs.path.join(allocator, &.{ dst_path, entry.name });
                defer allocator.free(child_dst);
                dst_dir.makeDir(entry.name) catch {};
                try copyDirRecursive(child_src, child_dst, allocator);
            },
            .file => {
                const src_file = try src_dir.openFile(entry.name, .{});
                defer src_file.close();
                var dst_file = try dst_dir.createFile(entry.name, .{});
                defer dst_file.close();
                const stat = try src_file.stat();
                var buf: [32768]u8 = undefined;
                var total: u64 = 0;
                while (total < stat.size) {
                    const n = try src_file.readAll(&buf);
                    if (n == 0) break;
                    try dst_file.writeAll(buf[0..n]);
                    total += n;
                }
            },
            .sym_link => {
                var link_buf: [std.fs.max_path_bytes]u8 = undefined;
                const target = try src_dir.readLink(entry.name, &link_buf);
                dst_dir.symLink(target, entry.name, .{}) catch {};
            },
            else => {},
        }
    }
}

/// Get directory size recursively
pub fn getDirSize(path: []const u8, allocator: std.mem.Allocator) !u64 {
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
    return builder.buildFromImage(image_ref, .{
        .target_dir = target_dir,
    });
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

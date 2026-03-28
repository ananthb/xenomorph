const std = @import("std");
const log = @import("util/log.zig");
const config = @import("config.zig");
const oci_lib = @import("oci");
const rootfs_builder = @import("rootfs/builder.zig");
const oci_layout_writer = oci_lib.layout_writer;

const scoped_log = log.scoped("cache");

/// Compute a cache key from the effective layer list.
/// The key is a sha256 of the normalized layer descriptions.
pub fn computeBuildCacheKey(allocator: std.mem.Allocator, layers: []const config.Layer) ![64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    for (layers) |layer| {
        switch (layer) {
            .image => |ref| {
                hasher.update("image:");
                const normalized = config.normalizeImageRef(allocator, ref) catch ref;
                defer if (normalized.ptr != ref.ptr) allocator.free(normalized);
                hasher.update(normalized);
            },
            .rootfs => |path| {
                hasher.update("rootfs:");
                hasher.update(path);
            },
        }
        hasher.update("\n");
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// Check if a build with the given cache key exists.
/// Returns the path to the cached OCI layout directory, or null.
pub fn checkBuildCache(allocator: std.mem.Allocator, cache_dir: []const u8, key: []const u8) ?[]const u8 {
    const cache_path = std.fmt.allocPrint(allocator, "{s}/builds/{s}", .{ cache_dir, key }) catch return null;

    // Check if index.json exists in the cached build
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const index_path = std.fmt.bufPrint(&buf, "{s}/index.json", .{cache_path}) catch {
        allocator.free(cache_path);
        return null;
    };

    std.fs.accessAbsolute(index_path, .{}) catch {
        allocator.free(cache_path);
        return null;
    };

    return cache_path;
}

/// Save a built rootfs as a cached OCI layout.
pub fn saveBuildCache(allocator: std.mem.Allocator, cache_dir: []const u8, key: []const u8, rootfs_dir: []const u8, image_config: ?rootfs_builder.BuildResult.ImageConfig) void {
    const cache_path = std.fmt.allocPrint(allocator, "{s}/builds/{s}", .{ cache_dir, key }) catch return;
    defer allocator.free(cache_path);

    // Ensure cache directory structure exists
    {
        std.fs.makeDirAbsolute(cache_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                // Try creating parent dirs
                if (std.fs.path.dirname(cache_dir)) |parent| {
                    var root = std.fs.openDirAbsolute("/", .{}) catch return;
                    defer root.close();
                    if (parent.len > 1) root.makePath(parent[1..]) catch return;
                }
                std.fs.makeDirAbsolute(cache_dir) catch return;
            }
        };
        var dir = std.fs.openDirAbsolute(cache_dir, .{}) catch return;
        defer dir.close();
        dir.makePath("builds") catch return;
    }

    // Write OCI layout to cache
    _ = oci_layout_writer.writeOciLayout(allocator, rootfs_dir, cache_path, image_config) catch |err| {
        scoped_log.warn("Failed to save build cache: {}", .{err});
    };
}

const std = @import("std");
const log = @import("../util/log.zig");
const image = @import("image.zig");
const layer = @import("layer.zig");

const scoped_log = log.scoped("oci/cache");

pub const CacheError = error{
    CacheNotFound,
    CacheCorrupted,
    CacheWriteFailed,
    OutOfMemory,
    IoError,
};

/// Default cache directory
pub const default_cache_dir = "/var/cache/xenomorph";

/// Cache entry metadata
pub const CacheEntry = struct {
    digest: []const u8,
    size: u64,
    last_used: i64,
    path: []const u8,

    pub fn deinit(self: *CacheEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.digest);
        allocator.free(self.path);
    }
};

/// Layer cache manager
pub const LayerCache = struct {
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    max_size_bytes: u64,

    const Self = @This();

    /// Initialize cache with default settings
    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .cache_dir = default_cache_dir,
            .max_size_bytes = 10 * 1024 * 1024 * 1024, // 10GB default
        };
    }

    /// Initialize cache with custom directory
    pub fn initWithDir(allocator: std.mem.Allocator, cache_dir: []const u8) Self {
        return Self{
            .allocator = allocator,
            .cache_dir = cache_dir,
            .max_size_bytes = 10 * 1024 * 1024 * 1024,
        };
    }

    /// Ensure cache directory exists
    pub fn ensureCacheDir(self: *Self) !void {
        std.fs.makeDirAbsolute(self.cache_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                scoped_log.err("Cannot create cache directory {s}: {}", .{ self.cache_dir, err });
                return error.CacheWriteFailed;
            }
        };

        // Create subdirectories
        const subdirs = [_][]const u8{ "blobs", "layers", "manifests" };
        for (subdirs) |subdir| {
            const path = try std.fs.path.join(self.allocator, &.{ self.cache_dir, subdir });
            defer self.allocator.free(path);

            std.fs.makeDirAbsolute(path) catch |err| {
                if (err != error.PathAlreadyExists) return error.CacheWriteFailed;
            };
        }
    }

    /// Check if a layer is cached
    pub fn hasLayer(self: *Self, digest: []const u8) bool {
        const path = self.getLayerPath(digest) catch return false;
        defer self.allocator.free(path);

        std.fs.accessAbsolute(path, .{}) catch return false;
        return true;
    }

    /// Get path to cached layer
    pub fn getLayerPath(self: *Self, digest: []const u8) ![]const u8 {
        // Parse digest to get algorithm and hash
        const colon_idx = std.mem.indexOf(u8, digest, ":") orelse return error.CacheCorrupted;
        const algorithm = digest[0..colon_idx];
        const hash = digest[colon_idx + 1 ..];

        return std.fs.path.join(self.allocator, &.{
            self.cache_dir,
            "blobs",
            algorithm,
            hash,
        });
    }

    /// Store a layer in cache
    pub fn putLayer(self: *Self, digest: []const u8, data: []const u8) !void {
        scoped_log.debug("Caching layer {s}", .{digest});

        try self.ensureCacheDir();

        // Parse digest
        const colon_idx = std.mem.indexOf(u8, digest, ":") orelse return error.CacheCorrupted;
        const algorithm = digest[0..colon_idx];

        // Create algorithm subdirectory
        const algo_dir = try std.fs.path.join(self.allocator, &.{ self.cache_dir, "blobs", algorithm });
        defer self.allocator.free(algo_dir);

        std.fs.makeDirAbsolute(algo_dir) catch |err| {
            if (err != error.PathAlreadyExists) return error.CacheWriteFailed;
        };

        // Write layer
        const path = try self.getLayerPath(digest);
        defer self.allocator.free(path);

        const file = std.fs.createFileAbsolute(path, .{}) catch return error.CacheWriteFailed;
        defer file.close();

        file.writeAll(data) catch return error.CacheWriteFailed;

        scoped_log.debug("Layer cached at {s}", .{path});
    }

    /// Store a layer from file
    pub fn putLayerFromFile(self: *Self, digest: []const u8, source_path: []const u8) !void {
        scoped_log.debug("Caching layer {s} from {s}", .{ digest, source_path });

        try self.ensureCacheDir();

        const colon_idx = std.mem.indexOf(u8, digest, ":") orelse return error.CacheCorrupted;
        const algorithm = digest[0..colon_idx];

        const algo_dir = try std.fs.path.join(self.allocator, &.{ self.cache_dir, "blobs", algorithm });
        defer self.allocator.free(algo_dir);

        std.fs.makeDirAbsolute(algo_dir) catch |err| {
            if (err != error.PathAlreadyExists) return error.CacheWriteFailed;
        };

        const dest_path = try self.getLayerPath(digest);
        defer self.allocator.free(dest_path);

        std.fs.copyFileAbsolute(source_path, dest_path, .{}) catch return error.CacheWriteFailed;
    }

    /// Get a layer from cache
    pub fn getLayer(self: *Self, digest: []const u8) ![]const u8 {
        const path = try self.getLayerPath(digest);
        defer self.allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch return error.CacheNotFound;
        defer file.close();

        const stat = file.stat() catch return error.CacheCorrupted;
        const data = self.allocator.alloc(u8, stat.size) catch return error.OutOfMemory;
        errdefer self.allocator.free(data);

        const n = file.readAll(data) catch return error.IoError;
        if (n != stat.size) return error.CacheCorrupted;

        // Update access time
        self.touchLayer(digest) catch {};

        return data;
    }

    /// Update access time for LRU
    fn touchLayer(self: *Self, digest: []const u8) !void {
        _ = self;
        _ = digest;
        // TODO: implement access time tracking
    }

    /// Get total cache size
    pub fn getCacheSize(self: *Self) !u64 {
        var total_size: u64 = 0;

        const blobs_dir = try std.fs.path.join(self.allocator, &.{ self.cache_dir, "blobs" });
        defer self.allocator.free(blobs_dir);

        var dir = std.fs.openDirAbsolute(blobs_dir, .{ .iterate = true }) catch return 0;
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |algo_entry| {
            if (algo_entry.kind != .directory) continue;

            var algo_dir = dir.openDir(algo_entry.name, .{ .iterate = true }) catch continue;
            defer algo_dir.close();

            var hash_iter = algo_dir.iterate();
            while (hash_iter.next() catch null) |hash_entry| {
                if (hash_entry.kind != .file) continue;

                const stat = algo_dir.statFile(hash_entry.name) catch continue;
                total_size += stat.size;
            }
        }

        return total_size;
    }

    /// Prune cache to stay under max size
    pub fn prune(self: *Self) !void {
        const current_size = try self.getCacheSize();
        if (current_size <= self.max_size_bytes) return;

        scoped_log.info("Cache size {} exceeds limit {}, pruning", .{ current_size, self.max_size_bytes });

        // TODO: implement LRU eviction
        // For now, just log
        scoped_log.warn("Cache pruning not yet implemented", .{});
    }

    /// Clear all cached data
    pub fn clear(self: *Self) !void {
        scoped_log.info("Clearing cache at {s}", .{self.cache_dir});

        std.fs.deleteTreeAbsolute(self.cache_dir) catch |err| {
            if (err != error.FileNotFound) {
                scoped_log.err("Failed to clear cache: {}", .{err});
                return error.IoError;
            }
        };
    }
};

/// Check if an image is cached
pub fn isImageCached(allocator: std.mem.Allocator, ref: *const image.ImageReference) bool {
    const cache = LayerCache.init(allocator);

    // Check if manifest is cached
    const manifest_path = std.fmt.allocPrint(
        allocator,
        "{s}/manifests/{s}/{s}/{s}",
        .{ cache.cache_dir, ref.registry, ref.repository, ref.tag },
    ) catch return false;
    defer allocator.free(manifest_path);

    std.fs.accessAbsolute(manifest_path, .{}) catch return false;
    return true;
}

test "LayerCache initialization" {
    const testing = std.testing;
    const cache = LayerCache.init(testing.allocator);

    try testing.expectEqualStrings(default_cache_dir, cache.cache_dir);
    try testing.expectEqual(@as(u64, 10 * 1024 * 1024 * 1024), cache.max_size_bytes);
}

test "layer path generation" {
    const testing = std.testing;
    var cache = LayerCache.initWithDir(testing.allocator, "/tmp/cache");

    const path = try cache.getLayerPath("sha256:abc123");
    defer testing.allocator.free(path);

    try testing.expectEqualStrings("/tmp/cache/blobs/sha256/abc123", path);
}

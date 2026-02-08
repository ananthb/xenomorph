const std = @import("std");
const log = @import("../util/log.zig");
const mount_util = @import("../util/mount.zig");
const syscall = @import("../util/syscall.zig");

const scoped_log = log.scoped("rootfs/overlay");

pub const OverlayError = error{
    InvalidLayer,
    MountFailed,
    DirectoryCreationFailed,
    OutOfMemory,
    UnsupportedFilesystem,
};

/// Overlay filesystem configuration
pub const OverlayConfig = struct {
    /// Lower directories (read-only layers, bottom to top)
    lower_dirs: []const []const u8,

    /// Upper directory (writable layer)
    upper_dir: []const u8,

    /// Work directory (required by overlayfs)
    work_dir: []const u8,

    /// Mount point
    mount_point: []const u8,
};

/// Create an overlay filesystem from multiple layers
pub fn createOverlay(config: OverlayConfig, allocator: std.mem.Allocator) OverlayError!void {
    scoped_log.info("Creating overlay at {s}", .{config.mount_point});

    // Ensure directories exist
    for (config.lower_dirs) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                scoped_log.err("Cannot access lower dir {s}: {}", .{ dir, err });
                return error.InvalidLayer;
            }
        };
    }

    std.fs.makeDirAbsolute(config.upper_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            scoped_log.err("Cannot create upper dir: {}", .{err});
            return error.DirectoryCreationFailed;
        }
    };

    std.fs.makeDirAbsolute(config.work_dir) catch |err| {
        if (err != error.PathAlreadyExists) {
            scoped_log.err("Cannot create work dir: {}", .{err});
            return error.DirectoryCreationFailed;
        }
    };

    std.fs.makeDirAbsolute(config.mount_point) catch |err| {
        if (err != error.PathAlreadyExists) {
            scoped_log.err("Cannot create mount point: {}", .{err});
            return error.DirectoryCreationFailed;
        }
    };

    // Build mount options string
    // Format: lowerdir=dir1:dir2:dir3,upperdir=upper,workdir=work
    var opts_buf: [4096]u8 = undefined;
    var opts_len: usize = 0;

    // Add lowerdir
    const lower_prefix = "lowerdir=";
    @memcpy(opts_buf[opts_len..][0..lower_prefix.len], lower_prefix);
    opts_len += lower_prefix.len;

    for (config.lower_dirs, 0..) |dir, i| {
        if (i > 0) {
            opts_buf[opts_len] = ':';
            opts_len += 1;
        }
        @memcpy(opts_buf[opts_len..][0..dir.len], dir);
        opts_len += dir.len;
    }

    // Add upperdir
    const upper_str = try std.fmt.bufPrint(opts_buf[opts_len..], ",upperdir={s}", .{config.upper_dir});
    opts_len += upper_str.len;

    // Add workdir
    const work_str = try std.fmt.bufPrint(opts_buf[opts_len..], ",workdir={s}", .{config.work_dir});
    opts_len += work_str.len;

    opts_buf[opts_len] = 0;

    scoped_log.debug("Overlay options: {s}", .{opts_buf[0..opts_len]});

    // Mount overlay
    var mount_point_buf: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(mount_point_buf[0..config.mount_point.len], config.mount_point);
    mount_point_buf[config.mount_point.len] = 0;

    const mount_point_z: [*:0]const u8 = @ptrCast(mount_point_buf[0..config.mount_point.len :0]);

    syscall.mount("overlay", mount_point_z, "overlay", .{}, @ptrCast(&opts_buf)) catch |err| {
        scoped_log.err("Failed to mount overlay: {}", .{err});
        return error.MountFailed;
    };

    scoped_log.info("Overlay mounted at {s}", .{config.mount_point});
    _ = allocator;
}

/// Unmount overlay and cleanup
pub fn destroyOverlay(mount_point: []const u8) !void {
    scoped_log.info("Destroying overlay at {s}", .{mount_point});
    try mount_util.umount(mount_point);
}

/// Layer manager for incremental layer application
pub const LayerManager = struct {
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    layers: std.ArrayList([]const u8),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, base_dir: []const u8) Self {
        return Self{
            .allocator = allocator,
            .base_dir = base_dir,
            .layers = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.layers.items) |layer| {
            self.allocator.free(layer);
        }
        self.layers.deinit();
    }

    /// Add a layer
    pub fn addLayer(self: *Self, layer_path: []const u8) !void {
        const path = try self.allocator.dupe(u8, layer_path);
        try self.layers.append(path);
    }

    /// Create a new layer directory
    pub fn createLayer(self: *Self, name: []const u8) ![]const u8 {
        const path = try std.fs.path.join(self.allocator, &.{ self.base_dir, name });

        std.fs.makeDirAbsolute(path) catch |err| {
            if (err != error.PathAlreadyExists) {
                self.allocator.free(path);
                return error.DirectoryCreationFailed;
            }
        };

        try self.layers.append(path);
        return path;
    }

    /// Get all layer paths (for overlay lowerdir)
    pub fn getLowerDirs(self: *Self) []const []const u8 {
        return self.layers.items;
    }

    /// Create overlay from all layers
    pub fn createOverlayFromLayers(
        self: *Self,
        upper_dir: []const u8,
        work_dir: []const u8,
        mount_point: []const u8,
    ) !void {
        try createOverlay(.{
            .lower_dirs = self.getLowerDirs(),
            .upper_dir = upper_dir,
            .work_dir = work_dir,
            .mount_point = mount_point,
        }, self.allocator);
    }
};

/// Check if overlayfs is supported
pub fn isOverlaySupported() bool {
    // Try to check /proc/filesystems
    const file = std.fs.openFileAbsolute("/proc/filesystems", .{}) catch return false;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return false;

    return std.mem.indexOf(u8, buf[0..n], "overlay") != null;
}

/// Create a simple two-layer overlay (base + writable)
pub fn createSimpleOverlay(
    allocator: std.mem.Allocator,
    base_dir: []const u8,
    overlay_dir: []const u8,
    mount_point: []const u8,
) !void {
    const upper = try std.fs.path.join(allocator, &.{ overlay_dir, "upper" });
    defer allocator.free(upper);

    const work = try std.fs.path.join(allocator, &.{ overlay_dir, "work" });
    defer allocator.free(work);

    try createOverlay(.{
        .lower_dirs = &.{base_dir},
        .upper_dir = upper,
        .work_dir = work,
        .mount_point = mount_point,
    }, allocator);
}

test "OverlayConfig structure" {
    const config = OverlayConfig{
        .lower_dirs = &.{ "/layer1", "/layer2" },
        .upper_dir = "/upper",
        .work_dir = "/work",
        .mount_point = "/merged",
    };

    const testing = std.testing;
    try testing.expectEqual(@as(usize, 2), config.lower_dirs.len);
}

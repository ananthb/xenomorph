const std = @import("std");
const mount_util = @import("../util/mount.zig");
const mounts = @import("mounts.zig");
const log = @import("../util/log.zig");

const scoped_log = log.scoped("cleanup");

pub const CleanupError = mount_util.MountError || std.mem.Allocator.Error;

/// Options for cleanup phase
pub const CleanupOptions = struct {
    /// Path to old root (from new root's perspective)
    old_root: []const u8,

    /// Whether to unmount old root
    unmount_old_root: bool = false,

    /// Whether to delete old root mount point
    remove_mount_point: bool = false,

    /// Force unmount if busy
    force: bool = false,
};

/// Perform post-pivot cleanup
pub fn cleanup(options: CleanupOptions, allocator: std.mem.Allocator) CleanupError!void {
    scoped_log.info("Starting cleanup, old root at {s}", .{options.old_root});

    if (options.unmount_old_root) {
        try unmountOldRoot(options.old_root, options.force, allocator);
    }

    if (options.remove_mount_point) {
        try removeMountPoint(options.old_root);
    }

    scoped_log.info("Cleanup complete", .{});
}

/// Unmount the old root filesystem
pub fn unmountOldRoot(old_root: []const u8, force: bool, allocator: std.mem.Allocator) CleanupError!void {
    scoped_log.info("Unmounting old root at {s}", .{old_root});

    // First, unmount all submounts
    try mounts.cleanupOldRoot(old_root, allocator);

    // Then unmount old root itself
    if (force) {
        mount_util.umountDetach(old_root) catch |err| {
            scoped_log.warn("Failed to lazy unmount {s}: {}", .{ old_root, err });
        };
    } else {
        mount_util.umount(old_root) catch |err| {
            scoped_log.warn("Failed to unmount {s}: {}", .{ old_root, err });
            // Try lazy unmount as fallback
            mount_util.umountDetach(old_root) catch {};
        };
    }
}

/// Remove the old root mount point directory
pub fn removeMountPoint(old_root: []const u8) !void {
    scoped_log.info("Removing mount point {s}", .{old_root});

    std.fs.deleteTreeAbsolute(old_root) catch |err| {
        scoped_log.warn("Cannot remove {s}: {}", .{ old_root, err });
        return err;
    };
}

/// List remaining mounts under a path
pub fn listMountsUnder(path: []const u8, allocator: std.mem.Allocator) ![]const []const u8 {
    const all_mounts = try mount_util.readMounts(allocator);
    defer {
        for (all_mounts.items) |*m| {
            var m_copy = m.*;
            m_copy.deinit(allocator);
        }
        all_mounts.deinit();
    }

    var result = std.ArrayList([]const u8).init(allocator);
    errdefer {
        for (result.items) |item| {
            allocator.free(item);
        }
        result.deinit();
    }

    for (all_mounts.items) |m| {
        if (std.mem.startsWith(u8, m.target, path)) {
            try result.append(try allocator.dupe(u8, m.target));
        }
    }

    return result.toOwnedSlice();
}

/// Free the result of listMountsUnder
pub fn freeMountsList(list: []const []const u8, allocator: std.mem.Allocator) void {
    for (list) |item| {
        allocator.free(item);
    }
    allocator.free(list);
}

/// Check if old root can be safely unmounted
pub fn canUnmountOldRoot(old_root: []const u8, allocator: std.mem.Allocator) !bool {
    scoped_log.debug("Checking if {s} can be unmounted", .{old_root});

    // Check for processes using the old root
    // This is done by checking /proc/*/root and /proc/*/cwd

    var proc_dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch {
        return false;
    };
    defer proc_dir.close();

    var iter = proc_dir.iterate();
    while (iter.next() catch null) |entry| {
        // Skip non-numeric directories
        _ = std.fmt.parseInt(u32, entry.name, 10) catch continue;

        // Check if process root or cwd points to old root
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;

        // Check root
        const root_link = std.fmt.bufPrint(&path_buf, "/proc/{s}/root", .{entry.name}) catch continue;
        const root_target = std.fs.readLinkAbsolute(root_link, &path_buf) catch continue;

        if (std.mem.startsWith(u8, root_target, old_root)) {
            scoped_log.debug("Process {s} has root in old root", .{entry.name});
            return false;
        }
    }

    _ = allocator;
    return true;
}

/// Attempt graceful cleanup with retries
pub fn gracefulCleanup(options: CleanupOptions, allocator: std.mem.Allocator, max_retries: u32) !void {
    scoped_log.info("Starting graceful cleanup with {} max retries", .{max_retries});

    var retry: u32 = 0;
    while (retry < max_retries) : (retry += 1) {
        if (try canUnmountOldRoot(options.old_root, allocator)) {
            try cleanup(options, allocator);
            return;
        }

        scoped_log.debug("Cannot unmount yet, retry {}/{}", .{ retry + 1, max_retries });
        std.time.sleep(500 * std.time.ns_per_ms);
    }

    scoped_log.warn("Max retries reached, forcing cleanup", .{});
    var force_options = options;
    force_options.force = true;
    try cleanup(force_options, allocator);
}

test "CleanupOptions defaults" {
    const opts = CleanupOptions{
        .old_root = "/mnt/oldroot",
    };

    const testing = std.testing;
    try testing.expect(!opts.unmount_old_root);
    try testing.expect(!opts.remove_mount_point);
    try testing.expect(!opts.force);
}

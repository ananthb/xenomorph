const std = @import("std");
const mounts = @import("mounts.zig");
const pivot = @import("pivot.zig");
const mount_util = @import("../util/mount.zig");
const log = @import("../util/log.zig");

const scoped_log = log.scoped("prepare");

pub const PrepareError = error{
    InvalidRootfs,
    MountNamespaceFailed,
    EssentialMountsFailed,
    RootfsPreparationFailed,
    AllocationFailed,
} || mounts.MountError || std.mem.Allocator.Error;

/// Options for preparation phase
pub const PrepareOptions = struct {
    /// Path to the new rootfs
    new_root: []const u8,

    /// Skip verification of new rootfs
    skip_verify: bool = false,

    /// Create new mount namespace
    create_namespace: bool = true,
};

/// Result of preparation phase
pub const PrepareResult = struct {
    /// Prepared new root path
    new_root: []const u8,

    /// Whether mount namespace was created
    namespace_created: bool,

    /// Allocator used (for cleanup)
    allocator: std.mem.Allocator,

    pub fn deinit(self: *PrepareResult) void {
        self.allocator.free(self.new_root);
    }
};

/// Prepare the system for pivot_root
/// This performs all pre-pivot setup including:
/// - Verifying the new rootfs
/// - Creating mount namespace
/// - Setting up essential mounts
/// - Ensuring new root is a mount point
pub fn prepare(options: PrepareOptions, allocator: std.mem.Allocator) PrepareError!PrepareResult {
    scoped_log.info("Preparing pivot to {s}", .{options.new_root});

    // Verify new rootfs if requested
    if (!options.skip_verify) {
        scoped_log.debug("Verifying new rootfs", .{});
        const valid = pivot.verifyNewRoot(options.new_root, allocator) catch {
            return error.InvalidRootfs;
        };
        if (!valid) {
            scoped_log.err("New rootfs verification failed", .{});
            return error.InvalidRootfs;
        }
        scoped_log.info("New rootfs verified", .{});
    }

    var namespace_created = false;

    // Create mount namespace if requested
    if (options.create_namespace) {
        scoped_log.debug("Creating mount namespace", .{});
        mounts.createMountNamespace() catch |err| {
            scoped_log.err("Failed to create mount namespace: {}", .{err});
            return error.MountNamespaceFailed;
        };
        namespace_created = true;
    }

    // Setup essential mounts in new root
    scoped_log.debug("Setting up essential mounts", .{});
    mounts.setupEssentialMounts(options.new_root, allocator) catch |err| {
        scoped_log.err("Failed to setup essential mounts: {}", .{err});
        return error.EssentialMountsFailed;
    };

    // Prepare new root as mount point
    scoped_log.debug("Preparing new root mount point", .{});
    const prepared_root = mounts.prepareNewRoot(options.new_root, allocator) catch |err| {
        scoped_log.err("Failed to prepare new root: {}", .{err});
        return error.RootfsPreparationFailed;
    };

    scoped_log.info("Preparation complete", .{});

    return PrepareResult{
        .new_root = prepared_root,
        .namespace_created = namespace_created,
        .allocator = allocator,
    };
}

/// Verify prerequisites for pivot_root
pub fn checkPrerequisites() !void {
    scoped_log.debug("Checking prerequisites", .{});

    // Check if running as root
    if (std.os.linux.getuid() != 0) {
        scoped_log.err("Must run as root (uid 0)", .{});
        return error.PermissionDenied;
    }

    // Check if we have CAP_SYS_ADMIN
    // For now, just assume root has it
    scoped_log.debug("Running as root, CAP_SYS_ADMIN assumed", .{});
}

/// Prepare a directory for use as new root by setting up minimal structure
pub fn prepareMinimalRoot(path: []const u8) !void {
    scoped_log.info("Preparing minimal root structure at {s}", .{path});

    const dir = std.fs.openDirAbsolute(path, .{}) catch |err| {
        scoped_log.err("Cannot open directory {s}: {}", .{ path, err });
        return err;
    };
    defer dir.close();

    // Create essential directories
    const dirs = [_][]const u8{
        "bin",
        "sbin",
        "lib",
        "lib64",
        "usr",
        "usr/bin",
        "usr/lib",
        "etc",
        "dev",
        "proc",
        "sys",
        "run",
        "tmp",
        "mnt",
        "mnt/oldroot",
    };

    for (dirs) |d| {
        dir.makePath(d) catch |err| {
            if (err != error.PathAlreadyExists) {
                scoped_log.warn("Cannot create {s}: {}", .{ d, err });
            }
        };
    }

    scoped_log.info("Minimal root structure created", .{});
}

/// Create a copy of essential files for standalone rootfs
pub fn copyEssentials(src_root: []const u8, dst_root: []const u8, allocator: std.mem.Allocator) !void {
    scoped_log.info("Copying essentials from {s} to {s}", .{ src_root, dst_root });

    const essentials = [_][]const u8{
        "bin/sh",
        "bin/busybox",
        "lib/ld-linux-x86-64.so.2",
        "lib64/ld-linux-x86-64.so.2",
    };

    for (essentials) |rel_path| {
        const src_path = try std.fs.path.join(allocator, &.{ src_root, rel_path });
        defer allocator.free(src_path);

        const dst_path = try std.fs.path.join(allocator, &.{ dst_root, rel_path });
        defer allocator.free(dst_path);

        // Ensure parent directory exists
        if (std.fs.path.dirname(dst_path)) |parent| {
            std.fs.makeDirAbsolute(parent) catch |err| {
                if (err != error.PathAlreadyExists) continue;
            };
        }

        // Copy file
        std.fs.copyFileAbsolute(src_path, dst_path, .{}) catch |err| {
            scoped_log.debug("Cannot copy {s}: {}", .{ rel_path, err });
            continue;
        };

        scoped_log.debug("Copied {s}", .{rel_path});
    }
}

test "PrepareOptions defaults" {
    const opts = PrepareOptions{
        .new_root = "/newroot",
    };

    const testing = std.testing;
    try testing.expect(!opts.skip_verify);
    try testing.expect(opts.create_namespace);
}

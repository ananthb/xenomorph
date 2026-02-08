const std = @import("std");
const syscall = @import("../util/syscall.zig");
const mount_util = @import("../util/mount.zig");
const log = @import("../util/log.zig");

const scoped_log = log.scoped("mounts");

pub const MountError = mount_util.MountError;

/// Essential filesystem mounts that need to be preserved across pivot
pub const EssentialMount = struct {
    source: []const u8,
    target: []const u8,
    fstype: ?[]const u8,
    bind: bool,
};

pub const essential_mounts = [_]EssentialMount{
    .{ .source = "/dev", .target = "/dev", .fstype = null, .bind = true },
    .{ .source = "/proc", .target = "/proc", .fstype = "proc", .bind = false },
    .{ .source = "/sys", .target = "/sys", .fstype = "sysfs", .bind = false },
    .{ .source = "/run", .target = "/run", .fstype = null, .bind = true },
};

/// Create a new mount namespace for isolation
pub fn createMountNamespace() !void {
    scoped_log.info("Creating new mount namespace", .{});
    try syscall.unshare(.{ .newns = true });

    // Make all mounts private to prevent propagation to parent namespace
    scoped_log.debug("Making root mount private", .{});
    try mount_util.makePrivate("/");
}

/// Setup essential filesystem mounts in new rootfs
pub fn setupEssentialMounts(new_root: []const u8, allocator: std.mem.Allocator) !void {
    scoped_log.info("Setting up essential mounts in {s}", .{new_root});

    for (essential_mounts) |em| {
        const target_path = try std.fs.path.join(allocator, &.{ new_root, em.target });
        defer allocator.free(target_path);

        // Ensure target directory exists
        try mount_util.ensureDir(target_path);

        if (em.bind) {
            scoped_log.debug("Bind mounting {s} to {s}", .{ em.source, target_path });
            mount_util.bindMountRec(em.source, target_path) catch |err| {
                scoped_log.warn("Failed to bind mount {s}: {}", .{ em.source, err });
                // /run might not exist on minimal systems, continue
                if (!std.mem.eql(u8, em.source, "/run")) return err;
            };
        } else {
            scoped_log.debug("Mounting {s} ({s}) at {s}", .{ em.source, em.fstype orelse "none", target_path });
            mountFs(em.source, target_path, em.fstype) catch |err| {
                scoped_log.warn("Failed to mount {s}: {}", .{ em.source, err });
                return err;
            };
        }
    }
}

/// Mount a filesystem (non-bind)
fn mountFs(source: []const u8, target: []const u8, fstype: ?[]const u8) MountError!void {
    var source_buf: [std.fs.max_path_bytes]u8 = undefined;
    var target_buf: [std.fs.max_path_bytes]u8 = undefined;
    var fstype_buf: [64]u8 = undefined;

    if (source.len >= source_buf.len or target.len >= target_buf.len) {
        return error.PathTooLong;
    }

    @memcpy(source_buf[0..source.len], source);
    source_buf[source.len] = 0;

    @memcpy(target_buf[0..target.len], target);
    target_buf[target.len] = 0;

    const source_z: [*:0]const u8 = @ptrCast(source_buf[0..source.len :0]);
    const target_z: [*:0]const u8 = @ptrCast(target_buf[0..target.len :0]);

    var fstype_z: ?[*:0]const u8 = null;
    if (fstype) |ft| {
        if (ft.len >= fstype_buf.len) {
            return error.PathTooLong;
        }
        @memcpy(fstype_buf[0..ft.len], ft);
        fstype_buf[ft.len] = 0;
        fstype_z = @ptrCast(fstype_buf[0..ft.len :0]);
    }

    try syscall.mount(source_z, target_z, fstype_z, .{}, null);
}

/// Move old root to new location after pivot
pub fn moveOldRoot(old_root_mount: []const u8, new_location: []const u8) !void {
    scoped_log.info("Moving old root from {s} to {s}", .{ old_root_mount, new_location });
    try mount_util.moveMount(old_root_mount, new_location);
}

/// Unmount old root and all its submounts
pub fn cleanupOldRoot(old_root: []const u8, allocator: std.mem.Allocator) !void {
    scoped_log.info("Cleaning up old root at {s}", .{old_root});

    // Read all mounts and find those under old_root
    const mounts = try mount_util.readMounts(allocator);
    defer {
        for (mounts) |*m| {
            var m_copy = m.*;
            m_copy.deinit(allocator);
        }
        allocator.free(mounts);
    }

    // Collect mounts under old_root, sorted by depth (deepest first)
    var old_root_mounts: std.ArrayListUnmanaged([]const u8) = .{};
    defer old_root_mounts.deinit(allocator);

    for (mounts) |m| {
        if (std.mem.startsWith(u8, m.target, old_root)) {
            try old_root_mounts.append(allocator, try allocator.dupe(u8, m.target));
        }
    }
    defer {
        for (old_root_mounts.items) |m| {
            allocator.free(m);
        }
    }

    // Sort by path length descending (unmount deepest first)
    std.mem.sort([]const u8, old_root_mounts.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return a.len > b.len;
        }
    }.lessThan);

    // Unmount each
    for (old_root_mounts.items) |mount_path| {
        scoped_log.debug("Unmounting {s}", .{mount_path});
        mount_util.umountDetach(mount_path) catch |err| {
            scoped_log.warn("Failed to unmount {s}: {}", .{ mount_path, err });
        };
    }
}

/// Prepare the new root for pivot_root
/// Returns the path to the prepared mount point
pub fn prepareNewRoot(new_root: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    scoped_log.info("Preparing new root at {s}", .{new_root});

    // Ensure new_root is a mount point
    const is_mount = try mount_util.isMountPoint(new_root, allocator);
    if (!is_mount) {
        scoped_log.debug("{s} is not a mount point, bind mounting to itself", .{new_root});
        try mount_util.ensureMountPoint(new_root);
    }

    return try allocator.dupe(u8, new_root);
}

test "essential mounts defined" {
    const testing = std.testing;
    try testing.expect(essential_mounts.len > 0);

    // Verify /dev is included
    var has_dev = false;
    for (essential_mounts) |em| {
        if (std.mem.eql(u8, em.source, "/dev")) {
            has_dev = true;
            break;
        }
    }
    try testing.expect(has_dev);
}

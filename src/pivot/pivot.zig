const std = @import("std");
const syscall = @import("../util/syscall.zig");
const mount_util = @import("../util/mount.zig");
const mounts = @import("mounts.zig");
const log = @import("../util/log.zig");

const scoped_log = log.scoped("pivot");

pub const PivotError = error{
    NewRootNotFound,
    NewRootNotDirectory,
    OldRootCreationFailed,
    PivotRootFailed,
    ChdirFailed,
    ChrootFailed,
    ExecFailed,
    PreparationFailed,
    PathTooLong,
    AllocationFailed,
} || syscall.SyscallError || std.fs.File.OpenError;

/// Configuration for the pivot operation
pub const PivotConfig = struct {
    /// Path to the new root filesystem
    new_root: []const u8,

    /// Where to mount old root (relative to new root)
    old_root_mount: []const u8 = "mnt/oldroot",

    /// Command to execute after pivot (null = don't exec)
    exec_cmd: ?[]const u8 = null,

    /// Arguments for exec command
    exec_args: ?[]const []const u8 = null,

    /// Keep old root accessible after pivot
    keep_old_root: bool = true,

    /// Allocator for temporary allocations
    allocator: std.mem.Allocator,
};

/// Execute the pivot_root operation
pub fn executePivot(config: PivotConfig) PivotError!void {
    scoped_log.info("Starting pivot to {s}", .{config.new_root});

    // Verify new root exists and is a directory
    var new_root_stat = std.fs.openDirAbsolute(config.new_root, .{}) catch |err| {
        scoped_log.err("Cannot open new root {s}: {}", .{ config.new_root, err });
        return error.NewRootNotFound;
    };
    new_root_stat.close();

    // Create the old root mount point inside new root
    const old_root_path = std.fs.path.join(config.allocator, &.{ config.new_root, config.old_root_mount }) catch {
        return error.AllocationFailed;
    };
    defer config.allocator.free(old_root_path);

    scoped_log.debug("Old root will be at {s}", .{old_root_path});

    // Ensure old root mount point exists (including parent directories)
    // Open the new root directory and create the path relative to it
    {
        var new_root_dir = std.fs.openDirAbsolute(config.new_root, .{}) catch |err| {
            scoped_log.err("Cannot open new root {s}: {}", .{ config.new_root, err });
            return error.NewRootNotFound;
        };
        defer new_root_dir.close();

        // makePath creates all parent directories as needed
        new_root_dir.makePath(config.old_root_mount) catch |err| {
            scoped_log.err("Cannot create old root mount point {s}: {}", .{ config.old_root_mount, err });
            return error.OldRootCreationFailed;
        };
    }

    scoped_log.debug("Created old root mount point", .{});

    // Prepare null-terminated path for new_root
    var new_root_buf: [std.fs.max_path_bytes]u8 = undefined;

    if (config.new_root.len >= new_root_buf.len) {
        return error.PathTooLong;
    }

    @memcpy(new_root_buf[0..config.new_root.len], config.new_root);
    new_root_buf[config.new_root.len] = 0;

    const new_root_z: [*:0]const u8 = @ptrCast(new_root_buf[0..config.new_root.len :0]);

    // Make mounts private to avoid propagation issues
    scoped_log.debug("Making root mount private", .{});
    mount_util.makePrivate("/") catch |err| {
        scoped_log.warn("Failed to make root private: {}, continuing anyway", .{err});
    };

    // Make new root private too
    mount_util.makePrivate(config.new_root) catch |err| {
        scoped_log.warn("Failed to make new root private: {}, continuing anyway", .{err});
    };

    // Build absolute path for put_old (pivot_root requires put_old under new_root)
    const put_old_abs_path = std.fs.path.join(config.allocator, &.{ config.new_root, config.old_root_mount }) catch {
        return error.AllocationFailed;
    };
    defer config.allocator.free(put_old_abs_path);

    var put_old_abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (put_old_abs_path.len >= put_old_abs_buf.len) {
        return error.PathTooLong;
    }
    @memcpy(put_old_abs_buf[0..put_old_abs_path.len], put_old_abs_path);
    put_old_abs_buf[put_old_abs_path.len] = 0;
    const put_old_z: [*:0]const u8 = @ptrCast(put_old_abs_buf[0..put_old_abs_path.len :0]);

    // First try pivot_root
    scoped_log.info("Trying pivot_root({s}, {s})", .{ config.new_root, put_old_abs_path });
    syscall.pivotRoot(new_root_z, put_old_z) catch |pivot_err| {
        scoped_log.warn("pivot_root failed: {}, trying switch_root approach", .{pivot_err});

        // Fallback to switch_root approach (for initramfs/rootfs)
        // This is similar to what busybox's switch_root does
        scoped_log.info("Using switch_root approach (chdir + mount move + chroot)", .{});

        // 1. Change to new root
        syscall.chdir(new_root_z) catch |err| {
            scoped_log.err("chdir to new root failed: {}", .{err});
            return error.ChdirFailed;
        };

        // 2. Move mount to / (overmount)
        scoped_log.debug("Moving mount to /", .{});
        syscall.mount(".", "/", null, .{ .move = true }, null) catch |err| {
            scoped_log.err("mount move failed: {}", .{err});
            return error.PivotRootFailed;
        };

        // 3. Chroot to the new root
        scoped_log.debug("Chroot to new root", .{});
        syscall.chroot(".") catch |err| {
            scoped_log.err("chroot failed: {}", .{err});
            return error.ChrootFailed;
        };

        // 4. Change to / after chroot
        syscall.chdir("/") catch |err| {
            scoped_log.err("chdir to / after chroot failed: {}", .{err});
            return error.ChdirFailed;
        };

        scoped_log.info("switch_root complete", .{});

        // Execute post-pivot command if specified (same as pivot_root path)
        if (config.exec_cmd) |cmd| {
            try execCommand(cmd, config.exec_args);
        }
        return;
    };

    // Change to new root
    scoped_log.debug("Changing directory to /", .{});
    syscall.chdir("/") catch |err| {
        scoped_log.err("chdir to / failed: {}", .{err});
        return error.ChdirFailed;
    };

    // Optionally cleanup old root
    if (!config.keep_old_root) {
        scoped_log.info("Cleaning up old root", .{});
        const old_root_in_new = std.fs.path.join(config.allocator, &.{ "/", config.old_root_mount }) catch {
            return error.AllocationFailed;
        };
        defer config.allocator.free(old_root_in_new);

        mounts.cleanupOldRoot(old_root_in_new, config.allocator) catch |err| {
            scoped_log.warn("Failed to cleanup old root: {}", .{err});
        };
    }

    scoped_log.info("Pivot complete", .{});

    // Execute post-pivot command if specified
    if (config.exec_cmd) |cmd| {
        try execCommand(cmd, config.exec_args);
    }
}

/// Execute a command (replaces current process)
fn execCommand(cmd: []const u8, args: ?[]const []const u8) PivotError!void {
    scoped_log.info("Executing: {s}", .{cmd});

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Build argv
    var argv: std.ArrayListUnmanaged(?[*:0]const u8) = .{};

    // Add command as argv[0]
    const cmd_z = allocator.dupeZ(u8, cmd) catch return error.AllocationFailed;
    argv.append(allocator, cmd_z) catch return error.AllocationFailed;

    // Add additional arguments
    if (args) |arg_list| {
        for (arg_list) |arg| {
            const arg_z = allocator.dupeZ(u8, arg) catch return error.AllocationFailed;
            argv.append(allocator, arg_z) catch return error.AllocationFailed;
        }
    }

    // Null terminate argv
    argv.append(allocator, null) catch return error.AllocationFailed;

    // Get environment from libc
    const envp = std.c.environ;

    // Execute
    const err = std.posix.execveZ(cmd_z, @ptrCast(argv.items.ptr), @ptrCast(envp));
    scoped_log.err("execve failed: {}", .{err});
    return error.ExecFailed;
}

/// Convenience function for simple pivot with shell
pub fn pivotToShell(new_root: []const u8, allocator: std.mem.Allocator) PivotError!void {
    try executePivot(.{
        .new_root = new_root,
        .exec_cmd = "/bin/sh",
        .allocator = allocator,
    });
}

/// Verify that a path is suitable as a new root
pub fn verifyNewRoot(path: []const u8, allocator: std.mem.Allocator) !bool {
    _ = allocator;
    scoped_log.debug("Verifying new root at {s}", .{path});

    // Check it's a directory
    var dir = std.fs.openDirAbsolute(path, .{}) catch |err| {
        scoped_log.warn("Cannot open {s}: {}", .{ path, err });
        return false;
    };
    defer dir.close();

    // Check for essential directories
    const required_dirs = [_][]const u8{
        "bin",
        "lib",
    };

    for (required_dirs) |req_dir| {
        var sub_dir = dir.openDir(req_dir, .{}) catch {
            scoped_log.warn("Missing required directory: {s}", .{req_dir});
            return false;
        };
        sub_dir.close();
    }

    // Check for init or shell
    var has_executable = false;
    const executables = [_][]const u8{
        "sbin/init",
        "bin/sh",
        "bin/bash",
    };

    for (executables) |exe| {
        if (dir.access(exe, .{})) |_| {
            has_executable = true;
            break;
        } else |_| {}
    }

    if (!has_executable) {
        scoped_log.warn("No init or shell found in new root", .{});
        return false;
    }

    return true;
}

test "PivotConfig defaults" {
    const testing = std.testing;
    const config = PivotConfig{
        .new_root = "/newroot",
        .allocator = testing.allocator,
    };

    try testing.expectEqualStrings("mnt/oldroot", config.old_root_mount);
    try testing.expect(config.keep_old_root);
    try testing.expect(config.exec_cmd == null);
}

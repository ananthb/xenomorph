const std = @import("std");
const runz = @import("runz");
const syscall = runz.linux_util.syscall;
const mount_util = runz.linux_util.mount_util;
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

    /// Path to keep old root (relative to /), or empty string to unmount.
    keep_old_root: []const u8 = "mnt/oldroot",

    /// Environment variables for the exec'd command (null = inherit current env)
    exec_env: ?[]const []const u8 = null,

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

    // Ensure old root mount point exists (including parent directories)
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

    // Make mounts private to avoid propagation issues
    scoped_log.debug("Making root mount private", .{});
    mount_util.makePrivate("/") catch |err| {
        scoped_log.warn("Failed to make root private: {}, continuing anyway", .{err});
    };

    // Make new root private too
    mount_util.makePrivate(config.new_root) catch |err| {
        scoped_log.warn("Failed to make new root private: {}, continuing anyway", .{err});
    };

    // Use runz pivotRoot helper
    scoped_log.info("Performing pivot_root", .{});
    mount_util.pivotRoot(config.new_root, config.old_root_mount) catch |err| {
        scoped_log.err("pivotRoot failed: {}", .{err});
        return switch (err) {
            error.PivotRootFailed => error.PivotRootFailed,
            error.ChdirFailed => error.ChdirFailed,
            error.ChrootFailed => error.ChrootFailed,
            error.PathTooLong => error.PathTooLong,
        };
    };

    // Optionally cleanup old root
    if (config.keep_old_root.len == 0) {
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
        try execCommand(cmd, config.exec_args, config.exec_env);
    }
}

/// Execute a command (replaces current process)
fn execCommand(cmd: []const u8, args: ?[]const []const u8, env: ?[]const []const u8) PivotError!void {
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

    // Build envp: use custom env if provided, otherwise inherit from libc
    var envp_ptr: [*:null]const ?[*:0]const u8 = undefined;
    if (env) |env_list| {
        var envp_list: std.ArrayListUnmanaged(?[*:0]const u8) = .{};
        for (env_list) |e| {
            const e_z = allocator.dupeZ(u8, e) catch return error.AllocationFailed;
            envp_list.append(allocator, e_z) catch return error.AllocationFailed;
        }
        envp_list.append(allocator, null) catch return error.AllocationFailed;
        envp_ptr = @ptrCast(envp_list.items.ptr);
    } else {
        envp_ptr = @ptrCast(std.c.environ);
    }

    // Execute
    const err = std.posix.execveZ(cmd_z, @ptrCast(argv.items.ptr), envp_ptr);
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
    try testing.expectEqualStrings("mnt/oldroot", config.keep_old_root);
    try testing.expect(config.exec_cmd == null);
}

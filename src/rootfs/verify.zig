const std = @import("std");
const log = @import("../util/log.zig");

const scoped_log = log.scoped("rootfs/verify");

pub const VerifyError = error{
    RootfsNotFound,
    MissingEssentialDirectory,
    MissingExecutable,
    InvalidPermissions,
    VerificationFailed,
};

/// Verification result
pub const VerifyResult = struct {
    valid: bool,
    errors: std.ArrayListUnmanaged([]const u8),
    warnings: std.ArrayListUnmanaged([]const u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *VerifyResult, allocator: std.mem.Allocator) void {
        for (self.errors.items) |e| allocator.free(e);
        self.errors.deinit(allocator);
        for (self.warnings.items) |w| allocator.free(w);
        self.warnings.deinit(allocator);
    }
};

/// Essential directories that must exist
const essential_dirs = [_][]const u8{
    "bin",
    "lib",
    "dev",
    "proc",
    "sys",
};

/// Recommended directories
const recommended_dirs = [_][]const u8{
    "etc",
    "tmp",
    "var",
    "usr",
    "sbin",
    "run",
};

/// Essential executables (at least one must exist)
const essential_executables = [_][]const u8{
    "bin/sh",
    "bin/bash",
    "sbin/init",
    "usr/bin/sh",
};

/// Verify a rootfs is suitable for pivot
pub fn verify(rootfs_path: []const u8, allocator: std.mem.Allocator) !VerifyResult {
    scoped_log.info("Verifying rootfs at {s}", .{rootfs_path});

    var result = VerifyResult{
        .valid = true,
        .errors = .{},
        .warnings = .{},
        .allocator = allocator,
    };
    errdefer result.deinit(allocator);

    // Open root directory
    var dir = std.fs.openDirAbsolute(rootfs_path, .{}) catch {
        try result.errors.append(allocator, try allocator.dupe(u8, "Cannot open rootfs directory"));
        result.valid = false;
        return result;
    };
    defer dir.close();

    // Check essential directories
    for (essential_dirs) |essential| {
        var sub_dir = dir.openDir(essential, .{}) catch {
            const msg = try std.fmt.allocPrint(allocator, "Missing essential directory: {s}", .{essential});
            try result.errors.append(allocator, msg);
            result.valid = false;
            continue;
        };
        sub_dir.close();
    }

    // Check recommended directories
    for (recommended_dirs) |recommended| {
        dir.access(recommended, .{}) catch {
            const msg = try std.fmt.allocPrint(allocator, "Missing recommended directory: {s}", .{recommended});
            try result.warnings.append(allocator, msg);
        };
    }

    // Check for at least one executable
    var has_executable = false;
    for (essential_executables) |exe| {
        if (dir.access(exe, .{})) |_| {
            has_executable = true;
            scoped_log.debug("Found executable: {s}", .{exe});
            break;
        } else |_| {}
    }

    if (!has_executable) {
        try result.errors.append(allocator, try allocator.dupe(u8, "No shell or init found (need bin/sh, bin/bash, or sbin/init)"));
        result.valid = false;
    }

    if (result.valid) {
        scoped_log.info("Rootfs verification passed", .{});
    } else {
        scoped_log.err("Rootfs verification failed with {} errors", .{result.errors.items.len});
    }

    return result;
}

/// Quick check if rootfs is valid (no detailed errors)
pub fn isValid(rootfs_path: []const u8) bool {
    const dir = std.fs.openDirAbsolute(rootfs_path, .{}) catch return false;
    defer dir.close();

    // Check essential directories
    for (essential_dirs) |essential| {
        var sub_dir = dir.openDir(essential, .{}) catch return false;
        sub_dir.close();
    }

    // Check for at least one executable
    for (essential_executables) |exe| {
        if (dir.access(exe, .{})) |_| {
            return true;
        } else |_| {}
    }

    return false;
}

/// Check if an executable exists and is executable
pub fn checkExecutable(rootfs_path: []const u8, exe_path: []const u8, allocator: std.mem.Allocator) !bool {
    const full_path = try std.fs.path.join(allocator, &.{ rootfs_path, exe_path });
    defer allocator.free(full_path);

    const file = std.fs.openFileAbsolute(full_path, .{}) catch return false;
    defer file.close();

    const stat = file.stat() catch return false;

    // Check if executable bit is set
    const mode = stat.mode;
    return (mode & 0o111) != 0;
}

/// Get information about a rootfs
pub const RootfsInfo = struct {
    total_size: u64,
    file_count: u64,
    has_init: bool,
    has_shell: bool,
    architecture: ?[]const u8,

    pub fn deinit(self: *RootfsInfo, allocator: std.mem.Allocator) void {
        if (self.architecture) |arch| allocator.free(arch);
    }
};

/// Get detailed information about a rootfs
pub fn getInfo(rootfs_path: []const u8, allocator: std.mem.Allocator) !RootfsInfo {
    var info = RootfsInfo{
        .total_size = 0,
        .file_count = 0,
        .has_init = false,
        .has_shell = false,
        .architecture = null,
    };

    const dir = std.fs.openDirAbsolute(rootfs_path, .{}) catch return info;
    defer dir.close();

    // Check for init
    info.has_init = (dir.access("sbin/init", .{}) catch null) != null;

    // Check for shell
    info.has_shell = (dir.access("bin/sh", .{}) catch null) != null or
        (dir.access("bin/bash", .{}) catch null) != null;

    // Try to detect architecture from ld-linux
    if (dir.access("lib64/ld-linux-x86-64.so.2", .{})) |_| {
        info.architecture = try allocator.dupe(u8, "x86_64");
    } else |_| {
        if (dir.access("lib/ld-linux-armhf.so.3", .{})) |_| {
            info.architecture = try allocator.dupe(u8, "arm");
        } else |_| {
            if (dir.access("lib/ld-linux-aarch64.so.1", .{})) |_| {
                info.architecture = try allocator.dupe(u8, "aarch64");
            } else |_| {}
        }
    }

    // Count files and size (simple, non-recursive for now)
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        info.file_count += 1;
        if (entry.kind == .file) {
            const stat = dir.statFile(entry.name) catch continue;
            info.total_size += stat.size;
        }
    }

    return info;
}

/// Print verification result
pub fn printResult(result: *const VerifyResult, writer: anytype) !void {
    if (result.valid) {
        try writer.print("Rootfs verification: PASSED\n", .{});
    } else {
        try writer.print("Rootfs verification: FAILED\n", .{});
    }

    if (result.errors.items.len > 0) {
        try writer.print("\nErrors:\n", .{});
        for (result.errors.items) |err| {
            try writer.print("  - {s}\n", .{err});
        }
    }

    if (result.warnings.items.len > 0) {
        try writer.print("\nWarnings:\n", .{});
        for (result.warnings.items) |warn| {
            try writer.print("  - {s}\n", .{warn});
        }
    }
}

test "essential directories defined" {
    const testing = std.testing;
    try testing.expect(essential_dirs.len > 0);
    try testing.expect(essential_executables.len > 0);
}

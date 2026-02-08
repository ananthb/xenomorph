const std = @import("std");
const log = @import("log.zig");
const syscall = @import("syscall.zig");

const scoped_log = log.scoped("util/memory");

pub const MemoryError = error{
    InsufficientMemory,
    CannotReadMemInfo,
    MountFailed,
    UnmountFailed,
};

/// Memory information from /proc/meminfo
pub const MemInfo = struct {
    /// Total physical memory in bytes
    total: u64,
    /// Available memory in bytes (MemAvailable or Free + Buffers + Cached)
    available: u64,
    /// Free memory in bytes
    free: u64,
    /// Memory used by buffers
    buffers: u64,
    /// Memory used by cache
    cached: u64,

    /// Get percentage of memory available
    pub fn availablePercent(self: MemInfo) f64 {
        if (self.total == 0) return 0;
        return @as(f64, @floatFromInt(self.available)) / @as(f64, @floatFromInt(self.total)) * 100.0;
    }
};

/// Read memory information from /proc/meminfo
pub fn getMemInfo() MemoryError!MemInfo {
    const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch {
        return error.CannotReadMemInfo;
    };
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return error.CannotReadMemInfo;
    const content = buf[0..n];

    var info = MemInfo{
        .total = 0,
        .available = 0,
        .free = 0,
        .buffers = 0,
        .cached = 0,
    };

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "MemTotal:")) {
            info.total = parseMemValue(line) orelse 0;
        } else if (std.mem.startsWith(u8, line, "MemAvailable:")) {
            info.available = parseMemValue(line) orelse 0;
        } else if (std.mem.startsWith(u8, line, "MemFree:")) {
            info.free = parseMemValue(line) orelse 0;
        } else if (std.mem.startsWith(u8, line, "Buffers:")) {
            info.buffers = parseMemValue(line) orelse 0;
        } else if (std.mem.startsWith(u8, line, "Cached:")) {
            info.cached = parseMemValue(line) orelse 0;
        }
    }

    // If MemAvailable isn't present (older kernels), estimate it
    if (info.available == 0) {
        info.available = info.free + info.buffers + info.cached;
    }

    return info;
}

/// Parse a value from /proc/meminfo (e.g., "MemTotal:       16384000 kB")
fn parseMemValue(line: []const u8) ?u64 {
    // Find the colon
    const colon_idx = std.mem.indexOf(u8, line, ":") orelse return null;
    const value_part = std.mem.trim(u8, line[colon_idx + 1 ..], " \t");

    // Split off the "kB" suffix
    var parts = std.mem.splitScalar(u8, value_part, ' ');
    const num_str = parts.next() orelse return null;

    const value = std.fmt.parseInt(u64, num_str, 10) catch return null;

    // Convert from kB to bytes
    return value * 1024;
}

/// Check if there's enough memory for a given size
/// Returns error if insufficient, otherwise returns available memory
pub fn checkAvailableMemory(required_bytes: u64) MemoryError!u64 {
    const mem_info = try getMemInfo();

    scoped_log.debug("Memory: total={d}MB, available={d}MB, required={d}MB", .{
        mem_info.total / (1024 * 1024),
        mem_info.available / (1024 * 1024),
        required_bytes / (1024 * 1024),
    });

    // Require some headroom (keep at least 10% or 256MB free, whichever is larger)
    const min_headroom = @max(mem_info.total / 10, 256 * 1024 * 1024);
    const usable = if (mem_info.available > min_headroom)
        mem_info.available - min_headroom
    else
        0;

    if (usable < required_bytes) {
        scoped_log.err("Insufficient memory: need {d}MB but only {d}MB usable ({d}MB available, keeping {d}MB headroom)", .{
            required_bytes / (1024 * 1024),
            usable / (1024 * 1024),
            mem_info.available / (1024 * 1024),
            min_headroom / (1024 * 1024),
        });
        return error.InsufficientMemory;
    }

    return mem_info.available;
}

/// Estimate image size from OCI manifest or tarball
pub fn estimateImageSize(image_path: []const u8) !u64 {
    // For tarballs, use file size * 2 (compressed -> uncompressed estimate)
    if (std.mem.endsWith(u8, image_path, ".tar.gz") or
        std.mem.endsWith(u8, image_path, ".tgz"))
    {
        const stat = std.fs.cwd().statFile(image_path) catch {
            // Try absolute path
            const file = std.fs.openFileAbsolute(image_path, .{}) catch return 512 * 1024 * 1024; // Default 512MB
            defer file.close();
            const s = file.stat() catch return 512 * 1024 * 1024;
            return s.size * 3; // gzip typically 3x compression
        };
        return stat.size * 3;
    } else if (std.mem.endsWith(u8, image_path, ".tar")) {
        const stat = std.fs.cwd().statFile(image_path) catch {
            const file = std.fs.openFileAbsolute(image_path, .{}) catch return 512 * 1024 * 1024;
            defer file.close();
            const s = file.stat() catch return 512 * 1024 * 1024;
            return s.size;
        };
        return stat.size;
    }

    // Check if it's a local directory
    var dir = std.fs.openDirAbsolute(image_path, .{ .iterate = true }) catch {
        // For registry images, we'll need to check the manifest
        // For now, return a conservative default
        return 1024 * 1024 * 1024; // 1GB default for registry images
    };
    defer dir.close();

    // Calculate actual directory size
    const size = calculateDirSize(dir) catch {
        return 256 * 1024 * 1024; // 256MB fallback
    };

    // Add 50% headroom for local directories and minimum 32MB
    return @max(size + size / 2, 32 * 1024 * 1024);
}

/// Calculate total size of files in a directory recursively
fn calculateDirSize(dir: std.fs.Dir) !u64 {
    var total: u64 = 0;
    var iter = dir.iterate();

    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .file => {
                const stat = dir.statFile(entry.name) catch continue;
                total += stat.size;
            },
            .directory => {
                var sub_dir = dir.openDir(entry.name, .{ .iterate = true }) catch continue;
                defer sub_dir.close();
                total += calculateDirSize(sub_dir) catch 0;
            },
            else => {},
        }
    }

    return total;
}

/// Mount point for tmpfs rootfs
pub const TmpfsMount = struct {
    path: []const u8,
    allocator: std.mem.Allocator,
    mounted: bool,

    const Self = @This();

    /// Create and mount a tmpfs at the given path with size limit
    pub fn init(allocator: std.mem.Allocator, path: []const u8, size_bytes: u64) !Self {
        var self = Self{
            .path = try allocator.dupe(u8, path),
            .allocator = allocator,
            .mounted = false,
        };

        try self.mount(size_bytes);
        return self;
    }

    /// Mount the tmpfs
    fn mount(self: *Self, size_bytes: u64) !void {
        // Create mount point directory
        std.fs.makeDirAbsolute(self.path) catch |err| {
            if (err != error.PathAlreadyExists) {
                scoped_log.err("Cannot create tmpfs mount point {s}: {}", .{ self.path, err });
                return error.MountFailed;
            }
        };

        // Prepare mount options with size
        var options_buf: [128]u8 = undefined;
        const options = std.fmt.bufPrint(&options_buf, "size={d},mode=0755", .{size_bytes}) catch {
            return error.MountFailed;
        };

        // Null-terminate strings for syscall
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (self.path.len >= path_buf.len) return error.MountFailed;
        @memcpy(path_buf[0..self.path.len], self.path);
        path_buf[self.path.len] = 0;

        var opts_buf: [256]u8 = undefined;
        if (options.len >= opts_buf.len) return error.MountFailed;
        @memcpy(opts_buf[0..options.len], options);
        opts_buf[options.len] = 0;

        const path_z: [*:0]const u8 = @ptrCast(path_buf[0..self.path.len :0]);
        const opts_z: [*:0]const u8 = @ptrCast(opts_buf[0..options.len :0]);

        scoped_log.info("Mounting tmpfs at {s} with size {d}MB", .{
            self.path,
            size_bytes / (1024 * 1024),
        });

        syscall.mount("tmpfs", path_z, "tmpfs", .{}, opts_z) catch |err| {
            scoped_log.err("Failed to mount tmpfs: {}", .{err});
            return error.MountFailed;
        };

        self.mounted = true;
    }

    /// Unmount and cleanup
    pub fn deinit(self: *Self) void {
        if (self.mounted) {
            self.unmount() catch |err| {
                scoped_log.warn("Failed to unmount tmpfs at {s}: {}", .{ self.path, err });
            };
        }
        self.allocator.free(self.path);
    }

    /// Unmount the tmpfs
    pub fn unmount(self: *Self) !void {
        if (!self.mounted) return;

        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        @memcpy(path_buf[0..self.path.len], self.path);
        path_buf[self.path.len] = 0;

        const path_z: [*:0]const u8 = @ptrCast(path_buf[0..self.path.len :0]);

        scoped_log.debug("Unmounting tmpfs at {s}", .{self.path});

        // Try lazy unmount first
        const result = std.os.linux.syscall2(.umount2, @intFromPtr(path_z), 2); // MNT_DETACH = 2
        if (std.os.linux.E.init(result) != .SUCCESS) {
            return error.UnmountFailed;
        }

        self.mounted = false;
    }

    /// Get path to the mounted tmpfs
    pub fn getPath(self: *const Self) []const u8 {
        return self.path;
    }
};

/// Format bytes as human-readable string
pub fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var size: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;

    while (size >= 1024 and unit_idx < units.len - 1) {
        size /= 1024;
        unit_idx += 1;
    }

    return std.fmt.bufPrint(buf, "{d:.1}{s}", .{ size, units[unit_idx] }) catch "?";
}

test "parseMemValue" {
    const testing = std.testing;

    const val1 = parseMemValue("MemTotal:       16384000 kB");
    try testing.expect(val1 != null);
    try testing.expectEqual(@as(u64, 16384000 * 1024), val1.?);

    const val2 = parseMemValue("Invalid line");
    try testing.expect(val2 == null);
}

test "formatBytes" {
    const testing = std.testing;
    var buf: [32]u8 = undefined;

    const result = formatBytes(1536 * 1024 * 1024, &buf);
    try testing.expect(std.mem.indexOf(u8, result, "1.5") != null);
    try testing.expect(std.mem.indexOf(u8, result, "GB") != null);
}

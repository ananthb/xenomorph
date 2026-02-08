const std = @import("std");
const log = @import("../util/log.zig");

const scoped_log = log.scoped("init/detector");

/// Supported init systems
pub const InitSystem = enum {
    systemd,
    openrc,
    sysvinit,
    upstart,
    runit,
    s6,
    unknown,

    pub fn name(self: InitSystem) []const u8 {
        return switch (self) {
            .systemd => "systemd",
            .openrc => "OpenRC",
            .sysvinit => "SysV init",
            .upstart => "Upstart",
            .runit => "runit",
            .s6 => "s6",
            .unknown => "unknown",
        };
    }
};

/// Detection result with additional info
pub const DetectionResult = struct {
    init_system: InitSystem,
    version: ?[]const u8,
    pid1_comm: []const u8,

    pub fn deinit(self: *DetectionResult, allocator: std.mem.Allocator) void {
        if (self.version) |v| allocator.free(v);
        allocator.free(self.pid1_comm);
    }
};

/// Detect the running init system
pub fn detect(allocator: std.mem.Allocator) !DetectionResult {
    scoped_log.info("Detecting init system", .{});

    // Read PID 1's comm
    const pid1_comm = try readPid1Comm(allocator);
    errdefer allocator.free(pid1_comm);

    scoped_log.debug("PID 1 comm: {s}", .{pid1_comm});

    // Check for systemd
    if (isSystemd()) {
        const version = getSystemdVersion(allocator) catch null;
        scoped_log.info("Detected systemd", .{});
        return DetectionResult{
            .init_system = .systemd,
            .version = version,
            .pid1_comm = pid1_comm,
        };
    }

    // Check for OpenRC
    if (isOpenrc()) {
        scoped_log.info("Detected OpenRC", .{});
        return DetectionResult{
            .init_system = .openrc,
            .version = null,
            .pid1_comm = pid1_comm,
        };
    }

    // Check for runit
    if (isRunit()) {
        scoped_log.info("Detected runit", .{});
        return DetectionResult{
            .init_system = .runit,
            .version = null,
            .pid1_comm = pid1_comm,
        };
    }

    // Check for s6
    if (isS6()) {
        scoped_log.info("Detected s6", .{});
        return DetectionResult{
            .init_system = .s6,
            .version = null,
            .pid1_comm = pid1_comm,
        };
    }

    // Check for Upstart
    if (isUpstart()) {
        scoped_log.info("Detected Upstart", .{});
        return DetectionResult{
            .init_system = .upstart,
            .version = null,
            .pid1_comm = pid1_comm,
        };
    }

    // Check for SysV init (fallback)
    if (std.mem.eql(u8, pid1_comm, "init")) {
        scoped_log.info("Detected SysV init (or compatible)", .{});
        return DetectionResult{
            .init_system = .sysvinit,
            .version = null,
            .pid1_comm = pid1_comm,
        };
    }

    scoped_log.warn("Could not detect init system", .{});
    return DetectionResult{
        .init_system = .unknown,
        .version = null,
        .pid1_comm = pid1_comm,
    };
}

/// Read the command name of PID 1
fn readPid1Comm(allocator: std.mem.Allocator) ![]const u8 {
    const file = std.fs.openFileAbsolute("/proc/1/comm", .{}) catch {
        return allocator.dupe(u8, "unknown");
    };
    defer file.close();

    var buf: [256]u8 = undefined;
    const n = file.readAll(&buf) catch return allocator.dupe(u8, "unknown");

    // Remove trailing newline
    var end = n;
    while (end > 0 and (buf[end - 1] == '\n' or buf[end - 1] == '\r')) {
        end -= 1;
    }

    return allocator.dupe(u8, buf[0..end]);
}

/// Check if systemd is running
fn isSystemd() bool {
    // Check for /run/systemd/system (most reliable)
    std.fs.accessAbsolute("/run/systemd/system", .{}) catch return false;
    return true;
}

/// Get systemd version
fn getSystemdVersion(allocator: std.mem.Allocator) ![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "systemctl", "--version" },
    }) catch return error.VersionCheckFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Parse first line: "systemd 252 (252.4-1)"
    const first_line_end = std.mem.indexOf(u8, result.stdout, "\n") orelse result.stdout.len;
    const first_line = result.stdout[0..first_line_end];

    // Extract version number
    var iter = std.mem.splitScalar(u8, first_line, ' ');
    _ = iter.next(); // skip "systemd"
    if (iter.next()) |version| {
        return allocator.dupe(u8, version);
    }

    return error.VersionCheckFailed;
}

/// Check if OpenRC is running
fn isOpenrc() bool {
    // Check for /run/openrc or openrc-run in path
    std.fs.accessAbsolute("/run/openrc", .{}) catch {
        std.fs.accessAbsolute("/sbin/openrc-run", .{}) catch return false;
    };
    return true;
}

/// Check if runit is running
fn isRunit() bool {
    // Check for runit-specific files
    std.fs.accessAbsolute("/run/runit.stopit", .{}) catch {
        // Also check if runsvdir is running
        std.fs.accessAbsolute("/var/run/runsvdir", .{}) catch return false;
    };
    return true;
}

/// Check if s6 is running
fn isS6() bool {
    // Check for s6-specific files
    std.fs.accessAbsolute("/run/s6", .{}) catch {
        std.fs.accessAbsolute("/run/s6-rc", .{}) catch return false;
    };
    return true;
}

/// Check if Upstart is running
fn isUpstart() bool {
    // Check for Upstart socket
    std.fs.accessAbsolute("/var/run/upstart", .{}) catch return false;
    return true;
}

/// Quick check if we're running under systemd
pub fn isUnderSystemd() bool {
    return isSystemd();
}

/// Get the current runlevel (for SysV-style inits)
pub fn getRunlevel(allocator: std.mem.Allocator) !?u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{"runlevel"},
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Output is like "N 5" (previous runlevel and current)
    var iter = std.mem.splitScalar(u8, result.stdout, ' ');
    _ = iter.next(); // skip previous
    if (iter.next()) |current| {
        const trimmed = std.mem.trim(u8, current, " \n\r");
        if (trimmed.len == 1) {
            return trimmed[0];
        }
    }

    return null;
}

test "InitSystem names" {
    const testing = std.testing;

    try testing.expectEqualStrings("systemd", InitSystem.systemd.name());
    try testing.expectEqualStrings("OpenRC", InitSystem.openrc.name());
    try testing.expectEqualStrings("unknown", InitSystem.unknown.name());
}

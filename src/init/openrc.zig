const std = @import("std");
const log = @import("../util/log.zig");

const scoped_log = log.scoped("init/openrc");

/// OpenRC-specific operations
pub const OpenrcController = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    /// Change runlevel
    pub fn changeRunlevel(self: *Self, runlevel: []const u8) !void {
        scoped_log.info("Changing to runlevel {s}", .{runlevel});

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "openrc", runlevel },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            scoped_log.err("Failed to change runlevel: {s}", .{result.stderr});
            return error.CommandFailed;
        }
    }

    /// Get list of running services
    pub fn listRunningServices(self: *Self) ![]const []const u8 {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "rc-status", "--servicelist" },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        var services = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (services.items) |s| self.allocator.free(s);
            services.deinit();
        }

        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (trimmed.len == 0) continue;

            // Parse service name (format varies)
            if (std.mem.indexOf(u8, trimmed, "[") == null) continue;

            const name_end = std.mem.indexOf(u8, trimmed, " ") orelse trimmed.len;
            try services.append(try self.allocator.dupe(u8, trimmed[0..name_end]));
        }

        return services.toOwnedSlice();
    }

    /// Stop a service
    pub fn stopService(self: *Self, name: []const u8) !void {
        scoped_log.debug("Stopping service: {s}", .{name});

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "rc-service", name, "stop" },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            scoped_log.warn("Failed to stop {s}: {s}", .{ name, result.stderr });
        }
    }

    /// Start a service
    pub fn startService(self: *Self, name: []const u8) !void {
        scoped_log.debug("Starting service: {s}", .{name});

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "rc-service", name, "start" },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            scoped_log.warn("Failed to start {s}: {s}", .{ name, result.stderr });
        }
    }

    /// Get service status
    pub fn getServiceStatus(self: *Self, name: []const u8) !ServiceStatus {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "rc-service", name, "status" },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited == 0) {
            if (std.mem.indexOf(u8, result.stdout, "started") != null) {
                return .running;
            }
            return .stopped;
        }

        return .unknown;
    }

    /// Stop all services in a runlevel
    pub fn stopRunlevel(self: *Self, runlevel: []const u8) !void {
        scoped_log.info("Stopping all services in runlevel {s}", .{runlevel});

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "rc", runlevel, "stop" },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
    }

    /// Enter single user mode
    pub fn enterSingleUser(self: *Self) !void {
        try self.changeRunlevel("single");
    }

    /// Get current runlevel
    pub fn getCurrentRunlevel(self: *Self) ![]const u8 {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "rc-status", "--runlevel" },
        });
        defer self.allocator.free(result.stderr);

        const trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
        const owned = try self.allocator.dupe(u8, trimmed);
        self.allocator.free(result.stdout);
        return owned;
    }
};

/// Service status
pub const ServiceStatus = enum {
    running,
    stopped,
    crashed,
    unknown,
};

/// Check if OpenRC is available
pub fn isAvailable() bool {
    std.fs.accessAbsolute("/sbin/openrc", .{}) catch {
        std.fs.accessAbsolute("/usr/sbin/openrc", .{}) catch return false;
    };
    return true;
}

/// Get OpenRC version
pub fn getVersion(allocator: std.mem.Allocator) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "openrc", "--version" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Parse version from output
    const first_line_end = std.mem.indexOf(u8, result.stdout, "\n") orelse result.stdout.len;
    return allocator.dupe(u8, result.stdout[0..first_line_end]);
}

/// Essential services that should not be stopped
const essential_services = [_][]const u8{
    "udev",
    "devfs",
    "dmesg",
    "sysfs",
    "procfs",
    "root",
    "localmount",
    "bootmisc",
};

/// Check if a service is essential
pub fn isEssentialService(name: []const u8) bool {
    for (essential_services) |e| {
        if (std.mem.eql(u8, name, e)) return true;
    }
    return false;
}

test "essential service check" {
    const testing = std.testing;

    try testing.expect(isEssentialService("udev"));
    try testing.expect(isEssentialService("sysfs"));
    try testing.expect(!isEssentialService("nginx"));
}

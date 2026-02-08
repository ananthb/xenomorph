const std = @import("std");
const log = @import("../util/log.zig");
const interface = @import("interface.zig");

const scoped_log = log.scoped("init/systemd");

/// systemd-specific operations
pub const SystemdController = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    /// Isolate to a target (like changing runlevel)
    pub fn isolate(self: *Self, target: []const u8) !void {
        scoped_log.info("Isolating to {s}", .{target});

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "systemctl", "isolate", target },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            scoped_log.err("Failed to isolate: {s}", .{result.stderr});
            return error.CommandFailed;
        }
    }

    /// Get list of active units
    pub fn listActiveUnits(self: *Self) ![]const Unit {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{
                "systemctl",
                "list-units",
                "--type=service",
                "--state=running",
                "--no-legend",
                "--plain",
            },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        var units = std.ArrayList(Unit).init(self.allocator);
        errdefer {
            for (units.items) |*u| u.deinit(self.allocator);
            units.deinit();
        }

        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            const name = parts.next() orelse continue;
            const load = parts.next() orelse continue;
            const active = parts.next() orelse continue;
            const sub = parts.next() orelse continue;

            try units.append(.{
                .name = try self.allocator.dupe(u8, name),
                .load_state = try self.allocator.dupe(u8, load),
                .active_state = try self.allocator.dupe(u8, active),
                .sub_state = try self.allocator.dupe(u8, sub),
            });
        }

        return units.toOwnedSlice();
    }

    /// Stop a service
    pub fn stopService(self: *Self, name: []const u8) !void {
        scoped_log.debug("Stopping service: {s}", .{name});

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "systemctl", "stop", name },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            scoped_log.warn("Failed to stop {s}: {s}", .{ name, result.stderr });
        }
    }

    /// Stop all services
    pub fn stopAllServices(self: *Self) !void {
        scoped_log.info("Stopping all services", .{});

        const units = try self.listActiveUnits();
        defer {
            for (units) |*u| {
                var unit = u.*;
                unit.deinit(self.allocator);
            }
            self.allocator.free(units);
        }

        for (units) |unit| {
            // Skip essential services
            if (isEssentialService(unit.name)) {
                scoped_log.debug("Skipping essential service: {s}", .{unit.name});
                continue;
            }

            self.stopService(unit.name) catch |err| {
                scoped_log.warn("Could not stop {s}: {}", .{ unit.name, err });
            };
        }
    }

    /// Wait for all jobs to complete
    pub fn waitForJobs(self: *Self, timeout_seconds: u32) !void {
        scoped_log.info("Waiting for systemd jobs (timeout: {}s)", .{timeout_seconds});

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{
                "systemctl",
                "is-system-running",
                "--wait",
            },
            .max_output_bytes = 4096,
        }) catch |err| {
            scoped_log.warn("is-system-running failed: {}", .{err});
            return;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
    }

    /// Get number of pending jobs
    pub fn getPendingJobCount(self: *Self) !u32 {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "systemctl", "list-jobs", "--no-legend" },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        var count: u32 = 0;
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        while (lines.next()) |line| {
            if (line.len > 0) count += 1;
        }

        return count;
    }

    /// Enter emergency mode
    pub fn enterEmergencyMode(self: *Self) !void {
        try self.isolate("emergency.target");
    }

    /// Enter rescue mode
    pub fn enterRescueMode(self: *Self) !void {
        try self.isolate("rescue.target");
    }

    /// Daemon reload
    pub fn daemonReload(self: *Self) !void {
        scoped_log.debug("Reloading systemd daemon", .{});

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "systemctl", "daemon-reload" },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
    }
};

/// systemd unit info
pub const Unit = struct {
    name: []const u8,
    load_state: []const u8,
    active_state: []const u8,
    sub_state: []const u8,

    pub fn deinit(self: *Unit, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.load_state);
        allocator.free(self.active_state);
        allocator.free(self.sub_state);
    }
};

/// Check if a service is essential and should not be stopped
fn isEssentialService(name: []const u8) bool {
    const essential = [_][]const u8{
        "systemd-journald.service",
        "systemd-udevd.service",
        "dbus.service",
        "polkit.service",
    };

    for (essential) |e| {
        if (std.mem.eql(u8, name, e)) return true;
    }

    // Also keep anything with -generator or essential in the name
    if (std.mem.indexOf(u8, name, "generator") != null) return true;

    return false;
}

/// Check if systemd is available
pub fn isAvailable() bool {
    std.fs.accessAbsolute("/run/systemd/system", .{}) catch return false;
    return true;
}

/// Get systemd version
pub fn getVersion(allocator: std.mem.Allocator) ![]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "systemctl", "--version" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    // Parse "systemd 252"
    const first_line_end = std.mem.indexOf(u8, result.stdout, "\n") orelse result.stdout.len;
    var parts = std.mem.tokenizeScalar(u8, result.stdout[0..first_line_end], ' ');
    _ = parts.next(); // "systemd"

    if (parts.next()) |version| {
        return allocator.dupe(u8, version);
    }

    return error.VersionNotFound;
}

test "essential service detection" {
    const testing = std.testing;

    try testing.expect(isEssentialService("systemd-journald.service"));
    try testing.expect(isEssentialService("dbus.service"));
    try testing.expect(!isEssentialService("nginx.service"));
    try testing.expect(!isEssentialService("apache2.service"));
}

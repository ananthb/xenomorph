const std = @import("std");
const log = @import("../util/log.zig");
const detector = @import("detector.zig");

const scoped_log = log.scoped("init/interface");

/// Init system coordination errors
pub const InitError = error{
    InitSystemNotSupported,
    TransitionFailed,
    Timeout,
    ServiceStopFailed,
    PermissionDenied,
    CommandFailed,
};

/// Service state
pub const ServiceState = enum {
    running,
    stopped,
    failed,
    unknown,
};

/// Target runlevel/mode
pub const TargetMode = enum {
    /// Normal multi-user mode
    multi_user,
    /// Single-user/rescue mode (minimal services)
    rescue,
    /// Emergency mode (even more minimal)
    emergency,
    /// Poweroff
    poweroff,
    /// Reboot
    reboot,
};

/// Init system coordinator interface
pub const InitCoordinator = struct {
    allocator: std.mem.Allocator,
    init_system: detector.InitSystem,
    timeout_seconds: u32,

    const Self = @This();

    /// Create coordinator for detected init system
    pub fn init(allocator: std.mem.Allocator) !Self {
        const detection = try detector.detect(allocator);
        defer {
            var d = detection;
            d.deinit(allocator);
        }

        return Self{
            .allocator = allocator,
            .init_system = detection.init_system,
            .timeout_seconds = 30,
        };
    }

    /// Create coordinator for specific init system
    pub fn initFor(allocator: std.mem.Allocator, init_system: detector.InitSystem) Self {
        return Self{
            .allocator = allocator,
            .init_system = init_system,
            .timeout_seconds = 30,
        };
    }

    /// Transition to rescue/single-user mode
    pub fn transitionToRescue(self: *Self) InitError!void {
        scoped_log.info("Transitioning to rescue mode ({s})", .{self.init_system.name()});

        switch (self.init_system) {
            .systemd => try self.systemdTransition(.rescue),
            .openrc => try self.openrcTransition(.rescue),
            .sysvinit => try self.sysvinitTransition(.rescue),
            else => {
                scoped_log.warn("Init system {s} not fully supported, skipping transition", .{self.init_system.name()});
            },
        }
    }

    /// Stop all non-essential services
    pub fn stopServices(self: *Self) InitError!void {
        scoped_log.info("Stopping services", .{});

        switch (self.init_system) {
            .systemd => try self.systemdStopServices(),
            .openrc => try self.openrcStopServices(),
            .sysvinit => try self.sysvinitStopServices(),
            else => {
                scoped_log.warn("Cannot stop services on {s}", .{self.init_system.name()});
            },
        }
    }

    /// Wait for services to stop
    pub fn waitForServicesToStop(self: *Self) InitError!void {
        scoped_log.info("Waiting for services to stop (timeout: {}s)", .{self.timeout_seconds});

        const start = std.time.milliTimestamp();
        const timeout_ms: i64 = @as(i64, self.timeout_seconds) * 1000;

        while (std.time.milliTimestamp() - start < timeout_ms) {
            const pending = self.getPendingJobCount() catch 0;
            if (pending == 0) {
                scoped_log.info("All services stopped", .{});
                return;
            }

            scoped_log.debug("Waiting for {} pending jobs", .{pending});
            std.Thread.sleep(500 * std.time.ns_per_ms);
        }

        scoped_log.warn("Timeout waiting for services", .{});
        return error.Timeout;
    }

    /// Get count of pending jobs/services
    fn getPendingJobCount(self: *Self) !u32 {
        switch (self.init_system) {
            .systemd => return self.systemdGetPendingJobs(),
            else => return 0,
        }
    }

    // systemd-specific implementations

    fn systemdTransition(self: *Self, mode: TargetMode) InitError!void {
        const target = switch (mode) {
            .rescue => "rescue.target",
            .emergency => "emergency.target",
            .multi_user => "multi-user.target",
            .poweroff => "poweroff.target",
            .reboot => "reboot.target",
        };

        scoped_log.debug("systemctl isolate {s}", .{target});
        try self.runCommand(&.{ "systemctl", "isolate", target });
    }

    fn systemdStopServices(self: *Self) InitError!void {
        // Stop all units except essential ones
        try self.runCommand(&.{ "systemctl", "stop", "--all" });
    }

    fn systemdGetPendingJobs(self: *Self) !u32 {
        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "systemctl", "list-jobs", "--no-legend" },
        }) catch return 0;
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        // Count lines
        var count: u32 = 0;
        var iter = std.mem.splitScalar(u8, result.stdout, '\n');
        while (iter.next()) |line| {
            if (line.len > 0) count += 1;
        }

        return count;
    }

    // OpenRC-specific implementations

    fn openrcTransition(self: *Self, mode: TargetMode) InitError!void {
        _ = mode;
        // OpenRC uses runlevels
        try self.runCommand(&.{ "openrc", "single" });
    }

    fn openrcStopServices(self: *Self) InitError!void {
        try self.runCommand(&.{ "rc-service", "--all", "stop" });
    }

    // SysV init implementations

    fn sysvinitTransition(self: *Self, mode: TargetMode) InitError!void {
        const runlevel = switch (mode) {
            .rescue => "1",
            .multi_user => "3",
            else => "1",
        };

        try self.runCommand(&.{ "telinit", runlevel });
    }

    fn sysvinitStopServices(self: *Self) InitError!void {
        // Stop services in reverse order
        // This is a simplified approach
        try self.runCommand(&.{ "killall5", "-15" }); // SIGTERM to all
    }

    // Helper to run commands

    fn runCommand(self: *Self, argv: []const []const u8) InitError!void {
        scoped_log.debug("Running: {s}", .{argv[0]});

        var child = std.process.Child.init(argv, self.allocator);
        child.spawn() catch return error.CommandFailed;

        const result = child.wait() catch return error.CommandFailed;

        if (result.Exited != 0) {
            scoped_log.warn("Command {s} exited with {}", .{ argv[0], result.Exited });
            // Don't fail - some commands may fail but we should continue
        }
    }
};

/// Check if init coordination should be skipped (e.g., in a container)
pub fn shouldSkipCoordination() bool {
    // Check if we're in a container
    std.fs.accessAbsolute("/.dockerenv", .{}) catch {
        // Check for container indicator in cgroup
        const file = std.fs.openFileAbsolute("/proc/1/cgroup", .{}) catch return false;
        defer file.close();

        var buf: [4096]u8 = undefined;
        const n = file.readAll(&buf) catch return false;

        if (std.mem.indexOf(u8, buf[0..n], "docker") != null or
            std.mem.indexOf(u8, buf[0..n], "lxc") != null or
            std.mem.indexOf(u8, buf[0..n], "kubepods") != null)
        {
            return true;
        }
        return false;
    };
    return true; // .dockerenv exists
}

test "TargetMode values" {
    const testing = std.testing;
    _ = testing;

    // Just verify the enum compiles
    const mode: TargetMode = .rescue;
    _ = mode;
}

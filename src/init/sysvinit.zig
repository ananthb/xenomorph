const std = @import("std");
const log = @import("../util/log.zig");

const scoped_log = log.scoped("init/sysvinit");

/// SysV init specific operations
pub const SysvinitController = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    /// Change runlevel using telinit
    pub fn changeRunlevel(self: *Self, runlevel: u8) !void {
        scoped_log.info("Changing to runlevel {c}", .{runlevel});

        const runlevel_str = [_]u8{runlevel};

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "telinit", &runlevel_str },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            scoped_log.err("telinit failed: {s}", .{result.stderr});
            return error.CommandFailed;
        }
    }

    /// Get current runlevel
    pub fn getCurrentRunlevel(self: *Self) !struct { previous: u8, current: u8 } {
        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{"runlevel"},
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        // Output format: "N 5" (previous current)
        const trimmed = std.mem.trim(u8, result.stdout, " \n\r\t");
        var parts = std.mem.splitScalar(u8, trimmed, ' ');

        const prev_str = parts.next() orelse return error.ParseError;
        const curr_str = parts.next() orelse return error.ParseError;

        return .{
            .previous = if (prev_str.len > 0 and prev_str[0] != 'N') prev_str[0] else '0',
            .current = if (curr_str.len > 0) curr_str[0] else '0',
        };
    }

    /// Stop a SysV service
    pub fn stopService(self: *Self, name: []const u8) !void {
        scoped_log.debug("Stopping service: {s}", .{name});

        // Try /etc/init.d/service stop
        const script_path = try std.fmt.allocPrint(self.allocator, "/etc/init.d/{s}", .{name});
        defer self.allocator.free(script_path);

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ script_path, "stop" },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            scoped_log.warn("Failed to stop {s}", .{name});
        }
    }

    /// Start a SysV service
    pub fn startService(self: *Self, name: []const u8) !void {
        scoped_log.debug("Starting service: {s}", .{name});

        const script_path = try std.fmt.allocPrint(self.allocator, "/etc/init.d/{s}", .{name});
        defer self.allocator.free(script_path);

        const result = try std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ script_path, "start" },
        });
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        if (result.term.Exited != 0) {
            scoped_log.warn("Failed to start {s}", .{name});
        }
    }

    /// List init scripts
    pub fn listServices(self: *Self) ![]const []const u8 {
        var services = std.ArrayList([]const u8).init(self.allocator);
        errdefer {
            for (services.items) |s| self.allocator.free(s);
            services.deinit();
        }

        var dir = std.fs.openDirAbsolute("/etc/init.d", .{ .iterate = true }) catch {
            return services.toOwnedSlice();
        };
        defer dir.close();

        var iter = dir.iterate();
        while (iter.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.startsWith(u8, entry.name, ".")) continue;
            if (std.mem.eql(u8, entry.name, "README")) continue;

            try services.append(try self.allocator.dupe(u8, entry.name));
        }

        return services.toOwnedSlice();
    }

    /// Enter single user mode
    pub fn enterSingleUser(self: *Self) !void {
        try self.changeRunlevel('1');
    }

    /// Kill all processes except essential ones
    pub fn killAllProcesses(self: *Self, signal: u32) !void {
        scoped_log.info("Sending signal {} to all processes", .{signal});

        const sig_str = try std.fmt.allocPrint(self.allocator, "-{}", .{signal});
        defer self.allocator.free(sig_str);

        const result = std.process.Child.run(.{
            .allocator = self.allocator,
            .argv = &.{ "killall5", sig_str },
        }) catch {
            scoped_log.warn("killall5 not available, using manual kill", .{});
            return;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);
    }

    /// Sync filesystems
    pub fn sync(self: *Self) !void {
        _ = self;
        scoped_log.debug("Syncing filesystems", .{});

        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &.{"sync"},
        }) catch return;
        std.heap.page_allocator.free(result.stdout);
        std.heap.page_allocator.free(result.stderr);
    }
};

/// Runlevel definitions
pub const Runlevel = struct {
    pub const halt: u8 = '0';
    pub const single_user: u8 = '1';
    pub const multi_user_no_network: u8 = '2';
    pub const multi_user: u8 = '3';
    pub const unused: u8 = '4';
    pub const graphical: u8 = '5';
    pub const reboot: u8 = '6';
    pub const emergency: u8 = 's';
};

/// Check if SysV init is available
pub fn isAvailable() bool {
    std.fs.accessAbsolute("/sbin/init", .{}) catch return false;

    // Make sure it's not systemd or another init pretending
    std.fs.accessAbsolute("/run/systemd/system", .{}) catch {
        return true; // No systemd marker, likely SysV
    };
    return false;
}

/// Essential services that should not be stopped
const essential_services = [_][]const u8{
    "rcS",
    "rc",
    "single",
    "killall",
    "halt",
    "reboot",
    "sendsigs",
    "umountfs",
    "umountroot",
};

/// Check if a service is essential
pub fn isEssentialService(name: []const u8) bool {
    for (essential_services) |e| {
        if (std.mem.eql(u8, name, e)) return true;
    }
    return false;
}

test "runlevel definitions" {
    const testing = std.testing;

    try testing.expectEqual(@as(u8, '0'), Runlevel.halt);
    try testing.expectEqual(@as(u8, '1'), Runlevel.single_user);
    try testing.expectEqual(@as(u8, '6'), Runlevel.reboot);
}

const std = @import("std");
const log = @import("../util/log.zig");
const scanner = @import("scanner.zig");

const scoped_log = log.scoped("process/essential");

/// Categories of essential processes
pub const Category = enum {
    kernel,
    init,
    self,
    device,
    logging,
    network,
    storage,
    other,
};

/// Essential process definitions by name
const essential_by_name = [_]struct { name: []const u8, category: Category }{
    // Kernel threads (usually in brackets)
    .{ .name = "kthreadd", .category = .kernel },
    .{ .name = "ksoftirqd", .category = .kernel },
    .{ .name = "kworker", .category = .kernel },
    .{ .name = "migration", .category = .kernel },
    .{ .name = "watchdog", .category = .kernel },
    .{ .name = "kcompactd", .category = .kernel },
    .{ .name = "khugepaged", .category = .kernel },
    .{ .name = "kswapd", .category = .kernel },
    .{ .name = "kblockd", .category = .kernel },

    // Init systems
    .{ .name = "systemd", .category = .init },
    .{ .name = "init", .category = .init },
    .{ .name = "openrc", .category = .init },
    .{ .name = "runit", .category = .init },
    .{ .name = "s6-svscan", .category = .init },

    // Device management
    .{ .name = "udevd", .category = .device },
    .{ .name = "systemd-udevd", .category = .device },
    .{ .name = "eudev", .category = .device },
    .{ .name = "mdev", .category = .device },

    // Logging
    .{ .name = "journald", .category = .logging },
    .{ .name = "systemd-journald", .category = .logging },
    .{ .name = "rsyslogd", .category = .logging },
    .{ .name = "syslog-ng", .category = .logging },

    // Networking (sometimes needed)
    .{ .name = "dhclient", .category = .network },
    .{ .name = "dhcpcd", .category = .network },
    .{ .name = "NetworkManager", .category = .network },
    .{ .name = "wpa_supplicant", .category = .network },

    // Storage
    .{ .name = "lvmetad", .category = .storage },
    .{ .name = "multipathd", .category = .storage },
    .{ .name = "iscsid", .category = .storage },
};

/// Check if a process is essential and should not be killed
pub fn isEssentialProcess(process: *const scanner.ProcessInfo) bool {
    // Always preserve PID 1
    if (process.pid == 1) return true;

    // Always preserve kernel threads
    if (process.isKernelThread()) return true;

    // Check if it's ourselves
    if (process.pid == std.os.linux.getpid()) return true;

    // Check against known essential names
    for (essential_by_name) |entry| {
        if (std.mem.eql(u8, process.comm, entry.name)) {
            return true;
        }
        // Also check for partial matches (e.g., "kworker/0:0")
        if (std.mem.startsWith(u8, process.comm, entry.name)) {
            return true;
        }
    }

    // Check for bracketed kernel thread names
    if (process.comm.len > 0 and process.comm[0] == '[') {
        return true;
    }

    return false;
}

/// Get the category of an essential process
pub fn getEssentialCategory(process: *const scanner.ProcessInfo) ?Category {
    if (process.pid == 1) return .init;
    if (process.isKernelThread()) return .kernel;
    if (process.pid == std.os.linux.getpid()) return .self;

    for (essential_by_name) |entry| {
        if (std.mem.eql(u8, process.comm, entry.name) or
            std.mem.startsWith(u8, process.comm, entry.name))
        {
            return entry.category;
        }
    }

    return null;
}

/// Check if a PID is essential
pub fn isEssentialPid(pid: i32, allocator: std.mem.Allocator) bool {
    // Always preserve special PIDs
    if (pid == 1 or pid == 2) return true;
    if (pid == std.os.linux.getpid()) return true;

    // Get process info and check
    const info = scanner.getProcessInfo(allocator, pid) catch return false;
    defer {
        var p = info;
        p.deinit(allocator);
    }

    return isEssentialProcess(&info);
}

/// Get list of essential PIDs on the system
pub fn getEssentialPids(allocator: std.mem.Allocator) ![]const i32 {
    const all_processes = try scanner.scanProcesses(allocator);
    defer {
        for (all_processes) |*p| {
            var proc = p.*;
            proc.deinit(allocator);
        }
        allocator.free(all_processes);
    }

    var essential_pids: std.ArrayListUnmanaged(i32) = .{};
    errdefer essential_pids.deinit(allocator);

    for (all_processes) |p| {
        if (isEssentialProcess(&p)) {
            try essential_pids.append(allocator, p.pid);
        }
    }

    return essential_pids.toOwnedSlice(allocator);
}

/// Get count of non-essential processes
pub fn getNonEssentialCount(allocator: std.mem.Allocator) !u32 {
    const all_processes = try scanner.scanProcesses(allocator);
    defer {
        for (all_processes) |*p| {
            var proc = p.*;
            proc.deinit(allocator);
        }
        allocator.free(all_processes);
    }

    var count: u32 = 0;
    for (all_processes) |p| {
        if (!isEssentialProcess(&p)) {
            count += 1;
        }
    }

    return count;
}

/// Check if a name matches an essential process pattern
pub fn isEssentialName(name: []const u8) bool {
    for (essential_by_name) |entry| {
        if (std.mem.eql(u8, name, entry.name) or
            std.mem.startsWith(u8, name, entry.name))
        {
            return true;
        }
    }
    return false;
}

test "essential process detection" {
    const testing = std.testing;

    try testing.expect(isEssentialName("systemd"));
    try testing.expect(isEssentialName("kworker"));
    try testing.expect(isEssentialName("systemd-journald"));
    try testing.expect(!isEssentialName("nginx"));
    try testing.expect(!isEssentialName("apache2"));
}

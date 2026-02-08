const std = @import("std");
const log = @import("../util/log.zig");
const syscall = @import("../util/syscall.zig");
const scanner = @import("scanner.zig");
const essential = @import("essential.zig");

const scoped_log = log.scoped("process/terminator");

/// Termination options
pub const TerminateOptions = struct {
    /// Timeout for graceful termination (SIGTERM) in milliseconds
    graceful_timeout_ms: u32 = 5000,

    /// Timeout for forceful termination (SIGKILL) in milliseconds
    forceful_timeout_ms: u32 = 2000,

    /// Skip essential processes
    skip_essential: bool = true,

    /// PIDs to explicitly exclude
    exclude_pids: []const i32 = &.{},
};

/// Result of termination
pub const TerminateResult = struct {
    /// Number of processes terminated
    terminated_count: u32,

    /// Number of processes that required SIGKILL
    killed_count: u32,

    /// PIDs that could not be terminated
    stubborn_pids: []const i32,

    /// Any errors encountered
    errors: []const []const u8,

    pub fn deinit(self: *TerminateResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stubborn_pids);
        for (self.errors) |e| allocator.free(e);
        allocator.free(self.errors);
    }
};

/// Terminate all non-essential processes
pub fn terminateAll(allocator: std.mem.Allocator, options: TerminateOptions) !TerminateResult {
    scoped_log.info("Terminating all non-essential processes", .{});

    // Scan for processes
    const all_processes = try scanner.scanProcesses(allocator);
    defer {
        for (all_processes) |*p| {
            var proc = p.*;
            proc.deinit(allocator);
        }
        allocator.free(all_processes);
    }

    // Filter to user processes
    var pids_to_kill: std.ArrayListUnmanaged(i32) = .{};
    defer pids_to_kill.deinit(allocator);

    const self_pid = std.os.linux.getpid();
    const parent_pid = std.os.linux.getppid();

    for (all_processes) |p| {
        // Skip kernel threads
        if (p.isKernelThread()) continue;

        // Skip init
        if (p.pid == 1) continue;

        // Skip self and parent
        if (p.pid == self_pid or p.pid == parent_pid) continue;

        // Check exclusion list
        var excluded = false;
        for (options.exclude_pids) |exclude_pid| {
            if (p.pid == exclude_pid) {
                excluded = true;
                break;
            }
        }
        if (excluded) continue;

        // Check if essential
        if (options.skip_essential and essential.isEssentialProcess(&p)) {
            scoped_log.debug("Skipping essential process: {} ({s})", .{ p.pid, p.comm });
            continue;
        }

        try pids_to_kill.append(allocator, p.pid);
    }

    scoped_log.info("Terminating {} processes", .{pids_to_kill.items.len});

    // Send SIGTERM to all
    var terminated: u32 = 0;
    for (pids_to_kill.items) |pid| {
        scoped_log.debug("Sending SIGTERM to {}", .{pid});
        syscall.kill(pid, syscall.Signal.SIGTERM) catch |err| {
            scoped_log.debug("Cannot send SIGTERM to {}: {}", .{ pid, err });
        };
    }

    // Wait for graceful termination
    const grace_start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - grace_start < options.graceful_timeout_ms) {
        var still_running: u32 = 0;
        for (pids_to_kill.items) |pid| {
            if (scanner.isProcessRunning(pid)) {
                still_running += 1;
            } else {
                terminated += 1;
            }
        }

        if (still_running == 0) break;

        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    // Find processes that didn't terminate gracefully
    var stubborn: std.ArrayListUnmanaged(i32) = .{};
    errdefer stubborn.deinit(allocator);

    var killed: u32 = 0;
    for (pids_to_kill.items) |pid| {
        if (!scanner.isProcessRunning(pid)) continue;

        scoped_log.debug("Sending SIGKILL to {}", .{pid});
        syscall.kill(pid, syscall.Signal.SIGKILL) catch {};
        killed += 1;
    }

    // Wait for SIGKILL to take effect
    if (killed > 0) {
        std.Thread.sleep(@as(u64, options.forceful_timeout_ms) * std.time.ns_per_ms);

        // Check for truly stubborn processes
        for (pids_to_kill.items) |pid| {
            if (scanner.isProcessRunning(pid)) {
                try stubborn.append(allocator, pid);
            }
        }
    }

    if (stubborn.items.len > 0) {
        scoped_log.warn("{} processes could not be terminated", .{stubborn.items.len});
    }

    return TerminateResult{
        .terminated_count = terminated + killed,
        .killed_count = killed,
        .stubborn_pids = try stubborn.toOwnedSlice(allocator),
        .errors = &.{},
    };
}

/// Terminate a specific process
pub fn terminateProcess(pid: i32, options: TerminateOptions) !bool {
    scoped_log.debug("Terminating process {}", .{pid});

    // Check if process exists
    if (!scanner.isProcessRunning(pid)) {
        return true; // Already dead
    }

    // Send SIGTERM
    syscall.kill(pid, syscall.Signal.SIGTERM) catch |err| {
        scoped_log.warn("Cannot send SIGTERM to {}: {}", .{ pid, err });
        return false;
    };

    // Wait for graceful termination
    const grace_start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - grace_start < options.graceful_timeout_ms) {
        if (!scanner.isProcessRunning(pid)) return true;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    // Send SIGKILL
    scoped_log.debug("Sending SIGKILL to {}", .{pid});
    syscall.kill(pid, syscall.Signal.SIGKILL) catch {};

    // Wait for SIGKILL
    std.Thread.sleep(@as(u64, options.forceful_timeout_ms) * std.time.ns_per_ms);

    return !scanner.isProcessRunning(pid);
}

/// Send signal to all processes matching a name
pub fn killByName(allocator: std.mem.Allocator, name: []const u8, signal: u32) !u32 {
    scoped_log.debug("Killing all processes named '{s}' with signal {}", .{ name, signal });

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
        if (std.mem.eql(u8, p.comm, name)) {
            syscall.kill(p.pid, signal) catch continue;
            count += 1;
        }
    }

    return count;
}

test "TerminateOptions defaults" {
    const opts = TerminateOptions{};

    const testing = std.testing;
    try testing.expectEqual(@as(u32, 5000), opts.graceful_timeout_ms);
    try testing.expectEqual(@as(u32, 2000), opts.forceful_timeout_ms);
    try testing.expect(opts.skip_essential);
}

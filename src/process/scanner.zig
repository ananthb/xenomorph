const std = @import("std");
const log = @import("../util/log.zig");
const runz = @import("runz");
const process = runz.linux_util.process;

const scoped_log = log.scoped("process/scanner");

/// Re-export ProcessInfo from runz
pub const ProcessInfo = process.ProcessInfo;

/// Scan all processes in the system
pub fn scanProcesses(allocator: std.mem.Allocator) ![]ProcessInfo {
    return process.scanProcesses(allocator);
}

/// Get information about a specific process
pub fn getProcessInfo(allocator: std.mem.Allocator, pid: i32) !ProcessInfo {
    return process.getProcessInfo(allocator, pid);
}

/// Filter processes to find user processes (non-kernel, non-init)
pub fn filterUserProcesses(allocator: std.mem.Allocator, processes: []const ProcessInfo) ![]const ProcessInfo {
    var result: std.ArrayListUnmanaged(ProcessInfo) = .{};
    errdefer {
        for (result.items) |*p| p.deinit(allocator);
        result.deinit(allocator);
    }

    const self_pid = std.os.linux.getpid();

    for (processes) |p| {
        // Skip kernel threads
        if (p.isKernelThread()) continue;

        // Skip init
        if (p.pid == 1) continue;

        // Skip ourselves
        if (p.pid == self_pid) continue;

        // Create a copy with duplicated strings
        const copy = ProcessInfo{
            .pid = p.pid,
            .ppid = p.ppid,
            .comm = try allocator.dupe(u8, p.comm),
            .cmdline = try allocator.dupe(u8, p.cmdline),
            .state = p.state,
            .uid = p.uid,
            .gid = p.gid,
        };

        try result.append(allocator, copy);
    }

    return result.toOwnedSlice(allocator);
}

/// Get process count
pub fn getProcessCount() u32 {
    return process.getProcessCount();
}

/// Check if a process is still running
pub fn isProcessRunning(pid: i32) bool {
    return process.isProcessRunning(pid);
}

const std = @import("std");
const log = @import("../util/log.zig");

const scoped_log = log.scoped("process/scanner");

/// Process information
pub const ProcessInfo = struct {
    pid: i32,
    ppid: i32,
    comm: []const u8,
    cmdline: []const u8,
    state: u8,
    uid: u32,
    gid: u32,

    pub fn deinit(self: *ProcessInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.comm);
        allocator.free(self.cmdline);
    }

    /// Check if this is a kernel thread
    pub fn isKernelThread(self: *const ProcessInfo) bool {
        if (self.ppid == 0 or self.ppid == 2) return true;
        if (self.comm.len > 0 and self.comm[0] == '[') return true;
        return false;
    }

    /// Check if this is the current process
    pub fn isSelf(self: *const ProcessInfo) bool {
        return self.pid == std.os.linux.getpid();
    }

    /// Check if this is init (PID 1)
    pub fn isInit(self: *const ProcessInfo) bool {
        return self.pid == 1;
    }
};

/// Scan all processes in the system
pub fn scanProcesses(allocator: std.mem.Allocator) ![]ProcessInfo {
    scoped_log.debug("Scanning processes", .{});

    var processes: std.ArrayListUnmanaged(ProcessInfo) = .{};
    errdefer {
        for (processes.items) |*p| p.deinit(allocator);
        processes.deinit(allocator);
    }

    var proc_dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch {
        scoped_log.err("Cannot open /proc", .{});
        return error.ProcNotAvailable;
    };
    defer proc_dir.close();

    var iter = proc_dir.iterate();
    while (iter.next() catch null) |entry| {
        // Only process numeric directories (PIDs)
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;

        if (getProcessInfo(allocator, pid)) |info| {
            try processes.append(allocator, info);
        } else |_| {
            // Process may have exited, skip
        }
    }

    scoped_log.debug("Found {} processes", .{processes.items.len});
    return processes.toOwnedSlice(allocator);
}

/// Get information about a specific process
pub fn getProcessInfo(allocator: std.mem.Allocator, pid: i32) !ProcessInfo {
    var path_buf: [64]u8 = undefined;

    // Read /proc/PID/stat
    const stat_path = try std.fmt.bufPrint(&path_buf, "/proc/{}/stat", .{pid});
    const stat_content = try readProcFile(allocator, stat_path);
    defer allocator.free(stat_content);

    // Parse stat file
    const comm_start = std.mem.indexOf(u8, stat_content, "(") orelse return error.ParseError;
    const comm_end = std.mem.lastIndexOf(u8, stat_content, ")") orelse return error.ParseError;

    const comm = try allocator.dupe(u8, stat_content[comm_start + 1 .. comm_end]);
    errdefer allocator.free(comm);

    // Parse remaining fields after comm
    const after_comm = stat_content[comm_end + 2 ..];
    var fields = std.mem.tokenizeScalar(u8, after_comm, ' ');

    const state_str = fields.next() orelse return error.ParseError;
    const state = if (state_str.len > 0) state_str[0] else '?';

    const ppid_str = fields.next() orelse return error.ParseError;
    const ppid = try std.fmt.parseInt(i32, ppid_str, 10);

    // Read cmdline
    const cmdline_path = try std.fmt.bufPrint(&path_buf, "/proc/{}/cmdline", .{pid});
    const cmdline = readProcFile(allocator, cmdline_path) catch try allocator.dupe(u8, "");
    errdefer allocator.free(cmdline);

    // Replace null bytes with spaces in cmdline
    for (cmdline) |*c| {
        if (c.* == 0) c.* = ' ';
    }

    // Read status for uid/gid
    const status_path = try std.fmt.bufPrint(&path_buf, "/proc/{}/status", .{pid});
    var uid: u32 = 0;
    var gid: u32 = 0;

    if (readProcFile(allocator, status_path)) |status_content| {
        defer allocator.free(status_content);

        var lines = std.mem.splitScalar(u8, status_content, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "Uid:")) {
                var parts = std.mem.tokenizeScalar(u8, line[4..], '\t');
                if (parts.next()) |uid_str| {
                    uid = std.fmt.parseInt(u32, std.mem.trim(u8, uid_str, " "), 10) catch 0;
                }
            } else if (std.mem.startsWith(u8, line, "Gid:")) {
                var parts = std.mem.tokenizeScalar(u8, line[4..], '\t');
                if (parts.next()) |gid_str| {
                    gid = std.fmt.parseInt(u32, std.mem.trim(u8, gid_str, " "), 10) catch 0;
                }
            }
        }
    } else |_| {}

    return ProcessInfo{
        .pid = pid,
        .ppid = ppid,
        .comm = comm,
        .cmdline = cmdline,
        .state = state,
        .uid = uid,
        .gid = gid,
    };
}

/// Read a file from /proc
fn readProcFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = try file.readAll(&buf);

    return allocator.dupe(u8, buf[0..n]);
}

/// Filter processes to find user processes (non-kernel, non-init)
pub fn filterUserProcesses(allocator: std.mem.Allocator, processes: []const ProcessInfo) ![]const ProcessInfo {
    var result: std.ArrayListUnmanaged(ProcessInfo) = .{};
    errdefer result.deinit(allocator);

    const self_pid = std.os.linux.getpid();

    for (processes) |p| {
        // Skip kernel threads
        if (p.isKernelThread()) continue;

        // Skip init
        if (p.pid == 1) continue;

        // Skip ourselves and our parent chain
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
pub fn getProcessCount() !u32 {
    var count: u32 = 0;

    var proc_dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch {
        return 0;
    };
    defer proc_dir.close();

    var iter = proc_dir.iterate();
    while (iter.next() catch null) |entry| {
        _ = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        count += 1;
    }

    return count;
}

/// Check if a process is still running
pub fn isProcessRunning(pid: i32) bool {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{}", .{pid}) catch return false;

    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

test "ProcessInfo kernel thread detection" {
    const testing = std.testing;

    const allocator = testing.allocator;
    const comm = try allocator.dupe(u8, "[kthreadd]");
    defer allocator.free(comm);
    const cmdline = try allocator.dupe(u8, "");
    defer allocator.free(cmdline);

    const kernel_thread = ProcessInfo{
        .pid = 2,
        .ppid = 0,
        .comm = comm,
        .cmdline = cmdline,
        .state = 'S',
        .uid = 0,
        .gid = 0,
    };

    try testing.expect(kernel_thread.isKernelThread());
}

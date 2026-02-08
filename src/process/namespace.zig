const std = @import("std");
const log = @import("../util/log.zig");
const syscall = @import("../util/syscall.zig");

const scoped_log = log.scoped("process/namespace");

/// Namespace types
pub const NamespaceType = enum(u32) {
    mount = 0x00020000, // CLONE_NEWNS
    uts = 0x04000000, // CLONE_NEWUTS
    ipc = 0x08000000, // CLONE_NEWIPC
    user = 0x10000000, // CLONE_NEWUSER
    pid = 0x20000000, // CLONE_NEWPID
    network = 0x40000000, // CLONE_NEWNET
    cgroup = 0x02000000, // CLONE_NEWCGROUP

    pub fn toPath(self: NamespaceType) []const u8 {
        return switch (self) {
            .mount => "mnt",
            .uts => "uts",
            .ipc => "ipc",
            .user => "user",
            .pid => "pid",
            .network => "net",
            .cgroup => "cgroup",
        };
    }
};

/// Namespace information
pub const NamespaceInfo = struct {
    ns_type: NamespaceType,
    inode: u64,
    pid: i32,
};

/// Get namespace inode for a process
pub fn getNamespace(pid: i32, ns_type: NamespaceType) !u64 {
    var path_buf: [64]u8 = undefined;
    const ns_path = std.fmt.bufPrint(&path_buf, "/proc/{}/ns/{s}", .{ pid, ns_type.toPath() }) catch
        return error.PathTooLong;

    const file = std.fs.openFileAbsolute(ns_path, .{}) catch return error.NamespaceNotFound;
    defer file.close();

    const stat = file.stat() catch return error.StatFailed;
    return stat.inode;
}

/// Check if two processes share a namespace
pub fn shareNamespace(pid1: i32, pid2: i32, ns_type: NamespaceType) !bool {
    const ns1 = try getNamespace(pid1, ns_type);
    const ns2 = try getNamespace(pid2, ns_type);
    return ns1 == ns2;
}

/// Enter a process's namespace
pub fn enterNamespace(pid: i32, ns_type: NamespaceType) !void {
    var path_buf: [64]u8 = undefined;
    const ns_path = std.fmt.bufPrint(&path_buf, "/proc/{}/ns/{s}", .{ pid, ns_type.toPath() }) catch
        return error.PathTooLong;

    const file = std.fs.openFileAbsolute(ns_path, .{}) catch return error.NamespaceNotFound;
    defer file.close();

    // setns syscall
    const fd = file.handle;
    const result = std.os.linux.syscall2(.setns, @as(usize, @intCast(fd)), @intFromEnum(ns_type));
    if (std.os.linux.E.init(result) != .SUCCESS) {
        return error.SetNsFailed;
    }
}

/// Create new namespaces using unshare
pub fn unshareNamespaces(types: []const NamespaceType) !void {
    var flags: u32 = 0;
    for (types) |t| {
        flags |= @intFromEnum(t);
    }

    const result = std.os.linux.syscall1(.unshare, flags);
    if (std.os.linux.E.init(result) != .SUCCESS) {
        return error.UnshareFailed;
    }
}

/// Get all namespaces for a process
pub fn getAllNamespaces(allocator: std.mem.Allocator, pid: i32) ![]NamespaceInfo {
    var namespaces: std.ArrayListUnmanaged(NamespaceInfo) = .{};
    errdefer namespaces.deinit(allocator);

    const all_types = [_]NamespaceType{
        .mount, .uts, .ipc, .user, .pid, .network, .cgroup,
    };

    for (all_types) |ns_type| {
        if (getNamespace(pid, ns_type)) |inode| {
            try namespaces.append(allocator, .{
                .ns_type = ns_type,
                .inode = inode,
                .pid = pid,
            });
        } else |_| {}
    }

    return namespaces.toOwnedSlice(allocator);
}

/// Find all processes in the same namespace
pub fn findProcessesInNamespace(
    allocator: std.mem.Allocator,
    ns_type: NamespaceType,
    target_inode: u64,
) ![]i32 {
    var pids: std.ArrayListUnmanaged(i32) = .{};
    errdefer pids.deinit(allocator);

    var proc_dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch {
        return pids.toOwnedSlice(allocator);
    };
    defer proc_dir.close();

    var iter = proc_dir.iterate();
    while (iter.next() catch null) |entry| {
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;

        if (getNamespace(pid, ns_type)) |inode| {
            if (inode == target_inode) {
                try pids.append(allocator, pid);
            }
        } else |_| {}
    }

    return pids.toOwnedSlice(allocator);
}

/// Check if running in a container
pub fn inContainer() bool {
    // Check for container indicators

    // Docker/Podman
    if (std.fs.accessAbsolute("/.dockerenv", .{})) |_| {
        return true;
    } else |_| {}

    // LXC
    const cgroup_file = std.fs.openFileAbsolute("/proc/1/cgroup", .{}) catch return false;
    defer cgroup_file.close();

    var buf: [4096]u8 = undefined;
    const n = cgroup_file.readAll(&buf) catch return false;

    const content = buf[0..n];
    if (std.mem.indexOf(u8, content, "docker") != null) return true;
    if (std.mem.indexOf(u8, content, "lxc") != null) return true;
    if (std.mem.indexOf(u8, content, "kubepods") != null) return true;
    if (std.mem.indexOf(u8, content, "containerd") != null) return true;

    return false;
}

/// Create a new mount namespace (wrapper for convenience)
pub fn createMountNamespace() !void {
    try syscall.unshare(.{ .newns = true });
}

/// Create isolated environment with multiple namespaces
pub fn createIsolatedEnvironment() !void {
    try unshareNamespaces(&.{
        .mount,
        .uts,
        .ipc,
    });
}

test "NamespaceType paths" {
    const testing = std.testing;

    try testing.expectEqualStrings("mnt", NamespaceType.mount.toPath());
    try testing.expectEqualStrings("net", NamespaceType.network.toPath());
    try testing.expectEqualStrings("pid", NamespaceType.pid.toPath());
}

test "container detection logic" {
    // Just verify the function compiles
    _ = inContainer();
}

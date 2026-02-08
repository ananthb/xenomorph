const std = @import("std");
const os = std.os;
const linux = std.os.linux;

pub const SyscallError = error{
    PermissionDenied,
    InvalidArgument,
    OutOfMemory,
    DeviceBusy,
    NotADirectory,
    IsADirectory,
    NoSuchFileOrDirectory,
    NotEmpty,
    ReadOnlyFilesystem,
    TooManySymlinks,
    NameTooLong,
    NoSpace,
    Unexpected,
};

/// Wrapper for the pivot_root syscall
/// new_root: path to new root filesystem
/// put_old: path where old root will be mounted (relative to new_root)
pub fn pivotRoot(new_root: [*:0]const u8, put_old: [*:0]const u8) SyscallError!void {
    const result = linux.syscall2(.pivot_root, @intFromPtr(new_root), @intFromPtr(put_old));
    return switch (linux.E.init(result)) {
        .SUCCESS => {},
        .PERM => error.PermissionDenied,
        .INVAL => error.InvalidArgument,
        .BUSY => error.DeviceBusy,
        .NOTDIR => error.NotADirectory,
        .NOENT => error.NoSuchFileOrDirectory,
        else => error.Unexpected,
    };
}

/// Unshare flags for namespace creation
pub const UnshareFlags = packed struct(u32) {
    vm: bool = false, // CLONE_VM
    fs: bool = false, // CLONE_FS
    files: bool = false, // CLONE_FILES
    sighand: bool = false, // CLONE_SIGHAND
    _reserved1: u4 = 0,
    ptrace: bool = false, // CLONE_PTRACE
    vfork: bool = false, // CLONE_VFORK
    parent: bool = false, // CLONE_PARENT
    thread: bool = false, // CLONE_THREAD
    newns: bool = false, // CLONE_NEWNS (mount namespace)
    sysvsem: bool = false, // CLONE_SYSVSEM
    settls: bool = false, // CLONE_SETTLS
    parent_settid: bool = false, // CLONE_PARENT_SETTID
    child_cleartid: bool = false, // CLONE_CHILD_CLEARTID
    detached: bool = false, // CLONE_DETACHED
    untraced: bool = false, // CLONE_UNTRACED
    child_settid: bool = false, // CLONE_CHILD_SETTID
    _reserved2: u2 = 0,
    newcgroup: bool = false, // CLONE_NEWCGROUP
    newuts: bool = false, // CLONE_NEWUTS
    newipc: bool = false, // CLONE_NEWIPC
    newuser: bool = false, // CLONE_NEWUSER
    newpid: bool = false, // CLONE_NEWPID
    newnet: bool = false, // CLONE_NEWNET
    io: bool = false, // CLONE_IO
    _reserved3: u3 = 0, // Padding to fill 32 bits
};

/// Unshare namespaces from parent process
pub fn unshare(flags: UnshareFlags) SyscallError!void {
    const result = linux.syscall1(.unshare, @as(u32, @bitCast(flags)));
    return switch (linux.E.init(result)) {
        .SUCCESS => {},
        .PERM => error.PermissionDenied,
        .INVAL => error.InvalidArgument,
        .NOMEM => error.OutOfMemory,
        .NOSPC => error.NoSpace,
        else => error.Unexpected,
    };
}

/// Mount flags matching Linux mount(2)
pub const MountFlags = packed struct(u32) {
    rdonly: bool = false, // MS_RDONLY
    nosuid: bool = false, // MS_NOSUID
    nodev: bool = false, // MS_NODEV
    noexec: bool = false, // MS_NOEXEC
    synchronous: bool = false, // MS_SYNCHRONOUS
    remount: bool = false, // MS_REMOUNT
    mandlock: bool = false, // MS_MANDLOCK
    dirsync: bool = false, // MS_DIRSYNC
    nosymfollow: bool = false, // MS_NOSYMFOLLOW
    noatime: bool = false, // MS_NOATIME
    nodiratime: bool = false, // MS_NODIRATIME
    bind: bool = false, // MS_BIND
    move: bool = false, // MS_MOVE
    rec: bool = false, // MS_REC
    silent: bool = false, // MS_SILENT
    posixacl: bool = false, // MS_POSIXACL
    unbindable: bool = false, // MS_UNBINDABLE
    private: bool = false, // MS_PRIVATE
    slave: bool = false, // MS_SLAVE
    shared: bool = false, // MS_SHARED
    relatime: bool = false, // MS_RELATIME
    kernmount: bool = false, // MS_KERNMOUNT
    i_version: bool = false, // MS_I_VERSION
    strictatime: bool = false, // MS_STRICTATIME
    lazytime: bool = false, // MS_LAZYTIME
    _reserved: u7 = 0,
};

/// Mount a filesystem
pub fn mount(
    source: ?[*:0]const u8,
    target: [*:0]const u8,
    fstype: ?[*:0]const u8,
    flags: MountFlags,
    data: ?[*]const u8,
) SyscallError!void {
    const result = linux.syscall5(
        .mount,
        if (source) |s| @intFromPtr(s) else 0,
        @intFromPtr(target),
        if (fstype) |f| @intFromPtr(f) else 0,
        @as(u32, @bitCast(flags)),
        if (data) |d| @intFromPtr(d) else 0,
    );
    return switch (linux.E.init(result)) {
        .SUCCESS => {},
        .PERM, .ACCES => error.PermissionDenied,
        .INVAL => error.InvalidArgument,
        .BUSY => error.DeviceBusy,
        .NOTDIR => error.NotADirectory,
        .NOENT => error.NoSuchFileOrDirectory,
        .NOMEM => error.OutOfMemory,
        .ROFS => error.ReadOnlyFilesystem,
        .LOOP => error.TooManySymlinks,
        .NAMETOOLONG => error.NameTooLong,
        else => error.Unexpected,
    };
}

/// Umount flags
pub const UmountFlags = packed struct(u32) {
    force: bool = false, // MNT_FORCE
    detach: bool = false, // MNT_DETACH
    expire: bool = false, // MNT_EXPIRE
    nofollow: bool = false, // UMOUNT_NOFOLLOW
    _reserved: u28 = 0,
};

/// Unmount a filesystem
pub fn umount(target: [*:0]const u8, flags: UmountFlags) SyscallError!void {
    const result = linux.syscall2(.umount2, @intFromPtr(target), @as(u32, @bitCast(flags)));
    return switch (linux.E.init(result)) {
        .SUCCESS => {},
        .PERM => error.PermissionDenied,
        .INVAL => error.InvalidArgument,
        .BUSY => error.DeviceBusy,
        .NOENT => error.NoSuchFileOrDirectory,
        else => error.Unexpected,
    };
}

/// Change root directory
pub fn chroot(path: [*:0]const u8) SyscallError!void {
    const result = linux.syscall1(.chroot, @intFromPtr(path));
    return switch (linux.E.init(result)) {
        .SUCCESS => {},
        .PERM, .ACCES => error.PermissionDenied,
        .NOTDIR => error.NotADirectory,
        .NOENT => error.NoSuchFileOrDirectory,
        .LOOP => error.TooManySymlinks,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.OutOfMemory,
        else => error.Unexpected,
    };
}

/// Change current working directory
pub fn chdir(path: [*:0]const u8) SyscallError!void {
    const result = linux.syscall1(.chdir, @intFromPtr(path));
    return switch (linux.E.init(result)) {
        .SUCCESS => {},
        .PERM, .ACCES => error.PermissionDenied,
        .NOTDIR => error.NotADirectory,
        .NOENT => error.NoSuchFileOrDirectory,
        .LOOP => error.TooManySymlinks,
        .NAMETOOLONG => error.NameTooLong,
        .NOMEM => error.OutOfMemory,
        else => error.Unexpected,
    };
}

/// Send a signal to a process
pub fn kill(pid: i32, sig: u32) SyscallError!void {
    const result = linux.syscall2(.kill, @as(u32, @bitCast(pid)), sig);
    return switch (linux.E.init(result)) {
        .SUCCESS => {},
        .PERM => error.PermissionDenied,
        .INVAL => error.InvalidArgument,
        .SRCH => error.NoSuchFileOrDirectory, // No such process
        else => error.Unexpected,
    };
}

/// Signal numbers
pub const Signal = struct {
    pub const SIGTERM: u32 = 15;
    pub const SIGKILL: u32 = 9;
    pub const SIGHUP: u32 = 1;
    pub const SIGINT: u32 = 2;
    pub const SIGQUIT: u32 = 3;
};

test "UnshareFlags layout" {
    const std_test = @import("std").testing;
    try std_test.expectEqual(@sizeOf(UnshareFlags), 4);
}

test "MountFlags layout" {
    const std_test = @import("std").testing;
    try std_test.expectEqual(@sizeOf(MountFlags), 4);
}

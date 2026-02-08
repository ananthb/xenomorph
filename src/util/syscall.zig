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

/// Clone flags for unshare (correct bit positions from Linux headers)
pub const CloneFlags = struct {
    pub const CLONE_VM: u32 = 0x00000100;
    pub const CLONE_FS: u32 = 0x00000200;
    pub const CLONE_FILES: u32 = 0x00000400;
    pub const CLONE_SIGHAND: u32 = 0x00000800;
    pub const CLONE_PTRACE: u32 = 0x00002000;
    pub const CLONE_VFORK: u32 = 0x00004000;
    pub const CLONE_PARENT: u32 = 0x00008000;
    pub const CLONE_THREAD: u32 = 0x00010000;
    pub const CLONE_NEWNS: u32 = 0x00020000;
    pub const CLONE_SYSVSEM: u32 = 0x00040000;
    pub const CLONE_SETTLS: u32 = 0x00080000;
    pub const CLONE_PARENT_SETTID: u32 = 0x00100000;
    pub const CLONE_CHILD_CLEARTID: u32 = 0x00200000;
    pub const CLONE_DETACHED: u32 = 0x00400000;
    pub const CLONE_UNTRACED: u32 = 0x00800000;
    pub const CLONE_CHILD_SETTID: u32 = 0x01000000;
    pub const CLONE_NEWCGROUP: u32 = 0x02000000;
    pub const CLONE_NEWUTS: u32 = 0x04000000;
    pub const CLONE_NEWIPC: u32 = 0x08000000;
    pub const CLONE_NEWUSER: u32 = 0x10000000;
    pub const CLONE_NEWPID: u32 = 0x20000000;
    pub const CLONE_NEWNET: u32 = 0x40000000;
    pub const CLONE_IO: u32 = 0x80000000;
};

/// Unshare flags (convenience struct that builds a u32)
pub const UnshareFlags = struct {
    newns: bool = false,
    newuts: bool = false,
    newipc: bool = false,
    newuser: bool = false,
    newpid: bool = false,
    newnet: bool = false,
    newcgroup: bool = false,

    pub fn toU32(self: UnshareFlags) u32 {
        var flags: u32 = 0;
        if (self.newns) flags |= CloneFlags.CLONE_NEWNS;
        if (self.newuts) flags |= CloneFlags.CLONE_NEWUTS;
        if (self.newipc) flags |= CloneFlags.CLONE_NEWIPC;
        if (self.newuser) flags |= CloneFlags.CLONE_NEWUSER;
        if (self.newpid) flags |= CloneFlags.CLONE_NEWPID;
        if (self.newnet) flags |= CloneFlags.CLONE_NEWNET;
        if (self.newcgroup) flags |= CloneFlags.CLONE_NEWCGROUP;
        return flags;
    }
};

/// Unshare namespaces from parent process
pub fn unshare(flags: UnshareFlags) SyscallError!void {
    const flag_value = flags.toU32();
    const result = linux.syscall1(.unshare, flag_value);
    const errno = linux.E.init(result);
    if (errno != .SUCCESS) {
        std.debug.print("unshare syscall failed: flags=0x{x}, result={}, errno={}\n", .{ flag_value, result, errno });
    }
    return switch (errno) {
        .SUCCESS => {},
        .PERM => error.PermissionDenied,
        .INVAL => error.InvalidArgument,
        .NOMEM => error.OutOfMemory,
        .NOSPC => error.NoSpace,
        else => error.Unexpected,
    };
}

/// Mount flag constants matching Linux mount(2) exactly
pub const MS_RDONLY: u32 = 1;
pub const MS_NOSUID: u32 = 2;
pub const MS_NODEV: u32 = 4;
pub const MS_NOEXEC: u32 = 8;
pub const MS_SYNCHRONOUS: u32 = 16;
pub const MS_REMOUNT: u32 = 32;
pub const MS_MANDLOCK: u32 = 64;
pub const MS_DIRSYNC: u32 = 128;
pub const MS_NOSYMFOLLOW: u32 = 256;
pub const MS_NOATIME: u32 = 1024;
pub const MS_NODIRATIME: u32 = 2048;
pub const MS_BIND: u32 = 4096;
pub const MS_MOVE: u32 = 8192;
pub const MS_REC: u32 = 16384;
pub const MS_SILENT: u32 = 32768;
pub const MS_POSIXACL: u32 = 1 << 16;
pub const MS_UNBINDABLE: u32 = 1 << 17;
pub const MS_PRIVATE: u32 = 1 << 18;
pub const MS_SLAVE: u32 = 1 << 19;
pub const MS_SHARED: u32 = 1 << 20;
pub const MS_RELATIME: u32 = 1 << 21;
pub const MS_KERNMOUNT: u32 = 1 << 22;
pub const MS_I_VERSION: u32 = 1 << 23;
pub const MS_STRICTATIME: u32 = 1 << 24;
pub const MS_LAZYTIME: u32 = 1 << 25;

/// Mount flags helper struct that builds a u32 with correct bit positions
pub const MountFlags = struct {
    rdonly: bool = false,
    nosuid: bool = false,
    nodev: bool = false,
    noexec: bool = false,
    synchronous: bool = false,
    remount: bool = false,
    mandlock: bool = false,
    dirsync: bool = false,
    nosymfollow: bool = false,
    noatime: bool = false,
    nodiratime: bool = false,
    bind: bool = false,
    move: bool = false,
    rec: bool = false,
    silent: bool = false,
    posixacl: bool = false,
    unbindable: bool = false,
    private: bool = false,
    slave: bool = false,
    shared: bool = false,
    relatime: bool = false,
    kernmount: bool = false,
    i_version: bool = false,
    strictatime: bool = false,
    lazytime: bool = false,

    pub fn toU32(self: MountFlags) u32 {
        var flags: u32 = 0;
        if (self.rdonly) flags |= MS_RDONLY;
        if (self.nosuid) flags |= MS_NOSUID;
        if (self.nodev) flags |= MS_NODEV;
        if (self.noexec) flags |= MS_NOEXEC;
        if (self.synchronous) flags |= MS_SYNCHRONOUS;
        if (self.remount) flags |= MS_REMOUNT;
        if (self.mandlock) flags |= MS_MANDLOCK;
        if (self.dirsync) flags |= MS_DIRSYNC;
        if (self.nosymfollow) flags |= MS_NOSYMFOLLOW;
        if (self.noatime) flags |= MS_NOATIME;
        if (self.nodiratime) flags |= MS_NODIRATIME;
        if (self.bind) flags |= MS_BIND;
        if (self.move) flags |= MS_MOVE;
        if (self.rec) flags |= MS_REC;
        if (self.silent) flags |= MS_SILENT;
        if (self.posixacl) flags |= MS_POSIXACL;
        if (self.unbindable) flags |= MS_UNBINDABLE;
        if (self.private) flags |= MS_PRIVATE;
        if (self.slave) flags |= MS_SLAVE;
        if (self.shared) flags |= MS_SHARED;
        if (self.relatime) flags |= MS_RELATIME;
        if (self.kernmount) flags |= MS_KERNMOUNT;
        if (self.i_version) flags |= MS_I_VERSION;
        if (self.strictatime) flags |= MS_STRICTATIME;
        if (self.lazytime) flags |= MS_LAZYTIME;
        return flags;
    }
};

/// Mount a filesystem
pub fn mount(
    source: ?[*:0]const u8,
    target: [*:0]const u8,
    fstype: ?[*:0]const u8,
    flags: MountFlags,
    data: ?[*]const u8,
) SyscallError!void {
    const flag_value = flags.toU32();
    const result = linux.syscall5(
        .mount,
        if (source) |s| @intFromPtr(s) else 0,
        @intFromPtr(target),
        if (fstype) |f| @intFromPtr(f) else 0,
        flag_value,
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

test "MountFlags toU32" {
    const std_test = @import("std").testing;

    // Test MS_PRIVATE | MS_REC
    const private_rec = MountFlags{ .private = true, .rec = true };
    try std_test.expectEqual(private_rec.toU32(), MS_PRIVATE | MS_REC);

    // Test MS_BIND
    const bind = MountFlags{ .bind = true };
    try std_test.expectEqual(bind.toU32(), MS_BIND);

    // Test MS_SHARED | MS_REC
    const shared_rec = MountFlags{ .shared = true, .rec = true };
    try std_test.expectEqual(shared_rec.toU32(), MS_SHARED | MS_REC);

    // Test MS_MOVE
    const move_flags = MountFlags{ .move = true };
    try std_test.expectEqual(move_flags.toU32(), MS_MOVE);
}

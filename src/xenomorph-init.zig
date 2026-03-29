const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

/// xenomorph-init: pre-entrypoint setup binary
/// Reads config from /etc/xenomorph-init.json, sets up services, then execs the entrypoint.
///
/// Config format:
/// {
///   "flush_firewall": true,
///   "ssh": { "port": 22, "password": "xxx", "authorized_keys": "ssh-ed25519 ..." },
///   "tailscale": { "authkey": "tskey-...", "args": "--ssh --hostname=..." },
///   "entrypoint": ["/bin/sh"],
///   "command": ["-c", "echo hello"]
/// }

const config_path = "/etc/xenomorph-init.json";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    // 0. Ensure essential device nodes exist
    ensureDeviceNodes();

    // Read config (optional — if missing, just supervise the entrypoint from argv)
    const config_file = std.fs.openFileAbsolute(config_path, .{}) catch {
        // No config — supervise argv directly
        forkAndSupervise(allocator, null, true);
        return;
    };
    defer config_file.close();

    const stat = try config_file.stat();
    const config_data = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(config_data);
    _ = try config_file.readAll(config_data);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, config_data, .{}) catch {
        forkAndSupervise(allocator, null, true);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value;

    // 1. Flush firewall
    if (getBool(root, "flush_firewall") orelse true) {
        flushFirewall(allocator);
    }

    // 2. SSH (dropbear)
    if (root.object.get("ssh")) |ssh| {
        setupSsh(allocator, ssh);
    }

    // 3. Set tailscale env vars (let the image's entrypoint handle tailscale)
    if (root.object.get("tailscale")) |ts| {
        setTailscaleEnv(ts);
    }

    // 4. Fork entrypoint and act as init (reap zombies, forward signals)
    const reboot_on_failure = getBool(root, "reboot_on_failure") orelse true;
    forkAndSupervise(allocator, root, reboot_on_failure);
}

/// Ensure essential device nodes exist after pivot.
/// The /dev bind mount should carry these over, but if not, create them.
fn ensureDeviceNodes() void {
    // Essential devices: (name, type, major, minor)
    const Device = struct { name: []const u8, major: u32, minor: u32 };
    const devices = [_]Device{
        .{ .name = "/dev/null", .major = 1, .minor = 3 },
        .{ .name = "/dev/zero", .major = 1, .minor = 5 },
        .{ .name = "/dev/random", .major = 1, .minor = 8 },
        .{ .name = "/dev/urandom", .major = 1, .minor = 9 },
        .{ .name = "/dev/tty", .major = 5, .minor = 0 },
    };

    for (devices) |dev| {
        std.fs.accessAbsolute(dev.name, .{}) catch {
            // Device doesn't exist, create it with mknod
            const path = std.posix.toPosixPath(dev.name) catch continue;
            const dev_num = (@as(u64, dev.major) << 8) | @as(u64, dev.minor);
            const rc = linux.syscall4(.mknodat, @bitCast(@as(isize, -100)), @intFromPtr(&path), linux.S.IFCHR | 0o666, dev_num);
            if (linux.E.init(rc) != .SUCCESS) {
                log("warning: cannot create {s}\n", .{dev.name});
            }
        };
    }

    // /dev/net/tun for VPN/WireGuard
    std.fs.accessAbsolute("/dev/net/tun", .{}) catch {
        std.fs.makeDirAbsolute("/dev/net") catch {};
        const path = std.posix.toPosixPath("/dev/net/tun") catch return;
        const tun_dev = (@as(u64, 10) << 8) | @as(u64, 200);
        const rc = linux.syscall4(.mknodat, @bitCast(@as(isize, -100)), @intFromPtr(&path), linux.S.IFCHR | 0o666, tun_dev);
        if (linux.E.init(rc) != .SUCCESS) {
            log("warning: cannot create /dev/net/tun\n", .{});
        }
    };
}

fn flushFirewall(allocator: std.mem.Allocator) void {
    // Try iptables
    for ([_][]const []const u8{
        &.{ "iptables", "-F" },
        &.{ "iptables", "-X" },
        &.{ "iptables", "-t", "nat", "-F" },
        &.{ "iptables", "-t", "mangle", "-F" },
        &.{ "ip6tables", "-F" },
        &.{ "ip6tables", "-X" },
    }) |argv| {
        runQuiet(allocator, argv);
    }

    // Try nftables
    runQuiet(allocator, &.{ "nft", "flush", "ruleset" });

    log("firewall rules flushed\n", .{});
}

fn setupSsh(allocator: std.mem.Allocator, ssh: std.json.Value) void {
    const port_val = ssh.object.get("port") orelse return;
    const port = switch (port_val) {
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}) catch return,
        else => return,
    };
    defer allocator.free(port);

    // Set password
    if (getString(ssh, "password")) |pw| {
        const chpasswd_input = std.fmt.allocPrint(allocator, "root:{s}\n", .{pw}) catch return;
        defer allocator.free(chpasswd_input);
        runWithStdin(allocator, &.{"chpasswd"}, chpasswd_input);
        log("SSH password set\n", .{});
    } else {
        // Generate random password
        var rand_buf: [8]u8 = undefined;
        const urandom = std.fs.openFileAbsolute("/dev/urandom", .{}) catch return;
        defer urandom.close();
        _ = urandom.readAll(&rand_buf) catch return;
        const pw = std.fmt.bytesToHex(rand_buf, .lower);
        const chpasswd_input = std.fmt.allocPrint(allocator, "root:{s}\n", .{&pw}) catch return;
        defer allocator.free(chpasswd_input);
        runWithStdin(allocator, &.{"chpasswd"}, chpasswd_input);
        log("SSH password: {s}\n", .{&pw});
    }

    // Install authorized keys
    if (getString(ssh, "authorized_keys")) |keys| {
        std.fs.makeDirAbsolute("/root/.ssh") catch {};
        const dir = std.fs.openDirAbsolute("/root/.ssh", .{}) catch return;
        var ak_dir = dir;
        defer ak_dir.close();
        var file = ak_dir.createFile("authorized_keys", .{}) catch return;
        defer file.close();
        file.writeAll(keys) catch {};
    }

    // Generate host keys
    std.fs.makeDirAbsolute("/etc/dropbear") catch {};
    for ([_]struct { key_type: []const u8, path: []const u8 }{
        .{ .key_type = "rsa", .path = "/etc/dropbear/dropbear_rsa_host_key" },
        .{ .key_type = "ed25519", .path = "/etc/dropbear/dropbear_ed25519_host_key" },
    }) |key| {
        std.fs.accessAbsolute(key.path, .{}) catch {
            runQuiet(allocator, &.{ "dropbearkey", "-t", key.key_type, "-f", key.path });
        };
    }

    // Start dropbear in background
    const bind_addr = std.fmt.allocPrint(allocator, "0.0.0.0:{s}", .{port}) catch return;
    defer allocator.free(bind_addr);
    spawnBackground(allocator, &.{ "dropbear", "-R", "-F", "-E", "-p", bind_addr });
    log("dropbear SSH listening on port {s}\n", .{port});
}

/// Set environment variables for the image's native tailscale entrypoint
/// (e.g. containerboot reads TS_AUTHKEY, TS_EXTRA_ARGS, etc.)
/// Set environment variables for the image's native tailscale entrypoint
/// (e.g. containerboot reads TS_AUTHKEY, TS_EXTRA_ARGS, etc.)
fn setTailscaleEnv(ts: std.json.Value) void {
    if (getString(ts, "authkey")) |authkey| {
        setEnv("TS_AUTHKEY", authkey);
        log("set TS_AUTHKEY\n", .{});
    }
    if (getString(ts, "args")) |args_str| {
        setEnv("TS_EXTRA_ARGS", args_str);
        log("set TS_EXTRA_ARGS={s}\n", .{args_str});
    }
    _ = @"setenv"("TS_STATE_DIR", "/var/lib/tailscale", 1);
    _ = @"setenv"("TS_SOCKET", "/var/run/tailscale/tailscaled.sock", 1);

    std.fs.makeDirAbsolute("/var/lib/tailscale") catch {};
    std.fs.makeDirAbsolute("/var/run/tailscale") catch {};
}

extern "c" fn @"setenv"(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

fn setEnv(key: [*:0]const u8, value: []const u8) void {
    var buf: [4096]u8 = undefined;
    if (value.len >= buf.len) return;
    @memcpy(buf[0..value.len], value);
    buf[value.len] = 0;
    const val_z: [*:0]const u8 = @ptrCast(buf[0..value.len :0]);
    _ = @"setenv"(key, val_z, 1);
}

/// Exec argv[1..] (the entrypoint passed after xenomorph-init)
/// Signal flag set by the signal handler
var got_signal: std.atomic.Value(u32) = std.atomic.Value(u32).init(0);

/// Fork the entrypoint, then act as init: forward signals and reap zombies.
/// This is equivalent to tini — ensures no zombie processes accumulate and
/// the entrypoint receives signals properly.
fn forkAndSupervise(allocator: std.mem.Allocator, config_root: ?std.json.Value, reboot_on_failure: bool) void {
    // Build argv from config entrypoint + command, or fall back to process args
    var argv_buf: std.ArrayListUnmanaged(?[*:0]const u8) = .{};

    var has_entrypoint = false;
    if (config_root) |cr| {
        if (cr.object.get("entrypoint")) |ep| {
            if (ep == .array) {
                for (ep.array.items) |item| {
                    if (item == .string) {
                        const z = allocator.dupeZ(u8, item.string) catch return;
                        argv_buf.append(allocator, z) catch return;
                        has_entrypoint = true;
                    }
                }
            }
        }
        if (cr.object.get("command")) |cmd| {
            if (cmd == .array) {
                for (cmd.array.items) |item| {
                    if (item == .string) {
                        const z = allocator.dupeZ(u8, item.string) catch return;
                        argv_buf.append(allocator, z) catch return;
                    }
                }
            }
        }
    }

    // Fall back to process argv if no entrypoint in config
    if (!has_entrypoint) {
        const args = std.process.argsAlloc(allocator) catch return;
        if (args.len <= 1) {
            log("error: no entrypoint specified\n", .{});
            std.process.exit(1);
        }
        for (args[1..]) |arg| {
            const z = allocator.dupeZ(u8, arg) catch return;
            argv_buf.append(allocator, z) catch return;
        }
    }

    if (argv_buf.items.len == 0) {
        log("error: no entrypoint specified\n", .{});
        std.process.exit(1);
    }

    argv_buf.append(allocator, null) catch return;

    // Install signal handler for forwarding
    const SA_RESTART = 0x10000000;
    var sa: linux.Sigaction = undefined;
    @memset(std.mem.asBytes(&sa), 0);
    sa.handler.handler = signalHandler;
    sa.flags = SA_RESTART;
    for ([_]u6{ linux.SIG.TERM, linux.SIG.INT, linux.SIG.HUP, linux.SIG.USR1, linux.SIG.USR2 }) |sig| {
        _ = linux.sigaction(sig, &sa, null);
    }

    // Fork (aarch64 lacks fork syscall, use clone with SIGCHLD)
    const pid = if (@hasField(linux.SYS, "fork"))
        linux.syscall0(.fork)
    else
        linux.syscall5(.clone, linux.SIG.CHLD, 0, 0, 0, 0);
    const fork_err = linux.E.init(pid);
    if (fork_err != .SUCCESS) {
        log("error: fork failed\n", .{});
        std.process.exit(1);
    }

    if (pid == 0) {
        // Child: exec entrypoint
        const cmd_z = argv_buf.items[0].?;
        const envp = std.c.environ;
        const err = std.posix.execveZ(cmd_z, @ptrCast(argv_buf.items.ptr), @ptrCast(envp));
        log("error: execve failed: {}\n", .{err});
        std.process.exit(127);
    }

    // Parent: act as init
    const child_pid: linux.pid_t = @bitCast(@as(u32, @truncate(pid)));
    log("init: supervising pid {d}\n", .{child_pid});

    while (true) {
        // Forward any pending signal to the child
        const sig = got_signal.swap(0, .seq_cst);
        if (sig != 0) {
            _ = linux.kill(child_pid, @bitCast(@as(u32, @truncate(sig))));
        }

        // Reap zombies (wait for any child, non-blocking)
        var status: u32 = 0;
        const waited_raw = linux.waitpid(-1, &status, linux.W.NOHANG);
        const wait_err = linux.E.init(waited_raw);

        if (wait_err == .CHILD) {
            // No more children — entrypoint exited
            break;
        }

        const waited: linux.pid_t = @bitCast(@as(u32, @truncate(waited_raw)));

        if (waited == child_pid) {
            // Our main child exited — reap remaining zombies then exit
            const exit_code: u8 = if (linux.W.IFEXITED(status))
                linux.W.EXITSTATUS(status)
            else if (linux.W.IFSIGNALED(status))
                @truncate(128 + linux.W.TERMSIG(status))
            else
                1;

            // Reap any remaining orphans
            while (true) {
                const r = linux.waitpid(-1, &status, linux.W.NOHANG);
                if (linux.E.init(r) == .CHILD) break;
                if (r == 0) break;
            }

            log("init: entrypoint exited with code {d}\n", .{exit_code});
            if (exit_code != 0 and reboot_on_failure) {
                reboot();
            }
            std.process.exit(exit_code);
        }

        if (waited_raw == 0) {
            // No child state change — sleep briefly
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }

    log("init: all children exited unexpectedly\n", .{});
    if (reboot_on_failure) {
        reboot();
    }
    std.process.exit(1);
}

/// Sync filesystems and reboot. Recovers the original OS since the
/// tmpfs rootfs is lost on reboot.
fn reboot() void {
    log("init: rebooting in 5 seconds (entrypoint failed)...\n", .{});
    std.Thread.sleep(5 * std.time.ns_per_s);

    // Sync all filesystems to flush logs
    _ = linux.syscall0(.sync);

    // reboot(LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2, LINUX_REBOOT_CMD_RESTART)
    const MAGIC1: usize = 0xfee1dead;
    const MAGIC2: usize = 672274793; // LINUX_REBOOT_MAGIC2
    const CMD_RESTART: usize = 0x01234567;
    _ = linux.syscall4(.reboot, MAGIC1, MAGIC2, CMD_RESTART, 0);

    // If reboot syscall fails, just exit
    log("init: reboot syscall failed\n", .{});
    std.process.exit(1);
}

fn signalHandler(sig: c_int) callconv(.c) void {
    got_signal.store(@intCast(@as(u32, @bitCast(sig))), .seq_cst);
}

// --- Helpers ---

fn log(comptime fmt: []const u8, args: anytype) void {
    const stderr = std.fs.File.stderr().deprecatedWriter();
    stderr.print("xenomorph-init: " ++ fmt, args) catch {};
}

fn getString(obj: std.json.Value, key: []const u8) ?[]const u8 {
    const val = obj.object.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn getBool(obj: std.json.Value, key: []const u8) ?bool {
    const val = obj.object.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

fn runQuiet(allocator: std.mem.Allocator, argv: []const []const u8) void {
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch return;
    _ = child.wait() catch return;
}

fn runWait(allocator: std.mem.Allocator, argv: []const []const u8) void {
    var child = std.process.Child.init(argv, allocator);
    child.spawn() catch return;
    _ = child.wait() catch return;
}

fn runWithStdin(allocator: std.mem.Allocator, argv: []const []const u8, stdin_data: []const u8) void {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.spawn() catch return;
    if (child.stdin) |stdin| {
        var s = stdin;
        s.writeAll(stdin_data) catch {};
        s.close();
        child.stdin = null;
    }
    _ = child.wait() catch return;
}

fn spawnBackground(allocator: std.mem.Allocator, argv: []const []const u8) void {
    var child = std.process.Child.init(argv, allocator);
    child.spawn() catch |err| {
        log("error: cannot spawn {s}: {}\n", .{ argv[0], err });
    };
    // Don't wait — leave it running in background
}

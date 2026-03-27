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

    // Read config
    const config_file = std.fs.openFileAbsolute(config_path, .{}) catch |err| {
        log("error: cannot open {s}: {}\n", .{ config_path, err });
        // No config — just exec argv
        execArgv();
        return;
    };
    defer config_file.close();

    const stat = try config_file.stat();
    const config_data = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(config_data);
    _ = try config_file.readAll(config_data);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, config_data, .{}) catch |err| {
        log("error: cannot parse config: {}\n", .{err});
        execArgv();
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

    // 3. Tailscale
    if (root.object.get("tailscale")) |ts| {
        setupTailscale(allocator, ts);
    }

    // 4. Exec entrypoint (from argv or config)
    execArgv();
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

fn setupTailscale(allocator: std.mem.Allocator, ts: std.json.Value) void {
    const authkey = getString(ts, "authkey") orelse return;
    const args_str = getString(ts, "args") orelse "--ssh";

    std.fs.makeDirAbsolute("/var/lib/tailscale") catch {};
    std.fs.makeDirAbsolute("/var/run/tailscale") catch {};

    // Start tailscaled in background
    spawnBackground(allocator, &.{
        "/usr/local/bin/tailscaled",
        "--state=/var/lib/tailscale/tailscaled.state",
        "--socket=/var/run/tailscale/tailscaled.sock",
    });

    // Wait for socket
    var i: u32 = 0;
    while (i < 50) : (i += 1) {
        std.fs.accessAbsolute("/var/run/tailscale/tailscaled.sock", .{}) catch {
            std.Thread.sleep(100 * std.time.ns_per_ms);
            continue;
        };
        break;
    }

    std.fs.accessAbsolute("/var/run/tailscale/tailscaled.sock", .{}) catch {
        log("warning: tailscaled failed to start\n", .{});
        return;
    };

    // Build tailscale up command
    const auth_arg = std.fmt.allocPrint(allocator, "--authkey={s}", .{authkey}) catch return;
    defer allocator.free(auth_arg);

    // Parse args_str into individual args
    var up_argv_buf: [20][]const u8 = undefined;
    var up_argc: usize = 0;
    up_argv_buf[up_argc] = "/usr/local/bin/tailscale";
    up_argc += 1;
    up_argv_buf[up_argc] = "--socket=/var/run/tailscale/tailscaled.sock";
    up_argc += 1;
    up_argv_buf[up_argc] = "up";
    up_argc += 1;
    up_argv_buf[up_argc] = auth_arg;
    up_argc += 1;

    // Split args_str on spaces
    var args_iter = std.mem.tokenizeScalar(u8, args_str, ' ');
    while (args_iter.next()) |arg| {
        if (up_argc < up_argv_buf.len) {
            up_argv_buf[up_argc] = arg;
            up_argc += 1;
        }
    }

    runWait(allocator, up_argv_buf[0..up_argc]);
    log("tailscale connected\n", .{});
}

/// Exec argv[1..] (the entrypoint passed after xenomorph-init)
fn execArgv() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();

    const args = std.process.argsAlloc(allocator) catch return;
    if (args.len <= 1) {
        log("error: no entrypoint specified\n", .{});
        std.process.exit(1);
    }

    // Build null-terminated argv
    var argv: std.ArrayListUnmanaged(?[*:0]const u8) = .{};
    for (args[1..]) |arg| {
        const z = allocator.dupeZ(u8, arg) catch return;
        argv.append(allocator, z) catch return;
    }
    argv.append(allocator, null) catch return;

    const cmd_z = allocator.dupeZ(u8, args[1]) catch return;
    const envp = std.c.environ;
    const err = std.posix.execveZ(cmd_z, @ptrCast(argv.items.ptr), @ptrCast(envp));
    log("error: execve failed: {}\n", .{err});
    std.process.exit(1);
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

const std = @import("std");
const log = @import("util/log.zig");

const scoped_log = log.scoped("initscript");

pub const InitScriptError = error{
    ScriptCreationFailed,
    OutOfMemory,
};

/// Configuration for the xenomorph init script that runs before the entrypoint.
pub const InitScriptConfig = struct {
    /// Flush iptables/nftables rules before starting services
    flush_firewall: bool = true,

    /// Dropbear SSH config (null = disabled)
    ssh: ?SshConfig = null,

    /// WireGuard config (null = disabled)
    wireguard: ?WireguardConfig = null,

    /// Tailscale config (null = disabled)
    tailscale: ?TailscaleConfig = null,

    /// Whether any service is configured
    pub fn hasServices(self: *const InitScriptConfig) bool {
        return self.ssh != null or self.wireguard != null or self.tailscale != null;
    }
};

pub const SshConfig = struct {
    port: u16 = 22,
    password: ?[]const u8 = null, // null = random (printed to log)
    keyfile_content: ?[]const u8 = null, // authorized_keys content
};

pub const WireguardConfig = struct {
    port: u16 = 51820,
    privkey: []const u8,
    peer_pubkey: []const u8,
    peer_endpoint: ?[]const u8 = null,
    allowed_ips: []const u8 = "0.0.0.0/0",
    address: []const u8 = "10.0.0.2/24",
};

pub const TailscaleConfig = struct {
    authkey: []const u8,
    args: []const u8,
};

/// Create the init script in the rootfs. Returns the script path inside the rootfs.
pub fn createInitScript(
    allocator: std.mem.Allocator,
    rootfs_path: []const u8,
    cfg: *const InitScriptConfig,
) InitScriptError!void {
    var script = std.ArrayListUnmanaged(u8){};
    defer script.deinit(allocator);

    // Header
    appendStr(&script, allocator,
        \\#!/bin/sh
        \\# Xenomorph init script — runs before the entrypoint
        \\set -e
        \\
    ) catch return error.OutOfMemory;

    // Firewall flush
    if (cfg.flush_firewall) {
        appendStr(&script, allocator,
            \\# Flush firewall rules
            \\if command -v iptables >/dev/null 2>&1; then
            \\  iptables -F 2>/dev/null || true
            \\  iptables -X 2>/dev/null || true
            \\  iptables -t nat -F 2>/dev/null || true
            \\  iptables -t mangle -F 2>/dev/null || true
            \\  ip6tables -F 2>/dev/null || true
            \\  ip6tables -X 2>/dev/null || true
            \\fi
            \\if command -v nft >/dev/null 2>&1; then
            \\  nft flush ruleset 2>/dev/null || true
            \\fi
            \\echo "xenomorph: firewall rules flushed" >&2
            \\
        ) catch return error.OutOfMemory;
    }

    // SSH (dropbear)
    if (cfg.ssh) |ssh| {
        // Set up password
        if (ssh.password) |pw| {
            const line = std.fmt.allocPrint(allocator,
                \\# Set root password
                \\echo "root:{s}" | chpasswd 2>/dev/null || true
                \\
            , .{pw}) catch return error.OutOfMemory;
            defer allocator.free(line);
            appendStr(&script, allocator, line) catch return error.OutOfMemory;
        } else {
            appendStr(&script, allocator,
                \\# Generate random root password
                \\XENOMORPH_SSH_PASS=$(head -c 16 /dev/urandom | od -A n -t x1 | tr -d ' \n' | head -c 16)
                \\echo "root:${XENOMORPH_SSH_PASS}" | chpasswd 2>/dev/null || true
                \\echo "xenomorph: SSH password: ${XENOMORPH_SSH_PASS}" >&2
                \\
            ) catch return error.OutOfMemory;
        }

        // Set up authorized keys
        if (ssh.keyfile_content) |keys| {
            const line = std.fmt.allocPrint(allocator,
                \\# Install SSH authorized keys
                \\mkdir -p /root/.ssh
                \\chmod 700 /root/.ssh
                \\cat > /root/.ssh/authorized_keys << 'XENOMORPH_KEYS_EOF'
                \\{s}
                \\XENOMORPH_KEYS_EOF
                \\chmod 600 /root/.ssh/authorized_keys
                \\
            , .{keys}) catch return error.OutOfMemory;
            defer allocator.free(line);
            appendStr(&script, allocator, line) catch return error.OutOfMemory;
        }

        // Start dropbear
        {
            const line = std.fmt.allocPrint(allocator,
                \\# Start dropbear SSH server
                \\mkdir -p /etc/dropbear
                \\if [ ! -f /etc/dropbear/dropbear_rsa_host_key ]; then
                \\  dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key 2>/dev/null
                \\fi
                \\if [ ! -f /etc/dropbear/dropbear_ed25519_host_key ]; then
                \\  dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key 2>/dev/null
                \\fi
                \\dropbear -R -F -E -p 0.0.0.0:{d} &
                \\echo "xenomorph: dropbear SSH listening on port {d}" >&2
                \\
            , .{ ssh.port, ssh.port }) catch return error.OutOfMemory;
            defer allocator.free(line);
            appendStr(&script, allocator, line) catch return error.OutOfMemory;
        }
    }

    // WireGuard
    if (cfg.wireguard) |wg| {
        const endpoint_line = if (wg.peer_endpoint) |ep|
            std.fmt.allocPrint(allocator, "wg set wg0 peer '{s}' endpoint '{s}' allowed-ips '{s}'\n", .{ wg.peer_pubkey, ep, wg.allowed_ips }) catch return error.OutOfMemory
        else
            std.fmt.allocPrint(allocator, "wg set wg0 peer '{s}' allowed-ips '{s}'\n", .{ wg.peer_pubkey, wg.allowed_ips }) catch return error.OutOfMemory;
        defer allocator.free(endpoint_line);

        const line = std.fmt.allocPrint(allocator,
            \\# Configure WireGuard
            \\ip link add wg0 type wireguard 2>/dev/null || true
            \\wg set wg0 private-key <(echo '{s}') listen-port {d}
            \\{s}ip addr add {s} dev wg0 2>/dev/null || true
            \\ip link set wg0 up
            \\echo "xenomorph: wireguard wg0 up on port {d}" >&2
            \\
        , .{ wg.privkey, wg.port, endpoint_line, wg.address, wg.port }) catch return error.OutOfMemory;
        defer allocator.free(line);
        appendStr(&script, allocator, line) catch return error.OutOfMemory;
    }

    // Tailscale
    if (cfg.tailscale) |ts| {
        const line = std.fmt.allocPrint(allocator,
            \\# Start Tailscale
            \\mkdir -p /var/lib/tailscale /var/run/tailscale
            \\/usr/local/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
            \\i=0
            \\while [ ! -S /var/run/tailscale/tailscaled.sock ] && [ "$i" -lt 50 ]; do
            \\  sleep 0.1
            \\  i=$((i+1))
            \\done
            \\if [ ! -S /var/run/tailscale/tailscaled.sock ]; then
            \\  echo "xenomorph: warning: tailscaled failed to start" >&2
            \\else
            \\  /usr/local/bin/tailscale --socket=/var/run/tailscale/tailscaled.sock up --authkey='{s}' {s}
            \\  echo "xenomorph: tailscale connected" >&2
            \\fi
            \\
        , .{ ts.authkey, ts.args }) catch return error.OutOfMemory;
        defer allocator.free(line);
        appendStr(&script, allocator, line) catch return error.OutOfMemory;
    }

    // Exec entrypoint
    appendStr(&script, allocator,
        \\# Exec the entrypoint
        \\exec "$@"
        \\
    ) catch return error.OutOfMemory;

    // Write the script
    const script_path = std.fmt.allocPrint(
        allocator,
        "{s}/usr/local/bin/xenomorph-init",
        .{rootfs_path},
    ) catch return error.OutOfMemory;
    defer allocator.free(script_path);

    {
        var dir = std.fs.openDirAbsolute(rootfs_path, .{}) catch return error.ScriptCreationFailed;
        defer dir.close();
        dir.makePath("usr/local/bin") catch return error.ScriptCreationFailed;
    }

    {
        const dir_path = std.fs.path.dirname(script_path) orelse "/";
        var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return error.ScriptCreationFailed;
        defer dir.close();
        var file = dir.createFile(std.fs.path.basename(script_path), .{}) catch return error.ScriptCreationFailed;
        defer file.close();
        file.writeAll(script.items) catch return error.ScriptCreationFailed;
    }

    // chmod +x
    var child = std.process.Child.init(&.{ "chmod", "+x", script_path }, allocator);
    child.spawn() catch return error.ScriptCreationFailed;
    const term = child.wait() catch return error.ScriptCreationFailed;
    switch (term) {
        .Exited => |code| {
            if (code != 0) return error.ScriptCreationFailed;
        },
        else => return error.ScriptCreationFailed,
    }

    scoped_log.info("Created init script at /usr/local/bin/xenomorph-init", .{});
}

fn appendStr(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try list.appendSlice(allocator, s);
}

pub const init_script_path = "/usr/local/bin/xenomorph-init";

test "InitScriptConfig hasServices" {
    const t = std.testing;

    try t.expect(!(InitScriptConfig{}).hasServices());
    try t.expect((InitScriptConfig{ .ssh = .{} }).hasServices());
    try t.expect((InitScriptConfig{ .tailscale = .{ .authkey = "x", .args = "" } }).hasServices());
}

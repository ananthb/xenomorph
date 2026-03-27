const std = @import("std");
const init_bin = @import("init_bin");
const log = @import("util/log.zig");

const scoped_log = log.scoped("initscript");

/// The embedded xenomorph-init binary, compiled at build time.
const init_binary = init_bin.data;

pub const InitScriptError = error{
    ScriptCreationFailed,
    OutOfMemory,
};

/// Configuration for the xenomorph init binary that runs before the entrypoint.
pub const InitScriptConfig = struct {
    /// Flush iptables/nftables rules before starting services
    flush_firewall: bool = true,

    /// Dropbear SSH config (null = disabled)
    ssh: ?SshConfig = null,

    /// Tailscale config (null = disabled)
    tailscale: ?TailscaleConfig = null,

    /// Whether any service is configured
    pub fn hasServices(self: *const InitScriptConfig) bool {
        return self.ssh != null or self.tailscale != null;
    }
};

pub const SshConfig = struct {
    port: u16 = 22,
    password: ?[]const u8 = null,
    keyfile_content: ?[]const u8 = null,
};

pub const TailscaleConfig = struct {
    authkey: []const u8,
    args: []const u8,
};

pub const init_script_path = "/usr/local/bin/xenomorph-init";
const config_path = "/etc/xenomorph-init.json";

/// Install the embedded init binary and write its JSON config into the rootfs.
pub fn createInitScript(
    allocator: std.mem.Allocator,
    rootfs_path: []const u8,
    cfg: *const InitScriptConfig,
) InitScriptError!void {
    // Ensure directories exist
    {
        var dir = std.fs.openDirAbsolute(rootfs_path, .{}) catch return error.ScriptCreationFailed;
        defer dir.close();
        dir.makePath("usr/local/bin") catch return error.ScriptCreationFailed;
        dir.makePath("etc") catch return error.ScriptCreationFailed;
    }

    // Write the embedded init binary
    const bin_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ rootfs_path, init_script_path }) catch
        return error.OutOfMemory;
    defer allocator.free(bin_path);

    {
        const dir_path = std.fs.path.dirname(bin_path) orelse "/";
        var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return error.ScriptCreationFailed;
        defer dir.close();
        var file = dir.createFile(std.fs.path.basename(bin_path), .{ .mode = 0o755 }) catch
            return error.ScriptCreationFailed;
        defer file.close();
        file.writeAll(init_binary) catch return error.ScriptCreationFailed;
    }

    // Write JSON config
    const config_json = buildConfigJson(allocator, cfg) catch return error.OutOfMemory;
    defer allocator.free(config_json);

    const json_path = std.fmt.allocPrint(allocator, "{s}{s}", .{ rootfs_path, config_path }) catch
        return error.OutOfMemory;
    defer allocator.free(json_path);

    {
        const dir_path = std.fs.path.dirname(json_path) orelse "/";
        var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return error.ScriptCreationFailed;
        defer dir.close();
        var file = dir.createFile(std.fs.path.basename(json_path), .{}) catch
            return error.ScriptCreationFailed;
        defer file.close();
        file.writeAll(config_json) catch return error.ScriptCreationFailed;
    }

    scoped_log.info("Installed xenomorph-init ({d} bytes) + config", .{init_binary.len});
}

fn buildConfigJson(allocator: std.mem.Allocator, cfg: *const InitScriptConfig) ![]const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (parts.items) |p| allocator.free(p);
        parts.deinit(allocator);
    }

    // flush_firewall
    try parts.append(allocator, try std.fmt.allocPrint(
        allocator,
        "\"flush_firewall\":{s}",
        .{if (cfg.flush_firewall) "true" else "false"},
    ));

    // SSH
    if (cfg.ssh) |ssh| {
        var ssh_parts: std.ArrayListUnmanaged([]const u8) = .{};
        defer {
            for (ssh_parts.items) |p| allocator.free(p);
            ssh_parts.deinit(allocator);
        }
        try ssh_parts.append(allocator, try std.fmt.allocPrint(allocator, "\"port\":{d}", .{ssh.port}));
        if (ssh.password) |pw| {
            try ssh_parts.append(allocator, try std.fmt.allocPrint(allocator, "\"password\":\"{s}\"", .{pw}));
        }
        if (ssh.keyfile_content) |keys| {
            try ssh_parts.append(allocator, try std.fmt.allocPrint(allocator, "\"authorized_keys\":\"{s}\"", .{keys}));
        }
        const ssh_inner = try std.mem.join(allocator, ",", ssh_parts.items);
        defer allocator.free(ssh_inner);
        try parts.append(allocator, try std.fmt.allocPrint(allocator, "\"ssh\":{{{s}}}", .{ssh_inner}));
    }

    // Tailscale
    if (cfg.tailscale) |ts| {
        try parts.append(allocator, try std.fmt.allocPrint(
            allocator,
            "\"tailscale\":{{\"authkey\":\"{s}\",\"args\":\"{s}\"}}",
            .{ ts.authkey, ts.args },
        ));
    }

    const inner = try std.mem.join(allocator, ",", parts.items);
    defer allocator.free(inner);
    return std.fmt.allocPrint(allocator, "{{{s}}}", .{inner});
}

test "InitScriptConfig hasServices" {
    const t = std.testing;

    try t.expect(!(InitScriptConfig{}).hasServices());
    try t.expect((InitScriptConfig{ .ssh = .{} }).hasServices());
    try t.expect((InitScriptConfig{ .tailscale = .{ .authkey = "x", .args = "" } }).hasServices());
}

test "embedded init binary is non-empty" {
    const t = std.testing;
    try t.expect(init_binary.len > 0);
}

const std = @import("std");
const log = @import("util/log.zig");
const config = @import("config.zig");
const initscript = @import("initscript.zig");

const scoped_log = log.scoped("helpers");

/// Read a file's content into an allocated buffer.
/// Build an InitScriptConfig from the CLI config.
pub fn buildInitScriptConfig(_: std.mem.Allocator, cfg: *const config.Config, effective_ts_args: []const u8) initscript.InitScriptConfig {
    var init_cfg = initscript.InitScriptConfig{
        .flush_firewall = !cfg.keep_firewall,
    };

    // SSH
    if (cfg.sshEnabled()) {
        init_cfg.ssh = .{
            .port = cfg.ssh_port orelse 22,
            .password = cfg.ssh_password,
            .keyfile_content = cfg.ssh_authorized_keys,
        };
    }

    // Tailscale
    if (cfg.tailscaleEnabled()) {
        init_cfg.tailscale = .{
            .authkey = cfg.tailscale_authkey orelse "",
            .args = effective_ts_args,
        };
    }

    return init_cfg;
}

/// Resolve the effective tailscale up arguments.
/// If the user provided --tailscale.args, use that.
/// Otherwise, generate a default: --ssh --hostname=<hostname>-xenomorph
pub fn resolveTailscaleArgs(allocator: std.mem.Allocator, cfg: *const config.Config) []const u8 {
    if (!cfg.tailscaleEnabled()) return "--ssh";
    if (cfg.tailscale_args) |args| return args;

    // Detect hostname via uname syscall
    var uts: std.os.linux.utsname = undefined;
    _ = std.os.linux.syscall1(.uname, @intFromPtr(&uts));
    const hostname = std.mem.sliceTo(&uts.nodename, 0);

    var base = std.fmt.allocPrint(
        allocator,
        "--ssh --hostname={s}-xenomorph",
        .{hostname},
    ) catch return "--ssh";

    // Append --login-server if set
    if (cfg.tailscale_server) |server| {
        const with_server = std.fmt.allocPrint(
            allocator,
            "{s} --login-server={s}",
            .{ base, server },
        ) catch return base;
        allocator.free(base);
        base = with_server;
    }

    return base;
}

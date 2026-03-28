const std = @import("std");
const log = @import("util/log.zig");
const config = @import("config.zig");
const initscript = @import("initscript.zig");

const scoped_log = log.scoped("helpers");

/// Read a file's content into an allocated buffer.
pub fn readFileContent(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    // Try absolute then relative
    const file = std.fs.openFileAbsolute(path, .{}) catch
        std.fs.cwd().openFile(path, .{}) catch {
        scoped_log.warn("Cannot open file: {s}", .{path});
        return null;
    };
    defer file.close();
    const stat = file.stat() catch return null;
    const buf = allocator.alloc(u8, @intCast(stat.size)) catch return null;
    const n = file.readAll(buf) catch {
        allocator.free(buf);
        return null;
    };
    return buf[0..n];
}

/// Build an InitScriptConfig from the CLI config.
pub fn buildInitScriptConfig(allocator: std.mem.Allocator, cfg: *const config.Config, effective_ts_args: []const u8) initscript.InitScriptConfig {
    var init_cfg = initscript.InitScriptConfig{
        .flush_firewall = !cfg.keep_firewall,
    };

    // SSH
    if (cfg.ssh_port) |port| {
        init_cfg.ssh = .{
            .port = port,
            .password = cfg.ssh_password,
            .keyfile_content = if (cfg.ssh_keyfile) |path| readFileContent(allocator, path) else null,
        };
    }

    // Tailscale
    if (cfg.tailscale_authkey) |authkey| {
        init_cfg.tailscale = .{
            .authkey = authkey,
            .args = effective_ts_args,
        };
    }

    return init_cfg;
}

/// Resolve the effective tailscale up arguments.
/// If the user provided --tailscale-args, use that.
/// Otherwise, generate a default: --ssh --hostname=<hostname>-xenomorph
pub fn resolveTailscaleArgs(allocator: std.mem.Allocator, cfg: *const config.Config) []const u8 {
    if (!cfg.tailscaleEnabled()) return "--ssh";
    if (cfg.tailscale_args) |args| return args;

    // Detect hostname via uname syscall
    var uts: std.os.linux.utsname = undefined;
    _ = std.os.linux.syscall1(.uname, @intFromPtr(&uts));
    const hostname = std.mem.sliceTo(&uts.nodename, 0);

    return std.fmt.allocPrint(
        allocator,
        "--ssh --hostname={s}-xenomorph",
        .{hostname},
    ) catch "--ssh";
}

const std = @import("std");

// Utility modules
pub const log = @import("util/log.zig");
const oci_lib = @import("oci");
pub const syscall = oci_lib.linux_util.syscall;
pub const mount = oci_lib.linux_util.mount_util;
pub const memory = @import("util/memory.zig");

// Pivot modules
pub const pivot_mounts = @import("pivot/mounts.zig");
pub const pivot = @import("pivot/pivot.zig");
pub const pivot_prepare = @import("pivot/prepare.zig");
pub const pivot_cleanup = @import("pivot/cleanup.zig");

// OCI modules
pub const oci_image = oci_lib.image;
pub const oci_layer = oci_lib.layer;
pub const oci_registry = oci_lib.registry;
pub const oci_auth = oci_lib.auth;
pub const oci_cache = oci_lib.cache;
pub const oci_layout_writer = oci_lib.layout_writer;
pub const oci_containerfile = oci_lib.containerfile;

// Rootfs modules
pub const rootfs_builder = @import("rootfs/builder.zig");
pub const rootfs_overlay = @import("rootfs/overlay.zig");
pub const rootfs_verify = @import("rootfs/verify.zig");

// Init system modules
pub const init_detector = @import("init/detector.zig");
pub const init_interface = @import("init/interface.zig");
pub const init_systemd = @import("init/systemd.zig");
pub const init_openrc = @import("init/openrc.zig");
pub const init_sysvinit = @import("init/sysvinit.zig");

// Process management modules
pub const process_scanner = @import("process/scanner.zig");
pub const process_terminator = @import("process/terminator.zig");
pub const process_essential = @import("process/essential.zig");
pub const process_namespace = @import("process/namespace.zig");

pub const initscript = @import("initscript.zig");
pub const config = @import("config.zig");

// Command modules
const pivot_cmd = @import("cmd/pivot.zig");
const build_cmd = @import("cmd/build.zig");
const daemon_mod = @import("daemon.zig");
const helpers = @import("helpers.zig");
const cache = @import("cache.zig");
const containerfile_exec = @import("cmd/containerfile_exec.zig");

const scoped_log = log.scoped("main");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command line arguments
    const cfg = config.parseArgs(allocator) catch |err| {
        std.debug.print("Error parsing arguments: {}\n", .{err});
        std.process.exit(1);
    } orelse {
        // Help or version was printed
        return;
    };

    if (cfg.verbose) {
        log.setLevel(.debug);
    }

    config.validate(&cfg) catch |err| {
        std.debug.print("Configuration error: {}\n", .{err});
        std.process.exit(1);
    };

    if (cfg.subcommand == .build) {
        build_cmd.runBuild(allocator, &cfg) catch |err| {
            scoped_log.err("Build failed: {}", .{err});
            std.process.exit(1);
        };
        return;
    }

    // Resolve effective tailscale args (need this before fork for the pre-exit print)
    const effective_ts_args = helpers.resolveTailscaleArgs(allocator, &cfg);

    if (cfg.headless) {
        // Pre-flight checks before forking — errors must appear on the terminal
        if (std.os.linux.getuid() != 0) {
            std.debug.print("Error: must run as root\n", .{});
            std.process.exit(1);
        }
        if (cfg.tailscaleEnabled()) {
            // Validate authkey format
            if (cfg.tailscale_authkey) |key| {
                if (!std.mem.startsWith(u8, key, "tskey-auth-") and
                    !std.mem.startsWith(u8, key, "tskey-"))
                {
                    std.debug.print("Error: tailscale authkey doesn't look valid (expected tskey-auth-... or tskey-...)\n", .{});
                    std.process.exit(1);
                }
            }
            std.debug.print("xenomorph: tailscale up args: {s}\n", .{effective_ts_args});
        }
        daemon_mod.daemonize(cfg.log_dir);
    }

    pivot_cmd.runPivot(allocator, &cfg, effective_ts_args) catch |err| {
        scoped_log.err("Pivot failed: {}", .{err});
        std.process.exit(1);
    };
}

test "all modules compile" {
    // Import all modules to ensure they compile
    _ = log;
    _ = syscall;
    _ = mount;
    _ = memory;
    _ = pivot_mounts;
    _ = pivot;
    _ = pivot_prepare;
    _ = pivot_cleanup;
    _ = oci_image;
    _ = oci_layer;
    _ = oci_registry;
    _ = oci_auth;
    _ = oci_cache;
    _ = oci_layout_writer;
    _ = oci_containerfile;
    _ = rootfs_builder;
    _ = rootfs_overlay;
    _ = rootfs_verify;
    _ = init_detector;
    _ = init_interface;
    _ = init_systemd;
    _ = init_openrc;
    _ = init_sysvinit;
    _ = process_scanner;
    _ = process_terminator;
    _ = process_essential;
    _ = process_namespace;
    _ = initscript;
    _ = config;
    // New modules
    _ = pivot_cmd;
    _ = build_cmd;
    _ = daemon_mod;
    _ = helpers;
    _ = cache;
    _ = containerfile_exec;
}

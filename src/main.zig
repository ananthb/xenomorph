const std = @import("std");

// Utility modules
pub const log = @import("util/log.zig");
pub const syscall = @import("util/syscall.zig");
pub const mount = @import("util/mount.zig");
pub const memory = @import("util/memory.zig");

// Pivot modules
pub const pivot_mounts = @import("pivot/mounts.zig");
pub const pivot = @import("pivot/pivot.zig");
pub const pivot_prepare = @import("pivot/prepare.zig");
pub const pivot_cleanup = @import("pivot/cleanup.zig");

// OCI modules
pub const oci_image = @import("oci/image.zig");
pub const oci_layer = @import("oci/layer.zig");
pub const oci_registry = @import("oci/registry.zig");
pub const oci_auth = @import("oci/auth.zig");
pub const oci_cache = @import("oci/cache.zig");

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

pub const tailscale = @import("tailscale.zig");
pub const config = @import("config.zig");

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

    // Resolve effective tailscale args (need this before fork for the pre-exit print)
    const effective_ts_args = resolveTailscaleArgs(allocator, &cfg);

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
        daemonize();
    }

    runPivot(allocator, &cfg, effective_ts_args) catch |err| {
        scoped_log.err("Pivot failed: {}", .{err});
        std.process.exit(1);
    };
}

fn runPivot(allocator: std.mem.Allocator, cfg: *const config.Config, effective_ts_args: []const u8) !void {
    scoped_log.info("Starting xenomorph pivot", .{});
    scoped_log.info("Image: {s}", .{cfg.image});

    if (std.os.linux.getuid() != 0) {
        scoped_log.err("Must run as root", .{});
        return error.PermissionDenied;
    }

    if (cfg.dry_run) {
        try dryRun(allocator, cfg, effective_ts_args);
        return;
    }

    if (!cfg.force) {
        const confirmed = try confirmPivot();
        if (!confirmed) {
            scoped_log.info("Pivot cancelled by user", .{});
            return;
        }
    }

    scoped_log.info("Building rootfs from image (in-memory)", .{});
    var builder = rootfs_builder.RootfsBuilder.init(allocator);
    var build_result = builder.buildFromImage(cfg.image, .{
        .target_dir = cfg.work_dir,
        .skip_verify = cfg.skip_verify,
    }) catch |err| {
        if (err == error.InsufficientMemory) {
            scoped_log.err("Insufficient memory for in-memory rootfs", .{});
            scoped_log.err("The rootfs must fit entirely in RAM. Try:", .{});
            scoped_log.err("  - Using a smaller image", .{});
            scoped_log.err("  - Freeing up memory (stop services, clear caches)", .{});
            scoped_log.err("  - Adding more RAM to the system", .{});
            return error.InsufficientMemory;
        }
        return err;
    };
    defer build_result.deinit(allocator);
    errdefer build_result.unmountTmpfs();

    scoped_log.info("Rootfs built: {} layers, {} bytes", .{
        build_result.layer_count,
        build_result.total_size,
    });

    if (!cfg.skip_verify) {
        scoped_log.info("Verifying rootfs", .{});
        var verify_result = try rootfs_verify.verify(cfg.work_dir, allocator);
        defer verify_result.deinit(allocator);

        if (!verify_result.valid) {
            scoped_log.err("Rootfs verification failed", .{});
            for (verify_result.errors.items) |err| {
                scoped_log.err("  {s}", .{err});
            }
            return error.InvalidRootfs;
        }
    }

    // Tailscale injection (after rootfs is built, before pivot)
    var ts_exec_cmd: []const u8 = cfg.exec_cmd;
    var ts_exec_args: ?[]const []const u8 = if (cfg.exec_args.len > 0) cfg.exec_args else null;

    if (cfg.tailscaleEnabled()) {
        scoped_log.info("Setting up Tailscale integration", .{});
        var injector = tailscale.TailscaleInjector.init(allocator, cfg.tailscale_authkey.?, effective_ts_args);
        defer injector.deinit();

        injector.inject(cfg.work_dir) catch |err| {
            scoped_log.err("Tailscale injection failed: {}", .{err});
            if (err == error.PlatformNotSupported) {
                scoped_log.err("Current platform not supported by Tailscale image", .{});
            } else if (err == error.BinaryNotFound) {
                scoped_log.err("tailscale/tailscaled binaries not found in docker.io/tailscale/tailscale", .{});
            }
            return err;
        };

        injector.createStartupScript(cfg.work_dir) catch |err| {
            scoped_log.err("Failed to create Tailscale startup script: {}", .{err});
            return err;
        };

        // Wrap exec: run the init script which starts tailscale then exec's the real command
        var new_args: std.ArrayListUnmanaged([]const u8) = .{};
        try new_args.append(std.heap.page_allocator, cfg.exec_cmd);
        if (cfg.exec_args.len > 0) {
            try new_args.appendSlice(std.heap.page_allocator, cfg.exec_args);
        }
        ts_exec_args = try new_args.toOwnedSlice(std.heap.page_allocator);
        ts_exec_cmd = "/usr/local/bin/xenomorph-ts-init";

        scoped_log.info("Tailscale integration configured", .{});
    }

    if (!cfg.no_init_coord and !init_interface.shouldSkipCoordination()) {
        scoped_log.info("Coordinating with init system", .{});

        if (init_interface.InitCoordinator.init(allocator)) |coord| {
            var c = coord;
            c.timeout_seconds = cfg.timeout;

            c.transitionToRescue() catch |err| {
                scoped_log.warn("Failed to transition to rescue mode: {}", .{err});
            };

            c.waitForServicesToStop() catch |err| {
                scoped_log.warn("Timeout waiting for services: {}", .{err});
            };
        } else |err| {
            scoped_log.warn("Cannot initialize init coordinator: {}", .{err});
            // Continue anyway
        }
    }

    scoped_log.info("Terminating non-essential processes", .{});
    if (process_terminator.terminateAll(allocator, .{
        .graceful_timeout_ms = cfg.timeout * 1000,
    })) |result| {
        var r = result;
        scoped_log.info("Terminated {} processes ({} killed)", .{
            r.terminated_count,
            r.killed_count,
        });
        r.deinit(allocator);
    } else |err| {
        scoped_log.warn("Process termination failed: {}", .{err});
    }

    scoped_log.info("Preparing pivot", .{});
    var prep_result = try pivot_prepare.prepare(.{
        .new_root = cfg.work_dir,
        .skip_verify = true, // Already verified
        .create_namespace = !cfg.skip_namespace,
    }, allocator);
    defer prep_result.deinit();

    scoped_log.info("Executing pivot_root", .{});
    try pivot.executePivot(.{
        .new_root = cfg.work_dir,
        .old_root_mount = cfg.keep_old_root[1..], // Remove leading /
        .exec_cmd = ts_exec_cmd,
        .exec_args = ts_exec_args,
        .keep_old_root = !cfg.no_keep_old_root,
        .allocator = allocator,
    });

    // If we get here, exec didn't happen or failed
    scoped_log.info("Pivot complete", .{});
}

fn dryRun(allocator: std.mem.Allocator, cfg: *const config.Config, effective_ts_args: []const u8) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    try stdout.print("\n=== DRY RUN ===\n\n", .{});

    try stdout.print("Image: {s}\n", .{cfg.image});
    try stdout.print("Exec command: {s}\n", .{cfg.exec_cmd});
    try stdout.print("Old root mount: {s}\n", .{cfg.keep_old_root});
    try stdout.print("Timeout: {}s\n", .{cfg.timeout});
    if (cfg.headless) {
        try stdout.print("Mode: headless (will fork and detach, log to /var/log/xenomorph.log)\n", .{});
    }

    try stdout.print("\nSteps that would be performed:\n", .{});
    try stdout.print("  1. Build rootfs from {s}\n", .{cfg.image});
    try stdout.print("  2. Verify rootfs structure\n", .{});

    if (!cfg.no_init_coord) {
        // Detect init system
        var detection = try init_detector.detect(allocator);
        defer detection.deinit(allocator);

        try stdout.print("  3. Coordinate with init system ({s})\n", .{detection.init_system.name()});
        try stdout.print("  4. Transition to rescue mode\n", .{});
    } else {
        try stdout.print("  3. Skip init coordination (--no-init-coord)\n", .{});
    }

    if (cfg.tailscaleEnabled()) {
        try stdout.print("  5. Inject Tailscale from docker.io/tailscale/tailscale\n", .{});
        try stdout.print("     - Auth key: {s}...{s}\n", .{
            cfg.tailscale_authkey.?[0..@min(cfg.tailscale_authkey.?.len, 8)],
            if (cfg.tailscale_authkey.?.len > 12) cfg.tailscale_authkey.?[cfg.tailscale_authkey.?.len - 4 ..] else "",
        });
        try stdout.print("     - Args: {s}\n", .{effective_ts_args});
    }

    try stdout.print("  6. Terminate non-essential processes\n", .{});
    try stdout.print("  7. Create mount namespace\n", .{});
    try stdout.print("  8. Execute pivot_root\n", .{});
    try stdout.print("  9. Mount old root at {s}\n", .{cfg.keep_old_root});
    try stdout.print(" 10. Execute {s}\n", .{cfg.exec_cmd});

    try stdout.print("\n=== END DRY RUN ===\n", .{});
}

fn confirmPivot() !bool {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const stdin = std.fs.File.stdin().deprecatedReader();

    try stdout.print("\n", .{});
    try stdout.print("WARNING: This will:\n", .{});
    try stdout.print("  - Stop most running services\n", .{});
    try stdout.print("  - Terminate most running processes\n", .{});
    try stdout.print("  - Replace the root filesystem\n", .{});
    try stdout.print("\nThis operation is DANGEROUS and may render the system unbootable.\n", .{});
    try stdout.print("Make sure you have a recovery plan.\n", .{});
    try stdout.print("\nContinue? [y/N] ", .{});

    var buf: [10]u8 = undefined;
    const n = try stdin.read(&buf);

    if (n == 0) return false;

    const response = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return std.mem.eql(u8, response, "y") or std.mem.eql(u8, response, "Y");
}

/// Resolve the effective tailscale up arguments.
/// If the user provided --tailscale-args, use that.
/// Otherwise, generate a default: --ssh --hostname=<hostname>-xenomorph
fn resolveTailscaleArgs(allocator: std.mem.Allocator, cfg: *const config.Config) []const u8 {
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

/// Fork and detach from the controlling terminal.
/// The parent prints the child PID and log path, then exits immediately.
/// The child continues in a new session with stderr redirected to a log file.
fn daemonize() void {
    const linux = std.os.linux;
    const headless_log = "/var/log/xenomorph.log";

    // Ensure log directory exists
    std.fs.makeDirAbsolute("/var/log") catch {};

    // Open log file (create/truncate, write-only)
    const log_fd = std.posix.open(
        headless_log,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    ) catch {
        std.debug.print("Error: cannot create {s}\n", .{headless_log});
        std.process.exit(1);
    };

    // Fork
    const fork_result = linux.syscall0(.fork);
    if (linux.E.init(fork_result) != .SUCCESS) {
        std.debug.print("Error: fork failed\n", .{});
        std.process.exit(1);
    }

    if (fork_result > 0) {
        // Parent: print status and exit, freeing the SSH shell
        std.debug.print("xenomorph: daemonized (pid={}, log={s})\n", .{ fork_result, headless_log });
        std.process.exit(0);
    }

    // --- Child continues below ---

    // Create a new session so we're not tied to the SSH terminal.
    // When sshd is killed during pivot, SIGHUP goes to the old session, not us.
    _ = linux.syscall0(.setsid);

    // Redirect stdin/stdout to /dev/null, stderr to the log file
    const null_fd = std.posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch {
        // Fallback: just redirect stderr
        _ = std.posix.dup2(log_fd, 2) catch {};
        log.setColors(false);
        return;
    };

    _ = std.posix.dup2(null_fd, 0) catch {}; // stdin  -> /dev/null
    _ = std.posix.dup2(null_fd, 1) catch {}; // stdout -> /dev/null
    _ = std.posix.dup2(log_fd, 2) catch {}; // stderr -> log file

    // Close the original fds (dup2 created new references on 0/1/2)
    std.posix.close(null_fd);
    std.posix.close(log_fd);

    // No terminal, no colors
    log.setColors(false);
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
    _ = tailscale;
    _ = config;
}

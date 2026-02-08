const std = @import("std");

// Utility modules
pub const log = @import("util/log.zig");
pub const syscall = @import("util/syscall.zig");
pub const mount = @import("util/mount.zig");

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

// Configuration
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

    // Set log level
    if (cfg.verbose) {
        log.setLevel(.debug);
    }

    // Validate configuration
    config.validate(&cfg) catch |err| {
        std.debug.print("Configuration error: {}\n", .{err});
        std.process.exit(1);
    };

    // Run the pivot operation
    runPivot(allocator, &cfg) catch |err| {
        scoped_log.err("Pivot failed: {}", .{err});
        std.process.exit(1);
    };
}

fn runPivot(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    scoped_log.info("Starting xenomorph pivot", .{});
    scoped_log.info("Image: {s}", .{cfg.image});

    // Check if running as root
    if (std.os.linux.getuid() != 0) {
        scoped_log.err("Must run as root", .{});
        return error.PermissionDenied;
    }

    // Dry run mode
    if (cfg.dry_run) {
        try dryRun(allocator, cfg);
        return;
    }

    // Confirmation prompt
    if (!cfg.force) {
        const confirmed = try confirmPivot();
        if (!confirmed) {
            scoped_log.info("Pivot cancelled by user", .{});
            return;
        }
    }

    // Step 1: Build rootfs from image
    scoped_log.info("Building rootfs from image", .{});
    var builder = rootfs_builder.RootfsBuilder.init(allocator);
    const build_result = try builder.buildFromImage(cfg.image, .{
        .target_dir = cfg.work_dir,
        .skip_verify = cfg.skip_verify,
    });
    defer {
        var result = build_result;
        result.deinit(allocator);
    }

    scoped_log.info("Rootfs built: {} layers, {} bytes", .{
        build_result.layer_count,
        build_result.total_size,
    });

    // Step 2: Verify rootfs
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

    // Step 3: Init system coordination
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

    // Step 4: Stop remaining processes
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

    // Step 5: Prepare for pivot
    scoped_log.info("Preparing pivot", .{});
    var prep_result = try pivot_prepare.prepare(.{
        .new_root = cfg.work_dir,
        .skip_verify = true, // Already verified
        .create_namespace = true,
    }, allocator);
    defer prep_result.deinit();

    // Step 6: Execute pivot
    scoped_log.info("Executing pivot_root", .{});
    try pivot.executePivot(.{
        .new_root = cfg.work_dir,
        .old_root_mount = cfg.keep_old_root[1..], // Remove leading /
        .exec_cmd = cfg.exec_cmd,
        .exec_args = if (cfg.exec_args.len > 0) cfg.exec_args else null,
        .keep_old_root = !cfg.no_keep_old_root,
        .allocator = allocator,
    });

    // If we get here, exec didn't happen or failed
    scoped_log.info("Pivot complete", .{});
}

fn dryRun(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    try stdout.print("\n=== DRY RUN ===\n\n", .{});

    try stdout.print("Image: {s}\n", .{cfg.image});
    try stdout.print("Exec command: {s}\n", .{cfg.exec_cmd});
    try stdout.print("Old root mount: {s}\n", .{cfg.keep_old_root});
    try stdout.print("Timeout: {}s\n", .{cfg.timeout});

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

    try stdout.print("  5. Terminate non-essential processes\n", .{});
    try stdout.print("  6. Create mount namespace\n", .{});
    try stdout.print("  7. Execute pivot_root\n", .{});
    try stdout.print("  8. Mount old root at {s}\n", .{cfg.keep_old_root});
    try stdout.print("  9. Execute {s}\n", .{cfg.exec_cmd});

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

test "all modules compile" {
    // Import all modules to ensure they compile
    _ = log;
    _ = syscall;
    _ = mount;
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
    _ = config;
}

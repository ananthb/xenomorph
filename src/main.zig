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
const oci_lib = @import("oci");
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

    if (cfg.subcommand == .build) {
        runBuild(allocator, &cfg) catch |err| {
            scoped_log.err("Build failed: {}", .{err});
            std.process.exit(1);
        };
        return;
    }

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

    if (std.os.linux.getuid() != 0) {
        scoped_log.err("Must run as root", .{});
        return error.PermissionDenied;
    }

    // Handle containerfile if specified
    var cf_result: ?ContainerfileResult = null;
    defer if (cf_result) |*cfr| cfr.deinit(allocator);

    if (cfg.containerfile) |cf_path| {
        const context_dir = cfg.context orelse blk: {
            break :blk std.fs.path.dirname(cf_path) orelse ".";
        };
        scoped_log.info("Building from containerfile: {s}", .{cf_path});
        cf_result = executeContainerfile(allocator, cf_path, context_dir, cfg.work_dir) catch |err| {
            scoped_log.err("Failed to parse containerfile: {}", .{err});
            return err;
        };
    }

    // Build effective layer list: user layers + tailscale image if enabled
    var effective_layers: std.ArrayListUnmanaged(config.Layer) = .{};
    defer effective_layers.deinit(allocator);

    if (cf_result) |cfr| {
        if (cfr.base_image) |bi| {
            try effective_layers.append(allocator, .{ .image = bi });
        }
    }
    if (effective_layers.items.len == 0) {
        try effective_layers.appendSlice(allocator, cfg.layers);
    }
    if (cfg.tailscaleEnabled()) {
        try effective_layers.append(allocator, .{ .image = tailscale.tailscale_image });
    }

    for (effective_layers.items, 0..) |layer, i| {
        switch (layer) {
            .image => |ref| scoped_log.info("Layer {}/{}: image {s}", .{ i + 1, effective_layers.items.len, ref }),
            .rootfs => |path| scoped_log.info("Layer {}/{}: rootfs {s}", .{ i + 1, effective_layers.items.len, path }),
        }
    }

    if (cfg.dry_run) {
        try dryRun(allocator, cfg, effective_ts_args, effective_layers.items);
        return;
    }

    if (!cfg.force) {
        const confirmed = try confirmPivot();
        if (!confirmed) {
            scoped_log.info("Pivot cancelled by user", .{});
            return;
        }
    }

    // Build rootfs from first layer
    const first_layer = effective_layers.items[0];
    switch (first_layer) {
        .image => |ref| scoped_log.info("Building rootfs from image {s}", .{ref}),
        .rootfs => |path| scoped_log.info("Building rootfs from {s}", .{path}),
    }
    var builder = rootfs_builder.RootfsBuilder.init(allocator);
    var build_result = builder.buildFromLayer(first_layer, .{
        .target_dir = cfg.work_dir,
        .skip_verify = true, // verify after all merges
        .tmpfs_headroom = 1.5 + 0.5 * @as(f64, @floatFromInt(effective_layers.items.len - 1)),
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

    scoped_log.info("Base rootfs: {} layers, {} bytes", .{
        build_result.layer_count,
        build_result.total_size,
    });

    // Thread ImageConfig through the merge loop: subsequent images overwrite on conflict
    var effective_config: ?rootfs_builder.BuildResult.ImageConfig = build_result.config;
    build_result.config = null;
    defer {
        if (effective_config) |*ec| {
            if (ec.entrypoint) |ep| {
                for (ep) |e| allocator.free(e);
                allocator.free(ep);
            }
            if (ec.cmd) |cmd| {
                for (cmd) |c| allocator.free(c);
                allocator.free(cmd);
            }
            if (ec.env) |env| {
                for (env) |e| allocator.free(e);
                allocator.free(env);
            }
            if (ec.working_dir) |wd| allocator.free(wd);
        }
    }

    // Merge additional layers in order (later overwrites earlier on conflict)
    for (effective_layers.items[1..]) |layer| {
        switch (layer) {
            .image => |ref| scoped_log.info("Merging image {s}", .{ref}),
            .rootfs => |path| scoped_log.info("Merging rootfs {s}", .{path}),
        }
        const merge_config = builder.mergeLayer(layer, cfg.work_dir) catch |err| {
            scoped_log.err("Failed to merge layer: {}", .{err});
            return err;
        };
        if (merge_config) |mc| {
            mergeImageConfig(allocator, &effective_config, mc);
        }
    }

    // Merge containerfile config if present
    if (cf_result) |cfr| {
        if (cfr.img_config) |ic| {
            mergeImageConfig(allocator, &effective_config, ic);
        }
    }

    // Resolve effective entrypoint
    var resolved_cmd: []const u8 = undefined;
    var resolved_args: ?[]const []const u8 = null;
    if (cfg.exec_cmd_explicit) {
        resolved_cmd = cfg.exec_cmd;
        resolved_args = if (cfg.exec_args.len > 0) cfg.exec_args else null;
    } else if (effective_config) |ec| {
        if (ec.entrypoint) |ep| {
            if (ep.len > 0) {
                resolved_cmd = ep[0];
                if (ep.len > 1 or (ec.cmd != null)) {
                    var args_list: std.ArrayListUnmanaged([]const u8) = .{};
                    defer args_list.deinit(allocator);
                    for (ep[1..]) |a| {
                        try args_list.append(allocator, a);
                    }
                    if (ec.cmd) |cmd| {
                        for (cmd) |c| {
                            try args_list.append(allocator, c);
                        }
                    }
                    if (args_list.items.len > 0) {
                        resolved_args = try args_list.toOwnedSlice(allocator);
                    }
                }
            } else {
                resolved_cmd = "/sbin/init";
            }
        } else if (ec.cmd) |cmd| {
            if (cmd.len > 0) {
                resolved_cmd = cmd[0];
                if (cmd.len > 1) {
                    resolved_args = cmd[1..];
                }
            } else {
                resolved_cmd = "/sbin/init";
            }
        } else {
            resolved_cmd = "/sbin/init";
        }
    } else {
        resolved_cmd = "/sbin/init";
    }

    // Validate entrypoint exists in rootfs
    {
        const relative_path = if (std.mem.startsWith(u8, resolved_cmd, "/")) resolved_cmd[1..] else resolved_cmd;
        var rootfs_dir = std.fs.openDirAbsolute(cfg.work_dir, .{}) catch {
            scoped_log.err("Cannot open rootfs at {s}", .{cfg.work_dir});
            return error.InvalidRootfs;
        };
        defer rootfs_dir.close();
        rootfs_dir.access(relative_path, .{}) catch {
            scoped_log.err("Entrypoint {s} not found in rootfs", .{resolved_cmd});
            return error.EntrypointNotFound;
        };
    }

    // Build OCI image from the rootfs (for hashing)
    oci_hash_blk: {
        const oci_dir = "/tmp/xenomorph-oci";
        std.fs.deleteTreeAbsolute(oci_dir) catch {};
        const oci_digest = oci_layout_writer.writeOciLayout(allocator, cfg.work_dir, oci_dir, effective_config) catch |err| {
            scoped_log.warn("Failed to build OCI image for hashing: {}", .{err});
            break :oci_hash_blk;
        };
        scoped_log.info("OCI image: sha256:{s} ({d} bytes)", .{ &oci_digest.manifest_digest, oci_digest.manifest_size });
        std.fs.deleteTreeAbsolute(oci_dir) catch {};
    }

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

    // Tailscale startup script (binaries already in rootfs from merge)
    var ts_exec_cmd: []const u8 = resolved_cmd;
    var ts_exec_args: ?[]const []const u8 = resolved_args;

    if (cfg.tailscaleEnabled()) {
        scoped_log.info("Creating Tailscale startup script", .{});
        var injector = tailscale.TailscaleInjector.init(allocator, cfg.tailscale_authkey.?, effective_ts_args);
        defer injector.deinit();

        injector.createStartupScript(cfg.work_dir) catch |err| {
            scoped_log.err("Failed to create Tailscale startup script: {}", .{err});
            return err;
        };

        // Wrap exec: run the init script which starts tailscale then exec's the real command
        var new_args: std.ArrayListUnmanaged([]const u8) = .{};
        try new_args.append(std.heap.page_allocator, resolved_cmd);
        if (resolved_args) |ra| {
            try new_args.appendSlice(std.heap.page_allocator, ra);
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
        .exec_env = if (effective_config) |c| c.env else null,
        .allocator = allocator,
    });

    // If we get here, exec didn't happen or failed
    scoped_log.info("Pivot complete", .{});
}

fn dryRun(allocator: std.mem.Allocator, cfg: *const config.Config, effective_ts_args: []const u8, layers: []const config.Layer) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    try stdout.print("\n=== DRY RUN ===\n\n", .{});

    try stdout.print("Layers (merged in order):\n", .{});
    for (layers, 0..) |layer, i| {
        const label = switch (layer) {
            .image => |ref| ref,
            .rootfs => |path| path,
        };
        const kind = switch (layer) {
            .image => "image",
            .rootfs => "rootfs",
        };
        if (i == 0) {
            try stdout.print("  {}: {s} ({s}, base)\n", .{ i + 1, label, kind });
        } else if (cfg.tailscaleEnabled() and layer == .image and std.mem.eql(u8, layer.image, tailscale.tailscale_image)) {
            try stdout.print("  {}: {s} ({s}, tailscale)\n", .{ i + 1, label, kind });
        } else {
            try stdout.print("  {}: {s} ({s})\n", .{ i + 1, label, kind });
        }
    }

    try stdout.print("\nExec command: {s}\n", .{cfg.exec_cmd});
    try stdout.print("Old root mount: {s}\n", .{cfg.keep_old_root});
    try stdout.print("Timeout: {}s\n", .{cfg.timeout});
    if (cfg.headless) {
        try stdout.print("Mode: headless (will fork and detach, log to /var/log/xenomorph.log)\n", .{});
    }

    try stdout.print("\nSteps that would be performed:\n", .{});
    var step: usize = 1;

    const first = layers[0];
    switch (first) {
        .image => |ref| try stdout.print("  {}. Build rootfs from image {s}\n", .{ step, ref }),
        .rootfs => |path| try stdout.print("  {}. Build rootfs from {s}\n", .{ step, path }),
    }
    step += 1;

    for (layers[1..]) |layer| {
        switch (layer) {
            .image => |ref| try stdout.print("  {}. Merge image {s}\n", .{ step, ref }),
            .rootfs => |path| try stdout.print("  {}. Merge rootfs {s}\n", .{ step, path }),
        }
        step += 1;
    }

    try stdout.print("  {}. Verify rootfs structure\n", .{step});
    step += 1;

    if (cfg.tailscaleEnabled()) {
        try stdout.print("  {}. Create Tailscale startup script\n", .{step});
        step += 1;
        try stdout.print("     - Auth key: {s}...{s}\n", .{
            cfg.tailscale_authkey.?[0..@min(cfg.tailscale_authkey.?.len, 8)],
            if (cfg.tailscale_authkey.?.len > 12) cfg.tailscale_authkey.?[cfg.tailscale_authkey.?.len - 4 ..] else "",
        });
        try stdout.print("     - Args: {s}\n", .{effective_ts_args});
    }

    if (!cfg.no_init_coord) {
        var detection = try init_detector.detect(allocator);
        defer detection.deinit(allocator);
        try stdout.print("  {}. Coordinate with init system ({s})\n", .{ step, detection.init_system.name() });
        step += 1;
    }

    try stdout.print("  {}. Terminate non-essential processes\n", .{step});
    step += 1;
    try stdout.print("  {}. Execute pivot_root\n", .{step});
    step += 1;
    try stdout.print("  {}. Execute {s}\n", .{ step, cfg.exec_cmd });

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

fn runBuild(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    scoped_log.info("Building OCI image", .{});

    // Handle containerfile if specified
    var cf_result_build: ?ContainerfileResult = null;
    defer if (cf_result_build) |*cfr| cfr.deinit(allocator);

    if (cfg.containerfile) |cf_path| {
        const context_dir = cfg.context orelse blk: {
            break :blk std.fs.path.dirname(cf_path) orelse ".";
        };
        scoped_log.info("Building from containerfile: {s}", .{cf_path});
        cf_result_build = executeContainerfile(allocator, cf_path, context_dir, cfg.work_dir) catch |err| {
            scoped_log.err("Failed to parse containerfile: {}", .{err});
            return err;
        };
    }

    // Build effective layer list (with tailscale if enabled)
    var effective_layers: std.ArrayListUnmanaged(config.Layer) = .{};
    defer effective_layers.deinit(allocator);

    if (cf_result_build) |cfr| {
        if (cfr.base_image) |bi| {
            try effective_layers.append(allocator, .{ .image = bi });
        }
    }
    if (effective_layers.items.len == 0) {
        try effective_layers.appendSlice(allocator, cfg.layers);
    }
    if (cfg.tailscaleEnabled()) {
        try effective_layers.append(allocator, .{ .image = tailscale.tailscale_image });
    }

    for (effective_layers.items, 0..) |layer, i| {
        switch (layer) {
            .image => |ref| scoped_log.info("Layer {}/{}: image {s}", .{ i + 1, effective_layers.items.len, ref }),
            .rootfs => |path| scoped_log.info("Layer {}/{}: rootfs {s}", .{ i + 1, effective_layers.items.len, path }),
        }
    }

    // Build rootfs from first layer
    var builder = rootfs_builder.RootfsBuilder.init(allocator);
    var build_result = builder.buildFromLayer(effective_layers.items[0], .{
        .target_dir = cfg.work_dir,
        .skip_verify = true,
        .tmpfs_headroom = 1.5 + 0.5 * @as(f64, @floatFromInt(effective_layers.items.len - 1)),
    }) catch |err| {
        scoped_log.err("Failed to build rootfs: {}", .{err});
        return err;
    };
    defer build_result.deinit(allocator);
    defer build_result.unmountTmpfs();

    // Thread ImageConfig through the merge loop: last OCI image wins
    var effective_config: ?rootfs_builder.BuildResult.ImageConfig = build_result.config;
    build_result.config = null;
    defer {
        if (effective_config) |*ec| {
            if (ec.entrypoint) |ep| {
                for (ep) |e| allocator.free(e);
                allocator.free(ep);
            }
            if (ec.cmd) |cmd| {
                for (cmd) |c| allocator.free(c);
                allocator.free(cmd);
            }
            if (ec.env) |env| {
                for (env) |e| allocator.free(e);
                allocator.free(env);
            }
            if (ec.working_dir) |wd| allocator.free(wd);
        }
    }

    // Merge additional layers (later overwrites earlier on conflict)
    for (effective_layers.items[1..]) |layer| {
        switch (layer) {
            .image => |ref| scoped_log.info("Merging image {s}", .{ref}),
            .rootfs => |path| scoped_log.info("Merging rootfs {s}", .{path}),
        }
        const merge_config = builder.mergeLayer(layer, cfg.work_dir) catch |err| {
            scoped_log.err("Failed to merge layer: {}", .{err});
            return err;
        };
        if (merge_config) |mc| {
            mergeImageConfig(allocator, &effective_config, mc);
        }
    }

    // Merge containerfile config if present
    if (cf_result_build) |cfr| {
        if (cfr.img_config) |ic| {
            mergeImageConfig(allocator, &effective_config, ic);
        }
    }

    // Create tailscale startup script if enabled
    if (cfg.tailscaleEnabled()) {
        const effective_ts_args = resolveTailscaleArgs(allocator, cfg);
        var injector = tailscale.TailscaleInjector.init(allocator, cfg.tailscale_authkey.?, effective_ts_args);
        defer injector.deinit();
        try injector.createStartupScript(cfg.work_dir);
    }

    // Write OCI layout
    scoped_log.info("Writing OCI layout to {s}", .{cfg.output});
    const oci_digest = try oci_layout_writer.writeOciLayout(allocator, cfg.work_dir, cfg.output, effective_config);
    scoped_log.info("OCI image: sha256:{s}", .{&oci_digest.manifest_digest});

    // Optionally write rootfs tarball
    if (cfg.rootfs_output) |rootfs_path| {
        scoped_log.info("Writing rootfs tarball to {s}", .{rootfs_path});
        const tar_cmd = std.fmt.allocPrint(
            allocator,
            "tar czf {s} --sort=name -C {s} .",
            .{ rootfs_path, cfg.work_dir },
        ) catch return error.OutOfMemory;
        defer allocator.free(tar_cmd);

        var child = std.process.Child.init(&.{ "sh", "-c", tar_cmd }, allocator);
        child.spawn() catch return error.IoError;
        const term = child.wait() catch return error.IoError;
        switch (term) {
            .Exited => |code| {
                if (code != 0) {
                    scoped_log.err("tar failed with exit code {}", .{code});
                    return error.IoError;
                }
            },
            else => return error.IoError,
        }
    }

    // Entrypoint validation (warning only for generate)
    if (!cfg.exec_cmd_explicit) {
        const has_entrypoint = if (effective_config) |ec|
            (ec.entrypoint != null and ec.entrypoint.?.len > 0) or
                (ec.cmd != null and ec.cmd.?.len > 0)
        else
            false;

        if (!has_entrypoint) {
            var rootfs_dir = std.fs.openDirAbsolute(cfg.work_dir, .{}) catch {
                scoped_log.warn("Cannot open rootfs to validate entrypoint", .{});
                return;
            };
            defer rootfs_dir.close();
            rootfs_dir.access("sbin/init", .{}) catch {
                scoped_log.warn("No entrypoint from image config and /sbin/init not found in rootfs", .{});
            };
        }
    }

    scoped_log.info("Generated {s}", .{cfg.output});
}

const ContainerfileResult = struct {
    base_image: ?[]const u8,
    img_config: ?rootfs_builder.BuildResult.ImageConfig,

    fn deinit(self: *ContainerfileResult, allocator: std.mem.Allocator) void {
        if (self.base_image) |bi| allocator.free(bi);
        if (self.img_config) |*ic| {
            if (ic.entrypoint) |ep| {
                for (ep) |e| allocator.free(e);
                allocator.free(ep);
            }
            if (ic.cmd) |cmd| {
                for (cmd) |c| allocator.free(c);
                allocator.free(cmd);
            }
            if (ic.env) |env| {
                for (env) |e| allocator.free(e);
                allocator.free(env);
            }
            if (ic.working_dir) |wd| allocator.free(wd);
        }
    }
};

fn executeContainerfile(
    allocator: std.mem.Allocator,
    cf_path: []const u8,
    context_dir: []const u8,
    work_dir: []const u8,
) !ContainerfileResult {
    const cf = try oci_containerfile.Containerfile.parseFile(allocator, cf_path);
    defer cf.deinit(allocator);

    var result = ContainerfileResult{
        .base_image = null,
        .img_config = null,
    };
    errdefer result.deinit(allocator);

    var env_list: std.ArrayListUnmanaged([]const u8) = .{};
    defer env_list.deinit(allocator);

    var entrypoint: ?[]const []const u8 = null;
    var cmd: ?[]const []const u8 = null;
    var working_dir: ?[]const u8 = null;

    for (cf.instructions) |inst| {
        switch (inst) {
            .from => |from| {
                if (result.base_image == null) {
                    result.base_image = try allocator.dupe(u8, from.image);
                }
            },
            .copy, .add => |copy| {
                // Copy files from context_dir to work_dir
                for (copy.sources) |src| {
                    const src_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ context_dir, src });
                    defer allocator.free(src_path);

                    // Determine destination path within work_dir
                    const dest_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ work_dir, copy.dest });
                    defer allocator.free(dest_path);

                    const cp_cmd = try std.fmt.allocPrint(
                        allocator,
                        "cp -a {s} {s}",
                        .{ src_path, dest_path },
                    );
                    defer allocator.free(cp_cmd);

                    var child = std.process.Child.init(&.{ "sh", "-c", cp_cmd }, allocator);
                    child.spawn() catch {
                        scoped_log.warn("Failed to copy {s} to {s}", .{ src, copy.dest });
                        continue;
                    };
                    const term = child.wait() catch continue;
                    switch (term) {
                        .Exited => |code| {
                            if (code != 0) {
                                scoped_log.warn("cp failed for {s}", .{src});
                            }
                        },
                        else => {},
                    }
                }
            },
            .env => |env| {
                const env_str = try std.fmt.allocPrint(allocator, "{s}={s}", .{ env.key, env.value });
                try env_list.append(allocator, env_str);
            },
            .workdir => |wd| {
                if (working_dir) |old| allocator.free(old);
                working_dir = try allocator.dupe(u8, wd);
            },
            .entrypoint => |ep| {
                if (entrypoint) |old| {
                    for (old) |o| allocator.free(o);
                    allocator.free(old);
                }
                var new_ep = try allocator.alloc([]const u8, ep.len);
                for (ep, 0..) |e, i| {
                    new_ep[i] = try allocator.dupe(u8, e);
                }
                entrypoint = new_ep;
            },
            .cmd => |c| {
                if (cmd) |old| {
                    for (old) |o| allocator.free(o);
                    allocator.free(old);
                }
                var new_cmd = try allocator.alloc([]const u8, c.len);
                for (c, 0..) |e, i| {
                    new_cmd[i] = try allocator.dupe(u8, e);
                }
                cmd = new_cmd;
            },
            else => {}, // Other instructions stored but not acted on during build
        }
    }

    // Build the image config
    var env_slice: ?[]const []const u8 = null;
    if (env_list.items.len > 0) {
        env_slice = try env_list.toOwnedSlice(allocator);
    }

    result.img_config = .{
        .entrypoint = entrypoint,
        .cmd = cmd,
        .env = env_slice,
        .working_dir = working_dir,
    };

    return result;
}

/// Merge a new ImageConfig on top of an existing one.
/// Only non-null fields from `overlay` overwrite `base`.
/// Env vars are merged by key (later value for same key wins, new keys appended).
fn mergeImageConfig(
    allocator: std.mem.Allocator,
    base: *?rootfs_builder.BuildResult.ImageConfig,
    overlay: rootfs_builder.BuildResult.ImageConfig,
) void {
    if (base.* == null) {
        base.* = overlay;
        return;
    }
    var b = &(base.*.?);

    // Entrypoint: overlay wins if present
    if (overlay.entrypoint) |new_ep| {
        if (b.entrypoint) |old_ep| {
            for (old_ep) |e| allocator.free(e);
            allocator.free(old_ep);
        }
        b.entrypoint = new_ep;
    } else {
        // overlay didn't define entrypoint, keep base — but free overlay's null
    }

    // Cmd: overlay wins if present
    if (overlay.cmd) |new_cmd| {
        if (b.cmd) |old_cmd| {
            for (old_cmd) |c| allocator.free(c);
            allocator.free(old_cmd);
        }
        b.cmd = new_cmd;
    }

    // WorkingDir: overlay wins if present
    if (overlay.working_dir) |new_wd| {
        if (b.working_dir) |old_wd| allocator.free(old_wd);
        b.working_dir = new_wd;
    }

    // Env: merge by key (KEY=VALUE, split on first '=')
    if (overlay.env) |new_env| {
        if (b.env) |old_env| {
            // Build merged list: start with old, overlay new on top
            var merged: std.ArrayListUnmanaged([]const u8) = .{};
            // Add all old entries
            for (old_env) |entry| {
                merged.append(allocator, entry) catch continue;
            }
            // For each new entry, find and replace by key, or append
            for (new_env) |new_entry| {
                const new_eq = std.mem.indexOf(u8, new_entry, "=") orelse new_entry.len;
                const new_key = new_entry[0..new_eq];
                var found = false;
                for (merged.items, 0..) |*existing, idx| {
                    const old_eq = std.mem.indexOf(u8, existing.*, "=") orelse existing.len;
                    if (std.mem.eql(u8, existing.*[0..old_eq], new_key)) {
                        allocator.free(existing.*);
                        merged.items[idx] = new_entry;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    merged.append(allocator, new_entry) catch continue;
                }
            }
            allocator.free(old_env);
            b.env = merged.toOwnedSlice(allocator) catch null;
            // Don't free new_env slice itself — entries are now owned by merged
            allocator.free(new_env);
        } else {
            b.env = new_env;
        }
    }
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
    _ = tailscale;
    _ = config;
}

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

pub const initscript = @import("initscript.zig");
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
        daemonize(cfg.log_dir);
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

    // Build effective layer list
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

    // Check build cache
    const cache_key = try computeBuildCacheKey(allocator, effective_layers.items);
    const cached_path = checkBuildCache(allocator, cfg.cache_dir, &cache_key);
    defer if (cached_path) |p| allocator.free(p);

    const use_cache = cached_path != null;
    if (use_cache) {
        scoped_log.info("Cache hit: {s}", .{cached_path.?});
    }

    // Build rootfs — from cache (single OCI layout) or from scratch (layer-by-layer)
    if (!use_cache) {
        switch (effective_layers.items[0]) {
            .image => |ref| scoped_log.info("Building rootfs from image {s}", .{ref}),
            .rootfs => |path| scoped_log.info("Building rootfs from {s}", .{path}),
        }
    }
    var builder = rootfs_builder.RootfsBuilder.init(allocator, cfg.cache_dir);

    // If cached, build from the cached OCI layout; otherwise from the first layer
    const build_result = if (use_cache)
        builder.buildFromImage(cached_path.?, .{
            .target_dir = cfg.work_dir,
            .skip_verify = true,
            .tmpfs_headroom = 1.5,
        })
    else
        builder.buildFromLayer(effective_layers.items[0], .{
            .target_dir = cfg.work_dir,
            .skip_verify = true,
            .tmpfs_headroom = 1.5 + 0.5 * @as(f64, @floatFromInt(effective_layers.items.len - 1)),
        });

    var result = build_result catch |err| {
        if (use_cache) {
            scoped_log.warn("Cache hit but build failed: {}", .{err});
        }
        if (err == error.InsufficientMemory) {
            scoped_log.err("Insufficient memory for in-memory rootfs", .{});
        }
        return err;
    };
    defer result.deinit(allocator);
    errdefer result.unmountTmpfs();

    scoped_log.info("Base rootfs: {} layers, {} bytes", .{
        result.layer_count,
        result.total_size,
    });

    // Thread ImageConfig through the merge loop: subsequent images overwrite on conflict
    var effective_config: ?rootfs_builder.BuildResult.ImageConfig = result.config;
    result.config = null;
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

    // Merge additional layers in order (skip if using cache — already merged)
    const layers_to_merge = if (use_cache) effective_layers.items[0..0] else effective_layers.items[1..];
    for (layers_to_merge) |layer| {
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

    // Execute RUN commands from containerfile (after rootfs is built)
    if (cf_result) |cfr| {
        for (cfr.run_commands) |argv| {
            oci_lib.run.executeInRootfs(allocator, cfg.work_dir, argv, null) catch |err| {
                scoped_log.err("RUN command failed: {}", .{err});
                return err;
            };
        }
        if (cfr.img_config) |ic| {
            mergeImageConfig(allocator, &effective_config, ic);
        }
    }

    // Auto-install packages for --ssh-port
    if (cfg.ssh_port != null) {
        scoped_log.info("Installing dropbear SSH server", .{});
        oci_lib.run.executeInRootfs(allocator, cfg.work_dir, &.{ "/bin/sh", "-c", "apk add --no-cache dropbear" }, null) catch |err| {
            scoped_log.warn("Failed to install dropbear: {} (image may not be alpine-based)", .{err});
        };
    }

    // Resolve effective entrypoint
    var resolved_cmd: []const u8 = undefined;
    var resolved_args: ?[]const []const u8 = null;
    if (cfg.entrypoint_explicit) {
        resolved_cmd = cfg.entrypoint;
        resolved_args = if (cfg.command.len > 0) cfg.command else null;
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

    // Build OCI image for hashing + save to cache
    oci_hash_blk: {
        const oci_dir = std.fmt.allocPrint(allocator, "{s}/builds/{s}", .{ cfg.cache_dir, &cache_key }) catch break :oci_hash_blk;
        defer allocator.free(oci_dir);

        if (!use_cache) {
            // Save build to cache
            saveBuildCache(allocator, cfg.cache_dir, &cache_key, cfg.work_dir, effective_config);
        }

        // Read back the manifest digest for display
        var digest_buf: [std.fs.max_path_bytes]u8 = undefined;
        const index_path = std.fmt.bufPrint(&digest_buf, "{s}/index.json", .{oci_dir}) catch break :oci_hash_blk;
        const index_file = std.fs.openFileAbsolute(index_path, .{}) catch break :oci_hash_blk;
        defer index_file.close();
        var index_buf: [4096]u8 = undefined;
        const n = index_file.readAll(&index_buf) catch break :oci_hash_blk;
        // Extract digest from index.json (contains sha256:...)
        if (std.mem.indexOf(u8, index_buf[0..n], "sha256:")) |start| {
            const end = std.mem.indexOfScalarPos(u8, index_buf[0..n], start + 7, '"') orelse n;
            scoped_log.info("OCI image: {s}", .{index_buf[start..end]});
        }
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

    // Create init script if any services are configured
    var final_exec_cmd: []const u8 = resolved_cmd;
    var final_exec_args: ?[]const []const u8 = resolved_args;

    const init_cfg = buildInitScriptConfig(allocator, cfg, effective_ts_args);
    if (init_cfg.hasServices() or init_cfg.flush_firewall) {
        scoped_log.info("Creating init script", .{});
        initscript.createInitScript(allocator, cfg.work_dir, &init_cfg) catch |err| {
            scoped_log.err("Failed to create init script: {}", .{err});
            return err;
        };

        // Wrap exec through the init script
        var new_args: std.ArrayListUnmanaged([]const u8) = .{};
        try new_args.append(std.heap.page_allocator, resolved_cmd);
        if (resolved_args) |ra| {
            try new_args.appendSlice(std.heap.page_allocator, ra);
        }
        final_exec_args = try new_args.toOwnedSlice(std.heap.page_allocator);
        final_exec_cmd = initscript.init_script_path;
    }

    if (cfg.systemd_mode) {
        scoped_log.info("Systemd mode: skipping init coordination and process termination", .{});
    } else {
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
            }
        }

        scoped_log.info("Terminating non-essential processes", .{});
        if (process_terminator.terminateAll(allocator, .{
            .graceful_timeout_ms = cfg.timeout * 1000,
        })) |term_result| {
            var r = term_result;
            scoped_log.info("Terminated {} processes ({} killed)", .{
                r.terminated_count,
                r.killed_count,
            });
            r.deinit(allocator);
        } else |err| {
            scoped_log.warn("Process termination failed: {}", .{err});
        }
    }

    // Check RAM before pivot — rootfs lives in tmpfs (RAM)
    {
        const rootfs_size = rootfs_builder.getDirSize(cfg.work_dir, allocator) catch 0;
        if (memory.getMemInfo()) |mem_info| {
            const available = mem_info.available;
            const total = mem_info.total;
            const used_pct = if (total > 0) (total - available) * 100 / total else 0;

            scoped_log.info("Rootfs size: {d}MB, RAM available: {d}MB/{d}MB ({d}% used)", .{
                rootfs_size / (1024 * 1024),
                available / (1024 * 1024),
                total / (1024 * 1024),
                used_pct,
            });

            // Error if less than 10% RAM would remain after accounting for rootfs
            const headroom = if (available > rootfs_size) available - rootfs_size else 0;
            const min_headroom = total / 10; // 10% of total
            if (headroom < min_headroom) {
                scoped_log.err("Insufficient RAM: rootfs uses {d}MB but only {d}MB available ({d}MB total)", .{
                    rootfs_size / (1024 * 1024),
                    available / (1024 * 1024),
                    total / (1024 * 1024),
                });
                scoped_log.err("The system needs at least 10% free RAM after pivot to function", .{});
                return error.InsufficientMemory;
            }

            // Warn if less than 25% would remain
            const warn_headroom = total / 4; // 25% of total
            if (headroom < warn_headroom) {
                scoped_log.warn("Low RAM: only {d}MB will remain free after pivot ({d}MB rootfs, {d}MB available)", .{
                    headroom / (1024 * 1024),
                    rootfs_size / (1024 * 1024),
                    available / (1024 * 1024),
                });
            }
        } else |_| {
            scoped_log.warn("Cannot read memory info, skipping RAM check", .{});
        }
    }

    scoped_log.info("Preparing pivot", .{});
    var prep_result = try pivot_prepare.prepare(.{
        .new_root = cfg.work_dir,
        .skip_verify = true, // Already verified
        .create_namespace = !cfg.skip_namespace,
    }, allocator);
    defer prep_result.deinit();

    scoped_log.info("Executing pivot_root", .{});
    // Write log buffer to the new rootfs before pivot (survives the exec)
    {
        const log_path = std.fmt.allocPrint(allocator, "{s}{s}/xenomorph.log", .{ cfg.work_dir, cfg.log_dir }) catch null;
        if (log_path) |lp| {
            defer allocator.free(lp);
            log.writeBufferToFile(lp);
        }
    }

    try pivot.executePivot(.{
        .new_root = cfg.work_dir,
        .old_root_mount = cfg.keep_old_root[1..], // Remove leading /
        .exec_cmd = final_exec_cmd,
        .exec_args = final_exec_args,
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
        } else if (layer == .image and std.mem.indexOf(u8, layer.image, "tailscale") != null) {
            try stdout.print("  {}: {s} ({s}, tailscale)\n", .{ i + 1, label, kind });
        } else {
            try stdout.print("  {}: {s} ({s})\n", .{ i + 1, label, kind });
        }
    }

    try stdout.print("\nEntrypoint: {s}\n", .{cfg.entrypoint});
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
    try stdout.print("  {}. Execute {s}\n", .{ step, cfg.entrypoint });

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

    // Build effective layer list
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

    for (effective_layers.items, 0..) |layer, i| {
        switch (layer) {
            .image => |ref| scoped_log.info("Layer {}/{}: image {s}", .{ i + 1, effective_layers.items.len, ref }),
            .rootfs => |path| scoped_log.info("Layer {}/{}: rootfs {s}", .{ i + 1, effective_layers.items.len, path }),
        }
    }

    // Build rootfs from first layer
    var builder = rootfs_builder.RootfsBuilder.init(allocator, cfg.cache_dir);
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

    // Execute RUN commands from containerfile
    if (cf_result_build) |cfr| {
        for (cfr.run_commands) |argv| {
            oci_lib.run.executeInRootfs(allocator, cfg.work_dir, argv, null) catch |err| {
                scoped_log.err("RUN command failed: {}", .{err});
                return err;
            };
        }
        if (cfr.img_config) |ic| {
            mergeImageConfig(allocator, &effective_config, ic);
        }
    }

    // Auto-install packages for --ssh-port
    if (cfg.ssh_port != null) {
        scoped_log.info("Installing dropbear SSH server", .{});
        oci_lib.run.executeInRootfs(allocator, cfg.work_dir, &.{ "/bin/sh", "-c", "apk add --no-cache dropbear" }, null) catch |err| {
            scoped_log.warn("Failed to install dropbear: {} (image may not be alpine-based)", .{err});
        };
    }

    // Create init script if any services are configured
    // Create init script only if services are configured (not for bare builds)
    {
        const effective_ts_args = resolveTailscaleArgs(allocator, cfg);
        const init_cfg = buildInitScriptConfig(allocator, cfg, effective_ts_args);
        if (init_cfg.hasServices()) {
            initscript.createInitScript(allocator, cfg.work_dir, &init_cfg) catch |err| {
                scoped_log.err("Failed to create init script: {}", .{err});
                return err;
            };
        }
    }

    // Save to cache
    const cache_key = try computeBuildCacheKey(allocator, effective_layers.items);
    saveBuildCache(allocator, cfg.cache_dir, &cache_key, cfg.work_dir, effective_config);
    scoped_log.info("Cached build: {s}", .{&cache_key});

    // Write OCI layout to output if requested
    if (cfg.output) |output_path| {
        scoped_log.info("Writing OCI layout to {s}", .{output_path});
        const oci_digest = try oci_layout_writer.writeOciLayout(allocator, cfg.work_dir, output_path, effective_config);
        scoped_log.info("OCI image: sha256:{s}", .{&oci_digest.manifest_digest});
    }

    // Optionally write rootfs tarball
    if (cfg.rootfs_output) |rootfs_path| {
        scoped_log.info("Writing rootfs tarball to {s}", .{rootfs_path});
        oci_layout_writer.createTarFromDir(cfg.work_dir, rootfs_path, allocator) catch |err| {
            scoped_log.err("Failed to create rootfs tarball: {}", .{err});
            return err;
        };
    }

    // Entrypoint validation (warning only for generate)
    if (!cfg.entrypoint_explicit) {
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

    if (cfg.output) |output_path| {
        scoped_log.info("Generated {s}", .{output_path});
    } else {
        scoped_log.info("Build cached (no output requested)", .{});
    }
}

const ContainerfileResult = struct {
    base_image: ?[]const u8,
    img_config: ?rootfs_builder.BuildResult.ImageConfig,
    /// RUN commands to execute after the rootfs is built
    run_commands: []const []const []const u8 = &.{},

    fn deinit(self: *ContainerfileResult, allocator: std.mem.Allocator) void {
        if (self.base_image) |bi| allocator.free(bi);
        for (self.run_commands) |argv| {
            for (argv) |a| allocator.free(a);
            allocator.free(argv);
        }
        if (self.run_commands.len > 0) allocator.free(self.run_commands);
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

    var run_commands: std.ArrayListUnmanaged([]const []const u8) = .{};
    defer run_commands.deinit(allocator);

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

                    const dest_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ work_dir, copy.dest });
                    defer allocator.free(dest_path);

                    // Create destination directory
                    if (std.fs.path.dirname(dest_path)) |parent| {
                        var root_dir = std.fs.openDirAbsolute("/", .{}) catch continue;
                        defer root_dir.close();
                        if (parent.len > 1) root_dir.makePath(parent[1..]) catch {};
                    }

                    rootfs_builder.copyDirRecursive(src_path, dest_path, allocator) catch |err| {
                        // May be a file, not a dir — try file copy
                        const src_file = std.fs.openFileAbsolute(src_path, .{}) catch {
                            scoped_log.warn("Failed to copy {s}: {}", .{ src, err });
                            continue;
                        };
                        defer src_file.close();
                        const dir_path = std.fs.path.dirname(dest_path) orelse "/";
                        var dst_dir = std.fs.openDirAbsolute(dir_path, .{}) catch continue;
                        defer dst_dir.close();
                        var dst_file = dst_dir.createFile(std.fs.path.basename(dest_path), .{}) catch continue;
                        defer dst_file.close();
                        var buf: [32768]u8 = undefined;
                        while (true) {
                            const n = src_file.readAll(&buf) catch break;
                            if (n == 0) break;
                            dst_file.writeAll(buf[0..n]) catch break;
                            if (n < buf.len) break;
                        }
                    };
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
            .run => |r| {
                // Collect RUN commands — they execute after the rootfs is built
                try run_commands.append(allocator, r.argv);
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

    if (run_commands.items.len > 0) {
        result.run_commands = try run_commands.toOwnedSlice(allocator);
    }

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
/// Compute a cache key from the effective layer list.
/// The key is a sha256 of the normalized layer descriptions.
fn computeBuildCacheKey(allocator: std.mem.Allocator, layers: []const config.Layer) ![64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    for (layers) |layer| {
        switch (layer) {
            .image => |ref| {
                hasher.update("image:");
                const normalized = config.normalizeImageRef(allocator, ref) catch ref;
                defer if (normalized.ptr != ref.ptr) allocator.free(normalized);
                hasher.update(normalized);
            },
            .rootfs => |path| {
                hasher.update("rootfs:");
                hasher.update(path);
            },
        }
        hasher.update("\n");
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// Check if a build with the given cache key exists.
/// Returns the path to the cached OCI layout directory, or null.
fn checkBuildCache(allocator: std.mem.Allocator, cache_dir: []const u8, key: []const u8) ?[]const u8 {
    const cache_path = std.fmt.allocPrint(allocator, "{s}/builds/{s}", .{ cache_dir, key }) catch return null;

    // Check if index.json exists in the cached build
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const index_path = std.fmt.bufPrint(&buf, "{s}/index.json", .{cache_path}) catch {
        allocator.free(cache_path);
        return null;
    };

    std.fs.accessAbsolute(index_path, .{}) catch {
        allocator.free(cache_path);
        return null;
    };

    return cache_path;
}

/// Save a built rootfs as a cached OCI layout.
fn saveBuildCache(allocator: std.mem.Allocator, cache_dir: []const u8, key: []const u8, rootfs_dir: []const u8, image_config: ?rootfs_builder.BuildResult.ImageConfig) void {
    const cache_path = std.fmt.allocPrint(allocator, "{s}/builds/{s}", .{ cache_dir, key }) catch return;
    defer allocator.free(cache_path);

    // Ensure cache directory structure exists
    {
        std.fs.makeDirAbsolute(cache_dir) catch |err| {
            if (err != error.PathAlreadyExists) {
                // Try creating parent dirs
                if (std.fs.path.dirname(cache_dir)) |parent| {
                    var root = std.fs.openDirAbsolute("/", .{}) catch return;
                    defer root.close();
                    if (parent.len > 1) root.makePath(parent[1..]) catch return;
                }
                std.fs.makeDirAbsolute(cache_dir) catch return;
            }
        };
        var dir = std.fs.openDirAbsolute(cache_dir, .{}) catch return;
        defer dir.close();
        dir.makePath("builds") catch return;
    }

    // Write OCI layout to cache
    _ = oci_layout_writer.writeOciLayout(allocator, rootfs_dir, cache_path, image_config) catch |err| {
        scoped_log.warn("Failed to save build cache: {}", .{err});
    };
}

fn readFileContent(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
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

/// Build an InitScriptConfig from the CLI config
fn buildInitScriptConfig(allocator: std.mem.Allocator, cfg: *const config.Config, effective_ts_args: []const u8) initscript.InitScriptConfig {
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
fn daemonize(log_dir: []const u8) void {
    const linux = std.os.linux;

    // Build log path
    var log_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const headless_log = std.fmt.bufPrint(&log_path_buf, "{s}/xenomorph.log", .{log_dir}) catch "/var/log/xenomorph.log";

    // Ensure log directory exists
    std.fs.makeDirAbsolute(log_dir) catch {};

    // Open log file (create/truncate, write-only)
    const log_fd = std.posix.open(
        headless_log,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    ) catch {
        std.debug.print("Error: cannot create {s}\n", .{headless_log});
        std.process.exit(1);
    };

    // Fork (aarch64 lacks fork syscall, use clone with SIGCHLD instead)
    const fork_result = if (@hasField(linux.SYS, "fork"))
        linux.syscall0(.fork)
    else
        linux.syscall5(.clone, linux.SIG.CHLD, 0, 0, 0, 0);
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
    _ = initscript;
    _ = config;
}

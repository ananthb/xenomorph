const std = @import("std");
const log = @import("../util/log.zig");
const config = @import("../config.zig");
const oci_lib = @import("oci");
const rootfs_builder = @import("../rootfs/builder.zig");
const rootfs_verify = @import("../rootfs/verify.zig");
const memory = @import("../util/memory.zig");
const initscript = @import("../initscript.zig");
const init_detector = @import("../init/detector.zig");
const init_interface = @import("../init/interface.zig");
const process_terminator = @import("../process/terminator.zig");
const pivot_prepare = @import("../pivot/prepare.zig");
const pivot = @import("../pivot/pivot.zig");
const containerfile_exec = @import("containerfile_exec.zig");
const cache = @import("../cache.zig");
const helpers = @import("../helpers.zig");

const ContainerfileResult = containerfile_exec.ContainerfileResult;
const mergeImageConfig = containerfile_exec.mergeImageConfig;
const computeBuildCacheKey = cache.computeBuildCacheKey;
const checkBuildCache = cache.checkBuildCache;
const saveBuildCache = cache.saveBuildCache;
const buildInitScriptConfig = helpers.buildInitScriptConfig;

const scoped_log = log.scoped("cmd/pivot");

pub fn runPivot(allocator: std.mem.Allocator, cfg: *const config.Config, effective_ts_args: []const u8) !void {
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
        cf_result = containerfile_exec.executeContainerfile(allocator, cf_path, context_dir, cfg.work_dir) catch |err| {
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

pub fn dryRun(allocator: std.mem.Allocator, cfg: *const config.Config, effective_ts_args: []const u8, layers: []const config.Layer) !void {
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

pub fn confirmPivot() !bool {
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

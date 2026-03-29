const std = @import("std");
const log = @import("../util/log.zig");
const config = @import("../config.zig");
const oci_lib = @import("runz");
const rootfs_builder = @import("../rootfs/builder.zig");
const initscript = @import("../initscript.zig");
const oci_layout_writer = oci_lib.layout_writer;
const containerfile_exec = @import("containerfile_exec.zig");
const cache = @import("../cache.zig");
const helpers = @import("../helpers.zig");

const ContainerfileResult = containerfile_exec.ContainerfileResult;
const mergeImageConfig = containerfile_exec.mergeImageConfig;
const computeBuildCacheKey = cache.computeBuildCacheKey;
const saveBuildCache = cache.saveBuildCache;
const buildInitScriptConfig = helpers.buildInitScriptConfig;
const resolveTailscaleArgs = helpers.resolveTailscaleArgs;

const scoped_log = log.scoped("cmd/build");

pub fn runBuild(allocator: std.mem.Allocator, cfg: *const config.Config) !void {
    scoped_log.info("Building OCI image", .{});

    // Handle containerfile if specified
    var cf_result_build: ?ContainerfileResult = null;
    defer if (cf_result_build) |*cfr| cfr.deinit(allocator);

    if (cfg.containerfile) |cf_path| {
        const context_dir = cfg.context orelse blk: {
            break :blk std.fs.path.dirname(cf_path) orelse ".";
        };
        scoped_log.info("Building from containerfile: {s}", .{cf_path});
        cf_result_build = containerfile_exec.executeContainerfile(allocator, cf_path, context_dir, cfg.work_dir) catch |err| {
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
            oci_lib.run.executeInRootfs(allocator, cfg.work_dir, argv, null, .{}) catch |err| {
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
        oci_lib.run.executeInRootfs(allocator, cfg.work_dir, &.{ "/bin/sh", "-c", "apk add --no-cache dropbear" }, null, .{}) catch |err| {
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

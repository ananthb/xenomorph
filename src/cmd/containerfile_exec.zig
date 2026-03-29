const std = @import("std");
const log = @import("../util/log.zig");
const oci_lib = @import("runz");
const rootfs_builder = @import("../rootfs/builder.zig");
const oci_containerfile = oci_lib.containerfile;

const scoped_log = log.scoped("containerfile");

pub const ContainerfileResult = struct {
    base_image: ?[]const u8,
    img_config: ?rootfs_builder.BuildResult.ImageConfig,
    /// RUN commands to execute after the rootfs is built
    run_commands: []const []const []const u8 = &.{},

    pub fn deinit(self: *ContainerfileResult, allocator: std.mem.Allocator) void {
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

pub fn executeContainerfile(
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
pub fn mergeImageConfig(
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

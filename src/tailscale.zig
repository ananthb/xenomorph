const std = @import("std");
const builtin = @import("builtin");
const log = @import("util/log.zig");
const oci_registry = @import("oci/registry.zig");

const scoped_log = log.scoped("tailscale");

pub const TailscaleError = error{
    PlatformNotSupported,
    BinaryNotFound,
    InjectionFailed,
    OutOfMemory,
};

const tmp_base = "/tmp/xenomorph-tailscale";

/// Fetches tailscale/tailscaled binaries from docker.io/tailscale/tailscale
/// and injects them into a rootfs with an auto-start wrapper script.
pub const TailscaleInjector = struct {
    allocator: std.mem.Allocator,
    authkey: []const u8,
    args: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, authkey: []const u8, args: []const u8) Self {
        return .{
            .allocator = allocator,
            .authkey = authkey,
            .args = args,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    /// Fetch tailscale binaries from Docker Hub and inject into rootfs
    pub fn inject(self: *Self, rootfs_path: []const u8) TailscaleError!void {
        scoped_log.info("Injecting Tailscale into rootfs at {s}", .{rootfs_path});

        // Set up temp directory
        std.fs.deleteTreeAbsolute(tmp_base) catch {};
        std.fs.makeDirAbsolute(tmp_base) catch return error.InjectionFailed;
        errdefer std.fs.deleteTreeAbsolute(tmp_base) catch {};

        // Create registry client for Docker Hub
        var client = oci_registry.RegistryClient.init(self.allocator, "registry-1.docker.io");
        defer client.deinit();

        // Authenticate
        client.ensureAuth("tailscale/tailscale") catch {
            scoped_log.err("Failed to authenticate with Docker Hub", .{});
            return error.InjectionFailed;
        };
        scoped_log.info("Authenticated with Docker Hub", .{});

        // Resolve platform-specific manifest
        const resolved = client.resolveForPlatform("tailscale/tailscale", "latest") catch |err| {
            if (err == error.PlatformNotSupported) return error.PlatformNotSupported;
            scoped_log.err("Failed to resolve manifest: {}", .{err});
            return error.InjectionFailed;
        };
        defer resolved.deinit(self.allocator);

        scoped_log.info("Resolved platform manifest: {s}", .{
            resolved.digest[0..@min(resolved.digest.len, 24)],
        });

        // Parse manifest for layers
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            resolved.body,
            .{},
        ) catch return error.InjectionFailed;
        defer parsed.deinit();

        const layers = parsed.value.object.get("layers") orelse
            return error.InjectionFailed;

        var layer_list: std.ArrayListUnmanaged(Self.LayerInfo) = .{};
        defer layer_list.deinit(self.allocator);

        for (layers.array.items) |layer| {
            const digest = layer.object.get("digest") orelse continue;
            const mt = layer.object.get("mediaType") orelse continue;
            layer_list.append(self.allocator, .{
                .digest = digest.string,
                .media_type = mt.string,
            }) catch return error.OutOfMemory;
        }

        scoped_log.info("Image has {} layers", .{layer_list.items.len});

        // Download layers and extract tailscale binaries
        try self.extractFromLayers(&client, layer_list.items, rootfs_path);

        // Clean up
        std.fs.deleteTreeAbsolute(tmp_base) catch {};
        scoped_log.info("Tailscale injection complete", .{});
    }

    /// Create the startup wrapper script that starts tailscaled and authenticates
    /// before exec'ing the user's command
    pub fn createStartupScript(self: *Self, rootfs_path: []const u8) TailscaleError!void {
        const script_path = std.fmt.allocPrint(
            self.allocator,
            "{s}/usr/local/bin/xenomorph-ts-init",
            .{rootfs_path},
        ) catch return error.OutOfMemory;
        defer self.allocator.free(script_path);

        const script_content = std.fmt.allocPrint(self.allocator,
            \\#!/bin/sh
            \\# Xenomorph Tailscale init - starts tailscaled and authenticates before exec
            \\set -e
            \\mkdir -p /var/lib/tailscale /var/run/tailscale
            \\/usr/local/bin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
            \\# Wait for tailscaled socket (up to 5 seconds)
            \\i=0
            \\while [ ! -S /var/run/tailscale/tailscaled.sock ] && [ "$i" -lt 50 ]; do
            \\  sleep 0.1
            \\  i=$((i+1))
            \\done
            \\if [ ! -S /var/run/tailscale/tailscaled.sock ]; then
            \\  echo "xenomorph: warning: tailscaled failed to start" >&2
            \\  exec "$@"
            \\fi
            \\/usr/local/bin/tailscale --socket=/var/run/tailscale/tailscaled.sock up --authkey='{s}' {s}
            \\exec "$@"
            \\
        , .{ self.authkey, self.args }) catch return error.OutOfMemory;
        defer self.allocator.free(script_content);

        // Write the script file
        const dir_path = std.fs.path.dirname(script_path) orelse "/";
        var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return error.InjectionFailed;
        defer dir.close();

        var file = dir.createFile(std.fs.path.basename(script_path), .{}) catch
            return error.InjectionFailed;
        defer file.close();

        file.writeAll(script_content) catch return error.InjectionFailed;

        // Make executable
        try self.runCmd(&.{ "chmod", "+x", script_path });

        scoped_log.info("Created startup script at /usr/local/bin/xenomorph-ts-init", .{});
    }

    // ---- Private helpers ----

    const LayerInfo = struct { digest: []const u8, media_type: []const u8 };

    fn extractFromLayers(
        self: *Self,
        client: *oci_registry.RegistryClient,
        layer_list: []const LayerInfo,
        rootfs_path: []const u8,
    ) TailscaleError!void {
        const extract_dir = tmp_base ++ "/extract";
        std.fs.makeDirAbsolute(extract_dir) catch return error.InjectionFailed;

        const layer_file = tmp_base ++ "/layer.tar";

        var found_tailscale = false;
        var found_tailscaled = false;

        for (layer_list) |layer| {
            if (found_tailscale and found_tailscaled) break;

            scoped_log.info("Downloading layer {s}...", .{
                layer.digest[0..@min(layer.digest.len, 19)],
            });

            client.downloadBlobToFile("tailscale/tailscale", layer.digest, layer_file) catch |err| {
                scoped_log.warn("Failed to download layer: {}", .{err});
                continue;
            };
            defer std.fs.deleteFileAbsolute(layer_file) catch {};

            // Determine decompression flag from media type
            const decompress_flag: ?[]const u8 =
                if (std.mem.indexOf(u8, layer.media_type, "gzip") != null)
                    "-z"
                else if (std.mem.indexOf(u8, layer.media_type, "zstd") != null)
                    "--zstd"
                else
                    null;

            // Try extracting tailscale binaries from this layer
            var argv_buf: [10][]const u8 = undefined;
            var argc: usize = 0;
            argv_buf[argc] = "tar";
            argc += 1;
            argv_buf[argc] = "-x";
            argc += 1;
            if (decompress_flag) |flag| {
                argv_buf[argc] = flag;
                argc += 1;
            }
            argv_buf[argc] = "-f";
            argc += 1;
            argv_buf[argc] = layer_file;
            argc += 1;
            argv_buf[argc] = "-C";
            argc += 1;
            argv_buf[argc] = extract_dir;
            argc += 1;
            argv_buf[argc] = "usr/local/bin/tailscale";
            argc += 1;
            argv_buf[argc] = "usr/local/bin/tailscaled";
            argc += 1;

            var child = std.process.Child.init(argv_buf[0..argc], self.allocator);
            child.stderr_behavior = .Pipe;
            child.spawn() catch continue;
            _ = child.wait() catch continue;

            // Check what we found
            if (!found_tailscale) {
                if (std.fs.accessAbsolute(extract_dir ++ "/usr/local/bin/tailscale", .{})) |_| {
                    found_tailscale = true;
                    scoped_log.info("Found tailscale binary", .{});
                } else |_| {}
            }
            if (!found_tailscaled) {
                if (std.fs.accessAbsolute(extract_dir ++ "/usr/local/bin/tailscaled", .{})) |_| {
                    found_tailscaled = true;
                    scoped_log.info("Found tailscaled binary", .{});
                } else |_| {}
            }
        }

        if (!found_tailscale or !found_tailscaled) {
            scoped_log.err(
                "Tailscale binaries not found in image (tailscale={}, tailscaled={})",
                .{ found_tailscale, found_tailscaled },
            );
            return error.BinaryNotFound;
        }

        // Create target directory in rootfs
        {
            var dir = std.fs.openDirAbsolute(rootfs_path, .{}) catch
                return error.InjectionFailed;
            defer dir.close();
            dir.makePath("usr/local/bin") catch return error.InjectionFailed;
        }

        // Copy binaries into rootfs
        const dst_ts = std.fmt.allocPrint(
            self.allocator,
            "{s}/usr/local/bin/tailscale",
            .{rootfs_path},
        ) catch return error.OutOfMemory;
        defer self.allocator.free(dst_ts);

        const dst_tsd = std.fmt.allocPrint(
            self.allocator,
            "{s}/usr/local/bin/tailscaled",
            .{rootfs_path},
        ) catch return error.OutOfMemory;
        defer self.allocator.free(dst_tsd);

        try self.runCmd(&.{ "cp", extract_dir ++ "/usr/local/bin/tailscale", dst_ts });
        try self.runCmd(&.{ "cp", extract_dir ++ "/usr/local/bin/tailscaled", dst_tsd });
        try self.runCmd(&.{ "chmod", "+x", dst_ts });
        try self.runCmd(&.{ "chmod", "+x", dst_tsd });

        scoped_log.info("Tailscale binaries installed to rootfs", .{});
    }

    fn runCmd(self: *Self, argv: []const []const u8) TailscaleError!void {
        var child = std.process.Child.init(argv, self.allocator);
        child.spawn() catch return error.InjectionFailed;
        const term = child.wait() catch return error.InjectionFailed;
        switch (term) {
            .Exited => |code| {
                if (code != 0) return error.InjectionFailed;
            },
            else => return error.InjectionFailed,
        }
    }
};

test "platform detection" {
    const arch = oci_registry.getPlatformArch();
    const testing = std.testing;

    // Should return a valid architecture on supported platforms
    if (arch) |a| {
        try testing.expect(a.len > 0);
    }
}

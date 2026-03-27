const std = @import("std");
const log = @import("util/log.zig");

const scoped_log = log.scoped("tailscale");

pub const TailscaleError = error{
    InjectionFailed,
    OutOfMemory,
};

/// Creates the Tailscale startup wrapper script in a rootfs.
/// The tailscale binaries themselves come from merging the tailscale OCI image.
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

        // Ensure directory exists
        {
            var dir = std.fs.openDirAbsolute(rootfs_path, .{}) catch return error.InjectionFailed;
            defer dir.close();
            dir.makePath("usr/local/bin") catch return error.InjectionFailed;
        }

        // Write the script file
        const dir_path = std.fs.path.dirname(script_path) orelse "/";
        var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return error.InjectionFailed;
        defer dir.close();

        var file = dir.createFile(std.fs.path.basename(script_path), .{}) catch
            return error.InjectionFailed;
        defer file.close();

        file.writeAll(script_content) catch return error.InjectionFailed;

        // Make executable
        var child = std.process.Child.init(&.{ "chmod", "+x", script_path }, self.allocator);
        child.spawn() catch return error.InjectionFailed;
        const term = child.wait() catch return error.InjectionFailed;
        switch (term) {
            .Exited => |code| {
                if (code != 0) return error.InjectionFailed;
            },
            else => return error.InjectionFailed,
        }

        scoped_log.info("Created startup script at /usr/local/bin/xenomorph-ts-init", .{});
    }
};

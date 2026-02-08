const std = @import("std");
const log = @import("util/log.zig");

const scoped_log = log.scoped("config");

/// Main configuration for xenomorph
pub const Config = struct {
    /// OCI image reference (local path or registry URL)
    image: []const u8,

    /// Command to execute post-pivot
    exec_cmd: []const u8 = "/bin/sh",

    /// Arguments for exec command
    exec_args: []const []const u8 = &.{},

    /// Mount point for old root
    keep_old_root: []const u8 = "/mnt/oldroot",

    /// Skip confirmation prompts
    force: bool = false,

    /// Timeout for service shutdown in seconds
    timeout: u32 = 30,

    /// Skip init system coordination
    no_init_coord: bool = false,

    /// Verbose output
    verbose: bool = false,

    /// Dry run mode
    dry_run: bool = false,

    /// Don't keep old root accessible
    no_keep_old_root: bool = false,

    /// Skip rootfs verification
    skip_verify: bool = false,

    /// Cache directory for OCI layers
    cache_dir: []const u8 = "/var/cache/xenomorph",

    /// Working directory for extraction
    work_dir: []const u8 = "/var/lib/xenomorph/rootfs",

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        _ = allocator;
        _ = self;
        // Strings are from argv, don't free them
    }
};

/// Parse command line arguments
pub fn parseArgs(allocator: std.mem.Allocator) !?Config {
    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // Skip program name
    _ = args.next();

    // Check for subcommand
    const subcommand = args.next() orelse {
        printUsage();
        return null;
    };

    if (std.mem.eql(u8, subcommand, "pivot")) {
        return try parsePivotArgs(&args);
    } else if (std.mem.eql(u8, subcommand, "help") or
        std.mem.eql(u8, subcommand, "--help") or
        std.mem.eql(u8, subcommand, "-h"))
    {
        printUsage();
        return null;
    } else if (std.mem.eql(u8, subcommand, "version") or
        std.mem.eql(u8, subcommand, "--version") or
        std.mem.eql(u8, subcommand, "-V"))
    {
        printVersion();
        return null;
    } else {
        std.debug.print("Unknown subcommand: {s}\n\n", .{subcommand});
        printUsage();
        return null;
    }
}

fn parsePivotArgs(args: *std.process.ArgIterator) !Config {
    var cfg = Config{
        .image = "",
    };

    var exec_args_list: std.ArrayListUnmanaged([]const u8) = .{};
    defer exec_args_list.deinit(std.heap.page_allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--image")) {
            cfg.image = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--exec")) {
            cfg.exec_cmd = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--keep-old-root")) {
            cfg.keep_old_root = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--force") or std.mem.eql(u8, arg, "-f")) {
            cfg.force = true;
        } else if (std.mem.eql(u8, arg, "--timeout")) {
            const timeout_str = args.next() orelse return error.MissingValue;
            cfg.timeout = try std.fmt.parseInt(u32, timeout_str, 10);
        } else if (std.mem.eql(u8, arg, "--no-init-coord")) {
            cfg.no_init_coord = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            cfg.verbose = true;
        } else if (std.mem.eql(u8, arg, "--dry-run") or std.mem.eql(u8, arg, "-n")) {
            cfg.dry_run = true;
        } else if (std.mem.eql(u8, arg, "--no-keep-old-root")) {
            cfg.no_keep_old_root = true;
        } else if (std.mem.eql(u8, arg, "--skip-verify")) {
            cfg.skip_verify = true;
        } else if (std.mem.eql(u8, arg, "--cache-dir")) {
            cfg.cache_dir = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            cfg.work_dir = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--")) {
            // Everything after -- is exec args
            while (args.next()) |exec_arg| {
                try exec_args_list.append(std.heap.page_allocator, exec_arg);
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Positional argument is the image
            if (cfg.image.len == 0) {
                cfg.image = arg;
            } else {
                try exec_args_list.append(std.heap.page_allocator, arg);
            }
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.UnknownOption;
        }
    }

    if (cfg.image.len == 0) {
        std.debug.print("Error: image is required\n\n", .{});
        printUsage();
        return error.MissingImage;
    }

    if (exec_args_list.items.len > 0) {
        cfg.exec_args = try exec_args_list.toOwnedSlice(std.heap.page_allocator);
    }

    return cfg;
}

fn printUsage() void {
    const usage =
        \\xenomorph - Pivot root to an OCI-based rootfs
        \\
        \\USAGE:
        \\    xenomorph pivot <image> [options]
        \\    xenomorph pivot --image <ref> [options]
        \\
        \\ARGUMENTS:
        \\    <image>                   OCI image reference (local path or registry URL)
        \\
        \\OPTIONS:
        \\    --image <ref>             OCI image reference (alternative to positional)
        \\    --exec <cmd>              Command to execute post-pivot (default: /bin/sh)
        \\    --keep-old-root <path>    Mount point for old root (default: /mnt/oldroot)
        \\    --no-keep-old-root        Don't keep old root accessible
        \\    -f, --force               Skip confirmation prompts
        \\    --timeout <seconds>       Timeout for service shutdown (default: 30)
        \\    --no-init-coord           Skip init system coordination (dangerous)
        \\    --skip-verify             Skip rootfs verification
        \\    --cache-dir <path>        Cache directory for OCI layers
        \\    --work-dir <path>         Working directory for extraction
        \\    -v, --verbose             Verbose output
        \\    -n, --dry-run             Show what would be done without executing
        \\    -- <args>...              Arguments to pass to exec command
        \\
        \\EXAMPLES:
        \\    # Pivot to a local tarball
        \\    xenomorph pivot ./rootfs.tar --exec /bin/bash
        \\
        \\    # Pivot to a registry image
        \\    xenomorph pivot alpine:latest
        \\
        \\    # Pivot with custom old root location
        \\    xenomorph pivot ubuntu:22.04 --keep-old-root /old
        \\
        \\SUBCOMMANDS:
        \\    pivot       Execute pivot_root to new rootfs
        \\    help        Show this help message
        \\    version     Show version information
        \\
    ;
    std.debug.print("{s}", .{usage});
}

fn printVersion() void {
    std.debug.print("xenomorph 0.1.0\n", .{});
}

/// Load configuration from file
pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    var buf: [8192]u8 = undefined;
    const n = try file.readAll(&buf);

    return parseConfigFile(allocator, buf[0..n]);
}

fn parseConfigFile(allocator: std.mem.Allocator, content: []const u8) !Config {
    _ = allocator;

    var config = Config{
        .image = "",
    };

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_idx| {
            const key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
            const value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t\"'");

            if (std.mem.eql(u8, key, "image")) {
                config.image = value;
            } else if (std.mem.eql(u8, key, "exec")) {
                config.exec_cmd = value;
            } else if (std.mem.eql(u8, key, "keep_old_root")) {
                config.keep_old_root = value;
            } else if (std.mem.eql(u8, key, "timeout")) {
                config.timeout = try std.fmt.parseInt(u32, value, 10);
            } else if (std.mem.eql(u8, key, "force")) {
                config.force = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "verbose")) {
                config.verbose = std.mem.eql(u8, value, "true");
            }
        }
    }

    return config;
}

/// Validate configuration
pub fn validate(config: *const Config) !void {
    if (config.image.len == 0) {
        return error.MissingImage;
    }

    if (config.timeout == 0) {
        return error.InvalidTimeout;
    }
}

test "parse empty config" {
    const config = Config{
        .image = "alpine:latest",
    };

    const testing = std.testing;
    try testing.expectEqualStrings("/bin/sh", config.exec_cmd);
    try testing.expectEqualStrings("/mnt/oldroot", config.keep_old_root);
    try testing.expectEqual(@as(u32, 30), config.timeout);
}

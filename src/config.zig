const std = @import("std");
const log = @import("util/log.zig");

const scoped_log = log.scoped("config");

/// A layer source for the rootfs, either a local path or an OCI image reference.
pub const Layer = union(enum) {
    /// OCI image reference (pulled from registry)
    image: []const u8,
    /// Local rootfs directory or tarball
    rootfs: []const u8,
};

pub const Subcommand = enum { pivot, build };

/// Main configuration for xenomorph
pub const Config = struct {
    /// Which subcommand was invoked
    subcommand: Subcommand = .pivot,

    /// Ordered list of layers to merge into the rootfs (later wins on conflict)
    layers: []const Layer = &.{.{ .image = "docker.io/library/alpine:latest" }},

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

    /// Skip mount namespace creation (for testing)
    skip_namespace: bool = false,

    /// Cache directory for OCI layers
    cache_dir: []const u8 = "/var/cache/xenomorph",

    /// Working directory for extraction
    work_dir: []const u8 = "/var/lib/xenomorph/rootfs",

    /// Output path for generate subcommand (OCI layout directory)
    output: []const u8 = "rootfs.oci",

    /// Optional additional rootfs tarball output for generate
    rootfs_output: ?[]const u8 = null,

    /// Whether --exec was explicitly set by the user
    exec_cmd_explicit: bool = false,

    /// Headless mode: fork, detach from terminal, log to file.
    /// Survives SSH disconnection. Implies --force.
    headless: bool = false,

    /// Path to Containerfile/Dockerfile
    containerfile: ?[]const u8 = null,

    /// Build context directory (default: directory containing containerfile)
    context: ?[]const u8 = null,

    /// Enable Tailscale integration (set implicitly by --tailscale-authkey)
    tailscale: ?bool = null,

    /// Tailscale auth key (implies --tailscale)
    tailscale_authkey: ?[]const u8 = null,

    /// Arguments for 'tailscale up' (null = auto-generate with --ssh --hostname)
    tailscale_args: ?[]const u8 = null,

    /// Check if tailscale integration is effectively enabled
    pub fn tailscaleEnabled(self: *const Config) bool {
        if (self.tailscale) |ts| return ts;
        return self.tailscale_authkey != null;
    }

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
    } else if (std.mem.eql(u8, subcommand, "build")) {
        return try parseBuildArgs(&args);
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
    var cfg = Config{};

    var layers_list: std.ArrayListUnmanaged(Layer) = .{};
    defer layers_list.deinit(std.heap.page_allocator);

    var exec_args_list: std.ArrayListUnmanaged([]const u8) = .{};
    defer exec_args_list.deinit(std.heap.page_allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--image")) {
            try layers_list.append(std.heap.page_allocator, .{ .image = args.next() orelse return error.MissingValue });
        } else if (std.mem.eql(u8, arg, "--rootfs")) {
            try layers_list.append(std.heap.page_allocator, .{ .rootfs = args.next() orelse return error.MissingValue });
        } else if (std.mem.eql(u8, arg, "--exec")) {
            cfg.exec_cmd = args.next() orelse return error.MissingValue;
            cfg.exec_cmd_explicit = true;
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
        } else if (std.mem.eql(u8, arg, "--skip-namespace")) {
            cfg.skip_namespace = true;
        } else if (std.mem.eql(u8, arg, "--cache-dir")) {
            cfg.cache_dir = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            cfg.work_dir = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            cfg.headless = true;
            cfg.force = true;
        } else if (std.mem.eql(u8, arg, "--containerfile") or std.mem.eql(u8, arg, "--dockerfile")) {
            cfg.containerfile = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--context")) {
            cfg.context = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--tailscale") or std.mem.eql(u8, arg, "--tailscale=true")) {
            cfg.tailscale = true;
        } else if (std.mem.eql(u8, arg, "--tailscale=false") or std.mem.eql(u8, arg, "--no-tailscale")) {
            cfg.tailscale = false;
        } else if (std.mem.eql(u8, arg, "--tailscale-authkey")) {
            cfg.tailscale_authkey = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--tailscale-args")) {
            cfg.tailscale_args = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--")) {
            // Everything after -- is exec args
            while (args.next()) |exec_arg| {
                try exec_args_list.append(std.heap.page_allocator, exec_arg);
            }
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.UnknownOption;
        }
    }

    if (layers_list.items.len > 0) {
        cfg.layers = try layers_list.toOwnedSlice(std.heap.page_allocator);
    }

    if (exec_args_list.items.len > 0) {
        cfg.exec_args = try exec_args_list.toOwnedSlice(std.heap.page_allocator);
    }

    return cfg;
}

fn parseBuildArgs(args: *std.process.ArgIterator) !Config {
    var cfg = Config{ .subcommand = .build };

    var layers_list: std.ArrayListUnmanaged(Layer) = .{};
    defer layers_list.deinit(std.heap.page_allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--image")) {
            try layers_list.append(std.heap.page_allocator, .{ .image = args.next() orelse return error.MissingValue });
        } else if (std.mem.eql(u8, arg, "--rootfs")) {
            try layers_list.append(std.heap.page_allocator, .{ .rootfs = args.next() orelse return error.MissingValue });
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            cfg.output = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--rootfs-output")) {
            cfg.rootfs_output = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            cfg.verbose = true;
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            cfg.work_dir = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--containerfile") or std.mem.eql(u8, arg, "--dockerfile")) {
            cfg.containerfile = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--context")) {
            cfg.context = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--tailscale") or std.mem.eql(u8, arg, "--tailscale=true")) {
            cfg.tailscale = true;
        } else if (std.mem.eql(u8, arg, "--tailscale-authkey")) {
            cfg.tailscale_authkey = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--tailscale-args")) {
            cfg.tailscale_args = args.next() orelse return error.MissingValue;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.UnknownOption;
        }
    }

    if (layers_list.items.len > 0) {
        cfg.layers = try layers_list.toOwnedSlice(std.heap.page_allocator);
    }

    return cfg;
}

fn printUsage() void {
    const usage =
        \\xenomorph - Pivot root to an OCI-based rootfs
        \\
        \\USAGE:
        \\    xenomorph pivot [options]
        \\
        \\LAYERS (merged in order, later wins on conflict):
        \\    --image <ref>             OCI image from registry (repeatable)
        \\    --rootfs <path>           Local rootfs directory or tarball (repeatable)
        \\                              (default: --image docker.io/library/alpine:latest)
        \\
        \\OPTIONS:
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
        \\    --headless                Detach from terminal (survives SSH disconnect)
        \\    --containerfile <path>    Build from Containerfile/Dockerfile
        \\    --dockerfile <path>       Alias for --containerfile
        \\    --context <dir>           Build context directory (default: containerfile dir)
        \\    -- <args>...              Arguments to pass to exec command
        \\
        \\TAILSCALE:
        \\    --tailscale-authkey <key> Tailscale auth key (enables Tailscale integration)
        \\    --tailscale-args <args>   Arguments for 'tailscale up'
        \\                              (default: --ssh --hostname=<hostname>-xenomorph)
        \\    --tailscale               Explicitly enable Tailscale
        \\    --no-tailscale            Disable Tailscale (overrides --tailscale-authkey)
        \\
        \\EXAMPLES:
        \\    # Pivot to alpine (default)
        \\    xenomorph pivot
        \\
        \\    # Pivot to a specific image
        \\    xenomorph pivot --image ubuntu:22.04
        \\
        \\    # Merge a local rootfs tarball with a registry image
        \\    xenomorph pivot --rootfs ./base.tar.gz --image myapp:latest
        \\
        \\    # Headless pivot over SSH with Tailscale
        \\    xenomorph pivot --headless --tailscale-authkey tskey-auth-xxxxx
        \\
        \\BUILD:
        \\    xenomorph build [--image <ref>...] [--rootfs <path>...] [-o <dir>]
        \\    -o, --output <dir>        Output OCI layout directory (default: rootfs.oci)
        \\    --rootfs-output <file>    Also write a rootfs tarball
        \\
        \\SUBCOMMANDS:
        \\    pivot       Execute pivot_root to new rootfs
        \\    build       Build OCI image without pivoting
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

    var cfg = Config{};

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOf(u8, trimmed, "=")) |eq_idx| {
            const key = std.mem.trim(u8, trimmed[0..eq_idx], " \t");
            const value = std.mem.trim(u8, trimmed[eq_idx + 1 ..], " \t\"'");

            if (std.mem.eql(u8, key, "image")) {
                cfg.layers = &.{.{ .image = value }};
            } else if (std.mem.eql(u8, key, "exec")) {
                cfg.exec_cmd = value;
            } else if (std.mem.eql(u8, key, "keep_old_root")) {
                cfg.keep_old_root = value;
            } else if (std.mem.eql(u8, key, "timeout")) {
                cfg.timeout = try std.fmt.parseInt(u32, value, 10);
            } else if (std.mem.eql(u8, key, "force")) {
                cfg.force = std.mem.eql(u8, value, "true");
            } else if (std.mem.eql(u8, key, "verbose")) {
                cfg.verbose = std.mem.eql(u8, value, "true");
            }
        }
    }

    return cfg;
}

/// Validate configuration
pub fn validate(cfg: *const Config) !void {
    if (cfg.timeout == 0) {
        return error.InvalidTimeout;
    }

    if (cfg.tailscaleEnabled() and cfg.tailscale_authkey == null) {
        std.debug.print("Error: --tailscale requires --tailscale-authkey\n", .{});
        return error.TailscaleMissingAuthkey;
    }

    if (cfg.headless and !cfg.tailscaleEnabled()) {
        std.debug.print("Error: --headless requires an alternative login method (e.g. --tailscale-authkey)\n", .{});
        return error.HeadlessRequiresLoginMethod;
    }
}

test "default config" {
    const cfg = Config{};

    const testing = std.testing;
    try testing.expectEqual(@as(usize, 1), cfg.layers.len);
    try testing.expectEqualStrings("docker.io/library/alpine:latest", cfg.layers[0].image);
    try testing.expectEqualStrings("/bin/sh", cfg.exec_cmd);
    try testing.expectEqualStrings("/mnt/oldroot", cfg.keep_old_root);
    try testing.expectEqual(@as(u32, 30), cfg.timeout);
    try testing.expectEqualStrings("rootfs.oci", cfg.output);
    try testing.expect(!cfg.exec_cmd_explicit);
    try testing.expect(cfg.rootfs_output == null);
}

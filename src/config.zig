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

    /// Entrypoint command for the new rootfs
    entrypoint: []const u8 = "/bin/sh",

    /// Command/arguments passed to entrypoint
    command: []const []const u8 = &.{},

    /// Keep old root mounted at /mnt/oldroot (default: true)
    keep_old_root: bool = true,

    /// Run in a container (mount+PID ns, host network) instead of a real pivot.
    /// The host is unaffected — useful for testing.
    contain: bool = false,

    /// Skip confirmation prompts
    force: bool = false,

    /// Timeout for service shutdown in seconds
    timeout: u32 = 30,

    /// Skip init system coordination
    no_init_coord: bool = false,

    /// Systemd service mode: skip init coordination and process termination
    /// (assumes systemd has already isolated to rescue.target)
    systemd_mode: bool = false,

    /// Verbose output
    verbose: bool = false,

    /// Dry run mode
    dry_run: bool = false,

    /// Skip rootfs verification
    skip_verify: bool = false,

    /// Skip build cache (force fresh pull/build)
    no_cache: bool = false,

    /// Cache directory for OCI layers
    cache_dir: []const u8 = "/var/cache/xenomorph",

    /// Working directory for rootfs extraction (ephemeral, under /run)
    work_dir: []const u8 = "/run/xenomorph/rootfs",

    /// Log directory (used by headless mode)
    log_dir: []const u8 = "/var/log",

    /// Output path for build subcommand (null = cache only, no output)
    output: ?[]const u8 = null,

    /// Optional additional rootfs tarball output for generate
    rootfs_output: ?[]const u8 = null,

    /// Whether --entrypoint was explicitly set by the user
    entrypoint_explicit: bool = false,

    /// Headless mode: fork, detach from terminal, log to file.
    /// Survives SSH disconnection. Implies --force.
    headless: bool = false,

    /// Path to Containerfile/Dockerfile
    containerfile: ?[]const u8 = null,

    /// Build context directory (default: directory containing containerfile)
    context: ?[]const u8 = null,

    /// Keep existing firewall rules (default: flush all rules before services)
    keep_firewall: bool = false,

    /// SSH explicitly enabled/disabled (null = auto from other ssh.* flags)
    ssh_enable: ?bool = null,
    ssh_port: ?u16 = null,
    ssh_password: ?[]const u8 = null,
    ssh_authorized_keys: ?[]const u8 = null,

    /// Tailscale explicitly enabled/disabled (null = auto from other tailscale.* flags)
    tailscale_enable: ?bool = null,
    tailscale_image: []const u8 = "docker.io/tailscale/tailscale:latest",
    tailscale_authkey: ?[]const u8 = null,
    tailscale_server: ?[]const u8 = null,
    tailscale_args: ?[]const u8 = null,

    pub fn sshEnabled(self: *const Config) bool {
        if (self.ssh_enable) |e| return e;
        return self.ssh_port != null or self.ssh_password != null or self.ssh_authorized_keys != null;
    }

    pub fn tailscaleEnabled(self: *const Config) bool {
        if (self.tailscale_enable) |e| return e;
        return self.tailscale_authkey != null;
    }

    pub fn hasInitServices(self: *const Config) bool {
        return self.sshEnabled() or self.tailscaleEnabled() or !self.keep_firewall;
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

/// Parse a `--name=value` or `--name value` style argument.
/// Returns the value if `arg` matches `prefix` (exact or with `=`), null otherwise.
fn parseDotArg(arg: []const u8, args: *std.process.ArgIterator, prefix: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, arg, prefix)) {
        return args.next();
    }
    if (arg.len > prefix.len and std.mem.startsWith(u8, arg, prefix) and arg[prefix.len] == '=') {
        return arg[prefix.len + 1 ..];
    }
    return null;
}

/// Parse a `--name`, `--name=true`, or `--name=false` boolean flag.
fn parseBoolArg(arg: []const u8, prefix: []const u8) ?bool {
    if (std.mem.eql(u8, arg, prefix)) return true;
    if (arg.len > prefix.len and std.mem.startsWith(u8, arg, prefix) and arg[prefix.len] == '=') {
        const val = arg[prefix.len + 1 ..];
        if (std.mem.eql(u8, val, "true")) return true;
        if (std.mem.eql(u8, val, "false")) return false;
    }
    return null;
}

fn applyCacheDirEnv(cfg: *Config) void {
    if (std.posix.getenv("CACHE_DIRECTORY")) |dir| {
        cfg.cache_dir = dir;
    }
}

fn applyRuntimeDirEnv(cfg: *Config) void {
    if (std.posix.getenv("RUNTIME_DIRECTORY")) |dir| {
        // RUNTIME_DIRECTORY is set by systemd to e.g. /run/xenomorph
        // Use a "rootfs" subdir under it
        cfg.work_dir = std.fmt.allocPrint(std.heap.page_allocator, "{s}/rootfs", .{dir}) catch return;
    }
}

fn parsePivotArgs(args: *std.process.ArgIterator) !Config {
    var cfg = Config{};
    applyCacheDirEnv(&cfg);
    applyRuntimeDirEnv(&cfg);

    var layers_list: std.ArrayListUnmanaged(Layer) = .{};
    defer layers_list.deinit(std.heap.page_allocator);

    var command_list: std.ArrayListUnmanaged([]const u8) = .{};
    defer command_list.deinit(std.heap.page_allocator);

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--image")) {
            try layers_list.append(std.heap.page_allocator, .{ .image = args.next() orelse return error.MissingValue });
        } else if (std.mem.eql(u8, arg, "--rootfs")) {
            try layers_list.append(std.heap.page_allocator, .{ .rootfs = args.next() orelse return error.MissingValue });
        } else if (std.mem.eql(u8, arg, "--entrypoint")) {
            cfg.entrypoint = args.next() orelse return error.MissingValue;
            cfg.entrypoint_explicit = true;
        } else if (std.mem.eql(u8, arg, "--command") or std.mem.eql(u8, arg, "--cmd")) {
            try command_list.append(std.heap.page_allocator, args.next() orelse return error.MissingValue);
        } else if (std.mem.eql(u8, arg, "--keep-old-root")) {
            cfg.keep_old_root = true;
        } else if (std.mem.eql(u8, arg, "--no-keep-old-root")) {
            cfg.keep_old_root = false;
        } else if (std.mem.eql(u8, arg, "--contain") or std.mem.eql(u8, arg, "-c")) {
            cfg.contain = true;
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
        } else if (std.mem.eql(u8, arg, "--skip-verify")) {
            cfg.skip_verify = true;
        } else if (std.mem.eql(u8, arg, "--no-cache")) {
            cfg.no_cache = true;
        } else if (std.mem.eql(u8, arg, "--cache-dir")) {
            cfg.cache_dir = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            cfg.work_dir = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--log-dir")) {
            cfg.log_dir = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--systemd-mode")) {
            cfg.systemd_mode = true;
            cfg.no_init_coord = true;
            cfg.force = true;
        } else if (std.mem.eql(u8, arg, "--headless")) {
            cfg.headless = true;
            cfg.force = true;
        } else if (std.mem.eql(u8, arg, "--containerfile") or std.mem.eql(u8, arg, "--dockerfile")) {
            cfg.containerfile = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--context")) {
            cfg.context = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--keep-firewall")) {
            cfg.keep_firewall = true;
        } else if (parseBoolArg(arg, "--ssh.enable")) |v| {
            cfg.ssh_enable = v;
            if (v and cfg.ssh_port == null) cfg.ssh_port = 22;
        } else if (parseDotArg(arg, args, "--ssh.port")) |v| {
            cfg.ssh_port = try std.fmt.parseInt(u16, v, 10);
        } else if (parseDotArg(arg, args, "--ssh.password")) |v| {
            cfg.ssh_password = v;
            if (cfg.ssh_port == null) cfg.ssh_port = 22;
        } else if (parseDotArg(arg, args, "--ssh.authorized-keys")) |v| {
            cfg.ssh_authorized_keys = v;
            if (cfg.ssh_port == null) cfg.ssh_port = 22;
        } else if (parseBoolArg(arg, "--tailscale.enable")) |v| {
            cfg.tailscale_enable = v;
        } else if (parseDotArg(arg, args, "--tailscale.image")) |v| {
            cfg.tailscale_image = v;
        } else if (parseDotArg(arg, args, "--tailscale.authkey")) |v| {
            cfg.tailscale_authkey = v;
        } else if (parseDotArg(arg, args, "--tailscale.server")) |v| {
            cfg.tailscale_server = v;
        } else if (parseDotArg(arg, args, "--tailscale.args")) |v| {
            cfg.tailscale_args = v;
        } else if (std.mem.eql(u8, arg, "--")) {
            // Everything after -- is command args
            while (args.next()) |cmd_arg| {
                try command_list.append(std.heap.page_allocator, cmd_arg);
            }
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.UnknownOption;
        }
    }

    // Add tailscale image as last layer if enabled
    if (cfg.tailscaleEnabled()) {
        try layers_list.append(std.heap.page_allocator, .{ .image = cfg.tailscale_image });
    }

    if (layers_list.items.len > 0) {
        cfg.layers = try deduplicateLayers(std.heap.page_allocator, &layers_list);
    }

    if (command_list.items.len > 0) {
        cfg.command = try command_list.toOwnedSlice(std.heap.page_allocator);
    }

    return cfg;
}

fn parseBuildArgs(args: *std.process.ArgIterator) !Config {
    var cfg = Config{ .subcommand = .build };
    applyCacheDirEnv(&cfg);
    applyRuntimeDirEnv(&cfg);

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
        } else if (std.mem.eql(u8, arg, "--no-cache")) {
            cfg.no_cache = true;
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            cfg.work_dir = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--containerfile") or std.mem.eql(u8, arg, "--dockerfile")) {
            cfg.containerfile = args.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--context")) {
            cfg.context = args.next() orelse return error.MissingValue;
        } else if (parseBoolArg(arg, "--tailscale.enable")) |v| {
            cfg.tailscale_enable = v;
        } else if (parseDotArg(arg, args, "--tailscale.image")) |v| {
            cfg.tailscale_image = v;
        } else if (parseDotArg(arg, args, "--tailscale.authkey")) |v| {
            cfg.tailscale_authkey = v;
        } else if (parseDotArg(arg, args, "--tailscale.server")) |v| {
            cfg.tailscale_server = v;
        } else if (parseDotArg(arg, args, "--tailscale.args")) |v| {
            cfg.tailscale_args = v;
        } else {
            std.debug.print("Unknown option: {s}\n", .{arg});
            return error.UnknownOption;
        }
    }

    // Add tailscale image as last layer if enabled
    if (cfg.tailscaleEnabled()) {
        try layers_list.append(std.heap.page_allocator, .{ .image = cfg.tailscale_image });
    }

    if (layers_list.items.len > 0) {
        cfg.layers = try deduplicateLayers(std.heap.page_allocator, &layers_list);
    }

    return cfg;
}

/// Remove duplicate layers, keeping the last occurrence of each.
/// Image references are normalized before comparison (alpine = docker.io/library/alpine:latest).
/// Rootfs paths are compared as-is.
fn deduplicateLayers(allocator: std.mem.Allocator, layers: *std.ArrayListUnmanaged(Layer)) ![]const Layer {
    var seen: std.StringHashMapUnmanaged(void) = .{};
    defer seen.deinit(allocator);

    // Temp storage for normalized keys we allocate
    var key_storage: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (key_storage.items) |k| allocator.free(k);
        key_storage.deinit(allocator);
    }

    var deduped: std.ArrayListUnmanaged(Layer) = .{};
    defer deduped.deinit(allocator);

    // Walk backwards so last occurrence wins position
    var i: usize = layers.items.len;
    while (i > 0) {
        i -= 1;
        const layer = layers.items[i];
        const key = switch (layer) {
            .image => |ref| blk: {
                const normalized = normalizeImageRef(allocator, ref) catch ref;
                if (normalized.ptr != ref.ptr) {
                    try key_storage.append(allocator, normalized);
                }
                break :blk normalized;
            },
            .rootfs => |path| path,
        };
        if (!seen.contains(key)) {
            try seen.put(allocator, key, {});
            try deduped.append(allocator, layer);
        }
    }

    std.mem.reverse(Layer, deduped.items);
    return deduped.toOwnedSlice(allocator);
}

/// Normalize an OCI image reference to canonical form: registry/repository:tag
/// e.g. "alpine" → "registry-1.docker.io/library/alpine:latest"
pub fn normalizeImageRef(allocator: std.mem.Allocator, ref: []const u8) ![]const u8 {
    const default_registry = "registry-1.docker.io";

    var remaining = ref;
    var registry: []const u8 = default_registry;
    var tag: []const u8 = "latest";

    // Strip digest (@sha256:...) — not relevant for dedup
    if (std.mem.indexOf(u8, remaining, "@")) |idx| {
        remaining = remaining[0..idx];
    }

    // Extract tag after last ':'
    if (std.mem.lastIndexOfScalar(u8, remaining, ':')) |idx| {
        const potential_tag = remaining[idx + 1 ..];
        // Make sure it's not a port (no '/' in tag)
        if (std.mem.indexOf(u8, potential_tag, "/") == null) {
            tag = potential_tag;
            remaining = remaining[0..idx];
        }
    }

    // Extract registry (contains '.' or ':' or is 'localhost')
    if (std.mem.indexOf(u8, remaining, "/")) |first_slash| {
        const potential_registry = remaining[0..first_slash];
        if (std.mem.indexOf(u8, potential_registry, ".") != null or
            std.mem.indexOf(u8, potential_registry, ":") != null or
            std.mem.eql(u8, potential_registry, "localhost"))
        {
            registry = potential_registry;
            remaining = remaining[first_slash + 1 ..];
        }
    }

    // Docker Hub library images: "alpine" → "library/alpine"
    const repository: []const u8 = remaining;
    if (std.mem.eql(u8, registry, default_registry) and
        std.mem.indexOf(u8, remaining, "/") == null)
    {
        return std.fmt.allocPrint(allocator, "{s}/library/{s}:{s}", .{ registry, remaining, tag });
    }

    return std.fmt.allocPrint(allocator, "{s}/{s}:{s}", .{ registry, repository, tag });
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
        \\    --entrypoint <cmd>        Entrypoint for the new rootfs (default: from image or /bin/sh)
        \\    --command, --cmd <arg>    Command/args passed to entrypoint (repeatable)
        \\    -- <args>...              Arguments passed as command (alternative to --command)
        \\    --keep-old-root           Keep old root at /mnt/oldroot (default)
        \\    --no-keep-old-root        Unmount old root after pivot
        \\    -c, --contain             Run in a container (mount+PID ns) for testing
        \\    -f, --force               Skip confirmation prompts
        \\    --timeout <seconds>       Timeout for service shutdown (default: 30)
        \\    --no-init-coord           Skip init system coordination (dangerous)
        \\    --skip-verify             Skip rootfs verification
        \\    --no-cache                Skip build cache, pull fresh
        \\    --cache-dir <path>        Cache directory for OCI layers
        \\    --work-dir <path>         Working directory for extraction
        \\    --log-dir <path>          Log directory for headless mode (default: /var/log)
        \\    -v, --verbose             Verbose output
        \\    -n, --dry-run             Show what would be done without executing
        \\    --systemd-mode            Running as systemd unit (skip init coord + kill)
        \\    --headless                Detach from terminal (survives SSH disconnect)
        \\    --containerfile <path>    Build from Containerfile/Dockerfile
        \\    --dockerfile <path>       Alias for --containerfile
        \\    --context <dir>           Build context directory (default: containerfile dir)
        \\
        \\SSH:
        \\    --ssh.enable[=bool]       Enable/disable SSH (auto if other ssh.* set)
        \\    --ssh.port=<port>         SSH port (default: 22)
        \\    --ssh.password=<pw>       Root password (default: random)
        \\    --ssh.authorized-keys=<k> Authorized public keys (inline)
        \\
        \\TAILSCALE:
        \\    --tailscale.enable[=bool] Enable/disable tailscale (auto if authkey set)
        \\    --tailscale.authkey=<key> Auth key (starts tailscale in new rootfs)
        \\    --tailscale.server=<url>  Coordination server (for Headscale)
        \\    --tailscale.image=<ref>   Image (default: docker.io/tailscale/tailscale:latest)
        \\    --tailscale.args=<args>   Arguments for 'tailscale up'
        \\                              (default: --ssh --hostname=<hostname>-xenomorph)
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
        \\    xenomorph pivot --headless --tailscale.authkey=tskey-auth-xxxxx
        \\
        \\BUILD:
        \\    xenomorph build [--image <ref>...] [--rootfs <path>...] [-o <dir>]
        \\    -o, --output <dir>        Output OCI layout directory (omit to cache only)
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
                cfg.entrypoint = value;
            } else if (std.mem.eql(u8, key, "keep_old_root")) {
                cfg.keep_old_root = std.mem.eql(u8, value, "true");
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

    if (cfg.tailscale_authkey == null) {
        if (cfg.tailscale_args != null) {
            std.debug.print("Warning: --tailscale.args without --tailscale.authkey won't start tailscale\n", .{});
        }
        if (!std.mem.eql(u8, cfg.tailscale_image, "docker.io/tailscale/tailscale:latest")) {
            std.debug.print("Warning: --tailscale.image without --tailscale.authkey won't start tailscale\n", .{});
        }
    }

    if (cfg.containerfile != null) {
        // Check if any --image or --rootfs was explicitly provided
        // The default alpine image doesn't count
        if (cfg.layers.len > 1 or (cfg.layers.len == 1 and
            !(cfg.layers[0] == .image and std.mem.eql(u8, cfg.layers[0].image, "docker.io/library/alpine:latest"))))
        {
            std.debug.print("Error: --containerfile cannot be combined with --image or --rootfs\n", .{});
            return error.ContainerfileMutuallyExclusive;
        }
    }

    if (cfg.headless and !cfg.tailscaleEnabled() and cfg.ssh_port == null) {
        std.debug.print("Warning: --headless without remote access — ensure your entrypoint provides access\n", .{});
    }
}

test "default config" {
    const cfg = Config{};

    const testing = std.testing;
    try testing.expectEqual(@as(usize, 1), cfg.layers.len);
    try testing.expectEqualStrings("docker.io/library/alpine:latest", cfg.layers[0].image);
    try testing.expectEqualStrings("/bin/sh", cfg.entrypoint);
    try testing.expect(cfg.keep_old_root);
    try testing.expectEqual(@as(u32, 30), cfg.timeout);
    try testing.expect(cfg.output == null);
    try testing.expect(!cfg.entrypoint_explicit);
    try testing.expect(cfg.rootfs_output == null);
}

test "normalizeImageRef" {
    const t = std.testing;

    // Simple name → full canonical form
    {
        const n = try normalizeImageRef(t.allocator, "alpine");
        defer t.allocator.free(n);
        try t.expectEqualStrings("registry-1.docker.io/library/alpine:latest", n);
    }

    // Name with tag
    {
        const n = try normalizeImageRef(t.allocator, "alpine:3.18");
        defer t.allocator.free(n);
        try t.expectEqualStrings("registry-1.docker.io/library/alpine:3.18", n);
    }

    // docker.io short form
    {
        const n = try normalizeImageRef(t.allocator, "docker.io/library/alpine");
        defer t.allocator.free(n);
        try t.expectEqualStrings("docker.io/library/alpine:latest", n);
    }

    // Full form with tag is stable
    {
        const n = try normalizeImageRef(t.allocator, "ghcr.io/user/repo:v1.0");
        defer t.allocator.free(n);
        try t.expectEqualStrings("ghcr.io/user/repo:v1.0", n);
    }

    // All alpine variants normalize to equivalent
    {
        const a = try normalizeImageRef(t.allocator, "alpine");
        defer t.allocator.free(a);
        const b = try normalizeImageRef(t.allocator, "library/alpine:latest");
        defer t.allocator.free(b);
        try t.expectEqualStrings(a, b);
    }
}

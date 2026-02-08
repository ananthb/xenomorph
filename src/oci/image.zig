const std = @import("std");
const log = @import("../util/log.zig");

const scoped_log = log.scoped("oci/image");

/// OCI Image Manifest (application/vnd.oci.image.manifest.v1+json)
pub const ImageManifest = struct {
    schemaVersion: u32 = 2,
    mediaType: []const u8 = "application/vnd.oci.image.manifest.v1+json",
    config: Descriptor,
    layers: []const Descriptor,

    pub fn deinit(self: *ImageManifest, allocator: std.mem.Allocator) void {
        self.config.deinit(allocator);
        for (self.layers) |*layer| {
            var l = layer.*;
            l.deinit(allocator);
        }
        allocator.free(self.layers);
    }
};

/// OCI Content Descriptor
pub const Descriptor = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: u64,
    urls: ?[]const []const u8 = null,
    annotations: ?std.json.ArrayHashMap([]const u8) = null,

    pub fn deinit(self: *Descriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.mediaType);
        allocator.free(self.digest);
        if (self.urls) |urls| {
            for (urls) |url| {
                allocator.free(url);
            }
            allocator.free(urls);
        }
    }

    /// Parse the digest to get algorithm and hash
    pub fn parseDigest(self: *const Descriptor) !struct { algorithm: []const u8, hash: []const u8 } {
        const colon_idx = std.mem.indexOf(u8, self.digest, ":") orelse return error.InvalidDigest;
        return .{
            .algorithm = self.digest[0..colon_idx],
            .hash = self.digest[colon_idx + 1 ..],
        };
    }
};

/// OCI Image Configuration
pub const ImageConfig = struct {
    architecture: []const u8,
    os: []const u8,
    config: ?ContainerConfig = null,
    rootfs: RootFs,
    history: ?[]const HistoryEntry = null,

    pub fn deinit(self: *ImageConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.architecture);
        allocator.free(self.os);
        if (self.config) |*cfg| {
            cfg.deinit(allocator);
        }
        self.rootfs.deinit(allocator);
        if (self.history) |hist| {
            for (hist) |*h| {
                var entry = h.*;
                entry.deinit(allocator);
            }
            allocator.free(hist);
        }
    }
};

/// Container configuration
pub const ContainerConfig = struct {
    User: ?[]const u8 = null,
    ExposedPorts: ?std.json.ArrayHashMap(std.json.Value) = null,
    Env: ?[]const []const u8 = null,
    Entrypoint: ?[]const []const u8 = null,
    Cmd: ?[]const []const u8 = null,
    Volumes: ?std.json.ArrayHashMap(std.json.Value) = null,
    WorkingDir: ?[]const u8 = null,
    Labels: ?std.json.ArrayHashMap([]const u8) = null,

    pub fn deinit(self: *ContainerConfig, allocator: std.mem.Allocator) void {
        if (self.User) |user| allocator.free(user);
        if (self.Env) |env| {
            for (env) |e| allocator.free(e);
            allocator.free(env);
        }
        if (self.Entrypoint) |ep| {
            for (ep) |e| allocator.free(e);
            allocator.free(ep);
        }
        if (self.Cmd) |cmd| {
            for (cmd) |c| allocator.free(c);
            allocator.free(cmd);
        }
        if (self.WorkingDir) |wd| allocator.free(wd);
    }
};

/// RootFs information
pub const RootFs = struct {
    type: []const u8,
    diff_ids: []const []const u8,

    pub fn deinit(self: *RootFs, allocator: std.mem.Allocator) void {
        allocator.free(self.type);
        for (self.diff_ids) |id| {
            allocator.free(id);
        }
        allocator.free(self.diff_ids);
    }
};

/// History entry
pub const HistoryEntry = struct {
    created: ?[]const u8 = null,
    created_by: ?[]const u8 = null,
    author: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    empty_layer: ?bool = null,

    pub fn deinit(self: *HistoryEntry, allocator: std.mem.Allocator) void {
        if (self.created) |c| allocator.free(c);
        if (self.created_by) |c| allocator.free(c);
        if (self.author) |a| allocator.free(a);
        if (self.comment) |c| allocator.free(c);
    }
};

/// OCI Image Index (for multi-platform images)
pub const ImageIndex = struct {
    schemaVersion: u32 = 2,
    mediaType: []const u8 = "application/vnd.oci.image.index.v1+json",
    manifests: []const ManifestDescriptor,

    pub fn deinit(self: *ImageIndex, allocator: std.mem.Allocator) void {
        for (self.manifests) |*m| {
            var manifest = m.*;
            manifest.deinit(allocator);
        }
        allocator.free(self.manifests);
    }
};

/// Manifest descriptor with platform info
pub const ManifestDescriptor = struct {
    mediaType: []const u8,
    digest: []const u8,
    size: u64,
    platform: ?Platform = null,

    pub fn deinit(self: *ManifestDescriptor, allocator: std.mem.Allocator) void {
        allocator.free(self.mediaType);
        allocator.free(self.digest);
        if (self.platform) |*p| {
            p.deinit(allocator);
        }
    }
};

/// Platform specification
pub const Platform = struct {
    architecture: []const u8,
    os: []const u8,
    variant: ?[]const u8 = null,

    pub fn deinit(self: *Platform, allocator: std.mem.Allocator) void {
        allocator.free(self.architecture);
        allocator.free(self.os);
        if (self.variant) |v| allocator.free(v);
    }
};

/// Parse an image reference (e.g., "alpine:latest", "docker.io/library/alpine:3.18")
pub const ImageReference = struct {
    registry: []const u8,
    repository: []const u8,
    tag: []const u8,
    digest: ?[]const u8,

    /// Default registry if none specified
    pub const default_registry = "registry-1.docker.io";

    /// Parse an image reference string
    pub fn parse(ref: []const u8, allocator: std.mem.Allocator) !ImageReference {
        scoped_log.debug("Parsing image reference: {s}", .{ref});

        var registry: []const u8 = default_registry;
        var repository: []const u8 = undefined;
        var tag: []const u8 = "latest";
        var digest: ?[]const u8 = null;

        var remaining = ref;

        // Check for digest
        if (std.mem.indexOf(u8, remaining, "@sha256:")) |idx| {
            digest = try allocator.dupe(u8, remaining[idx + 1 ..]);
            remaining = remaining[0..idx];
        }

        // Check for tag
        if (std.mem.lastIndexOf(u8, remaining, ":")) |idx| {
            // Make sure this isn't a port number (registry with port)
            const potential_tag = remaining[idx + 1 ..];
            if (std.mem.indexOf(u8, potential_tag, "/") == null) {
                tag = try allocator.dupe(u8, potential_tag);
                remaining = remaining[0..idx];
            }
        } else {
            tag = try allocator.dupe(u8, "latest");
        }

        // Check for registry (contains . or :)
        if (std.mem.indexOf(u8, remaining, "/")) |first_slash| {
            const potential_registry = remaining[0..first_slash];
            if (std.mem.indexOf(u8, potential_registry, ".") != null or
                std.mem.indexOf(u8, potential_registry, ":") != null or
                std.mem.eql(u8, potential_registry, "localhost"))
            {
                registry = try allocator.dupe(u8, potential_registry);
                remaining = remaining[first_slash + 1 ..];
            } else {
                registry = try allocator.dupe(u8, default_registry);
            }
        } else {
            registry = try allocator.dupe(u8, default_registry);
        }

        // Handle Docker Hub library images
        if (std.mem.eql(u8, registry, default_registry) and
            std.mem.indexOf(u8, remaining, "/") == null)
        {
            repository = try std.fmt.allocPrint(allocator, "library/{s}", .{remaining});
        } else {
            repository = try allocator.dupe(u8, remaining);
        }

        scoped_log.debug("Parsed: registry={s}, repo={s}, tag={s}", .{ registry, repository, tag });

        return ImageReference{
            .registry = registry,
            .repository = repository,
            .tag = tag,
            .digest = digest,
        };
    }

    pub fn deinit(self: *ImageReference, allocator: std.mem.Allocator) void {
        allocator.free(self.registry);
        allocator.free(self.repository);
        allocator.free(self.tag);
        if (self.digest) |d| allocator.free(d);
    }

    /// Format as a string
    pub fn format(self: *const ImageReference, allocator: std.mem.Allocator) ![]const u8 {
        if (self.digest) |d| {
            return std.fmt.allocPrint(allocator, "{s}/{s}@{s}", .{ self.registry, self.repository, d });
        }
        return std.fmt.allocPrint(allocator, "{s}/{s}:{s}", .{ self.registry, self.repository, self.tag });
    }
};

/// Check if a path is a local OCI layout or tarball
pub fn isLocalImage(path: []const u8) bool {
    // Check for tarball
    if (std.mem.endsWith(u8, path, ".tar") or
        std.mem.endsWith(u8, path, ".tar.gz") or
        std.mem.endsWith(u8, path, ".tgz"))
    {
        return true;
    }

    // Check for OCI layout directory
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const oci_layout_path = std.fmt.bufPrint(&buf, "{s}/oci-layout", .{path}) catch return false;

    std.fs.accessAbsolute(oci_layout_path, .{}) catch return false;
    return true;
}

test "parse simple image reference" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ref = try ImageReference.parse("alpine", allocator);
    defer ref.deinit(allocator);

    try testing.expectEqualStrings("registry-1.docker.io", ref.registry);
    try testing.expectEqualStrings("library/alpine", ref.repository);
    try testing.expectEqualStrings("latest", ref.tag);
}

test "parse image with tag" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ref = try ImageReference.parse("alpine:3.18", allocator);
    defer ref.deinit(allocator);

    try testing.expectEqualStrings("library/alpine", ref.repository);
    try testing.expectEqualStrings("3.18", ref.tag);
}

test "parse full image reference" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ref = try ImageReference.parse("ghcr.io/user/image:v1.0", allocator);
    defer ref.deinit(allocator);

    try testing.expectEqualStrings("ghcr.io", ref.registry);
    try testing.expectEqualStrings("user/image", ref.repository);
    try testing.expectEqualStrings("v1.0", ref.tag);
}

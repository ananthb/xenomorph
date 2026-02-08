const std = @import("std");
const log = @import("../util/log.zig");
const image = @import("image.zig");
const auth = @import("auth.zig");

const scoped_log = log.scoped("oci/registry");

pub const RegistryError = error{
    ConnectionFailed,
    AuthenticationFailed,
    ManifestNotFound,
    BlobNotFound,
    RateLimited,
    ServerError,
    InvalidResponse,
    UnsupportedMediaType,
    OutOfMemory,
    HttpError,
    NotImplemented,
};

/// Registry client for pulling OCI images
/// Note: Simplified for Zig 0.15 - HTTP client API has changed
pub const RegistryClient = struct {
    allocator: std.mem.Allocator,
    registry: []const u8,
    auth_token: ?[]const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, registry: []const u8) Self {
        return Self{
            .allocator = allocator,
            .registry = registry,
            .auth_token = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.auth_token) |token| {
            self.allocator.free(token);
        }
    }

    /// Authenticate with the registry
    pub fn authenticate(self: *Self, repository: []const u8) !void {
        scoped_log.info("Authenticating with {s} for {s}", .{ self.registry, repository });

        const token = try auth.getRegistryToken(self.allocator, self.registry, repository);
        self.auth_token = token;
    }

    /// Fetch manifest for an image
    /// Note: Requires HTTP client - stubbed for now
    pub fn getManifest(self: *Self, repository: []const u8, reference: []const u8) ![]const u8 {
        scoped_log.info("Fetching manifest for {s}:{s}", .{ repository, reference });
        scoped_log.warn("Registry pull not yet implemented for Zig 0.15", .{});
        _ = self;
        return error.NotImplemented;
    }

    /// Download a blob (layer or config)
    pub fn getBlob(self: *Self, repository: []const u8, digest: []const u8) ![]const u8 {
        scoped_log.info("Fetching blob {s} from {s}", .{ digest, repository });
        _ = self;
        return error.NotImplemented;
    }

    /// Download a blob to a file
    pub fn getBlobToFile(self: *Self, repository: []const u8, digest: []const u8, output_path: []const u8) !void {
        scoped_log.info("Downloading blob {s} to {s}", .{ digest, output_path });
        _ = self;
        _ = repository;
        return error.NotImplemented;
    }

    /// Check if blob exists without downloading
    pub fn blobExists(self: *Self, repository: []const u8, digest: []const u8) !bool {
        _ = self;
        _ = repository;
        _ = digest;
        return false;
    }
};

/// Pull an image from a registry
/// Note: Requires HTTP client updates for Zig 0.15
pub fn pullImage(
    allocator: std.mem.Allocator,
    ref: *const image.ImageReference,
    output_dir: []const u8,
) !void {
    scoped_log.info("Pulling image {s}/{s}:{s}", .{ ref.registry, ref.repository, ref.tag });
    scoped_log.warn("Registry pull not implemented - use local tarball instead", .{});
    _ = allocator;
    _ = output_dir;
    return error.NotImplemented;
}

test "RegistryClient initialization" {
    const testing = std.testing;
    var client = RegistryClient.init(testing.allocator, "registry-1.docker.io");
    defer client.deinit();

    try testing.expectEqualStrings("registry-1.docker.io", client.registry);
    try testing.expect(client.auth_token == null);
}

const std = @import("std");
const log = @import("../util/log.zig");

const scoped_log = log.scoped("oci/auth");

pub const AuthError = error{
    AuthenticationFailed,
    TokenRequestFailed,
    InvalidResponse,
    ConfigNotFound,
    OutOfMemory,
    ConnectionFailed,
};

/// Credentials structure
pub const Credentials = struct {
    username: []const u8,
    password: []const u8,
};

/// Get authentication token for a registry
/// Note: Simplified implementation - full registry auth requires HTTP client updates for Zig 0.15
pub fn getRegistryToken(
    allocator: std.mem.Allocator,
    registry: []const u8,
    repository: []const u8,
) AuthError![]const u8 {
    scoped_log.debug("Getting token for {s}/{s}", .{ registry, repository });

    // For now, return empty token (anonymous access)
    // Full implementation requires updated HTTP client API
    return allocator.dupe(u8, "") catch return error.OutOfMemory;
}

/// Get stored credentials from Docker config
pub fn getStoredCredentials(allocator: std.mem.Allocator, registry: []const u8) AuthError!Credentials {
    scoped_log.debug("Looking for stored credentials for {s}", .{registry});
    _ = allocator;

    // Simplified - just return error for now
    return error.ConfigNotFound;
}

/// Check if authentication is required for a registry
pub fn requiresAuth(registry: []const u8) bool {
    _ = registry;
    return true;
}

test "credential structure" {
    const creds = Credentials{
        .username = "test",
        .password = "secret",
    };
    const testing = std.testing;
    try testing.expectEqualStrings("test", creds.username);
}

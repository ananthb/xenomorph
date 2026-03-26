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

/// Parsed WWW-Authenticate challenge
pub const AuthChallenge = struct {
    realm: []const u8,
    service: []const u8,
    scope: ?[]const u8,
};

/// Parse a WWW-Authenticate header value of the form:
/// Bearer realm="...",service="...",scope="..."
pub fn parseWwwAuthenticate(header: []const u8) ?AuthChallenge {
    // Must start with "Bearer " (case-insensitive)
    const bearer_prefix = "Bearer ";
    const bearer_prefix_lower = "bearer ";
    var rest: []const u8 = undefined;
    if (header.len >= bearer_prefix.len and
        (std.mem.eql(u8, header[0..bearer_prefix.len], bearer_prefix) or
        std.mem.eql(u8, header[0..bearer_prefix_lower.len], bearer_prefix_lower)))
    {
        rest = header[bearer_prefix.len..];
    } else {
        return null;
    }

    var realm: ?[]const u8 = null;
    var service: ?[]const u8 = null;
    var scope: ?[]const u8 = null;

    // Parse key="value" pairs separated by commas
    while (rest.len > 0) {
        // Skip whitespace and commas
        while (rest.len > 0 and (rest[0] == ' ' or rest[0] == ',')) {
            rest = rest[1..];
        }
        if (rest.len == 0) break;

        // Find '='
        const eq_idx = std.mem.indexOf(u8, rest, "=") orelse break;
        const key = rest[0..eq_idx];
        rest = rest[eq_idx + 1 ..];

        // Extract quoted value
        if (rest.len == 0) break;
        if (rest[0] == '"') {
            rest = rest[1..];
            const end_quote = std.mem.indexOf(u8, rest, "\"") orelse break;
            const value = rest[0..end_quote];
            rest = rest[end_quote + 1 ..];

            if (std.mem.eql(u8, key, "realm")) {
                realm = value;
            } else if (std.mem.eql(u8, key, "service")) {
                service = value;
            } else if (std.mem.eql(u8, key, "scope")) {
                scope = value;
            }
        } else {
            // Unquoted value - read until comma or end
            const end = std.mem.indexOf(u8, rest, ",") orelse rest.len;
            const value = rest[0..end];
            rest = rest[end..];

            if (std.mem.eql(u8, key, "realm")) {
                realm = value;
            } else if (std.mem.eql(u8, key, "service")) {
                service = value;
            } else if (std.mem.eql(u8, key, "scope")) {
                scope = value;
            }
        }
    }

    const r = realm orelse return null;
    const s = service orelse return null;

    return AuthChallenge{
        .realm = r,
        .service = s,
        .scope = scope,
    };
}

/// Fetch a bearer token from the auth realm endpoint.
/// Caller owns the returned token string.
pub fn fetchToken(
    allocator: std.mem.Allocator,
    http_client: *std.http.Client,
    realm: []const u8,
    service: []const u8,
    scope: []const u8,
) AuthError![]const u8 {
    scoped_log.debug("Fetching token from {s}", .{realm});

    // Build token URL: realm?service=...&scope=...
    const url_str = std.fmt.allocPrint(
        allocator,
        "{s}?service={s}&scope={s}",
        .{ realm, service, scope },
    ) catch return error.OutOfMemory;
    defer allocator.free(url_str);

    const uri = std.Uri.parse(url_str) catch {
        scoped_log.err("Failed to parse token URL: {s}", .{url_str});
        return error.TokenRequestFailed;
    };

    var req = http_client.request(.GET, uri, .{
        .redirect_behavior = @enumFromInt(5),
    }) catch {
        scoped_log.err("Failed to create token request", .{});
        return error.ConnectionFailed;
    };
    defer req.deinit();

    req.sendBodiless() catch {
        scoped_log.err("Failed to send token request", .{});
        return error.ConnectionFailed;
    };

    var redirect_buf: [8192]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch {
        scoped_log.err("Failed to receive token response", .{});
        return error.ConnectionFailed;
    };

    if (response.head.status != .ok) {
        scoped_log.err("Token endpoint returned status {}", .{@intFromEnum(response.head.status)});
        return error.TokenRequestFailed;
    }

    var transfer_buf: [8192]u8 = undefined;
    const body_reader = response.reader(&transfer_buf);
    const body = body_reader.allocRemaining(allocator, std.Io.Limit.limited(4 * 1024 * 1024)) catch {
        scoped_log.err("Failed to read token response body", .{});
        return error.TokenRequestFailed;
    };
    defer allocator.free(body);

    // Parse JSON for "token" or "access_token"
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        body,
        .{},
    ) catch return error.InvalidResponse;
    defer parsed.deinit();

    const token_val = parsed.value.object.get("token") orelse
        parsed.value.object.get("access_token") orelse
        return error.InvalidResponse;

    return allocator.dupe(u8, token_val.string) catch return error.OutOfMemory;
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

test "parseWwwAuthenticate basic" {
    const testing = std.testing;

    const result = parseWwwAuthenticate(
        "Bearer realm=\"https://auth.docker.io/token\",service=\"registry.docker.io\",scope=\"repository:library/alpine:pull\"",
    );
    try testing.expect(result != null);
    const challenge = result.?;
    try testing.expectEqualStrings("https://auth.docker.io/token", challenge.realm);
    try testing.expectEqualStrings("registry.docker.io", challenge.service);
    try testing.expectEqualStrings("repository:library/alpine:pull", challenge.scope.?);
}

test "parseWwwAuthenticate no scope" {
    const testing = std.testing;

    const result = parseWwwAuthenticate(
        "Bearer realm=\"https://auth.docker.io/token\",service=\"registry.docker.io\"",
    );
    try testing.expect(result != null);
    const challenge = result.?;
    try testing.expectEqualStrings("https://auth.docker.io/token", challenge.realm);
    try testing.expectEqualStrings("registry.docker.io", challenge.service);
    try testing.expect(challenge.scope == null);
}

test "parseWwwAuthenticate invalid" {
    const testing = std.testing;

    try testing.expect(parseWwwAuthenticate("Basic realm=\"test\"") == null);
    try testing.expect(parseWwwAuthenticate("") == null);
}

test "credential structure" {
    const creds = Credentials{
        .username = "test",
        .password = "secret",
    };
    const testing = std.testing;
    try testing.expectEqualStrings("test", creds.username);
}

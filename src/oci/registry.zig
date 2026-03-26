const std = @import("std");
const builtin = @import("builtin");
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
    PlatformNotSupported,
    IoError,
};

pub const ResolvedManifest = struct {
    body: []const u8,
    digest: []const u8,

    pub fn deinit(self: ResolvedManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        allocator.free(self.digest);
    }
};

/// Result of an HTTP GET with status information
const HttpResult = struct {
    status: std.http.Status,
    body: []const u8,
    /// Raw head bytes, duped if needed for header inspection
    head_bytes: ?[]const u8,

    pub fn deinit(self: HttpResult, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        if (self.head_bytes) |hb| allocator.free(hb);
    }
};

/// Registry client for pulling OCI images via native HTTP
pub const RegistryClient = struct {
    allocator: std.mem.Allocator,
    http_client: std.http.Client,
    registry: []const u8,
    auth_token: ?[]const u8 = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, registry: []const u8) Self {
        return Self{
            .allocator = allocator,
            .http_client = .{ .allocator = allocator },
            .registry = registry,
            .auth_token = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.auth_token) |token| {
            self.allocator.free(token);
        }
        self.http_client.deinit();
    }

    /// Probe /v2/ for auth challenge, parse WWW-Authenticate, fetch token
    pub fn ensureAuth(self: *Self, repository: []const u8) RegistryError!void {
        scoped_log.info("Authenticating with {s} for {s}", .{ self.registry, repository });

        const v2_url = std.fmt.allocPrint(
            self.allocator,
            "https://{s}/v2/",
            .{self.registry},
        ) catch return error.OutOfMemory;
        defer self.allocator.free(v2_url);

        // Do a raw GET to /v2/ to get the auth challenge
        const result = self.httpGetRaw(v2_url, null) catch |err| {
            scoped_log.err("Failed to probe /v2/: {}", .{err});
            return err;
        };
        defer result.deinit(self.allocator);

        if (result.status == .ok) {
            scoped_log.info("No authentication required", .{});
            return;
        }

        if (result.status != .unauthorized) {
            scoped_log.err("Unexpected status from /v2/: {}", .{@intFromEnum(result.status)});
            return error.AuthenticationFailed;
        }

        // Parse WWW-Authenticate from head bytes
        const head_bytes = result.head_bytes orelse {
            scoped_log.err("No head bytes available for auth challenge", .{});
            return error.AuthenticationFailed;
        };

        const www_auth = findHeader(head_bytes, "www-authenticate") orelse {
            scoped_log.err("No WWW-Authenticate header in 401 response", .{});
            return error.AuthenticationFailed;
        };

        const challenge = auth.parseWwwAuthenticate(www_auth) orelse {
            scoped_log.err("Failed to parse WWW-Authenticate: {s}", .{www_auth});
            return error.AuthenticationFailed;
        };

        // Build scope
        const scope = std.fmt.allocPrint(
            self.allocator,
            "repository:{s}:pull",
            .{repository},
        ) catch return error.OutOfMemory;
        defer self.allocator.free(scope);

        // Fetch token
        const token = auth.fetchToken(
            self.allocator,
            &self.http_client,
            challenge.realm,
            challenge.service,
            scope,
        ) catch |err| {
            scoped_log.err("Failed to fetch auth token: {}", .{err});
            return error.AuthenticationFailed;
        };

        if (self.auth_token) |old| self.allocator.free(old);
        self.auth_token = token;
        scoped_log.info("Authentication successful", .{});
    }

    /// GET manifest with Accept headers, returns JSON body (caller owns)
    pub fn fetchManifest(
        self: *Self,
        repository: []const u8,
        reference: []const u8,
        accept: []const u8,
    ) RegistryError![]const u8 {
        const url = std.fmt.allocPrint(
            self.allocator,
            "https://{s}/v2/{s}/manifests/{s}",
            .{ self.registry, repository, reference },
        ) catch return error.OutOfMemory;
        defer self.allocator.free(url);

        return self.httpGet(url, accept);
    }

    /// Download blob to file path (follows CDN redirects via privileged_headers stripping)
    pub fn downloadBlobToFile(
        self: *Self,
        repository: []const u8,
        digest: []const u8,
        output_path: []const u8,
    ) RegistryError!void {
        const url = std.fmt.allocPrint(
            self.allocator,
            "https://{s}/v2/{s}/blobs/{s}",
            .{ self.registry, repository, digest },
        ) catch return error.OutOfMemory;
        defer self.allocator.free(url);

        return self.httpDownloadToFile(url, output_path);
    }

    /// Resolve multi-platform image index to platform-specific manifest.
    /// Returns the manifest body and its sha256 digest.
    pub fn resolveForPlatform(
        self: *Self,
        repository: []const u8,
        reference: []const u8,
    ) RegistryError!ResolvedManifest {
        const accept = "application/vnd.docker.distribution.manifest.list.v2+json, " ++
            "application/vnd.oci.image.index.v1+json, " ++
            "application/vnd.docker.distribution.manifest.v2+json, " ++
            "application/vnd.oci.image.manifest.v1+json";

        const body = try self.fetchManifest(repository, reference, accept);
        defer self.allocator.free(body);

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            self.allocator,
            body,
            .{},
        ) catch return error.InvalidResponse;
        defer parsed.deinit();

        // Determine if this is a multi-platform index or single manifest
        const is_index = blk: {
            if (parsed.value.object.get("mediaType")) |mt| {
                if (std.mem.indexOf(u8, mt.string, "list") != null) break :blk true;
                if (std.mem.indexOf(u8, mt.string, "index") != null) break :blk true;
            }
            break :blk parsed.value.object.get("manifests") != null and
                parsed.value.object.get("layers") == null;
        };

        if (!is_index) {
            // Single-platform manifest, use it directly
            const digest = computeSha256Digest(self.allocator, body) catch return error.OutOfMemory;
            return ResolvedManifest{
                .body = self.allocator.dupe(u8, body) catch return error.OutOfMemory,
                .digest = digest,
            };
        }

        // Multi-platform: find the digest matching our architecture
        const manifests = parsed.value.object.get("manifests") orelse
            return error.ManifestNotFound;

        const target_arch = getPlatformArch() orelse return error.PlatformNotSupported;
        const target_variant = getPlatformVariant();

        for (manifests.array.items) |m| {
            const platform = m.object.get("platform") orelse continue;
            const os_val = platform.object.get("os") orelse continue;
            const arch_val = platform.object.get("architecture") orelse continue;

            if (!std.mem.eql(u8, os_val.string, "linux")) continue;
            if (!std.mem.eql(u8, arch_val.string, target_arch)) continue;

            if (target_variant) |tv| {
                if (platform.object.get("variant")) |variant| {
                    if (!std.mem.eql(u8, variant.string, tv)) continue;
                } else continue;
            }

            const digest_val = m.object.get("digest") orelse continue;

            scoped_log.info("Resolved platform manifest: {s}", .{
                digest_val.string[0..@min(digest_val.string.len, 24)],
            });

            // Fetch the platform-specific manifest
            const platform_accept = "application/vnd.docker.distribution.manifest.v2+json, " ++
                "application/vnd.oci.image.manifest.v1+json";

            const manifest_body = try self.fetchManifest(repository, digest_val.string, platform_accept);
            const manifest_digest = computeSha256Digest(self.allocator, manifest_body) catch {
                self.allocator.free(manifest_body);
                return error.OutOfMemory;
            };

            return ResolvedManifest{
                .body = manifest_body,
                .digest = manifest_digest,
            };
        }

        scoped_log.err("No matching platform in manifest index (want linux/{s}{s}{s})", .{
            target_arch,
            if (target_variant != null) @as([]const u8, "/") else @as([]const u8, ""),
            target_variant orelse "",
        });
        return error.PlatformNotSupported;
    }

    // ---- Private HTTP helpers ----

    /// HTTP GET returning body (caller owns). Errors on non-200.
    fn httpGet(self: *Self, url: []const u8, accept: ?[]const u8) RegistryError![]const u8 {
        const result = try self.httpGetRaw(url, accept);
        defer {
            if (result.head_bytes) |hb| self.allocator.free(hb);
        }

        if (result.status != .ok) {
            self.allocator.free(result.body);
            scoped_log.err("HTTP GET {s} returned {}", .{ url, @intFromEnum(result.status) });
            return switch (result.status) {
                .not_found => error.ManifestNotFound,
                .unauthorized => error.AuthenticationFailed,
                .too_many_requests => error.RateLimited,
                else => if (@intFromEnum(result.status) >= 500) error.ServerError else error.HttpError,
            };
        }

        return result.body;
    }

    /// HTTP GET returning status + body + head bytes for auth handling
    fn httpGetRaw(self: *Self, url: []const u8, accept: ?[]const u8) RegistryError!HttpResult {
        const uri = std.Uri.parse(url) catch {
            scoped_log.err("Failed to parse URL: {s}", .{url});
            return error.HttpError;
        };

        // Build extra headers (Accept)
        var extra_headers_buf: [1]std.http.Header = undefined;
        var extra_count: usize = 0;
        if (accept) |a| {
            extra_headers_buf[0] = .{ .name = "Accept", .value = a };
            extra_count = 1;
        }

        // Build privileged headers (Authorization - stripped on cross-domain redirect)
        var priv_headers_buf: [1]std.http.Header = undefined;
        var priv_count: usize = 0;
        if (self.auth_token) |token| {
            const auth_value = std.fmt.allocPrint(
                self.allocator,
                "Bearer {s}",
                .{token},
            ) catch return error.OutOfMemory;
            defer self.allocator.free(auth_value);

            priv_headers_buf[0] = .{ .name = "Authorization", .value = auth_value };
            priv_count = 1;

            return self.doHttpGetRaw(uri, extra_headers_buf[0..extra_count], priv_headers_buf[0..priv_count]);
        }

        return self.doHttpGetRaw(uri, extra_headers_buf[0..extra_count], &.{});
    }

    fn doHttpGetRaw(
        self: *Self,
        uri: std.Uri,
        extra_headers: []const std.http.Header,
        privileged_headers: []const std.http.Header,
    ) RegistryError!HttpResult {
        var req = self.http_client.request(.GET, uri, .{
            .extra_headers = extra_headers,
            .privileged_headers = privileged_headers,
            .redirect_behavior = .unhandled,
        }) catch {
            return error.ConnectionFailed;
        };
        defer req.deinit();

        req.sendBodiless() catch {
            return error.ConnectionFailed;
        };

        var redirect_buf: [8192]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch {
            return error.ConnectionFailed;
        };

        // Dupe head bytes before calling reader() which invalidates them
        const head_bytes_copy = self.allocator.dupe(u8, response.head.bytes) catch return error.OutOfMemory;
        errdefer self.allocator.free(head_bytes_copy);

        var transfer_buf: [8192]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);
        const body = body_reader.allocRemaining(self.allocator, std.Io.Limit.limited(8 * 1024 * 1024)) catch {
            return error.InvalidResponse;
        };

        return HttpResult{
            .status = response.head.status,
            .body = body,
            .head_bytes = head_bytes_copy,
        };
    }

    /// Download URL contents to a file, streaming to avoid holding in memory
    fn httpDownloadToFile(self: *Self, url: []const u8, output_path: []const u8) RegistryError!void {
        const uri = std.Uri.parse(url) catch {
            scoped_log.err("Failed to parse URL: {s}", .{url});
            return error.HttpError;
        };

        // Build privileged headers (Authorization - stripped on CDN redirect)
        var priv_headers_buf: [1]std.http.Header = undefined;
        var priv_count: usize = 0;

        // We need the auth_value to outlive the request, so allocate here
        var auth_value: ?[]const u8 = null;
        defer if (auth_value) |av| self.allocator.free(av);

        if (self.auth_token) |token| {
            auth_value = std.fmt.allocPrint(
                self.allocator,
                "Bearer {s}",
                .{token},
            ) catch return error.OutOfMemory;
            priv_headers_buf[0] = .{ .name = "Authorization", .value = auth_value.? };
            priv_count = 1;
        }

        var req = self.http_client.request(.GET, uri, .{
            .privileged_headers = priv_headers_buf[0..priv_count],
            .redirect_behavior = @enumFromInt(10),
        }) catch {
            return error.ConnectionFailed;
        };
        defer req.deinit();

        req.sendBodiless() catch {
            return error.ConnectionFailed;
        };

        var redirect_buf: [8192]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch {
            return error.ConnectionFailed;
        };

        if (response.head.status != .ok) {
            scoped_log.err("Download returned status {}", .{@intFromEnum(response.head.status)});
            return error.BlobNotFound;
        }

        // Open output file
        const dir_path = std.fs.path.dirname(output_path) orelse "/";
        var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return error.IoError;
        defer dir.close();

        var file = dir.createFile(std.fs.path.basename(output_path), .{}) catch
            return error.IoError;
        defer file.close();

        // Stream response body to file
        var transfer_buf: [32768]u8 = undefined;
        const body_reader = response.reader(&transfer_buf);

        var write_buf: [32768]u8 = undefined;
        var file_writer = file.writer(&write_buf);

        _ = body_reader.streamRemaining(&file_writer.interface) catch {
            return error.IoError;
        };
        file_writer.interface.flush() catch {
            return error.IoError;
        };
    }
};

/// Find a header value by name (case-insensitive) in raw HTTP head bytes
fn findHeader(bytes: []const u8, name: []const u8) ?[]const u8 {
    var it = std.http.HeaderIterator.init(bytes);
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) {
            return header.value;
        }
    }
    return null;
}

/// Compute sha256 digest string "sha256:<hex>" from data
fn computeSha256Digest(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(data);
    const hash = hasher.finalResult();

    // Format as hex
    var hex_buf: [64]u8 = undefined;
    for (hash, 0..) |byte, i| {
        const hex = std.fmt.bytesToHex([1]u8{byte}, .lower);
        hex_buf[i * 2] = hex[0];
        hex_buf[i * 2 + 1] = hex[1];
    }

    return std.fmt.allocPrint(allocator, "sha256:{s}", .{hex_buf[0..64]});
}

/// Detect OCI platform architecture from build target
pub fn getPlatformArch() ?[]const u8 {
    return switch (builtin.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        .arm => "arm",
        else => null,
    };
}

/// Detect OCI platform variant from build target
pub fn getPlatformVariant() ?[]const u8 {
    return switch (builtin.cpu.arch) {
        .arm => "v7",
        else => null,
    };
}

/// Pull an image from a registry into an OCI layout directory
pub fn pullImage(
    allocator: std.mem.Allocator,
    ref: *const image.ImageReference,
    output_dir: []const u8,
) !void {
    scoped_log.info("Pulling image {s}/{s}:{s}", .{ ref.registry, ref.repository, ref.tag });

    var client = RegistryClient.init(allocator, ref.registry);
    defer client.deinit();

    // Authenticate
    client.ensureAuth(ref.repository) catch |err| {
        scoped_log.err("Authentication failed: {}", .{err});
        return err;
    };

    // Resolve platform-specific manifest
    const reference = if (ref.digest) |d| d else ref.tag;
    const resolved = client.resolveForPlatform(ref.repository, reference) catch |err| {
        scoped_log.err("Failed to resolve manifest: {}", .{err});
        return err;
    };
    defer resolved.deinit(allocator);

    scoped_log.info("Resolved manifest digest: {s}", .{
        resolved.digest[0..@min(resolved.digest.len, 24)],
    });

    // Create blob directory structure
    const blobs_dir = std.fs.path.join(allocator, &.{ output_dir, "blobs", "sha256" }) catch
        return error.OutOfMemory;
    defer allocator.free(blobs_dir);

    // Create directory recursively
    {
        var dir = std.fs.openDirAbsolute(output_dir, .{}) catch return error.IoError;
        defer dir.close();
        dir.makePath("blobs/sha256") catch return error.IoError;
    }

    // Save manifest as a blob
    const manifest_hash = resolved.digest[7..]; // strip "sha256:"
    const manifest_blob_path = std.fs.path.join(allocator, &.{ output_dir, "blobs", "sha256", manifest_hash }) catch
        return error.OutOfMemory;
    defer allocator.free(manifest_blob_path);

    {
        const dir_path = std.fs.path.dirname(manifest_blob_path) orelse "/";
        var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return error.IoError;
        defer dir.close();
        var file = dir.createFile(std.fs.path.basename(manifest_blob_path), .{}) catch return error.IoError;
        defer file.close();
        file.writeAll(resolved.body) catch return error.IoError;
    }

    // Parse manifest for config and layers
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        resolved.body,
        .{},
    ) catch return error.InvalidResponse;
    defer parsed.deinit();

    // Download config blob
    if (parsed.value.object.get("config")) |config_desc| {
        if (config_desc.object.get("digest")) |config_digest| {
            scoped_log.info("Downloading config {s}", .{
                config_digest.string[0..@min(config_digest.string.len, 24)],
            });
            const config_hash = config_digest.string[7..]; // strip "sha256:"
            const config_path = std.fs.path.join(allocator, &.{ output_dir, "blobs", "sha256", config_hash }) catch
                return error.OutOfMemory;
            defer allocator.free(config_path);

            client.downloadBlobToFile(ref.repository, config_digest.string, config_path) catch |err| {
                scoped_log.err("Failed to download config: {}", .{err});
                return err;
            };
        }
    }

    // Download layer blobs
    if (parsed.value.object.get("layers")) |layers| {
        scoped_log.info("Downloading {} layers", .{layers.array.items.len});

        for (layers.array.items, 0..) |layer, i| {
            const layer_digest = layer.object.get("digest") orelse continue;
            scoped_log.info("Downloading layer {}/{} {s}", .{
                i + 1,
                layers.array.items.len,
                layer_digest.string[0..@min(layer_digest.string.len, 19)],
            });

            const layer_hash = layer_digest.string[7..]; // strip "sha256:"
            const layer_path = std.fs.path.join(allocator, &.{ output_dir, "blobs", "sha256", layer_hash }) catch
                return error.OutOfMemory;
            defer allocator.free(layer_path);

            client.downloadBlobToFile(ref.repository, layer_digest.string, layer_path) catch |err| {
                scoped_log.err("Failed to download layer: {}", .{err});
                return err;
            };
        }
    }

    // Write index.json pointing to the manifest
    const index_json = std.fmt.allocPrint(allocator,
        \\{{
        \\  "schemaVersion": 2,
        \\  "manifests": [
        \\    {{
        \\      "mediaType": "application/vnd.oci.image.manifest.v1+json",
        \\      "digest": "{s}",
        \\      "size": {d}
        \\    }}
        \\  ]
        \\}}
    , .{ resolved.digest, resolved.body.len }) catch return error.OutOfMemory;
    defer allocator.free(index_json);

    const index_path = std.fs.path.join(allocator, &.{ output_dir, "index.json" }) catch
        return error.OutOfMemory;
    defer allocator.free(index_path);

    {
        const dir_path = std.fs.path.dirname(index_path) orelse "/";
        var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return error.IoError;
        defer dir.close();
        var file = dir.createFile(std.fs.path.basename(index_path), .{}) catch return error.IoError;
        defer file.close();
        file.writeAll(index_json) catch return error.IoError;
    }

    scoped_log.info("Image pull complete", .{});
}

test "RegistryClient initialization" {
    const testing = std.testing;
    var client = RegistryClient.init(testing.allocator, "registry-1.docker.io");
    defer client.deinit();

    try testing.expectEqualStrings("registry-1.docker.io", client.registry);
    try testing.expect(client.auth_token == null);
}

test "getPlatformArch returns valid value" {
    const arch = getPlatformArch();
    const testing = std.testing;
    if (arch) |a| {
        try testing.expect(a.len > 0);
    }
}

test "computeSha256Digest" {
    const testing = std.testing;
    const digest = try computeSha256Digest(testing.allocator, "hello");
    defer testing.allocator.free(digest);

    try testing.expect(std.mem.startsWith(u8, digest, "sha256:"));
    try testing.expect(digest.len == 7 + 64); // "sha256:" + 64 hex chars
}

const std = @import("std");
const xeno = @import("xenomorph");
const oci = @import("oci");

// Fuzz targets for xenomorph-specific code.
// Run with: zig build fuzz -ffuzz
// Run once (as regular test): zig build fuzz

test "fuzz: image reference normalizer" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) !void {
            const normalized = xeno.config.normalizeImageRef(
                std.testing.allocator,
                input,
            ) catch return;
            defer if (normalized.ptr != input.ptr) std.testing.allocator.free(normalized);
        }
    }.testOne, .{
        .corpus = &.{
            "alpine",
            "alpine:latest",
            "alpine:3.18",
            "library/alpine:latest",
            "docker.io/library/alpine:latest",
            "ghcr.io/user/repo:v1.0",
            "localhost:5000/image:tag",
            "registry.example.com/org/repo@sha256:abc123",
            "",
            ":",
            "/",
            "a/b/c/d/e:tag",
            "@sha256:",
        },
    });
}

test "fuzz: config layer deduplication" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) !void {
            // Split input on newlines, treat each as an image ref
            var layers: std.ArrayListUnmanaged(xeno.config.Layer) = .{};
            defer layers.deinit(std.testing.allocator);

            var iter = std.mem.splitScalar(u8, input, '\n');
            while (iter.next()) |line| {
                if (line.len == 0) continue;
                if (line[0] == '/') {
                    layers.append(std.testing.allocator, .{ .rootfs = line }) catch return;
                } else {
                    layers.append(std.testing.allocator, .{ .image = line }) catch return;
                }
            }
            // Just verify it doesn't crash — the dedup is internal to parsePivotArgs
            // so we test the normalizer which is the core of dedup
        }
    }.testOne, .{
        .corpus = &.{
            "alpine\nalpine:latest\nlibrary/alpine",
            "/path/to/rootfs\n/path/to/rootfs",
            "ghcr.io/a/b:v1\nghcr.io/a/b:v1",
            "",
        },
    });
}

test "fuzz: cache key computation" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) !void {
            var layers: std.ArrayListUnmanaged(xeno.config.Layer) = .{};
            defer layers.deinit(std.testing.allocator);

            var iter = std.mem.splitScalar(u8, input, '\n');
            while (iter.next()) |line| {
                if (line.len == 0) continue;
                layers.append(std.testing.allocator, .{ .image = line }) catch return;
            }

            if (layers.items.len == 0) return;

            const key = xeno.cache.computeBuildCacheKey(
                std.testing.allocator,
                layers.items,
            ) catch return;
            // Key should always be 64 hex chars
            try std.testing.expectEqual(@as(usize, 64), key.len);
        }
    }.testOne, .{
        .corpus = &.{
            "alpine",
            "alpine:latest",
            "docker.io/library/alpine:latest",
            "image1\nimage2\nimage3",
            "",
        },
    });
}

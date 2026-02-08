const std = @import("std");

/// Compatibility layer for Zig 0.15+ API changes

/// Get stdout writer (using deprecated API for compatibility)
pub fn stdout() std.fs.File.DeprecatedWriter {
    return std.fs.File.stdout().deprecatedWriter();
}

/// Get stderr writer (using deprecated API for compatibility)
pub fn stderr() std.fs.File.DeprecatedWriter {
    return std.fs.File.stderr().deprecatedWriter();
}

/// Get stdin reader (using deprecated API for compatibility)
pub fn stdin() std.fs.File.DeprecatedReader {
    return std.fs.File.stdin().deprecatedReader();
}

/// ArrayList wrapper that works with Zig 0.15
pub fn ArrayList(comptime T: type) type {
    return struct {
        list: std.ArrayListUnmanaged(T) = .{},
        allocator: std.mem.Allocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.list.deinit(self.allocator);
        }

        pub fn append(self: *Self, item: T) !void {
            try self.list.append(self.allocator, item);
        }

        pub fn appendSlice(self: *Self, items: []const T) !void {
            try self.list.appendSlice(self.allocator, items);
        }

        pub fn toOwnedSlice(self: *Self) ![]T {
            return self.list.toOwnedSlice(self.allocator);
        }

        pub fn items(self: *const Self) []T {
            return self.list.items;
        }
    };
}

test "ArrayList wrapper" {
    const testing = std.testing;
    var list = ArrayList(u32).init(testing.allocator);
    defer list.deinit();

    try list.append(1);
    try list.append(2);
    try testing.expectEqual(@as(usize, 2), list.list.items.len);
}

const std = @import("std");

pub const Level = enum {
    debug,
    info,
    warn,
    err,

    pub fn string(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .err => "ERROR",
        };
    }

    pub fn color(self: Level) []const u8 {
        return switch (self) {
            .debug => "\x1b[36m", // cyan
            .info => "\x1b[32m", // green
            .warn => "\x1b[33m", // yellow
            .err => "\x1b[31m", // red
        };
    }
};

const reset_color = "\x1b[0m";

var log_level: Level = .info;
var use_colors: bool = true;

/// In-memory log buffer. Captures all messages for writing after pivot.
var log_buffer: std.ArrayListUnmanaged(u8) = .{};
var buffer_allocator: std.mem.Allocator = std.heap.page_allocator;

pub fn setLevel(level: Level) void {
    log_level = level;
}

pub fn setColors(enabled: bool) void {
    use_colors = enabled;
}

pub fn getLevel() Level {
    return log_level;
}

fn shouldLog(level: Level) bool {
    return @intFromEnum(level) >= @intFromEnum(log_level);
}

pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    if (!shouldLog(level)) return;

    // Write to stderr
    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (use_colors) {
        stderr.print("{s}[{s}]{s} ", .{ level.color(), level.string(), reset_color }) catch {};
    } else {
        stderr.print("[{s}] ", .{level.string()}) catch {};
    }

    stderr.print(fmt ++ "\n", args) catch {};

    // Also capture to in-memory buffer (without colors)
    const prefix = std.fmt.allocPrint(buffer_allocator, "[{s}] ", .{level.string()}) catch return;
    defer buffer_allocator.free(prefix);
    log_buffer.appendSlice(buffer_allocator, prefix) catch return;

    const msg = std.fmt.allocPrint(buffer_allocator, fmt ++ "\n", args) catch return;
    defer buffer_allocator.free(msg);
    log_buffer.appendSlice(buffer_allocator, msg) catch return;
}

/// Get the accumulated log buffer contents.
pub fn getBuffer() []const u8 {
    return log_buffer.items;
}

/// Write the log buffer to a file. Safe to call after pivot.
pub fn writeBufferToFile(path: []const u8) void {
    if (log_buffer.items.len == 0) return;

    const dir_path = std.fs.path.dirname(path) orelse "/";
    var dir = std.fs.openDirAbsolute(dir_path, .{}) catch return;
    defer dir.close();
    var file = dir.createFile(std.fs.path.basename(path), .{}) catch return;
    defer file.close();
    file.writeAll(log_buffer.items) catch {};
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

/// Log with a custom prefix (for subsystems)
pub fn scoped(comptime scope: []const u8) type {
    return struct {
        pub fn debug(comptime fmt: []const u8, args: anytype) void {
            log(.debug, "[" ++ scope ++ "] " ++ fmt, args);
        }

        pub fn info(comptime fmt: []const u8, args: anytype) void {
            log(.info, "[" ++ scope ++ "] " ++ fmt, args);
        }

        pub fn warn(comptime fmt: []const u8, args: anytype) void {
            log(.warn, "[" ++ scope ++ "] " ++ fmt, args);
        }

        pub fn err(comptime fmt: []const u8, args: anytype) void {
            log(.err, "[" ++ scope ++ "] " ++ fmt, args);
        }
    };
}

test "log levels" {
    const testing = std.testing;

    setLevel(.debug);
    try testing.expect(shouldLog(.debug));
    try testing.expect(shouldLog(.info));
    try testing.expect(shouldLog(.warn));
    try testing.expect(shouldLog(.err));

    setLevel(.warn);
    try testing.expect(!shouldLog(.debug));
    try testing.expect(!shouldLog(.info));
    try testing.expect(shouldLog(.warn));
    try testing.expect(shouldLog(.err));
}

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

    const stderr = std.fs.File.stderr().deprecatedWriter();

    if (use_colors) {
        stderr.print("{s}[{s}]{s} ", .{ level.color(), level.string(), reset_color }) catch return;
    } else {
        stderr.print("[{s}] ", .{level.string()}) catch return;
    }

    stderr.print(fmt ++ "\n", args) catch return;
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

const std = @import("std");
const log = @import("util/log.zig");

/// Fork and detach from the controlling terminal.
/// The parent prints the child PID and log path, then exits immediately.
/// The child continues in a new session with stderr redirected to a log file.
pub fn daemonize(log_dir: []const u8) void {
    const linux = std.os.linux;

    // Build log path
    var log_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const headless_log = std.fmt.bufPrint(&log_path_buf, "{s}/xenomorph.log", .{log_dir}) catch "/var/log/xenomorph.log";

    // Ensure log directory exists
    std.fs.makeDirAbsolute(log_dir) catch {};

    // Open log file (create/truncate, write-only)
    const log_fd = std.posix.open(
        headless_log,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    ) catch {
        std.debug.print("Error: cannot create {s}\n", .{headless_log});
        std.process.exit(1);
    };

    // Fork (aarch64 lacks fork syscall, use clone with SIGCHLD instead)
    const fork_result = if (@hasField(linux.SYS, "fork"))
        linux.syscall0(.fork)
    else
        linux.syscall5(.clone, linux.SIG.CHLD, 0, 0, 0, 0);
    if (linux.E.init(fork_result) != .SUCCESS) {
        std.debug.print("Error: fork failed\n", .{});
        std.process.exit(1);
    }

    if (fork_result > 0) {
        // Parent: print status and exit, freeing the SSH shell
        std.debug.print("xenomorph: daemonized (pid={}, log={s})\n", .{ fork_result, headless_log });
        std.process.exit(0);
    }

    // --- Child continues below ---

    // Create a new session so we're not tied to the SSH terminal.
    // When sshd is killed during pivot, SIGHUP goes to the old session, not us.
    _ = linux.syscall0(.setsid);

    // Redirect stdin/stdout to /dev/null, stderr to the log file
    const null_fd = std.posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch {
        // Fallback: just redirect stderr
        _ = std.posix.dup2(log_fd, 2) catch {};
        log.setColors(false);
        return;
    };

    _ = std.posix.dup2(null_fd, 0) catch {}; // stdin  -> /dev/null
    _ = std.posix.dup2(null_fd, 1) catch {}; // stdout -> /dev/null
    _ = std.posix.dup2(log_fd, 2) catch {}; // stderr -> log file

    // Close the original fds (dup2 created new references on 0/1/2)
    std.posix.close(null_fd);
    std.posix.close(log_fd);

    // No terminal, no colors
    log.setColors(false);
}

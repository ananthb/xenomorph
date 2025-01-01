const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Get a list of all processes.
    const pids = try getProcessIds();

    // Iterate over each process ID.
    for (pids.items) |pid| {
        // Open the process's directory in /proc.
        var proc_dir = try std.fs.openDirAbsolute(std.fmt.allocPrint(allocator, "/proc/{d}", .{pid}), .{});
        defer proc_dir.close();

        // Check if the process has a "fd" directory (which contains open file descriptors).
        if (proc_dir.access("fd", .{})) |_| {
            // Open the "fd" directory.
            var fd_dir = try proc_dir.openDir("fd", .{});
            defer fd_dir.close();

            // Iterate over each file descriptor.
            var fd_iter = fd_dir.iterate();
            while (try fd_iter.next()) |entry| {
                // Read the symbolic link of the file descriptor to get the path to the open file.
                const link_path = try std.fs.readLinkAlloc(std.heap.page_allocator, fd_dir.fd, entry.name);
                defer std.heap.page_allocator.free(link_path);

                // Check if the path starts with "/".
                if (std.mem.startsWith(u8, link_path, "/")) {
                    // Print the process ID and the open file path.
                    std.debug.print("Process {d} has open file: {s}\n", .{ pid, link_path });
                    // We found at least one file, so we can break out of this loop.
                    break;
                }
            }
        }
    }
}

pub fn getProcessIds() !std.ArrayList(u32) {
    var pids = std.ArrayList(u32).init(std.heap.page_allocator);
    errdefer pids.deinit();

    var proc_dir = try std.fs.openDirAbsolute("/proc", .{});
    defer proc_dir.close();

    var dir_iter = proc_dir.iterate();
    while (try dir_iter.next()) |entry| {
        if (entry.kind == .directory and std.ascii.isDigit(entry.name[0])) {
            if (std.fmt.parseInt(u32, entry.name, 10)) |pid| {
                try pids.append(pid);
            } else |_| {} // Ignore entries that aren't valid PIDs.
        }
    }

    return pids;
}

const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const io = std.io;
const log = std.log;
const process = std.process;
const math = std.math;

const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const DisplayWidth = @import("zg_DisplayWidth");

const c = switch (builtin.os.tag) {
    .macos, .linux => @cImport({
        @cInclude("sys/ioctl.h");
        @cInclude("unistd.h");
    }),
    .windows => @cImport({
        @cDefine("WIN32_LEAN_AND_MEAN", {});
        @cInclude("windows.h");
    }),
    else => @compileError("this OS is not supported"),
};

const FULL_PRINT_TOLERANCE: usize = 75;
const MINIMUM_COLUMN_SUPPORTED: usize = 30;

pub fn main() !void {
    const win_col = try getTermColumn();
    if (win_col < MINIMUM_COLUMN_SUPPORTED) return error.TerminalIsTooSmall;
    if (!io.getStdOut().supportsAnsiEscapeCodes()) return error.TerminalNotSupporedAnsi;

    const allocator = std.heap.page_allocator;
    var argv = try process.argsWithAllocator(allocator);
    defer argv.deinit();
    _ = argv.skip();

    const dwd = try DisplayWidth.DisplayWidthData.init(allocator);
    defer dwd.deinit();
    const dw = DisplayWidth{ .data = &dwd };

    var dir_to_search = try if (argv.next()) |dir_name| blk: {
        break :blk if (fs.path.isAbsolute(dir_name)) fs.openDirAbsolute(dir_name, .{
            .iterate = true,
            .no_follow = true,
        }) else fs.cwd().openDir(dir_name, .{ .iterate = true, .no_follow = true });
    } else fs.cwd().openDir(".", .{ .iterate = true, .no_follow = true });
    defer dir_to_search.close();
    var iter = dir_to_search.iterate();

    const stdout_file = io.getStdOut();
    var stdout_buf = io.bufferedWriter(stdout_file.writer());
    const stdout = stdout_buf.writer();

    var infos = try ArrayList(struct { []const u8, u64 }).initCapacity(allocator, 45);
    defer {
        for (infos.items) |info| {
            allocator.free(info[0]);
        }
        infos.deinit();
    }

    while (try iter.next()) |entry| {
        const entry_name = try allocator.alloc(u8, entry.name.len);
        errdefer allocator.free(entry_name);
        @memcpy(entry_name, entry.name);

        try infos.append(if (entry.kind == .directory)
            .{
                entry_name,
                try getDirSize(dir_to_search, entry.name),
            }
        else blk: {
            var file = try dir_to_search.openFile(entry.name, .{});
            defer file.close();
            break :blk .{
                entry_name,
                (try file.stat()).size,
            };
        });
    }

    try sortFileSizeInfos(allocator, infos.items);

    for (infos.items) |info| {
        try formatResult(allocator, stdout, win_col, dw, info[0], info[1]);
    }

    try stdout_buf.flush();
}

fn sortFileSizeInfos(allocator: Allocator, lst: []struct { []const u8, u64 }) !void {
    if (lst.len <= 1) return;

    const tmp = try allocator.alloc(struct { []const u8, u64 }, lst.len);
    defer allocator.free(tmp);

    const middle = lst.len / 2;
    const lhs = lst[0..middle];
    const rhs = lst[middle..lst.len];

    try sortFileSizeInfos(allocator, lhs);
    try sortFileSizeInfos(allocator, rhs);

    var lhs_ptr: usize = 0;
    var rhs_ptr: usize = 0;
    var tmp_ptr = @as([*]struct { []const u8, u64 }, @ptrCast(tmp));
    while (lhs_ptr < lhs.len and rhs_ptr < rhs.len) {
        if (lhs[lhs_ptr][1] <= rhs[rhs_ptr][1]) {
            tmp_ptr[0] = lhs[lhs_ptr];
            lhs_ptr += 1;
        } else {
            tmp_ptr[0] = rhs[rhs_ptr];
            rhs_ptr += 1;
        }
        tmp_ptr += 1;
    } else {
        if (lhs_ptr >= lhs.len) {
            @memcpy(tmp_ptr[0..], rhs[rhs_ptr..]);
        } else {
            @memcpy(tmp_ptr[0..], lhs[lhs_ptr..]);
        }
    }

    @memcpy(lst, tmp);
}

fn formatResult(
    allocator: Allocator,
    stdout: anytype,
    win_col: usize,
    dw: DisplayWidth,
    dir_name: []const u8,
    dir_size: u64,
) !void {
    const format_col = if (win_col > FULL_PRINT_TOLERANCE) win_col / 2 else win_col;
    const dir_size_readable = try parseBytes(allocator, dir_size);
    defer allocator.free(dir_size_readable);

    try stdout.print("|{s}", .{dir_name});
    try stdout.writeByteNTimes(' ', format_col -| (dw.strWidth(dir_name) + dir_size_readable.len + 2));
    try stdout.print("{s}|\n", .{dir_size_readable});
}

fn getDirSize(parent_dir: fs.Dir, name: []const u8) !u64 {
    var output: usize = 0;

    var dir = try parent_dir.openDir(name, .{ .iterate = true, .no_follow = true });
    defer dir.close();
    var iter = dir.iterate();

    while (try iter.next()) |entry| {
        switch (entry.kind) {
            .directory => output += try getDirSize(dir, entry.name),
            .file => {
                var file = try dir.openFile(entry.name, .{});
                defer file.close();
                output += (try file.stat()).size;
            },
            else => {},
        }
    }

    return output;
}

const getTermColumn = switch (builtin.os.tag) {
    .linux, .macos => struct {
        pub fn posix() !usize {
            var win_info: c.winsize = undefined;
            if (c.ioctl(std.posix.STDOUT_FILENO, c.TIOCGWINSZ, &win_info) < 0) {
                log.err("Cannot get the terminal size", .{});
                return error.TermSizeNotObtained;
            }
            return @intCast(win_info.ws_col);
        }
    }.posix,
    .windows => struct {
        pub fn windows() !usize {
            const stdout = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
            if (stdout == c.INVALID_HANDLE_VALUE) {
                log.err("cannot get the stdout handle", .{});
                return error.CannotGetStdHandle;
            }

            var console_info: c.CONSOLE_SCREEN_BUFFER_INFO = undefined;
            if (c.GetConsoleScreenBufferInfo(stdout, &console_info) != c.TRUE) {
                log.err("cannot get the console screen buffer info", .{});
                return error.CannotGetConsoleScreenBufInfo;
            }
            return @intCast(console_info.dwSize.X);
        }
    },
    else => @compileError("this OS is not supported"),
};

const KILOBYTE: u64 = math.powi(u64, 10, 3) catch unreachable;
const MEGABYTE: u64 = math.powi(u64, 10, 6) catch unreachable;
const GIGABYTE: u64 = math.powi(u64, 10, 9) catch unreachable;
const TERABYTE: u64 = math.powi(u64, 10, 12) catch unreachable;
const PETABYTE: u64 = math.powi(u64, 10, 15) catch unreachable;
const EXABYTE: u64 = math.powi(u64, 10, 18) catch unreachable;

pub fn parseBytes(allocator: Allocator, bytes: u64) ![]const u8 {
    var output = try ArrayList(u8).initCapacity(allocator, 50);
    errdefer output.deinit();

    var writer = output.writer();

    const exabyte = @divTrunc(bytes, EXABYTE);
    const petabyte = @divTrunc(@rem(bytes, EXABYTE), PETABYTE);
    const terabyte = @divTrunc(@rem(bytes, PETABYTE), TERABYTE);
    const gigabyte = @divTrunc(@rem(bytes, TERABYTE), GIGABYTE);
    const megabyte = @divTrunc(@rem(bytes, GIGABYTE), MEGABYTE);
    const kilobyte = @divTrunc(@rem(bytes, MEGABYTE), KILOBYTE);
    const byte = @rem(bytes, KILOBYTE);

    if (bytes >= EXABYTE) {
        @panic("Are you really using a normal computer?");
    }

    if (bytes < KILOBYTE) {
        try writer.print("{}B", .{byte});
    } else if (bytes < MEGABYTE) {
        try writer.print("{}K {}B", .{ kilobyte, byte });
    } else if (bytes < GIGABYTE) {
        try writer.print("{}M {}K {}B", .{ megabyte, kilobyte, byte });
    } else if (bytes < TERABYTE) {
        try writer.print("{}G {}M {}K {}B", .{ gigabyte, megabyte, kilobyte, byte });
    } else {
        try writer.print("{}E {}P {}T {}G {}M {}K {}B", .{
            exabyte,
            petabyte,
            terabyte,
            gigabyte,
            megabyte,
            kilobyte,
            byte,
        });
    }

    return try output.toOwnedSlice();
}

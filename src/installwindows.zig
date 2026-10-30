pub fn main(init: std.process.Init.Minimal) !void {
    // the same choice std's start.zig makes for std.process.Init
    const use_safe_allocator = switch (builtin.mode) {
        .debug, .safe => true,
        .fast, .small => false,
    };
    var safe_allocator: std.heap.SafeAllocator = if (use_safe_allocator) .init(std.heap.page_allocator, .{}) else undefined;
    defer if (use_safe_allocator) {
        const leak_count = safe_allocator.deinit();
        if (leak_count != 0) errExit("leaked {d} allocations", .{leak_count});
    };
    const gpa = if (use_safe_allocator) safe_allocator.allocator() else std.heap.smp_allocator;
    // process-lifetime memory, kept out of gpa so it skips gpa's bookkeeping
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{ .environ = init.environ, .argv0 = .init(init.args) });
    defer threaded.deinit();
    const io = threaded.io();

    const opt: struct {
        prefix: []const u8,
        exe: []const u8,
        pdb: []const u8,
    } = blk: {
        var maybe_prefix: ?[]const u8 = null;
        var maybe_exe: ?[]const u8 = null;
        var maybe_pdb: ?[]const u8 = null;
        var arg_it = try init.args.iterateAllocator(arena);
        _ = arg_it.next();
        while (arg_it.next()) |arg| {
            if (std.mem.eql(u8, "--prefix", arg)) {
                maybe_prefix = arg_it.next() orelse errExit("--prefix requires a path argument", .{});
            } else if (std.mem.eql(u8, "--exe", arg)) {
                maybe_exe = arg_it.next() orelse errExit("--exe requires a path argument", .{});
            } else if (std.mem.eql(u8, "--pdb", arg)) {
                maybe_pdb = arg_it.next() orelse errExit("--pdb requires a path argument", .{});
            } else errExit("unknown cmdline option '{s}'", .{arg});
        }
        break :blk .{
            .prefix = maybe_prefix orelse errExit("missing --prefix cmdline option", .{}),
            .exe = maybe_exe orelse errExit("missing --exe cmdline option", .{}),
            .pdb = maybe_pdb orelse errExit("missing --pdb cmdline option", .{}),
        };
    };
    try std.Io.Dir.cwd().createDirPath(io, opt.prefix);

    // the same directory as dof's appDataDir
    const app_data_path = blk: {
        const local_app_data_w = init.environ.getWindows(std.unicode.wtf8ToWtf16LeStringLiteral("LOCALAPPDATA")) orelse
            errExit("LOCALAPPDATA is unset", .{});
        if (local_app_data_w.len == 0) errExit("LOCALAPPDATA is empty", .{});
        const local_app_data = try std.unicode.wtf16LeToWtf8Alloc(arena, local_app_data_w);
        break :blk try std.fs.path.join(arena, &.{ local_app_data, "dof" });
    };
    var app_data_dir = try std.Io.Dir.cwd().createDirPathOpen(io, app_data_path, .{});
    defer app_data_dir.close(io);

    // Installs are serialized so each file only needs one fixed temporary name
    // (<name>.new). A crash leaves at most that one file, the next install
    // overwrites it.
    const lock_name = "install.lock";
    // never deleted, another install could be waiting on it
    const lock_file = try lockfile.createOrOpen(io, app_data_dir, lock_name);
    // releases the lock
    defer lock_file.close(io);
    if (!try lock_file.tryLock(io, .exclusive)) {
        std.log.info("waiting for another install to finish", .{});
        try lock_file.lock(io, .exclusive);
    }

    try install(io, arena, opt.prefix, opt.exe);
    try install(io, arena, opt.prefix, opt.pdb);
}

fn install(io: std.Io, scratch: std.mem.Allocator, prefix: []const u8, file: []const u8) !void {
    const dest = try std.fs.path.join(scratch, &.{ prefix, std.fs.path.basename(file) });
    defer scratch.free(dest);
    const dest_new = try std.mem.concat(scratch, u8, &.{ dest, ".new" });
    defer scratch.free(dest_new);
    const dest_old = try std.mem.concat(scratch, u8, &.{ dest, ".old" });
    defer scratch.free(dest_old);

    // Write next to dest first so dest is never missing or partially written.
    // Not Dir.copyFile, it writes to a randomly named temporary file which a crash
    // would leave behind.
    std.log.info("copy '{s}' to '{s}'", .{ file, dest_new });
    {
        const src = try std.Io.Dir.cwd().openFile(io, file, .{});
        defer src.close(io);
        const new = try std.Io.Dir.cwd().createFile(io, dest_new, .{});
        defer new.close(io);
        var src_reader: std.Io.File.Reader = .init(src, io, &.{});
        var buffer: [4096]u8 = undefined; // only used when direct fd-to-fd isn't available
        var new_writer = new.writer(io, &buffer);
        _ = new_writer.interface.sendFileAll(&src_reader, .unlimited) catch |err| switch (err) {
            error.ReadFailed => return src_reader.err.?,
            error.WriteFailed => return new_writer.err.?,
        };
        try new_writer.flush();
        // without this the rename can reach the disk before the content
        try new.sync(io);
    }

    // Zig's rename opens the source file which fails with SHARING_VIOLATION on a
    // running exe, and replacing a running exe retries AccessDenied for ~4s before
    // failing, so we use MoveFileExW directly.
    moveFile(dest_new, dest) catch |err| switch (err) {
        error.InUse => {
            // dest is running (dof updating itself). Windows can't replace a running
            // exe but can rename it, so move it aside first. dest is missing between
            // these two renames.
            std.log.info("replacing '{s}' was denied (it's probably running), moving it aside", .{dest});
            moveFile(dest, dest_old) catch |e| errExit("rename '{s}' to '{s}' failed with {t}", .{ dest, dest_old, e });
            moveFile(dest_new, dest) catch |e| {
                // put the running exe back so dest isn't left missing
                moveFile(dest_old, dest) catch |e2| std.log.err("rename '{s}' back to '{s}' failed with {t}", .{ dest_old, dest, e2 });
                errExit("rename '{s}' to '{s}' failed with {t}", .{ dest_new, dest, e });
            };
        },
        else => |e| return e,
    };
}

fn moveFile(old_path: []const u8, new_path: []const u8) error{ InUse, RenameFailed }!void {
    std.log.info("rename '{s}' to '{s}'", .{ old_path, new_path });
    const old_w = std.Io.Threaded.sliceToPrefixedFileW(null, old_path, .{}) catch |err|
        errExit("invalid path '{s}': {t}", .{ old_path, err });
    const new_w = std.Io.Threaded.sliceToPrefixedFileW(null, new_path, .{}) catch |err|
        errExit("invalid path '{s}': {t}", .{ new_path, err });
    if (!MoveFileExW(old_w.span().ptr, new_w.span().ptr, MOVEFILE_REPLACE_EXISTING).toBool()) {
        switch (std.os.windows.GetLastError()) {
            .ACCESS_DENIED => return error.InUse,
            else => |err| {
                std.log.err("rename '{s}' to '{s}' failed with error {f}", .{ old_path, new_path, fmtError(err) });
                return error.RenameFailed;
            },
        }
    }
}

/// Formats a win32 error as "<code> (<message>)", e.g. "5 (Access is denied.)".
/// The message comes from FormatMessageA so the binary doesn't need the name of
/// every Win32Error value. Ported from zigwin32's fmtError.
fn fmtError(err: std.os.windows.Win32Error) FormatError {
    return .{ .code = @backingInt(err) };
}
const FormatError = struct {
    code: u32,
    pub fn format(self: FormatError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{d} (", .{self.code});
        var buf: [300]u8 = undefined;
        const len = FormatMessageA(
            FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS,
            null,
            self.code,
            0,
            &buf,
            buf.len,
            null,
        );
        if (len == 0) {
            try writer.writeAll("unknown error");
        } else {
            try writer.writeAll(std.mem.trimEnd(u8, buf[0..len], "\r\n"));
            // messages can be arbitrarily long
            if (len + 1 >= buf.len) try writer.writeAll("...");
        }
        try writer.writeAll(")");
    }
};

const FORMAT_MESSAGE_IGNORE_INSERTS = 0x200;
const FORMAT_MESSAGE_FROM_SYSTEM = 0x1000;
extern "kernel32" fn FormatMessageA(
    dwFlags: u32,
    lpSource: ?*const anyopaque,
    dwMessageId: u32,
    dwLanguageId: u32,
    lpBuffer: [*]u8,
    nSize: u32,
    Arguments: ?*anyopaque,
) callconv(.winapi) u32;

const MOVEFILE_REPLACE_EXISTING = 0x1;
extern "kernel32" fn MoveFileExW(
    lpExistingFileName: [*:0]const u16,
    lpNewFileName: [*:0]const u16,
    dwFlags: u32,
) callconv(.winapi) std.os.windows.BOOL;

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const builtin = @import("builtin");
const std = @import("std");
const lockfile = @import("lockfile.zig");

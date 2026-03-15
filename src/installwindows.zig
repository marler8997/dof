pub fn main() !void {
    var arena_state: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const arena = arena_state.allocator();

    const opt: struct {
        prefix: []const u8,
        exe: []const u8,
        pdb: []const u8,
    } = blk: {
        var maybe_prefix: ?[]const u8 = null;
        var maybe_exe: ?[]const u8 = null;
        var maybe_pdb: ?[]const u8 = null;
        var arg_it = try std.process.argsWithAllocator(arena);
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
    try install(arena, opt.prefix, opt.exe);
    try install(arena, opt.prefix, opt.pdb);
}

fn install(scratch: std.mem.Allocator, prefix: []const u8, file: []const u8) !void {
    const basename = std.fs.path.basename(file);
    const dest = try std.fs.path.join(scratch, &.{ prefix, basename });
    defer scratch.free(dest);
    std.log.info("copy '{s}' to '{s}'", .{ file, dest });
    std.fs.cwd().copyFile(file, std.fs.cwd(), dest, .{}) catch |e| {
        if (e != error.AccessDenied) return e;
        // On Windows, a running exe can't be overwritten but can be renamed.
        // Zig's rename opens the source file which fails with SHARING_VIOLATION
        // on a running exe, so we use MoveFileExW directly.
        const dest_old = try std.fmt.allocPrint(scratch, "{s}.old", .{dest});
        defer scratch.free(dest_old);
        std.log.info("rename running '{s}' to '{s}'", .{ dest, dest_old });
        std.os.windows.MoveFileEx(dest, dest_old, std.os.windows.MOVEFILE_REPLACE_EXISTING) catch |e2| {
            std.log.err("rename '{s}' to '{s}': {}", .{ dest, dest_old, e2 });
            return e;
        };
        try std.fs.cwd().copyFile(file, std.fs.cwd(), dest, .{});
    };
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const std = @import("std");

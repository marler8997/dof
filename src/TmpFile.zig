//! Atomically writes files. Content is written to a uniquely named file in a temporary
//! directory, synced, then renamed over the destination. Readers only ever see the old
//! file or the complete new one, and concurrent writers race to see whose rename lands
//! last. Readers and writers of the destination never wait on each other.
//!
//! All temporary files live in a single directory so files left behind by a process that
//! died (or a power loss) can be found and cleaned up by a later process. To know whether
//! a temporary file is abandoned, each one is its own liveness lock: its owner holds an
//! exclusive lock on it until it has been renamed and closed. The OS releases the lock
//! when the owner dies, so any temporary file that can be locked has no owner and is
//! safe to delete. This lock is only ever tried (never waited on) and only by the
//! cleanup, it doesn't coordinate access to the destination.
//!
//! The temporary directory must be on the same filesystem as the destination.
//!
//! Copied from anyzig's TmpFile.zig.
const TmpFile = @This();

const random_bytes_len = 12;
pub const name_len = std.fs.base64_encoder.calcSize(random_bytes_len);

dir: std.Io.Dir,
dir_path: []const u8,
name: [name_len]u8,
file: std.Io.File,
state: enum { open, finished },

/// `tmp_dir_path` must stay valid until deinit, errors name files with it.
pub fn create(io: std.Io, tmp_dir_path: []const u8) !TmpFile {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, tmp_dir_path, .{ .open_options = .{ .iterate = true } });
    errdefer dir.close(io);
    try cleanAbandoned(io, dir, tmp_dir_path);
    while (true) {
        var random_bytes: [random_bytes_len]u8 = undefined;
        io.random(&random_bytes);
        var name: [name_len]u8 = undefined;
        _ = std.fs.base64_encoder.encode(&name, &random_bytes);
        const file = dir.createFile(io, &name, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => |e| return e,
        };
        errdefer {
            // delete before closing so no other process can lock it in between
            dir.deleteFile(io, &name) catch |e| logLeftBehind(tmp_dir_path, &name, e);
            file.close(io);
        }
        // There's a window between creating the file and locking it where another
        // process cleaning up abandoned files could lock it first. If that happens it
        // will delete it, so we abandon this one and try again with a new name.
        if (!try tryLock(io, file)) {
            file.close(io);
            continue;
        }
        if (try isDeleted(io, file)) {
            file.close(io);
            continue;
        }
        return .{ .dir = dir, .dir_path = tmp_dir_path, .name = name, .file = file, .state = .open };
    }
}

/// Always call deinit, even after a successful finish. Deletes the temporary file if
/// finish wasn't called or failed.
pub fn deinit(self: *TmpFile, io: std.Io) void {
    switch (self.state) {
        .open => {
            // delete before closing so no other process can lock it in between
            self.dir.deleteFile(io, &self.name) catch |e| logLeftBehind(self.dir_path, &self.name, e);
            self.file.close(io);
        },
        .finished => {},
    }
    self.dir.close(io);
    self.* = undefined;
}

/// Syncs the temporary file and renames it to `dest_path`, replacing it if it exists.
pub fn finish(self: *TmpFile, io: std.Io, dest_path: []const u8) !void {
    std.debug.assert(self.state == .open);
    // without this the rename can reach the disk before the content, leaving an
    // empty or zero-filled file after a power loss
    try self.file.sync(io);
    // we keep the file open (and locked) until after the rename, otherwise another
    // process could clean it up before we rename it
    try std.Io.Dir.rename(self.dir, &self.name, .cwd(), dest_path, io);
    self.file.close(io);
    self.state = .finished;
}

/// Deletes every file in the temporary directory that isn't locked by its owner.
fn cleanAbandoned(io: std.Io, dir: std.Io.Dir, dir_path: []const u8) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        // some filesystems don't report the kind (.unknown), those are handled below
        // since we'll fail to delete a directory
        if (entry.kind == .directory) {
            std.log.err(
                "unexpected {s} '{s}' in temporary directory '{s}'",
                .{ @tagName(entry.kind), entry.name, dir_path },
            );
            return error.UnexpectedTmpEntry;
        }
        const file = dir.openFile(io, entry.name, .{}) catch |err| switch (err) {
            // its owner finished or another process cleaned it up
            error.FileNotFound => continue,
            else => |e| return logTmpErr("open", dir_path, entry.name, e),
        };
        defer file.close(io);
        // locked means its owner is still alive
        const locked = tryLock(io, file) catch |e| return logTmpErr("lock", dir_path, entry.name, e);
        if (!locked) continue;
        std.log.info("deleting abandoned temporary file '{s}{c}{s}'", .{ dir_path, std.Io.Dir.path.sep, entry.name });
        // delete while we still hold the lock so its owner (if it's in the window
        // between creating and locking it) will see it's been deleted
        dir.deleteFile(io, entry.name) catch |err| switch (err) {
            // another process cleaned it up
            error.FileNotFound => {},
            else => |e| return logTmpErr("delete", dir_path, entry.name, e),
        };
    }
}

/// The next create cleans it up.
fn logLeftBehind(dir_path: []const u8, name: []const u8, err: anyerror) void {
    std.log.err(
        "delete temporary file '{s}{c}{s}' failed with {t}, it's left behind",
        .{ dir_path, std.Io.Dir.path.sep, name, err },
    );
}

/// An error here blocks every write until the user deals with the file, so make sure
/// they know which one it is.
fn logTmpErr(op: []const u8, dir_path: []const u8, name: []const u8, err: anytype) @TypeOf(err) {
    std.log.err(
        "{s} temporary file '{s}{c}{s}' failed with {s}",
        .{ op, dir_path, std.Io.Dir.path.sep, name, @errorName(err) },
    );
    return err;
}

/// On windows we lock a single byte far beyond the end of the file instead of using
/// std.Io.File.tryLock, which locks byte 0. Windows locks are mandatory, so locking real
/// content would make reads of the file fail in the brief window after we rename it
/// but before we close it.
const windows_lock_offset: windows.LARGE_INTEGER = std.math.maxInt(windows.LARGE_INTEGER) - 1;
const windows_lock_len: windows.LARGE_INTEGER = 1;

/// Tries to take an exclusive lock without blocking, returns false if another process
/// holds it. The lock is released when the file is closed (or the process dies).
pub fn tryLock(io: std.Io, file: std.Io.File) !bool {
    if (builtin.os.tag == .windows) {
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        return switch (windows.ntdll.NtLockFile(
            file.handle,
            null,
            null,
            null,
            &io_status_block,
            &windows_lock_offset,
            &windows_lock_len,
            null,
            .TRUE, // fail immediately
            .TRUE, // exclusive
        )) {
            .SUCCESS => true,
            .LOCK_NOT_GRANTED => false,
            .INSUFFICIENT_RESOURCES => error.SystemResources,
            else => |status| windows.unexpectedStatus(status),
        };
    }
    return file.tryLock(io, .exclusive);
}

/// Returns true if the file has been deleted since we opened it.
fn isDeleted(io: std.Io, file: std.Io.File) !bool {
    if (builtin.os.tag == .windows) {
        var io_status_block: windows.IO_STATUS_BLOCK = undefined;
        var info: windows.FILE.STANDARD_INFORMATION = undefined;
        const rc = windows.ntdll.NtQueryInformationFile(
            file.handle,
            &io_status_block,
            &info,
            @sizeOf(windows.FILE.STANDARD_INFORMATION),
            .Standard,
        );
        if (rc != .SUCCESS) return windows.unexpectedStatus(rc);
        return info.DeletePending.toBool() or info.NumberOfLinks == 0;
    }
    return (try file.stat(io)).nlink == 0;
}

const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;

test "cleanup deletes abandoned temporary files but not live ones" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_path);

    // a file that isn't locked simulates one left behind by a process that died
    try tmp.dir.writeFile(io, .{ .sub_path = "abandoned", .data = "" });
    // creating a TmpFile cleans up, it must delete the abandoned file
    var live = try create(io, tmp_path);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "abandoned", .{}));

    // creating another must leave the live (locked) one alone
    var second = try create(io, tmp_path);
    try tmp.dir.access(io, &live.name, .{});

    // deinit invalidates the TmpFile, so copy the names out first
    const second_name = second.name;
    second.deinit(io);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, &second_name, .{}));
    const live_name = live.name;
    live.deinit(io);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, &live_name, .{}));
}

test "finish replaces the destination and leaves nothing in the temporary directory" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const tmp_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "tmp" });
    defer std.testing.allocator.free(tmp_path);
    const dest_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "dest" });
    defer std.testing.allocator.free(dest_path);

    try tmp.dir.writeFile(io, .{ .sub_path = "dest", .data = "old" });
    var tmp_file = try create(io, tmp_path);
    defer tmp_file.deinit(io);
    try tmp_file.file.writeStreamingAll(io, "new");
    try tmp_file.finish(io, dest_path);

    const content = try tmp.dir.readFileAlloc(io, "dest", std.testing.allocator, .limited(100));
    defer std.testing.allocator.free(content);
    try std.testing.expectEqualStrings("new", content);
    var tmp_dir = try tmp.dir.openDir(io, "tmp", .{ .iterate = true });
    defer tmp_dir.close(io);
    var it = tmp_dir.iterate();
    try std.testing.expectEqual(null, try it.next(io));
}

test "concurrent writers replace the destination and readers only see complete files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const tmp_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "tmp" });
    defer std.testing.allocator.free(tmp_path);
    const dest_path = try std.Io.Dir.path.join(std.testing.allocator, &.{ root, "dest" });
    defer std.testing.allocator.free(dest_path);

    const content_len = 4096;
    const writer_count = 4;
    const iterations = 200;
    const initial: [content_len]u8 = @splat('0');
    try tmp.dir.writeFile(io, .{ .sub_path = "dest", .data = &initial });

    const Shared = struct {
        tmp_path: []const u8,
        dest_path: []const u8,
        writers_done: std.atomic.Value(u32) = .init(0),
        failures: std.atomic.Value(u32) = .init(0),

        fn write(shared: *@This(), id: u8) void {
            defer _ = shared.writers_done.fetchAdd(1, .release);
            const content: [content_len]u8 = @splat('a' + id);
            for (0..iterations) |_| shared.writeOnce(&content) catch |err| {
                std.log.err("writer {d} failed with {t}", .{ id, err });
                _ = shared.failures.fetchAdd(1, .monotonic);
                return;
            };
        }
        fn writeOnce(shared: *@This(), content: []const u8) !void {
            var tmp_file = try create(std.testing.io, shared.tmp_path);
            defer tmp_file.deinit(std.testing.io);
            try tmp_file.file.writeStreamingAll(std.testing.io, content);
            try tmp_file.finish(std.testing.io, shared.dest_path);
        }
        fn read(shared: *@This()) void {
            var buf: [content_len + 1]u8 = undefined;
            while (shared.writers_done.load(.acquire) < writer_count) {
                const content = std.Io.Dir.cwd().readFile(std.testing.io, shared.dest_path, &buf) catch |err| {
                    std.log.err("read failed with {t}", .{err});
                    _ = shared.failures.fetchAdd(1, .monotonic);
                    return;
                };
                const complete = content.len == content_len and
                    std.mem.allEqual(u8, content, content[0]);
                if (!complete) {
                    std.log.err("read a partial file ({d} bytes)", .{content.len});
                    _ = shared.failures.fetchAdd(1, .monotonic);
                    return;
                }
            }
        }
    };
    var shared: Shared = .{ .tmp_path = tmp_path, .dest_path = dest_path };
    var writers: [writer_count]std.Thread = undefined;
    for (&writers, 0..) |*thread, id| thread.* = try std.Thread.spawn(.{}, Shared.write, .{ &shared, @as(u8, @intCast(id)) });
    const reader = try std.Thread.spawn(.{}, Shared.read, .{&shared});
    for (writers) |thread| thread.join();
    reader.join();
    try std.testing.expectEqual(0, shared.failures.load(.monotonic));

    var tmp_dir = try tmp.dir.openDir(io, "tmp", .{ .iterate = true });
    defer tmp_dir.close(io);
    var it = tmp_dir.iterate();
    try std.testing.expectEqual(null, try it.next(io));
}

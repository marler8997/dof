const builtin = @import("builtin");
const std = @import("std");

/// Like std.fs.readLinkAbsolute but returns null instead of error when the
/// path doesn't exist or isn't a symlink. On Windows, properly handles
/// STATUS_NOT_A_REPARSE_POINT (0xc0000275) which std treats as unexpected.
pub fn readLinkAbsolute(path: []const u8, buf: *[std.fs.max_path_bytes]u8) !?[]const u8 {
    if (builtin.os.tag != .windows) {
        return std.fs.readLinkAbsolute(path, buf) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => |e| return e,
        };
    }

    var path_w = try std.os.windows.sliceToPrefixedFileW(null, path);
    var result_handle: std.os.windows.HANDLE = undefined;
    var unicode_str: std.os.windows.UNICODE_STRING = .{
        .Length = @intCast(path_w.len * 2),
        .MaximumLength = @intCast(path_w.len * 2),
        .Buffer = @constCast(path_w.span().ptr),
    };
    var obj_attrs: std.os.windows.OBJECT_ATTRIBUTES = .{
        .Length = @sizeOf(std.os.windows.OBJECT_ATTRIBUTES),
        .RootDirectory = null,
        .ObjectName = &unicode_str,
        .Attributes = std.os.windows.OBJ_CASE_INSENSITIVE,
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };
    var io_status: std.os.windows.IO_STATUS_BLOCK = .{
        .u = .{ .Status = .SUCCESS },
        .Information = 0,
    };
    const rc = std.os.windows.ntdll.NtCreateFile(
        &result_handle,
        std.os.windows.FILE_READ_ATTRIBUTES,
        &obj_attrs,
        &io_status,
        null,
        0,
        std.os.windows.FILE_SHARE_READ | std.os.windows.FILE_SHARE_WRITE | std.os.windows.FILE_SHARE_DELETE,
        std.os.windows.FILE_OPEN,
        std.os.windows.FILE_OPEN_REPARSE_POINT,
        null,
        0,
    );
    switch (rc) {
        .SUCCESS => {},
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => return null,
        else => return std.os.windows.unexpectedStatus(rc),
    }
    defer std.os.windows.CloseHandle(result_handle);

    var reparse_buf: [std.os.windows.MAXIMUM_REPARSE_DATA_BUFFER_SIZE]u8 align(@alignOf(std.os.windows.REPARSE_DATA_BUFFER)) = undefined;
    var io: std.os.windows.IO_STATUS_BLOCK = .{
        .u = .{ .Status = .SUCCESS },
        .Information = 0,
    };
    const ioctl_rc = std.os.windows.ntdll.NtFsControlFile(
        result_handle,
        null,
        null,
        null,
        &io,
        std.os.windows.FSCTL_GET_REPARSE_POINT,
        null,
        0,
        &reparse_buf,
        reparse_buf.len,
    );
    switch (ioctl_rc) {
        .SUCCESS => {},
        .NOT_A_REPARSE_POINT => return null,
        else => return std.os.windows.unexpectedStatus(ioctl_rc),
    }

    const reparse_struct: *const std.os.windows.REPARSE_DATA_BUFFER = @ptrCast(@alignCast(&reparse_buf));
    switch (reparse_struct.ReparseTag) {
        std.os.windows.IO_REPARSE_TAG_SYMLINK => {
            const sym_buf: *const std.os.windows.SYMBOLIC_LINK_REPARSE_BUFFER = @ptrCast(@alignCast(&reparse_struct.DataBuffer));
            const offset = sym_buf.SubstituteNameOffset >> 1;
            const len = sym_buf.SubstituteNameLength >> 1;
            const path_buf_ptr = @as([*]const u16, &sym_buf.PathBuffer);
            const wide_slice = path_buf_ptr[offset..][0..len];
            const n = std.unicode.wtf16LeToWtf8(buf, wide_slice);
            return buf[0..n];
        },
        else => return null,
    }
}

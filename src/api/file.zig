const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;
const fs_compat = openmiles.fs_compat;
const io = openmiles.io;

pub fn AIL_file_error() callconv(.winapi) [*:0]const u8 {
    if (openmiles.last_file_error_buf[0] == 0) return "No error";
    return &openmiles.last_file_error_buf;
}
pub fn AIL_file_read(filename: [*:0]const u8, dest: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    return openmiles.ailFileRead(filename, dest);
}
pub fn AIL_file_size(filename: [*:0]const u8) callconv(.winapi) u32 {
    return openmiles.ailFileSize(filename);
}
pub fn AIL_file_type(data: *anyopaque, len: u32) callconv(.winapi) i32 {
    return openmiles.detectFileType(data, len);
}
pub fn AIL_file_write(filename: [*:0]const u8, data: *anyopaque, len: u32) callconv(.winapi) i32 {
    const path = std.mem.span(filename);
    openmiles.clearFileError();
    const file = fs_compat.createFile(io, path, .{}) catch |err| {
        // AIL_file_error() is the only channel this call has: a bare 0 with
        // "No error" behind it leaves the application with no way to tell a
        // missing directory from a full disk. Name the file and the reason.
        log("AIL_file_write: cannot create '{s}' ({any})\n", .{ path, err });
        openmiles.setFileErrorFmt("Cannot create '{s}'", .{path});
        return 0;
    };
    // A write that fails partway leaves a truncated file on disk; the failure
    // is reported, but the partial contents stay, so say which file is short.
    errdefer openmiles.setFileErrorFmt("Write to '{s}' failed", .{path});
    defer file.close(io);
    const buf: [*]const u8 = @ptrCast(@alignCast(data));
    file.writeStreamingAll(io, buf[0..len]) catch |err| {
        log("AIL_file_write: writing {d} bytes to '{s}' failed ({any})\n", .{ len, path, err });
        openmiles.setFileErrorFmt("Write of {d} bytes to '{s}' failed", .{ len, path });
        return 0;
    };
    return 1;
}
// SDK arg order is (open, close, SEEK, READ) — not (open, close, read, seek).
pub fn AIL_set_file_callbacks(open_fn: ?*anyopaque, close_fn: ?*anyopaque, seek_fn: ?*anyopaque, read_fn: ?*anyopaque) callconv(.winapi) void {
    log("AIL_set_file_callbacks\n", .{});
    openmiles.cb_file_open = if (open_fn) |f| @ptrCast(f) else null;
    openmiles.cb_file_close = if (close_fn) |f| @ptrCast(f) else null;
    openmiles.cb_file_seek = if (seek_fn) |f| @ptrCast(f) else null;
    openmiles.cb_file_read = if (read_fn) |f| @ptrCast(f) else null;
}
pub fn AIL_set_file_async_callbacks(open_fn: ?*anyopaque, close_fn: ?*anyopaque, seek_fn: ?*anyopaque, read_fn: ?*anyopaque, callback_fn: ?*anyopaque) callconv(.winapi) void {
    _ = callback_fn;
    AIL_set_file_callbacks(open_fn, close_fn, seek_fn, read_fn);
}

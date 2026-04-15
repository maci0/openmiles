const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;
const fs_compat = openmiles.fs_compat;

fn openFileAnyPath(path: []const u8) ?std.fs.File {
    return fs_compat.openFile(path, .{}) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
}

pub export fn AIL_file_error() callconv(.winapi) [*:0]const u8 {
    if (openmiles.last_file_error_buf[0] == 0) return "No error";
    return &openmiles.last_file_error_buf;
}
pub export fn AIL_file_read(filename: [*:0]const u8, dest: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    openmiles.clearFileError();
    if (openmiles.cb_file_open != null) {
        const buf = openmiles.fileCallbackReadAll(filename) catch null;
        if (buf) |b| {
            defer openmiles.global_allocator.free(b);
            if (dest) |d| {
                @memcpy(@as([*]u8, @ptrCast(@alignCast(d)))[0..b.len], b);
                return d;
            }
            const out: [*]u8 = @ptrCast(std.c.malloc(b.len) orelse {
                openmiles.setFileError("Out of memory");
                return null;
            });
            @memcpy(out[0..b.len], b);
            return out;
        }
        openmiles.setFileError("File not found");
        return null;
    }
    const path = std.mem.span(filename);
    const file = openFileAnyPath(path) orelse {
        openmiles.setFileError("File not found");
        return null;
    };
    defer file.close();
    const stat_size = (file.stat() catch {
        openmiles.setFileError("Stat failed");
        return null;
    }).size;
    if (stat_size <= 0) return null;
    const size: usize = @intCast(stat_size);
    if (dest) |d| {
        const buf: [*]u8 = @ptrCast(@alignCast(d));
        const n = file.readAll(buf[0..size]) catch {
            openmiles.setFileError("Read error");
            return null;
        };
        if (n < size) {
            @memset(buf[n..size], 0);
        }
        return d;
    } else {
        const buf: [*]u8 = @ptrCast(std.c.malloc(size) orelse {
            openmiles.setFileError("Out of memory");
            return null;
        });
        const n = file.readAll(buf[0..size]) catch {
            std.c.free(buf);
            openmiles.setFileError("Read error");
            return null;
        };
        if (n < size) {
            @memset(buf[n..size], 0);
        }
        return buf;
    }
}
pub export fn AIL_file_size(filename: [*:0]const u8) callconv(.winapi) u32 {
    openmiles.clearFileError();
    if (openmiles.cb_file_open != null) {
        var size: u32 = 0;
        const open_fn = openmiles.cb_file_open.?;
        const close_fn = openmiles.cb_file_close orelse return 0;
        const handle = open_fn(filename, &size) orelse {
            openmiles.setFileError("File not found");
            return 0;
        };
        close_fn(handle);
        return size;
    }
    const path = std.mem.span(filename);
    const file = openFileAnyPath(path) orelse {
        openmiles.setFileError("File not found");
        return 0;
    };
    defer file.close();
    const stat = file.stat() catch {
        openmiles.setFileError("Stat failed");
        return 0;
    };
    if (stat.size <= 0) return 0;
    return @intCast(@min(stat.size, std.math.maxInt(u32)));
}
pub export fn AIL_file_type(data: *anyopaque, len: u32) callconv(.winapi) i32 {
    if (len < 4) return 0;
    const raw: [*]const u8 = @ptrCast(@alignCast(data));
    if (raw[0] == 'R' and raw[1] == 'I' and raw[2] == 'F' and raw[3] == 'F') return 1;
    if (raw[0] == 'M' and raw[1] == 'T' and raw[2] == 'h' and raw[3] == 'd') return 2;
    if (raw[0] == 'F' and raw[1] == 'O' and raw[2] == 'R' and raw[3] == 'M' and len >= 12) {
        if ((raw[8] == 'X' and raw[9] == 'D' and raw[10] == 'I' and raw[11] == 'R') or
            (raw[8] == 'X' and raw[9] == 'M' and raw[10] == 'I' and raw[11] == 'D'))
        {
            return 3;
        }
    }
    return 0;
}
pub export fn AIL_file_write(filename: [*:0]const u8, data: *anyopaque, len: u32) callconv(.winapi) i32 {
    const path = std.mem.span(filename);
    const file = fs_compat.createFile(path, .{}) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    defer file.close();
    const buf: [*]const u8 = @ptrCast(@alignCast(data));
    file.writeAll(buf[0..len]) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    return 1;
}
pub export fn AIL_set_file_callbacks(open_fn: ?*anyopaque, close_fn: ?*anyopaque, read_fn: ?*anyopaque, seek_fn: ?*anyopaque) callconv(.winapi) void {
    log("AIL_set_file_callbacks\n", .{});
    openmiles.cb_file_open = if (open_fn) |f| @ptrCast(f) else null;
    openmiles.cb_file_close = if (close_fn) |f| @ptrCast(f) else null;
    openmiles.cb_file_read = if (read_fn) |f| @ptrCast(f) else null;
    openmiles.cb_file_seek = if (seek_fn) |f| @ptrCast(f) else null;
}
pub export fn AIL_set_file_async_callbacks(open_fn: ?*anyopaque, close_fn: ?*anyopaque, read_fn: ?*anyopaque, seek_fn: ?*anyopaque, callback_fn: ?*anyopaque) callconv(.winapi) void {
    _ = callback_fn;
    AIL_set_file_callbacks(open_fn, close_fn, read_fn, seek_fn);
}

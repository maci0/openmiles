//! Filesystem compatibility shim. Wraps file/directory operations over std.Io
//! with a native Windows fallback so the rest of the codebase has one portable
//! open/read/seek/stat surface regardless of target OS.

const std = @import("std");
const builtin = @import("builtin");
const logger = @import("logger.zig");
const wide = @import("wide.zig");

const log = logger.log;
const is_windows = builtin.os.tag == .windows;

const win = if (is_windows) struct {
    const HANDLE = ?*anyopaque;

    const FILETIME = extern struct {
        dwLowDateTime: u32,
        dwHighDateTime: u32,
    };

    pub const WIN32_FIND_DATAW = extern struct {
        dwFileAttributes: u32,
        ftCreationTime: FILETIME,
        ftLastAccessTime: FILETIME,
        ftLastWriteTime: FILETIME,
        nFileSizeHigh: u32,
        nFileSizeLow: u32,
        dwReserved0: u32,
        dwReserved1: u32,
        cFileName: [260]u16,
        cAlternateFileName: [14]u16,
    };

    pub const invalid_handle_value: HANDLE = @ptrFromInt(std.math.maxInt(usize));

    /// MAX_PATH, the bound on cFileName; a UTF-8 form of a name that long can
    /// need up to three bytes per unit.
    pub const MAX_PATH: usize = 260;

    // The W entry point, so a component whose name carries characters outside
    // the process ANSI code page is queried as written instead of mangled.
    extern "kernel32" fn FindFirstFileW(lpFileName: [*:0]const u16, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) HANDLE;
    extern "kernel32" fn FindClose(hFindFile: HANDLE) callconv(.winapi) i32;
} else struct {};

fn isPathSeparator(ch: u8) bool {
    return ch == '\\' or ch == '/';
}

fn maybeResolveCaseInsensitiveWindowsPath(path: []const u8, out_buf: []u8) ?[]const u8 {
    if (!is_windows or path.len == 0 or path.len >= out_buf.len) return null;
    if (std.mem.indexOfAny(u8, path, "*?") != null) return null;

    var out_len: usize = 0;
    var i: usize = 0;

    if (path.len >= 2 and path[1] == ':') {
        if (out_buf.len < 2) return null;
        out_buf[0] = path[0];
        out_buf[1] = ':';
        out_len = 2;
        i = 2;
        if (i < path.len and isPathSeparator(path[i])) {
            if (out_buf.len < 3) return null;
            out_buf[2] = '\\';
            out_len = 3;
            while (i < path.len and isPathSeparator(path[i])) : (i += 1) {}
        }
    } else if (path.len > 0 and isPathSeparator(path[0])) {
        out_buf[0] = '\\';
        out_len = 1;
        while (i < path.len and isPathSeparator(path[i])) : (i += 1) {}
    }

    while (i < path.len) {
        while (i < path.len and isPathSeparator(path[i])) : (i += 1) {}
        if (i >= path.len) break;

        const start = i;
        while (i < path.len and !isPathSeparator(path[i])) : (i += 1) {}
        const component = path[start..i];

        var next_index = i;
        while (next_index < path.len and isPathSeparator(path[next_index])) : (next_index += 1) {}
        const has_more = next_index < path.len;

        const actual_component: []const u8 = if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, ".."))
            component
        else blk: {
            var query_buf: [std.fs.max_path_bytes]u8 = undefined;
            var query_len: usize = 0;

            if (out_len > 0) {
                if (out_len >= query_buf.len) return null;
                @memcpy(query_buf[0..out_len], out_buf[0..out_len]);
                query_len = out_len;
            }
            if (query_len > 0 and query_buf[query_len - 1] != '\\') {
                if (query_len >= query_buf.len) return null;
                query_buf[query_len] = '\\';
                query_len += 1;
            }
            if (query_len + component.len >= query_buf.len) return null;
            @memcpy(query_buf[query_len..][0..component.len], component);
            query_len += component.len;

            var query_wbuf: [std.fs.max_path_bytes]u16 = undefined;
            const query_w = wide.toWide(query_buf[0..query_len], &query_wbuf) catch return null;

            var find_data: win.WIN32_FIND_DATAW = undefined;
            const handle = win.FindFirstFileW(query_w.ptr, &find_data);
            if (handle == win.invalid_handle_value) return null;
            defer _ = win.FindClose(handle);

            // cFileName is UTF-16; the rest of this function works in UTF-8.
            var name_buf: [win.MAX_PATH * 3]u8 = undefined;
            break :blk wide.toUtf8(find_data.cFileName[0..], &name_buf) catch return null;
        };

        if (out_len > 0 and out_buf[out_len - 1] != '\\') {
            if (out_len >= out_buf.len) return null;
            out_buf[out_len] = '\\';
            out_len += 1;
        }
        if (out_len + actual_component.len + @intFromBool(has_more) > out_buf.len) return null;
        @memcpy(out_buf[out_len..][0..actual_component.len], actual_component);
        out_len += actual_component.len;
        if (has_more) {
            out_buf[out_len] = '\\';
            out_len += 1;
        }
    }

    return out_buf[0..out_len];
}

pub fn maybeResolveCaseInsensitivePath(path: []const u8, out_buf: []u8) ?[]const u8 {
    if (!is_windows) return null;
    return maybeResolveCaseInsensitiveWindowsPath(path, out_buf);
}

fn logResolvedPath(original: []const u8, resolved: []const u8) void {
    if (!std.mem.eql(u8, original, resolved)) {
        log("fs_compat: resolved '{s}' -> '{s}'\n", .{ original, resolved });
    }
}

/// Fault injection at the library's only file-I/O seam. Every open the engine
/// performs goes through this module, so a schedule installed here is what a
/// simulation replays to produce a failing open or a read that comes up
/// short. Null in production: one load of a global per open.
pub const Fault = struct {
    /// Fails the open of `path` with the error returned. Null lets it pass.
    open: ?*const fn (path: []const u8) ?anyerror = null,
    /// Bytes a whole-file read of `path` actually delivers, fewer than the
    /// file holds. Models a write that never finished, which a real disk
    /// cannot be made to do on demand. Null for no truncation.
    truncate_read: ?*const fn (path: []const u8) ?usize = null,
    /// Bytes a whole-file write of `path` actually stores, fewer than the
    /// caller offered. The complement of `truncate_read`: a short write leaves
    /// a file whose tail was never written, so a later read of it is short too.
    /// Null writes the whole buffer.
    truncate_write: ?*const fn (path: []const u8) ?usize = null,
};

pub var fault: ?*const Fault = null;

/// Fail the open of `path` if the installed schedule says so.
fn checkOpenFault(path: []const u8) ?anyerror {
    const f = fault orelse return null;
    const hook = f.open orelse return null;
    return hook(path);
}

/// Bytes a whole-file read of `path` should ask for, after any injected
/// truncation. `len` when no fault is installed.
pub fn readLength(path: []const u8, len: usize) usize {
    const f = fault orelse return len;
    const hook = f.truncate_read orelse return len;
    const want = hook(path) orelse return len;
    return @min(want, len);
}

/// Write `bytes` to `file` in full, or to the length an installed schedule
/// names for `path`. `file` must be positioned at the write offset. Returns
/// the number of bytes stored, so the caller can tell a short write from a
/// complete one exactly as it would from the real call.
pub fn writeAll(io: std.Io, file: std.Io.File, path: []const u8, bytes: []const u8) !usize {
    const f = fault orelse {
        try file.writeStreamingAll(io, bytes);
        return bytes.len;
    };
    const hook = f.truncate_write orelse {
        try file.writeStreamingAll(io, bytes);
        return bytes.len;
    };
    const want = hook(path) orelse {
        try file.writeStreamingAll(io, bytes);
        return bytes.len;
    };
    const len = @min(want, bytes.len);
    try file.writeStreamingAll(io, bytes[0..len]);
    return len;
}

pub fn openFile(io: std.Io, path: []const u8, options: std.Io.File.OpenFlags) !std.Io.File {
    if (checkOpenFault(path)) |err| return err;
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openFileAbsolute(io, path, options) catch |err| {
            var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
            const resolved = maybeResolveCaseInsensitivePath(path, &resolved_buf) orelse return err;
            if (std.mem.eql(u8, resolved, path)) return err;
            logResolvedPath(path, resolved);
            return std.Io.Dir.openFileAbsolute(io, resolved, options);
        };
    }

    return cwd.openFile(io, path, options) catch |err| {
        var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved = maybeResolveCaseInsensitivePath(path, &resolved_buf) orelse return err;
        if (std.mem.eql(u8, resolved, path)) return err;
        logResolvedPath(path, resolved);
        return cwd.openFile(io, resolved, options);
    };
}

pub fn openDir(io: std.Io, path: []const u8, options: std.Io.Dir.OpenOptions) !std.Io.Dir {
    if (checkOpenFault(path)) |err| return err;
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openDirAbsolute(io, path, options) catch |err| {
            var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
            const resolved = maybeResolveCaseInsensitivePath(path, &resolved_buf) orelse return err;
            if (std.mem.eql(u8, resolved, path)) return err;
            logResolvedPath(path, resolved);
            return std.Io.Dir.openDirAbsolute(io, resolved, options);
        };
    }

    return cwd.openDir(io, path, options) catch |err| {
        var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved = maybeResolveCaseInsensitivePath(path, &resolved_buf) orelse return err;
        if (std.mem.eql(u8, resolved, path)) return err;
        logResolvedPath(path, resolved);
        return cwd.openDir(io, resolved, options);
    };
}

pub fn createFile(io: std.Io, path: []const u8, flags: std.Io.Dir.CreateFileOptions) !std.Io.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.createFileAbsolute(io, path, flags);
    }
    return std.Io.Dir.cwd().createFile(io, path, flags);
}

pub fn dupeResolvedPathZ(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = maybeResolveCaseInsensitivePath(path, &resolved_buf) orelse path;
    logResolvedPath(path, resolved);
    return try allocator.dupeZ(u8, resolved);
}

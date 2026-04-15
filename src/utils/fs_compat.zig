const std = @import("std");
const builtin = @import("builtin");
const logger = @import("logger.zig");

const log = logger.log;
const is_windows = builtin.os.tag == .windows;

const win = if (is_windows) struct {
    const HANDLE = ?*anyopaque;

    const FILETIME = extern struct {
        dwLowDateTime: u32,
        dwHighDateTime: u32,
    };

    pub const WIN32_FIND_DATAA = extern struct {
        dwFileAttributes: u32,
        ftCreationTime: FILETIME,
        ftLastAccessTime: FILETIME,
        ftLastWriteTime: FILETIME,
        nFileSizeHigh: u32,
        nFileSizeLow: u32,
        dwReserved0: u32,
        dwReserved1: u32,
        cFileName: [260]u8,
        cAlternateFileName: [14]u8,
    };

    pub const invalid_handle_value: HANDLE = @ptrFromInt(std.math.maxInt(usize));

    extern "kernel32" fn FindFirstFileA(lpFileName: [*:0]const u8, lpFindFileData: *WIN32_FIND_DATAA) callconv(.winapi) HANDLE;
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
            var query_buf: [std.fs.max_path_bytes:0]u8 = undefined;
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
            query_buf[query_len] = 0;

            var find_data: win.WIN32_FIND_DATAA = undefined;
            const handle = win.FindFirstFileA(&query_buf, &find_data);
            if (handle == win.invalid_handle_value) return null;
            defer _ = win.FindClose(handle);

            break :blk std.mem.sliceTo(find_data.cFileName[0..], 0);
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

pub fn openFile(path: []const u8, flags: std.fs.File.OpenFlags) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openFileAbsolute(path, flags) catch |err| {
            var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
            const resolved = maybeResolveCaseInsensitivePath(path, &resolved_buf) orelse return err;
            if (std.mem.eql(u8, resolved, path)) return err;
            logResolvedPath(path, resolved);
            return std.fs.openFileAbsolute(resolved, flags);
        };
    }

    return std.fs.cwd().openFile(path, flags) catch |err| {
        var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved = maybeResolveCaseInsensitivePath(path, &resolved_buf) orelse return err;
        if (std.mem.eql(u8, resolved, path)) return err;
        logResolvedPath(path, resolved);
        return std.fs.cwd().openFile(resolved, flags);
    };
}

pub fn openDir(path: []const u8, options: std.fs.Dir.OpenOptions) !std.fs.Dir {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.openDirAbsolute(path, options) catch |err| {
            var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
            const resolved = maybeResolveCaseInsensitivePath(path, &resolved_buf) orelse return err;
            if (std.mem.eql(u8, resolved, path)) return err;
            logResolvedPath(path, resolved);
            return std.fs.openDirAbsolute(resolved, options);
        };
    }

    return std.fs.cwd().openDir(path, options) catch |err| {
        var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
        const resolved = maybeResolveCaseInsensitivePath(path, &resolved_buf) orelse return err;
        if (std.mem.eql(u8, resolved, path)) return err;
        logResolvedPath(path, resolved);
        return std.fs.cwd().openDir(resolved, options);
    };
}

pub fn createFile(path: []const u8, flags: std.fs.File.CreateFlags) !std.fs.File {
    if (std.fs.path.isAbsolute(path)) {
        return std.fs.createFileAbsolute(path, flags);
    }
    return std.fs.cwd().createFile(path, flags);
}

pub fn dupeResolvedPathZ(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = maybeResolveCaseInsensitivePath(path, &resolved_buf) orelse path;
    logResolvedPath(path, resolved);
    return try allocator.dupeZ(u8, resolved);
}

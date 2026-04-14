const std = @import("std");
const builtin = @import("builtin");

var log_file: ?std.fs.File = null;
var initialized = false;
var debug_enabled = false;
var mutex = std.Thread.Mutex{};

extern "kernel32" fn GetEnvironmentVariableA(lpName: [*:0]const u8, lpBuffer: [*]u8, nSize: u32) callconv(.winapi) u32;
extern "kernel32" fn OutputDebugStringA(lpOutputString: [*c]const u8) callconv(.winapi) void;

pub fn init() void {
    if (initialized) return;
    mutex.lock();
    defer mutex.unlock();
    if (initialized) return;

    // Default to enabled in debug builds, but allow override via env var
    debug_enabled = builtin.mode == .Debug;

    if (builtin.os.tag == .windows) {
        var buf: [256]u8 = undefined;
        const len = GetEnvironmentVariableA("OPENMILES_DEBUG", &buf, buf.len);
        if (len > 0 and len < buf.len) {
            const val = buf[0..len];
            if (std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true")) {
                debug_enabled = true;
            } else {
                debug_enabled = false;
            }
        }
    } else {
        if (std.posix.getenv("OPENMILES_DEBUG")) |val| {
            if (std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "true")) {
                debug_enabled = true;
            } else {
                debug_enabled = false;
            }
        }
    }

    if (debug_enabled) {
        // Try to open openmiles.log in current directory with restrictive permissions
        if (std.fs.cwd().createFile("openmiles.log", .{
            .truncate = false,
            .mode = if (builtin.os.tag != .windows) 0o600 else 0,
        })) |f| {
            f.seekFromEnd(0) catch {};
            log_file = f;
        } else |_| {}
    }
    initialized = true;
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled and initialized) return;
    init();
    if (!debug_enabled) return;
    {
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;

        mutex.lock();
        defer mutex.unlock();

        if (builtin.os.tag == .windows) {
            // Write to OutputDebugString
            var z_buf: [1025]u8 = undefined;
            @memcpy(z_buf[0..msg.len], msg);
            z_buf[msg.len] = 0;
            OutputDebugStringA(@ptrCast(&z_buf));
        } else {
            std.debug.print("{s}", .{msg});
        }

        if (log_file) |f| {
            _ = f.writeAll(msg) catch {};
        }
    }
}

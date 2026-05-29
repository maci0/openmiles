//! Cross-platform dynamic library loader.
//!
//! Zig 0.16 removed the Windows backend from `std.DynLib` (the `else` branch of
//! its inner-type switch is `@compileError("unsupported platform")`). Windows is
//! OpenMiles' primary target — mss32.dll is loaded into games which in turn load
//! real `.asi`/`.m3d`/`.flt` MSS plugin DLLs at runtime via the RIB system. So we
//! provide our own thin loader: Win32 LoadLibrary/GetProcAddress/FreeLibrary on
//! Windows, delegating to `std.DynLib` everywhere else.

const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

pub const Error = error{ FileNotFound, OutOfMemory } || std.posix.RealPathError;

pub const DynLib = if (native_os == .windows) WindowsDynLib else StdDynLib;

/// Wrapper around `std.DynLib` for non-Windows targets, normalizing the API to
/// the small surface the RIB provider needs (open / close / lookup).
const StdDynLib = struct {
    inner: std.DynLib,

    pub fn open(path: []const u8) !DynLib {
        return .{ .inner = try std.DynLib.open(path) };
    }

    pub fn close(self: *DynLib) void {
        self.inner.close();
    }

    pub fn lookup(self: *DynLib, comptime T: type, name: [:0]const u8) ?T {
        return self.inner.lookup(T, name);
    }
};

/// Win32 module loader. Mirrors the original MSS behavior: plugins are ordinary
/// DLLs resolved through the OS loader so dependent imports (other MSS DLLs,
/// system libraries) are satisfied normally.
const WindowsDynLib = struct {
    const windows = std.os.windows;

    extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?windows.HMODULE;
    extern "kernel32" fn FreeLibrary(hLibModule: windows.HMODULE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?windows.FARPROC;

    module: windows.HMODULE,

    pub fn open(path: []const u8) !DynLib {
        // LoadLibraryA needs a NUL-terminated path; bound by max_path_bytes.
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        if (path.len >= buf.len) return error.FileNotFound;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&buf);
        const module = LoadLibraryA(path_z) orelse return error.FileNotFound;
        return .{ .module = module };
    }

    pub fn close(self: *DynLib) void {
        _ = FreeLibrary(self.module);
        self.module = undefined;
    }

    pub fn lookup(self: *DynLib, comptime T: type, name: [:0]const u8) ?T {
        const addr = GetProcAddress(self.module, name.ptr) orelse return null;
        return @as(T, @ptrCast(@alignCast(addr)));
    }
};

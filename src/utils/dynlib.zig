//! Cross-platform dynamic library loader.
//!
//! Zig 0.16 removed the Windows backend from `std.DynLib` (the `else` branch of
//! its inner-type switch is `@compileError("unsupported platform")`). Windows is
//! OpenMiles' primary target — mss32.dll is loaded into games which in turn load
//! real `.asi`/`.m3d`/`.flt` MSS plugin DLLs at runtime via the RIB system. So we
//! provide our own thin loader: Win32 LoadLibrary/GetProcAddress/FreeLibrary on
//! Windows, delegating to `std.DynLib` everywhere else.
//!
//! On Linux + static musl, std.DynLib uses its minimal ElfDynLib mapper, which
//! (a) copies each writable segment's initialized data from file offset 0
//! instead of the segment's p_offset, corrupting `.data`, and (b) applies no
//! relocations, so pointer fields in plugin data still hold link-time
//! addresses and crash on first dereference. `applyElfFixups` repairs both
//! after the map so RIB plugins register correctly.

const std = @import("std");
const builtin = @import("builtin");
const native_os = builtin.os.tag;

pub const Error = error{ FileNotFound, OutOfMemory, ImageFixupFailed } || std.posix.RealPathError;

/// Same condition under which std.DynLib picks its relocation-less ElfDynLib
/// backend (plus an arch gate: the relocation pass knows x86_64 types).
const needs_elf_fixup = native_os == .linux and
    builtin.abi == .musl and
    builtin.link_mode == .static and
    builtin.cpu.arch == .x86_64;

pub const DynLib = if (native_os == .windows) WindowsDynLib else StdDynLib;

/// Wrapper around `std.DynLib` for non-Windows targets, normalizing the API to
/// the small surface the RIB provider needs (open / close / lookup).
const StdDynLib = struct {
    inner: std.DynLib,

    pub fn open(path: []const u8) !DynLib {
        var self: DynLib = .{ .inner = try std.DynLib.open(path) };
        errdefer self.inner.close();
        if (needs_elf_fixup) try applyElfFixups(&self.inner, path);
        return self;
    }

    pub fn close(self: *DynLib) void {
        self.inner.close();
    }

    pub fn lookup(self: *DynLib, comptime T: type, name: [:0]const u8) ?T {
        return self.inner.lookup(T, name);
    }
};

/// Repair std.DynLib's ElfDynLib map: re-copy writable segments from their real
/// file offsets and apply R_X86_64_RELATIVE relocations against the load base.
fn applyElfFixups(lib: *std.DynLib, path: []const u8) !void {
    const img = lib.inner.memory;
    const base = @intFromPtr(img.ptr);
    if (img.len < @sizeOf(std.elf.Ehdr)) return error.ImageFixupFailed;
    const eh: *const std.elf.Ehdr = @ptrCast(img.ptr);
    if (!std.mem.eql(u8, eh.e_ident[0..4], std.elf.MAGIC)) return error.ImageFixupFailed;
    const phdr_end: usize = @intCast(eh.e_phoff + @as(u64, eh.e_phentsize) * eh.e_phnum);
    if (eh.e_phoff == 0 or phdr_end > img.len) return error.ImageFixupFailed;

    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    const fd = std.posix.openat(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0) catch return error.ImageFixupFailed;
    defer _ = std.os.linux.close(fd);

    const phdrs: [*]align(1) const std.elf.Phdr = @ptrFromInt(base + @as(usize, @intCast(eh.e_phoff)));
    var dynamic_vaddr: ?usize = null;
    for (phdrs[0..eh.e_phnum]) |ph| {
        switch (ph.p_type) {
            std.elf.PT_LOAD => if ((ph.p_flags & std.elf.PF_W) != 0) {
                recopyWritableSegment(fd, img, ph) catch return error.ImageFixupFailed;
            },
            std.elf.PT_DYNAMIC => dynamic_vaddr = ph.p_vaddr,
            else => {},
        }
    }

    const dyn_vaddr = dynamic_vaddr orelse return error.ImageFixupFailed;
    if (dyn_vaddr >= img.len) return error.ImageFixupFailed;
    const dynv: [*]align(1) const usize = @ptrFromInt(base + dyn_vaddr);
    var rela_off: usize = 0;
    var rela_sz: usize = 0;
    var i: usize = 0;
    while (dynv[i] != 0) : (i += 2) {
        switch (dynv[i]) {
            std.elf.DT_RELA => rela_off = dynv[i + 1],
            std.elf.DT_RELASZ => rela_sz = dynv[i + 1],
            else => {},
        }
    }
    if (rela_off == 0 or rela_sz == 0) return;
    if (rela_off >= img.len or rela_sz > img.len - rela_off) return error.ImageFixupFailed;

    const relas: [*]align(1) const std.elf.Rela = @ptrFromInt(base + rela_off);
    for (relas[0 .. rela_sz / @sizeOf(std.elf.Rela)]) |r| {
        if (@as(u32, @truncate(r.r_info)) == @intFromEnum(std.elf.R_X86_64.RELATIVE)) {
            const slot: *u64 = @ptrFromInt(base + r.r_offset);
            slot.* = @bitCast(base +% @as(u64, @bitCast(r.r_addend)));
        }
    }
}

/// Copy the segment's initialized bytes from p_offset (the source std uses,
/// file offset 0, yields ELF-header garbage for every non-first segment).
fn recopyWritableSegment(fd: std.posix.fd_t, img: []u8, ph: std.elf.Phdr) !void {
    if (ph.p_filesz == 0) return;
    if (@as(u64, ph.p_vaddr) + ph.p_filesz > img.len) return error.ImageFixupFailed;
    const buf = try std.heap.page_allocator.alloc(u8, @intCast(ph.p_filesz));
    defer std.heap.page_allocator.free(buf);
    var got: usize = 0;
    while (got < buf.len) {
        const rc = std.os.linux.pread(fd, buf[got..].ptr, buf.len - got, @intCast(ph.p_offset + got));
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.ImageFixupFailed; // truncated file
                got += rc;
            },
            .INTR => continue,
            else => return error.ImageFixupFailed,
        }
    }
    @memcpy(img[ph.p_vaddr..][0..@intCast(ph.p_filesz)], buf);
}

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

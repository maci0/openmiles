//! Cross-platform dynamic library loader.
//!
//! Zig 0.16 removed the Windows backend from `std.DynLib` (the `else` branch of
//! its inner-type switch is `@compileError("unsupported platform")`). Windows is
//! OpenMiles' primary target — mss32.dll is loaded into games which in turn load
//! real `.asi`/`.m3d`/`.flt` MSS plugin DLLs at runtime via the RIB system. So we
//! provide our own thin loader: Win32 LoadLibrary/GetProcAddress/FreeLibrary on
//! Windows, delegating to `std.DynLib` everywhere else.
//!
//! On Linux without a libc (or with static musl), std.DynLib uses its minimal
//! ElfDynLib mapper, which (a) copies each writable segment's initialized data
//! from file offset 0 instead of the segment's p_offset, corrupting `.data`,
//! and (b) applies no relocations, so pointer fields in plugin data still hold
//! link-time addresses and crash on first dereference. `applyElfFixups`
//! repairs both after the map so RIB plugins register correctly. The
//! condition is std's own (`dynamic_library.zig`), not an arch-narrowed copy
//! of it: a gate that named one architecture left every other Linux build
//! with the broken mapper and no repair.

const std = @import("std");
const builtin = @import("builtin");
const wide = @import("wide.zig");
const native_os = builtin.os.tag;

/// Same condition under which std.DynLib picks its relocation-less ElfDynLib
/// backend. It names no architecture, so neither does this: aarch64 and every
/// other Linux target reach the same broken map and get the same repair.
const needs_elf_fixup = native_os == .linux and
    (!builtin.link_libc or (builtin.abi == .musl and builtin.link_mode == .static));

/// The relocation an architecture uses to rebase a pointer against the load
/// base, or null where the pass below does not apply. Two things narrow it: a
/// 32-bit target, whose `Elf32_Dyn` entries the walk reads at 64-bit stride,
/// and an architecture std names no RELATIVE type for. The writable-segment
/// recopy that precedes this needs neither, so it runs either way.
const relative_reloc_type: ?u32 = switch (builtin.cpu.arch) {
    .x86_64 => @intFromEnum(std.elf.R_X86_64.RELATIVE),
    .aarch64 => @intFromEnum(std.elf.R_AARCH64.RELATIVE),
    else => null,
};

pub const DynLib = if (native_os == .windows) WindowsDynLib else StdDynLib;

/// Wrapper around `std.DynLib` for non-Windows targets, normalizing the API to
/// the small surface the RIB provider needs (open / close / lookup).
const StdDynLib = struct {
    inner: std.DynLib,

    pub fn open(path: []const u8) !DynLib {
        var self: DynLib = .{ .inner = try std.DynLib.open(path) };
        errdefer self.inner.close();
        if (comptime needs_elf_fixup) try applyElfFixups(&self.inner, path);
        return self;
    }

    pub fn close(self: *DynLib) void {
        self.inner.close();
    }

    pub fn lookup(self: *DynLib, comptime T: type, name: [:0]const u8) ?T {
        return self.inner.lookup(T, name);
    }
};

/// Whether the program header table named by `eh` lies inside the image.
///
/// The three fields are file-controlled, so the sum is computed in u64 and
/// compared there: a crafted e_phoff plus e_phentsize * e_phnum lands far past
/// the end of any image, and a comparison made in u32 would truncate it back to
/// a small value that passes.
fn programHeaderTableFits(eh: *const std.elf.Ehdr, img_len: usize) bool {
    if (eh.e_phoff == 0) return false;
    // The walk below indexes a [*]Phdr, so it strides by @sizeOf(Phdr), not by
    // e_phentsize. A file whose declared entry size is smaller makes the two
    // disagree and the loop reads past the image the bound was computed for.
    if (eh.e_phentsize < @sizeOf(std.elf.Phdr)) return false;
    const end = @as(u64, eh.e_phoff) + @as(u64, eh.e_phentsize) * @as(u64, eh.e_phnum);
    return end <= @as(u64, img_len);
}

/// Repair std.DynLib's ElfDynLib map: re-copy writable segments from their real
/// file offsets and apply the load-base-relative relocations against the load
/// base.
fn applyElfFixups(lib: *std.DynLib, path: []const u8) !void {
    const img = lib.inner.memory;
    const base = @intFromPtr(img.ptr);
    if (img.len < @sizeOf(std.elf.Ehdr)) return error.ImageFixupFailed;
    const eh: *const std.elf.Ehdr = @ptrCast(img.ptr);
    if (!std.mem.eql(u8, eh.e_ident[0..4], std.elf.MAGIC)) return error.ImageFixupFailed;
    if (!programHeaderTableFits(eh, img.len)) return error.ImageFixupFailed;

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
            std.elf.PT_DYNAMIC => dynamic_vaddr = std.math.cast(usize, ph.p_vaddr) orelse return error.ImageFixupFailed,
            else => {},
        }
    }

    const rel_type = relative_reloc_type orelse return;
    const dyn_vaddr = dynamic_vaddr orelse return error.ImageFixupFailed;
    if (dyn_vaddr >= img.len) return error.ImageFixupFailed;
    const dynv: [*]align(1) const usize = @ptrFromInt(base + dyn_vaddr);
    // The DT_NULL terminator is what ends this walk, and a malformed image may
    // not have one inside the mapping. Bound the scan by the image so a lying
    // dynamic section fails the load instead of reading past the map. Each step
    // reads d_tag and d_un, so the bound is on complete pairs: `dyn_entries` is
    // truncated and can be odd, and stopping on it alone would read one entry
    // past the image.
    const dyn_entries = (img.len - dyn_vaddr) / @sizeOf(usize);
    if (dyn_entries < 2) return error.ImageFixupFailed;
    var rela_off: usize = 0;
    var rela_sz: usize = 0;
    var i: usize = 0;
    while (i + 1 < dyn_entries and dynv[i] != 0) : (i += 2) {
        switch (dynv[i]) {
            std.elf.DT_RELA => rela_off = dynv[i + 1],
            std.elf.DT_RELASZ => rela_sz = dynv[i + 1],
            else => {},
        }
    }
    if (rela_off == 0 or rela_sz == 0) return;
    if (rela_off >= img.len or rela_sz > img.len - rela_off) return error.ImageFixupFailed;

    const relas: [*]align(1) const std.elf.Rela = @ptrFromInt(base + rela_off);
    try applyRelativeRelocations(base, img.len, rel_type, relas[0 .. rela_sz / @sizeOf(std.elf.Rela)]);
}

/// Rebase every relocation of type `rel_type` in `relas` against `base`.
///
/// The slot is a pointer-width word, so the bounds are in the address space's
/// own units: an x86_64 or aarch64 slot is 8 bytes and 8-aligned, a 32-bit one
/// 4 and 4. A hardcoded 8 is only right on the architecture it was written
/// for, and would misalign-check the wrong slots on every other one.
fn applyRelativeRelocations(base: usize, img_len: usize, rel_type: u32, relas: []align(1) const std.elf.Rela) !void {
    for (relas) |r| {
        if (@as(u32, @truncate(r.r_info)) != rel_type) continue;
        // r_offset is file-controlled and not implied by the rela table's own
        // bounds, so a crafted entry would otherwise write anywhere in the
        // address space. Only in-image, pointer-aligned slots are ours.
        if (r.r_offset % @alignOf(usize) != 0 or r.r_offset > img_len -| @sizeOf(usize)) return error.ImageFixupFailed;
        const slot: *usize = @ptrFromInt(base + r.r_offset);
        // The addend is a signed file-controlled field; a negative one wraps
        // rather than traps, and the load base added to it wraps the same way.
        const addend: std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(r.r_addend))) = @bitCast(r.r_addend);
        slot.* = base +% @as(usize, @truncate(addend));
    }
}

/// Copy the segment's initialized bytes from p_offset (the source std uses,
/// file offset 0, yields ELF-header garbage for every non-first segment).
fn recopyWritableSegment(fd: std.posix.fd_t, img: []u8, ph: std.elf.Phdr) !void {
    if (ph.p_filesz == 0) return;
    // Saturating: p_vaddr and p_filesz are file-controlled, so a sum that wraps
    // would compare as small and pass the bound with a segment that lies past
    // the mapping.
    if (@as(u64, ph.p_vaddr) +| ph.p_filesz > img.len) return error.ImageFixupFailed;
    const buf = try std.heap.page_allocator.alloc(u8, @intCast(ph.p_filesz));
    defer std.heap.page_allocator.free(buf);
    var got: usize = 0;
    while (got < buf.len) {
        const rc = std.os.linux.pread(fd, buf[got..].ptr, buf.len - got, @intCast(ph.p_offset +| @as(u64, got)));
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

    // LoadLibraryW, not LoadLibraryA: the game directory a plugin is loaded
    // from routinely contains characters outside the process ANSI code page,
    // which the A entry point turns into '?' and then fails to find.
    extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?windows.HMODULE;
    extern "kernel32" fn FreeLibrary(hLibModule: windows.HMODULE) callconv(.winapi) windows.BOOL;
    extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?windows.FARPROC;

    module: windows.HMODULE,

    /// Why the last Windows load failed, for a caller to log. The code is
    /// threadlocal because a load is threadlocal, and null on non-Windows.
    pub threadlocal var last_load_error: ?LoadFailure = null;

    pub const LoadFailure = struct {
        /// The raw Win32 code, for a reader who knows the numeric namespace.
        win32: u32,
        /// The name Zig gives the matching std error, which is the readable one.
        name: []const u8,
    };

    pub fn open(path: []const u8) !DynLib {
        var buf: [std.fs.max_path_bytes]u16 = undefined;
        // toWide fails with NoSpaceLeft on an over-long path and InvalidUtf8 on
        // one spelled outside Unicode, neither of which is a missing file, so
        // the conversion error propagates as it stands rather than being
        // renamed FileNotFound and sent to a caller hunting a file on disk.
        const path_w = try wide.toWide(path, &buf);
        // LoadLibraryW's null covers three causes the caller has to tell apart:
        // the module is absent, one of its imports is absent (ERROR_MOD_NOT_
        // FOUND with the module present on disk), or its DllMain refused. They
        // were all reported as FileNotFound, which sends the operator looking
        // for a file that is there. GetLastError is only valid until the next
        // Win32 call, so it is captured here and read by the caller that knows
        // the plugin's name.
        const module = LoadLibraryW(path_w.ptr) orelse {
            const err = windows.GetLastError();
            last_load_error = .{ .win32 = @intFromEnum(err), .name = @errorName(err) };
            return error.LoadLibraryFailed;
        };
        last_load_error = null;
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

const testing = std.testing;

test "a program header table inside the image is accepted" {
    var eh: std.elf.Ehdr = std.mem.zeroes(std.elf.Ehdr);
    eh.e_phoff = 64;
    eh.e_phentsize = @sizeOf(std.elf.Phdr);
    eh.e_phnum = 4;
    try testing.expect(programHeaderTableFits(&eh, 64 + 4 * @sizeOf(std.elf.Phdr)));
    try testing.expect(programHeaderTableFits(&eh, 4096));
}

test "a program header table past the end of the image is rejected" {
    var eh: std.elf.Ehdr = std.mem.zeroes(std.elf.Ehdr);
    eh.e_phoff = 4096;
    eh.e_phentsize = @sizeOf(std.elf.Phdr);
    eh.e_phnum = 4;
    try testing.expect(!programHeaderTableFits(&eh, 4096));
}

test "a program header table whose end overflows u64 is rejected" {
    // The field is 32 bits on a 32-bit target, so the image this describes
    // cannot be spelled there and the overflow cannot happen: the literal would
    // not compile, taking the whole test binary down with it.
    if (@bitSizeOf(@TypeOf(std.mem.zeroes(std.elf.Ehdr).e_phoff)) < 64) return error.SkipZigTest;
    var eh: std.elf.Ehdr = std.mem.zeroes(std.elf.Ehdr);
    // e_phoff + e_phentsize * e_phnum stays inside u64 but lands at
    // 2^64 - 122879, which a u32 bound would truncate to 0x2001 and accept as a
    // table inside a 16 KiB image.
    eh.e_phoff = 0xffffffff00002000;
    eh.e_phentsize = 0xffff;
    eh.e_phnum = 0xffff;
    try testing.expect(!programHeaderTableFits(&eh, 0x4000));
}

test "an image with no program header table is rejected" {
    var eh: std.elf.Ehdr = std.mem.zeroes(std.elf.Ehdr);
    eh.e_phentsize = @sizeOf(std.elf.Phdr);
    eh.e_phnum = 4;
    try testing.expect(!programHeaderTableFits(&eh, 4096));
}

test "a relative relocation rebases the slot against the load base" {
    const rel_type = relative_reloc_type orelse return error.SkipZigTest;
    // Aligned as the mapped image is, so a slot at a pointer-aligned offset is
    // one a *usize can be formed at.
    var image: [64]u8 align(@alignOf(usize)) = @splat(0);
    const base = @intFromPtr(&image);
    var relas = [_]std.elf.Rela{.{ .r_offset = 32, .r_info = rel_type, .r_addend = 0x1234 }};
    try applyRelativeRelocations(base, image.len, rel_type, relas[0..]);
    const slot: *usize = @ptrFromInt(base + 32);
    try testing.expectEqual(base + 0x1234, slot.*);
}

test "a relocation of another type leaves the slot alone" {
    const rel_type = relative_reloc_type orelse return error.SkipZigTest;
    var image: [64]u8 align(@alignOf(usize)) = @splat(0);
    const base = @intFromPtr(&image);
    var relas = [_]std.elf.Rela{.{ .r_offset = 32, .r_info = rel_type ^ 1, .r_addend = 0x1234 }};
    try applyRelativeRelocations(base, image.len, rel_type, relas[0..]);
    const slot: *const usize = @ptrFromInt(base + 32);
    try testing.expectEqual(@as(usize, 0), slot.*);
}

test "a slot at a misaligned or out-of-image offset is rejected" {
    const rel_type = relative_reloc_type orelse return error.SkipZigTest;
    var image: [64]u8 align(@alignOf(usize)) = @splat(0);
    const base = @intFromPtr(&image);

    // A pointer-sized slot the base address cannot hold at this alignment: the
    // bound has to be the address space's own alignment, not a fixed 8.
    const misaligned: usize = @alignOf(usize) + 1;
    var bad_align = [_]std.elf.Rela{.{ .r_offset = misaligned, .r_info = rel_type, .r_addend = 0 }};
    try testing.expectError(error.ImageFixupFailed, applyRelativeRelocations(base, image.len, rel_type, bad_align[0..]));

    var past_end = [_]std.elf.Rela{.{ .r_offset = image.len, .r_info = rel_type, .r_addend = 0 }};
    try testing.expectError(error.ImageFixupFailed, applyRelativeRelocations(base, image.len, rel_type, past_end[0..]));
}

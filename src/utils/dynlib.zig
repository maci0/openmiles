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
/// base, or null where the pass below does not apply: an architecture whose
/// RELATIVE value this build has no name for, because std.elf defines the
/// enum for only the four below. Those are the whole of the 64-bit ELF
/// architectures std ships a relocation table for, and the writable-segment
/// recopy that precedes this pass needs no architecture at all, so it runs on
/// every Linux target either way.
const relative_reloc_type: ?u32 = switch (builtin.cpu.arch) {
    .x86_64 => @intFromEnum(std.elf.R_X86_64.RELATIVE),
    .aarch64 => @intFromEnum(std.elf.R_AARCH64.RELATIVE),
    .riscv64 => @intFromEnum(std.elf.R_RISCV.RELATIVE),
    .powerpc64 => @intFromEnum(std.elf.R_PPC64.RELATIVE),
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

/// Where a writable segment's initialized bytes are read from: the file on
/// disk when a mapped image is being repaired, and a filling source when the
/// image is already in memory. A fuzz image is built in a buffer rather than
/// mapped from a path, so the pass cannot reopen itself, and a parser that can
/// only be reached through a file descriptor is a parser that is only ever
/// tested by hand.
const SegmentSource = struct {
    /// The open file a real image is read back from, or null when the image
    /// already holds every byte a segment claims.
    fd: ?*const std.posix.fd_t,
    readAt: *const fn (fd: ?*const std.posix.fd_t, offset: u64, buf: []u8) anyerror!void,
};

/// Fill `buf` from the open file `fd` names, starting at `offset`. A short
/// read is a truncated file, not an error to retry past: the segment claims
/// bytes the file does not have.
fn readSegmentFromFd(fd: ?*const std.posix.fd_t, offset: u64, buf: []u8) anyerror!void {
    var got: usize = 0;
    while (got < buf.len) {
        const rc = std.os.linux.pread((fd orelse return error.ImageFixupFailed).*, buf[got..].ptr, buf.len - got, @intCast(offset +| @as(u64, got)));
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return error.ImageFixupFailed; // truncated file
                got += rc;
            },
            .INTR => continue,
            else => return error.ImageFixupFailed,
        }
    }
}

fn applyElfFixups(lib: *std.DynLib, path: []const u8) !void {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    const fd = std.posix.openat(std.posix.AT.FDCWD, path_z, .{ .ACCMODE = .RDONLY }, 0) catch return error.ImageFixupFailed;
    defer _ = std.os.linux.close(fd);
    try fixupImage(lib.inner.memory, .{ .fd = &fd, .readAt = readSegmentFromFd });
}

/// Repair an already-mapped ELF image in place: re-copy writable segments from
/// their real file offsets and apply the load-base-relative relocations against
/// the load base.
///
/// Every field this reads is file-controlled, and the walks below are the
/// unchecked ones (`[*]Phdr`, `[*]usize`, `[*]Rela`), so each bound is checked
/// against the image before the pointer is formed rather than left to the
/// slice bounds checks that a raw pointer does not get.
fn fixupImage(img: []align(@alignOf(std.elf.Ehdr)) u8, seg: SegmentSource) !void {
    const base = @intFromPtr(img.ptr);
    if (img.len < @sizeOf(std.elf.Ehdr)) return error.ImageFixupFailed;
    const eh: *const std.elf.Ehdr = @ptrCast(img.ptr);
    if (!std.mem.eql(u8, eh.e_ident[0..4], std.elf.MAGIC)) return error.ImageFixupFailed;
    if (!programHeaderTableFits(eh, img.len)) return error.ImageFixupFailed;

    const phdrs: [*]align(1) const std.elf.Phdr = @ptrFromInt(base + @as(usize, @intCast(eh.e_phoff)));
    var dynamic_vaddr: ?usize = null;
    for (phdrs[0..eh.e_phnum]) |ph| {
        switch (ph.p_type) {
            std.elf.PT_LOAD => if ((ph.p_flags & std.elf.PF_W) != 0) {
                recopyWritableSegment(img, seg, ph) catch return error.ImageFixupFailed;
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
fn recopyWritableSegment(img: []u8, seg: SegmentSource, ph: std.elf.Phdr) !void {
    if (ph.p_filesz == 0) return;
    // Saturating: p_vaddr and p_filesz are file-controlled, so a sum that wraps
    // would compare as small and pass the bound with a segment that lies past
    // the mapping.
    if (@as(u64, ph.p_vaddr) +| ph.p_filesz > img.len) return error.ImageFixupFailed;
    const buf = try std.heap.page_allocator.alloc(u8, @intCast(ph.p_filesz));
    defer std.heap.page_allocator.free(buf);
    try seg.readAt(seg.fd, ph.p_offset, buf);
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
            last_load_error = .{ .win32 = @intFromEnum(err), .name = @tagName(err) };
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

// --- fuzzing the image walk -------------------------------------------------

/// An image with an unmapped page after it.
///
/// The fixup pass indexes raw pointers (a [*]Phdr, a [*]usize, a [*]Rela), and
/// a raw pointer is exactly what Zig's slice bounds checks do not cover: an
/// offset a crafted header aims past the end of the image is a wild access,
/// not a panic. Ending the allocation where the image ends, and taking the page
/// after it away with PROT_NONE, turns that access into a fault the test run
/// cannot walk past. This walk is otherwise reachable only by mapping a real
/// library, so a hostile `.asi` plugin is the only thing that would ever hand
/// it a lie.
const GuardedImage = struct {
    buf: []u8,
    /// Aligned as a mapped image is, so the pass can form the `*Ehdr` and
    /// `*Phdr` it forms over a real map without the test asserting an alignment
    /// the image does not have.
    img: []align(@alignOf(std.elf.Ehdr)) u8,

    fn init(img_len: usize) !GuardedImage {
        const page = std.heap.page_size_min;
        const pages = std.mem.alignForward(usize, img_len, page) / page + 1;
        const buf = try std.heap.page_allocator.alloc(u8, pages * page);
        errdefer std.heap.page_allocator.free(buf);
        if (@intFromPtr(buf.ptr) % page != 0) return error.ImageFixupFailed;
        const img_end = std.mem.alignForward(usize, img_len, page);
        if (img_end % @alignOf(std.elf.Ehdr) != 0) return error.ImageFixupFailed;
        if (std.os.linux.mprotect(buf.ptr + img_end, page, .{ .READ = true }) != 0) {
            return error.ImageFixupFailed;
        }
        return .{ .buf = buf, .img = @alignCast(buf[0..img_len]) };
    }

    fn deinit(self: *GuardedImage) void {
        // The guard page is PROT_NONE, and unmapping a range that contains a
        // protected page is fine, but restoring it first keeps the free
        // independent of how the mapping was left.
        _ = std.os.linux.mprotect(self.buf.ptr + std.mem.alignForward(usize, self.img.len, std.heap.page_size_min), std.heap.page_size_min, .{ .READ = true, .WRITE = true });
        std.heap.page_allocator.free(self.buf);
    }
};

/// Stands in for the file on disk: the segment's copy has to be visible in the
/// image, and a buffer that costs no descriptor and no second mapping is where
/// it is visible from.
fn fillSegment(_: ?*const std.posix.fd_t, _: u64, buf: []u8) anyerror!void {
    @memset(buf, 0xA5);
}

const mem_source = SegmentSource{ .fd = null, .readAt = fillSegment };

/// Write the dynamic section of a crafted image: `pairs` unrelated entries, a
/// DT_RELA and a DT_RELASZ at the two slots `off` and `sz`, and a DT_NULL when
/// the fuzzer wants the walk to stop on the terminator rather than on the end
/// of the image. Returns nothing: the caller already knows the table, so there
/// is no entry list to hand back.
fn writeDynamic(img: []u8, dyn_vaddr: usize, pairs: usize, off: usize, off_value: usize, sz: usize, sz_value: usize) void {
    const dyn: [*]usize = @ptrCast(@alignCast(img.ptr + dyn_vaddr));
    for (dyn[0 .. pairs * 2]) |*v| v.* = 0;
    dyn[2 * off] = std.elf.DT_RELA;
    dyn[2 * off + 1] = off_value;
    dyn[2 * sz] = std.elf.DT_RELASZ;
    dyn[2 * sz + 1] = sz_value;
    if (pairs > 0 and dyn[2 * pairs - 1] == 0) dyn[2 * pairs - 1] = 0; // DT_NULL terminator
}

/// The bytes the pass is allowed to write: writable PT_LOAD segments that pass
/// the in-image bound, and relocation slots that pass the alignment and range
/// bound. Over-marking is harmless (a slot the pass never reached is marked but
/// stays untouched), so the check the caller runs stays one-directional.
fn writableBytes(alloc: std.mem.Allocator, img_len: usize, phdrs: []const std.elf.Phdr, relas: []align(1) const std.elf.Rela) ![]bool {
    const owned = try alloc.alloc(bool, img_len);
    @memset(owned, false);
    for (phdrs) |ph| {
        if (ph.p_type != std.elf.PT_LOAD or (ph.p_flags & std.elf.PF_W) == 0 or ph.p_filesz == 0) continue;
        if (@as(u64, ph.p_vaddr) +| ph.p_filesz > img_len) continue;
        @memset(owned[@intCast(ph.p_vaddr)..][0..@intCast(ph.p_filesz)], true);
    }
    for (relas) |r| {
        if (r.r_offset % @alignOf(usize) != 0 or r.r_offset > img_len -| @sizeOf(usize)) continue;
        @memset(owned[@intCast(r.r_offset)..][0..@sizeOf(usize)], true);
    }
    return owned;
}

test "fuzz: a crafted ELF image is refused or repaired inside its own bytes" {
    if (native_os != .linux) return error.SkipZigTest;
    // Every field the walk reads is file-controlled and every one of them can
    // lie, so the corpus is not a byte soup: each image is an ELF skeleton
    // with the lying fields fuzzed, because a soup is rejected at the magic and
    // never reaches the program header, dynamic, or relocation walks that this
    // pass exists to bound.
    var prng = std.Random.DefaultPrng.init(0xE1F);
    const rand = prng.random();
    const alloc = testing.allocator;

    const img_len = 2048;
    const phoff = 64;
    const phnum = 4;
    const dyn_vaddr = 512;
    const rela_off = 1024;
    const rela_cap = (img_len - rela_off) / @sizeOf(std.elf.Rela);
    const rel_type: u64 = relative_reloc_type orelse 0;

    var guarded = try GuardedImage.init(img_len);
    defer guarded.deinit();
    const img = guarded.img;

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        @memset(img, 0);
        rand.bytes(img);

        const eh: *std.elf.Ehdr = @ptrCast(@alignCast(img.ptr));
        @memcpy(eh.e_ident[0..4], std.elf.MAGIC);
        eh.e_phoff = phoff;
        eh.e_phentsize = @sizeOf(std.elf.Phdr);
        eh.e_phnum = phnum;

        // Two writable loads whose p_vaddr and p_filesz lie about where their
        // bytes go, the dynamic section, and a type the walk must ignore.
        const phdrs: [*]std.elf.Phdr = @ptrCast(@alignCast(img.ptr + phoff));
        for (phdrs[0..phnum]) |*ph| ph.* = std.mem.zeroes(std.elf.Phdr);
        phdrs[0].p_type = std.elf.PT_LOAD;
        phdrs[0].p_flags = std.elf.PF_W | std.elf.PF_R;
        phdrs[0].p_vaddr = rand.intRangeAtMost(u64, 0, img_len);
        phdrs[0].p_filesz = rand.intRangeAtMost(u64, 0, img_len);
        phdrs[0].p_offset = rand.int(u64);
        phdrs[2].p_type = std.elf.PT_LOAD;
        phdrs[2].p_flags = std.elf.PF_W;
        phdrs[2].p_vaddr = rand.intRangeAtMost(u64, 0, img_len);
        phdrs[2].p_filesz = rand.intRangeAtMost(u64, 0, img_len);
        phdrs[1].p_type = std.elf.PT_DYNAMIC;
        phdrs[1].p_vaddr = dyn_vaddr;
        phdrs[3].p_type = std.elf.PT_NOTE;

        // The relocation table: entries with a fuzzed r_info, so most are
        // skipped as another type and a few are applied, with r_offset ranging
        // over aligned, misaligned, in-image, and past-the-end values.
        const relas: [*]align(1) std.elf.Rela = @ptrCast(@alignCast(img.ptr + rela_off));
        const n_relas = rand.intRangeAtMost(usize, 0, rela_cap);
        for (relas[0..n_relas]) |*r| {
            r.* = .{
                .r_offset = rand.int(u64),
                .r_info = if (rand.boolean()) rel_type else rand.int(u64),
                .r_addend = rand.int(i64),
            };
        }
        // DT_RELASZ is a byte count and a lying one need not agree with the
        // table planted above: truncated below one entry, cut mid-entry, or
        // past the image entirely.
        const rela_sz = switch (rand.intRangeAtMost(u8, 0, 3)) {
            0 => n_relas * @sizeOf(std.elf.Rela) + rand.intRangeAtMost(usize, 0, @sizeOf(std.elf.Rela) * 2),
            1 => rand.intRangeAtMost(usize, 0, n_relas * @sizeOf(std.elf.Rela)),
            2 => rand.intRangeAtMost(usize, 0, img_len * 2),
            else => rand.int(usize),
        };

        // The two tags sit at distinct slots, so neither is overwritten by the
        // other and the table the pass reads is the one this harness marked.
        const pairs = rand.intRangeAtMost(usize, 2, 40);
        const off_slot = rand.intRangeAtMost(usize, 0, pairs - 1);
        const sz_slot = rand.intRangeAtMost(usize, 0, pairs - 1);
        writeDynamic(img, dyn_vaddr, pairs, off_slot, if (rand.boolean()) rela_off else rand.int(usize), sz_slot, rela_sz);

        const before = try alloc.dupe(u8, img);
        defer alloc.free(before);
        // The pass reads floor(rela_sz / 24) entries from the table offset, so
        // that is the set whose slots it may write; a lie that sends it past
        // the table is rejected before any relocation is applied.
        const applied = if (rela_off != 0 and rela_sz <= img_len - rela_off) rela_sz / @sizeOf(std.elf.Rela) else 0;
        const owned = try writableBytes(alloc, img_len, phdrs[0..phnum], @as([*]align(1) const std.elf.Rela, @ptrCast(relas))[0..applied]);
        defer alloc.free(owned);

        // The whole point: a bad image must fail the load, never the process.
        fixupImage(img, mem_source) catch {};

        // Nothing outside the bytes the pass owns may have moved, and nothing
        // outside the image is mapped at all, so an escaped access faults
        // above instead of passing unnoticed.
        for (img, 0..) |now, k| {
            if (!owned[k]) try testing.expectEqual(before[k], now);
        }
    }
}

test "fuzz: a second pass over a crafted image settles where the first one did" {
    if (native_os != .linux) return error.SkipZigTest;
    // The pair assertion across the mapping boundary: re-running the pass over
    // the same bytes must not move anything the first run settled. A length
    // field the pass both read and wrote, or a count a lie made grow between
    // runs, shows up here as a diff rather than as a crash.
    var prng = std.Random.DefaultPrng.init(0xE1F01);
    const rand = prng.random();
    const alloc = testing.allocator;

    const img_len = 2048;
    const rela_off = 1024;
    var guarded = try GuardedImage.init(img_len);
    defer guarded.deinit();
    const img = guarded.img;

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        @memset(img, 0);
        rand.bytes(img);
        const eh: *std.elf.Ehdr = @ptrCast(@alignCast(img.ptr));
        @memcpy(eh.e_ident[0..4], std.elf.MAGIC);
        eh.e_phoff = 64;
        eh.e_phentsize = @sizeOf(std.elf.Phdr);
        eh.e_phnum = 2;
        const phdrs: [*]std.elf.Phdr = @ptrCast(@alignCast(img.ptr + 64));
        for (phdrs[0..2]) |*ph| ph.* = std.mem.zeroes(std.elf.Phdr);
        phdrs[0].p_type = std.elf.PT_LOAD;
        phdrs[0].p_flags = std.elf.PF_W;
        phdrs[0].p_vaddr = rand.intRangeAtMost(u64, 0, img_len);
        phdrs[0].p_filesz = rand.intRangeAtMost(u64, 0, img_len);
        phdrs[1].p_type = std.elf.PT_DYNAMIC;
        phdrs[1].p_vaddr = 512;
        writeDynamic(img, 512, 4, 0, rela_off, 2, rand.intRangeAtMost(usize, 0, 512));

        fixupImage(img, mem_source) catch {};
        const settled = try alloc.dupe(u8, img);
        defer alloc.free(settled);
        fixupImage(img, mem_source) catch {};
        try testing.expectEqualSlices(u8, settled, img);
    }
}

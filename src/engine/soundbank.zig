//! MSS v8+ SoundBank loader (the `BANK`-tagged on-disk format documented in the
//! Miles 9.x SDK hlbank.cpp). Parses the metadata block — header, the Events /
//! Environments / Presets / Sounds asset tables, and the string table — so the
//! soundbank query/enumeration API works for real. Asset *data* (preset values,
//! event-step bytecode) is left opaque: executing it needs the Miles event VM,
//! which is a separate subsystem.
//!
//! Banks targeting the 32-bit mss32.dll store 4-byte pointer slots on disk; the
//! pointer fields hold file-relative offsets that the loader resolves. All
//! offset reads are bounds-checked against the loaded metadata so a malformed
//! or truncated bank is rejected rather than over-reading.

const std = @import("std");

pub const BANK_TAG: u32 = (@as(u32, 'B') << 24) | (@as(u32, 'A') << 16) | (@as(u32, 'N') << 8) | @as(u32, 'K');
pub const BANK_VERSION: i32 = 8;

// Global registry of currently-loaded banks (the SDK's "container"). Banks add
// themselves in loadFromMemory and remove themselves in Bank.deinit, so the
// container can resolve an event or sound by name across every loaded bank —
// what MilesGetEventLength / event enqueue look it up through.
var g_registry: std.ArrayListUnmanaged(*Bank) = .empty;
var g_registry_lock: std.atomic.Value(bool) = .init(false);
// The registry backing uses a process-stable allocator, independent of any
// bank's own allocator (which in tests may be the leak-checked test allocator).
const registry_alloc = std.heap.page_allocator;

fn regLock() void {
    while (g_registry_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {}
}
fn regUnlock() void {
    g_registry_lock.store(false, .release);
}

/// Track a loaded bank in the global registry. Fails only on OOM; the caller
/// must treat that as a failed load, since an untracked bank would be invisible
/// to every containerFindEvent/containerSoundDurationMs lookup while still
/// holding its memory.
fn registryAdd(bank: *Bank) !void {
    regLock();
    defer regUnlock();
    try g_registry.append(registry_alloc, bank);
}
fn registryRemove(bank: *Bank) void {
    regLock();
    defer regUnlock();
    for (g_registry.items, 0..) |b, i| {
        if (b == bank) {
            _ = g_registry.swapRemove(i);
            return;
        }
    }
}

pub fn loadedCount() u32 {
    regLock();
    defer regUnlock();
    return @intCast(g_registry.items.len);
}

/// Resolve a named event's step bytecode across all loaded banks (Container_GetEvent).
pub fn containerFindEvent(event_name: []const u8) ?[*]const u8 {
    regLock();
    defer regUnlock();
    for (g_registry.items) |b| {
        if (b.findEventContents(event_name)) |ev| return ev;
    }
    return null;
}

// Sound references in events are formatted "<bank>/<sound>"; the asset table is
// keyed by the bare sound name, so drop any leading "<bank>/" path (Container_GetSound).
fn bareSoundName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| return name[slash + 1 ..];
    return name;
}

/// Resolve a named sound's playback duration (ms) across all loaded banks
/// (Container_GetSound -> MILESBANKSOUNDINFO.DurationMs).
pub fn containerSoundDurationMs(sound_name: []const u8) ?u32 {
    const bare = bareSoundName(sound_name);
    regLock();
    defer regUnlock();
    for (g_registry.items) |b| {
        if (b.soundDurationMs(bare)) |ms| return ms;
    }
    return null;
}

// Field byte offsets in the on-disk SoundBank header (32-bit pointer layout).
const off_tag = 0;
const off_version = 4;
const off_meta_size = 8;
const off_events = 20; // pointer slot holding the Events table offset
const off_envs = 24;
const off_presets = 28;
const off_sounds = 32;
const off_event_count = 40;
const off_env_count = 44;
const off_preset_count = 48;
const off_sound_count = 52;
const off_name = 56; // char SoundBankName[4]
const header_size = 60;
const asset_entry_size = 8; // { U32 NameOffset; U32 DataOffset; }

/// Case-insensitive asset-name index for one table: lowercased name -> entry
/// index. Keys are owned lowercase copies (freed with the Bank); values are
/// table entry indices so all offset validation stays with the callers.
/// `complete == false` (the build ran out of memory) makes lookups fall back
/// to the original linear scan.
const NameIndex = struct {
    map: std.StringHashMapUnmanaged(u32) = .empty,
    complete: bool = false,

    fn deinit(self: *NameIndex, allocator: std.mem.Allocator) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        self.map.deinit(allocator);
        self.* = .{};
    }
};

pub const Bank = struct {
    meta: []u8,
    // SoundBankName[4] copied out NUL-terminated at load: the on-disk field is
    // fixed-width and may use all 4 bytes, so handing out a pointer into meta
    // would let C-string consumers run past the block (over-read under
    // ReleaseFast). Immutable after load, so sharing it is race-free.
    name_buf: [5]u8 = [_]u8{0} ** 5,
    filename: [:0]u8,
    allocator: std.mem.Allocator,
    // Name indexes for the two queried tables (events, sounds). Built once at
    // load, before the bank joins the global registry, so concurrent lookups
    // never race the build; immutable afterwards.
    event_index: NameIndex = .{},
    sound_index: NameIndex = .{},

    fn rdU32(self: *const Bank, off: usize) u32 {
        if (off + 4 > self.meta.len) return 0;
        return std.mem.readInt(u32, self.meta[off..][0..4], .little);
    }
    fn rdI32(self: *const Bank, off: usize) i32 {
        return @bitCast(self.rdU32(off));
    }

    pub fn metaSize(self: *const Bank) i32 {
        return self.rdI32(off_meta_size);
    }
    pub fn name(self: *const Bank) [*:0]const u8 {
        return @ptrCast(&self.name_buf);
    }

    fn countFor(self: *const Bank, which: AssetKind) u32 {
        return switch (which) {
            .events => self.rdU32(off_event_count),
            .environments => self.rdU32(off_env_count),
            .presets => self.rdU32(off_preset_count),
            .sounds => self.rdU32(off_sound_count),
        };
    }
    fn tableOff(self: *const Bank, which: AssetKind) u32 {
        return switch (which) {
            .events => self.rdU32(off_events),
            .environments => self.rdU32(off_envs),
            .presets => self.rdU32(off_presets),
            .sounds => self.rdU32(off_sounds),
        };
    }

    /// Name of asset `idx` in the given table, or null if out of range / the
    /// name offset escapes the metadata block.
    pub fn assetName(self: *const Bank, which: AssetKind, idx: u32) ?[*:0]const u8 {
        if (idx >= self.countFor(which)) return null;
        const entry = @as(usize, self.tableOff(which)) + @as(usize, idx) * asset_entry_size;
        const name_off = self.rdU32(entry);
        if (name_off == 0 or name_off >= self.meta.len) return null;
        // Require a NUL terminator within bounds.
        if (std.mem.indexOfScalar(u8, self.meta[name_off..], 0) == null) return null;
        return @ptrCast(self.meta.ptr + name_off);
    }

    pub fn assetCount(self: *const Bank, which: AssetKind) u32 {
        return self.countFor(which);
    }

    /// Resolve `target` to an entry index in `which`: the load-time hash index
    /// when available, else (or when the key cannot be lowered) the original
    /// linear scan. First match in table order wins on both paths, matching
    /// the SDK FindAsset.
    fn findEntry(self: *const Bank, which: AssetKind, target: []const u8) ?u32 {
        const ix: ?*const NameIndex = switch (which) {
            .events => &self.event_index,
            .sounds => &self.sound_index,
            else => null,
        };
        if (ix) |index| {
            if (index.complete) {
                switch (self.indexGet(index, target)) {
                    .entry => |e| return e,
                    .absent => return null,
                    .unavailable => {}, // could not lower the key; scan instead
                }
            }
        }
        const count = self.countFor(which);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            if (self.entryNameAt(which, i)) |nm| {
                if (std.ascii.eqlIgnoreCase(nm, target)) return i;
            }
        }
        return null;
    }

    const IndexHit = union(enum) { entry: u32, absent, unavailable };

    /// Hash-index lookup of a case-lowered `target`.
    fn indexGet(self: *const Bank, ix: *const NameIndex, target: []const u8) IndexHit {
        var buf: [128]u8 = undefined;
        if (target.len > buf.len) {
            const heap = self.allocator.alloc(u8, target.len) catch return .unavailable;
            defer self.allocator.free(heap);
            for (target, 0..) |c, i| heap[i] = std.ascii.toLower(c);
            return if (ix.map.get(heap)) |e| .{ .entry = e } else .absent;
        }
        const k = buf[0..target.len];
        for (target, 0..) |c, i| k[i] = std.ascii.toLower(c);
        return if (ix.map.get(k)) |e| .{ .entry = e } else .absent;
    }

    /// Name of table entry `i`, or null when the offset escapes the metadata.
    fn entryNameAt(self: *const Bank, which: AssetKind, i: u32) ?[]const u8 {
        const entry = @as(usize, self.tableOff(which)) + @as(usize, i) * asset_entry_size;
        const name_off = self.rdU32(entry);
        if (name_off == 0 or name_off >= self.meta.len) return null;
        return std.mem.sliceTo(self.meta[name_off..], 0);
    }

    /// Build one table's name index. First occurrence wins, matching the scan
    /// in findEntry. Any allocation failure discards the partial index so
    /// lookups take the linear-scan path.
    fn buildNameIndex(self: *Bank, which: AssetKind) !NameIndex {
        var idx: NameIndex = .{};
        errdefer idx.deinit(self.allocator);
        const count = self.countFor(which);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const nm = self.entryNameAt(which, i) orelse continue;
            const key = try self.allocator.dupe(u8, nm);
            for (key) |*c| c.* = std.ascii.toLower(c.*);
            if (idx.map.contains(key)) {
                self.allocator.free(key);
            } else {
                idx.map.put(self.allocator, key, i) catch |err| {
                    self.allocator.free(key);
                    return err;
                };
            }
        }
        idx.complete = true;
        return idx;
    }

    /// Find an asset by (case-insensitive) name and return a pointer to its data
    /// at DataOffset, or null if not found / the data offset escapes the metadata.
    /// Mirrors the SDK FindAsset + AIL_ptr_add(bank, pAsset->DataOffset).
    pub fn assetData(self: *const Bank, which: AssetKind, target: []const u8) ?[*]const u8 {
        const i = self.findEntry(which, target) orelse return null;
        const entry = @as(usize, self.tableOff(which)) + @as(usize, i) * asset_entry_size;
        const data_off = self.rdU32(entry + 4);
        if (data_off == 0 or data_off >= self.meta.len) return null;
        return @ptrCast(self.meta.ptr + data_off);
    }

    /// The event-step bytecode for a named event (MilesFindEvent / AIL_find_event).
    pub fn findEventContents(self: *const Bank, event_name: []const u8) ?[*]const u8 {
        return self.assetData(.events, event_name);
    }

    /// Raw DataOffset of a named sound's table entry, or null if not found / the
    /// name offset escapes the metadata. Callers validate the offset against
    /// whatever they read from the record.
    fn findSoundDataOffset(self: *const Bank, sound_name: []const u8) ?u32 {
        const i = self.findEntry(.sounds, sound_name) orelse return null;
        const entry = @as(usize, self.tableOff(.sounds)) + @as(usize, i) * asset_entry_size;
        return self.rdU32(entry + 4);
    }

    /// Resolve a sound asset's source filename into `out` as the SDK formats it:
    /// "*" + bank filename + the sound's own filename. Returns the sound's
    /// DataLen (MILESBANKSOUNDINFO.DataLen) on success, or -1 if not found.
    /// `out` must be large enough for the result (the C API takes no size, matching
    /// the SDK). The Sound layout (NameOffset@0, FileNameOffset@4, Info@12 with
    /// DataLen at Info+12) is from hlbank.cpp.
    pub fn soundAssetFilename(self: *const Bank, sound_name: []const u8, out: [*]u8) i32 {
        const data_off = self.findSoundDataOffset(sound_name) orelse 0;
        // Offset math in usize (64-bit): a lying u32 DataOffset from the bank
        // file must saturate/widen here, not overflow a u32 addition.
        if (data_off == 0 or @as(usize, data_off) + 8 > self.meta.len) {
            out[0] = 0;
            return -1;
        }
        const fn_abs = @as(usize, data_off) + self.rdU32(data_off + 4); // pSound + FileNameOffset
        if (fn_abs >= self.meta.len) {
            out[0] = 0;
            return -1;
        }
        const sfn = std.mem.sliceTo(self.meta[fn_abs..], 0);
        var w: usize = 0;
        out[w] = '*';
        w += 1;
        @memcpy(out[w .. w + self.filename.len], self.filename);
        w += self.filename.len;
        @memcpy(out[w .. w + sfn.len], sfn);
        w += sfn.len;
        out[w] = 0;
        // MILESBANKSOUNDINFO.DataLen is at Sound+12 (Info) +12.
        if (@as(usize, data_off) + 28 > self.meta.len) return 0;
        return self.rdI32(data_off + 24);
    }

    // MILESBANKSOUNDINFO (mss.h) — the compiled-bank sound record, copied verbatim
    // into AIL_sound_asset_info's out_info. The SDK warns this layout is bank-
    // format-critical, so define it and lock its size at comptime.
    pub const MILESBANKSOUNDINFO = extern struct {
        ChannelCount: i32,
        ChannelMask: u32,
        Rate: i32,
        DataLen: i32,
        SoundLimit: i32,
        IsExternal: i32,
        DurationMs: u32,
        StreamBufferSize: i32,
        IsAdpcm: i32,
        AdpcmBlockSize: i32,
        MixVolumeDAC: f32,
    };
    const sound_info_size = @sizeOf(MILESBANKSOUNDINFO);
    comptime {
        if (sound_info_size != 44) @compileError("MILESBANKSOUNDINFO must be 44 bytes (compiled-bank format)");
        // The 44-byte total survives any reorder of the eleven 4-byte fields, but
        // the compiled-bank record is memcpy'd in verbatim, so each field must sit
        // at its mss.h offset. Lock the field order, not just the size.
        const fields = @typeInfo(MILESBANKSOUNDINFO).@"struct".fields;
        const order = [_][]const u8{
            "ChannelCount", "ChannelMask", "Rate",             "DataLen", "SoundLimit",
            "IsExternal",   "DurationMs",  "StreamBufferSize", "IsAdpcm", "AdpcmBlockSize",
            "MixVolumeDAC",
        };
        if (fields.len != order.len) @compileError("MILESBANKSOUNDINFO field count drifted");
        for (order, 0..) |fname, i| {
            if (!std.mem.eql(u8, fields[i].name, fname)) @compileError("MILESBANKSOUNDINFO field order drifted at " ++ fname);
        }
    }

    /// AIL_sound_asset_info: optionally copy the sound's MILESBANKSOUNDINFO into
    /// `out_info`, optionally format its path into `out_filename`, and return the
    /// filename-buffer requirement (`2 + bankNameLen + soundNameLen`), or 0 if not
    /// found. Mirrors hlbank.cpp.
    pub fn soundAssetInfo(self: *const Bank, sound_name: []const u8, out_filename: ?[*]u8, out_info: ?[*]u8) i32 {
        const data_off = self.findSoundDataOffset(sound_name) orelse 0;
        // Offset math in usize (64-bit): see soundAssetFilename.
        if (data_off == 0 or @as(usize, data_off) + 8 > self.meta.len) {
            if (out_filename) |o| o[0] = 0;
            return 0;
        }
        if (out_info) |oi| {
            if (@as(usize, data_off) + 12 + sound_info_size <= self.meta.len) {
                @memcpy(oi[0..sound_info_size], self.meta[data_off + 12 ..][0..sound_info_size]);
            }
        }
        const fn_abs = @as(usize, data_off) + self.rdU32(data_off + 4);
        if (fn_abs >= self.meta.len) {
            if (out_filename) |o| o[0] = 0;
            return 0;
        }
        const sfn = std.mem.sliceTo(self.meta[fn_abs..], 0);
        const req: i32 = @intCast(2 + self.filename.len + sfn.len);
        if (out_filename) |o| {
            var w: usize = 0;
            o[w] = '*';
            w += 1;
            @memcpy(o[w .. w + self.filename.len], self.filename);
            w += self.filename.len;
            @memcpy(o[w .. w + sfn.len], sfn);
            w += sfn.len;
            o[w] = 0;
        }
        return req;
    }

    /// MILESBANKSOUNDINFO.DurationMs (Sound+12 Info, +24) for a named sound.
    pub fn soundDurationMs(self: *const Bank, sound_name: []const u8) ?u32 {
        const data_off = self.findSoundDataOffset(sound_name) orelse return null;
        if (@as(usize, data_off) + 40 > self.meta.len) return 0;
        return self.rdU32(data_off + 36);
    }

    pub fn deinit(self: *Bank) void {
        registryRemove(self);
        self.event_index.deinit(self.allocator);
        self.sound_index.deinit(self.allocator);
        self.allocator.free(self.meta);
        self.allocator.free(self.filename);
        self.allocator.destroy(self);
    }
};

pub const AssetKind = enum { events, environments, presets, sounds };

/// Parse a BANK image already in memory. Validates tag/version and that the
/// asset tables fit. Returns an owned Bank or an error.
pub fn loadFromMemory(allocator: std.mem.Allocator, filename: []const u8, image: []const u8) !*Bank {
    if (image.len < header_size) return error.TooShort;
    if (std.mem.readInt(u32, image[off_tag..][0..4], .little) != BANK_TAG) return error.NotABank;
    if (std.mem.readInt(i32, image[off_version..][0..4], .little) != BANK_VERSION) return error.BadVersion;
    const meta_size = std.mem.readInt(i32, image[off_meta_size..][0..4], .little);
    if (meta_size < header_size or @as(usize, @intCast(meta_size)) > image.len) return error.BadMetaSize;
    const msz: usize = @intCast(meta_size);

    // Copy the metadata with one trailing NUL sentinel: fixed-width on-disk
    // string fields (SoundBankName[4]) and event-step text are consumed as C
    // strings via bare pointers, so a malformed bank whose bytes run non-zero
    // right up to the block end must not send strlen/step-decode scans past
    // the allocation (over-read under ReleaseFast).
    const meta = try allocator.alloc(u8, msz + 1);
    errdefer allocator.free(meta);
    @memcpy(meta[0..msz], image[0..msz]);
    meta[msz] = 0;
    const fname = try allocator.dupeZ(u8, filename);
    errdefer allocator.free(fname);

    const self = try allocator.create(Bank);
    errdefer allocator.destroy(self);
    self.* = .{ .meta = meta, .filename = fname, .allocator = allocator };

    // Copy SoundBankName[4] out terminated (meta_size >= header_size > off_name,
    // enforced above, so the read is in bounds).
    const nlen = @min(msz - off_name, 4);
    @memcpy(self.name_buf[0..nlen], image[off_name..][0..nlen]);

    // Validate each asset table fits inside the metadata (errdefers above free
    // meta/fname/self on failure — do not deinit here or they double-free).
    inline for (.{ AssetKind.events, .environments, .presets, .sounds }) |k| {
        const cnt = self.countFor(k);
        const base = self.tableOff(k);
        if (cnt != 0) {
            const end = @as(u64, base) + @as(u64, cnt) * asset_entry_size;
            if (base == 0 or end > msz) return error.BadAssetTable;
        }
    }
    // Build the events/sounds name indexes before the bank joins the registry:
    // until registryAdd publishes it, no other thread can reach the Bank, so
    // the build needs no lock and lookups never race it. A failed build leaves
    // that table on the linear-scan path.
    self.event_index = self.buildNameIndex(.events) catch .{};
    self.sound_index = self.buildNameIndex(.sounds) catch .{};
    // A bank that cannot be registered must fail the whole load: the registry is
    // the only lookup path (MilesFindEvent / Container_GetSound), so returning a
    // success here would hand out a handle whose assets can never be found.
    try registryAdd(self);
    return self;
}

test "asset lookup: index parity with scan semantics" {
    const testing = std.testing;
    var img: [2048]u8 = undefined;
    @memset(&img, 0);

    const w32 = struct {
        fn f(buf: []u8, off: usize, v: u32) void {
            std.mem.writeInt(u32, buf[off..][0..4], v, .little);
        }
    }.f;
    const putStr = struct {
        fn f(buf: []u8, at: usize, s: []const u8) usize {
            @memcpy(buf[at .. at + s.len], s);
            buf[at + s.len] = 0;
            return at + s.len + 1;
        }
    }.f;

    // Header: two event entries + one sound entry, tables right after it.
    const ev_off: u32 = header_size;
    const snd_off: u32 = ev_off + 3 * asset_entry_size;
    w32(&img, off_events, ev_off);
    w32(&img, off_sounds, snd_off);
    w32(&img, off_event_count, 3);
    w32(&img, off_sound_count, 1);

    // String/data pool after both tables.
    var pool: usize = snd_off + asset_entry_size;
    const d0: u32 = @intCast(pool);
    pool = putStr(&img, pool, "E0DATA");
    const d1: u32 = @intCast(pool);
    pool = putStr(&img, pool, "E1DATA");
    const n0: u32 = @intCast(pool);
    pool = putStr(&img, pool, "Boom");
    const n1: u32 = @intCast(pool); // duplicate name, different case
    pool = putStr(&img, pool, "BOOM");
    const n2: u32 = @intCast(pool); // >128 bytes to exercise the heap key path
    var long_buf: [200]u8 = undefined;
    @memset(&long_buf, 'x');
    long_buf[199] = 'Z';
    pool = putStr(&img, pool, &long_buf);
    const s0: u32 = @intCast(pool);
    pool = putStr(&img, pool, "kick");

    // events: e0 "Boom" (first match must win over e1), e1 "BOOM", e2 long name.
    w32(&img, ev_off, n0);
    w32(&img, ev_off + 4, d0);
    w32(&img, ev_off + 8, n1);
    w32(&img, ev_off + 12, d1);
    w32(&img, ev_off + 16, n2);
    w32(&img, ev_off + 20, d1);
    // sounds: one entry.
    w32(&img, snd_off, s0);
    w32(&img, snd_off + 4, d0);

    w32(&img, off_meta_size, @intCast(pool));
    const bank = try loadFromMemory(testing.allocator, "idx.mbnk", img[0..pool]);
    defer bank.deinit();

    try testing.expect(bank.event_index.complete);
    try testing.expect(bank.sound_index.complete);

    const p_first = bank.findEventContents("boom") orelse return error.NoEvent;
    try testing.expectEqual(@as(usize, d0), @intFromPtr(p_first) - @intFromPtr(bank.meta.ptr));
    // Case-insensitive hit resolves to the SAME (first) entry.
    const p_upper = bank.findEventContents("BOOM") orelse return error.NoEvent;
    try testing.expectEqual(@intFromPtr(p_first), @intFromPtr(p_upper));
    // Long name (> stack key buffer) still hits through the heap path.
    var long_query: [200]u8 = undefined;
    @memset(&long_query, 'x');
    long_query[199] = 'z'; // case-insensitive against the stored 'Z'
    try testing.expect(bank.findEventContents(&long_query) != null);
    // Miss is a definitive miss on the indexed path too.
    try testing.expect(bank.findEventContents("nope") == null);
    // Sounds table lookups go through their own index.
    try testing.expectEqual(d0, bank.findSoundDataOffset("KICK") orelse return error.NoSound);
}

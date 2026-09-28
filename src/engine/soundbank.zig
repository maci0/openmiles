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
const root = @import("../root.zig");
const fs_compat = root.fs_compat;
const wide = root.wide;

pub const BANK_TAG: u32 = (@as(u32, 'B') << 24) | (@as(u32, 'A') << 16) | (@as(u32, 'N') << 8) | @as(u32, 'K');
pub const BANK_VERSION: i32 = 8;

// Global registry of currently-loaded banks (the SDK's "container"). Banks add
// themselves in loadFromMemory and remove themselves in Bank.deinit, so the
// container can resolve an event or sound by name across every loaded bank —
// what MilesGetEventLength / event enqueue look it up through. The list is kept
// in load order and the first bank holding a name answers for it, so a game that
// overrides a bank by loading a second one after it is unaffected by the order
// in which unrelated banks are later released.
var g_registry: std.ArrayListUnmanaged(*Bank) = .empty;
var g_registry_mutex: std.Io.Mutex = .init;
// The registry backing uses a process-stable allocator, independent of any
// bank's own allocator (which in tests may be the leak-checked test allocator).
const registry_alloc = std.heap.page_allocator;

fn regLock() void {
    g_registry_mutex.lockUncancelable(root.io);
}
fn regUnlock() void {
    g_registry_mutex.unlock(root.io);
}

/// Reserve room for one more registry entry, before a load owns any memory, so
/// publishing the bank it builds cannot fail. A bank that could not be
/// registered would be invisible to every containerFindEvent /
/// containerSoundDurationMs lookup while still holding its memory, so the load
/// fails on the reservation instead of on the append.
fn registryReserve() !void {
    regLock();
    defer regUnlock();
    try g_registry.ensureUnusedCapacity(registry_alloc, 1);
}

/// Track a loaded bank in the global registry, or hand back the bank already
/// loaded from the same file (see `registryAcquireBySource`), with a reference
/// taken for this open. Only call after registryReserve succeeded.
fn registryAdd(bank: *Bank) *Bank {
    regLock();
    defer regUnlock();
    if (registryFindLocked(bank.source_path)) |existing| {
        existing.refs += 1;
        return existing;
    }
    g_registry.appendAssumeCapacity(bank);
    return bank;
}
/// The live bank whose resolved source path is `source_path`, or null. The
/// caller holds the registry lock.
fn registryFindLocked(source_path: []const u8) ?*Bank {
    for (g_registry.items) |b| {
        if (std.mem.eql(u8, b.source_path, source_path)) return b;
    }
    return null;
}

/// One bank per file: the live bank loaded from the same file `source_path`
/// names, with a reference taken for this open, or null when the file is not
/// loaded yet. A game that opens the same .mbnk twice (a retry, a scene
/// reloaded, a "did it register?" check) must not get two registry entries and
/// two copies of the metadata, or the second copy answers a name lookup the
/// first one already answers and LoadedBankCount overstates what is loaded.
///
/// The lookup and the reference are taken under one lock: a load that only
/// looked the bank up and released the lock would race another load's
/// registration and hand out a bank that is about to be freed.
fn registryAcquireBySource(source_path: []const u8) ?*Bank {
    regLock();
    defer regUnlock();
    const existing = registryFindLocked(source_path) orelse return null;
    existing.refs += 1;
    return existing;
}

/// Drop one reference and report whether this was the last one. The
/// decrement, the last-reference test and the unregister all happen under the
/// registry lock, so they are one atomic step against registryAcquireBySource:
/// a concurrent open either takes its reference before the drop and keeps the
/// bank alive, or misses the bank entirely and loads its own. Splitting them
/// let an open find the bank, take a reference, and then have the bank torn
/// down under it, and let two concurrent closes lose a decrement.
fn registryRelease(bank: *Bank) bool {
    g_registry_mutex.lockUncancelable(root.io);
    defer g_registry_mutex.unlock(root.io);
    std.debug.assert(bank.refs > 0);
    bank.refs -= 1;
    if (bank.refs > 0) return false;
    for (g_registry.items, 0..) |b, i| {
        if (b == bank) {
            // orderedRemove, not swapRemove: registry order is the resolution
            // order, so a bank that duplicates another's event/sound name wins
            // by being loaded first. swapRemove would move the last-loaded bank
            // into the freed slot, and unloading a bank would silently change
            // which bank answers a name it never defined. The cost is an O(n)
            // shift over the handful of banks a game loads.
            _ = g_registry.orderedRemove(i);
            break;
        }
    }
    return true;
}

pub fn loadedCount() u32 {
    g_registry_mutex.lockUncancelable(root.io);
    defer g_registry_mutex.unlock(root.io);
    return @intCast(g_registry.items.len);
}

/// Resolve a named event's step bytecode across all loaded banks (Container_GetEvent).
///
/// The bytes live in the bank's metadata, which the registry lock does not keep
/// alive past this return: a concurrent MilesReleaseSoundBank frees them under a
/// caller still walking the steps. A caller that holds its own reference to the
/// bank (every open does) may use this; one that only has the name must use
/// containerFindEventOwned, which takes the reference it needs.
pub fn containerFindEvent(event_name: []const u8) ?[*]const u8 {
    g_registry_mutex.lockUncancelable(root.io);
    defer g_registry_mutex.unlock(root.io);
    for (g_registry.items) |b| {
        if (b.findEventContents(event_name)) |ev| return ev;
    }
    return null;
}

/// A found event's bytecode together with a reference on the bank that owns it.
/// The bytes are only valid while that reference is held; drop it with
/// `bank.deinit()` once the walk is done.
pub const FoundEvent = struct { bank: *Bank, data: [*]const u8 };

/// containerFindEvent for a caller that has only the name, taking the keep-alive
/// under the same lock that resolves it. Taking the reference after the search
/// would let a release in between unregister and free the bank, so the two are
/// one step here.
pub fn containerFindEventOwned(event_name: []const u8) ?FoundEvent {
    g_registry_mutex.lockUncancelable(root.io);
    defer g_registry_mutex.unlock(root.io);
    for (g_registry.items) |b| {
        if (b.findEventContents(event_name)) |ev| {
            b.refs += 1;
            return .{ .bank = b, .data = ev };
        }
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
    g_registry_mutex.lockUncancelable(root.io);
    defer g_registry_mutex.unlock(root.io);
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

/// Longest "*<bank file name><sound file name>" asset path the loader reports.
/// Both names come out of the bank file and neither C entry point carries a
/// buffer size, so the write is bounded here rather than by a buffer the
/// library never learns the size of. MAX_PATH, the bound on the file open that
/// consumes such a path.
pub const max_asset_path_bytes: usize = 260;

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
    /// Resolved form of `filename`, and the key the global registry dedups on.
    /// Owned like `filename` — sentinel-typed, which is the slice type its
    /// allocator frees it as — and freed with the bank.
    source_path: [:0]u8,
    /// Number of successful opens still holding this bank. Each open that finds
    /// the bank already loaded adds one; the last release unregisters and frees
    /// it. The open and the release are per open, so a second open of the same
    /// file is answered by a second release rather than by a second copy.
    refs: u32 = 1,
    allocator: std.mem.Allocator,
    // Name indexes for the two queried tables (events, sounds). Built once at
    // load, before the bank joins the global registry, so concurrent lookups
    // never race the build; immutable afterwards.
    event_index: NameIndex = .{},
    sound_index: NameIndex = .{},

    /// True when the `n` bytes at `off` lie inside the metadata block.
    ///
    /// Written as a subtraction, never as `off + n > len`: a bank-supplied u32
    /// offset near the top of the 32-bit address space wraps the sum on the
    /// 32-bit x86 target the DLL ships for, turning the bounds check into a
    /// false pass and the slice that follows into an out-of-bounds read. The
    /// 64-bit host the tests build on never wraps, so it cannot see the bug.
    fn inBounds(self: *const Bank, off: usize, n: usize) bool {
        return off <= self.meta.len and self.meta.len - off >= n;
    }

    fn rdU32(self: *const Bank, off: usize) u32 {
        if (!self.inBounds(off, 4)) return 0;
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

    /// Byte offset of table entry `idx`, or null when the file's table offset
    /// and index put it outside the metadata block. Saturating, because both
    /// operands are u32 and the product overflows a 32-bit usize.
    fn entryOffset(self: *const Bank, which: AssetKind, idx: u32) ?usize {
        const base: usize = @intCast(self.tableOff(which));
        const entry = base +| (@as(usize, idx) *| asset_entry_size);
        if (!self.inBounds(entry, asset_entry_size)) return null;
        return entry;
    }

    /// Name of asset `idx` in the given table, or null if out of range / the
    /// name offset escapes the metadata block.
    pub fn assetName(self: *const Bank, which: AssetKind, idx: u32) ?[*:0]const u8 {
        if (idx >= self.countFor(which)) return null;
        const entry = self.entryOffset(which, idx) orelse return null;
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
        const entry = self.entryOffset(which, i) orelse return null;
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
        // Size the table for the whole table up front: grown one key at a time
        // it rehashes log(count) times, each pass reallocating and reinserting
        // every key inserted so far, so a bank with thousands of sounds pays a
        // multiple of the insert cost at load. A reserve that fails is not an
        // error; the loop below still inserts and the map grows as it must.
        // Bounded by what the metadata block can actually hold entries for, so
        // a header count far past the end of the file cannot ask for a table
        // sized by a number no entry will ever occupy.
        const capacity_hint: u32 = @intCast(@min(@as(usize, count), self.meta.len / asset_entry_size));
        idx.map.ensureTotalCapacity(self.allocator, capacity_hint) catch {};
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const nm = self.entryNameAt(which, i) orelse continue;
            const key = try self.allocator.dupe(u8, nm);
            for (key) |*c| c.* = std.ascii.toLower(c.*);
            // One hash lookup, not the two contains+put took. A name already in
            // the map keeps its entry: first occurrence wins, as the scan does.
            const gop = idx.map.getOrPut(self.allocator, key) catch |err| {
                self.allocator.free(key);
                return err;
            };
            if (gop.found_existing) {
                self.allocator.free(key);
            } else {
                gop.value_ptr.* = i;
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
        const entry = self.entryOffset(which, i) orelse return null;
        const data_off = self.rdU32(entry + 4);
        if (data_off == 0 or data_off >= self.meta.len) return null;
        return @ptrCast(self.meta.ptr + data_off);
    }

    /// The event-step bytecode for a named event (MilesFindEvent).
    pub fn findEventContents(self: *const Bank, event_name: []const u8) ?[*]const u8 {
        return self.assetData(.events, event_name);
    }

    /// Raw DataOffset of a named sound's table entry, or null if not found / the
    /// name offset escapes the metadata. Callers validate the offset against
    /// whatever they read from the record.
    fn findSoundDataOffset(self: *const Bank, sound_name: []const u8) ?u32 {
        const i = self.findEntry(.sounds, sound_name) orelse return null;
        const entry = self.entryOffset(.sounds, i) orelse return null;
        return self.rdU32(entry + 4);
    }

    /// Resolve a sound's table offset and its NUL-terminated file name, or null
    /// when the sound is not found or its FileNameOffset escapes the metadata.
    /// The Sound layout (NameOffset@0, FileNameOffset@4, Info@12) is from
    /// hlbank.cpp.
    const SoundFileName = struct { data_off: u32, sfn: []const u8 };

    fn findSoundFileName(self: *const Bank, sound_name: []const u8) ?SoundFileName {
        const data_off = self.findSoundDataOffset(sound_name) orelse return null;
        if (data_off == 0 or !self.inBounds(data_off, 8)) return null;
        // Saturating: a bank file can name a FileNameOffset that pushes the sum
        // past the address space, which must read as "out of range" rather than
        // wrap around to a small in-bounds offset.
        const fn_abs = @as(usize, data_off) +| self.rdU32(data_off + 4); // pSound + FileNameOffset
        if (fn_abs >= self.meta.len) return null;
        return .{ .data_off = data_off, .sfn = std.mem.sliceTo(self.meta[fn_abs..], 0) };
    }

    /// Resolve a sound asset's source filename into `out` as the SDK formats it:
    /// "*" + bank filename + the sound's own filename. Returns the sound's
    /// DataLen (MILESBANKSOUNDINFO.DataLen) on success, -1 if not found, or 0 if truncated.
    /// `out` must be large enough for the result (the C API takes no size, matching
    /// the SDK).
    pub fn soundAssetFilename(self: *const Bank, sound_name: []const u8, out: [*]u8) i32 {
        const found = self.findSoundFileName(sound_name) orelse {
            out[0] = 0;
            return -1;
        };
        // A path over the cap is not one the loader can have opened, so it
        // reports as unresolved rather than writing a truncated string the
        // caller would then open.
        if (self.soundAssetPathBytes(found.sfn) == 0) {
            out[0] = 0;
            return -1;
        }
        _ = self.writeSoundAssetPath(found.sfn, out);
        // MILESBANKSOUNDINFO.DataLen is at Sound+12 (Info) +12.
        if (!self.inBounds(found.data_off, 28)) return 0;
        return self.rdI32(found.data_off + 24);
    }

    // MILESBANKSOUNDINFO (the SDK's mss.h) — the compiled-bank sound record,
    // copied verbatim into AIL_sound_asset_info's out_info. The SDK warns this
    // layout is bank-format-critical, so define it and lock its size at comptime.
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

    /// Write `*<bank file name><sound file name>` (MSS's DOS-style relative
    /// asset path) into `out`, NUL-terminated. Returns the bytes the caller must
    /// provide: 1 for the `*`, both names, and 1 for the terminator. An asset
    /// path over `max_asset_path_bytes` is not written at all (see
    /// `soundAssetPathBytes`).
    ///
    /// No size parameter exists on the SDK call, so `out` must be at least this
    /// many bytes; AIL_sound_asset_info returns the requirement for exactly this
    /// reason.
    fn writeSoundAssetPath(self: *const Bank, sfn: []const u8, out: [*]u8) i32 {
        const need = self.soundAssetPathBytes(sfn);
        if (need == 0) {
            out[0] = 0;
            return 0;
        }
        var w: usize = 0;
        out[w] = '*';
        w += 1;
        @memcpy(out[w .. w + self.filename.len], self.filename);
        w += self.filename.len;
        @memcpy(out[w .. w + sfn.len], sfn);
        w += sfn.len;
        out[w] = 0;
        return need;
    }

    /// The buffer writeSoundAssetPath needs for `sfn`, or 0 when the pair is
    /// over `max_asset_path_bytes`.
    ///
    /// Both lengths come from the bank file, and neither C entry point takes a
    /// buffer size, so a bank naming a sound with a megabyte of file name would
    /// otherwise write megabytes into a buffer the game sized for the path the
    /// real Miles loader would have produced. The cap is the same MAX_PATH the
    /// loader's own file opens are bound by, so a rejected path is one no
    /// consumer of it could have opened anyway.
    fn soundAssetPathBytes(self: *const Bank, sfn: []const u8) i32 {
        const need: usize = 1 + self.filename.len + sfn.len + 1;
        if (need > max_asset_path_bytes) return 0;
        return @intCast(need);
    }

    /// AIL_sound_asset_info: optionally copy the sound's MILESBANKSOUNDINFO into
    /// `out_info`, optionally format its path into `out_filename`, and return the
    /// filename-buffer requirement (`2 + bankNameLen + soundNameLen`), or 0 if not
    /// found. Mirrors hlbank.cpp.
    pub fn soundAssetInfo(self: *const Bank, sound_name: []const u8, out_filename: ?[*]u8, out_info: ?[*]u8) i32 {
        const found = self.findSoundFileName(sound_name) orelse {
            if (out_filename) |o| o[0] = 0;
            return 0;
        };
        // Over the cap: the sound resolves, but no path this library is willing
        // to write into an unsized buffer describes it, so the call reports
        // unresolved and writes nothing past the terminator.
        if (self.soundAssetPathBytes(found.sfn) == 0) {
            if (out_filename) |o| o[0] = 0;
            return 0;
        }
        if (out_info) |oi| {
            if (self.inBounds(found.data_off, 12 + sound_info_size)) {
                @memcpy(oi[0..sound_info_size], self.meta[found.data_off + 12 ..][0..sound_info_size]);
            } else {
                // Truncated record: zero the struct rather than leaving the
                // caller's buffer unwritten, since the fill is documented to
                // happen whenever the sound resolves.
                @memset(oi[0..sound_info_size], 0);
            }
        }
        const o = out_filename orelse return self.soundAssetPathBytes(found.sfn);
        return self.writeSoundAssetPath(found.sfn, o);
    }

    /// MILESBANKSOUNDINFO.DurationMs (Sound+12 Info, +24) for a named sound.
    pub fn soundDurationMs(self: *const Bank, sound_name: []const u8) ?u32 {
        const data_off = self.findSoundDataOffset(sound_name) orelse return null;
        if (!self.inBounds(data_off, 40)) return 0;
        return self.rdU32(data_off + 36);
    }

    /// Drop this open's reference. The bank is unregistered and freed by the
    /// release that drops the last one, so an open of an already-loaded bank and
    /// its matching close leave the state the first open alone would.
    pub fn deinit(self: *Bank) void {
        // A leftover reference means another open still holds the bank; the
        // frees belong to whichever release drops the last one.
        if (!registryRelease(self)) return;
        self.teardown();
    }

    /// Free a bank that was never published to the registry: the load path's
    /// own failure and duplicate cases. `deinit` is the only path that reaches
    /// a published bank's frees.
    fn teardown(self: *Bank) void {
        self.event_index.deinit(self.allocator);
        self.sound_index.deinit(self.allocator);
        self.allocator.free(self.meta);
        self.allocator.free(self.source_path);
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

    // A file already in the container answers this open with a reference to the
    // copy it holds, before the metadata is copied and the indexes built. The
    // header checks above still run, so a caller that hands over bytes which are
    // not a bank keeps getting that error rather than silently getting the bank
    // of a file it named.
    const source = try fs_compat.dupeResolvedPathZ(allocator, filename);
    if (registryAcquireBySource(source)) |existing| {
        allocator.free(source);
        return existing;
    }
    errdefer allocator.free(source);
    try registryReserve();

    const meta_size = std.mem.readInt(i32, image[off_meta_size..][0..4], .little);
    if (meta_size < header_size or @as(usize, @intCast(meta_size)) > image.len) return error.BadMetaSize;
    const msz: usize = @intCast(meta_size);

    // Validate each asset table fits inside the metadata, reading the caller's
    // image through a view of the metadata the bank will hold. Checked before
    // anything is copied, so a rejected bank owns nothing, and the ownership
    // below then moves exactly once with no errdefer left to unwind against it.
    const probe: Bank = .{
        // The table checks below only read, and the bank holds a mutable copy of
        // these same bytes, so the const image needs only a type cast here.
        .meta = @constCast(image[0..msz]),
        .filename = source,
        .source_path = source,
        .allocator = undefined,
    };
    inline for (.{ AssetKind.events, .environments, .presets, .sounds }) |k| {
        const cnt = probe.countFor(k);
        const base = probe.tableOff(k);
        if (cnt != 0) {
            const end = @as(u64, base) + @as(u64, cnt) * asset_entry_size;
            if (base == 0 or end > msz) return error.BadAssetTable;
        }
    }

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
    // The struct owns meta, fname and source from here on: the errdefers above
    // are spent and the only step left cannot fail.
    self.* = .{ .meta = meta, .filename = fname, .source_path = source, .allocator = allocator };

    // Copy SoundBankName[4] out terminated (meta_size >= header_size > off_name,
    // enforced above, so the read is in bounds). The field is 4 bytes, so a
    // name outside ASCII is cut mid-character: "café" is 5 bytes, and the
    // field holds "caf" plus the lead byte of the é. name() hands this buffer
    // to the C surface as a string, and the callers match it against the name
    // the game asked for, so drop the partial character. The scratch carries a
    // NUL past the field because utf8Prefix only trims a string longer than its
    // limit, and 4 bytes is exactly the field.
    const nlen = @min(msz - off_name, 4);
    var name_field: [5]u8 = [_]u8{0} ** 5;
    @memcpy(name_field[0..nlen], image[off_name..][0..nlen]);
    const cut_name = wide.utf8Prefix(&name_field, nlen);
    @memcpy(self.name_buf[0..cut_name.len], cut_name);

    // Build the events/sounds name indexes before the bank joins the registry:
    // until registryAdd publishes it, no other thread can reach the Bank, so
    // the build needs no lock and lookups never race it. A failed build leaves
    // that table on the linear-scan path.
    self.event_index = self.buildNameIndex(.events) catch .{};
    self.sound_index = self.buildNameIndex(.sounds) catch .{};
    const registered = registryAdd(self);
    if (registered != self) {
        // Another load of the same file reached the registry between the lookup
        // above and this one, and already holds the bank. The copy just built is
        // redundant, so it goes and the caller gets the live bank's reference.
        self.teardown();
    }
    return registered;
}

// Hand-built images for the tests below: a little-endian field write and a
// NUL-terminated name appended to the string pool.
fn writeU32(buf: []u8, off: usize, v: u32) void {
    std.mem.writeInt(u32, buf[off..][0..4], v, .little);
}

fn putName(buf: []u8, at: usize, s: []const u8) usize {
    @memcpy(buf[at .. at + s.len], s);
    buf[at + s.len] = 0;
    return at + s.len + 1;
}

test "asset lookup: index parity with scan semantics" {
    const testing = std.testing;
    var img: [2048]u8 = undefined;
    @memset(&img, 0);

    // Header: two event entries + one sound entry, tables right after it.
    const ev_off: u32 = header_size;
    const snd_off: u32 = ev_off + 3 * asset_entry_size;
    writeU32(&img, off_tag, BANK_TAG);
    writeU32(&img, off_version, @bitCast(BANK_VERSION));
    writeU32(&img, off_events, ev_off);
    writeU32(&img, off_sounds, snd_off);
    writeU32(&img, off_event_count, 3);
    writeU32(&img, off_sound_count, 1);

    // String/data pool after both tables.
    var pool: usize = snd_off + asset_entry_size;
    const d0: u32 = @intCast(pool);
    pool = putName(&img, pool, "E0DATA");
    const d1: u32 = @intCast(pool);
    pool = putName(&img, pool, "E1DATA");
    const n0: u32 = @intCast(pool);
    pool = putName(&img, pool, "Boom");
    const n1: u32 = @intCast(pool); // duplicate name, different case
    pool = putName(&img, pool, "BOOM");
    const n2: u32 = @intCast(pool); // >128 bytes to exercise the heap key path
    var long_buf: [200]u8 = undefined;
    @memset(&long_buf, 'x');
    long_buf[199] = 'Z';
    pool = putName(&img, pool, &long_buf);
    const s0: u32 = @intCast(pool);
    pool = putName(&img, pool, "kick");

    // events: e0 "Boom" (first match must win over e1), e1 "BOOM", e2 long name.
    writeU32(&img, ev_off, n0);
    writeU32(&img, ev_off + 4, d0);
    writeU32(&img, ev_off + 8, n1);
    writeU32(&img, ev_off + 12, d1);
    writeU32(&img, ev_off + 16, n2);
    writeU32(&img, ev_off + 20, d1);
    // sounds: one entry.
    writeU32(&img, snd_off, s0);
    writeU32(&img, snd_off + 4, d0);

    writeU32(&img, off_meta_size, @intCast(pool));
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

test "container: a duplicated event name resolves by load order, not unload history" {
    const testing = std.testing;

    // One event per image, the same name in all of them, distinct contents.
    const BankImage = struct {
        bytes: [256]u8,
        len: usize,
        data_off: u32,

        fn build(img: *@This(), tag: u8) void {
            @memset(&img.bytes, 0);
            writeU32(&img.bytes, off_events, @intCast(header_size));
            writeU32(&img.bytes, off_tag, BANK_TAG);
            writeU32(&img.bytes, off_version, @bitCast(BANK_VERSION));
            writeU32(&img.bytes, off_event_count, 1);
            var pool: usize = header_size + asset_entry_size;
            const name = "Boom";
            writeU32(&img.bytes, header_size, @intCast(pool));
            @memcpy(img.bytes[pool..][0..name.len], name[0..name.len]);
            pool += name.len + 1;
            img.data_off = @intCast(pool);
            writeU32(&img.bytes, header_size + 4, img.data_off);
            @memset(img.bytes[pool..][0..4], tag);
            pool += 4;
            writeU32(&img.bytes, off_meta_size, @intCast(pool));
            img.len = pool;
        }
    };

    var imgs: [3]BankImage = undefined;
    for (&imgs, 0..) |*img, i| img.build(@intCast('A' + i));

    const resolvesTo = struct {
        fn f(bank: *Bank, off: u32) bool {
            const p = containerFindEvent("boom") orelse return false;
            return @intFromPtr(p) - @intFromPtr(bank.meta.ptr) == off;
        }
    }.f;

    // Each bank is released mid-test, so a guard tracks what is still live and
    // keeps an assertion failure from double-freeing one.
    const first = try loadFromMemory(testing.allocator, "one.mbnk", imgs[0].bytes[0..imgs[0].len]);
    var first_live = true;
    defer if (first_live) first.deinit();
    const second = try loadFromMemory(testing.allocator, "two.mbnk", imgs[1].bytes[0..imgs[1].len]);
    var second_live = true;
    defer if (second_live) second.deinit();
    const third = try loadFromMemory(testing.allocator, "three.mbnk", imgs[2].bytes[0..imgs[2].len]);
    const third_live = true;
    defer if (third_live) third.deinit();

    try testing.expect(resolvesTo(first, imgs[0].data_off));
    // Releasing the winning bank must promote the next one loaded, not the
    // one that happens to sit last in the registry.
    first.deinit();
    first_live = false;
    try testing.expect(resolvesTo(second, imgs[1].data_off));
    second.deinit();
    second_live = false;
    try testing.expect(resolvesTo(third, imgs[2].data_off));
}

test "owned lookup holds the bank for the walk and gives the reference back" {
    const testing = std.testing;
    var img: [256]u8 = undefined;
    @memset(&img, 0);
    const w32 = struct {
        fn f(buf: []u8, off: u32, v: u32) void {
            std.mem.writeInt(u32, buf[off..][0..4], v, .little);
        }
    }.f;

    w32(&img, off_tag, BANK_TAG);
    w32(&img, off_version, @bitCast(BANK_VERSION));
    w32(&img, off_events, header_size);
    w32(&img, off_event_count, 1);
    var pool: usize = header_size + asset_entry_size;
    const nm = "Boom";
    w32(&img, header_size, @intCast(pool));
    @memcpy(img[pool..][0..nm.len], nm);
    pool += nm.len + 1;
    const data_off: u32 = @intCast(pool);
    w32(&img, header_size + 4, data_off);
    @memset(img[pool..][0..4], 'A');
    pool += 4;
    w32(&img, off_meta_size, @intCast(pool));

    const bank = try loadFromMemory(testing.allocator, "owned.mbnk", img[0..pool]);
    var live = true;
    defer if (live) bank.deinit();

    // The reference the owned lookup hands out is the caller's to drop. If it
    // were not, the release below would leave the bank registered and the test
    // allocator would report its metadata as leaked at the end of the test.
    const found = containerFindEventOwned("boom") orelse return error.NoEvent;
    try testing.expectEqual(bank, found.bank);
    try testing.expectEqual(@as(usize, data_off), @intFromPtr(found.data) - @intFromPtr(bank.meta.ptr));
    found.bank.deinit();
    try testing.expectEqual(@as(u32, 1), loadedCount());

    // Still live and still answering: the found reference is gone, not the
    // open that loaded it.
    try testing.expect(bank.findEventContents("boom") != null);
    bank.deinit();
    live = false;
    try testing.expectEqual(@as(u32, 0), loadedCount());
}

test "sound record: a DataOffset near the top of the 32-bit range is rejected" {
    const testing = std.testing;

    // The DLL ships as a 32-bit x86 PE, so a sound record's u32 DataOffset sits
    // in a usize that can hold 2^32 - 1 values. Every bound that adds to it
    // (DataOffset + 4, + 8, + 28, + 40, and DataOffset + FileNameOffset) wraps on
    // that target, which turns `off + n > len` into a false pass and the slice
    // behind it into an out-of-bounds read. These offsets cover every point in
    // the wrap window; each must read as "out of range" rather than as a small
    // in-bounds offset that resolves to some unrelated byte of the metadata.
    const out_of_range: []const u32 = &.{
        0xFFFF_FFFC,
        0xFFFF_FFF8,
        0xFFFF_FFF0,
        0xFFFF_FF00,
        0xFFFF_F000,
    };

    for (out_of_range) |data_off| {
        var img: [256]u8 = undefined;
        @memset(&img, 0);

        // A well-formed one-entry sound table whose record lies out of range.
        // The table itself is in bounds, so the bank loads and the lookups below
        // reach the record path rather than failing at table validation.
        const snd_off: u32 = header_size;
        var pool: usize = snd_off + asset_entry_size;
        const s0: u32 = @intCast(pool);
        pool = putName(&img, pool, "kick");
        writeU32(&img, off_tag, BANK_TAG);
        writeU32(&img, off_version, @bitCast(BANK_VERSION));
        writeU32(&img, off_sounds, snd_off);
        writeU32(&img, off_sound_count, 1);
        writeU32(&img, snd_off, s0);
        writeU32(&img, snd_off + 4, data_off);
        writeU32(&img, off_meta_size, @intCast(pool));

        const bank = try loadFromMemory(testing.allocator, "bad.mbnk", img[0..pool]);
        defer bank.deinit();

        // The name still resolves: only the record's own offset is a lie.
        try testing.expectEqual(data_off, bank.findSoundDataOffset("kick") orelse return error.NoSound);

        var out: [256]u8 = undefined;
        try testing.expectEqual(@as(i32, -1), bank.soundAssetFilename("kick", &out));
        try testing.expectEqual(@as(u8, 0), out[0]);
        try testing.expectEqual(@as(i32, 0), bank.soundAssetInfo("kick", &out, &out));
        try testing.expectEqual(@as(u8, 0), out[0]);
        // soundDurationMs reports an out-of-range record as a zero duration; the
        // name resolved, so null is not the answer here.
        try testing.expectEqual(@as(u32, 0), bank.soundDurationMs("kick") orelse return error.NoSound);
        try testing.expectEqualStrings("kick", std.mem.span(bank.assetName(.sounds, 0) orelse return error.NoName));
    }
}

test "a bank name that does not fit SoundBankName[4] keeps whole characters" {
    const testing = std.testing;
    var img: [256]u8 = undefined;
    @memset(&img, 0);
    writeU32(&img, off_tag, BANK_TAG);
    writeU32(&img, off_version, @bitCast(BANK_VERSION));
    // "café" is 5 bytes, so the 4-byte field holds "caf" plus the lead byte of
    // the two-byte character. The C surface reads name() as a string, and
    // AIL_open_soundbank matches it against the name the game asked for.
    const cafe = "caf\u{00e9}";
    @memcpy(img[off_name..][0..4], cafe[0..4]);
    writeU32(&img, off_meta_size, header_size);
    const bank = try loadFromMemory(testing.allocator, "cafe.mbnk", img[0..header_size]);
    defer bank.deinit();

    const name = std.mem.span(bank.name());
    try testing.expect(std.unicode.utf8ValidateSlice(name));
    try testing.expectEqualStrings("caf", name);
}

/// A bank image with one sound whose file name is `sfn_len` bytes long, so the
/// "*<bank file><sound file>" path the accessors write is 10 + sfn_len bytes
/// with the bank named "big.mbnk".
fn bankWithSoundFileName(sfn_len: usize) struct { img: [1024]u8, len: usize } {
    var img: [1024]u8 = undefined;
    @memset(&img, 0);
    const snd_off: u32 = header_size;
    const rec_off: usize = header_size + asset_entry_size;
    const name_off: u32 = @intCast(rec_off + 64);
    @memcpy(img[name_off..][0..5], "kick\x00");
    const sfn_off: u32 = @intCast(name_off + 5);
    @memset(img[sfn_off..][0..sfn_len], 's');
    img[sfn_off + sfn_len] = 0;

    writeU32(&img, off_tag, BANK_TAG);
    writeU32(&img, off_version, @bitCast(BANK_VERSION));
    writeU32(&img, off_sounds, snd_off);
    writeU32(&img, off_sound_count, 1);
    writeU32(&img, snd_off, name_off);
    writeU32(&img, snd_off + 4, @intCast(rec_off));
    // Sound record: NameOffset, FileNameOffset (relative to the record), and
    // the MILESBANKSOUNDINFO Info block at +12.
    writeU32(&img, rec_off, name_off);
    writeU32(&img, rec_off + 4, sfn_off -| @as(u32, @intCast(rec_off)));
    const len = sfn_off + sfn_len + 1;
    writeU32(&img, off_meta_size, @intCast(len));
    return .{ .img = img, .len = len };
}

test "an asset path longer than the cap is refused, not written" {
    const testing = std.testing;

    // One byte over the cap: "*" + "big.mbnk" + the name + terminator. The C
    // entry points take no buffer size, so a name this long would run as far
    // past a game-sized buffer as the bank file cared to say.
    const over = bankWithSoundFileName(max_asset_path_bytes - 9);
    const bank = try loadFromMemory(testing.allocator, "big.mbnk", over.img[0..over.len]);
    defer bank.deinit();

    var out: [512]u8 = undefined;
    @memset(&out, 0xAA);
    try testing.expectEqual(@as(i32, -1), bank.soundAssetFilename("kick", &out));
    try testing.expectEqual(@as(u8, 0), out[0]);
    @memset(&out, 0xAA);
    try testing.expectEqual(@as(i32, 0), bank.soundAssetInfo("kick", &out, null));
    try testing.expectEqual(@as(u8, 0), out[0]);
    // The record itself is in bounds, so the rest of the sound still answers.
    try testing.expect(bank.soundDurationMs("kick") != null);

    // Exactly at the cap still resolves, and reports the exact requirement.
    const at = bankWithSoundFileName(max_asset_path_bytes - 10);
    const exact = try loadFromMemory(testing.allocator, "yes.mbnk", at.img[0..at.len]);
    defer exact.deinit();
    const req = exact.soundAssetInfo("kick", null, null);
    try testing.expectEqual(@as(i32, @intCast(max_asset_path_bytes)), req);
    const sized = try testing.allocator.alloc(u8, @intCast(req));
    defer testing.allocator.free(sized);
    @memset(sized, 0xAA);
    try testing.expectEqual(req, exact.soundAssetInfo("kick", sized.ptr, null));
    try testing.expectEqual(@as(usize, max_asset_path_bytes - 1), std.mem.span(@as([*:0]u8, @ptrCast(sized.ptr))).len);
    try testing.expect(sized[0] == '*');
}

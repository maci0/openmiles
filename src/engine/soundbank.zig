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

fn registryAdd(bank: *Bank) void {
    regLock();
    defer regUnlock();
    g_registry.append(registry_alloc, bank) catch {};
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

pub const Bank = struct {
    meta: []u8,
    filename: [:0]u8,
    allocator: std.mem.Allocator,

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
        // SoundBankName[4] is a fixed 4-char field; ensure it stays in bounds.
        if (off_name + 4 <= self.meta.len) return @ptrCast(self.meta.ptr + off_name);
        return "";
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

    /// Find an asset by (case-insensitive) name and return a pointer to its data
    /// at DataOffset, or null if not found / the data offset escapes the metadata.
    /// Mirrors the SDK FindAsset + AIL_ptr_add(bank, pAsset->DataOffset).
    pub fn assetData(self: *const Bank, which: AssetKind, target: []const u8) ?[*]const u8 {
        const count = self.countFor(which);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const entry = @as(usize, self.tableOff(which)) + @as(usize, i) * asset_entry_size;
            const name_off = self.rdU32(entry);
            if (name_off == 0 or name_off >= self.meta.len) continue;
            const nm = std.mem.sliceTo(self.meta[name_off..], 0);
            if (std.ascii.eqlIgnoreCase(nm, target)) {
                const data_off = self.rdU32(entry + 4);
                if (data_off == 0 or data_off >= self.meta.len) return null;
                return @ptrCast(self.meta.ptr + data_off);
            }
        }
        return null;
    }

    /// The event-step bytecode for a named event (MilesFindEvent / AIL_find_event).
    pub fn findEventContents(self: *const Bank, event_name: []const u8) ?[*]const u8 {
        return self.assetData(.events, event_name);
    }

    /// Resolve a sound asset's source filename into `out` as the SDK formats it:
    /// "*" + bank filename + the sound's own filename. Returns the sound's
    /// DataLen (MILESBANKSOUNDINFO.DataLen) on success, or -1 if not found.
    /// `out` must be large enough for the result (the C API takes no size, matching
    /// the SDK). The Sound layout (NameOffset@0, FileNameOffset@4, Info@12 with
    /// DataLen at Info+12) is from hlbank.cpp.
    pub fn soundAssetFilename(self: *const Bank, sound_name: []const u8, out: [*]u8) i32 {
        const count = self.countFor(.sounds);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const entry = @as(usize, self.tableOff(.sounds)) + @as(usize, i) * asset_entry_size;
            const name_off = self.rdU32(entry);
            if (name_off == 0 or name_off >= self.meta.len) continue;
            const nm = std.mem.sliceTo(self.meta[name_off..], 0);
            if (!std.ascii.eqlIgnoreCase(nm, sound_name)) continue;
            const data_off = self.rdU32(entry + 4);
            if (data_off == 0 or data_off + 8 > self.meta.len) {
                out[0] = 0;
                return -1;
            }
            const fn_abs = data_off + self.rdU32(data_off + 4); // pSound + FileNameOffset
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
            if (data_off + 28 > self.meta.len) return 0;
            return self.rdI32(data_off + 24);
        }
        out[0] = 0;
        return -1;
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
            "ChannelCount", "ChannelMask", "Rate", "DataLen", "SoundLimit",
            "IsExternal", "DurationMs", "StreamBufferSize", "IsAdpcm", "AdpcmBlockSize", "MixVolumeDAC",
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
        const count = self.countFor(.sounds);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const entry = @as(usize, self.tableOff(.sounds)) + @as(usize, i) * asset_entry_size;
            const name_off = self.rdU32(entry);
            if (name_off == 0 or name_off >= self.meta.len) continue;
            const nm = std.mem.sliceTo(self.meta[name_off..], 0);
            if (!std.ascii.eqlIgnoreCase(nm, sound_name)) continue;
            const data_off = self.rdU32(entry + 4);
            if (data_off == 0 or data_off + 8 > self.meta.len) {
                if (out_filename) |o| o[0] = 0;
                return 0;
            }
            if (out_info) |oi| {
                if (data_off + 12 + sound_info_size <= self.meta.len) {
                    @memcpy(oi[0..sound_info_size], self.meta[data_off + 12 ..][0..sound_info_size]);
                }
            }
            const fn_abs = data_off + self.rdU32(data_off + 4);
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
        if (out_filename) |o| o[0] = 0;
        return 0;
    }

    /// MILESBANKSOUNDINFO.DurationMs (Sound+12 Info, +24) for a named sound.
    pub fn soundDurationMs(self: *const Bank, sound_name: []const u8) ?u32 {
        const count = self.countFor(.sounds);
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const entry = @as(usize, self.tableOff(.sounds)) + @as(usize, i) * asset_entry_size;
            const name_off = self.rdU32(entry);
            if (name_off == 0 or name_off >= self.meta.len) continue;
            const nm = std.mem.sliceTo(self.meta[name_off..], 0);
            if (!std.ascii.eqlIgnoreCase(nm, sound_name)) continue;
            const data_off = self.rdU32(entry + 4);
            if (data_off + 40 > self.meta.len) return 0;
            return self.rdU32(data_off + 36);
        }
        return null;
    }

    pub fn deinit(self: *Bank) void {
        registryRemove(self);
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

    const meta = try allocator.dupe(u8, image[0..msz]);
    errdefer allocator.free(meta);
    const fname = try allocator.dupeZ(u8, filename);
    errdefer allocator.free(fname);

    const self = try allocator.create(Bank);
    errdefer allocator.destroy(self);
    self.* = .{ .meta = meta, .filename = fname, .allocator = allocator };

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
    registryAdd(self);
    return self;
}

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

// Count of banks currently loaded, maintained automatically by loadFromMemory /
// Bank.deinit. The Miles event-system state reports this as LoadedBankCount.
var g_loaded_count: u32 = 0;
pub fn loadedCount() u32 {
    return @atomicLoad(u32, &g_loaded_count, .seq_cst);
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

    pub fn deinit(self: *Bank) void {
        _ = @atomicRmw(u32, &g_loaded_count, .Sub, 1, .seq_cst);
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
    _ = @atomicRmw(u32, &g_loaded_count, .Add, 1, .seq_cst);
    return self;
}

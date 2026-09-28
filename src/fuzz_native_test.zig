//! Coverage-guided fuzz targets (std.testing.fuzz) for the parsers that take
//! the most untrusted bytes per input: the SoundBank event-step decoder
//! (`event.nextStep`, a hand-written recursive-descent bytecode reader that
//! copies names into a caller scratch buffer), the XMIDI IFF → SMF converter
//! (`xmidiToSmf` / `xmidiBareToSmf`), the BANK image loader behind the bank
//! query API, the WAV container readers that classify a file, and the WAV
//! cue-point marker API (count / by-index / by-name over a nested
//! LIST-adtl-labl chunk tree), the Miles 9.x event enqueue, which turns a
//! parsed event string into sound instances, cached names, persisted presets
//! and per-label caps, the MP3 image inspector and frame enumerator (ID3v2
//! skips, the frame-sync search, and the bitrate-derived frame length a
//! decoder is handed for each frame), the DLS container split
//! (find / extract / list over a merged .mil image), and the plugin loader's
//! directory-entry name filter, the gate every untrusted name in a game
//! directory passes before the loader opens it as code.
//!
//! fuzz_test.zig drives these with fixed-seed PRNG bytes. These targets add
//! what a PRNG loop cannot: the input picks the shapes (which ASCII a field may
//! contain, how the IFF chunks nest, whether a declared chunk size lies), and
//! each target asserts invariants instead of only "did not crash", so a
//! correctness bug becomes a failing input rather than a silent one.
//!
//! The corpora run as part of `zig build test`; `zig build test --fuzz` (the
//! build runner's own flag) runs them coverage-guided. Each seed is a
//! well-formed or near-well-formed image of the shape the parser meets in
//! real data, so a mutation starts from one instead of from noise.

const std = @import("std");
const testing = std.testing;
const openmiles = @import("openmiles");
const api_v8 = @import("api/v8.zig");
const api_miles = @import("api/miles.zig");
const api_dls = @import("api/dls.zig");
const api_memory = @import("api/memory.zig");

const Weight = std.testing.Smith.Weight;

fn w(min: u8, max: u8, weight: u64) Weight {
    return .{ .min = min, .max = max, .weight = weight };
}

/// The C allocator's free, for the buffers the AIL_* exports hand back.
fn freeLock(p: ?*anyopaque) void {
    if (p) |ptr| api_memory.AIL_mem_free_lock(ptr);
}

// --- Target 1: the event-step decoder ---------------------------------------

/// Bytes a Miles event string is built from: step-type digits, hex field
/// digits, the ';' field separator, the ':' name-list separator, and the
/// characters names are made of. Keeping the rest out gives the fuzzer the
/// alphabet the format actually uses.
const event_byte_weights: []const Weight = &.{
    w('0', '9', 40), // step types, version, hex digits
    w('a', 'z', 20), // names, float digits
    w('A', 'Z', 20),
    w(';', ';', 60), // field separator
    w(':', ':', 20), // cache/purge name-list separator
    w(' ', ' ', 10), // float field padding
    w('-', '.', 10), // float sign and decimal point
    w('/', '/', 5), // "<bank>/<sound>" sound references
    w('_', '_', 5),
    w('<', '>', 5), // separator noise the decoder has to tolerate
};

const event_ctx = struct {
    buf: [1024]u8 = undefined,
    scratch: [512]u8 = undefined,
};

/// Every string the decoder hands out must be readable for `len` bytes plus a
/// terminator, and must point either into the caller's scratch (the copy path,
/// which always NUL-terminates) or into the source text (the un-copied path
/// taken when the scratch overflows, where the field's own ';' or NUL ends
/// it). Anything else is a wild pointer a caller would read through.
fn expectReadableString(s: openmiles.event.MSSStringC, text: []const u8, scratch: []const []const u8) !void {
    const p = s.str orelse return;
    const n: usize = @intCast(@max(0, s.len));
    const addr = @intFromPtr(p);
    for (scratch) |sc| {
        const lo = @intFromPtr(sc.ptr);
        if (addr >= lo and addr +| n +| 1 <= lo +| sc.len) {
            try testing.expectEqual(@as(u8, 0), p[n]);
            return;
        }
    }
    const lo = @intFromPtr(text.ptr);
    if (addr >= lo and addr +| n +| 1 <= lo +| text.len) {
        // Source field: the decoder stops the field at ';' or at the NUL.
        try testing.expect(p[n] == 0 or p[n] == ';');
        return;
    }
    return error.StringOutOfBounds;
}

/// A cached/purged name-list entry must be a NUL-terminated name inside the
/// scratch, never uninitialized memory (a trailing-colon list reserves one
/// slot more than it writes).
fn expectScratchName(entry: [*]const u8, scratch: []const []const u8) !void {
    const addr = @intFromPtr(entry);
    for (scratch) |sc| {
        const lo = @intFromPtr(sc.ptr);
        if (addr < lo or addr >= lo +| sc.len) continue;
        const tail = entry[0 .. lo +| sc.len - addr];
        if (std.mem.indexOfScalar(u8, tail, 0) != null) return;
    }
    return error.NameNotInScratch;
}

fn expectReadableStepStrings(step: openmiles.event.EVENT_STEP_INFO, text: []const u8, scratch: []const []const u8) !void {
    const S = openmiles.event;
    switch (@as(S.StepType, @enumFromInt(step.type))) {
        .start_sound => {
            const s = step.u.start;
            try expectReadableString(s.soundname, text, scratch);
            try expectReadableString(s.presetname, text, scratch);
            try expectReadableString(s.eventname, text, scratch);
            try expectReadableString(s.labels, text, scratch);
            try expectReadableString(s.markerstart, text, scratch);
            try expectReadableString(s.markerend, text, scratch);
            try expectReadableString(s.startoffset, text, scratch);
            try expectReadableString(s.statevar, text, scratch);
            try expectReadableString(s.varinit, text, scratch);
        },
        .control_sounds => {
            const s = step.u.control;
            try expectReadableString(s.labels, text, scratch);
            try expectReadableString(s.markerstart, text, scratch);
            try expectReadableString(s.markerend, text, scratch);
            try expectReadableString(s.position, text, scratch);
            try expectReadableString(s.presetname, text, scratch);
        },
        .apply_env => try expectReadableString(step.u.env.envname, text, scratch),
        .comment => try expectReadableString(step.u.comment.comment, text, scratch),
        .cache_sounds, .purge_sounds => {
            const s = step.u.load;
            try expectReadableString(s.lib, text, scratch);
            try testing.expect(s.namecount >= 0);
            const count: usize = @intCast(s.namecount);
            const list = s.namelist orelse {
                try testing.expectEqual(@as(usize, 0), count);
                return;
            };
            for (0..count) |i| {
                if (list[i]) |entry| try expectScratchName(entry, scratch);
            }
        },
        .set_limits => {
            try expectReadableString(step.u.limits.name, text, scratch);
            try expectReadableString(step.u.limits.limits, text, scratch);
        },
        .persist => {
            const s = step.u.persist;
            try expectReadableString(s.name, text, scratch);
            try expectReadableString(s.presetname, text, scratch);
            try expectReadableString(s.labels, text, scratch);
        },
        .ramp => {
            const s = step.u.ramp;
            try expectReadableString(s.name, text, scratch);
            try expectReadableString(s.labels, text, scratch);
            try expectReadableString(s.target, text, scratch);
        },
        .set_blend => try expectReadableString(step.u.blend.name, text, scratch),
        .exec_event => try expectReadableString(step.u.exec.eventname, text, scratch),
        .enable_limit => try expectReadableString(step.u.enablelimit.limitname, text, scratch),
        .set_lfo => {
            const s = step.u.setlfo;
            try expectReadableString(s.name, text, scratch);
            try expectReadableString(s.base, text, scratch);
            try expectReadableString(s.amplitude, text, scratch);
            try expectReadableString(s.freq, text, scratch);
        },
        .move_var => try expectReadableString(step.u.movevar.name, text, scratch),
        else => {},
    }
}

fn fuzzEventStepsOne(ctx: *event_ctx, smith: *std.testing.Smith) anyerror!void {
    const n: usize = @intCast(smith.sliceWeighted(
        &ctx.buf,
        &.{.{ .min = 1, .max = ctx.buf.len, .weight = 1 }},
        event_byte_weights,
    ));
    if (n == 0) return;
    const text = ctx.buf[0..n];
    // A real event string is NUL-terminated, so the malformations that matter
    // are cuts at an arbitrary point, not stray NULs mid-string. Punch a few
    // terminators in so the decoder meets truncated fields.
    const holes: u32 = smith.valueRangeAtMost(u32, 0, 4);
    var h: u32 = 0;
    while (h < holes) : (h += 1) text[smith.index(n)] = 0;
    text[n - 1] = 0;

    // A small scratch makes the copy path overflow, which is the branch that
    // hands source pointers back instead of copies.
    const scratch_len: usize = @intCast(smith.valueRangeAtMost(u32, 0, ctx.scratch.len));
    const sc = ctx.scratch[0..scratch_len];

    var p: [*:0]const u8 = @ptrCast(text.ptr);
    const terminator = @intFromPtr(text.ptr) + n - 1;
    var steps: usize = 0;
    while (steps < 256) : (steps += 1) {
        var step: openmiles.event.EVENT_STEP_INFO = .{};
        const next = openmiles.event.nextStep(p, &step, sc) orelse break;
        const cur = @intFromPtr(next);
        // Every step consumes its type byte and separator, so a cursor that
        // does not move is a walk that can never terminate.
        try testing.expect(cur > @intFromPtr(p));
        // The caller dereferences the returned cursor until it finds the
        // terminator, so the cursor may never point past it.
        try testing.expect(cur <= terminator);
        try expectReadableStepStrings(step, text, &.{sc});
        p = next;
    }
}

const event_corpus = [_][]const u8{
    // A start_sound step as the event VM writes it: names, a state-var list,
    // then the "%f" range fields.
    "1;FILE.SND;FILE.SND;0;EVENTNAME;M_START;M_END;STATEVAR;VARINIT;LABELS;0;0;0;0;0;0;0;0;0.000000;0.000000;-127.000000;127.000000;-127.000000;127.000000;0.000000;0;0;",
    // A cache_sounds step: the ':'-separated name list is the field whose
    // pointer array is carved out of the scratch.
    "5;MUS.MLB;snd1:snd2:snd3;0;0;",
    // A version header in front of a ramp step: the header re-enters the
    // decoder, so the cursor moves across two steps for one call.
    "9;4;:name;labels;target;1.500000;1;1;2;",
    // A trailing-colon name list, which reserves one slot more than it writes.
    "6;;lib.a:;0;0;",
    "7;limname;1,2,3;",
    // Truncations: every prefix of a well-formed step is the shape a
    // half-written bank record has on disk.
    "1;FILE.SND;FILE.SND",
    "5;MUS.MLB;snd1:",
    "9;4",
    "9",
    "",
};

test "fuzz: event step decoder" {
    var ctx: event_ctx = .{};
    try std.testing.fuzz(&ctx, fuzzEventStepsOne, .{ .corpus = &event_corpus });
}

// --- Target 2: the XMIDI → SMF converter ------------------------------------

const xmidi_ctx = struct {
    buf: [512]u8 = undefined,
    evnt: [200]u8 = undefined,
};

/// The sizes a real file declares, plus the ones a hostile one does: zero, one
/// byte over, doubled, and the whole u32 range.
fn declaredSize(smith: *std.testing.Smith, correct: usize) u32 {
    return switch (smith.index(6)) {
        0 => @intCast(correct),
        1 => 0,
        2 => @intCast(correct + 1),
        3 => @intCast(correct * 2),
        4 => @intCast(correct / 2),
        else => std.math.maxInt(u32),
    };
}

fn putBe32(buf: []u8, at: usize, v: u32) void {
    std.mem.writeInt(u32, buf[at..][0..4], v, .big);
}

/// EVNT bytes: delta-time VLQs and MIDI status bytes, so the event loop walks
/// the real note/meta/sysex branches instead of stopping at the first odd byte.
const evnt_byte_weights: []const Weight = &.{
    w(0x00, 0x7F, 60), // delta times and data bytes
    w(0x80, 0x8F, 20), // note-off
    w(0x90, 0x9F, 20), // note-on (XMIDI adds a duration VLQ after it)
    w(0xB0, 0xBF, 10), // control change
    w(0xC0, 0xDF, 10), // program change / channel pressure
    w(0xFF, 0xFF, 10), // meta event
    w(0xF0, 0xF7, 5), // sysex
};

/// Lay out one canonical XMIDI image and let the fuzzer pick which of its
/// chunk sizes to lie about. Returns the whole image plus its bare FORM/XMID
/// part, which the converter can also be handed on its own.
fn buildXmidiImage(ctx: *xmidi_ctx, smith: *std.testing.Smith) struct { image: []u8, bare: []u8 } {
    const evnt_len: usize = @intCast(smith.sliceWeighted(
        &ctx.evnt,
        &.{.{ .min = 0, .max = ctx.evnt.len, .weight = 1 }},
        evnt_byte_weights,
    ));
    const evnt_padded = evnt_len + (evnt_len & 1); // IFF pads odd chunks
    const evnt_chunk = 8 + evnt_padded;
    const xmid_body = 4 + evnt_chunk; // "XMID" + EVNT chunk
    const cat_body = 4 + 8 + xmid_body; // "XMID" + FORM/XMID chunk
    const xdir_body = 4 + 8 + cat_body; // "XDIR" + CAT chunk

    // FORM <size> XDIR { CAT <size> XMID { FORM <size> XMID { EVNT ... } } }
    const xdir_at: usize = 0;
    const cat_at: usize = 8 + 4;
    const xmid_at: usize = cat_at + 8 + 4;
    const evnt_at: usize = xmid_at + 8 + 4;
    const bare_end: usize = xmid_at + 8 + xmid_body;

    @memcpy(ctx.buf[xdir_at..][0..4], "FORM");
    putBe32(ctx.buf[0..], xdir_at + 4, declaredSize(smith, xdir_body));
    @memcpy(ctx.buf[xdir_at + 8 ..][0..4], "XDIR");
    @memcpy(ctx.buf[cat_at..][0..4], "CAT ");
    putBe32(ctx.buf[0..], cat_at + 4, declaredSize(smith, cat_body));
    @memcpy(ctx.buf[cat_at + 8 ..][0..4], "XMID");
    @memcpy(ctx.buf[xmid_at..][0..4], "FORM");
    putBe32(ctx.buf[0..], xmid_at + 4, declaredSize(smith, xmid_body));
    @memcpy(ctx.buf[xmid_at + 8 ..][0..4], "XMID");
    @memcpy(ctx.buf[evnt_at..][0..4], "EVNT");
    putBe32(ctx.buf[0..], evnt_at + 4, declaredSize(smith, evnt_padded));
    @memcpy(ctx.buf[evnt_at + 8 ..][0..evnt_len], ctx.evnt[0..evnt_len]);

    return .{ .image = ctx.buf[0..bare_end], .bare = ctx.buf[xmid_at..bare_end] };
}

fn fuzzXmidiOne(ctx: *xmidi_ctx, smith: *std.testing.Smith) anyerror!void {
    const built = buildXmidiImage(ctx, smith);
    // Hand the converter either the wrapped image or the bare FORM/XMID, so
    // both entry points are driven, and a sequence number past the end.
    const from = if (smith.boolWeighted(1, 1)) built.image else built.bare;
    const seq = smith.index(3);

    const smf = openmiles.xmidiToSmf(testing.allocator, from, seq) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer testing.allocator.free(smf);
    try expectValidSmf(smf, from.len);

    if (openmiles.xmidiBareToSmf(testing.allocator, from)) |bare| {
        defer testing.allocator.free(bare);
        try expectValidSmf(bare, from.len);
    } else |err| switch (err) {
        error.OutOfMemory => return err,
        else => {},
    }

    // The time-signature reader is the other consumer of a converted file; it
    // must return a usable value for any track the converter emitted.
    if (openmiles.parseSmfTimeSigNumerator(smf) <= 0) return error.BadTimeSignature;

    // The container walkers parse the same bytes with a length-aware parser, so
    // cross-check their answers: every slice they report must lie in the image,
    // and an XDIR image must measure as the extent its outer size declared.
    if (openmiles.dls_container.findXmi(from)) |xmi| {
        try testing.expect(@intFromPtr(xmi.ptr) >= @intFromPtr(from.ptr));
        try testing.expect(@intFromPtr(xmi.ptr) + xmi.len <= @intFromPtr(from.ptr) + from.len);
    }
    const sized = openmiles.dls_container.xmiImageSize(from);
    try testing.expect(sized <= from.len);
    if (std.mem.eql(u8, from[0..4], "FORM") and std.mem.eql(u8, from[8..12], "XDIR")) {
        const declared = 8 + @as(usize, std.mem.readInt(u32, from[4..8], .big));
        if (declared <= from.len) try testing.expectEqual(declared, sized);
    }
}

/// Every SMF this converter produces must be a complete, self-consistent file:
/// a 14-byte MThd followed by one MTrk whose declared length is exactly the
/// rest of the buffer, ending in an end-of-track meta event. A conversion that
/// drops or miscounts a byte still opens in most players, so these are the
/// assertions that catch it; the input bound keeps a 4-byte EVNT from being
/// answered with a gigabyte of track.
fn expectValidSmf(smf: []const u8, input_len: usize) !void {
    try testing.expect(smf.len >= 22);
    try testing.expect(smf.len <= 22 + 16 * input_len);
    try testing.expectEqualStrings("MThd", smf[0..4]);
    try testing.expectEqual(@as(u32, 6), std.mem.readInt(u32, smf[4..8], .big));
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, smf[8..10], .big));
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, smf[10..12], .big));
    try testing.expectEqual(@as(u16, 120), std.mem.readInt(u16, smf[12..14], .big));
    try testing.expectEqualStrings("MTrk", smf[14..18]);
    try testing.expectEqual(@as(usize, smf.len - 22), std.mem.readInt(u32, smf[18..22], .big));
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x2F, 0x00 }, smf[smf.len - 4 ..]);
}

const evnt_seed = [12]u8{ 0x00, 0xFF, 0x51, 0x03, 0x0F, 0x42, 0x40, 0x60, 0x90, 0x3C, 0x64, 0x30 };
const xmidi_seed = "FORM" ++ "\x00\x00\x00\x2C" ++ "XDIR" ++
    "CAT " ++ "\x00\x00\x00\x24" ++ "XMID" ++
    "FORM" ++ "\x00\x00\x00\x18" ++ "XMID" ++
    "EVNT" ++ "\x00\x00\x00\x0C" ++ evnt_seed[0..];

const xmidi_corpus = [_][]const u8{
    // A complete XDIR/XMID image with a tempo meta event and one note-on.
    xmidi_seed,
    // The same image with a lying outer size and a zero-length CAT.
    "FORM" ++ "\xFF\xFF\xFF\xFF" ++ "XDIR" ++ "CAT " ++ "\x00\x00\x00\x00" ++ "XMID" ++ evnt_seed[0..],
    // Not XMIDI at all: a RIFF/DLS bank and a plain SMF, which is what the two
    // halves of a merged .mil file look like.
    "RIFF" ++ "\x10\x00\x00\x00" ++ "DLS " ++ "LIST" ++ "\x04\x00\x00\x00" ++ "INFO",
    "MThd" ++ "\x00\x00\x00\x06" ++ "\x00\x00\x00\x01\x00\x78" ++ "MTrk" ++ "\x00\x00\x00\x04" ++ "\x00\xFF\x2F\x00",
    // Truncated and empty images.
    xmidi_seed[0..16],
    xmidi_seed[0..12],
    "",
};

test "fuzz: XMIDI to SMF conversion" {
    var ctx: xmidi_ctx = .{};
    try std.testing.fuzz(&ctx, fuzzXmidiOne, .{ .corpus = &xmidi_corpus });
}

// --- Target 3: the SoundBank (BANK) image loader ----------------------------
//
// A .mbnk file arrives from the game's data directory, so the header, the four
// asset tables and every name/data offset in it are untrusted. fuzz_test.zig
// only proves the loader survives random bytes; this target builds banks whose
// *shape* is a real one (a header, four tables, a string/data pool) and then
// lies about individual fields, which is the mutation that reaches the offset
// arithmetic. Every accessor is then checked against the metadata it claims to
// have been copied out of.

const BankAssetKind = openmiles.soundbank.AssetKind;
const all_asset_kinds = [_]BankAssetKind{ .events, .environments, .presets, .sounds };

// Header field offsets of the 32-bit on-disk layout (soundbank.zig).
const bank_header_size: usize = 60;
const bank_entry_size: u32 = 8;

const bank_ctx = struct {
    img: [768]u8 = undefined,
    pool: [256]u8 = undefined,
    fname: [16]u8 = undefined,
};

const bank_name_weights: []const Weight = &.{
    w('a', 'z', 40), // asset names
    w('A', 'Z', 20), // case that the name index must fold
    w('0', '9', 10),
    w(' ', ' ', 5), // a name with embedded space, and an empty one
    w(0, 0, 10), // the terminator itself
};

/// A u32 the fuzzer may either keep honest or push somewhere the bounds checks
/// have to reject: inside the image, one past it, at zero (the "no name" and
/// "no table" sentinel), and at the top of the 32-bit range where the 32-bit
/// DLL target's `off + n > len` check would wrap.
fn bankOffset(smith: *std.testing.Smith, honest: u32, img_len: usize) u32 {
    return switch (smith.index(6)) {
        0 => honest,
        1 => @intCast(img_len),
        2 => @intCast(img_len + 1),
        3 => 0,
        4 => std.math.maxInt(u32),
        else => @intCast(honest +| @as(u32, @intCast(smith.index(64)))),
    };
}

fn fuzzSoundBankOne(ctx: *bank_ctx, smith: *std.testing.Smith) anyerror!void {
    @memset(&ctx.img, 0);
    @memset(&ctx.pool, 0);

    // A string/data pool the tables can legitimately point into.
    const name_count: usize = 1 + smith.index(6);
    var name_offs: [8]u32 = undefined;
    var data_offs: [8]u32 = undefined;
    var pool: usize = 0;
    for (0..name_count) |i| {
        const len: usize = smith.index(8); // 0 gives an empty name
        const n: usize = @intCast(smith.sliceWeighted(
            ctx.pool[pool..][0..len],
            &.{.{ .min = len, .max = len, .weight = 1 }},
            bank_name_weights,
        ));
        name_offs[i] = @intCast(pool);
        @memcpy(ctx.pool[pool..][0..n], ctx.pool[pool..][0..n]);
        pool += n;
        ctx.pool[pool] = 0;
        pool += 1;
        data_offs[i] = @intCast(pool);
        pool += len; // payload bytes follow, so a data offset is in bounds too
    }
    // The pool lives after the header and the tables.
    const table_bytes: usize = all_asset_kinds.len * 3 * bank_entry_size;
    const pool_at: usize = bank_header_size + table_bytes;
    @memcpy(ctx.img[pool_at..][0..pool], ctx.pool[0..pool]);
    const img_len: usize = pool_at + pool;

    // Four tables back to back, each with its own count and base.
    const table_off_at = [_]usize{ 20, 24, 28, 32 };
    const count_off_at = [_]usize{ 40, 44, 48, 52 };
    for (all_asset_kinds, 0..) |_, ki| {
        const count: u32 = @intCast(smith.index(4));
        const base: u32 = @intCast(bank_header_size + ki * 3 * bank_entry_size);
        std.mem.writeInt(u32, ctx.img[table_off_at[ki]..][0..4], bankOffset(smith, base, img_len), .little);
        std.mem.writeInt(u32, ctx.img[count_off_at[ki]..][0..4], count, .little);
        for (0..count) |e| {
            const at = bank_header_size + ki * 3 * bank_entry_size + e * bank_entry_size;
            std.mem.writeInt(u32, ctx.img[at..][0..4], bankOffset(smith, name_offs[smith.index(name_count)], img_len), .little);
            std.mem.writeInt(u32, ctx.img[at + 4 ..][0..4], bankOffset(smith, data_offs[smith.index(name_count)], img_len), .little);
        }
    }

    // The bank name is copied into a fixed 4-byte on-disk field; a name of any
    // length is legal input, and the filename length is what the sound-record
    // formatting must account for.
    const fname_len: usize = smith.index(ctx.fname.len);
    const fname_n: usize = @intCast(smith.sliceWeighted(
        ctx.fname[0..fname_len],
        &.{.{ .min = fname_len, .max = fname_len, .weight = 1 }},
        bank_name_weights,
    ));
    const fname = ctx.fname[0..fname_n];

    // meta_size decides how much is copied; a lie here either truncates the
    // image or claims more than was passed.
    const honest_meta: u32 = @intCast(img_len);
    const meta_size: u32 = switch (smith.index(5)) {
        0 => honest_meta,
        1 => bank_header_size,
        2 => honest_meta / 2,
        3 => honest_meta +| @as(u32, @intCast(1 + smith.index(4096))),
        else => @intCast(smith.index(80)), // below header_size: always rejected
    };
    std.mem.writeInt(u32, ctx.img[0..4], openmiles.soundbank.BANK_TAG, .little);
    std.mem.writeInt(i32, ctx.img[4..8], openmiles.soundbank.BANK_VERSION, .little);
    std.mem.writeInt(i32, ctx.img[8..12], @bitCast(meta_size), .little);
    @memcpy(ctx.img[56..60], "ABNK");

    const before = openmiles.soundbank.loadedCount();
    const bank = openmiles.soundbank.loadFromMemory(testing.allocator, fname, ctx.img[0..img_len]) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            // A rejected image must leave the container exactly as it was.
            try testing.expectEqual(before, openmiles.soundbank.loadedCount());
            return;
        },
    };
    try testing.expectEqual(before + 1, openmiles.soundbank.loadedCount());

    // The load copied exactly meta_size bytes plus the sentinel that keeps a
    // C-string consumer of a fixed-width field inside the allocation.
    try testing.expectEqual(@as(usize, @intCast(meta_size)) + 1, bank.meta.len);
    try testing.expectEqual(@as(u8, 0), bank.meta[bank.meta.len - 1]);
    try testing.expectEqual(meta_size, @as(u32, @bitCast(bank.metaSize())));
    // The 4-byte on-disk name field is handed out as a C string, so it must be
    // terminated within those 4 bytes whatever they contain.
    const bank_name = std.mem.span(bank.name());
    try testing.expect(bank_name.len <= 4);
    try testing.expectEqualStrings(bank_name, std.mem.sliceTo(ctx.img[56..][0..4], 0));

    for (all_asset_kinds) |kind| {
        const cnt = bank.assetCount(kind);
        const limit = @min(cnt, 24);
        var i: u32 = 0;
        while (i < limit) : (i += 1) {
            const name_ptr = bank.assetName(kind, i) orelse continue;
            try expectInBank(bank, name_ptr);
            const name = std.mem.span(name_ptr);
            // The same entry queried twice must answer twice the same way, or a
            // consumer that re-reads a bank mid-game sees it change underfoot.
            try testing.expectEqual(@intFromPtr(name_ptr), @intFromPtr(bank.assetName(kind, i).?));
            // A name the table reports must be resolvable by that same name,
            // and the data it hands back must live in the metadata.
            if (bank.assetData(kind, name)) |data| {
                try expectInBank(bank, data);
                try testing.expectEqual(@intFromPtr(data), @intFromPtr(bank.assetData(kind, name).?));
            }
            // The sound record is the one accessor that formats into a caller
            // buffer, so its declared size and its written string must agree.
            if (kind == .sounds) try expectSoundRecord(bank, name);
        }
        // Index past the declared count is out of range whatever the table says.
        try testing.expect(bank.assetName(kind, cnt) == null);
        try testing.expect(bank.assetName(kind, std.math.maxInt(u32)) == null);
    }

    bank.deinit();
    try testing.expectEqual(before, openmiles.soundbank.loadedCount());
}

fn expectInBank(bank: *const openmiles.soundbank.Bank, p: [*]const u8) !void {
    const lo = @intFromPtr(bank.meta.ptr);
    const addr = @intFromPtr(p);
    if (addr < lo or addr - lo >= bank.meta.len) return error.PointerOutsideMetadata;
}

/// `soundAssetInfo` returns the buffer size it needs, and `soundAssetFilename`
/// returns the record's DataLen. Both format "*" + bank filename + the sound's
/// own file name into a buffer the C API hands out with no size, so the number
/// it returns and the string it wrote have to be the same length, and the sound
/// record it copied out has to be the bytes at that offset. The write is made
/// into a buffer sized from the number the other entry point reported, which is
/// the contract a caller programs against: an accessors pair that under-reports
/// overruns it.
fn expectSoundRecord(bank: *const openmiles.soundbank.Bank, name: []const u8) !void {
    var info: [44]u8 = undefined;
    @memset(&info, 0xAA);
    // Ask for the requirement with no buffer attached, so the size is known
    // before anything is written through it.
    const req = bank.soundAssetInfo(name, null, null);
    if (req == 0) {
        var none: [1]u8 = undefined;
        try testing.expectEqual(@as(i32, 0), bank.soundAssetInfo(name, &none, null));
        try testing.expectEqual(@as(u8, 0), none[0]);
        return;
    }
    try testing.expect(req >= 2);
    const out = try testing.allocator.alloc(u8, @intCast(req));
    defer testing.allocator.free(out);
    @memset(out, 0xAA);
    const written_req = bank.soundAssetInfo(name, out.ptr, &info);
    try testing.expectEqual(req, written_req);
    const written = std.mem.span(@as([*:0]u8, @ptrCast(out.ptr)));
    try testing.expectEqual(@as(usize, @intCast(req)) - 1, written.len);
    try testing.expectEqual(@as(u8, '*'), written[0]);

    // data_off is where assetData resolved the record. Where the record is
    // long enough, the info copy and the duration must be exactly the bytes at
    // that offset; where it is truncated, the accessors must report the short
    // record without reaching past the metadata.
    const data = bank.assetData(.sounds, name) orelse return;
    const off = @intFromPtr(data) - @intFromPtr(bank.meta.ptr);
    if (bank.meta.len -| off >= 12 + info.len) {
        try testing.expectEqualSlices(u8, bank.meta[off + 12 ..][0..info.len], &info);
    }
    if (bank.meta.len -| off >= 40) {
        try testing.expectEqual(
            std.mem.readInt(u32, bank.meta[off + 24 ..][0..4], .little),
            bank.soundDurationMs(name).?,
        );
    }

    // soundAssetFilename writes the same string through the other entry point,
    // into the buffer the requirement was measured against.
    @memset(out, 0xAA);
    const dlen = bank.soundAssetFilename(name, out.ptr);
    if (dlen == -1) {
        try testing.expectEqual(@as(u8, 0), out[0]);
    } else {
        try testing.expectEqual(@as(u8, '*'), out[0]);
        try testing.expectEqual(@as(usize, @intCast(req)) - 1, std.mem.span(@as([*:0]u8, @ptrCast(out.ptr))).len);
    }
    // A sound that resolves has a duration; one that does not has none.
    try testing.expectEqual(bank.assetData(.sounds, name) != null, bank.soundDurationMs(name) != null);
}

// A loadable bank: header, one event entry, one sound entry, a 44-byte sound
// record, and the string pool they point at. Every seed below is a mutation
// of this one, so a fuzz run starts from an image the accessors actually
// answer for instead of from a header the loader rejects on the first field.
const seed_meta_size: u32 = 181;
fn makeBankSeed() [seed_meta_size]u8 {
    var s: [seed_meta_size]u8 = [_]u8{0} ** seed_meta_size;
    @memcpy(s[0..4], "BANK");
    std.mem.writeInt(i32, s[4..8], openmiles.soundbank.BANK_VERSION, .little);
    std.mem.writeInt(i32, s[8..12], @bitCast(seed_meta_size), .little);
    // Events table at the header, sounds table after it; environments and
    // presets left empty, which is the shape of a bank that ships one library.
    std.mem.writeInt(u32, s[20..24], bank_header_size, .little);
    std.mem.writeInt(u32, s[32..36], bank_header_size + bank_entry_size, .little);
    std.mem.writeInt(u32, s[40..44], 1, .little);
    std.mem.writeInt(u32, s[52..56], 1, .little);
    // Entry 0 (event "kick"): name and the event-step text after it.
    std.mem.writeInt(u32, s[60..64], 168, .little);
    std.mem.writeInt(u32, s[64..68], 178, .little);
    // Entry 1 (sound "KICK"): name and the sound record.
    std.mem.writeInt(u32, s[68..72], 173, .little);
    std.mem.writeInt(u32, s[72..76], 128, .little);
    // The sound record: FileNameOffset is relative to the record, and the
    // MILESBANKSOUNDINFO that soundAssetInfo copies verbatim follows at +12.
    std.mem.writeInt(u32, s[132..136], 40, .little);
    std.mem.writeInt(i32, s[140..144], 1, .little); // ChannelCount
    std.mem.writeInt(i32, s[152..156], 22050, .little); // Rate
    std.mem.writeInt(i32, s[156..160], 4096, .little); // DataLen
    std.mem.writeInt(u32, s[164..168], 1500, .little); // DurationMs
    // The pool: the sound's file name, the same name in another case, the
    // event's text.
    @memcpy(s[168..173], "kick\x00");
    @memcpy(s[173..178], "KICK\x00");
    @memcpy(s[178..181], "E0\x00");
    return s;
}

/// The same image with one header field replaced, which is how each malformed
/// seed below is derived from the loadable one.
fn withU32(img: [seed_meta_size]u8, at: usize, v: u32) [seed_meta_size]u8 {
    var s = img;
    std.mem.writeInt(u32, s[at..][0..4], v, .little);
    return s;
}
fn withI32(img: [seed_meta_size]u8, at: usize, v: i32) [seed_meta_size]u8 {
    var s = img;
    std.mem.writeInt(i32, s[at..][0..4], v, .little);
    return s;
}

const bank_seed_arr = makeBankSeed();
const bank_seed: []const u8 = &bank_seed_arr;
// The sound record's DataOffset pushed to the top of the 32-bit range, where
// the bounds checks have to reject it instead of wrapping into a small
// in-bounds offset.
const bank_seed_wrapping: []const u8 = &withU32(bank_seed_arr, 72, std.math.maxInt(u32));
// A meta_size that stops inside the tables.
const bank_seed_short_meta: []const u8 = &withI32(bank_seed_arr, 8, 61);
// A table count that overruns the metadata.
const bank_seed_overrun: []const u8 = &withU32(bank_seed_arr, 40, 0x10000);
// A sound name that resolves to a data offset past the end of the metadata.
const bank_seed_unterminated: []const u8 = &withU32(bank_seed_arr, 68, 173);

const bank_corpus = [_][]const u8{
    bank_seed,
    bank_seed_wrapping,
    bank_seed_short_meta,
    bank_seed_overrun,
    bank_seed_unterminated,
    // Not a bank at all: a RIFF image and a plain SMF, which is what a game
    // ships beside the .mbnk files.
    "RIFF" ++ "\x10\x00\x00\x00" ++ "DLS " ++ "LIST" ++ "\x04\x00\x00\x00" ++ "INFO",
    "MThd" ++ "\x00\x00\x00\x06" ++ "\x00\x00\x00\x01\x00\x78" ++ "MTrk" ++ "\x00\x00\x00\x04" ++ "\x00\xFF\x2F\x00",
    "",
};

test "fuzz: SoundBank image loader and asset queries" {
    var ctx: bank_ctx = .{};
    try std.testing.fuzz(&ctx, fuzzSoundBankOne, .{ .corpus = &bank_corpus });
}

// --- Target 4: the WAV container readers and file classification ------------
//
// `wavInfoBounded` walks attacker-declared chunk sizes and hands its caller a
// data pointer and a length that every downstream consumer (a decode, a copy, a
// sample count) then trusts, and `detectFileType` runs the same bytes through a
// second, independent classification. This target writes a well-formed IMA ADPCM
// WAV, reads it back with both, then corrupts it and reads it back again, so
// the two parsers are cross-checked against each other and against the bytes
// actually present.

const wav_ctx = struct {
    adpcm: [512]u8 = undefined,
    wav: [1024]u8 = undefined,
};

/// Bytes a WAV file is built from: the chunk ids and RIFF magic the readers
/// look for, plus the noise a truncated or mislabelled file carries between
/// them.
const wav_byte_weights: []const Weight = &.{
    w('R', 'W', 5), // "RIFF" / "WAVE"
    w('A', 'E', 5),
    w('f', 'm', 10), // "fmt ", "fact"
    w('d', 'd', 5), // "data"
    w('t', 't', 5),
    w(' ', ' ', 20), // the space in "fmt " and "data"
    w(0, 0xFF, 20), // chunk sizes, sample bytes, everything else
};

fn fuzzWavOne(ctx: *wav_ctx, smith: *std.testing.Smith) anyerror!void {
    // A block-aligned ADPCM payload: wrapAdpcmInWav copies these bytes through
    // untouched, so they are the untrusted half of the round trip.
    const adpcm_len: usize = smith.sliceWeighted(
        &ctx.adpcm,
        &.{.{ .min = 1, .max = ctx.adpcm.len, .weight = 1 }},
        wav_byte_weights,
    );
    const adpcm = ctx.adpcm[0..adpcm_len];
    // block_size must be above 4*channels or the encoder rejects it; the
    // rejection itself is part of the contract, so both outcomes are exercised.
    const channels: u16 = if (smith.boolWeighted(1, 1)) 1 else 2;
    const block_size: u32 = switch (smith.index(5)) {
        0 => if (channels == 1) 256 else 512,
        1 => 512,
        2 => 4 * @as(u32, channels), // the boundary the guard rejects
        3 => 0xFFFF, // the largest a WAV block-alignment field can hold
        else => 8 * @as(u32, channels) + @as(u32, @intCast(smith.index(2048))),
    };
    const rate: u32 = switch (smith.index(4)) {
        0 => 22050,
        1 => 11025,
        2 => 44100,
        else => smith.valueRangeAtMost(u32, 0, std.math.maxInt(u32)), // absurd: must saturate, never wrap
    };
    const total: u32 = @intCast(smith.index(4096));

    const wav = openmiles.wrapAdpcmInWav(testing.allocator, adpcm, block_size, channels, rate, total) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer testing.allocator.free(wav);
    try expectAdpcmRoundTrip(wav, adpcm.len, channels, rate, block_size, total);
    try expectClassification(wav);

    // Corrupt the file the way a bad download or a hostile pack would: flip a
    // few bytes, then cut it at an arbitrary point. The readers must still
    // report a data range that lies inside what they were handed.
    const flips: u32 = smith.valueRangeAtMost(u32, 0, 6);
    var f: u32 = 0;
    while (f < flips) : (f += 1) wav[smith.index(wav.len)] = smith.valueRangeAtMost(u8, 0, 255);
    try expectClassification(wav);
    const cut: usize = smith.index(wav.len);
    try expectBoundedInfo(wav.ptr, cut);
    try expectClassification(wav[0..cut]);

    // A buffer the readers never saw anything like: random chunk tags and
    // sizes, including a declared data length far past the end.
    const noise_len: usize = 12 + smith.index(600);
    const n: usize = @intCast(smith.sliceWeighted(
        ctx.wav[0..noise_len],
        &.{.{ .min = noise_len, .max = noise_len, .weight = 1 }},
        wav_byte_weights,
    ));
    const noise = ctx.wav[0..n];
    @memcpy(noise[0..4], "RIFF");
    @memcpy(noise[8..12], "WAVE");
    try expectBoundedInfo(noise.ptr, n);
    try expectClassification(noise);
}

/// Everything the writer put in the header has to come back out of the reader:
/// the two walk the same chunks independently, so a disagreement is a bug in
/// whichever one is wrong.
fn expectAdpcmRoundTrip(
    wav: []const u8,
    adpcm_len: usize,
    channels: u16,
    rate: u32,
    block_size: u32,
    total: u32,
) !void {
    var info: openmiles.AILSOUNDINFO = .{};
    try testing.expectEqual(@as(i32, 1), openmiles.wavInfoBounded(wav.ptr, wav.len, &info));
    try testing.expectEqual(@as(i32, 0x0011), info.format);
    try testing.expectEqual(@as(i32, 4), info.bits);
    try testing.expectEqual(@as(i32, channels), info.channels);
    try testing.expectEqual(rate, info.rate);
    try testing.expectEqual(block_size, info.block_size);
    try testing.expectEqual(@as(u32, @intCast(adpcm_len)), info.data_len);
    // The fact chunk carries the per-channel sample count the writer was given.
    try testing.expectEqual(total, info.samples);
    const lo = @intFromPtr(wav.ptr);
    const data = @intFromPtr(info.data_ptr.?);
    try testing.expect(data >= lo + 12);
    try testing.expect(data - lo + @as(usize, info.data_len) <= wav.len);
}

/// The clamp the reader exists for: a declared data length may never run past
/// the bytes the caller actually passed, and the pointer it reports must point
/// inside them.
fn expectBoundedInfo(raw: [*]const u8, len: usize) !void {
    if (len < 12) return;
    var info: openmiles.AILSOUNDINFO = .{};
    if (openmiles.wavInfoBounded(raw, len, &info) == 0) return;
    const lo = @intFromPtr(raw);
    const data = @intFromPtr(info.data_ptr orelse return);
    if (data < lo or data - lo > len) return error.DataPointerOutsideImage;
    try testing.expect(data - lo + @as(usize, info.data_len) <= len);
}

/// `detectFileType` must agree with the WAV reader it delegates to: an image the
/// reader accepts as IMA ADPCM classifies as ADPCM_WAV (2) or OTHER_WAV (3), and
/// an image it rejects never classifies as a WAV type at all.
fn expectClassification(img: []const u8) !void {
    if (img.len < 8) return;
    const kind = openmiles.detectFileType(@constCast(img.ptr), @intCast(img.len));
    var info: openmiles.AILSOUNDINFO = .{};
    const parsed = openmiles.wavInfoBounded(img.ptr, img.len, &info) != 0;
    if (!parsed) {
        // 1/2/3/15 are the WAV classifications; none may be claimed for an
        // image the chunk walk rejected.
        try testing.expect(kind != 1 and kind != 2 and kind != 3 and kind != 15);
        return;
    }
    switch (info.format) {
        1 => try testing.expectEqual(@as(i32, 1), kind),
        0x0011 => try testing.expect(kind == 2 or kind == 3),
        0x0069 => try testing.expect(kind == 15 or kind == 3),
        0x77 => try testing.expectEqual(@as(i32, 17), kind), // V12_VOICE
        0x74 => try testing.expectEqual(@as(i32, 18), kind), // V24_VOICE
        0x75 => try testing.expectEqual(@as(i32, 19), kind), // V29_VOICE
        // Every other format tag is OTHER_WAV, unless it is an MPEG-wrapped
        // WAV, which falls through to the MPEG scan and reports an audio type.
        else => try testing.expect(kind == 3 or kind == 0 or kind > 19),
    }
}

const adpcm_seed = [_]u8{ 0x11, 0x22, 0x33, 0x44 } ++ [_]u8{0x55} ** 60;
const adpcm_wav_seed = "RIFF" ++ "\x4A\x00\x00\x00" ++ "WAVE" ++
    "fmt " ++ "\x28\x00\x00\x00" ++ "\x11\x00\x01\x00" ++ "\x22\x56\x00\x00" ++
    "\x00\x2C\x00\x00" ++ "\x00\x01\x04\x00" ++ "\x02\x00" ++
    "fact" ++ "\x04\x00\x00\x00" ++ "\x40\x00\x00\x00" ++
    "data" ++ "\x40\x00\x00\x00" ++ adpcm_seed[0..];

const wav_corpus = [_][]const u8{
    // A complete IMA ADPCM WAV: the shape the wrapper produces and the reader
    // has to agree on field for field.
    adpcm_wav_seed,
    // The same file with a lying RIFF size and a data chunk running past the end.
    adpcm_wav_seed[0..40] ++ "\xFF\xFF\xFF\xFF" ++ adpcm_seed[0..],
    // A plain PCM WAV, and an extensible one whose subformat is not PCM.
    "RIFF" ++ "\x2C\x00\x00\x00" ++ "WAVE" ++ "fmt " ++ "\x10\x00\x00\x00" ++
        "\x01\x00\x02\x00" ++ "\x44\xAC\x00\x00" ++ "\x88\x58\x01\x00" ++
        "\x04\x00\x10\x00" ++ "data" ++ "\x00\x00\x00\x00",
    "RIFF" ++ "\x64\x00\x00\x00" ++ "WAVE" ++ "fmt " ++ "\x28\x00\x00\x00" ++
        "\xFE\xFF\x02\x00" ++ "\x44\xAC\x00\x00" ++ "\x88\x58\x01\x00" ++ "\x04\x00\x10\x00" ++
        "\x16\x00\x00\x00" ++ "\x03\x00\x00\x00" ++ "\x00\x00\x10\x00\x80\x00\x00\xAA\x00\x38\x9B\x71" ++
        "data" ++ "\x00\x00\x00\x00",
    // Not a WAV at all: the container magics the classifier knows.
    "FORM" ++ "\x10\x00\x00\x00" ++ "XDIR" ++ "CAT " ++ "\x04\x00\x00\x00" ++ "XMID",
    "OggS" ++ "\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00" ++ "Speex   " ++ "Speex   " ++ "1.2rc1",
    "RIFF" ++ "\x10\x00\x00\x00" ++ "DLS ",
    "MThd" ++ "\x00\x00\x00\x06" ++ "\x00\x00\x00\x01\x00\x78" ++ "MTrk" ++ "\x00\x00\x00\x04" ++ "\x00\xFF\x2F\x00",
    // Truncated headers and empty input.
    adpcm_wav_seed[0..12],
    adpcm_wav_seed[0..4],
    "",
};

test "fuzz: WAV container round trip and file classification" {
    var ctx: wav_ctx = .{};
    try std.testing.fuzz(&ctx, fuzzWavOne, .{ .corpus = &wav_corpus });
}

// --- Target 5: the WAV cue-point ("marker") API -----------------------------
//
// AIL_WAV_marker_count / _by_index / _by_name take a bare `wav_image` pointer
// with no length and resolve a marker by walking a 'cue ' chunk of fixed-size
// records and a LIST/adtl chunk holding one 'labl' chunk per cue id. Four
// file-supplied lengths feed the one pointer they hand back: the RIFF size, the
// chunk sizes, the cue count, and the labl body that has to contain a NUL
// before the label is readable. Nothing in the fuzz suite reached this API
// before (the PRNG suite only ever passes a null image), so this target builds
// the chunk tree, lets the fuzzer lie about each declared size, and checks the
// three entry points against each other rather than only for the absence of a
// crash.

const marker_ctx = struct {
    img: [1536]u8 = undefined,
    labels: [4][24]u8 = undefined,
};

/// Marker names are built from this alphabet, and the "no such marker" probe
/// below uses a byte outside it, so a name the harness invents can never be
/// confused with one the image carries.
const marker_name_weights: []const Weight = &.{
    w('a', 'z', 40),
    w('0', '9', 10),
    w(' ', ' ', 5),
    w('-', '_', 5),
};

const no_such_marker = "~no-such-marker~";

/// Cursor over the image being built, so a chunk is written as "id, declared
/// size, body" in one place and the honest size is never recomputed by hand.
const ChunkWriter = struct {
    buf: []u8,
    at: usize = 0,
    body_at: usize = 0,
    body_len: usize = 0,

    fn begin(self: *ChunkWriter, id: *const [4]u8, body_len: usize, declared: u32) void {
        @memcpy(self.buf[self.at..][0..4], id);
        std.mem.writeInt(u32, self.buf[self.at + 4 ..][0..4], declared, .little);
        self.at += 8;
        self.body_at = self.at;
        self.body_len = body_len;
    }

    /// Close the chunk: word-align the body, pad an odd one, leave the cursor
    /// one past the chunk. The pad byte is what an off-by-one reads a tag out
    /// of, so it is written rather than left undefined.
    fn end(self: *ChunkWriter) void {
        if (self.body_len & 1 != 0) self.buf[self.body_at + self.body_len] = 0;
        self.at = self.body_at + self.body_len + (self.body_len & 1);
    }

    fn put32(self: *ChunkWriter, v: u32) void {
        std.mem.writeInt(u32, self.buf[self.at..][0..4], v, .little);
        self.at += 4;
    }
};

/// Lay out one RIFF/WAVE image carrying a 'cue ' chunk and a LIST/adtl chunk of
/// 'labl' chunks. The fuzzer decides how many of each there are, which cue ids
/// are used, whether a label is NUL-terminated, and which of the four declared
/// sizes lie.
fn buildMarkerImage(ctx: *marker_ctx, smith: *std.testing.Smith, labels_terminated: bool) []u8 {
    @memset(&ctx.img, 0);
    @memcpy(ctx.img[0..4], "RIFF");
    @memcpy(ctx.img[8..12], "WAVE");
    var cw: ChunkWriter = .{ .buf = ctx.img[0..], .at = 12 };

    // A minimal PCM fmt chunk, so the image is a WAV a tagger would produce
    // rather than a container that happens to carry a cue list.
    cw.begin("fmt ", 16, 16);
    cw.put32(1); // PCM
    cw.put32(1); // mono
    cw.put32(22050); // rate
    cw.put32(22050 * 2); // byte rate
    cw.put32(2); // block align
    cw.put32(16); // bits
    cw.end();

    const cue_count: usize = smith.index(4);
    cw.begin("cue ", 4 + cue_count * 24, declaredSize(smith, 4 + cue_count * 24));
    // The count is the field the record loop trusts, so it gets its own lie:
    // more records than the chunk holds, fewer than it does, or a value large
    // enough to wrap the record offset on the 32-bit target.
    const declared_cue: u32 = switch (smith.index(5)) {
        0 => @intCast(cue_count),
        1 => 0,
        2 => @intCast(cue_count + 1),
        3 => std.math.maxInt(u32),
        else => @intCast(smith.index(16)),
    };
    cw.put32(declared_cue);
    var cue_ids: [4]u32 = undefined;
    for (0..cue_count) |i| {
        cue_ids[i] = if (smith.boolWeighted(3, 1)) @as(u32, @intCast(smith.index(8))) else @intCast(i);
        cw.put32(cue_ids[i]);
        cw.put32(0); // dwPosition
        cw.put32(0); // fccChunk: "data"
        cw.put32(0); // dwChunkStart
        cw.put32(0); // dwBlockStart
        cw.put32(smith.valueRangeAtMost(u32, 0, 1 << 24)); // dwSampleOffset
    }
    cw.end();

    // LIST <size> "adtl" { "labl" <size> <cue id> <name> ... }
    // The label lengths come first so the LIST size can be the honest total of
    // the chunks that follow, padding included: a LIST that stops one byte
    // short of its own last label is the off-by-one the walk must not have.
    const labl_count: usize = smith.index(4);
    var name_lens: [4]usize = undefined;
    var labl_total: usize = 4; // "adtl"
    for (0..labl_count) |i| {
        name_lens[i] = smith.index(ctx.labels[i].len);
        const body = 4 + name_lens[i];
        labl_total += 8 + body + (body & 1);
    }
    cw.begin("LIST", labl_total, declaredSize(smith, labl_total));
    @memcpy(ctx.img[cw.at..][0..4], if (smith.boolWeighted(4, 1)) "adtl" else "INFO");
    cw.at += 4;
    var labl_ids: [4]u32 = undefined;
    for (0..labl_count) |i| {
        const n = name_lens[i];
        // Half the time the label is a cue id already in the list (a lookup
        // resolves), half the time one that is not, or a repeat of an earlier
        // label (the first match has to win).
        labl_ids[i] = switch (smith.index(4)) {
            0 => @intCast(smith.index(8)),
            1 => if (cue_count == 0) 0 else cue_ids[smith.index(cue_count)],
            2 => if (i == 0) 0 else labl_ids[0],
            else => @intCast(smith.index(64)),
        };
        const body = 4 + n;
        cw.begin("labl", body, declaredSize(smith, body));
        cw.put32(labl_ids[i]);
        const n_written: usize = @intCast(smith.sliceWeighted(
            ctx.labels[i][0..n],
            &.{.{ .min = n, .max = n, .weight = 1 }},
            marker_name_weights,
        ));
        for (ctx.labels[i][0..n_written], 0..) |*dst, k| {
            dst.* = if (labels_terminated) ctx.labels[i][k] else 'a' + @as(u8, @truncate(smith.index(26)));
        }
        cw.at += n;
        cw.end();
    }
    cw.end();

    // A data chunk after the marker chunks: a real file has one, and it is
    // what the walk reaches when a declared size is short.
    const data_len: usize = smith.index(64);
    cw.begin("data", data_len, declaredSize(smith, data_len));
    for (0..data_len) |i| ctx.img[cw.at + i] = @truncate(smith.index(256));
    cw.at += data_len;
    cw.end();

    const len = cw.at;
    // The top-level RIFF size stays honest: the marker API is handed a whole
    // image and reads exactly riff_size + 8 bytes, so a lying value there is a
    // truncated file the length-less signature cannot detect, not a parser
    // bug. The lie belongs in the nested chunk sizes above.
    std.mem.writeInt(u32, ctx.img[4..8], @intCast(len - 8), .little);
    return ctx.img[0..len];
}

fn fuzzWavMarkersOne(ctx: *marker_ctx, smith: *std.testing.Smith) anyerror!void {
    const img = buildMarkerImage(ctx, smith, true);
    const exact = try testing.allocator.dupe(u8, img);
    defer testing.allocator.free(exact);
    try expectMarkers(exact);

    // The same image with a handful of bytes flipped: the chunk ids, the cue
    // ids and the label bodies are the fields a truncated or rewritten download
    // leaves behind, and a reader that trusts a stale offset has to reject them.
    const flips: u32 = smith.valueRangeAtMost(u32, 0, 5);
    var f: u32 = 0;
    while (f < flips) : (f += 1) exact[smith.index(exact.len)] = smith.valueRangeAtMost(u8, 0, 255);
    try expectMarkers(exact);

    // Labels with no NUL anywhere in their chunk: cueLabel requires the
    // terminator, so the lookup has to miss rather than hand out a string that
    // runs into the following chunk.
    const unterminated = buildMarkerImage(ctx, smith, false);
    const exact_unterminated = try testing.allocator.dupe(u8, unterminated);
    defer testing.allocator.free(exact_unterminated);
    try expectMarkers(exact_unterminated);
}

/// The three marker entry points are one contract seen from three sides: the
/// count is what the 'cue ' chunk holds, every index below it answers, every
/// name the index form hands out points inside the image and is NUL-terminated
/// there, and the by-name form answers the offset of the first cue carrying
/// that name. A disagreement between any two is a bug in whichever one is
/// wrong.
fn expectMarkers(img: []const u8) !void {
    if (img.len < 12) return;
    const lo = @intFromPtr(img.ptr);
    const hi = lo + img.len;
    const raw: *const anyopaque = img.ptr;

    const count = api_v8.AIL_WAV_marker_count(raw);
    try testing.expect(count >= 0);
    if (count == 0) {
        try testing.expectEqual(@as(i32, -1), api_v8.AIL_WAV_marker_by_index(raw, 0, null));
        return;
    }
    // At, past, and far past the declared count, and a negative index: out of
    // range whatever the file claims.
    try testing.expectEqual(@as(i32, -1), api_v8.AIL_WAV_marker_by_index(raw, count, null));
    try testing.expectEqual(@as(i32, -1), api_v8.AIL_WAV_marker_by_index(raw, std.math.maxInt(i32), null));
    try testing.expectEqual(@as(i32, -1), api_v8.AIL_WAV_marker_by_index(raw, -1, null));

    const limit: i32 = @intCast(@min(count, 24));
    var offs: [24]i32 = undefined;
    var labels: [24]?[*:0]const u8 = undefined;
    var i: i32 = 0;
    var answered: usize = 0;
    while (i < limit) : (i += 1) {
        var name: ?[*:0]const u8 = null;
        const off = api_v8.AIL_WAV_marker_by_index(raw, i, &name);
        // The count is capped by the records the cue chunk carries, so an
        // index below it that does not answer is a bug, not a short image.
        if (off < 0) return error.MarkerBelowCountMissing;
        offs[@intCast(i)] = off;
        labels[@intCast(i)] = name;
        answered += 1;
        if (name) |p| {
            try testing.expect(@intFromPtr(p) >= lo and @intFromPtr(p) < hi);
            const label = std.mem.span(p); // the NUL has to be inside the image
            try testing.expect(label.len < img.len);
        }
    }

    for (0..answered) |idx| {
        const p = labels[idx] orelse continue;
        // by-name answers the first cue carrying this name, which is this
        // marker's offset or an earlier one's, so compare against the first
        // index whose label matches rather than against this index alone.
        const want = blk: {
            for (0..idx + 1) |j| {
                const q = labels[j] orelse continue;
                if (std.mem.eql(u8, std.mem.span(q), std.mem.span(p))) break :blk offs[j];
            }
            continue;
        };
        try testing.expectEqual(want, api_v8.AIL_WAV_marker_by_name(raw, @ptrCast(p)));
    }
    // A name the image cannot carry, and no name at all, resolve to nothing.
    try testing.expectEqual(@as(i32, -1), api_v8.AIL_WAV_marker_by_name(raw, no_such_marker));
    try testing.expectEqual(@as(i32, -1), api_v8.AIL_WAV_marker_by_name(raw, null));
    // The name out-parameter of the index form is a request for a pointer, not
    // for a string: an index that resolves with no label must leave it null
    // rather than hand back an uninitialized pointer.
    var unset: ?[*:0]const u8 = @ptrCast(&no_such_marker);
    if (api_v8.AIL_WAV_marker_by_index(raw, 0, &unset) >= 0) {
        if (unset) |p| try testing.expect(@intFromPtr(p) >= lo and @intFromPtr(p) < hi);
    }
}

/// One tagged WAV with two cue points and the adtl list that names them, built
/// at comptime so the malformed seeds below can replace a field by offset
/// instead of being cut out of a string literal at a guessed index.
const marker_seed_bytes: usize = 192;
const marker_seed_layout = blk: {
    const Seed = struct { bytes: [marker_seed_bytes]u8, len: usize, cue_count: usize, list_type: usize, labl1_body: usize, labl1_size: usize, labl2_size: usize, data_size: usize };
    var s: [marker_seed_bytes]u8 = [_]u8{0} ** marker_seed_bytes;
    var cw: ChunkWriter = .{ .buf = s[0..] };
    @memcpy(s[0..4], "RIFF");
    @memcpy(s[8..12], "WAVE");
    cw.at = 12;
    cw.begin("fmt ", 16, 16);
    cw.put32(1);
    cw.put32(1);
    cw.put32(22050);
    cw.put32(22050 * 2);
    cw.put32(2);
    cw.put32(16);
    cw.end();
    cw.begin("cue ", 4 + 2 * 24, 4 + 2 * 24);
    const cue_count = cw.at;
    cw.put32(2);
    for ([_]u32{ 1, 2 }, 0..) |id, i| {
        cw.put32(id);
        cw.put32(0);
        cw.put32(0);
        cw.put32(0);
        cw.put32(0);
        cw.put32(if (i == 0) 0 else 22050);
    }
    cw.end();
    cw.begin("LIST", 4 + 2 * (8 + 10), 4 + 2 * (8 + 10));
    const list_type = cw.at;
    @memcpy(s[cw.at..][0..4], "adtl");
    cw.at += 4;
    cw.begin("labl", 9, 9);
    cw.put32(1);
    const labl1_body = cw.at;
    @memcpy(s[cw.at..][0..5], "mark\x00");
    cw.at += 5;
    cw.end();
    cw.begin("labl", 9, 9);
    cw.put32(2);
    @memcpy(s[cw.at..][0..5], "ends\x00");
    cw.at += 5;
    cw.end();
    cw.end();
    cw.begin("data", 4, 4);
    cw.put32(0);
    cw.end();
    std.mem.writeInt(u32, s[4..8], @intCast(cw.at - 8), .little);
    break :blk Seed{
        .bytes = s,
        .len = cw.at,
        .cue_count = cue_count,
        .list_type = list_type,
        .labl1_body = labl1_body,
        .labl1_size = labl1_body - 4,
        .labl2_size = labl1_body + 4 + 8,
        .data_size = cw.at - 4,
    };
};

const marker_seed_arr = marker_seed_layout.bytes;
const marker_seed: []const u8 = marker_seed_arr[0..marker_seed_layout.len];

/// The same image with one field replaced, which is how each malformed seed
/// below is derived from the loadable one. The image is returned by value, so
/// a caller's `&` at comptime names a constant with static storage.
fn markerWithU32(at: usize, v: u32) [marker_seed_bytes]u8 {
    var s = marker_seed_arr;
    std.mem.writeInt(u32, s[at..][0..4], v, .little);
    return s;
}

fn markerWithBytes(at: usize, bytes: []const u8) [marker_seed_bytes]u8 {
    var s = marker_seed_arr;
    @memcpy(s[at..][0..bytes.len], bytes);
    return s;
}

const marker_corpus = [_][]const u8{
    marker_seed,
    // A cue count larger than the records the chunk holds.
    &markerWithU32(marker_seed_layout.cue_count, 0xFFFF),
    // A labl body with no NUL in it, and the same chunk with the size field
    // pushed past the image.
    &markerWithBytes(marker_seed_layout.labl1_body, "mark!"),
    &markerWithU32(marker_seed_layout.labl1_size, std.math.maxInt(u32)),
    &markerWithU32(marker_seed_layout.labl2_size, 0),
    // A LIST that is not an adtl list, and a data chunk running past the end.
    &markerWithBytes(marker_seed_layout.list_type, "INFO"),
    &markerWithU32(marker_seed_layout.data_size, std.math.maxInt(u32)),
    // The RIFF/DLS, RIFF/RMID and RIFF/XMID shapes a bank ships beside a WAV:
    // the chunk walk has to pass them without finding a cue list.
    "RIFF" ++ "\x10\x00\x00\x00" ++ "DLS ",
    "RIFF" ++ "\x10\x00\x00\x00" ++ "RMID",
    "RIFF" ++ "\x10\x00\x00\x00" ++ "XMID",
    // A WAV header with nothing after it, a cue chunk with no records, an
    // image cut inside its cue chunk, and an empty image.
    "RIFF" ++ "\x04\x00\x00\x00" ++ "WAVE",
    "RIFF" ++ "\x10\x00\x00\x00" ++ "WAVE" ++ "cue " ++ "\x04\x00\x00\x00" ++ "\x00\x00\x00\x00",
    marker_seed[0..48],
    "",
};

test "fuzz: WAV cue-point marker lookup" {
    var ctx: marker_ctx = .{};
    try std.testing.fuzz(&ctx, fuzzWavMarkersOne, .{ .corpus = &marker_corpus });
}

// The corpus and the builder above are only worth anything if a well-formed
// tagged WAV actually resolves, so the seed image is pinned here: a fuzz target
// whose shapes never reach the interesting branch would pass on anything.
test "WAV marker API resolves a well-formed tagged WAV" {
    const raw: *const anyopaque = marker_seed.ptr;
    try testing.expectEqual(@as(i32, 2), api_v8.AIL_WAV_marker_count(raw));

    var first: ?[*:0]const u8 = null;
    try testing.expectEqual(@as(i32, 0), api_v8.AIL_WAV_marker_by_index(raw, 0, &first));
    try testing.expectEqualStrings("mark", std.mem.span(first.?));
    var second: ?[*:0]const u8 = null;
    try testing.expectEqual(@as(i32, 22050), api_v8.AIL_WAV_marker_by_index(raw, 1, &second));
    try testing.expectEqualStrings("ends", std.mem.span(second.?));

    try testing.expectEqual(@as(i32, 0), api_v8.AIL_WAV_marker_by_name(raw, "mark"));
    try testing.expectEqual(@as(i32, 22050), api_v8.AIL_WAV_marker_by_name(raw, "ends"));
    try testing.expectEqual(@as(i32, -1), api_v8.AIL_WAV_marker_by_name(raw, "missing"));

    // The same image with the cue count raised past the records the chunk
    // holds: the count is capped at what the chunk carries, the two real
    // records still resolve, and the rest report -1 rather than being read out
    // of the chunks that follow the cue chunk.
    const overrun = markerWithU32(marker_seed_layout.cue_count, 99);
    try testing.expectEqual(@as(i32, 2), api_v8.AIL_WAV_marker_count(overrun[0..].ptr));
    try testing.expectEqual(@as(i32, 22050), api_v8.AIL_WAV_marker_by_index(overrun[0..].ptr, 1, null));
    try testing.expectEqual(@as(i32, -1), api_v8.AIL_WAV_marker_by_index(overrun[0..].ptr, 2, null));

    // A labl body with no NUL: the label is not readable, so the lookup misses
    // rather than handing out a string that runs into the next chunk.
    const unterminated = markerWithBytes(marker_seed_layout.labl1_body, "mark!");
    var unterminated_name: ?[*:0]const u8 = @ptrCast(&no_such_marker);
    try testing.expectEqual(@as(i32, 0), api_v8.AIL_WAV_marker_by_index(unterminated[0..].ptr, 0, &unterminated_name));
    try testing.expect(unterminated_name == null);
    try testing.expectEqual(@as(i32, -1), api_v8.AIL_WAV_marker_by_name(unterminated[0..].ptr, "mark"));
}

// --- Target 6: the Miles 9.x event enqueue ----------------------------------
//
// An event string reaches the enqueue path from a game's data: a soundbank
// event resolved by name, or a text handed straight to MilesEnqueueEvent. The
// decoder itself is Target 1, but enqueue is where a decoded step turns into
// state the rest of the library owns: one tracked SoundInstance per start_sound
// (with the names and labels copied onto the global allocator), names added to
// and removed from the cache set, presets added to the persist set, and the
// per-label caps evicting instances. fuzz_test.zig fuzzes the caps and the
// label grammar through MilesStartSoundInstance; this target drives the same
// state from the parse side, and pairs the two entry points that must agree on
// it (the decode walk against the instance list, the enumeration against
// pause/stop, the persist list against the reported PersistCount).
//
// The choices come from a PRNG seeded by the input rather than from Smith
// draws: one weighted slice consumes the rest of the seed, so a target that
// draws many fields would see the stream run dry after the first and run the
// same minimal event every time. Hashing the whole seed instead of reading a
// draw from it also keeps two seeds that share a prefix apart.

const miles_ctx = struct {
    text: [1025]u8 = undefined,
    name: [25]u8 = undefined,
    other: [33]u8 = undefined,
    labels: [25]u8 = undefined,
    // The label list of the last start_sound step, kept apart from `labels` so
    // the query below can be the one a caller would write for this event.
    last_labels: [25]u8 = undefined,
};

const Range = struct { min: u8, max: u8, weight: u64 };

/// A sound reference, bank name or preset name: what the format allows inside
/// a field, which is any byte that is not the ';' separator or the NUL.
const miles_name_ranges = [_]Range{
    .{ .min = 'a', .max = 'z', .weight = 40 },
    .{ .min = 'A', .max = 'Z', .weight = 20 },
    .{ .min = '0', .max = '9', .weight = 20 },
    .{ .min = '_', .max = '_', .weight = 10 },
    .{ .min = '-', .max = '-', .weight = 5 },
    .{ .min = '.', .max = '.', .weight = 5 },
    .{ .min = '/', .max = '/', .weight = 5 },
    .{ .min = '*', .max = '?', .weight = 5 },
    .{ .min = 0x80, .max = 0xFF, .weight = 5 },
};

/// A label list: the label names, the ',' and ' ' the tokenizer splits on, and
/// the '*' / '?' globs a query is written with.
const miles_label_ranges = [_]Range{
    .{ .min = 'a', .max = 'z', .weight = 40 },
    .{ .min = 'A', .max = 'Z', .weight = 20 },
    .{ .min = ',', .max = ',', .weight = 20 },
    .{ .min = ' ', .max = ' ', .weight = 20 },
    .{ .min = '0', .max = '9', .weight = 10 },
    .{ .min = '*', .max = '?', .weight = 5 },
    .{ .min = 0x80, .max = 0xFF, .weight = 5 },
};

fn randFromRanges(rand: std.Random, comptime ranges: []const Range) u8 {
    comptime var total: u64 = 0;
    inline for (ranges) |r| total += r.weight;
    var pick = rand.intRangeAtMost(u64, 0, total - 1);
    inline for (ranges) |r| {
        if (pick < r.weight) return rand.intRangeAtMost(u8, r.min, r.max);
        pick -= r.weight;
    }
    unreachable;
}

/// The step an event is built from, weighted towards the ones the enqueue acts
/// on: a start_sound step creates an instance, cache/purge and persist steps
/// move the two sets the counts are read from, and the rest only have to be
/// walked over.
fn randStepKind(rand: std.Random) u8 {
    return switch (rand.intRangeAtMost(u8, 0, 19)) {
        0...7 => 0, // start_sound
        8, 9 => 1, // cache_sounds
        10, 11 => 2, // purge_sounds
        12, 13 => 3, // persist
        14 => 4, // set_limits
        15 => 5, // comment
        else => 6, // version
    };
}

/// A NUL-terminated field of 0..`buf.len - 1` bytes, empty included (an empty
/// sound name is a shape the event VM writes for an unset field).
fn randMilesField(rand: std.Random, buf: []u8, comptime ranges: []const Range) [:0]const u8 {
    const n = rand.intRangeAtMost(usize, 0, buf.len - 1);
    for (buf[0..n]) |*b| b.* = randFromRanges(rand, ranges);
    buf[n] = 0;
    return buf[0..n :0];
}

/// A ':'-separated cache/purge name list, which the decoder splits into a
/// pointer array carved out of its scratch. Names are kept short so three of
/// them still fit the field with room for the separators.
fn randMilesNameList(rand: std.Random, buf: []u8) [:0]const u8 {
    var scratch: [8]u8 = undefined;
    var used: usize = 0;
    const parts = rand.intRangeAtMost(usize, 1, 3);
    for (0..parts) |p| {
        if (used + scratch.len >= buf.len) break;
        if (p > 0) {
            buf[used] = ':';
            used += 1;
        }
        const name = randMilesField(rand, &scratch, &miles_name_ranges);
        @memcpy(buf[used..][0..name.len], name);
        used += name.len;
    }
    buf[used] = 0;
    return buf[0..used :0];
}

/// How many start_sound steps the public step decoder reads out of `text`. The
/// enqueue path runs the same decoder with the same 512-byte scratch, so this
/// is the number of instances the event asked for before any cap evicted some.
fn countStartSteps(text: []const u8) usize {
    var scratch: [512]u8 align(8) = undefined;
    var p: [*:0]const u8 = @ptrCast(@constCast(text.ptr));
    var starts: usize = 0;
    var guard: usize = 0;
    while (guard < 256) : (guard += 1) {
        var step_out: ?*openmiles.event.EVENT_STEP_INFO = null;
        const next = api_v8.AIL_next_event_step(@ptrCast(p), &step_out, &scratch, scratch.len) orelse break;
        if (step_out.?.type == @intFromEnum(openmiles.event.StepType.start_sound)) starts += 1;
        p = @ptrCast(next);
    }
    return starts;
}

/// The event string is handed over as a malloc'd copy and the library is asked
/// to own it (FREE_EVENT), so the parse and the free are one boundary: a
/// length that disagrees with the allocation is a heap overflow, and a queue
/// that still points into the buffer after the free is a use-after-free.
fn enqueueOwned(text: []const u8, user_buffer_len: i32) u64 {
    const buf: [*]u8 = @ptrCast(std.c.malloc(text.len + 1) orelse return 0);
    @memcpy(buf[0..text.len], text);
    buf[text.len] = 0;
    return api_miles.MilesEnqueueEvent(buf, null, user_buffer_len, 0x2, 0);
}

const InstanceView = struct {
    instance_id: u64,
    queued_id: u64,
    status: i32,
    sound: []const u8,
};

/// Every instance the enumeration reports, with the fields a caller reads back.
fn collectInstances(views: []InstanceView) usize {
    var next: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize)); // MSS_FIRST
    var info: api_miles.MILESEVENTSOUNDINFO = undefined;
    var n: usize = 0;
    while (api_miles.MilesEnumerateSoundInstances(null, &next, 0, null, 0, @ptrCast(&info)) != 0) {
        if (n == views.len) return n;
        views[n] = .{
            .instance_id = info.InstanceID,
            .queued_id = info.QueuedID,
            .status = info.Status,
            .sound = std.mem.span(info.UsedSound.?),
        };
        n += 1;
    }
    return n;
}

fn countInstancesMatching(query: ?[*:0]const u8) u64 {
    var next: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
    var info: api_miles.MILESEVENTSOUNDINFO = undefined;
    var n: u64 = 0;
    while (api_miles.MilesEnumerateSoundInstances(null, &next, 0, query, 0, @ptrCast(&info)) != 0) n += 1;
    return n;
}

fn countPersists() u64 {
    var next: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
    var name: ?[*:0]const u8 = null;
    var n: u64 = 0;
    while (api_miles.MilesEnumeratePresetPersists(null, &next, &name) != 0) {
        _ = std.mem.span(name.?);
        n += 1;
    }
    return n;
}

fn milesState() api_miles.MILESEVENTSTATE {
    var st: api_miles.MILESEVENTSTATE = undefined;
    api_miles.MilesGetEventSystemState(null, &st);
    return st;
}

fn fuzzMilesEnqueueOne(ctx: *miles_ctx, smith: *std.testing.Smith) anyerror!void {
    // Outside a fuzzing build the whole seed is available; under the fuzzer
    // `in` is null and the draw below is the fuzzer's, so a mutated input
    // still reaches every decision below.
    const seed: u64 = if (smith.in) |bytes|
        std.hash.Wyhash.hash(0, bytes)
    else
        smith.value(u64);
    var prng = std.Random.DefaultPrng.init(seed);
    const rand = prng.random();

    api_miles.MilesClearEventQueue();
    defer {
        api_miles.MilesClearEventQueue();
        _ = api_miles.MilesSetSoundLabelLimits(null, "");
    }
    // Caps first, so an event whose start_sound steps carry a capped label runs
    // the eviction the label limits drive.
    _ = api_miles.MilesSetSoundLabelLimits(null, randMilesField(rand, &ctx.other, &miles_label_ranges).ptr);

    // The event is built by the shipped constructor, so the fuzzer picks the
    // field *values* (which names, labels, name lists and cap strings the event
    // names) while the step layout stays one the encoder really writes. The
    // layout is Target 1's job; what is unproven here is what the enqueue does
    // with a step it decodes.
    const ev = openmiles.event.EventConstruct.create(testing.allocator) orelse return error.NoEvent;
    const steps = rand.intRangeAtMost(usize, 1, 3);
    for (0..steps) |_| {
        switch (randStepKind(rand)) {
            0 => {
                const name = randMilesField(rand, &ctx.name, &miles_name_ranges);
                const labels = randMilesField(rand, &ctx.labels, &miles_label_ranges);
                @memcpy(ctx.last_labels[0..labels.len], labels);
                ctx.last_labels[labels.len] = 0;
                _ = ev.addStartSound(.{
                    .soundname = name.ptr,
                    .presetname = null,
                    .presetisdynamic = 0,
                    .eventname = null,
                    .markerstart = null,
                    .markerend = null,
                    .statevar = null,
                    .varinit = null,
                    .labels = labels.ptr,
                    .stream = 0,
                    .canload = 0,
                    .delaymin = 0,
                    .delaymax = 0,
                    .priority = 0,
                    .loopcount = 0,
                    .startoffset = null,
                    .volmin = 0,
                    .volmax = 0,
                    .pitchmin = -127,
                    .pitchmax = 127,
                    .fadeintime = 0,
                    .evictiontype = 0,
                    .selecttype = 0,
                });
            },
            1, 2 => {
                const lib = randMilesField(rand, &ctx.name, &miles_name_ranges);
                const list = randMilesNameList(rand, &ctx.other);
                _ = ev.addCacheSounds(if (rand.boolean()) .cache_sounds else .purge_sounds, lib.ptr, list.ptr);
            },
            3 => {
                const preset = randMilesField(rand, &ctx.name, &miles_name_ranges);
                const labels = randMilesField(rand, &ctx.labels, &miles_label_ranges);
                _ = ev.addPersist(preset.ptr, preset.ptr, labels.ptr, 0);
            },
            4 => {
                const name = randMilesField(rand, &ctx.name, &miles_name_ranges);
                const limits = randMilesField(rand, &ctx.other, &miles_label_ranges);
                _ = ev.addSoundLimit(name.ptr, limits.ptr);
            },
            5 => _ = ev.addOneString(.comment, randMilesField(rand, &ctx.name, &miles_name_ranges)),
            else => _ = ev.addOneString(.version, "4"),
        }
    }

    // close() consumes the builder, so this is the one point the event text
    // exists: everything past it works on a copy the enqueue owns.
    const built = ev.close() orelse return error.NoEvent;
    defer std.c.free(built);
    const nul = std.mem.indexOfScalar(u8, built[0 .. ctx.text.len - 1], 0) orelse return;
    const raw = built[0..nul];
    if (raw.len == 0 or raw.len > ctx.text.len - 1) return;
    @memcpy(ctx.text[0..raw.len], raw);

    // Malformations on top of the constructed text: a cut at an arbitrary point
    // (the half-written bank record), a NUL inside a field, and a run of raw
    // bytes over a run of fields.
    var len: usize = raw.len;
    if (rand.intRangeAtMost(u8, 0, 7) == 0) len = rand.intRangeAtMost(usize, 0, raw.len);
    if (len == 0) return;
    if (rand.intRangeAtMost(u8, 0, 3) == 0) {
        const holes = rand.intRangeAtMost(usize, 1, 3);
        for (0..holes) |_| ctx.text[rand.intRangeAtMost(usize, 0, len - 1)] = 0;
    }
    if (rand.intRangeAtMost(u8, 0, 3) == 0) {
        const at = rand.intRangeAtMost(usize, 0, len - 1);
        const n = rand.intRangeAtMost(usize, 0, len - at);
        for (0..n) |j| ctx.text[at + j] = randFromRanges(rand, &miles_name_ranges);
    }
    const text = ctx.text[0..len];
    ctx.text[len] = 0; // however it was cut or overwritten, this is a C string

    const starts = countStartSteps(text);
    const first_qid = enqueueOwned(text, rand.intRangeAtMost(i32, -8, 64));
    try testing.expect(first_qid != 0);

    var views: [256]InstanceView = undefined;
    const n = collectInstances(&views);
    try testing.expect(n <= starts);
    for (views[0..n], 0..) |v, j| {
        // A name is copied out of a field of the event text, so it cannot be
        // longer than the text it came from: a longer one is a read past the
        // buffer the library was handed.
        try testing.expect(v.sound.len <= text.len);
        try testing.expect(v.instance_id != 0);
        try testing.expect(v.status == 0x1 or v.status == 0x2 or v.status == 0x4);
        // Two entries carrying one id means the instance array was compacted
        // into a slot still holding the pointer it moved out of.
        for (views[0..j]) |prev| try testing.expect(prev.instance_id != v.instance_id);
    }

    // The enumeration, the pause and the resume are three public entry points
    // onto the same label predicate and must report the same set. Half the time
    // the query is the label list this event's own start step carried, so the
    // predicate is walked with a list it really has to match.
    const last: [*:0]const u8 = @ptrCast(&ctx.last_labels);
    const query: [*:0]const u8 = if (last[0] != 0 and rand.boolean())
        last
    else
        randMilesField(rand, &ctx.labels, &miles_label_ranges).ptr;
    const matched = countInstancesMatching(query);
    try testing.expectEqual(matched, api_miles.MilesPauseSoundInstances(query, 0));
    try testing.expectEqual(matched, api_miles.MilesResumeSoundInstances(query, 0));
    try testing.expectEqual(@as(u64, n), countInstancesMatching(null));

    // The cache and the persist list are sets keyed by name, so enqueuing the
    // same event twice lands on the same two counts: a run that added an entry
    // on every enqueue is the leak this catches.
    const st_before = milesState();
    const second_qid = enqueueOwned(text, 0);
    try testing.expect(second_qid != first_qid);
    const st_after = milesState();
    try testing.expectEqual(st_before.LoadedSoundCount, st_after.LoadedSoundCount);
    try testing.expectEqual(st_before.PersistCount, st_after.PersistCount);
    try testing.expectEqual(@as(i32, @intCast(countPersists())), st_after.PersistCount);
    try testing.expect(st_after.LoadedSoundCount >= 0);

    // Processing the queue runs the state machine over the same array.
    _ = api_miles.MilesBeginEventQueueProcessing();
    _ = api_miles.MilesCompleteEventQueueProcessing();
    const st_done = milesState();
    const total = collectInstances(&views);
    try testing.expect(total <= 2 * starts);
    try testing.expect(st_done.PlayingSoundCount >= 0);
    try testing.expect(st_done.PlayingSoundCount <= @as(i32, @intCast(total)));

    // Stopping everything removes exactly what the enumeration reported, and
    // an emptied queue enumerates empty.
    try testing.expectEqual(@as(u64, total), api_miles.MilesStopSoundInstances(null, 0));
    try testing.expectEqual(@as(usize, 0), collectInstances(&views));
}

// Seeds are the shapes an event takes in real data, in the field order the
// decoder reads. A seed only has to be long enough to carry a full event: the
// PRNG inside the target spreads it over every choice.
const seed_version = "9;4;";
const seed_start_music = "1;MUS/FLUTE;0;EVT_MUS;M_START;M_END;music,amb;0;0;0;0000;0000;00;00;;0.000000;0.000000;-127.000000;127.000000;0.000000;0;0;";
const seed_start_sfx = "1;SFX/KICK;0;EVT_SFX;M_START;M_END;sfx,amb;0;1;0;0000;0000;0a;00;;0.000000;1.000000;-127.000000;127.000000;0.000000;0;0;";
const seed_cache = "5;MUS.MLB;FLUTE:CLARINET:VIOLIN;";
const seed_purge = "6;MUS.MLB;VIOLIN;";
const seed_persist = "8;preset_a;save1;music;0;";
const seed_limits = "7;limname;music 2:amb 0:sfx 4;";
const seed_ramp = "10;VAR_pitch;music,amb;VAR_vol;1.500000;1;1;2;";
const seed_lfo = "15;LFO1;0;1.000000;2.000000;0;0;0;0;1;";
const seed_glob = "1;sound*?;0;;;;*music;0;0;0;0000;0000;00;00;;0.000000;0.000000;-127.000000;127.000000;0.000000;0;0;";
const seed_utf8 = "1;caf\xC3\xA9;0;;;;caf\xC3\xA9,amb;0;0;0;0000;0000;00;00;;0.000000;0.000000;-127.000000;127.000000;0.000000;0;0;";

const miles_corpus = [_][]const u8{
    // The full shape: two start_sound steps under a cap, a cached name list, a
    // purge of one of those names, a persisted preset and a limits step.
    seed_version ++ seed_start_music ++ seed_start_sfx ++ seed_cache ++ seed_purge ++ seed_persist ++ seed_limits,
    // A start step after a comment, with the cache set the counts are read from.
    seed_version ++ "4;level_one_music" ++ seed_start_music ++ seed_cache ++ seed_limits,
    // A start step, a ramp and an LFO between two start steps, so the walk
    // passes over the step types the enqueue ignores.
    seed_version ++ seed_start_sfx ++ seed_ramp ++ seed_lfo ++ seed_start_music,
    // Globs and multi-byte characters in the names, a trailing-colon name list,
    // and an empty sound name.
    seed_glob ++ seed_utf8 ++ "5;MUS.MLB;snd1:;" ++ "1;;;0;;;;music;0;0;0;0000;0000;00;00;;0.000000;0.000000;-127.000000;127.000000;0.000000;0;0;",
    // Truncations: every prefix of a well-formed event is the shape a
    // half-written bank record has on disk.
    (seed_version ++ seed_start_music ++ seed_cache ++ seed_persist)[0..160],
    (seed_version ++ seed_start_music ++ seed_cache)[0..120],
    (seed_version ++ seed_start_music)[0..80],
    (seed_version ++ seed_start_music)[0..24],
    seed_version,
    "",
};

test "fuzz: Miles event enqueue, instance lifecycle, and cache bookkeeping" {
    var ctx: miles_ctx = .{};
    try std.testing.fuzz(&ctx, fuzzMilesEnqueueOne, .{ .corpus = &miles_corpus });
}

// The target above is only worth running if a well-formed event actually
// reaches the state it asserts on, so the seed shape is pinned here: two
// start_sound steps, a cached name list, a persist and a cap.
test "a well-formed Miles event enqueues the instances, cache and preset it names" {
    api_miles.MilesClearEventQueue();
    api_miles.MilesShutdownEventSystem(); // clears the cache and persist sets
    defer {
        api_miles.MilesClearEventQueue();
        _ = api_miles.MilesSetSoundLabelLimits(null, "");
    }
    const base = milesState();

    const ev = openmiles.event.EventConstruct.create(testing.allocator).?;
    for ([_][]const u8{ "kick:0", "snare:0" }) |name| {
        _ = ev.addStartSound(.{
            .soundname = @ptrCast(@constCast(name.ptr)),
            .presetname = null,
            .presetisdynamic = 0,
            .eventname = null,
            .markerstart = null,
            .markerend = null,
            .statevar = null,
            .varinit = null,
            .labels = @constCast("music,amb"),
            .stream = 0,
            .canload = 0,
            .delaymin = 0,
            .delaymax = 0,
            .priority = 0,
            .loopcount = 0,
            .startoffset = null,
            .volmin = 0,
            .volmax = 0,
            .pitchmin = -127,
            .pitchmax = 127,
            .fadeintime = 0,
            .evictiontype = 0,
            .selecttype = 0,
        });
    }
    _ = ev.addCacheSounds(.cache_sounds, "MUS.MLB", "a:bee:cee");
    _ = ev.addPersist("preset_a", "save1", "music", 0);
    _ = ev.addSoundLimit("limname", "music 2:amb 2");
    // close() consumes the builder, so the text is the only copy of the event.
    const built = ev.close().?;
    defer std.c.free(built);
    const text = built[0..std.mem.indexOfScalar(u8, built[0..1024], 0).?];

    // The decoder walk the target compares against sees both start steps.
    try testing.expectEqual(@as(usize, 2), countStartSteps(text));
    _ = api_miles.MilesSetSoundLabelLimits(null, "music 2:amb 2");
    try testing.expect(enqueueOwned(text, 0) != 0);

    var views: [16]InstanceView = undefined;
    const n = collectInstances(&views);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expectEqualStrings("kick", views[0].sound);
    try testing.expectEqualStrings("snare", views[1].sound);
    try testing.expectEqual(views[0].queued_id, views[1].queued_id);
    try testing.expect(views[0].instance_id != views[1].instance_id);
    try testing.expectEqual(@as(u64, 2), countInstancesMatching("music"));
    try testing.expectEqual(@as(u64, 2), countInstancesMatching("amb"));

    const after = milesState();
    try testing.expectEqual(base.LoadedSoundCount + 3, after.LoadedSoundCount);
    try testing.expectEqual(base.PersistCount + 1, after.PersistCount);
    try testing.expectEqual(after.PersistCount, @as(i32, @intCast(countPersists())));

    // Re-enqueuing the same event adds no cache or preset names: both are sets
    // keyed by name. The instance list does not grow either, because the two
    // caps hold it at one instance per label.
    try testing.expect(enqueueOwned(text, 0) != 0);
    const again = milesState();
    try testing.expectEqual(after.LoadedSoundCount, again.LoadedSoundCount);
    try testing.expectEqual(after.PersistCount, again.PersistCount);
    try testing.expectEqual(@as(usize, 2), collectInstances(&views));
    try testing.expectEqual(@as(u64, 2), api_miles.MilesStopSoundInstances(null, 0));
    try testing.expectEqual(@as(usize, 0), collectInstances(&views));

    // A cap of 0 evicts every instance carrying the label before the step that
    // enforces it adds its own, so one run of the two start steps leaves the
    // second instance alone.
    _ = api_miles.MilesSetSoundLabelLimits(null, "music 0");
    try testing.expect(enqueueOwned(text, 0) != 0);
    try testing.expectEqual(@as(u64, 1), countInstancesMatching("music"));
    try testing.expectEqual(@as(usize, 1), collectInstances(&views));
    try testing.expectEqual(@as(u64, 1), api_miles.MilesStopSoundInstances(null, 0));
    try testing.expectEqual(@as(usize, 0), collectInstances(&views));
}

// --- Target 7: the MP3 image inspector and frame enumerator ------------------
//
// `mp3.inspect` takes a raw image pointer and an i32 size the caller got from
// the filesystem, then `mp3.enumerateFrames` walks it: it skips an ID3v2 tag
// anywhere in the stream, slides a 4-byte window looking for an 11-bit frame
// sync, and turns each header's bitrate/sample-rate fields into a frame length
// it then consumes. Every one of those is attacker-declared, and a frame length
// computed one step wrong desynchronizes every frame after it, so the parser
// hands the caller lengths and pointers that are internally consistent only if
// nothing was miscounted. fuzz_test.zig feeds this random bytes and asserts
// nothing but a step cap; this target builds images out of real Layer III
// frames, ID3v2 tags and VBR headers, lies about individual header fields, and
// checks the cursor invariant after every step.

const mp3_ctx = struct {
    buf: [2048]u8 = undefined,
};

/// Bytes an MP3 stream is built from: the 0xFF/0xE0 frame syncs, the ASCII of a
/// Xing/Info/LAME header and an ID3v1 "TAG", the rest arbitrary.
const mp3_byte_weights: []const Weight = &.{
    w(0xFF, 0xFF, 30), // frame sync lead
    w(0xE0, 0xEF, 20), // frame sync follow
    w(0x00, 0x7F, 20), // side info, payloads
    w('X', 'X', 4),
    w('i', 'i', 4),
    w('n', 'n', 4),
    w('g', 'g', 4),
    w('I', 'I', 2),
    w('f', 'f', 2),
    w('o', 'o', 2),
    w('T', 'T', 2),
    w('A', 'A', 2),
    w('G', 'G', 2),
};

/// Write a 4-byte Layer III header. The two fixed bytes are sync + MPEG-1 +
/// Layer III + no CRC; the other two carry the fields the frame length is
/// computed from, so a draw of 0xF (bad bitrate) or 3 (reserved sample rate)
/// is a header the parser must reject without consuming it.
fn putFrameHeader(buf: []u8, at: usize, bitrate_index: u8, sf_index: u8, padding: bool) void {
    buf[at] = 0xFF;
    buf[at + 1] = 0xFB;
    buf[at + 2] = (bitrate_index << 4) | (sf_index << 2) | (@as(u8, @intFromBool(padding)) << 1);
    buf[at + 3] = 0xC0; // stereo
}

/// The frame length the parser derives from a header, or 0 for a header it
/// rejects. Written out rather than reused from mp3.zig so the corpus and the
/// assertions below agree with the SDK rule independently.
fn mpeg1Layer3FrameLen(bitrate: i32, sample_rate: i32, padding: bool) usize {
    if (sample_rate <= 0 or bitrate <= 0) return 0;
    return @intCast(@divTrunc(144 * bitrate, sample_rate) + @as(i32, @intFromBool(padding)));
}

/// An ID3v2.3/2.4 header with a 28-bit synchsafe body size, optionally with
/// the v2.4 footer flag. A size that claims more than the image holds is the
/// case both the initial skip and the mid-stream skip have to survive.
fn putId3v2(buf: []u8, at: usize, body_len: u32, footer: bool) void {
    @memcpy(buf[at..][0..3], "ID3");
    buf[at + 3] = 3; // version
    buf[at + 4] = 0;
    buf[at + 5] = if (footer) 0x10 else 0;
    const s: u32 = body_len & 0x0FFF_FFFF;
    buf[at + 6] = @intCast((s >> 21) & 0x7F);
    buf[at + 7] = @intCast((s >> 14) & 0x7F);
    buf[at + 8] = @intCast((s >> 7) & 0x7F);
    buf[at + 9] = @intCast(s & 0x7F);
}

/// Build one stream into `ctx.buf` and return its length: an optional leading
/// ID3v2 tag, a run of frames (the first optionally carrying a Xing/Info VBR
/// header), an optional ID3v2 tag between frames, and an optional trailing
/// ID3v1 tag. Sizes the fuzzer draws are written as declared, so the image
/// routinely claims more than it holds.
fn buildMp3Image(ctx: *mp3_ctx, smith: *std.testing.Smith) usize {
    var at: usize = 0;
    if (smith.boolWeighted(1, 2)) {
        const body: usize = smith.index(64);
        if (at + 10 + body > ctx.buf.len) return at;
        const declared: u32 = switch (smith.index(6)) {
            0 => @intCast(body),
            1 => @intCast(body + 1),
            2 => 0x0FFF_FFFF,
            3 => @as(u32, @intCast(body)) -| 1,
            else => @intCast(smith.index(256)),
        };
        putId3v2(&ctx.buf, at, declared, smith.boolWeighted(2, 1));
        at += 10;
        smith.bytesWeighted(ctx.buf[at..][0..body], mp3_byte_weights);
        at += body;
    }

    const frames: usize = 2 + smith.index(5);
    var f: usize = 0;
    while (f < frames) : (f += 1) {
        if (at + 8 > ctx.buf.len) break;
        // Bitrate index 1..14 is a tabulated rate; 0 (free format) and 0xF
        // (bad) are the two headers a real file carries that the parser has to
        // refuse rather than turn into a frame length.
        const bitrate_index: u8 = switch (smith.index(8)) {
            0 => 0,
            1 => 0x0F,
            else => 1 + @as(u8, @intCast(smith.index(14))),
        };
        const sf_index: u8 = switch (smith.index(5)) {
            0 => 3, // reserved
            else => @intCast(smith.index(3)),
        };
        const padding = smith.boolWeighted(1, 1);
        putFrameHeader(&ctx.buf, at, bitrate_index, sf_index, padding);
        const body = mpeg1Layer3FrameLen(
            openmiles.mp3.MPEG_bit_rate[0][@min(bitrate_index, 14)],
            openmiles.mp3.MPEG_sample_rate[0][0][sf_index & 3],
            padding,
        );
        if (at + 4 + body > ctx.buf.len) {
            at += 4;
            break;
        }
        smith.bytesWeighted(ctx.buf[at + 4 ..][0..body], mp3_byte_weights);
        at += 4 + body;

        // A VBR header belongs in the first frame's payload, where the parser
        // looks for it before it consumes the frame.
        if (f == 0 and smith.boolWeighted(1, 2)) {
            const tag: usize = smith.index(16);
            if (at + tag <= ctx.buf.len) {
                smith.bytesWeighted(ctx.buf[at..][0..tag], mp3_byte_weights);
                // Written after the fill: the four identifier bytes are the one
                // part of the tag the parser looks for by name.
                @memcpy(ctx.buf[at..][0..4], if (smith.boolWeighted(1, 1)) "Xing" else "Info");
            }
        }
        // A tag between frames: the mid-stream skip in enumerateFrames.
        if (f + 1 < frames and smith.boolWeighted(3, 1)) {
            const tag_body: usize = smith.index(48);
            if (at + 10 + tag_body > ctx.buf.len) break;
            putId3v2(&ctx.buf, at, @intCast(tag_body + smith.index(4)), smith.boolWeighted(1, 2));
            at += 10 + tag_body;
        }
    }

    if (smith.boolWeighted(1, 1) and at + 128 <= ctx.buf.len) {
        @memcpy(ctx.buf[at..][0..3], "TAG");
        smith.bytesWeighted(ctx.buf[at + 3 ..][0..125], mp3_byte_weights);
        at += 128;
    }
    return at;
}

/// After every step the cursor and the remaining-byte count must describe the
/// same window of the image: the enumerator advances `ptr` by one byte for
/// every byte it takes off `bytes_left`, so the two can only agree if no read
/// walked off either end. A frame's own numbers must be usable by a caller that
/// decodes from `byte_offset` for `data_size` bytes.
fn expectCursorState(es: *const openmiles.mp3.MP3_INFO, img: [*]const u8, img_len: usize) !void {
    const ptr = es.ptr orelse return error.NoCursor;
    const start = es.start_MP3_data orelse return error.NoStart;
    const end = es.end_MP3_data orelse return error.NoEnd;
    const lo = @intFromPtr(img);
    const hi = lo + img_len;
    try testing.expect(@intFromPtr(start) >= lo and @intFromPtr(start) <= hi);
    try testing.expect(@intFromPtr(end) >= @intFromPtr(start) and @intFromPtr(end) < hi);
    try testing.expect(@intFromPtr(ptr) >= @intFromPtr(start) and @intFromPtr(ptr) <= @intFromPtr(end) + 1);
    try testing.expectEqual(@intFromPtr(end) + 1, @intFromPtr(ptr) + @as(usize, @intCast(es.bytes_left)));
    try testing.expect(es.bytes_left >= 0);
    // Offsets are relative to the first MP3 byte, so they cannot precede it.
    try testing.expect(es.byte_offset >= 0);
    try testing.expect(es.next_frame_expected >= 0);
}

fn expectFrameState(es: *const openmiles.mp3.MP3_INFO, img: [*]const u8, img_len: usize) !void {
    try expectCursorState(es, img, img_len);
    const start = es.start_MP3_data orelse return error.NoStart;
    const lo = @intFromPtr(img);
    const hi = lo + img_len;
    // A reported frame is one the decoder will be handed.
    try testing.expect(es.data_size > 0);
    try testing.expect(es.header_size == 4 or es.header_size == 6);
    try testing.expect(es.bit_rate > 0);
    try testing.expect(es.sample_rate > 0);
    try testing.expect(es.channels_per_sample == 1 or es.channels_per_sample == 2);
    try testing.expect(es.samples_per_frame == 576 or es.samples_per_frame == 1152);
    try testing.expect(es.MPEG1 == 0 or es.MPEG1 == 1);
    try testing.expect(es.MPEG25 == 0 or es.MPEG25 == 1);
    // The frame runs from the header the byte offset names to the cursor, and
    // a caller decodes that whole span, so it has to fit in the image.
    const frame_start = @intFromPtr(start) + @as(usize, @intCast(es.byte_offset));
    try testing.expect(frame_start >= lo);
    try testing.expect(frame_start <= @intFromPtr(es.end_MP3_data.?) + 1);
    try testing.expect(hi - frame_start >= @as(usize, @intCast(es.data_size + es.header_size + es.side_info_size)));
    // LAME delay/padding are 12-bit fields; anything outside the range is
    // reported as -1, never as a wrapped value.
    try testing.expect(es.enc_delay >= -1 and es.enc_delay <= 4096);
    try testing.expect(es.enc_padding >= -1 and es.enc_padding <= 4096);
}

fn fuzzMp3One(ctx: *mp3_ctx, smith: *std.testing.Smith) anyerror!void {
    const len = buildMp3Image(ctx, smith);
    if (len == 0) return;
    const img = ctx.buf[0..len];

    var es: openmiles.mp3.MP3_INFO = .{};
    openmiles.mp3.inspect(&es, @ptrCast(img.ptr), @intCast(len));
    try testing.expectEqual(@as(i32, @intCast(len)), es.MP3_image_size);
    try expectCursorState(&es, img.ptr, len);
    // The reported tag pointer names the tag at the head of the image, and the
    // audio start is either that tag's end (a tag that fits) or the head of the
    // image again (one claiming more than the file holds).
    if (es.ID3v2) |p| {
        try testing.expectEqual(@intFromPtr(img.ptr), @intFromPtr(p));
        try testing.expect(es.ID3v2_size > 0);
        if (es.start_MP3_data) |s| {
            try testing.expect(@intFromPtr(s) == @intFromPtr(p) or
                @intFromPtr(s) >= @intFromPtr(p) + @as(usize, @intCast(es.ID3v2_size)));
        }
    }
    if (es.ID3v1) |p| {
        try testing.expect(@intFromPtr(p) + 128 <= @intFromPtr(img.ptr) + len);
    }

    // Walk every frame, checking the cursor after each one and that the walk
    // makes progress: two successive frames at the same offset would spin a
    // caller's decode loop forever.
    var prev: usize = 0;
    var frames: usize = 0;
    while (openmiles.mp3.enumerateFrames(&es) != 0) {
        try expectFrameState(&es, img.ptr, len);
        const at = @intFromPtr(es.ptr.?) - @intFromPtr(img.ptr);
        try testing.expect(at > prev);
        try testing.expect(at <= len);
        prev = at;
        frames += 1;
        if (frames > 100_000) return error.WalkDidNotTerminate;
    }
    // A walk that stops still has to leave the cursor inside the image with a
    // non-negative remainder, whatever half-finished header it stopped on.
    try expectCursorState(&es, img.ptr, len);
}

const mp3_frame_seed = [_]u8{ 0xFF, 0xFB, 0x90, 0xC0 };
const mp3_xing_seed = "ID3" ++ "\x03\x00\x00" ++ "\x00\x00\x00\x0A" ++ "abcdefghij" ++
    mp3_frame_seed[0..] ++ "\x00\x00\x00\x00\x00\x00\x00\x00" ++
    "Xing" ++ "\x00\x00\x00\x0F" ++ "\x00\x00\x00\x0A" ++ "\x00\x00\x30\x00" ++
    mp3_frame_seed[0..] ++ "\x00\x00\x00\x00\x00\x00\x00\x00";

const mp3_corpus = [_][]const u8{
    // A tagged VBR stream: ID3v2, a Xing frame, a plain frame, ID3v1.
    mp3_xing_seed,
    // The same stream without the tags, so the first bytes are a frame header.
    mp3_frame_seed[0..] ++ "\x00\x00\x00\x00\x00\x00\x00\x00",
    // A header whose fields the parser must reject (bad bitrate, reserved
    // sample rate, free format) in front of a good one.
    mp3_frame_seed[0..] ++ "\xFF\xFF\xFF\xFF" ++ mp3_frame_seed[0..] ++ "\x00\x00\x00\x00",
    // A tag claiming 256 MiB of body, then a frame.
    "ID3" ++ "\x03\x00\x00" ++ "\x7F\x7F\x7F\x7F" ++ mp3_frame_seed[0..] ++ "\x00\x00",
    // A lone sync with nothing behind it.
    "\xFF\xFB",
    "",
};

test "fuzz: MP3 image inspector and frame enumerator" {
    var ctx: mp3_ctx = .{};
    try std.testing.fuzz(&ctx, fuzzMp3One, .{ .corpus = &mp3_corpus });
}

// --- Target 8: the DLS container split (find / extract / list) ---------------
//
// A merged .mil image is two containers in one buffer: an XMIDI sequence and a
// RIFF/DLS bank. `AIL_find_DLS` reports where each starts without copying and
// `AIL_extract_DLS` copies them out for a caller that loads the halves
// separately, so every pointer and length those exports hand back is a
// boundary the caller dereferences with no further checks. fuzz_test.zig runs
// them over random bytes; this target builds the two containers as they nest in
// a real file, lies about their declared sizes, and checks that what comes back
// is the same bytes that went in, at a length that fits.

const dls_ctx = struct {
    buf: [2048]u8 = undefined,
};

/// Write an XDIR-wrapped XMIDI image (FORM/XDIR/CAT/XMID/FORM/XMID/EVNT) and
/// return the offset the DLS bank should start at.
fn buildXmiImage(buf: []u8, smith: *std.testing.Smith) usize {
    const evnt_len: usize = 8 + smith.index(24);
    const xmid_inner: usize = 8 + 8 + evnt_len;
    const cat_body: usize = 4 + xmid_inner;
    var at: usize = 0;
    @memcpy(buf[at..][0..4], "FORM");
    putBe32(buf, at + 4, declaredSize(smith, 4 + 4 + 4 + cat_body));
    @memcpy(buf[at + 8 ..][0..4], "XDIR");
    at += 12;
    @memcpy(buf[at..][0..4], "CAT ");
    putBe32(buf, at + 4, declaredSize(smith, cat_body));
    @memcpy(buf[at + 8 ..][0..4], "XMID");
    at += 12;
    @memcpy(buf[at..][0..4], "FORM");
    putBe32(buf, at + 4, declaredSize(smith, xmid_inner));
    @memcpy(buf[at + 8 ..][0..4], "XMID");
    at += 12;
    @memcpy(buf[at..][0..4], "EVNT");
    putBe32(buf, at + 4, declaredSize(smith, evnt_len));
    smith.bytes(buf[at + 8 ..][0..evnt_len]);
    return at + 8 + evnt_len;
}

/// Write a RIFF/DLS bank: a LIST/INFO group, an instrument collection, and a
/// LIST/adtl group carrying a `labl` chunk, which is what the listing reads
/// the instrument count out of.
fn buildDlsImage(buf: []u8, at: usize, smith: *std.testing.Smith) usize {
    var p = at;
    @memcpy(buf[p..][0..4], "RIFF");
    putBe32(buf, p + 4, declaredSize(smith, 4 + 4 + 8 + 8 + 12 + 8 + 4 + 8));
    @memcpy(buf[p + 8 ..][0..4], "DLS ");
    p += 12;
    @memcpy(buf[p..][0..4], "LIST");
    putBe32(buf, p + 4, declaredSize(smith, 4 + 8));
    @memcpy(buf[p + 8 ..][0..4], "INFO");
    p += 12;
    @memcpy(buf[p..][0..4], "colh");
    putBe32(buf, p + 4, declaredSize(smith, 12));
    putBe32(buf, p + 8, @intCast(smith.index(64)));
    p += 20;
    @memcpy(buf[p..][0..4], "LIST");
    putBe32(buf, p + 4, declaredSize(smith, 4 + 8 + 4));
    @memcpy(buf[p + 8 ..][0..4], "adtl");
    @memcpy(buf[p + 12 ..][0..4], "labl");
    putBe32(buf, p + 16, declaredSize(smith, 4));
    putBe32(buf, p + 20, @intCast(smith.index(4)));
    return p + 24;
}

fn fuzzDlsSplitOne(ctx: *dls_ctx, smith: *std.testing.Smith) anyerror!void {
    // A merged .mil puts the XMIDI sequence before the DLS bank; a bank
    // loaded on its own has no sequence in front of it. Both halves are built
    // either way, so every input reaches the split with a bank in it.
    var at: usize = if (smith.index(2) == 0) buildXmiImage(&ctx.buf, smith) else 0;
    if (at + 64 > ctx.buf.len) return;
    at = buildDlsImage(&ctx.buf, at, smith);
    const img = ctx.buf[0..at];

    var xo: ?*anyopaque = null;
    var xl: u32 = 0;
    var do_: ?*anyopaque = null;
    var dl: u32 = 0;
    const found = api_dls.AIL_find_DLS(@ptrCast(img.ptr), @intCast(img.len), &xo, &xl, &do_, &dl);

    // Every pointer handed back is an interior pointer into this buffer, and
    // its length has to fit: a caller walks these without a bounds check.
    const lo = @intFromPtr(img.ptr);
    if (do_) |p| {
        const off = @intFromPtr(p) - lo;
        try testing.expect(off <= img.len);
        try testing.expectEqual(@as(usize, dl), img.len - off);
    } else try testing.expectEqual(@as(u32, 0), dl);
    if (xo) |p| {
        const off = @intFromPtr(p) - lo;
        try testing.expect(off <= img.len);
        try testing.expect(@as(usize, xl) <= img.len - off);
    } else try testing.expectEqual(@as(u32, 0), xl);
    // The XMI, when reported, ends where the bank begins: the two are the
    // halves of one buffer, and an overlap would make the second load re-read
    // the first one's bytes.
    if (xo != null and do_ != null) try testing.expect(xl == @intFromPtr(do_.?) - lo);

    // extract_DLS copies the same two regions out, so the copy has to be
    // byte-identical to the region find_DLS reported.
    var exo: ?*anyopaque = null;
    var exl: u32 = 0;
    var edo: ?*anyopaque = null;
    var edl: u32 = 0;
    const extracted = api_dls.AIL_extract_DLS(@ptrCast(img.ptr), @intCast(img.len), &exo, &exl, &edo, &edl, null);
    defer freeLock(exo);
    defer freeLock(edo);
    if (extracted != 0) {
        const bank: ?[*]const u8 = if (edo) |p| @ptrCast(p) else null;
        const at_off: usize = if (do_) |p| @intFromPtr(p) - lo else img.len;
        if (bank) |b| try testing.expectEqualSlices(u8, img[at_off..][0..@intCast(edl)], b[0..@intCast(edl)]);
        try testing.expectEqual(@as(u32, dl), edl);
    }
    if (exo) |p| {
        const x: [*]const u8 = @ptrCast(p);
        const off: usize = if (xo) |q| @intFromPtr(q) - lo else 0;
        try testing.expectEqualSlices(u8, img[off..][0..@intCast(exl)], x[0..@intCast(exl)]);
    }
    try testing.expectEqual(found == 1, extracted == 1);

    // The listing is a C string a game prints; the terminator has to be inside
    // the block the caller's free owns, and its length has to be the size the
    // same call reported.
    var lst: ?*anyopaque = null;
    var lsz: u32 = 0;
    if (api_dls.AIL_list_DLS(@ptrCast(img.ptr), &lst, &lsz, 0, "fuzz") != 0) {
        defer freeLock(lst);
        const text: [*:0]const u8 = @ptrCast(@alignCast(lst.?));
        try testing.expectEqual(@as(usize, lsz), std.mem.span(text).len);
        try testing.expect(lsz > 0);
        try testing.expect(std.mem.indexOf(u8, std.mem.span(text), "fuzz") != null);
    } else {
        try testing.expectEqual(@as(u32, 0), lsz);
    }
}

const dls_corpus = [_][]const u8{
    // A merged image: XMIDI sequence first, DLS bank after it.
    "FORM" ++ "\x00\x00\x00\x28" ++ "XDIR" ++ "CAT " ++ "\x00\x00\x00\x20" ++ "XMID" ++
        "FORM" ++ "\x00\x00\x00\x14" ++ "XMID" ++ "EVNT" ++ "\x00\x00\x00\x08" ++ "\x00\xFF\x51\x03\x0F\x42\x40\x60" ++
        "RIFF" ++ "\x00\x00\x00\x40" ++ "DLS " ++ "LIST" ++ "\x00\x00\x00\x0C" ++ "INFO" ++
        "colh" ++ "\x0C\x00\x00\x00" ++ "\x04\x00\x00\x00" ++ "\x00\x00\x00\x00",
    // The bank alone, with a lying RIFF size.
    "RIFF" ++ "\xFF\xFF\xFF\xFF" ++ "DLS " ++ "LIST" ++ "\x00\x00\x00\x0C" ++ "INFO" ++
        "colh" ++ "\x0C\x00\x00\x00" ++ "\xFF\xFF\xFF\xFF" ++ "\x00\x00\x00\x00",
    // The sequence alone, and a plain SMF (not XMIDI at all).
    "FORM" ++ "\x00\x00\x00\x14" ++ "XMID" ++ "EVNT" ++ "\x00\x00\x00\x04" ++ "\x00\xFF\x2F\x00",
    "MThd" ++ "\x00\x00\x00\x06" ++ "\x00\x00\x00\x01\x00\x78" ++ "MTrk" ++ "\x00\x00\x00\x04" ++ "\x00\xFF\x2F\x00",
    "",
};

test "fuzz: DLS container split, extract, and listing" {
    var ctx: dls_ctx = .{};
    try std.testing.fuzz(&ctx, fuzzDlsSplitOne, .{ .corpus = &dls_corpus });
}

// --- Target 9: the plugin directory-entry name filter -----------------------
//
// The plugin loader reads a directory, and every name that scan hands it is
// untrusted: the game directory is where a user, an installer, or an archive
// unpack drops files, and the name is then joined to a path and loaded as code.
// `isPluginExtension` and `isSafePluginFilename` are the whole gate, so this
// target asserts the properties the loader relies on rather than only that the
// two predicates return without trapping: a name either accepts carries no
// traversal, no separator, no NTFS stream colon, no stripped trailing dot or
// space, and no DOS device stem; and both verdicts are unchanged when ASCII
// case is folded, since the device and extension checks are case-insensitive
// and a case-sensitive slip there would let "NUL.asi" or "decoder.ASI" past.

const plugin_name_weights: []const Weight = &.{
    w('a', 'z', 24), // stems, and the letters of the device names
    w('A', 'Z', 24),
    w('0', '9', 10), // COM1..COM9 / LPT1..LPT9
    w('.', '.', 24), // the extension dot, and the stem terminator
    w(' ', ' ', 8), // stripped off a Windows name before it is stored
    w('/', '/', 5),
    w('\\', '\\', 5),
    w(':', ':', 5), // NTFS named stream
    w('$', '$', 2), // CLOCK$
    w(0x01, 0x7F, 6),
    w(0x80, 0xFF, 4), // a non-ASCII game directory
};

const plugin_ctx = struct {
    name: [256]u8 = undefined,
    upper: [256]u8 = undefined,
};

fn asciiUpper(s: []const u8, buf: []u8) []const u8 {
    for (s, buf[0..s.len]) |c, *d| d.* = std.ascii.toUpper(c);
    return buf[0..s.len];
}

/// A DOS device name, spelled the way the resolver reads it: the part of the
/// name before its first dot, compared without regard to case.
fn namesDosDevice(name: []const u8) bool {
    const stem = name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len];
    const fixed = [_][]const u8{ "con", "prn", "aux", "nul", "clock$" };
    for (fixed) |d| {
        if (std.ascii.eqlIgnoreCase(stem, d)) return true;
    }
    if (stem.len != 4) return false;
    if (!std.ascii.startsWithIgnoreCase(stem, "com") and !std.ascii.startsWithIgnoreCase(stem, "lpt")) return false;
    return stem[3] >= '1' and stem[3] <= '9';
}

fn fuzzPluginNameOne(ctx: *plugin_ctx, smith: *std.testing.Smith) anyerror!void {
    const n: usize = @intCast(smith.sliceWeighted(
        &ctx.name,
        &.{.{ .min = 1, .max = ctx.name.len, .weight = 1 }},
        plugin_name_weights,
    ));
    var name = ctx.name[0..n];
    // Half the time the name carries a real extension, so the accept branch is
    // the one a game directory actually produces rather than a name the loader
    // drops on the extension check before it reads the stem.
    if (smith.boolWeighted(1, 2)) {
        const exts = [_][]const u8{ ".asi", ".m3d", ".flt", ".ASI", ".Asi" };
        const ext = exts[smith.index(exts.len)];
        if (n + ext.len <= ctx.name.len) {
            @memcpy(ctx.name[n..][0..ext.len], ext);
            name = ctx.name[0 .. n + ext.len];
        }
    }

    const safe = openmiles.isSafePluginFilename(name);
    if (safe) {
        // Everything the loader opens is a file inside the scanned directory
        // under the name the scan listed. A name carrying any of these opens
        // something else.
        try testing.expect(std.mem.indexOf(u8, name, "..") == null);
        try testing.expect(std.mem.indexOfScalar(u8, name, '/') == null);
        try testing.expect(std.mem.indexOfScalar(u8, name, '\\') == null);
        try testing.expect(std.mem.indexOfScalar(u8, name, ':') == null);
        try testing.expect(name.len == 0 or (name[name.len - 1] != '.' and name[name.len - 1] != ' '));
        try testing.expect(!namesDosDevice(name));
        // Wrapping the accepted name in a directory component names a
        // different file, so the filter has to reject the wrapped form too;
        // a fix that only checked the head of the name would let this through.
        var wrapped: [ctx.name.len + 4]u8 = undefined;
        @memcpy(wrapped[0..4], "sub/");
        @memcpy(wrapped[4..][0..name.len], name);
        try testing.expect(!openmiles.isSafePluginFilename(wrapped[0 .. name.len + 4]));
        @memcpy(wrapped[0..2], "..");
        @memcpy(wrapped[2..][0..name.len], name);
        try testing.expect(!openmiles.isSafePluginFilename(wrapped[0 .. name.len + 2]));
    }

    // Case folding must not move either verdict: a name the loader opens in a
    // game directory is opened the same way whatever case the filesystem
    // hands the entry back in.
    const upper = asciiUpper(name, &ctx.upper);
    try testing.expectEqual(safe, openmiles.isSafePluginFilename(upper));
    const ext_ok = openmiles.isPluginExtension(name);
    try testing.expectEqual(ext_ok, openmiles.isPluginExtension(upper));
    if (ext_ok) {
        try testing.expect(name.len >= 4);
        const tail = name[name.len - 4 ..];
        try testing.expect(std.ascii.eqlIgnoreCase(tail, ".asi") or
            std.ascii.eqlIgnoreCase(tail, ".m3d") or
            std.ascii.eqlIgnoreCase(tail, ".flt"));
    }
}

const plugin_corpus = [_][]const u8{
    // What a game directory holds: the providers, and the files beside them.
    "mss32.asi",
    "Miles Decoder.asi",
    "adpcm.flt",
    "a3d.m3d",
    "readme.txt",
    "",
    // Names the Windows filesystem resolves away from the file the entry named.
    "nul.asi",
    "CON.m3d",
    "com1.asi",
    "lpt9.flt",
    "clock$.asi",
    "com0.asi",
    // Traversal, separators, and a stream: a name an archive or a sync client
    // can plant, and each of which opens something the scan did not list.
    "..\\evil.asi",
    "../evil.asi",
    "sub/evil.asi",
    "evil.asi:payload",
    "decoder.asi ",
    "decoder.asi.",
    "..",
    ".",
    // Non-ASCII stems, the case a game directory with a localized path has.
    "Aventura \xC3\x89pica.asi",
    "\xE3\x83\x86\xE3\x82\xB9\xE3\x83\x88.m3d",
};

test "fuzz: plugin directory-entry name filter" {
    var ctx: plugin_ctx = .{};
    try std.testing.fuzz(&ctx, fuzzPluginNameOne, .{ .corpus = &plugin_corpus });
}

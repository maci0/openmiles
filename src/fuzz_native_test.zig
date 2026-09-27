//! Coverage-guided fuzz targets (std.testing.fuzz) for the parsers that take
//! the most untrusted bytes per input: the SoundBank event-step decoder
//! (`event.nextStep`, a hand-written recursive-descent bytecode reader that
//! copies names into a caller scratch buffer), the XMIDI IFF → SMF converter
//! (`xmidiToSmf` / `xmidiBareToSmf`), the BANK image loader behind the bank
//! query API, the WAV container readers that classify a file, and the WAV
//! cue-point marker API (count / by-index / by-name over a nested
//! LIST-adtl-labl chunk tree).
//!
//! fuzz_test.zig drives these with fixed-seed PRNG bytes. These targets add
//! what a PRNG loop cannot: `Smith` picks the shapes (which ASCII a field may
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

const Weight = std.testing.Smith.Weight;

fn w(min: u8, max: u8, weight: u64) Weight {
    return .{ .min = min, .max = max, .weight = weight };
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

//! Coverage-guided fuzz targets (std.testing.fuzz) for the two parsers that
//! take the most untrusted bytes per input: the SoundBank event-step decoder
//! (`event.nextStep`, a hand-written recursive-descent bytecode reader that
//! copies names into a caller scratch buffer) and the XMIDI IFF → SMF
//! converter (`xmidiToSmf` / `xmidiBareToSmf`).
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

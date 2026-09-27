//! UTF-8 <-> UTF-16 conversion for the Win32 wide ("W") entry points.
//!
//! The ANSI ("A") entry points transcode through the process ANSI code page
//! (or, when no system code page is set, the process default), so any
//! character outside it is replaced with '?'. A game directory, plugin path, or
//! %TEMP% containing an accented, CJK, or Cyrillic character then fails to
//! open. The W entry points take UTF-16 and need no such transliteration.
//!
//! Both std converters index their output without a bounds check, so these
//! wrappers validate the destination up front and fail rather than write past
//! it. The bounds are worst case: one UTF-16 unit per UTF-8 byte, and one to
//! three UTF-8 bytes per UTF-16 unit.

const std = @import("std");

pub const Error = error{ NoSpaceLeft, InvalidUtf8 } || std.unicode.Utf16LeToUtf8Error;

/// Upper bound on the UTF-8 length of `wide`, terminator excluded: one unit is
/// at most three bytes, and a surrogate pair is four bytes for two of them. A
/// caller that sizes its UTF-8 destination from the *unit* count instead (a
/// MAX_PATH-unit path into a MAX_PATH-byte buffer) loses every path carrying a
/// character outside ASCII, so size it from this.
pub fn utf8LenBound(wide: []const u16) usize {
    return wide.len * 3;
}

/// Convert a UTF-8 string for a *W call: NUL-terminated, no embedded NUL.
pub fn toWide(utf8: []const u8, buf: []u16) Error![:0]const u16 {
    if (utf8.len >= buf.len) return error.NoSpaceLeft;
    const n = try std.unicode.utf8ToUtf16Le(buf[0..utf8.len], utf8);
    buf[n] = 0;
    return buf[0..n :0];
}

/// Convert a *W result back to UTF-8, dropping the NUL terminator.
pub fn toUtf8(wide: []const u16, buf: []u8) Error![]const u8 {
    const n_units = std.mem.indexOfScalar(u16, wide, 0) orelse wide.len;
    // std's converter asserts on a short destination, so check first. All-ASCII
    // input needs one byte per unit; anything else may need three.
    const ascii = blk: {
        for (wide[0..n_units]) |unit| {
            if (unit >= 0x80) break :blk false;
        }
        break :blk true;
    };
    const max_bytes = if (ascii) n_units else utf8LenBound(wide[0..n_units]);
    if (max_bytes > buf.len) return error.NoSpaceLeft;
    const n = try std.unicode.utf16LeToUtf8(buf[0..max_bytes], wide[0..n_units]);
    return buf[0..n];
}

/// Longest prefix of `s` that is at most `max` bytes and ends where a
/// character ends, so a caller that has to cut a string to fit a fixed buffer
/// stores text rather than a lead byte with its continuation bytes left
/// behind. Used for the fixed error and path buffers the C surface hands out.
pub fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    // The last byte kept is s[n - 1]; walk back over the continuation bytes to
    // the byte its character starts with. A string that is not valid UTF-8 can
    // hold a run of continuation bytes with no lead byte at all, and those are
    // kept as they came in: the input was already broken and the caller's
    // buffer is the wrong place to repair it.
    var start = n;
    while (start > 0 and s[start - 1] & 0xC0 == 0x80) start -= 1;
    if (start > 0) {
        const width = std.unicode.utf8ByteSequenceLength(s[start - 1]) catch 1;
        if (start - 1 + width > n) n = start - 1;
    }
    return s[0..n];
}

const testing = std.testing;

test "utf8Prefix never cuts a character in half" {
    // Two-byte 'é' repeated: an odd cut lands mid-character, and a cut at the
    // boundary of a four-byte one is a third of the way into it.
    const s = "\u{00e9}\u{00e9}\u{1F600}\u{00e9}";
    try testing.expectEqualStrings("\u{00e9}", utf8Prefix(s, 3));
    try testing.expectEqualStrings("\u{00e9}\u{00e9}", utf8Prefix(s, 4));
    try testing.expectEqualStrings(s, utf8Prefix(s, s.len));
    try testing.expectEqualStrings(s, utf8Prefix(s, s.len + 10));
    for (0..s.len + 1) |max| {
        const cut = utf8Prefix(s, max);
        try testing.expect(cut.len <= max);
        try testing.expect(std.unicode.utf8ValidateSlice(cut));
    }
}

test "utf8Prefix keeps ascii whole" {
    try testing.expectEqualStrings("abc", utf8Prefix("abcdef", 3));
    try testing.expectEqualStrings("", utf8Prefix("abcdef", 0));
}

test "ascii round trip" {
    var wbuf: [32]u16 = undefined;
    var buf: [32]u8 = undefined;
    const w = try toWide("plugins/mock.asi", &wbuf);
    try testing.expectEqualSlices(u16, &.{
        'p', 'l', 'u', 'g', 'i', 'n', 's', '/', 'm', 'o', 'c', 'k', '.', 'a', 's', 'i',
    }, w);
    try testing.expectEqual(@as(u16, 0), wbuf[w.len]);
    try testing.expectEqualStrings("plugins/mock.asi", try toUtf8(w, &buf));
}

test "non-ascii survives a round trip" {
    var wbuf: [64]u16 = undefined;
    var buf: [256]u8 = undefined;
    // A path outside every legacy ANSI code page: the case the *A entry points
    // mangle to '?'.
    const path = "C:\\Juegos\\Aventura Épica\\mock.asi";
    const w = try toWide(path, &wbuf);
    try testing.expectEqualStrings(path, try toUtf8(w, &buf));
}

test "astral plane codepoints round trip" {
    var wbuf: [16]u16 = undefined;
    var buf: [16]u8 = undefined;
    const w = try toWide("\u{10FFFF}", &wbuf);
    try testing.expectEqual(@as(usize, 2), w.len); // surrogate pair
    try testing.expectEqualStrings("\u{10FFFF}", try toUtf8(w, &buf));
}

test "unpaired surrogate is rejected" {
    var buf: [8]u8 = undefined;
    try testing.expectError(error.DanglingSurrogateHalf, toUtf8(&.{0xD800}, &buf));
}

test "short destination fails instead of overrunning" {
    var wbuf: [4]u16 = undefined;
    var buf: [4]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, toWide("abcdef", &wbuf));
    try testing.expectError(error.NoSpaceLeft, toUtf8(&.{ 'a', 'b', 'c', 'd', 'e' }, &buf));
    try testing.expectError(error.InvalidUtf8, toWide("\xFF", &wbuf));
}

test "a buffer sized in UTF-16 units is not sized in UTF-8 bytes" {
    // 100 units of two-byte characters need 300 bytes, not 100: a caller that
    // sized the destination by unit count would see NoSpaceLeft here and drop
    // the whole path rather than degrade it.
    const units: [100]u16 = @splat(0x00E9); // 'é'
    var buf: [utf8LenBound(&units)]u8 = undefined;
    const utf8 = try toUtf8(&units, &buf);
    try testing.expectEqual(@as(usize, 200), utf8.len);
    try testing.expectEqualSlices(u8, &.{ 0xC3, 0xA9, 0xC3, 0xA9 }, utf8[0..4]);
}

test "fuzz: arbitrary bytes are refused or converted, never overrun" {
    // The *W entry points transcode file names and plugin paths the process
    // did not author, so the input is arbitrary bytes: malformed sequences,
    // overlong encodings, lone continuation bytes. Anything the converters
    // refuse is a valid answer; what must never happen is a write past the
    // destination or a partial result reported as a whole one.
    var prng = std.Random.DefaultPrng.init(0xA17E);
    const rand = prng.random();
    const canary: u16 = 0x5A5A;
    var bytes: [96]u8 = undefined;
    // Worst case in both directions for a 96-byte input: one UTF-16 unit per
    // UTF-8 byte, and one to three UTF-8 bytes per unit.
    var wbuf: [bytes.len + 2]u16 = undefined;
    var out: [bytes.len * 3 + 2]u8 = undefined;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        const n = rand.intRangeAtMost(usize, 0, bytes.len);
        rand.bytes(bytes[0..n]);
        // A NUL would end the wide string early and truncate the result; the
        // converters document the input as NUL-free, so keep the fuzz bytes
        // NUL-free too and let everything else through unfiltered.
        for (bytes[0..n]) |*b| {
            if (b.* == 0) b.* = 0x01;
        }

        @memset(&wbuf, canary);
        const w = toWide(bytes[0..n], &wbuf) catch continue;
        try testing.expect(w.len <= bytes[0..n].len);
        try testing.expectEqual(@as(u16, 0), wbuf[w.len]);
        try testing.expectEqual(canary, wbuf[w.len + 1]);

        // A destination too small for what the string needs is refused whole:
        // a prefix written and returned would be a truncated path that still
        // looked like a whole one.
        if (n > 0) {
            const short = out[0..rand.intRangeAtMost(usize, 0, n - 1)];
            @memset(short, 0xCC);
            try testing.expectError(error.NoSpaceLeft, toUtf8(w, short));
            for (short) |b| try testing.expectEqual(@as(u8, 0xCC), b);
        }
        // Malformed bytes decode lossily (the replacement character), so the
        // only property left is that the result is a prefix-bounded string of
        // well-formed UTF-8 and nothing was written past it.
        const back = try toUtf8(w, &out);
        try testing.expect(std.unicode.utf8ValidateSlice(back));
    }
}

test "fuzz: valid utf-8 survives the round trip whatever it contains" {
    var prng = std.Random.DefaultPrng.init(0xA17F);
    const rand = prng.random();
    var bytes: [96]u8 = undefined;
    // Worst case in both directions for a 96-byte input: one UTF-16 unit per
    // UTF-8 byte, and one to three UTF-8 bytes per unit.
    var wbuf: [bytes.len + 2]u16 = undefined;
    var out: [bytes.len * 3 + 2]u8 = undefined;
    var i: usize = 0;
    while (i < 5000) : (i += 1) {
        // Whole code points across every plane, so surrogate pairs, four-byte
        // sequences, and the ASCII tail of a name all get built.
        const n = rand.intRangeAtMost(usize, 0, bytes.len);
        var k: usize = 0;
        while (k < n) {
            const cp: u21 = switch (rand.intRangeAtMost(u8, 0, 3)) {
                0 => rand.intRangeAtMost(u21, 0, 0x7F),
                1 => rand.intRangeAtMost(u21, 0x80, 0x7FF),
                2 => rand.intRangeAtMost(u21, 0x800, 0xD7FF),
                else => rand.intRangeAtMost(u21, 0xE000, 0x10FFFF),
            };
            // utf8CodepointSequenceLength, not the ByteSequenceLength variant:
            // that one takes a lead BYTE, so feeding it a code point reports
            // the width of the low byte's lead pattern (0xE000 -> 1) and the
            // space check below stops protecting utf8Encode.
            const len: usize = std.unicode.utf8CodepointSequenceLength(cp) catch continue;
            if (k + len > n) break;
            // utf8Encode writes at the START of its output slice, so encode into
            // a scratch buffer and copy at k: handing it bytes[0..n] overwrote
            // the code points already written, and handing it bytes[k..n]
            // returned a length that had to be added to k by hand. Either way
            // the string ended up a mix of the last code point and stale bytes
            // (which is what surfaced as a surrogate-half encoding below).
            var enc: [4]u8 = undefined;
            const written: usize = std.unicode.utf8Encode(cp, &enc) catch continue;
            @memcpy(bytes[k..][0..written], enc[0..written]);
            k += written;
        }
        const s = bytes[0..k];
        if (std.mem.indexOfScalar(u8, s, 0) != null) continue; // never generated
        const w = try toWide(s, &wbuf);
        try testing.expectEqualStrings(s, try toUtf8(w, &out));
    }
}

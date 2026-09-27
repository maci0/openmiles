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

const testing = std.testing;

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

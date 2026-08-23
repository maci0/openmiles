//! MSS bundled-resource container helpers.
//!
//! MSS ships music as XMIDI sequences (IFF: `FORM XDIR` + `CAT  XMID`) optionally
//! bundled with a DLS instrument bank (RIFF: `RIFF .... DLS `). The merged image
//! is the XMI image directly followed by the DLS image. These helpers locate and
//! measure each sub-image by signature so `AIL_find_DLS` / `AIL_extract_DLS` /
//! `AIL_merge_DLS_with_XMI` can split and join them faithfully — no codec needed,
//! pure container manipulation, matching the original MSS behavior.

const std = @import("std");

/// Round an IFF chunk size up to the 2-byte boundary IFF uses for padding.
fn align2(n: usize) usize {
    return n +| (n & 1);
}

/// Total byte length of the XMIDI (or SMF) image at the start of `data`, or 0 if
/// `data` does not begin with a recognized music image.
///
/// Standalone XMIDI is two top-level IFF groups: `FORM XDIR { INFO ... }` followed
/// by `CAT  XMID { FORM XMID ... }`. Both contribute to the image extent. A plain
/// SMF (`MThd`) is measured by walking its track chunks.
pub fn xmiImageSize(data: []const u8) usize {
    if (data.len < 12) return 0;

    if (std.mem.eql(u8, data[0..4], "MThd")) {
        const size = smfImageSize(data);
        return @min(size, data.len);
    }

    if (!std.mem.eql(u8, data[0..4], "FORM")) return 0;

    // First top-level FORM (typically XDIR). Saturating adds + immediate clamp
    // so a lying 32-bit chunk size can't overflow the cursor (panic/wrap).
    const form_body = std.mem.readInt(u32, data[4..8], .big);
    var end = @min(align2(8 +| @as(usize, form_body)), data.len);

    // An XDIR group is immediately followed by a `CAT  XMID` group holding the
    // actual sequences; fold it into the image extent when present.
    if (end +| 12 <= data.len and
        std.mem.eql(u8, data[end .. end + 4], "CAT ") and
        std.mem.eql(u8, data[end + 8 .. end + 12], "XMID"))
    {
        const cat_body = std.mem.readInt(u32, data[end + 4 .. end + 8][0..4], .big);
        end = @min(align2(end +| 8 +| @as(usize, cat_body)), data.len);
    }

    return end;
}

/// Byte length of a Standard MIDI File by walking its track chunks.
fn smfImageSize(data: []const u8) usize {
    if (data.len < 14) return data.len;
    const hdr_len = std.mem.readInt(u32, data[4..8], .big);
    const num_tracks = std.mem.readInt(u16, data[10..12], .big);
    var pos: usize = @min(8 +| @as(usize, hdr_len), data.len);
    var found: u16 = 0;
    while (found < num_tracks) {
        if (pos +| 8 > data.len) return data.len;
        if (!std.mem.eql(u8, data[pos .. pos + 4], "MTrk")) return data.len;
        const trk_len = std.mem.readInt(u32, data[pos + 4 .. pos + 8][0..4], .big);
        pos = @min(pos +| 8 +| @as(usize, trk_len), data.len);
        found += 1;
    }
    return pos;
}

/// Largest image extent xmiImageSizePtr accepts from header-declared sizes.
/// This pointer-based API carries no length, so a lying IFF/MThd size field
/// would otherwise drive reads at offsets up to ~4 GiB past the caller's
/// buffer (guaranteed SIGSEGV on 64-bit targets; on 32-bit the wrap happens
/// to stay near the image). Matches readWholeFile's 256 MiB load cap: no
/// legitimate caller passes a larger image, so a larger claim is corruption.
const max_ptr_image_size: usize = 256 * 1024 * 1024;

/// Pointer-based XMI/SMF image sizing for callers that lack an explicit length
/// (e.g. `AIL_merge_DLS_with_XMI`). Relies on the IFF format guarantee that an
/// `XDIR` group is always followed by its `CAT  XMID` group, so the look-ahead
/// reads stay inside the supplied image. Header-declared extents are bounded
/// by max_ptr_image_size; beyond it (or for unrecognized data) returns 0.
pub fn xmiImageSizePtr(raw: [*]const u8) usize {
    if (std.mem.eql(u8, raw[0..4], "MThd")) {
        const hdr_len = std.mem.readInt(u32, raw[4..8], .big);
        const num_tracks = std.mem.readInt(u16, raw[10..12], .big);
        var pos: usize = 8 +| @as(usize, hdr_len);
        if (pos > max_ptr_image_size) return 0;
        var found: u16 = 0;
        while (found < num_tracks) : (found += 1) {
            if (pos +| 8 > max_ptr_image_size) return 0;
            if (!std.mem.eql(u8, raw[pos .. pos + 4], "MTrk")) break;
            const trk_len = std.mem.readInt(u32, raw[pos + 4 .. pos + 8][0..4], .big);
            pos +|= 8 +| @as(usize, trk_len);
            if (pos > max_ptr_image_size) return 0;
        }
        return pos;
    }
    if (!std.mem.eql(u8, raw[0..4], "FORM")) return 0;
    const form_body = std.mem.readInt(u32, raw[4..8], .big);
    var end = align2(8 +| @as(usize, form_body));
    if (end > max_ptr_image_size) return 0;
    // Only an XDIR group is guaranteed to be followed by a CAT group; a bare
    // `FORM XMID` is the whole image, so do not read past it.
    if (std.mem.eql(u8, raw[8..12], "XDIR") and
        std.mem.eql(u8, raw[end .. end + 4], "CAT ") and
        std.mem.eql(u8, raw[end + 8 .. end + 12], "XMID"))
    {
        const cat_body = std.mem.readInt(u32, raw[end + 4 .. end + 8][0..4], .big);
        end = align2(end +| 8 +| @as(usize, cat_body));
        if (end > max_ptr_image_size) return 0;
    }
    return end;
}

/// Locate a DLS RIFF image (`RIFF .... DLS `) anywhere within `data`.
/// Returns the sub-slice (header through declared size) or null if absent.
pub fn findDls(data: []const u8) ?[]const u8 {
    if (data.len < 12) return null;
    var i: usize = 0;
    while (i + 12 <= data.len) : (i += 1) {
        if (data[i] == 'R' and
            std.mem.eql(u8, data[i .. i + 4], "RIFF") and
            std.mem.eql(u8, data[i + 8 .. i + 12], "DLS "))
        {
            const body = std.mem.readInt(u32, data[i + 4 .. i + 8][0..4], .little);
            const total = @min(8 + @as(usize, body), data.len - i);
            return data[i .. i + total];
        }
    }
    return null;
}

/// Locate the XMIDI/SMF image within `data`. Returns the leading music image
/// (the bytes before any trailing DLS bank), or null if none is recognized.
pub fn findXmi(data: []const u8) ?[]const u8 {
    if (data.len < 12) return null;
    if (std.mem.eql(u8, data[0..4], "FORM") or std.mem.eql(u8, data[0..4], "MThd")) {
        const size = xmiImageSize(data);
        if (size == 0) return null;
        return data[0..size];
    }
    return null;
}

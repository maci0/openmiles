//! Faithful port of the Miles MP3 frame inspector (AIL_inspect_MP3 /
//! AIL_enumerate_MP3_frames, from the MSS 9.x SDK mssutil.cpp). Walks an MP3
//! file image one frame at a time, decoding the standard MPEG-1/2/2.5 Layer III
//! frame headers (sync search, bitrate/sample-rate tables, frame-size
//! calculation) plus the LAME/Xing/Info VBR tag. The MP3_INFO layout matches the
//! SDK header so a caller's allocation and field reads line up byte-for-byte.

const std = @import("std");

// Bitrate (bps) for [MPEG1][bitrate_index]; index 0 = free, 0x0f = bad.
const MPEG_bit_rate = [2][15]i32{
    .{ 0, 8000, 16000, 24000, 32000, 40000, 48000, 56000, 64000, 80000, 96000, 112000, 128000, 144000, 160000 },
    .{ 0, 32000, 40000, 48000, 56000, 64000, 80000, 96000, 112000, 128000, 160000, 192000, 224000, 256000, 320000 },
};
// Sample rate (Hz) for [MPEG25][MPEG1][sampling_frequency].
const MPEG_sample_rate = [2][2][4]i32{
    .{ .{ 22050, 24000, 16000, 22050 }, .{ 44100, 48000, 32000, 44100 } },
    .{ .{ 11025, 12000, 8000, 11025 }, .{ 44100, 48000, 32000, 44100 } },
};

const FRAMES_FLAG: u32 = 1;
const BYTES_FLAG: u32 = 2;
const TOC_FLAG: u32 = 4;
const VBR_SCALE_FLAG: u32 = 8;

/// Mirrors the SDK MP3_INFO struct field-for-field (all 32-bit fields + TOC[100]).
pub const MP3_INFO = extern struct {
    MP3_file_image: ?[*]u8 = null,
    MP3_image_size: i32 = 0,
    ID3v2: ?[*]u8 = null,
    ID3v2_size: i32 = 0,
    ID3v1: ?[*]u8 = null,
    start_MP3_data: ?[*]u8 = null,
    end_MP3_data: ?[*]u8 = null,
    sample_rate: i32 = 0,
    bit_rate: i32 = 0,
    channels_per_sample: i32 = 0,
    samples_per_frame: i32 = 0,
    byte_offset: i32 = 0,
    next_frame_expected: i32 = 0,
    average_frame_size: i32 = 0,
    data_size: i32 = 0,
    header_size: i32 = 0,
    side_info_size: i32 = 0,
    ngr: i32 = 0,
    main_data_begin: i32 = 0,
    hpos: i32 = 0,
    MPEG1: i32 = 0,
    MPEG25: i32 = 0,
    layer: i32 = 0,
    protection_bit: i32 = 0,
    bitrate_index: i32 = 0,
    sampling_frequency: i32 = 0,
    padding_bit: i32 = 0,
    private_bit: i32 = 0,
    mode: i32 = 0,
    mode_extension: i32 = 0,
    copyright: i32 = 0,
    original: i32 = 0,
    emphasis: i32 = 0,
    Xing_valid: i32 = 0,
    Info_valid: i32 = 0,
    header_flags: u32 = 0,
    frame_count: i32 = 0,
    byte_count: i32 = 0,
    VBR_scale: i32 = 0,
    TOC: [100]u8 = [_]u8{0} ** 100,
    enc_delay: i32 = 0,
    enc_padding: i32 = 0,
    ptr: ?[*]u8 = null,
    bytes_left: i32 = 0,
    check_valid: i32 = 0,
    check_MPEG1: i32 = 0,
    check_MPEG25: i32 = 0,
    check_layer: i32 = 0,
    check_protection_bit: i32 = 0,
    check_sampling_frequency: i32 = 0,
    check_mode: i32 = 0,
    check_copyright: i32 = 0,
    check_original: i32 = 0,
};

/// Read `n` bits (MSB-first) from `data` at `bitpos`, advancing it. Mirrors the
/// SDK read_bits: assemble 4 bytes big-endian, shift the window into place.
fn readBits(data: []const u8, bitpos: *i32, n: i32) u32 {
    if (n <= 0) return 0;
    const b: usize = @intCast(bitpos.*);
    const i = b >> 3;
    const p0: u32 = if (i < data.len) data[i] else 0;
    const p1: u32 = if (i + 1 < data.len) data[i + 1] else 0;
    const p2: u32 = if (i + 2 < data.len) data[i + 2] else 0;
    const p3: u32 = if (i + 3 < data.len) data[i + 3] else 0;
    var val: u32 = (p0 << 24) | (p1 << 16) | (p2 << 8) | p3;
    val <<= @intCast(b & 7);
    val >>= @intCast(32 - n);
    bitpos.* = @intCast(b + @as(usize, @intCast(n)));
    return val;
}

fn fetchU32(p: []const u8) u32 {
    if (p.len < 4) return 0;
    return (@as(u32, p[0]) << 24) | (@as(u32, p[1]) << 16) | (@as(u32, p[2]) << 8) | @as(u32, p[3]);
}

fn isId3v2(p: [*]const u8) bool {
    return p[0] == 0x49 and p[1] == 0x44 and p[2] == 0x33 and
        p[3] < 0xff and p[4] < 0xff and p[6] < 0x80 and p[7] < 0x80 and p[8] < 0x80 and p[9] < 0x80;
}

pub fn inspect(es: *MP3_INFO, file_image_in: [*]u8, file_size_in: i32) void {
    es.* = .{};
    es.MP3_file_image = file_image_in;
    es.MP3_image_size = file_size_in;
    var file_image = file_image_in;
    var file_size = file_size_in;

    // Skip an initial ID3v2 tag.
    if (file_size >= 10 and isId3v2(file_image)) {
        const skip: i32 = @intCast(10 + ((@as(u32, file_image[9])) | (@as(u32, file_image[8]) << 7) |
            (@as(u32, file_image[7]) << 14) | (@as(u32, file_image[6]) << 21)));
        es.ID3v2 = file_image;
        es.ID3v2_size = skip;
        file_image += @intCast(skip);
        file_size -= skip;
    }
    es.start_MP3_data = file_image;

    // Account for a trailing ID3v1 tag.
    if (file_size >= 128) {
        const tag = file_image + @as(usize, @intCast(file_size - 128));
        if (tag[0] == 'T' and tag[1] == 'A' and tag[2] == 'G') {
            es.ID3v1 = tag;
            file_size -= 128;
        }
    }
    if (file_size < 1) {
        es.end_MP3_data = file_image;
        es.ptr = file_image;
        es.bytes_left = 0;
        return;
    }
    es.end_MP3_data = file_image + @as(usize, @intCast(file_size - 1));
    es.ptr = file_image;
    es.bytes_left = file_size;
}

/// Advance to the next valid Layer III frame; 1 on success, 0 at end.
pub fn enumerateFrames(es: *MP3_INFO) i32 {
    const start = es.start_MP3_data orelse return 0;

    read_frame_header: while (true) {
        var ptr = es.ptr orelse return 0;
        es.next_frame_expected = @intCast(@intFromPtr(ptr) - @intFromPtr(start));

        // ID3v2 tags can appear at any frame boundary.
        while (es.bytes_left >= 10) {
            if (!isId3v2(ptr)) break;
            const size: i32 = @intCast((@as(u32, ptr[9])) | (@as(u32, ptr[8]) << 7) |
                (@as(u32, ptr[7]) << 14) | (@as(u32, ptr[6]) << 21));
            const total_len: i32 = if (ptr[5] & 0x10 != 0) 20 + size else 10 + size;
            if (es.bytes_left < total_len) return 0;
            es.bytes_left -= total_len;
            ptr += @intCast(total_len);
            es.ptr = ptr;
        }

        // Find an 11-bit frame-sync via a sliding 4-byte window.
        var window = [4]u8{ 0, 0, 0, 0 };
        var found = false;
        while (true) {
            if (es.bytes_left <= 0) return 0;
            window[0] = window[1];
            window[1] = window[2];
            window[2] = window[3];
            window[3] = ptr[0];
            ptr += 1;
            es.bytes_left -= 1;
            es.ptr = ptr;
            if (window[0] == 0xFF and (window[1] & 0xE0) == 0xE0) {
                found = true;
                break;
            }
        }
        if (!found) return 0;

        es.byte_offset = @as(i32, @intCast(@intFromPtr(ptr) - @intFromPtr(start))) - 4;

        // Parse the 4-byte header (skip the 11-bit sync).
        var header_buffer = [_]u8{0} ** 64;
        header_buffer[0..4].* = window;
        es.hpos = 11;
        es.MPEG25 = @intFromBool(readBits(&header_buffer, &es.hpos, 1) == 0);
        es.MPEG1 = @intCast(readBits(&header_buffer, &es.hpos, 1));
        es.layer = @intCast(readBits(&header_buffer, &es.hpos, 2));
        es.protection_bit = @intCast(readBits(&header_buffer, &es.hpos, 1));
        es.bitrate_index = @intCast(readBits(&header_buffer, &es.hpos, 4));
        es.sampling_frequency = @intCast(readBits(&header_buffer, &es.hpos, 2));
        es.padding_bit = @intCast(readBits(&header_buffer, &es.hpos, 1));
        es.private_bit = @intCast(readBits(&header_buffer, &es.hpos, 1));
        es.mode = @intCast(readBits(&header_buffer, &es.hpos, 2));
        es.mode_extension = @intCast(readBits(&header_buffer, &es.hpos, 2));
        es.copyright = @intCast(readBits(&header_buffer, &es.hpos, 1));
        es.original = @intCast(readBits(&header_buffer, &es.hpos, 1));
        es.emphasis = @intCast(readBits(&header_buffer, &es.hpos, 2));

        if (es.bitrate_index == 0x0f or es.sampling_frequency == 0x03) continue :read_frame_header;
        if (es.layer != 1) continue :read_frame_header; // Layer III only

        if (es.check_valid == 0) {
            es.check_valid = 1;
            es.check_MPEG25 = es.MPEG25;
            es.check_MPEG1 = es.MPEG1;
            es.check_layer = es.layer;
            es.check_protection_bit = es.protection_bit;
            es.check_sampling_frequency = es.sampling_frequency;
            es.check_mode = es.mode;
            es.check_copyright = es.copyright;
            es.check_original = es.original;
        } else if (es.MPEG1 != es.check_MPEG1 or es.MPEG25 != es.check_MPEG25 or
            es.layer != es.check_layer or es.sampling_frequency != es.check_sampling_frequency)
        {
            es.check_MPEG25 = es.MPEG25;
            es.check_MPEG1 = es.MPEG1;
            es.check_layer = es.layer;
            es.check_protection_bit = es.protection_bit;
            es.check_sampling_frequency = es.sampling_frequency;
            es.check_mode = es.mode;
            es.check_copyright = es.copyright;
            es.check_original = es.original;
            continue :read_frame_header;
        }

        // CRC word (if present).
        es.header_size = 4;
        if (es.protection_bit == 0) {
            if (es.bytes_left < 2) return 0;
            header_buffer[4] = ptr[0];
            header_buffer[5] = ptr[1];
            ptr += 2;
            es.bytes_left -= 2;
            es.ptr = ptr;
            es.hpos += 16;
            es.header_size = 6;
        }

        // Side info.
        es.side_info_size = if (es.MPEG1 != 0) (if (es.mode == 3) @as(i32, 17) else 32) else (if (es.mode == 3) @as(i32, 9) else 17);
        if (es.bytes_left < es.side_info_size) return 0;
        es.bytes_left -= es.side_info_size;
        {
            var i: usize = 0;
            while (i < @as(usize, @intCast(es.side_info_size))) : (i += 1) {
                header_buffer[@as(usize, @intCast(es.header_size)) + i] = ptr[0];
                ptr += 1;
            }
            es.ptr = ptr;
        }

        es.channels_per_sample = if (es.mode == 3) 1 else 2;
        es.ngr = if (es.MPEG1 != 0) 2 else 1;
        if (es.MPEG1 != 0) {
            es.main_data_begin = @intCast(readBits(&header_buffer, &es.hpos, 9));
            _ = readBits(&header_buffer, &es.hpos, if (es.channels_per_sample == 1) 5 else 3);
        } else {
            es.main_data_begin = @intCast(readBits(&header_buffer, &es.hpos, 8));
            _ = readBits(&header_buffer, &es.hpos, if (es.channels_per_sample == 1) 1 else 2);
        }

        es.bit_rate = MPEG_bit_rate[@intCast(es.MPEG1)][@intCast(es.bitrate_index)];
        es.sample_rate = MPEG_sample_rate[@intCast(es.MPEG25)][@intCast(es.MPEG1)][@intCast(es.sampling_frequency)];
        if (es.sample_rate == 0) continue :read_frame_header;
        es.average_frame_size = if (es.MPEG1 != 0)
            @divTrunc(144 * es.bit_rate, es.sample_rate)
        else
            @divTrunc(72 * es.bit_rate, es.sample_rate);
        es.data_size = es.average_frame_size + es.padding_bit - (es.header_size + es.side_info_size);
        if (es.data_size < 0) es.data_size = 0;
        es.samples_per_frame = if (es.sample_rate == 44100 or es.sample_rate == 48000 or es.sample_rate == 32000) 1152 else 576;

        if (es.bytes_left < es.data_size) return 0;

        // LAME/Xing/Info VBR tag.
        const info_base = ptr[0..@min(@as(usize, @intCast(es.bytes_left)), 200)];
        var info_frame = false;
        if (info_base.len >= 4) {
            if (info_base[0] == 'I' and info_base[1] == 'n' and info_base[2] == 'f' and info_base[3] == 'o') {
                es.Info_valid = 1;
                info_frame = true;
            } else if (info_base[0] == 'X' and info_base[1] == 'i' and info_base[2] == 'n' and info_base[3] == 'g') {
                es.Xing_valid = 1;
                info_frame = true;
            }
        }
        if (info_frame) {
            var off: usize = 4;
            es.header_flags = if (info_base.len >= off + 4) fetchU32(info_base[off..]) else 0;
            off += 4;
            if (es.header_flags & FRAMES_FLAG != 0) {
                if (info_base.len >= off + 4) es.frame_count = @bitCast(fetchU32(info_base[off..]));
                off += 4;
            }
            if (es.header_flags & BYTES_FLAG != 0) {
                if (info_base.len >= off + 4) es.byte_count = @bitCast(fetchU32(info_base[off..]));
                off += 4;
            }
            if (es.header_flags & TOC_FLAG != 0) {
                if (info_base.len >= off + 100) @memcpy(es.TOC[0..100], info_base[off .. off + 100]);
                off += 100;
            }
            if (es.header_flags & VBR_SCALE_FLAG != 0) {
                if (info_base.len >= off + 4) es.VBR_scale = @bitCast(fetchU32(info_base[off..]));
                off += 4;
            }
            off += 21;
            if (info_base.len >= off + 3) {
                es.enc_delay = (@as(i32, info_base[off]) << 4) + (@as(i32, info_base[off + 1]) >> 4);
                es.enc_padding = (@as(i32, info_base[off + 1] & 0x0f) << 8) + @as(i32, info_base[off + 2]);
                if (es.enc_delay < 0 or es.enc_delay > 4096) es.enc_delay = -1;
                if (es.enc_padding < 0 or es.enc_padding > 4096) es.enc_padding = -1;
            }
        }

        // Skip the audio data; the frame is valid.
        ptr += @intCast(es.data_size);
        es.bytes_left -= es.data_size;
        es.ptr = ptr;
        return 1;
    }
}

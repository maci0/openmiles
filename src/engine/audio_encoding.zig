const std = @import("std");

/// Wrap already-encoded IMA ADPCM block data in a WAV container so a standard
/// WAV decoder (miniaudio) can decode it. Mirrors buildAdpcmWav's header layout
/// but copies the supplied ADPCM bytes verbatim instead of encoding. `block_size`
/// is the ADPCM block alignment; `total_per_ch` is the decoded sample count per
/// channel (the fact-chunk value).
pub fn wrapAdpcmInWav(alloc: std.mem.Allocator, adpcm: []const u8, block_size: u32, channels: u16, rate: u32, total_per_ch: u32) ![]u8 {
    if (channels == 0 or channels > 2) return error.InvalidParam;
    const ch: u32 = channels;
    // block_size is a u16 WAV field; reject out-of-range values so neither the
    // u16 store nor the (block_size-4*ch)*8 math can overflow/panic.
    if (block_size <= 4 * ch or block_size > 0xFFFF) return error.InvalidParam;
    const spb: u32 = (block_size - 4 * ch) * 8 / (4 * ch) + 1;
    if (adpcm.len > std.math.maxInt(u32)) return error.InvalidParam;
    const data_size: u32 = @intCast(adpcm.len);
    const avg_bps: u32 = @intCast(@min(@as(u64, rate) * block_size / spb, std.math.maxInt(u32)));
    const header_sz: usize = 8 + 4 + 8 + 20 + 8 + 4 + 8;
    var buf = try alloc.alloc(u8, header_sz + adpcm.len);
    errdefer alloc.free(buf);
    var o: usize = 0;
    const wr16 = struct {
        fn f(b: []u8, p: *usize, v: u16) void {
            std.mem.writeInt(u16, b[p.*..][0..2], v, .little);
            p.* += 2;
        }
    }.f;
    const wr32 = struct {
        fn f(b: []u8, p: *usize, v: u32) void {
            std.mem.writeInt(u32, b[p.*..][0..4], v, .little);
            p.* += 4;
        }
    }.f;
    @memcpy(buf[o .. o + 4], "RIFF");
    o += 4;
    wr32(buf, &o, @intCast(buf.len - 8));
    @memcpy(buf[o .. o + 4], "WAVE");
    o += 4;
    @memcpy(buf[o .. o + 4], "fmt ");
    o += 4;
    wr32(buf, &o, 20);
    wr16(buf, &o, 0x0011); // WAVE_FORMAT_IMA_ADPCM
    wr16(buf, &o, channels);
    wr32(buf, &o, rate);
    wr32(buf, &o, avg_bps);
    wr16(buf, &o, @intCast(block_size));
    wr16(buf, &o, 4); // bits per sample
    wr16(buf, &o, 2); // cbSize
    wr16(buf, &o, @intCast(spb)); // wSamplesPerBlock
    @memcpy(buf[o .. o + 4], "fact");
    o += 4;
    wr32(buf, &o, 4);
    wr32(buf, &o, total_per_ch);
    @memcpy(buf[o .. o + 4], "data");
    o += 4;
    wr32(buf, &o, data_size);
    @memcpy(buf[o..], adpcm);
    return buf;
}

pub fn buildWavFromPcm(allocator: std.mem.Allocator, pcm_data: []const u8, channels: u16, sample_rate: u32, bits: u16) ![]u8 {
    if (pcm_data.len > std.math.maxInt(u32) - 44) return error.InvalidParam;
    // Header fields only — saturate rather than panic on absurd rate/channels.
    const byte_rate: u32 = sample_rate *| @as(u32, channels) *| (@as(u32, bits) / 8);
    const block_align: u16 = channels *| (bits / 8);
    const data_len: u32 = @intCast(pcm_data.len);
    const riff_size: u32 = 36 + data_len;
    const total_size = 8 + riff_size;
    const buf = try allocator.alloc(u8, total_size);
    @memcpy(buf[0..4], "RIFF");
    std.mem.writeInt(u32, buf[4..8], riff_size, .little);
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    std.mem.writeInt(u32, buf[16..20], 16, .little); // fmt chunk size
    std.mem.writeInt(u16, buf[20..22], 1, .little); // PCM
    std.mem.writeInt(u16, buf[22..24], channels, .little);
    std.mem.writeInt(u32, buf[24..28], sample_rate, .little);
    std.mem.writeInt(u32, buf[28..32], byte_rate, .little);
    std.mem.writeInt(u16, buf[32..34], block_align, .little);
    std.mem.writeInt(u16, buf[34..36], bits, .little);
    @memcpy(buf[36..40], "data");
    std.mem.writeInt(u32, buf[40..44], data_len, .little);
    @memcpy(buf[44..], pcm_data);
    return buf;
}

pub const ima_step_table = [89]i32{
    7,     8,     9,     10,    11,    12,    13,    14,    16,    17,   19,   21,   23,    25,    28,    31,
    34,    37,    41,    45,    50,    55,    60,    66,    73,    80,   88,   97,   107,   118,   130,   143,
    157,   173,   190,   209,   230,   253,   279,   307,   337,   371,  408,  449,  494,   544,   598,   658,
    724,   796,   876,   963,   1060,  1166,  1282,  1411,  1552,  1707, 1878, 2066, 2272,  2499,  2749,  3024,
    3327,  3660,  4026,  4428,  4871,  5358,  5894,  6484,  7132,  7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
};
pub const ima_index_table = [16]i32{ -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8 };

fn imaEncode(sample: i16, predictor: *i32, step_idx: *i32) u8 {
    const step = ima_step_table[@intCast(@max(0, @min(88, step_idx.*)))];
    var diff: i32 = @as(i32, sample) - predictor.*;
    var nibble: u8 = 0;
    if (diff < 0) {
        nibble = 8;
        diff = -diff;
    }
    if (diff >= step) {
        nibble |= 4;
        diff -= step;
    }
    if (diff >= step >> 1) {
        nibble |= 2;
        diff -= step >> 1;
    }
    if (diff >= step >> 2) {
        nibble |= 1;
    }
    var delta: i32 = step >> 3;
    if (nibble & 4 != 0) delta += step;
    if (nibble & 2 != 0) delta += step >> 1;
    if (nibble & 1 != 0) delta += step >> 2;
    if (nibble & 8 != 0) predictor.* -= delta else predictor.* += delta;
    if (predictor.* > 32767) predictor.* = 32767;
    if (predictor.* < -32768) predictor.* = -32768;
    step_idx.* += ima_index_table[nibble];
    if (step_idx.* < 0) step_idx.* = 0;
    if (step_idx.* > 88) step_idx.* = 88;
    return nibble;
}

pub fn buildAdpcmWav(alloc: std.mem.Allocator, pcm: [*]const i16, total_per_ch: usize, channels: u16, rate: u32) ![]u8 {
    // IMA ADPCM WAV is mono or stereo only; >2 channels would underflow the
    // `block_size - 4*ch` samples-per-block computation below.
    if (channels == 0 or channels > 2) return error.InvalidParam;
    const ch: u32 = channels;
    // MSS block alignment (mssadpcm.cpp): 256<<(channels/2) — 256 mono, 512
    // stereo — scaled up with the sample rate above 11025 Hz. Computed in u64 so
    // an adversarial rate can't overflow; clamped to the u16 blockalign field.
    var bs: u64 = @as(u64, 256) << @intCast(ch / 2);
    if (rate > 11025) bs *= (@as(u64, rate) + 5000) / 11025;
    if (bs <= 4 * ch or bs > 0xFFFF) return error.InvalidParam;
    const block_size: u32 = @intCast(bs);
    const spb: u32 = (block_size - 4 * ch) * 8 / (4 * ch) + 1;
    const num_blocks: usize = (total_per_ch + spb - 1) / spb;
    // Reject inputs whose encoded size would not fit the 32-bit WAV size fields.
    const data_bytes: usize = num_blocks * block_size;
    if (data_bytes > std.math.maxInt(u32)) return error.InvalidParam;
    const data_size: u32 = @intCast(data_bytes);
    const avg_bps: u32 = @intCast(@min(@as(u64, rate) * block_size / spb, std.math.maxInt(u32)));
    const header_sz: usize = 8 + 4 + 8 + 20 + 8 + 4 + 8;
    var buf = try alloc.alloc(u8, header_sz + data_size);
    errdefer alloc.free(buf);
    var o: usize = 0;
    @memcpy(buf[o .. o + 4], "RIFF");
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], @intCast(buf.len - 8), .little);
    o += 4;
    @memcpy(buf[o .. o + 4], "WAVE");
    o += 4;
    @memcpy(buf[o .. o + 4], "fmt ");
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], 20, .little);
    o += 4;
    std.mem.writeInt(u16, buf[o..][0..2], 0x0011, .little);
    o += 2;
    std.mem.writeInt(u16, buf[o..][0..2], channels, .little);
    o += 2;
    std.mem.writeInt(u32, buf[o..][0..4], rate, .little);
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], avg_bps, .little);
    o += 4;
    std.mem.writeInt(u16, buf[o..][0..2], @intCast(block_size), .little);
    o += 2;
    std.mem.writeInt(u16, buf[o..][0..2], 4, .little);
    o += 2;
    std.mem.writeInt(u16, buf[o..][0..2], 2, .little);
    o += 2;
    std.mem.writeInt(u16, buf[o..][0..2], @intCast(spb), .little);
    o += 2;
    @memcpy(buf[o .. o + 4], "fact");
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], 4, .little);
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], @intCast(total_per_ch), .little);
    o += 4;
    @memcpy(buf[o .. o + 4], "data");
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], data_size, .little);
    o += 4;
    // MSS (mssadpcm.cpp) initializes the IMA step index to 0 once and CARRIES it
    // across every block (convert_to_adpcm reads/writes *plstepi/*prstepi), while
    // the predictor is reset to each block's first sample. Each block header thus
    // stores the step index carried in from the previous block, not a fresh 0.
    // Carrying it here makes our encoded image byte-identical to MSS for multi-
    // block audio (the per-block reset would diverge from block 2 on).
    var sidx: i32 = 0; // mono step index, carried across blocks
    var sl: i32 = 0; // stereo left step index, carried across blocks
    var sr: i32 = 0; // stereo right step index, carried across blocks
    for (0..num_blocks) |blk| {
        const blk_start = blk * spb;
        const blk_out = buf[o .. o + block_size];
        o += block_size;
        if (channels == 1) {
            const init_s: i16 = if (blk_start < total_per_ch) pcm[blk_start] else 0;
            var pred: i32 = init_s;
            std.mem.writeInt(i16, blk_out[0..2][0..2], init_s, .little);
            blk_out[2] = @intCast(sidx); // step index carried from prior block
            blk_out[3] = 0;
            var si: usize = 1;
            var ob: usize = 4;
            while (ob < block_size) : (ob += 1) {
                const s0: i16 = if (blk_start + si < total_per_ch) pcm[blk_start + si] else 0;
                si += 1;
                const s1: i16 = if (blk_start + si < total_per_ch) pcm[blk_start + si] else 0;
                si += 1;
                blk_out[ob] = imaEncode(s0, &pred, &sidx) | (imaEncode(s1, &pred, &sidx) << 4);
            }
        } else {
            const il: i16 = if (blk_start < total_per_ch) pcm[blk_start * 2] else 0;
            const ir: i16 = if (blk_start < total_per_ch) pcm[blk_start * 2 + 1] else 0;
            var pl: i32 = il;
            var pr: i32 = ir;
            std.mem.writeInt(i16, blk_out[0..2][0..2], il, .little);
            blk_out[2] = @intCast(sl); // left step index carried from prior block
            blk_out[3] = 0;
            std.mem.writeInt(i16, blk_out[4..6][0..2], ir, .little);
            blk_out[6] = @intCast(sr); // right step index carried from prior block
            blk_out[7] = 0;
            var grp: usize = 0;
            var ob: usize = 8;
            while (ob + 8 <= block_size) : ({
                grp += 1;
                ob += 8;
            }) {
                const base = blk_start + 1 + grp * 8;
                for (0..4) |b| {
                    const si0 = base + b * 2;
                    const si1 = base + b * 2 + 1;
                    const l0: i16 = if (si0 < total_per_ch) pcm[si0 * 2] else 0;
                    const l1: i16 = if (si1 < total_per_ch) pcm[si1 * 2] else 0;
                    blk_out[ob + b] = imaEncode(l0, &pl, &sl) | (imaEncode(l1, &pl, &sl) << 4);
                }
                for (0..4) |b| {
                    const si0 = base + b * 2;
                    const si1 = base + b * 2 + 1;
                    const r0: i16 = if (si0 < total_per_ch) pcm[si0 * 2 + 1] else 0;
                    const r1: i16 = if (si1 < total_per_ch) pcm[si1 * 2 + 1] else 0;
                    blk_out[ob + 4 + b] = imaEncode(r0, &pr, &sr) | (imaEncode(r1, &pr, &sr) << 4);
                }
            }
        }
    }
    return buf;
}

const std = @import("std");

pub fn buildWavFromPcm(allocator: std.mem.Allocator, pcm_data: []const u8, channels: u16, sample_rate: u32, bits: u16) ![]u8 {
    if (pcm_data.len > std.math.maxInt(u32) - 44) return error.InvalidParam;
    const byte_rate: u32 = sample_rate * @as(u32, channels) * (@as(u32, bits) / 8);
    const block_align: u16 = channels * (bits / 8);
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

const ima_step_table = [89]i32{
    7,     8,     9,     10,    11,    12,    13,    14,    16,    17,   19,   21,   23,    25,    28,    31,
    34,    37,    41,    45,    50,    55,    60,    66,    73,    80,   88,   97,   107,   118,   130,   143,
    157,   173,   190,   209,   230,   253,   279,   307,   337,   371,  408,  449,  494,   544,   598,   658,
    724,   796,   876,   963,   1060,  1166,  1282,  1411,  1552,  1707, 1878, 2066, 2272,  2499,  2749,  3024,
    3327,  3660,  4026,  4428,  4871,  5358,  5894,  6484,  7132,  7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
};
const ima_index_table = [16]i32{ -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8 };

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
    if (channels == 0) return error.InvalidParam;
    const block_size: u32 = 512;
    const ch: u32 = channels;
    const spb: u32 = (block_size - 4 * ch) * 8 / (4 * ch) + 1;
    const num_blocks: usize = (total_per_ch + spb - 1) / spb;
    const data_size: u32 = @intCast(num_blocks * block_size);
    const avg_bps: u32 = rate * block_size / spb;
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
    for (0..num_blocks) |blk| {
        const blk_start = blk * spb;
        const blk_out = buf[o .. o + block_size];
        o += block_size;
        if (channels == 1) {
            const init_s: i16 = if (blk_start < total_per_ch) pcm[blk_start] else 0;
            var pred: i32 = init_s;
            var sidx: i32 = 0;
            std.mem.writeInt(i16, blk_out[0..2][0..2], init_s, .little);
            blk_out[2] = 0;
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
            var sl: i32 = 0;
            var pr: i32 = ir;
            var sr: i32 = 0;
            std.mem.writeInt(i16, blk_out[0..2][0..2], il, .little);
            blk_out[2] = 0;
            blk_out[3] = 0;
            std.mem.writeInt(i16, blk_out[4..6][0..2], ir, .little);
            blk_out[6] = 0;
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

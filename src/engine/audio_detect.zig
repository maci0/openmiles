const std = @import("std");

pub const streaming_sentinel_size: usize = 16 * 1024 * 1024;

pub fn detectAudioSize(raw: [*]const u8) usize {
    if (raw[0] == 'R' and raw[1] == 'I' and raw[2] == 'F' and raw[3] == 'F') {
        const body = std.mem.readInt(u32, raw[4..8], .little);
        return @as(usize, body) +| 8;
    }
    if (raw[0] == 'F' and raw[1] == 'O' and raw[2] == 'R' and raw[3] == 'M') {
        const body = std.mem.readInt(u32, raw[4..8], .big);
        return @as(usize, body) +| 8;
    }
    if (raw[0] == 'M' and raw[1] == 'T' and raw[2] == 'h' and raw[3] == 'd') {
        return detectMidiSize(raw);
    }
    if (raw[0] == 'O' and raw[1] == 'g' and raw[2] == 'g' and raw[3] == 'S') {
        return streaming_sentinel_size;
    }
    if ((raw[0] == 0xFF and (raw[1] & 0xE0) == 0xE0) or
        (raw[0] == 'I' and raw[1] == 'D' and raw[2] == '3'))
    {
        return streaming_sentinel_size;
    }
    if (raw[0] == 'f' and raw[1] == 'L' and raw[2] == 'a' and raw[3] == 'C') {
        return streaming_sentinel_size;
    }
    return 0;
}

pub fn detectMidiSize(raw: [*]const u8) usize {
    if (raw[0] == 'F' and raw[1] == 'O' and raw[2] == 'R' and raw[3] == 'M') {
        const body = std.mem.readInt(u32, raw[4..8], .big);
        return @as(usize, body) +| 8;
    }
    if (raw[0] == 'M' and raw[1] == 'T' and raw[2] == 'h' and raw[3] == 'd') {
        const hdr_size = std.mem.readInt(u32, raw[4..8], .big);
        const num_tracks = std.mem.readInt(u16, raw[10..12], .big);
        var pos: usize = @as(usize, 8) +| hdr_size;
        var tracks_found: u16 = 0;
        while (tracks_found < num_tracks) {
            if (pos +| 8 > streaming_sentinel_size) return streaming_sentinel_size;
            const trk_raw = raw + pos + 4;
            const trk_len = std.mem.readInt(u32, trk_raw[0..4], .big);
            if (trk_len > streaming_sentinel_size - pos - 8) return streaming_sentinel_size;
            pos = pos +| 8 +| trk_len;
            tracks_found += 1;
        }
        return pos;
    }
    return streaming_sentinel_size;
}

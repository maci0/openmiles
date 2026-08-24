//! Media container sniffing: derive byte lengths from container headers
//! (RIFF/WAV, AIFF/FORM, MIDI, …) for streaming reads, inspect WAV headers into
//! an AILSOUNDINFO, and classify buffers into AILFILETYPE_* codes. Shared by the
//! api/ modules through the openmiles facade so no api file imports another.

const std = @import("std");
const root = @import("../root.zig");

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

// Returns an AILFILETYPE_* code: UNKNOWN=0, PCM_WAV=1, ADPCM_WAV=2, MIDI=5,
// XMIDI=6 (consistent across MSS 3.x-9.x). These are NOT sequential 1/2/3.
// Exact / case-insensitive 4..N-byte magic compares with bounds checking.
fn eq(buf: []const u8, off: usize, lit: []const u8) bool {
    return off + lit.len <= buf.len and std.mem.eql(u8, buf[off .. off + lit.len], lit);
}
fn eqi(buf: []const u8, off: usize, lit: []const u8) bool {
    return off + lit.len <= buf.len and std.ascii.eqlIgnoreCase(buf[off .. off + lit.len], lit);
}

// MPEG audio detection: ID3v2 skip then a frame-sync scan, ported from
// AIL_API_file_type (miscutil.cpp). Returns the MPEG layer file type or null.
fn detectMpeg(in: []const u8) ?i32 {
    var s = in;
    if (s.len >= 10 and root.mp3.isId3v2(s.ptr)) {
        const skip: u32 = 10 + (@as(u32, s[9]) | (@as(u32, s[8]) << 7) | (@as(u32, s[7]) << 14) | (@as(u32, s[6]) << 21));
        if (skip < s.len) s = s[skip..] else return null;
    }
    const lim = @min(s.len, root.max_file_header_size); // AIL_MAX_FILE_HEADER_SIZE (4096 pre-7.0, else 8192)
    var ftype: i32 = 0;
    var p: usize = 0;
    while (p + 4 <= lim) {
        const w16: u16 = @as(u16, s[p]) | (@as(u16, s[p + 1]) << 8); // LE read
        if ((w16 & 0xF0FF) == 0xF0FF) { // 11-bit frame sync candidate
            const w32: u32 = @as(u32, s[p]) | (@as(u32, s[p + 1]) << 8) | (@as(u32, s[p + 2]) << 16) | (@as(u32, s[p + 3]) << 24);
            if (w32 != 0xFFFFFFFF and ((w32 >> 18) & 0x3f) != 0x3F) {
                switch ((w16 >> 9) & 3) {
                    1 => return 13, // MPEG_L3_AUDIO
                    2 => ftype = 12, // MPEG_L2_AUDIO
                    3 => ftype = 11, // MPEG_L1_AUDIO
                    else => {},
                }
            }
            p += 3;
        }
        p += 1;
    }
    return if (ftype != 0) ftype else null;
}

/// Classify a media buffer into an AILFILETYPE_* code (AIL_file_type core,
/// miscutil.cpp). Pure byte inspection; the api/file.zig export is a thin ABI
/// wrapper over this.
pub fn detectFileType(data: *anyopaque, len: u32) i32 {
    if (len < 8) return 0; // AILFILETYPE_UNKNOWN (SDK: data==0 || size<8)
    const buf = @as([*]const u8, @ptrCast(@alignCast(data)))[0..@intCast(len)];
    const AILSOUNDINFO = root.AILSOUNDINFO;

    // 1. WAV: classify via the robust AIL_WAV_info parser (needs a data chunk).
    var si: AILSOUNDINFO = .{};
    var mp3_off: usize = 0;
    var mp3_len: usize = buf.len;
    if (wavInfoBounded(buf.ptr, buf.len, &si) != 0) {
        switch (si.format) {
            1 => return 1, // PCM_WAV (EXTENSIBLE PCM is reported as 1 by WAV_info)
            0x0011 => return if (si.bits == 4) 2 else 3, // ADPCM_WAV / OTHER_WAV
            0x0069 => return if (si.bits == 4) 15 else 3, // XBOX_ADPCM_WAV / OTHER_WAV
            0x77 => return 17, // V12_VOICE
            0x74 => return 18, // V24_VOICE
            0x75 => return 19, // V29_VOICE
            85 => { // MPEG wrapped in a WAV: scan the data chunk as MP3 below
                const base = @intFromPtr(si.data_ptr) -% @intFromPtr(data);
                if (base < buf.len) {
                    mp3_off = base;
                    mp3_len = @min(@as(usize, si.data_len), buf.len - base);
                }
            },
            else => return 3, // OTHER_WAV (no ASI provider registry to consult)
        }
    } else {
        // 2. Non-WAV container magic (SDK uses case-insensitive compares).
        if (eq(buf, 0, "1FCB")) return 24; // BINKA (*(S32*)data == 'BCF1' on LE)
        if (eqi(buf, 0, "OggS")) {
            const ogg_lim = @min(buf.len, 128);
            var i: usize = 0;
            while (i + 5 <= ogg_lim) : (i += 1) {
                if (eqi(buf, i, "Speex")) return 20; // OGG_SPEEX
            }
            return 16; // OGG_VORBIS
        }
        if (eqi(buf, 0, "Creative")) return 4; // VOC
        if (eqi(buf, 0, "FORM") and eqi(buf, 8, "XDIR")) return 6; // XMIDI
        if (eq(buf, 0, "RIFF")) {
            if (eq(buf, 8, "DLS ")) return 9; // DLS
            if (eq(buf, 8, "MLS ")) return 10; // MLS
        }
    }

    // 3. MPEG audio (also reached for an MPEG-in-WAV after unwrapping).
    if (detectMpeg(buf[mp3_off .. mp3_off + mp3_len])) |t| return t;

    // 4. Last resort: scan the whole image for an 'MThd' header -> MIDI.
    var i: usize = 0;
    while (i + 4 <= buf.len) : (i += 1) {
        if (eqi(buf, i, "MThd")) return 5; // MIDI
    }
    return 0; // AILFILETYPE_UNKNOWN
}

/// WAV header inspector bounded to `max_len` bytes of `raw`. Chunk-walk reads
/// never run past `min(declared RIFF size, max_len)`, so a lying in-file RIFF
/// size cannot cause an out-of-bounds read when the real buffer length is known.
pub fn wavInfoBounded(raw: [*]const u8, max_len: usize, info: *anyopaque) i32 {
    if (max_len < 12) return 0;
    if (raw[0] != 'R' or raw[1] != 'I' or raw[2] != 'F' or raw[3] != 'F') return 0;
    if (raw[8] != 'W' or raw[9] != 'A' or raw[10] != 'V' or raw[11] != 'E') return 0;
    const out: *root.AILSOUNDINFO = @ptrCast(@alignCast(info));
    // Use the RIFF chunk size to determine the file end boundary, clamped to the
    // known buffer length so a lying RIFF size cannot read past the allocation.
    const riff_body = std.mem.readInt(u32, raw[4..8][0..4], .little);
    const file_end: usize = @min(@as(usize, riff_body) + 8, max_len);
    var offset: usize = 12;
    var audio_format: u16 = 1;
    var num_channels: u16 = 1;
    var sample_rate: u32 = 44100;
    var bits_per_sample: u16 = 16;
    var block_align: u16 = 2;
    var data_ptr: ?*const anyopaque = null;
    var data_len: u32 = 0;
    var fact_samples: ?u32 = null;
    // WAVEFORMATEXTENSIBLE (0xFFFE) extension fields, captured if present.
    var ext_cbsize: u16 = 0;
    var ext_channel_mask: u32 = 0;
    var ext_subformat_pcm: bool = false;
    while (offset + 8 <= file_end) {
        const tag = raw[offset .. offset + 4];
        const chunk_size = std.mem.readInt(u32, raw[offset + 4 .. offset + 8][0..4], .little);
        offset += 8;
        if (std.mem.eql(u8, tag, "fmt ") and chunk_size >= 16 and offset + 16 <= file_end) {
            audio_format = std.mem.readInt(u16, raw[offset .. offset + 2][0..2], .little);
            num_channels = std.mem.readInt(u16, raw[offset + 2 .. offset + 4][0..2], .little);
            sample_rate = std.mem.readInt(u32, raw[offset + 4 .. offset + 8][0..4], .little);
            block_align = std.mem.readInt(u16, raw[offset + 12 .. offset + 14][0..2], .little);
            bits_per_sample = std.mem.readInt(u16, raw[offset + 14 .. offset + 16][0..2], .little);
            // WAVEFORMATEXTENSIBLE: read cbSize, dwChannelMask, and the SubFormat
            // GUID so we can validate/convert PCMEX the way the SDK does.
            if (audio_format == 0xFFFE and chunk_size >= 40 and offset + 40 <= file_end) {
                ext_cbsize = std.mem.readInt(u16, raw[offset + 16 .. offset + 18][0..2], .little);
                ext_channel_mask = std.mem.readInt(u32, raw[offset + 20 .. offset + 24][0..4], .little);
                // KSDATAFORMAT_SUBTYPE_PCM = {00000001-0000-0010-8000-00aa00389b71}
                const pcm_guid = [16]u8{ 0x01, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71 };
                ext_subformat_pcm = std.mem.eql(u8, raw[offset + 24 .. offset + 40], &pcm_guid);
            }
        } else if (std.mem.eql(u8, tag, "fact") and chunk_size >= 4 and offset + 4 <= file_end) {
            fact_samples = std.mem.readInt(u32, raw[offset .. offset + 4][0..4], .little);
        } else if (std.mem.eql(u8, tag, "data")) {
            data_ptr = raw + offset;
            data_len = chunk_size;
            // Keep walking for a fact chunk only if we haven't seen one (data is
            // usually last, so break here matches the SDK's data-found exit).
            break;
        }
        const next = offset +| chunk_size +| (chunk_size & 1); // pad to even (saturating)
        if (next <= offset) break; // guard against zero/wraparound
        offset = next;
    }
    if (data_ptr == null) return 0;
    // Per AIL_API_WAV_info (wavefile.cpp): info->format is the WAVE format_tag
    // (1=PCM, 0x11=IMA ADPCM, 0x02=MS ADPCM), NOT a DIG_F_ code; channel_mask is
    // ~0U; initial_ptr is always data_ptr; and `samples` is the total interleaved
    // sample count: (data_len*8)/bits for PCM, block-derived for IMA ADPCM.
    out.format = audio_format;
    out.data_ptr = data_ptr;
    out.data_len = data_len;
    out.rate = sample_rate;
    out.bits = bits_per_sample;
    out.channels = num_channels;
    out.block_size = block_align;
    out.initial_ptr = data_ptr;
    if (@hasField(root.AILSOUNDINFO, "channel_mask")) out.channel_mask = ~@as(u32, 0);
    if (audio_format == 0xFFFE) {
        // WAVEFORMATEXTENSIBLE: the SDK only accepts a 16-bit PCM subformat whose
        // block alignment is channels*2, reports it as plain WAVE_FORMAT_PCM, and
        // carries the file's dwChannelMask. Anything else is rejected (return 0).
        if (ext_cbsize < 22 or !ext_subformat_pcm or block_align != num_channels *| 2) return 0;
        out.format = 1; // WAVE_FORMAT_PCM
        if (@hasField(root.AILSOUNDINFO, "channel_mask")) out.channel_mask = ext_channel_mask;
    }
    if (audio_format == 0x0011 and bits_per_sample == 4) {
        // IMA ADPCM: use the fact chunk's sample count if present, else derive
        // from the block size (SDK formula).
        if (fact_samples) |fs| {
            out.samples = fs;
        } else if (block_align > 0 and num_channels > 0) {
            const spb0: u32 = @as(u32, 4) << @intCast(@min(num_channels / 2, 16));
            if (block_align > spb0) {
                const samples_per_block: u32 = 1 + (@as(u32, block_align) - spb0) * 8 / spb0;
                const blocks: u32 = (data_len +| (block_align - 1)) / block_align;
                out.samples = blocks *| samples_per_block;
            } else out.samples = 0;
        } else out.samples = 0;
    } else if (bits_per_sample > 0) {
        out.samples = @intCast(@min((@as(u64, data_len) * 8) / bits_per_sample, std.math.maxInt(u32)));
    } else out.samples = 0;
    return 1;
}

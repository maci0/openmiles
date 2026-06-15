const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;
const fs_compat = openmiles.fs_compat;
const io = openmiles.io;

fn openFileAnyPath(path: []const u8) ?std.Io.File {
    return fs_compat.openFile(io, path, .{}) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
}

pub fn AIL_file_error() callconv(.winapi) [*:0]const u8 {
    if (openmiles.last_file_error_buf[0] == 0) return "No error";
    return &openmiles.last_file_error_buf;
}
pub fn AIL_file_read(filename: [*:0]const u8, dest: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    openmiles.clearFileError();
    if (openmiles.cb_file_open != null) {
        const buf = openmiles.fileCallbackReadAll(filename) catch null;
        if (buf) |b| {
            defer openmiles.global_allocator.free(b);
            if (dest) |d| {
                @memcpy(@as([*]u8, @ptrCast(@alignCast(d)))[0..b.len], b);
                return d;
            }
            const out: [*]u8 = @ptrCast(std.c.malloc(b.len) orelse {
                openmiles.setFileError("Out of memory");
                return null;
            });
            @memcpy(out[0..b.len], b);
            return out;
        }
        openmiles.setFileError("File not found");
        return null;
    }
    const path = std.mem.span(filename);
    const file = openFileAnyPath(path) orelse {
        openmiles.setFileError("File not found");
        return null;
    };
    defer file.close(io);
    const file_len = file.length(io) catch {
        openmiles.setFileError("Stat failed");
        return null;
    };
    if (file_len == 0) return null;
    const size: usize = @intCast(file_len);
    if (dest) |d| {
        const buf: [*]u8 = @ptrCast(@alignCast(d));
        const n = file.readPositionalAll(io, buf[0..size], 0) catch {
            openmiles.setFileError("Read error");
            return null;
        };
        if (n < size) {
            @memset(buf[n..size], 0);
        }
        return d;
    } else {
        const buf: [*]u8 = @ptrCast(std.c.malloc(size) orelse {
            openmiles.setFileError("Out of memory");
            return null;
        });
        const n = file.readPositionalAll(io, buf[0..size], 0) catch {
            std.c.free(buf);
            openmiles.setFileError("Read error");
            return null;
        };
        if (n < size) {
            @memset(buf[n..size], 0);
        }
        return buf;
    }
}
pub fn AIL_file_size(filename: [*:0]const u8) callconv(.winapi) u32 {
    openmiles.clearFileError();
    if (openmiles.cb_file_open != null) {
        const open_fn = openmiles.cb_file_open.?;
        const close_fn = openmiles.cb_file_close orelse return 0;
        // open returns the file length and fills the handle out-param.
        var handle: u32 = 0;
        const size = open_fn(filename, &handle);
        if (size == 0) {
            openmiles.setFileError("File not found");
            return 0;
        }
        close_fn(handle);
        return size;
    }
    const path = std.mem.span(filename);
    const file = openFileAnyPath(path) orelse {
        openmiles.setFileError("File not found");
        return 0;
    };
    defer file.close(io);
    const file_len = file.length(io) catch {
        openmiles.setFileError("Stat failed");
        return 0;
    };
    if (file_len == 0) return 0;
    return @intCast(@min(file_len, std.math.maxInt(u32)));
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
    if (s.len >= 10 and s[0] == 'I' and s[1] == 'D' and s[2] == '3' and
        s[3] < 0xff and s[4] < 0xff and s[6] < 0x80 and s[7] < 0x80 and s[8] < 0x80 and s[9] < 0x80)
    {
        const skip: u32 = 10 + (@as(u32, s[9]) | (@as(u32, s[8]) << 7) | (@as(u32, s[7]) << 14) | (@as(u32, s[6]) << 21));
        if (skip < s.len) s = s[skip..] else return null;
    }
    const lim = @min(s.len, openmiles.max_file_header_size); // AIL_MAX_FILE_HEADER_SIZE (4096 pre-7.0, else 8192)
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

pub fn AIL_file_type(data: *anyopaque, len: u32) callconv(.winapi) i32 {
    if (len < 8) return 0; // AILFILETYPE_UNKNOWN (SDK: data==0 || size<8)
    const buf = @as([*]const u8, @ptrCast(@alignCast(data)))[0..@intCast(len)];
    const AILSOUNDINFO = openmiles.AILSOUNDINFO;
    const digital = @import("digital.zig");

    // 1. WAV: classify via the robust AIL_WAV_info parser (needs a data chunk).
    var si: AILSOUNDINFO = .{};
    var mp3_off: usize = 0;
    var mp3_len: usize = buf.len;
    if (digital.wavInfoBounded(buf.ptr, buf.len, &si) != 0) {
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
pub fn AIL_file_write(filename: [*:0]const u8, data: *anyopaque, len: u32) callconv(.winapi) i32 {
    const path = std.mem.span(filename);
    const file = fs_compat.createFile(io, path, .{}) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    defer file.close(io);
    const buf: [*]const u8 = @ptrCast(@alignCast(data));
    file.writeStreamingAll(io, buf[0..len]) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    return 1;
}
// SDK arg order is (open, close, SEEK, READ) — not (open, close, read, seek).
pub fn AIL_set_file_callbacks(open_fn: ?*anyopaque, close_fn: ?*anyopaque, seek_fn: ?*anyopaque, read_fn: ?*anyopaque) callconv(.winapi) void {
    log("AIL_set_file_callbacks\n", .{});
    openmiles.cb_file_open = if (open_fn) |f| @ptrCast(f) else null;
    openmiles.cb_file_close = if (close_fn) |f| @ptrCast(f) else null;
    openmiles.cb_file_seek = if (seek_fn) |f| @ptrCast(f) else null;
    openmiles.cb_file_read = if (read_fn) |f| @ptrCast(f) else null;
}
pub fn AIL_set_file_async_callbacks(open_fn: ?*anyopaque, close_fn: ?*anyopaque, seek_fn: ?*anyopaque, read_fn: ?*anyopaque, callback_fn: ?*anyopaque) callconv(.winapi) void {
    _ = callback_fn;
    AIL_set_file_callbacks(open_fn, close_fn, seek_fn, read_fn);
}

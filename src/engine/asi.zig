const std = @import("std");
const root = @import("../root.zig");
const ma = root.ma;
const log = root.log;
const fs_compat = root.fs_compat;

// The decoded output geometry, declared once. The ASI ABI moves PCM as raw
// bytes, so the byte/frame conversion in process and seek is the only thing
// standing between the caller and the decoder's configuration: a second copy
// of the stride in each entry point is an invariant nothing enforces, and a
// change to the output here would leave them scaling positions by the old one.
const output_format = ma.ma_format_s16;
const output_bits: u16 = 16;
const output_channels: u32 = 2;
const output_rate: u32 = 44100;
const bytes_per_frame: usize = (output_bits / 8) * output_channels;

/// Built-in ASI (Audio Stream Interface) codec implementation backed by miniaudio.
/// Decodes MP3, OGG, WAV, and FLAC to 16-bit stereo PCM at 44100 Hz.
const ASI_Stream_Impl = struct {
    decoder: ma.ma_decoder,
    pub fn open(filename: []const u8) !*ASI_Stream_Impl {
        const self = try root.global_allocator.create(ASI_Stream_Impl);
        errdefer root.global_allocator.destroy(self);
        var config = ma.ma_decoder_config_init(output_format, output_channels, output_rate);
        const resolved = try fs_compat.dupeResolvedPathZ(root.global_allocator, filename);
        defer root.global_allocator.free(resolved);
        const result = ma.ma_decoder_init_file(resolved.ptr, &config, &self.decoder);
        if (result != ma.MA_SUCCESS) {
            // Name the file and miniaudio's status: the caller only sees
            // error.DecoderInitFailed, which does not distinguish a missing
            // file from a corrupt one or from a device/format rejection.
            log("ASI_Stream_Impl.open: ma_decoder_init_file('{s}') failed with {d} ({s})\n", .{ filename, result, root.maResultDescription(result) });
            return error.DecoderInitFailed;
        }
        return self;
    }
    pub fn close(self: *ASI_Stream_Impl) void {
        _ = ma.ma_decoder_uninit(&self.decoder);
        root.global_allocator.destroy(self);
    }
};

pub const ASI_stream = anyopaque;

fn openmiles_ASI_stream_open(file_tag: u32, filename: [*:0]const u8, open_flags: u32) callconv(.c) ?*ASI_stream {
    log("openmiles.ASI_stream_open: {s} (tag={d}, flags={d})\n", .{ filename, file_tag, open_flags });
    const stream = ASI_Stream_Impl.open(std.mem.span(filename)) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
    return @ptrCast(stream);
}

fn openmiles_ASI_stream_close(stream: *ASI_stream) callconv(.c) void {
    log("openmiles.ASI_stream_close: {*}\n", .{stream});
    const s: *ASI_Stream_Impl = @ptrCast(@alignCast(stream));
    s.close();
}

fn openmiles_ASI_stream_process(stream: *ASI_stream, buffer: *anyopaque, len: i32) callconv(.c) i32 {
    if (len <= 0) return 0;
    const s: *ASI_Stream_Impl = @ptrCast(@alignCast(stream));
    var frames_read: u64 = 0;
    const frames_to_read = @as(u64, @intCast(len)) / bytes_per_frame;
    const result = ma.ma_decoder_read_pcm_frames(&s.decoder, buffer, frames_to_read, &frames_read);
    // A read error also leaves frames_read at 0, which the caller reads as the
    // end of the stream. Name the status so a truncated or corrupt file is not
    // taken for a file that simply ended.
    if (result != ma.MA_SUCCESS and result != ma.MA_AT_END) {
        log("openmiles.ASI_stream_process: ma_decoder_read_pcm_frames failed with {d} ({s})\n", .{ result, root.maResultDescription(result) });
        return 0;
    }
    return @intCast(frames_read * bytes_per_frame);
}

fn openmiles_ASI_stream_seek(stream: *ASI_stream, pos: i32) callconv(.c) i32 {
    if (pos < 0) return 0;
    const s: *ASI_Stream_Impl = @ptrCast(@alignCast(stream));
    const frame = @as(u64, @intCast(pos)) / bytes_per_frame;
    // Reporting the requested offset on a failed seek told the caller the
    // stream had moved when it had not, so the next read decoded from the old
    // position. A failed seek reports 0, the SDK's failure return.
    const result = ma.ma_decoder_seek_to_pcm_frame(&s.decoder, frame);
    if (result != ma.MA_SUCCESS) {
        log("openmiles.ASI_stream_seek: seek to frame {d} failed with {d} ({s})\n", .{ frame, result, root.maResultDescription(result) });
        return 0;
    }
    return pos;
}

fn openmiles_ASI_stream_attribute(stream: *ASI_stream, name: [*:0]const u8) callconv(.c) i32 {
    const s: *ASI_Stream_Impl = @ptrCast(@alignCast(stream));
    const attr = std.mem.span(name);
    // Saturate: both are u32 decoder values, and an i32 attribute return has
    // nowhere to report a value that does not fit, so clamping beats a panic.
    if (std.mem.eql(u8, attr, "OUTPUT RATE")) return std.math.cast(i32, s.decoder.outputSampleRate) orelse std.math.maxInt(i32);
    if (std.mem.eql(u8, attr, "OUTPUT CHANNELS")) return std.math.cast(i32, s.decoder.outputChannels) orelse std.math.maxInt(i32);
    if (std.mem.eql(u8, attr, "OUTPUT BITS")) return output_bits;
    return 0;
}

pub fn get_ASI_INTERFACE() [7]root.RIB_INTERFACE_ENTRY {
    return [_]root.RIB_INTERFACE_ENTRY{
        .{ .entry_type = .RIB_FUNCTION, .name = "ASI stream open", .token = @intFromPtr(&openmiles_ASI_stream_open), .subtype = 0 },
        .{ .entry_type = .RIB_FUNCTION, .name = "ASI stream close", .token = @intFromPtr(&openmiles_ASI_stream_close), .subtype = 0 },
        .{ .entry_type = .RIB_FUNCTION, .name = "ASI stream process", .token = @intFromPtr(&openmiles_ASI_stream_process), .subtype = 0 },
        .{ .entry_type = .RIB_FUNCTION, .name = "ASI stream seek", .token = @intFromPtr(&openmiles_ASI_stream_seek), .subtype = 0 },
        .{ .entry_type = .RIB_FUNCTION, .name = "ASI stream attribute", .token = @intFromPtr(&openmiles_ASI_stream_attribute), .subtype = 0 },
        .{ .entry_type = .RIB_ATTRIBUTE, .name = "Input file types", .token = @intFromPtr(".mp3\x00.ogg\x00.wav\x00.flac\x00"), .subtype = 0 },
        .{ .entry_type = .RIB_ATTRIBUTE, .name = "Output file types", .token = @intFromPtr(".raw\x00.pcm\x00"), .subtype = 0 },
    };
}

test "ASI stream read and seek move the decode position" {
    const testing = std.testing;
    const pcm_frames: usize = 4410;
    const pcm = try testing.allocator.alloc(u8, pcm_frames * 2);
    defer testing.allocator.free(pcm);
    for (0..pcm_frames) |i| std.mem.writeInt(i16, pcm[i * 2 ..][0..2], @intCast(i), .little);
    const wav = try root.buildWavFromPcm(testing.allocator, pcm, 1, 44100, 16);
    defer testing.allocator.free(wav);

    const dir_name = "om_asi_stream_test";
    const cwd = std.Io.Dir.cwd();
    cwd.createDir(root.io, dir_name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer cwd.deleteTree(root.io, dir_name) catch {};
    const path = dir_name ++ "/ramp.wav";
    try cwd.writeFile(root.io, .{ .sub_path = path, .data = wav });

    const stream = openmiles_ASI_stream_open(0, @ptrCast(path), 0) orelse return error.StreamOpenFailed;
    defer openmiles_ASI_stream_close(stream);

    // The attributes the caller reads to size its buffer are the same declared
    // geometry the byte/frame conversion in process and seek scales by, so a
    // caller that divides a byte budget by the attribute value agrees with the
    // stream about where a frame boundary falls.
    try testing.expectEqual(@as(i32, output_bits), openmiles_ASI_stream_attribute(stream, "OUTPUT BITS"));
    try testing.expectEqual(@as(i32, output_channels), openmiles_ASI_stream_attribute(stream, "OUTPUT CHANNELS"));
    try testing.expectEqual(@as(i32, output_rate), openmiles_ASI_stream_attribute(stream, "OUTPUT RATE"));

    // Output is 16-bit stereo, so the mono ramp appears in the left channel.
    var buf: [4096]u8 align(4) = undefined;
    try testing.expect(openmiles_ASI_stream_process(stream, &buf, 400) > 0);
    try testing.expectEqual(@as(i16, 0), std.mem.readInt(i16, buf[0..2], .little));

    // A seek inside the file reports the offset it reached, and the next read
    // decodes from there rather than from where the stream already was.
    const seek_bytes: i32 = 4000;
    try testing.expectEqual(seek_bytes, openmiles_ASI_stream_seek(stream, seek_bytes));
    try testing.expect(openmiles_ASI_stream_process(stream, &buf, 400) > 0);
    try testing.expectEqual(@as(i16, @intCast(seek_bytes / @as(i32, @intCast(bytes_per_frame)))), std.mem.readInt(i16, buf[0..2], .little));
}

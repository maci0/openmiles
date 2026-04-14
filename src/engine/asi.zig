const std = @import("std");
const root = @import("../root.zig");
const ma = root.ma;
const log = root.log;
const fs_compat = root.fs_compat;

/// Built-in ASI (Audio Stream Interface) codec implementation backed by miniaudio.
/// Decodes MP3, OGG, WAV, and FLAC to 16-bit stereo PCM at 44100 Hz.
const ASI_Stream_Impl = struct {
    decoder: ma.ma_decoder,
    is_initialized: bool = false,
    pub fn open(filename: []const u8) !*ASI_Stream_Impl {
        const self = try root.global_allocator.?.create(ASI_Stream_Impl);
        var config = ma.ma_decoder_config_init(ma.ma_format_s16, 2, 44100);
        const resolved = try fs_compat.dupeResolvedPathZ(root.global_allocator.?, filename);
        defer root.global_allocator.?.free(resolved);
        const result = ma.ma_decoder_init_file(resolved.ptr, &config, &self.decoder);
        if (result != ma.MA_SUCCESS) {
            root.global_allocator.?.destroy(self);
            return error.DecoderInitFailed;
        }
        self.is_initialized = true;
        return self;
    }
    pub fn close(self: *ASI_Stream_Impl) void {
        if (self.is_initialized) {
            _ = ma.ma_decoder_uninit(&self.decoder);
        }
        root.global_allocator.?.destroy(self);
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
    const s: *ASI_Stream_Impl = @ptrCast(@alignCast(stream));
    var frames_read: u64 = 0;
    const frames_to_read = @as(u64, @intCast(len)) / 4; // 16-bit stereo = 4 bytes/frame
    _ = ma.ma_decoder_read_pcm_frames(&s.decoder, buffer, frames_to_read, &frames_read);
    return @intCast(frames_read * 4);
}

fn openmiles_ASI_stream_seek(stream: *ASI_stream, pos: i32) callconv(.c) i32 {
    const s: *ASI_Stream_Impl = @ptrCast(@alignCast(stream));
    const frame = @as(u64, @intCast(pos)) / 4;
    _ = ma.ma_decoder_seek_to_pcm_frame(&s.decoder, frame);
    return pos;
}

fn openmiles_ASI_stream_attribute(stream: *ASI_stream, name: [*:0]const u8) callconv(.c) i32 {
    const s: *ASI_Stream_Impl = @ptrCast(@alignCast(stream));
    const attr = std.mem.span(name);
    if (std.mem.eql(u8, attr, "OUTPUT RATE")) return @intCast(s.decoder.outputSampleRate);
    if (std.mem.eql(u8, attr, "OUTPUT CHANNELS")) return @intCast(s.decoder.outputChannels);
    if (std.mem.eql(u8, attr, "OUTPUT BITS")) return 16;
    return 0;
}

pub fn get_ASI_INTERFACE() [7]root.RIB_INTERFACE_ENTRY {
    return [_]root.RIB_INTERFACE_ENTRY{
        .{ .entry_type = .RIB_FUNCTION, .name = "ASI stream open", .token = @intFromPtr(&openmiles_ASI_stream_open), .subtype = 0 },
        .{ .entry_type = .RIB_FUNCTION, .name = "ASI stream close", .token = @intFromPtr(&openmiles_ASI_stream_close), .subtype = 0 },
        .{ .entry_type = .RIB_FUNCTION, .name = "ASI stream process", .token = @intFromPtr(&openmiles_ASI_stream_process), .subtype = 0 },
        .{ .entry_type = .RIB_FUNCTION, .name = "ASI stream seek", .token = @intFromPtr(&openmiles_ASI_stream_seek), .subtype = 0 },
        .{ .entry_type = .RIB_FUNCTION, .name = "ASI stream attribute", .token = @intFromPtr(&openmiles_ASI_stream_attribute), .subtype = 0 },
        .{ .entry_type = .RIB_ATTRIBUTE, .name = "Input file types", .token = @intFromPtr(".mp3\x00.ogg\x00.wav\x00"), .subtype = 0 },
        .{ .entry_type = .RIB_ATTRIBUTE, .name = "Output file types", .token = @intFromPtr(".raw\x00.pcm\x00"), .subtype = 0 },
    };
}

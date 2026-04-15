const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;
const Sample = openmiles.Sample;
const DigitalDriver = openmiles.DigitalDriver;

pub export fn AIL_open_stream(driver_opt: ?*DigitalDriver, filename_opt: ?[*:0]const u8, stream_mem: i32) callconv(.winapi) ?*Sample {
    const driver = driver_opt orelse return null;
    const file_str = if (filename_opt) |ptr| std.mem.span(ptr) else "<null>";
    log("AIL_open_stream(driver={*}, filename='{s}', stream_mem={d})\n", .{ driver, file_str, stream_mem });
    openmiles.clearLastError();
    const s = openmiles.Sample.init(driver) catch |err| {
        log("AIL_open_stream: Failed to init Sample ({any})\n", .{err});
        openmiles.setLastError("Failed to allocate stream sample");
        return null;
    };

    if (filename_opt == null) {
        log("AIL_open_stream: Memory stream loading...\n", .{});
        if (stream_mem != 0) {
            const mem_ptr: [*]const u8 = @ptrFromInt(@as(usize, @as(u32, @bitCast(stream_mem))));
            s.loadFromUnownedMemoryUnknownSize(mem_ptr) catch |err| {
                log("AIL_open_stream: memory load failed ({any})\n", .{err});
                openmiles.setLastError("Failed to load stream from memory block");
                s.deinit();
                return null;
            };
            log("AIL_open_stream: Success via memory pointer\n", .{});
            return s;
        } else {
            log("AIL_open_stream: Null filename and null stream_mem!\n", .{});
            s.deinit();
            return null;
        }
    }
    const filename = filename_opt.?;

    if (openmiles.cb_file_open != null) {
        log("AIL_open_stream: Using custom cb_file_open\n", .{});
        const buf = openmiles.fileCallbackReadAll(filename) catch |err| {
            log("AIL_open_stream: fileCallbackReadAll failed ({any})\n", .{err});
            s.deinit();
            return null;
        };
        s.loadFromOwnedMemory(buf) catch |err| {
            log("AIL_open_stream: loadFromOwnedMemory failed ({any})\n", .{err});
            openmiles.global_allocator.free(buf);
            openmiles.setLastError("Failed to load stream from callback buffer");
            s.deinit();
            return null;
        };
        log("AIL_open_stream: Success via custom callbacks\n", .{});
        return s;
    }
    log("AIL_open_stream: loading via loadFromFile\n", .{});
    s.loadFromFile(file_str) catch |err| {
        log("AIL_open_stream: loadFromFile failed ({any})\n", .{err});
        openmiles.setLastError("Failed to open stream file");
        s.deinit();
        return null;
    };
    log("AIL_open_stream: Success via loadFromFile\n", .{});
    return s;
}
pub export fn AIL_close_stream(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_close_stream(s={*})\n", .{s});
    s.deinit();
}
pub export fn AIL_start_stream(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_start_stream(s={*})\n", .{s});
    s.start();
}
pub export fn AIL_pause_stream(s_opt: ?*Sample, onoff: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_pause_stream(s={*}, onoff={d})\n", .{ s, onoff });
    if (onoff != 0) s.pause() else s.resumePlayback();
}
pub export fn AIL_set_stream_volume(s_opt: ?*Sample, volume: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_stream_volume(s={*}, volume={d})\n", .{ s, volume });
    s.setVolume(volume);
}
pub export fn AIL_set_stream_loop_count(s_opt: ?*Sample, count: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_stream_loop_count(s={*}, count={d})\n", .{ s, count });
    s.setLoopCount(count);
}
pub export fn AIL_register_stream_callback(s_opt: ?*Sample, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    log("AIL_register_stream_callback(s={*}, callback={*})\n", .{ s, callback });
    const prev: ?*anyopaque = @ptrFromInt(s.eos_callback);
    s.eos_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_auto_service_stream(s_opt: ?*Sample, onoff: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_auto_service_stream(s={*}, onoff={d})\n", .{ s, onoff });
}
pub export fn AIL_set_stream_playback_rate(s_opt: ?*Sample, rate: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_stream_playback_rate(s={*}, rate={d})\n", .{ s, rate });
    s.setPlaybackRate(rate);
}
pub export fn AIL_set_stream_pan(s_opt: ?*Sample, pan: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_stream_pan(s={*}, pan={d})\n", .{ s, pan });
    s.setPan(pan);
}
pub export fn AIL_set_stream_ms_position(s_opt: ?*Sample, ms: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_stream_ms_position(s={*}, ms={d})\n", .{ s, ms });
    s.setMsPosition(ms);
}
pub export fn AIL_stream_status(s_opt: ?*Sample) callconv(.winapi) u32 {
    const s = s_opt orelse return 0;
    return @intFromEnum(s.status());
}
pub export fn AIL_stream_playback_rate(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return @intFromFloat(s.target_rate orelse 44100.0);
}
pub export fn AIL_stream_volume(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return s.original_volume;
}
pub export fn AIL_stream_pan(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return openmiles.panToMss(s.pan);
}
pub export fn AIL_stream_loop_count(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return s.loop_count;
}
pub export fn AIL_stream_ms_position(s_opt: ?*Sample, total_ms: ?*i32, current_ms: ?*i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    const pos = s.getMsPosition();
    if (total_ms) |t| t.* = pos.total;
    if (current_ms) |c| c.* = pos.current;
}
pub export fn AIL_stream_position(s_opt: ?*Sample) callconv(.winapi) u32 {
    const s = s_opt orelse return 0;
    return s.getPosition();
}
pub export fn AIL_set_stream_position(s_opt: ?*Sample, pos: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setPosition(pos);
}
pub export fn AIL_stream_user_data(s_opt: ?*Sample, index: i32) callconv(.winapi) u32 {
    const s = s_opt orelse return 0;
    const idx: usize = @intCast(@min(@max(index, 0), 7));
    return s.user_data[idx];
}
pub export fn AIL_set_stream_user_data(s_opt: ?*Sample, index: i32, value: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    const idx: usize = @intCast(@min(@max(index, 0), 7));
    s.user_data[idx] = value;
}
pub export fn AIL_stream_reverb(s_opt: ?*Sample, room_type: ?*f32, level: ?*f32, reflect_time: ?*f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    const rev = s.getReverb();
    if (room_type) |p| p.* = rev.room_type;
    if (level) |p| p.* = rev.level;
    if (reflect_time) |p| p.* = rev.reflect_time;
}
pub export fn AIL_set_stream_reverb(s_opt: ?*Sample, room_type: f32, level: f32, reflect_time: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setReverb(room_type, level, reflect_time);
}
pub export fn AIL_stream_info(s_opt: ?*Sample, playback_rate: ?*i32, channels: ?*i32, bits: ?*i32, format: ?*i32, len: ?*i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    if (s.is_initialized and s.decoder != null) {
        const dec = s.decoder.?;
        const rate: i32 = @intCast(dec.outputSampleRate);
        const ch: i32 = @intCast(dec.outputChannels);
        const bps = openmiles.ma.ma_get_bytes_per_sample(dec.outputFormat);
        const b: i32 = if (bps > 0) @intCast(bps * 8) else 16;
        if (playback_rate) |p| p.* = rate;
        if (channels) |p| p.* = ch;
        if (bits) |p| p.* = b;
        if (format) |p| {
            p.* = switch (ch) {
                1 => if (b == 8) 0 else 1,
                else => if (b == 8) 2 else 3,
            };
        }
        var length_frames: u64 = 0;
        _ = openmiles.ma.ma_sound_get_length_in_pcm_frames(&s.sound, &length_frames);
        const bpf: u64 = if (bps > 0) @as(u64, bps) * @as(u64, @intCast(dec.outputChannels)) else 4;
        if (len) |p| p.* = @intCast(@min(length_frames * bpf, std.math.maxInt(i32)));
    } else {
        if (playback_rate) |p| p.* = 44100;
        if (channels) |p| p.* = 2;
        if (bits) |p| p.* = 16;
        if (format) |p| p.* = 3;
        if (len) |p| p.* = 0;
    }
}
pub export fn AIL_set_stream_loop_block(s_opt: ?*Sample, loop_start: i32, loop_end: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setLoopBlock(loop_start, loop_end);
}
pub export fn AIL_service_stream(s_opt: ?*Sample, onoff: i32) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    _ = s;
    _ = onoff;
    return 1;
}
pub export fn AIL_register_EOF_callback(s_opt: ?*Sample, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(s.eos_callback);
    s.eos_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_set_stream_processor(s_opt: ?*Sample, stage: i32, processor: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    const idx: usize = @intCast(@min(@max(stage, 0), 1));
    const prev: ?*anyopaque = @ptrFromInt(s.sample_processors[idx]);
    s.sample_processors[idx] = if (processor) |p| @intFromPtr(p) else 0;
    return prev;
}
pub export fn AIL_filter_stream_attribute(s_opt: ?*Sample, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const s = s_opt orelse return;
    if (s.attached_filter) |filter| {
        const out: *f32 = @ptrCast(@alignCast(val));
        out.* = filter.getAttribute(std.mem.span(name));
    }
}
pub export fn AIL_set_filter_stream_preference(s_opt: ?*Sample, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const s = s_opt orelse return;
    if (s.attached_filter) |filter| {
        const v: *const f32 = @ptrCast(@alignCast(val));
        filter.setAttribute(std.mem.span(name), v.*);
    }
}

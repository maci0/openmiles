const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;
const Sample = openmiles.Sample;
const DigitalDriver = openmiles.DigitalDriver;

// Legacy 3.x AIL_open_stream_ex(dig, filename, stream_mem, flags) @16 — the
// extended form adds a flags word; we open the stream the same way and ignore
// the extra flags (they selected DirectSound buffer behavior on the old backend).
pub fn AIL_open_stream_ex(driver_opt: ?*DigitalDriver, filename_opt: ?[*:0]const u8, stream_mem: i32, flags: i32) callconv(.winapi) ?*Sample {
    _ = flags;
    return AIL_open_stream(driver_opt, filename_opt, stream_mem);
}
// `_AIL_open_stream_by_sample@16`: an undocumented internal that leaked into
// the 6.1a export table only (gone again by 6.1c, never in any header). Like
// `stream_background`, it is an accidental export, not a public API, so there
// is no documented signature or behavior to reproduce. We export the exact
// decorated name (@16 = four stdcall args) backed by a safe stub that reports
// failure (null HSTREAM), purely so the 6.1a export table byte-matches.
pub fn AIL_open_stream_by_sample(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: i32) callconv(.winapi) ?*Sample {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    return null;
}
pub fn AIL_open_stream(driver_opt: ?*DigitalDriver, filename_opt: ?[*:0]const u8, stream_mem: i32) callconv(.winapi) ?*Sample {
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
pub fn AIL_close_stream(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_close_stream(s={*})\n", .{s});
    s.deinit();
}
pub fn AIL_start_stream(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_start_stream(s={*})\n", .{s});
    s.start();
}
pub fn AIL_pause_stream(s_opt: ?*Sample, onoff: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_pause_stream(s={*}, onoff={d})\n", .{ s, onoff });
    if (onoff != 0) s.pause() else s.resumePlayback();
}
pub fn AIL_set_stream_volume(s_opt: ?*Sample, volume: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_stream_volume(s={*}, volume={d})\n", .{ s, volume });
    s.setVolume(volume);
}
pub fn AIL_set_stream_loop_count(s_opt: ?*Sample, count: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_stream_loop_count(s={*}, count={d})\n", .{ s, count });
    s.setLoopCount(count);
}
pub fn AIL_register_stream_callback(s_opt: ?*Sample, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    log("AIL_register_stream_callback(s={*}, callback={*})\n", .{ s, callback });
    const prev: ?*anyopaque = @ptrFromInt(s.eos_callback);
    s.eos_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub fn AIL_auto_service_stream(s_opt: ?*Sample, onoff: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_auto_service_stream(s={*}, onoff={d})\n", .{ s, onoff });
}
pub fn AIL_set_stream_playback_rate(s_opt: ?*Sample, rate: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_stream_playback_rate(s={*}, rate={d})\n", .{ s, rate });
    s.setPlaybackRate(rate);
}
pub fn AIL_set_stream_pan(s_opt: ?*Sample, pan: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_stream_pan(s={*}, pan={d})\n", .{ s, pan });
    s.setPan(pan);
}
// Combined F32 volume/pan (0.0..1.0), the form modern v6+ titles use on streams.
pub fn AIL_set_stream_volume_pan(s_opt: ?*Sample, volume: f32, pan: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_stream_volume_pan(s={*}, volume={d}, pan={d})\n", .{ s, volume, pan });
    s.setVolumePanF(volume, pan);
}
pub fn AIL_set_stream_ms_position(s_opt: ?*Sample, ms: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_stream_ms_position(s={*}, ms={d})\n", .{ s, ms });
    s.setMsPosition(ms);
}
pub fn AIL_stream_status(s_opt: ?*Sample) callconv(.winapi) i32 {
    // SDK mssstrm.cpp returns S32 -1 for a null (or errored) stream.
    const s = s_opt orelse return -1;
    // SDK mssstrm.cpp AIL_API_stream_status maps stream states differently from a
    // plain HSAMPLE: a paused stream (playcontrol&8) OR a not-yet-started stream
    // (playcontrol==0) reports SMP_STOPPED -- whereas a paused 2D sample reports
    // SMP_PLAYING and a never-started sample reports SMP_DONE. Only a stream that
    // has actually finished reports SMP_DONE.
    const ma = openmiles.ma;
    const done: i32 = @intFromEnum(openmiles.SampleStatus.done);
    const stopped: i32 = @intFromEnum(openmiles.SampleStatus.stopped);
    if (s.is_done) return done;
    if (s.is_paused) return stopped;
    if (s.is_initialized) {
        if (ma.ma_sound_is_playing(&s.sound) != 0) return @intFromEnum(openmiles.SampleStatus.playing);
        if (ma.ma_sound_at_end(&s.sound) != 0) return done;
    }
    // Opened but not playing / explicitly stopped -> SMP_STOPPED.
    return stopped;
}
pub fn AIL_stream_playback_rate(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return openmiles.satI32(s.target_rate orelse 44100.0);
}
pub fn AIL_stream_volume(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return s.original_volume;
}
pub fn AIL_stream_pan(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    // Return the 0..127 pan the app set; s.pan holds the balance-panner value.
    return s.original_pan;
}
pub fn AIL_stream_loop_count(s_opt: ?*Sample) callconv(.winapi) i32 {
    // SDK mssstrm.cpp AIL_API_stream_loop_count: returns -1 on a null stream, and
    // for a preloaded stream delegates to AIL_sample_loop_count -- which returns
    // the REMAINING loop count (S->loop_count), not the original. Our streams are
    // preloaded, so mirror AIL_sample_loop_count exactly (loops_remaining).
    const s = s_opt orelse return -1;
    return s.loops_remaining;
}
pub fn AIL_stream_ms_position(s_opt: ?*Sample, total_ms: ?*i32, current_ms: ?*i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    const pos = s.getMsPosition();
    if (total_ms) |t| t.* = pos.total;
    if (current_ms) |c| c.* = pos.current;
}
pub fn AIL_stream_position(s_opt: ?*Sample) callconv(.winapi) i32 {
    // SDK mssstrm.cpp AIL_API_stream_position returns S32 with -1 on a null
    // stream (for a preloaded stream the position is AIL_sample_position(samp)).
    const s = s_opt orelse return -1;
    const pos = s.getPosition();
    return if (pos > std.math.maxInt(i32)) std.math.maxInt(i32) else @intCast(pos);
}
pub fn AIL_set_stream_position(s_opt: ?*Sample, pos: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setPosition(pos);
}
pub fn AIL_stream_user_data(s_opt: ?*Sample, index: i32) callconv(.winapi) u32 {
    const s = s_opt orelse return 0;
    const idx: usize = @intCast(@min(@max(index, 0), 7));
    return s.user_data[idx];
}
pub fn AIL_set_stream_user_data(s_opt: ?*Sample, index: i32, value: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    const idx: usize = @intCast(@min(@max(index, 0), 7));
    s.user_data[idx] = value;
}
// SDK: AIL_stream_reverb(HSTREAM, F32* reverb_level, F32* reverb_reflect_time,
// F32* reverb_decay_time). The engine's .room_type field holds the decay value.
pub fn AIL_stream_reverb(s_opt: ?*Sample, reverb_level: ?*f32, reverb_reflect_time: ?*f32, reverb_decay_time: ?*f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    const rev = s.getReverb();
    if (reverb_level) |p| p.* = rev.level;
    if (reverb_reflect_time) |p| p.* = rev.reflect_time;
    if (reverb_decay_time) |p| p.* = rev.room_type;
}
// SDK (mss.h): AIL_set_stream_reverb(HSTREAM, F32 reverb_level,
// F32 reverb_reflect_time, F32 reverb_decay_time) -- no "room_type". Map onto the
// engine's setReverb(decay, wet level, delay).
pub fn AIL_set_stream_reverb(s_opt: ?*Sample, reverb_level: f32, reverb_reflect_time: f32, reverb_decay_time: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setReverb(reverb_decay_time, reverb_level, reverb_reflect_time);
}
// Real MSS: AIL_stream_info(HSTREAM, S32 *datarate, S32 *sndtype, S32 *length,
// S32 *memory) — datarate in bytes/sec, sndtype a DIG_F format code, length in
// bytes, memory the stream's working-buffer size.
pub fn AIL_stream_info(s_opt: ?*Sample, datarate: ?*i32, sndtype: ?*i32, length: ?*i32, memory: ?*i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    if (s.is_initialized and s.decoder != null) {
        const dec = s.decoder.?;
        const ch: u64 = @intCast(dec.outputChannels);
        const bps = openmiles.ma.ma_get_bytes_per_sample(dec.outputFormat);
        const bps64: u64 = if (bps > 0) bps else 2;
        const b: i32 = @intCast(bps64 * 8);
        if (datarate) |p| p.* = @intCast(@min(@as(u64, dec.outputSampleRate) * ch * bps64, std.math.maxInt(i32)));
        if (sndtype) |p| p.* = switch (ch) {
            1 => if (b == 8) 0 else 1,
            else => if (b == 8) 2 else 3,
        };
        var length_frames: u64 = 0;
        _ = openmiles.ma.ma_sound_get_length_in_pcm_frames(&s.sound, &length_frames);
        const bpf: u64 = bps64 * ch;
        // Saturate the multiply: length_frames is decoder/header-derived, so the
        // product could otherwise overflow u64 before the clamp.
        if (length) |p| p.* = @intCast(@min(length_frames *| bpf, std.math.maxInt(i32)));
        if (memory) |p| p.* = 0; // working-buffer size not separately tracked
    } else {
        if (datarate) |p| p.* = 44100 * 2 * 2;
        if (sndtype) |p| p.* = 3;
        if (length) |p| p.* = 0;
        if (memory) |p| p.* = 0;
    }
}
pub fn AIL_set_stream_loop_block(s_opt: ?*Sample, loop_start: i32, loop_end: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setLoopBlock(loop_start, loop_end);
}
pub fn AIL_service_stream(s_opt: ?*Sample, onoff: i32) callconv(.winapi) i32 {
    _ = onoff; // `fillup`: block on pending async IO (no async IO in our model)
    // SDK mssstrm.cpp AIL_API_service_stream returns S32 -1 for a null stream or
    // one that has errored/finished (alldone), otherwise the number of bytes
    // serviced (start_IOs_if_we_can). Our streams are fully preloaded, so there
    // is never any IO to service -> 0 bytes on a live stream, -1 once finished.
    const s = s_opt orelse return -1;
    if (s.is_done) return -1;
    return 0;
}
pub fn AIL_register_EOF_callback(s_opt: ?*Sample, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(s.eos_callback);
    s.eos_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub fn AIL_set_stream_processor(s_opt: ?*Sample, stage: i32, processor: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    const idx: usize = @intCast(@min(@max(stage, 0), 1));
    const prev: ?*anyopaque = @ptrFromInt(s.sample_processors[idx]);
    s.sample_processors[idx] = if (processor) |p| @intFromPtr(p) else 0;
    return prev;
}
pub fn AIL_filter_stream_attribute(s_opt: ?*Sample, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const s = s_opt orelse return;
    if (s.attached_filter) |filter| {
        const out: *f32 = @ptrCast(@alignCast(val));
        out.* = filter.getAttribute(std.mem.span(name));
    }
}
pub fn AIL_set_filter_stream_preference(s_opt: ?*Sample, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const s = s_opt orelse return;
    if (s.attached_filter) |filter| {
        const v: *const f32 = @ptrCast(@alignCast(val));
        filter.setAttribute(std.mem.span(name), v.*);
    }
}

// --- 6.5/6.6-only stream attribute APIs --------------------------------------
// These existed only in MSS 6.5/6.6 (dropped in 7.x). A stream handle is a
// Sample, so each mirrors the corresponding AIL_*_sample_* form exactly.

// Per-channel volume levels: store as volume=max(L,R), pan=R/(L+R); the getter
// reconstructs L/R (lossless when both were <=1). Matches AIL_sample_volume_levels.
pub fn AIL_set_stream_volume_levels(s_opt: ?*Sample, left_level: f32, right_level: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setVolumeLevels(left_level, right_level); // verbatim L/R, like the sample form
}
pub fn AIL_stream_volume_levels(s_opt: ?*Sample, left_level: ?*f32, right_level: ?*f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    if (left_level) |p| p.* = s.v51_levels[0];
    if (right_level) |p| p.* = s.v51_levels[1];
}
// Combined volume/pan getter (the setter, AIL_set_stream_volume_pan, is above).
pub fn AIL_stream_volume_pan(s_opt: ?*Sample, volume: ?*f32, pan: ?*f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    if (volume) |p| p.* = s.save_vol_f; // exact float (not i32-quantized)
    if (pan) |p| p.* = s.save_pan_f;
}
// Reverb dry/wet levels (stored independently). Matches AIL_sample_reverb_levels.
pub fn AIL_set_stream_reverb_levels(s_opt: ?*Sample, dry_level: f32, wet_level: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.reverb_dry_level = dry_level;
    s.setReverb(s.reverb_room_type, std.math.clamp(wet_level, 0.0, 1.0), if (s.reverb_reflect_time > 0) s.reverb_reflect_time else 0.05);
    s.reverb_level = wet_level; // verbatim for the getter (SDK stores dry/wet as-is)
}
pub fn AIL_stream_reverb_levels(s_opt: ?*Sample, dry_level: ?*f32, wet_level: ?*f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    if (dry_level) |p| p.* = s.reverb_dry_level;
    if (wet_level) |p| p.* = s.reverb_level;
}
// Low-pass cutoff (no-channel form, like the 6.5-7.x sample variant).
pub fn AIL_set_stream_low_pass_cut_off(s_opt: ?*Sample, cut_off: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setLowPassNormalized(cut_off); // normalized 0..1 (MSS), not Hz
}
pub fn AIL_stream_low_pass_cut_off(s_opt: ?*Sample) callconv(.winapi) f32 {
    // 1.0 = fully open (no filtering) is the MSS default, returned for a null
    // handle too — consistent with AIL_sample_low_pass_cut_off (wavefile.cpp).
    const s = s_opt orelse return 1.0;
    return s.getLowPassNormalized();
}

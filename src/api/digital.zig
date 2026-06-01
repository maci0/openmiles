const std = @import("std");
const builtin = @import("builtin");
const openmiles = @import("openmiles");
const log = openmiles.log;
const DigitalDriver = openmiles.DigitalDriver;
const Sample = openmiles.Sample;
const Provider = openmiles.Provider;
const Sequence = openmiles.Sequence;
const Filter = openmiles.Filter;
const MidiDriver = openmiles.MidiDriver;
const AILSOUNDINFO = openmiles.AILSOUNDINFO;

// Miles startup is reference-counted: AIL_startup returns the new use count (1
// on the first call), and the public AIL_startup maps to AIL_startup_reg/_stack
// in mss.h. AIL_shutdown stays void. We don't re-init the engine on nested
// calls; the count just mirrors the documented return value.
var g_startup_count: i32 = 0;
pub fn AIL_startup() callconv(.winapi) i32 {
    log("ENTER AIL_startup\n", .{});
    openmiles.startup();
    g_startup_count +|= 1;
    log("EXIT AIL_startup\n", .{});
    return g_startup_count;
}
pub fn AIL_shutdown() callconv(.winapi) void {
    log("AIL_shutdown()\n", .{});
    openmiles.shutdown();
    if (g_startup_count > 0) g_startup_count -= 1;
}
pub fn AIL_set_redist_directory(path: [*:0]const u8) callconv(.winapi) [*:0]const u8 {
    // SDK returns char* — a pointer to the stored redist directory so callers
    // can read it back. (EAX was previously left undefined as a void return.)
    log("AIL_set_redist_directory(path={s})\n", .{path});
    openmiles.setRedistDirectory(std.mem.span(path));
    return openmiles.redistDirectoryZ();
}
pub fn AIL_last_error() callconv(.winapi) [*:0]const u8 {
    if (openmiles.last_error_buf[0] == 0) return "";
    return &openmiles.last_error_buf;
}
pub fn AIL_get_preference(number: u32) callconv(.winapi) i32 {
    return openmiles.getPreference(number);
}
pub fn AIL_set_preference(number: u32, value: i32) callconv(.winapi) i32 {
    log("AIL_set_preference(number={d}, value={d})\n", .{ number, value });
    return openmiles.setPreference(number, value);
}
pub fn AIL_waveOutOpen(drvr_ptr: ?*?*DigitalDriver, lphwo: ?*u32, device_id: i32, format: ?*anyopaque) callconv(.winapi) u32 {
    log("AIL_waveOutOpen(drvr_ptr={*}, lphwo={*}, device_id={d}, format={*})\n", .{ drvr_ptr, lphwo, device_id, format });
    if (drvr_ptr) |ptr| {
        const driver = openmiles.DigitalDriver.init(openmiles.global_allocator, 44100, 16, 2) catch |err| {
            log("Error: {any}\n", .{err});
            return 1;
        }; // MMSYSERR_ERROR
        ptr.* = driver;
    }
    if (lphwo) |ptr| {
        ptr.* = 0x12345678; // Dummy waveOut handle
    }
    return 0; // MMSYSERR_NOERROR
}
pub fn AIL_digital_handle_release(driver_opt: ?*DigitalDriver) callconv(.winapi) i32 {
    const driver = driver_opt orelse return 0;
    log("AIL_digital_handle_release(driver={*})\n", .{driver});
    return 1;
}
pub fn AIL_digital_handle_reacquire(driver_opt: ?*DigitalDriver) callconv(.winapi) i32 {
    const driver = driver_opt orelse return 0;
    log("AIL_digital_handle_reacquire(driver={*})\n", .{driver});
    return 1;
}
pub fn AIL_set_named_sample_file(s_opt: ?*Sample, file_type: [*:0]const u8, file_image: *const anyopaque, size: i32, flags: u32) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    log("AIL_set_named_sample_file(s={*}, type={s}, image={*}, size={d}, flags={d})\n", .{ s, file_type, file_image, size, flags });
    openmiles.clearLastError();
    const ft = std.mem.span(file_type);
    const is_raw = std.ascii.eqlIgnoreCase(ft, "raw") or
        std.ascii.eqlIgnoreCase(ft, ".raw") or
        std.ascii.eqlIgnoreCase(ft, "pcm") or
        std.ascii.eqlIgnoreCase(ft, ".pcm");
    if (std.ascii.eqlIgnoreCase(ft, "mp3") or std.ascii.eqlIgnoreCase(ft, ".mp3")) {
        log("AIL_set_named_sample_file is routing MP3 directly to decoder\n", .{});
    }
    if (is_raw and size > 0) {
        s.setAddress(@constCast(file_image), @intCast(size)) catch {
            openmiles.setLastError("Failed to load raw PCM sample");
            return 0;
        };
        return 1;
    }
    // Dump header bytes when size is known to be large enough
    const ptr: [*]const u8 = @ptrCast(file_image);
    if (size >= 16) {
        log("AIL_set_named_sample_file: Header bytes: {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2} {X:0>2}\n", .{ ptr[0], ptr[1], ptr[2], ptr[3], ptr[4], ptr[5], ptr[6], ptr[7], ptr[8], ptr[9], ptr[10], ptr[11], ptr[12], ptr[13], ptr[14], ptr[15] });
    } else if (size > 0) {
        log("AIL_set_named_sample_file: Buffer too small for header dump (size={d})\n", .{size});
    }
    s.load(@constCast(file_image), size) catch |err| {
        log("AIL_set_named_sample_file: Failed to load sample file ({any})\n", .{err});
        openmiles.setLastError("Failed to load named sample file");
        return 0;
    };
    return 1;
}
pub fn AIL_sample_volume(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return s.original_volume;
}
pub fn AIL_sample_pan(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    // Return the 0..127 pan the app set; s.pan holds the balance-panner value.
    return s.original_pan;
}
pub fn AIL_sample_playback_rate(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    // SDK (wavefile.cpp AIL_API_sample_playback_rate) returns S->original_playback_
    // rate verbatim. AIL_API_init_sample seeds it to 11025; loading a file
    // overwrites it with the file's native rate, and AIL_set_sample_playback_rate
    // overwrites it with the app value. So: explicit override first, then the
    // loaded decoder's native rate, then the 11025 init default for a fresh,
    // unloaded sample (NOT 44100).
    if (s.target_rate) |tr| return openmiles.satI32(tr);
    if (s.decoder) |d| return @intCast(d.outputSampleRate);
    return 11025;
}
// SDK: AIL_set_sample_volume_pan(HSAMPLE, F32 volume, F32 pan) — floats in 0.0..1.0,
// not the S32 0..127 of the separate set_sample_volume/set_sample_pan.
pub fn AIL_set_sample_volume_pan(s_opt: ?*Sample, volume: f32, pan: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_volume_pan(s={*}, volume={d}, pan={d})\n", .{ s, volume, pan });
    s.setVolumePanF(volume, pan);
}
pub fn AIL_active_sample_count(driver_opt: ?*DigitalDriver) callconv(.winapi) u32 {
    const driver = driver_opt orelse return 0;
    return driver.getActiveSampleCount();
}
pub fn AIL_sample_ms_position(s_opt: ?*Sample, total_ms: ?*i32, current_ms: ?*i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    const pos = s.getMsPosition();
    if (total_ms) |t| t.* = pos.total;
    if (current_ms) |c| c.* = pos.current;
}
pub fn AIL_set_sample_ms_position(s_opt: ?*Sample, ms: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_ms_position(s={*}, ms={d})\n", .{ s, ms });
    s.setMsPosition(ms);
}
pub fn AIL_sample_position(s_opt: ?*Sample) callconv(.winapi) u32 {
    const s = s_opt orelse return 0;
    return s.getPosition();
}
pub fn AIL_set_sample_position(s_opt: ?*Sample, pos: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_position(s={*}, pos={d})\n", .{ s, pos });
    s.setPosition(pos);
}
pub fn AIL_sample_loop_count(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return -1; // SDK (wavefile.cpp) returns -1 on null, not 0
    // SDK returns S->loop_count, which decrements during playback (remaining
    // loops), while orig_loop_count (AIL_sample_loop_block) holds the original.
    // Our loops_remaining tracks the same value (reset to loop_count on start).
    return s.loops_remaining;
}
pub fn AIL_register_EOS_callback(s_opt: ?*Sample, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    log("AIL_register_EOS_callback(s={*}, callback={*})\n", .{ s, callback });
    const prev: ?*anyopaque = @ptrFromInt(s.eos_callback);
    s.eos_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub fn AIL_open_digital_driver(frequency: u32, bits: i32, channels: i32, flags: u32) callconv(.winapi) ?*DigitalDriver {
    log("AIL_open_digital_driver(freq={d}, bits={d}, chans={d}, flags={d})\n", .{ frequency, bits, channels, flags });
    return openmiles.openDigitalDriver(frequency, bits, channels);
}
pub fn AIL_close_digital_driver(driver_opt: ?*DigitalDriver) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    log("AIL_close_digital_driver(driver={*})\n", .{driver});
    openmiles.closeDigitalDriver(driver);
}
pub fn AIL_serve() callconv(.winapi) void {}
pub fn AIL_set_digital_master_volume(driver_opt: ?*DigitalDriver, master_volume: i32) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    log("AIL_set_digital_master_volume(driver={*}, volume={d})\n", .{ driver, master_volume });
    // The master volume is a LINEAR final gain (the F32 AIL_set_digital_master_
    // volume_level sets dig->master_volume directly with no curve, per
    // wavefile.cpp), unlike the perceptual ^(10/6) sample-volume curve.
    const clamped: f32 = @floatFromInt(std.math.clamp(master_volume, 0, 127));
    driver.setMasterVolume(clamped / 127.0);
}
pub fn AIL_digital_master_volume(driver_opt: ?*DigitalDriver) callconv(.winapi) i32 {
    const driver = driver_opt orelse return 0;
    return openmiles.satI32(@round(driver.getMasterVolume() * 127.0));
}
pub fn AIL_allocate_sample_handle(driver_opt: ?*DigitalDriver) callconv(.winapi) ?*Sample {
    const driver = driver_opt orelse return null;
    log("AIL_allocate_sample_handle(driver={*})\n", .{driver});
    return openmiles.Sample.init(driver) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
}
pub fn AIL_release_sample_handle(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_release_sample_handle(s={*})\n", .{s});
    s.deinit();
}
pub fn AIL_init_sample(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_init_sample(s={*})\n", .{s});
    s.reset();
}
// v7 carried two extra (now-unused) slots: void AIL_init_sample(HSAMPLE, S32, S32) @12.
pub fn AIL_init_sample_v7(s_opt: ?*Sample, a1: i32, a2: i32) callconv(.winapi) void {
    _ = a1;
    _ = a2;
    AIL_init_sample(s_opt);
}
// v8+ gained a `format` argument: S32 AIL_init_sample(HSAMPLE S, S32 format) @8.
// Exported as _AIL_init_sample@8 for v8/v9 via a symbol override.
pub fn AIL_init_sample_v8(s_opt: ?*Sample, format: i32) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    _ = format; // output format selection: the miniaudio mixer is format-agnostic
    s.reset();
    return 1;
}
pub fn AIL_set_sample_file(s_opt: ?*Sample, data: *anyopaque, block: i32) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    log("AIL_set_sample_file(s={*}, data={*}, block={d})\n", .{ s, data, block });
    openmiles.clearLastError();
    // set_sample_file always loads a complete file image. Chunked double-buffered
    // streaming uses AIL_set_sample_type + AIL_load_sample_buffer instead, so the
    // block parameter is not meaningful here.
    s.load(data, -1) catch {
        openmiles.setLastError("Failed to load sample file");
        return 0;
    };
    return 1;
}
pub fn AIL_set_sample_address(s_opt: ?*Sample, data: *anyopaque, size: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_address(s={*}, data={*}, size={d})\n", .{ s, data, size });
    s.setAddress(data, size) catch |err| {
        log("AIL_set_sample_address: failed: {any}\n", .{err});
    };
}
pub fn AIL_set_sample_type(s_opt: ?*Sample, format: u32, flags: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_type(s={*}, format={d}, flags={d})\n", .{ s, format, flags });
    s.setType(format, flags);
}
pub fn AIL_start_sample(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_start_sample(s={*})\n", .{s});
    s.start();
}
pub fn AIL_stop_sample(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_stop_sample(s={*})\n", .{s});
    s.stop();
}
pub fn AIL_pause_sample(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_pause_sample(s={*})\n", .{s});
    s.pause();
}
pub fn AIL_resume_sample(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_resume_sample(s={*})\n", .{s});
    s.resumePlayback();
}
pub fn AIL_end_sample(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_end_sample(s={*})\n", .{s});
    s.end();
}
pub fn AIL_sample_status(s_opt: ?*Sample) callconv(.winapi) u32 {
    const s = s_opt orelse return 0;
    return @intFromEnum(s.status());
}
pub fn AIL_set_sample_volume(s_opt: ?*Sample, volume: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_volume(s={*}, volume={d})\n", .{ s, volume });
    s.setVolume(volume);
}
pub fn AIL_set_sample_pan(s_opt: ?*Sample, pan: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_pan(s={*}, pan={d})\n", .{ s, pan });
    s.setPan(pan);
}
pub fn AIL_set_sample_playback_rate(s_opt: ?*Sample, rate: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_playback_rate(s={*}, rate={d})\n", .{ s, rate });
    s.setPlaybackRate(rate);
}
pub fn AIL_set_sample_loop_count(s_opt: ?*Sample, count: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_loop_count(s={*}, count={d})\n", .{ s, count });
    s.setLoopCount(count);
}
pub fn AIL_sample_user_data(s_opt: ?*Sample, index: i32) callconv(.winapi) u32 {
    const s = s_opt orelse return 0;
    const idx: usize = @intCast(@min(@max(index, 0), 7));
    return s.user_data[idx];
}
pub fn AIL_set_sample_user_data(s_opt: ?*Sample, index: i32, value: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    const idx: usize = @intCast(@min(@max(index, 0), 7));
    s.user_data[idx] = value;
}
// SDK (mss.h 6.x): AIL_(set_)sample_reverb(HSAMPLE, F32 reverb_level,
// F32 reverb_reflect_time, F32 reverb_decay_time) -- there is NO "room_type" arg.
// The engine's setReverb takes (decay, wet level, delay), so map accordingly.
pub fn AIL_sample_reverb(s_opt: ?*Sample, reverb_level: ?*f32, reverb_reflect_time: ?*f32, reverb_decay_time: ?*f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    const rev = s.getReverb(); // .room_type holds the decay, .level wet, .reflect_time delay
    if (reverb_level) |p| p.* = rev.level;
    if (reverb_reflect_time) |p| p.* = rev.reflect_time;
    if (reverb_decay_time) |p| p.* = rev.room_type;
}
pub fn AIL_set_sample_reverb(s_opt: ?*Sample, reverb_level: f32, reverb_reflect_time: f32, reverb_decay_time: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setReverb(reverb_decay_time, reverb_level, reverb_reflect_time);
}
pub fn AIL_set_sample_loop_block(s_opt: ?*Sample, loop_start: i32, loop_end: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    // SDK (AIL_API_set_sample_loop_block): both -2 is a no-op; a -2 offset means
    // "keep the current one"; if start > end (unsigned) the two are swapped.
    if (loop_start == -2 and loop_end == -2) return;
    const bpf: u64 = s.bytesPerFrame();
    var start = loop_start;
    var end = loop_end;
    if (start == -2) start = @intCast(@min(s.loop_start_frame *| bpf, @as(u64, std.math.maxInt(i32))));
    if (end == -2) end = if (s.loop_end_frame > 0) @intCast(@min(s.loop_end_frame *| bpf, @as(u64, std.math.maxInt(i32)))) else 0;
    if (@as(u32, @bitCast(start)) > @as(u32, @bitCast(end))) {
        const t = start;
        start = end;
        end = t;
    }
    s.setLoopBlock(start, end);
}
pub fn AIL_set_sample_adpcm_block_size(s_opt: ?*Sample, block_size: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.adpcm_block_size = block_size;
}
// SDK: AIL_sample_granularity(HSAMPLE S) -- the seek granularity in bytes:
// the ADPCM block size for ADPCM samples, else bytes-per-frame (SS_granularity:
// 1 for mono-8, 2 for mono-16/stereo-8, 4 for stereo-16). NOT a driver-level
// constant.
pub fn AIL_sample_granularity(s_opt: ?*Sample) callconv(.winapi) u32 {
    const s = s_opt orelse return 0;
    if (s.adpcm_block_size > 0) return s.adpcm_block_size;
    const bpf = s.bytesPerFrame();
    return if (bpf == 0) 1 else bpf;
}
pub fn AIL_minimum_sample_buffer_size(driver_opt: ?*DigitalDriver, rate: i32, format: i32) callconv(.winapi) u32 {
    const driver = driver_opt orelse return 0;
    _ = driver;
    _ = rate;
    _ = format;
    // The SDK derives this from the driver's hardware_buffer_size, DMA_rate, and
    // bytes_per_channel (wavefile.cpp) -- values our miniaudio backend doesn't
    // expose. Return a conservative constant: it is used as a "minimum
    // sufficient" streaming-buffer hint, so over-estimating is safe whereas a
    // guessed formula could under-estimate and glitch playback.
    return 2048;
}
pub fn AIL_allocate_file_sample(driver_opt: ?*DigitalDriver, data: *anyopaque, flags: u32) callconv(.winapi) ?*Sample {
    const driver = driver_opt orelse return null;
    log("AIL_allocate_file_sample\n", .{});
    _ = flags;
    const s = openmiles.Sample.init(driver) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
    const raw: [*]const u8 = @ptrCast(@alignCast(data));
    const size = openmiles.detectAudioSize(raw);
    if (size == 0) return s; // unknown format, return empty sample
    s.loadFromMemory(raw[0..size], true) catch {
        s.deinit();
        return null;
    };
    return s;
}
// AIL_load_sample_buffer(HSAMPLE S, U32 buff_num, void const *buffer, U32 len)
/// MSS_BUFFER_HEAD (mss.h): pass as buff_num to target the ring's head slot.
const MSS_BUFFER_HEAD: i32 = -1;
pub fn AIL_load_sample_buffer(s_opt: ?*Sample, buff_num: i32, data: ?*anyopaque, len: u32) callconv(.winapi) i32 {
    // SDK (wavefile.cpp) returns S32: -1 on a null sample or an out-of-range
    // slot (signed compare, so MSS_BUFFER_HEAD = -1 passes); otherwise the
    // resolved buffer number that was loaded (or removed).
    const s = s_opt orelse return -1;
    if (buff_num >= s.n_buffers) return -1;
    var bn = buff_num;
    if (bn == MSS_BUFFER_HEAD) {
        const n = if (s.n_buffers > 0) s.n_buffers else 1;
        bn = s.stream_head;
        s.stream_head = @mod(bn + 1, n);
    }
    if (bn < 0) return -1; // defensive: SDK would index buf[<0]; we stay safe
    s.last_loaded_buffer = bn;
    if (data == null) {
        // SDK: a null buffer removes the slot from the ring; nothing to feed.
        return bn;
    }
    if (s.pcm_format != null) {
        // Raw PCM + a known format = MSS double-buffer streaming. Feed the buffer
        // into the ping-pong stream source (zero-copy; the app owns it until EOB).
        s.loadStreamBuffer(@intCast(bn), data.?, len) catch |err| {
            openmiles.log("AIL_load_sample_buffer: stream feed failed: {any}\n", .{err});
            return -1;
        };
    } else {
        // No format hint: treat as a complete encoded file image (whole-buffer).
        s.load(data.?, @intCast(@min(len, @as(u32, std.math.maxInt(i32))))) catch return -1;
    }
    // Fire SOB (Start Of Buffer) callback now that a new buffer is accepted.
    // AILSAMPLECB: void callback(HSAMPLE S) — single arg; app queries buffer state separately.
    if (s.sob_callback != 0) {
        const cb: *const fn (?*anyopaque) callconv(.winapi) void = @ptrFromInt(s.sob_callback);
        cb(@ptrCast(s));
    }
    return bn;
}
pub fn AIL_sample_buffer_ready(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    // Streaming: return the index (0/1) of a free buffer slot, or -1 if both full.
    if (s.stream_active) return s.streamBufferReady();
    // Non-streaming whole-buffer samples: "ready" once finished or not yet started.
    if (s.is_done or !s.is_initialized) return 0;
    if (openmiles.ma.ma_sound_at_end(&s.sound) != 0) return 0;
    return -1;
}
// v3-v7 form: 5 args @20 — both double-buffer slots (pos/len each). Exported as
// _AIL_sample_buffer_info@20 for v3-v7.
pub fn AIL_sample_buffer_info_old(s_opt: ?*Sample, pos0: ?*u32, len0: ?*u32, pos1: ?*u32, len1: ?*u32) callconv(.winapi) void {
    if (pos0) |p| p.* = 0;
    if (len0) |p| p.* = 0;
    if (pos1) |p| p.* = 0;
    if (len1) |p| p.* = 0;
    const s = s_opt orelse return;
    if (s.stream_active) {
        var p0: u32 = 0;
        var l0: u32 = 0;
        var p1: u32 = 0;
        var l1: u32 = 0;
        s.stream_src.bufferInfo(&p0, &l0, &p1, &l1);
        if (pos0) |p| p.* = p0;
        if (len0) |p| p.* = l0;
        if (pos1) |p| p.* = p1;
        if (len1) |p| p.* = l1;
    } else if (s.owned_buffer) |buf| {
        if (len0) |p| p.* = @intCast(buf.len);
    }
}
// v8+ form: S32 AIL_sample_buffer_info(HSAMPLE S, S32 buff_num, U32 *pos,
// U32 *len, U32 *used, U32 *free) @24 — report play position/length and the
// used/free buffer counts for the requested double-buffer slot.
// SDK (wavefile.cpp): pos/len of buffer buff_num, the ring head/tail indices,
// and the return is S->starved (0 when healthy) — NOT a success flag. A null
// sample yields pos/len 0 and head/tail -1.
pub fn AIL_sample_buffer_info(s_opt: ?*Sample, buff_num: i32, pos: ?*u32, len: ?*u32, head: ?*i32, tail: ?*i32) callconv(.winapi) i32 {
    const s = s_opt orelse {
        if (pos) |p| p.* = 0;
        if (len) |p| p.* = 0;
        if (head) |p| p.* = -1;
        if (tail) |p| p.* = -1;
        return 0;
    };
    if (head) |p| p.* = s.stream_head;
    if (tail) |p| p.* = s.stream_head; // single ring pointer in our ping-pong model
    if (s.stream_active) {
        var p0: u32 = 0;
        var l0: u32 = 0;
        var p1: u32 = 0;
        var l1: u32 = 0;
        s.stream_src.bufferInfo(&p0, &l0, &p1, &l1);
        const even = @mod(buff_num, 2) == 0;
        if (pos) |p| p.* = if (even) p0 else p1;
        if (len) |p| p.* = if (even) l0 else l1;
        return if (s.stream_src.starved) 1 else 0; // return S->starved
    }
    if (pos) |p| p.* = 0;
    if (len) |p| p.* = if (s.owned_buffer) |buf| @intCast(@min(buf.len, std.math.maxInt(u32))) else 0;
    return 0;
}
pub fn AIL_register_EOB_callback(s_opt: ?*Sample, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(s.eob_callback);
    s.eob_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub fn AIL_register_SOB_callback(s_opt: ?*Sample, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(s.sob_callback);
    s.sob_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub fn AIL_set_sample_processor(s_opt: ?*Sample, stage: i32, processor: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    const idx: usize = @intCast(@min(@max(stage, 0), 1));
    const prev: ?*anyopaque = @ptrFromInt(s.sample_processors[idx]);
    s.sample_processors[idx] = if (processor) |p| @intFromPtr(p) else 0;
    return prev;
}
// AIL_primary_digital_driver(HDIGDRIVER new_primary) -> HDIGDRIVER
// Passing a driver makes it the primary; null queries the current primary.
pub fn AIL_primary_digital_driver(new_primary: ?*DigitalDriver) callconv(.winapi) ?*DigitalDriver {
    if (new_primary) |d| openmiles.last_digital_driver = d;
    return openmiles.last_digital_driver;
}
pub fn AIL_digital_CPU_percent(driver_opt: ?*DigitalDriver) callconv(.winapi) i32 {
    const driver = driver_opt orelse return 0;
    // Estimate CPU load from the ratio of active sounds to a nominal budget.
    // miniaudio doesn't expose CPU usage directly; this approximation is
    // sufficient for games that throttle sound spawning based on this value.
    // SDK returns S32 (integer percent in EAX), not F32.
    const active: f32 = @floatFromInt(driver.getActiveSampleCount() + driver.get3DActiveSampleCount());
    const nominal_budget: f32 = 32.0;
    const pct = (active / nominal_budget) * 100.0;
    return @intFromFloat(@min(pct, 100.0));
}
pub fn AIL_digital_latency(driver_opt: ?*DigitalDriver) callconv(.winapi) u32 {
    const driver = driver_opt orelse return 0;
    if (driver.getDevice()) |device| {
        const period = device.playback.internalPeriodSizeInFrames;
        const rate = device.playback.internalSampleRate;
        if (rate > 0 and period > 0) {
            return (period * 1000) / rate;
        }
    }
    // Fallback for no-device engines (tests) or if period info unavailable
    return 10;
}
// Real MSS: AIL_digital_configuration(HDIGDRIVER dig, S32 *rate, S32 *format,
// char *string) — rate is the mixer output rate, format a DIG_F code, and
// string receives a short human-readable driver description.
pub fn AIL_digital_configuration(driver_opt: ?*DigitalDriver, rate: ?*i32, format: ?*i32, string: ?[*]u8) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    if (rate) |p| p.* = @intCast(driver.getSampleRate());
    if (format) |p| p.* = if (driver.getChannels() >= 2) 3 else 1; // 16-bit: 1=mono,3=stereo
    if (string) |buf| {
        const name = "OpenMiles (miniaudio)";
        for (name, 0..) |c, i| buf[i] = c;
        buf[name.len] = 0;
    }
}
// Legacy 3.x exports. The DirectSound-specific ones have no meaning on the
// miniaudio backend (no DirectSound buffers/DS3D), so they report "unsupported".
pub fn AIL_get_DirectSound3D_info(s: ?*anyopaque, ds3d: ?*anyopaque, caps: ?*anyopaque, size: u32) callconv(.winapi) void {
    _ = s;
    _ = ds3d;
    _ = caps;
    _ = size;
}
pub fn AIL_set_direct_buffer_control(s_opt: ?*Sample, command: u32) callconv(.winapi) i32 {
    _ = s_opt;
    _ = command;
    return 0; // no DirectSound secondary buffer to control
}
pub fn AIL_start_sample_at(s_opt: ?*Sample, offset: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setPosition(offset);
    s.start();
}
// void AIL_get_DirectSound_info(HSAMPLE S, AILLPDIRECTSOUND *lplpDS, AILLPDIRECTSOUNDBUFFER *lplpDSB)
// OpenMiles renders through miniaudio/WASAPI, not DirectSound, so report that no
// DirectSound object/buffer is available by nulling the out-pointers.
pub fn AIL_get_DirectSound_info(s_opt: ?*Sample, lplpDS: ?*?*anyopaque, lplpDSB: ?*?*anyopaque) callconv(.winapi) void {
    _ = s_opt;
    if (lplpDS) |p| p.* = null;
    if (lplpDSB) |p| p.* = null;
}
// SDK (mss.h 3.x/6.1): S32 return -- hands back a success status (1; 0 for a null
// driver). We have no DirectSound backend, so it is a no-op that still reports OK.
pub fn AIL_set_DirectSound_HWND(driver_opt: ?*DigitalDriver, hwnd: *anyopaque) callconv(.winapi) i32 {
    const driver = driver_opt orelse return 0;
    _ = driver;
    _ = hwnd;
    return 1;
}
pub fn AIL_set_digital_driver_processor(driver_opt: ?*DigitalDriver, stage: i32, processor: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const driver = driver_opt orelse return null;
    const idx: usize = @intCast(@min(@max(stage, 0), 1));
    const prev: ?*anyopaque = @ptrFromInt(driver.driver_processors[idx]);
    driver.driver_processors[idx] = if (processor) |p| @intFromPtr(p) else 0;
    return prev;
}
// One normalized mixer input: 16-bit interleaved samples plus its geometry.
const MixSrc = struct {
    s16: []const i16 = &[_]i16{},
    owned: ?[]i16 = null, // freed by the caller if set
    channels: u32 = 1,
    points: usize = 0, // per-channel sample count
    rate: u32 = 0,
};

// Decode one IMA-ADPCM source's raw blocks to owned interleaved 16-bit PCM via
// the same wrap-and-decode path as AIL_decompress_ADPCM.
fn decodeAdpcmSource(info: *const AILSOUNDINFO) ?MixSrc {
    if (info.data_ptr == null or info.data_len == 0 or info.samples == 0) return null;
    const adpcm: []const u8 = @as([*]const u8, @ptrCast(@alignCast(info.data_ptr.?)))[0..info.data_len];
    const ch: u16 = @intCast(@max(1, @min(2, info.channels)));
    const block_size: u32 = if (info.block_size > 4 * @as(u32, ch)) info.block_size else 512;
    const wav = openmiles.wrapAdpcmInWav(openmiles.global_allocator, adpcm, block_size, ch, info.rate, info.samples) catch return null;
    defer openmiles.global_allocator.free(wav);
    var decoder: openmiles.ma.ma_decoder = undefined;
    var cfg = openmiles.ma.ma_decoder_config_init(openmiles.ma.ma_format_s16, 0, 0);
    if (openmiles.ma.ma_decoder_init_memory(wav.ptr, wav.len, &cfg, &decoder) != openmiles.ma.MA_SUCCESS) return null;
    defer _ = openmiles.ma.ma_decoder_uninit(&decoder);
    const dch: u32 = decoder.outputChannels;
    var list: std.ArrayListUnmanaged(i16) = .empty;
    errdefer list.deinit(openmiles.global_allocator);
    // Heap scratch (16-byte aligned) — avoids the stack-layout-dependent
    // misaligned ma_int16 write inside miniaudio's IMA decoder (see decompress).
    const chunk = openmiles.global_allocator.alignedAlloc(i16, .@"16", 4096 * 4) catch return null;
    defer openmiles.global_allocator.free(chunk);
    const cap_frames: u64 = chunk.len / @max(dch, 1);
    while (true) {
        var fr: u64 = 0;
        _ = openmiles.ma.ma_decoder_read_pcm_frames(&decoder, chunk.ptr, cap_frames, &fr);
        if (fr == 0) break;
        list.appendSlice(openmiles.global_allocator, chunk[0..@intCast(fr * dch)]) catch break;
    }
    const buf = list.toOwnedSlice(openmiles.global_allocator) catch return null;
    return .{ .s16 = buf, .owned = buf, .channels = dch, .points = buf.len / @max(dch, 1), .rate = if (info.rate == 0) 22050 else info.rate };
}

// S32 AIL_process_digital_audio(void *dest, S32 dest_size, U32 dest_rate, U32 dest_format, S32 num_srcs, AILMIXINFO *src)
// Offline software mixer (wavefile.cpp): resample each source to dest_rate, sum,
// and write dest_format into dest, returning the byte count produced. MSS's exact
// per-sample interpolation/mix lives in the closed mixer RIB, so — like the rest
// of OpenMiles' DSP — we mix functionally (nearest-neighbor resample, summed with
// clipping) rather than byte-identically. The dest_points / nbytes_written
// contract matches the SDK.
pub fn AIL_process_digital_audio(dest: ?*anyopaque, dest_size: i32, dest_rate: u32, dest_format: u32, num_srcs: i32, src: ?*anyopaque) callconv(.winapi) i32 {
    if (dest == null or src == null or num_srcs <= 0 or dest_rate == 0 or dest_size <= 0) return 0;
    const n: usize = @min(@as(usize, @intCast(num_srcs)), 256); // SDK caps at operations[256]
    const srcs: [*]const openmiles.AILMIXINFO = @ptrCast(@alignCast(src.?));

    var mix: [256]MixSrc = undefined;
    var nmix: usize = 0;
    defer for (mix[0..nmix]) |m| {
        if (m.owned) |o| openmiles.global_allocator.free(o);
    };

    var max_points: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const info = &srcs[i].Info;
        var ms: MixSrc = .{ .channels = @intCast(@max(1, @min(2, info.channels))), .rate = if (info.rate == 0) dest_rate else info.rate };
        if (info.data_ptr != null and info.data_len > 0) {
            if (info.format == 0x0011 and info.bits == 4) {
                if (decodeAdpcmSource(info)) |dec| ms = dec;
            } else if (info.bits == 16) {
                const p: [*]const i16 = @ptrCast(@alignCast(info.data_ptr.?));
                const total = info.data_len / 2;
                ms.s16 = p[0..total];
                ms.points = total / ms.channels;
            } else if (info.bits == 8) {
                const u8d: [*]const u8 = @ptrCast(info.data_ptr.?);
                const total: usize = info.data_len;
                const buf = openmiles.global_allocator.alloc(i16, total) catch break;
                for (0..total) |k| buf[k] = (@as(i16, u8d[k]) - 128) << 8;
                ms.owned = buf;
                ms.s16 = buf;
                ms.points = total / ms.channels;
            }
        }
        mix[nmix] = ms;
        nmix += 1;
        const pts: u64 = @as(u64, ms.points) *| dest_rate / ms.rate;
        if (pts > max_points) max_points = pts;
    }

    const dest_chan: usize = if ((dest_format & 2) != 0) 2 else 1; // DIG_F_STEREO_MASK
    const dest_bps: usize = if ((dest_format & 1) != 0) 2 else 1; // DIG_F_16BITS_MASK
    const dps = dest_chan * dest_bps;
    var dest_points: usize = @as(usize, @intCast(dest_size)) / dps;
    if (max_points < dest_points) dest_points = @intCast(max_points);
    if (dest_points == 0) return 0;

    const out: [*]u8 = @ptrCast(dest.?);
    var o: usize = 0;
    var j: usize = 0;
    while (j < dest_points) : (j += 1) {
        var accL: i32 = 0;
        var accR: i32 = 0;
        for (mix[0..nmix]) |m| {
            if (m.points == 0) continue;
            const sp: u64 = @as(u64, j) *| m.rate / dest_rate;
            if (sp >= m.points) continue;
            const spi: usize = @intCast(sp);
            if (m.channels == 2) {
                accL += m.s16[spi * 2];
                accR += m.s16[spi * 2 + 1];
            } else {
                const v: i32 = m.s16[spi];
                accL += v;
                accR += v;
            }
        }
        const L: i32 = std.math.clamp(accL, -32768, 32767);
        const R: i32 = std.math.clamp(accR, -32768, 32767);
        if (dest_chan == 2) {
            writeSample(out, &o, dest_bps, L);
            writeSample(out, &o, dest_bps, R);
        } else {
            writeSample(out, &o, dest_bps, std.math.clamp(@divTrunc(accL + accR, 2), -32768, 32767));
        }
    }
    return @intCast(o);
}

fn writeSample(out: [*]u8, o: *usize, dest_bps: usize, v: i32) void {
    if (dest_bps == 2) {
        std.mem.writeInt(i16, out[o.*..][0..2], @intCast(v), .little);
        o.* += 2;
    } else {
        out[o.*] = @intCast((@divTrunc(v, 256)) + 128); // 16-bit -> 8-bit unsigned
        o.* += 1;
    }
}
// Real MSS: S32 AIL_size_processed_digital_audio(U32 dest_rate, U32 dest_format,
// S32 num_srcs, AILMIXINFO const* src) @16 — return the byte size that
// AIL_process_digital_audio would emit for the given source(s) resampled to the
// destination rate/format. AILMIXINFO begins with an AILSOUNDINFO, so the first
// source's length/rate drive the estimate.
pub fn AIL_size_processed_digital_audio(dest_rate: u32, dest_format: u32, num_srcs: i32, src: ?*const anyopaque) callconv(.winapi) i32 {
    if (num_srcs <= 0 or dest_rate == 0) return 0;
    const sp = src orelse return 0;
    // Mirror AIL_API_size_processed_digital_audio (wavefile.cpp): a "point" is one
    // time position (mono sample / stereo pair). ADPCM packs 2 samples/byte,
    // 16-bit uses 2 bytes/sample, a stereo point is 2 samples. Take the largest
    // source's point count after resampling to dest_rate, then size the dest.
    const srcs: [*]const openmiles.AILMIXINFO = @ptrCast(@alignCast(sp));
    var max_points: u64 = 0;
    var i: usize = 0;
    while (i < @as(usize, @intCast(num_srcs))) : (i += 1) {
        const info = &srcs[i].Info;
        var points: u64 = info.data_len;
        if (info.format == 0x0011) { // WAVE_FORMAT_IMA_ADPCM
            points <<= 1;
        } else if (info.bits != 8) {
            points >>= 1;
        }
        if (info.channels == 2) points >>= 1;
        const src_rate: u64 = if (info.rate == 0) dest_rate else info.rate;
        points = points *| dest_rate / src_rate;
        if (points > max_points) max_points = points;
    }
    // dest point size = (stereo?2:1) * (16-bit?2:1); DIG_F bit0=16BITS, bit1=STEREO.
    const dest_point_size: u64 = (if ((dest_format & 2) != 0) @as(u64, 2) else 1) * (if ((dest_format & 1) != 0) @as(u64, 2) else 1);
    return @intCast(@min(dest_point_size *| max_points +| 256, std.math.maxInt(i32))); // +256 slop (SDK)
}
pub fn AIL_ms_count() callconv(.winapi) u32 {
    return openmiles.getMsCount();
}
pub fn AIL_us_count() callconv(.winapi) u32 {
    return openmiles.getUsCount();
}
pub fn AIL_delay(ms: u32) callconv(.winapi) void {
    const duration = std.Io.Duration.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms);
    openmiles.io.sleep(duration, .awake) catch {};
}
pub fn AIL_lock() callconv(.winapi) void {}
pub fn AIL_unlock() callconv(.winapi) void {}
pub fn AIL_lock_mutex() callconv(.winapi) void {}
pub fn AIL_unlock_mutex() callconv(.winapi) void {}
pub fn AIL_background() callconv(.winapi) ?*anyopaque {
    return null;
}
pub fn AIL_MMX_available() callconv(.winapi) i32 {
    // The 32-bit Windows target always runs on an x86 with MMX (Pentium MMX, 1997+).
    return 1;
}
pub fn AIL_HWND() callconv(.winapi) ?*anyopaque {
    return null;
}
pub fn AIL_set_error(msg: [*:0]const u8) callconv(.winapi) void {
    openmiles.setLastError(std.mem.span(msg));
}
// AIL_debug_printf and AIL_sprintf are implemented in C (src/bindings/c_impl.c)
// to avoid Zig stage2_llvm miscompilation of C varargs on Windows.

pub fn AIL_WAV_info(data: *anyopaque, info: *anyopaque) callconv(.winapi) i32 {
    const raw: [*]const u8 = @ptrCast(@alignCast(data));
    if (raw[0] != 'R' or raw[1] != 'I' or raw[2] != 'F' or raw[3] != 'F') return 0;
    if (raw[8] != 'W' or raw[9] != 'A' or raw[10] != 'V' or raw[11] != 'E') return 0;
    const out: *AILSOUNDINFO = @ptrCast(@alignCast(info));
    // Use the RIFF chunk size to determine the file end boundary
    const riff_body = std.mem.readInt(u32, raw[4..8][0..4], .little);
    const file_end: usize = @as(usize, riff_body) + 8;
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
    if (@hasField(AILSOUNDINFO, "channel_mask")) out.channel_mask = ~@as(u32, 0);
    if (audio_format == 0xFFFE) {
        // WAVEFORMATEXTENSIBLE: the SDK only accepts a 16-bit PCM subformat whose
        // block alignment is channels*2, reports it as plain WAVE_FORMAT_PCM, and
        // carries the file's dwChannelMask. Anything else is rejected (return 0).
        if (ext_cbsize < 22 or !ext_subformat_pcm or block_align != num_channels *| 2) return 0;
        out.format = 1; // WAVE_FORMAT_PCM
        if (@hasField(AILSOUNDINFO, "channel_mask")) out.channel_mask = ext_channel_mask;
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
pub fn AIL_WAV_file_write(filename: [*:0]const u8, data: *anyopaque, len: u32, rate: i32, format: i32) callconv(.winapi) i32 {
    // The 5th arg is a DIG_F format code (mss.h), NOT a bit depth:
    //   DIG_F_16BITS_MASK (1) -> 16-bit else 8-bit; DIG_F_STEREO_MASK (2) -> stereo.
    if (rate <= 0) return 0;
    // MSS 8.0+ (msssys.c AIL_API_WAV_file_write) honors DIG_F_MULTICHANNEL_MASK
    // (bit 16): the real channel count is packed in the high 16 bits. Pre-8.0 has
    // no multichannel path -- and there bit 16 meant DIG_F_USING_ASI, an unrelated
    // state flag -- so only the stereo bit applies. Gate to match each release.
    const channels: u16 = blk: {
        if (openmiles.mss_version >= 80 and (format & 16) != 0) {
            break :blk @intCast(@as(u32, @bitCast(format)) >> 16);
        }
        break :blk if (format & 2 != 0) 2 else 1;
    };
    const bits: u16 = if (format & 1 != 0) 16 else 8;
    const pcm_data: []const u8 = @as([*]const u8, @ptrCast(@alignCast(data)))[0..len];
    const wav = openmiles.buildWavFromPcm(openmiles.global_allocator, pcm_data, channels, @intCast(rate), bits) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    defer openmiles.global_allocator.free(wav);
    const io = openmiles.io;
    const path = std.mem.span(filename);
    const file = openmiles.fs_compat.createFile(io, path, .{}) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    defer file.close(io);
    file.writeStreamingAll(io, wav) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    return 1;
}
/// Allocates a new buffer which must be freed by the caller using AIL_mem_free_lock.
pub fn AIL_compress_ADPCM(info: *const AILSOUNDINFO, outdata: **anyopaque, outsize: *u32) callconv(.winapi) i32 {
    if (info.data_ptr == null or info.data_len == 0) return 0;
    // SDK (mssadpcm.cpp): source must be PCM, 8- or 16-bit, mono or stereo.
    if (info.format != 1) return 0; // "Data is already compressed."
    if ((info.bits != 8 and info.bits != 16) or (info.channels != 1 and info.channels != 2)) return 0;
    const channels: u16 = @intCast(info.channels);
    const bytes_per_sample: usize = if (info.bits == 8) 1 else 2;
    const total_per_ch: usize = @as(usize, info.data_len) / (bytes_per_sample * @as(usize, channels));
    // The encoder works on 16-bit samples; promote 8-bit unsigned PCM (128 = 0).
    var pcm16_owned: ?[]i16 = null;
    defer if (pcm16_owned) |p| openmiles.global_allocator.free(p);
    const pcm: [*]const i16 = blk: {
        if (info.bits == 8) {
            const u8data: [*]const u8 = @ptrCast(info.data_ptr.?);
            const n: usize = info.data_len;
            const tmp = openmiles.global_allocator.alloc(i16, n) catch return 0;
            for (0..n) |i| tmp[i] = (@as(i16, u8data[i]) - 128) << 8;
            pcm16_owned = tmp;
            break :blk tmp.ptr;
        }
        break :blk @ptrCast(@alignCast(info.data_ptr.?));
    };
    const wav = openmiles.buildAdpcmWav(openmiles.global_allocator, pcm, total_per_ch, channels, info.rate) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    defer openmiles.global_allocator.free(wav);
    const out_ptr: [*]u8 = @ptrCast(std.c.malloc(wav.len) orelse return 0);
    @memcpy(out_ptr[0..wav.len], wav);
    outdata.* = out_ptr;
    outsize.* = @intCast(wav.len);
    return 1;
}
/// AIL_decompress_ADPCM(AILSOUNDINFO const *info, void **outdata, U32 *outsize)
/// Decodes the ADPCM image described by `info` to a 16-bit PCM WAV. Allocates
/// `outdata` (free with AIL_mem_free_lock) and sets `outsize`. Returns 1 on success.
pub fn AIL_decompress_ADPCM(info: *const AILSOUNDINFO, outdata: **anyopaque, outsize: *u32) callconv(.winapi) i32 {
    // SDK (miscutil.cpp): info->data_ptr is the RAW IMA ADPCM block data (as
    // AIL_WAV_info reports it), not a WAV image. Validate exactly as the SDK:
    // need data, samples, and an IMA ADPCM 4-bit source.
    if (info.data_ptr == null or info.data_len == 0 or info.samples == 0) return 0;
    if (info.format != 0x0011 or info.bits != 4) return 0; // "Data is not IMA compressed."
    const adpcm: []const u8 = @as([*]const u8, @ptrCast(@alignCast(info.data_ptr.?)))[0..info.data_len];
    // Reconstruct an IMA ADPCM WAV around the raw blocks so the decoder can read
    // it (block_size/channels/rate come from the AILSOUNDINFO).
    const src_channels: u16 = @intCast(@max(1, @min(2, info.channels)));
    const block_size: u32 = if (info.block_size > 4 * @as(u32, src_channels)) info.block_size else 512;
    const adpcm_wav = openmiles.wrapAdpcmInWav(openmiles.global_allocator, adpcm, block_size, src_channels, info.rate, info.samples) catch return 0;
    defer openmiles.global_allocator.free(adpcm_wav);
    const raw: []const u8 = adpcm_wav;
    var decoder: openmiles.ma.ma_decoder = undefined;
    var config = openmiles.ma.ma_decoder_config_init(openmiles.ma.ma_format_s16, 0, 0); // preserve channel/rate from source
    if (openmiles.ma.ma_decoder_init_memory(raw.ptr, raw.len, &config, &decoder) != openmiles.ma.MA_SUCCESS) return 0;
    defer _ = openmiles.ma.ma_decoder_uninit(&decoder);

    const channels = @as(u32, decoder.outputChannels);
    const rate = @as(u32, decoder.outputSampleRate);
    const bpf = channels * 2; // 16-bit = 2 bytes/sample

    // Decode all frames into a temporary list
    var pcm: std.ArrayListUnmanaged(u8) = .empty;
    defer pcm.deinit(openmiles.global_allocator);

    var length_frames: u64 = 0;
    _ = openmiles.ma.ma_decoder_get_length_in_pcm_frames(&decoder, &length_frames);
    if (length_frames > 0) {
        // length_frames is decoder-reported (header-derived, so spoofable); a
        // saturating multiply + clamp keeps the capacity hint from overflowing
        // or panicking the usize cast on the 32-bit target. The decode loop is
        // bounded by real reads, so an inflated hint only over-reserves.
        const hint: u64 = @min(length_frames *| @as(u64, bpf), std.math.maxInt(usize));
        pcm.ensureTotalCapacity(openmiles.global_allocator, @intCast(hint)) catch {};
    }

    // Heap-allocate the decode scratch: the allocator guarantees high alignment,
    // avoiding a stack-layout-dependent misaligned write inside miniaudio's IMA
    // decoder that a stack [u8 align(2)] / [i16] array did not reliably prevent.
    const chunk_bytes: usize = 4096 * 8; // up to 4096 frames x 8 bytes (4ch 16-bit)
    const chunk_buf = openmiles.global_allocator.alignedAlloc(u8, .@"16", chunk_bytes) catch return 0;
    defer openmiles.global_allocator.free(chunk_buf);
    const chunk_frames: u64 = chunk_bytes / @as(usize, bpf);
    while (true) {
        var fr: u64 = 0;
        _ = openmiles.ma.ma_decoder_read_pcm_frames(&decoder, chunk_buf.ptr, chunk_frames, &fr);
        if (fr == 0) break;
        const nbytes: usize = @intCast(fr * @as(u64, bpf));
        pcm.appendSlice(openmiles.global_allocator, chunk_buf[0..nbytes]) catch break;
    }
    if (pcm.items.len == 0) return 0;

    // SDK (miscutil.cpp): the output is sized to exactly info->samples frames
    // (size = samples*channels*16/8). IMA block padding makes the decoder emit up
    // to spb-1 extra frames in the final block, so clamp the decoded PCM to the
    // declared sample count to match MSS byte-for-byte. A short decode is zero-
    // extended to the same declared size (MSS allocates `size` and leaves the
    // unfilled tail; we use deterministic silence instead of its uninitialized
    // bytes).
    if (info.samples != 0) {
        const target_bytes: usize = @intCast(@min(@as(u64, info.samples) *| @as(u64, channels) *| 2, std.math.maxInt(usize)));
        if (pcm.items.len > target_bytes) {
            pcm.items.len = target_bytes;
        } else if (pcm.items.len < target_bytes) {
            pcm.appendNTimes(openmiles.global_allocator, 0, target_bytes - pcm.items.len) catch {};
        }
    }

    const wav = openmiles.buildWavFromPcm(openmiles.global_allocator, pcm.items, @intCast(channels), rate, 16) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    defer openmiles.global_allocator.free(wav);

    const out_ptr: [*]u8 = @ptrCast(std.c.malloc(wav.len) orelse return 0);
    @memcpy(out_ptr[0..wav.len], wav);
    outdata.* = out_ptr;
    outsize.* = @intCast(wav.len);
    return 1;
}
// SDK: AIL_create_wave_synthesizer(HDIGDRIVER dig, HMDIDRIVER mdi,
// void const* wave_lib, S32 polyphony) -- param 2 is the MIDI driver (not a
// sequence) and param 4 is the polyphony count.
pub fn AIL_create_wave_synthesizer(dig_opt: ?*DigitalDriver, mdi: ?*MidiDriver, dls: ?*anyopaque, polyphony: i32) callconv(.winapi) ?*MidiDriver {
    const dig = dig_opt orelse return null;
    _ = dig;
    _ = mdi;
    _ = polyphony;
    const driver = MidiDriver.init(openmiles.global_allocator) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
    if (dls) |bank| {
        // `bank` is a *tsf.tsf returned from AIL_DLS_load_file / AIL_DLS_load_memory.
        // Borrow the soundfont — do not free it when this wave synthesizer is destroyed,
        // since the original MidiDriver that loaded it still owns it.
        driver.soundfont = @ptrCast(@alignCast(bank));
        driver.owns_soundfont = false;
    }
    return driver;
}
pub fn AIL_destroy_wave_synthesizer(synth: *MidiDriver) callconv(.winapi) void {
    if (openmiles.last_midi_driver == synth) openmiles.last_midi_driver = null;
    synth.deinit();
}
pub fn AIL_waveOutClose(driver_opt: ?*DigitalDriver) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    if (openmiles.last_digital_driver == driver) openmiles.last_digital_driver = null;
    driver.deinit();
}
pub fn DllMain(hinstDLL: *anyopaque, fdwReason: u32, lpvReserved: ?*anyopaque) callconv(.winapi) i32 {
    _ = hinstDLL;
    _ = fdwReason;
    _ = lpvReserved;
    return 1;
}
comptime {
    @setEvalBranchQuota(1000000);
    const is_x86_windows = builtin.target.cpu.arch == .x86 and builtin.target.os.tag == .windows;
    if (is_x86_windows) {
        const Target = struct {
            name: []const u8,
            stack_size: u8,
            ver: u16 = 30, // MSS version (major*10+minor) the export first appeared in
            ver_max: u16 = 999, // last version that still exports it (for renamed/dropped APIs)
            // Optional COFF symbol to alias when it differs from `name` (e.g. a
            // renamed export sharing another function's implementation).
            symbol: ?[]const u8 = null,
            // The real DLL exports the public RIB-interface and DLS APIs under
            // __cdecl (undecorated: no leading `_`, no `@N`), while the AIL_*
            // surface and the RIB provider-management calls stay __stdcall. When
            // set, emit the bare name and the backing fn must be callconv(.c).
            cdecl: bool = false,
        };
        const targets = [_]Target{
            .{ .name = "AIL_startup", .stack_size = 0 },
            .{ .name = "AIL_shutdown", .stack_size = 0 },
            .{ .name = "AIL_set_redist_directory", .stack_size = 4, .ver = 61 },
            .{ .name = "AIL_last_error", .stack_size = 0 },
            .{ .name = "AIL_get_preference", .stack_size = 4 },
            .{ .name = "AIL_set_preference", .stack_size = 8 },
            .{ .name = "AIL_open_midi_driver", .stack_size = 4 },
            .{ .name = "AIL_close_midi_driver", .stack_size = 4 },
            .{ .name = "AIL_open_XMIDI_driver", .stack_size = 4, .ver = 61, .ver_max = 70 },
            .{ .name = "AIL_close_XMIDI_driver", .stack_size = 4, .ver = 61, .ver_max = 70 },
            .{ .name = "AIL_allocate_sequence_handle", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_release_sequence_handle", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_init_sequence", .stack_size = 12, .ver_max = 70 },
            .{ .name = "AIL_start_sequence", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_stop_sequence", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_pause_sequence", .stack_size = 4 },
            .{ .name = "AIL_resume_sequence", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_sequence_status", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_set_sequence_volume", .stack_size = 12, .ver_max = 70 },
            .{ .name = "AIL_set_sequence_loop_count", .stack_size = 8, .ver_max = 70 },
            .{ .name = "AIL_branch_index", .stack_size = 8, .ver_max = 70 },
            .{ .name = "AIL_DLS_load_file", .stack_size = 12, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_DLS_unload_file", .stack_size = 8 },
            .{ .name = "AIL_digital_handle_release", .stack_size = 4 },
            .{ .name = "AIL_digital_handle_reacquire", .stack_size = 4 },
            .{ .name = "AIL_waveOutOpen", .stack_size = 16, .ver_max = 65 },
            .{ .name = "AIL_open_digital_driver", .stack_size = 16, .ver = 61 },
            .{ .name = "AIL_close_digital_driver", .stack_size = 4, .ver = 61 },
            .{ .name = "AIL_serve", .stack_size = 0 },
            .{ .name = "AIL_set_digital_master_volume", .stack_size = 8, .ver_max = 61 },
            .{ .name = "AIL_digital_master_volume", .stack_size = 4, .ver_max = 61 },
            .{ .name = "AIL_allocate_sample_handle", .stack_size = 4 },
            .{ .name = "AIL_release_sample_handle", .stack_size = 4 },
            // init_sample arity by era: v3-v6 @4 (S), v7 @12 (S + 2 extra slots),
            // v8+ @8 (S, format).
            .{ .name = "AIL_init_sample", .stack_size = 4, .ver_max = 66 },
            .{ .name = "AIL_init_sample", .stack_size = 12, .ver = 70, .ver_max = 70, .symbol = "AIL_init_sample_v7" },
            .{ .name = "AIL_init_sample", .stack_size = 8, .ver = 80, .symbol = "AIL_init_sample_v8" },
            .{ .name = "AIL_set_named_sample_file", .stack_size = 20, .ver = 50 },
            .{ .name = "AIL_set_sample_file", .stack_size = 12 },
            .{ .name = "AIL_set_sample_address", .stack_size = 12 },
            .{ .name = "AIL_set_sample_type", .stack_size = 12, .ver_max = 65 },
            .{ .name = "AIL_start_sample", .stack_size = 4 },
            .{ .name = "AIL_stop_sample", .stack_size = 4 },
            .{ .name = "AIL_pause_sample", .stack_size = 4 },
            .{ .name = "AIL_resume_sample", .stack_size = 4 },
            .{ .name = "AIL_end_sample", .stack_size = 4 },
            .{ .name = "AIL_sample_status", .stack_size = 4 },
            .{ .name = "AIL_sample_volume", .stack_size = 4, .ver_max = 61 },
            .{ .name = "AIL_sample_pan", .stack_size = 4, .ver_max = 61 },
            .{ .name = "AIL_sample_playback_rate", .stack_size = 4 },
            .{ .name = "AIL_set_sample_volume", .stack_size = 8, .ver_max = 61 },
            .{ .name = "AIL_set_sample_pan", .stack_size = 8, .ver_max = 61 },
            .{ .name = "AIL_set_sample_playback_rate", .stack_size = 8 },
            .{ .name = "AIL_set_sample_volume_pan", .stack_size = 12, .ver = 65 },
            .{ .name = "AIL_set_sample_loop_count", .stack_size = 8 },
            .{ .name = "AIL_active_sample_count", .stack_size = 4 },
            .{ .name = "AIL_sample_ms_position", .stack_size = 12, .ver = 50 },
            .{ .name = "AIL_set_sample_ms_position", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_sample_position", .stack_size = 4 },
            .{ .name = "AIL_set_sample_position", .stack_size = 8 },
            .{ .name = "AIL_sample_loop_count", .stack_size = 4 },
            .{ .name = "AIL_register_EOS_callback", .stack_size = 8 },
            .{ .name = "AIL_open_stream", .stack_size = 12 },
            // Undocumented internal that leaked into the 6.1a export table only.
            .{ .name = "AIL_open_stream_by_sample", .stack_size = 16, .ver = 61, .ver_max = 61 },
            .{ .name = "AIL_close_stream", .stack_size = 4 },
            .{ .name = "AIL_start_stream", .stack_size = 4 },
            .{ .name = "AIL_pause_stream", .stack_size = 8 },
            .{ .name = "AIL_set_stream_volume", .stack_size = 8, .ver_max = 61 },
            .{ .name = "AIL_set_stream_loop_count", .stack_size = 8 },
            .{ .name = "AIL_register_stream_callback", .stack_size = 8 },
            .{ .name = "AIL_auto_service_stream", .stack_size = 8 },
            .{ .name = "AIL_set_stream_playback_rate", .stack_size = 8, .ver_max = 65 },
            .{ .name = "AIL_set_stream_pan", .stack_size = 8, .ver_max = 61 },
            // Combined F32 volume/pan stream setter — present in many v4+ builds
            // (e.g. Midnight Club II's v6 mss32.dll) though absent from some refs.
            .{ .name = "AIL_set_stream_volume_pan", .stack_size = 12, .ver = 65, .ver_max = 65 },
            .{ .name = "AIL_set_stream_ms_position", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_stream_status", .stack_size = 4 },
            .{ .name = "AIL_stream_playback_rate", .stack_size = 4, .ver_max = 65 },
            .{ .name = "AIL_stream_volume", .stack_size = 4, .ver_max = 61 },
            .{ .name = "AIL_stream_pan", .stack_size = 4, .ver_max = 61 },
            .{ .name = "AIL_stream_loop_count", .stack_size = 4 },
            .{ .name = "AIL_stream_ms_position", .stack_size = 12, .ver = 50 },
            .{ .name = "RIB_alloc_provider_handle", .stack_size = 4, .ver = 40, .cdecl = true, .ver_max = 79 },
            .{ .name = "RIB_alloc_provider_handle", .stack_size = 4, .ver = 80, .symbol = "RIB_alloc_provider_handle_std" },
            .{ .name = "RIB_free_provider_handle", .stack_size = 4, .ver = 40, .cdecl = true, .ver_max = 79 },
            .{ .name = "RIB_free_provider_handle", .stack_size = 4, .ver = 80, .symbol = "RIB_free_provider_handle_std" },
            .{ .name = "RIB_register_interface", .stack_size = 16, .ver = 40, .cdecl = true, .ver_max = 79 },
            .{ .name = "RIB_register_interface", .stack_size = 16, .ver = 80, .symbol = "RIB_register_interface_std" },
            .{ .name = "RIB_unregister_interface", .stack_size = 16, .ver = 40, .cdecl = true, .ver_max = 79 },
            .{ .name = "RIB_unregister_interface", .stack_size = 16, .ver = 80, .symbol = "RIB_unregister_interface_std" },
            .{ .name = "RIB_provider_library_handle", .stack_size = 0, .ver = 50, .ver_max = 61 },
            .{ .name = "RIB_load_application_providers", .stack_size = 4, .ver = 50 },
            .{ .name = "RIB_enumerate_providers", .stack_size = 12, .ver = 50 },
            .{ .name = "RIB_request_interface", .stack_size = 16, .ver = 40, .cdecl = true, .ver_max = 79 },
            .{ .name = "RIB_request_interface", .stack_size = 16, .ver = 80, .symbol = "RIB_request_interface_std" },
            .{ .name = "RIB_find_files_provider", .stack_size = 20, .ver = 61 },
            .{ .name = "AIL_open_filter", .stack_size = 8, .ver = 61 },
            .{ .name = "AIL_close_filter", .stack_size = 4, .ver = 61 },
            .{ .name = "AIL_set_sample_filter", .stack_size = 12, .ver = 60 },
            .{ .name = "AIL_filter_attribute", .stack_size = 12, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_set_filter_attribute", .stack_size = 12, .ver = 60 },
            .{ .name = "AIL_enumerate_filters", .stack_size = 12, .ver = 61 },
            .{ .name = "AIL_enumerate_3D_providers", .stack_size = 12, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_allocate_3D_sample_handle", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_release_3D_sample_handle", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_set_3D_sample_file", .stack_size = 8, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_set_3D_position", .stack_size = 16, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_set_3D_velocity", .stack_size = 20, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_set_3D_orientation", .stack_size = 28, .ver = 50, .ver_max = 65 },
            // v6+ simplified the distances calls to 3 args (@12); v4/v5 used the
            // wider 5-arg (@20) form (v5 also adds a float_distances @20 pair).
            .{ .name = "AIL_set_3D_sample_distances", .stack_size = 12, .ver = 60, .ver_max = 69 },
            .{ .name = "AIL_set_3D_sample_distances", .stack_size = 20, .ver = 40, .ver_max = 59, .symbol = "AIL_set_3D_sample_distances_v4" },
            .{ .name = "AIL_set_3D_sample_float_distances", .stack_size = 20, .ver = 50, .ver_max = 59, .symbol = "AIL_set_3D_sample_float_distances_v5" },
            .{ .name = "AIL_3D_sample_float_distances", .stack_size = 20, .ver = 50, .ver_max = 59, .symbol = "AIL_3D_sample_float_distances_v5" },
            .{ .name = "AIL_set_listener_3D_position", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_set_listener_3D_velocity", .stack_size = 20, .ver = 70 },
            .{ .name = "AIL_set_listener_3D_orientation", .stack_size = 28, .ver = 70 },
            .{ .name = "AIL_register_timer", .stack_size = 4 },
            .{ .name = "AIL_set_timer_frequency", .stack_size = 8 },
            .{ .name = "AIL_set_timer_period", .stack_size = 8 },
            .{ .name = "AIL_set_timer_user_data", .stack_size = 8 },
            .{ .name = "AIL_start_timer", .stack_size = 4 },
            .{ .name = "AIL_stop_timer", .stack_size = 4 },
            .{ .name = "AIL_release_timer_handle", .stack_size = 4 },
            .{ .name = "AIL_start_all_timers", .stack_size = 0 },
            .{ .name = "AIL_stop_all_timers", .stack_size = 0 },
            .{ .name = "AIL_quick_startup", .stack_size = 20, .ver = 30, .ver_max = 70 },
            .{ .name = "AIL_quick_shutdown", .stack_size = 0, .ver = 30, .ver_max = 70 },
            .{ .name = "AIL_quick_load", .stack_size = 4, .ver = 30, .ver_max = 70 },
            .{ .name = "AIL_quick_load_mem", .stack_size = 8, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_quick_copy", .stack_size = 4, .ver = 30, .ver_max = 70 },
            .{ .name = "AIL_quick_unload", .stack_size = 4, .ver = 30, .ver_max = 70 },
            .{ .name = "AIL_quick_play", .stack_size = 8, .ver = 30, .ver_max = 70 },
            .{ .name = "AIL_quick_stop", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_quick_status", .stack_size = 4, .ver = 30, .ver_max = 70 },
            // Volume args switch S32 (0..127) -> F32 (0.0..1.0) in the Miles-7 API.
            // quick_set_volume took S32 0..127 through 6.1 but switched to F32 in
            // 6.5: disassembly of the debug-log format string is "%ld,%ld" in 6.1d,
            // "%f,%f" in 6.5h, and "%s,%s" (float->string) in 7.0k. So the float
            // variant starts at 6.2, not 7.0.
            .{ .name = "AIL_quick_set_volume", .stack_size = 12, .ver = 30, .ver_max = 61 },
            .{ .name = "AIL_quick_set_volume", .stack_size = 12, .ver = 62, .symbol = "AIL_quick_set_volume_f32" },
            .{ .name = "AIL_quick_set_speed", .stack_size = 8, .ver = 30, .ver_max = 70 },
            .{ .name = "AIL_quick_ms_length", .stack_size = 4, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_quick_ms_position", .stack_size = 4, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_quick_set_ms_position", .stack_size = 8, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_redbook_open", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_redbook_close", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_redbook_play", .stack_size = 12, .ver_max = 70 },
            .{ .name = "AIL_redbook_stop", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_redbook_pause", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_redbook_resume", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_redbook_status", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_redbook_tracks", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_open_ASI_provider", .stack_size = 8, .ver = 40 },
            .{ .name = "AIL_close_ASI_provider", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_ASI_provider_attribute", .stack_size = 8, .ver = 40 },
            .{ .name = "AIL_compress_ASI", .stack_size = 20, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_decompress_ASI", .stack_size = 24, .ver = 50 },
            .{ .name = "AIL_mem_alloc_lock", .stack_size = 4, .ver = 30 },
            .{ .name = "AIL_mem_free_lock", .stack_size = 4, .ver = 30 },
            // 3D Sample control
            .{ .name = "AIL_start_3D_sample", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_stop_3D_sample", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_resume_3D_sample", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_end_3D_sample", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_3D_sample_status", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_3D_sample_volume", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_set_3D_sample_volume", .stack_size = 8, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_3D_sample_loop_count", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_set_3D_sample_loop_count", .stack_size = 8, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_3D_sample_playback_rate", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_set_3D_sample_playback_rate", .stack_size = 8, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_3D_sample_offset", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_set_3D_sample_offset", .stack_size = 8, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_3D_sample_length", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_3D_sample_ms_position", .stack_size = 12, .ver = 50 },
            .{ .name = "AIL_set_3D_sample_ms_position", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_register_3D_EOS_callback", .stack_size = 8, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_active_3D_sample_count", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_3D_user_data", .stack_size = 8, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_set_3D_user_data", .stack_size = 12, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_set_3D_sample_info", .stack_size = 8, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_set_3D_sample_loop_block", .stack_size = 12, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_set_3D_sample_cone", .stack_size = 16, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_3D_sample_cone", .stack_size = 16, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_set_3D_sample_effects_level", .stack_size = 8, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_3D_sample_effects_level", .stack_size = 4, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_set_3D_sample_obstruction", .stack_size = 8, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_3D_sample_obstruction", .stack_size = 4, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_set_3D_sample_occlusion", .stack_size = 8, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_3D_sample_occlusion", .stack_size = 4, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_set_3D_sample_preference", .stack_size = 12, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_3D_sample_attribute", .stack_size = 12, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_auto_update_3D_position", .stack_size = 8, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_update_3D_position", .stack_size = 8, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_set_3D_velocity_vector", .stack_size = 16, .ver = 50, .ver_max = 65 },
            // 3D Environment
            .{ .name = "AIL_set_3D_distance_factor", .stack_size = 8, .ver = 61 },
            .{ .name = "AIL_3D_distance_factor", .stack_size = 4, .ver = 61 },
            .{ .name = "AIL_set_3D_doppler_factor", .stack_size = 8, .ver = 61 },
            .{ .name = "AIL_3D_doppler_factor", .stack_size = 4, .ver = 61 },
            .{ .name = "AIL_set_3D_rolloff_factor", .stack_size = 8, .ver = 61 },
            .{ .name = "AIL_3D_rolloff_factor", .stack_size = 4, .ver = 61 },
            .{ .name = "AIL_set_3D_room_type", .stack_size = 8, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_3D_room_type", .stack_size = 4, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_set_3D_speaker_type", .stack_size = 8, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_3D_speaker_type", .stack_size = 4, .ver = 61, .ver_max = 65 },
            // 3D Provider/Listener/Object
            .{ .name = "AIL_open_3D_provider", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_close_3D_provider", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_open_3D_listener", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_close_3D_listener", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_open_3D_object", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_close_3D_object", .stack_size = 4, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_3D_provider_attribute", .stack_size = 12, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_set_3D_provider_preference", .stack_size = 12, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_enumerate_3D_provider_attributes", .stack_size = 12, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_enumerate_3D_sample_attributes", .stack_size = 12, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_3D_orientation", .stack_size = 28, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_3D_position", .stack_size = 16, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_3D_velocity", .stack_size = 16, .ver = 50, .ver_max = 65 },
            .{ .name = "AIL_3D_update_position", .stack_size = 8, .ver = 50, .ver_max = 50 },
            .{ .name = "AIL_3D_auto_update_position", .stack_size = 8, .ver = 50, .ver_max = 50 },
            .{ .name = "AIL_get_DirectSound3D_info", .stack_size = 16, .ver_max = 39 },
            .{ .name = "AIL_set_direct_buffer_control", .stack_size = 8, .ver_max = 50 },
            .{ .name = "AIL_start_sample_at", .stack_size = 8, .ver_max = 39 },
            .{ .name = "AIL_open_stream_ex", .stack_size = 16, .ver_max = 39 },
            .{ .name = "AIL_3D_sample_distances", .stack_size = 12, .ver = 60, .ver_max = 69 },
            .{ .name = "AIL_3D_sample_distances", .stack_size = 20, .ver = 40, .ver_max = 59, .symbol = "AIL_3D_sample_distances_v4" },
            // Sequence extras
            .{ .name = "AIL_sequence_ms_position", .stack_size = 12, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_set_sequence_ms_position", .stack_size = 8, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_sequence_loop_count", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_sequence_volume", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_sequence_tempo", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_set_sequence_tempo", .stack_size = 12, .ver_max = 70 },
            .{ .name = "AIL_active_sequence_count", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_sequence_position", .stack_size = 12, .ver_max = 70 },
            .{ .name = "AIL_sequence_user_data", .stack_size = 8, .ver_max = 70 },
            .{ .name = "AIL_set_sequence_user_data", .stack_size = 12, .ver_max = 70 },
            .{ .name = "AIL_end_sequence", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_channel_notes", .stack_size = 8, .ver_max = 70 },
            .{ .name = "AIL_true_sequence_channel", .stack_size = 8, .ver_max = 70 },
            .{ .name = "AIL_map_sequence_channel", .stack_size = 12, .ver_max = 70 },
            .{ .name = "AIL_controller_value", .stack_size = 12, .ver_max = 70 },
            .{ .name = "AIL_send_channel_voice_message", .stack_size = 20, .ver_max = 70 },
            .{ .name = "AIL_send_sysex_message", .stack_size = 8, .ver_max = 70 },
            .{ .name = "AIL_lock_channel", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_release_channel", .stack_size = 8, .ver_max = 70 },
            .{ .name = "AIL_register_beat_callback", .stack_size = 8, .ver_max = 70 },
            .{ .name = "AIL_register_event_callback", .stack_size = 8, .ver_max = 70 },
            .{ .name = "AIL_register_prefix_callback", .stack_size = 8, .ver_max = 70 },
            .{ .name = "AIL_register_trigger_callback", .stack_size = 8, .ver_max = 70 },
            .{ .name = "AIL_register_sequence_callback", .stack_size = 8, .ver_max = 70 },
            .{ .name = "AIL_register_timbre_callback", .stack_size = 8, .ver_max = 70 },
            .{ .name = "AIL_register_ICA_array", .stack_size = 8, .ver_max = 70 },
            .{ .name = "AIL_XMIDI_master_volume", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_set_XMIDI_master_volume", .stack_size = 8, .ver_max = 70 },
            .{ .name = "AIL_midiOutClose", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_midiOutOpen", .stack_size = 12, .ver_max = 70 },
            .{ .name = "AIL_MIDI_handle_release", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_MIDI_handle_reacquire", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_MIDI_to_XMI", .stack_size = 20, .ver = 50, .ver_max = 70 },
            // Sample extras
            .{ .name = "AIL_sample_user_data", .stack_size = 8 },
            .{ .name = "AIL_set_sample_user_data", .stack_size = 12 },
            .{ .name = "AIL_sample_reverb", .stack_size = 16, .ver = 61, .ver_max = 61 },
            .{ .name = "AIL_set_sample_reverb", .stack_size = 16, .ver = 61, .ver_max = 61 },
            .{ .name = "AIL_set_sample_loop_block", .stack_size = 12 },
            .{ .name = "AIL_set_sample_adpcm_block_size", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_sample_granularity", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_minimum_sample_buffer_size", .stack_size = 12 },
            .{ .name = "AIL_allocate_file_sample", .stack_size = 12, .ver_max = 65 },
            .{ .name = "AIL_load_sample_buffer", .stack_size = 16 },
            .{ .name = "AIL_sample_buffer_ready", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_sample_buffer_info", .stack_size = 20, .ver_max = 70, .symbol = "AIL_sample_buffer_info_old" },
            .{ .name = "AIL_sample_buffer_info", .stack_size = 24, .ver = 80 },
            .{ .name = "AIL_register_EOB_callback", .stack_size = 8 },
            .{ .name = "AIL_register_SOB_callback", .stack_size = 8 },
            .{ .name = "AIL_set_sample_processor", .stack_size = 12, .ver = 50 },
            // Stream extras
            .{ .name = "AIL_stream_position", .stack_size = 4 },
            .{ .name = "AIL_set_stream_position", .stack_size = 8 },
            .{ .name = "AIL_stream_user_data", .stack_size = 8 },
            .{ .name = "AIL_set_stream_user_data", .stack_size = 12 },
            .{ .name = "AIL_stream_reverb", .stack_size = 16, .ver = 61, .ver_max = 61 },
            .{ .name = "AIL_set_stream_reverb", .stack_size = 16, .ver = 61, .ver_max = 61 },
            .{ .name = "AIL_stream_info", .stack_size = 20 },
            .{ .name = "AIL_set_stream_loop_block", .stack_size = 12, .ver = 61 },
            .{ .name = "AIL_service_stream", .stack_size = 8 },
            .{ .name = "AIL_register_EOF_callback", .stack_size = 8, .ver_max = 65 },
            .{ .name = "AIL_set_stream_processor", .stack_size = 12, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_filter_stream_attribute", .stack_size = 12, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_set_filter_stream_preference", .stack_size = 12, .ver = 61, .ver_max = 65 },
            // Filter extras
            .{ .name = "AIL_enumerate_filter_attributes", .stack_size = 12, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_enumerate_filter_sample_attributes", .stack_size = 12, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_filter_sample_attribute", .stack_size = 12, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_set_filter_sample_preference", .stack_size = 12, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_set_filter_DLS_preference", .stack_size = 12, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_set_filter_preference", .stack_size = 12, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_filter_DLS_attribute", .stack_size = 12, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_filter_DLS_with_XMI", .stack_size = 24, .ver = 50, .ver_max = 70 },
            // Quick API extras
            .{ .name = "AIL_quick_halt", .stack_size = 4, .ver = 30, .ver_max = 70 },
            .{ .name = "AIL_quick_set_reverb", .stack_size = 16, .ver = 61, .ver_max = 61 },
            .{ .name = "AIL_quick_load_and_play", .stack_size = 12, .ver = 30, .ver_max = 70 },
            .{ .name = "AIL_quick_type", .stack_size = 4, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_quick_handles", .stack_size = 8, .ver = 30, .ver_max = 39, .symbol = "AIL_quick_handles_v3" },
            .{ .name = "AIL_quick_handles", .stack_size = 12, .ver = 40 },
            // DLS extras
            .{ .name = "AIL_DLS_load_memory", .stack_size = 12, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_DLS_unload", .stack_size = 8, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_DLS_compact", .stack_size = 4, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_DLS_get_info", .stack_size = 12, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_DLS_get_reverb", .stack_size = 16, .ver = 61, .ver_max = 61 },
            .{ .name = "AIL_DLS_set_reverb", .stack_size = 16, .ver = 61, .ver_max = 61 },
            .{ .name = "AIL_DLS_open", .stack_size = 28, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_DLS_close", .stack_size = 8, .ver = 50, .ver_max = 70 },
            // Redbook extras
            .{ .name = "AIL_redbook_eject", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_redbook_retract", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_redbook_id", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_redbook_open_drive", .stack_size = 4, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_redbook_position", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_redbook_track", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_redbook_track_info", .stack_size = 16, .ver_max = 70 },
            .{ .name = "AIL_redbook_set_volume", .stack_size = 8, .ver_max = 61 },
            .{ .name = "AIL_redbook_volume", .stack_size = 4, .ver_max = 61 },
            // RIB extras
            .{ .name = "RIB_error", .stack_size = 0, .ver = 40, .cdecl = true, .ver_max = 79 },
            .{ .name = "RIB_error", .stack_size = 0, .ver = 80, .symbol = "RIB_error_std" },
            .{ .name = "RIB_find_file_provider", .stack_size = 12, .ver = 40, .cdecl = true, .ver_max = 79 },
            .{ .name = "RIB_find_file_provider", .stack_size = 12, .ver = 80, .symbol = "RIB_find_file_provider_std" },
            .{ .name = "RIB_load_provider_library", .stack_size = 4, .ver = 40, .cdecl = true, .ver_max = 79 },
            .{ .name = "RIB_load_provider_library", .stack_size = 4, .ver = 80, .symbol = "RIB_load_provider_library_std" },
            .{ .name = "RIB_free_provider_library", .stack_size = 4, .ver = 40, .cdecl = true, .ver_max = 79 },
            .{ .name = "RIB_free_provider_library", .stack_size = 4, .ver = 80, .symbol = "RIB_free_provider_library_std" },
            .{ .name = "RIB_request_interface_entry", .stack_size = 20, .ver = 40, .cdecl = true, .ver_max = 79 },
            .{ .name = "RIB_request_interface_entry", .stack_size = 20, .ver = 80, .symbol = "RIB_request_interface_entry_std" },
            .{ .name = "RIB_enumerate_interface", .stack_size = 20, .ver = 40, .cdecl = true, .ver_max = 79 },
            .{ .name = "RIB_enumerate_interface", .stack_size = 20, .ver = 80, .symbol = "RIB_enumerate_interface_std" },
            .{ .name = "RIB_type_string", .stack_size = 8, .ver = 40, .cdecl = true, .ver_max = 79 },
            .{ .name = "RIB_type_string", .stack_size = 8, .ver = 80, .symbol = "RIB_type_string_std" },
            // v9-only: v7/v8 export MIX_RIB_MAIN@8 (a different ASI entry arity);
            // v4-v6 and v7/v8 do not export MSS_alloc_info/MSS_free_info at all.
            .{ .name = "MIX_RIB_MAIN", .stack_size = 20, .ver = 90 },
            .{ .name = "MIX_RIB_MAIN", .stack_size = 8, .ver = 65, .ver_max = 80, .symbol = "MIX_RIB_MAIN_v7" },
            // Intermittent export: present in 6.x and v8 (8.0j), absent from v5,
            // v7, and v9 — two separate version ranges.
                        .{ .name = "MSSDisableThreadLibraryCalls", .stack_size = 4, .ver = 80, .ver_max = 89 },
            .{ .name = "MSS_alloc_info", .stack_size = 16, .ver = 90 },
            .{ .name = "MSS_free_info", .stack_size = 16, .ver = 90 },
            .{ .name = "RIB_provider_system_data", .stack_size = 8, .ver = 50 },
            .{ .name = "RIB_provider_user_data", .stack_size = 8, .ver = 50 },
            .{ .name = "RIB_set_provider_system_data", .stack_size = 12, .ver = 50 },
            .{ .name = "RIB_set_provider_user_data", .stack_size = 12, .ver = 50 },
            .{ .name = "RIB_find_file_dec_provider", .stack_size = 20, .ver = 61 },
            .{ .name = "RIB_find_provider", .stack_size = 12, .ver = 61 },
            // Digital driver extras
            .{ .name = "AIL_primary_digital_driver", .stack_size = 4, .ver = 61 },
            .{ .name = "AIL_digital_CPU_percent", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_digital_latency", .stack_size = 4, .ver = 61 },
            .{ .name = "AIL_digital_configuration", .stack_size = 16 },
            .{ .name = "AIL_get_DirectSound_info", .stack_size = 12, .ver_max = 70 },
            .{ .name = "AIL_set_DirectSound_HWND", .stack_size = 8, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_set_digital_driver_processor", .stack_size = 12, .ver = 50 },
            .{ .name = "AIL_process_digital_audio", .stack_size = 24, .ver = 50 },
            .{ .name = "AIL_size_processed_digital_audio", .stack_size = 16, .ver = 50 },
            // Utility
            .{ .name = "AIL_ms_count", .stack_size = 0 },
            .{ .name = "AIL_us_count", .stack_size = 0, .ver = 50 },
            .{ .name = "AIL_delay", .stack_size = 4, .ver_max = 80 },
            .{ .name = "AIL_lock", .stack_size = 0, .ver_max = 80 },
            .{ .name = "AIL_unlock", .stack_size = 0, .ver_max = 80 },
            .{ .name = "AIL_lock_mutex", .stack_size = 0, .ver = 61 },
            .{ .name = "AIL_unlock_mutex", .stack_size = 0, .ver = 61 },
            .{ .name = "AIL_background", .stack_size = 0 },
            .{ .name = "AIL_MMX_available", .stack_size = 0, .ver = 50 },
            .{ .name = "AIL_HWND", .stack_size = 0, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_set_error", .stack_size = 4 },
            .{ .name = "AIL_get_timer_highest_delay", .stack_size = 0, .ver = 61 },
            .{ .name = "AIL_set_timer_divisor", .stack_size = 8, .ver_max = 80 },
            .{ .name = "AIL_set_timer_user", .stack_size = 8 },
            .{ .name = "AIL_release_all_timers", .stack_size = 0 },
            .{ .name = "AIL_file_error", .stack_size = 0 },
            .{ .name = "AIL_file_read", .stack_size = 8 },
            .{ .name = "AIL_file_size", .stack_size = 4 },
            .{ .name = "AIL_file_type", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_file_write", .stack_size = 12 },
            .{ .name = "AIL_WAV_info", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_WAV_file_write", .stack_size = 20, .ver = 50 },
            .{ .name = "AIL_mem_use_malloc", .stack_size = 4, .ver = 61 },
            .{ .name = "AIL_mem_use_free", .stack_size = 4, .ver = 61 },
            .{ .name = "AIL_set_mem_callbacks", .stack_size = 8, .ver = 40 },
            .{ .name = "AIL_compress_ADPCM", .stack_size = 12, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_decompress_ADPCM", .stack_size = 12, .ver = 50 },
            // v4/v5 used AIL_input_open@12 / AIL_input_close@4; v6 renamed them to
            // the 1-arg AIL_open_input@4 / AIL_close_input@4.
            .{ .name = "AIL_input_open", .stack_size = 12, .ver = 40, .ver_max = 59 },
            .{ .name = "AIL_input_close", .stack_size = 4, .ver = 40, .ver_max = 59, .symbol = "AIL_close_input" },
            .{ .name = "AIL_open_input", .stack_size = 4, .ver = 61 },
            .{ .name = "AIL_close_input", .stack_size = 4, .ver = 61 },
            .{ .name = "AIL_set_input_state", .stack_size = 8, .ver = 61 },
            .{ .name = "AIL_input_info", .stack_size = 4, .ver = 40, .ver_max = 66 }, // renamed to get_input_info in v7
            .{ .name = "AIL_get_input_info", .stack_size = 4, .ver = 61, .symbol = "AIL_input_info" },
            .{ .name = "AIL_set_file_callbacks", .stack_size = 16, .ver = 61 },
            .{ .name = "AIL_set_file_async_callbacks", .stack_size = 20, .ver = 61, .ver_max = 80 },
            .{ .name = "AIL_set_DLS_processor", .stack_size = 12, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_create_wave_synthesizer", .stack_size = 16, .ver_max = 70 },
            .{ .name = "AIL_destroy_wave_synthesizer", .stack_size = 4, .ver_max = 70 },
            .{ .name = "AIL_waveOutClose", .stack_size = 4, .ver_max = 65 },
            // EOB ASI reset: v7 @8 (HSAMPLE, buff_num); v8+ added new_stream_position.
            // Arity oscillates across point releases: 6.0 @8, 6.1 @12, 7.0b-d
            // @8, 7.0h+/8.x @12. We target the dominant families — the 6.0
            // mainline (@8) for v6, and 7.0h+ (@12) for v7+.
            .{ .name = "AIL_request_EOB_ASI_reset", .stack_size = 8, .ver = 60, .ver_max = 69, .symbol = "AIL_request_EOB_ASI_reset_v7" },
            .{ .name = "AIL_request_EOB_ASI_reset", .stack_size = 12, .ver = 70 },
            // DLS utilities
            .{ .name = "AIL_compress_DLS", .stack_size = 20, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_extract_DLS", .stack_size = 28, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_find_DLS", .stack_size = 24, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_list_DLS", .stack_size = 20, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_list_MIDI", .stack_size = 20, .ver = 50, .ver_max = 70 },
            .{ .name = "AIL_merge_DLS_with_XMI", .stack_size = 16, .ver = 50, .ver_max = 70 },
            // Legacy DLS* functions (no AIL_ prefix)
            .{ .name = "DLSClose", .stack_size = 8, .ver = 50, .cdecl = true, .ver_max = 70 },
            .{ .name = "DLSCompactMemory", .stack_size = 4, .ver = 50, .cdecl = true, .ver_max = 70 },
            .{ .name = "DLSGetInfo", .stack_size = 12, .ver = 50, .cdecl = true, .ver_max = 70 },
            .{ .name = "DLSLoadFile", .stack_size = 12, .ver = 50, .cdecl = true, .ver_max = 70 },
            .{ .name = "DLSLoadMemFile", .stack_size = 12, .ver = 50, .cdecl = true, .ver_max = 70 },
            .{ .name = "DLSMSSGetCPU", .stack_size = 4, .ver = 50, .ver_max = 70 },
            .{ .name = "DLSMSSOpen", .stack_size = 28, .ver = 50, .cdecl = true, .ver_max = 70 },
            .{ .name = "DLSSetAttribute", .stack_size = 12, .ver = 50, .cdecl = true, .ver_max = 70 },
            .{ .name = "DLSUnloadAll", .stack_size = 4, .ver = 50, .cdecl = true, .ver_max = 70 },
            .{ .name = "DLSUnloadFile", .stack_size = 8, .ver = 50, .cdecl = true, .ver_max = 70 },
            // DLL entry point
            .{ .name = "DllMain", .stack_size = 12, .ver_max = 70 },
            .{ .name = "AIL_set_sample_3D_position", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_set_sample_3D_velocity", .stack_size = 20, .ver = 70 },
            .{ .name = "AIL_set_sample_3D_velocity_vector", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_set_sample_3D_orientation", .stack_size = 28, .ver = 70 },
            .{ .name = "AIL_set_sample_3D_cone", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_set_sample_3D_distances", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_update_sample_3D_position", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_sample_3D_position", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_sample_3D_velocity", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_sample_3D_orientation", .stack_size = 28, .ver = 70 },
            .{ .name = "AIL_sample_3D_cone", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_sample_3D_distances", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_set_sample_volume_levels", .stack_size = 12, .ver = 65 },
            .{ .name = "AIL_sample_volume_levels", .stack_size = 12, .ver = 65 },
            .{ .name = "AIL_sample_volume_pan", .stack_size = 12, .ver = 65 },
            // low-pass cutoff first appears in 6.5 as the narrow no-channel
            // form (set @8 / get @4), carried through 7.x. v8 widened it with a
            // channel parameter (set @12 / get @8), kept through v9. 6.0/6.1
            // never exported it, so it is gated to 65+.
            .{ .name = "AIL_set_sample_low_pass_cut_off", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_set_sample_low_pass_cut_off", .stack_size = 8, .ver = 65, .ver_max = 70, .symbol = "AIL_set_sample_low_pass_cut_off_v7" },
            .{ .name = "AIL_sample_low_pass_cut_off", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_sample_low_pass_cut_off", .stack_size = 4, .ver = 65, .ver_max = 70, .symbol = "AIL_sample_low_pass_cut_off_v7" },
            .{ .name = "AIL_set_sample_reverb_levels", .stack_size = 12, .ver = 65 },
            .{ .name = "AIL_sample_reverb_levels", .stack_size = 12, .ver = 65 },
            .{ .name = "AIL_set_sample_info", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_set_sample_obstruction", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_sample_obstruction", .stack_size = 4, .ver = 70 },
            .{ .name = "AIL_set_sample_occlusion", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_sample_occlusion", .stack_size = 4, .ver = 70 },
            .{ .name = "AIL_set_sample_exclusion", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_sample_exclusion", .stack_size = 4, .ver = 70 },
            .{ .name = "AIL_listener_3D_position", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_listener_3D_velocity", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_listener_3D_orientation", .stack_size = 28, .ver = 70 },
            .{ .name = "AIL_set_listener_3D_velocity_vector", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_update_listener_3D_position", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_digital_master_volume_level", .stack_size = 4, .ver = 65 },
            .{ .name = "AIL_set_digital_master_volume_level", .stack_size = 8, .ver = 65 },
            .{ .name = "AIL_set_digital_master_reverb", .stack_size = 20, .ver = 90 },
            .{ .name = "AIL_set_digital_master_reverb", .stack_size = 16, .ver = 65, .ver_max = 80, .symbol = "AIL_set_digital_master_reverb_v7" },
            .{ .name = "AIL_digital_master_reverb", .stack_size = 20, .ver = 90 },
            .{ .name = "AIL_digital_master_reverb", .stack_size = 16, .ver = 65, .ver_max = 80, .symbol = "AIL_digital_master_reverb_v7" },
            .{ .name = "AIL_set_digital_master_reverb_levels", .stack_size = 16, .ver = 90 },
            .{ .name = "AIL_set_digital_master_reverb_levels", .stack_size = 12, .ver = 65, .ver_max = 80, .symbol = "AIL_set_digital_master_reverb_levels_v7" },
            .{ .name = "AIL_digital_master_reverb_levels", .stack_size = 16, .ver = 90 },
            .{ .name = "AIL_digital_master_reverb_levels", .stack_size = 12, .ver = 65, .ver_max = 80, .symbol = "AIL_digital_master_reverb_levels_v7" },
            .{ .name = "AIL_set_room_type", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_set_room_type", .stack_size = 8, .ver = 70, .ver_max = 80, .symbol = "AIL_set_room_type_v7" },
            .{ .name = "AIL_room_type", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_room_type", .stack_size = 4, .ver = 70, .ver_max = 80, .symbol = "AIL_room_type_v7" },
            .{ .name = "AIL_redbook_set_volume_level", .stack_size = 8, .ver = 65, .ver_max = 70 },
            .{ .name = "AIL_redbook_volume_level", .stack_size = 4, .ver = 65, .ver_max = 70 },
            // 6.5-7.x take the narrow (HAUDIO, F32) @8; v8+ widened it to
            // (HAUDIO, S32 channel, F32) @12.
            .{ .name = "AIL_quick_set_low_pass_cut_off", .stack_size = 8, .ver = 65, .ver_max = 70, .symbol = "AIL_quick_set_low_pass_cut_off_v7" },
            .{ .name = "AIL_quick_set_low_pass_cut_off", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_quick_set_reverb_levels", .stack_size = 12, .ver = 65, .ver_max = 70 },
            // 6.5/6.6-only APIs (added in 6.5, dropped in 7.x): per-stream
            // volume/pan/reverb/low-pass, H3DSAMPLE exclusion, DLS reverb-level
            // pair, and the 6.x master room-type spelling.
            .{ .name = "AIL_set_stream_volume_levels", .stack_size = 12, .ver = 65, .ver_max = 65 },
            .{ .name = "AIL_stream_volume_levels", .stack_size = 12, .ver = 65, .ver_max = 65 },
            .{ .name = "AIL_stream_volume_pan", .stack_size = 12, .ver = 65, .ver_max = 65 },
            .{ .name = "AIL_set_stream_reverb_levels", .stack_size = 12, .ver = 65, .ver_max = 65 },
            .{ .name = "AIL_stream_reverb_levels", .stack_size = 12, .ver = 65, .ver_max = 65 },
            .{ .name = "AIL_set_stream_low_pass_cut_off", .stack_size = 8, .ver = 65, .ver_max = 65 },
            .{ .name = "AIL_stream_low_pass_cut_off", .stack_size = 4, .ver = 65, .ver_max = 65 },
            // First appeared in the 6.1d patch (absent in 6.1a/6.1c), present through 6.6.
            .{ .name = "AIL_set_3D_sample_exclusion", .stack_size = 8, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_3D_sample_exclusion", .stack_size = 4, .ver = 61, .ver_max = 65 },
            .{ .name = "AIL_DLS_set_reverb_levels", .stack_size = 12, .ver = 65, .ver_max = 65 },
            .{ .name = "AIL_DLS_get_reverb_levels", .stack_size = 12, .ver = 65, .ver_max = 65 },
            .{ .name = "AIL_set_digital_master_room_type", .stack_size = 8, .ver = 65, .ver_max = 65 },
            .{ .name = "AIL_stream_sample_handle", .stack_size = 4, .ver = 70 },
            .{ .name = "AIL_DLS_sample_handle", .stack_size = 4, .ver = 70, .ver_max = 70 },
            .{ .name = "AIL_find_filter", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_background_CPU_percent", .stack_size = 0, .ver = 70 },
            .{ .name = "AIL_sample_processor", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_digital_driver_processor", .stack_size = 8, .ver = 70 },
            // DSP stage attributes were a v7-only API (@16, with a stage index).
            .{ .name = "AIL_sample_stage_attribute", .stack_size = 16, .ver = 70, .ver_max = 70, .symbol = "AIL_sample_stage_attribute_v7" },
            .{ .name = "AIL_set_sample_stage_preference", .stack_size = 16, .ver = 70, .ver_max = 70, .symbol = "AIL_set_sample_stage_preference_v7" },
            .{ .name = "AIL_enumerate_sample_stage_attributes", .stack_size = 16, .ver = 70, .ver_max = 70, .symbol = "AIL_enumerate_sample_stage_attributes_v7" },
            // channel levels: v7 @8/@12 lacked the src/dst matrices v8 added (@20).
            .{ .name = "AIL_sample_channel_levels", .stack_size = 20, .ver = 80 },
                        .{ .name = "AIL_sample_channel_levels", .stack_size = 8, .ver = 70, .ver_max = 70, .symbol = "AIL_sample_channel_levels_v7" },
            .{ .name = "AIL_set_sample_channel_levels", .stack_size = 20, .ver = 80 },
                        .{ .name = "AIL_set_sample_channel_levels", .stack_size = 12, .ver = 70, .ver_max = 70, .symbol = "AIL_set_sample_channel_levels_v7" },
            .{ .name = "AIL_listener_relative_receiver_array", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_set_listener_relative_receiver_array", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_speaker_configuration", .stack_size = 20, .ver = 70 },
            .{ .name = "AIL_set_speaker_configuration", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_speaker_reverb_levels", .stack_size = 16, .ver = 70 },
            // speaker reverb levels: v7 @16 lacked the per-speaker index array (v8 @20).
            .{ .name = "AIL_set_speaker_reverb_levels", .stack_size = 20, .ver = 80 },
                        .{ .name = "AIL_set_speaker_reverb_levels", .stack_size = 16, .ver = 70, .ver_max = 70, .symbol = "AIL_set_speaker_reverb_levels_v7" },
            .{ .name = "AIL_calculate_3D_channel_levels", .stack_size = 56, .ver = 70, .ver_max = 70, .symbol = "AIL_calculate_3D_channel_levels_v7" },
            .{ .name = "AIL_calculate_3D_channel_levels", .stack_size = 68, .ver = 80 },
                        .{ .name = "AIL_digital_output_filter", .stack_size = 4, .ver = 70 },
            .{ .name = "AIL_output_filter_driver_attribute", .stack_size = 12, .ver = 70, .ver_max = 79 },
            .{ .name = "AIL_set_output_filter_driver_preference", .stack_size = 12, .ver = 70, .ver_max = 79 },
            .{ .name = "AIL_enumerate_output_filter_driver_attributes", .stack_size = 12, .ver = 70, .ver_max = 79 },
            .{ .name = "AIL_enumerate_output_filter_sample_attributes", .stack_size = 12, .ver = 70, .ver_max = 79 },
            .{ .name = "AIL_inspect_MP3", .stack_size = 12, .ver = 70, .ver_max = 70 },
            .{ .name = "AIL_enumerate_MP3_frames", .stack_size = 4, .ver = 70, .ver_max = 70 },
            .{ .name = "RIB_load_static_provider_library", .stack_size = 8, .ver = 65 },
            .{ .name = "AIL_WAV_marker_by_index", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_WAV_marker_by_name", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_WAV_marker_count", .stack_size = 4, .ver = 80 },
            // v8 form @8 (2-arg); v9 adds a trailing S32 (@12).
            .{ .name = "AIL_add_apply_environment_event_step", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_add_apply_environment_event_step", .stack_size = 8, .ver = 80, .ver_max = 89, .symbol = "AIL_add_apply_environment_event_step_v8" },
            .{ .name = "AIL_add_cache_sounds_event_step", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_add_comment_event_step", .stack_size = 8, .ver = 80 },
            // v8 form @32 (8-arg); v9 adds two trailing args (@40).
            .{ .name = "AIL_add_control_sounds_event_step", .stack_size = 40, .ver = 90 },
            .{ .name = "AIL_add_control_sounds_event_step", .stack_size = 32, .ver = 80, .ver_max = 89, .symbol = "AIL_add_control_sounds_event_step_v8" },
            // v8 form @16 (4-arg); v9 adds a trailing S32 (@20).
            .{ .name = "AIL_add_persist_preset_event_step", .stack_size = 20, .ver = 90 },
            .{ .name = "AIL_add_persist_preset_event_step", .stack_size = 16, .ver = 80, .ver_max = 89, .symbol = "AIL_add_persist_preset_event_step_v8" },
            .{ .name = "AIL_add_sound_limit_event_step", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_add_sound_limit_event_step", .stack_size = 8, .ver = 80, .ver_max = 80, .symbol = "AIL_add_sound_limit_event_step_v8" },
            // v8 form @76 (19-arg); v9 adds five trailing args (@96).
            .{ .name = "AIL_add_start_sound_event_step", .stack_size = 96, .ver = 90 },
            .{ .name = "AIL_add_start_sound_event_step", .stack_size = 76, .ver = 80, .ver_max = 89, .symbol = "AIL_add_start_sound_event_step_v8" },
            .{ .name = "AIL_add_uncache_sounds_event_step", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_apply_environment_preset", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_apply_sound_preset", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_close_event", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_close_soundbank", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_create_event", .stack_size = 0, .ver = 80 },
            .{ .name = "AIL_debug", .stack_size = 4, .ver = 80, .cdecl = true },
            .{ .name = "AIL_debug_log", .stack_size = 4, .ver = 80, .cdecl = true },
            .{ .name = "AIL_enumerate_environment_presets", .stack_size = 16, .ver = 80 },
            .{ .name = "AIL_enumerate_events", .stack_size = 16, .ver = 80 },
            .{ .name = "AIL_enumerate_filter_properties", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_enumerate_filter_sample_properties", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_enumerate_output_filter_driver_properties", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_enumerate_output_filter_sample_properties", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_enumerate_sample_stage_properties", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_enumerate_sound_assets", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_enumerate_sound_presets", .stack_size = 16, .ver = 80 },
            .{ .name = "AIL_file_type_named", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_filter_property", .stack_size = 20, .ver = 70 },
            // @8 (2-arg) across all of v8 and v9.
            .{ .name = "AIL_find_marker_in_list", .stack_size = 8, .ver = 80, .symbol = "AIL_find_marker_in_list_v8" },
            // @4 (single F32) form spans 6.x-8.x (confirmed in the 6.1 and 7.x DLLs).
            .{ .name = "AIL_ftoa", .stack_size = 4, .ver = 70, .ver_max = 80, .symbol = "AIL_ftoa_v8" },
            .{ .name = "AIL_get_event_contents", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_get_marker_list", .stack_size = 8, .ver = 80 },
            // v8 form @8 (2-arg); v9 dropped the second arg (@4).
            .{ .name = "AIL_get_soundbank_filename", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_get_soundbank_filename", .stack_size = 8, .ver = 80, .ver_max = 89, .symbol = "AIL_get_soundbank_filename_v8" },
            .{ .name = "AIL_get_soundbank_mem_usage", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_indent", .stack_size = 4, .ver = 80, .cdecl = true },
            .{ .name = "AIL_mem_close", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_mem_create", .stack_size = 0, .ver = 80 },
            .{ .name = "AIL_mem_create_from_existing", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_mem_error", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_mem_open", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_mem_pos", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_mem_printc", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_mem_printf", .stack_size = 8, .ver = 80, .cdecl = true },
            .{ .name = "AIL_mem_prints", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_mem_read", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_mem_seek", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_mem_size", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_mem_write", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_next_event_step", .stack_size = 16, .ver = 80 },
            .{ .name = "AIL_open_soundbank", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_open_soundbank", .stack_size = 4, .ver = 80, .ver_max = 80, .symbol = "AIL_open_soundbank_v8" },
            .{ .name = "AIL_output_filter_driver_property", .stack_size = 20, .ver = 70 },
            .{ .name = "AIL_platform_property", .stack_size = 20, .ver = 80 },
            .{ .name = "AIL_register_falloff_function_callback", .stack_size = 8, .ver = 80 },
            // @8 (2-arg) form spans 6.x-8.x (confirmed in the 6.1 and 7.x DLLs).
            .{ .name = "AIL_register_trace_callback", .stack_size = 8, .ver = 70, .ver_max = 80, .symbol = "AIL_register_trace_callback_v8" },
            .{ .name = "AIL_sample_51_volume_levels", .stack_size = 28, .ver = 80 },
            .{ .name = "AIL_sample_51_volume_pan", .stack_size = 24, .ver = 80 },
            .{ .name = "AIL_sample_buffer_available", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_sample_buffer_count", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_sample_channel_count", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_sample_loop_block", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_sample_output_levels", .stack_size = 20, .ver = 80 },
            .{ .name = "AIL_sample_playback_delay", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_sample_playback_rate_factor", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_sample_speaker_scale_factors", .stack_size = 16, .ver = 80 },
            // Arity dips in v7: 6.x and 8.x+ take the 7-arg @28 form; v7 takes a
            // 6-arg @24 form.
                        .{ .name = "AIL_sample_stage_property", .stack_size = 24, .ver = 70, .ver_max = 79, .symbol = "AIL_sample_stage_property_v7" },
            .{ .name = "AIL_sample_stage_property", .stack_size = 28, .ver = 80 },
            .{ .name = "AIL_set_sample_51_volume_levels", .stack_size = 28, .ver = 80 },
            .{ .name = "AIL_set_sample_51_volume_pan", .stack_size = 24, .ver = 80 },
            .{ .name = "AIL_set_sample_buffer_count", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_set_sample_is_3D", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_set_sample_playback_delay", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_set_sample_playback_rate_factor", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_set_sample_speaker_scale_factors", .stack_size = 16, .ver = 80 },
            .{ .name = "AIL_sound_asset_filename", .stack_size = 12, .ver = 80, .ver_max = 80, .symbol = "AIL_sound_asset_filename_v8" },
            .{ .name = "AIL_stricmp", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_strnicmp", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_sys_debug", .stack_size = 4, .ver = 80, .cdecl = true },
            .{ .name = "AIL_unapply_environment_preset", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_unapply_sound_preset", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_IO_thread_handle", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_add_clear_state_event_step", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_add_exec_event_event_step", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_add_ramp_event_step", .stack_size = 32, .ver = 90 },
            .{ .name = "AIL_add_setblend_event_step", .stack_size = 36, .ver = 90 },
            .{ .name = "AIL_apply_raw_environment_preset", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_apply_raw_sound_preset", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_configure_logging", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_file_callbacks", .stack_size = 16, .ver = 90 },
            .{ .name = "AIL_file_read_info", .stack_size = 16, .ver = 90 },
            .{ .name = "AIL_file_size_info", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_find_environment_preset", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_find_sound_preset", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_get_soundbank_name", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_get_time", .stack_size = 0, .ver = 90 },
            .{ .name = "AIL_mem_alloc_lock_info", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_ms_count64", .stack_size = 0, .ver = 90 },
            .{ .name = "AIL_ms_to_time", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_resolve_raw_environment_preset", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_resolve_raw_sound_preset", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_sample_loaded_len", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_sample_ms_lookup", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_sleep", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_sound_asset_info", .stack_size = 16, .ver = 90 },
            .{ .name = "AIL_stream_filled_percent", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_time_to_ms", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_timer_thread_handle", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_unapply_raw_environment_preset", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_unapply_raw_sound_preset", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_us_count64", .stack_size = 0, .ver = 90 },
            .{ .name = "AIL_set_sample_id", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_sample_id", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_set_sample_bus", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_sample_bus", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_set_sample_level_mask", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_sample_level_mask", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_set_sample_3D_spread", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_allocate_bus", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_free_all_busses", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_bus_sample_handle", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_enable_limiter", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_bus_enable_limiter", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_install_bus_compressor", .stack_size = 16, .ver = 90 },
            .{ .name = "AIL_digital_mixed_samples", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_register_mix_callback", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_end_fade_sample", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_sample_mixed_ms", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_sample_schedule_time", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_schedule_start_sample", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_set_sample_loop_samples", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_push_system_state", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_pop_system_state", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_system_state_level", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_set_async_callbacks", .stack_size = 28, .ver = 90 },
            .{ .name = "AIL_start_sample_group", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_stop_sample_group", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_resume_sample_group", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_end_sample_group", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_set_sample_3D_volume_falloff", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_set_sample_3D_exclusion_falloff", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_set_sample_3D_lowpass_falloff", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_set_sample_3D_spread_falloff", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_set_sample_3D_position_segments", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_enqueue_event_start", .stack_size = 0, .ver = 90 },
            .{ .name = "AIL_enqueue_event_cancel", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_enqueue_event_context", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_enqueue_event_end_named", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_enqueue_event_selection", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_enqueue_event_filter", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_enqueue_event_variablef", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_enqueue_event_buffer", .stack_size = 16, .ver = 90 },
            .{ .name = "AIL_enqueue_event_position", .stack_size = 16, .ver = 90 },
            .{ .name = "AIL_enqueue_event_velocity", .stack_size = 20, .ver = 90 },
            .{ .name = "AIL_event_system_command_queue_remaining", .stack_size = 0, .ver = 90 },
            .{ .name = "AIL_set_event_settings", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_set_event_sample_functions", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_add_enable_limit_event_step", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_add_move_var_event_step", .stack_size = 20, .ver = 90 },
            .{ .name = "AIL_add_set_lfo_event_step", .stack_size = 40, .ver = 90 },
            // Miles 9.x event-system C-ABI (the 9.x SDK aliases AIL_* event names
            // onto these). Real mss32.dll 9.x exports the Miles* set.
            // @16 (4-arg) in both v8 and v9 — the default covers both.
            .{ .name = "MilesStartupEventSystem", .stack_size = 16, .ver = 80 },
            .{ .name = "MilesShutdownEventSystem", .stack_size = 0, .ver = 80 },
            .{ .name = "MilesAddEventSystem", .stack_size = 4, .ver = 90 },
            .{ .name = "MilesGetEventSystemState", .stack_size = 8, .ver = 90 },
            .{ .name = "MilesGetEventSystemState", .stack_size = 4, .ver = 80, .ver_max = 80, .symbol = "MilesGetEventSystemState_v8" },
            .{ .name = "MilesSetVarI", .stack_size = 12, .ver = 90 },
            .{ .name = "MilesSetVarF", .stack_size = 12, .ver = 90 },
            .{ .name = "MilesGetVarI", .stack_size = 12, .ver = 90 },
            .{ .name = "MilesGetVarF", .stack_size = 12, .ver = 90 },
            .{ .name = "MilesEnqueueEvent", .stack_size = 24, .ver = 80 },
            .{ .name = "MilesEnqueueEventContext", .stack_size = 28, .ver = 90 },
            .{ .name = "MilesEnqueueEventByName", .stack_size = 4, .ver = 90 },
            .{ .name = "MilesBeginEventQueueProcessing", .stack_size = 0, .ver = 80 },
            .{ .name = "MilesCompleteEventQueueProcessing", .stack_size = 0, .ver = 80 },
            .{ .name = "MilesClearEventQueue", .stack_size = 0, .ver = 80 },
            .{ .name = "MilesStartSoundInstance", .stack_size = 32, .ver = 80 },
            .{ .name = "MilesStopSoundInstances", .stack_size = 12, .ver = 80 },
            .{ .name = "MilesPauseSoundInstances", .stack_size = 12, .ver = 80 },
            .{ .name = "MilesResumeSoundInstances", .stack_size = 12, .ver = 80 },
            .{ .name = "MilesEnumerateSoundInstances", .stack_size = 28, .ver = 90 },
            .{ .name = "MilesEnumerateSoundInstances", .stack_size = 24, .ver = 80, .ver_max = 80, .symbol = "MilesEnumerateSoundInstances_v8" },
            .{ .name = "MilesEnumeratePresetPersists", .stack_size = 12, .ver = 90 },
            .{ .name = "MilesEnumeratePresetPersists", .stack_size = 8, .ver = 80, .ver_max = 80, .symbol = "MilesEnumeratePresetPersists_v8" },
            .{ .name = "MilesSetSoundStartOffset", .stack_size = 12, .ver = 90 },
            .{ .name = "MilesSetSoundLabelLimits", .stack_size = 8, .ver = 90 },
            .{ .name = "MilesSetSoundLabelLimits", .stack_size = 4, .ver = 80, .ver_max = 80, .symbol = "MilesSetSoundLabelLimits_v8" },
            .{ .name = "MilesAddSoundBank", .stack_size = 8, .ver = 90 },
            .{ .name = "MilesAddSoundBank", .stack_size = 4, .ver = 80, .ver_max = 80, .symbol = "MilesAddSoundBank_v8" },
            .{ .name = "MilesReleaseSoundBank", .stack_size = 4, .ver = 80 },
            .{ .name = "MilesFindEvent", .stack_size = 8, .ver = 80 },
            .{ .name = "MilesGetEventLength", .stack_size = 4, .ver = 90 },
            .{ .name = "MilesTextDumpEventSystem", .stack_size = 0, .ver = 80 },
            .{ .name = "MilesRegisterRand", .stack_size = 4, .ver = 80 },
            .{ .name = "MilesSetEventErrorCallback", .stack_size = 4, .ver = 80 },
            .{ .name = "MilesEventSetAuditionFunctions", .stack_size = 4, .ver = 90, .cdecl = true },
            .{ .name = "MilesGetBankFunctions", .stack_size = 0, .ver = 90 },
            .{ .name = "MilesSetBankFunctions", .stack_size = 4, .ver = 80 },
            .{ .name = "MilesUseTelemetry", .stack_size = 4, .ver = 90 },
            .{ .name = "MilesUseTmLite", .stack_size = 4, .ver = 90 },
            .{ .name = "MilesAsyncStartup", .stack_size = 0, .ver = 90 },
            .{ .name = "MilesAsyncShutdown", .stack_size = 0, .ver = 90 },
            .{ .name = "MilesAsyncFileRead", .stack_size = 4, .ver = 90 },
            .{ .name = "MilesAsyncFileCancel", .stack_size = 4, .ver = 90 },
            .{ .name = "MilesAsyncFileStatus", .stack_size = 8, .ver = 90 },
            .{ .name = "MilesAsyncSetPaused", .stack_size = 4, .ver = 90 },
            .{ .name = "MilesRequeueAsyncs", .stack_size = 0, .ver = 90 },
            // Quick-API mem loader with a filename format hint (6.x onward).
            .{ .name = "AIL_quick_load_named_mem", .stack_size = 12, .ver = 70, .ver_max = 70 },
            // 6.x-only embedded-library + sample-attribute exports (gone by 7.0).
            .{ .name = "AIL_open_library", .stack_size = 8, .ver = 60, .ver_max = 69 },
            .{ .name = "AIL_close_library", .stack_size = 4, .ver = 60, .ver_max = 69 },
            .{ .name = "AIL_library_resource_filename", .stack_size = 16, .ver = 60, .ver_max = 69 },
            .{ .name = "AIL_load_sample_attributes", .stack_size = 8, .ver = 60, .ver_max = 69 },
            .{ .name = "AIL_save_sample_attributes", .stack_size = 8, .ver = 60, .ver_max = 69 },
        };
        // Emit one PE export per active target, as the MSVC-decorated stdcall
        // name `_NAME@stack`, via @export rather than `export fn`. A bare
        // `export fn` would ALSO leak the underscore-less `NAME@stack` symbol,
        // doubling the table and shifting the alphabetical ordinal numbering
        // away from the reference DLL. With @export only the decorated name is
        // emitted; Zig appends the `@stack` suffix from each function's own
        // arity, so the per-version arity variants resolve automatically. The
        // function is located by name (or `symbol` override) across the api
        // modules — none of which import this one, so there is no cycle.
        const mods = .{
            @This(),                  @import("3d.zig"),     @import("stream.zig"),
            @import("quick.zig"),     @import("redbook.zig"), @import("timer.zig"),
            @import("file.zig"),      @import("input.zig"),  @import("midi.zig"),
            @import("dls.zig"),       @import("rib.zig"),    @import("filter.zig"),
            @import("memory.zig"),    @import("v7.zig"),     @import("v8.zig"),
            @import("v9.zig"),         @import("miles.zig"),  @import("legacy.zig"),
        };
        // API families dropped wholesale in MSS 8.0. The 8.0e/9.1d DLLs export
        // none of these symbols (all are present through 7.0k), so emitting them
        // would bloat the export table beyond the reference. Each token below was
        // verified to occur in zero 8.0e/9.1d exports and >0 7.0k exports, so a
        // substring match is safe and only suppresses these from 8.0 on. Covered:
        // the Quick API, Redbook (CD audio), the whole XMIDI/MIDI-sequencer stack
        // (sequences, channels, MIDI/XMIDI drivers, midiOut, the MIDI callback
        // registrations, the software wave synthesizer) and the DLS API.
        const removed_at_80 = [_][]const u8{
            "redbook",            "quick",                "sequence",
            "DLS",                "midiOut",              "XMIDI",
            "midi_driver",        "register_beat",        "register_trigger",
            "register_sequence",  "register_timbre",      "register_prefix",
            "register_ICA",       "channel_notes",        "lock_channel",
            "release_channel",    "send_channel_voice",   "send_sysex",
            "controller_value",   "branch_index",         "wave_synthesizer",
            "map_sequence",       "true_sequence",
        };
        // Export names that appear in NO reference DLL (3.6a..9.1d) and nowhere in
        // the 9.3b SDK (headers + source). These table entries were mistakes: no
        // real Miles release ever exported them, so they must not appear in any
        // version's export table. Their implementations remain callable internally
        // and from tests; they are simply never emitted as PE exports.
        const never_export = [_][]const u8{
            "AIL_pause_sample",
            "AIL_open_ASI_provider",
            "AIL_close_ASI_provider",
            "AIL_ASI_provider_attribute",
            "AIL_3D_sample_ms_position",
            "AIL_set_3D_sample_ms_position",
            "AIL_set_event_sample_functions",
            "AIL_set_filter_attribute",
            "AIL_set_sample_filter",
            "AIL_set_mem_callbacks",
            "AIL_set_timer_user_data",
            // Wrong-name duplicates: a real Miles export exists under a different
            // name (open_XMIDI_driver, quick_halt, DLS_unload, open_input/
            // close_input/get_input_info, ...). We already export the correct
            // names (parity MISSING stays 0); these aliases are emitted by no
            // real release.
            "AIL_open_midi_driver",
            "AIL_close_midi_driver",
            "AIL_quick_stop",
            "AIL_DLS_unload_file",
            "AIL_input_open",
            "AIL_input_close",
            "AIL_input_info",
            "AIL_pause_sequence",
            "AIL_3D_sample_float_distances",
            "AIL_set_3D_sample_float_distances",
            "AIL_open_stream_by_sample",
            "AIL_open_stream_ex",
            "AIL_start_sample_at",
            "AIL_get_DirectSound3D_info",
            // The v6 "resource library" and sample-attribute persistence names,
            // and the filter/stage *_attribute / *_preference spellings: none
            // appear in any reference DLL or SDK header (the real DSP-property
            // surface uses *_property, handled elsewhere).
            "AIL_open_library",
            "AIL_close_library",
            "AIL_library_resource_filename",
            "AIL_load_sample_attributes",
            "AIL_save_sample_attributes",
            "AIL_sample_stage_attribute",
            "AIL_set_sample_stage_preference",
            "AIL_output_filter_driver_attribute",
            "AIL_set_output_filter_driver_preference",
            "AIL_enumerate_sample_stage_attributes",
            "AIL_enumerate_output_filter_driver_attributes",
            "AIL_enumerate_output_filter_sample_attributes",
        };
        for (targets) |t| {
            if (openmiles.mss_version < t.ver or openmiles.mss_version > t.ver_max) continue;
            const dropped = openmiles.mss_version >= 80 and for (removed_at_80) |tok| {
                if (std.mem.indexOf(u8, t.name, tok) != null) break true;
            } else false;
            if (dropped) continue;
            const spurious = for (never_export) |n| {
                if (std.mem.eql(u8, t.name, n)) break true;
            } else false;
            if (spurious) continue;
            const fname = t.symbol orelse t.name;
            const exp_name = if (t.cdecl) t.name else "_" ++ t.name;
            for (mods) |m| {
                if (@hasDecl(m, fname)) {
                    @export(&@field(m, fname), .{ .name = exp_name, .linkage = .strong });
                    break;
                }
            }
        }
        // (The CRT entry DllMainCRTStartup is the PE entry point via the header,
        // not an export — real mss32.dll does not export it, so neither do we.)
        // Variadic functions use callconv(.c), generating `_FuncName` in COFF (not `_FuncName@N`).
        // They are NOT in the stdcall targets loop, so they need explicit /EXPORT renames so the
        // DLL export table contains the bare name (AIL_debug_printf) rather than _AIL_debug_printf.
        // The linker automatically prepends `_` to the symbol reference in /EXPORT:name=symbol,
        // so we use the bare name (without leading underscore) as the symbol.
        // AIL_sprintf was introduced in 5.0 (3.6a exports neither it nor
        // AIL_debug_printf); AIL_debug_printf runs 5.0..8.0 and is gone by 9.1d.
        if (openmiles.mss_version >= 50) {
            asm (".section .drectve\n .ascii \" /EXPORT:AIL_sprintf=AIL_sprintf\"\n .text\n");
        }
        if (openmiles.mss_version >= 50 and openmiles.mss_version <= 80) {
            asm (".section .drectve\n .ascii \" /EXPORT:AIL_debug_printf=AIL_debug_printf\"\n .text\n");
        }
        // `stream_background`: an undocumented internal symbol that leaked into
        // the 6.1-6.6 export tables. Its decoration varies *within* a minor
        // version: fastcall `@stream_background@0` in 6.1 and 6.5a-c, but
        // undecorated `stream_background` from 6.5d onward (and all of 6.6),
        // confirming it is an accidental export, not an API. Our canonical 6.5
        // reference is 6.5h (a 6.5d+ patch), which exports the undecorated form
        // only, so for v65 we emit just that and match it exactly.
        if (openmiles.mss_version == 61) {
            asm (".section .drectve\n .ascii \" /EXPORT:@stream_background@0=mss_stream_background_stub\"\n .text\n");
        } else if (openmiles.mss_version == 65) {
            asm (".section .drectve\n .ascii \" /EXPORT:stream_background=mss_stream_background_stub\"\n .text\n");
        } else if (openmiles.mss_version == 66) {
            asm (".section .drectve\n .ascii \" /EXPORT:stream_background=mss_stream_background_stub\"\n .text\n");
        }
    }
}

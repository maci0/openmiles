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

pub export fn AIL_startup() callconv(.winapi) void {
    log("ENTER AIL_startup\n", .{});
    openmiles.startup();
    log("EXIT AIL_startup\n", .{});
}
pub export fn AIL_shutdown() callconv(.winapi) void {
    log("AIL_shutdown()\n", .{});
    openmiles.shutdown();
}
pub export fn AIL_set_redist_directory(path: [*:0]const u8) callconv(.winapi) void {
    log("AIL_set_redist_directory(path={s})\n", .{path});
    openmiles.setRedistDirectory(std.mem.span(path));
}
pub export fn AIL_last_error() callconv(.winapi) [*:0]const u8 {
    if (openmiles.last_error_buf[0] == 0) return "";
    return &openmiles.last_error_buf;
}
pub export fn AIL_get_preference(number: u32) callconv(.winapi) i32 {
    return openmiles.getPreference(number);
}
pub export fn AIL_set_preference(number: u32, value: i32) callconv(.winapi) i32 {
    log("AIL_set_preference(number={d}, value={d})\n", .{ number, value });
    return openmiles.setPreference(number, value);
}
pub export fn AIL_waveOutOpen(drvr_ptr: ?*?*DigitalDriver, lphwo: ?*u32, device_id: i32, format: ?*anyopaque) callconv(.winapi) u32 {
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
pub export fn AIL_digital_handle_release(driver_opt: ?*DigitalDriver) callconv(.winapi) i32 {
    const driver = driver_opt orelse return 0;
    log("AIL_digital_handle_release(driver={*})\n", .{driver});
    return 1;
}
pub export fn AIL_digital_handle_reacquire(driver_opt: ?*DigitalDriver) callconv(.winapi) i32 {
    const driver = driver_opt orelse return 0;
    log("AIL_digital_handle_reacquire(driver={*})\n", .{driver});
    return 1;
}
pub export fn AIL_set_named_sample_file(s_opt: ?*Sample, file_type: [*:0]const u8, file_image: *const anyopaque, size: i32, flags: u32) callconv(.winapi) i32 {
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
pub export fn AIL_sample_volume(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return s.original_volume;
}
pub export fn AIL_sample_pan(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return openmiles.panToMss(s.pan);
}
pub export fn AIL_sample_playback_rate(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return @intFromFloat(s.target_rate orelse 44100.0);
}
pub export fn AIL_set_sample_volume_pan(s_opt: ?*Sample, volume: i32, pan: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_volume_pan(s={*}, volume={d}, pan={d})\n", .{ s, volume, pan });
    s.setVolumePan(volume, pan);
}
pub export fn AIL_active_sample_count(driver_opt: ?*DigitalDriver) callconv(.winapi) u32 {
    const driver = driver_opt orelse return 0;
    return driver.getActiveSampleCount();
}
pub export fn AIL_sample_ms_position(s_opt: ?*Sample, total_ms: ?*i32, current_ms: ?*i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    const pos = s.getMsPosition();
    if (total_ms) |t| t.* = pos.total;
    if (current_ms) |c| c.* = pos.current;
}
pub export fn AIL_set_sample_ms_position(s_opt: ?*Sample, ms: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_ms_position(s={*}, ms={d})\n", .{ s, ms });
    s.setMsPosition(ms);
}
pub export fn AIL_sample_position(s_opt: ?*Sample) callconv(.winapi) u32 {
    const s = s_opt orelse return 0;
    return s.getPosition();
}
pub export fn AIL_set_sample_position(s_opt: ?*Sample, pos: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_position(s={*}, pos={d})\n", .{ s, pos });
    s.setPosition(pos);
}
pub export fn AIL_sample_loop_count(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return s.loop_count;
}
pub export fn AIL_register_EOS_callback(s_opt: ?*Sample, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    log("AIL_register_EOS_callback(s={*}, callback={*})\n", .{ s, callback });
    const prev: ?*anyopaque = @ptrFromInt(s.eos_callback);
    s.eos_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_open_digital_driver(frequency: u32, bits: i32, channels: i32, flags: u32) callconv(.winapi) ?*DigitalDriver {
    log("AIL_open_digital_driver(freq={d}, bits={d}, chans={d}, flags={d})\n", .{ frequency, bits, channels, flags });
    return openmiles.openDigitalDriver(frequency, bits, channels);
}
pub export fn AIL_close_digital_driver(driver_opt: ?*DigitalDriver) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    log("AIL_close_digital_driver(driver={*})\n", .{driver});
    openmiles.closeDigitalDriver(driver);
}
pub export fn AIL_serve() callconv(.winapi) void {}
pub export fn AIL_set_digital_master_volume(driver_opt: ?*DigitalDriver, master_volume: i32) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    log("AIL_set_digital_master_volume(driver={*}, volume={d})\n", .{ driver, master_volume });
    driver.setMasterVolume(openmiles.mssVolumeToGain(master_volume));
}
pub export fn AIL_digital_master_volume(driver_opt: ?*DigitalDriver) callconv(.winapi) i32 {
    const driver = driver_opt orelse return 0;
    return openmiles.gainToMssVolume(driver.getMasterVolume());
}
pub export fn AIL_allocate_sample_handle(driver_opt: ?*DigitalDriver) callconv(.winapi) ?*Sample {
    const driver = driver_opt orelse return null;
    log("AIL_allocate_sample_handle(driver={*})\n", .{driver});
    return openmiles.Sample.init(driver) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
}
pub export fn AIL_release_sample_handle(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_release_sample_handle(s={*})\n", .{s});
    s.deinit();
}
pub export fn AIL_init_sample(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_init_sample(s={*})\n", .{s});
    s.reset();
}
pub export fn AIL_set_sample_file(s_opt: ?*Sample, data: *anyopaque, block: i32) callconv(.winapi) i32 {
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
pub export fn AIL_set_sample_address(s_opt: ?*Sample, data: *anyopaque, size: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_address(s={*}, data={*}, size={d})\n", .{ s, data, size });
    s.setAddress(data, size) catch |err| {
        log("AIL_set_sample_address: failed: {any}\n", .{err});
    };
}
pub export fn AIL_set_sample_type(s_opt: ?*Sample, format: u32, flags: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_type(s={*}, format={d}, flags={d})\n", .{ s, format, flags });
    s.setType(format, flags);
}
pub export fn AIL_start_sample(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_start_sample(s={*})\n", .{s});
    s.start();
}
pub export fn AIL_stop_sample(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_stop_sample(s={*})\n", .{s});
    s.stop();
}
pub export fn AIL_pause_sample(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_pause_sample(s={*})\n", .{s});
    s.pause();
}
pub export fn AIL_resume_sample(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_resume_sample(s={*})\n", .{s});
    s.resumePlayback();
}
pub export fn AIL_end_sample(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_end_sample(s={*})\n", .{s});
    s.end();
}
pub export fn AIL_sample_status(s_opt: ?*Sample) callconv(.winapi) u32 {
    const s = s_opt orelse return 0;
    return @intFromEnum(s.status());
}
pub export fn AIL_set_sample_volume(s_opt: ?*Sample, volume: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_volume(s={*}, volume={d})\n", .{ s, volume });
    s.setVolume(volume);
}
pub export fn AIL_set_sample_pan(s_opt: ?*Sample, pan: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_pan(s={*}, pan={d})\n", .{ s, pan });
    s.setPan(pan);
}
pub export fn AIL_set_sample_playback_rate(s_opt: ?*Sample, rate: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_playback_rate(s={*}, rate={d})\n", .{ s, rate });
    s.setPlaybackRate(rate);
}
pub export fn AIL_set_sample_loop_count(s_opt: ?*Sample, count: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_loop_count(s={*}, count={d})\n", .{ s, count });
    s.setLoopCount(count);
}
pub export fn AIL_sample_user_data(s_opt: ?*Sample, index: i32) callconv(.winapi) u32 {
    const s = s_opt orelse return 0;
    const idx: usize = @intCast(@min(@max(index, 0), 7));
    return s.user_data[idx];
}
pub export fn AIL_set_sample_user_data(s_opt: ?*Sample, index: i32, value: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    const idx: usize = @intCast(@min(@max(index, 0), 7));
    s.user_data[idx] = value;
}
pub export fn AIL_sample_reverb(s_opt: ?*Sample, room_type: ?*f32, level: ?*f32, reflect_time: ?*f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    const rev = s.getReverb();
    if (room_type) |p| p.* = rev.room_type;
    if (level) |p| p.* = rev.level;
    if (reflect_time) |p| p.* = rev.reflect_time;
}
pub export fn AIL_set_sample_reverb(s_opt: ?*Sample, room_type: f32, level: f32, reflect_time: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setReverb(room_type, level, reflect_time);
}
pub export fn AIL_set_sample_loop_block(s_opt: ?*Sample, loop_start: i32, loop_end: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setLoopBlock(loop_start, loop_end);
}
pub export fn AIL_set_sample_adpcm_block_size(s_opt: ?*Sample, block_size: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.adpcm_block_size = block_size;
}
pub export fn AIL_sample_granularity(driver_opt: ?*DigitalDriver) callconv(.winapi) u32 {
    const driver = driver_opt orelse return 0;
    _ = driver;
    return 512;
}
pub export fn AIL_minimum_sample_buffer_size(driver_opt: ?*DigitalDriver, rate: i32, format: i32) callconv(.winapi) u32 {
    const driver = driver_opt orelse return 0;
    _ = driver;
    _ = rate;
    _ = format;
    return 2048;
}
pub export fn AIL_allocate_file_sample(driver_opt: ?*DigitalDriver, data: *anyopaque, flags: u32) callconv(.winapi) ?*Sample {
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
pub export fn AIL_load_sample_buffer(s_opt: ?*Sample, buff_num: u32, data: *anyopaque, len: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    const buffer_id: i32 = @intCast(buff_num);
    s.last_loaded_buffer = buffer_id;
    if (s.pcm_format != null) {
        // Raw PCM + a known format = MSS double-buffer streaming. Feed the buffer
        // into the ping-pong stream source (zero-copy; the app owns it until EOB).
        s.loadStreamBuffer(@intCast(buff_num), data, len) catch |err| {
            openmiles.log("AIL_load_sample_buffer: stream feed failed: {any}\n", .{err});
            return;
        };
    } else {
        // No format hint: treat as a complete encoded file image (whole-buffer).
        s.load(data, @intCast(@min(len, @as(u32, std.math.maxInt(i32))))) catch return;
    }
    // Fire SOB (Start Of Buffer) callback now that a new buffer is accepted.
    // Signature: void callback(HSAMPLE S, S32 buff_num, U32 buff_size, void const *buff_addr)
    if (s.sob_callback != 0) {
        const cb: *const fn (?*anyopaque, i32, u32, ?*anyopaque) callconv(.winapi) void = @ptrFromInt(s.sob_callback);
        cb(@ptrCast(s), buffer_id, len, data);
    }
}
pub export fn AIL_sample_buffer_ready(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    // Streaming: return the index (0/1) of a free buffer slot, or -1 if both full.
    if (s.stream_active) return s.streamBufferReady();
    // Non-streaming whole-buffer samples: "ready" once finished or not yet started.
    if (s.is_done or !s.is_initialized) return 0;
    if (openmiles.ma.ma_sound_at_end(&s.sound) != 0) return 0;
    return -1;
}
pub export fn AIL_sample_buffer_info(s_opt: ?*Sample, pos0: *u32, len0: *u32, pos1: *u32, len1: *u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    if (s.stream_active) {
        s.stream_src.bufferInfo(pos0, len0, pos1, len1);
        return;
    }
    // Non-streaming: report the single owned buffer as slot 0.
    if (s.owned_buffer) |buf| {
        pos0.* = 0;
        len0.* = @intCast(buf.len);
    } else {
        pos0.* = 0;
        len0.* = 0;
    }
    pos1.* = 0;
    len1.* = 0;
}
pub export fn AIL_register_EOB_callback(s_opt: ?*Sample, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(s.eob_callback);
    s.eob_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_register_SOB_callback(s_opt: ?*Sample, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(s.sob_callback);
    s.sob_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_set_sample_processor(s_opt: ?*Sample, stage: i32, processor: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    const idx: usize = @intCast(@min(@max(stage, 0), 1));
    const prev: ?*anyopaque = @ptrFromInt(s.sample_processors[idx]);
    s.sample_processors[idx] = if (processor) |p| @intFromPtr(p) else 0;
    return prev;
}
// AIL_primary_digital_driver(HDIGDRIVER new_primary) -> HDIGDRIVER
// Passing a driver makes it the primary; null queries the current primary.
pub export fn AIL_primary_digital_driver(new_primary: ?*DigitalDriver) callconv(.winapi) ?*DigitalDriver {
    if (new_primary) |d| openmiles.last_digital_driver = d;
    return openmiles.last_digital_driver;
}
pub export fn AIL_digital_CPU_percent(driver_opt: ?*DigitalDriver) callconv(.winapi) f32 {
    const driver = driver_opt orelse return 0.0;
    // Estimate CPU load from the ratio of active sounds to a nominal budget.
    // miniaudio doesn't expose CPU usage directly; this approximation is
    // sufficient for games that throttle sound spawning based on this value.
    const active: f32 = @floatFromInt(driver.getActiveSampleCount() + driver.get3DActiveSampleCount());
    const nominal_budget: f32 = 32.0;
    const pct = (active / nominal_budget) * 100.0;
    return @min(pct, 100.0);
}
pub export fn AIL_digital_latency(driver_opt: ?*DigitalDriver) callconv(.winapi) u32 {
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
pub export fn AIL_digital_configuration(driver_opt: ?*DigitalDriver, rate: ?*i32, channels: ?*i32, bits: ?*i32, flags: ?*u32) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    if (rate) |p| p.* = @intCast(driver.getSampleRate());
    if (channels) |p| p.* = @intCast(driver.getChannels());
    if (bits) |p| p.* = 16; // MSS convention: report 16-bit to match legacy expectations
    if (flags) |p| p.* = 0;
}
pub export fn AIL_get_DirectSound_info(driver_opt: ?*DigitalDriver, info: *anyopaque, size: u32) callconv(.winapi) i32 {
    const driver = driver_opt orelse return 0;
    _ = driver;
    _ = info;
    _ = size;
    return 0;
}
pub export fn AIL_set_DirectSound_HWND(driver_opt: ?*DigitalDriver, hwnd: *anyopaque) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    _ = driver;
    _ = hwnd;
}
pub export fn AIL_set_digital_driver_processor(driver_opt: ?*DigitalDriver, stage: i32, processor: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const driver = driver_opt orelse return null;
    const idx: usize = @intCast(@min(@max(stage, 0), 1));
    const prev: ?*anyopaque = @ptrFromInt(driver.driver_processors[idx]);
    driver.driver_processors[idx] = if (processor) |p| @intFromPtr(p) else 0;
    return prev;
}
pub export fn AIL_process_digital_audio(driver_opt: ?*DigitalDriver, dest: ?*anyopaque, count: u32, mono_dest: ?*anyopaque, mono_count: u32, flags: u32) callconv(.winapi) i32 {
    const driver = driver_opt orelse return 0;
    _ = flags;
    driver.enableCapture();
    if (dest) |d| {
        const bytes = driver.readCaptured(@ptrCast(@alignCast(d)), @as(usize, count));
        if (bytes == 0) return 0;
    }
    // Mono down-mix: average L+R if both buffers provided
    if (mono_dest) |md| {
        if (dest) |d| {
            const channels = openmiles.ma.ma_engine_get_channels(&driver.engine);
            if (channels >= 2) {
                const stereo: [*]const i16 = @ptrCast(@alignCast(d));
                const mono: [*]i16 = @ptrCast(@alignCast(md));
                const frames = @min(count / 4, mono_count / 2);
                for (0..frames) |i| {
                    const l: i32 = stereo[i * 2];
                    const r: i32 = stereo[i * 2 + 1];
                    mono[i] = @intCast(@divTrunc(l + r, 2));
                }
            }
        }
    }
    return 1;
}
pub export fn AIL_size_processed_digital_audio(driver_opt: ?*DigitalDriver, rate: i32, format: i32, data: *anyopaque, len: u32) callconv(.winapi) u32 {
    const driver = driver_opt orelse return 0;
    _ = driver;
    _ = data;
    const bytes_per_sample: u32 = switch (@as(u32, @intCast(format))) {
        0, 2 => 1, // 8-bit
        else => 2, // 16-bit
    };
    const channels: u32 = if (format >= 2) 2 else 1;
    return @intCast(@as(u64, len) * 1000 / (@as(u64, @intCast(rate)) * bytes_per_sample * channels));
}
pub export fn AIL_ms_count() callconv(.winapi) u32 {
    return openmiles.getMsCount();
}
pub export fn AIL_us_count() callconv(.winapi) u32 {
    return openmiles.getUsCount();
}
pub export fn AIL_delay(ms: u32) callconv(.winapi) void {
    const duration = std.Io.Duration.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms);
    openmiles.io.sleep(duration, .awake) catch {};
}
pub export fn AIL_lock() callconv(.winapi) void {}
pub export fn AIL_unlock() callconv(.winapi) void {}
pub export fn AIL_lock_mutex() callconv(.winapi) void {}
pub export fn AIL_unlock_mutex() callconv(.winapi) void {}
pub export fn AIL_background() callconv(.winapi) ?*anyopaque {
    return null;
}
pub export fn AIL_MMX_available() callconv(.winapi) i32 {
    return 0;
}
pub export fn AIL_HWND() callconv(.winapi) ?*anyopaque {
    return null;
}
pub export fn AIL_set_error(msg: [*:0]const u8) callconv(.winapi) void {
    openmiles.setLastError(std.mem.span(msg));
}
// AIL_debug_printf and AIL_sprintf are implemented in C (src/bindings/c_impl.c)
// to avoid Zig stage2_llvm miscompilation of C varargs on Windows.

pub export fn AIL_WAV_info(data: *anyopaque, info: *anyopaque) callconv(.winapi) i32 {
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
        } else if (std.mem.eql(u8, tag, "data")) {
            data_ptr = raw + offset;
            data_len = chunk_size;
            break;
        }
        const next = offset +| chunk_size +| (chunk_size & 1); // pad to even (saturating)
        if (next <= offset) break; // guard against zero/wraparound
        offset = next;
    }
    if (data_ptr == null) return 0;
    // For PCM (format 1): bytes_per_frame = channels * (bits/8)
    // For ADPCM (format 2) and others: block_align from fmt chunk is used
    // Note: out.samples is left 0 for non-PCM formats (ADPCM etc.) because per-sample counting requires decompression.
    const fmt: i32 = switch (num_channels) {
        1 => if (bits_per_sample <= 8) 0 else 1,
        else => if (bits_per_sample <= 8) 2 else 3,
    };
    const bytes_per_frame: u32 = if (audio_format == 1 and bits_per_sample > 0)
        @as(u32, num_channels) * (@as(u32, bits_per_sample) / 8)
    else
        @as(u32, block_align);
    out.format = fmt;
    out.data_ptr = data_ptr;
    out.data_len = data_len;
    out.rate = sample_rate;
    out.bits = bits_per_sample;
    out.channels = num_channels;
    out.samples = if (bytes_per_frame > 0 and audio_format == 1) data_len / bytes_per_frame else 0;
    out.block_size = block_align;
    // initial_ptr: set to data_ptr for compressed formats (no separate codec header in our implementation)
    out.initial_ptr = if (audio_format != 1) data_ptr else null;
    return 1;
}
pub export fn AIL_WAV_file_write(filename: [*:0]const u8, data: *anyopaque, len: u32, rate: i32, bits: i32) callconv(.winapi) i32 {
    const pcm_data: []const u8 = @as([*]const u8, @ptrCast(@alignCast(data)))[0..len];
    const wav = openmiles.buildWavFromPcm(openmiles.global_allocator, pcm_data, 1, @intCast(rate), @intCast(bits)) catch |err| {
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
pub export fn AIL_compress_ADPCM(info: *const AILSOUNDINFO, outdata: **anyopaque, outsize: *u32) callconv(.winapi) i32 {
    if (info.data_ptr == null or info.data_len == 0) return 0;
    if (info.bits != 16) return 0; // IMA ADPCM only encodes from 16-bit PCM
    const channels: u16 = @intCast(@max(1, @min(2, info.channels)));
    const pcm: [*]const i16 = @ptrCast(@alignCast(info.data_ptr.?));
    const total_per_ch: usize = @as(usize, info.data_len) / (@as(usize, channels) * 2);
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
pub export fn AIL_decompress_ADPCM(info: *const AILSOUNDINFO, outdata: **anyopaque, outsize: *u32) callconv(.winapi) i32 {
    if (info.data_ptr == null or info.data_len == 0) return 0;
    const raw: []const u8 = @as([*]const u8, @ptrCast(@alignCast(info.data_ptr.?)))[0..info.data_len];
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
        pcm.ensureTotalCapacity(openmiles.global_allocator, @intCast(length_frames * bpf)) catch {};
    }

    var chunk_buf: [4096 * 8]u8 = undefined; // up to 4096 frames × 8 bytes (4ch 16-bit)
    const chunk_frames: u64 = chunk_buf.len / @as(usize, bpf);
    while (true) {
        var fr: u64 = 0;
        _ = openmiles.ma.ma_decoder_read_pcm_frames(&decoder, &chunk_buf, chunk_frames, &fr);
        if (fr == 0) break;
        pcm.appendSlice(openmiles.global_allocator, chunk_buf[0..@intCast(fr * @as(u64, bpf))]) catch break;
    }
    if (pcm.items.len == 0) return 0;

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
pub export fn AIL_create_wave_synthesizer(dig_opt: ?*DigitalDriver, seq: ?*Sequence, dls: ?*anyopaque, flags: u32) callconv(.winapi) ?*MidiDriver {
    const dig = dig_opt orelse return null;
    _ = dig;
    _ = seq;
    _ = flags;
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
pub export fn AIL_destroy_wave_synthesizer(synth: *MidiDriver) callconv(.winapi) void {
    if (openmiles.last_midi_driver == synth) openmiles.last_midi_driver = null;
    synth.deinit();
}
pub export fn AIL_waveOutClose(driver_opt: ?*DigitalDriver) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    if (openmiles.last_digital_driver == driver) openmiles.last_digital_driver = null;
    driver.deinit();
}
pub export fn DllMain(hinstDLL: *anyopaque, fdwReason: u32, lpvReserved: ?*anyopaque) callconv(.winapi) i32 {
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
        };
        const targets = [_]Target{
            .{ .name = "AIL_startup", .stack_size = 0 },
            .{ .name = "AIL_shutdown", .stack_size = 0 },
            .{ .name = "AIL_set_redist_directory", .stack_size = 4 },
            .{ .name = "AIL_last_error", .stack_size = 0 },
            .{ .name = "AIL_get_preference", .stack_size = 4 },
            .{ .name = "AIL_set_preference", .stack_size = 8 },
            .{ .name = "AIL_open_midi_driver", .stack_size = 4 },
            .{ .name = "AIL_close_midi_driver", .stack_size = 4 },
            .{ .name = "AIL_open_XMIDI_driver", .stack_size = 4 },
            .{ .name = "AIL_close_XMIDI_driver", .stack_size = 4 },
            .{ .name = "AIL_allocate_sequence_handle", .stack_size = 4 },
            .{ .name = "AIL_release_sequence_handle", .stack_size = 4 },
            .{ .name = "AIL_init_sequence", .stack_size = 12 },
            .{ .name = "AIL_start_sequence", .stack_size = 4 },
            .{ .name = "AIL_stop_sequence", .stack_size = 4 },
            .{ .name = "AIL_pause_sequence", .stack_size = 4 },
            .{ .name = "AIL_resume_sequence", .stack_size = 4 },
            .{ .name = "AIL_sequence_status", .stack_size = 4 },
            .{ .name = "AIL_set_sequence_volume", .stack_size = 12 },
            .{ .name = "AIL_set_sequence_loop_count", .stack_size = 8 },
            .{ .name = "AIL_branch_index", .stack_size = 8 },
            .{ .name = "AIL_DLS_load_file", .stack_size = 12 },
            .{ .name = "AIL_DLS_unload_file", .stack_size = 8 },
            .{ .name = "AIL_digital_handle_release", .stack_size = 4 },
            .{ .name = "AIL_digital_handle_reacquire", .stack_size = 4 },
            .{ .name = "AIL_waveOutOpen", .stack_size = 16 },
            .{ .name = "AIL_open_digital_driver", .stack_size = 16 },
            .{ .name = "AIL_close_digital_driver", .stack_size = 4 },
            .{ .name = "AIL_serve", .stack_size = 0 },
            .{ .name = "AIL_set_digital_master_volume", .stack_size = 8 },
            .{ .name = "AIL_digital_master_volume", .stack_size = 4 },
            .{ .name = "AIL_allocate_sample_handle", .stack_size = 4 },
            .{ .name = "AIL_release_sample_handle", .stack_size = 4 },
            .{ .name = "AIL_init_sample", .stack_size = 4 },
            .{ .name = "AIL_set_named_sample_file", .stack_size = 20 },
            .{ .name = "AIL_set_sample_file", .stack_size = 12 },
            .{ .name = "AIL_set_sample_address", .stack_size = 12 },
            .{ .name = "AIL_set_sample_type", .stack_size = 12 },
            .{ .name = "AIL_start_sample", .stack_size = 4 },
            .{ .name = "AIL_stop_sample", .stack_size = 4 },
            .{ .name = "AIL_pause_sample", .stack_size = 4 },
            .{ .name = "AIL_resume_sample", .stack_size = 4 },
            .{ .name = "AIL_end_sample", .stack_size = 4 },
            .{ .name = "AIL_sample_status", .stack_size = 4 },
            .{ .name = "AIL_sample_volume", .stack_size = 4 },
            .{ .name = "AIL_sample_pan", .stack_size = 4 },
            .{ .name = "AIL_sample_playback_rate", .stack_size = 4 },
            .{ .name = "AIL_set_sample_volume", .stack_size = 8 },
            .{ .name = "AIL_set_sample_pan", .stack_size = 8 },
            .{ .name = "AIL_set_sample_playback_rate", .stack_size = 8 },
            .{ .name = "AIL_set_sample_volume_pan", .stack_size = 12 },
            .{ .name = "AIL_set_sample_loop_count", .stack_size = 8 },
            .{ .name = "AIL_active_sample_count", .stack_size = 4 },
            .{ .name = "AIL_sample_ms_position", .stack_size = 12 },
            .{ .name = "AIL_set_sample_ms_position", .stack_size = 8 },
            .{ .name = "AIL_sample_position", .stack_size = 4 },
            .{ .name = "AIL_set_sample_position", .stack_size = 8 },
            .{ .name = "AIL_sample_loop_count", .stack_size = 4 },
            .{ .name = "AIL_register_EOS_callback", .stack_size = 8 },
            .{ .name = "AIL_open_stream", .stack_size = 12 },
            .{ .name = "AIL_close_stream", .stack_size = 4 },
            .{ .name = "AIL_start_stream", .stack_size = 4 },
            .{ .name = "AIL_pause_stream", .stack_size = 8 },
            .{ .name = "AIL_set_stream_volume", .stack_size = 8 },
            .{ .name = "AIL_set_stream_loop_count", .stack_size = 8 },
            .{ .name = "AIL_register_stream_callback", .stack_size = 8 },
            .{ .name = "AIL_auto_service_stream", .stack_size = 8 },
            .{ .name = "AIL_set_stream_playback_rate", .stack_size = 8 },
            .{ .name = "AIL_set_stream_pan", .stack_size = 8 },
            .{ .name = "AIL_set_stream_ms_position", .stack_size = 8 },
            .{ .name = "AIL_stream_status", .stack_size = 4 },
            .{ .name = "AIL_stream_playback_rate", .stack_size = 4 },
            .{ .name = "AIL_stream_volume", .stack_size = 4 },
            .{ .name = "AIL_stream_pan", .stack_size = 4 },
            .{ .name = "AIL_stream_loop_count", .stack_size = 4 },
            .{ .name = "AIL_stream_ms_position", .stack_size = 12 },
            .{ .name = "RIB_alloc_provider_handle", .stack_size = 4, .ver = 40 },
            .{ .name = "RIB_free_provider_handle", .stack_size = 4, .ver = 40 },
            .{ .name = "RIB_register_interface", .stack_size = 16, .ver = 40 },
            .{ .name = "RIB_unregister_interface", .stack_size = 16, .ver = 40 },
            .{ .name = "RIB_provider_library_handle", .stack_size = 0, .ver = 40 },
            .{ .name = "RIB_load_application_providers", .stack_size = 4, .ver = 40 },
            .{ .name = "RIB_enumerate_providers", .stack_size = 12, .ver = 40 },
            .{ .name = "RIB_request_interface", .stack_size = 16, .ver = 40 },
            .{ .name = "RIB_find_files_provider", .stack_size = 20, .ver = 40 },
            .{ .name = "AIL_open_filter", .stack_size = 8, .ver = 60 },
            .{ .name = "AIL_close_filter", .stack_size = 4, .ver = 60 },
            .{ .name = "AIL_set_sample_filter", .stack_size = 12, .ver = 60 },
            .{ .name = "AIL_filter_attribute", .stack_size = 12, .ver = 60 },
            .{ .name = "AIL_set_filter_attribute", .stack_size = 12, .ver = 60 },
            .{ .name = "AIL_enumerate_filters", .stack_size = 12, .ver = 60 },
            .{ .name = "AIL_enumerate_3D_providers", .stack_size = 12, .ver = 50 },
            .{ .name = "AIL_allocate_3D_sample_handle", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_release_3D_sample_handle", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_set_3D_sample_file", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_set_3D_position", .stack_size = 16, .ver = 50 },
            .{ .name = "AIL_set_3D_velocity", .stack_size = 20, .ver = 50 },
            .{ .name = "AIL_set_3D_orientation", .stack_size = 28, .ver = 50 },
            .{ .name = "AIL_set_3D_sample_distances", .stack_size = 12, .ver = 50 },
            .{ .name = "AIL_set_listener_3D_position", .stack_size = 16, .ver = 50 },
            .{ .name = "AIL_set_listener_3D_velocity", .stack_size = 20, .ver = 50 },
            .{ .name = "AIL_set_listener_3D_orientation", .stack_size = 28, .ver = 50 },
            .{ .name = "AIL_register_timer", .stack_size = 4 },
            .{ .name = "AIL_set_timer_frequency", .stack_size = 8 },
            .{ .name = "AIL_set_timer_period", .stack_size = 8 },
            .{ .name = "AIL_set_timer_user_data", .stack_size = 8 },
            .{ .name = "AIL_start_timer", .stack_size = 4 },
            .{ .name = "AIL_stop_timer", .stack_size = 4 },
            .{ .name = "AIL_release_timer_handle", .stack_size = 4 },
            .{ .name = "AIL_start_all_timers", .stack_size = 0 },
            .{ .name = "AIL_stop_all_timers", .stack_size = 0 },
            .{ .name = "AIL_quick_startup", .stack_size = 20, .ver = 40 },
            .{ .name = "AIL_quick_shutdown", .stack_size = 0, .ver = 40 },
            .{ .name = "AIL_quick_load", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_quick_load_mem", .stack_size = 8, .ver = 40 },
            .{ .name = "AIL_quick_copy", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_quick_unload", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_quick_play", .stack_size = 8, .ver = 40 },
            .{ .name = "AIL_quick_stop", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_quick_status", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_quick_set_volume", .stack_size = 8, .ver = 40 },
            .{ .name = "AIL_quick_set_speed", .stack_size = 8, .ver = 40 },
            .{ .name = "AIL_quick_ms_length", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_quick_ms_position", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_quick_set_ms_position", .stack_size = 8, .ver = 40 },
            .{ .name = "AIL_redbook_open", .stack_size = 4 },
            .{ .name = "AIL_redbook_close", .stack_size = 4 },
            .{ .name = "AIL_redbook_play", .stack_size = 12 },
            .{ .name = "AIL_redbook_stop", .stack_size = 4 },
            .{ .name = "AIL_redbook_pause", .stack_size = 4 },
            .{ .name = "AIL_redbook_resume", .stack_size = 4 },
            .{ .name = "AIL_redbook_status", .stack_size = 4 },
            .{ .name = "AIL_redbook_tracks", .stack_size = 4 },
            .{ .name = "AIL_open_ASI_provider", .stack_size = 8, .ver = 40 },
            .{ .name = "AIL_close_ASI_provider", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_ASI_provider_attribute", .stack_size = 8, .ver = 40 },
            .{ .name = "AIL_compress_ASI", .stack_size = 16, .ver = 40 },
            .{ .name = "AIL_decompress_ASI", .stack_size = 16, .ver = 40 },
            .{ .name = "AIL_mem_alloc_lock", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_mem_free_lock", .stack_size = 4, .ver = 40 },
            // 3D Sample control
            .{ .name = "AIL_start_3D_sample", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_stop_3D_sample", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_resume_3D_sample", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_end_3D_sample", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_3D_sample_status", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_3D_sample_volume", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_set_3D_sample_volume", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_3D_sample_loop_count", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_set_3D_sample_loop_count", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_3D_sample_playback_rate", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_set_3D_sample_playback_rate", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_3D_sample_offset", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_set_3D_sample_offset", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_3D_sample_length", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_3D_sample_ms_position", .stack_size = 12, .ver = 50 },
            .{ .name = "AIL_set_3D_sample_ms_position", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_register_3D_EOS_callback", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_active_3D_sample_count", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_3D_user_data", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_set_3D_user_data", .stack_size = 12, .ver = 50 },
            .{ .name = "AIL_set_3D_sample_info", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_set_3D_sample_loop_block", .stack_size = 12, .ver = 50 },
            .{ .name = "AIL_set_3D_sample_cone", .stack_size = 16, .ver = 50 },
            .{ .name = "AIL_3D_sample_cone", .stack_size = 16, .ver = 50 },
            .{ .name = "AIL_set_3D_sample_effects_level", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_3D_sample_effects_level", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_set_3D_sample_obstruction", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_3D_sample_obstruction", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_set_3D_sample_occlusion", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_3D_sample_occlusion", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_set_3D_sample_preference", .stack_size = 12, .ver = 50 },
            .{ .name = "AIL_3D_sample_attribute", .stack_size = 12, .ver = 50 },
            .{ .name = "AIL_auto_update_3D_position", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_update_3D_position", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_set_3D_velocity_vector", .stack_size = 16, .ver = 50 },
            // 3D Environment
            .{ .name = "AIL_set_3D_distance_factor", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_3D_distance_factor", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_set_3D_doppler_factor", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_3D_doppler_factor", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_set_3D_rolloff_factor", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_3D_rolloff_factor", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_set_3D_room_type", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_3D_room_type", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_set_3D_speaker_type", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_3D_speaker_type", .stack_size = 4, .ver = 50 },
            // 3D Provider/Listener/Object
            .{ .name = "AIL_open_3D_provider", .stack_size = 8, .ver = 50 },
            .{ .name = "AIL_close_3D_provider", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_open_3D_listener", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_close_3D_listener", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_open_3D_object", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_close_3D_object", .stack_size = 4, .ver = 50 },
            .{ .name = "AIL_3D_provider_attribute", .stack_size = 12, .ver = 50 },
            .{ .name = "AIL_set_3D_provider_preference", .stack_size = 12, .ver = 50 },
            .{ .name = "AIL_enumerate_3D_provider_attributes", .stack_size = 12, .ver = 50 },
            .{ .name = "AIL_enumerate_3D_sample_attributes", .stack_size = 12, .ver = 50 },
            .{ .name = "AIL_3D_orientation", .stack_size = 28, .ver = 50 },
            .{ .name = "AIL_3D_position", .stack_size = 16, .ver = 50 },
            .{ .name = "AIL_3D_velocity", .stack_size = 16, .ver = 50 },
            .{ .name = "AIL_3D_sample_distances", .stack_size = 12, .ver = 50 },
            // Sequence extras
            .{ .name = "AIL_sequence_ms_position", .stack_size = 12 },
            .{ .name = "AIL_set_sequence_ms_position", .stack_size = 8 },
            .{ .name = "AIL_sequence_loop_count", .stack_size = 4 },
            .{ .name = "AIL_sequence_volume", .stack_size = 4 },
            .{ .name = "AIL_sequence_tempo", .stack_size = 4 },
            .{ .name = "AIL_set_sequence_tempo", .stack_size = 12 },
            .{ .name = "AIL_active_sequence_count", .stack_size = 4 },
            .{ .name = "AIL_sequence_position", .stack_size = 12 },
            .{ .name = "AIL_sequence_user_data", .stack_size = 8 },
            .{ .name = "AIL_set_sequence_user_data", .stack_size = 12 },
            .{ .name = "AIL_end_sequence", .stack_size = 4 },
            .{ .name = "AIL_channel_notes", .stack_size = 8 },
            .{ .name = "AIL_true_sequence_channel", .stack_size = 8 },
            .{ .name = "AIL_map_sequence_channel", .stack_size = 12 },
            .{ .name = "AIL_controller_value", .stack_size = 12 },
            .{ .name = "AIL_send_channel_voice_message", .stack_size = 20 },
            .{ .name = "AIL_send_sysex_message", .stack_size = 8 },
            .{ .name = "AIL_lock_channel", .stack_size = 4 },
            .{ .name = "AIL_release_channel", .stack_size = 8 },
            .{ .name = "AIL_register_beat_callback", .stack_size = 8 },
            .{ .name = "AIL_register_event_callback", .stack_size = 8 },
            .{ .name = "AIL_register_prefix_callback", .stack_size = 8 },
            .{ .name = "AIL_register_trigger_callback", .stack_size = 8 },
            .{ .name = "AIL_register_sequence_callback", .stack_size = 8 },
            .{ .name = "AIL_register_timbre_callback", .stack_size = 8 },
            .{ .name = "AIL_register_ICA_array", .stack_size = 8 },
            .{ .name = "AIL_XMIDI_master_volume", .stack_size = 4 },
            .{ .name = "AIL_set_XMIDI_master_volume", .stack_size = 8 },
            .{ .name = "AIL_midiOutClose", .stack_size = 4 },
            .{ .name = "AIL_midiOutOpen", .stack_size = 12 },
            .{ .name = "AIL_MIDI_handle_release", .stack_size = 4 },
            .{ .name = "AIL_MIDI_handle_reacquire", .stack_size = 4 },
            .{ .name = "AIL_MIDI_to_XMI", .stack_size = 20 },
            // Sample extras
            .{ .name = "AIL_sample_user_data", .stack_size = 8 },
            .{ .name = "AIL_set_sample_user_data", .stack_size = 12 },
            .{ .name = "AIL_sample_reverb", .stack_size = 16 },
            .{ .name = "AIL_set_sample_reverb", .stack_size = 16 },
            .{ .name = "AIL_set_sample_loop_block", .stack_size = 12 },
            .{ .name = "AIL_set_sample_adpcm_block_size", .stack_size = 8 },
            .{ .name = "AIL_sample_granularity", .stack_size = 4 },
            .{ .name = "AIL_minimum_sample_buffer_size", .stack_size = 12 },
            .{ .name = "AIL_allocate_file_sample", .stack_size = 12 },
            .{ .name = "AIL_load_sample_buffer", .stack_size = 16 },
            .{ .name = "AIL_sample_buffer_ready", .stack_size = 4 },
            .{ .name = "AIL_sample_buffer_info", .stack_size = 20 },
            .{ .name = "AIL_register_EOB_callback", .stack_size = 8 },
            .{ .name = "AIL_register_SOB_callback", .stack_size = 8 },
            .{ .name = "AIL_set_sample_processor", .stack_size = 12 },
            // Stream extras
            .{ .name = "AIL_stream_position", .stack_size = 4 },
            .{ .name = "AIL_set_stream_position", .stack_size = 8 },
            .{ .name = "AIL_stream_user_data", .stack_size = 8 },
            .{ .name = "AIL_set_stream_user_data", .stack_size = 12 },
            .{ .name = "AIL_stream_reverb", .stack_size = 16 },
            .{ .name = "AIL_set_stream_reverb", .stack_size = 16 },
            .{ .name = "AIL_stream_info", .stack_size = 24 },
            .{ .name = "AIL_set_stream_loop_block", .stack_size = 12 },
            .{ .name = "AIL_service_stream", .stack_size = 8 },
            .{ .name = "AIL_register_EOF_callback", .stack_size = 8 },
            .{ .name = "AIL_set_stream_processor", .stack_size = 12 },
            .{ .name = "AIL_filter_stream_attribute", .stack_size = 12 },
            .{ .name = "AIL_set_filter_stream_preference", .stack_size = 12 },
            // Filter extras
            .{ .name = "AIL_enumerate_filter_attributes", .stack_size = 12, .ver = 60 },
            .{ .name = "AIL_enumerate_filter_sample_attributes", .stack_size = 12, .ver = 60 },
            .{ .name = "AIL_filter_sample_attribute", .stack_size = 12, .ver = 60 },
            .{ .name = "AIL_set_filter_sample_preference", .stack_size = 12, .ver = 60 },
            .{ .name = "AIL_set_filter_DLS_preference", .stack_size = 12 },
            .{ .name = "AIL_set_filter_preference", .stack_size = 12, .ver = 60 },
            .{ .name = "AIL_filter_DLS_attribute", .stack_size = 12 },
            .{ .name = "AIL_filter_DLS_with_XMI", .stack_size = 24 },
            // Quick API extras
            .{ .name = "AIL_quick_halt", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_quick_set_reverb", .stack_size = 16, .ver = 40 },
            .{ .name = "AIL_quick_load_and_play", .stack_size = 12, .ver = 40 },
            .{ .name = "AIL_quick_type", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_quick_handles", .stack_size = 12, .ver = 40 },
            // DLS extras
            .{ .name = "AIL_DLS_load_memory", .stack_size = 12 },
            .{ .name = "AIL_DLS_unload", .stack_size = 8 },
            .{ .name = "AIL_DLS_compact", .stack_size = 4 },
            .{ .name = "AIL_DLS_get_info", .stack_size = 12 },
            .{ .name = "AIL_DLS_get_reverb", .stack_size = 16 },
            .{ .name = "AIL_DLS_set_reverb", .stack_size = 16 },
            .{ .name = "AIL_DLS_open", .stack_size = 28 },
            .{ .name = "AIL_DLS_close", .stack_size = 8 },
            // Redbook extras
            .{ .name = "AIL_redbook_eject", .stack_size = 4 },
            .{ .name = "AIL_redbook_retract", .stack_size = 4 },
            .{ .name = "AIL_redbook_id", .stack_size = 4 },
            .{ .name = "AIL_redbook_open_drive", .stack_size = 4 },
            .{ .name = "AIL_redbook_position", .stack_size = 4 },
            .{ .name = "AIL_redbook_track", .stack_size = 4 },
            .{ .name = "AIL_redbook_track_info", .stack_size = 16 },
            .{ .name = "AIL_redbook_set_volume", .stack_size = 8 },
            .{ .name = "AIL_redbook_volume", .stack_size = 4 },
            // RIB extras
            .{ .name = "RIB_error", .stack_size = 0, .ver = 40 },
            .{ .name = "RIB_find_file_provider", .stack_size = 12, .ver = 40 },
            .{ .name = "RIB_load_provider_library", .stack_size = 4, .ver = 40 },
            .{ .name = "RIB_free_provider_library", .stack_size = 4, .ver = 40 },
            .{ .name = "RIB_request_interface_entry", .stack_size = 16, .ver = 40 },
            .{ .name = "RIB_enumerate_interface", .stack_size = 20, .ver = 40 },
            .{ .name = "RIB_type_string", .stack_size = 4, .ver = 40 },
            .{ .name = "RIB_provider_system_data", .stack_size = 8, .ver = 40 },
            .{ .name = "RIB_provider_user_data", .stack_size = 8, .ver = 40 },
            .{ .name = "RIB_set_provider_system_data", .stack_size = 12, .ver = 40 },
            .{ .name = "RIB_set_provider_user_data", .stack_size = 12, .ver = 40 },
            .{ .name = "RIB_find_file_dec_provider", .stack_size = 20, .ver = 40 },
            .{ .name = "RIB_find_provider", .stack_size = 12, .ver = 40 },
            // Digital driver extras
            .{ .name = "AIL_primary_digital_driver", .stack_size = 4 },
            .{ .name = "AIL_digital_CPU_percent", .stack_size = 4 },
            .{ .name = "AIL_digital_latency", .stack_size = 4 },
            .{ .name = "AIL_digital_configuration", .stack_size = 20 },
            .{ .name = "AIL_get_DirectSound_info", .stack_size = 12 },
            .{ .name = "AIL_set_DirectSound_HWND", .stack_size = 8 },
            .{ .name = "AIL_set_digital_driver_processor", .stack_size = 12 },
            .{ .name = "AIL_process_digital_audio", .stack_size = 24 },
            .{ .name = "AIL_size_processed_digital_audio", .stack_size = 20 },
            // Utility
            .{ .name = "AIL_ms_count", .stack_size = 0 },
            .{ .name = "AIL_us_count", .stack_size = 0 },
            .{ .name = "AIL_delay", .stack_size = 4 },
            .{ .name = "AIL_lock", .stack_size = 0 },
            .{ .name = "AIL_unlock", .stack_size = 0 },
            .{ .name = "AIL_lock_mutex", .stack_size = 0 },
            .{ .name = "AIL_unlock_mutex", .stack_size = 0 },
            .{ .name = "AIL_background", .stack_size = 0 },
            .{ .name = "AIL_MMX_available", .stack_size = 0 },
            .{ .name = "AIL_HWND", .stack_size = 0 },
            .{ .name = "AIL_set_error", .stack_size = 4 },
            .{ .name = "AIL_get_timer_highest_delay", .stack_size = 0 },
            .{ .name = "AIL_set_timer_divisor", .stack_size = 8 },
            .{ .name = "AIL_set_timer_user", .stack_size = 8 },
            .{ .name = "AIL_release_all_timers", .stack_size = 0 },
            .{ .name = "AIL_file_error", .stack_size = 0 },
            .{ .name = "AIL_file_read", .stack_size = 8 },
            .{ .name = "AIL_file_size", .stack_size = 4 },
            .{ .name = "AIL_file_type", .stack_size = 8 },
            .{ .name = "AIL_file_write", .stack_size = 12 },
            .{ .name = "AIL_WAV_info", .stack_size = 8 },
            .{ .name = "AIL_WAV_file_write", .stack_size = 20 },
            .{ .name = "AIL_mem_use_malloc", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_mem_use_free", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_set_mem_callbacks", .stack_size = 8, .ver = 40 },
            .{ .name = "AIL_compress_ADPCM", .stack_size = 12 },
            .{ .name = "AIL_decompress_ADPCM", .stack_size = 12 },
            .{ .name = "AIL_open_input", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_close_input", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_set_input_state", .stack_size = 8, .ver = 40 },
            .{ .name = "AIL_get_input_info", .stack_size = 4, .ver = 40 },
            .{ .name = "AIL_set_file_callbacks", .stack_size = 16 },
            .{ .name = "AIL_set_file_async_callbacks", .stack_size = 20 },
            .{ .name = "AIL_set_DLS_processor", .stack_size = 12 },
            .{ .name = "AIL_create_wave_synthesizer", .stack_size = 16 },
            .{ .name = "AIL_destroy_wave_synthesizer", .stack_size = 4 },
            .{ .name = "AIL_waveOutClose", .stack_size = 4 },
            .{ .name = "AIL_request_EOB_ASI_reset", .stack_size = 8, .ver = 40 },
            // DLS utilities
            .{ .name = "AIL_compress_DLS", .stack_size = 20 },
            .{ .name = "AIL_extract_DLS", .stack_size = 28 },
            .{ .name = "AIL_find_DLS", .stack_size = 24 },
            .{ .name = "AIL_list_DLS", .stack_size = 20 },
            .{ .name = "AIL_list_MIDI", .stack_size = 20 },
            .{ .name = "AIL_merge_DLS_with_XMI", .stack_size = 16 },
            // Legacy DLS* functions (no AIL_ prefix)
            .{ .name = "DLSClose", .stack_size = 8 },
            .{ .name = "DLSCompactMemory", .stack_size = 4 },
            .{ .name = "DLSGetInfo", .stack_size = 12 },
            .{ .name = "DLSLoadFile", .stack_size = 12 },
            .{ .name = "DLSLoadMemFile", .stack_size = 12 },
            .{ .name = "DLSMSSGetCPU", .stack_size = 4 },
            .{ .name = "DLSMSSOpen", .stack_size = 28 },
            .{ .name = "DLSSetAttribute", .stack_size = 12 },
            .{ .name = "DLSUnloadAll", .stack_size = 4 },
            .{ .name = "DLSUnloadFile", .stack_size = 8 },
            // DLL entry point
            .{ .name = "DllMain", .stack_size = 12 },
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
            .{ .name = "AIL_set_sample_volume_levels", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_sample_volume_levels", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_sample_volume_pan", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_set_sample_low_pass_cut_off", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_sample_low_pass_cut_off", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_set_sample_reverb_levels", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_sample_reverb_levels", .stack_size = 12, .ver = 70 },
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
            .{ .name = "AIL_digital_master_volume_level", .stack_size = 4, .ver = 70 },
            .{ .name = "AIL_set_digital_master_volume_level", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_set_digital_master_reverb", .stack_size = 20, .ver = 70 },
            .{ .name = "AIL_digital_master_reverb", .stack_size = 20, .ver = 70 },
            .{ .name = "AIL_set_digital_master_reverb_levels", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_digital_master_reverb_levels", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_set_room_type", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_room_type", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_redbook_set_volume_level", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_redbook_volume_level", .stack_size = 4, .ver = 70 },
            .{ .name = "AIL_quick_set_low_pass_cut_off", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_quick_set_reverb_levels", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_stream_sample_handle", .stack_size = 4, .ver = 70 },
            .{ .name = "AIL_DLS_sample_handle", .stack_size = 4, .ver = 70 },
            .{ .name = "AIL_find_filter", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_background_CPU_percent", .stack_size = 0, .ver = 70 },
            .{ .name = "AIL_sample_processor", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_digital_driver_processor", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_sample_stage_attribute", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_set_sample_stage_preference", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_enumerate_sample_stage_attributes", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_sample_channel_levels", .stack_size = 20, .ver = 70 },
            .{ .name = "AIL_set_sample_channel_levels", .stack_size = 20, .ver = 70 },
            .{ .name = "AIL_listener_relative_receiver_array", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_set_listener_relative_receiver_array", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_speaker_configuration", .stack_size = 20, .ver = 70 },
            .{ .name = "AIL_set_speaker_configuration", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_speaker_reverb_levels", .stack_size = 16, .ver = 70 },
            .{ .name = "AIL_set_speaker_reverb_levels", .stack_size = 20, .ver = 70 },
            .{ .name = "AIL_calculate_3D_channel_levels", .stack_size = 20, .ver = 70 },
            .{ .name = "AIL_digital_output_filter", .stack_size = 4, .ver = 70 },
            .{ .name = "AIL_output_filter_driver_attribute", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_set_output_filter_driver_preference", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_enumerate_output_filter_driver_attributes", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_enumerate_output_filter_sample_attributes", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_inspect_MP3", .stack_size = 12, .ver = 70 },
            .{ .name = "AIL_enumerate_MP3_frames", .stack_size = 4, .ver = 70 },
            .{ .name = "RIB_load_static_provider_library", .stack_size = 8, .ver = 70 },
            .{ .name = "RIB_MAIN", .stack_size = 8, .ver = 70 },
            .{ .name = "AIL_WAV_marker_by_index", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_WAV_marker_by_name", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_WAV_marker_count", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_add_apply_environment_event_step", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_add_cache_sounds_event_step", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_add_comment_event_step", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_add_control_sounds_event_step", .stack_size = 40, .ver = 80 },
            .{ .name = "AIL_add_persist_preset_event_step", .stack_size = 20, .ver = 80 },
            .{ .name = "AIL_add_sound_limit_event_step", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_add_start_sound_event_step", .stack_size = 96, .ver = 80 },
            .{ .name = "AIL_add_uncache_sounds_event_step", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_apply_environment_preset", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_apply_sound_preset", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_close_event", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_close_soundbank", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_create_event", .stack_size = 0, .ver = 80 },
            .{ .name = "AIL_debug", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_debug_log", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_enumerate_environment_presets", .stack_size = 16, .ver = 80 },
            .{ .name = "AIL_enumerate_events", .stack_size = 16, .ver = 80 },
            .{ .name = "AIL_enumerate_filter_properties", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_enumerate_filter_sample_properties", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_enumerate_output_filter_driver_properties", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_enumerate_output_filter_sample_properties", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_enumerate_sample_stage_properties", .stack_size = 16, .ver = 80 },
            .{ .name = "AIL_enumerate_sound_assets", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_enumerate_sound_presets", .stack_size = 16, .ver = 80 },
            .{ .name = "AIL_file_type_named", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_filter_property", .stack_size = 20, .ver = 80 },
            .{ .name = "AIL_find_marker_in_list", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_ftoa", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_get_event_contents", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_get_marker_list", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_get_soundbank_filename", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_get_soundbank_mem_usage", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_indent", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_mem_close", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_mem_create", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_mem_create_from_existing", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_mem_error", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_mem_open", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_mem_pos", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_mem_printc", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_mem_printf", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_mem_prints", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_mem_read", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_mem_seek", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_mem_size", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_mem_write", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_next_event_step", .stack_size = 16, .ver = 80 },
            .{ .name = "AIL_open_soundbank", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_output_filter_driver_property", .stack_size = 20, .ver = 80 },
            .{ .name = "AIL_platform_property", .stack_size = 20, .ver = 80 },
            .{ .name = "AIL_register_falloff_function_callback", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_register_trace_callback", .stack_size = 4, .ver = 80 },
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
            .{ .name = "AIL_sample_stage_property", .stack_size = 28, .ver = 80 },
            .{ .name = "AIL_set_sample_51_volume_levels", .stack_size = 28, .ver = 80 },
            .{ .name = "AIL_set_sample_51_volume_pan", .stack_size = 24, .ver = 80 },
            .{ .name = "AIL_set_sample_buffer_count", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_set_sample_is_3D", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_set_sample_playback_delay", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_set_sample_playback_rate_factor", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_set_sample_speaker_scale_factors", .stack_size = 16, .ver = 80 },
            .{ .name = "AIL_sound_asset_filename", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_stricmp", .stack_size = 8, .ver = 80 },
            .{ .name = "AIL_strnicmp", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_sys_debug", .stack_size = 4, .ver = 80 },
            .{ .name = "AIL_unapply_environment_preset", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_unapply_sound_preset", .stack_size = 12, .ver = 80 },
            .{ .name = "AIL_IO_thread_handle", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_add_clear_state_event_step", .stack_size = 4, .ver = 90 },
            .{ .name = "AIL_add_exec_event_event_step", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_add_ramp_event_step", .stack_size = 32, .ver = 90 },
            .{ .name = "AIL_add_setblend_event_step", .stack_size = 36, .ver = 90 },
            .{ .name = "AIL_apply_raw_environment_preset", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_apply_raw_sound_preset", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_configure_logging", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_file_callbacks", .stack_size = 16, .ver = 90 },
            .{ .name = "AIL_file_read_info", .stack_size = 16, .ver = 90 },
            .{ .name = "AIL_file_size_info", .stack_size = 12, .ver = 90 },
            .{ .name = "AIL_find_environment_preset", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_find_sound_preset", .stack_size = 8, .ver = 90 },
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
            .{ .name = "AIL_unapply_raw_environment_preset", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_unapply_raw_sound_preset", .stack_size = 8, .ver = 90 },
            .{ .name = "AIL_us_count64", .stack_size = 0, .ver = 90 },
        };
        for (targets) |t| {
            // Skip exports newer than the targeted MSS version so the export
            // table is ABI-shaped like that release (matches the gated imports
            // in main.zig — the symbols don't exist in older-version builds).
            if (openmiles.mss_version < t.ver) continue;
            const canonical = std.fmt.comptimePrint("{s}@{d}", .{ t.name, t.stack_size });
            asm (std.fmt.comptimePrint(".section .drectve\n .ascii \" /EXPORT:{s}={s} /EXPORT:_{s}={s} /EXPORT:_{s}={s}\"\n .text\n", .{ t.name, canonical, t.name, canonical, canonical, canonical }));
        }
        // Manual exports for problematic symbols (RIB is v4+).
        if (openmiles.mss_version >= 40)
            asm (".section .drectve\n .ascii \" /EXPORT:_RIB_provider_library_handle@0=RIB_provider_library_handle@0\"\n .text\n");
        // DllMain is also covered by the targets loop above, but keep explicit alias for safety
        @export(&DllMain, .{ .name = "_DllMain@12", .linkage = .strong });
        // Export the CRT-provided DllMainCRTStartup (defined in dllcrt2.obj, not our code)
        asm (".section .drectve\n .ascii \" /EXPORT:DllMainCRTStartup=_DllMainCRTStartup@12 /EXPORT:_DllMainCRTStartup@12\"\n .text\n");
        // Variadic functions use callconv(.c), generating `_FuncName` in COFF (not `_FuncName@N`).
        // They are NOT in the stdcall targets loop, so they need explicit /EXPORT renames so the
        // DLL export table contains the bare name (AIL_debug_printf) rather than _AIL_debug_printf.
        // The linker automatically prepends `_` to the symbol reference in /EXPORT:name=symbol,
        // so we use the bare name (without leading underscore) as the symbol.
        asm (".section .drectve\n .ascii \" /EXPORT:AIL_debug_printf=AIL_debug_printf /EXPORT:AIL_sprintf=AIL_sprintf\"\n .text\n");
    }
}

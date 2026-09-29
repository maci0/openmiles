const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;
const DigitalDriver = openmiles.DigitalDriver;
const Sample = openmiles.Sample;
const Provider = openmiles.Provider;
const Sequence = openmiles.Sequence;
const Filter = openmiles.Filter;
const MidiDriver = openmiles.MidiDriver;
const AILSOUNDINFO = openmiles.AILSOUNDINFO;

/// Channel ceiling AIL_WAV_file_write will put in a WAV header. Matches
/// miniaudio's MA_MAX_CHANNELS, the widest the engine mixes; a header claiming
/// more is a file the decoder cannot open.
const max_wav_channels: u16 = 254;

// Miles startup is reference-counted: AIL_startup returns the new use count (1
// on the first call), and the public AIL_startup maps to AIL_startup_reg/_stack
// in mss.h. AIL_shutdown stays void. We don't re-init the engine on nested
// calls, so the count is what both ends of the pair act on.
//
// The shutdown side of the count is honoured too. Several games (and the
// Quick API's own users) call AIL_startup more than once and AIL_shutdown
// once per startup; tearing the engine down on the first shutdown left those
// processes with no startup provider, no drivers and a count that still said
// one use was outstanding, so the same sequence of calls left a different
// state depending on how many times startup had run. The teardown is what a
// shutdown at count zero means and stays harmless when repeated, since
// openmiles.shutdown() releases nothing that is already gone.
var g_startup_count: std.atomic.Value(i32) = .init(0);
pub fn AIL_startup() callconv(.winapi) i32 {
    log("ENTER AIL_startup\n", .{});
    openmiles.startup();
    const count = g_startup_count.fetchAdd(1, .acq_rel) + 1;
    log("EXIT AIL_startup\n", .{});
    return count;
}
pub fn AIL_shutdown() callconv(.winapi) void {
    log("AIL_shutdown()\n", .{});
    if (!releaseStartupUse()) return;
    openmiles.shutdown();
}

/// Drop one use and report whether this call should tear the engine down.
/// The decrement and the decision are one compare-exchange: two threads
/// shutting down the last use would otherwise both read 1, both store 0, and
/// both run teardown. A count that is already 0 still reports teardown,
/// because startup() can publish a provider without AIL_startup, and
/// openmiles.shutdown releases nothing that is already gone.
fn releaseStartupUse() bool {
    const first = g_startup_count.load(.acquire);
    if (first <= 0) return true;
    var remaining = first;
    while (remaining > 0) {
        if (g_startup_count.cmpxchgWeak(remaining, remaining - 1, .acq_rel, .acquire)) |actual| {
            remaining = actual;
        } else {
            const last = remaining == 1;
            if (!last) {
                log("AIL_shutdown: {d} use(s) still open, the engine stays up\n", .{remaining - 1});
            }
            return last;
        }
    }
    // Lost the race for the last use: the thread that stored 0 tears down.
    return false;
}

/// The outstanding AIL_startup uses. Not an SDK export: the test suite drains
/// the count through AIL_shutdown to prove the teardown lands on the last use,
/// and a hardcoded number of shutdowns would not survive a suite whose earlier
/// tests left uses of their own behind.
pub fn startupUseCount() i32 {
    return g_startup_count.load(.acquire);
}
pub fn AIL_set_redist_directory(path: [*:0]const u8) callconv(.winapi) [*:0]const u8 {
    // SDK returns char* — a pointer to the stored redist directory so callers
    // can read it back. (EAX was previously left undefined as a void return.)
    log("AIL_set_redist_directory(path={s})\n", .{path});
    openmiles.setRedistDirectory(std.mem.span(path));
    return openmiles.redistDirectoryZ();
}
pub fn AIL_last_error() callconv(.winapi) [*:0]const u8 {
    // SDK (genericmss.cpp) always returns &AIL_error, a stable pointer to the
    // 256-byte buffer that is the empty string when no error is set. Returning a
    // distinct "" literal when empty would hand back an unstable pointer that
    // never reflects later errors for callers that cache it.
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
        // The same process-wide device AIL_open_digital_driver hands back, by
        // the same counted open. Building a second engine here gave a game that
        // mixes the two entry points two miniaudio devices on one output, which
        // the second open can fail outright, and left the waveOutClose side of
        // the pair as the only way to release the first one.
        const driver = openmiles.openDigitalDriver(44100, 16, 2) orelse {
            log("Error: digital driver init failed\n", .{});
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
    if (is_raw and size > 0) {
        s.setAddress(@constCast(file_image), @intCast(size)) catch |err| {
            log("AIL_set_named_sample_file: raw PCM setAddress failed ({any})\n", .{err});
            openmiles.setLastError("Failed to load raw PCM sample");
            return 0;
        };
        return 1;
    }
    if (size >= 16) {
        const ptr: [*]const u8 = @ptrCast(file_image);
        log("AIL_set_named_sample_file: Header bytes: {X}\n", .{ptr[0..16]});
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
    return s.original_pan;
}
pub fn AIL_sample_playback_rate(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return s.playbackRate();
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
    return driver.getActiveSampleCount(std.math.maxInt(u32));
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
    return s.loops_remaining.load(.acquire);
}
pub fn AIL_register_EOS_callback(s_opt: ?*Sample, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    log("AIL_register_EOS_callback(s={*}, callback={*})\n", .{ s, callback });
    return @ptrFromInt(s.eos_callback.swap(if (callback) |cb| @intFromPtr(cb) else 0, .acq_rel));
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
pub fn AIL_serve() callconv(.winapi) void {
    openmiles.serveAllDrivers();
}
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
        openmiles.setLastError("Failed to allocate sample handle");
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
    s.load(data, -1) catch |err| {
        log("AIL_set_sample_file: load failed ({any})\n", .{err});
        openmiles.setLastError("Failed to load sample file");
        return 0;
    };
    return 1;
}
pub fn AIL_set_sample_address(s_opt: ?*Sample, data: *anyopaque, size: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_address(s={*}, data={*}, size={d})\n", .{ s, data, size });
    openmiles.clearLastError();
    s.setAddress(data, size) catch |err| {
        log("AIL_set_sample_address: failed: {any}\n", .{err});
        openmiles.setLastError("Failed to set sample address");
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
    return s.user_data[openmiles.userDataIndex(index)];
}
pub fn AIL_set_sample_user_data(s_opt: ?*Sample, index: i32, value: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.user_data[openmiles.userDataIndex(index)] = value;
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
    const block = openmiles.resolveLoopBlock(s, loop_start, loop_end) orelse return;
    s.setLoopBlock(block[0], block[1]);
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
    // SDK SS_granularity is the SOURCE sample-format frame size (mono-8=1,
    // mono-16/stereo-8=2, stereo-16=4), not whatever miniaudio decodes to. Use
    // the WAV-parsed source bpf when known (stable across reverb/level changes
    // that rebuild the decoded node), else fall back to the decoded frame size.
    if (s.src_bpf > 0) return s.src_bpf;
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
        openmiles.setLastError("Failed to allocate file sample");
        return null;
    };
    const raw: [*]const u8 = @ptrCast(@alignCast(data));
    const size = openmiles.detectAudioSize(raw);
    if (size == 0) return s; // unknown format, return empty sample
    s.loadFromMemory(raw[0..size], true) catch |err| {
        log("AIL_allocate_file_sample: loadFromMemory failed ({any})\n", .{err});
        openmiles.setLastError("Failed to load sample from memory");
        s.deinit();
        return null;
    };
    return s;
}
/// The SDK's MSS_BUFFER_HEAD (-1): pass as buff_num for the ring's head slot.
const MSS_BUFFER_HEAD: i32 = -1;
pub fn AIL_load_sample_buffer(s_opt: ?*Sample, buff_num: i32, data: ?*anyopaque, len: u32) callconv(.winapi) i32 {
    // SDK (wavefile.cpp) returns S32: -1 on a null sample or an out-of-range
    // slot (signed compare, so MSS_BUFFER_HEAD = -1 passes); otherwise the
    // resolved buffer number that was loaded (or removed).
    const s = s_opt orelse return -1;
    if (buff_num >= s.n_buffers) return -1;
    var bn = buff_num;
    var head_advanced = false;
    var head_next: i32 = 0;
    if (bn == MSS_BUFFER_HEAD) {
        const n = if (s.n_buffers > 0) s.n_buffers else 1;
        bn = s.stream_head;
        // The cursor moves only once the slot it names has been taken, so a
        // refusal leaves it where it was and the head keeps naming the slot
        // AIL_sample_buffer_ready reports.
        head_next = @mod(bn + 1, n);
        head_advanced = true;
    }
    if (bn < 0) return -1; // defensive: SDK would index buf[<0]; we stay safe
    if (s.pcm_format != null) {
        // Raw PCM + a known format = MSS double-buffer streaming. Feed the buffer
        // into the ping-pong stream source (zero-copy; the app owns it until EOB).
        // A null buffer is the end-of-stream marker the transport speaks, which
        // is how the slot is taken out of the ring without dropping what it holds.
        s.loadStreamBuffer(@intCast(bn), data, if (data == null) 0 else len) catch |err| {
            openmiles.log("AIL_load_sample_buffer: stream feed failed: {any}\n", .{err});
            openmiles.setLastErrorFmt("AIL_load_sample_buffer: buffer {d} rejected ({any})", .{ bn, err });
            return -1;
        };
    } else {
        if (data == null) {
            // Nothing was loaded and nothing was removed: a whole-image sample
            // has no ring slot to take, so the call reports no load.
            openmiles.setLastErrorFmt("AIL_load_sample_buffer: buffer {d} has nothing to load", .{bn});
            return -1;
        }
        // No format hint: treat as a complete encoded file image (whole-buffer).
        s.load(data.?, @intCast(@min(len, @as(u32, std.math.maxInt(i32))))) catch |err| {
            openmiles.log("AIL_load_sample_buffer: load failed: {any}\n", .{err});
            openmiles.setLastErrorFmt("AIL_load_sample_buffer: buffer {d} rejected ({any})", .{ bn, err });
            return -1;
        };
    }
    if (head_advanced) s.stream_head = head_next;
    // The slot is only reported once the submission was accepted, so a
    // rejected feed leaves AIL_sample_buffer_ready describing the ring that is
    // really there.
    s.last_loaded_buffer.store(bn, .release);
    // Fire SOB (Start Of Buffer) callback now that a new buffer is accepted.
    // AILSAMPLECB: void callback(HSAMPLE S), single arg; the app queries buffer state separately.
    openmiles.fireSampleCallback(&s.sob_callback, s);
    return bn;
}
pub fn AIL_sample_buffer_ready(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    // Streaming: index of a free buffer slot, or -1 when the ring is full.
    if (s.stream_active) return s.streamBufferReady();
    // Non-streaming whole-buffer samples: "ready" once finished or not yet started.
    if (s.is_done.load(.acquire) or !s.is_initialized) return 0;
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
// U32 *len, S32 *head, S32 *tail) @24 — report the play position/length for the
// requested buffer slot, plus the ring head/tail indices.
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
        s.stream_src.slotInfo(@intCast(@max(buff_num, 0)), &p0, &l0);
        if (pos) |p| p.* = p0;
        if (len) |l| l.* = l0;
        return if (s.stream_src.isStarved()) 1 else 0; // return S->starved
    }
    if (pos) |p| p.* = 0;
    if (len) |p| p.* = if (s.owned_buffer) |buf| @intCast(@min(buf.len, std.math.maxInt(u32))) else 0;
    return 0;
}
pub fn AIL_register_EOB_callback(s_opt: ?*Sample, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    return @ptrFromInt(s.eob_callback.swap(if (callback) |cb| @intFromPtr(cb) else 0, .acq_rel));
}
pub fn AIL_register_SOB_callback(s_opt: ?*Sample, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    return @ptrFromInt(s.sob_callback.swap(if (callback) |cb| @intFromPtr(cb) else 0, .acq_rel));
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
    if (new_primary) |d| openmiles.setLastDigitalDriver(d);
    return openmiles.lastDigitalDriver();
}
pub fn AIL_digital_CPU_percent(driver_opt: ?*DigitalDriver) callconv(.winapi) i32 {
    const driver = driver_opt orelse return 0;
    // Estimate CPU load from the ratio of active sounds to a nominal budget.
    // miniaudio doesn't expose CPU usage directly; this approximation is
    // sufficient for games that throttle sound spawning based on this value.
    // SDK returns S32 (integer percent in EAX), not F32.
    // The nominal budget is the cap: past 32 the percent is 100 either way, so
    // the count need not resolve the tail of two long handle lists.
    const active: f32 = @floatFromInt(driver.getActiveSampleCount(32) + driver.get3DActiveSampleCount(32));
    const nominal_budget: f32 = 32.0;
    const pct = (active / nominal_budget) * 100.0;
    return @intFromFloat(@min(pct, 100.0));
}
pub fn AIL_digital_latency(driver_opt: ?*DigitalDriver) callconv(.winapi) u32 {
    const driver = driver_opt orelse return 0; // SDK: null -> 0
    if (driver.getDevice()) |device| {
        const period = device.playback.internalPeriodSizeInFrames;
        const periods = @max(device.playback.internalPeriods, 1);
        const rate = device.playback.internalSampleRate;
        if (rate > 0 and period > 0) {
            // SDK (genericdig.cpp) reports TOTAL output buffering, not one period:
            // (hw_buffer_ms) * DIG_DS_MIX_FRAGMENT_CNT. Our equivalent is the full
            // device buffer = all internalPeriods of internalPeriodSizeInFrames, so
            // multiply by the period count.
            // 64-bit intermediate: period*periods*1000 overflows u32 for
            // large-device configs (e.g. 384000-frame periods x 32).
            const total_frames = @as(u64, period) * periods;
            return @intCast(@min(total_frames *| 1000 / rate, std.math.maxInt(u32)));
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
        // The SDK call carries no buffer size, so the write is unbounded.
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
    // An 8-bit source, still unsigned. widenU8Prefix converts it once the
    // output length is known, so the conversion covers the samples the mix
    // reaches rather than the whole source.
    pending_u8: ?[]const u8 = null,
};

// A mixer input plus the resample cursor the mix loop advances. The source
// position for output frame j is floor(j * rate / dest_rate); carrying it
// forward via the quotient/remainder decomposition of rate/dest_rate keeps the
// mix loop division-free (one add + compare per source per frame instead of a
// 64-bit divide, which dominates the loop on the software-mixer hot path).
const MixCursor = struct {
    src: MixSrc,
    step_q: u64, // floor(rate / dest_rate): whole source points per output frame
    step_r: u64, // rate % dest_rate: fractional remainder carried between frames
    rem: u64 = 0, // accumulated remainder, always < dest_rate
    pos: u64 = 0, // current source position == floor(j * rate / dest_rate)

    // Move from frame j's position floor(j*rate/dest_rate) to frame j+1's: the
    // whole-point quotient, plus one more when the carried remainder crosses
    // dest_rate.
    fn advance(self: *MixCursor, dest_rate: u64) void {
        self.pos += self.step_q;
        self.rem += self.step_r;
        if (self.rem >= dest_rate) {
            self.rem -= dest_rate;
            self.pos += 1;
        }
    }
};

const DecodedPcm = struct {
    samples: []i16, // owned; free with the allocator passed to decodeWavToPcm
    channels: u32,
    rate: u32,
};

/// Decode a WAV-wrapped IMA-ADPCM image to owned interleaved 16-bit PCM.
/// Shared by the mixer source path and AIL_decompress_ADPCM, which both wrap
/// the raw blocks and drive the same miniaudio decode; the two copies had
/// drifted (differing scratch sizes, and a zero-channel divide guard that only
/// one of them carried). The channel count is clamped to at least 1 so the
/// frames-per-chunk division below cannot divide by zero.
fn decodeWavToPcm(allocator: std.mem.Allocator, wav: []const u8) !DecodedPcm {
    var decoder: openmiles.ma.ma_decoder = undefined;
    var cfg = openmiles.ma.ma_decoder_config_init(openmiles.ma.ma_format_s16, 0, 0);
    if (openmiles.ma.ma_decoder_init_memory(wav.ptr, wav.len, &cfg, &decoder) != openmiles.ma.MA_SUCCESS) {
        return error.DecoderInitFailed;
    }
    defer _ = openmiles.ma.ma_decoder_uninit(&decoder);

    const channels = @max(@as(u32, decoder.outputChannels), 1);
    const rate = @as(u32, decoder.outputSampleRate);

    var list: std.ArrayListUnmanaged(i16) = .empty;
    errdefer list.deinit(allocator);
    // Reserve the decoder-reported PCM size up front so appendSlice never
    // realloc-copies the whole buffer mid-decode. The frame count is
    // header-derived, hence spoofable; a saturating multiply + clamp keeps the
    // hint from overflowing or panicking the usize cast on the 32-bit target,
    // and the loop below is bounded by real reads, so an inflated hint only
    // over-reserves.
    var length_frames: u64 = 0;
    _ = openmiles.ma.ma_decoder_get_length_in_pcm_frames(&decoder, &length_frames);
    if (length_frames > 0) {
        const hint: u64 = @min(length_frames *| @as(u64, channels), std.math.maxInt(usize));
        list.ensureTotalCapacity(allocator, @intCast(hint)) catch {};
    }

    // Heap scratch (16-byte aligned) — avoids the stack-layout-dependent
    // misaligned ma_int16 write inside miniaudio's IMA decoder that a stack
    // array did not reliably prevent.
    const chunk = try allocator.alignedAlloc(i16, .@"16", 4096 * 4);
    defer allocator.free(chunk);
    const chunk_frames: u64 = chunk.len / channels;
    while (true) {
        var fr: u64 = 0;
        const read_result = openmiles.ma.ma_decoder_read_pcm_frames(&decoder, chunk.ptr, chunk_frames, &fr);
        // A decoder error leaves fr at 0, indistinguishable from a clean end of
        // stream. Fail the decode instead of returning a silently truncated
        // image, and name the status the callers cannot see.
        if (read_result != openmiles.ma.MA_SUCCESS and read_result != openmiles.ma.MA_AT_END) {
            log("decodeWavToPcm: ma_decoder_read_pcm_frames failed with {d} ({s})\n", .{ read_result, openmiles.maResultDescription(read_result) });
            return error.DecodeFailed;
        }
        if (fr == 0) break;
        list.appendSlice(allocator, chunk[0..@intCast(fr * channels)]) catch return error.OutOfMemory;
    }
    if (list.items.len == 0) return error.EmptyResult;
    // toOwnedSlice leaves the list intact when it fails, and the catch returns
    // an error, so the errdefer above is what frees it. Calling deinit here as
    // well freed the same backing store twice.
    const samples = list.toOwnedSlice(allocator) catch return error.OutOfMemory;
    return .{ .samples = samples, .channels = channels, .rate = rate };
}

// Decode one IMA-ADPCM source's raw blocks to owned interleaved 16-bit PCM via
// the same wrap-and-decode path as AIL_decompress_ADPCM.
fn decodeAdpcmSource(info: *const AILSOUNDINFO) ?MixSrc {
    if (info.data_ptr == null or info.data_len == 0 or info.samples == 0) return null;
    const adpcm: []const u8 = @as([*]const u8, @ptrCast(@alignCast(info.data_ptr.?)))[0..info.data_len];
    const ch: u16 = @intCast(@max(1, @min(2, info.channels)));
    const block_size: u32 = if (info.block_size > 4 * @as(u32, ch)) info.block_size else 512;
    const wav = openmiles.wrapAdpcmInWav(openmiles.global_allocator, adpcm, block_size, ch, info.rate, info.samples) catch return null;
    defer openmiles.global_allocator.free(wav);
    const pcm = decodeWavToPcm(openmiles.global_allocator, wav) catch |err| {
        log("decodeAdpcmSource: {d} byte ADPCM image failed to decode ({any})\n", .{ wav.len, err });
        return null;
    };
    return .{
        .s16 = pcm.samples,
        .owned = pcm.samples,
        .channels = pcm.channels,
        .points = pcm.samples.len / pcm.channels,
        .rate = if (info.rate == 0) 22050 else info.rate,
    };
}

/// Widen every 8-bit source in `part` to 16-bit, covering only the samples the
/// mix can reach in `dest_points` output frames. The last source point read is
/// floor((dest_points - 1) * rate / dest_rate) and a point spans `channels`
/// interleaved samples, so a source longer than that is converted (and
/// allocated) only as far as it is consumed. A failed allocation drops that
/// source, which the mix loop does by finding it exhausted.
fn widenU8Prefix(part: []MixCursor, dest_points: usize, dest_rate: u64) void {
    for (part) |*c| {
        const u8d = c.src.pending_u8 orelse continue;
        const last_frame: u64 = @intCast(dest_points - 1);
        // Saturating: dest_points comes from dest_size and rate from the
        // source, so the product can pass what usize holds on the 32-bit
        // target. The clamp to points below keeps the result in range either
        // way, since no frame past the source's own length is ever read.
        const last_pos: u64 = @min(last_frame *| c.src.rate / dest_rate, std.math.maxInt(usize));
        const total = c.src.points * @as(usize, c.src.channels);
        const needed: usize = @min(last_pos *| c.src.channels +| c.src.channels, total);
        const buf = openmiles.global_allocator.alloc(i16, needed) catch {
            // Dropping the source is the only option left (the mix reads
            // 16-bit), but a source that vanishes from a mix with nothing said
            // reads as a source that was never queued, so name the sample count
            // the allocation was for.
            log("AILMIXINFO mixer: cannot allocate {d} bytes to widen an 8-bit source; that source is omitted from this mix\n", .{needed * @sizeOf(i16)});
            c.src.points = 0; // exhausted: the mix loop drops it, owning nothing
            continue;
        };
        for (0..needed) |k| buf[k] = (@as(i16, u8d[k]) - 128) << 8;
        c.src.s16 = buf;
        c.src.owned = buf;
        c.src.points = needed / c.src.channels;
    }
}

/// SDK cap on the `operations[]` array an AILMIXINFO mixer call may name
/// (wavefile.cpp bounds `num_srcs` to 256 before walking it).
pub const max_mix_operations: usize = 256;

// S32 AIL_process_digital_audio(void *dest, S32 dest_size, U32 dest_rate, U32 dest_format, S32 num_srcs, AILMIXINFO *src)
// Offline software mixer (wavefile.cpp): resample each source to dest_rate, sum,
// and write dest_format into dest, returning the byte count produced. MSS's exact
// per-sample interpolation/mix lives in the closed mixer RIB, so — like the rest
// of OpenMiles' DSP — we mix functionally (nearest-neighbor resample, summed with
// clipping) rather than byte-identically. The dest_points / nbytes_written
// contract matches the SDK.
pub fn AIL_process_digital_audio(dest: ?*anyopaque, dest_size: i32, dest_rate: u32, dest_format: u32, num_srcs: i32, src: ?*anyopaque) callconv(.winapi) i32 {
    if (dest == null or src == null or num_srcs <= 0 or dest_rate == 0 or dest_size <= 0) return 0;
    const n: usize = @min(@as(usize, @intCast(num_srcs)), max_mix_operations);
    const srcs: [*]const openmiles.AILMIXINFO = @ptrCast(@alignCast(src.?));

    // Cursors are partitioned by channel count at build time: the mix loop is
    // per output frame over every source, and a mono/stereo test inside it
    // kept the accumulation scalar and branchy. Each partition also drops
    // exhausted cursors (pos only grows) instead of re-testing them every
    // frame.
    var stereo: [max_mix_operations]MixCursor = undefined;
    var nstereo: usize = 0;
    var mono: [max_mix_operations]MixCursor = undefined;
    var nmono: usize = 0;
    defer {
        for (stereo[0..nstereo]) |c| {
            if (c.src.owned) |owned_buf| openmiles.global_allocator.free(owned_buf);
        }
        for (mono[0..nmono]) |c| {
            if (c.src.owned) |owned_buf| openmiles.global_allocator.free(owned_buf);
        }
    }

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
                // Left unsigned here: dest_points is not known until every
                // source has been sized, and an 8-bit source routinely outruns
                // the output. widenU8Prefix converts the reached prefix once.
                ms.pending_u8 = u8d[0..total];
                ms.points = total / ms.channels;
            }
        }
        // A zero-point source contributes to no output frame; drop it here so
        // the mix loop never revisits it (freeing any owned decode buffer now).
        if (ms.points == 0) {
            if (ms.owned) |owned| openmiles.global_allocator.free(owned);
            continue;
        }
        const cursor: MixCursor = .{ .src = ms, .step_q = ms.rate / dest_rate, .step_r = ms.rate % dest_rate };
        if (ms.channels == 2) {
            stereo[nstereo] = cursor;
            nstereo += 1;
        } else {
            mono[nmono] = cursor;
            nmono += 1;
        }
        // Saturating multiply, then clamped to usize: a source rate far below
        // dest_rate makes pts exceed 2^32, and the @intCast below would panic
        // on the 32-bit target. dest_size caps the real output anyway.
        const pts: u64 = @min(@as(u64, ms.points) *| dest_rate / ms.rate, std.math.maxInt(usize));
        if (pts > max_points) max_points = pts;
    }

    const dest_chan: usize = if ((dest_format & 2) != 0) 2 else 1; // DIG_F_STEREO_MASK
    const dest_bps: usize = if ((dest_format & 1) != 0) 2 else 1; // DIG_F_16BITS_MASK
    const dps = dest_chan * dest_bps;
    var dest_points: usize = @as(usize, @intCast(dest_size)) / dps;
    if (max_points < dest_points) dest_points = @intCast(max_points);
    if (dest_points == 0) return 0;
    widenU8Prefix(stereo[0..nstereo], dest_points, dest_rate);
    widenU8Prefix(mono[0..nmono], dest_points, dest_rate);

    const out: [*]u8 = @ptrCast(dest.?);
    var o: usize = 0;
    var j: usize = 0;
    while (j < dest_points) : (j += 1) {
        var accL: i32 = 0;
        var accR: i32 = 0;
        var si: usize = 0;
        while (si < nstereo) {
            const c = &stereo[si];
            // Exhausted sources stay exhausted (pos only grows), so they are
            // dropped from the partition instead of being re-tested each frame.
            // Dropping moves the last cursor into this slot, so the source that
            // leaves the partition is no longer covered by the deferred sweep
            // over [0, nstereo): free its owned decode buffer here or it is
            // leaked on every mix call that outruns the shortest source.
            if (c.pos >= c.src.points) {
                if (c.src.owned) |owned_buf| openmiles.global_allocator.free(owned_buf);
                nstereo -= 1;
                stereo[si] = stereo[nstereo];
                continue;
            }
            const spi: usize = @intCast(c.pos);
            accL += c.src.s16[spi * 2];
            accR += c.src.s16[spi * 2 + 1];
            c.advance(dest_rate);
            si += 1;
        }
        var mi: usize = 0;
        while (mi < nmono) {
            const c = &mono[mi];
            if (c.pos >= c.src.points) {
                if (c.src.owned) |owned_buf| openmiles.global_allocator.free(owned_buf);
                nmono -= 1;
                mono[mi] = mono[nmono];
                continue;
            }
            const v: i32 = c.src.s16[@intCast(c.pos)];
            accL += v;
            accR += v;
            c.advance(dest_rate);
            mi += 1;
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
// S32 num_srcs, AILMIXINFO const* src) @16 — size the buffer that
// AIL_process_digital_audio will write for the given source(s) resampled to the
// destination rate/format, including the SDK's 256 bytes of slop. This is an
// upper bound to allocate, not the exact byte count that call will return.
pub fn AIL_size_processed_digital_audio(dest_rate: u32, dest_format: u32, num_srcs: i32, src: ?*const anyopaque) callconv(.winapi) i32 {
    if (num_srcs <= 0 or dest_rate == 0) return 0;
    const sp = src orelse return 0;
    // Mirror AIL_API_size_processed_digital_audio (wavefile.cpp): a "point" is one
    // time position (mono sample / stereo pair). ADPCM packs 2 samples/byte,
    // 16-bit uses 2 bytes/sample, a stereo point is 2 samples. Take the largest
    // source's point count after resampling to dest_rate, then size the dest.
    const srcs: [*]const openmiles.AILMIXINFO = @ptrCast(@alignCast(sp));
    // Same SDK cap as AIL_process_digital_audio: the caller's array is
    // operations[num_srcs], and num_srcs is attacker-supplied.
    const n: usize = @min(@as(usize, @intCast(num_srcs)), max_mix_operations);
    var max_points: u64 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
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
    openmiles.sleep(duration);
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
pub fn AIL_set_error(msg: ?[*:0]const u8) callconv(.winapi) void {
    // SDK (genericmss.cpp): a NULL message clears the error rather than crashing.
    const m = msg orelse {
        openmiles.clearLastError();
        return;
    };
    openmiles.setLastError(std.mem.span(m));
}
// AIL_debug_printf and AIL_sprintf are implemented in C (src/bindings/c_impl.c)
// to avoid Zig stage2_llvm miscompilation of C varargs on Windows.

pub fn AIL_WAV_info(data: *anyopaque, info: *anyopaque) callconv(.winapi) i32 {
    // Size-less SDK ABI: the caller passes a bare pointer and guarantees the
    // buffer spans the declared RIFF size, so there is no true length to bound
    // against. Internal callers that know the real buffer length must use
    // wavInfoBounded (openmiles facade) with it. Here the bound is the
    // declared-image ceiling: a hostile RIFF or chunk size field must not walk
    // the parse past that, and a chunk larger than it is not a real image.
    return openmiles.wavInfoBounded(
        @ptrCast(@alignCast(data)),
        openmiles.max_declared_image_size,
        info,
    );
}

pub fn AIL_WAV_file_write(filename: [*:0]const u8, data: *anyopaque, len: u32, rate: i32, format: i32) callconv(.winapi) i32 {
    // The 5th arg is a DIG_F format code (mss.h), NOT a bit depth:
    //   DIG_F_16BITS_MASK (1) -> 16-bit else 8-bit; DIG_F_STEREO_MASK (2) -> stereo.
    if (rate <= 0) return 0;
    openmiles.clearFileError();
    const out_path = std.mem.span(filename);
    // A write that fails partway leaves a short file behind; the caller is told
    // which file, so a later AIL_file_size does not read it as complete.
    errdefer openmiles.setFileErrorFmt("AIL_WAV_file_write: '{s}' is incomplete", .{out_path});
    // MSS 8.0+ (msssys.c AIL_API_WAV_file_write) honors DIG_F_MULTICHANNEL_MASK
    // (bit 16): the real channel count is packed in the high 16 bits. Pre-8.0 has
    // no multichannel path -- and there bit 16 meant DIG_F_USING_ASI, an unrelated
    // state flag -- so only the stereo bit applies. Gate to match each release.
    const channels: u16 = blk: {
        // The multichannel half of `format` is app-supplied and unvalidated, so it
        // can be 0 (bit 16 set, high word empty) or up to 65535. buildWavFromPcm
        // then writes byte_rate 0 and block_align 0, and a count past the engine's
        // channel cap saturates both fields into a header no decoder agrees with.
        // Hold the count to the range the writer can actually represent, with the
        // same one-channel floor the stereo arm uses.
        const raw: u16 = if (openmiles.mss_version >= 80 and (format & 16) != 0)
            @intCast(@as(u32, @bitCast(format)) >> 16)
        else if (format & 2 != 0) 2 else 1;
        break :blk std.math.clamp(raw, 1, max_wav_channels);
    };
    const bits: u16 = if (format & 1 != 0) 16 else 8;
    const pcm_data: []const u8 = @as([*]const u8, @ptrCast(@alignCast(data)))[0..len];
    const wav = openmiles.buildWavFromPcm(openmiles.global_allocator, pcm_data, channels, @intCast(rate), bits) catch |err| {
        log("Error: {any}\n", .{err});
        openmiles.setFileErrorFmt("AIL_WAV_file_write: cannot build a WAV for '{s}'", .{out_path});
        return 0;
    };
    defer openmiles.global_allocator.free(wav);
    const io = openmiles.io;
    const file = openmiles.fs_compat.createFile(io, out_path, .{}) catch |err| {
        log("AIL_WAV_file_write: cannot create '{s}' ({any})\n", .{ out_path, err });
        openmiles.setFileErrorFmt("AIL_WAV_file_write: cannot create '{s}'", .{out_path});
        return 0;
    };
    defer file.close(io);
    file.writeStreamingAll(io, wav) catch |err| {
        log("AIL_WAV_file_write: writing {d} bytes to '{s}' failed ({any})\n", .{ wav.len, out_path, err });
        openmiles.setFileErrorFmt("AIL_WAV_file_write: write of {d} bytes to '{s}' failed", .{ wav.len, out_path });
        return 0;
    };
    return 1;
}
/// Hand a freshly built WAV to the caller as a malloc'd buffer (free with
/// AIL_mem_free_lock). Returns 0 if the allocation fails.
fn adoptWavOut(wav: []const u8, outdata: **anyopaque, outsize: *u32) i32 {
    const out_ptr: [*]u8 = @ptrCast(std.c.malloc(wav.len) orelse {
        openmiles.setLastError("Cannot allocate the output buffer");
        return 0;
    });
    @memcpy(out_ptr[0..wav.len], wav);
    outdata.* = out_ptr;
    outsize.* = @intCast(wav.len);
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
    // Fewer bytes than one whole frame: nothing to encode, and a header-only
    // image handed back under a success code decodes as a file of silence.
    if (total_per_ch == 0) {
        openmiles.setLastError("AIL_compress_ADPCM: source holds less than one sample frame");
        return 0;
    }
    // The encoder works on 16-bit samples; promote 8-bit unsigned PCM (128 = 0).
    var pcm16_owned: ?[]i16 = null;
    defer if (pcm16_owned) |p| openmiles.global_allocator.free(p);
    const pcm: [*]const i16 = blk: {
        if (info.bits == 8) {
            const u8data: [*]const u8 = @ptrCast(info.data_ptr.?);
            const n: usize = info.data_len;
            const tmp = openmiles.global_allocator.alloc(i16, n) catch {
                openmiles.setLastErrorFmt("AIL_compress_ADPCM: cannot allocate {d} bytes for the 16-bit source", .{n * 2});
                return 0;
            };
            for (0..n) |i| tmp[i] = (@as(i16, u8data[i]) - 128) << 8;
            pcm16_owned = tmp;
            break :blk tmp.ptr;
        }
        break :blk @ptrCast(@alignCast(info.data_ptr.?));
    };
    const wav = openmiles.buildAdpcmWav(openmiles.global_allocator, pcm, total_per_ch, channels, info.rate) catch |err| {
        log("Error: {any}\n", .{err});
        openmiles.setLastError("AIL_compress_ADPCM: cannot encode the PCM source");
        return 0;
    };
    defer openmiles.global_allocator.free(wav);
    return adoptWavOut(wav, outdata, outsize);
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
    const adpcm_wav = openmiles.wrapAdpcmInWav(openmiles.global_allocator, adpcm, block_size, src_channels, info.rate, info.samples) catch |err| {
        log("AIL_decompress_ADPCM: wrapping {d} ADPCM blocks failed ({any})\n", .{ info.data_len, err });
        openmiles.setLastError("Failed to wrap ADPCM image for decoding");
        return 0;
    };
    defer openmiles.global_allocator.free(adpcm_wav);
    const pcm = decodeWavToPcm(openmiles.global_allocator, adpcm_wav) catch |err| {
        switch (err) {
            error.DecoderInitFailed => openmiles.setLastError("Failed to open ADPCM image for decoding"),
            error.DecodeFailed => openmiles.setLastError("ADPCM decode failed mid-stream"),
            error.EmptyResult => openmiles.setLastError("AIL_decompress_ADPCM: the image decoded to no audio"),
            error.OutOfMemory => openmiles.setLastError("AIL_decompress_ADPCM: out of memory while decoding"),
        }
        return 0;
    };
    defer openmiles.global_allocator.free(pcm.samples);
    const channels = pcm.channels;
    const rate = pcm.rate;
    const decoded: []const u8 = std.mem.sliceAsBytes(pcm.samples);

    // SDK (miscutil.cpp): the output is sized to exactly info->samples frames
    // (size = samples*channels*16/8). IMA block padding makes the decoder emit up
    // to spb-1 extra frames in the final block, so clamp the decoded PCM to the
    // declared sample count to match MSS byte-for-byte. A short decode is zero-
    // extended to the same declared size (MSS allocates `size` and leaves the
    // unfilled tail; we use deterministic silence instead of its uninitialized
    // bytes).
    const target_bytes: usize = @intCast(@min(@as(u64, info.samples) *| @as(u64, channels) *| 2, std.math.maxInt(usize)));
    const kept = @min(decoded.len, target_bytes);
    var resized: ?[]u8 = null;
    defer if (resized) |r| openmiles.global_allocator.free(r);
    if (kept != target_bytes) {
        // The zero-extension is what makes the output exactly the declared
        // sample count. Losing it to an allocation failure would hand back a
        // shorter image than info->samples promises, with nothing to say so.
        resized = openmiles.global_allocator.alloc(u8, target_bytes) catch {
            log("AIL_decompress_ADPCM: cannot zero-extend to {d} bytes (short by {d})\n", .{ target_bytes, target_bytes - kept });
            return 0;
        };
        @memcpy(resized.?[0..kept], decoded[0..kept]);
        @memset(resized.?[kept..], 0);
    }
    const out_pcm: []const u8 = resized orelse decoded[0..kept];

    const wav = openmiles.buildWavFromPcm(openmiles.global_allocator, out_pcm, @intCast(channels), rate, 16) catch |err| {
        log("Error: {any}\n", .{err});
        openmiles.setLastError("AIL_decompress_ADPCM: cannot build the output WAV");
        return 0;
    };
    defer openmiles.global_allocator.free(wav);
    return adoptWavOut(wav, outdata, outsize);
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
        openmiles.setLastError("Failed to create wave synthesizer");
        return null;
    };
    if (dls) |bank| {
        // `bank` is a *tsf.tsf returned from AIL_DLS_load_file / AIL_DLS_load_memory.
        // Borrow the soundfont — do not free it when this wave synthesizer is destroyed,
        // since the original MidiDriver that loaded it still owns it.
        driver.swapSoundfont(@ptrCast(@alignCast(bank)), false);
    }
    return driver;
}
pub fn AIL_destroy_wave_synthesizer(synth: *MidiDriver) callconv(.winapi) void {
    // The shared close, as AIL_DLS_close uses: the sequences allocated on this
    // device are stopped and released before the driver they read through goes
    // away. A bare deinit left each of them with an initialized ma_sound and a
    // data source reading through a freed driver, and its entry in the global
    // sequence list still naming the freed pointer.
    openmiles.closeMidiDriver(synth);
}
pub fn AIL_waveOutClose(driver_opt: ?*DigitalDriver) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    openmiles.closeDigitalDriver(driver);
}

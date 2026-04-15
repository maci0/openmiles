const std = @import("std");
const builtin = @import("builtin");
const openmiles = @import("openmiles");
const log = openmiles.log;
const fs_compat = openmiles.fs_compat;
const DigitalDriver = openmiles.DigitalDriver;
const Sample = openmiles.Sample;
const Sequence = openmiles.Sequence;
const Provider = openmiles.Provider;

const ma = openmiles.ma;

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
pub export fn AIL_branch_index(seq_opt: ?*Sequence, marker: u32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_branch_index(seq={*}, marker={d})\n", .{ seq, marker });
    seq.branchIndex(marker);
}
pub export fn AIL_waveOutOpen(drvr_ptr: ?*?*DigitalDriver, lphwo: ?*u32, device_id: i32, format: ?*anyopaque) callconv(.winapi) u32 {
    log("AIL_waveOutOpen(drvr_ptr={*}, lphwo={*}, device_id={d}, format={*})\n", .{ drvr_ptr, lphwo, device_id, format });
    if (drvr_ptr) |ptr| {
        const driver = openmiles.DigitalDriver.init(openmiles.global_allocator.?, 44100, 16, 2) catch |err| {
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
    // If the caller indicates raw/unheadered PCM (e.g. type = "RAW", ".RAW", "PCM"),
    // route through setAddress which wraps raw PCM in a WAV header using any
    // pcm_format previously set via AIL_set_sample_type.
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
    return @min(127, @max(0, @as(i32, @intFromFloat((s.pan * 64.0) + 64.0))));
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
    // block parameter is currently ignored; all data is treated as single-block.
    // MSS semantics: block=-1 = single-block, block=0/1 = double-buffer.
    s.load(data, -1) catch {
        openmiles.setLastError("Failed to load sample file");
        return 0;
    };
    return 1;
}
pub export fn AIL_set_sample_address(s_opt: ?*Sample, data: *anyopaque, size: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_set_sample_address(s={*}, data={*}, size={d})\n", .{ s, data, size });
    s.setAddress(data, size) catch {};
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
    // end_sample transitions to SMP_DONE (not SMP_STOPPED)
    if (s.is_initialized) {
        _ = openmiles.ma.ma_sound_stop(&s.sound);
        _ = openmiles.ma.ma_sound_seek_to_pcm_frame(&s.sound, 0);
    }
    s.is_done = true;
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
pub export fn AIL_open_stream(driver_opt: ?*DigitalDriver, filename_opt: ?[*:0]const u8, stream_mem: i32) callconv(.winapi) ?*Sample {
    const driver = driver_opt orelse return null;
    const file_str = if (filename_opt) |ptr| std.mem.span(ptr) else "<null>";
    log("AIL_open_stream(driver={*}, filename='{s}', stream_mem={d})\n", .{ driver, file_str, stream_mem });
    _ = &stream_mem;
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

    // If custom file callbacks are set, read the whole file through them
    if (openmiles.cb_file_open != null) {
        log("AIL_open_stream: Using custom cb_file_open\n", .{});
        const buf = openmiles.fileCallbackReadAll(filename) catch |err| {
            log("AIL_open_stream: fileCallbackReadAll failed ({any})\n", .{err});
            return null;
        };
        s.loadFromOwnedMemory(buf) catch |err| {
            log("AIL_open_stream: loadFromOwnedMemory failed ({any})\n", .{err});
            openmiles.global_allocator.?.free(buf);
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
    // Stream callbacks in MSS are called at end-of-stream; reuse the EOS callback mechanism.
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
    return @min(127, @max(0, @as(i32, @intFromFloat((s.pan * 64.0) + 64.0))));
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
pub export fn AIL_open_filter(provider_opt: ?*Provider, driver_opt: ?*DigitalDriver) callconv(.winapi) ?*anyopaque {
    const provider = provider_opt orelse return null;
    const driver = driver_opt orelse return null;
    log("AIL_open_filter(provider={*}, driver={*})\n", .{ provider, driver });
    const filter = openmiles.Filter.init(provider, driver) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
    return @ptrCast(filter);
}
pub export fn AIL_close_filter(filter_ptr: *anyopaque) callconv(.winapi) void {
    log("AIL_close_filter(filter={*})\n", .{filter_ptr});
    const filter: *openmiles.Filter = @ptrCast(@alignCast(filter_ptr));
    filter.deinit();
}
pub export fn AIL_set_sample_filter(HSAMPLE_opt: ?*Sample, filter_ptr: *anyopaque, priority: i32) callconv(.winapi) void {
    const HSAMPLE = HSAMPLE_opt orelse return;
    _ = priority;
    log("AIL_set_sample_filter(HSAMPLE={*}, filter={*})\n", .{ HSAMPLE, filter_ptr });
    const filter: *openmiles.Filter = @ptrCast(@alignCast(filter_ptr));
    filter.attachSample(HSAMPLE);
}
pub export fn AIL_filter_attribute(filter_ptr: *anyopaque, name: [*:0]const u8, value: *anyopaque) callconv(.winapi) void {
    log("AIL_filter_attribute(filter={*}, name={s})\n", .{ filter_ptr, name });
    const filter: *const openmiles.Filter = @ptrCast(@alignCast(filter_ptr));
    const name_slice = std.mem.span(name);
    const result = filter.getAttribute(name_slice);
    const out: *f32 = @ptrCast(@alignCast(value));
    out.* = result;
}
pub export fn AIL_set_filter_attribute(filter_ptr: *anyopaque, name: [*:0]const u8, value: *anyopaque) callconv(.winapi) void {
    const val: *const f32 = @ptrCast(@alignCast(value));
    log("AIL_set_filter_attribute(filter={*}, name={s}, value={d})\n", .{ filter_ptr, name, val.* });
    const filter: *openmiles.Filter = @ptrCast(@alignCast(filter_ptr));
    const name_slice = std.mem.span(name);
    filter.setAttribute(name_slice, val.*);
}
const builtin_filter_name: [*:0]const u8 = "OpenMiles Low-Pass Filter";
pub export fn AIL_enumerate_filters(provider_opt: ?*Provider, next: *?*anyopaque, name: *[*:0]const u8) callconv(.winapi) i32 {
    _ = provider_opt;
    if (next.* == null) {
        // First call — return the built-in filter
        name.* = builtin_filter_name;
        // Use a sentinel value so the next call returns 0 (end of list)
        next.* = @ptrFromInt(@as(usize, 1));
        return 1;
    }
    return 0;
}
pub export fn AIL_redbook_open(drive: u32) callconv(.winapi) ?*anyopaque {
    log("AIL_redbook_open(drive={d})\n", .{drive});
    return null;
}
pub export fn AIL_redbook_close(hb: *anyopaque) callconv(.winapi) void {
    log("AIL_redbook_close(hb={*})\n", .{hb});
}
pub export fn AIL_redbook_play(hb: *anyopaque, start: u32, end: u32) callconv(.winapi) u32 {
    log("AIL_redbook_play(hb={*}, start={d}, end={d})\n", .{ hb, start, end });
    return 0;
}
pub export fn AIL_redbook_stop(hb: *anyopaque) callconv(.winapi) u32 {
    log("AIL_redbook_stop(hb={*})\n", .{hb});
    return 0;
}
pub export fn AIL_redbook_pause(hb: *anyopaque) callconv(.winapi) u32 {
    log("AIL_redbook_pause(hb={*})\n", .{hb});
    return 0;
}
pub export fn AIL_redbook_resume(hb: *anyopaque) callconv(.winapi) u32 {
    log("AIL_redbook_resume(hb={*})\n", .{hb});
    return 0;
}
pub export fn AIL_redbook_status(hb: *anyopaque) callconv(.winapi) u32 {
    log("AIL_redbook_status(hb={*})\n", .{hb});
    return 0;
}
pub export fn AIL_redbook_tracks(hb: *anyopaque) callconv(.winapi) u32 {
    log("AIL_redbook_tracks(hb={*})\n", .{hb});
    return 0;
}

pub export fn AIL_mem_alloc_lock(size: u32) callconv(.winapi) ?*anyopaque {
    log("AIL_mem_alloc_lock(size={d})\n", .{size});
    return std.c.malloc(size);
}
pub export fn AIL_mem_free_lock(ptr: *anyopaque) callconv(.winapi) void {
    log("AIL_mem_free_lock(ptr={*})\n", .{ptr});
    std.c.free(ptr);
}
extern fn openmiles_tsf_channel_note_count(f: ?*openmiles.tsf.tsf, channel: i32) i32;
pub export fn AIL_channel_notes(seq_opt: ?*Sequence, channel: i32) callconv(.winapi) i32 {
    const seq = seq_opt orelse return 0;
    const sf = seq.driver.soundfont orelse return 0;
    return openmiles_tsf_channel_note_count(sf, channel);
}
pub export fn AIL_controller_value(seq_opt: ?*Sequence, channel: i32, controller: i32) callconv(.winapi) i32 {
    const seq = seq_opt orelse return 0;
    const sf = seq.driver.soundfont orelse return 0;
    const tsf_mod = openmiles.tsf;
    switch (controller) {
        0 => return tsf_mod.tsf_channel_get_preset_bank(sf, channel),
        7, 11 => { // Volume / Expression (both map to channel volume in tsf)
            const v = tsf_mod.tsf_channel_get_volume(sf, channel);
            return @intFromFloat(v * 127.0);
        },
        10 => { // Pan: tsf returns -1..1, MSS wants 0..127 (center=64)
            const p = tsf_mod.tsf_channel_get_pan(sf, channel);
            return @min(127, @max(0, @as(i32, @intFromFloat((p + 1.0) * 64.0))));
        },
        else => return 0,
    }
}
pub export fn AIL_send_channel_voice_message(seq_opt: ?*Sequence, status: i32, d1: i32, d2: i32, time: i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    _ = time;
    if (seq.driver.soundfont == null) return;
    const sf = seq.driver.soundfont.?;
    const tsf_mod = openmiles.tsf;
    const msg_type = status & 0xF0;
    const channel = status & 0x0F;
    switch (msg_type) {
        0x80 => tsf_mod.tsf_note_off(sf, channel, d1), // Note Off
        0x90 => if (d2 > 0) { // Note On
            _ = tsf_mod.tsf_note_on(sf, channel, d1, @as(f32, @floatFromInt(d2)) / 127.0);
        } else {
            tsf_mod.tsf_note_off(sf, channel, d1);
        },
        0xB0 => { // Control Change
            _ = tsf_mod.tsf_channel_midi_control(sf, channel, d1, d2);
        },
        0xC0 => { // Program Change
            _ = tsf_mod.tsf_channel_set_presetnumber(sf, channel, d1, if (channel == 9) 1 else 0);
        },
        0xE0 => { // Pitch Bend (d1=LSB, d2=MSB)
            const bend = (d2 << 7) | d1;
            _ = tsf_mod.tsf_channel_set_pitchwheel(sf, channel, bend);
        },
        0xA0 => { // Aftertouch - not supported in tsf, ignore
        },
        else => {},
    }
}
pub export fn AIL_send_sysex_message(seq_opt: ?*Sequence, data: *anyopaque) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    const sf = seq.driver.soundfont orelse return;
    const bytes: [*]const u8 = @ptrCast(data);
    // SysEx starts with 0xF0 and ends with 0xF7. Scan for known reset patterns.
    if (bytes[0] != 0xF0) return;
    // Match common resets by looking for distinctive bytes within a small window
    var is_reset = false;
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        if (bytes[i] == 0xF7) break;
        // GM On: F0 7E 7F 09 01 F7
        if (bytes[i] == 0x7E and i + 2 < 16 and bytes[i + 2] == 0x09) {
            is_reset = true;
            break;
        }
        // GS Reset: F0 41 .. 42 12 40 00 7F 00
        if (bytes[i] == 0x40 and i + 2 < 16 and bytes[i + 1] == 0x00 and bytes[i + 2] == 0x7F) {
            is_reset = true;
            break;
        }
        // XG Reset: F0 43 .. 4C 00 00 7E 00
        if (bytes[i] == 0x4C and i + 3 < 16 and bytes[i + 1] == 0x00 and bytes[i + 3] == 0x7E) {
            is_reset = true;
            break;
        }
    }
    if (is_reset) {
        log("AIL_send_sysex_message: recognized GM/GS/XG reset — resetting all channels\n", .{});
        var ch: i32 = 0;
        while (ch < 16) : (ch += 1) {
            _ = openmiles.tsf.tsf_channel_midi_control(sf, ch, 123, 0); // All Notes Off
            _ = openmiles.tsf.tsf_channel_midi_control(sf, ch, 121, 0); // Reset All Controllers
            _ = openmiles.tsf.tsf_channel_midi_control(sf, ch, 7, 100); // Default volume
            _ = openmiles.tsf.tsf_channel_midi_control(sf, ch, 10, 64); // Center pan
        }
    }
}
pub export fn AIL_lock_channel(seq_opt: ?*Sequence) callconv(.winapi) i32 {
    const seq = seq_opt orelse return -1;
    return openmiles.lockChannel(seq);
}
pub export fn AIL_release_channel(seq_opt: ?*Sequence, channel: i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    openmiles.releaseChannel(seq, channel);
}
pub export fn AIL_register_beat_callback(seq_opt: ?*Sequence, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const seq = seq_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(seq.beat_callback);
    seq.beat_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_register_event_callback(seq_opt: ?*Sequence, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const seq = seq_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(seq.event_callback);
    seq.event_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_register_prefix_callback(seq_opt: ?*Sequence, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const seq = seq_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(seq.prefix_callback);
    seq.prefix_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_register_trigger_callback(seq_opt: ?*Sequence, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const seq = seq_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(seq.trigger_callback);
    seq.trigger_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_register_timbre_callback(seq_opt: ?*Sequence, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const seq = seq_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(seq.timbre_callback);
    seq.timbre_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_register_ICA_array(seq_opt: ?*Sequence, arr: *anyopaque) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    const sf = seq.driver.soundfont orelse return;
    // ICA is a 16x128 array: for each MIDI channel, 128 controller initial values.
    // Apply all non-zero CCs to TSF so channels start in the correct state.
    const data: [*]const u8 = @ptrCast(arr);
    var ch: i32 = 0;
    while (ch < 16) : (ch += 1) {
        var cc: i32 = 0;
        while (cc < 128) : (cc += 1) {
            const val = data[@intCast(ch * 128 + cc)];
            if (val != 0) {
                _ = openmiles.tsf.tsf_channel_midi_control(sf, seq.getPhysicalChannel(ch), cc, val);
            }
        }
    }
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
    _ = s;
    _ = block_size;
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
pub export fn AIL_load_sample_buffer(s_opt: ?*Sample, data: *anyopaque, len: u32, buffer_id: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.last_loaded_buffer = buffer_id;
    const was_done = s.is_done;
    if (s.pcm_format) |fmt| {
        // Raw PCM data: wrap in a WAV header so miniaudio can decode it.
        // pcm_format was set by a prior AIL_set_sample_type call.
        const raw: []const u8 = @as([*]const u8, @ptrCast(@alignCast(data)))[0..@as(usize, len)];
        const rate: u32 = if (s.target_rate) |r| @intFromFloat(r) else 22050;
        const wav = openmiles.buildWavFromPcm(s.driver.allocator, raw, fmt.channels, rate, fmt.bits) catch return;
        s.loadFromOwnedMemory(wav) catch {
            s.driver.allocator.free(wav);
            return;
        };
    } else {
        s.load(data, @intCast(len)) catch return;
    }
    // Fire SOB (Start Of Buffer) callback now that a new buffer is ready.
    // Signature: void callback(HSAMPLE S, S32 buff_num, U32 buff_size, void const *buff_addr)
    if (s.sob_callback != 0) {
        const cb: *const fn (?*anyopaque, i32, u32, ?*anyopaque) callconv(.winapi) void = @ptrFromInt(s.sob_callback);
        cb(@ptrCast(s), buffer_id, len, data);
    }
    // If playback had stopped (buffer ran dry), restart it now that new data is available.
    if (was_done and s.is_initialized) {
        s.is_done = false;
        s.loops_remaining = 1;
        _ = openmiles.ma.ma_sound_seek_to_pcm_frame(&s.sound, 0);
        _ = openmiles.ma.ma_sound_start(&s.sound);
    }
}
pub export fn AIL_sample_buffer_ready(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    _ = s;
    return 1;
}
pub export fn AIL_sample_buffer_info(s_opt: ?*Sample, info: *anyopaque, len: *u32, buffer_id: *i32, flags: *u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    const addr_out: *?*anyopaque = @ptrCast(@alignCast(info));
    if (s.owned_buffer) |buf| {
        addr_out.* = @ptrCast(buf.ptr);
        len.* = @intCast(buf.len);
    } else {
        addr_out.* = null;
        len.* = 0;
    }
    buffer_id.* = s.last_loaded_buffer;
    flags.* = 0;
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
pub export fn AIL_register_EOF_callback(s: *anyopaque, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const stream: *Sample = @ptrCast(@alignCast(s));
    const prev: ?*anyopaque = @ptrFromInt(stream.eos_callback);
    stream.eos_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_set_stream_processor(s_opt: ?*Sample, stage: i32, processor: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const s = s_opt orelse return null;
    const idx: usize = @intCast(@min(@max(stage, 0), 1));
    const prev: ?*anyopaque = @ptrFromInt(s.sample_processors[idx]);
    s.sample_processors[idx] = if (processor) |p| @intFromPtr(p) else 0;
    return prev;
}
pub export fn AIL_filter_stream_attribute(s: *anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const sample: *Sample = @ptrCast(@alignCast(s));
    if (sample.attached_filter) |filter| {
        const out: *f32 = @ptrCast(@alignCast(val));
        out.* = filter.getAttribute(std.mem.span(name));
    }
}
pub export fn AIL_set_filter_stream_preference(s: *anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const sample: *Sample = @ptrCast(@alignCast(s));
    if (sample.attached_filter) |filter| {
        const v: *const f32 = @ptrCast(@alignCast(val));
        filter.setAttribute(std.mem.span(name), v.*);
    }
}
const filter_attr_names = [_][*:0]const u8{ "Cutoff", "Order" };
pub export fn AIL_enumerate_filter_attributes(filter: *anyopaque, next: *?*anyopaque, name: *[*:0]const u8) callconv(.winapi) i32 {
    _ = filter;
    const idx: usize = if (next.* == null) 0 else @intFromPtr(next.*);
    if (idx >= filter_attr_names.len) return 0;
    name.* = filter_attr_names[idx];
    next.* = @ptrFromInt(idx + 1);
    return 1;
}
pub export fn AIL_enumerate_filter_sample_attributes(filter: *anyopaque, next: *?*anyopaque, name: *[*:0]const u8) callconv(.winapi) i32 {
    _ = filter;
    const idx: usize = if (next.* == null) 0 else @intFromPtr(next.*);
    if (idx >= filter_attr_names.len) return 0;
    name.* = filter_attr_names[idx];
    next.* = @ptrFromInt(idx + 1);
    return 1;
}
pub export fn AIL_filter_sample_attribute(s: *anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const sample: *Sample = @ptrCast(@alignCast(s));
    if (sample.attached_filter) |filter| {
        const out: *f32 = @ptrCast(@alignCast(val));
        out.* = filter.getAttribute(std.mem.span(name));
    }
}
pub export fn AIL_set_filter_sample_preference(s: *anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const sample: *Sample = @ptrCast(@alignCast(s));
    if (sample.attached_filter) |filter| {
        const v: *const f32 = @ptrCast(@alignCast(val));
        filter.setAttribute(std.mem.span(name), v.*);
    }
}
pub export fn AIL_set_filter_preference(filter_ptr: *anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const filter: *openmiles.Filter = @ptrCast(@alignCast(filter_ptr));
    const v: *const f32 = @ptrCast(@alignCast(val));
    filter.setAttribute(std.mem.span(name), v.*);
}
pub export fn AIL_redbook_eject(hb: *anyopaque) callconv(.winapi) u32 {
    _ = hb;
    return 0;
}
pub export fn AIL_redbook_retract(hb: *anyopaque) callconv(.winapi) u32 {
    _ = hb;
    return 0;
}
pub export fn AIL_redbook_id(hb: *anyopaque) callconv(.winapi) [*:0]const u8 {
    _ = hb;
    return "";
}
pub export fn AIL_redbook_open_drive(drive: [*:0]const u8) callconv(.winapi) ?*anyopaque {
    _ = drive;
    return null;
}
pub export fn AIL_redbook_position(hb: *anyopaque) callconv(.winapi) u32 {
    _ = hb;
    return 0;
}
pub export fn AIL_redbook_track(hb: *anyopaque) callconv(.winapi) u32 {
    _ = hb;
    return 0;
}
pub export fn AIL_redbook_track_info(hb: *anyopaque, track: u32, start_ms: ?*u32, end_ms: ?*u32) callconv(.winapi) void {
    _ = hb;
    _ = track;
    if (start_ms) |p| p.* = 0;
    if (end_ms) |p| p.* = 0;
}
pub export fn AIL_redbook_set_volume(hb: *anyopaque, volume: i32) callconv(.winapi) void {
    _ = hb;
    _ = volume;
}
pub export fn AIL_redbook_volume(hb: *anyopaque) callconv(.winapi) i32 {
    _ = hb;
    return 127;
}
pub export fn AIL_primary_digital_driver(device_num: i32) callconv(.winapi) ?*DigitalDriver {
    _ = device_num;
    return openmiles.last_digital_driver;
}
pub export fn AIL_digital_CPU_percent(driver_opt: ?*DigitalDriver) callconv(.winapi) f32 {
    const driver = driver_opt orelse return 0.0;
    _ = driver;
    return 0.0;
}
pub export fn AIL_digital_latency(driver_opt: ?*DigitalDriver) callconv(.winapi) u32 {
    const driver = driver_opt orelse return 0;
    const device = openmiles.ma.ma_engine_get_device(&driver.engine);
    if (device != null) {
        const period = device.*.playback.internalPeriodSizeInFrames;
        const rate = device.*.playback.internalSampleRate;
        if (rate > 0 and period > 0) {
            return (period * 1000) / rate;
        }
    }
    // Fallback for no-device engines (tests) or if period info unavailable
    return 10;
}
pub export fn AIL_digital_configuration(driver_opt: ?*DigitalDriver, rate: ?*i32, channels: ?*i32, bits: ?*i32, flags: ?*u32) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    const eng = &driver.engine;
    if (rate) |p| p.* = @intCast(openmiles.ma.ma_engine_get_sample_rate(eng));
    if (channels) |p| p.* = @intCast(openmiles.ma.ma_engine_get_channels(eng));
    if (bits) |p| p.* = 16; // miniaudio always outputs 16-bit PCM from this interface
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
pub export fn AIL_process_digital_audio(driver_opt: ?*DigitalDriver, dest: *anyopaque, count: u32, mono_dest: *anyopaque, mono_count: u32, flags: u32) callconv(.winapi) i32 {
    const driver = driver_opt orelse return 0;
    _ = driver;
    _ = dest;
    _ = count;
    _ = mono_dest;
    _ = mono_count;
    _ = flags;
    return 0;
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
    std.Thread.sleep(@as(u64, ms) * std.time.ns_per_ms);
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
pub export fn AIL_file_error() callconv(.winapi) [*:0]const u8 {
    if (openmiles.last_file_error_buf[0] == 0) return "No error";
    return &openmiles.last_file_error_buf;
}
fn openFileAnyPath(path: []const u8) ?std.fs.File {
    return fs_compat.openFile(path, .{}) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
}
pub export fn AIL_file_read(filename: [*:0]const u8, dest: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    openmiles.clearFileError();
    // Try custom file callbacks first
    if (openmiles.cb_file_open != null) {
        const buf = openmiles.fileCallbackReadAll(filename) catch null;
        if (buf) |b| {
            defer openmiles.global_allocator.?.free(b);
            if (dest) |d| {
                @memcpy(@as([*]u8, @ptrCast(@alignCast(d)))[0..b.len], b);
                return d;
            }
            // Allocate with malloc so caller can free with AIL_mem_free_lock (std.c.free)
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
    defer file.close();
    const size: usize = @intCast((file.stat() catch {
        openmiles.setFileError("Stat failed");
        return null;
    }).size);
    if (size == 0) return null;
    if (dest) |d| {
        const buf: [*]u8 = @ptrCast(@alignCast(d));
        _ = file.readAll(buf[0..size]) catch {
            openmiles.setFileError("Read error");
            return null;
        };
        return d;
    } else {
        // Allocate with malloc so caller can free with AIL_mem_free_lock (std.c.free)
        const buf: [*]u8 = @ptrCast(std.c.malloc(size) orelse {
            openmiles.setFileError("Out of memory");
            return null;
        });
        _ = file.readAll(buf[0..size]) catch {
            std.c.free(buf);
            openmiles.setFileError("Read error");
            return null;
        };
        return buf;
    }
}
pub export fn AIL_file_size(filename: [*:0]const u8) callconv(.winapi) u32 {
    openmiles.clearFileError();
    // Try custom file callbacks first
    if (openmiles.cb_file_open != null) {
        var size: u32 = 0;
        const open_fn = openmiles.cb_file_open.?;
        const close_fn = openmiles.cb_file_close orelse return 0;
        const handle = open_fn(filename, &size) orelse {
            openmiles.setFileError("File not found");
            return 0;
        };
        close_fn(handle);
        return size;
    }
    const path = std.mem.span(filename);
    const file = openFileAnyPath(path) orelse {
        openmiles.setFileError("File not found");
        return 0;
    };
    defer file.close();
    const stat = file.stat() catch {
        openmiles.setFileError("Stat failed");
        return 0;
    };
    return @intCast(stat.size);
}
pub export fn AIL_file_type(data: *anyopaque, len: u32) callconv(.winapi) i32 {
    if (len < 4) return 0;
    const raw: [*]const u8 = @ptrCast(@alignCast(data));
    if (raw[0] == 'R' and raw[1] == 'I' and raw[2] == 'F' and raw[3] == 'F') return 1; // WAV
    if (raw[0] == 'M' and raw[1] == 'T' and raw[2] == 'h' and raw[3] == 'd') return 2; // SMF MIDI
    // XMIDI: IFF FORM container with XDIR or XMID fourCC at offset 8
    if (raw[0] == 'F' and raw[1] == 'O' and raw[2] == 'R' and raw[3] == 'M' and len >= 12) {
        if ((raw[8] == 'X' and raw[9] == 'D' and raw[10] == 'I' and raw[11] == 'R') or
            (raw[8] == 'X' and raw[9] == 'M' and raw[10] == 'I' and raw[11] == 'D'))
        {
            return 3; // XMIDI
        }
    }
    return 0;
}
pub export fn AIL_file_write(filename: [*:0]const u8, data: *anyopaque, len: u32) callconv(.winapi) i32 {
    const path = std.mem.span(filename);
    const file = if (std.fs.path.isAbsolute(path))
        std.fs.createFileAbsolute(path, .{}) catch |err| {
            log("Error: {any}\n", .{err});
            return 0;
        }
    else
        std.fs.cwd().createFile(path, .{}) catch |err| {
            log("Error: {any}\n", .{err});
            return 0;
        };
    defer file.close();
    const buf: [*]const u8 = @ptrCast(@alignCast(data));
    file.writeAll(buf[0..len]) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    return 1;
}

/// Parses a WAV file header and populates an AILSOUNDINFO structure.
/// Returns 1 on success, 0 on failure.
pub export fn AIL_WAV_info(data: *anyopaque, info: *anyopaque) callconv(.winapi) i32 {
    const raw: [*]const u8 = @ptrCast(@alignCast(data));
    if (raw[0] != 'R' or raw[1] != 'I' or raw[2] != 'F' or raw[3] != 'F') return 0;
    if (raw[8] != 'W' or raw[9] != 'A' or raw[10] != 'V' or raw[11] != 'E') return 0;
    const out: *openmiles.AILSOUNDINFO = @ptrCast(@alignCast(info));
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
        const next = offset + chunk_size + (chunk_size & 1); // pad to even
        if (next <= offset) break; // guard against zero/wraparound
        offset = next;
    }
    if (data_ptr == null) return 0;
    // For PCM (format 1): bytes_per_frame = channels * (bits/8)
    // For ADPCM (format 2) and others: block_align from fmt chunk is used
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
    // initial_ptr: for compressed formats, points to the start of compressed data (same as data_ptr)
    out.initial_ptr = if (audio_format != 1) data_ptr else null;
    return 1;
}
pub export fn AIL_WAV_file_write(filename: [*:0]const u8, data: *anyopaque, len: u32, rate: i32, bits: i32) callconv(.winapi) i32 {
    // Build a PCM WAV and write it
    const pcm_data: []const u8 = @as([*]const u8, @ptrCast(@alignCast(data)))[0..len];
    const wav = openmiles.buildWavFromPcm(openmiles.global_allocator.?, pcm_data, 1, @intCast(rate), @intCast(bits)) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    defer openmiles.global_allocator.?.free(wav);
    const path = std.mem.span(filename);
    const file = if (std.fs.path.isAbsolute(path))
        std.fs.createFileAbsolute(path, .{}) catch |err| {
            log("Error: {any}\n", .{err});
            return 0;
        }
    else
        std.fs.cwd().createFile(path, .{}) catch |err| {
            log("Error: {any}\n", .{err});
            return 0;
        };
    defer file.close();
    file.writeAll(wav) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    return 1;
}
pub export fn AIL_mem_use_malloc(malloc_fn: ?*anyopaque) callconv(.winapi) void {
    _ = malloc_fn;
}
pub export fn AIL_mem_use_free(free_fn: ?*anyopaque) callconv(.winapi) void {
    _ = free_fn;
}
pub export fn AIL_set_mem_callbacks(malloc_fn: ?*anyopaque, free_fn: ?*anyopaque) callconv(.winapi) void {
    _ = malloc_fn;
    _ = free_fn;
}
const ima_step_table = [89]i32{
    7,     8,     9,     10,    11,    12,    13,    14,    16,    17,   19,   21,   23,    25,    28,    31,
    34,    37,    41,    45,    50,    55,    60,    66,    73,    80,   88,   97,   107,   118,   130,   143,
    157,   173,   190,   209,   230,   253,   279,   307,   337,   371,  408,  449,  494,   544,   598,   658,
    724,   796,   876,   963,   1060,  1166,  1282,  1411,  1552,  1707, 1878, 2066, 2272,  2499,  2749,  3024,
    3327,  3660,  4026,  4428,  4871,  5358,  5894,  6484,  7132,  7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
};
const ima_index_table = [16]i32{ -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8 };
fn imaEncode(sample: i16, predictor: *i32, step_idx: *i32) u8 {
    const step = ima_step_table[@intCast(@max(0, @min(88, step_idx.*)))];
    var diff: i32 = @as(i32, sample) - predictor.*;
    var nibble: u8 = 0;
    if (diff < 0) {
        nibble = 8;
        diff = -diff;
    }
    if (diff >= step) {
        nibble |= 4;
        diff -= step;
    }
    if (diff >= step >> 1) {
        nibble |= 2;
        diff -= step >> 1;
    }
    if (diff >= step >> 2) {
        nibble |= 1;
    }
    // Update predictor by decoding the nibble we just encoded (keeps encoder/decoder in sync)
    var delta: i32 = step >> 3;
    if (nibble & 4 != 0) delta += step;
    if (nibble & 2 != 0) delta += step >> 1;
    if (nibble & 1 != 0) delta += step >> 2;
    if (nibble & 8 != 0) predictor.* -= delta else predictor.* += delta;
    if (predictor.* > 32767) predictor.* = 32767;
    if (predictor.* < -32768) predictor.* = -32768;
    step_idx.* += ima_index_table[nibble];
    if (step_idx.* < 0) step_idx.* = 0;
    if (step_idx.* > 88) step_idx.* = 88;
    return nibble;
}
fn buildAdpcmWav(alloc: std.mem.Allocator, pcm: [*]const i16, total_per_ch: usize, channels: u16, rate: u32) ![]u8 {
    const block_size: u32 = 512;
    const ch: u32 = channels;
    // MS formula: (BlockAlign - 4*ch) * 8 / (4*ch) + 1
    const spb: u32 = (block_size - 4 * ch) * 8 / (4 * ch) + 1;
    const num_blocks: usize = (total_per_ch + spb - 1) / spb;
    const data_size: u32 = @intCast(num_blocks * block_size);
    const avg_bps: u32 = rate * block_size / spb;
    // Layout: RIFF(8) + "WAVE"(4) + "fmt "(8+20) + "fact"(8+4) + "data"(8+data_size)
    const header_sz: usize = 8 + 4 + 8 + 20 + 8 + 4 + 8;
    var buf = try alloc.alloc(u8, header_sz + data_size);
    errdefer alloc.free(buf);
    var o: usize = 0;
    @memcpy(buf[o .. o + 4], "RIFF");
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], @intCast(buf.len - 8), .little);
    o += 4;
    @memcpy(buf[o .. o + 4], "WAVE");
    o += 4;
    @memcpy(buf[o .. o + 4], "fmt ");
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], 20, .little);
    o += 4; // fmt chunk size
    std.mem.writeInt(u16, buf[o..][0..2], 0x0011, .little);
    o += 2; // WAVE_FORMAT_IMA_ADPCM
    std.mem.writeInt(u16, buf[o..][0..2], channels, .little);
    o += 2;
    std.mem.writeInt(u32, buf[o..][0..4], rate, .little);
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], avg_bps, .little);
    o += 4;
    std.mem.writeInt(u16, buf[o..][0..2], @intCast(block_size), .little);
    o += 2;
    std.mem.writeInt(u16, buf[o..][0..2], 4, .little);
    o += 2; // wBitsPerSample=4
    std.mem.writeInt(u16, buf[o..][0..2], 2, .little);
    o += 2; // cbSize=2
    std.mem.writeInt(u16, buf[o..][0..2], @intCast(spb), .little);
    o += 2; // nSamplesPerBlock
    @memcpy(buf[o .. o + 4], "fact");
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], 4, .little);
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], @intCast(total_per_ch), .little);
    o += 4;
    @memcpy(buf[o .. o + 4], "data");
    o += 4;
    std.mem.writeInt(u32, buf[o..][0..4], data_size, .little);
    o += 4;
    // Encode blocks
    for (0..num_blocks) |blk| {
        const blk_start = blk * spb;
        const blk_out = buf[o .. o + block_size];
        @memset(blk_out, 0);
        o += block_size;
        if (channels == 1) {
            const init_s: i16 = if (blk_start < total_per_ch) pcm[blk_start] else 0;
            var pred: i32 = init_s;
            var sidx: i32 = 0;
            std.mem.writeInt(i16, blk_out[0..2][0..2], init_s, .little);
            blk_out[2] = 0;
            blk_out[3] = 0;
            var si: usize = 1;
            var ob: usize = 4;
            while (ob < block_size) : (ob += 1) {
                const s0: i16 = if (blk_start + si < total_per_ch) pcm[blk_start + si] else 0;
                si += 1;
                const s1: i16 = if (blk_start + si < total_per_ch) pcm[blk_start + si] else 0;
                si += 1;
                blk_out[ob] = imaEncode(s0, &pred, &sidx) | (imaEncode(s1, &pred, &sidx) << 4);
            }
        } else {
            // Stereo: 8-byte header (4L + 4R), then 8-byte interleaved groups (4L + 4R)
            const il: i16 = if (blk_start < total_per_ch) pcm[blk_start * 2] else 0;
            const ir: i16 = if (blk_start < total_per_ch) pcm[blk_start * 2 + 1] else 0;
            var pl: i32 = il;
            var sl: i32 = 0;
            var pr: i32 = ir;
            var sr: i32 = 0;
            std.mem.writeInt(i16, blk_out[0..2][0..2], il, .little);
            blk_out[2] = 0;
            blk_out[3] = 0;
            std.mem.writeInt(i16, blk_out[4..6][0..2], ir, .little);
            blk_out[6] = 0;
            blk_out[7] = 0;
            var grp: usize = 0;
            var ob: usize = 8;
            while (ob + 8 <= block_size) : ({
                grp += 1;
                ob += 8;
            }) {
                const base = blk_start + 1 + grp * 8;
                for (0..4) |b| {
                    const si0 = base + b * 2;
                    const si1 = base + b * 2 + 1;
                    const l0: i16 = if (si0 < total_per_ch) pcm[si0 * 2] else 0;
                    const l1: i16 = if (si1 < total_per_ch) pcm[si1 * 2] else 0;
                    blk_out[ob + b] = imaEncode(l0, &pl, &sl) | (imaEncode(l1, &pl, &sl) << 4);
                }
                for (0..4) |b| {
                    const si0 = base + b * 2;
                    const si1 = base + b * 2 + 1;
                    const r0: i16 = if (si0 < total_per_ch) pcm[si0 * 2 + 1] else 0;
                    const r1: i16 = if (si1 < total_per_ch) pcm[si1 * 2 + 1] else 0;
                    blk_out[ob + 4 + b] = imaEncode(r0, &pr, &sr) | (imaEncode(r1, &pr, &sr) << 4);
                }
            }
        }
    }
    return buf;
}
/// Compresses a 16-bit PCM WAV loaded via AIL_WAV_info into IMA ADPCM format.
/// Allocates a new buffer which must be freed by the caller using AIL_mem_free_lock.
pub export fn AIL_compress_ADPCM(info: *const openmiles.AILSOUNDINFO, outdata: **anyopaque, outsize: *u32) callconv(.winapi) i32 {
    if (info.data_ptr == null or info.data_len == 0) return 0;
    if (info.bits != 16) return 0; // IMA ADPCM only encodes from 16-bit PCM
    const channels: u16 = @intCast(@max(1, @min(2, info.channels)));
    const pcm: [*]const i16 = @ptrCast(@alignCast(info.data_ptr.?));
    const total_per_ch: usize = @as(usize, info.data_len) / (@as(usize, channels) * 2);
    const wav = buildAdpcmWav(openmiles.global_allocator.?, pcm, total_per_ch, channels, info.rate) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    defer openmiles.global_allocator.?.free(wav);
    const out_ptr: [*]u8 = @ptrCast(std.c.malloc(wav.len) orelse return 0);
    @memcpy(out_ptr[0..wav.len], wav);
    outdata.* = out_ptr;
    outsize.* = @intCast(wav.len);
    return 1;
}
/// Decodes ADPCM (or any miniaudio-supported compressed format) WAV to a 16-bit PCM WAV.
/// If `out` is null, returns the required output buffer size in bytes without decoding.
/// Otherwise, writes the decoded WAV into the `out` buffer.
pub export fn AIL_decompress_ADPCM(data: *anyopaque, len: u32, out: ?*anyopaque) callconv(.winapi) i32 {
    const raw: []const u8 = @as([*]const u8, @ptrCast(@alignCast(data)))[0..len];
    var decoder: openmiles.ma.ma_decoder = undefined;
    var config = openmiles.ma.ma_decoder_config_init(openmiles.ma.ma_format_s16, 0, 0); // preserve channel/rate from source
    if (openmiles.ma.ma_decoder_init_memory(raw.ptr, raw.len, &config, &decoder) != openmiles.ma.MA_SUCCESS) return 0;
    defer _ = openmiles.ma.ma_decoder_uninit(&decoder);

    const channels = @as(u32, decoder.outputChannels);
    const rate = @as(u32, decoder.outputSampleRate);
    const bpf = channels * 2; // 16-bit = 2 bytes/sample

    // Decode all frames into a temporary list
    var pcm = std.ArrayListUnmanaged(u8){};
    defer pcm.deinit(openmiles.global_allocator.?);

    var length_frames: u64 = 0;
    _ = openmiles.ma.ma_decoder_get_length_in_pcm_frames(&decoder, &length_frames);
    if (length_frames > 0) {
        pcm.ensureTotalCapacity(openmiles.global_allocator.?, @intCast(length_frames * bpf)) catch {};
    }

    var chunk_buf: [4096 * 8]u8 = undefined; // up to 4096 frames × 8 bytes (4ch 16-bit)
    const chunk_frames: u64 = chunk_buf.len / @as(usize, bpf);
    while (true) {
        var fr: u64 = 0;
        _ = openmiles.ma.ma_decoder_read_pcm_frames(&decoder, &chunk_buf, chunk_frames, &fr);
        if (fr == 0) break;
        pcm.appendSlice(openmiles.global_allocator.?, chunk_buf[0..@intCast(fr * @as(u64, bpf))]) catch break;
    }
    if (pcm.items.len == 0) return 0;

    const wav = openmiles.buildWavFromPcm(openmiles.global_allocator.?, pcm.items, @intCast(channels), rate, 16) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    defer openmiles.global_allocator.?.free(wav);

    const wav_size: i32 = @intCast(wav.len);
    if (out == null) return wav_size; // size query
    @memcpy(@as([*]u8, @ptrCast(@alignCast(out.?)))[0..wav.len], wav);
    return wav_size;
}
pub export fn AIL_open_input(device: *anyopaque) callconv(.winapi) ?*openmiles.Input {
    _ = device;
    const allocator = openmiles.global_allocator orelse return null;
    const input = openmiles.Input.init(allocator) catch |err| {
        log("AIL_open_input failed: {any}\n", .{err});
        return null;
    };
    log("AIL_open_input: input={*}\n", .{input});
    return input;
}
pub export fn AIL_close_input(input_ptr: ?*openmiles.Input) callconv(.winapi) void {
    const input = input_ptr orelse return;
    log("AIL_close_input: input={*}\n", .{input});
    input.deinit();
}
pub export fn AIL_set_input_state(input_ptr: ?*openmiles.Input, state: i32) callconv(.winapi) void {
    const input = input_ptr orelse return;
    log("AIL_set_input_state: input={*}, state={d}\n", .{ input, state });
    if (state != 0) {
        input.start();
    } else {
        input.stop();
    }
}
pub export fn AIL_get_input_info(input_ptr: ?*openmiles.Input) callconv(.winapi) u32 {
    const input = input_ptr orelse return 0;
    const info = input.getInfo();
    // MSS historically returned sample count here; callers query additional info via separate paths.
    return info.samples;
}
pub export fn AIL_set_file_callbacks(open_fn: ?*anyopaque, close_fn: ?*anyopaque, read_fn: ?*anyopaque, seek_fn: ?*anyopaque) callconv(.winapi) void {
    log("AIL_set_file_callbacks\n", .{});
    openmiles.cb_file_open = if (open_fn) |f| @ptrCast(f) else null;
    openmiles.cb_file_close = if (close_fn) |f| @ptrCast(f) else null;
    openmiles.cb_file_read = if (read_fn) |f| @ptrCast(f) else null;
    openmiles.cb_file_seek = if (seek_fn) |f| @ptrCast(f) else null;
}
pub export fn AIL_set_file_async_callbacks(open_fn: ?*anyopaque, close_fn: ?*anyopaque, read_fn: ?*anyopaque, seek_fn: ?*anyopaque, callback_fn: ?*anyopaque) callconv(.winapi) void {
    log("AIL_set_file_async_callbacks\n", .{});
    // Treat async the same as sync; we always read synchronously
    openmiles.cb_file_open = if (open_fn) |f| @ptrCast(f) else null;
    openmiles.cb_file_close = if (close_fn) |f| @ptrCast(f) else null;
    openmiles.cb_file_read = if (read_fn) |f| @ptrCast(f) else null;
    openmiles.cb_file_seek = if (seek_fn) |f| @ptrCast(f) else null;
    _ = callback_fn;
}
pub export fn AIL_create_wave_synthesizer(dig_opt: ?*DigitalDriver, seq: ?*Sequence, dls: ?*anyopaque, flags: u32) callconv(.winapi) ?*openmiles.MidiDriver {
    const dig = dig_opt orelse return null;
    _ = dig;
    _ = seq;
    _ = flags;
    const driver = openmiles.MidiDriver.init(openmiles.global_allocator.?) catch |err| {
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
pub export fn AIL_destroy_wave_synthesizer(synth: *openmiles.MidiDriver) callconv(.winapi) void {
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
            .{ .name = "openmiles.AIL_open_digital_driver", .stack_size = 16 },
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
            .{ .name = "RIB_alloc_provider_handle", .stack_size = 4 },
            .{ .name = "RIB_free_provider_handle", .stack_size = 4 },
            .{ .name = "RIB_register_interface", .stack_size = 16 },
            .{ .name = "RIB_unregister_interface", .stack_size = 16 },
            .{ .name = "RIB_provider_library_handle", .stack_size = 0 },
            .{ .name = "RIB_load_application_providers", .stack_size = 4 },
            .{ .name = "RIB_enumerate_providers", .stack_size = 12 },
            .{ .name = "RIB_request_interface", .stack_size = 16 },
            .{ .name = "RIB_find_files_provider", .stack_size = 20 },
            .{ .name = "AIL_open_filter", .stack_size = 8 },
            .{ .name = "AIL_close_filter", .stack_size = 4 },
            .{ .name = "AIL_set_sample_filter", .stack_size = 12 },
            .{ .name = "AIL_filter_attribute", .stack_size = 12 },
            .{ .name = "AIL_set_filter_attribute", .stack_size = 12 },
            .{ .name = "AIL_enumerate_filters", .stack_size = 12 },
            .{ .name = "AIL_enumerate_3D_providers", .stack_size = 12 },
            .{ .name = "AIL_allocate_3D_sample_handle", .stack_size = 4 },
            .{ .name = "AIL_release_3D_sample_handle", .stack_size = 4 },
            .{ .name = "AIL_set_3D_sample_file", .stack_size = 8 },
            .{ .name = "AIL_set_3D_position", .stack_size = 16 },
            .{ .name = "AIL_set_3D_velocity", .stack_size = 20 },
            .{ .name = "AIL_set_3D_orientation", .stack_size = 28 },
            .{ .name = "AIL_set_3D_sample_distances", .stack_size = 12 },
            .{ .name = "AIL_set_listener_3D_position", .stack_size = 16 },
            .{ .name = "AIL_set_listener_3D_velocity", .stack_size = 20 },
            .{ .name = "AIL_set_listener_3D_orientation", .stack_size = 28 },
            .{ .name = "AIL_register_timer", .stack_size = 4 },
            .{ .name = "AIL_set_timer_frequency", .stack_size = 8 },
            .{ .name = "AIL_set_timer_period", .stack_size = 8 },
            .{ .name = "AIL_set_timer_user_data", .stack_size = 8 },
            .{ .name = "AIL_start_timer", .stack_size = 4 },
            .{ .name = "AIL_stop_timer", .stack_size = 4 },
            .{ .name = "AIL_release_timer_handle", .stack_size = 4 },
            .{ .name = "AIL_start_all_timers", .stack_size = 0 },
            .{ .name = "AIL_stop_all_timers", .stack_size = 0 },
            .{ .name = "AIL_quick_startup", .stack_size = 20 },
            .{ .name = "AIL_quick_shutdown", .stack_size = 0 },
            .{ .name = "AIL_quick_load", .stack_size = 4 },
            .{ .name = "AIL_quick_load_mem", .stack_size = 8 },
            .{ .name = "AIL_quick_copy", .stack_size = 4 },
            .{ .name = "AIL_quick_unload", .stack_size = 4 },
            .{ .name = "AIL_quick_play", .stack_size = 8 },
            .{ .name = "AIL_quick_stop", .stack_size = 4 },
            .{ .name = "AIL_quick_status", .stack_size = 4 },
            .{ .name = "AIL_quick_set_volume", .stack_size = 8 },
            .{ .name = "AIL_quick_set_speed", .stack_size = 8 },
            .{ .name = "AIL_quick_ms_length", .stack_size = 4 },
            .{ .name = "AIL_quick_ms_position", .stack_size = 4 },
            .{ .name = "AIL_quick_set_ms_position", .stack_size = 8 },
            .{ .name = "AIL_redbook_open", .stack_size = 4 },
            .{ .name = "AIL_redbook_close", .stack_size = 4 },
            .{ .name = "AIL_redbook_play", .stack_size = 12 },
            .{ .name = "AIL_redbook_stop", .stack_size = 4 },
            .{ .name = "AIL_redbook_pause", .stack_size = 4 },
            .{ .name = "AIL_redbook_resume", .stack_size = 4 },
            .{ .name = "AIL_redbook_status", .stack_size = 4 },
            .{ .name = "AIL_redbook_tracks", .stack_size = 4 },
            .{ .name = "AIL_open_ASI_provider", .stack_size = 8 },
            .{ .name = "AIL_close_ASI_provider", .stack_size = 4 },
            .{ .name = "AIL_ASI_provider_attribute", .stack_size = 8 },
            .{ .name = "AIL_compress_ASI", .stack_size = 16 },
            .{ .name = "AIL_decompress_ASI", .stack_size = 16 },
            .{ .name = "AIL_mem_alloc_lock", .stack_size = 4 },
            .{ .name = "AIL_mem_free_lock", .stack_size = 4 },
            // 3D Sample control
            .{ .name = "AIL_start_3D_sample", .stack_size = 4 },
            .{ .name = "AIL_stop_3D_sample", .stack_size = 4 },
            .{ .name = "AIL_resume_3D_sample", .stack_size = 4 },
            .{ .name = "AIL_end_3D_sample", .stack_size = 4 },
            .{ .name = "AIL_3D_sample_status", .stack_size = 4 },
            .{ .name = "AIL_3D_sample_volume", .stack_size = 4 },
            .{ .name = "AIL_set_3D_sample_volume", .stack_size = 8 },
            .{ .name = "AIL_3D_sample_loop_count", .stack_size = 4 },
            .{ .name = "AIL_set_3D_sample_loop_count", .stack_size = 8 },
            .{ .name = "AIL_3D_sample_playback_rate", .stack_size = 4 },
            .{ .name = "AIL_set_3D_sample_playback_rate", .stack_size = 8 },
            .{ .name = "AIL_3D_sample_offset", .stack_size = 4 },
            .{ .name = "AIL_set_3D_sample_offset", .stack_size = 8 },
            .{ .name = "AIL_3D_sample_length", .stack_size = 4 },
            .{ .name = "AIL_3D_sample_ms_position", .stack_size = 12 },
            .{ .name = "AIL_set_3D_sample_ms_position", .stack_size = 8 },
            .{ .name = "AIL_register_3D_EOS_callback", .stack_size = 8 },
            .{ .name = "AIL_active_3D_sample_count", .stack_size = 4 },
            .{ .name = "AIL_3D_user_data", .stack_size = 8 },
            .{ .name = "AIL_set_3D_user_data", .stack_size = 12 },
            .{ .name = "AIL_set_3D_sample_info", .stack_size = 8 },
            .{ .name = "AIL_set_3D_sample_loop_block", .stack_size = 12 },
            .{ .name = "AIL_set_3D_sample_cone", .stack_size = 16 },
            .{ .name = "AIL_3D_sample_cone", .stack_size = 16 },
            .{ .name = "AIL_set_3D_sample_effects_level", .stack_size = 8 },
            .{ .name = "AIL_3D_sample_effects_level", .stack_size = 4 },
            .{ .name = "AIL_set_3D_sample_obstruction", .stack_size = 8 },
            .{ .name = "AIL_3D_sample_obstruction", .stack_size = 4 },
            .{ .name = "AIL_set_3D_sample_occlusion", .stack_size = 8 },
            .{ .name = "AIL_3D_sample_occlusion", .stack_size = 4 },
            .{ .name = "AIL_set_3D_sample_preference", .stack_size = 12 },
            .{ .name = "AIL_3D_sample_attribute", .stack_size = 12 },
            .{ .name = "AIL_auto_update_3D_position", .stack_size = 8 },
            .{ .name = "AIL_update_3D_position", .stack_size = 8 },
            .{ .name = "AIL_set_3D_velocity_vector", .stack_size = 16 },
            // 3D Environment
            .{ .name = "AIL_set_3D_distance_factor", .stack_size = 8 },
            .{ .name = "AIL_3D_distance_factor", .stack_size = 4 },
            .{ .name = "AIL_set_3D_doppler_factor", .stack_size = 8 },
            .{ .name = "AIL_3D_doppler_factor", .stack_size = 4 },
            .{ .name = "AIL_set_3D_rolloff_factor", .stack_size = 8 },
            .{ .name = "AIL_3D_rolloff_factor", .stack_size = 4 },
            .{ .name = "AIL_set_3D_room_type", .stack_size = 8 },
            .{ .name = "AIL_3D_room_type", .stack_size = 4 },
            .{ .name = "AIL_set_3D_speaker_type", .stack_size = 8 },
            .{ .name = "AIL_3D_speaker_type", .stack_size = 4 },
            // 3D Provider/Listener/Object
            .{ .name = "AIL_open_3D_provider", .stack_size = 8 },
            .{ .name = "AIL_close_3D_provider", .stack_size = 4 },
            .{ .name = "AIL_open_3D_listener", .stack_size = 4 },
            .{ .name = "AIL_close_3D_listener", .stack_size = 4 },
            .{ .name = "AIL_open_3D_object", .stack_size = 4 },
            .{ .name = "AIL_close_3D_object", .stack_size = 4 },
            .{ .name = "AIL_3D_provider_attribute", .stack_size = 12 },
            .{ .name = "AIL_set_3D_provider_preference", .stack_size = 12 },
            .{ .name = "AIL_enumerate_3D_provider_attributes", .stack_size = 12 },
            .{ .name = "AIL_enumerate_3D_sample_attributes", .stack_size = 12 },
            .{ .name = "AIL_3D_orientation", .stack_size = 28 },
            .{ .name = "AIL_3D_position", .stack_size = 16 },
            .{ .name = "AIL_3D_velocity", .stack_size = 20 },
            .{ .name = "AIL_3D_sample_distances", .stack_size = 12 },
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
            .{ .name = "AIL_enumerate_filter_attributes", .stack_size = 12 },
            .{ .name = "AIL_enumerate_filter_sample_attributes", .stack_size = 12 },
            .{ .name = "AIL_filter_sample_attribute", .stack_size = 12 },
            .{ .name = "AIL_set_filter_sample_preference", .stack_size = 12 },
            .{ .name = "AIL_set_filter_DLS_preference", .stack_size = 12 },
            .{ .name = "AIL_set_filter_preference", .stack_size = 12 },
            .{ .name = "AIL_filter_DLS_attribute", .stack_size = 12 },
            .{ .name = "AIL_filter_DLS_with_XMI", .stack_size = 24 },
            // Quick API extras
            .{ .name = "AIL_quick_halt", .stack_size = 4 },
            .{ .name = "AIL_quick_set_reverb", .stack_size = 16 },
            .{ .name = "AIL_quick_load_and_play", .stack_size = 12 },
            .{ .name = "AIL_quick_type", .stack_size = 4 },
            .{ .name = "AIL_quick_handles", .stack_size = 12 },
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
            .{ .name = "RIB_error", .stack_size = 0 },
            .{ .name = "RIB_find_file_provider", .stack_size = 12 },
            .{ .name = "RIB_load_provider_library", .stack_size = 4 },
            .{ .name = "RIB_free_provider_library", .stack_size = 4 },
            .{ .name = "RIB_request_interface_entry", .stack_size = 16 },
            .{ .name = "RIB_enumerate_interface", .stack_size = 20 },
            .{ .name = "RIB_type_string", .stack_size = 4 },
            .{ .name = "RIB_provider_system_data", .stack_size = 8 },
            .{ .name = "RIB_provider_user_data", .stack_size = 8 },
            .{ .name = "RIB_set_provider_system_data", .stack_size = 12 },
            .{ .name = "RIB_set_provider_user_data", .stack_size = 12 },
            .{ .name = "RIB_find_file_dec_provider", .stack_size = 20 },
            .{ .name = "RIB_find_provider", .stack_size = 12 },
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
            .{ .name = "AIL_mem_use_malloc", .stack_size = 4 },
            .{ .name = "AIL_mem_use_free", .stack_size = 4 },
            .{ .name = "AIL_set_mem_callbacks", .stack_size = 8 },
            .{ .name = "AIL_compress_ADPCM", .stack_size = 12 },
            .{ .name = "AIL_decompress_ADPCM", .stack_size = 12 },
            .{ .name = "AIL_open_input", .stack_size = 4 },
            .{ .name = "AIL_close_input", .stack_size = 4 },
            .{ .name = "AIL_set_input_state", .stack_size = 8 },
            .{ .name = "AIL_get_input_info", .stack_size = 4 },
            .{ .name = "AIL_set_file_callbacks", .stack_size = 16 },
            .{ .name = "AIL_set_file_async_callbacks", .stack_size = 20 },
            .{ .name = "AIL_set_DLS_processor", .stack_size = 12 },
            .{ .name = "AIL_create_wave_synthesizer", .stack_size = 16 },
            .{ .name = "AIL_destroy_wave_synthesizer", .stack_size = 4 },
            .{ .name = "AIL_waveOutClose", .stack_size = 4 },
            .{ .name = "AIL_request_EOB_ASI_reset", .stack_size = 8 },
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
        };
        for (targets) |t| {
            const canonical = std.fmt.comptimePrint("{s}@{d}", .{ t.name, t.stack_size });
            asm (std.fmt.comptimePrint(".section .drectve\n .ascii \" /EXPORT:{s}={s} /EXPORT:_{s}={s} /EXPORT:_{s}={s}\"\n .text\n", .{ t.name, canonical, t.name, canonical, canonical, canonical }));
        }
        // Manual exports for problematic symbols
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

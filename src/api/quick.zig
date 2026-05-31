const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;

const DigitalDriver = openmiles.DigitalDriver;
const Sample = openmiles.Sample;

pub fn AIL_quick_startup(use_dig: i32, use_midi: i32, rate: u32, bits: i32, channels: i32) callconv(.winapi) void {
    log("AIL_quick_startup(use_dig={d}, use_midi={d}, rate={d}, bits={d}, channels={d})\n", .{ use_dig, use_midi, rate, bits, channels });
    // Ensure the startup provider exists so plugins can call RIB_provider_library_handle()
    // to register themselves (AIL_startup is not always called when using the Quick API).
    openmiles.startup();
    if (use_dig != 0) _ = openmiles.openDigitalDriver(rate, bits, channels);
    if (use_midi != 0) _ = openmiles.openMidiDriver();
}
pub fn AIL_quick_shutdown() callconv(.winapi) void {
    log("AIL_quick_shutdown()\n", .{});
    if (openmiles.last_digital_driver) |d| openmiles.closeDigitalDriver(d);
    if (openmiles.last_midi_driver) |m| openmiles.closeMidiDriver(m);
}
pub fn AIL_quick_load(filename: [*:0]const u8) callconv(.winapi) ?*Sample {
    log("AIL_quick_load(filename={s})\n", .{filename});
    openmiles.clearLastError();
    if (openmiles.last_digital_driver) |d| {
        const s = openmiles.Sample.init(d) catch |err| {
            log("Error: {any}\n", .{err});
            openmiles.setLastError("Failed to allocate sample for quick load");
            return null;
        };
        if (openmiles.cb_file_open != null) {
            const buf = openmiles.fileCallbackReadAll(filename) catch null;
            if (buf) |b| {
                s.loadFromOwnedMemory(b) catch {
                    openmiles.global_allocator.free(b);
                    openmiles.setLastError("Failed to load quick sample from memory");
                    s.deinit();
                    return null;
                };
                return s;
            }
        }
        s.loadFromFile(std.mem.span(filename)) catch {
            openmiles.setLastError("Failed to load quick sample file");
            s.deinit();
            return null;
        };
        return s;
    }
    return null;
}
pub fn AIL_quick_load_mem(data: *anyopaque, size: u32) callconv(.winapi) ?*Sample {
    log("AIL_quick_load_mem(data={*}, size={d})\n", .{ data, size });
    openmiles.clearLastError();
    if (openmiles.last_digital_driver) |d| {
        const s = openmiles.Sample.init(d) catch |err| {
            log("Error: {any}\n", .{err});
            openmiles.setLastError("Failed to allocate sample for quick load");
            return null;
        };
        s.load(data, @intCast(@min(size, @as(u32, std.math.maxInt(i32))))) catch {
            openmiles.setLastError("Failed to load quick sample from memory");
            s.deinit();
            return null;
        };
        return s;
    }
    return null;
}
// AIL_quick_load_named_mem(void const *mem, char const *filename, U32 size) -> HAUDIO
// Like AIL_quick_load_mem, but the filename supplies a format hint. Our loader
// auto-detects the format from the data, so the name is advisory only.
pub fn AIL_quick_load_named_mem(data: ?*anyopaque, filename: ?[*:0]const u8, size: u32) callconv(.winapi) ?*Sample {
    if (filename) |f| {
        log("AIL_quick_load_named_mem(data={*}, filename={s}, size={d})\n", .{ data orelse undefined, f, size });
    } else {
        log("AIL_quick_load_named_mem(data={*}, filename=null, size={d})\n", .{ data orelse undefined, size });
    }
    const d = data orelse return null;
    return AIL_quick_load_mem(d, size);
}
pub fn AIL_quick_copy(s_opt: ?*Sample) callconv(.winapi) ?*Sample {
    const s = s_opt orelse return null;
    log("AIL_quick_copy(s={*})\n", .{s});
    openmiles.clearLastError();
    if (openmiles.last_digital_driver) |d| {
        const new_s = openmiles.Sample.init(d) catch |err| {
            log("Error: {any}\n", .{err});
            openmiles.setLastError("Failed to allocate sample for quick copy");
            return null;
        };
        if (s.owned_buffer) |buf| {
            new_s.loadFromMemory(buf, true) catch {
                openmiles.setLastError("Failed to copy sample data");
                new_s.deinit();
                return null;
            };
        }
        return new_s;
    }
    return null;
}
pub fn AIL_quick_unload(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_quick_unload(s={*})\n", .{s});
    s.deinit();
}
pub fn AIL_quick_play(s_opt: ?*Sample, loop_count: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_quick_play(s={*}, loop_count={d})\n", .{ s, loop_count });
    s.setLoopCount(loop_count);
    s.start();
}
pub fn AIL_quick_stop(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_quick_stop(s={*})\n", .{s});
    s.stop();
}
pub fn AIL_quick_status(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    // The Quick API uses its own QSTAT_* enum (DONE=1, LOADED=2, PLAYING=3),
    // NOT the SMP_* sample-status bitmask (FREE=1/DONE=2/PLAYING=4/STOPPED=8).
    // A loaded-but-never-played sample is SMP_DONE at the sample level, but the
    // Quick API reports it as QSTAT_LOADED; only after it has actually played and
    // finished is it QSTAT_DONE.
    return switch (s.status()) {
        .playing, .playing_but_released => 3, // QSTAT_PLAYING
        .done => if (s.has_played) 1 else 2, // QSTAT_DONE (finished) vs QSTAT_LOADED (never played)
        .free, .stopped => 2, // QSTAT_LOADED (loaded, ready to (re)play)
    };
}
// v3-v6: S32 volume/extravol on the legacy 0..127 scale.
pub fn AIL_quick_set_volume(s_opt: ?*Sample, volume: i32, extravol: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_quick_set_volume(s={*}, volume={d}, extravol={d})\n", .{ s, volume, extravol });
    // MSS scales the primary 0..127 volume by the secondary 0..127 extravol.
    const ev = std.math.clamp(extravol, 0, 127);
    const scaled: i32 = @intCast(@divTrunc(@as(i64, std.math.clamp(volume, 0, 127)) * ev, 127));
    s.setVolume(scaled);
}
// v7+: the Miles-7 float API uses F32 volume/extravol on the 0.0..1.0 scale.
pub fn AIL_quick_set_volume_f32(s_opt: ?*Sample, volume: f32, extravol: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_quick_set_volume_f32(s={*}, volume={d}, extravol={d})\n", .{ s, volume, extravol });
    const v = std.math.clamp(volume, 0.0, 1.0) * std.math.clamp(extravol, 0.0, 1.0);
    s.setVolume(@intFromFloat(v * 127.0));
}
pub fn AIL_quick_set_speed(s_opt: ?*Sample, rate: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_quick_set_speed(s={*}, rate={d})\n", .{ s, rate });
    s.setPlaybackRate(rate);
}
pub fn AIL_quick_ms_length(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return s.getMsPosition().total;
}
pub fn AIL_quick_ms_position(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return s.getMsPosition().current;
}
pub fn AIL_quick_set_ms_position(s_opt: ?*Sample, ms: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_quick_set_ms_position(s={*}, ms={d})\n", .{ s, ms });
    s.setMsPosition(ms);
}
pub fn AIL_quick_halt(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_quick_halt(s={*})\n", .{s});
    // Real MSS AIL_quick_halt calls AIL_end_sample (stop + mark done) and then
    // clears the HAUDIO's handle reference — it does NOT free the sample. The
    // backing handle stays valid so the title can reload/replay it. Freeing
    // here would dangle every later AIL_quick_* call on the same handle.
    s.end();
}
pub fn AIL_quick_set_reverb(s_opt: ?*Sample, room_type: f32, level: f32, reflect_time: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setReverb(room_type, level, reflect_time);
}
pub fn AIL_quick_load_and_play(filename: [*:0]const u8, loop_count: i32, start_paused: i32) callconv(.winapi) ?*Sample {
    openmiles.clearLastError();
    if (openmiles.last_digital_driver) |d| {
        const s = openmiles.Sample.init(d) catch |err| {
            log("Error: {any}\n", .{err});
            openmiles.setLastError("Failed to allocate sample for quick load and play");
            return null;
        };
        loaded: {
            if (openmiles.cb_file_open != null) {
                const buf = openmiles.fileCallbackReadAll(filename) catch null;
                if (buf) |b| {
                    s.loadFromOwnedMemory(b) catch {
                        openmiles.global_allocator.free(b);
                        break :loaded;
                    };
                    s.setLoopCount(loop_count);
                    if (start_paused == 0) s.start();
                    return s;
                }
            }
            s.loadFromFile(std.mem.span(filename)) catch break :loaded;
            s.setLoopCount(loop_count);
            if (start_paused == 0) s.start();
            return s;
        }
        openmiles.setLastError("Failed to load quick sample file");
        s.deinit();
        return null;
    }
    return null;
}
pub fn AIL_quick_type(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    _ = s;
    return 1; // AILFMT_PCM
}
pub fn AIL_quick_handles(quick_ptr: ?*?*Sample, dig_ptr: ?*?*DigitalDriver, midi_ptr: ?*?*openmiles.MidiDriver) callconv(.winapi) void {
    if (quick_ptr) |p| p.* = null;
    if (dig_ptr) |p| p.* = openmiles.last_digital_driver;
    if (midi_ptr) |p| p.* = openmiles.last_midi_driver;
}
// MSS 3.x form: 2 args @8 (digital + MIDI driver handles, no DLS slot).
// Exported as _AIL_quick_handles@8 for v3 only.
pub fn AIL_quick_handles_v3(dig_ptr: ?*?*DigitalDriver, midi_ptr: ?*?*openmiles.MidiDriver) callconv(.winapi) void {
    if (dig_ptr) |p| p.* = openmiles.last_digital_driver;
    if (midi_ptr) |p| p.* = openmiles.last_midi_driver;
}

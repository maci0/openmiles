const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;

const DigitalDriver = openmiles.DigitalDriver;
const Sample = openmiles.Sample;

pub export fn AIL_quick_startup(use_dig: i32, use_midi: i32, rate: u32, bits: i32, channels: i32) callconv(.winapi) void {
    log("AIL_quick_startup(use_dig={d}, use_midi={d}, rate={d}, bits={d}, channels={d})\n", .{ use_dig, use_midi, rate, bits, channels });
    // Ensure the startup provider exists so plugins can call RIB_provider_library_handle()
    // to register themselves (AIL_startup is not always called when using the Quick API).
    openmiles.startup();
    if (use_dig != 0) _ = openmiles.openDigitalDriver(rate, bits, channels);
    if (use_midi != 0) _ = openmiles.openMidiDriver();
}
pub export fn AIL_quick_shutdown() callconv(.winapi) void {
    log("AIL_quick_shutdown()\n", .{});
    if (openmiles.last_digital_driver) |d| openmiles.closeDigitalDriver(d);
    if (openmiles.last_midi_driver) |m| openmiles.closeMidiDriver(m);
}
pub export fn AIL_quick_load(filename: [*:0]const u8) callconv(.winapi) ?*Sample {
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
pub export fn AIL_quick_load_mem(data: *anyopaque, size: u32) callconv(.winapi) ?*Sample {
    log("AIL_quick_load_mem(data={*}, size={d})\n", .{ data, size });
    openmiles.clearLastError();
    if (openmiles.last_digital_driver) |d| {
        const s = openmiles.Sample.init(d) catch |err| {
            log("Error: {any}\n", .{err});
            openmiles.setLastError("Failed to allocate sample for quick load");
            return null;
        };
        s.load(data, @intCast(size)) catch {
            openmiles.setLastError("Failed to load quick sample from memory");
            s.deinit();
            return null;
        };
        return s;
    }
    return null;
}
pub export fn AIL_quick_copy(s_opt: ?*Sample) callconv(.winapi) ?*Sample {
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
pub export fn AIL_quick_unload(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_quick_unload(s={*})\n", .{s});
    s.deinit();
}
pub export fn AIL_quick_play(s_opt: ?*Sample, loop_count: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_quick_play(s={*}, loop_count={d})\n", .{ s, loop_count });
    s.setLoopCount(loop_count);
    s.start();
}
pub export fn AIL_quick_stop(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_quick_stop(s={*})\n", .{s});
    s.stop();
}
pub export fn AIL_quick_status(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return @intCast(@intFromEnum(s.status()));
}
pub export fn AIL_quick_set_volume(s_opt: ?*Sample, volume: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_quick_set_volume(s={*}, volume={d})\n", .{ s, volume });
    s.setVolume(volume);
}
pub export fn AIL_quick_set_speed(s_opt: ?*Sample, rate: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_quick_set_speed(s={*}, rate={d})\n", .{ s, rate });
    s.setPlaybackRate(rate);
}
pub export fn AIL_quick_ms_length(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return s.getMsPosition().total;
}
pub export fn AIL_quick_ms_position(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return s.getMsPosition().current;
}
pub export fn AIL_quick_set_ms_position(s_opt: ?*Sample, ms: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    log("AIL_quick_set_ms_position(s={*}, ms={d})\n", .{ s, ms });
    s.setMsPosition(ms);
}
pub export fn AIL_quick_halt(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.stop();
    s.deinit();
}
pub export fn AIL_quick_set_reverb(s_opt: ?*Sample, room_type: f32, level: f32, reflect_time: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setReverb(room_type, level, reflect_time);
}
pub export fn AIL_quick_load_and_play(filename: [*:0]const u8, loop_count: i32, start_paused: i32) callconv(.winapi) ?*Sample {
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
pub export fn AIL_quick_type(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    _ = s;
    return 1; // AILFMT_PCM
}
pub export fn AIL_quick_handles(quick_ptr: ?*?*Sample, dig_ptr: ?*?*DigitalDriver, midi_ptr: ?*?*openmiles.MidiDriver) callconv(.winapi) void {
    if (quick_ptr) |p| p.* = null;
    if (dig_ptr) |p| p.* = openmiles.last_digital_driver;
    if (midi_ptr) |p| p.* = openmiles.last_midi_driver;
}

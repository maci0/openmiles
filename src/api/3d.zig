const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;
const DigitalDriver = openmiles.DigitalDriver;
const Provider = openmiles.Provider;

const deg2rad = openmiles.deg2rad;

pub export fn AIL_enumerate_3D_providers(next: *?*anyopaque, handle: *?*Provider, name: *[*:0]const u8) callconv(.winapi) i32 {
    log("AIL_enumerate_3D_providers(next={*}, handle={*}, name={*})\n", .{ next, handle, name });
    const idx: usize = if (next.*) |v| @intFromPtr(v) else 0;
    if (idx == 0 and openmiles.startup_provider != null) {
        handle.* = openmiles.startup_provider;
        name.* = "OpenMiles Software 3D";
        next.* = @ptrFromInt(1);
        return 1;
    }
    next.* = null;
    handle.* = null;
    return 0;
}
pub export fn AIL_allocate_3D_sample_handle(driver_opt: ?*DigitalDriver) callconv(.winapi) ?*anyopaque {
    const driver = driver_opt orelse return null;
    log("AIL_allocate_3D_sample_handle(driver={*})\n", .{driver});
    const s = openmiles.Sample3D.init(driver) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
    return @ptrCast(s);
}
pub export fn AIL_release_3D_sample_handle(s: ?*anyopaque) callconv(.winapi) void {
    const p = s orelse return;
    log("AIL_release_3D_sample_handle(s={*})\n", .{p});
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.deinit();
}
pub export fn AIL_set_3D_sample_file(s: ?*anyopaque, data: ?*anyopaque) callconv(.winapi) i32 {
    const p = s orelse return 0;
    const d = data orelse return 0;
    log("AIL_set_3D_sample_file(s={*}, data={*})\n", .{ p, d });
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    const raw: [*]const u8 = @ptrCast(@alignCast(d));
    sample.loadFromUnownedPointer(raw) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    return 1;
}
// MSS uses the same function for both listener and sample positioning; the obj handle determines which.
pub export fn AIL_set_3D_position(obj: ?*anyopaque, x: f32, y: f32, z: f32) callconv(.winapi) void {
    const o = obj orelse return;
    if (openmiles.isKnownDriver(o)) {
        const dig: *DigitalDriver = @ptrCast(@alignCast(o));
        dig.setListenerPosition(x, y, z);
    } else {
        const sample: *openmiles.Sample3D = @ptrCast(@alignCast(o));
        sample.setPosition(x, y, z);
    }
}
pub export fn AIL_set_3D_velocity(obj: ?*anyopaque, x: f32, y: f32, z: f32, factor: f32) callconv(.winapi) void {
    const o = obj orelse return;
    if (openmiles.isKnownDriver(o)) {
        const dig: *DigitalDriver = @ptrCast(@alignCast(o));
        dig.setListenerVelocity(x * factor, y * factor, z * factor);
    } else {
        const sample: *openmiles.Sample3D = @ptrCast(@alignCast(o));
        sample.setVelocity(x * factor, y * factor, z * factor);
    }
}
pub export fn AIL_set_3D_orientation(obj: ?*anyopaque, fx: f32, fy: f32, fz: f32, ux: f32, uy: f32, uz: f32) callconv(.winapi) void {
    const o = obj orelse return;
    if (openmiles.isKnownDriver(o)) {
        const dig: *DigitalDriver = @ptrCast(@alignCast(o));
        dig.setListenerDirection(fx, fy, fz);
        dig.setListenerWorldUp(ux, uy, uz);
    } else {
        const sample: *openmiles.Sample3D = @ptrCast(@alignCast(o));
        sample.setOrientation(fx, fy, fz, ux, uy, uz);
    }
}
pub export fn AIL_set_3D_sample_distances(s: ?*anyopaque, max_dist: f32, min_dist: f32) callconv(.winapi) void {
    const p = s orelse return;
    log("AIL_set_3D_sample_distances(s={*}, max={d}, min={d})\n", .{ p, max_dist, min_dist });
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setMinMaxDistance(min_dist, max_dist);
}
pub export fn AIL_set_listener_3D_position(dig_opt: ?*DigitalDriver, x: f32, y: f32, z: f32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    dig.setListenerPosition(x, y, z);
}
pub export fn AIL_set_listener_3D_velocity(dig_opt: ?*DigitalDriver, x: f32, y: f32, z: f32, factor: f32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    dig.setListenerVelocity(x * factor, y * factor, z * factor);
}
pub export fn AIL_set_listener_3D_orientation(dig_opt: ?*DigitalDriver, fx: f32, fy: f32, fz: f32, ux: f32, uy: f32, uz: f32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    dig.setListenerDirection(fx, fy, fz);
    dig.setListenerWorldUp(ux, uy, uz);
}
pub export fn AIL_start_3D_sample(s: ?*anyopaque) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.start();
}
pub export fn AIL_stop_3D_sample(s: ?*anyopaque) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.pause();
}
pub export fn AIL_resume_3D_sample(s: ?*anyopaque) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.resumePlayback();
}
pub export fn AIL_end_3D_sample(s: ?*anyopaque) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.end();
}
pub export fn AIL_3D_sample_status(s: ?*anyopaque) callconv(.winapi) u32 {
    const p = s orelse return 0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return @intFromEnum(sample.status());
}
pub export fn AIL_3D_sample_volume(s: ?*anyopaque) callconv(.winapi) i32 {
    const p = s orelse return 0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return sample.original_volume;
}
pub export fn AIL_set_3D_sample_volume(s: ?*anyopaque, volume: i32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setVolume(volume);
}
pub export fn AIL_3D_sample_loop_count(s: ?*anyopaque) callconv(.winapi) i32 {
    const p = s orelse return 0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return sample.loop_count;
}
pub export fn AIL_set_3D_sample_loop_count(s: ?*anyopaque, count: i32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setLoopCount(count);
}
pub export fn AIL_3D_sample_playback_rate(s: ?*anyopaque) callconv(.winapi) i32 {
    const p = s orelse return 0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return @intFromFloat(sample.target_rate orelse 44100.0);
}
pub export fn AIL_set_3D_sample_playback_rate(s: ?*anyopaque, rate: i32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setPlaybackRate(rate);
}
pub export fn AIL_3D_sample_offset(s: ?*anyopaque) callconv(.winapi) u32 {
    const p = s orelse return 0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return sample.getOffset();
}
pub export fn AIL_set_3D_sample_offset(s: ?*anyopaque, offset: u32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setOffset(offset);
}
pub export fn AIL_3D_sample_length(s: ?*anyopaque) callconv(.winapi) u32 {
    const p = s orelse return 0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return sample.getLength();
}
pub export fn AIL_3D_sample_ms_position(s: ?*anyopaque, total_ms: ?*i32, current_ms: ?*i32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    const pos = sample.getMsPosition();
    if (total_ms) |t| t.* = pos.total;
    if (current_ms) |c| c.* = pos.current;
}
pub export fn AIL_set_3D_sample_ms_position(s: ?*anyopaque, ms: i32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setMsPosition(ms);
}
pub export fn AIL_register_3D_EOS_callback(s: ?*anyopaque, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const p = s orelse return null;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    const prev: ?*anyopaque = @ptrFromInt(sample.eos_callback);
    sample.eos_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_active_3D_sample_count(dig_opt: ?*DigitalDriver) callconv(.winapi) u32 {
    const dig = dig_opt orelse return 0;
    return dig.get3DActiveSampleCount();
}
pub export fn AIL_3D_user_data(s: ?*anyopaque, index: i32) callconv(.winapi) u32 {
    const p = s orelse return 0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    const idx: usize = @intCast(@min(@max(index, 0), 7));
    return sample.user_data[idx];
}
pub export fn AIL_set_3D_user_data(s: ?*anyopaque, index: i32, value: u32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    const idx: usize = @intCast(@min(@max(index, 0), 7));
    sample.user_data[idx] = value;
}
pub export fn AIL_set_3D_sample_info(s: ?*anyopaque, info: ?*anyopaque) callconv(.winapi) i32 {
    const p = s orelse return 0;
    const i = info orelse return 0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    const si: *openmiles.AILSOUNDINFO = @ptrCast(@alignCast(i));
    if (si.data_ptr == null or si.data_len == 0) return 0;
    const data: [*]const u8 = @ptrCast(si.data_ptr.?);
    const channels: u16 = @intCast(@max(1, si.channels));
    const bits: u16 = @intCast(if (si.bits > 0) si.bits else 16);
    sample.loadFromPcm(data[0..si.data_len], channels, si.rate, bits) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    return 1;
}
pub export fn AIL_set_3D_sample_loop_block(s: ?*anyopaque, loop_start: i32, loop_end: i32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setLoopBlock(loop_start, loop_end);
}
pub export fn AIL_set_3D_sample_cone(s: ?*anyopaque, inner_angle: f32, outer_angle: f32, outer_volume: f32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.cone_inner_rad = inner_angle * openmiles.deg2rad;
    sample.cone_outer_rad = outer_angle * openmiles.deg2rad;
    sample.cone_outer_volume = outer_volume;
    sample.applyCone();
}
pub export fn AIL_3D_sample_cone(s: ?*anyopaque, inner_angle: ?*f32, outer_angle: ?*f32, outer_volume: ?*f32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    if (inner_angle) |a| a.* = sample.cone_inner_rad / openmiles.deg2rad;
    if (outer_angle) |a| a.* = sample.cone_outer_rad / openmiles.deg2rad;
    if (outer_volume) |a| a.* = sample.cone_outer_volume;
}
pub export fn AIL_set_3D_sample_effects_level(s: ?*anyopaque, effects_level: f32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.effects_level = @min(1.0, @max(0.0, effects_level));
}
pub export fn AIL_3D_sample_effects_level(s: ?*anyopaque) callconv(.winapi) f32 {
    const p = s orelse return 0.0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return sample.effects_level;
}
pub export fn AIL_set_3D_sample_obstruction(s: ?*anyopaque, obstruction: f32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setObstruction(obstruction);
}
pub export fn AIL_3D_sample_obstruction(s: ?*anyopaque) callconv(.winapi) f32 {
    const p = s orelse return 0.0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return sample.obstruction;
}
pub export fn AIL_set_3D_sample_occlusion(s: ?*anyopaque, occlusion: f32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setOcclusion(occlusion);
}
pub export fn AIL_3D_sample_occlusion(s: ?*anyopaque) callconv(.winapi) f32 {
    const p = s orelse return 0.0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return sample.occlusion;
}
pub export fn AIL_set_3D_sample_preference(s: ?*anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    const n = std.mem.span(name);
    if (std.mem.eql(u8, n, "Obstruction")) {
        const v: *const f32 = @ptrCast(@alignCast(val));
        sample.setObstruction(v.*);
    } else if (std.mem.eql(u8, n, "Occlusion")) {
        const v: *const f32 = @ptrCast(@alignCast(val));
        sample.setOcclusion(v.*);
    } else if (std.mem.eql(u8, n, "Effects level")) {
        const v: *const f32 = @ptrCast(@alignCast(val));
        sample.effects_level = v.*;
    } else if (std.mem.eql(u8, n, "Position")) {
        const v: *const [3]f32 = @ptrCast(@alignCast(val));
        sample.setPosition(v.*[0], v.*[1], v.*[2]);
    } else if (std.mem.eql(u8, n, "Velocity")) {
        const v: *const [4]f32 = @ptrCast(@alignCast(val));
        sample.setVelocity(v.*[0], v.*[1], v.*[2]);
    } else if (std.mem.eql(u8, n, "Orientation")) {
        const v: *const [6]f32 = @ptrCast(@alignCast(val));
        sample.setOrientation(v.*[0], v.*[1], v.*[2], v.*[3], v.*[4], v.*[5]);
    } else if (std.mem.eql(u8, n, "Frequency") or std.mem.eql(u8, n, "Playback rate")) {
        const v: *const i32 = @ptrCast(@alignCast(val));
        sample.setPlaybackRate(v.*);
    } else if (std.mem.eql(u8, n, "Volume")) {
        const v: *const i32 = @ptrCast(@alignCast(val));
        sample.setVolume(v.*);
    } else if (std.mem.eql(u8, n, "Minimum distance")) {
        const v: *const f32 = @ptrCast(@alignCast(val));
        sample.min_distance = v.*;
        if (sample.is_initialized) openmiles.ma.ma_sound_set_min_distance(&sample.sound, v.*);
    } else if (std.mem.eql(u8, n, "Maximum distance")) {
        const v: *const f32 = @ptrCast(@alignCast(val));
        sample.max_distance = v.*;
        if (sample.is_initialized) openmiles.ma.ma_sound_set_max_distance(&sample.sound, v.*);
    } else if (std.mem.eql(u8, n, "Cone inner angle")) {
        const v: *const f32 = @ptrCast(@alignCast(val));
        sample.cone_inner_rad = v.* * openmiles.deg2rad;
        sample.applyCone();
    } else if (std.mem.eql(u8, n, "Cone outer angle")) {
        const v: *const f32 = @ptrCast(@alignCast(val));
        sample.cone_outer_rad = v.* * openmiles.deg2rad;
        sample.applyCone();
    } else if (std.mem.eql(u8, n, "Cone outer volume")) {
        const v: *const f32 = @ptrCast(@alignCast(val));
        sample.cone_outer_volume = v.*;
        sample.applyCone();
    } else if (std.mem.eql(u8, n, "Loop count")) {
        const v: *const i32 = @ptrCast(@alignCast(val));
        sample.setLoopCount(v.*);
    }
}
pub export fn AIL_3D_sample_attribute(s: ?*anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const sp = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(sp));
    const n = std.mem.span(name);
    if (std.mem.eql(u8, n, "Obstruction")) {
        const v: *f32 = @ptrCast(@alignCast(val));
        v.* = sample.obstruction;
    } else if (std.mem.eql(u8, n, "Occlusion")) {
        const v: *f32 = @ptrCast(@alignCast(val));
        v.* = sample.occlusion;
    } else if (std.mem.eql(u8, n, "Effects level")) {
        const v: *f32 = @ptrCast(@alignCast(val));
        v.* = sample.effects_level;
    } else if (std.mem.eql(u8, n, "Position")) {
        const v: *[3]f32 = @ptrCast(@alignCast(val));
        if (sample.is_initialized) {
            const pos = openmiles.ma.ma_sound_get_position(&sample.sound);
            v.*[0] = pos.x;
            v.*[1] = pos.y;
            v.*[2] = pos.z;
        } else {
            v.*[0] = sample.pos_x;
            v.*[1] = sample.pos_y;
            v.*[2] = sample.pos_z;
        }
    } else if (std.mem.eql(u8, n, "Velocity")) {
        const v: *[4]f32 = @ptrCast(@alignCast(val));
        v.*[0] = sample.velocity_x;
        v.*[1] = sample.velocity_y;
        v.*[2] = sample.velocity_z;
        v.*[3] = 1.0;
    } else if (std.mem.eql(u8, n, "Orientation")) {
        const v: *[6]f32 = @ptrCast(@alignCast(val));
        v.*[0] = sample.orient_fx;
        v.*[1] = sample.orient_fy;
        v.*[2] = sample.orient_fz;
        v.*[3] = sample.orient_ux;
        v.*[4] = sample.orient_uy;
        v.*[5] = sample.orient_uz;
    } else if (std.mem.eql(u8, n, "Minimum distance")) {
        const v: *f32 = @ptrCast(@alignCast(val));
        v.* = if (sample.is_initialized) openmiles.ma.ma_sound_get_min_distance(&sample.sound) else sample.min_distance;
    } else if (std.mem.eql(u8, n, "Maximum distance")) {
        const v: *f32 = @ptrCast(@alignCast(val));
        v.* = if (sample.is_initialized) openmiles.ma.ma_sound_get_max_distance(&sample.sound) else sample.max_distance;
    } else if (std.mem.eql(u8, n, "Cone inner angle")) {
        const v: *f32 = @ptrCast(@alignCast(val));
        v.* = sample.cone_inner_rad / openmiles.deg2rad;
    } else if (std.mem.eql(u8, n, "Cone outer angle")) {
        const v: *f32 = @ptrCast(@alignCast(val));
        v.* = sample.cone_outer_rad / openmiles.deg2rad;
    } else if (std.mem.eql(u8, n, "Cone outer volume")) {
        const v: *f32 = @ptrCast(@alignCast(val));
        v.* = sample.cone_outer_volume;
    } else if (std.mem.eql(u8, n, "Frequency") or std.mem.eql(u8, n, "Playback rate")) {
        const v: *i32 = @ptrCast(@alignCast(val));
        v.* = @intFromFloat(sample.target_rate orelse 44100.0);
    } else if (std.mem.eql(u8, n, "Volume")) {
        const v: *i32 = @ptrCast(@alignCast(val));
        v.* = sample.original_volume;
    } else if (std.mem.eql(u8, n, "Status")) {
        const v: *u32 = @ptrCast(@alignCast(val));
        v.* = @intFromEnum(sample.status());
    } else if (std.mem.eql(u8, n, "Loop count")) {
        const v: *i32 = @ptrCast(@alignCast(val));
        v.* = sample.loop_count;
    }
}
pub export fn AIL_auto_update_3D_position(s: ?*anyopaque, onoff: i32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.auto_update = (onoff != 0);
}
pub export fn AIL_update_3D_position(s: ?*anyopaque, dt: f32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.updatePosition(dt / 1000.0);
}
pub export fn AIL_set_3D_velocity_vector(s: ?*anyopaque, x: f32, y: f32, z: f32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setVelocity(x, y, z);
}
pub export fn AIL_set_3D_distance_factor(dig_opt: ?*DigitalDriver, factor: f32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    dig.distance_factor = factor;
}
pub export fn AIL_3D_distance_factor(dig_opt: ?*DigitalDriver) callconv(.winapi) f32 {
    const dig = dig_opt orelse return 1.0;
    return dig.distance_factor;
}
pub export fn AIL_set_3D_doppler_factor(dig_opt: ?*DigitalDriver, factor: f32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    dig.doppler_factor = factor;
    for (dig.samples_3d.items) |s| {
        if (s.is_initialized) openmiles.ma.ma_sound_set_doppler_factor(&s.sound, factor);
    }
}
pub export fn AIL_3D_doppler_factor(dig_opt: ?*DigitalDriver) callconv(.winapi) f32 {
    const dig = dig_opt orelse return 1.0;
    return dig.doppler_factor;
}
pub export fn AIL_set_3D_rolloff_factor(dig_opt: ?*DigitalDriver, factor: f32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    dig.rolloff_factor = factor;
    for (dig.samples_3d.items) |s| {
        if (s.is_initialized) openmiles.ma.ma_sound_set_rolloff(&s.sound, factor);
    }
}
pub export fn AIL_3D_rolloff_factor(dig_opt: ?*DigitalDriver) callconv(.winapi) f32 {
    const dig = dig_opt orelse return 1.0;
    return dig.rolloff_factor;
}
pub export fn AIL_set_3D_room_type(dig_opt: ?*DigitalDriver, room_type: i32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    dig.room_type = room_type;
}
pub export fn AIL_3D_room_type(dig_opt: ?*DigitalDriver) callconv(.winapi) i32 {
    const dig = dig_opt orelse return 0;
    return dig.room_type;
}
pub export fn AIL_set_3D_speaker_type(dig_opt: ?*DigitalDriver, speaker_type: i32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    dig.speaker_type = speaker_type;
}
pub export fn AIL_3D_speaker_type(dig_opt: ?*DigitalDriver) callconv(.winapi) i32 {
    const dig = dig_opt orelse return 0;
    return dig.speaker_type;
}
pub export fn AIL_open_3D_provider(provider: *anyopaque, dig_opt: ?*DigitalDriver) callconv(.winapi) ?*anyopaque {
    const dig = dig_opt orelse return null;
    _ = provider;
    // Return the driver as the 3D provider handle — our miniaudio engine IS the 3D provider
    return @ptrCast(dig);
}
pub export fn AIL_close_3D_provider(handle: *anyopaque) callconv(.winapi) void {
    _ = handle; // Driver lifetime managed by AIL_close_digital_driver
}
pub export fn AIL_open_3D_listener(provider: *anyopaque) callconv(.winapi) ?*anyopaque {
    return provider;
}
pub export fn AIL_close_3D_listener(listener: *anyopaque) callconv(.winapi) void {
    _ = listener;
}
pub export fn AIL_open_3D_object(provider: *anyopaque) callconv(.winapi) ?*anyopaque {
    const dig: *DigitalDriver = @ptrCast(@alignCast(provider));
    const s = openmiles.Sample3D.init(dig) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
    return @ptrCast(s);
}
pub export fn AIL_close_3D_object(obj: *anyopaque) callconv(.winapi) void {
    const s: *openmiles.Sample3D = @ptrCast(@alignCast(obj));
    s.deinit();
}
pub export fn AIL_3D_provider_attribute(provider: *anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const dig: *DigitalDriver = @ptrCast(@alignCast(provider));
    const n = std.mem.span(name);
    if (std.mem.eql(u8, n, "Rolloff factor")) {
        const v: *f32 = @ptrCast(@alignCast(val));
        v.* = dig.rolloff_factor;
    } else if (std.mem.eql(u8, n, "Doppler factor")) {
        const v: *f32 = @ptrCast(@alignCast(val));
        v.* = dig.doppler_factor;
    } else if (std.mem.eql(u8, n, "Distance factor")) {
        const v: *f32 = @ptrCast(@alignCast(val));
        v.* = dig.distance_factor;
    }
}
pub export fn AIL_set_3D_provider_preference(provider: *anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const dig: *DigitalDriver = @ptrCast(@alignCast(provider));
    const n = std.mem.span(name);
    if (std.mem.eql(u8, n, "Rolloff factor")) {
        const v: *const f32 = @ptrCast(@alignCast(val));
        dig.rolloff_factor = v.*;
    } else if (std.mem.eql(u8, n, "Doppler factor")) {
        const v: *const f32 = @ptrCast(@alignCast(val));
        dig.doppler_factor = v.*;
    } else if (std.mem.eql(u8, n, "Distance factor")) {
        const v: *const f32 = @ptrCast(@alignCast(val));
        dig.distance_factor = v.*;
    }
}
pub export fn AIL_enumerate_3D_provider_attributes(provider: *anyopaque, next: *?*anyopaque, name: *[*:0]const u8) callconv(.winapi) i32 {
    _ = provider;
    const idx: usize = if (next.*) |v| @intFromPtr(v) else 0;
    if (idx < openmiles.provider_3d_attr_names.len) {
        name.* = openmiles.provider_3d_attr_names[idx];
        next.* = @ptrFromInt(idx + 1);
        return 1;
    }
    next.* = null;
    return 0;
}
pub export fn AIL_enumerate_3D_sample_attributes(s: ?*anyopaque, next: *?*anyopaque, name: *[*:0]const u8) callconv(.winapi) i32 {
    _ = s;
    const idx: usize = if (next.*) |v| @intFromPtr(v) else 0;
    if (idx < openmiles.sample_3d_attr_names.len) {
        name.* = openmiles.sample_3d_attr_names[idx];
        next.* = @ptrFromInt(idx + 1);
        return 1;
    }
    next.* = null;
    return 0;
}
pub export fn AIL_3D_orientation(obj: *anyopaque, fx: ?*f32, fy: ?*f32, fz: ?*f32, ux: ?*f32, uy: ?*f32, uz: ?*f32) callconv(.winapi) void {
    if (openmiles.isKnownDriver(obj)) {
        const dig: *DigitalDriver = @ptrCast(@alignCast(obj));
        const fwd = dig.getListenerDirection();
        const up = dig.getListenerWorldUp();
        if (fx) |p| p.* = fwd.x;
        if (fy) |p| p.* = fwd.y;
        if (fz) |p| p.* = fwd.z;
        if (ux) |p| p.* = up.x;
        if (uy) |p| p.* = up.y;
        if (uz) |p| p.* = up.z;
    } else {
        const s: *openmiles.Sample3D = @ptrCast(@alignCast(obj));
        if (fx) |p| p.* = s.orient_fx;
        if (fy) |p| p.* = s.orient_fy;
        if (fz) |p| p.* = s.orient_fz;
        if (ux) |p| p.* = s.orient_ux;
        if (uy) |p| p.* = s.orient_uy;
        if (uz) |p| p.* = s.orient_uz;
    }
}
pub export fn AIL_3D_position(obj: *anyopaque, x: ?*f32, y: ?*f32, z: ?*f32) callconv(.winapi) void {
    if (openmiles.isKnownDriver(obj)) {
        const dig: *DigitalDriver = @ptrCast(@alignCast(obj));
        const pos = dig.getListenerPosition();
        if (x) |p| p.* = pos.x;
        if (y) |p| p.* = pos.y;
        if (z) |p| p.* = pos.z;
    } else {
        const s: *openmiles.Sample3D = @ptrCast(@alignCast(obj));
        if (x) |p| p.* = s.pos_x;
        if (y) |p| p.* = s.pos_y;
        if (z) |p| p.* = s.pos_z;
    }
}
pub export fn AIL_3D_velocity(obj: *anyopaque, x: ?*f32, y: ?*f32, z: ?*f32, factor: ?*f32) callconv(.winapi) void {
    if (openmiles.isKnownDriver(obj)) {
        const dig: *DigitalDriver = @ptrCast(@alignCast(obj));
        const vel = dig.getListenerVelocity();
        if (x) |p| p.* = vel.x;
        if (y) |p| p.* = vel.y;
        if (z) |p| p.* = vel.z;
        if (factor) |p| p.* = 1.0;
    } else {
        const s: *openmiles.Sample3D = @ptrCast(@alignCast(obj));
        if (x) |p| p.* = s.velocity_x;
        if (y) |p| p.* = s.velocity_y;
        if (z) |p| p.* = s.velocity_z;
        if (factor) |p| p.* = 1.0;
    }
}
pub export fn AIL_3D_sample_distances(s_opt: ?*openmiles.Sample3D, max_dist: ?*f32, min_dist: ?*f32) callconv(.winapi) void {
    const sample = s_opt orelse return;
    if (sample.is_initialized) {
        if (max_dist) |p| p.* = openmiles.ma.ma_sound_get_max_distance(&sample.sound);
        if (min_dist) |p| p.* = openmiles.ma.ma_sound_get_min_distance(&sample.sound);
    } else {
        if (max_dist) |p| p.* = sample.max_distance;
        if (min_dist) |p| p.* = sample.min_distance;
    }
}

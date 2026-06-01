const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;
const DigitalDriver = openmiles.DigitalDriver;
const Provider = openmiles.Provider;

const deg2rad = openmiles.deg2rad;

pub fn AIL_enumerate_3D_providers(next: *?*anyopaque, handle: *?*Provider, name: *[*:0]const u8) callconv(.winapi) i32 {
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
pub fn AIL_allocate_3D_sample_handle(driver_opt: ?*DigitalDriver) callconv(.winapi) ?*anyopaque {
    const driver = driver_opt orelse return null;
    log("AIL_allocate_3D_sample_handle(driver={*})\n", .{driver});
    const s = openmiles.Sample3D.init(driver) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
    return @ptrCast(s);
}
pub fn AIL_release_3D_sample_handle(s: ?*anyopaque) callconv(.winapi) void {
    const p = s orelse return;
    log("AIL_release_3D_sample_handle(s={*})\n", .{p});
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.deinit();
}
pub fn AIL_set_3D_sample_file(s: ?*anyopaque, data: ?*anyopaque) callconv(.winapi) i32 {
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
pub fn AIL_set_3D_position(obj: ?*anyopaque, x: f32, y: f32, z: f32) callconv(.winapi) void {
    const o = obj orelse return;
    if (openmiles.isKnownDriver(o)) {
        const dig: *DigitalDriver = @ptrCast(@alignCast(o));
        dig.setListenerPosition(x, y, z);
    } else {
        const sample: *openmiles.Sample3D = @ptrCast(@alignCast(o));
        sample.setPosition(x, y, z);
    }
}
pub fn AIL_set_3D_velocity(obj: ?*anyopaque, x: f32, y: f32, z: f32, factor: f32) callconv(.winapi) void {
    const o = obj orelse return;
    if (openmiles.isKnownDriver(o)) {
        const dig: *DigitalDriver = @ptrCast(@alignCast(o));
        dig.setListenerVelocity(x * factor, y * factor, z * factor);
    } else {
        const sample: *openmiles.Sample3D = @ptrCast(@alignCast(o));
        sample.setVelocity(x * factor, y * factor, z * factor);
    }
}
pub fn AIL_set_3D_orientation(obj: ?*anyopaque, fx: f32, fy: f32, fz: f32, ux: f32, uy: f32, uz: f32) callconv(.winapi) void {
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
pub fn AIL_set_3D_sample_distances(s: ?*anyopaque, max_dist: f32, min_dist: f32) callconv(.winapi) void {
    const p = s orelse return;
    log("AIL_set_3D_sample_distances(s={*}, max={d}, min={d})\n", .{ p, max_dist, min_dist });
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setMinMaxDistance(min_dist, max_dist);
}
// v4/v5 ABI: AIL_(set_)3D_sample_distances were 5-arg (@20), and v5 adds a
// *_float_distances @20 pair. Disassembly of 4.0h confirms the H3DSAMPLE handle
// plus four trailing slots (the v6 max/min and two further distance-model values
// whose meaning no available SDK documents). These variants satisfy the @20
// import — applying the known max/min in v6 argument order, ignoring the extra
// two — so v4/v5 games link and get approximately-correct distance falloff. The
// v6+ build exports the simplified 3-arg (@12) form above.
pub fn AIL_set_3D_sample_distances_v4(s: ?*anyopaque, max_dist: f32, min_dist: f32, a3: f32, a4: f32) callconv(.winapi) void {
    _ = a3;
    _ = a4;
    AIL_set_3D_sample_distances(s, max_dist, min_dist);
}
pub fn AIL_3D_sample_distances_v4(s: ?*openmiles.Sample3D, max_dist: ?*f32, min_dist: ?*f32, a3: ?*f32, a4: ?*f32) callconv(.winapi) void {
    AIL_3D_sample_distances(s, max_dist, min_dist);
    if (a3) |p| p.* = 0;
    if (a4) |p| p.* = 0;
}
pub fn AIL_set_3D_sample_float_distances_v5(s: ?*anyopaque, max_dist: f32, min_dist: f32, a3: f32, a4: f32) callconv(.winapi) void {
    _ = a3;
    _ = a4;
    AIL_set_3D_sample_distances(s, max_dist, min_dist);
}
pub fn AIL_3D_sample_float_distances_v5(s: ?*openmiles.Sample3D, max_dist: ?*f32, min_dist: ?*f32, a3: ?*f32, a4: ?*f32) callconv(.winapi) void {
    AIL_3D_sample_distances(s, max_dist, min_dist);
    if (a3) |p| p.* = 0;
    if (a4) |p| p.* = 0;
}
pub fn AIL_set_listener_3D_position(dig_opt: ?*DigitalDriver, x: f32, y: f32, z: f32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    dig.setListenerPosition(x, y, z);
}
pub fn AIL_set_listener_3D_velocity(dig_opt: ?*DigitalDriver, x: f32, y: f32, z: f32, factor: f32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    dig.setListenerVelocity(x * factor, y * factor, z * factor);
}
pub fn AIL_set_listener_3D_orientation(dig_opt: ?*DigitalDriver, fx: f32, fy: f32, fz: f32, ux: f32, uy: f32, uz: f32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    dig.setListenerDirection(fx, fy, fz);
    dig.setListenerWorldUp(ux, uy, uz);
}
pub fn AIL_start_3D_sample(s: ?*anyopaque) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.start();
}
pub fn AIL_stop_3D_sample(s: ?*anyopaque) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.pause();
}
pub fn AIL_resume_3D_sample(s: ?*anyopaque) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.resumePlayback();
}
pub fn AIL_end_3D_sample(s: ?*anyopaque) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.end();
}
pub fn AIL_3D_sample_status(s: ?*anyopaque) callconv(.winapi) u32 {
    const p = s orelse return 0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return @intFromEnum(sample.status());
}
pub fn AIL_3D_sample_volume(s: ?*anyopaque) callconv(.winapi) i32 {
    const p = s orelse return 0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return sample.original_volume;
}
pub fn AIL_set_3D_sample_volume(s: ?*anyopaque, volume: i32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setVolume(volume);
}
pub fn AIL_3D_sample_loop_count(s: ?*anyopaque) callconv(.winapi) i32 {
    const p = s orelse return 0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return sample.loop_count;
}
pub fn AIL_set_3D_sample_loop_count(s: ?*anyopaque, count: i32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setLoopCount(count);
}
pub fn AIL_3D_sample_playback_rate(s: ?*anyopaque) callconv(.winapi) i32 {
    const p = s orelse return 0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    // Mirror AIL_API_sample_playback_rate (a 3D sample is HSAMPLE-backed and is
    // init'd through the same AIL_API_init_sample): explicit app-set rate first,
    // then the loaded decoder's native rate (original_playback_rate is set to the
    // file rate at load), then the 11025 init default for a fresh sample.
    if (sample.target_rate) |tr| return openmiles.satI32(tr);
    if (sample.decoder) |d| return @intCast(d.outputSampleRate);
    return 11025;
}
pub fn AIL_set_3D_sample_playback_rate(s: ?*anyopaque, rate: i32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setPlaybackRate(rate);
}
pub fn AIL_3D_sample_offset(s: ?*anyopaque) callconv(.winapi) u32 {
    const p = s orelse return 0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return sample.getOffset();
}
pub fn AIL_set_3D_sample_offset(s: ?*anyopaque, offset: u32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setOffset(offset);
}
pub fn AIL_3D_sample_length(s: ?*anyopaque) callconv(.winapi) u32 {
    const p = s orelse return 0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return sample.getLength();
}
pub fn AIL_3D_sample_ms_position(s: ?*anyopaque, total_ms: ?*i32, current_ms: ?*i32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    const pos = sample.getMsPosition();
    if (total_ms) |t| t.* = pos.total;
    if (current_ms) |c| c.* = pos.current;
}
pub fn AIL_set_3D_sample_ms_position(s: ?*anyopaque, ms: i32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setMsPosition(ms);
}
pub fn AIL_register_3D_EOS_callback(s: ?*anyopaque, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const p = s orelse return null;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    const prev: ?*anyopaque = @ptrFromInt(sample.eos_callback);
    sample.eos_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub fn AIL_active_3D_sample_count(dig_opt: ?*DigitalDriver) callconv(.winapi) u32 {
    const dig = dig_opt orelse return 0;
    return dig.get3DActiveSampleCount();
}
pub fn AIL_3D_user_data(s: ?*anyopaque, index: i32) callconv(.winapi) u32 {
    const p = s orelse return 0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    const idx: usize = @intCast(@min(@max(index, 0), 7));
    return sample.user_data[idx];
}
pub fn AIL_set_3D_user_data(s: ?*anyopaque, index: i32, value: u32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    const idx: usize = @intCast(@min(@max(index, 0), 7));
    sample.user_data[idx] = value;
}
pub fn AIL_set_3D_sample_info(s: ?*anyopaque, info: ?*anyopaque) callconv(.winapi) i32 {
    const p = s orelse return 0;
    const i = info orelse return 0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    const si: *openmiles.AILSOUNDINFO = @ptrCast(@alignCast(i));
    if (si.data_ptr == null or si.data_len == 0) return 0;
    const data: [*]const u8 = @ptrCast(si.data_ptr.?);
    // Clamp untrusted AILSOUNDINFO fields to valid ranges before narrowing to
    // u16 (a raw @intCast of a huge/negative i32 would panic).
    const channels: u16 = @intCast(std.math.clamp(si.channels, 1, 8));
    const bits: u16 = if (si.bits == 8) 8 else 16;
    sample.loadFromPcm(data[0..si.data_len], channels, si.rate, bits) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    return 1;
}
pub fn AIL_set_3D_sample_loop_block(s: ?*anyopaque, loop_start: i32, loop_end: i32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setLoopBlock(loop_start, loop_end);
}
// AIL_set_3D_sample_cone(H3DSAMPLE, F32 inner_angle, F32 outer_angle, S32 outer_volume)
// outer_volume is an MSS 0-127 scalar; stored internally as a 0..1 gain.
pub fn AIL_set_3D_sample_cone(s: ?*anyopaque, inner_angle: f32, outer_angle: f32, outer_volume: i32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.cone_inner_rad = inner_angle * openmiles.deg2rad;
    sample.cone_outer_rad = outer_angle * openmiles.deg2rad;
    const clamped: f32 = @floatFromInt(@min(@max(outer_volume, 0), 127));
    sample.cone_outer_volume = clamped / 127.0;
    sample.applyCone();
}
// AIL_3D_sample_cone(H3DSAMPLE, F32* inner_angle, F32* outer_angle, S32* outer_volume)
pub fn AIL_3D_sample_cone(s: ?*anyopaque, inner_angle: ?*f32, outer_angle: ?*f32, outer_volume: ?*i32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    if (inner_angle) |a| a.* = sample.cone_inner_rad / openmiles.deg2rad;
    if (outer_angle) |a| a.* = sample.cone_outer_rad / openmiles.deg2rad;
    if (outer_volume) |a| a.* = openmiles.satI32(sample.cone_outer_volume * 127.0 + 0.5);
}
pub fn AIL_set_3D_sample_effects_level(s: ?*anyopaque, effects_level: f32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.effects_level = @min(1.0, @max(0.0, effects_level));
}
pub fn AIL_3D_sample_effects_level(s: ?*anyopaque) callconv(.winapi) f32 {
    const p = s orelse return 0.0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return sample.effects_level;
}
pub fn AIL_set_3D_sample_obstruction(s: ?*anyopaque, obstruction: f32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setObstruction(obstruction);
}
pub fn AIL_3D_sample_obstruction(s: ?*anyopaque) callconv(.winapi) f32 {
    const p = s orelse return 0.0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return sample.obstruction;
}
pub fn AIL_set_3D_sample_occlusion(s: ?*anyopaque, occlusion: f32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setOcclusion(occlusion);
}
pub fn AIL_3D_sample_occlusion(s: ?*anyopaque) callconv(.winapi) f32 {
    const p = s orelse return 0.0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return sample.occlusion;
}
// 6.5/6.6 only: H3DSAMPLE exclusion attenuation hint (stored, queried back).
// SDK m3d.cpp AIL_API_set_sample_exclusion stores `S->exclusion = exclusion`
// verbatim (no clamp), so the getter must round-trip out-of-range values.
pub fn AIL_set_3D_sample_exclusion(s: ?*anyopaque, exclusion: f32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.exclusion = exclusion;
}
pub fn AIL_3D_sample_exclusion(s: ?*anyopaque) callconv(.winapi) f32 {
    const p = s orelse return 0.0;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    return sample.exclusion;
}
pub fn AIL_set_3D_sample_preference(s: ?*anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
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
pub fn AIL_3D_sample_attribute(s: ?*anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
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
        v.* = openmiles.satI32(sample.target_rate orelse 44100.0);
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
pub fn AIL_auto_update_3D_position(s: ?*anyopaque, onoff: i32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.auto_update = (onoff != 0);
}
pub fn AIL_update_3D_position(s: ?*anyopaque, dt: f32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.updatePosition(dt / 1000.0);
}
pub fn AIL_set_3D_velocity_vector(s: ?*anyopaque, x: f32, y: f32, z: f32) callconv(.winapi) void {
    const p = s orelse return;
    const sample: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    sample.setVelocity(x, y, z);
}
pub fn AIL_set_3D_distance_factor(dig_opt: ?*DigitalDriver, factor: f32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    dig.distance_factor = factor;
    // MSS folds distance_factor into the Doppler velocity scale; push the
    // combined factor to every live sample's miniaudio doppler factor.
    const eff = dig.effectiveDoppler();
    for (dig.samples_3d.items) |s| {
        if (s.is_initialized) openmiles.ma.ma_sound_set_doppler_factor(&s.sound, eff);
    }
}
pub fn AIL_3D_distance_factor(dig_opt: ?*DigitalDriver) callconv(.winapi) f32 {
    const dig = dig_opt orelse return 0.0; // SDK (mssds3d.cpp): null handle -> 0.0, not the 1.0 default
    return dig.distance_factor;
}
pub fn AIL_set_3D_doppler_factor(dig_opt: ?*DigitalDriver, factor: f32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    dig.doppler_factor = factor;
    // ma's doppler factor multiplies velocity, matching MSS's combined
    // distance_factor * doppler_factor scaling.
    const eff = dig.effectiveDoppler();
    for (dig.samples_3d.items) |s| {
        if (s.is_initialized) openmiles.ma.ma_sound_set_doppler_factor(&s.sound, eff);
    }
}
pub fn AIL_3D_doppler_factor(dig_opt: ?*DigitalDriver) callconv(.winapi) f32 {
    const dig = dig_opt orelse return 0.0; // SDK: null handle -> 0.0, not the 1.0 default
    return dig.doppler_factor;
}
pub fn AIL_set_3D_rolloff_factor(dig_opt: ?*DigitalDriver, factor: f32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    dig.rolloff_factor = factor;
    for (dig.samples_3d.items) |s| {
        if (s.is_initialized) openmiles.ma.ma_sound_set_rolloff(&s.sound, factor);
    }
}
pub fn AIL_3D_rolloff_factor(dig_opt: ?*DigitalDriver) callconv(.winapi) f32 {
    const dig = dig_opt orelse return 0.0; // SDK: null handle -> 0.0, not the 1.0 default
    return dig.rolloff_factor;
}
pub fn AIL_set_3D_room_type(dig_opt: ?*DigitalDriver, room_type: i32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    dig.room_type = room_type;
}
pub fn AIL_3D_room_type(dig_opt: ?*DigitalDriver) callconv(.winapi) i32 {
    const dig = dig_opt orelse return 0;
    return dig.room_type;
}
pub fn AIL_set_3D_speaker_type(dig_opt: ?*DigitalDriver, speaker_type: i32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    dig.speaker_type = speaker_type;
}
pub fn AIL_3D_speaker_type(dig_opt: ?*DigitalDriver) callconv(.winapi) i32 {
    const dig = dig_opt orelse return 0;
    return dig.speaker_type;
}
// Real MSS: M3DRESULT AIL_open_3D_provider(HPROVIDER lib) @4 — initialize the
// 3D provider, returning M3D_NOERR (0) on success. Our miniaudio engine is
// always the 3D provider and 3D objects are created against the active digital
// driver (see AIL_open_3D_object), so this just validates and reports success.
pub fn AIL_open_3D_provider(lib: ?*anyopaque) callconv(.winapi) i32 {
    _ = lib;
    return 0; // M3D_NOERR
}
pub fn AIL_3D_update_position(obj: ?*anyopaque, dt_milliseconds: f32) callconv(.winapi) void {
    const p = obj orelse return;
    const s: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    s.updatePositionExplicit(dt_milliseconds);
}
pub fn AIL_3D_auto_update_position(obj: ?*anyopaque, enable: i32) callconv(.winapi) void {
    const p = obj orelse return;
    const s: *openmiles.Sample3D = @ptrCast(@alignCast(p));
    s.auto_update = (enable != 0);
}
pub fn AIL_close_3D_provider(handle: *anyopaque) callconv(.winapi) void {
    _ = handle; // Driver lifetime managed by AIL_close_digital_driver
}
pub fn AIL_open_3D_listener(provider: *anyopaque) callconv(.winapi) ?*anyopaque {
    return provider;
}
pub fn AIL_close_3D_listener(listener: *anyopaque) callconv(.winapi) void {
    _ = listener;
}
pub fn AIL_open_3D_object(provider: *anyopaque) callconv(.winapi) ?*anyopaque {
    // Prefer the active digital driver (the real engine); fall back to treating
    // the provider handle as a driver for legacy callers.
    const dig: *DigitalDriver = openmiles.last_digital_driver orelse @ptrCast(@alignCast(provider));
    const s = openmiles.Sample3D.init(dig) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
    return @ptrCast(s);
}
pub fn AIL_close_3D_object(obj: *anyopaque) callconv(.winapi) void {
    const s: *openmiles.Sample3D = @ptrCast(@alignCast(obj));
    s.deinit();
}
pub fn AIL_3D_provider_attribute(provider: *anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
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
pub fn AIL_set_3D_provider_preference(provider: *anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const dig: *DigitalDriver = @ptrCast(@alignCast(provider));
    const n = std.mem.span(name);
    // Delegate to the dedicated setters so these also propagate to live samples
    // (ma rolloff / doppler), exactly like the AIL_set_3D_*_factor entry points.
    if (std.mem.eql(u8, n, "Rolloff factor")) {
        AIL_set_3D_rolloff_factor(dig, @as(*const f32, @ptrCast(@alignCast(val))).*);
    } else if (std.mem.eql(u8, n, "Doppler factor")) {
        AIL_set_3D_doppler_factor(dig, @as(*const f32, @ptrCast(@alignCast(val))).*);
    } else if (std.mem.eql(u8, n, "Distance factor")) {
        AIL_set_3D_distance_factor(dig, @as(*const f32, @ptrCast(@alignCast(val))).*);
    }
}
pub fn AIL_enumerate_3D_provider_attributes(provider: *anyopaque, next: *?*anyopaque, name: *[*:0]const u8) callconv(.winapi) i32 {
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
pub fn AIL_enumerate_3D_sample_attributes(s: ?*anyopaque, next: *?*anyopaque, name: *[*:0]const u8) callconv(.winapi) i32 {
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
pub fn AIL_3D_orientation(obj: *anyopaque, fx: ?*f32, fy: ?*f32, fz: ?*f32, ux: ?*f32, uy: ?*f32, uz: ?*f32) callconv(.winapi) void {
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
pub fn AIL_3D_position(obj: *anyopaque, x: ?*f32, y: ?*f32, z: ?*f32) callconv(.winapi) void {
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
// AIL_3D_velocity(H3DPOBJECT obj, F32 *dX_per_ms, F32 *dY_per_ms, F32 *dZ_per_ms)
// Getter takes no magnitude out-param (unlike the setter).
pub fn AIL_3D_velocity(obj: *anyopaque, x: ?*f32, y: ?*f32, z: ?*f32) callconv(.winapi) void {
    if (openmiles.isKnownDriver(obj)) {
        const dig: *DigitalDriver = @ptrCast(@alignCast(obj));
        const vel = dig.getListenerVelocity();
        if (x) |p| p.* = vel.x;
        if (y) |p| p.* = vel.y;
        if (z) |p| p.* = vel.z;
    } else {
        const s: *openmiles.Sample3D = @ptrCast(@alignCast(obj));
        if (x) |p| p.* = s.velocity_x;
        if (y) |p| p.* = s.velocity_y;
        if (z) |p| p.* = s.velocity_z;
    }
}
// NOTE: this is the v6+ 3-arg ABI (`_AIL_3D_sample_distances@12`, matching the
// 6.1 and combined SDK headers). The 4.0/5.0 mss32.dll exports a wider
// `@20` (5-arg) variant — and 5.0 adds `AIL_3D_sample_float_distances@20` — whose
// two extra parameters are not documented by any available SDK header. Faithfully
// reproducing the v4/v5 decoration needs the era SDK or a 4.0h/5.0r disassembly;
// until then those four symbols are the only gap in the v4/v5 export tables.
pub fn AIL_3D_sample_distances(s_opt: ?*openmiles.Sample3D, max_dist: ?*f32, min_dist: ?*f32) callconv(.winapi) void {
    const sample = s_opt orelse return;
    if (sample.is_initialized) {
        if (max_dist) |p| p.* = openmiles.ma.ma_sound_get_max_distance(&sample.sound);
        if (min_dist) |p| p.* = openmiles.ma.ma_sound_get_min_distance(&sample.sound);
    } else {
        if (max_dist) |p| p.* = sample.max_distance;
        if (min_dist) |p| p.* = sample.min_distance;
    }
}

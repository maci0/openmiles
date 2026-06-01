//! MSS v7+ unified API.
//!
//! Miles 7 merged the separate 2D/3D sample models: 3D, low-pass, and reverb now
//! live directly on the normal `HSAMPLE`. These exports are additive — they sit
//! alongside the legacy 3.x–6.x surface (one DLL serves any era) and reuse the
//! same engine methods the v6 wrappers call. Signatures follow the unified
//! `mss.h` shipped with the MSS 9.x SDK (the v7–v9 unified API is identical).
//!
//! Functions that map onto existing engine features are implemented by reusing
//! them; genuinely-new v7 subsystems (multichannel speaker/receiver arrays,
//! output-filter providers, MP3 frame inspection, pipeline stages) are stubbed
//! with sane defaults so v7 titles link and run.

const std = @import("std");
const openmiles = @import("openmiles");
const ma = openmiles.ma;
const log = openmiles.log;
const Sample = openmiles.Sample;
const DigitalDriver = openmiles.DigitalDriver;
const Redbook = openmiles.Redbook;
const MidiDriver = openmiles.MidiDriver;
const AILSOUNDINFO = openmiles.AILSOUNDINFO;
const openmiles_v8 = @import("v8.zig"); // shared output_speaker_index table

// --- Unified 3D on HSAMPLE (reuses the sample's miniaudio spatial state) -----

fn enable3D(s: *Sample) void {
    s.is_3D = 1; // SDK: specifying a 3D position enables 3D until re-init (m3d.cpp)
    if (s.is_initialized) ma.ma_sound_set_spatialization_enabled(&s.sound, ma.MA_TRUE);
}

// Unified 3D-on-HSAMPLE. Like Sample3D/the listener, negate Z crossing the
// miniaudio boundary (MSS left-handed +Z forward vs miniaudio right-handed -Z)
// so all three coordinate spaces stay consistent. See Sample3D.setPosition.
pub fn AIL_set_sample_3D_position(obj: ?*Sample, x: f32, y: f32, z: f32) callconv(.winapi) void {
    const s = obj orelse return;
    enable3D(s);
    if (s.is_initialized) ma.ma_sound_set_position(&s.sound, x, y, -z);
}
pub fn AIL_set_sample_3D_velocity(obj: ?*Sample, dx: f32, dy: f32, dz: f32, magnitude: f32) callconv(.winapi) void {
    // SDK (m3d.cpp): scale the (unit-ish) direction by magnitude, then defer to
    // the vector form. Dropping magnitude left every such call at unit speed.
    AIL_set_sample_3D_velocity_vector(obj, dx * magnitude, dy * magnitude, dz * magnitude);
}
pub fn AIL_set_sample_3D_velocity_vector(obj: ?*Sample, dx: f32, dy: f32, dz: f32) callconv(.winapi) void {
    const s = obj orelse return;
    if (s.is_initialized) ma.ma_sound_set_velocity(&s.sound, dx, dy, -dz);
}
pub fn AIL_set_sample_3D_orientation(obj: ?*Sample, fx: f32, fy: f32, fz: f32, ux: f32, uy: f32, uz: f32) callconv(.winapi) void {
    const s = obj orelse return;
    // SDK (m3d.cpp) normalizes both face and up and stores them; the up vector
    // has no miniaudio analogue but is retained for a faithful getter round-trip.
    s.setOrientation(fx, fy, fz, ux, uy, uz);
}
pub fn AIL_set_sample_3D_cone(obj: ?*Sample, inner_angle: f32, outer_angle: f32, outer_volume_level: f32) callconv(.winapi) void {
    const s = obj orelse return;
    // MSS takes full (diameter) cone angles in degrees and stores half-angle
    // radians (DEGS_TO_DIAMS = deg*pi/360); miniaudio takes the full angle in
    // radians and internally halves it (cos(angle*0.5)). So deg->rad is the
    // correct, faithful conversion and the inner/outer cutoffs match MSS.
    // Known minor deviation: in the inner..outer transition band MSS lerps the
    // gain linearly in ANGLE (alpha=(outer-angle)/(outer-inner)) whereas
    // miniaudio lerps in COSINE; endpoints match exactly, mid-band differs a
    // few percent. Faithfully matching it would require bypassing ma's
    // per-frame spatializer, so the (rarely-used) cone curve is left to ma.
    if (s.is_initialized) ma.ma_sound_set_cone(&s.sound, inner_angle * openmiles.deg2rad, outer_angle * openmiles.deg2rad, std.math.clamp(outer_volume_level, 0.0, 1.0));
}
pub fn AIL_set_sample_3D_distances(obj: ?*Sample, max_dist: f32, min_dist: f32, auto_3D_wet_atten: i32) callconv(.winapi) void {
    const s = obj orelse return;
    s.s3d_auto_atten = auto_3D_wet_atten; // SDK stores S3D.auto_3D_atten verbatim
    // SDK (m3d.cpp) swaps the pair when min > max so min_dist <= max_dist always
    // holds; miniaudio's attenuation is undefined for min > max, so this matters.
    var lo = min_dist;
    var hi = max_dist;
    if (lo > hi) {
        const tmp = lo;
        lo = hi;
        hi = tmp;
    }
    if (s.is_initialized) {
        ma.ma_sound_set_min_distance(&s.sound, lo);
        ma.ma_sound_set_max_distance(&s.sound, hi);
    }
}
pub fn AIL_update_sample_3D_position(obj: ?*Sample, dt_ms: f32) callconv(.winapi) void {
    const s = obj orelse return;
    if (!s.is_initialized) return;
    if (!(dt_ms == dt_ms) or std.math.isInf(dt_ms)) return; // NaN/Inf guard
    const dt_s = dt_ms / 1000.0;
    const p = ma.ma_sound_get_position(&s.sound);
    const v = ma.ma_sound_get_velocity(&s.sound);
    ma.ma_sound_set_position(&s.sound, p.x + v.x * dt_s, p.y + v.y * dt_s, p.z + v.z * dt_s);
}

pub fn AIL_sample_3D_position(obj: ?*Sample, x: ?*f32, y: ?*f32, z: ?*f32) callconv(.winapi) i32 {
    const s = obj orelse return 0;
    const v = if (s.is_initialized) ma.ma_sound_get_position(&s.sound) else ma.ma_vec3f{ .x = 0, .y = 0, .z = 0 };
    if (x) |p| p.* = v.x;
    if (y) |p| p.* = v.y;
    if (z) |p| p.* = -v.z;
    return s.is_3D; // SDK returns S->is_3D
}
pub fn AIL_sample_3D_velocity(obj: ?*Sample, dx: ?*f32, dy: ?*f32, dz: ?*f32) callconv(.winapi) void {
    const s = obj orelse return;
    const v = if (s.is_initialized) ma.ma_sound_get_velocity(&s.sound) else ma.ma_vec3f{ .x = 0, .y = 0, .z = 0 };
    if (dx) |p| p.* = v.x;
    if (dy) |p| p.* = v.y;
    if (dz) |p| p.* = -v.z;
}
pub fn AIL_sample_3D_orientation(obj: ?*Sample, fx: ?*f32, fy: ?*f32, fz: ?*f32, ux: ?*f32, uy: ?*f32, uz: ?*f32) callconv(.winapi) void {
    const s = obj orelse return;
    // Return the stored, normalized face & up exactly as the SDK does.
    if (fx) |p| p.* = s.s3d_face[0];
    if (fy) |p| p.* = s.s3d_face[1];
    if (fz) |p| p.* = s.s3d_face[2];
    if (ux) |p| p.* = s.s3d_up[0];
    if (uy) |p| p.* = s.s3d_up[1];
    if (uz) |p| p.* = s.s3d_up[2];
}
pub fn AIL_sample_3D_cone(obj: ?*Sample, inner_angle: ?*f32, outer_angle: ?*f32, outer_volume_level: ?*f32) callconv(.winapi) void {
    const s = obj orelse return;
    var inner: f32 = 0;
    var outer: f32 = 6.2831855;
    var gain: f32 = 1;
    if (s.is_initialized) ma.ma_sound_get_cone(&s.sound, &inner, &outer, &gain);
    if (inner_angle) |p| p.* = inner / openmiles.deg2rad;
    if (outer_angle) |p| p.* = outer / openmiles.deg2rad;
    if (outer_volume_level) |p| p.* = gain;
}
pub fn AIL_sample_3D_distances(obj: ?*Sample, max_dist: ?*f32, min_dist: ?*f32, auto_3D_wet_atten: ?*i32) callconv(.winapi) void {
    const s = obj orelse return;
    if (max_dist) |p| p.* = if (s.is_initialized) ma.ma_sound_get_max_distance(&s.sound) else 0;
    if (min_dist) |p| p.* = if (s.is_initialized) ma.ma_sound_get_min_distance(&s.sound) else 0;
    if (auto_3D_wet_atten) |p| p.* = s.s3d_auto_atten; // SDK returns S3D.auto_3D_atten

}

// --- Unified sample volume / pan / reverb / low-pass (reuse v6 engine) --------

pub fn AIL_set_sample_volume_levels(s_opt: ?*Sample, left_level: f32, right_level: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setVolumeLevels(left_level, right_level);
}
pub fn AIL_sample_volume_levels(s_opt: ?*Sample, left_level: ?*f32, right_level: ?*f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    // SDK returns left_volume/right_volume verbatim (the front pair).
    if (left_level) |p| p.* = s.v51_levels[0];
    if (right_level) |p| p.* = s.v51_levels[1];
}
pub fn AIL_sample_volume_pan(s_opt: ?*Sample, volume: ?*f32, pan: ?*f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    // Return the exact 0..1 volume/pan the app set (the SDK getter inverts the
    // gain curve to recover it and returns save_pan), NOT the internal
    // balance-pan value -- and not quantized through the i32 0..127 fields.
    if (volume) |p| p.* = s.save_vol_f;
    if (pan) |p| p.* = s.save_pan_f;
}
pub fn AIL_set_sample_low_pass_cut_off(s_opt: ?*Sample, channel: i32, cut_off: f32) callconv(.winapi) void {
    _ = channel;
    const s = s_opt orelse return;
    // cut_off is MSS's normalized 0..1 cutoff (not Hz); the engine converts.
    s.setLowPassNormalized(cut_off);
}
pub fn AIL_sample_low_pass_cut_off(s_opt: ?*Sample, channel: i32) callconv(.winapi) f32 {
    _ = channel;
    // SDK (wavefile.cpp) returns 1.0 (fully open / no filtering) for a null
    // handle and whenever no low-pass is active — never 0.
    const s = s_opt orelse return 1.0;
    return s.getLowPassNormalized();
}
pub fn AIL_set_sample_reverb_levels(s_opt: ?*Sample, dry_level: f32, wet_level: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    // The SDK (AIL_API_set_sample_reverb_levels) stores dry and wet verbatim
    // (independent, need not sum to 1) and the getter returns them as-is. Drive
    // the engine with a clamped wet, then store the verbatim wet for the getter.
    s.reverb_dry_level = dry_level;
    s.setReverb(s.reverb_room_type, std.math.clamp(wet_level, 0.0, 1.0), if (s.reverb_reflect_time > 0) s.reverb_reflect_time else 0.05);
    s.reverb_level = wet_level; // verbatim for the getter (engine used the clamped value)
}
pub fn AIL_sample_reverb_levels(s_opt: ?*Sample, dry_level: ?*f32, wet_level: ?*f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    if (dry_level) |p| p.* = s.reverb_dry_level;
    if (wet_level) |p| p.* = s.reverb_level;
}
pub fn AIL_set_sample_info(s_opt: ?*Sample, info: *const AILSOUNDINFO) callconv(.winapi) i32 {
    const s = s_opt orelse return 0; // SDK (wavefile.cpp): 0 on null S/info
    // Channel-count selection mirrors AIL_API_set_sample_info exactly (verified by
    // disassembling 7.0k vs 8.0e/9.1d):
    //   v8/v9: channels>2 OR channel_mask!=~0U  -> DIG_F_MULTICHANNEL | channels<<16
    //          (the true channel count is preserved); channels==2 -> stereo; else
    //          mono. Collapsing those cases, the resulting count is max(1,channels).
    //   v7 and earlier: stereo only when channels==2, otherwise mono — there is no
    //          multichannel path, so >2 channels downgrades to mono, NOT stereo.
    const ch: u16 = blk: {
        if (@hasField(AILSOUNDINFO, "channel_mask")) {
            const want = @max(@as(i32, 1), @min(info.channels, 0xFFFF));
            break :blk @intCast(want);
        }
        break :blk if (info.channels == 2) 2 else 1;
    };
    const bits: u16 = if (info.bits == 8) 8 else 16;
    s.pcm_format = .{ .channels = ch, .bits = bits };
    if (@hasField(AILSOUNDINFO, "channel_mask")) s.channel_mask = info.channel_mask;
    return 1; // success (the miniaudio mixer accepts any PCM/ADPCM format we set)
}

// Obstruction / occlusion / exclusion: stored attenuation hints (reuse Sample3D
// semantics but on the unified handle; applied as a wet/volume hint).
pub fn AIL_set_sample_obstruction(s_opt: ?*Sample, obstruction: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.v7_obstruction = obstruction; // SDK (m3d.cpp) stores verbatim, no clamp
}
pub fn AIL_sample_obstruction(s_opt: ?*Sample) callconv(.winapi) f32 {
    const s = s_opt orelse return 0;
    return s.v7_obstruction;
}
pub fn AIL_set_sample_occlusion(s_opt: ?*Sample, occlusion: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.v7_occlusion = occlusion; // SDK (m3d.cpp) stores verbatim, no clamp
    // MSS (m3d.cpp AIL_API_set_sample_occlusion): occlusion drives the low-pass
    // cutoff to (1-occlusion)+0.01 (obstruction, by contrast, only stores in the
    // software path). Reproduce that so occluded sources are muffled, not just
    // tracked.
    s.setLowPassNormalized((1.0 - s.v7_occlusion) + 0.01);
}
pub fn AIL_sample_occlusion(s_opt: ?*Sample) callconv(.winapi) f32 {
    const s = s_opt orelse return 0;
    return s.v7_occlusion;
}
pub fn AIL_set_sample_exclusion(s_opt: ?*Sample, exclusion: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.v7_exclusion = exclusion; // SDK (m3d.cpp) stores verbatim, no clamp
}
pub fn AIL_sample_exclusion(s_opt: ?*Sample) callconv(.winapi) f32 {
    const s = s_opt orelse return 0;
    return s.v7_exclusion;
}

// --- Listener (reuse the engine's miniaudio listener) ------------------------

pub fn AIL_listener_3D_position(dig_opt: ?*DigitalDriver, x: ?*f32, y: ?*f32, z: ?*f32) callconv(.winapi) void {
    const d = dig_opt orelse return;
    const v = d.getListenerPosition();
    if (x) |p| p.* = v.x;
    if (y) |p| p.* = v.y;
    if (z) |p| p.* = v.z;
}
pub fn AIL_listener_3D_velocity(dig_opt: ?*DigitalDriver, dx: ?*f32, dy: ?*f32, dz: ?*f32) callconv(.winapi) void {
    const d = dig_opt orelse return;
    const v = d.getListenerVelocity();
    if (dx) |p| p.* = v.x;
    if (dy) |p| p.* = v.y;
    if (dz) |p| p.* = v.z;
}
pub fn AIL_listener_3D_orientation(dig_opt: ?*DigitalDriver, fx: ?*f32, fy: ?*f32, fz: ?*f32, ux: ?*f32, uy: ?*f32, uz: ?*f32) callconv(.winapi) void {
    const d = dig_opt orelse return;
    const face = d.getListenerDirection();
    const up = d.getListenerWorldUp();
    if (fx) |p| p.* = face.x;
    if (fy) |p| p.* = face.y;
    if (fz) |p| p.* = face.z;
    if (ux) |p| p.* = up.x;
    if (uy) |p| p.* = up.y;
    if (uz) |p| p.* = up.z;
}
pub fn AIL_set_listener_3D_velocity_vector(dig_opt: ?*DigitalDriver, dx: f32, dy: f32, dz: f32) callconv(.winapi) void {
    const d = dig_opt orelse return;
    d.setListenerVelocity(dx, dy, dz);
}
pub fn AIL_update_listener_3D_position(dig_opt: ?*DigitalDriver, dt_ms: f32) callconv(.winapi) void {
    const dig = dig_opt orelse return;
    if (!(dt_ms == dt_ms) or std.math.isInf(dt_ms)) return; // NaN/Inf guard
    const dt_s = dt_ms / 1000.0;
    const p = dig.getListenerPosition();
    const v = dig.getListenerVelocity();
    dig.setListenerPosition(p.x + v.x * dt_s, p.y + v.y * dt_s, p.z + v.z * dt_s);
}

// --- Master volume / reverb / room (reuse DigitalDriver) ---------------------

pub fn AIL_digital_master_volume_level(dig_opt: ?*DigitalDriver) callconv(.winapi) f32 {
    const d = dig_opt orelse return 0;
    return d.getMasterVolume();
}
pub fn AIL_set_digital_master_volume_level(dig_opt: ?*DigitalDriver, master_volume: f32) callconv(.winapi) void {
    const d = dig_opt orelse return;
    d.setMasterVolume(std.math.clamp(master_volume, 0.0, 1.0));
}
pub fn AIL_set_digital_master_reverb(dig_opt: ?*DigitalDriver, bus_index: i32, reverb_decay_time: f32, reverb_predelay: f32, reverb_damping: f32) callconv(.winapi) void {
    _ = bus_index;
    const d = dig_opt orelse return;
    d.v7_master_reverb_decay = reverb_decay_time;
    d.v7_master_reverb_predelay = reverb_predelay;
    d.v7_master_reverb_damping = reverb_damping;
}
pub fn AIL_digital_master_reverb(dig_opt: ?*DigitalDriver, bus_index: i32, reverb_time: ?*f32, reverb_predelay: ?*f32, reverb_damping: ?*f32) callconv(.winapi) void {
    _ = bus_index;
    const d = dig_opt orelse return;
    if (reverb_time) |p| p.* = d.v7_master_reverb_decay;
    if (reverb_predelay) |p| p.* = d.v7_master_reverb_predelay;
    if (reverb_damping) |p| p.* = d.v7_master_reverb_damping;
}
pub fn AIL_set_digital_master_reverb_levels(dig_opt: ?*DigitalDriver, bus_index: i32, dry_level: f32, wet_level: f32) callconv(.winapi) void {
    _ = bus_index;
    const d = dig_opt orelse return;
    d.v7_master_reverb_dry = dry_level;
    d.v7_master_reverb_wet = wet_level;
}
pub fn AIL_digital_master_reverb_levels(dig_opt: ?*DigitalDriver, bus_index: i32, dry_level: ?*f32, wet_level: ?*f32) callconv(.winapi) void {
    _ = bus_index;
    const d = dig_opt orelse return;
    if (dry_level) |p| p.* = d.v7_master_reverb_dry;
    if (wet_level) |p| p.* = d.v7_master_reverb_wet;
}
pub fn AIL_set_room_type(dig_opt: ?*DigitalDriver, bus_index: i32, room_type: i32) callconv(.winapi) void {
    _ = bus_index;
    const d = dig_opt orelse return;
    d.v7_room_type = room_type;
}
pub fn AIL_room_type(dig_opt: ?*DigitalDriver, bus_index: i32) callconv(.winapi) i32 {
    _ = bus_index;
    const d = dig_opt orelse return 0;
    return d.v7_room_type;
}

// --- Redbook volume (reuse) --------------------------------------------------

// SDK: F32 AIL_redbook_set_volume_level(HREDBOOK, F32 volume) — returns the
// PREVIOUS volume level (F32 in ST(0)); returning void left a caller's float
// result undefined.
pub fn AIL_redbook_set_volume_level(hand: ?*Redbook, volume: f32) callconv(.winapi) f32 {
    const rb = hand orelse return 0;
    const old = @as(f32, @floatFromInt(rb.volume)) / 127.0;
    rb.volume = @intFromFloat(std.math.clamp(volume, 0.0, 1.0) * 127.0);
    return old;
}
pub fn AIL_redbook_volume_level(hand: ?*Redbook) callconv(.winapi) f32 {
    const rb = hand orelse return 0;
    return @as(f32, @floatFromInt(rb.volume)) / 127.0;
}

// --- Quick API extras (reuse) ------------------------------------------------

pub fn AIL_quick_set_low_pass_cut_off(audio: ?*Sample, channel: i32, cut_off: f32) callconv(.winapi) void {
    AIL_set_sample_low_pass_cut_off(audio, channel, cut_off);
}
pub fn AIL_quick_set_reverb_levels(audio: ?*Sample, dry_level: f32, wet_level: f32) callconv(.winapi) void {
    AIL_set_sample_reverb_levels(audio, dry_level, wet_level);
}

// --- Stream/DLS handle bridges ----------------------------------------------

pub fn AIL_stream_sample_handle(stream: ?*Sample) callconv(.winapi) ?*anyopaque {
    return @ptrCast(stream); // a stream IS a Sample in OpenMiles
}
pub fn AIL_DLS_sample_handle(dls: ?*MidiDriver) callconv(.winapi) ?*anyopaque {
    const d = dls orelse return null;
    // The DLS "sample" is the loaded SoundFont the driver renders MIDI through.
    return @ptrCast(d.soundfont);
}

// --- find_filter (reuse the built-in filter provider) ------------------------

pub fn AIL_find_filter(name: [*:0]const u8, ret: ?*?*openmiles.Provider) callconv(.winapi) i32 {
    _ = name;
    if (ret) |p| p.* = openmiles.startup_provider;
    return if (openmiles.startup_provider != null) 1 else 0;
}

// SDK returns S32 (integer percent in EAX), not F32.
pub fn AIL_background_CPU_percent() callconv(.winapi) i32 {
    return 0;
}

// --- Genuinely-new v7 subsystems: stubbed (no engine equivalent) -------------
// Multichannel speaker/receiver, output-filter providers, MP3 frame inspection,
// and pipeline-stage processors return defaults so v7 titles link and run.

pub fn AIL_sample_processor(s_opt: ?*Sample, pipeline_stage: i32) callconv(.winapi) ?*anyopaque {
    _ = s_opt;
    _ = pipeline_stage;
    return null;
}
pub fn AIL_digital_driver_processor(dig_opt: ?*DigitalDriver, pipeline_stage: i32) callconv(.winapi) ?*anyopaque {
    _ = dig_opt;
    _ = pipeline_stage;
    return null;
}
pub fn AIL_sample_stage_attribute(s_opt: ?*Sample, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    _ = s_opt;
    _ = name;
    _ = val;
}
pub fn AIL_set_sample_stage_preference(s_opt: ?*Sample, name: [*:0]const u8, val: *const anyopaque) callconv(.winapi) void {
    _ = s_opt;
    _ = name;
    _ = val;
}
pub fn AIL_enumerate_sample_stage_attributes(s_opt: ?*Sample, next: *?*anyopaque, dest: *anyopaque) callconv(.winapi) i32 {
    _ = s_opt;
    _ = dest;
    next.* = null;
    return 0;
}
// Number of source channels carried by the sample (S->n_channels).
fn sampleSourceChannels(s: *Sample) u32 {
    if (s.pcm_format) |f| return @max(1, f.channels);
    if (s.decoder) |d| return @max(1, @as(u32, d.outputChannels));
    return 1;
}
// speaker_enum_to_source_chan (wavefile.cpp): the source channel carrying an
// MSS_SPEAKER, derived from channel_mask — the Nth set bit maps to source N.
fn srcChanOf(s: *Sample, speaker: i32) i32 {
    if (speaker < 0 or speaker > 31) return -1;
    const bit = @as(u32, 1) << @intCast(speaker);
    if (s.channel_mask & bit == 0) return -1;
    const idx: u32 = @popCount(s.channel_mask & (bit - 1));
    return if (idx >= sampleSourceChannels(s)) -1 else @intCast(idx);
}
// Default mono/stereo routing (set_user_channel_defaults) used until the matrix
// is explicitly set: stereo source is identity; mono source feeds outputs 0 & 1.
fn defaultChannelLevel(s: *Sample, dest: usize, src: usize) f32 {
    if (sampleSourceChannels(s) >= 2) return if (dest < 2 and dest == src) 1.0 else 0.0;
    return if (src == 0 and dest < 2) 1.0 else 0.0;
}
fn logicalChannels(s: *Sample) usize {
    return @min(@as(usize, ma.ma_engine_get_channels(&s.driver.engine)), 9);
}
pub fn AIL_sample_channel_levels(s_opt: ?*Sample, src: ?*const anyopaque, dst: ?*const anyopaque, levels: ?*f32, n_levels: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    const src_idx: [*]const i32 = @ptrCast(@alignCast(src orelse return));
    const dst_idx: [*]const i32 = @ptrCast(@alignCast(dst orelse return));
    const lv: [*]f32 = @ptrCast(@alignCast(levels orelse return));
    if (n_levels <= 0) return;
    const row = openmiles_v8.output_speaker_index[logicalChannels(s)];
    var i: usize = 0;
    while (i < @as(usize, @intCast(n_levels))) : (i += 1) {
        const sc = srcChanOf(s, src_idx[i]);
        const dspk = dst_idx[i];
        const dc: i32 = if (dspk >= 0 and dspk <= openmiles_v8.SPK_MAX_INDEX) row[@intCast(dspk)] else -1;
        if (sc < 0 or dc < 0) {
            lv[i] = 0.0;
            continue;
        }
        lv[i] = if (s.user_channel_levels_set) s.user_channel_levels[@intCast(dc)][@intCast(sc)] else defaultChannelLevel(s, @intCast(dc), @intCast(sc));
    }
}
pub fn AIL_set_sample_channel_levels(s_opt: ?*Sample, src: ?*const anyopaque, dst: ?*const anyopaque, levels: ?*const f32, n_levels: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    // SDK: null source/dest/levels resets the matrix to the channel defaults.
    if (src == null or dst == null or levels == null) {
        s.user_channel_levels_set = false;
        return;
    }
    const src_idx: [*]const i32 = @ptrCast(@alignCast(src.?));
    const dst_idx: [*]const i32 = @ptrCast(@alignCast(dst.?));
    const lv: [*]const f32 = @ptrCast(@alignCast(levels.?));
    if (n_levels <= 0) return;
    // Materialize the current defaults before the first explicit edit so
    // unspecified entries keep their default routing.
    if (!s.user_channel_levels_set) {
        for (0..9) |d| for (0..9) |c| {
            s.user_channel_levels[d][c] = defaultChannelLevel(s, d, c);
        };
        s.user_channel_levels_set = true;
    }
    const row = openmiles_v8.output_speaker_index[logicalChannels(s)];
    var i: usize = 0;
    while (i < @as(usize, @intCast(n_levels))) : (i += 1) {
        const sc = srcChanOf(s, src_idx[i]);
        const dspk = dst_idx[i];
        const dc: i32 = if (dspk >= 0 and dspk <= openmiles_v8.SPK_MAX_INDEX) row[@intCast(dspk)] else -1;
        if (sc < 0 or dc < 0) continue;
        s.user_channel_levels[@intCast(dc)][@intCast(sc)] = lv[i];
    }
}
pub fn AIL_listener_relative_receiver_array(dig_opt: ?*DigitalDriver, n_receivers: ?*i32) callconv(.winapi) ?*anyopaque {
    _ = dig_opt orelse {
        if (n_receivers) |p| p.* = 0;
        return null;
    };
    if (n_receivers) |p| p.* = g_n_receiver_specs;
    return @ptrCast(&g_receiver_specs[0]); // SDK returns dig->D3D.receiver_specifications
}
pub fn AIL_set_listener_relative_receiver_array(dig_opt: ?*DigitalDriver, array: ?*anyopaque, n_receivers: i32) callconv(.winapi) void {
    // SDK (wavefile.cpp): clamp to MAX_RECEIVER_SPECS, store the count, and copy
    // the receiver specs in. A null driver is a no-op.
    _ = dig_opt orelse return;
    const n: i32 = @min(@max(n_receivers, 0), MAX_RECEIVER_SPECS);
    g_n_receiver_specs = n;
    if (n > 0) {
        if (array) |a| {
            const src: [*]const MSS_RECEIVER_LIST = @ptrCast(@alignCast(a));
            @memcpy(g_receiver_specs[0..@intCast(n)], src[0..@intCast(n)]);
        } else {
            g_n_receiver_specs = 0; // null array with a positive count = nothing stored
        }
    }
}
pub const MSSVECTOR3D = extern struct { x: f32, y: f32, z: f32 };
// MSS_RECEIVER_LIST (mss.h): one listener-relative receiver direction. No
// pointer fields, so its 88-byte layout is identical on 32- and 64-bit.
pub const MSS_RECEIVER_LIST = extern struct {
    direction: MSSVECTOR3D = .{ .x = 0, .y = 0, .z = 0 },
    speaker_index: [9]i32 = [_]i32{0} ** 9, // MAX_SPEAKERS
    speaker_level: [9]f32 = [_]f32{0} ** 9,
    n_speakers_affected: i32 = 0,
};
const MAX_RECEIVER_SPECS: i32 = 32;
var g_receiver_specs = [_]MSS_RECEIVER_LIST{.{}} ** 32; // dig->D3D.receiver_specifications
var g_n_receiver_specs: i32 = 0;
// Default stereo speaker layout (mssdig.cpp): left-handed frame (face=+Z,
// right=+X, up=+Y), speakers at ±45° -> x=∓1/√2, z=1/√2. Mutable storage so the
// returned pointer matches the SDK's driver-owned (writable) array.
const rsqrtf: f32 = 0.707106781;
// MAX_SPEAKERS positions; [0]/[1] default to the stereo ±45° layout, the rest 0.
var g_speaker_positions = [_]MSSVECTOR3D{
    .{ .x = -rsqrtf, .y = 0.0, .z = rsqrtf }, // front-left
    .{ .x = rsqrtf, .y = 0.0, .z = rsqrtf }, // front-right
} ++ [_]MSSVECTOR3D{.{ .x = 0, .y = 0, .z = 0 }} ** 7;
var g_falloff_power: f32 = 1.0; // D3D.falloff_power, set/queried via the pair below
pub fn AIL_speaker_configuration(dig_opt: ?*DigitalDriver, n_physical: ?*i32, n_logical: ?*i32, falloff_power: ?*f32, channel_spec: ?*anyopaque) callconv(.winapi) ?*MSSVECTOR3D {
    _ = dig_opt orelse return null; // SDK (wavefile.cpp): NULL dig -> NULL
    _ = channel_spec;
    if (n_physical) |p| p.* = 2;
    if (n_logical) |p| p.* = 2;
    if (falloff_power) |p| p.* = g_falloff_power;
    return &g_speaker_positions[0]; // SDK returns dig->D3D.speaker_positions
}
pub fn AIL_set_speaker_configuration(dig_opt: ?*DigitalDriver, array: ?*anyopaque, n_channels: i32, falloff_power: f32) callconv(.winapi) void {
    // SDK (wavefile.cpp): store falloff_power, then copy the first n_channels
    // speaker positions (any beyond n_channels keep their current values). A
    // null array / 0 count changes only the falloff power.
    _ = dig_opt orelse return;
    g_falloff_power = falloff_power;
    if (array) |a| {
        if (n_channels > 0) {
            const pos: [*]const MSSVECTOR3D = @ptrCast(@alignCast(a));
            const n: usize = @min(@as(usize, @intCast(n_channels)), g_speaker_positions.len);
            @memcpy(g_speaker_positions[0..n], pos[0..n]);
        }
    }
}
// output_speaker_order[m][channel] = the MSS_SPEAKER for output channel in an
// m-channel config (wavefile.cpp). Only the first m entries are valid (-1 fill).
fn ord(comptime prefix: []const i32) [18]i32 {
    var r = [_]i32{-1} ** 18;
    for (prefix, 0..) |v, i| r[i] = v;
    return r;
}
// FL=0 FR=1 FC=2 LFE=3 BL=4 BR=5 BC=8 SL=9 SR=10
const output_speaker_order = [10][18]i32{
    ord(&.{}), ord(&.{0}), ord(&.{ 0, 1 }), ord(&.{ 0, 1, 8 }),
    ord(&.{ 0, 1, 4, 5 }), ord(&.{ 0, 1, 2, 4, 5 }), ord(&.{ 0, 1, 2, 3, 4, 5 }),
    ord(&.{ 0, 1, 2, 3, 4, 5, 8 }), ord(&.{ 0, 1, 2, 3, 4, 5, 9, 10 }), ord(&.{ 0, 1, 2, 3, 4, 5, 8, 9, 10 }),
};
var g_speaker_wet_reverb = [_]f32{1.0} ** 9; // D3D.speaker_wet_reverb_response
var g_speaker_dry_reverb = [_]f32{1.0} ** 9; // D3D.speaker_dry_reverb_response
fn drvLogical(d: *DigitalDriver) usize {
    return @min(@as(usize, ma.ma_engine_get_channels(&d.engine)), 9);
}
pub fn AIL_speaker_reverb_levels(dig_opt: ?*DigitalDriver, wet_array: ?*?*f32, dry_array: ?*?*f32, speaker_index_array: ?*?*const anyopaque) callconv(.winapi) i32 {
    // SDK (wavefile.cpp): hand back pointers to the driver's per-speaker wet/dry
    // reverb response arrays and the speaker order, returning the channel count.
    const d = dig_opt orelse return 0;
    const logical = drvLogical(d);
    if (logical == 0) return 0;
    if (speaker_index_array) |p| p.* = @ptrCast(&output_speaker_order[logical][0]);
    if (wet_array) |p| p.* = &g_speaker_wet_reverb[0];
    if (dry_array) |p| p.* = &g_speaker_dry_reverb[0];
    return @intCast(logical);
}
pub fn AIL_set_speaker_reverb_levels(dig_opt: ?*DigitalDriver, wet_array: ?*const f32, dry_array: ?*const f32, speaker_index_array: ?*const anyopaque, n_levels: i32) callconv(.winapi) void {
    // SDK (wavefile.cpp): a null wet/speaker (resp. dry/speaker) array resets
    // that response to 1.0; a null speaker array returns after resetting; else
    // store per-speaker levels at the mapped driver channel.
    const d = dig_opt orelse return;
    const logical = drvLogical(d);
    if (logical == 0) return;
    if (wet_array == null or speaker_index_array == null) {
        for (0..logical) |i| g_speaker_wet_reverb[i] = 1.0;
    }
    if (dry_array == null or speaker_index_array == null) {
        for (0..logical) |i| g_speaker_dry_reverb[i] = 1.0;
    }
    const spk = speaker_index_array orelse return;
    const spks: [*]const i32 = @ptrCast(@alignCast(spk));
    const n: usize = @min(@as(usize, @intCast(@max(n_levels, 0))), logical);
    const row = openmiles_v8.output_speaker_index[logical];
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const s = spks[i];
        const dch: i32 = if (s >= 0 and s <= openmiles_v8.SPK_MAX_INDEX) row[@intCast(s)] else -1;
        if (dch < 0) continue;
        if (wet_array) |w| {
            const wp: [*]const f32 = @ptrCast(@alignCast(w));
            g_speaker_wet_reverb[@intCast(dch)] = wp[i];
        }
        if (dry_array) |dr| {
            const dp: [*]const f32 = @ptrCast(@alignCast(dr));
            g_speaker_dry_reverb[@intCast(dch)] = dp[i];
        }
    }
}
// Real MSS computes per-speaker gains for a positioned 3D source. The full
// panning/falloff math has no miniaudio equivalent (ma_sound spatializes
// internally), so these report success and leave the caller's channel_levels
// untouched. The signature grew across versions: v7 @56 (14 args), v8+ @68
// (adds listener up-vector + doppler velocity/shift).
pub fn AIL_calculate_3D_channel_levels(
    dig: ?*DigitalDriver,
    channel_levels: ?*f32,
    speaker_array: ?*anyopaque,
    src_pos: ?*anyopaque,
    src_face: ?*anyopaque,
    src_up: ?*anyopaque,
    src_inner_angle: f32,
    src_outer_angle: f32,
    src_outer_volume: f32,
    src_max_dist: f32,
    src_min_dist: f32,
    listen_pos: ?*anyopaque,
    listen_face: ?*anyopaque,
    listen_up: ?*anyopaque,
    rolloff_factor: f32,
    doppler_velocity: ?*anyopaque,
    doppler_shift: ?*f32,
) callconv(.winapi) i32 {
    _ = dig;
    _ = channel_levels;
    _ = speaker_array;
    _ = src_pos;
    _ = src_face;
    _ = src_up;
    _ = src_inner_angle;
    _ = src_outer_angle;
    _ = src_outer_volume;
    _ = src_max_dist;
    _ = src_min_dist;
    _ = listen_pos;
    _ = listen_face;
    _ = listen_up;
    _ = rolloff_factor;
    _ = doppler_velocity;
    if (doppler_shift) |p| p.* = 1.0; // no pitch shift
    return 0;
}
// v7 form: 14 args @56 (no listener up-vector / doppler). Exported as
// _AIL_calculate_3D_channel_levels@56 for v7 only.
pub fn AIL_calculate_3D_channel_levels_v7(
    dig: ?*DigitalDriver,
    channel_levels: ?*f32,
    speaker_array: ?*anyopaque,
    src_pos: ?*anyopaque,
    src_face: ?*anyopaque,
    src_up: ?*anyopaque,
    src_inner_angle: f32,
    src_outer_angle: f32,
    src_outer_volume: f32,
    src_max_dist: f32,
    src_min_dist: f32,
    listen_pos: ?*anyopaque,
    listen_face: ?*anyopaque,
    rolloff_factor: f32,
) callconv(.winapi) i32 {
    _ = dig;
    _ = channel_levels;
    _ = speaker_array;
    _ = src_pos;
    _ = src_face;
    _ = src_up;
    _ = src_inner_angle;
    _ = src_outer_angle;
    _ = src_outer_volume;
    _ = src_max_dist;
    _ = src_min_dist;
    _ = listen_pos;
    _ = listen_face;
    _ = rolloff_factor;
    return 0;
}
pub fn AIL_digital_output_filter(dig_opt: ?*DigitalDriver) callconv(.winapi) ?*anyopaque {
    _ = dig_opt;
    return null;
}
pub fn AIL_output_filter_driver_attribute(lib: ?*anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    _ = lib;
    _ = name;
    _ = val;
}
pub fn AIL_set_output_filter_driver_preference(lib: ?*anyopaque, name: [*:0]const u8, val: *const anyopaque) callconv(.winapi) void {
    _ = lib;
    _ = name;
    _ = val;
}
pub fn AIL_enumerate_output_filter_driver_attributes(lib: ?*anyopaque, next: *?*anyopaque, dest: *anyopaque) callconv(.winapi) i32 {
    _ = lib;
    _ = dest;
    next.* = null;
    return 0;
}
pub fn AIL_enumerate_output_filter_sample_attributes(lib: ?*anyopaque, next: *?*anyopaque, dest: *anyopaque) callconv(.winapi) i32 {
    _ = lib;
    _ = dest;
    next.* = null;
    return 0;
}
pub fn AIL_inspect_MP3(inspection_state: ?*anyopaque, mp3_image: ?*anyopaque, image_size: i32) callconv(.winapi) i32 {
    const es: *openmiles.mp3.MP3_INFO = @ptrCast(@alignCast(inspection_state orelse return 0));
    const img: [*]u8 = @ptrCast(mp3_image orelse {
        es.* = .{};
        return 0;
    });
    if (image_size <= 0) {
        es.* = .{};
        return 0;
    }
    openmiles.mp3.inspect(es, img, image_size);
    return 1;
}
pub fn AIL_enumerate_MP3_frames(inspection_state: ?*anyopaque) callconv(.winapi) i32 {
    const es: *openmiles.mp3.MP3_INFO = @ptrCast(@alignCast(inspection_state orelse return 0));
    return openmiles.mp3.enumerateFrames(es);
}
pub fn RIB_load_static_provider_library(main_fn: ?*anyopaque, description: [*:0]const u8) callconv(.winapi) ?*anyopaque {
    _ = main_fn;
    _ = description;
    return null;
}
pub fn RIB_MAIN(self: ?*anyopaque, dll_name: [*:0]const u8) callconv(.winapi) i32 {
    _ = self;
    _ = dll_name;
    return 0;
}

// v7/v8 ABI: the master-reverb, room-type and low-pass-cutoff calls predate the
// v9 bus mixer, so they lack the bus_index/channel parameter that v9 inserted as
// the second argument. These narrower variants (ver 70..80) forward to the v9
// implementations targeting the default bus/channel 0; the v9 build exports the
// wider forms above.
pub fn AIL_room_type_v7(dig_opt: ?*DigitalDriver) callconv(.winapi) i32 {
    return AIL_room_type(dig_opt, 0);
}
pub fn AIL_set_room_type_v7(dig_opt: ?*DigitalDriver, room_type: i32) callconv(.winapi) void {
    AIL_set_room_type(dig_opt, 0, room_type);
}
// 6.5/6.6-only spelling of the master room-type setter (@8: driver, room_type).
pub fn AIL_set_digital_master_room_type(dig_opt: ?*DigitalDriver, room_type: i32) callconv(.winapi) void {
    AIL_set_room_type(dig_opt, 0, room_type);
}
pub fn AIL_digital_master_reverb_v7(dig_opt: ?*DigitalDriver, reverb_time: ?*f32, reverb_predelay: ?*f32, reverb_damping: ?*f32) callconv(.winapi) void {
    AIL_digital_master_reverb(dig_opt, 0, reverb_time, reverb_predelay, reverb_damping);
}
pub fn AIL_set_digital_master_reverb_v7(dig_opt: ?*DigitalDriver, reverb_decay_time: f32, reverb_predelay: f32, reverb_damping: f32) callconv(.winapi) void {
    AIL_set_digital_master_reverb(dig_opt, 0, reverb_decay_time, reverb_predelay, reverb_damping);
}
pub fn AIL_digital_master_reverb_levels_v7(dig_opt: ?*DigitalDriver, dry_level: ?*f32, wet_level: ?*f32) callconv(.winapi) void {
    AIL_digital_master_reverb_levels(dig_opt, 0, dry_level, wet_level);
}
pub fn AIL_set_digital_master_reverb_levels_v7(dig_opt: ?*DigitalDriver, dry_level: f32, wet_level: f32) callconv(.winapi) void {
    AIL_set_digital_master_reverb_levels(dig_opt, 0, dry_level, wet_level);
}
pub fn AIL_sample_low_pass_cut_off_v7(s_opt: ?*Sample) callconv(.winapi) f32 {
    return AIL_sample_low_pass_cut_off(s_opt, 0);
}
pub fn AIL_set_sample_low_pass_cut_off_v7(s_opt: ?*Sample, cut_off: f32) callconv(.winapi) void {
    AIL_set_sample_low_pass_cut_off(s_opt, 0, cut_off);
}
pub fn AIL_quick_set_low_pass_cut_off_v7(audio: ?*Sample, cut_off: f32) callconv(.winapi) void {
    AIL_quick_set_low_pass_cut_off(audio, 0, cut_off);
}

// --- v7-only ABI variants (arities that differ from v8/v9) -------------------
// These match the exact stdcall decoration the 7.0b mss32.dll exports. Where v7
// carried extra parameters later dropped (the DSP stage index, the per-call
// channel-level source/dest matrices), the variant accepts them for ABI fidelity
// and forwards the meaningful arguments to the v8/v9 implementation.

// stage DSP attributes were v7-only and carried a stage index as the second arg.
pub fn AIL_sample_stage_attribute_v7(s_opt: ?*Sample, stage_index: i32, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    _ = stage_index;
    AIL_sample_stage_attribute(s_opt, name, val);
}
pub fn AIL_set_sample_stage_preference_v7(s_opt: ?*Sample, stage_index: i32, name: [*:0]const u8, val: *const anyopaque) callconv(.winapi) void {
    _ = stage_index;
    AIL_set_sample_stage_preference(s_opt, name, val);
}
pub fn AIL_enumerate_sample_stage_attributes_v7(s_opt: ?*Sample, stage_index: i32, next: *?*anyopaque, dest: *anyopaque) callconv(.winapi) i32 {
    _ = stage_index;
    return AIL_enumerate_sample_stage_attributes(s_opt, next, dest);
}
// channel levels: v7 @8/@12 lacked the src/dst speaker-matrix pointers v8 added.
pub fn AIL_sample_channel_levels_v7(s_opt: ?*Sample, levels: ?*f32) callconv(.winapi) void {
    AIL_sample_channel_levels(s_opt, null, null, levels, 0);
}
pub fn AIL_set_sample_channel_levels_v7(s_opt: ?*Sample, levels: ?*const f32, n_levels: i32) callconv(.winapi) void {
    AIL_set_sample_channel_levels(s_opt, null, null, levels, n_levels);
}
// speaker reverb levels: v7 @16 lacked the per-speaker index array v8 added.
pub fn AIL_set_speaker_reverb_levels_v7(dig_opt: ?*DigitalDriver, wet_array: ?*f32, dry_array: ?*f32, n_levels: i32) callconv(.winapi) void {
    AIL_set_speaker_reverb_levels(dig_opt, wet_array, dry_array, null, n_levels);
}

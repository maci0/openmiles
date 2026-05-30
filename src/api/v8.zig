//! MSS v8 additive API (stubbed). Soundbank/event/preset system, 5.1
//! surround, in-memory I/O, WAV markers, util helpers — gated at v8+ and
//! additive over v3-v7. Signatures from the MSS 9.x SDK mss.h. These subsystems
//! have no OpenMiles engine equivalent yet, so they link and return safe defaults.
const std = @import("std");
const openmiles = @import("openmiles");

pub export fn AIL_WAV_marker_by_index(a0: ?*anyopaque, a1: i32, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_WAV_marker_by_name(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub export fn AIL_WAV_marker_count(a0: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    return 0;
}
pub export fn AIL_add_apply_environment_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: i32) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_add_cache_sounds_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_add_comment_event_step(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub export fn AIL_add_control_sounds_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque, a4: ?*anyopaque, a5: ?*anyopaque, a6: i32, a7: f32, a8: i32, a9: i32) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    _ = a5;
    _ = a6;
    _ = a7;
    _ = a8;
    _ = a9;
    return 0;
}
pub export fn AIL_add_persist_preset_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque, a4: i32) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    return 0;
}
pub export fn AIL_add_sound_limit_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_add_start_sound_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: i32, a4: ?*anyopaque, a5: ?*anyopaque, a6: ?*anyopaque, a7: ?*anyopaque, a8: ?*anyopaque, a9: ?*anyopaque, a10: u32, a11: i32, a12: i32, a13: i32, a14: i32, a15: i32, a16: ?*anyopaque, a17: f32, a18: f32, a19: f32, a20: f32, a21: f32, a22: i32, a23: i32) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    _ = a5;
    _ = a6;
    _ = a7;
    _ = a8;
    _ = a9;
    _ = a10;
    _ = a11;
    _ = a12;
    _ = a13;
    _ = a14;
    _ = a15;
    _ = a16;
    _ = a17;
    _ = a18;
    _ = a19;
    _ = a20;
    _ = a21;
    _ = a22;
    _ = a23;
    return 0;
}
pub export fn AIL_add_uncache_sounds_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_apply_environment_preset(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_apply_sound_preset(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_close_event(a0: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    _ = a0;
    return null;
}
pub export fn AIL_close_soundbank(a0: ?*anyopaque) callconv(.winapi) void {
    _ = a0;

}
pub export fn AIL_create_event() callconv(.winapi) ?*anyopaque {
    return null;
}
pub export fn AIL_debug(a0: ?*anyopaque) callconv(.winapi) void {
    _ = a0;

}
pub export fn AIL_debug_log(a0: ?*anyopaque) callconv(.winapi) void {
    _ = a0;

}
pub export fn AIL_enumerate_environment_presets(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    return 0;
}
pub export fn AIL_enumerate_events(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    return 0;
}
pub export fn AIL_enumerate_filter_properties(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_enumerate_filter_sample_properties(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_enumerate_output_filter_driver_properties(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_enumerate_output_filter_sample_properties(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_enumerate_sample_stage_properties(a0: ?*anyopaque, a1: i32, a2: ?*anyopaque, a3: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    return 0;
}
pub export fn AIL_enumerate_sound_assets(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_enumerate_sound_presets(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    return 0;
}
pub export fn AIL_file_type_named(a0: ?*anyopaque, a1: ?*anyopaque, a2: u32) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_filter_property(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque, a4: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    return 0;
}
pub export fn AIL_find_marker_in_list(a0: i32, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_ftoa(a0: f32, a1: ?*anyopaque) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub export fn AIL_get_event_contents(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_get_marker_list(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub export fn AIL_get_soundbank_filename(a0: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    _ = a0;
    return null;
}
pub export fn AIL_get_soundbank_mem_usage(a0: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    return 0;
}
pub export fn AIL_indent(a0: i32) callconv(.winapi) void {
    _ = a0;

}
pub export fn AIL_mem_close(a0: ?*anyopaque) callconv(.winapi) void {
    _ = a0;

}
pub export fn AIL_mem_create(a0: i32) callconv(.winapi) void {
    _ = a0;

}
pub export fn AIL_mem_create_from_existing(a0: ?*anyopaque, a1: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub export fn AIL_mem_error(a0: ?*anyopaque) callconv(.winapi) void {
    _ = a0;

}
pub export fn AIL_mem_open(a0: ?*anyopaque, a1: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub export fn AIL_mem_pos(a0: ?*anyopaque) callconv(.winapi) void {
    _ = a0;

}
pub export fn AIL_mem_printc(a0: ?*anyopaque, a1: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub export fn AIL_mem_printf(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub export fn AIL_mem_prints(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub export fn AIL_mem_read(a0: ?*anyopaque, a1: ?*anyopaque, a2: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;

}
pub export fn AIL_mem_seek(a0: ?*anyopaque, a1: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub export fn AIL_mem_size(a0: ?*anyopaque) callconv(.winapi) void {
    _ = a0;

}
pub export fn AIL_mem_write(a0: ?*anyopaque, a1: ?*anyopaque, a2: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;

}
pub export fn AIL_next_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: i32) callconv(.winapi) ?*anyopaque {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    return null;
}
pub export fn AIL_open_soundbank(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    _ = a0;
    _ = a1;
    return null;
}
pub export fn AIL_output_filter_driver_property(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque, a4: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    return 0;
}
pub export fn AIL_platform_property(a0: ?*anyopaque, a1: i32, a2: ?*anyopaque, a3: ?*anyopaque, a4: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    return 0;
}
pub export fn AIL_register_falloff_function_callback(a0: ?*anyopaque, a1: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub export fn AIL_register_trace_callback(a0: ?*anyopaque) callconv(.winapi) void {
    _ = a0;

}
pub export fn AIL_sample_51_volume_levels(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque, a4: ?*anyopaque, a5: ?*anyopaque, a6: ?*anyopaque) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    _ = a5;
    _ = a6;

}
pub export fn AIL_sample_51_volume_pan(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque, a4: ?*anyopaque, a5: ?*anyopaque) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    _ = a5;

}
pub export fn AIL_sample_buffer_available(a0: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    return 0;
}
pub export fn AIL_sample_buffer_count(a0: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    return 0;
}
pub export fn AIL_sample_channel_count(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub export fn AIL_sample_loop_block(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_sample_output_levels(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque, a4: i32) callconv(.winapi) f32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    return 0;
}
pub export fn AIL_sample_playback_delay(a0: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    return 0;
}
pub export fn AIL_sample_playback_rate_factor(a0: ?*anyopaque) callconv(.winapi) f32 {
    _ = a0;
    return 0;
}
pub export fn AIL_sample_speaker_scale_factors(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;

}
pub export fn AIL_sample_stage_property(a0: ?*anyopaque, a1: i32, a2: ?*anyopaque, a3: i32, a4: ?*anyopaque, a5: ?*anyopaque, a6: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    _ = a5;
    _ = a6;
    return 0;
}
pub export fn AIL_set_sample_51_volume_levels(a0: ?*anyopaque, a1: f32, a2: f32, a3: f32, a4: f32, a5: f32, a6: f32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    _ = a5;
    _ = a6;

}
pub export fn AIL_set_sample_51_volume_pan(a0: ?*anyopaque, a1: f32, a2: f32, a3: f32, a4: f32, a5: f32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    _ = a5;

}
pub export fn AIL_set_sample_buffer_count(a0: ?*anyopaque, a1: i32) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub export fn AIL_set_sample_is_3D(a0: ?*anyopaque, a1: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub export fn AIL_set_sample_playback_delay(a0: ?*anyopaque, a1: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub export fn AIL_set_sample_playback_rate_factor(a0: ?*anyopaque, a1: f32) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub export fn AIL_set_sample_speaker_scale_factors(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;

}
pub export fn AIL_sound_asset_filename(a0: ?*anyopaque, a1: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub export fn AIL_stricmp(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub export fn AIL_strnicmp(a0: ?*anyopaque, a1: ?*anyopaque, a2: u32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;

}
pub export fn AIL_sys_debug(a0: ?*anyopaque) callconv(.winapi) void {
    _ = a0;

}
pub export fn AIL_unapply_environment_preset(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_unapply_sound_preset(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}

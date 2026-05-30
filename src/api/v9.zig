//! MSS v9 additive API (stubbed). Soundbank/event/preset system, 5.1
//! surround, in-memory I/O, WAV markers, util helpers — gated at v9+ and
//! additive over v3-v7. Signatures from the MSS 9.x SDK mss.h. These subsystems
//! have no OpenMiles engine equivalent yet, so they link and return safe defaults.
const std = @import("std");
const openmiles = @import("openmiles");

pub export fn AIL_IO_thread_handle(a0: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    return 0;
}
pub export fn AIL_add_clear_state_event_step(a0: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    return 0;
}
pub export fn AIL_add_exec_event_event_step(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub export fn AIL_add_ramp_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: f32, a4: ?*anyopaque, a5: i32, a6: i32, a7: i32) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    _ = a5;
    _ = a6;
    _ = a7;
    return 0;
}
pub export fn AIL_add_setblend_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: i32, a3: ?*anyopaque, a4: ?*anyopaque, a5: ?*anyopaque, a6: ?*anyopaque, a7: ?*anyopaque, a8: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    _ = a5;
    _ = a6;
    _ = a7;
    _ = a8;
    return 0;
}
pub export fn AIL_apply_raw_environment_preset(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub export fn AIL_apply_raw_sound_preset(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub export fn AIL_configure_logging(a0: ?*anyopaque, a1: i32, a2: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;

}
pub export fn AIL_file_callbacks(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;

}
pub export fn AIL_file_read_info(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: u32) callconv(.winapi) ?*anyopaque {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    return null;
}
pub export fn AIL_file_size_info(a0: ?*anyopaque, a1: ?*anyopaque, a2: u32) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_find_environment_preset(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    _ = a0;
    _ = a1;
    return null;
}
pub export fn AIL_find_sound_preset(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    _ = a0;
    _ = a1;
    return null;
}
pub export fn AIL_get_soundbank_name(a0: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    _ = a0;
    return null;
}
pub export fn AIL_get_time() callconv(.winapi) u64 {
    return openmiles.getUsCount64(); // Miles "time" is a microsecond tick
}
pub export fn AIL_mem_alloc_lock_info(a0: u32, a1: ?*anyopaque, a2: u32) callconv(.winapi) ?*anyopaque {
    _ = a0;
    _ = a1;
    _ = a2;
    return null;
}
pub export fn AIL_ms_count64() callconv(.winapi) u64 {
    return openmiles.getMsCount64();
}
pub export fn AIL_ms_to_time(ms: u64) callconv(.winapi) u64 {
    return ms *| 1000; // ms -> microsecond ticks
}
pub export fn AIL_resolve_raw_environment_preset(a0: ?*anyopaque, a1: i32) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub export fn AIL_resolve_raw_sound_preset(a0: ?*anyopaque, a1: ?*anyopaque, a2: i32) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_sample_loaded_len(a0: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    return 0;
}
pub export fn AIL_sample_ms_lookup(a0: ?*anyopaque, a1: i32, a2: ?*anyopaque) callconv(.winapi) u32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub export fn AIL_sleep(ms: u32) callconv(.winapi) void {
    openmiles.io.sleep(std.Io.Duration.fromNanoseconds(@as(u64, ms) *| std.time.ns_per_ms), .awake) catch {};
}
pub export fn AIL_sound_asset_info(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    return 0;
}
pub export fn AIL_stream_filled_percent(a0: ?*anyopaque) callconv(.winapi) f32 {
    _ = a0;
    return 0;
}
pub export fn AIL_time_to_ms(t: u64) callconv(.winapi) u64 {
    return t / 1000;
}
pub export fn AIL_timer_thread_handle(a0: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    return 0;
}
pub export fn AIL_unapply_raw_environment_preset(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub export fn AIL_unapply_raw_sound_preset(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub export fn AIL_us_count64() callconv(.winapi) u64 {
    return openmiles.getUsCount64();
}

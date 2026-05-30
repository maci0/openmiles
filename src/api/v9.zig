//! MSS v9 additive API (stubbed). Soundbank/event/preset system, 5.1
//! surround, in-memory I/O, WAV markers, util helpers — gated at v9+ and
//! additive over v3-v7. Signatures from the MSS 9.x SDK mss.h. These subsystems
//! have no OpenMiles engine equivalent yet, so they link and return safe defaults.
const std = @import("std");
const openmiles = @import("openmiles");

pub fn AIL_IO_thread_handle(a0: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    return 0;
}

// --- v9 per-sample attributes (synchronized control / buses / system levels) ---
const Sample = openmiles.Sample;
pub fn AIL_set_sample_id(s_opt: ?*Sample, id: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.v9_id = id;
}
pub fn AIL_sample_id(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return s.v9_id;
}
pub fn AIL_set_sample_bus(s_opt: ?*Sample, bus_index: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.v9_bus = bus_index;
}
pub fn AIL_sample_bus(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return s.v9_bus;
}
pub fn AIL_set_sample_level_mask(s_opt: ?*Sample, mask: u8) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.v9_level_mask = mask;
}
pub fn AIL_sample_level_mask(s_opt: ?*Sample) callconv(.winapi) u8 {
    const s = s_opt orelse return 0;
    return s.v9_level_mask;
}
pub fn AIL_set_sample_3D_spread(s_opt: ?*Sample, spread: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.v9_spread = spread;
}
pub fn AIL_add_clear_state_event_step(a0: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    return 0;
}
pub fn AIL_add_exec_event_event_step(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub fn AIL_add_ramp_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: f32, a4: ?*anyopaque, a5: i32, a6: i32, a7: i32) callconv(.winapi) i32 {
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
pub fn AIL_add_setblend_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: i32, a3: ?*anyopaque, a4: ?*anyopaque, a5: ?*anyopaque, a6: ?*anyopaque, a7: ?*anyopaque, a8: ?*anyopaque) callconv(.winapi) i32 {
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
pub fn AIL_apply_raw_environment_preset(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub fn AIL_apply_raw_sound_preset(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub fn AIL_configure_logging(a0: ?*anyopaque, a1: i32, a2: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;

}
pub fn AIL_file_callbacks(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;

}
pub fn AIL_file_read_info(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: u32) callconv(.winapi) ?*anyopaque {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    return null;
}
pub fn AIL_file_size_info(a0: ?*anyopaque, a1: ?*anyopaque, a2: u32) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub fn AIL_find_environment_preset(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    _ = a0;
    _ = a1;
    return null;
}
pub fn AIL_find_sound_preset(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    _ = a0;
    _ = a1;
    return null;
}
pub fn AIL_get_soundbank_name(bank: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const b: *openmiles.Bank = @ptrCast(@alignCast(bank orelse return null));
    return @constCast(@ptrCast(b.name()));
}
pub fn AIL_get_time() callconv(.winapi) u64 {
    return openmiles.getUsCount64(); // Miles "time" is a microsecond tick
}
pub fn AIL_mem_alloc_lock_info(a0: u32, a1: ?*anyopaque, a2: u32) callconv(.winapi) ?*anyopaque {
    _ = a0;
    _ = a1;
    _ = a2;
    return null;
}
pub fn AIL_ms_count64() callconv(.winapi) u64 {
    return openmiles.getMsCount64();
}
pub fn AIL_ms_to_time(ms: u64) callconv(.winapi) u64 {
    return ms *| 1000; // ms -> microsecond ticks
}
pub fn AIL_resolve_raw_environment_preset(a0: ?*anyopaque, a1: i32) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub fn AIL_resolve_raw_sound_preset(a0: ?*anyopaque, a1: ?*anyopaque, a2: i32) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub fn AIL_sample_loaded_len(a0: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    return 0;
}
pub fn AIL_sample_ms_lookup(a0: ?*anyopaque, a1: i32, a2: ?*anyopaque) callconv(.winapi) u32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub fn AIL_sleep(ms: u32) callconv(.winapi) void {
    openmiles.io.sleep(std.Io.Duration.fromNanoseconds(@as(u64, ms) *| std.time.ns_per_ms), .awake) catch {};
}
pub fn AIL_sound_asset_info(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    return 0;
}
pub fn AIL_stream_filled_percent(a0: ?*anyopaque) callconv(.winapi) f32 {
    _ = a0;
    return 0;
}
pub fn AIL_time_to_ms(t: u64) callconv(.winapi) u64 {
    return t / 1000;
}
pub fn AIL_timer_thread_handle(a0: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    return 0;
}
pub fn AIL_unapply_raw_environment_preset(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub fn AIL_unapply_raw_sound_preset(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub fn AIL_us_count64() callconv(.winapi) u64 {
    return openmiles.getUsCount64();
}

// =============================================================================
// v9 advanced subsystems. OpenMiles has no engine equivalent for the bus mixer,
// event command queue, sample groups, or system-state stack yet, so these link
// with the SDK-correct signatures (exact stdcall stack sizes) and return safe
// defaults. The few with a direct mapping onto our Sample do real work.
// =============================================================================
const DigitalDriver = openmiles.DigitalDriver;

// --- Bus mixer / limiter ---
pub fn AIL_allocate_bus(dig: ?*DigitalDriver) callconv(.winapi) ?*anyopaque {
    _ = dig;
    return null;
}
pub fn AIL_free_all_busses(dig: ?*DigitalDriver) callconv(.winapi) void {
    _ = dig;
}
pub fn AIL_bus_sample_handle(dig: ?*DigitalDriver, bus_index: i32) callconv(.winapi) ?*anyopaque {
    _ = dig;
    _ = bus_index;
    return null;
}
pub fn AIL_enable_limiter(dig: ?*DigitalDriver, on_off: i32) callconv(.winapi) void {
    _ = dig;
    _ = on_off;
}
pub fn AIL_bus_enable_limiter(dig: ?*DigitalDriver, bus_index: i32, on_off: i32) callconv(.winapi) void {
    _ = dig;
    _ = bus_index;
    _ = on_off;
}
pub fn AIL_install_bus_compressor(dig: ?*DigitalDriver, bus_index: i32, filter_stage: i32, input_bus_index: i32) callconv(.winapi) i32 {
    _ = dig;
    _ = bus_index;
    _ = filter_stage;
    _ = input_bus_index;
    return 0;
}

// --- Mixer status / scheduling / per-sample misc ---
pub fn AIL_digital_mixed_samples(dig: ?*DigitalDriver) callconv(.winapi) u64 {
    _ = dig;
    return 0;
}
pub fn AIL_register_mix_callback(dig: ?*DigitalDriver, mixcb: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    _ = dig;
    _ = mixcb;
    return null;
}
pub fn AIL_end_fade_sample(s_opt: ?*Sample) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.stop();
}
pub fn AIL_sample_mixed_ms(s_opt: ?*Sample) callconv(.winapi) u32 {
    const s = s_opt orelse return 0;
    const cur = s.getMsPosition().current;
    return if (cur > 0) @intCast(cur) else 0;
}
pub fn AIL_sample_schedule_time(s_opt: ?*Sample) callconv(.winapi) u64 {
    _ = s_opt;
    return 0;
}
pub fn AIL_schedule_start_sample(s_opt: ?*Sample, mix_time_to_start: u64) callconv(.winapi) void {
    const s = s_opt orelse return;
    _ = mix_time_to_start;
    s.start();
}
pub fn AIL_set_sample_loop_samples(s_opt: ?*Sample, loop_start_samples: i32, loop_end_samples: i32) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    s.loop_start_frame = if (loop_start_samples > 0) @intCast(loop_start_samples) else 0;
    s.loop_end_frame = if (loop_end_samples > 0) @intCast(loop_end_samples) else 0;
    return 1;
}

// --- System-state stack ---
pub fn AIL_push_system_state(dig: ?*DigitalDriver, flags: u32, crossfade_ms: i32) callconv(.winapi) void {
    _ = dig;
    _ = flags;
    _ = crossfade_ms;
}
pub fn AIL_pop_system_state(dig: ?*DigitalDriver, crossfade_ms: i32) callconv(.winapi) void {
    _ = dig;
    _ = crossfade_ms;
}
pub fn AIL_system_state_level(dig: ?*DigitalDriver) callconv(.winapi) u8 {
    _ = dig;
    return 0;
}
pub fn AIL_set_async_callbacks(read: ?*anyopaque, cancel: ?*anyopaque, status: ?*anyopaque, a3: ?*anyopaque, a4: ?*anyopaque, a5: ?*anyopaque, a6: ?*anyopaque) callconv(.winapi) void {
    _ = read;
    _ = cancel;
    _ = status;
    _ = a3;
    _ = a4;
    _ = a5;
    _ = a6;
}

// --- Synchronized sample groups ---
// Sample groups act on every HSAMPLE whose id matches; the matched samples are
// then re-tagged with `set_to_id` so they can be controlled as a new group.
const GroupOp = enum { start, stop, unpause };
fn sampleGroup(dig: ?*DigitalDriver, match_id: i32, set_to_id: i32, op: GroupOp) void {
    const d = dig orelse return;
    for (d.samples.items) |s| {
        if (s.v9_id != match_id) continue;
        switch (op) {
            .start => s.start(),
            .stop => s.stop(),
            .unpause => s.resumePlayback(),
        }
        s.v9_id = set_to_id;
    }
}
pub fn AIL_start_sample_group(dig: ?*DigitalDriver, start_id: i32, set_to_id: i32) callconv(.winapi) void {
    sampleGroup(dig, start_id, set_to_id, .start);
}
pub fn AIL_stop_sample_group(dig: ?*DigitalDriver, stop_id: i32, set_to_id: i32) callconv(.winapi) void {
    sampleGroup(dig, stop_id, set_to_id, .stop);
}
pub fn AIL_resume_sample_group(dig: ?*DigitalDriver, resume_id: i32, set_to_id: i32) callconv(.winapi) void {
    sampleGroup(dig, resume_id, set_to_id, .unpause);
}
pub fn AIL_end_sample_group(dig: ?*DigitalDriver, end_id: i32) callconv(.winapi) void {
    const d = dig orelse return;
    for (d.samples.items) |s| {
        if (s.v9_id == end_id) s.end();
    }
}

// --- 3D falloff graphs / position segments ---
pub fn AIL_set_sample_3D_volume_falloff(s_opt: ?*Sample, graph: ?*anyopaque, pointcount: i32) callconv(.winapi) void {
    _ = s_opt;
    _ = graph;
    _ = pointcount;
}
pub fn AIL_set_sample_3D_exclusion_falloff(s_opt: ?*Sample, graph: ?*anyopaque, pointcount: i32) callconv(.winapi) void {
    _ = s_opt;
    _ = graph;
    _ = pointcount;
}
pub fn AIL_set_sample_3D_lowpass_falloff(s_opt: ?*Sample, graph: ?*anyopaque, pointcount: i32) callconv(.winapi) void {
    _ = s_opt;
    _ = graph;
    _ = pointcount;
}
pub fn AIL_set_sample_3D_spread_falloff(s_opt: ?*Sample, graph: ?*anyopaque, pointcount: i32) callconv(.winapi) void {
    _ = s_opt;
    _ = graph;
    _ = pointcount;
}
pub fn AIL_set_sample_3D_position_segments(s_opt: ?*Sample, segments: ?*anyopaque, count: i32) callconv(.winapi) void {
    _ = s_opt;
    _ = segments;
    _ = count;
}

// --- Event command queue ---
pub fn AIL_enqueue_event_start() callconv(.winapi) void {}
pub fn AIL_enqueue_event_cancel(a0: i32) callconv(.winapi) void {
    _ = a0;
}
pub fn AIL_enqueue_event_context(a0: ?*anyopaque, a1: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
}
pub fn AIL_enqueue_event_end_named(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) void {
    _ = a0;
    _ = a1;
}
pub fn AIL_enqueue_event_selection(a0: ?*anyopaque, a1: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
}
pub fn AIL_enqueue_event_filter(a0: ?*anyopaque, a1: i32, a2: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;
}
pub fn AIL_enqueue_event_variablef(a0: ?*anyopaque, a1: f32, a2: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;
}
pub fn AIL_enqueue_event_buffer(a0: ?*anyopaque, a1: i32, a2: ?*anyopaque, a3: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
}
pub fn AIL_enqueue_event_position(a0: ?*anyopaque, a1: f32, a2: f32, a3: f32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
}
pub fn AIL_enqueue_event_velocity(a0: ?*anyopaque, a1: f32, a2: f32, a3: f32, a4: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
}
pub fn AIL_event_system_command_queue_remaining() callconv(.winapi) u32 {
    return 0;
}
pub fn AIL_set_event_settings(a0: i32) callconv(.winapi) void {
    _ = a0;
}
pub fn AIL_set_event_sample_functions(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) void {
    _ = a0;
    _ = a1;
}

// --- Event-step builders (event VM bytecode) ---
pub fn AIL_add_enable_limit_event_step(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub fn AIL_add_move_var_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque, a4: i32) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    return 0;
}
pub fn AIL_add_set_lfo_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: i32, a4: f32, a5: f32, a6: f32, a7: i32, a8: i32, a9: i32) callconv(.winapi) i32 {
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

// --- Memory subsystem (v9) ---

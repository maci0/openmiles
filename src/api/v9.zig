//! MSS v9 additive API (stubbed). Soundbank/event/preset system, 5.1
//! surround, in-memory I/O, WAV markers, util helpers — gated at v9+ and
//! additive over v3-v7. Signatures from the MSS 9.x SDK mss.h. These subsystems
//! have no OpenMiles engine equivalent yet, so they link and return safe defaults.
const std = @import("std");
const openmiles = @import("openmiles");
const api_file = @import("file.zig");

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
    // Route the sample's output through the bus submix if it exists.
    if (s.driver.busAt(bus_index)) |bus| _ = bus.route(s);
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
pub fn AIL_add_clear_state_event_step(event: ?*anyopaque) callconv(.winapi) i32 {
    const e: *openmiles.event.EventConstruct = @ptrCast(@alignCast(event orelse return 0));
    return if (e.addClearState()) 1 else 0;
}
pub fn AIL_add_exec_event_event_step(a0: ?*anyopaque, event_name: ?[*:0]const u8) callconv(.winapi) i32 {
    const e: *openmiles.event.EventConstruct = @ptrCast(@alignCast(a0 orelse return 0));
    const name = if (event_name) |p| std.mem.span(p) else "";
    return if (e.addOneString(.exec_event, name)) 1 else 0;
}
pub fn AIL_add_ramp_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: f32, a4: ?*anyopaque, a5: i32, a6: i32, a7: i32) callconv(.winapi) i32 {
    const e: *openmiles.event.EventConstruct = @ptrCast(@alignCast(a0 orelse return 0));
    // SDK: name(a1), labels(a2), time(a3), target(a4), type(a5), applytonew(a6), interp(a7).
    return if (e.addRamp(a1, a2, a3, a4, a5, a6, a7)) 1 else 0;
}
pub fn AIL_add_setblend_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: i32, a3: ?*anyopaque, a4: ?*anyopaque, a5: ?*anyopaque, a6: ?*anyopaque, a7: ?*anyopaque, a8: ?*anyopaque) callconv(.winapi) i32 {
    const e: *openmiles.event.EventConstruct = @ptrCast(@alignCast(a0 orelse return 0));
    // SDK: name(a1), soundcount(a2), inmin, inmax, outmin, outmax, minp, maxp.
    const ok = e.addSetBlend(a1, a2, @ptrCast(@alignCast(a3)), @ptrCast(@alignCast(a4)), @ptrCast(@alignCast(a5)), @ptrCast(@alignCast(a6)), @ptrCast(@alignCast(a7)), @ptrCast(@alignCast(a8)));
    return if (ok) 1 else 0;
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
var g_trace_cb: ?*anyopaque = null;
pub fn AIL_configure_logging(filename: ?*anyopaque, cb: ?*anyopaque, level: i32) callconv(.winapi) ?*anyopaque {
    // SDK: returns the previous trace callback after installing the new one. We
    // don't emit a log file, so filename/level are accepted but unused; the
    // callback contract (store + return old) is honored so callers can restore.
    _ = filename;
    _ = level;
    const old = g_trace_cb;
    g_trace_cb = cb;
    return old;
}
pub fn AIL_file_callbacks(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
}
// Tracking macro target for AIL_file_read(filename, dest): reads the whole file
// into `dest` (or a fresh AIL_mem_free_lock buffer if dest is null). caller/line
// are debug metadata.
pub fn AIL_file_read_info(filename: ?*anyopaque, dest: ?*anyopaque, caller: ?*anyopaque, line: u32) callconv(.winapi) ?*anyopaque {
    _ = caller;
    _ = line;
    const fname = filename orelse return null;
    return api_file.AIL_file_read(@ptrCast(fname), dest);
}
// Tracking macro target for AIL_file_size(filename): returns the file size in
// bytes (0 if not found). caller/line are debug metadata.
pub fn AIL_file_size_info(filename: ?*anyopaque, caller: ?*anyopaque, line: u32) callconv(.winapi) i32 {
    _ = caller;
    _ = line;
    const fname = filename orelse return 0;
    return @bitCast(api_file.AIL_file_size(@ptrCast(fname)));
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
    return @ptrCast(@constCast(b.name()));
}
pub fn AIL_get_time() callconv(.winapi) u64 {
    return openmiles.getUsCount64(); // Miles "time" is a microsecond tick
}
// AIL_mem_alloc_lock(size) is the tracking macro for AIL_mem_alloc_lock_info(
// size, __FILE__, __LINE__) -- so the _info form is the real exported allocator,
// not a stub. file/line are debug metadata. Allocate `size` bytes (free with
// AIL_mem_free_lock), matching the non-instrumented path.
pub fn AIL_mem_alloc_lock_info(size: u32, file: ?*anyopaque, line: u32) callconv(.winapi) ?*anyopaque {
    _ = file;
    _ = line;
    return std.c.malloc(size);
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
// SDK (AIL_API_sample_loaded_len): the amount of loaded-but-unconsumed sample
// data in bytes (sum of buf[t].len - buf[t].pos across the buffer ring). Our
// model holds the whole sample in memory, so that is the remaining unplayed
// span = (total_frames - cursor) * bytes-per-frame.
pub fn AIL_sample_loaded_len(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    if (!s.is_initialized) return 0;
    var cursor: u64 = 0;
    _ = openmiles.ma.ma_sound_get_cursor_in_pcm_frames(&s.sound, &cursor);
    const total = s.cached_length_frames;
    const remaining: u64 = if (cursor < total) total - cursor else 0;
    const bpf: u64 = s.bytesPerFrame();
    return @intCast(@min(remaining *| bpf, @as(u64, std.math.maxInt(i32))));
}
// SDK (AIL_API_sample_ms_lookup, wavefile.cpp): convert a ms position to the
// source byte position. datarate = effective_rate * bytes-per-frame, datapos =
// datarate * ms / 1000; *actualms = ms (the input, unchanged). Null S -> ~0U.
// SDK (wavefile.cpp AIL_API_sample_ms_lookup): null -> ~0U; *actualms = the input
// ms; datapos = datarate * ms / 1000 with datarate = effective_rate * bytes/frame.
// For PCM this is exactly our formula (effective_rate * nibbles/2 == rate*bpf).
// MSS computes datarate from the COMPRESSED stream for ADPCM/ASI (blocksize/
// samples_per_block, or the ASI bitrate), returning a position in the source
// bytes; our decoder-based model only has the decoded PCM rate, so for compressed
// sources this returns a decoded-byte position -- consistent with our own
// seek/position functions, which also operate on decoded frames.
pub fn AIL_sample_ms_lookup(s_opt: ?*Sample, milliseconds: i32, actualms: ?*i32) callconv(.winapi) u32 {
    const s = s_opt orelse return ~@as(u32, 0);
    if (actualms) |p| p.* = milliseconds;
    const d = s.decoder orelse return 0;
    const native = @as(f32, @floatFromInt(d.outputSampleRate));
    const effective = (s.target_rate orelse native) * s.v7_rate_factor;
    const datarate = effective * @as(f32, @floatFromInt(s.bytesPerFrame())); // bytes/sec
    const datapos = datarate * @as(f32, @floatFromInt(milliseconds)) / 1000.0;
    return openmiles.satU32(datapos);
}
pub fn AIL_sleep(ms: u32) callconv(.winapi) void {
    openmiles.io.sleep(std.Io.Duration.fromNanoseconds(@as(u64, ms) *| std.time.ns_per_ms), .awake) catch {};
}
// AIL_sound_asset_info(SoundBank* bank, char const* name, char* out_filename,
// MILESBANKSOUNDINFO* out_info) @16 — fills info + path, returns buffer requirement.
pub fn AIL_sound_asset_info(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque) callconv(.winapi) i32 {
    const b: *openmiles.Bank = @ptrCast(@alignCast(a0 orelse return 0));
    const nm = std.mem.span(@as([*:0]const u8, @ptrCast(a1 orelse return 0)));
    const out_fn: ?[*]u8 = if (a2) |p| @ptrCast(p) else null;
    const out_info: ?[*]u8 = if (a3) |p| @ptrCast(@alignCast(p)) else null;
    return b.soundAssetInfo(nm, out_fn, out_info);
}
// SDK (AIL_API_stream_filled_percent): 1.0 for a preloaded/primed stream, the
// fill level otherwise, 0.0 on null/error. Our streams load fully into memory
// (always preloaded), so an initialized stream is 100% filled.
pub fn AIL_stream_filled_percent(s_opt: ?*Sample) callconv(.winapi) f32 {
    const s = s_opt orelse return 0.0;
    return if (s.is_initialized) 1.0 else 0.0;
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
    const d = dig orelse return null;
    return @ptrCast(d.allocateBus());
}
pub fn AIL_free_all_busses(dig: ?*DigitalDriver) callconv(.winapi) void {
    const d = dig orelse return;
    d.freeAllBusses();
}
pub fn AIL_bus_sample_handle(dig: ?*DigitalDriver, bus_index: i32) callconv(.winapi) ?*anyopaque {
    const d = dig orelse return null;
    return @ptrCast(d.busAt(bus_index));
}
pub fn AIL_enable_limiter(dig: ?*DigitalDriver, on_off: i32) callconv(.winapi) void {
    // Master limiter == limiter on every bus (the master submix path here).
    const d = dig orelse return;
    for (d.buses.items) |bus| bus.enableLimiter(on_off != 0);
}
pub fn AIL_bus_enable_limiter(dig: ?*DigitalDriver, bus_index: i32, on_off: i32) callconv(.winapi) void {
    const d = dig orelse return;
    if (d.busAt(bus_index)) |bus| bus.enableLimiter(on_off != 0);
}
pub fn AIL_install_bus_compressor(dig: ?*DigitalDriver, bus_index: i32, filter_stage: i32, input_bus_index: i32) callconv(.winapi) i32 {
    _ = filter_stage;
    _ = input_bus_index; // sidechain input not modeled; main-path compression
    const d = dig orelse return 0;
    const bus = d.busAt(bus_index) orelse return 0;
    bus.installCompressor(true);
    return 1;
}

// --- Mixer status / scheduling / per-sample misc ---
pub fn AIL_digital_mixed_samples(dig: ?*DigitalDriver) callconv(.winapi) u64 {
    const d = dig orelse return 0;
    // Total sample frames the engine has mixed since startup (its PCM clock).
    return openmiles.ma.ma_engine_get_time_in_pcm_frames(&d.engine);
}
const AilMixerCb = *const fn (?*DigitalDriver) callconv(.winapi) void;
pub fn AIL_register_mix_callback(dig: ?*DigitalDriver, mixcb: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const d = dig orelse return null;
    // Atomic exchange: the audio thread reads mix_callback in mixDispatch, so the
    // store must not be torn or reordered against that read.
    const next: ?AilMixerCb = if (mixcb) |p| @as(AilMixerCb, @ptrCast(@alignCast(p))) else null;
    const prev = @atomicRmw(?AilMixerCb, &d.mix_callback, .Xchg, next, .acq_rel);
    return if (prev) |p| @ptrCast(@constCast(p)) else null;
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
    const s = s_opt orelse return 0;
    return s.v9_schedule_time;
}
pub fn AIL_schedule_start_sample(s_opt: ?*Sample, mix_time_to_start: u64) callconv(.winapi) void {
    const s = s_opt orelse return;
    // Begin playback at an absolute mixer time (engine PCM clock), so groups of
    // samples can be started sample-accurately.
    s.v9_schedule_time = mix_time_to_start;
    if (s.is_initialized) openmiles.ma.ma_sound_set_start_time_in_pcm_frames(&s.sound, mix_time_to_start);
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
    const d = dig orelse return;
    _ = flags;
    _ = crossfade_ms;
    // Save the current driver state so it can be restored by pop. (We snapshot
    // the master volume; the level counter mirrors the real push/pop depth.)
    d.system_state_stack.append(d.allocator, d.getMasterVolume()) catch {};
}
pub fn AIL_pop_system_state(dig: ?*DigitalDriver, crossfade_ms: i32) callconv(.winapi) void {
    const d = dig orelse return;
    _ = crossfade_ms;
    if (d.system_state_stack.pop()) |vol| d.setMasterVolume(vol);
}
pub fn AIL_system_state_level(dig: ?*DigitalDriver) callconv(.winapi) u8 {
    const d = dig orelse return 0;
    return @intCast(@min(d.system_state_stack.items.len, 255));
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
// MSSGRAPHPOINT: { F32 X, Y, ITX, ITY, OTX, OTY; S32 IType, OType; } — X is the
// distance, Y the value. The graph's first/last X give the falloff's near/far
// distance, which we map onto miniaudio's distance attenuation.
pub const MSSGraphPoint = openmiles.FalloffGraphPoint;
fn falloffPtr(graph: ?*anyopaque) ?[*]const MSSGraphPoint {
    return @ptrCast(@alignCast(graph orelse return null));
}
pub fn AIL_set_sample_3D_volume_falloff(s_opt: ?*Sample, graph: ?*anyopaque, pointcount: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    // SDK rejects pointcount > MILES_MAX_FALLOFF_GRAPH_POINTS (5); store verbatim.
    s.setFalloff(.volume, falloffPtr(graph), pointcount);
    // Adaptation: map the graph's first/last distance onto ma's min/max distance.
    const n = s.falloff_count[@intFromEnum(openmiles.FalloffKind.volume)];
    if (n >= 1 and s.is_initialized) {
        const pts = &s.falloff_graph[@intFromEnum(openmiles.FalloffKind.volume)];
        const near = pts[0].x;
        const far = pts[n - 1].x;
        if (far > near and !std.math.isNan(near) and !std.math.isNan(far)) {
            openmiles.ma.ma_sound_set_min_distance(&s.sound, near);
            openmiles.ma.ma_sound_set_max_distance(&s.sound, far);
        }
    }
}
pub fn AIL_set_sample_3D_exclusion_falloff(s_opt: ?*Sample, graph: ?*anyopaque, pointcount: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setFalloff(.exclusion, falloffPtr(graph), pointcount);
}
pub fn AIL_set_sample_3D_lowpass_falloff(s_opt: ?*Sample, graph: ?*anyopaque, pointcount: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setFalloff(.lowpass, falloffPtr(graph), pointcount);
}
pub fn AIL_set_sample_3D_spread_falloff(s_opt: ?*Sample, graph: ?*anyopaque, pointcount: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.setFalloff(.spread, falloffPtr(graph), pointcount);
}
pub fn AIL_set_sample_3D_position_segments(s_opt: ?*Sample, segments: ?*anyopaque, count: i32) callconv(.winapi) void {
    _ = segments;
    _ = count;
    // SDK (m3d.cpp) stores the position-segment graph (no engine consumer yet)
    // and marks the sample 3D; reflect at least the observable is_3D state.
    const s = s_opt orelse return;
    s.is_3D = 1;
}

// --- Event command queue (audition/remote-control build API) ---
// The deferred command queue itself is not implemented; these match the SDK
// signatures (return types matter — S32 in EAX, U64 in EDX:EAX) and report
// benign success so a caller's result register is defined. Builders return the
// running token; the *_start/*_by_name/*_end_named finalizers return an id.
var g_enqueue_token: i32 = 1;
pub fn AIL_enqueue_event_start() callconv(.winapi) i32 {
    g_enqueue_token +%= 1;
    return g_enqueue_token;
}
pub fn AIL_enqueue_event_cancel(token: i32) callconv(.winapi) void {
    _ = token;
}
pub fn AIL_enqueue_event_context(token: ?*i32, system: ?*anyopaque) callconv(.winapi) i32 {
    _ = system;
    return if (token) |t| t.* else 0;
}
pub fn AIL_enqueue_event_end_named(token: i32, name: ?*anyopaque) callconv(.winapi) u64 {
    _ = name;
    return @intCast(@max(token, 0));
}
pub fn AIL_enqueue_event_selection(token: ?*i32, selection: u32) callconv(.winapi) i32 {
    _ = selection;
    return if (token) |t| t.* else 0;
}
pub fn AIL_enqueue_event_filter(token: ?*i32, apply_to_id: u64) callconv(.winapi) i32 {
    _ = apply_to_id;
    return if (token) |t| t.* else 0;
}
pub fn AIL_enqueue_event_variablef(token: ?*i32, name: ?*anyopaque, value: f32) callconv(.winapi) i32 {
    _ = name;
    _ = value;
    return if (token) |t| t.* else 0;
}
pub fn AIL_enqueue_event_buffer(token: ?*i32, user_buffer: ?*anyopaque, user_buffer_len: i32, user_buffer_is_ptr: i32) callconv(.winapi) i32 {
    _ = user_buffer;
    _ = user_buffer_len;
    _ = user_buffer_is_ptr;
    return if (token) |t| t.* else 0;
}
pub fn AIL_enqueue_event_position(token: ?*i32, x: f32, y: f32, z: f32) callconv(.winapi) i32 {
    _ = x;
    _ = y;
    _ = z;
    return if (token) |t| t.* else 0;
}
pub fn AIL_enqueue_event_velocity(token: ?*i32, vx: f32, vy: f32, vz: f32, mag: f32) callconv(.winapi) i32 {
    _ = vx;
    _ = vy;
    _ = vz;
    _ = mag;
    return if (token) |t| t.* else 0;
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
    const e: *openmiles.event.EventConstruct = @ptrCast(@alignCast(a0 orelse return 0));
    const name = if (a1) |p| std.mem.span(@as([*:0]const u8, @ptrCast(p))) else "";
    return if (e.addOneString(.enable_limit, name)) 1 else 0;
}
pub fn AIL_add_move_var_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque, a4: ?*anyopaque) callconv(.winapi) i32 {
    const e: *openmiles.event.EventConstruct = @ptrCast(@alignCast(a0 orelse return 0));
    // SDK: name(a1), times F32[2](a2), interp_types S32[2](a3), values F32[3](a4).
    const ok = e.addMoveVar(a1, @ptrCast(@alignCast(a2)), @ptrCast(@alignCast(a3)), @ptrCast(@alignCast(a4)));
    return if (ok) 1 else 0;
}
pub fn AIL_add_set_lfo_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque, a4: ?*anyopaque, a5: i32, a6: i32, a7: i32, a8: i32, a9: i32) callconv(.winapi) i32 {
    const e: *openmiles.event.EventConstruct = @ptrCast(@alignCast(a0 orelse return 0));
    // SDK: name(a1), base(a2), amp(a3), freq(a4), invert(a5), polarity(a6),
    // waveform(a7), dutycycle(a8), isLFO(a9).
    return if (e.addSetLfo(a1, a2, a3, a4, a5, a6, a7, a8, a9)) 1 else 0;
}

// --- Memory subsystem (v9) ---

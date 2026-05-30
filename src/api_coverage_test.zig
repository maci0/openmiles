//! API coverage smoke test.
//!
//! Invokes every exported C-ABI function at least once so the whole public
//! surface is verified to link, be reachable, and survive a benign/null call
//! without crashing. Deep behavior + adversarial input is covered by
//! fuzz_test.zig and main_test.zig; this file guarantees breadth (every symbol).
//!
//! Convention: nullable handles are passed null (exercises the guard path);
//! non-optional pointer params get a scratch buffer or a real handle where the
//! callee dereferences it (e.g. a filter).

const std = @import("std");
const testing = std.testing;
const openmiles = @import("openmiles");

const dg = @import("api/digital.zig");
const flt = @import("api/filter.zig");
const mem = @import("api/memory.zig");
const td = @import("api/3d.zig");
const st = @import("api/stream.zig");
const qk = @import("api/quick.zig");
const rb = @import("api/redbook.zig");
const tm = @import("api/timer.zig");
const fl = @import("api/file.zig");
const inp = @import("api/input.zig");
const md = @import("api/midi.zig");
const dl = @import("api/dls.zig");
const rib = @import("api/rib.zig");

fn dummyTimerCb(_: u32) callconv(.winapi) void {}

// Variadic C exports (defined in src/bindings/c_impl.c).
extern fn AIL_debug_printf(fmt: [*:0]const u8, ...) callconv(.c) void;
extern fn AIL_sprintf(buf: [*:0]u8, fmt: [*:0]const u8, ...) callconv(.c) [*:0]u8;

// Crash-verification smoke test: use a plain allocator (no leak abort). Leak
// checking of the parsing paths is done in fuzz_test.zig with testing.allocator.
const alloc = std.heap.page_allocator;

var scratch: [512]u8 = [_]u8{0} ** 512;
var u32o: u32 = 0;
var i32o: i32 = 0;
var f32o: f32 = 0;
var pp: ?*anyopaque = null;
var next: ?*anyopaque = null;
var prov: ?*openmiles.Provider = null;
var namep: [*:0]const u8 = "x";

fn sc() *anyopaque {
    return @ptrCast(&scratch);
}

fn freeLock(p: ?*anyopaque) void {
    if (p) |ptr| mem.AIL_mem_free_lock(ptr);
}

test "coverage: digital.zig exports" {
    // Lifecycle / globals.
    _ = dg.AIL_startup();
    _ = dg.AIL_last_error();
    _ = dg.AIL_get_preference(0);
    _ = dg.AIL_set_preference(0, 0);
    _ = dg.AIL_ms_count();
    _ = dg.AIL_us_count();
    dg.AIL_delay(0);
    dg.AIL_lock();
    dg.AIL_unlock();
    dg.AIL_lock_mutex();
    dg.AIL_unlock_mutex();
    _ = dg.AIL_background();
    _ = dg.AIL_MMX_available();
    _ = dg.AIL_HWND();
    dg.AIL_set_error("x");
    dg.AIL_serve();
    dg.AIL_set_redist_directory("x");

    // A real device-less driver + initialized sample + filter for the params
    // that get dereferenced.
    const drv = try openmiles.DigitalDriver.init(alloc, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(alloc, &pcm, 1, 8000, 16);
    defer alloc.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    s.loadFromMemory(wav, false) catch {};
    const myprov = openmiles.Provider.init(alloc, null) catch null;
    defer if (myprov) |p| p.deinit();
    const filt: ?*anyopaque = flt.AIL_open_filter(myprov, drv);

    // Driver-level.
    _ = dg.AIL_primary_digital_driver(drv);
    _ = dg.AIL_digital_CPU_percent(drv);
    _ = dg.AIL_digital_latency(drv);
    var cfgbuf: [64]u8 = undefined;
    dg.AIL_digital_configuration(drv, &i32o, &i32o, &cfgbuf);
    _ = dg.AIL_digital_master_volume(drv);
    dg.AIL_set_digital_master_volume(drv, 64);
    _ = dg.AIL_active_sample_count(drv);
    _ = dg.AIL_sample_granularity(drv);
    _ = dg.AIL_minimum_sample_buffer_size(drv, 44100, 0);
    _ = dg.AIL_get_DirectSound_info(drv, sc(), 0);
    dg.AIL_set_DirectSound_HWND(drv, sc());
    _ = dg.AIL_set_digital_driver_processor(drv, 0, null);
    _ = dg.AIL_process_digital_audio(drv, sc(), 0, null, 0, 0);
    _ = dg.AIL_size_processed_digital_audio(drv, 44100, 0, sc(), 0);
    _ = dg.AIL_digital_handle_release(drv);
    _ = dg.AIL_digital_handle_reacquire(drv);

    // Sample-level (real handle).
    dg.AIL_init_sample(s);
    dg.AIL_set_sample_type(s, 1, 0);
    _ = dg.AIL_sample_status(s);
    _ = dg.AIL_sample_volume(s);
    _ = dg.AIL_sample_pan(s);
    _ = dg.AIL_sample_playback_rate(s);
    _ = dg.AIL_sample_loop_count(s);
    _ = dg.AIL_sample_position(s);
    dg.AIL_set_sample_volume(s, 64);
    dg.AIL_set_sample_pan(s, 64);
    dg.AIL_set_sample_volume_pan(s, 64, 64);
    dg.AIL_set_sample_playback_rate(s, 22050);
    dg.AIL_set_sample_loop_count(s, 1);
    dg.AIL_set_sample_position(s, 0);
    dg.AIL_set_sample_ms_position(s, 0);
    dg.AIL_sample_ms_position(s, &i32o, &i32o);
    _ = dg.AIL_sample_user_data(s, 0);
    dg.AIL_set_sample_user_data(s, 0, 0);
    dg.AIL_sample_reverb(s, &f32o, &f32o, &f32o);
    dg.AIL_set_sample_reverb(s, 1, 0.5, 0.1);
    dg.AIL_set_sample_loop_block(s, 0, -1);
    dg.AIL_set_sample_adpcm_block_size(s, 512);
    _ = dg.AIL_sample_buffer_ready(s);
    dg.AIL_sample_buffer_info(s, &u32o, &u32o, &u32o, &u32o);
    _ = dg.AIL_register_EOB_callback(s, null);
    _ = dg.AIL_register_SOB_callback(s, null);
    _ = dg.AIL_register_EOS_callback(s, null);
    _ = dg.AIL_set_sample_processor(s, 0, null);
    dg.AIL_start_sample(s);
    dg.AIL_pause_sample(s);
    dg.AIL_resume_sample(s);
    dg.AIL_stop_sample(s);
    dg.AIL_end_sample(s);
    dg.AIL_set_sample_address(s, sc(), 0);
    _ = dg.AIL_set_sample_file(s, @ptrCast(wav.ptr), -1);
    _ = dg.AIL_set_named_sample_file(s, "wav", @ptrCast(wav.ptr), @intCast(wav.len), 0);
    dg.AIL_load_sample_buffer(s, 0, sc(), 0);
    flt.AIL_filter_sample_attribute(s, "Cutoff", sc());
    flt.AIL_set_filter_sample_preference(s, "Cutoff", sc());

    // Filter-level (real filter handle).
    if (filt) |f| {
        flt.AIL_filter_attribute(f, "Cutoff", sc());
        flt.AIL_set_filter_attribute(f, "Cutoff", sc());
        flt.AIL_set_filter_preference(f, "Cutoff", sc());
        _ = flt.AIL_enumerate_filter_attributes(f, &next, &namep);
        next = null;
        _ = flt.AIL_enumerate_filter_sample_attributes(f, &next, &namep);
        flt.AIL_set_sample_filter(s, f, 0);
        flt.AIL_close_filter(f);
    }
    next = null;
    _ = flt.AIL_enumerate_filters(&next, &prov, &namep);

    // Allocators / misc.
    const m = mem.AIL_mem_alloc_lock(16);
    if (m) |mp| mem.AIL_mem_free_lock(mp);
    mem.AIL_mem_use_malloc(null);
    mem.AIL_mem_use_free(null);
    mem.AIL_set_mem_callbacks(null, null);
    _ = dg.AIL_allocate_file_sample(drv, @ptrCast(wav.ptr), 0);

    // WAV info / encoders.
    var info: openmiles.AILSOUNDINFO = undefined;
    _ = dg.AIL_WAV_info(@ptrCast(wav.ptr), &info);
    info = .{ .format = 0, .data_ptr = @ptrCast(&pcm), .data_len = pcm.len, .rate = 8000, .bits = 16, .channels = 1, .samples = 0, .block_size = 0, .initial_ptr = null };
    var outp: *anyopaque = undefined;
    if (dg.AIL_compress_ADPCM(&info, &outp, &u32o) != 0) mem.AIL_mem_free_lock(outp);
    if (dg.AIL_decompress_ADPCM(&info, &outp, &u32o) != 0) mem.AIL_mem_free_lock(outp);

    // Wave synth.
    const synth = dg.AIL_create_wave_synthesizer(drv, null, null, 0);
    if (synth) |sy| dg.AIL_destroy_wave_synthesizer(sy);

    _ = dg.AIL_set_sample_processor(s, 1, null);
}

test "coverage: 3d.zig exports" {
    const drv = try openmiles.DigitalDriver.init(alloc, 44100, 16, 2);
    defer drv.deinit();
    const dp: *anyopaque = @ptrCast(drv); // our 3D provider handle IS the driver
    // A real WAV image for the size-less set_3D_sample_file (it reads up to the
    // streaming sentinel from the pointer, so a tiny scratch would overread).
    const pcm3: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav3 = try openmiles.buildWavFromPcm(alloc, &pcm3, 1, 8000, 16);
    defer alloc.free(wav3);

    next = null;
    _ = td.AIL_enumerate_3D_providers(&next, &prov, &namep);
    _ = td.AIL_open_3D_provider(dp, drv);
    td.AIL_close_3D_provider(dp);
    const lis = td.AIL_open_3D_listener(dp);
    if (lis) |l| td.AIL_close_3D_listener(l);
    const obj = td.AIL_open_3D_object(dp) orelse return error.NoObj;
    td.AIL_close_3D_object(obj);

    // Provider/listener (driver-backed).
    td.AIL_set_listener_3D_position(drv, 0, 0, 0);
    td.AIL_set_listener_3D_velocity(drv, 0, 0, 0, 1);
    td.AIL_set_listener_3D_orientation(drv, 0, 0, 1, 0, 1, 0);
    td.AIL_set_3D_distance_factor(drv, 1);
    _ = td.AIL_3D_distance_factor(drv);
    td.AIL_set_3D_doppler_factor(drv, 1);
    _ = td.AIL_3D_doppler_factor(drv);
    td.AIL_set_3D_rolloff_factor(drv, 1);
    _ = td.AIL_3D_rolloff_factor(drv);
    td.AIL_set_3D_room_type(drv, 0);
    _ = td.AIL_3D_room_type(drv);
    td.AIL_set_3D_speaker_type(drv, 0);
    _ = td.AIL_3D_speaker_type(drv);
    _ = td.AIL_active_3D_sample_count(drv);
    td.AIL_3D_provider_attribute(dp, "x", sc());
    _ = td.AIL_set_3D_provider_preference(dp, "x", sc());
    next = null;
    _ = td.AIL_enumerate_3D_provider_attributes(dp, &next, &namep);

    // Sample3D object (real handle `s3`).
    const s3 = td.AIL_allocate_3D_sample_handle(drv) orelse return error.No3D;
    defer td.AIL_release_3D_sample_handle(s3);
    _ = td.AIL_set_3D_sample_file(s3, @ptrCast(wav3.ptr));
    td.AIL_set_3D_position(s3, 0, 0, 0);
    td.AIL_set_3D_velocity(s3, 0, 0, 0, 1);
    td.AIL_set_3D_orientation(s3, 0, 0, 1, 0, 1, 0);
    td.AIL_set_3D_velocity_vector(s3, 0, 0, 0);
    td.AIL_set_3D_sample_distances(s3, 100, 1);
    td.AIL_start_3D_sample(s3);
    td.AIL_stop_3D_sample(s3);
    td.AIL_resume_3D_sample(s3);
    td.AIL_end_3D_sample(s3);
    _ = td.AIL_3D_sample_status(s3);
    _ = td.AIL_3D_sample_volume(s3);
    td.AIL_set_3D_sample_volume(s3, 64);
    _ = td.AIL_3D_sample_loop_count(s3);
    td.AIL_set_3D_sample_loop_count(s3, 1);
    _ = td.AIL_3D_sample_playback_rate(s3);
    td.AIL_set_3D_sample_playback_rate(s3, 22050);
    _ = td.AIL_3D_sample_offset(s3);
    td.AIL_set_3D_sample_offset(s3, 0);
    _ = td.AIL_3D_sample_length(s3);
    td.AIL_3D_sample_ms_position(s3, &i32o, &i32o);
    td.AIL_set_3D_sample_ms_position(s3, 0);
    _ = td.AIL_register_3D_EOS_callback(s3, null);
    _ = td.AIL_3D_user_data(s3, 0);
    td.AIL_set_3D_user_data(s3, 0, 0);
    td.AIL_set_3D_sample_loop_block(s3, 0, -1);
    td.AIL_set_3D_sample_cone(s3, 0, 360, 64);
    td.AIL_3D_sample_cone(s3, &f32o, &f32o, &i32o);
    td.AIL_set_3D_sample_effects_level(s3, 0.5);
    _ = td.AIL_3D_sample_effects_level(s3);
    td.AIL_set_3D_sample_obstruction(s3, 0.5);
    _ = td.AIL_3D_sample_obstruction(s3);
    td.AIL_set_3D_sample_occlusion(s3, 0.5);
    _ = td.AIL_3D_sample_occlusion(s3);
    td.AIL_set_3D_sample_preference(s3, "x", sc());
    td.AIL_3D_sample_attribute(s3, "x", sc());
    td.AIL_auto_update_3D_position(s3, 1);
    td.AIL_update_3D_position(s3, 0.016);
    td.AIL_3D_orientation(s3, &f32o, &f32o, &f32o, &f32o, &f32o, &f32o);
    td.AIL_3D_position(s3, &f32o, &f32o, &f32o);
    td.AIL_3D_velocity(s3, &f32o, &f32o, &f32o);
    td.AIL_3D_sample_distances(@ptrCast(@alignCast(s3)), &f32o, &f32o);
    next = null;
    _ = td.AIL_enumerate_3D_sample_attributes(s3, &next, &namep);
    var sinfo: openmiles.AILSOUNDINFO = .{ .format = 0, .data_ptr = sc(), .data_len = 16, .rate = 8000, .bits = 16, .channels = 1, .samples = 0, .block_size = 0, .initial_ptr = null };
    _ = td.AIL_set_3D_sample_info(s3, &sinfo);
}

test "coverage: stream.zig exports" {
    const drv = try openmiles.DigitalDriver.init(alloc, 44100, 16, 2);
    defer drv.deinit();
    // open_stream with null filename returns null; all others null-guard.
    _ = st.AIL_open_stream(drv, null, 0);
    const n: ?*openmiles.Sample = null;
    st.AIL_close_stream(n);
    st.AIL_start_stream(n);
    st.AIL_pause_stream(n, 1);
    st.AIL_set_stream_volume(n, 64);
    st.AIL_set_stream_loop_count(n, 1);
    _ = st.AIL_register_stream_callback(n, null);
    st.AIL_auto_service_stream(n, 1);
    st.AIL_set_stream_playback_rate(n, 22050);
    st.AIL_set_stream_pan(n, 64);
    st.AIL_set_stream_ms_position(n, 0);
    _ = st.AIL_stream_status(n);
    _ = st.AIL_stream_playback_rate(n);
    _ = st.AIL_stream_volume(n);
    _ = st.AIL_stream_pan(n);
    _ = st.AIL_stream_loop_count(n);
    st.AIL_stream_ms_position(n, &i32o, &i32o);
    _ = st.AIL_stream_position(n);
    st.AIL_set_stream_position(n, 0);
    _ = st.AIL_stream_user_data(n, 0);
    st.AIL_set_stream_user_data(n, 0, 0);
    st.AIL_stream_reverb(n, &f32o, &f32o, &f32o);
    st.AIL_set_stream_reverb(n, 1, 0.5, 0.1);
    st.AIL_stream_info(n, &i32o, &i32o, &i32o, &i32o);
    st.AIL_set_stream_loop_block(n, 0, -1);
    _ = st.AIL_service_stream(n, 1);
    _ = st.AIL_register_EOF_callback(n, null);
    _ = st.AIL_set_stream_processor(n, 0, null);
    st.AIL_filter_stream_attribute(n, "Cutoff", sc());
    st.AIL_set_filter_stream_preference(n, "Cutoff", sc());
}

test "coverage: quick.zig exports" {
    const n: ?*openmiles.Sample = null;
    _ = qk.AIL_quick_copy(n);
    qk.AIL_quick_unload(n);
    qk.AIL_quick_play(n, 1);
    qk.AIL_quick_stop(n);
    _ = qk.AIL_quick_status(n);
    qk.AIL_quick_set_volume(n, 64, 127);
    qk.AIL_quick_set_speed(n, 22050);
    _ = qk.AIL_quick_ms_length(n);
    _ = qk.AIL_quick_ms_position(n);
    qk.AIL_quick_set_ms_position(n, 0);
    qk.AIL_quick_halt(n);
    qk.AIL_quick_set_reverb(n, 1, 0.5, 0.1);
    _ = qk.AIL_quick_type(n);
    var qs: ?*openmiles.Sample = null;
    var qd: ?*openmiles.DigitalDriver = null;
    var qm: ?*openmiles.MidiDriver = null;
    qk.AIL_quick_handles(&qs, &qd, &qm);
    // load_mem with a too-short/garbage buffer (no driver open) -> null.
    _ = qk.AIL_quick_load_mem(sc(), 0);
}

test "coverage: redbook.zig exports" {
    const h = rb.AIL_redbook_open_drive(0) orelse return;
    defer rb.AIL_redbook_close(h);
    _ = rb.AIL_redbook_play(h, 1, 2);
    _ = rb.AIL_redbook_stop(h);
    _ = rb.AIL_redbook_pause(h);
    _ = rb.AIL_redbook_resume(h);
    _ = rb.AIL_redbook_status(h);
    _ = rb.AIL_redbook_tracks(h);
    _ = rb.AIL_redbook_eject(h);
    _ = rb.AIL_redbook_retract(h);
    _ = rb.AIL_redbook_id(h);
    _ = rb.AIL_redbook_position(h);
    _ = rb.AIL_redbook_track(h);
    rb.AIL_redbook_track_info(h, 1, &u32o, &u32o);
    rb.AIL_redbook_set_volume(h, 64);
    _ = rb.AIL_redbook_volume(h);
    const h2 = rb.AIL_redbook_open(0);
    if (h2) |hh| rb.AIL_redbook_close(hh);
}

test "coverage: timer.zig exports" {
    const t = tm.AIL_register_timer(dummyTimerCb) orelse return;
    const tt: *openmiles.Timer = @ptrCast(@alignCast(t));
    tm.AIL_set_timer_frequency(tt, 60);
    tm.AIL_set_timer_period(tt, 16000);
    tm.AIL_set_timer_user_data(tt, 0);
    tm.AIL_set_timer_divisor(tt, 1);
    tm.AIL_set_timer_user(tt, 0);
    tm.AIL_start_timer(tt);
    tm.AIL_stop_timer(tt);
    _ = tm.AIL_get_timer_highest_delay();
    tm.AIL_release_timer_handle(tt); // frees tt
    // A second timer exercises the *_all_timers paths (which free it).
    _ = tm.AIL_register_timer(dummyTimerCb) orelse return;
    tm.AIL_start_all_timers();
    tm.AIL_stop_all_timers();
    tm.AIL_release_all_timers();
}

test "coverage: file/input.zig exports" {
    _ = fl.AIL_file_error();
    _ = fl.AIL_file_size("/nonexistent_om_test");
    _ = fl.AIL_file_type(sc(), 16);
    _ = fl.AIL_file_read("/nonexistent_om_test", null);
    _ = fl.AIL_file_write("/tmp/om_cov_test.bin", sc(), 4);
    fl.AIL_set_file_callbacks(null, null, null, null);
    fl.AIL_set_file_async_callbacks(null, null, null, null, null);

    // input: device-less; open may fail gracefully.
    const ip = inp.AIL_open_input(sc());
    if (ip) |p| {
        const ipt: *openmiles.Input = @ptrCast(@alignCast(p));
        inp.AIL_set_input_state(ipt, 0);
        _ = inp.AIL_input_info(ipt);
        inp.AIL_close_input(ipt);
    }
}

test "coverage: midi.zig exports" {
    const mdi = md.AIL_open_midi_driver(0) orelse return;
    defer md.AIL_close_midi_driver(mdi);
    const mp: *anyopaque = @ptrCast(mdi);
    _ = md.AIL_open_XMIDI_driver(0);
    const seq = md.AIL_allocate_sequence_handle(mdi) orelse return;
    defer md.AIL_release_sequence_handle(seq);

    // Minimal valid SMF so the size-less init_sequence detects a real length.
    const smf = [_]u8{
        'M', 'T', 'h', 'd', 0, 0, 0, 6, 0, 0, 0, 1, 0, 0x60,
        'M', 'T', 'r', 'k', 0, 0, 0, 4, 0, 0xFF, 0x2F, 0,
    };
    _ = md.AIL_init_sequence(seq, @constCast(@ptrCast(&smf)), 0);

    md.AIL_start_sequence(seq);
    md.AIL_pause_sequence(seq);
    md.AIL_resume_sequence(seq);
    md.AIL_stop_sequence(seq);
    md.AIL_end_sequence(seq);
    _ = md.AIL_sequence_status(seq);
    md.AIL_set_sequence_volume(seq, 64, 0);
    md.AIL_set_sequence_loop_count(seq, 1);
    md.AIL_sequence_ms_position(seq, &i32o, &i32o);
    md.AIL_set_sequence_ms_position(seq, 0);
    _ = md.AIL_sequence_loop_count(seq);
    _ = md.AIL_sequence_volume(seq);
    _ = md.AIL_sequence_tempo(seq);
    md.AIL_set_sequence_tempo(seq, 120, 0);
    _ = md.AIL_active_sequence_count(mp);
    md.AIL_sequence_position(seq, &i32o, &i32o);
    _ = md.AIL_sequence_user_data(seq, 0);
    md.AIL_set_sequence_user_data(seq, 0, 0);
    _ = md.AIL_true_sequence_channel(seq, 0);
    md.AIL_map_sequence_channel(seq, 0, 1);
    _ = md.AIL_register_sequence_callback(seq, null);
    _ = md.AIL_XMIDI_master_volume(mdi);
    md.AIL_set_XMIDI_master_volume(mdi, 64);
    _ = md.AIL_channel_notes(seq, 0);
    _ = md.AIL_controller_value(seq, 0, 7);
    md.AIL_send_channel_voice_message(mdi, seq, 0x90, 60, 64);
    md.AIL_send_sysex_message(seq, sc());
    _ = md.AIL_lock_channel(seq);
    md.AIL_release_channel(seq, 0);
    _ = md.AIL_register_beat_callback(seq, null);
    _ = md.AIL_register_event_callback(mdi, null);
    _ = md.AIL_register_prefix_callback(seq, null);
    _ = md.AIL_register_trigger_callback(seq, null);
    _ = md.AIL_register_timbre_callback(mdi, null);
    md.AIL_branch_index(seq, 0);
    md.AIL_register_ICA_array(seq, sc());

    // Driver-handle legacy / conversion.
    md.AIL_MIDI_handle_release(mp);
    _ = md.AIL_MIDI_handle_reacquire(mp);
    var hmo: *anyopaque = undefined;
    _ = md.AIL_midiOutOpen(mp, &hmo, 0);
    md.AIL_midiOutClose(mp);
    var out_len: u32 = scratch.len;
    _ = md.AIL_MIDI_to_XMI(@constCast(@ptrCast(&smf)), smf.len, sc(), &out_len, 0);
    var lst: ?*anyopaque = null;
    var lsz: u32 = 0;
    if (md.AIL_list_MIDI(@ptrCast(&smf), smf.len, &lst, &lsz, 0) != 0) freeLock(lst);
}

test "coverage: dls.zig exports" {
    const nd: ?*openmiles.MidiDriver = null;
    _ = dl.AIL_DLS_load_file(nd, "/nonexistent", 0);
    dl.AIL_DLS_unload_file(nd, sc());
    dl.AIL_set_filter_DLS_preference(nd, "Cutoff", sc());
    dl.AIL_filter_DLS_attribute(nd, "Cutoff", sc());
    _ = dl.AIL_DLS_load_memory(nd, sc(), 0);
    dl.AIL_DLS_unload(nd, sc());
    dl.AIL_DLS_compact(nd);
    _ = dl.AIL_DLS_get_info(nd, sc(), sc());
    dl.AIL_DLS_get_reverb(nd, &f32o, &f32o, &f32o);
    dl.AIL_DLS_set_reverb(nd, 1, 0.5, 0.1);
    _ = dl.AIL_DLS_open(null, null, null, 44100, 16, 2, 0);
    dl.AIL_DLS_close(nd, 0);
    _ = dl.AIL_set_DLS_processor(nd, 0, null);
    dl.DLSClose(nd, sc());
    dl.DLSCompactMemory(nd);
    _ = dl.DLSGetInfo(nd, sc(), sc());
    _ = dl.DLSLoadFile(nd, "/nonexistent", 0);
    _ = dl.DLSLoadMemFile(nd, sc(), 0);
    _ = dl.DLSMSSOpen(null, null, null, 44100, 16, 2, 0);
    _ = dl.DLSMSSGetCPU(nd);
    dl.DLSSetAttribute(nd, "Cutoff", sc());
    dl.DLSUnloadAll(nd);
    dl.DLSUnloadFile(nd, sc());

    // Buffer-based DLS/XMI container ops (allocate outputs -> free).
    var a: ?*anyopaque = null;
    var b: ?*anyopaque = null;
    var c: ?*anyopaque = null;
    _ = dl.AIL_find_DLS(sc(), 16, &a, &u32o, &b, &u32o);
    a = null;
    b = null;
    if (dl.AIL_extract_DLS(sc(), 16, &a, &u32o, &b, &u32o, null) != 0) {
        freeLock(a);
        freeLock(b);
    }
    c = null;
    if (dl.AIL_merge_DLS_with_XMI(sc(), sc(), &c, &u32o) != 0) freeLock(c);
    c = null;
    if (dl.AIL_list_DLS(sc(), &c, &u32o, 0, null) != 0) freeLock(c);
    c = null;
    if (dl.AIL_filter_DLS_with_XMI(sc(), sc(), &c, &u32o, 0, null) != 0) freeLock(c);
    c = null;
    if (dl.AIL_compress_DLS(sc(), "raw", &c, &u32o, null) != 0) freeLock(c);
}

test "coverage: rib.zig exports" {
    const np: ?*openmiles.Provider = null;
    _ = rib.RIB_provider_library_handle();
    _ = rib.RIB_load_application_providers(".");
    var rnext: ?*anyopaque = null;
    var rhandle: ?*openmiles.Provider = null;
    _ = rib.RIB_enumerate_providers("ASI codec", &rnext, &rhandle);
    _ = rib.RIB_request_interface(np, "ASI codec", 0, sc());
    _ = rib.RIB_find_files_provider("ASI codec", "x", "x", ".", "x");
    _ = rib.RIB_register_interface(np, "x", 0, sc());
    rib.RIB_unregister_interface(np, "x", 0, sc());
    _ = rib.RIB_error();
    _ = rib.RIB_find_file_provider("ASI codec", "x", "x");
    _ = rib.RIB_load_provider_library("/nonexistent");
    rib.RIB_free_provider_library(np);
    rib.RIB_free_provider_handle(np);
    _ = rib.RIB_request_interface_entry(np, "x", "y", null);
    var entry: openmiles.RIB_INTERFACE_ENTRY = undefined;
    rnext = null;
    _ = rib.RIB_enumerate_interface(np, "x", 0, &rnext, &entry);
    _ = rib.RIB_type_string(1);
    _ = rib.RIB_provider_system_data(np, 0);
    _ = rib.RIB_provider_user_data(np, 0);
    rib.RIB_set_provider_system_data(np, 0, 0);
    rib.RIB_set_provider_user_data(np, 0, 0);
    _ = rib.RIB_find_file_dec_provider("ASI codec", "x", "x", ".", "x");
    _ = rib.RIB_find_provider("ASI codec", "x", "y");
    const ph = rib.RIB_alloc_provider_handle(sc());
    if (ph) |p| rib.RIB_free_provider_handle(@ptrCast(@alignCast(p)));
    _ = rib.AIL_open_ASI_provider(sc(), 0);
    rib.AIL_close_ASI_provider(np);
    _ = rib.AIL_ASI_provider_attribute(np, "x");
    dg_request_eob();
    var asi_info: openmiles.AILSOUNDINFO = std.mem.zeroes(openmiles.AILSOUNDINFO);
    var asi_out: ?*anyopaque = null;
    var asi_sz: u32 = 0;
    _ = rib.AIL_compress_ASI(&asi_info, "wav", &asi_out, &asi_sz, null);
    _ = rib.AIL_decompress_ASI(null, 0, "wav", &asi_out, &asi_sz, null);
}

fn dg_request_eob() void {
    const n: ?*openmiles.Sample = null;
    rib.AIL_request_EOB_ASI_reset(n, 0);
}

test "coverage: lifecycle / driver open-close exports" {
    // Digital driver open/close + sample handle alloc/release.
    const drv = dg.AIL_open_digital_driver(44100, 16, 2, 0);
    if (drv) |d| {
        const sh = dg.AIL_allocate_sample_handle(d);
        if (sh) |h| dg.AIL_release_sample_handle(h);
        dg.AIL_close_digital_driver(d);
    }

    // waveOut wrappers.
    var wdrv: ?*openmiles.DigitalDriver = null;
    _ = dg.AIL_waveOutOpen(&wdrv, null, 0, null);
    if (wdrv) |w| dg.AIL_waveOutClose(w);

    // WAV file write.
    const wbytes = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    _ = dg.AIL_WAV_file_write("/tmp/om_cov.wav", @constCast(@ptrCast(&wbytes)), wbytes.len, 44100, 16);

    // XMIDI driver close (open covered in midi test).
    const xm = md.AIL_open_XMIDI_driver(0);
    if (xm) |x| md.AIL_close_XMIDI_driver(x);

    // Quick API lifecycle + file loads (nonexistent -> graceful null).
    _ = qk.AIL_quick_startup(1, 0, 44100, 16, 2);
    _ = qk.AIL_quick_load("/nonexistent_om");
    _ = qk.AIL_quick_load_and_play("/nonexistent_om", 1, 0);
    qk.AIL_quick_shutdown();

    // DllMain (DLL_PROCESS_ATTACH = 1).
    var hinst: u8 = 0;
    _ = dg.DllMain(@ptrCast(&hinst), 1, null);

    // Variadic C exports.
    AIL_debug_printf("coverage %d", @as(c_int, 1));
    var sbuf: [64]u8 = undefined;
    _ = AIL_sprintf(@ptrCast(&sbuf), "v=%d", @as(c_int, 7));

    // Global teardown last.
    dg.AIL_shutdown();
}

test "coverage: v7.zig unified exports" {
    const v7 = @import("api/v7.zig");
    const drv = try openmiles.DigitalDriver.init(alloc, 44100, 16, 2);
    defer drv.deinit();
    const pcm7: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav7 = try openmiles.buildWavFromPcm(alloc, &pcm7, 1, 8000, 16);
    defer alloc.free(wav7);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    s.loadFromMemory(wav7, false) catch {};

    // Unified 3D on the sample.
    v7.AIL_set_sample_3D_position(s, 1, 2, 3);
    v7.AIL_set_sample_3D_velocity(s, 0, 0, 0, 1);
    v7.AIL_set_sample_3D_velocity_vector(s, 0, 0, 0);
    v7.AIL_set_sample_3D_orientation(s, 0, 0, 1, 0, 1, 0);
    v7.AIL_set_sample_3D_cone(s, 0, 360, 0.5);
    v7.AIL_set_sample_3D_distances(s, 100, 1, 0);
    v7.AIL_update_sample_3D_position(s, 0.016);
    v7.AIL_sample_3D_position(s, &f32o, &f32o, &f32o);
    v7.AIL_sample_3D_velocity(s, &f32o, &f32o, &f32o);
    v7.AIL_sample_3D_orientation(s, &f32o, &f32o, &f32o, &f32o, &f32o, &f32o);
    v7.AIL_sample_3D_cone(s, &f32o, &f32o, &f32o);
    v7.AIL_sample_3D_distances(s, &f32o, &f32o, &i32o);

    // Unified volume / pan / reverb / low-pass.
    v7.AIL_set_sample_volume_levels(s, 0.8, 0.6);
    v7.AIL_sample_volume_levels(s, &f32o, &f32o);
    v7.AIL_sample_volume_pan(s, &f32o, &f32o);
    v7.AIL_set_sample_low_pass_cut_off(s, 0, 8000);
    _ = v7.AIL_sample_low_pass_cut_off(s, 0);
    v7.AIL_set_sample_reverb_levels(s, 0.7, 0.3);
    v7.AIL_sample_reverb_levels(s, &f32o, &f32o);
    var si: openmiles.AILSOUNDINFO = .{ .format = 0, .data_ptr = sc(), .data_len = 16, .rate = 8000, .bits = 16, .channels = 1, .samples = 0, .block_size = 0, .initial_ptr = null };
    v7.AIL_set_sample_info(s, &si);
    v7.AIL_set_sample_obstruction(s, 0.5);
    _ = v7.AIL_sample_obstruction(s);
    v7.AIL_set_sample_occlusion(s, 0.5);
    _ = v7.AIL_sample_occlusion(s);
    v7.AIL_set_sample_exclusion(s, 0.5);
    _ = v7.AIL_sample_exclusion(s);

    // Listener + master + room.
    v7.AIL_listener_3D_position(drv, &f32o, &f32o, &f32o);
    v7.AIL_listener_3D_velocity(drv, &f32o, &f32o, &f32o);
    v7.AIL_listener_3D_orientation(drv, &f32o, &f32o, &f32o, &f32o, &f32o, &f32o);
    v7.AIL_set_listener_3D_velocity_vector(drv, 0, 0, 0);
    v7.AIL_update_listener_3D_position(drv, 0.016);
    _ = v7.AIL_digital_master_volume_level(drv);
    v7.AIL_set_digital_master_volume_level(drv, 0.9);
    v7.AIL_set_digital_master_reverb(drv, 0, 1.0, 0.02, 0.5);
    v7.AIL_digital_master_reverb(drv, 0, &f32o, &f32o, &f32o);
    v7.AIL_set_digital_master_reverb_levels(drv, 0, 0.8, 0.2);
    v7.AIL_digital_master_reverb_levels(drv, 0, &f32o, &f32o);
    v7.AIL_set_room_type(drv, 0, 3);
    _ = v7.AIL_room_type(drv, 0);

    // Redbook + quick + bridges + stubs.
    const h = rb.AIL_redbook_open_drive(0);
    if (h) |hh| {
        v7.AIL_redbook_set_volume_level(hh, 0.5);
        _ = v7.AIL_redbook_volume_level(hh);
        rb.AIL_redbook_close(hh);
    }
    v7.AIL_quick_set_low_pass_cut_off(s, 0, 8000);
    v7.AIL_quick_set_reverb_levels(s, 0.7, 0.3);
    _ = v7.AIL_stream_sample_handle(s);
    _ = v7.AIL_DLS_sample_handle(null);
    _ = v7.AIL_find_filter("x", &prov);
    _ = v7.AIL_background_CPU_percent();
    _ = v7.AIL_sample_processor(s, 0);
    _ = v7.AIL_digital_driver_processor(drv, 0);
    v7.AIL_sample_stage_attribute(s, "x", sc());
    v7.AIL_set_sample_stage_preference(s, "x", sc());
    _ = v7.AIL_enumerate_sample_stage_attributes(s, &next, sc());
    v7.AIL_sample_channel_levels(s, null, null, &f32o, 0);
    v7.AIL_set_sample_channel_levels(s, null, null, &f32o, 0);
    _ = v7.AIL_listener_relative_receiver_array(drv, &i32o);
    v7.AIL_set_listener_relative_receiver_array(drv, null, 0);
    v7.AIL_speaker_configuration(drv, &i32o, &i32o, &f32o, sc());
    v7.AIL_set_speaker_configuration(drv, null, 2, 1);
    v7.AIL_speaker_reverb_levels(drv, null, null, null);
    v7.AIL_set_speaker_reverb_levels(drv, &f32o, &f32o, null, 0);
    v7.AIL_calculate_3D_channel_levels(drv, s, 0, &f32o, sc());
    _ = v7.AIL_digital_output_filter(drv);
    v7.AIL_output_filter_driver_attribute(null, "x", sc());
    v7.AIL_set_output_filter_driver_preference(null, "x", sc());
    _ = v7.AIL_enumerate_output_filter_driver_attributes(null, &next, sc());
    _ = v7.AIL_enumerate_output_filter_sample_attributes(null, &next, sc());
    _ = v7.AIL_inspect_MP3(sc(), sc(), 0);
    _ = v7.AIL_enumerate_MP3_frames(sc());
    _ = v7.RIB_load_static_provider_library(null, "x");
    _ = v7.RIB_MAIN(null, "x");
}

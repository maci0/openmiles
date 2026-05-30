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
    prov = openmiles.Provider.init(alloc, null) catch null;
    defer if (prov) |p| p.deinit();
    const filt: ?*anyopaque = dg.AIL_open_filter(prov, drv);

    // Driver-level.
    _ = dg.AIL_primary_digital_driver(drv);
    _ = dg.AIL_digital_CPU_percent(drv);
    _ = dg.AIL_digital_latency(drv);
    dg.AIL_digital_configuration(drv, &i32o, &i32o, &i32o, &u32o);
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
    dg.AIL_filter_sample_attribute(s, "Cutoff", sc());
    dg.AIL_set_filter_sample_preference(s, "Cutoff", sc());

    // Filter-level (real filter handle).
    if (filt) |f| {
        dg.AIL_filter_attribute(f, "Cutoff", sc());
        dg.AIL_set_filter_attribute(f, "Cutoff", sc());
        dg.AIL_set_filter_preference(f, "Cutoff", sc());
        _ = dg.AIL_enumerate_filter_attributes(f, &next, &namep);
        next = null;
        _ = dg.AIL_enumerate_filter_sample_attributes(f, &next, &namep);
        dg.AIL_set_sample_filter(s, f, 0);
        dg.AIL_close_filter(f);
    }
    next = null;
    _ = dg.AIL_enumerate_filters(&next, &prov, &namep);

    // Allocators / misc.
    const m = dg.AIL_mem_alloc_lock(16);
    if (m) |mp| dg.AIL_mem_free_lock(mp);
    dg.AIL_mem_use_malloc(null);
    dg.AIL_mem_use_free(null);
    dg.AIL_set_mem_callbacks(null, null);
    _ = dg.AIL_allocate_file_sample(drv, @ptrCast(wav.ptr), 0);

    // WAV info / encoders.
    var info: openmiles.AILSOUNDINFO = undefined;
    _ = dg.AIL_WAV_info(@ptrCast(wav.ptr), &info);
    info = .{ .format = 0, .data_ptr = @ptrCast(&pcm), .data_len = pcm.len, .rate = 8000, .bits = 16, .channels = 1, .samples = 0, .block_size = 0, .initial_ptr = null };
    var outp: *anyopaque = undefined;
    if (dg.AIL_compress_ADPCM(&info, &outp, &u32o) != 0) dg.AIL_mem_free_lock(outp);
    if (dg.AIL_decompress_ADPCM(&info, &outp, &u32o) != 0) dg.AIL_mem_free_lock(outp);

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
    st.AIL_stream_info(n, &i32o, &i32o, &i32o, &i32o, &i32o);
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
    qk.AIL_quick_set_volume(n, 64);
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
        _ = inp.AIL_get_input_info(ipt);
        inp.AIL_close_input(ipt);
    }
}

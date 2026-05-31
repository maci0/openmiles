//! Fuzz-all harness: invokes every exported function that accepts caller input
//! in a multi-seed PRNG loop with adversarial scalars/strings/buffers + a pool
//! of real handles, so each is both tested (called) and fuzzed (varied inputs).
//! Buffer lengths are bounded to the real scratch, so any over-read/write is a
//! genuine library bug rather than a harness contract violation.
//!
//! Out of scope here (covered by the ordered unit tests in main_test.zig and
//! the C integration harnesses instead): lifecycle functions that destroy or
//! create shared state — startup/shutdown, the open_*/close_*/release_* and
//! *_handle_release destructors, the DLS/memory subsystem teardown, the filter
//! attribute calls that need a live filter handle, and DllMain. Looping those
//! over a shared handle pool would tear it down rather than exercise input.
const std = @import("std");
const testing = std.testing;
const openmiles = @import("openmiles");
const api_digital = @import("api/digital.zig");
const api_3d = @import("api/3d.zig");
const api_stream = @import("api/stream.zig");
const api_quick = @import("api/quick.zig");
const api_legacy = @import("api/legacy.zig");
const api_redbook = @import("api/redbook.zig");
const api_timer = @import("api/timer.zig");
const api_file = @import("api/file.zig");
const api_input = @import("api/input.zig");
const api_midi = @import("api/midi.zig");
const api_dls = @import("api/dls.zig");
const api_rib = @import("api/rib.zig");
const api_filter = @import("api/filter.zig");
const api_memory = @import("api/memory.zig");
const api_v7 = @import("api/v7.zig");
const api_v8 = @import("api/v8.zig");
const api_v9 = @import("api/v9.zig");
const api_miles = @import("api/miles.zig");
fn dummyTimerCb(_: u32) callconv(.winapi) void {}
const alloc = std.heap.page_allocator;
var g_scratch: [65536]u8 align(8) = [_]u8{0} ** 65536;
test "fuzz: invoke every export with adversarial inputs" {
    var prng = std.Random.DefaultPrng.init(0xF0F0F0F0);
    const rand = prng.random();
    const advf = [_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), -1e30, -1, 0, 0.5, 1, 1e30 };
    const advi = [_]i32{ std.math.minInt(i32), -1, 0, 1, 127, 44100, std.math.maxInt(i32) };
    const hd = openmiles.DigitalDriver.init(alloc, 44100, 16, 2) catch return;
    defer hd.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = openmiles.buildWavFromPcm(alloc, &pcm, 1, 8000, 16) catch return;
    defer alloc.free(wav);
    const hm = openmiles.MidiDriver.init(alloc) catch return;
    defer hm.deinit();
    const hr = openmiles.Redbook.init(alloc, 0) catch return;
    defer hr.deinit();
    const ht_h = api_timer.AIL_register_timer(dummyTimerCb);
    const ht: ?*openmiles.Timer = if (ht_h) |t| @ptrCast(@alignCast(t)) else null;
    defer if (ht) |t| api_timer.AIL_release_timer_handle(t);
    // Sweep several PRNG seeds so the adversarial input space is explored more
    // broadly than a single fixed sequence would. Driver/timer handles above
    // are set up once and reused across all rounds.
    const seeds = [_]u64{ 0xF0F0F0F0, 0x12345678, 0xDEADBEEF, 0xCAFEBABE, 0x00000000, 0xFFFFFFFFFFFFFFFF, 0x9E3779B9, 0x1, 0x5555AAAA, 0xC0FFEE };
    for (seeds) |sd| {
        prng = std.Random.DefaultPrng.init(sd);
        var iter: usize = 0;
        while (iter < 200) : (iter += 1) {
        const rf = advf[rand.intRangeLessThan(usize, 0, advf.len)];
        const rf64: f64 = rf;
        const ri = advi[rand.intRangeLessThan(usize, 0, advi.len)];
        const ru: u32 = @bitCast(ri);
        const ru64: u64 = rand.int(u64);
        const ri64: i64 = @bitCast(ru64);
        rand.bytes(&g_scratch);
        g_scratch[g_scratch.len - 1] = 0; for (0..256) |zz| g_scratch[zz] = 0;
        const scp: *anyopaque = @ptrCast(&g_scratch);
        const rstr: [*:0]const u8 = @ptrCast(&g_scratch);
        var fo: f32 = 0;
        var io: i32 = 0;
        var uo: u32 = 0;
        var zo: usize = 0;
        var pp: ?*anyopaque = null;
        var ppnn: *anyopaque = scp;
        var prov: ?*openmiles.Provider = null;
        var pd: ?*openmiles.DigitalDriver = null;
        var pm: ?*openmiles.MidiDriver = null;
        var namep: [*:0]const u8 = rstr;
        var ps: ?*openmiles.Sample = null;
        const rz: usize = @truncate(ru64);
        const rsz: u32 = rand.intRangeAtMost(u32, 0, 256);
        const rszi: i32 = @intCast(rsz);
        var info: openmiles.AILSOUNDINFO = .{ .format = ri, .data_ptr = scp, .data_len = rand.intRangeAtMost(u32, 0, 256), .rate = ru, .bits = ri, .channels = ri, .samples = ru, .block_size = ru, .initial_ptr = null };
        std.mem.doNotOptimizeAway(.{ rf, rf64, ri, ru, ru64, ri64, scp, rstr, &fo, &io, &uo, &zo, &pp, &ppnn, &prov, &pd, &pm, &info, &namep, &ps, rz, rsz, rszi });
        // Fresh per-iteration handles so adversarial mutation can't accumulate
        // across iterations and crash a later getter.
        const hs = openmiles.Sample.init(hd) catch return;
        defer hs.deinit();
        hs.loadFromMemory(wav, false) catch {};
        const h3 = openmiles.Sample3D.init(hd) catch return;
        defer h3.deinit();
        const hq = openmiles.Sequence.init(hm) catch return;
        defer hq.deinit();
    _ = api_3d.AIL_3D_distance_factor(hd);
    _ = api_3d.AIL_3D_doppler_factor(hd);
    api_3d.AIL_3D_orientation(@as(*anyopaque, @ptrCast(h3)), &fo, &fo, &fo, &fo, &fo, &fo);
    api_3d.AIL_3D_position(@as(*anyopaque, @ptrCast(h3)), &fo, &fo, &fo);
    api_3d.AIL_3D_provider_attribute(@as(*anyopaque, @ptrCast(hd)), rstr, scp);
    _ = api_3d.AIL_3D_rolloff_factor(hd);
    _ = api_3d.AIL_3D_room_type(hd);
    api_3d.AIL_3D_sample_attribute(@as(?*anyopaque, @ptrCast(h3)), rstr, scp);
    api_3d.AIL_3D_sample_cone(@as(?*anyopaque, @ptrCast(h3)), &fo, &fo, &io);
    api_3d.AIL_3D_sample_distances(h3, &fo, &fo);
    api_3d.AIL_set_3D_sample_float_distances_v5(@as(?*anyopaque, @ptrCast(h3)), rf, rf, rf, rf);
    api_3d.AIL_3D_sample_float_distances_v5(h3, &fo, &fo, &fo, &fo);
    _ = api_3d.AIL_3D_sample_effects_level(@as(?*anyopaque, @ptrCast(h3)));
    _ = api_3d.AIL_3D_sample_length(@as(?*anyopaque, @ptrCast(h3)));
    _ = api_3d.AIL_3D_sample_loop_count(@as(?*anyopaque, @ptrCast(h3)));
    api_3d.AIL_3D_sample_ms_position(@as(?*anyopaque, @ptrCast(h3)), &io, &io);
    _ = api_3d.AIL_3D_sample_obstruction(@as(?*anyopaque, @ptrCast(h3)));
    _ = api_3d.AIL_3D_sample_occlusion(@as(?*anyopaque, @ptrCast(h3)));
    _ = api_3d.AIL_3D_sample_offset(@as(?*anyopaque, @ptrCast(h3)));
    _ = api_3d.AIL_3D_sample_playback_rate(@as(?*anyopaque, @ptrCast(h3)));
    _ = api_3d.AIL_3D_sample_status(@as(?*anyopaque, @ptrCast(h3)));
    _ = api_3d.AIL_3D_sample_volume(@as(?*anyopaque, @ptrCast(h3)));
    _ = api_3d.AIL_3D_speaker_type(hd);
    _ = api_3d.AIL_3D_user_data(@as(?*anyopaque, @ptrCast(h3)), ri);
    api_3d.AIL_3D_velocity(@as(*anyopaque, @ptrCast(h3)), &fo, &fo, &fo);
    _ = api_rib.AIL_ASI_provider_attribute(prov, rstr);
    api_dls.AIL_DLS_compact(hm);
    api_dls.AIL_DLS_get_reverb(hm, &fo, &fo, &fo);
    _ = api_dls.AIL_DLS_load_file(hm, rstr, ru);
    _ = api_dls.AIL_DLS_load_memory(hm, scp, ru);
    _ = api_v7.AIL_DLS_sample_handle(hm);
    api_dls.AIL_DLS_set_reverb(hm, rf, rf, rf);
    _ = api_digital.AIL_HWND();
    _ = api_v9.AIL_IO_thread_handle(null);
    _ = api_midi.AIL_MIDI_handle_reacquire(scp);
    _ = api_digital.AIL_MMX_available();
    _ = api_digital.AIL_WAV_info(scp, scp);
    _ = api_v8.AIL_WAV_marker_by_index(null, ri, null);
    _ = api_v8.AIL_WAV_marker_by_name(null, null);
    _ = api_v8.AIL_WAV_marker_count(null);
    _ = api_midi.AIL_XMIDI_master_volume(hm);
    _ = api_3d.AIL_active_3D_sample_count(hd);
    _ = api_digital.AIL_active_sample_count(hd);
    _ = api_midi.AIL_active_sequence_count(scp);
    _ = api_v8.AIL_add_apply_environment_event_step(null, null, ri);
    _ = api_v8.AIL_add_cache_sounds_event_step(null, null, null);
    _ = api_v9.AIL_add_clear_state_event_step(null);
    _ = api_v8.AIL_add_comment_event_step(null, null);
    _ = api_v8.AIL_add_control_sounds_event_step(null, null, null, null, null, null, ri, rf, ri, ri);
    _ = api_v9.AIL_add_exec_event_event_step(null, null);
    _ = api_v8.AIL_add_persist_preset_event_step(null, null, null, null, ri);
    _ = api_v9.AIL_add_ramp_event_step(null, null, null, rf, null, ri, ri, ri);
    _ = api_v9.AIL_add_setblend_event_step(null, null, ri, null, null, null, null, null, null);
    _ = api_v8.AIL_add_sound_limit_event_step(null, null, null);
    _ = api_v8.AIL_add_start_sound_event_step(null, null, null, ri, null, null, null, null, null, null, ru, ri, ri, ri, ri, ri, null, rf, rf, rf, rf, rf, ri, ri);
    _ = api_v8.AIL_add_uncache_sounds_event_step(null, null, null);
    // Release immediately: Sample/Sequence.init append to the driver's lists, so
    // discarding the handle here would leak ~2000 live objects across the sweep
    // and skew every later count/scan. (The full alloc->release lifecycle is also
    // exercised on throwaway handles further down.)
    if (api_3d.AIL_allocate_3D_sample_handle(hd)) |h| api_3d.AIL_release_3D_sample_handle(h);
    if (api_digital.AIL_allocate_sample_handle(hd)) |h| api_digital.AIL_release_sample_handle(h);
    if (api_midi.AIL_allocate_sequence_handle(hm)) |h| api_midi.AIL_release_sequence_handle(h);
    _ = api_v8.AIL_apply_environment_preset(null, null, null);
    _ = api_v9.AIL_apply_raw_environment_preset(null, null);
    _ = api_v9.AIL_apply_raw_sound_preset(null, null);
    _ = api_v8.AIL_apply_sound_preset(null, null, null);
    api_stream.AIL_auto_service_stream(hs, ri);
    api_3d.AIL_auto_update_3D_position(@as(?*anyopaque, @ptrCast(h3)), ri);
    _ = api_digital.AIL_background();
    _ = api_v7.AIL_background_CPU_percent();
    api_midi.AIL_branch_index(hq, ru);
    _ = api_v7.AIL_calculate_3D_channel_levels(hd, &fo, scp, scp, scp, scp, rf, rf, rf, rf, rf, scp, scp, scp, rf, scp, &fo);
    _ = api_midi.AIL_channel_notes(hq, ri);
    _ = api_digital.AIL_compress_ADPCM(&info, &ppnn, &uo);
    _ = api_rib.AIL_compress_ASI(&info, rstr, &pp, &uo, null);
    _ = api_dls.AIL_compress_DLS(null, rstr, &pp, &uo, null);
    api_v9.AIL_configure_logging(null, ri, ri);
    _ = api_midi.AIL_controller_value(hq, ri, ri);
    _ = api_v8.AIL_create_event();
    api_v8.AIL_debug(null);
    api_v8.AIL_debug_log(null);
    _ = api_digital.AIL_decompress_ADPCM(&info, &ppnn, &uo);
    _ = api_rib.AIL_decompress_ASI(scp, rsz, rstr, &pp, &uo, null);
    api_digital.AIL_delay(rand.intRangeAtMost(u32, 0, 1)); // bounded: real sleep, don't block the fuzzer
    _ = api_digital.AIL_digital_CPU_percent(hd);
    api_digital.AIL_digital_configuration(hd, &io, &io, @as([*]u8, @ptrCast(&g_scratch)));
    _ = api_v7.AIL_digital_driver_processor(hd, ri);
    _ = api_digital.AIL_digital_handle_reacquire(hd);
    _ = api_digital.AIL_digital_latency(hd);
    api_v7.AIL_digital_master_reverb(hd, ri, &fo, &fo, &fo);
    api_v7.AIL_digital_master_reverb_levels(hd, ri, &fo, &fo);
    // v7/v8 narrow-ABI variants (no bus_index/channel)
    _ = api_v7.AIL_room_type_v7(hd);
    api_v7.AIL_set_room_type_v7(hd, ri);
    api_v7.AIL_digital_master_reverb_v7(hd, &fo, &fo, &fo);
    api_v7.AIL_set_digital_master_reverb_v7(hd, rf, rf, rf);
    api_v7.AIL_digital_master_reverb_levels_v7(hd, &fo, &fo);
    api_v7.AIL_set_digital_master_reverb_levels_v7(hd, rf, rf);
    _ = api_v7.AIL_sample_low_pass_cut_off_v7(hs);
    api_v7.AIL_set_sample_low_pass_cut_off_v7(hs, rf);
    api_v7.AIL_quick_set_low_pass_cut_off_v7(hs, rf);
    api_digital.AIL_init_sample_v7(hs, ri, ri);
    api_v7.AIL_sample_stage_attribute_v7(hs, ri, rstr, scp);
    api_v7.AIL_set_sample_stage_preference_v7(hs, ri, rstr, scp);
    {
        var sp: ?*anyopaque = null;
        _ = api_v7.AIL_enumerate_sample_stage_attributes_v7(hs, ri, &sp, scp);
    }
    api_v7.AIL_sample_channel_levels_v7(hs, &fo);
    api_v7.AIL_set_sample_channel_levels_v7(hs, &fo, ri);
    api_v7.AIL_set_speaker_reverb_levels_v7(hd, &fo, &fo, ri);
    api_rib.AIL_request_EOB_ASI_reset_v7(hs, ru);
    _ = api_rib.MIX_RIB_MAIN_v7(prov, ru);
    _ = api_digital.AIL_digital_master_volume(hd);
    _ = api_v7.AIL_digital_master_volume_level(hd);
    _ = api_v7.AIL_digital_output_filter(hd);
    api_3d.AIL_end_3D_sample(@as(?*anyopaque, @ptrCast(h3)));
    api_digital.AIL_end_sample(hs);
    api_midi.AIL_end_sequence(hq);
    _ = api_3d.AIL_enumerate_3D_provider_attributes(@as(*anyopaque, @ptrCast(hd)), &pp, &namep);
    _ = api_3d.AIL_enumerate_3D_providers(&pp, &prov, &namep);
    _ = api_3d.AIL_enumerate_3D_sample_attributes(@as(?*anyopaque, @ptrCast(h3)), &pp, &namep);
    _ = api_v7.AIL_enumerate_MP3_frames(null);
    _ = api_v8.AIL_enumerate_environment_presets(null, null, null, null);
    _ = api_v8.AIL_enumerate_events(null, null, null, null);
    _ = api_v8.AIL_enumerate_filter_properties(null, null, null);
    _ = api_v8.AIL_enumerate_filter_sample_properties(null, null, null);
    _ = api_filter.AIL_enumerate_filters(&pp, &prov, &namep);
    _ = api_v7.AIL_enumerate_output_filter_driver_attributes(null, &pp, scp);
    _ = api_v8.AIL_enumerate_output_filter_driver_properties(null, null, null);
    _ = api_v7.AIL_enumerate_output_filter_sample_attributes(null, &pp, scp);
    _ = api_v8.AIL_enumerate_output_filter_sample_properties(null, null, null);
    _ = api_v7.AIL_enumerate_sample_stage_attributes(hs, &pp, scp);
    _ = api_v8.AIL_enumerate_sample_stage_properties(null, ri, null, null);
    _ = api_v8.AIL_enumerate_sound_assets(null, null, null);
    _ = api_v8.AIL_enumerate_sound_presets(null, null, null, null);
    _ = api_dls.AIL_extract_DLS(null, rsz, &pp, &uo, &pp, &uo, null);
    api_v9.AIL_file_callbacks(null, null, null, null);
    _ = api_file.AIL_file_error();
    _ = api_v9.AIL_file_read_info(null, null, null, ru);
    _ = api_file.AIL_file_size(rstr);
    _ = api_v9.AIL_file_size_info(null, null, ru);
    _ = api_file.AIL_file_type(scp, rsz);
    _ = api_v8.AIL_file_type_named(null, null, ru);
    api_dls.AIL_filter_DLS_attribute(hm, rstr, scp);
    _ = api_dls.AIL_filter_DLS_with_XMI(null, null, &pp, &uo, ri, null);
    _ = api_v8.AIL_filter_property(null, null, null, null, null);
    api_filter.AIL_filter_sample_attribute(hs, rstr, scp);
    api_stream.AIL_filter_stream_attribute(hs, rstr, scp);
    _ = api_dls.AIL_find_DLS(null, rsz, &pp, &uo, &pp, &uo);
    _ = api_v9.AIL_find_environment_preset(null, null);
    _ = api_v7.AIL_find_filter(rstr, &prov);
    _ = api_v8.AIL_find_marker_in_list(ri, null, null);
    _ = api_v9.AIL_find_sound_preset(null, null);
    _ = api_v8.AIL_ftoa(rf, null);
    _ = api_v8.AIL_get_event_contents(null, null, null);
    _ = api_input.AIL_input_info(null);
    api_v8.AIL_get_marker_list(null, null);
    _ = api_digital.AIL_get_preference(ru);
    _ = api_v8.AIL_get_soundbank_filename(null);
    _ = api_v8.AIL_get_soundbank_mem_usage(null);
    _ = api_v9.AIL_get_soundbank_name(null);
    _ = api_v9.AIL_get_time();
    _ = api_timer.AIL_get_timer_highest_delay();
    api_v8.AIL_indent(ri);
    _ = api_v7.AIL_inspect_MP3(null, null, rszi);
    _ = api_digital.AIL_last_error();
    _ = api_dls.AIL_list_DLS(null, &pp, &uo, ri, rstr);
    _ = api_midi.AIL_list_MIDI(null, rsz, &pp, &uo, ri);
    api_v7.AIL_listener_3D_orientation(hd, &fo, &fo, &fo, &fo, &fo, &fo);
    api_v7.AIL_listener_3D_position(hd, &fo, &fo, &fo);
    api_v7.AIL_listener_3D_velocity(hd, &fo, &fo, &fo);
    _ = api_v7.AIL_listener_relative_receiver_array(hd, &io);
    api_digital.AIL_lock();
    _ = api_midi.AIL_lock_channel(hm);
    api_digital.AIL_lock_mutex();
    api_midi.AIL_map_sequence_channel(hq, ri, ri);
    _ = api_memory.AIL_mem_alloc_lock(rsz);
    _ = api_v9.AIL_mem_alloc_lock_info(ru, null, ru);
    _ = api_v8.AIL_mem_create();
    _ = api_v8.AIL_mem_create_from_existing(null, rszi);
    _ = api_v8.AIL_mem_error(null);
    _ = api_v8.AIL_mem_open(null, rszi);
    _ = api_v8.AIL_mem_pos(null);
    _ = api_v8.AIL_mem_printc(null, ri);
    _ = api_v8.AIL_mem_printf(null, null);
    _ = api_v8.AIL_mem_prints(null, null);
    _ = api_v8.AIL_mem_read(null, null, ri);
    _ = api_v8.AIL_mem_seek(null, ri);
    _ = api_v8.AIL_mem_size(null);
    api_memory.AIL_mem_use_malloc(null);
    _ = api_v8.AIL_mem_write(null, null, ri);
    _ = api_dls.AIL_merge_DLS_with_XMI(null, null, &pp, &uo);
    _ = api_midi.AIL_midiOutOpen(scp, &ppnn, ri);
    _ = api_digital.AIL_minimum_sample_buffer_size(hd, ri, ri);
    _ = api_digital.AIL_ms_count();
    _ = api_v9.AIL_ms_count64();
    _ = api_v9.AIL_ms_to_time(ru64);
    _ = api_v8.AIL_next_event_step(null, null, null, ri);
    _ = api_rib.AIL_open_ASI_provider(scp, rsz);
    _ = api_midi.AIL_open_XMIDI_driver(ru);
    _ = api_digital.AIL_open_digital_driver(ru, ri, ri, ru);
    _ = api_filter.AIL_open_filter(prov, hd);
    _ = api_midi.AIL_open_midi_driver(ru);
    _ = api_v8.AIL_open_soundbank(null, null);
    api_v7.AIL_output_filter_driver_attribute(null, rstr, scp);
    _ = api_v8.AIL_output_filter_driver_property(null, null, null, null, null);
    api_digital.AIL_pause_sample(hs);
    api_midi.AIL_pause_sequence(hq);
    api_stream.AIL_pause_stream(hs, ri);
    _ = api_v8.AIL_platform_property(null, ri, null, null, null);
    _ = api_digital.AIL_primary_digital_driver(hd);
    api_quick.AIL_quick_halt(hs);
    api_quick.AIL_quick_handles(&ps, &pd, &pm);
    _ = api_quick.AIL_quick_ms_length(hs);
    _ = api_quick.AIL_quick_ms_position(hs);
    api_quick.AIL_quick_play(hs, ri);
    api_v7.AIL_quick_set_low_pass_cut_off(hs, ri, rf);
    api_quick.AIL_quick_set_ms_position(hs, ri);
    api_quick.AIL_quick_set_reverb(hs, rf, rf, rf);
    api_v7.AIL_quick_set_reverb_levels(hs, rf, rf);
    api_quick.AIL_quick_set_speed(hs, ri);
    api_quick.AIL_quick_set_volume(hs, ri, ri);
    api_quick.AIL_quick_set_volume_f32(hs, rf, rf);
    _ = api_quick.AIL_quick_status(hs);
    if (api_quick.AIL_quick_load_named_mem(scp, rstr, rsz)) |qs| qs.deinit();
    // 6.x-only legacy exports
    if (api_legacy.AIL_open_library(rstr, ru)) |lib| api_legacy.AIL_close_library(lib);
    _ = api_legacy.AIL_library_resource_filename(null, ri, scp, ri);
    _ = api_legacy.AIL_load_sample_attributes(hs, scp);
    _ = api_legacy.AIL_save_sample_attributes(hs, scp);
    api_quick.AIL_quick_stop(hs);
    _ = api_quick.AIL_quick_type(hs);
    _ = api_redbook.AIL_redbook_eject(hr);
    _ = api_redbook.AIL_redbook_id(hr);
    _ = api_redbook.AIL_redbook_open(ru);
    _ = api_redbook.AIL_redbook_open_drive(ri);
    _ = api_redbook.AIL_redbook_pause(hr);
    _ = api_redbook.AIL_redbook_play(hr, ru, ru);
    _ = api_redbook.AIL_redbook_position(hr);
    _ = api_redbook.AIL_redbook_resume(hr);
    _ = api_redbook.AIL_redbook_retract(hr);
    api_redbook.AIL_redbook_set_volume(hr, ri);
    _ = api_v7.AIL_redbook_set_volume_level(hr, rf);
    _ = api_redbook.AIL_redbook_status(hr);
    _ = api_redbook.AIL_redbook_stop(hr);
    _ = api_redbook.AIL_redbook_track(hr);
    api_redbook.AIL_redbook_track_info(hr, ru, &uo, &uo);
    _ = api_redbook.AIL_redbook_tracks(hr);
    _ = api_redbook.AIL_redbook_volume(hr);
    _ = api_v7.AIL_redbook_volume_level(hr);
    _ = api_3d.AIL_register_3D_EOS_callback(@as(?*anyopaque, @ptrCast(h3)), null);
    _ = api_digital.AIL_register_EOB_callback(hs, null);
    _ = api_stream.AIL_register_EOF_callback(hs, null);
    _ = api_digital.AIL_register_EOS_callback(hs, null);
    api_midi.AIL_register_ICA_array(hq, scp);
    _ = api_digital.AIL_register_SOB_callback(hs, null);
    _ = api_midi.AIL_register_beat_callback(hq, null);
    _ = api_midi.AIL_register_event_callback(hm, null);
    api_v8.AIL_register_falloff_function_callback(null, ri);
    _ = api_midi.AIL_register_prefix_callback(hq, null);
    _ = api_midi.AIL_register_sequence_callback(hq, null);
    _ = api_stream.AIL_register_stream_callback(hs, null);
    _ = api_midi.AIL_register_timbre_callback(hm, null);
    api_v8.AIL_register_trace_callback(null);
    _ = api_midi.AIL_register_trigger_callback(hq, null);
    api_rib.AIL_request_EOB_ASI_reset(hs, ru, ri);
    _ = api_v9.AIL_resolve_raw_environment_preset(null, ri);
    _ = api_v9.AIL_resolve_raw_sound_preset(null, null, ri);
    api_3d.AIL_resume_3D_sample(@as(?*anyopaque, @ptrCast(h3)));
    api_digital.AIL_resume_sample(hs);
    api_midi.AIL_resume_sequence(hq);
    _ = api_v7.AIL_room_type(hd, ri);
    api_v7.AIL_sample_3D_cone(hs, &fo, &fo, &fo);
    api_v7.AIL_sample_3D_distances(hs, &fo, &fo, &io);
    api_v7.AIL_sample_3D_orientation(hs, &fo, &fo, &fo, &fo, &fo, &fo);
    _ = api_v7.AIL_sample_3D_position(hs, &fo, &fo, &fo);
    api_v7.AIL_sample_3D_velocity(hs, &fo, &fo, &fo);
    api_v8.AIL_sample_51_volume_levels(null, null, null, null, null, null, null);
    api_v8.AIL_sample_51_volume_pan(null, null, null, null, null, null);
    _ = api_v8.AIL_sample_buffer_available(null);
    _ = api_v8.AIL_sample_buffer_count(null);
    _ = api_digital.AIL_sample_buffer_info(hs, ri, &uo, &uo, &uo, &uo);
    _ = api_digital.AIL_sample_buffer_ready(hs);
    _ = api_v8.AIL_sample_channel_count(null, null);
    api_v7.AIL_sample_channel_levels(hs, null, null, &fo, rszi);
    _ = api_v7.AIL_sample_exclusion(hs);
    _ = api_digital.AIL_sample_granularity(hs);
    _ = api_v9.AIL_sample_loaded_len(null);
    _ = api_v8.AIL_sample_loop_block(null, null, null);
    _ = api_digital.AIL_sample_loop_count(hs);
    _ = api_v7.AIL_sample_low_pass_cut_off(hs, ri);
    _ = api_v9.AIL_sample_ms_lookup(null, ri, null);
    api_digital.AIL_sample_ms_position(hs, &io, &io);
    _ = api_v7.AIL_sample_obstruction(hs);
    _ = api_v7.AIL_sample_occlusion(hs);
    _ = api_v8.AIL_sample_output_levels(null, null, null, null, ri);
    _ = api_digital.AIL_sample_pan(hs);
    _ = api_v8.AIL_sample_playback_delay(null);
    _ = api_digital.AIL_sample_playback_rate(hs);
    _ = api_v8.AIL_sample_playback_rate_factor(hs);
    _ = api_digital.AIL_sample_position(hs);
    _ = api_v7.AIL_sample_processor(hs, ri);
    api_digital.AIL_sample_reverb(hs, &fo, &fo, &fo);
    api_v7.AIL_sample_reverb_levels(hs, &fo, &fo);
    api_v8.AIL_sample_speaker_scale_factors(null, null, null, ri);
    api_v7.AIL_sample_stage_attribute(hs, rstr, scp);
    _ = api_v8.AIL_sample_stage_property(null, ri, null, ri, null, null, null);
    _ = api_digital.AIL_sample_status(hs);
    _ = api_digital.AIL_sample_user_data(hs, ri);
    _ = api_digital.AIL_sample_volume(hs);
    api_v7.AIL_sample_volume_levels(hs, &fo, &fo);
    api_v7.AIL_sample_volume_pan(hs, &fo, &fo);
    api_midi.AIL_send_channel_voice_message(hm, hq, ri, ri, ri);
    api_midi.AIL_send_sysex_message(hm, scp);
    _ = api_midi.AIL_sequence_loop_count(hq);
    api_midi.AIL_sequence_ms_position(hq, &io, &io);
    api_midi.AIL_sequence_position(hq, &io, &io);
    _ = api_midi.AIL_sequence_status(hq);
    _ = api_midi.AIL_sequence_tempo(hq);
    _ = api_midi.AIL_sequence_user_data(hq, ri);
    _ = api_midi.AIL_sequence_volume(hq);
    api_digital.AIL_serve();
    _ = api_stream.AIL_service_stream(hs, ri);
    api_3d.AIL_set_3D_distance_factor(hd, rf);
    api_3d.AIL_set_3D_doppler_factor(hd, rf);
    api_3d.AIL_set_3D_orientation(@as(?*anyopaque, @ptrCast(h3)), rf, rf, rf, rf, rf, rf);
    api_3d.AIL_set_3D_position(@as(?*anyopaque, @ptrCast(h3)), rf, rf, rf);
    api_3d.AIL_set_3D_provider_preference(@as(*anyopaque, @ptrCast(hd)), rstr, scp);
    api_3d.AIL_set_3D_rolloff_factor(hd, rf);
    api_3d.AIL_set_3D_room_type(hd, ri);
    api_3d.AIL_set_3D_sample_cone(@as(?*anyopaque, @ptrCast(h3)), rf, rf, ri);
    api_3d.AIL_set_3D_sample_distances(@as(?*anyopaque, @ptrCast(h3)), rf, rf);
    api_3d.AIL_set_3D_sample_effects_level(@as(?*anyopaque, @ptrCast(h3)), rf);
    api_3d.AIL_set_3D_sample_loop_block(@as(?*anyopaque, @ptrCast(h3)), ri, ri);
    api_3d.AIL_set_3D_sample_loop_count(@as(?*anyopaque, @ptrCast(h3)), rszi);
    api_3d.AIL_set_3D_sample_ms_position(@as(?*anyopaque, @ptrCast(h3)), ri);
    api_3d.AIL_set_3D_sample_obstruction(@as(?*anyopaque, @ptrCast(h3)), rf);
    api_3d.AIL_set_3D_sample_occlusion(@as(?*anyopaque, @ptrCast(h3)), rf);
    api_3d.AIL_set_3D_sample_offset(@as(?*anyopaque, @ptrCast(h3)), ru);
    api_3d.AIL_set_3D_sample_playback_rate(@as(?*anyopaque, @ptrCast(h3)), ri);
    api_3d.AIL_set_3D_sample_preference(@as(?*anyopaque, @ptrCast(h3)), rstr, scp);
    api_3d.AIL_set_3D_sample_volume(@as(?*anyopaque, @ptrCast(h3)), ri);
    api_3d.AIL_set_3D_speaker_type(hd, ri);
    api_3d.AIL_set_3D_user_data(@as(?*anyopaque, @ptrCast(h3)), ri, ru);
    api_3d.AIL_set_3D_velocity(@as(?*anyopaque, @ptrCast(h3)), rf, rf, rf, rf);
    api_3d.AIL_set_3D_velocity_vector(@as(?*anyopaque, @ptrCast(h3)), rf, rf, rf);
    _ = api_dls.AIL_set_DLS_processor(hm, ri, null);
    api_digital.AIL_set_DirectSound_HWND(hd, scp);
    api_midi.AIL_set_XMIDI_master_volume(hm, ri);
    _ = api_digital.AIL_set_digital_driver_processor(hd, ri, null);
    api_v7.AIL_set_digital_master_reverb(hd, ri, rf, rf, rf);
    api_v7.AIL_set_digital_master_reverb_levels(hd, ri, rf, rf);
    api_digital.AIL_set_digital_master_volume(hd, ri);
    api_v7.AIL_set_digital_master_volume_level(hd, rf);
    api_digital.AIL_set_error(rstr);
    api_file.AIL_set_file_async_callbacks(null, null, null, null, null);
    api_file.AIL_set_file_callbacks(null, null, null, null);
    api_dls.AIL_set_filter_DLS_preference(hm, rstr, scp);
    api_filter.AIL_set_filter_sample_preference(hs, rstr, scp);
    api_stream.AIL_set_filter_stream_preference(hs, rstr, scp);
    api_input.AIL_set_input_state(null, ri);
    api_3d.AIL_set_listener_3D_orientation(hd, rf, rf, rf, rf, rf, rf);
    api_3d.AIL_set_listener_3D_position(hd, rf, rf, rf);
    api_3d.AIL_set_listener_3D_velocity(hd, rf, rf, rf, rf);
    api_v7.AIL_set_listener_3D_velocity_vector(hd, rf, rf, rf);
    api_v7.AIL_set_listener_relative_receiver_array(hd, null, ri);
    api_memory.AIL_set_mem_callbacks(null, null);
    api_v7.AIL_set_output_filter_driver_preference(null, rstr, scp);
    _ = api_digital.AIL_set_preference(ru, ri);
    api_digital.AIL_set_redist_directory(rstr);
    api_v7.AIL_set_room_type(hd, ri, ri);
    api_v7.AIL_set_sample_3D_cone(hs, rf, rf, rf);
    api_v7.AIL_set_sample_3D_distances(hs, rf, rf, ri);
    api_v7.AIL_set_sample_3D_orientation(hs, rf, rf, rf, rf, rf, rf);
    api_v7.AIL_set_sample_3D_position(hs, rf, rf, rf);
    api_v7.AIL_set_sample_3D_velocity(hs, rf, rf, rf, rf);
    api_v7.AIL_set_sample_3D_velocity_vector(hs, rf, rf, rf);
    api_v8.AIL_set_sample_51_volume_levels(hs, rf, rf, rf, rf, rf, rf);
    api_v8.AIL_set_sample_51_volume_pan(hs, rf, rf, rf, rf, rf);
    api_digital.AIL_set_sample_adpcm_block_size(hs, ru);
    _ = api_v8.AIL_set_sample_buffer_count(null, ri);
    api_v7.AIL_set_sample_channel_levels(hs, null, null, &fo, rszi);
    api_v7.AIL_set_sample_exclusion(hs, rf);
    _ = api_v8.AIL_set_sample_is_3D(hs, ri);
    api_digital.AIL_set_sample_loop_block(hs, ri, ri);
    api_digital.AIL_set_sample_loop_count(hs, rszi);
    api_v7.AIL_set_sample_low_pass_cut_off(hs, ri, rf);
    api_digital.AIL_set_sample_ms_position(hs, ri);
    api_v7.AIL_set_sample_obstruction(hs, rf);
    api_v7.AIL_set_sample_occlusion(hs, rf);
    api_digital.AIL_set_sample_pan(hs, ri);
    api_v8.AIL_set_sample_playback_delay(null, ri);
    api_digital.AIL_set_sample_playback_rate(hs, ri);
    api_v8.AIL_set_sample_playback_rate_factor(hs, rf);
    api_digital.AIL_set_sample_position(hs, ru);
    _ = api_digital.AIL_set_sample_processor(hs, ri, null);
    api_digital.AIL_set_sample_reverb(hs, rf, rf, rf);
    api_v7.AIL_set_sample_reverb_levels(hs, rf, rf);
    api_v8.AIL_set_sample_speaker_scale_factors(null, null, null, ri);
    api_v7.AIL_set_sample_stage_preference(hs, rstr, scp);
    api_digital.AIL_set_sample_type(hs, ru, ru);
    api_digital.AIL_set_sample_user_data(hs, ri, ru);
    api_digital.AIL_set_sample_volume(hs, ri);
    api_v7.AIL_set_sample_volume_levels(hs, rf, rf);
    api_digital.AIL_set_sample_volume_pan(hs, rf, rf);
    api_stream.AIL_set_stream_volume_pan(hs, rf, rf);
    api_midi.AIL_set_sequence_loop_count(hq, rszi);
    api_midi.AIL_set_sequence_ms_position(hq, ri);
    api_midi.AIL_set_sequence_tempo(hq, ri, ri);
    api_midi.AIL_set_sequence_user_data(hq, ri, ru);
    api_midi.AIL_set_sequence_volume(hq, ri, ri);
    api_v7.AIL_set_speaker_configuration(hd, null, ri, rf);
    api_v7.AIL_set_speaker_reverb_levels(hd, &fo, &fo, null, rszi);
    api_stream.AIL_set_stream_loop_block(hs, ri, ri);
    api_stream.AIL_set_stream_loop_count(hs, rszi);
    api_stream.AIL_set_stream_ms_position(hs, ri);
    api_stream.AIL_set_stream_pan(hs, ri);
    api_stream.AIL_set_stream_playback_rate(hs, ri);
    api_stream.AIL_set_stream_position(hs, ru);
    _ = api_stream.AIL_set_stream_processor(hs, ri, null);
    api_stream.AIL_set_stream_reverb(hs, rf, rf, rf);
    api_stream.AIL_set_stream_user_data(hs, ri, ru);
    api_stream.AIL_set_stream_volume(hs, ri);
    api_timer.AIL_set_timer_divisor(ht, ru);
    api_timer.AIL_set_timer_frequency(ht, ru);
    api_timer.AIL_set_timer_period(ht, ru);
    api_timer.AIL_set_timer_user(ht, ru);
    api_timer.AIL_set_timer_user_data(ht, ru);
    api_v9.AIL_sleep(rand.intRangeAtMost(u32, 0, 1)); // bounded: real sleep, don't block the fuzzer
    api_v8.AIL_sound_asset_filename(null, ri);
    _ = api_v9.AIL_sound_asset_info(null, null, null, null);
    api_v7.AIL_speaker_configuration(hd, &io, &io, &fo, null);
    api_3d.AIL_start_3D_sample(@as(?*anyopaque, @ptrCast(h3)));
    api_timer.AIL_start_all_timers();
    api_digital.AIL_start_sample(hs);
    api_midi.AIL_start_sequence(hq);
    api_stream.AIL_start_stream(hs);
    api_timer.AIL_start_timer(ht);
    api_3d.AIL_stop_3D_sample(@as(?*anyopaque, @ptrCast(h3)));
    api_timer.AIL_stop_all_timers();
    api_digital.AIL_stop_sample(hs);
    api_midi.AIL_stop_sequence(hq);
    api_timer.AIL_stop_timer(ht);
    _ = api_v9.AIL_stream_filled_percent(null);
    api_stream.AIL_stream_info(hs, &io, &io, &io, &io);
    _ = api_stream.AIL_stream_loop_count(hs);
    api_stream.AIL_stream_ms_position(hs, &io, &io);
    _ = api_stream.AIL_stream_pan(hs);
    _ = api_stream.AIL_stream_playback_rate(hs);
    _ = api_stream.AIL_stream_position(hs);
    api_stream.AIL_stream_reverb(hs, &fo, &fo, &fo);
    _ = api_v7.AIL_stream_sample_handle(hs);
    _ = api_stream.AIL_stream_status(hs);
    _ = api_stream.AIL_stream_user_data(hs, ri);
    _ = api_stream.AIL_stream_volume(hs);
    _ = api_v8.AIL_stricmp(null, null);
    _ = api_v8.AIL_strnicmp(null, null, ru);
    api_v8.AIL_sys_debug(null);
    _ = api_v9.AIL_time_to_ms(ru64);
    _ = api_v9.AIL_timer_thread_handle(null);
    _ = api_midi.AIL_true_sequence_channel(hq, ri);
    _ = api_v8.AIL_unapply_environment_preset(null, null, null);
    _ = api_v9.AIL_unapply_raw_environment_preset(null, null);
    _ = api_v9.AIL_unapply_raw_sound_preset(null, null);
    _ = api_v8.AIL_unapply_sound_preset(null, null, null);
    api_digital.AIL_unlock();
    api_digital.AIL_unlock_mutex();
    api_3d.AIL_update_3D_position(@as(?*anyopaque, @ptrCast(h3)), rf);
    api_v7.AIL_update_listener_3D_position(hd, rf);
    api_v7.AIL_update_sample_3D_position(hs, rf);
    _ = api_digital.AIL_us_count();
    _ = api_v9.AIL_us_count64();
    _ = api_digital.AIL_waveOutOpen(&pd, &uo, ri, null);
    api_dls.DLSCompactMemory(hm);
    _ = api_dls.DLSLoadFile(hm, rstr, ru);
    _ = api_dls.DLSLoadMemFile(hm, scp, ru);
    _ = api_dls.DLSMSSGetCPU(hm);
    _ = api_dls.DLSMSSOpen(hm, hd, null, ru, ru, ri, ri); // (mdi, dig, libname, flags, rate, bits, channels)
    api_dls.DLSSetAttribute(hm, rstr, scp);
    _ = api_digital.DllMain(scp, ru, null);
    _ = api_v7.RIB_MAIN(null, rstr);
    _ = api_rib.RIB_alloc_provider_handle(scp);
    _ = api_rib.RIB_enumerate_providers(rstr, &pp, &prov);
    _ = api_rib.RIB_error();
    _ = api_rib.RIB_find_file_dec_provider(rstr, rstr, rstr, rstr, rstr);
    _ = api_rib.RIB_find_file_provider(rstr, rstr, rstr);
    _ = api_rib.RIB_find_files_provider(rstr, rstr, rstr, rstr, rstr);
    _ = api_rib.RIB_find_provider(rstr, rstr, rstr);
    _ = api_rib.RIB_load_application_providers(rstr);
    _ = api_rib.RIB_load_provider_library(rstr);
    _ = api_v7.RIB_load_static_provider_library(null, rstr);
    _ = api_rib.RIB_provider_library_handle();
    _ = api_rib.RIB_provider_system_data(prov, ru);
    _ = api_rib.RIB_provider_user_data(prov, ru);
    api_rib.RIB_register_interface(prov, rstr, rszi, scp);
    _ = api_rib.RIB_request_interface(prov, rstr, rszi, scp);
    _ = api_rib.RIB_request_interface_entry(prov, rstr, ru, rstr, &zo);
    api_rib.RIB_set_provider_system_data(prov, ru, rz);
    api_rib.RIB_set_provider_user_data(prov, ru, rz);
    { var tsv: i32 = ri; _ = api_rib.RIB_type_string(&tsv, ru); }
    api_rib.RIB_unregister_interface(prov, rstr, rszi, scp);
    // Input validators that load/parse caller-supplied buffers. Buffer lengths
    // are bounded to the real scratch (rsz <= 256, well inside g_scratch's
    // 64 KiB) so any out-of-bounds read/write is a genuine library bug, not a
    // harness contract violation. Filenames resolve to "" (scratch starts
    // zeroed), so the file writers just fail to open rather than touching disk.
    var pfo: ?*f32 = null;
    var pco: ?*const anyopaque = null;
    _ = api_digital.AIL_set_sample_file(hs, scp, ri);
    api_digital.AIL_set_sample_address(hs, scp, rsz);
    api_v7.AIL_set_sample_info(hs, &info);
    _ = api_digital.AIL_set_named_sample_file(hs, rstr, scp, rszi, ru);
    _ = api_3d.AIL_set_3D_sample_file(@as(?*anyopaque, @ptrCast(h3)), scp);
    _ = api_3d.AIL_set_3D_sample_info(@as(?*anyopaque, @ptrCast(h3)), @as(?*anyopaque, &info));
    api_digital.AIL_load_sample_buffer(hs, ru, scp, rsz);
    _ = api_digital.AIL_size_processed_digital_audio(ru, ru, rszi, &info);
    _ = api_digital.AIL_process_digital_audio(scp, rszi, ru, ru, rszi, scp);
    _ = api_dls.AIL_DLS_get_info(hm, scp, scp);
    {
        var ds_out: ?*anyopaque = null;
        var dsb_out: ?*anyopaque = null;
        api_digital.AIL_get_DirectSound_info(hs, &ds_out, &dsb_out);
    }
    api_v7.AIL_speaker_reverb_levels(hd, &pfo, &pfo, &pco);
    _ = api_file.AIL_file_read(rstr, scp);
    _ = api_file.AIL_file_write(rstr, scp, rsz);
    _ = api_digital.AIL_WAV_file_write(rstr, scp, rsz, ri, ri);
    _ = api_midi.AIL_MIDI_to_XMI(scp, rsz, null, &uo, ru);
    // More memory parsers fed adversarial (zeroed-prefix) buffers.
    if (api_quick.AIL_quick_load_mem(scp, rsz)) |qs| qs.deinit();
    api_digital.AIL_init_sample(hs);
    _ = api_midi.AIL_init_sequence(hq, scp, ri);
    _ = api_dls.DLSGetInfo(hm, scp, scp);
    _ = api_dls.DLSLoadMemFile(hm, scp, ru);
    var rib_entry: openmiles.RIB_INTERFACE_ENTRY = undefined;
    _ = api_rib.RIB_enumerate_interface(prov, rstr, ru, &pp, &rib_entry);
    // stdcall RIB variants (the v8.0j+/v9 decorated exports) — same logic,
    // distinct symbols, so they must be exercised too.
    _ = api_rib.RIB_alloc_provider_handle_std(scp);
    _ = api_rib.RIB_error_std();
    _ = api_rib.RIB_find_file_provider_std(rstr, rstr, rstr);
    _ = api_rib.RIB_load_provider_library_std(rstr);
    api_rib.RIB_free_provider_handle_std(prov);
    api_rib.RIB_free_provider_library_std(prov);
    api_rib.RIB_register_interface_std(prov, rstr, rszi, scp);
    _ = api_rib.RIB_request_interface_std(prov, rstr, rszi, scp);
    _ = api_rib.RIB_request_interface_entry_std(prov, rstr, ru, rstr, &zo);
    _ = api_rib.RIB_enumerate_interface_std(prov, rstr, ru, &pp, &rib_entry);
    { var tsv2: i32 = ri; _ = api_rib.RIB_type_string_std(&tsv2, ru); }
    api_rib.RIB_unregister_interface_std(prov, rstr, rszi, scp);
    // --- functions added this session (v8/v9 subsystems) ---
    const h3a: ?*anyopaque = @ptrCast(h3);
    api_3d.AIL_3D_update_position(h3a, rf);
    api_3d.AIL_3D_auto_update_position(h3a, ri);
    api_v9.AIL_set_sample_id(hs, ri);
    _ = api_v9.AIL_sample_id(hs);
    api_v9.AIL_set_sample_bus(hs, ri);
    _ = api_v9.AIL_sample_bus(hs);
    api_v9.AIL_set_sample_level_mask(hs, @truncate(ru));
    _ = api_v9.AIL_sample_level_mask(hs);
    api_v9.AIL_set_sample_3D_spread(hs, rf);
    api_v9.AIL_set_sample_3D_volume_falloff(hs, scp, rszi);
    api_v9.AIL_set_sample_3D_exclusion_falloff(hs, scp, rszi);
    api_v9.AIL_set_sample_3D_lowpass_falloff(hs, scp, rszi);
    api_v9.AIL_set_sample_3D_spread_falloff(hs, scp, rszi);
    api_v9.AIL_set_sample_3D_position_segments(hs, scp, rszi);
    _ = api_v9.AIL_digital_mixed_samples(hd);
    _ = api_v9.AIL_register_mix_callback(hd, null);
    api_v9.AIL_end_fade_sample(hs);
    _ = api_v9.AIL_sample_mixed_ms(hs);
    _ = api_v9.AIL_sample_schedule_time(hs);
    api_v9.AIL_schedule_start_sample(hs, ru64);
    _ = api_v9.AIL_set_sample_loop_samples(hs, ri, ri);
    api_v9.AIL_push_system_state(hd, ru, ri);
    api_v9.AIL_pop_system_state(hd, ri);
    _ = api_v9.AIL_system_state_level(hd);
    api_v9.AIL_set_async_callbacks(null, null, null, null, null, null, null);
    api_v9.AIL_start_sample_group(hd, ri, ri);
    api_v9.AIL_stop_sample_group(hd, ri, ri);
    api_v9.AIL_resume_sample_group(hd, ri, ri);
    api_v9.AIL_end_sample_group(hd, ri);
    // bus mixer (alloc + exercise + free so it stays bounded)
    _ = api_v9.AIL_allocate_bus(hd);
    _ = api_v9.AIL_bus_sample_handle(hd, ri);
    api_v9.AIL_enable_limiter(hd, ri);
    api_v9.AIL_bus_enable_limiter(hd, ri, ri);
    _ = api_v9.AIL_install_bus_compressor(hd, ri, ri, ri);
    api_v9.AIL_free_all_busses(hd);
    // event command queue
    _ = api_v9.AIL_enqueue_event_start();
    api_v9.AIL_enqueue_event_cancel(ri);
    _ = api_v9.AIL_enqueue_event_context(&io, scp);
    _ = api_v9.AIL_enqueue_event_end_named(ri, scp);
    _ = api_v9.AIL_enqueue_event_selection(&io, ru);
    _ = api_v9.AIL_enqueue_event_filter(&io, ru64);
    _ = api_v9.AIL_enqueue_event_variablef(&io, scp, rf);
    _ = api_v9.AIL_enqueue_event_buffer(&io, scp, ri, ri);
    _ = api_v9.AIL_enqueue_event_position(&io, rf, rf, rf);
    _ = api_v9.AIL_enqueue_event_velocity(&io, rf, rf, rf, rf);
    _ = api_v9.AIL_event_system_command_queue_remaining();
    api_v9.AIL_set_event_settings(ri);
    api_v9.AIL_set_event_sample_functions(null, null);
    _ = api_digital.AIL_get_DirectSound3D_info(scp, scp, scp, ru);
    _ = api_digital.AIL_set_direct_buffer_control(hs, ru);
    api_midi.AIL_midiOutClose(scp);
    if (api_quick.AIL_quick_copy(hs)) |qc| qc.deinit();
    if (api_digital.AIL_allocate_file_sample(hd, scp, rsz)) |fsamp| fsamp.deinit();
    if (api_v8.AIL_mem_create()) |m| api_v8.AIL_mem_close(m, null, null);
    api_memory.AIL_mem_use_free(null);
    // allocate/release lifecycle on throwaway handles (exercises C-ABI wrappers
    // without tearing down the shared hd/hm/hs handles the loop reuses)
    if (api_digital.AIL_allocate_sample_handle(hd)) |ts| api_digital.AIL_release_sample_handle(ts);
    if (api_3d.AIL_allocate_3D_sample_handle(hd)) |t3| api_3d.AIL_release_3D_sample_handle(t3);
    if (api_midi.AIL_allocate_sequence_handle(hm)) |tq| {
        api_midi.AIL_release_channel(hm, ri); // release_channel takes the MIDI driver
        api_midi.AIL_release_sequence_handle(tq);
    }
    if (api_memory.AIL_mem_alloc_lock(rsz)) |lk| api_memory.AIL_mem_free_lock(lk);
    // quick load with adversarial filename (-> null) and unload of null/handle
    if (api_quick.AIL_quick_load(rstr)) |qs| api_quick.AIL_quick_unload(qs);
    if (api_quick.AIL_quick_load_and_play(rstr, ri, ri)) |qs| api_quick.AIL_quick_unload(qs);
    api_quick.AIL_quick_unload(null);
    // filter subsystem (open -> attribute -> attach -> enumerate -> close)
    if (api_filter.AIL_open_filter(openmiles.startup_provider, hd)) |filt| {
        var fval: f32 = rf;
        api_filter.AIL_filter_attribute(filt, rstr, &fval);
        api_filter.AIL_set_filter_attribute(filt, rstr, &fval);
        api_filter.AIL_set_filter_preference(filt, rstr, &fval);
        api_filter.AIL_set_sample_filter(hs, filt, ri);
        var fnext: ?*anyopaque = null;
        var fname: [*:0]const u8 = undefined;
        _ = api_filter.AIL_enumerate_filter_attributes(filt, &fnext, &fname);
        fnext = null;
        _ = api_filter.AIL_enumerate_filter_sample_attributes(filt, &fnext, &fname);
        api_filter.AIL_close_filter(filt); // deinit nulls hs.attached_filter
    }
    // stream subsystem (adversarial filename exercises the parse/open path)
    if (api_stream.AIL_open_stream(hd, rstr, ri)) |st| {
        api_digital.AIL_start_sample_at(st, ru);
        api_stream.AIL_close_stream(st);
    }
    if (api_stream.AIL_open_stream_ex(hd, rstr, ri, ri)) |st| api_stream.AIL_close_stream(st);
    if (api_stream.AIL_open_stream_by_sample(hd, hs, scp, ri)) |st| api_stream.AIL_close_stream(st);
    api_digital.AIL_start_sample_at(hs, ru);
    // input device open/close
    if (api_input.AIL_open_input(scp)) |inp| api_input.AIL_close_input(inp);
    if (api_input.AIL_input_open(scp, rz, rz)) |inp| api_input.AIL_close_input(inp);
    // v4/v5 wide-ABI distance variants
    api_3d.AIL_set_3D_sample_distances_v4(@ptrCast(h3), rf, rf, rf, rf);
    api_3d.AIL_set_3D_sample_float_distances_v5(@ptrCast(h3), rf, rf, rf, rf);
    {
        var d0: f32 = 0;
        var d1: f32 = 0;
        var d2: f32 = 0;
        var d3: f32 = 0;
        api_3d.AIL_3D_sample_distances_v4(h3, &d0, &d1, &d2, &d3);
        api_3d.AIL_3D_sample_float_distances_v5(h3, &d0, &d1, &d2, &d3);
    }
    // 3D provider/listener/object open-close cycle
    _ = api_3d.AIL_open_3D_provider(null);
    _ = api_3d.AIL_open_3D_provider(scp);
    api_3d.AIL_close_3D_provider(scp);
    if (api_3d.AIL_open_3D_listener(hd)) |lis| api_3d.AIL_close_3D_listener(lis);
    if (api_3d.AIL_open_3D_object(hd)) |o3| api_3d.AIL_close_3D_object(o3);
    {
        var lvl: f32 = 0;
        _ = api_v7.AIL_calculate_3D_channel_levels_v7(hd, &lvl, scp, scp, scp, scp, rf, rf, rf, rf, rf, scp, scp, rf);
    }
    // Win16-legacy handle release/reacquire are no-ops; safe on shared handles
    _ = api_digital.AIL_digital_handle_release(hd);
    api_midi.AIL_MIDI_handle_release(@ptrCast(hm));
    api_dls.DLSUnloadAll(hm);
    _ = api_digital.AIL_init_sample_v8(hs, ri);
    {
        var p0: u32 = 0;
        var l0: u32 = 0;
        var p1: u32 = 0;
        var l1: u32 = 0;
        api_digital.AIL_sample_buffer_info_old(hs, &p0, &l0, &p1, &l1);
    }
    {
        var dptr: ?*openmiles.DigitalDriver = null;
        var mptr: ?*openmiles.MidiDriver = null;
        api_quick.AIL_quick_handles_v3(&dptr, &mptr);
    }
    // null-branch coverage for teardown exports that free their argument
    api_digital.AIL_waveOutClose(null);
    api_redbook.AIL_redbook_close(null);
    api_midi.AIL_close_XMIDI_driver(null);
    api_v8.AIL_close_soundbank(null);
    api_rib.AIL_close_ASI_provider(null);
    api_rib.RIB_free_provider_handle(null);
    api_rib.RIB_free_provider_library(null);
    // wave synthesizer + DLS open with garbage SF2 image (exercises parse path)
    if (api_digital.AIL_create_wave_synthesizer(hd, hm, scp, ri)) |ws| api_digital.AIL_destroy_wave_synthesizer(ws); // (dig, mdi, wave_lib, polyphony)
    if (api_dls.AIL_DLS_open(hm, hd, null, ru, ru, ri, ri)) |dh| api_dls.AIL_DLS_close(dh, ru); // (mdi, dig, libname, ...)
    // event constructor + steps + decode
    if (api_v8.AIL_create_event()) |evh| {
        _ = api_v8.AIL_add_comment_event_step(evh, rstr);
        _ = api_v9.AIL_add_clear_state_event_step(evh);
        _ = api_v9.AIL_add_exec_event_event_step(evh, rstr);
        _ = api_v9.AIL_add_ramp_event_step(evh, scp, scp, rf, scp, ri, ri, ri);
        _ = api_v9.AIL_add_setblend_event_step(evh, scp, ri, scp, scp, scp, scp, scp, scp);
        _ = api_v9.AIL_add_set_lfo_event_step(evh, scp, scp, scp, scp, ri, ri, ri, ri, ri);
        _ = api_v9.AIL_add_move_var_event_step(evh, scp, scp, scp, scp);
        _ = api_v9.AIL_add_enable_limit_event_step(evh, scp);
        _ = api_v8.AIL_add_cache_sounds_event_step(evh, scp, scp);
        _ = api_v8.AIL_add_uncache_sounds_event_step(evh, scp, scp);
        _ = api_v8.AIL_add_apply_environment_event_step(evh, scp, ri);
        _ = api_v8.AIL_add_control_sounds_event_step(evh, scp, scp, scp, scp, scp, ri, rf, ri, ri);
        _ = api_v8.AIL_add_persist_preset_event_step(evh, scp, scp, scp, ri);
        _ = api_v8.AIL_add_sound_limit_event_step(evh, scp, scp);
        _ = api_v8.AIL_add_start_sound_event_step(evh, scp, scp, ri, scp, scp, scp, scp, scp, scp, ru, ri, ri, ri, ri, ri, scp, rf, rf, rf, rf, rf, ri, ri);
        if (api_v8.AIL_close_event(evh)) |estr| {
            var stepbuf: [512]u8 align(8) = undefined;
            var sout: ?*openmiles.event.EVENT_STEP_INFO = null;
            var cur: ?*const anyopaque = @ptrCast(estr);
            var guard: u32 = 0;
            while (cur != null and guard < 64) : (guard += 1) {
                cur = api_v8.AIL_next_event_step(cur, &sout, &stepbuf, stepbuf.len);
            }
            std.c.free(estr);
        }
    }
    // Decode adversarial (random, non-constructed) event strings: the step parser
    // and the cache/purge namelist split must stay in-bounds on garbage input.
    {
        var ebuf: [600]u8 align(8) = undefined;
        var eout: ?*openmiles.event.EVENT_STEP_INFO = null;
        var ec: ?*const anyopaque = @ptrCast(&g_scratch[256]); // random bytes, NUL-terminated by g_scratch end
        var eg: u32 = 0;
        while (ec != null and eg < 48) : (eg += 1) {
            ec = api_v8.AIL_next_event_step(ec, &eout, &ebuf, ebuf.len);
        }
    }
    // Miles 9.x event system: lifecycle + vars + queue/instance/bank/async surface
    {
        const msys = api_miles.MilesStartupEventSystem(hd, ri, null, ri);
        const msysi: usize = @intFromPtr(msys);
        api_miles.MilesSetVarI(msysi, rstr, ri);
        api_miles.MilesSetVarF(msysi, rstr, rf);
        api_miles.MilesSetVarI(0, rstr, ri);
        api_miles.MilesSetVarF(0, rstr, rf);
        var mvi: i32 = 0;
        var mvf: f32 = 0;
        _ = api_miles.MilesGetVarI(msysi, rstr, &mvi);
        _ = api_miles.MilesGetVarF(0, rstr, &mvf);
        _ = api_miles.MilesAddEventSystem(hd);
        var mstate: api_miles.MILESEVENTSTATE = undefined;
        api_miles.MilesGetEventSystemState(msys, &mstate);
        _ = api_miles.MilesEnqueueEvent(null, scp, ri, ri, ru64);
        _ = api_miles.MilesEnqueueEventContext(msys, null, scp, ri, ri, ru64);
        _ = api_miles.MilesEnqueueEventByName(rstr);
        _ = api_miles.MilesBeginEventQueueProcessing();
        _ = api_miles.MilesCompleteEventQueueProcessing();
        api_miles.MilesClearEventQueue();
        _ = api_miles.MilesStartSoundInstance(scp, rstr, ru, ri, rstr, scp, ri, ri);
        _ = api_miles.MilesStopSoundInstances(rstr, ru64);
        _ = api_miles.MilesPauseSoundInstances(rstr, ru64);
        _ = api_miles.MilesResumeSoundInstances(rstr, ru64);
        var mnext: ?*anyopaque = null;
        _ = api_miles.MilesEnumerateSoundInstances(msys, &mnext, ri, rstr, ru64, scp);
        mnext = null;
        var mname: ?[*:0]const u8 = null;
        _ = api_miles.MilesEnumeratePresetPersists(msys, &mnext, &mname);
        api_miles.MilesSetSoundStartOffset(rz, ri, ri);
        _ = api_miles.MilesSetSoundLabelLimits(msys, rstr);
        _ = api_miles.MilesAddSoundBank(rstr, rstr);
        // ReleaseSoundBank/FindEvent dereference and free the bank handle (the
        // real DLL would too), so they take null here, not a garbage pointer;
        // the live-handle path is covered by main_test soundbank tests.
        _ = api_miles.MilesReleaseSoundBank(null);
        _ = api_miles.MilesFindEvent(null, rstr);
        _ = api_miles.MilesGetEventLength(rstr);
        if (api_miles.MilesTextDumpEventSystem()) |dump| std.c.free(dump);
        api_miles.MilesRegisterRand(scp);
        api_miles.MilesSetEventErrorCallback(scp);
        api_miles.MilesEventSetAuditionFunctions(scp);
        _ = api_miles.MilesGetBankFunctions();
        api_miles.MilesSetBankFunctions(scp);
        api_miles.MilesUseTelemetry(scp);
        api_miles.MilesUseTmLite(scp);
        _ = api_miles.MilesAsyncStartup();
        _ = api_miles.MilesAsyncFileRead(scp);
        _ = api_miles.MilesAsyncFileCancel(scp);
        _ = api_miles.MilesAsyncFileStatus(scp, ru);
        api_miles.MilesAsyncSetPaused(ri);
        api_miles.MilesRequeueAsyncs();
        _ = api_miles.MilesAsyncShutdown();
        // v8-arity Miles variants
        _ = api_miles.MilesStartupEventSystem_v8(hd, ri, null, ri, ri);
        _ = api_miles.MilesAddSoundBank_v8(rstr);
        api_miles.MilesGetEventSystemState_v8(&mstate);
        _ = api_miles.MilesSetSoundLabelLimits_v8(rstr);
        mnext = null;
        _ = api_miles.MilesEnumeratePresetPersists_v8(&mnext, &mname);
        mnext = null;
        _ = api_miles.MilesEnumerateSoundInstances_v8(msys, &mnext, ri, rstr, ru, scp);
        api_miles.MilesShutdownEventSystem();
    }
    // v8-arity AIL/event/misc variants
    api_v8.MSSDisableThreadLibraryCalls(scp);
    _ = api_v8.AIL_find_marker_in_list_v8(ri, scp);
    _ = api_v8.AIL_ftoa_v8(rf);
    _ = api_v8.AIL_open_soundbank_v8(scp);
    api_v8.AIL_register_trace_callback_v8(scp, scp);
    // dereferences+formats the bank handle (real DLL too) -> null, not garbage
    _ = api_v8.AIL_sound_asset_filename_v8(null, scp, scp);
    if (api_v8.AIL_create_event()) |ev8| {
        _ = api_v8.AIL_add_control_sounds_event_step_v8(ev8, scp, scp, scp, scp, scp, ri, rf);
        _ = api_v8.AIL_add_sound_limit_event_step_v8(ev8, scp);
        _ = api_v8.AIL_add_start_sound_event_step_v8(ev8, scp, scp, ri, scp, scp, scp, scp, scp, scp, ru, ri, ri, ri, ri, ri, scp, rf, rf);
        _ = api_v8.AIL_add_apply_environment_event_step_v8(ev8, scp);
        _ = api_v8.AIL_add_persist_preset_event_step_v8(ev8, scp, scp, scp);
        _ = api_v8.AIL_sample_stage_property_v7(scp, ri, scp, ri, scp, scp);
        _ = api_v8.AIL_get_soundbank_filename_v8(scp, scp);
        if (api_v8.AIL_close_event(ev8)) |s8| std.c.free(s8);
    }
    _ = api_rib.MIX_RIB_MAIN(prov, ru, scp, scp, scp);
    if (api_memory.MSS_alloc_info(rsz, rz, rstr, ru)) |mp| api_memory.MSS_free_info(mp, rz, rstr, ru);
        }
    }
}

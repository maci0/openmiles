const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;
const MidiDriver = openmiles.MidiDriver;
const Sequence = openmiles.Sequence;

pub export fn AIL_open_midi_driver(flags: u32) callconv(.winapi) ?*MidiDriver {
    log("AIL_open_midi_driver(flags={d})\n", .{flags});
    return openmiles.openMidiDriver();
}
pub export fn AIL_close_midi_driver(driver_opt: ?*MidiDriver) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    log("AIL_close_midi_driver(driver={*})\n", .{driver});
    openmiles.closeMidiDriver(driver);
}
pub export fn AIL_open_XMIDI_driver(flags: u32) callconv(.winapi) ?*MidiDriver {
    log("AIL_open_XMIDI_driver(flags={d})\n", .{flags});
    return AIL_open_midi_driver(flags);
}
pub export fn AIL_close_XMIDI_driver(driver_opt: ?*MidiDriver) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    log("AIL_close_XMIDI_driver(driver={*})\n", .{driver});
    AIL_close_midi_driver(driver);
}
pub export fn AIL_allocate_sequence_handle(driver_opt: ?*MidiDriver) callconv(.winapi) ?*Sequence {
    const driver = driver_opt orelse return null;
    log("AIL_allocate_sequence_handle(driver={*})\n", .{driver});
    return openmiles.Sequence.init(driver) catch |err| {
        log("Error: {any}\n", .{err});
        openmiles.setLastError("Failed to allocate sequence handle");
        return null;
    };
}
pub export fn AIL_release_sequence_handle(seq_opt: ?*Sequence) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_release_sequence_handle(seq={*})\n", .{seq});
    seq.deinit();
}
pub export fn AIL_init_sequence(seq_opt: ?*Sequence, data: *anyopaque, sequence_num: i32) callconv(.winapi) i32 {
    const seq = seq_opt orelse return 0;
    log("AIL_init_sequence(seq={*}, data={*}, sequence_num={d})\n", .{ seq, data, sequence_num });
    openmiles.clearLastError();
    // The third parameter is the sequence/track index (0-based), NOT the data size.
    const raw: [*]const u8 = @ptrCast(@alignCast(data));
    const midi_len = openmiles.detectMidiSize(raw);
    const midi_data = raw[0..midi_len];
    seq.loadMidi(midi_data, @intCast(@max(0, sequence_num))) catch {
        openmiles.setLastError("Failed to initialize MIDI sequence");
        return 0;
    };
    return 1;
}
pub export fn AIL_start_sequence(seq_opt: ?*Sequence) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_start_sequence(seq={*})\n", .{seq});
    seq.start();
}
pub export fn AIL_stop_sequence(seq_opt: ?*Sequence) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_stop_sequence(seq={*})\n", .{seq});
    seq.stop();
}
pub export fn AIL_pause_sequence(seq_opt: ?*Sequence) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_pause_sequence(seq={*})\n", .{seq});
    seq.pause();
}
pub export fn AIL_resume_sequence(seq_opt: ?*Sequence) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_resume_sequence(seq={*})\n", .{seq});
    seq.resumePlayback();
}
pub export fn AIL_sequence_status(seq_opt: ?*Sequence) callconv(.winapi) u32 {
    const seq = seq_opt orelse return 0;
    return @intFromEnum(seq.status());
}
pub export fn AIL_set_sequence_volume(seq_opt: ?*Sequence, volume: i32, ms: i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_set_sequence_volume(seq={*}, volume={d}, ms={d})\n", .{ seq, volume, ms });
    seq.setVolume(volume, ms);
}
pub export fn AIL_set_sequence_loop_count(seq_opt: ?*Sequence, count: i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_set_sequence_loop_count(seq={*}, count={d})\n", .{ seq, count });
    seq.setLoopCount(count);
}
pub export fn AIL_sequence_ms_position(seq_opt: ?*Sequence, total_ms: ?*i32, current_ms: ?*i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    const pos = seq.getMsPosition();
    if (total_ms) |t| t.* = pos.total;
    if (current_ms) |c| c.* = pos.current;
}
pub export fn AIL_set_sequence_ms_position(seq_opt: ?*Sequence, ms: i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    seq.setMsPosition(ms);
}
pub export fn AIL_sequence_loop_count(seq_opt: ?*Sequence) callconv(.winapi) i32 {
    const seq = seq_opt orelse return 0;
    return seq.loop_count;
}
pub export fn AIL_sequence_volume(seq_opt: ?*Sequence) callconv(.winapi) i32 {
    const seq = seq_opt orelse return 0;
    return seq.getVolume();
}
pub export fn AIL_sequence_tempo(seq_opt: ?*Sequence) callconv(.winapi) i32 {
    const seq = seq_opt orelse return 0;
    return if (seq.user_bpm > 0) seq.user_bpm else seq.tempo;
}
pub export fn AIL_set_sequence_tempo(seq_opt: ?*Sequence, tempo: i32, ms: i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_set_sequence_tempo(seq={*}, tempo={d}, ms={d})\n", .{ seq, tempo, ms });
    seq.startTempoFade(tempo, ms);
}
pub export fn AIL_active_sequence_count(driver: *anyopaque) callconv(.winapi) u32 {
    _ = driver;
    return openmiles.getActiveSequenceCount();
}
pub export fn AIL_sequence_position(seq_opt: ?*Sequence, beat: ?*i32, measure: ?*i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    if (beat) |p| p.* = seq.current_beat_in_measure;
    if (measure) |p| p.* = seq.current_measure;
}
pub export fn AIL_sequence_user_data(seq_opt: ?*Sequence, index: i32) callconv(.winapi) u32 {
    const seq = seq_opt orelse return 0;
    const idx: usize = @intCast(@min(@max(index, 0), 7));
    return seq.user_data[idx];
}
pub export fn AIL_set_sequence_user_data(seq_opt: ?*Sequence, index: i32, value: u32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    const idx: usize = @intCast(@min(@max(index, 0), 7));
    seq.user_data[idx] = value;
}
pub export fn AIL_end_sequence(seq_opt: ?*Sequence) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    seq.stop();
}
pub export fn AIL_true_sequence_channel(seq_opt: ?*Sequence, channel: i32) callconv(.winapi) i32 {
    const seq = seq_opt orelse return channel;
    return seq.getPhysicalChannel(channel);
}
pub export fn AIL_map_sequence_channel(seq_opt: ?*Sequence, channel: i32, new_channel: i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    seq.setChannelMap(channel, new_channel);
}
pub export fn AIL_register_sequence_callback(seq_opt: ?*Sequence, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const seq = seq_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(seq.sequence_callback);
    seq.sequence_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_XMIDI_master_volume(driver_opt: ?*openmiles.MidiDriver) callconv(.winapi) i32 {
    const midi = driver_opt orelse return 0;
    return openmiles.gainToMssVolume(midi.master_volume);
}
pub export fn AIL_set_XMIDI_master_volume(driver_opt: ?*openmiles.MidiDriver, volume: i32) callconv(.winapi) void {
    const midi = driver_opt orelse return;
    midi.master_volume = openmiles.mssVolumeToGain(volume);
    if (midi.soundfont) |sf| {
        openmiles.tsf.tsf_set_volume(sf, midi.master_volume);
    }
}
pub export fn AIL_midiOutClose(driver: *anyopaque) callconv(.winapi) void {
    _ = driver;
}
pub export fn AIL_midiOutOpen(driver: *anyopaque, hmidiout: *anyopaque, device_id: i32) callconv(.winapi) i32 {
    _ = driver;
    _ = hmidiout;
    _ = device_id;
    return 0;
}
pub export fn AIL_MIDI_handle_release(driver: *anyopaque) callconv(.winapi) void {
    _ = driver;
}
pub export fn AIL_MIDI_handle_reacquire(driver: *anyopaque) callconv(.winapi) i32 {
    _ = driver;
    return 1;
}
pub export fn AIL_MIDI_to_XMI(data: *anyopaque, len: u32, out: ?*anyopaque, out_len: *u32, flags: u32) callconv(.winapi) i32 {
    _ = flags;
    // No format conversion needed -- the engine handles both SMF and XMIDI natively.
    // When out is NULL, this is a size query; otherwise copy the data verbatim.
    out_len.* = len;
    if (len == 0) return 0;
    const out_ptr = out orelse return 1; // NULL = size query only
    const src: [*]const u8 = @ptrCast(@alignCast(data));
    const dst: [*]u8 = @ptrCast(@alignCast(out_ptr));
    @memcpy(dst[0..len], src[0..len]);
    return 1;
}
pub export fn AIL_list_MIDI(filename: [*:0]const u8, out_buf: *anyopaque, out_len: u32, flags: u32, callback: ?*anyopaque) callconv(.winapi) i32 {
    _ = filename;
    _ = out_buf;
    _ = out_len;
    _ = flags;
    _ = callback;
    return 0;
}
extern fn openmiles_tsf_channel_note_count(f: ?*openmiles.tsf.tsf, channel: i32) i32;
pub export fn AIL_channel_notes(seq_opt: ?*Sequence, channel: i32) callconv(.winapi) i32 {
    const seq = seq_opt orelse return 0;
    const sf = seq.driver.soundfont orelse return 0;
    return openmiles_tsf_channel_note_count(sf, channel);
}
pub export fn AIL_controller_value(seq_opt: ?*Sequence, channel: i32, controller: i32) callconv(.winapi) i32 {
    const seq = seq_opt orelse return 0;
    const sf = seq.driver.soundfont orelse return 0;
    const tsf_mod = openmiles.tsf;
    switch (controller) {
        0 => return tsf_mod.tsf_channel_get_preset_bank(sf, channel),
        7, 11 => {
            const v = tsf_mod.tsf_channel_get_volume(sf, channel);
            return @intFromFloat(v * 127.0);
        },
        10 => {
            const p = tsf_mod.tsf_channel_get_pan(sf, channel);
            return @min(127, @max(0, @as(i32, @intFromFloat((p + 1.0) * 64.0))));
        },
        else => return 0,
    }
}
pub export fn AIL_send_channel_voice_message(seq_opt: ?*Sequence, status: i32, d1: i32, d2: i32, time: i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    _ = time;
    if (seq.driver.soundfont == null) return;
    const sf = seq.driver.soundfont.?;
    const tsf_mod = openmiles.tsf;
    const msg_type = status & 0xF0;
    const channel = status & 0x0F;
    switch (msg_type) {
        0x80 => tsf_mod.tsf_channel_note_off(sf, channel, d1),
        0x90 => if (d2 > 0) {
            _ = tsf_mod.tsf_channel_note_on(sf, channel, d1, @as(f32, @floatFromInt(d2)) / 127.0);
        } else {
            tsf_mod.tsf_channel_note_off(sf, channel, d1);
        },
        0xB0 => {
            _ = tsf_mod.tsf_channel_midi_control(sf, channel, d1, d2);
        },
        0xC0 => {
            _ = tsf_mod.tsf_channel_set_presetnumber(sf, channel, d1, if (channel == 9) 1 else 0);
        },
        0xE0 => {
            const bend = (d2 << 7) | d1;
            _ = tsf_mod.tsf_channel_set_pitchwheel(sf, channel, bend);
        },
        0xA0 => {},
        else => {},
    }
}
pub export fn AIL_send_sysex_message(seq_opt: ?*Sequence, data: *anyopaque) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    const sf = seq.driver.soundfont orelse return;
    const bytes: [*]const u8 = @ptrCast(data);
    if (bytes[0] != 0xF0) return;
    var body_len: usize = 0;
    var i: usize = 1;
    while (i < 512) : (i += 1) {
        if (bytes[i] == 0xF7) break;
        body_len = i;
    }
    if (body_len == 0) return;
    const body = bytes[1 .. body_len + 1];
    const is_gm = body.len >= 4 and body[0] == 0x7E and body[1] == 0x7F and
        body[2] == 0x09 and body[3] == 0x01;
    const is_gs = body.len >= 8 and body[0] == 0x41 and body[2] == 0x42 and
        body[3] == 0x12 and body[4] == 0x40 and body[5] == 0x00 and
        body[6] == 0x7F and body[7] == 0x00;
    const is_xg = body.len >= 6 and body[0] == 0x43 and body[2] == 0x4C and
        body[3] == 0x00 and body[4] == 0x00 and body[5] == 0x7E;
    if (is_gm or is_gs or is_xg) {
        log("AIL_send_sysex_message: recognized GM/GS/XG reset — resetting all channels\n", .{});
        var ch: i32 = 0;
        while (ch < 16) : (ch += 1) {
            _ = openmiles.tsf.tsf_channel_midi_control(sf, ch, 123, 0);
            _ = openmiles.tsf.tsf_channel_midi_control(sf, ch, 121, 0);
            _ = openmiles.tsf.tsf_channel_midi_control(sf, ch, 7, 100);
            _ = openmiles.tsf.tsf_channel_midi_control(sf, ch, 10, 64);
        }
    }
}
pub export fn AIL_lock_channel(seq_opt: ?*Sequence) callconv(.winapi) i32 {
    const seq = seq_opt orelse return -1;
    return openmiles.lockChannel(seq);
}
pub export fn AIL_release_channel(seq_opt: ?*Sequence, channel: i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    openmiles.releaseChannel(seq, channel);
}
pub export fn AIL_register_beat_callback(seq_opt: ?*Sequence, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const seq = seq_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(seq.beat_callback);
    seq.beat_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_register_event_callback(seq_opt: ?*Sequence, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const seq = seq_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(seq.event_callback);
    seq.event_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_register_prefix_callback(seq_opt: ?*Sequence, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const seq = seq_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(seq.prefix_callback);
    seq.prefix_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_register_trigger_callback(seq_opt: ?*Sequence, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const seq = seq_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(seq.trigger_callback);
    seq.trigger_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_register_timbre_callback(seq_opt: ?*Sequence, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const seq = seq_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(seq.timbre_callback);
    seq.timbre_callback = if (callback) |cb| @intFromPtr(cb) else 0;
    return prev;
}
pub export fn AIL_branch_index(seq_opt: ?*Sequence, marker: u32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_branch_index(seq={*}, marker={d})\n", .{ seq, marker });
    seq.branchIndex(marker);
}
pub export fn AIL_register_ICA_array(seq_opt: ?*Sequence, arr: *anyopaque) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    const sf = seq.driver.soundfont orelse return;
    const data: [*]const u8 = @ptrCast(arr);
    var ch: i32 = 0;
    while (ch < 16) : (ch += 1) {
        var cc: i32 = 0;
        while (cc < 128) : (cc += 1) {
            const val = data[@intCast(ch * 128 + cc)];
            if (val != 0) {
                _ = openmiles.tsf.tsf_channel_midi_control(sf, seq.getPhysicalChannel(ch), cc, val);
            }
        }
    }
}

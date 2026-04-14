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
    // Detect MIDI data size from the MIDI file header.
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
    // Return user-set BPM if one has been set, otherwise return the file's current BPM.
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
pub export fn AIL_XMIDI_master_volume(driver: *anyopaque) callconv(.winapi) i32 {
    const midi: *openmiles.MidiDriver = @ptrCast(@alignCast(driver));
    return openmiles.gainToMssVolume(midi.master_volume);
}
pub export fn AIL_set_XMIDI_master_volume(driver: *anyopaque, volume: i32) callconv(.winapi) void {
    const midi: *openmiles.MidiDriver = @ptrCast(@alignCast(driver));
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
    // No actual conversion: the engine handles both SMF and XMIDI natively,
    // so we just copy the buffer as-is.
    // MSS spec: if out == NULL, just set *out_len to required buffer size and return 1.
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

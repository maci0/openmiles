const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;
const MidiDriver = openmiles.MidiDriver;
const Sequence = openmiles.Sequence;

pub fn AIL_open_midi_driver(flags: u32) callconv(.winapi) ?*MidiDriver {
    log("AIL_open_midi_driver(flags={d})\n", .{flags});
    return openmiles.openMidiDriver();
}
pub fn AIL_close_midi_driver(driver_opt: ?*MidiDriver) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    log("AIL_close_midi_driver(driver={*})\n", .{driver});
    openmiles.closeMidiDriver(driver);
}
pub fn AIL_open_XMIDI_driver(flags: u32) callconv(.winapi) ?*MidiDriver {
    log("AIL_open_XMIDI_driver(flags={d})\n", .{flags});
    return AIL_open_midi_driver(flags);
}
pub fn AIL_close_XMIDI_driver(driver_opt: ?*MidiDriver) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    log("AIL_close_XMIDI_driver(driver={*})\n", .{driver});
    AIL_close_midi_driver(driver);
}
pub fn AIL_allocate_sequence_handle(driver_opt: ?*MidiDriver) callconv(.winapi) ?*Sequence {
    const driver = driver_opt orelse return null;
    log("AIL_allocate_sequence_handle(driver={*})\n", .{driver});
    return openmiles.Sequence.init(driver) catch |err| {
        log("Error: {any}\n", .{err});
        openmiles.setLastError("Failed to allocate sequence handle");
        return null;
    };
}
pub fn AIL_release_sequence_handle(seq_opt: ?*Sequence) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_release_sequence_handle(seq={*})\n", .{seq});
    seq.deinit();
}
pub fn AIL_init_sequence(seq_opt: ?*Sequence, data: *anyopaque, sequence_num: i32) callconv(.winapi) i32 {
    const seq = seq_opt orelse return 0;
    log("AIL_init_sequence(seq={*}, data={*}, sequence_num={d})\n", .{ seq, data, sequence_num });
    openmiles.clearLastError();
    // The third parameter is the sequence/track index (0-based), NOT the data size.
    const raw: [*]const u8 = @ptrCast(@alignCast(data));
    const midi_len = openmiles.detectMidiSize(raw);
    // The detector returns the streaming sentinel when it cannot establish a
    // real length: an image that is neither FORM nor MThd, or an MThd whose
    // declared track extents exceed the sentinel budget. The sentinel is a
    // "length unknown" marker, not a length, and slicing the caller's bare
    // pointer with it reads far past the game's allocation. Refuse instead, as
    // MSS does for data it cannot identify as MIDI.
    if (midi_len == 0 or midi_len == openmiles.streaming_sentinel_size) {
        log("AIL_init_sequence: no usable MIDI length (detected {d})\n", .{midi_len});
        openmiles.setLastError("Unrecognized MIDI data");
        return 0;
    }
    const midi_data = raw[0..midi_len];
    seq.loadMidi(midi_data, @intCast(@max(0, sequence_num))) catch |err| {
        log("AIL_init_sequence: loadMidi(track {d}, {d} bytes) failed ({any})\n", .{ sequence_num, midi_len, err });
        openmiles.setLastError("Failed to initialize MIDI sequence");
        return 0;
    };
    return 1;
}
pub fn AIL_start_sequence(seq_opt: ?*Sequence) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_start_sequence(seq={*})\n", .{seq});
    seq.start();
}
pub fn AIL_stop_sequence(seq_opt: ?*Sequence) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_stop_sequence(seq={*})\n", .{seq});
    seq.stop();
}
pub fn AIL_pause_sequence(seq_opt: ?*Sequence) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_pause_sequence(seq={*})\n", .{seq});
    seq.pause();
}
pub fn AIL_resume_sequence(seq_opt: ?*Sequence) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_resume_sequence(seq={*})\n", .{seq});
    seq.resumePlayback();
}
pub fn AIL_sequence_status(seq_opt: ?*Sequence) callconv(.winapi) u32 {
    const seq = seq_opt orelse return 0;
    return @intFromEnum(seq.status());
}
pub fn AIL_set_sequence_volume(seq_opt: ?*Sequence, volume: i32, ms: i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_set_sequence_volume(seq={*}, volume={d}, ms={d})\n", .{ seq, volume, ms });
    seq.setVolume(volume, ms);
}
pub fn AIL_set_sequence_loop_count(seq_opt: ?*Sequence, count: i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_set_sequence_loop_count(seq={*}, count={d})\n", .{ seq, count });
    seq.setLoopCount(count);
}
pub fn AIL_sequence_ms_position(seq_opt: ?*Sequence, total_ms: ?*i32, current_ms: ?*i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    const pos = seq.getMsPosition();
    if (total_ms) |t| t.* = pos.total;
    if (current_ms) |c| c.* = pos.current;
}
pub fn AIL_set_sequence_ms_position(seq_opt: ?*Sequence, ms: i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    seq.setMsPosition(ms);
}
pub fn AIL_sequence_loop_count(seq_opt: ?*Sequence) callconv(.winapi) i32 {
    const seq = seq_opt orelse return 0;
    return seq.loop_count;
}
pub fn AIL_sequence_volume(seq_opt: ?*Sequence) callconv(.winapi) i32 {
    const seq = seq_opt orelse return 0;
    return seq.getVolume();
}
pub fn AIL_sequence_tempo(seq_opt: ?*Sequence) callconv(.winapi) i32 {
    const seq = seq_opt orelse return 0;
    return if (seq.user_bpm > 0) seq.user_bpm else seq.tempo;
}
pub fn AIL_set_sequence_tempo(seq_opt: ?*Sequence, tempo: i32, ms: i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_set_sequence_tempo(seq={*}, tempo={d}, ms={d})\n", .{ seq, tempo, ms });
    seq.startTempoFade(tempo, ms);
}
pub fn AIL_active_sequence_count(driver: *anyopaque) callconv(.winapi) u32 {
    _ = driver;
    return openmiles.getActiveSequenceCount();
}
pub fn AIL_sequence_position(seq_opt: ?*Sequence, beat: ?*i32, measure: ?*i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    if (beat) |p| p.* = seq.current_beat_in_measure.load(.acquire);
    if (measure) |p| p.* = seq.current_measure.load(.acquire);
}
pub fn AIL_sequence_user_data(seq_opt: ?*Sequence, index: i32) callconv(.winapi) u32 {
    const seq = seq_opt orelse return 0;

    return seq.getUserData(@intCast(@min(@max(index, 0), 7)));
}
pub fn AIL_set_sequence_user_data(seq_opt: ?*Sequence, index: i32, value: u32) callconv(.winapi) void {
    const seq = seq_opt orelse return;

    seq.setUserData(@intCast(@min(@max(index, 0), 7)), value);
}
pub fn AIL_end_sequence(seq_opt: ?*Sequence) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    seq.stop();
}
pub fn AIL_true_sequence_channel(seq_opt: ?*Sequence, channel: i32) callconv(.winapi) i32 {
    const seq = seq_opt orelse return channel;
    return seq.getPhysicalChannel(channel);
}
pub fn AIL_map_sequence_channel(seq_opt: ?*Sequence, channel: i32, new_channel: i32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    seq.setChannelMap(channel, new_channel);
}
pub fn AIL_register_sequence_callback(seq_opt: ?*Sequence, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const seq = seq_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(seq.sequence_callback.load(.acquire));
    seq.sequence_callback.store(if (callback) |cb| @intFromPtr(cb) else 0, .release);
    return prev;
}
pub fn AIL_XMIDI_master_volume(driver_opt: ?*openmiles.MidiDriver) callconv(.winapi) i32 {
    const midi = driver_opt orelse return 0;
    return openmiles.gainToMssVolume(midi.master_volume);
}
pub fn AIL_set_XMIDI_master_volume(driver_opt: ?*openmiles.MidiDriver, volume: i32) callconv(.winapi) void {
    const midi = driver_opt orelse return;
    midi.master_volume = openmiles.mssVolumeToGain(volume);
    if (midi.soundfont) |sf| {
        openmiles.tsf.tsf_set_volume(sf, midi.master_volume);
    }
}
pub fn AIL_midiOutClose(driver: *anyopaque) callconv(.winapi) void {
    _ = driver;
}
pub fn AIL_midiOutOpen(driver: *anyopaque, hmidiout: **anyopaque, device_id: i32) callconv(.winapi) i32 {
    _ = device_id;
    hmidiout.* = driver;
    return 0;
}
pub fn AIL_MIDI_handle_release(driver: *anyopaque) callconv(.winapi) i32 {
    // SDK returns S32. We hold no exclusive OS MIDI handle, so releasing it
    // always "succeeds" (1) — consistent with AIL_MIDI_handle_reacquire.
    _ = driver;
    return 1;
}
pub fn AIL_MIDI_handle_reacquire(driver: *anyopaque) callconv(.winapi) i32 {
    _ = driver;
    return 1;
}
// S32 AIL_MIDI_to_XMI(void const* MIDI, U32 MIDI_size, void** XMIDI, U32* XMIDI_size, S32 flags)
// XMIDI is void** — the function ALLOCATES the output and returns its pointer
// through *XMIDI (the caller frees it via AIL_mem_free_lock). We previously
// treated it as a pre-allocated void* buffer and memcpy'd into it, which
// overran the caller's 4-byte pointer variable.
pub fn AIL_MIDI_to_XMI(midi: *anyopaque, midi_size: u32, xmidi: ?*?*anyopaque, xmidi_size: ?*u32, flags: u32) callconv(.winapi) i32 {
    _ = flags;
    // The engine reads SMF and XMIDI natively, so "convert" = copy verbatim into
    // a freshly-allocated buffer whose pointer is returned via *xmidi.
    if (xmidi_size) |p| p.* = midi_size;
    const xp = xmidi orelse return if (midi_size != 0) 1 else 0; // null output = size query
    if (midi_size == 0) {
        xp.* = null;
        return 0;
    }
    const buf: [*]u8 = @ptrCast(std.c.malloc(midi_size) orelse {
        xp.* = null;
        return 0;
    });
    const src: [*]const u8 = @ptrCast(@alignCast(midi));
    @memcpy(buf[0..midi_size], src[0..midi_size]);
    xp.* = @ptrCast(buf);
    return 1;
}
/// AIL_list_MIDI(MIDI, MIDI_size, lst, lst_size, flags)
/// Build a human-readable summary of an SMF or XMIDI image (format, track/
/// sequence count, division). Output text is C-allocated; free with
/// AIL_mem_free_lock. Returns 1 on success.
pub fn AIL_list_MIDI(midi: ?*const anyopaque, midi_size: u32, lst: ?*?*anyopaque, lst_size: ?*u32, flags: i32) callconv(.winapi) i32 {
    _ = flags;
    if (lst) |pp| pp.* = null;
    if (lst_size) |p| p.* = 0;
    const mp = midi orelse return 0;
    const raw: [*]const u8 = @ptrCast(mp);
    // The MThd reads below span bytes 0..14, so a 12- or 13-byte image would
    // read past the caller's buffer.
    if (midi_size < 14) return 0;
    const data = raw[0..@as(usize, midi_size)];

    var text: [:0]u8 = undefined;
    if (std.mem.eql(u8, data[0..4], "MThd")) {
        const format = std.mem.readInt(u16, data[8..10], .big);
        const tracks = std.mem.readInt(u16, data[10..12], .big);
        const division = std.mem.readInt(u16, data[12..14], .big);
        text = std.fmt.allocPrintSentinel(openmiles.global_allocator, "Standard MIDI File\nFormat: {d}\nTracks: {d}\nDivision: {d} ticks/quarter\n", .{ format, tracks, division }, 0) catch {
            openmiles.setLastError("AIL_list_MIDI: cannot format the listing");
            return 0;
        };
    } else if (std.mem.eql(u8, data[0..4], "FORM")) {
        text = std.fmt.allocPrintSentinel(openmiles.global_allocator, "XMIDI sequence\nSize: {d} bytes\n", .{midi_size}, 0) catch {
            openmiles.setLastError("AIL_list_MIDI: cannot format the listing");
            return 0;
        };
    } else {
        openmiles.setLastError("AIL_list_MIDI: unrecognized MIDI image");
        return 0;
    }
    defer openmiles.global_allocator.free(text);

    // C-allocated only when there is an out-pointer to receive the listing: a
    // copy made for a caller that passed none could be freed by no one.
    if (lst) |pp| {
        const p = std.c.malloc(text.len + 1) orelse {
            openmiles.setLastError("AIL_list_MIDI: cannot allocate the listing");
            return 0;
        };
        const dst: [*]u8 = @ptrCast(p);
        @memcpy(dst[0 .. text.len + 1], text[0 .. text.len + 1]); // include NUL
        pp.* = p;
    }
    if (lst_size) |pp| pp.* = @intCast(text.len);
    return 1;
}
extern fn openmiles_tsf_channel_note_count(f: ?*openmiles.tsf.tsf, channel: i32) i32;
pub fn AIL_channel_notes(seq_opt: ?*Sequence, channel: i32) callconv(.winapi) i32 {
    const seq = seq_opt orelse return 0;
    const sf = seq.driver.soundfont orelse return 0;
    return openmiles_tsf_channel_note_count(sf, channel);
}
pub fn AIL_controller_value(seq_opt: ?*Sequence, channel: i32, controller: i32) callconv(.winapi) i32 {
    const seq = seq_opt orelse return 0;
    const sf = seq.driver.soundfont orelse return 0;
    const tsf_mod = openmiles.tsf;
    // TinySoundFont indexes the channel array with no lower bound of its own, so
    // a caller passing a negative channel would read in front of it.
    if (channel < 0) return 0;
    switch (controller) {
        0 => return tsf_mod.tsf_channel_get_preset_bank(sf, channel),
        7, 11 => {
            const v = tsf_mod.tsf_channel_get_volume(sf, channel);
            return openmiles.satI32(v * 127.0);
        },
        10 => {
            // tsf_channel_get_pan subtracts another 0.5 from the stored offset
            // (which is itself pan - 0.5), so pan - 1.0 comes back. That makes
            // a 0..1 float of (value / 127) recoverable; scaling by 64 instead
            // halved every answer, and no pan above 64 was reachable.
            const p = tsf_mod.tsf_channel_get_pan(sf, channel);
            return openmiles.satI32(@min(127.0, @max(0.0, (p + 1.0) * 127.0)));
        },
        else => return 0,
    }
}
// AIL_send_channel_voice_message(HMDIDRIVER mdi, HSEQUENCE S, S32 status, S32 data_1, S32 data_2)
pub fn AIL_send_channel_voice_message(mdi_opt: ?*MidiDriver, seq_opt: ?*Sequence, status: i32, d1: i32, d2: i32) callconv(.winapi) void {
    // Prefer the sequence's soundfont; fall back to the driver's when no sequence.
    const sf_opt = if (seq_opt) |seq| seq.driver.soundfont else if (mdi_opt) |mdi| mdi.soundfont else null;
    const sf = sf_opt orelse return;
    const tsf_mod = openmiles.tsf;
    const msg_type = status & 0xF0;
    const channel = status & 0x0F;
    // A channel voice message carries two 7-bit data bytes, but the SDK takes
    // them as S32 and the caller supplies them unchecked. Every handler below
    // scales or indexes the raw value, so an unmasked d2 = 256 would reach tsf
    // as note-on velocity 2.0 (a gain above unity), and a 14-bit pitch bend
    // assembled as (b2 << 7) | b1 would overflow its own field for any d2
    // above 0x3F, which tsf then stores as a bend past full deflection. Mask
    // both to the byte the format defines, so the value a handler sees is
    // always one the soundfont can hold.
    const b1: i32 = d1 & 0x7F;
    const b2: i32 = d2 & 0x7F;
    switch (msg_type) {
        0x80 => tsf_mod.tsf_channel_note_off(sf, channel, b1),
        0x90 => if (b2 > 0) {
            _ = tsf_mod.tsf_channel_note_on(sf, channel, b1, @as(f32, @floatFromInt(b2)) / 127.0);
        } else {
            tsf_mod.tsf_channel_note_off(sf, channel, b1);
        },
        0xB0 => {
            _ = tsf_mod.tsf_channel_midi_control(sf, channel, b1, b2);
        },
        0xC0 => {
            _ = tsf_mod.tsf_channel_set_presetnumber(sf, channel, b1, if (channel == 9) 1 else 0);
        },
        0xE0 => {
            // 14 bits: data byte 1 is the low 7, data byte 2 the high 7, so the
            // pair spans 0..16383 with 8192 as centre. That is the value tsf
            // divides by 16383 (deps/tsf.h), and the value the XMIDI path
            // forwards from tml, so the same number reaches the soundfont here.
            const bend = (b2 << 7) | b1;
            _ = tsf_mod.tsf_channel_set_pitchwheel(sf, channel, bend);
        },
        0xA0 => {},
        else => {},
    }
}
// SDK: AIL_send_sysex_message(HMDIDRIVER mdi, void const* buffer).
pub fn AIL_send_sysex_message(mdi_opt: ?*MidiDriver, data: *anyopaque) callconv(.winapi) void {
    const mdi = mdi_opt orelse return;
    const sf = mdi.soundfont orelse return;
    const bytes: [*]const u8 = @ptrCast(data);
    if (bytes[0] != 0xF0) return;
    var body_len: usize = 0;
    var i: usize = 1;
    // The SDK passes no length, so the scan needs both of its stop bytes. A
    // caller that hands over a short buffer without a terminator would
    // otherwise be read 511 bytes past its end; a NUL is the conventional
    // SysEx end-of-message marker and appears nowhere in a reset header, so
    // stopping on one only discards messages this function ignores anyway.
    while (i < 512) : (i += 1) {
        if (bytes[i] == 0xF7 or bytes[i] == 0) break;
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
        // A reset is four controllers per channel, and a rejected one leaves
        // that channel half reset: voices still sounding, the old volume and
        // pan in place. Nothing downstream of the SysEx would show it, so a
        // rejected control names the channel and the controller.
        var ch: i32 = 0;
        while (ch < 16) : (ch += 1) {
            resetControl(sf, ch, 123, 0);
            resetControl(sf, ch, 121, 0);
            resetControl(sf, ch, 7, 100);
            resetControl(sf, ch, 10, 64);
        }
    }
}

/// One controller of a GM/GS/XG channel reset. tsf answers 0 when it could not
/// apply the write (a channel it had to allocate for and could not), and the
/// caller gets no other signal that the channel did not come back to its
/// default state, so name the channel and the controller.
fn resetControl(sf: *openmiles.tsf.tsf, channel: i32, controller: i32, value: i32) void {
    if (openmiles.tsf.tsf_channel_midi_control(sf, channel, controller, value) == 0) {
        log("AIL_send_sysex_message: controller {d} on channel {d} was not applied; that channel is only partly reset\n", .{ controller, channel });
    }
}
// SDK: AIL_lock_channel(HMDIDRIVER mdi) / AIL_release_channel(HMDIDRIVER, S32).
pub fn AIL_lock_channel(mdi_opt: ?*MidiDriver) callconv(.winapi) i32 {
    const mdi = mdi_opt orelse return -1;
    return openmiles.lockChannel(@ptrCast(mdi));
}
pub fn AIL_release_channel(mdi_opt: ?*MidiDriver, channel: i32) callconv(.winapi) void {
    const mdi = mdi_opt orelse return;
    openmiles.releaseChannel(@ptrCast(mdi), channel);
}
pub fn AIL_register_beat_callback(seq_opt: ?*Sequence, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const seq = seq_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(seq.beat_callback.load(.acquire));
    seq.beat_callback.store(if (callback) |cb| @intFromPtr(cb) else 0, .release);
    return prev;
}
// AIL_register_event_callback(HMDIDRIVER mdi, AILEVENTCB cb) — driver-level.
pub fn AIL_register_event_callback(mdi_opt: ?*MidiDriver, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const mdi = mdi_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(mdi.event_callback.load(.acquire));
    mdi.event_callback.store(if (callback) |cb| @intFromPtr(cb) else 0, .release);
    return prev;
}
pub fn AIL_register_prefix_callback(seq_opt: ?*Sequence, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const seq = seq_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(seq.prefix_callback.load(.acquire));
    seq.prefix_callback.store(if (callback) |cb| @intFromPtr(cb) else 0, .release);
    return prev;
}
pub fn AIL_register_trigger_callback(seq_opt: ?*Sequence, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const seq = seq_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(seq.trigger_callback.load(.acquire));
    seq.trigger_callback.store(if (callback) |cb| @intFromPtr(cb) else 0, .release);
    return prev;
}
// AIL_register_timbre_callback(HMDIDRIVER mdi, AILTIMBRECB cb) — driver-level.
pub fn AIL_register_timbre_callback(mdi_opt: ?*MidiDriver, callback: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const mdi = mdi_opt orelse return null;
    const prev: ?*anyopaque = @ptrFromInt(mdi.timbre_callback.load(.acquire));
    mdi.timbre_callback.store(if (callback) |cb| @intFromPtr(cb) else 0, .release);
    return prev;
}
pub fn AIL_branch_index(seq_opt: ?*Sequence, marker: u32) callconv(.winapi) void {
    const seq = seq_opt orelse return;
    log("AIL_branch_index(seq={*}, marker={d})\n", .{ seq, marker });
    seq.branchIndex(marker);
}
/// AIL_register_ICA_array(ICA_array* arr): the SDK's "initial controller
/// array" is a fixed 16 x 128 byte grid (AIL_channel_info.c). The call carries
/// no length, so the grid size is the contract: a caller passing anything
/// smaller is already out of contract, and the walk below reads exactly the
/// documented 2048 bytes.
pub fn AIL_register_ICA_array(seq_opt: ?*Sequence, arr: *anyopaque) callconv(.winapi) void {
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

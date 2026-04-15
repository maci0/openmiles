const std = @import("std");
const root = @import("../root.zig");
const ma = root.ma;
const tsf = root.tsf;
const log = root.log;
const fs_compat = root.fs_compat;

extern fn openmiles_tml_get_key(m: *tsf.tml_message) u8;
extern fn openmiles_tml_get_velocity(m: *tsf.tml_message) u8;
extern fn openmiles_tml_get_control(m: *tsf.tml_message) u8;
extern fn openmiles_tml_get_control_value(m: *tsf.tml_message) u8;
extern fn openmiles_tml_get_program(m: *tsf.tml_message) u8;
extern fn openmiles_tml_get_pitch_bend(m: *tsf.tml_message) u16;

pub const MidiDriver = struct {
    allocator: std.mem.Allocator,
    soundfont: ?*tsf.tsf = null,
    master_volume: f32 = 1.0,
    sample_rate: u32 = 44100,
    owns_soundfont: bool = true, // false when soundfont is borrowed (AIL_create_wave_synthesizer)
    // DLS reverb state (stored; not actively applied — TSF has no global reverb bus)
    dls_reverb_room_type: f32 = 0.0,
    dls_reverb_level: f32 = 0.0,
    dls_reverb_reflect_time: f32 = 0.0,
    // Approximate soundfont memory footprint, captured at load time
    soundfont_size_bytes: u32 = 0,
    // DLS processor callback (stored but not invoked; TSF has its own pipeline)
    dls_processor: usize = 0,
    // DLS filter preferences — stored name/value pairs for AIL_set_filter_DLS_preference
    // and AIL_filter_DLS_attribute round-tripping. Simple last-set wins.
    dls_filter_pref_cutoff: f32 = 0.0,
    dls_filter_pref_compression: f32 = 0.0,

    pub fn init(allocator: std.mem.Allocator) !*MidiDriver {
        const self = try allocator.create(MidiDriver);
        self.* = .{
            .allocator = allocator,
            .soundfont = null,
        };
        root.last_midi_driver = self;
        return self;
    }

    pub fn deinit(self: *MidiDriver) void {
        if (self.soundfont) |sf| {
            if (self.owns_soundfont) tsf.tsf_close(sf);
        }
        self.allocator.destroy(self);
    }

    pub fn loadSoundfont(self: *MidiDriver, filename: []const u8) !void {
        if (self.soundfont) |sf| {
            if (self.owns_soundfont) tsf.tsf_close(sf);
        }
        self.owns_soundfont = true;
        const path_z = try fs_compat.dupeResolvedPathZ(self.allocator, filename);
        defer self.allocator.free(path_z);
        // Capture file size for AIL_DLS_get_info
        if (fs_compat.openFile(filename, .{})) |f| {
            defer f.close();
            if (f.stat()) |st| {
                self.soundfont_size_bytes = @intCast(st.size);
            } else |_| {}
        } else |_| {}
        self.soundfont = tsf.tsf_load_filename(path_z.ptr);
        if (self.soundfont == null) return error.SoundFontLoadFailed;
        // Use the engine's actual sample rate if a digital driver exists
        if (root.last_digital_driver) |dig| {
            self.sample_rate = ma.ma_engine_get_sample_rate(&dig.engine);
        }
        tsf.tsf_set_output(self.soundfont, tsf.TSF_STEREO_INTERLEAVED, @intCast(self.sample_rate), 0);
    }

    pub fn loadDLS(self: *MidiDriver, filename: []const u8) !*anyopaque {
        try self.loadSoundfont(filename);
        return @ptrCast(self.soundfont.?);
    }

    pub fn unloadDLS(self: *MidiDriver, bank: *anyopaque) void {
        const sf: *tsf.tsf = @ptrCast(@alignCast(bank));
        if (self.soundfont) |current_sf| {
            if (current_sf == sf) {
                if (self.owns_soundfont) tsf.tsf_close(sf);
                self.soundfont = null;
                self.owns_soundfont = true;
            }
        }
    }
};

pub const MidiStatus = enum(u32) {
    free = 1, // SEQ_FREE
    done = 2, // SEQ_DONE
    playing = 4, // SEQ_PLAYING
    stopped = 8, // SEQ_STOPPED
    playing_but_released = 16, // SEQ_PLAYINGBUTRELEASED
};

pub const XmidiLoopEntry = struct {
    start_msg: ?*tsf.tml_message = null,
    start_time_ms: f64 = 0,
    count: i32 = 1, // 0 = infinite, N>0 = N total passes remaining
};

pub const Sequence = struct {
    driver: *MidiDriver,
    midi: ?*tsf.tml_message = null,
    current_msg: ?*tsf.tml_message = null,
    time_ms: f64 = 0,
    total_ms: f64 = 0,
    is_playing: bool = false,
    is_paused: bool = false,
    is_done: bool = false,
    loop_count: i32 = 1,
    loops_remaining: i32 = 1,
    sound: ma.ma_sound,
    data_source: ma.ma_data_source_base,
    is_initialized: bool = false,
    volume: f32 = 1.0,
    tempo: i32 = 120,
    user_bpm: i32 = 0, // explicitly set by AIL_set_sequence_tempo (0 = follow MIDI file)
    tempo_ratio: f64 = 1.0, // user_bpm / file_bpm; scales time advancement in onRead
    initial_tempo: i32 = 120, // file's initial BPM (from first TML_SET_TEMPO at time 0)
    initial_ms_per_beat: f64 = 500.0, // file's initial ms/beat (reset on start/loop)
    user_data: [8]u32 = [_]u32{0} ** 8,
    // Beat/measure tracking
    ms_per_beat: f64 = 500.0, // current ms/beat (MIDI-time units = file BPM based)
    next_beat_ms: f64 = 500.0,
    current_beat_in_measure: i32 = 1,
    current_measure: i32 = 1,
    beats_per_measure: i32 = 4,
    // Callbacks
    beat_callback: usize = 0,
    event_callback: usize = 0,
    prefix_callback: usize = 0,
    trigger_callback: usize = 0,
    sequence_callback: usize = 0,
    timbre_callback: usize = 0,
    // Per-channel bank select (CC0 MSB) for timbre_callback
    channel_bank: [16]i32 = [_]i32{0} ** 16,
    // XMIDI FOR/NEXT loop stack
    xmidi_loop_depth: usize = 0,
    xmidi_loop_stack: [8]XmidiLoopEntry = [_]XmidiLoopEntry{.{}} ** 8,
    // Channel mapping: channel_map[logical] = physical. Identity by default.
    channel_map: [16]i32 = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 },
    // Tempo fade state: gradually transition tempo_ratio over a duration
    tempo_fade_start_ratio: f64 = 1.0,
    tempo_fade_target_ratio: f64 = 1.0,
    tempo_fade_elapsed_ms: f64 = 0,
    tempo_fade_duration_ms: f64 = 0,
    tempo_fade_active: bool = false,

    /// Resolve a logical MIDI channel to its physical (mapped) channel.
    fn mapChannel(self: *const Sequence, ch: i32) i32 {
        const idx: usize = @intCast(@min(@max(ch, 0), 15));
        return self.channel_map[idx];
    }

    pub fn setChannelMap(self: *Sequence, logical: i32, physical: i32) void {
        const idx: usize = @intCast(@min(@max(logical, 0), 15));
        self.channel_map[idx] = @min(@max(physical, 0), 15);
    }

    pub fn getPhysicalChannel(self: *const Sequence, logical: i32) i32 {
        return self.mapChannel(logical);
    }

    /// Send CC 123 (All Notes Off) on all 16 MIDI channels to avoid stuck notes.
    fn allNotesOff(self: *Sequence) void {
        if (self.driver.soundfont) |sf| {
            var ch: i32 = 0;
            while (ch < 16) : (ch += 1) {
                _ = tsf.tsf_channel_midi_control(sf, ch, 123, 0);
            }
        }
    }

    /// Process a TML_SET_TEMPO meta event: update file BPM, ms_per_beat, and tempo_ratio.
    fn applyTempoEvent(self: *Sequence, msg: *tsf.tml_message) void {
        const us_per_beat = tsf.tml_get_tempo_value(msg);
        if (us_per_beat > 0) {
            const file_ms_per_beat = @as(f64, @floatFromInt(us_per_beat)) / 1000.0;
            const file_bpm: i32 = @intFromFloat(60_000.0 / file_ms_per_beat);
            self.tempo = file_bpm;
            self.ms_per_beat = file_ms_per_beat;
            self.recalcTempoRatio(file_bpm);
        }
    }

    /// Recalculate tempo_ratio from user_bpm and a given file BPM.
    /// Tempo ratio is clamped to [0.01, 100] — games occasionally request
    /// extreme values, but onRead needs a non-zero divisor.
    fn recalcTempoRatio(self: *Sequence, file_bpm: i32) void {
        if (self.user_bpm > 0 and file_bpm > 0) {
            const raw = @as(f64, @floatFromInt(self.user_bpm)) / @as(f64, @floatFromInt(file_bpm));
            const target = @max(0.01, @min(raw, 100.0));
            if (self.tempo_fade_active) {
                self.tempo_fade_target_ratio = target;
            } else {
                self.tempo_ratio = target;
            }
        } else {
            self.tempo_ratio = 1.0;
            self.tempo_fade_active = false;
        }
    }

    /// Begin a gradual tempo transition from current tempo_ratio to the new target
    /// over `duration_ms` milliseconds of real time. Called by AIL_set_sequence_tempo.
    pub fn startTempoFade(self: *Sequence, target_bpm: i32, duration_ms: i32) void {
        if (duration_ms <= 0 or self.tempo <= 0) {
            // Instant change
            self.user_bpm = target_bpm;
            if (target_bpm > 0 and self.tempo > 0) {
                self.tempo_ratio = @as(f64, @floatFromInt(target_bpm)) / @as(f64, @floatFromInt(self.tempo));
            } else {
                self.tempo_ratio = 1.0;
            }
            self.tempo_fade_active = false;
            return;
        }
        self.user_bpm = target_bpm;
        self.tempo_fade_start_ratio = self.tempo_ratio;
        if (target_bpm > 0 and self.tempo > 0) {
            self.tempo_fade_target_ratio = @as(f64, @floatFromInt(target_bpm)) / @as(f64, @floatFromInt(self.tempo));
        } else {
            self.tempo_fade_target_ratio = 1.0;
        }
        self.tempo_fade_elapsed_ms = 0;
        self.tempo_fade_duration_ms = @floatFromInt(duration_ms);
        self.tempo_fade_active = true;
    }

    /// Advance the tempo fade by `real_ms` of wall-clock time. Returns the effective
    /// tempo_ratio to use for this interval.
    fn advanceTempoFade(self: *Sequence, real_ms: f64) void {
        if (!self.tempo_fade_active) return;
        self.tempo_fade_elapsed_ms += real_ms;
        if (self.tempo_fade_elapsed_ms >= self.tempo_fade_duration_ms) {
            // Fade complete
            self.tempo_ratio = self.tempo_fade_target_ratio;
            self.tempo_fade_active = false;
        } else {
            // Linear interpolation
            const t = self.tempo_fade_elapsed_ms / self.tempo_fade_duration_ms;
            self.tempo_ratio = self.tempo_fade_start_ratio + (self.tempo_fade_target_ratio - self.tempo_fade_start_ratio) * t;
        }
    }

    const data_source_vtable = ma.ma_data_source_vtable{
        .onRead = onRead,
        .onSeek = onSeek,
        .onGetDataFormat = onGetDataFormat,
        .onGetCursor = onGetCursor,
        .onGetLength = onGetLength,
        .onSetLooping = onSetLooping,
    };

    pub fn init(driver: *MidiDriver) !*Sequence {
        const self = try driver.allocator.create(Sequence);
        self.* = .{
            .driver = driver,
            .sound = undefined,
            .data_source = undefined,
        };

        var config = ma.ma_data_source_config_init();
        config.vtable = &data_source_vtable;

        const result = ma.ma_data_source_init(&config, &self.data_source);
        if (result != ma.MA_SUCCESS) {
            driver.allocator.destroy(self);
            return error.DataSourceInitFailed;
        }

        root.registerSequence(self);
        return self;
    }

    pub fn deinit(self: *Sequence) void {
        root.unregisterSequence(self);
        if (self.is_initialized) {
            ma.ma_sound_uninit(&self.sound);
        }
        ma.ma_data_source_uninit(&self.data_source);
        if (self.midi) |m| {
            tsf.tml_free(m);
        }
        self.driver.allocator.destroy(self);
    }

    fn onRead(pDataSource: ?*ma.ma_data_source, pFramesOut: ?*anyopaque, frameCount: ma.ma_uint64, pFramesRead: ?*ma.ma_uint64) callconv(.c) ma.ma_result {
        const self: *Sequence = @fieldParentPtr("data_source", @as(*ma.ma_data_source_base, @ptrCast(@alignCast(pDataSource.?))));
        if (!self.is_playing or self.driver.soundfont == null) {
            if (pFramesRead) |pr| pr.* = 0;
            return ma.MA_SUCCESS;
        }

        const sampleRate = @as(f64, @floatFromInt(self.driver.sample_rate));
        const msPerFrame = 1000.0 / sampleRate;
        var framesProcessed: ma.ma_uint64 = 0;
        const buffer: [*]f32 = @ptrCast(@alignCast(pFramesOut.?));

        while (framesProcessed < frameCount) {
            const framesRemaining = frameCount - framesProcessed;
            if (self.current_msg) |msg| {
                const timeToNextEvent = @as(f64, @floatFromInt(msg.*.time)) - self.time_ms;
                if (timeToNextEvent <= 0) {
                    var xmidi_jumped = false;
                    const phys_ch = self.mapChannel(msg.*.channel);
                    switch (msg.*.type) {
                        tsf.TML_NOTE_ON => {
                            // Use channel-aware API: tsf_note_on's second arg is preset_index,
                            // not channel. tsf_channel_note_on dispatches via channel's assigned patch.
                            _ = tsf.tsf_channel_note_on(self.driver.soundfont, phys_ch, openmiles_tml_get_key(msg), @as(f32, @floatFromInt(openmiles_tml_get_velocity(msg))) / 127.0);
                        },
                        tsf.TML_NOTE_OFF => {
                            tsf.tsf_channel_note_off(self.driver.soundfont, phys_ch, openmiles_tml_get_key(msg));
                        },
                        tsf.TML_PROGRAM_CHANGE => {
                            const prog = openmiles_tml_get_program(msg);
                            var allow: i32 = 1;
                            if (self.timbre_callback != 0) {
                                const cb: *const fn (*Sequence, i32, i32) callconv(.winapi) i32 = @ptrFromInt(self.timbre_callback);
                                allow = cb(self, self.channel_bank[@intCast(@as(u32, @intCast(phys_ch)))], @intCast(prog));
                            }
                            if (allow != 0) {
                                _ = tsf.tsf_channel_set_presetnumber(self.driver.soundfont, phys_ch, prog, if (phys_ch == 9) 1 else 0);
                            }
                        },
                        tsf.TML_CONTROL_CHANGE => {
                            const ctrl = openmiles_tml_get_control(msg);
                            const val = openmiles_tml_get_control_value(msg);
                            if (ctrl == 116) {
                                // XMIDI FOR: push loop stack entry. value=0 means infinite,
                                // value=N means play the loop body N times total.
                                if (self.xmidi_loop_depth < 8) {
                                    const loop_start = msg.*.next;
                                    const loop_time = if (loop_start) |lm| @as(f64, @floatFromInt(lm.*.time)) else self.time_ms;
                                    self.xmidi_loop_stack[self.xmidi_loop_depth] = .{
                                        .start_msg = loop_start,
                                        .start_time_ms = loop_time,
                                        .count = @as(i32, @intCast(val)), // 0=infinite
                                    };
                                    self.xmidi_loop_depth += 1;
                                } else {
                                    log("XMIDI: FOR/NEXT loop stack full (depth=8), ignoring nested loop\n", .{});
                                }
                            } else if (ctrl == 117) {
                                // XMIDI NEXT: check whether to loop back or exit
                                if (self.xmidi_loop_depth > 0) {
                                    const top = &self.xmidi_loop_stack[self.xmidi_loop_depth - 1];
                                    const should_loop = (top.count == 0) or (top.count > 1);
                                    if (should_loop) {
                                        if (top.count > 1) top.count -= 1;
                                        self.allNotesOff();
                                        self.current_msg = top.start_msg;
                                        self.time_ms = top.start_time_ms;
                                        const beats_elapsed: i32 = @intFromFloat(self.time_ms / self.ms_per_beat);
                                        self.current_beat_in_measure = @mod(beats_elapsed, self.beats_per_measure) + 1;
                                        self.current_measure = @divTrunc(beats_elapsed, self.beats_per_measure) + 1;
                                        self.next_beat_ms = @as(f64, @floatFromInt(beats_elapsed + 1)) * self.ms_per_beat;
                                        xmidi_jumped = true;
                                    } else {
                                        // count == 1: last pass, pop loop stack
                                        self.xmidi_loop_depth -= 1;
                                    }
                                }
                            } else if (ctrl == 112) {
                                // XMIDI prefix event — notify game
                                if (self.prefix_callback != 0) {
                                    const cb: *const fn (*Sequence, i32, i32, i32) callconv(.winapi) void = @ptrFromInt(self.prefix_callback);
                                    cb(self, @intCast(msg.*.channel), @intFromFloat(self.time_ms), @intCast(val));
                                }
                            } else if (ctrl == 119) {
                                // XMIDI trigger marker — notify game
                                if (self.trigger_callback != 0) {
                                    const cb: *const fn (*Sequence, i32, i32, i32) callconv(.winapi) void = @ptrFromInt(self.trigger_callback);
                                    cb(self, @intCast(msg.*.channel), @intFromFloat(self.time_ms), @intCast(val));
                                }
                            } else {
                                // Track bank select (CC0) for timbre_callback bank reporting
                                if (ctrl == 0) {
                                    const ch_idx: usize = @intCast(@as(u32, @intCast(phys_ch)));
                                    self.channel_bank[ch_idx] = @intCast(val);
                                }
                                _ = tsf.tsf_channel_midi_control(self.driver.soundfont, phys_ch, ctrl, val);
                                // Notify event callback with logical channel for game compatibility
                                if (self.event_callback != 0) {
                                    const cb: *const fn (*Sequence, i32, i32, i32, i32) callconv(.winapi) void = @ptrFromInt(self.event_callback);
                                    cb(self, @intCast(msg.*.channel), @intFromFloat(self.time_ms), @intCast(ctrl), @intCast(val));
                                }
                            }
                        },
                        tsf.TML_PITCH_BEND => {
                            _ = tsf.tsf_channel_set_pitchwheel(self.driver.soundfont, phys_ch, openmiles_tml_get_pitch_bend(msg));
                        },
                        tsf.TML_SET_TEMPO => {
                            self.applyTempoEvent(msg);
                        },
                        else => {},
                    }
                    if (!xmidi_jumped) self.current_msg = msg.*.next;
                    continue;
                }
                // Account for tempo_ratio: when playing faster, fewer frames elapse per ms of MIDI time.
                // Clamp to a small positive value to avoid division by zero from pathological fades.
                const safe_ratio = @max(self.tempo_ratio, 0.001);
                const msPerFrameEffective = msPerFrame * safe_ratio;
                const rawFramesUntilEvent = @max(0.0, @min(timeToNextEvent / msPerFrameEffective, @as(f64, @floatFromInt(frameCount))));
                const framesUntilEvent = @as(ma.ma_uint64, @intFromFloat(rawFramesUntilEvent));
                const framesToRender = @min(framesRemaining, @max(1, framesUntilEvent));
                tsf.tsf_render_float(self.driver.soundfont, buffer + (@as(usize, @intCast(framesProcessed)) * 2), @intCast(@as(usize, @intCast(framesToRender))), 0);
                const realMs = @as(f64, @floatFromInt(framesToRender)) * msPerFrame;
                self.advanceTempoFade(realMs);
                framesProcessed += framesToRender;
                self.time_ms += @as(f64, @floatFromInt(framesToRender)) * msPerFrameEffective;
                self.fireBeatCallbacks();
            } else {
                tsf.tsf_render_float(self.driver.soundfont, buffer + (@as(usize, @intCast(framesProcessed)) * 2), @intCast(@as(usize, @intCast(framesRemaining))), 0);
                const realMsPost = @as(f64, @floatFromInt(framesRemaining)) * msPerFrame;
                self.advanceTempoFade(realMsPost);
                framesProcessed += framesRemaining;
                self.time_ms += @as(f64, @floatFromInt(framesRemaining)) * msPerFrame * self.tempo_ratio;
                self.fireBeatCallbacks();
                if (self.loops_remaining <= 0 or self.loops_remaining > 1) {
                    // Loop restart (infinite when <=0, decrement when >1)
                    if (self.loops_remaining > 1) self.loops_remaining -= 1;
                    self.allNotesOff();
                    self.current_msg = self.midi;
                    self.time_ms = 0;
                    self.ms_per_beat = self.initial_ms_per_beat;
                    self.next_beat_ms = self.ms_per_beat;
                    self.current_beat_in_measure = 1;
                    self.current_measure = 1;
                } else {
                    self.is_playing = false;
                    self.is_done = true;
                    if (self.sequence_callback != 0) {
                        const cb: *const fn (*Sequence) callconv(.winapi) void = @ptrFromInt(self.sequence_callback);
                        cb(self);
                    }
                    break;
                }
            }
        }
        if (pFramesRead) |pr| pr.* = framesProcessed;
        return ma.MA_SUCCESS;
    }

    fn onSeek(pDataSource: ?*ma.ma_data_source, frameIndex: ma.ma_uint64) callconv(.c) ma.ma_result {
        _ = pDataSource;
        _ = frameIndex;
        return ma.MA_NOT_IMPLEMENTED;
    }

    fn onGetDataFormat(pDataSource: ?*ma.ma_data_source, pFormat: [*c]ma.ma_format, pChannels: [*c]ma.ma_uint32, pSampleRate: [*c]ma.ma_uint32, pChannelMap: [*c]ma.ma_channel, channelMapCap: usize) callconv(.c) ma.ma_result {
        _ = pChannelMap;
        _ = channelMapCap;
        const self: *Sequence = @fieldParentPtr("data_source", @as(*ma.ma_data_source_base, @ptrCast(@alignCast(pDataSource.?))));
        if (pFormat != null) pFormat.* = ma.ma_format_f32;
        if (pChannels != null) pChannels.* = 2;
        if (pSampleRate != null) pSampleRate.* = self.driver.sample_rate;
        return ma.MA_SUCCESS;
    }

    fn onGetCursor(pDataSource: ?*ma.ma_data_source, pCursor: ?*ma.ma_uint64) callconv(.c) ma.ma_result {
        _ = pDataSource;
        if (pCursor) |c| c.* = 0;
        return ma.MA_SUCCESS;
    }

    fn onGetLength(pDataSource: ?*ma.ma_data_source, pLength: ?*ma.ma_uint64) callconv(.c) ma.ma_result {
        _ = pDataSource;
        if (pLength) |l| l.* = 0;
        return ma.MA_SUCCESS;
    }

    fn onSetLooping(pDataSource: ?*ma.ma_data_source, isLooping: ma.ma_bool32) callconv(.c) ma.ma_result {
        _ = pDataSource;
        _ = isLooping;
        return ma.MA_SUCCESS;
    }

    fn fireBeatCallbacks(self: *Sequence) void {
        if (self.beat_callback == 0) return;
        if (self.ms_per_beat <= 0) return;
        var budget: u32 = 16; // cap iterations to prevent infinite loop on corrupted tempo
        while (self.time_ms >= self.next_beat_ms and budget > 0) : (budget -= 1) {
            const cb: *const fn (*Sequence, i32, i32) callconv(.winapi) void = @ptrFromInt(self.beat_callback);
            cb(self, self.current_beat_in_measure, self.current_measure);
            self.next_beat_ms += self.ms_per_beat;
            self.current_beat_in_measure += 1;
            if (self.current_beat_in_measure > self.beats_per_measure) {
                self.current_beat_in_measure = 1;
                self.current_measure += 1;
            }
        }
    }

    pub fn loadMidi(self: *Sequence, data: []const u8, seq_num: usize) !void {
        // Detect XMIDI (IFF FORM+XDIR or bare FORM+XMID) and convert to SMF if needed
        var converted: ?[]u8 = null;
        const alloc_opt = root.global_allocator;
        defer if (converted) |c| if (alloc_opt) |a| a.free(c);
        const smf_data: []const u8 = blk: {
            if (alloc_opt) |alloc| {
                if (data.len >= 12 and std.mem.eql(u8, data[0..4], "FORM")) {
                    if (std.mem.eql(u8, data[8..12], "XDIR")) {
                        converted = root.xmidiToSmf(alloc, data, seq_num) catch |err| {
                            log("XMIDI->SMF conversion failed: {any}\n", .{err});
                            break :blk data;
                        };
                        break :blk converted.?;
                    } else if (std.mem.eql(u8, data[8..12], "XMID")) {
                        converted = root.xmidiBareToSmf(alloc, data) catch |err| {
                            log("XMIDI (bare FORM/XMID) conversion failed: {any}\n", .{err});
                            break :blk data;
                        };
                        break :blk converted.?;
                    }
                }
            }
            break :blk data;
        };

        if (self.midi) |m| {
            tsf.tml_free(m);
        }
        self.midi = tsf.tml_load_memory(smf_data.ptr, @intCast(smf_data.len));
        if (self.midi == null) return error.MidiLoadFailed;
        self.current_msg = self.midi;
        self.time_ms = 0;
        // Extract time signature from SMF data
        self.beats_per_measure = root.parseSmfTimeSigNumerator(smf_data);
        // Single pass: find initial tempo AND compute total duration.
        {
            self.initial_tempo = 120;
            self.initial_ms_per_beat = 500.0;
            self.total_ms = 0;
            var found_tempo = false;
            var scan: ?*tsf.tml_message = self.midi;
            while (scan) |m| {
                if (!found_tempo and m.*.type == tsf.TML_SET_TEMPO) {
                    const us = tsf.tml_get_tempo_value(m);
                    if (us > 0) {
                        const fmpb = @as(f64, @floatFromInt(us)) / 1000.0;
                        self.initial_ms_per_beat = fmpb;
                        self.initial_tempo = @intFromFloat(60_000.0 / fmpb);
                    }
                    found_tempo = true;
                }
                self.total_ms = @max(self.total_ms, @as(f64, @floatFromInt(m.*.time)));
                scan = m.*.next;
            }
            self.ms_per_beat = self.initial_ms_per_beat;
            self.tempo = self.initial_tempo;
            self.recalcTempoRatio(self.initial_tempo);
        }
        // Loading a new sequence resets playback state (MSS: init_sequence → stopped)
        self.is_playing = false;
        self.is_paused = false;
        self.is_done = false;
    }

    /// Reset playback state to the beginning of the sequence (shared by start/stop).
    fn resetToBeginning(self: *Sequence) void {
        self.allNotesOff();
        self.current_msg = self.midi;
        self.time_ms = 0;
        self.loops_remaining = self.loop_count;
        self.ms_per_beat = self.initial_ms_per_beat;
        self.tempo = self.initial_tempo;
        self.tempo_fade_active = false;
        self.recalcTempoRatio(self.initial_tempo);
        self.next_beat_ms = self.ms_per_beat;
        self.current_beat_in_measure = 1;
        self.current_measure = 1;
        self.xmidi_loop_depth = 0;
    }

    pub fn start(self: *Sequence) void {
        if (!self.is_initialized) self.ensureSoundInitialized() catch return;
        // AIL_start_sequence always restarts from the beginning (even if paused)
        self.resetToBeginning();
        _ = ma.ma_sound_start(&self.sound);
        self.is_playing = true;
        self.is_paused = false;
        self.is_done = false;
    }

    pub fn stop(self: *Sequence) void {
        if (self.is_initialized) _ = ma.ma_sound_stop(&self.sound);
        self.is_playing = false;
        self.is_paused = false;
        self.is_done = false;
        self.resetToBeginning();
    }

    pub fn pause(self: *Sequence) void {
        if (self.is_playing and !self.is_paused) {
            if (self.is_initialized) _ = ma.ma_sound_stop(&self.sound);
            self.is_paused = true;
        }
    }

    pub fn resumePlayback(self: *Sequence) void {
        if (self.is_playing and self.is_paused) {
            if (self.is_initialized) _ = ma.ma_sound_start(&self.sound);
            self.is_paused = false;
        }
    }

    pub fn status(self: *Sequence) MidiStatus {
        if (!self.is_initialized) return .done;
        if (self.is_playing) return .playing; // includes paused state
        if (self.is_done) return .done;
        return .stopped;
    }

    pub fn setVolume(self: *Sequence, volume: i32, ms: i32) void {
        const new_vol = root.mssVolumeToGain(volume);
        self.volume = new_vol;
        if (self.is_initialized) {
            if (ms > 0) {
                // Fade from current volume to target over ms milliseconds
                ma.ma_sound_set_fade_in_milliseconds(&self.sound, -1, new_vol, @intCast(ms));
            } else {
                ma.ma_sound_set_volume(&self.sound, new_vol);
            }
        }
    }

    pub fn setLoopCount(self: *Sequence, count: i32) void {
        self.loop_count = count;
        self.loops_remaining = count;
    }

    pub fn getVolume(self: *Sequence) i32 {
        return root.gainToMssVolume(self.volume);
    }

    pub const MsPosition = struct { total: i32, current: i32 };

    pub fn getMsPosition(self: *Sequence) MsPosition {
        return .{
            .current = @intFromFloat(self.time_ms),
            .total = @intFromFloat(self.total_ms),
        };
    }

    pub fn setMsPosition(self: *Sequence, ms: i32) void {
        self.allNotesOff();
        const target_ms = @as(f64, @floatFromInt(ms));
        self.time_ms = target_ms;
        // Replay all non-note events before the target position to restore instrument/channel state
        // (program changes, control changes, pitch bends, tempo changes).  This ensures channels have
        // the correct patches, volumes, pans etc. after seeking — as if the MIDI had played through.
        self.current_msg = self.midi;
        while (self.current_msg) |msg| {
            if (@as(f64, @floatFromInt(msg.*.time)) >= target_ms) break;
            if (self.driver.soundfont) |sf| {
                // Apply channel mapping so seek-replay state targets the same
                // physical channel that onRead will use for live events.
                const phys_ch = self.mapChannel(msg.*.channel);
                switch (msg.*.type) {
                    tsf.TML_PROGRAM_CHANGE => {
                        _ = tsf.tsf_channel_set_presetnumber(sf, phys_ch, openmiles_tml_get_program(msg), if (phys_ch == 9) 1 else 0);
                    },
                    tsf.TML_CONTROL_CHANGE => {
                        const ctrl = openmiles_tml_get_control(msg);
                        const val = openmiles_tml_get_control_value(msg);
                        // Skip XMIDI reserved controls (112=prefix, 116=FOR, 117=NEXT, 119=trigger)
                        if (ctrl != 112 and ctrl != 116 and ctrl != 117 and ctrl != 119) {
                            _ = tsf.tsf_channel_midi_control(sf, phys_ch, ctrl, val);
                        }
                    },
                    tsf.TML_PITCH_BEND => {
                        _ = tsf.tsf_channel_set_pitchwheel(sf, phys_ch, openmiles_tml_get_pitch_bend(msg));
                    },
                    tsf.TML_SET_TEMPO => {
                        // Update tempo so beat/measure recalculation below uses the tempo
                        // that was active at the seek point, not the file's initial tempo.
                        self.applyTempoEvent(msg);
                    },
                    else => {},
                }
            }
            self.current_msg = msg.*.next;
        }
        // Recalculate beat/measure from new position
        const beats_elapsed: i32 = @intFromFloat(target_ms / self.ms_per_beat);
        self.current_beat_in_measure = @mod(beats_elapsed, self.beats_per_measure) + 1;
        self.current_measure = @divTrunc(beats_elapsed, self.beats_per_measure) + 1;
        self.next_beat_ms = @as(f64, @floatFromInt(beats_elapsed + 1)) * self.ms_per_beat;
        self.xmidi_loop_depth = 0;
    }

    pub fn branchIndex(self: *Sequence, marker_number: u32) void {
        // Seek to the XMIDI branch marker (CC 116) with value == marker_number.
        // After xmidiToSmf conversion, CC 116 events are preserved as TML_CONTROL_CHANGE
        // messages with control=116 and value=marker_index.
        var msg: ?*tsf.tml_message = self.midi;
        while (msg) |m| {
            if (m.*.type == tsf.TML_CONTROL_CHANGE and
                openmiles_tml_get_control(m) == 116 and
                @as(u32, openmiles_tml_get_control_value(m)) == marker_number)
            {
                self.allNotesOff();
                const target_ms = @as(f64, @floatFromInt(m.*.time));
                self.time_ms = target_ms;
                self.current_msg = m.*.next;
                const beats_elapsed: i32 = @intFromFloat(target_ms / self.ms_per_beat);
                self.current_beat_in_measure = @mod(beats_elapsed, self.beats_per_measure) + 1;
                self.current_measure = @divTrunc(beats_elapsed, self.beats_per_measure) + 1;
                self.next_beat_ms = @as(f64, @floatFromInt(beats_elapsed + 1)) * self.ms_per_beat;
                self.xmidi_loop_depth = 0;
                return;
            }
            msg = m.*.next;
        }
        // Marker not found — no-op
    }

    pub fn load(self: *Sequence, data: *anyopaque, size: i32) !void {
        try self.loadMidi(@as([*]const u8, @ptrCast(data))[0..@intCast(size)], 0);
    }

    pub fn ensureSoundInitialized(self: *Sequence) !void {
        if (self.is_initialized) return;
        // Auto-create a digital driver if none exists (game may only have opened a MIDI driver)
        if (root.last_digital_driver == null) {
            if (root.global_allocator) |ga| {
                _ = root.DigitalDriver.init(ga, 44100, 16, 2) catch {};
            }
        }
        if (root.last_digital_driver) |driver| {
            const result = ma.ma_sound_init_from_data_source(&driver.engine, @ptrCast(&self.data_source), ma.MA_SOUND_FLAG_NO_SPATIALIZATION, null, &self.sound);
            if (result != ma.MA_SUCCESS) return error.SoundInitFailed;
            self.is_initialized = true;
            ma.ma_sound_set_volume(&self.sound, self.volume);
        } else {
            return error.NoDigitalDriver;
        }
    }
};

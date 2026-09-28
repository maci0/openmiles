//! MIDI engine: MidiDriver loads SoundFont/DLS instruments and Sequence plays
//! XMIDI/SMF data, synthesizing through TSF/TML to the miniaudio output. Backs
//! the AIL_*_sequence MIDI surface.

const std = @import("std");
const root = @import("../root.zig");
const ma = root.ma;
const tsf = root.tsf;
const log = root.log;
const fs_compat = root.fs_compat;
const io = root.io;
const testing = std.testing;

extern fn openmiles_tml_get_key(m: *tsf.tml_message) u8;
extern fn openmiles_tml_get_velocity(m: *tsf.tml_message) u8;
extern fn openmiles_tml_get_control(m: *tsf.tml_message) u8;
extern fn openmiles_tml_get_control_value(m: *tsf.tml_message) u8;
extern fn openmiles_tml_get_program(m: *tsf.tml_message) u8;
extern fn openmiles_tml_get_pitch_bend(m: *tsf.tml_message) u16;

pub const MidiDriver = struct {
    allocator: std.mem.Allocator,
    // The audio thread renders from this pointer while the game thread can
    // replace or close the bank. tsf_close frees it, so a swap that closed the
    // displaced bank inline is a use-after-free the moment a sequence is playing.
    //
    // A renderer claims the bank by bumping render_readers before it loads the
    // pointer, and drops the claim when it is done. A swap publishes the
    // replacement first, then waits until the claim count is zero before
    // closing what it displaced. Only the swapping thread waits, so the audio
    // thread never blocks. Every write goes through swapSoundfont.
    soundfont: ?*tsf.tsf = null,
    render_readers: std.atomic.Value(u32) = .init(0),
    soundfont_mutex: std.Io.Mutex = .init,
    master_volume: f32 = 1.0,
    sample_rate: u32 = 44100,
    owns_soundfont: bool = true, // false when soundfont is borrowed (AIL_create_wave_synthesizer)
    // DLS reverb state (stored; not actively applied — TSF has no global reverb bus)
    dls_reverb_room_type: f32 = 0.0,
    dls_reverb_level: f32 = 0.0,
    dls_reverb_reflect_time: f32 = 0.0,
    // 6.5/6.6 AIL_DLS_*_reverb_levels: separate wet/dry pair (wet reuses
    // dls_reverb_level; dry defaults to fully-wet-passthrough 1.0).
    dls_reverb_dry_level: f32 = 1.0,
    // Approximate soundfont memory footprint, captured at load time
    soundfont_size_bytes: u32 = 0,
    // Identity of the soundfont in `soundfont`, so a load naming the same
    // source again is answered with the bank already in place. A bank handle
    // stays valid until it is unloaded, so a second load of one file (a retry
    // after a read error, a scene reloaded, a "is it loaded?" check) used to
    // close the bank the game was still holding and hand back a second copy,
    // leaving one dangling handle per repeat. `soundfont_path` is the resolved
    // path, owned; the image pair records a load from memory. A borrowed bank
    // (AIL_create_wave_synthesizer) records neither, so a borrow never answers
    // a load of its own.
    soundfont_path: ?[:0]u8 = null,
    // Address and length of the image the bank was loaded from, so a retry
    // that hands the same buffer back is recognised. Keyed on the address
    // rather than the bytes: the length comes from a header the caller
    // controls, so hashing it would read memory the image does not own.
    soundfont_image_ptr: usize = 0,
    soundfont_image_size: u32 = 0,
    // Loads of the bank in `soundfont` that no unload has answered yet. A
    // repeated load of the same source takes one, so N loads of one bank need
    // N unloads before it closes: the state after load/load/unload/unload is
    // the state one load and one unload left.
    soundfont_refs: u32 = 0,
    // DLS processor callback (stored but not invoked; TSF has its own pipeline)
    dls_processor: usize = 0,
    // Driver-level MIDI callbacks (MSS registers these on HMDIDRIVER, not a
    // sequence): AILEVENTCB(hmi, seq, status, d1, d2) and AILTIMBRECB(hmi, bank, patch).
    // Fired from the audio thread (onRead), registered from the game thread.
    event_callback: std.atomic.Value(usize) = .init(0),
    timbre_callback: std.atomic.Value(usize) = .init(0),
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
        root.setLastMidiDriver(self);
        return self;
    }

    pub fn deinit(self: *MidiDriver) void {
        root.clearLastMidiDriver(self);
        releaseAllChannels(@ptrCast(self));
        self.swapSoundfont(null, true);
        self.clearSoundfontSource();
        self.allocator.destroy(self);
    }

    /// Claim the soundfont for rendering, or null when none is loaded. Every
    /// non-null claim pairs with releaseSoundfontClaim, which is what lets a
    /// concurrent swap know the bank is idle enough to close.
    pub fn claimSoundfont(self: *MidiDriver) ?*tsf.tsf {
        _ = self.render_readers.fetchAdd(1, .seq_cst);
        const sf = self.soundfont;
        if (sf == null) self.releaseSoundfontClaim();
        return sf;
    }

    pub fn releaseSoundfontClaim(self: *MidiDriver) void {
        _ = self.render_readers.fetchSub(1, .seq_cst);
    }

    /// Publish `next` as the driver's soundfont and close the one it replaces,
    /// after in-flight renders finish with it. The displaced bank is closed
    /// only when it was owned, which is the flag as it stood before this call.
    pub fn swapSoundfont(self: *MidiDriver, next: ?*tsf.tsf, next_owned: bool) void {
        self.soundfont_mutex.lockUncancelable(io);
        defer self.soundfont_mutex.unlock(io);
        const previous = self.soundfont;
        const previous_owned = self.owns_soundfont;
        self.soundfont = next;
        self.owns_soundfont = next_owned;
        if (previous == next) return;
        while (self.render_readers.load(.seq_cst) != 0) std.atomic.spinLoopHint();
        if (previous) |sf| {
            if (previous_owned) tsf.tsf_close(sf);
        }
    }

    /// Forget which source the loaded soundfont came from, so the next load of
    /// that source is a real load rather than a repeat of this one. The reported
    /// size goes with it: AIL_DLS_get_info answers with it unconditionally, so
    /// leaving the previous bank's length in place reports the size of a bank
    /// that is no longer loaded whenever the new one's size cannot be read.
    pub fn clearSoundfontSource(self: *MidiDriver) void {
        if (self.soundfont_path) |p| self.allocator.free(p);
        self.soundfont_path = null;
        self.soundfont_image_ptr = 0;
        self.soundfont_image_size = 0;
        self.soundfont_size_bytes = 0;
        self.soundfont_refs = 0;
    }

    /// The bank already loaded from `path`, or null. A load that finds one
    /// keeps it: the handle the earlier load returned is still the live bank.
    pub fn soundfontFromPath(self: *const MidiDriver, path: []const u8) ?*tsf.tsf {
        const p = self.soundfont_path orelse return null;
        if (!std.mem.eql(u8, p, path)) return null;
        const sf = self.soundfont orelse return null;
        return sf;
    }

    /// The bank already loaded from the image at `data` of `size` bytes, or
    /// null.
    pub fn soundfontFromImage(self: *const MidiDriver, data: [*c]const u8, size: u32) ?*tsf.tsf {
        if (self.soundfont_image_ptr != @intFromPtr(data)) return null;
        if (self.soundfont_image_size != size) return null;
        const sf = self.soundfont orelse return null;
        return sf;
    }

    /// Drop the image identity of a bank whose source buffer the caller is
    /// about to free, keeping the bank itself. AIL_DLS_load_file's VFS path
    /// reads an image into a buffer it releases when it returns, so leaving
    /// that address recorded keyed a live bank to memory that no longer
    /// existed: the next image the allocator handed out at the same address,
    /// with a size its header matched, was answered with this bank instead of
    /// being loaded. The refs the loads took are untouched, so the bank still
    /// closes on the unload that answers the last of them.
    pub fn forgetSoundfontImage(self: *MidiDriver, data: [*c]const u8, size: u32) void {
        if (self.soundfont_image_ptr != @intFromPtr(data)) return;
        if (self.soundfont_image_size != size) return;
        self.soundfont_image_ptr = 0;
        self.soundfont_image_size = 0;
    }

    /// Milliseconds of MIDI time one output frame carries. A driver with no
    /// output rate has no frame time at all, and the unguarded 1000/rate it
    /// would otherwise yield is an infinity: the render loop would add it to
    /// `time_ms`, and every position read afterwards would be INF, NaN, or
    /// saturated to the counter maximum. Reports 0, which renders the buffer
    /// without advancing MIDI time.
    pub fn msPerFrame(self: *const MidiDriver) f64 {
        if (self.sample_rate == 0) return 0;
        return 1000.0 / @as(f64, @floatFromInt(self.sample_rate));
    }

    pub fn loadSoundfont(self: *MidiDriver, filename: []const u8) !void {
        const path_z = try fs_compat.dupeResolvedPathZ(self.allocator, filename);
        if (self.soundfontFromPath(path_z)) |_| {
            // The same file is already loaded. Keep the bank: replacing it
            // closed the handle the first load returned while the game was
            // still holding it, so every repeat of the load cost one dangling
            // handle and a second copy of the bank's memory. Nothing else the
            // load does applies here either, the bank already has it.
            log("loadSoundfont: '{s}' is already loaded; the bank in place is kept\n", .{filename});
            self.allocator.free(path_z);
            self.soundfont_refs += 1;
            return;
        }
        // Load the replacement before releasing the one in use: a load that
        // fails leaves the driver exactly as a single run left it, still
        // playing the previous soundfont, rather than silent with no bank.
        const loaded = tsf.tsf_load_filename(path_z.ptr);
        if (loaded == null) {
            self.allocator.free(path_z);
            return error.SoundFontLoadFailed;
        }
        self.swapSoundfont(loaded, true);
        self.clearSoundfontSource();
        self.soundfont_path = path_z;
        self.soundfont_refs = 1;
        self.captureSoundfontSize(filename);
        self.adoptOutputRate();
        tsf.tsf_set_output(self.soundfont, tsf.TSF_STEREO_INTERLEAVED, @intCast(self.sample_rate), 0);
    }

    /// Load a DLS/SF2 image, or hand back the bank already loaded from this
    /// same buffer. The handle the first load returned stays the live bank, so
    /// a retried memory load cannot leave the game holding a closed one.
    pub fn loadSoundfontImage(self: *MidiDriver, data: [*c]const u8, size: u32) !*tsf.tsf {
        if (self.soundfontFromImage(data, size)) |sf| {
            log("loadSoundfontImage: this image is already loaded; the bank in place is kept\n", .{});
            self.soundfont_refs += 1;
            return sf;
        }
        const loaded = tsf.tsf_load_memory(data, @intCast(size));
        if (loaded == null) return error.SoundFontLoadFailed;
        const bank = loaded.?;
        self.swapSoundfont(bank, true);
        self.clearSoundfontSource();
        self.soundfont_image_ptr = @intFromPtr(data);
        self.soundfont_image_size = size;
        self.soundfont_refs = 1;
        self.soundfont_size_bytes = @intCast(@min(size, std.math.maxInt(u32)));
        // Same rate the file path adopts: the data source hands the engine
        // frames at self.sample_rate, so a fixed 44100 here played a
        // 22050 Hz device at half speed.
        self.adoptOutputRate();
        tsf.tsf_set_output(self.soundfont, tsf.TSF_STEREO_INTERLEAVED, @intCast(self.sample_rate), 0);
        return bank;
    }

    /// Record the on-disk size of the bank just loaded, for AIL_DLS_get_info.
    /// A file that cannot be opened or sized leaves the reported size at 0;
    /// that is what the game sees, so the reason is named rather than left for
    /// the operator to compare against a value of 0 that looks like an empty
    /// bank.
    fn captureSoundfontSize(self: *MidiDriver, filename: []const u8) void {
        const f = fs_compat.openFile(io, filename, .{}) catch |err| {
            log("captureSoundfontSize: cannot open '{s}' ({any}); AIL_DLS_get_info reports 0 for it\n", .{ filename, err });
            return;
        };
        defer f.close(io);
        const len = f.length(io) catch |err| {
            log("captureSoundfontSize: cannot size '{s}' ({any}); AIL_DLS_get_info reports 0 for it\n", .{ filename, err });
            return;
        };
        self.soundfont_size_bytes = @intCast(@min(len, std.math.maxInt(u32)));
    }

    /// Take the output rate from the open playback device, if it has one. An
    /// engine with no device reports a rate of 0, and adopting it would leave
    /// every ms-per-frame conversion dividing by zero on the audio thread, so
    /// keep the last rate that can actually time anything.
    fn adoptOutputRate(self: *MidiDriver) void {
        if (root.lastDigitalDriver()) |dig| {
            const rate = ma.ma_engine_get_sample_rate(&dig.engine);
            if (rate > 0) self.sample_rate = rate;
        }
    }

    pub fn loadDLS(self: *MidiDriver, filename: []const u8) !*anyopaque {
        try self.loadSoundfont(filename);
        return @ptrCast(self.soundfont.?);
    }

    pub fn unloadDLS(self: *MidiDriver, bank: *anyopaque) void {
        const sf: *tsf.tsf = @ptrCast(@alignCast(bank));
        if (self.soundfont) |current_sf| {
            if (current_sf == sf) {
                // A load of this bank that no unload has answered yet keeps it
                // loaded: the game may still be holding the handle the first
                // load returned.
                if (self.soundfont_refs > 1) {
                    self.soundfont_refs -= 1;
                    return;
                }
                self.swapSoundfont(null, true);
                self.clearSoundfontSource();
                // AIL_DLS_get_info reports the size unconditionally, so a
                // released bank must not keep reporting its length.
                self.soundfont_size_bytes = 0;
            }
        }
    }
};

// Channel locks reserve a MIDI channel at the driver level; the owner pointer
// is opaque (the SDK's AIL_lock_channel/release_channel take an HMDIDRIVER) and
// used only for release matching.
pub var locked_channels: [16]?*anyopaque = .{null} ** 16;
var locked_channels_mutex: std.Io.Mutex = .init;

pub fn lockChannel(owner: *anyopaque) i32 {
    locked_channels_mutex.lockUncancelable(io);
    defer locked_channels_mutex.unlock(io);
    for (&locked_channels, 0..) |*slot, i| {
        if (i == 9) continue;
        if (slot.* == null) {
            slot.* = owner;
            return @intCast(i);
        }
    }
    return -1;
}

pub fn releaseChannel(owner: *anyopaque, channel: i32) void {
    if (channel < 0 or channel > 15) return;
    locked_channels_mutex.lockUncancelable(io);
    defer locked_channels_mutex.unlock(io);
    const idx: usize = @intCast(channel);
    if (locked_channels[idx] == owner) {
        locked_channels[idx] = null;
    }
}

/// Drop every lock held by `owner`. A lock outlives the handle that took it
/// unless the owner is torn down explicitly: a game that closes its MIDI
/// driver (or frees a sequence that locked a channel) otherwise leaves the
/// slots reserved by a freed pointer, and each leak costs one of the 15
/// lockable channels for the life of the process, until AIL_lock_channel
/// answers -1 forever. Releasing by owner is also the only form a teardown
/// path can use, since a single release call names one channel.
pub fn releaseAllChannels(owner: *anyopaque) void {
    locked_channels_mutex.lockUncancelable(io);
    defer locked_channels_mutex.unlock(io);
    for (&locked_channels) |*slot| {
        if (slot.* == owner) slot.* = null;
    }
}

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

/// Smallest BPM a SET_TEMPO microseconds value can express. Above 60_000_000 us
/// per beat (a 60 s beat) the 60000/ms_per_beat quotient falls under 1 and
/// truncates to 0, which AIL_tempo then reports and every tempo-ratio
/// consumer reads as "no tempo". Clamp instead of storing a zero beat rate.
const min_tempo_bpm: i32 = 1;

/// A file's tempo in whole BPM, from its microseconds-per-beat value. Both
/// callers of this derivation (the live event and the initial-tempo scan)
/// would otherwise truncate a slow tempo to zero. Any width: the TML accessor
/// returns a C int while a test literal reads more naturally unsigned.
fn bpmFromUsPerBeat(us_per_beat: anytype) i32 {
    const ms_per_beat = @as(f64, @floatFromInt(us_per_beat)) / 1000.0;
    return @max(min_tempo_bpm, root.satI32(60_000.0 / ms_per_beat));
}

/// Nested XMIDI FOR loops a sequence may keep open at once.
const max_xmidi_loop_depth = 8;

/// XMIDI FOR/NEXT jumps one buffer refill may take before the loop is dropped.
/// A jump costs no frames, so a body that never advances the clock (CC116 with
/// count 0 whose next message is CC117) would otherwise re-dispatch that NEXT
/// forever. Real bodies advance; the budget only bounds the degenerate one.
const max_xmidi_jumps_per_buffer: u32 = 256;

/// True when an XMIDI NEXT should jump back to its FOR. `budget` is the jumps
/// still allowed in this buffer; a finished loop (count 1) and an exhausted
/// budget both decline, and only a taken jump spends the budget.
fn xmidiShouldJump(count: i32, budget: *u32) bool {
    if (!((count == 0) or (count > 1))) return false;
    if (budget.* == 0) return false;
    budget.* -= 1;
    return true;
}

/// Truncate an f64 beat count into i32, clamping the high side one unit below
/// maxInt so every caller's `+ 1` (beat/measure bookkeeping) stays overflow-free.
/// ms_per_beat can be as small as 0.001 (a crafted 1-us-per-beat tempo event),
/// pushing time/ms_per_beat far past i32 range where @intFromFloat would panic.
fn satBeats(v: f64) i32 {
    return @min(root.satI32(v), std.math.maxInt(i32) - 1);
}

pub const Sequence = struct {
    driver: *MidiDriver,
    midi: ?*tsf.tml_message = null,
    current_msg: ?*tsf.tml_message = null,
    time_ms: f64 = 0,
    total_ms: f64 = 0,
    // Playback flags are written under state_mutex but read without it: by
    // status() on the caller's thread and by the root registry's active-sequence
    // count. Atomic so those reads are race-free without taking a lock the audio
    // thread may already hold. is_paused has no unlocked reader and is plain.
    is_playing: std.atomic.Value(bool) = .init(false),
    is_paused: bool = false,
    is_done: std.atomic.Value(bool) = .init(false),
    // SEQ_STOPPED only after an explicit AIL_stop_sequence; otherwise a loaded-
    // but-unplayed sequence is SEQ_DONE (the SDK comment: "finished playing, or
    // has [not yet played]").
    was_stopped: std.atomic.Value(bool) = .init(false),
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
    // Read back by the game's sequence callbacks, which the audio thread fires
    // while holding state_mutex, so this cannot be a plain field: the game
    // calls AIL_set_sequence_user_data from that same callback and would
    // deadlock on the mutex.
    user_data: [8]std.atomic.Value(u32) = [_]std.atomic.Value(u32){.init(0)} ** 8,
    // Beat/measure tracking
    ms_per_beat: f64 = 500.0, // current ms/beat (MIDI-time units = file BPM based)
    next_beat_ms: f64 = 500.0,
    // Advanced on the audio thread under state_mutex, read by
    // AIL_sequence_position from any thread (including from inside a beat
    // callback, where taking state_mutex would deadlock).
    current_beat_in_measure: std.atomic.Value(i32) = .init(1),
    current_measure: std.atomic.Value(i32) = .init(1),
    beats_per_measure: i32 = 4,
    // Callbacks (per-sequence: beat/prefix/trigger/sequence take HSEQUENCE).
    // event/timbre are driver-level and live on MidiDriver instead. Registered
    // from the game's thread and read by the audio thread, so atomic.
    beat_callback: std.atomic.Value(usize) = .init(0),
    prefix_callback: std.atomic.Value(usize) = .init(0),
    trigger_callback: std.atomic.Value(usize) = .init(0),
    sequence_callback: std.atomic.Value(usize) = .init(0),
    // Per-channel bank select (CC0 MSB) for timbre_callback
    channel_bank: [16]i32 = [_]i32{0} ** 16,
    // XMIDI FOR/NEXT loop stack. A deeper FOR is ignored; the NEXT that would
    // have closed it then finds the enclosing loop instead.
    xmidi_loop_depth: usize = 0,
    xmidi_loop_stack: [max_xmidi_loop_depth]XmidiLoopEntry = [_]XmidiLoopEntry{.{}} ** max_xmidi_loop_depth,
    // Channel mapping: channel_map[logical] = physical. Identity by default.
    // AIL_map_sequence_channel writes it from the game's thread while the audio
    // thread resolves channels in onRead, so each slot is atomic.
    channel_map: [16]std.atomic.Value(i32) = .{
        .init(0), .init(1), .init(2),  .init(3),  .init(4),  .init(5),  .init(6),  .init(7),
        .init(8), .init(9), .init(10), .init(11), .init(12), .init(13), .init(14), .init(15),
    },
    // Tempo fade state: gradually transition tempo_ratio over a duration
    tempo_fade_start_ratio: f64 = 1.0,
    tempo_fade_target_ratio: f64 = 1.0,
    tempo_fade_elapsed_ms: f64 = 0,
    tempo_fade_duration_ms: f64 = 0,
    tempo_fade_active: bool = false,
    // Protects Sequence state against audio-thread / control-thread races.
    // onRead uses tryLock (renders silence if contended); all control-path
    // methods (start/stop/setMsPosition/setLoopCount/etc.) use lock.
    state_mutex: std.Io.Mutex = .init,

    /// Resolve a logical MIDI channel to its physical (mapped) channel.
    fn mapChannel(self: *const Sequence, ch: i32) i32 {
        const idx: usize = @intCast(@min(@max(ch, 0), 15));
        return self.channel_map[idx].load(.acquire);
    }

    pub fn setChannelMap(self: *Sequence, logical: i32, physical: i32) void {
        const idx: usize = @intCast(@min(@max(logical, 0), 15));
        self.channel_map[idx].store(@min(@max(physical, 0), 15), .release);
    }

    pub fn getPhysicalChannel(self: *const Sequence, logical: i32) i32 {
        return self.mapChannel(logical);
    }

    pub fn getUserData(self: *const Sequence, index: u32) u32 {
        const idx: usize = @intCast(@min(index, self.user_data.len - 1));
        return self.user_data[idx].load(.acquire);
    }

    pub fn setUserData(self: *Sequence, index: u32, value: u32) void {
        const idx: usize = @intCast(@min(index, self.user_data.len - 1));
        self.user_data[idx].store(value, .release);
    }

    /// Send CC 123 (All Notes Off) on all 16 MIDI channels to avoid stuck notes.
    /// Claims the bank the way render does: this runs from the audio thread and
    /// from control methods, and a swap must not free the bank under either.
    fn allNotesOff(self: *Sequence) void {
        const sf = self.driver.claimSoundfont() orelse return;
        defer self.driver.releaseSoundfontClaim();
        var ch: i32 = 0;
        while (ch < 16) : (ch += 1) {
            _ = tsf.tsf_channel_midi_control(sf, ch, 123, 0);
        }
    }

    /// Process a TML_SET_TEMPO meta event: update file BPM, ms_per_beat, and tempo_ratio.
    fn applyTempoEvent(self: *Sequence, msg: *tsf.tml_message) void {
        const us_per_beat = tsf.tml_get_tempo_value(msg);
        if (us_per_beat > 0) {
            const file_ms_per_beat = @as(f64, @floatFromInt(us_per_beat)) / 1000.0;
            const file_bpm: i32 = bpmFromUsPerBeat(us_per_beat);
            self.tempo = file_bpm;
            self.ms_per_beat = file_ms_per_beat;
            self.recalcTempoRatio(file_bpm);
            // The new grid is anchored at time_ms, not carried over from the old
            // one. A pending beat deadline set at the old tempo can sit many
            // beats past time_ms under a faster one, so leaving it would skip
            // every beat between the tempo change and it, and the reported
            // measure would run behind the music for the rest of the sequence.
            self.resyncBeatClock();
        }
    }

    /// Re-derive the beat and measure counters, and the next beat deadline,
    /// from `at_ms` under the current `ms_per_beat`. Every point that moves the
    /// beat grid mid-sequence (a TML_SET_TEMPO event, an XMIDI loop-back, a
    /// seek) or falls out of the fire budget goes through here, so the reported
    /// position is always the one the file's tempo implies rather than an
    /// accumulation from whenever the grid last changed.
    fn resyncBeatClockAt(self: *Sequence, at_ms: f64) void {
        if (self.ms_per_beat <= 0) return;
        const beats = satBeats(at_ms / self.ms_per_beat);
        self.next_beat_ms = @as(f64, @floatFromInt(beats + 1)) * self.ms_per_beat;
        self.current_beat_in_measure.store(@mod(beats, self.beats_per_measure) + 1, .release);
        self.current_measure.store(@divTrunc(beats, self.beats_per_measure) + 1, .release);
    }

    fn resyncBeatClock(self: *Sequence) void {
        self.resyncBeatClockAt(self.time_ms);
    }

    /// Clamp a raw user/file BPM ratio into the range every consumer can
    /// divide by: games request extreme values, and onRead needs a non-zero
    /// divisor. Single source of truth for the [0.01, 100] bound.
    fn clampedTempoRatio(raw: f64) f64 {
        return @max(0.01, @min(raw, 100.0));
    }

    /// Recalculate tempo_ratio from user_bpm and a given file BPM.
    fn recalcTempoRatio(self: *Sequence, file_bpm: i32) void {
        if (self.user_bpm > 0 and file_bpm > 0) {
            const raw = @as(f64, @floatFromInt(self.user_bpm)) / @as(f64, @floatFromInt(file_bpm));
            const target = clampedTempoRatio(raw);
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
        self.state_mutex.lockUncancelable(io);
        defer self.state_mutex.unlock(io);
        if (duration_ms <= 0 or self.tempo <= 0) {
            self.user_bpm = target_bpm;
            if (target_bpm > 0 and self.tempo > 0) {
                const raw = @as(f64, @floatFromInt(target_bpm)) / @as(f64, @floatFromInt(self.tempo));
                self.tempo_ratio = clampedTempoRatio(raw);
            } else {
                self.tempo_ratio = 1.0;
            }
            self.tempo_fade_active = false;
            return;
        }
        self.user_bpm = target_bpm;
        self.tempo_fade_start_ratio = self.tempo_ratio;
        // Past the early return above, self.tempo is already known positive.
        if (target_bpm > 0) {
            const raw = @as(f64, @floatFromInt(target_bpm)) / @as(f64, @floatFromInt(self.tempo));
            self.tempo_fade_target_ratio = clampedTempoRatio(raw);
        } else {
            self.tempo_fade_target_ratio = 1.0;
        }
        self.tempo_fade_elapsed_ms = 0;
        self.tempo_fade_duration_ms = @floatFromInt(duration_ms);
        self.tempo_fade_active = true;
    }

    /// Advance the tempo fade by `real_ms` of rendered-audio time (frames x
    /// ms-per-frame, independent of any OS clock), updating `tempo_ratio` in place.
    fn advanceTempoFade(self: *Sequence, real_ms: f64) void {
        if (!self.tempo_fade_active) return;
        self.tempo_fade_elapsed_ms += real_ms;
        if (self.tempo_fade_duration_ms <= 0 or self.tempo_fade_elapsed_ms >= self.tempo_fade_duration_ms) {
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
        releaseAllChannels(@ptrCast(self));
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
        if (!self.is_playing.load(.acquire)) {
            if (pFramesRead) |pr| pr.* = 0;
            return ma.MA_SUCCESS;
        }
        // tryLock so the audio thread never blocks waiting for a control-path
        // method (start/stop/setMsPosition/etc.). If contended, render silence
        // for this buffer. The next callback retries.
        if (!self.state_mutex.tryLock()) {
            if (pFramesRead) |pr| pr.* = 0;
            return ma.MA_SUCCESS;
        }
        defer self.state_mutex.unlock(io);
        // Hold the bank for the whole callback, so a game thread that swaps it
        // waits out this render instead of freeing the bank mid-callback.
        const soundfont = self.driver.claimSoundfont() orelse {
            if (pFramesRead) |pr| pr.* = 0;
            return ma.MA_SUCCESS;
        };
        defer self.driver.releaseSoundfontClaim();

        const msPerFrame = self.driver.msPerFrame();
        var framesProcessed: ma.ma_uint64 = 0;
        var xmidi_jump_budget: u32 = max_xmidi_jumps_per_buffer;
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
                            _ = tsf.tsf_channel_note_on(soundfont, phys_ch, openmiles_tml_get_key(msg), @as(f32, @floatFromInt(openmiles_tml_get_velocity(msg))) / 127.0);
                        },
                        tsf.TML_NOTE_OFF => {
                            tsf.tsf_channel_note_off(soundfont, phys_ch, openmiles_tml_get_key(msg));
                        },
                        tsf.TML_PROGRAM_CHANGE => {
                            const prog = openmiles_tml_get_program(msg);
                            var allow: i32 = 1;
                            // One load, one call: a second load inside the guard
                            // can observe an unregister that landed between the
                            // two and hand @ptrFromInt(0) to the call.
                            const timbre_raw = self.driver.timbre_callback.load(.acquire);
                            if (timbre_raw != 0) {
                                // AILTIMBRECB(HMDIDRIVER hmi, S32 bank, S32 patch)
                                const cb: *const fn (?*anyopaque, i32, i32) callconv(.winapi) i32 = @ptrFromInt(timbre_raw);
                                allow = cb(@ptrCast(self.driver), self.channel_bank[@intCast(@as(u32, @intCast(phys_ch)))], @intCast(prog));
                            }
                            if (allow != 0) {
                                _ = tsf.tsf_channel_set_presetnumber(soundfont, phys_ch, prog, if (phys_ch == 9) 1 else 0);
                            }
                        },
                        tsf.TML_CONTROL_CHANGE => {
                            const ctrl = openmiles_tml_get_control(msg);
                            const val = openmiles_tml_get_control_value(msg);
                            if (ctrl == 116) {
                                // XMIDI FOR: push loop stack entry. value=0 means infinite,
                                // value=N means play the loop body N times total.
                                if (self.xmidi_loop_depth < max_xmidi_loop_depth) {
                                    const loop_start = msg.*.next;
                                    const loop_time = if (loop_start) |lm| @as(f64, @floatFromInt(lm.*.time)) else self.time_ms;
                                    self.xmidi_loop_stack[self.xmidi_loop_depth] = .{
                                        .start_msg = loop_start,
                                        .start_time_ms = loop_time,
                                        .count = @as(i32, @intCast(val)), // 0=infinite
                                    };
                                    self.xmidi_loop_depth += 1;
                                } else {
                                    log("XMIDI: FOR/NEXT loop stack full (depth={d}), ignoring nested loop\n", .{max_xmidi_loop_depth});
                                }
                            } else if (ctrl == 117) {
                                // XMIDI NEXT: check whether to loop back or exit
                                if (self.xmidi_loop_depth > 0) {
                                    const top = &self.xmidi_loop_stack[self.xmidi_loop_depth - 1];
                                    const should_loop = xmidiShouldJump(top.count, &xmidi_jump_budget);
                                    if (should_loop) {
                                        if (top.count > 1) top.count -= 1;
                                        self.allNotesOff();
                                        self.current_msg = top.start_msg;
                                        self.time_ms = top.start_time_ms;
                                        self.resyncBeatClock();
                                        xmidi_jumped = true;
                                    } else {
                                        // count == 1: last pass, pop loop stack
                                        self.xmidi_loop_depth -= 1;
                                    }
                                }
                            } else if (ctrl == 112) {
                                // XMIDI prefix event — notify game.
                                // AILPREFIXCB: S32 cb(HSEQUENCE seq, S32 log, S32 data)
                                const prefix_raw = self.prefix_callback.load(.acquire);
                                if (prefix_raw != 0) {
                                    const cb: *const fn (*Sequence, i32, i32) callconv(.winapi) i32 = @ptrFromInt(prefix_raw);
                                    _ = cb(self, @intCast(val), @intCast(msg.*.channel));
                                }
                            } else if (ctrl == 119) {
                                // XMIDI trigger marker — notify game.
                                // AILTRIGGERCB: void cb(HSEQUENCE seq, S32 log, S32 data)
                                const trigger_raw = self.trigger_callback.load(.acquire);
                                if (trigger_raw != 0) {
                                    const cb: *const fn (*Sequence, i32, i32) callconv(.winapi) void = @ptrFromInt(trigger_raw);
                                    cb(self, @intCast(val), @intCast(msg.*.channel));
                                }
                            } else {
                                // Track bank select (CC0) for timbre_callback bank reporting
                                if (ctrl == 0) {
                                    const ch_idx: usize = @intCast(@as(u32, @intCast(phys_ch)));
                                    self.channel_bank[ch_idx] = @intCast(val);
                                }
                                _ = tsf.tsf_channel_midi_control(soundfont, phys_ch, ctrl, val);
                                // AILEVENTCB(HMDIDRIVER hmi, HSEQUENCE seq, S32 status, S32 data_1, S32 data_2)
                                // status = 0xB0 | logical channel for a control-change event.
                                const event_raw = self.driver.event_callback.load(.acquire);
                                if (event_raw != 0) {
                                    const cb: *const fn (?*anyopaque, ?*anyopaque, i32, i32, i32) callconv(.winapi) i32 = @ptrFromInt(event_raw);
                                    _ = cb(@ptrCast(self.driver), @ptrCast(self), 0xB0 | @as(i32, @intCast(msg.*.channel)), @intCast(ctrl), @intCast(val));
                                }
                            }
                        },
                        tsf.TML_PITCH_BEND => {
                            _ = tsf.tsf_channel_set_pitchwheel(soundfont, phys_ch, openmiles_tml_get_pitch_bend(msg));
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
                const safe_ratio = @max(self.tempo_ratio, 0.01);
                const msPerFrameEffective = msPerFrame * safe_ratio;
                const rawFramesUntilEvent = @max(0.0, @min(timeToNextEvent / msPerFrameEffective, @as(f64, @floatFromInt(frameCount))));
                const framesUntilEvent = @as(ma.ma_uint64, @intFromFloat(rawFramesUntilEvent));
                const framesToRender = @min(framesRemaining, @max(1, framesUntilEvent));
                tsf.tsf_render_float(soundfont, buffer + (@as(usize, @intCast(framesProcessed)) * 2), @intCast(@as(usize, @intCast(framesToRender))), 0);
                const realMs = @as(f64, @floatFromInt(framesToRender)) * msPerFrame;
                self.advanceTempoFade(realMs);
                framesProcessed += framesToRender;
                self.time_ms += @as(f64, @floatFromInt(framesToRender)) * msPerFrameEffective;
                self.fireBeatCallbacks();
            } else {
                tsf.tsf_render_float(soundfont, buffer + (@as(usize, @intCast(framesProcessed)) * 2), @intCast(@as(usize, @intCast(framesRemaining))), 0);
                const realMsPost = @as(f64, @floatFromInt(framesRemaining)) * msPerFrame;
                self.advanceTempoFade(realMsPost);
                framesProcessed += framesRemaining;
                self.time_ms += @as(f64, @floatFromInt(framesRemaining)) * msPerFrame * self.tempo_ratio;
                self.fireBeatCallbacks();
                if (self.loops_remaining <= 0 or self.loops_remaining > 1) {
                    // Loop restart (infinite when <=0, decrement when >1)
                    if (self.loops_remaining > 1) self.loops_remaining -= 1;
                    self.rewindToStart();
                } else {
                    self.is_playing.store(false, .release);
                    self.is_done.store(true, .release);
                    const seq_raw = self.sequence_callback.load(.acquire);
                    if (seq_raw != 0) {
                        const cb: *const fn (*Sequence) callconv(.winapi) void = @ptrFromInt(seq_raw);
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

    /// Advance the beat clock to the current time, firing the beat callback for
    /// every beat crossed. The clock advances whether or not a callback is
    /// registered: AIL_sequence_position reports these same beat/measure
    /// counters, and returning early with no callback left them frozen at 1,1
    /// for the whole of a playing sequence.
    fn fireBeatCallbacks(self: *Sequence) void {
        if (self.ms_per_beat <= 0) return;
        const cb_ptr = self.beat_callback.load(.acquire);
        var budget: u32 = 16; // cap iterations to prevent infinite loop on corrupted tempo
        while (self.time_ms >= self.next_beat_ms and budget > 0) : (budget -= 1) {
            const beat = self.current_beat_in_measure.load(.acquire);
            const measure = self.current_measure.load(.acquire);
            if (cb_ptr != 0) {
                // AILBEATCB: void cb(HMDIDRIVER hmi, HSEQUENCE seq, S32 beat, S32 measure)
                const cb: *const fn (?*anyopaque, *Sequence, i32, i32) callconv(.winapi) void = @ptrFromInt(cb_ptr);
                cb(@ptrCast(self.driver), self, beat, measure);
            }
            self.next_beat_ms += self.ms_per_beat;
            self.current_beat_in_measure.store(beat + 1, .release);
            if (beat + 1 > self.beats_per_measure) {
                self.current_beat_in_measure.store(1, .release);
                self.current_measure.store(measure + 1, .release);
            }
        }
        // A buffer longer than the budget (a very fast tempo, or a tempo change
        // that shortened the beat) leaves next_beat_ms behind time_ms, so every
        // later call re-fires the same capped run and the reported beat stays
        // wrong forever. Resync the clock to the derived position instead.
        if (budget == 0 and self.time_ms >= self.next_beat_ms) {
            self.resyncBeatClock();
        }
    }

    pub fn loadMidi(self: *Sequence, data: []const u8, seq_num: usize) !void {
        // Detect XMIDI (IFF FORM+XDIR or bare FORM+XMID) and convert to SMF if needed
        var converted: ?[]u8 = null;
        const alloc = self.driver.allocator;
        defer if (converted) |c| alloc.free(c);
        const smf_data: []const u8 = blk: {
            if (data.len >= 12 and std.mem.eql(u8, data[0..4], "FORM")) {
                if (std.mem.eql(u8, data[8..12], "XDIR")) {
                    converted = root.xmidiToSmf(alloc, data, seq_num) catch |err| {
                        log("XMIDI->SMF conversion failed: {any}\n", .{err});
                        return err;
                    };
                    break :blk converted.?;
                } else if (std.mem.eql(u8, data[8..12], "XMID")) {
                    converted = root.xmidiBareToSmf(alloc, data) catch |err| {
                        log("XMIDI (bare FORM/XMID) conversion failed: {any}\n", .{err});
                        return err;
                    };
                    break :blk converted.?;
                }
            }
            break :blk data;
        };

        // Parse into a local first: only swap (and free the old sequence) once
        // the new data has parsed. Failing mid-swap would leave current_msg
        // pointing at freed TML memory while a playing sequence kept rendering.
        const loaded = tsf.tml_load_memory(smf_data.ptr, @intCast(smf_data.len));
        if (loaded == null) return error.MidiLoadFailed;
        // state_mutex across the swap and the fields rewritten from the new
        // list below. onRead holds it for the whole of each render block, and
        // clears is_playing only at the end of this function, so without it the
        // audio thread can still be walking the old chain when tml_free runs:
        // current_msg is followed through msg.*.next while it is freed. The
        // parse above stays outside the lock; it touches nothing shared.
        self.state_mutex.lockUncancelable(io);
        defer self.state_mutex.unlock(io);
        if (self.midi) |m| {
            tsf.tml_free(m);
        }
        self.midi = loaded;
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
                        self.initial_tempo = bpmFromUsPerBeat(us);
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
        // Loading a new sequence stops playback (MSS: init_sequence → stopped).
        // The status goes back to SEQ_DONE, not SEQ_STOPPED: was_stopped is only
        // set by AIL_stop_sequence, and SEQ_DONE also covers "not yet played".
        self.is_playing.store(false, .release);
        self.is_paused = false;
        self.is_done.store(false, .release);
        self.was_stopped.store(false, .release);
    }

    /// Everything a pass back to the start of the sequence has to restore,
    /// shared by the first start and a loop restart. `loops_remaining` is left
    /// alone: the first pass seeds it from `loop_count`, a restart spends one.
    fn rewindToStart(self: *Sequence) void {
        self.allNotesOff();
        self.current_msg = self.midi;
        self.time_ms = 0;
        self.ms_per_beat = self.initial_ms_per_beat;
        // The next pass starts at the file's own tempo: a tempo change applied
        // during the pass finished must not leak into it, or ms_per_beat and
        // tempo disagree and the loop plays at the wrong speed.
        self.tempo = self.initial_tempo;
        self.tempo_fade_active = false;
        self.recalcTempoRatio(self.initial_tempo);
        self.xmidi_loop_depth = 0;
        self.next_beat_ms = self.ms_per_beat;
        self.current_beat_in_measure.store(1, .release);
        self.current_measure.store(1, .release);
    }

    /// Reset playback state to the beginning of the sequence (shared by start/stop).
    fn resetToBeginning(self: *Sequence) void {
        self.loops_remaining = self.loop_count;
        self.rewindToStart();
    }

    pub fn start(self: *Sequence) void {
        self.state_mutex.lockUncancelable(io);
        defer self.state_mutex.unlock(io);
        if (!self.is_initialized) {
            self.ensureSoundInitialized() catch |err| {
                // Say why: the caller sees SEQ_DONE forever otherwise.
                log("Sequence.start: sound init failed ({any}); sequence will not play\n", .{err});
                return;
            };
        }
        self.resetToBeginning();
        _ = ma.ma_sound_start(&self.sound);
        self.is_playing.store(true, .release);
        self.is_paused = false;
        self.is_done.store(false, .release);
        self.was_stopped.store(false, .release);
    }

    pub fn stopAndUninit(self: *Sequence) void {
        self.state_mutex.lockUncancelable(io);
        defer self.state_mutex.unlock(io);
        self.is_playing.store(false, .release);
        if (self.is_initialized) {
            _ = ma.ma_sound_stop(&self.sound);
            ma.ma_sound_uninit(&self.sound);
            self.is_initialized = false;
        }
    }

    pub fn stop(self: *Sequence) void {
        self.state_mutex.lockUncancelable(io);
        defer self.state_mutex.unlock(io);
        if (self.is_initialized) _ = ma.ma_sound_stop(&self.sound);
        self.is_playing.store(false, .release);
        self.is_paused = false;
        self.is_done.store(false, .release);
        self.was_stopped.store(true, .release);
        self.resetToBeginning();
    }

    pub fn pause(self: *Sequence) void {
        self.state_mutex.lockUncancelable(io);
        defer self.state_mutex.unlock(io);
        if (self.is_playing.load(.acquire) and !self.is_paused) {
            if (self.is_initialized) _ = ma.ma_sound_stop(&self.sound);
            self.is_paused = true;
        }
    }

    pub fn resumePlayback(self: *Sequence) void {
        self.state_mutex.lockUncancelable(io);
        defer self.state_mutex.unlock(io);
        if (self.is_playing.load(.acquire) and self.is_paused) {
            if (self.is_initialized) _ = ma.ma_sound_start(&self.sound);
            self.is_paused = false;
        }
    }

    pub fn status(self: *Sequence) MidiStatus {
        if (!self.is_initialized) return .done; // MSS: uninitialized sequences report SEQ_DONE
        if (self.is_playing.load(.acquire)) return .playing; // includes paused state
        if (self.is_done.load(.acquire)) return .done;
        // Loaded-but-never-played -> SEQ_DONE; only after AIL_stop_sequence is it
        // SEQ_STOPPED (SEQ_DONE covers "finished or not yet played").
        return if (self.was_stopped.load(.acquire)) .stopped else .done;
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
        self.state_mutex.lockUncancelable(io);
        defer self.state_mutex.unlock(io);
        self.loop_count = count;
        self.loops_remaining = count;
    }

    pub fn getVolume(self: *Sequence) i32 {
        return root.gainToMssVolume(self.volume);
    }

    pub const MsPosition = struct { total: i32, current: i32 };

    pub fn getMsPosition(self: *Sequence) MsPosition {
        return .{
            // Saturating: total_ms comes from TML u32 event times and can
            // exceed maxInt(i32); time_ms accumulates unbounded in playback.
            .current = root.satI32(self.time_ms),
            .total = root.satI32(self.total_ms),
        };
    }

    pub fn setMsPosition(self: *Sequence, ms: i32) void {
        self.state_mutex.lockUncancelable(io);
        defer self.state_mutex.unlock(io);
        self.allNotesOff();
        const target_ms = @as(f64, @floatFromInt(ms));
        self.time_ms = target_ms;
        // Replay all non-note events before the target position to restore instrument/channel state
        // (program changes, control changes, pitch bends, tempo changes).  This ensures channels have
        // the correct patches, volumes, pans etc. after seeking — as if the MIDI had played through.
        self.current_msg = self.midi;
        const soundfont = self.driver.claimSoundfont();
        defer if (soundfont != null) self.driver.releaseSoundfontClaim();
        while (self.current_msg) |msg| {
            if (@as(f64, @floatFromInt(msg.*.time)) >= target_ms) break;
            if (soundfont) |sf| {
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
        self.recalcBeatPosition(target_ms);
    }

    fn recalcBeatPosition(self: *Sequence, target_ms: f64) void {
        if (self.ms_per_beat <= 0) return;
        self.resyncBeatClockAt(target_ms);
        self.xmidi_loop_depth = 0;
    }

    pub fn branchIndex(self: *Sequence, marker_number: u32) void {
        self.state_mutex.lockUncancelable(io);
        defer self.state_mutex.unlock(io);
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
                self.recalcBeatPosition(target_ms);
                return;
            }
            msg = m.*.next;
        }
    }

    pub fn load(self: *Sequence, data: *anyopaque, size: i32) !void {
        // Guard the narrowing like Sample.load does: a negative size panics on
        // the i32 -> usize cast in safe modes and becomes a ~4 GB slice in
        // ReleaseFast.
        if (size <= 0) return error.InvalidParam;
        try self.loadMidi(@as([*]const u8, @ptrCast(data))[0..@intCast(size)], 0);
    }

    pub fn ensureSoundInitialized(self: *Sequence) !void {
        if (self.is_initialized) return;
        // Auto-create a digital driver if none exists (game may only have opened
        // a MIDI driver). Go through openDigitalDriver: init() alone leaves the
        // new driver out of the current-driver handle, so this branch would run
        // again for every sequence and each one would build another miniaudio
        // engine that nothing can close. A null return already logged the reason;
        // the branch below reports it to the caller as error.NoDigitalDriver.
        _ = root.openDigitalDriver(44100, 16, 2);
        if (root.lastDigitalDriver()) |driver| {
            const result = ma.ma_sound_init_from_data_source(&driver.engine, @ptrCast(&self.data_source), ma.MA_SOUND_FLAG_NO_SPATIALIZATION, null, &self.sound);
            if (result != ma.MA_SUCCESS) return error.SoundInitFailed;
            self.is_initialized = true;
            ma.ma_sound_set_volume(&self.sound, self.volume);
        } else {
            return error.NoDigitalDriver;
        }
    }
};

test "bpmFromUsPerBeat never truncates a slow tempo to zero" {
    try testing.expectEqual(@as(i32, 120), bpmFromUsPerBeat(500_000)); // 500 ms/beat
    try testing.expectEqual(@as(i32, 1), bpmFromUsPerBeat(60_000_000)); // exactly 60 s/beat
    // Past 60 s/beat the quotient falls under 1: 0 BPM is a value AIL_tempo
    // reports and no tempo-ratio consumer can divide by.
    try testing.expectEqual(@as(i32, 1), bpmFromUsPerBeat(60_000_001));
    try testing.expectEqual(@as(i32, 1), bpmFromUsPerBeat(std.math.maxInt(u32)));
}

test "an XMIDI loop that never advances the clock stops after the jump budget" {
    var budget: u32 = 3;
    try testing.expect(xmidiShouldJump(0, &budget));
    try testing.expect(xmidiShouldJump(0, &budget));
    try testing.expect(xmidiShouldJump(0, &budget));
    try testing.expect(!xmidiShouldJump(0, &budget));
    try testing.expectEqual(@as(u32, 0), budget);
    budget = 4;
    try testing.expect(!xmidiShouldJump(1, &budget));
    try testing.expectEqual(@as(u32, 4), budget);
    try testing.expect(xmidiShouldJump(2, &budget));
    try testing.expectEqual(@as(u32, 3), budget);
}

test "satBeats truncates in range and clamps extremes with +1 headroom" {
    try testing.expectEqual(@as(i32, 0), satBeats(0.0));
    try testing.expectEqual(@as(i32, 7), satBeats(7.9)); // truncates toward zero
    try testing.expectEqual(@as(i32, -7), satBeats(-7.9));
    try testing.expectEqual(@as(i32, 0), satBeats(std.math.nan(f64)));
    // Beyond i32: clamps one below maxInt so callers' `+ 1` cannot overflow.
    try testing.expectEqual(std.math.maxInt(i32) - 1, satBeats(2e12));
    try testing.expectEqual(std.math.maxInt(i32) - 1, satBeats(1e300));
}

test "beat clock advances with no beat callback registered" {
    const driver = try MidiDriver.init(testing.allocator);
    defer driver.deinit();
    const seq = try Sequence.init(driver);
    defer seq.deinit();

    seq.ms_per_beat = 500.0;
    seq.beats_per_measure = 4;
    seq.next_beat_ms = 500.0;
    // No beat callback: AIL_sequence_position still reports a moving clock.
    seq.time_ms = 2600.0;
    seq.fireBeatCallbacks();
    try testing.expectEqual(@as(i32, 2), seq.current_beat_in_measure.load(.acquire));
    try testing.expectEqual(@as(i32, 2), seq.current_measure.load(.acquire));
    try testing.expectEqual(@as(f64, 3000.0), seq.next_beat_ms);
}

test "beat clock resyncs after the per-call beat budget is spent" {
    const driver = try MidiDriver.init(testing.allocator);
    defer driver.deinit();
    const seq = try Sequence.init(driver);
    defer seq.deinit();

    // 1000 ms of beats at 1 ms/beat crosses far more than the 16-beat budget.
    seq.ms_per_beat = 1.0;
    seq.beats_per_measure = 4;
    seq.next_beat_ms = 1.0;
    seq.time_ms = 1000.0;
    seq.fireBeatCallbacks();
    // Resynced to the derived position rather than left 984 ms behind the clock,
    // which would make every later call re-run the capped loop and report the
    // same stale beat.
    try testing.expectEqual(@as(i32, 1), seq.current_beat_in_measure.load(.acquire));
    try testing.expectEqual(@as(i32, 251), seq.current_measure.load(.acquire));
    try testing.expectEqual(@as(f64, 1001.0), seq.next_beat_ms);
}

test "a mid-sequence tempo change re-anchors the beat grid" {
    const driver = try MidiDriver.init(testing.allocator);
    defer driver.deinit();
    const seq = try Sequence.init(driver);
    defer seq.deinit();

    // 60 BPM, four beats into the song, with the next beat still a full beat
    // away on the old 1000 ms grid.
    seq.ms_per_beat = 1000.0;
    seq.initial_ms_per_beat = 1000.0;
    seq.tempo = 60;
    seq.beats_per_measure = 4;
    seq.next_beat_ms = 5000.0;
    seq.time_ms = 4000.0;
    seq.resyncBeatClock();
    try testing.expectEqual(@as(f64, 5000.0), seq.next_beat_ms);
    try testing.expectEqual(@as(i32, 1), seq.current_beat_in_measure.load(.acquire));
    try testing.expectEqual(@as(i32, 2), seq.current_measure.load(.acquire));

    // The file doubles the tempo at this point. Beats 4.5 and 4.9 of the old
    // grid have to fall where the new grid puts them, not where the pending
    // old-grid deadline sat.
    seq.time_ms = 4100.0;
    seq.ms_per_beat = 500.0;
    seq.resyncBeatClock();
    // 4100 / 500 = 8.2 beats elapsed: beat 9 of measure 3, next deadline 4500.
    try testing.expectEqual(@as(f64, 4500.0), seq.next_beat_ms);
    try testing.expectEqual(@as(i32, 1), seq.current_beat_in_measure.load(.acquire));
    try testing.expectEqual(@as(i32, 3), seq.current_measure.load(.acquire));
}

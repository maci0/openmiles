const std = @import("std");
const builtin = @import("builtin");
const logger = @import("utils/logger.zig");

pub const log = logger.log;
pub const fs_compat = @import("utils/fs_compat.zig");

pub const ma = @cImport({
    @cInclude("miniaudio.h");
});

pub const tsf = @cImport({
    @cInclude("tsf.h");
    @cInclude("tml.h");
});

// --- Default allocator (GPA) ---
// The library entry point (main.zig) no longer owns the allocator; it lives here
// so that all modules can reach it via the `openmiles` named import without
// creating a bidirectional dependency on main.zig.
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const default_allocator = gpa.allocator();

pub const DigitalDriver = @import("engine/digital.zig").DigitalDriver;
pub const Sample = @import("engine/digital.zig").Sample;
pub const Sample3D = @import("engine/digital.zig").Sample3D;
pub const SampleStatus = @import("engine/digital.zig").SampleStatus;
pub const SamplePcmFormat = @import("engine/digital.zig").SamplePcmFormat;
pub const buildWavFromPcm = @import("engine/digital.zig").buildWavFromPcm;

pub const MidiDriver = @import("engine/midi.zig").MidiDriver;
pub const Sequence = @import("engine/midi.zig").Sequence;
pub const MidiStatus = @import("engine/midi.zig").MidiStatus;

pub const Timer = @import("engine/timer.zig").Timer;

pub const Filter = @import("engine/filter.zig").Filter;

pub const Input = @import("engine/input.zig").Input;

pub const Redbook = @import("engine/redbook.zig").Redbook;
pub const RedbookStatus = @import("engine/redbook.zig").RedbookStatus;

pub const Provider = @import("rib/provider.zig").Provider;
pub const getCurrentLoadingProvider = @import("rib/provider.zig").getCurrentLoadingProvider;
pub const Interface = @import("rib/provider.zig").Interface;
pub const RIB_INTERFACE_ENTRY = @import("rib/provider.zig").RIB_INTERFACE_ENTRY;
pub const RIB_ENTRY_TYPE = @import("rib/provider.zig").RIB_ENTRY_TYPE;
pub const RIB_DATA_TYPE = @import("rib/provider.zig").RIB_DATA_TYPE;
pub const HPROVIDER = @import("rib/provider.zig").HPROVIDER;
pub const RIB_alloc_provider_handle_ptr = @import("rib/provider.zig").RIB_alloc_provider_handle_ptr;
pub const RIB_register_interface_ptr = @import("rib/provider.zig").RIB_register_interface_ptr;
pub const RIB_unregister_interface_ptr = @import("rib/provider.zig").RIB_unregister_interface_ptr;
pub const RIB_Main_ptr = @import("rib/provider.zig").RIB_Main_ptr;

pub const deg2rad = std.math.pi / 180.0;

/// Convert an MSS 0-127 volume value to a linear gain (0.0-1.0) using a
/// perceptual curve that approximates the original Miles Sound System
/// attenuation behavior (~60 dB dynamic range).
///
/// The original MSS hardware used a heavily weighted scale where low values
/// (e.g., 30/127) produced dramatic attenuation. A cubic power curve
/// `(v/127)^3` closely matches this: value 30 → gain ~0.013 (vs linear 0.24).
pub fn mssVolumeToGain(value: i32) f32 {
    if (value <= 0) return 0.0;
    if (value >= 127) return 1.0;
    const normalized = @as(f32, @floatFromInt(value)) / 127.0;
    return normalized * normalized * normalized;
}

/// Inverse of mssVolumeToGain: convert a linear gain back to MSS 0-127.
pub fn gainToMssVolume(gain: f32) i32 {
    if (gain <= 0.0) return 0;
    if (gain >= 1.0) return 127;
    const cbrt = std.math.cbrt(gain);
    return @intFromFloat(@round(cbrt * 127.0));
}

/// Sentinel size for streaming formats (OGG, MP3, FLAC) where the actual file
/// size cannot be determined from the header alone.
/// WARNING: Using this sentinel as a slice length from an arbitrary pointer may
/// read past allocated memory. Only safe when the underlying buffer is at least
/// this large.
pub const streaming_sentinel_size: usize = 16 * 1024 * 1024;

// --- Global State ---

pub var global_allocator: ?std.mem.Allocator = null;

// --- MIDI Channel Lock State ---
// Tracks which MIDI channels (0-15) are locked by sequences.
// null = unlocked, non-null = pointer to owning Sequence.
pub var locked_channels: [16]?*Sequence = .{null} ** 16;
var locked_channels_mutex: std.Thread.Mutex = .{};

pub fn lockChannel(seq: *Sequence) i32 {
    locked_channels_mutex.lock();
    defer locked_channels_mutex.unlock();
    // Find first unlocked non-drum channel (skip 9 = percussion)
    for (&locked_channels, 0..) |*slot, i| {
        if (i == 9) continue;
        if (slot.* == null) {
            slot.* = seq;
            return @intCast(i);
        }
    }
    return -1; // No channels available
}

pub fn releaseChannel(seq: *Sequence, channel: i32) void {
    if (channel < 0 or channel > 15) return;
    locked_channels_mutex.lock();
    defer locked_channels_mutex.unlock();
    const idx: usize = @intCast(channel);
    if (locked_channels[idx] == seq) {
        locked_channels[idx] = null;
    }
}

// --- Error state ---
pub var last_error_buf: [256:0]u8 = [_:0]u8{0} ** 256;
pub var last_file_error_buf: [256:0]u8 = [_:0]u8{0} ** 256;
pub var debug_printf_buf: [1024]u8 = [_]u8{0} ** 1024;

pub fn setLastError(msg: []const u8) void {
    const len = @min(msg.len, last_error_buf.len - 1);
    @memcpy(last_error_buf[0..len], msg[0..len]);
    last_error_buf[len] = 0;
}

pub fn clearLastError() void {
    last_error_buf[0] = 0;
}

pub fn setFileError(msg: []const u8) void {
    const len = @min(msg.len, last_file_error_buf.len - 1);
    @memcpy(last_file_error_buf[0..len], msg[0..len]);
    last_file_error_buf[len] = 0;
}

pub fn clearFileError() void {
    last_file_error_buf[0] = 0;
}

// --- Custom File I/O Callbacks ---
pub var cb_file_open: ?*const fn ([*:0]const u8, *u32) callconv(.winapi) ?*anyopaque = null;
pub var cb_file_close: ?*const fn (?*anyopaque) callconv(.winapi) void = null;
pub var cb_file_read: ?*const fn (?*anyopaque, *anyopaque, u32) callconv(.winapi) u32 = null;
pub var cb_file_seek: ?*const fn (?*anyopaque, i32) callconv(.winapi) i32 = null;

/// If file callbacks are set, open the file via the game's VFS, read it all into
/// a freshly-allocated slice (caller must free with default_allocator), and close it.
pub fn fileCallbackReadAll(filename: [*:0]const u8) ![]u8 {
    const open_fn = cb_file_open orelse return error.NoCallbacks;
    const close_fn = cb_file_close orelse return error.NoCallbacks;
    const read_fn = cb_file_read orelse return error.NoCallbacks;

    var file_size: u32 = 0;
    const handle = open_fn(filename, &file_size) orelse return error.FileNotFound;
    defer close_fn(handle);

    if (file_size == 0) {
        if (cb_file_seek) |seek_fn| {
            const end_pos = seek_fn(handle, std.math.maxInt(i32));
            if (end_pos > 0) {
                file_size = @intCast(end_pos);
                _ = seek_fn(handle, 0);
            }
        }
        if (file_size == 0) return error.UnknownSize;
    }

    const buf = try default_allocator.alloc(u8, file_size);
    errdefer default_allocator.free(buf);
    const bytes_read = read_fn(handle, buf.ptr, file_size);
    if (bytes_read != file_size) return error.ReadFailed;
    return buf;
}

// --- Startup provider and ASI state ---
pub var startup_provider: ?*Provider = null;
pub var asi_temp_counter: u32 = 0;

pub const AILSOUNDINFO = extern struct {
    format: i32,
    data_ptr: ?*const anyopaque,
    data_len: u32,
    rate: u32,
    bits: i32,
    channels: i32,
    samples: u32,
    block_size: u32,
    initial_ptr: ?*const anyopaque,
};

pub const provider_3d_attr_names = [_][*:0]const u8{
    "Rolloff factor",
    "Doppler factor",
    "Distance factor",
};

pub const sample_3d_attr_names = [_][*:0]const u8{
    "Obstruction",
    "Occlusion",
};

var global_providers: std.ArrayListUnmanaged(*Provider) = .{};

pub fn getAllProviders() []*Provider {
    return global_providers.items;
}

pub fn isPluginExtension(name: []const u8) bool {
    return name.len >= 4 and (std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".asi") or
        std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".m3d") or
        std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".flt"));
}

pub fn loadApplicationProviders(dir: []const u8) i32 {
    const alloc = global_allocator orelse return 0;
    var count: i32 = 0;
    var d = fs_compat.openDir(dir, .{ .iterate = true }) catch |err| {
        log("loadApplicationProviders: failed to open directory '{s}': {any}\n", .{ dir, err });
        return 0;
    };
    defer d.close();
    var it = d.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!isPluginExtension(name)) continue;
        const full_path = std.fs.path.join(alloc, &.{ dir, name }) catch continue;
        defer alloc.free(full_path);
        const p = Provider.load(alloc, full_path) catch |err| {
            log("loadApplicationProviders: failed to load plugin '{s}': {any}\n", .{ name, err });
            continue;
        };
        global_providers.append(alloc, p) catch {
            p.deinit();
            continue;
        };
        count += 1;
    }
    return count;
}

pub var global_timers: std.ArrayListUnmanaged(*Timer) = .{};
pub var global_timers_mutex: std.Thread.Mutex = .{};

pub fn startAllTimers() void {
    global_timers_mutex.lock();
    defer global_timers_mutex.unlock();
    for (global_timers.items) |t| t.start();
}

pub fn stopAllTimers() void {
    global_timers_mutex.lock();
    defer global_timers_mutex.unlock();
    for (global_timers.items) |t| t.stop();
}

pub fn releaseAllTimers() void {
    // Drain from the front; Timer.deinit locks global_timers_mutex internally,
    // so we must release our lock before each call to avoid deadlock.
    while (true) {
        global_timers_mutex.lock();
        if (global_timers.items.len == 0) {
            global_timers_mutex.unlock();
            break;
        }
        const t = global_timers.items[0];
        global_timers_mutex.unlock();
        t.deinit();
    }
}

pub var last_digital_driver: ?*DigitalDriver = null;
pub var last_midi_driver: ?*MidiDriver = null;

// Startup timestamp in nanoseconds (set on first call to getMsCount/getUsCount or library load).
// AIL_ms_count / AIL_us_count return elapsed time since startup, not since the epoch.
var startup_ns: i64 = 0;

pub fn ensureStartupTime() void {
    if (startup_ns == 0) startup_ns = @truncate(std.time.nanoTimestamp());
}

var known_drivers_buf: [8]?*DigitalDriver = [_]?*DigitalDriver{null} ** 8;

pub fn registerDriver(driver: *DigitalDriver) void {
    for (&known_drivers_buf) |*slot| {
        if (slot.* == null) {
            slot.* = driver;
            return;
        }
    }
}

pub fn unregisterDriver(driver: *DigitalDriver) void {
    for (&known_drivers_buf) |*slot| {
        if (slot.* == driver) {
            slot.* = null;
            return;
        }
    }
}

pub fn isKnownDriver(ptr: *anyopaque) bool {
    for (known_drivers_buf) |slot| {
        if (slot) |d| {
            if (@as(*anyopaque, @ptrCast(d)) == ptr) return true;
        }
    }
    return false;
}
var redist_directory: [256:0]u8 = [_:0]u8{0} ** 256;
var preferences: [512]i32 = init: {
    var p = [_]i32{0} ** 512;
    p[0] = 131; // DIG_RESAMPLING_TOLERANCE
    p[1] = 64; // DIG_MIXER_CHANNELS
    p[2] = 127; // DIG_DEFAULT_VOLUME
    p[3] = 120; // MDI_SERVICE_RATE
    p[4] = 8; // MDI_SEQUENCES
    p[5] = 127; // MDI_DEFAULT_VOLUME
    p[6] = 1; // MDI_QUANT_ADVANCE
    p[7] = 0; // MDI_ALLOW_LOOP_BRANCHING
    p[8] = 2; // MDI_DEFAULT_BEND_RANGE
    p[9] = 0; // MDI_DOUBLE_NOTE_OFF
    p[10] = 1536; // MDI_SYSEX_BUFFER_SIZE
    p[11] = 49152; // DIG_OUTPUT_BUFFER_SIZE
    p[12] = 5; // AIL_MM_PERIOD
    p[31] = 1; // DIG_ENABLE_RESAMPLE_FILTER
    p[32] = 2048; // DIG_DECODE_BUFFER_SIZE
    break :init p;
};

pub fn setRedistDirectory(path: []const u8) void {
    log("Setting redist directory to: {s}\n", .{path});
    const len = @min(path.len, redist_directory.len - 1);
    @memcpy(redist_directory[0..len], path[0..len]);
    redist_directory[len] = 0;
    if (last_digital_driver) |driver| {
        driver.loadAllAsi(redist_directory[0..len]);
    }
}

pub fn getRedistDirectory() []const u8 {
    return std.mem.sliceTo(&redist_directory, 0);
}

pub fn getPreference(number: u32) i32 {
    if (number < preferences.len) return preferences[number];
    return 0;
}

pub fn setPreference(number: u32, value: i32) i32 {
    if (number < preferences.len) {
        const old = preferences[number];
        preferences[number] = value;
        return old;
    }
    return 0;
}

// --- Global utility functions ---

var global_sequences: std.ArrayListUnmanaged(*Sequence) = .{};
var global_sequences_mutex: std.Thread.Mutex = .{};

pub fn registerSequence(seq: *Sequence) void {
    if (global_allocator) |ga| {
        global_sequences_mutex.lock();
        defer global_sequences_mutex.unlock();
        global_sequences.append(ga, seq) catch {};
    }
}

pub fn unregisterSequence(seq: *Sequence) void {
    global_sequences_mutex.lock();
    defer global_sequences_mutex.unlock();
    for (global_sequences.items, 0..) |s, i| {
        if (s == seq) {
            _ = global_sequences.swapRemove(i);
            break;
        }
    }
}

pub fn getActiveSequenceCount() u32 {
    global_sequences_mutex.lock();
    defer global_sequences_mutex.unlock();
    var count: u32 = 0;
    for (global_sequences.items) |s| {
        if (s.is_playing) count += 1;
    }
    return count;
}

pub fn getMsCount() u32 {
    ensureStartupTime();
    const now_ns: i64 = @truncate(std.time.nanoTimestamp());
    const elapsed_ns: u64 = @intCast(@max(0, now_ns - startup_ns));
    return @truncate(elapsed_ns / std.time.ns_per_ms);
}

pub fn getUsCount() u32 {
    ensureStartupTime();
    const now_ns: i64 = @truncate(std.time.nanoTimestamp());
    const elapsed_ns: u64 = @intCast(@max(0, now_ns - startup_ns));
    return @truncate(elapsed_ns / std.time.ns_per_us);
}

// ASI codec — delegated to engine/asi.zig
pub const get_ASI_INTERFACE = @import("engine/asi.zig").get_ASI_INTERFACE;

// XMIDI conversion — delegated to engine/xmidi.zig
const xmidi = @import("engine/xmidi.zig");
pub const parseSmfTimeSigNumerator = xmidi.parseSmfTimeSigNumerator;
pub const xmidiToSmf = xmidi.xmidiToSmf;
pub const xmidiBareToSmf = xmidi.xmidiBareToSmf;
comptime {
    _ = @import("main_test.zig");
}

// --- Lifecycle functions ---
// These encapsulate the startup/shutdown and driver open/close sequences so that
// both the standard API (AIL_startup, AIL_open_digital_driver, …) and the Quick
// API (AIL_quick_startup, AIL_quick_shutdown) share the same code path without
// lateral dependencies between api/ modules.

pub fn startup() void {
    if (startup_provider != null) return;
    log("startup: ensureStartupTime\n", .{});
    ensureStartupTime();
    log("startup: global_allocator\n", .{});
    global_allocator = default_allocator;
    log("startup: Provider.init\n", .{});
    const p = Provider.init(global_allocator.?, null) catch {
        log("startup: Provider.init FAILED\n", .{});
        return;
    };
    log("startup: get_ASI_INTERFACE\n", .{});
    const src = get_ASI_INTERFACE();
    log("startup: alloc heap_src\n", .{});
    const heap_src = global_allocator.?.alloc(RIB_INTERFACE_ENTRY, src.len) catch {
        log("startup: heap alloc FAILED\n", .{});
        return;
    };
    log("startup: memcpy\n", .{});
    @memcpy(heap_src, &src);

    log("startup: registerInterface\n", .{});
    p.registerInterface("ASI codec", @intCast(heap_src.len), heap_src.ptr) catch {
        log("startup: registerInterface FAILED\n", .{});
        return;
    };
    // Also register the same built-in decoder under "ASI stream" — games
    // query RIB_enumerate_providers("ASI stream", ...) to decide whether
    // MP3/OGG streaming is available.  The built-in miniaudio decoder
    // handles MP3, OGG, WAV and FLAC natively, so no external .asi plugins
    // are required.
    const heap_src2 = global_allocator.?.alloc(RIB_INTERFACE_ENTRY, src.len) catch {
        log("startup: heap alloc for ASI stream FAILED\n", .{});
        global_allocator.?.free(heap_src);
        return;
    };
    @memcpy(heap_src2, &src);
    p.registerInterface("ASI stream", @intCast(heap_src2.len), heap_src2.ptr) catch {
        log("startup: registerInterface ASI stream FAILED\n", .{});
    };
    global_allocator.?.free(heap_src2);
    log("startup: free heap_src\n", .{});
    global_allocator.?.free(heap_src);
    startup_provider = p;
    // Scan for external .asi plugins — games may ship proprietary codecs that
    // we don't replace yet.  These supplement (not replace) the built-in provider.
    log("startup: scanning CWD for .asi plugins\n", .{});
    const n = loadApplicationProviders(".");
    if (n > 0) log("startup: loaded {d} external plugin(s) from CWD\n", .{n});
}

pub fn shutdown() void {
    if (last_digital_driver) |d| {
        last_digital_driver = null;
        d.deinit();
    }
    if (last_midi_driver) |m| {
        last_midi_driver = null;
        m.deinit();
    }
    if (startup_provider) |p| {
        p.deinit();
        startup_provider = null;
    }
}

pub fn openDigitalDriver(frequency: u32, bits: i32, channels: i32) ?*DigitalDriver {
    clearLastError();
    const ch: u32 = if (channels <= 0) 2 else @intCast(channels);
    const driver = DigitalDriver.init(global_allocator.?, frequency, bits, ch) catch {
        setLastError("Failed to initialize digital driver");
        return null;
    };
    const rd = getRedistDirectory();
    if (rd.len > 0) driver.loadAllAsi(rd);
    return driver;
}

pub fn closeDigitalDriver(driver: *DigitalDriver) void {
    if (last_digital_driver == driver) last_digital_driver = null;
    driver.deinit();
}

pub fn openMidiDriver() ?*MidiDriver {
    return MidiDriver.init(global_allocator.?) catch |err| {
        log("openMidiDriver: {any}\n", .{err});
        return null;
    };
}

pub fn closeMidiDriver(driver: *MidiDriver) void {
    if (last_midi_driver == driver) last_midi_driver = null;
    // Stop every Sequence using this driver BEFORE freeing the soundfont — the
    // audio thread's onRead dereferences driver.soundfont, so any still-running
    // sound would UAF on the next render after deinit.
    global_sequences_mutex.lock();
    for (global_sequences.items) |seq| {
        if (seq.driver == driver) {
            seq.is_playing = false;
            if (seq.is_initialized) {
                _ = ma.ma_sound_stop(&seq.sound);
                ma.ma_sound_uninit(&seq.sound);
                seq.is_initialized = false;
            }
        }
    }
    global_sequences_mutex.unlock();
    driver.deinit();
}

/// Detect the size of an audio file from its header bytes.
/// Returns 0 if the format is unrecognized.
/// For streaming formats (OGG, MP3, FLAC) where size cannot be determined
/// from the header alone, returns a 16 MB sentinel value.
pub fn detectAudioSize(raw: [*]const u8) usize {
    // RIFF/WAVE: "RIFF" + 4-byte little-endian body size
    if (raw[0] == 'R' and raw[1] == 'I' and raw[2] == 'F' and raw[3] == 'F') {
        const body = std.mem.readInt(u32, raw[4..8], .little);
        return @as(usize, body) + 8;
    }
    // IFF/FORM container (AIFF, XMIDI, etc.): "FORM" + 4-byte big-endian body size
    if (raw[0] == 'F' and raw[1] == 'O' and raw[2] == 'R' and raw[3] == 'M') {
        const body = std.mem.readInt(u32, raw[4..8], .big);
        return @as(usize, body) + 8;
    }
    // Standard MIDI (MThd): walk track chunks to compute total size
    if (raw[0] == 'M' and raw[1] == 'T' and raw[2] == 'h' and raw[3] == 'd') {
        return detectMidiSize(raw);
    }
    // OGG: starts with "OggS" — streaming format, size unknown from header
    if (raw[0] == 'O' and raw[1] == 'g' and raw[2] == 'g' and raw[3] == 'S') {
        return streaming_sentinel_size;
    }
    // MP3: sync word (0xFF 0xE0+) or ID3 tag
    if ((raw[0] == 0xFF and (raw[1] & 0xE0) == 0xE0) or
        (raw[0] == 'I' and raw[1] == 'D' and raw[2] == '3'))
    {
        return streaming_sentinel_size;
    }
    // FLAC: "fLaC"
    if (raw[0] == 'f' and raw[1] == 'L' and raw[2] == 'a' and raw[3] == 'C') {
        return streaming_sentinel_size;
    }
    return 0;
}

pub fn detectMidiSize(raw: [*]const u8) usize {
    // FORM header (IFF/XMIDI): 4-byte tag + 4-byte big-endian body size
    if (raw[0] == 'F' and raw[1] == 'O' and raw[2] == 'R' and raw[3] == 'M') {
        const body = std.mem.readInt(u32, raw[4..8], .big);
        return @as(usize, body) + 8;
    }
    // Check for MThd header (Standard MIDI Format) - compute size from all track chunks.
    // Cap the walk at streaming_sentinel_size to prevent reading past the caller's
    // buffer when the file is corrupt (e.g. fabricated num_tracks or trk_len).
    if (raw[0] == 'M' and raw[1] == 'T' and raw[2] == 'h' and raw[3] == 'd') {
        const hdr_size = std.mem.readInt(u32, raw[4..8], .big);
        const num_tracks = std.mem.readInt(u16, raw[10..12], .big);
        var pos: usize = 8 + hdr_size;
        var tracks_found: u16 = 0;
        while (tracks_found < num_tracks) {
            // Stop walking if we've exceeded the bounded sentinel — a corrupt
            // or malicious SMF would otherwise read arbitrary memory.
            if (pos + 8 > streaming_sentinel_size) return streaming_sentinel_size;
            const trk_raw = raw + pos + 4;
            const trk_len = std.mem.readInt(u32, trk_raw[0..4], .big);
            if (trk_len > streaming_sentinel_size - pos - 8) return streaming_sentinel_size;
            pos += 8 + trk_len;
            tracks_found += 1;
        }
        return pos;
    }
    return streaming_sentinel_size;
}

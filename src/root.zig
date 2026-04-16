const std = @import("std");
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

// --- Engine type re-exports ---

const digital_mod = @import("engine/digital.zig");
pub const DigitalDriver = digital_mod.DigitalDriver;
pub const Sample = digital_mod.Sample;
pub const Sample3D = digital_mod.Sample3D;
pub const SampleStatus = digital_mod.SampleStatus;
pub const SamplePcmFormat = digital_mod.SamplePcmFormat;
const audio_encoding = @import("engine/audio_encoding.zig");
pub const buildWavFromPcm = audio_encoding.buildWavFromPcm;
pub const buildAdpcmWav = audio_encoding.buildAdpcmWav;

const midi_mod = @import("engine/midi.zig");
pub const MidiDriver = midi_mod.MidiDriver;
pub const Sequence = midi_mod.Sequence;
pub const MidiStatus = midi_mod.MidiStatus;
pub const locked_channels = &midi_mod.locked_channels;
pub const lockChannel = midi_mod.lockChannel;
pub const releaseChannel = midi_mod.releaseChannel;

pub const Timer = @import("engine/timer.zig").Timer;
pub const Filter = @import("engine/filter.zig").Filter;
pub const Input = @import("engine/input.zig").Input;

const redbook_mod = @import("engine/redbook.zig");
pub const Redbook = redbook_mod.Redbook;
pub const RedbookStatus = redbook_mod.RedbookStatus;

const rib_mod = @import("rib/provider.zig");
pub const Provider = rib_mod.Provider;
pub const getCurrentLoadingProvider = rib_mod.getCurrentLoadingProvider;
pub const Interface = rib_mod.Interface;
pub const RIB_INTERFACE_ENTRY = rib_mod.RIB_INTERFACE_ENTRY;
pub const RIB_ENTRY_TYPE = rib_mod.RIB_ENTRY_TYPE;
pub const RIB_DATA_TYPE = rib_mod.RIB_DATA_TYPE;
pub const HPROVIDER = rib_mod.HPROVIDER;
pub const RIB_alloc_provider_handle_ptr = rib_mod.RIB_alloc_provider_handle_ptr;
pub const RIB_register_interface_ptr = rib_mod.RIB_register_interface_ptr;
pub const RIB_unregister_interface_ptr = rib_mod.RIB_unregister_interface_ptr;
pub const RIB_Main_ptr = rib_mod.RIB_Main_ptr;

const audio_detect = @import("engine/audio_detect.zig");
pub const streaming_sentinel_size = audio_detect.streaming_sentinel_size;
pub const detectAudioSize = audio_detect.detectAudioSize;
pub const detectMidiSize = audio_detect.detectMidiSize;

pub const get_ASI_INTERFACE = @import("engine/asi.zig").get_ASI_INTERFACE;

const xmidi = @import("engine/xmidi.zig");
pub const parseSmfTimeSigNumerator = xmidi.parseSmfTimeSigNumerator;
pub const xmidiToSmf = xmidi.xmidiToSmf;
pub const xmidiBareToSmf = xmidi.xmidiBareToSmf;

// --- Constants and types ---

pub const deg2rad = std.math.pi / 180.0;

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

// --- Allocator ---
// Lives here so all modules can reach it via `openmiles` without a
// bidirectional dependency on main.zig.

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
pub const default_allocator = gpa.allocator();
pub var global_allocator: std.mem.Allocator = default_allocator;

// --- Error state ---

pub var last_error_buf: [256:0]u8 = [_:0]u8{0} ** 256;
pub var last_file_error_buf: [256:0]u8 = [_:0]u8{0} ** 256;
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

// --- Custom file I/O callbacks ---

pub var cb_file_open: ?*const fn ([*:0]const u8, *u32) callconv(.winapi) ?*anyopaque = null;
pub var cb_file_close: ?*const fn (?*anyopaque) callconv(.winapi) void = null;
pub var cb_file_read: ?*const fn (?*anyopaque, *anyopaque, u32) callconv(.winapi) u32 = null;
pub var cb_file_seek: ?*const fn (?*anyopaque, i32) callconv(.winapi) i32 = null;

/// If file callbacks are set, open the file via the game's VFS, read it all into
/// a freshly-allocated slice (caller must free with global_allocator), and close it.
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

    const buf = try global_allocator.alloc(u8, file_size);
    errdefer global_allocator.free(buf);
    const bytes_read = read_fn(handle, buf.ptr, file_size);
    if (bytes_read != file_size) return error.ReadFailed;
    return buf;
}

// --- Provider state ---

pub var startup_provider: ?*Provider = null;
pub var asi_temp_counter: u32 = 0;

var global_providers: std.ArrayListUnmanaged(*Provider) = .{};

pub fn getAllProviders() []*Provider {
    return global_providers.items;
}

pub fn isPluginExtension(name: []const u8) bool {
    return name.len >= 4 and (std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".asi") or
        std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".m3d") or
        std.ascii.eqlIgnoreCase(name[name.len - 4 ..], ".flt"));
}

pub fn isSafePluginFilename(name: []const u8) bool {
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    if (std.mem.indexOfScalar(u8, name, '\\') != null) return false;
    return true;
}

pub fn loadApplicationProviders(dir: []const u8) i32 {
    const alloc = global_allocator;
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
        if (!isSafePluginFilename(name)) continue;
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

// --- Timer state ---

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
    global_timers_mutex.lock();
    const items = global_timers.items;
    const snapshot = global_allocator.dupe(*Timer, items) catch {
        for (items) |t| {
            t.stop();
            t.allocator.destroy(t);
        }
        global_timers.items.len = 0;
        global_timers_mutex.unlock();
        return;
    };
    global_timers.items.len = 0;
    global_timers_mutex.unlock();
    defer global_allocator.free(snapshot);
    for (snapshot) |t| {
        t.stop();
        t.allocator.destroy(t);
    }
}

// --- Driver state ---

pub var last_digital_driver: ?*DigitalDriver = null;
pub var last_midi_driver: ?*MidiDriver = null;

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

// --- Sequence state ---

var global_sequences: std.ArrayListUnmanaged(*Sequence) = .{};
var global_sequences_mutex: std.Thread.Mutex = .{};

pub fn registerSequence(seq: *Sequence) void {
    global_sequences_mutex.lock();
    defer global_sequences_mutex.unlock();
    global_sequences.append(global_allocator, seq) catch {
        log("registerSequence: allocation failed, sequence will not be tracked\n", .{});
    };
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

// --- Redist directory ---

var redist_directory: [256:0]u8 = [_:0]u8{0} ** 256;

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

// --- Preferences ---

pub const Pref = enum(u32) {
    DIG_RESAMPLING_TOLERANCE = 0,
    DIG_MIXER_CHANNELS = 1,
    DIG_DEFAULT_VOLUME = 2,
    MDI_SERVICE_RATE = 3,
    MDI_SEQUENCES = 4,
    MDI_DEFAULT_VOLUME = 5,
    MDI_QUANT_ADVANCE = 6,
    MDI_ALLOW_LOOP_BRANCHING = 7,
    MDI_DEFAULT_BEND_RANGE = 8,
    MDI_DOUBLE_NOTE_OFF = 9,
    MDI_SYSEX_BUFFER_SIZE = 10,
    DIG_OUTPUT_BUFFER_SIZE = 11,
    AIL_MM_PERIOD = 12,
    DIG_ENABLE_RESAMPLE_FILTER = 31,
    DIG_DECODE_BUFFER_SIZE = 32,
};

var preferences: [512]i32 = init: {
    var p = [_]i32{0} ** 512;
    p[@intFromEnum(Pref.DIG_RESAMPLING_TOLERANCE)] = 131;
    p[@intFromEnum(Pref.DIG_MIXER_CHANNELS)] = 64;
    p[@intFromEnum(Pref.DIG_DEFAULT_VOLUME)] = 127;
    p[@intFromEnum(Pref.MDI_SERVICE_RATE)] = 120;
    p[@intFromEnum(Pref.MDI_SEQUENCES)] = 8;
    p[@intFromEnum(Pref.MDI_DEFAULT_VOLUME)] = 127;
    p[@intFromEnum(Pref.MDI_QUANT_ADVANCE)] = 1;
    p[@intFromEnum(Pref.MDI_ALLOW_LOOP_BRANCHING)] = 0;
    p[@intFromEnum(Pref.MDI_DEFAULT_BEND_RANGE)] = 2;
    p[@intFromEnum(Pref.MDI_DOUBLE_NOTE_OFF)] = 0;
    p[@intFromEnum(Pref.MDI_SYSEX_BUFFER_SIZE)] = 1536;
    p[@intFromEnum(Pref.DIG_OUTPUT_BUFFER_SIZE)] = 49152;
    p[@intFromEnum(Pref.AIL_MM_PERIOD)] = 5;
    p[@intFromEnum(Pref.DIG_ENABLE_RESAMPLE_FILTER)] = 1;
    p[@intFromEnum(Pref.DIG_DECODE_BUFFER_SIZE)] = 2048;
    break :init p;
};

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

// --- Volume/pan conversion ---

/// Convert an MSS 0-127 volume value to a linear gain (0.0-1.0) using a
/// perceptual curve that approximates the original Miles Sound System
/// attenuation behavior (~60 dB dynamic range).
///
/// The original MSS library used a heavily weighted scale where low values
/// (e.g., 30/127) produced dramatic attenuation. A cubic power curve
/// `(v/127)^3` closely matches this: value 30 → gain ~0.013 (vs linear ~0.236).
pub fn mssVolumeToGain(value: i32) f32 {
    if (value <= 0) return 0.0;
    if (value >= 127) return 1.0;
    return volume_to_gain_table[@intCast(value)];
}

/// Inverse of mssVolumeToGain: convert a linear gain back to MSS 0-127.
/// Binary-searches the precomputed gain table, then picks the nearest neighbor.
pub fn gainToMssVolume(gain: f32) i32 {
    if (gain <= 0.0) return 0;
    if (gain >= 1.0) return 127;
    var lo: i32 = 1;
    var hi: i32 = 126;
    while (lo <= hi) {
        const mid = lo + @divTrunc(hi - lo, 2);
        const mid_gain = volume_to_gain_table[@intCast(mid)];
        if (gain < mid_gain) {
            hi = mid - 1;
        } else {
            lo = mid + 1;
        }
    }
    if (hi <= 0) return if (lo <= 0) 0 else lo;
    const lo_clamped: usize = @intCast(@min(lo, 127));
    const g_lo = volume_to_gain_table[@intCast(hi)];
    const g_hi = volume_to_gain_table[lo_clamped];
    return if (gain - g_lo <= g_hi - gain) hi else @intCast(lo_clamped);
}

const volume_to_gain_table: [128]f32 = blk: {
    var table: [128]f32 = undefined;
    table[0] = 0.0;
    for (1..128) |i| {
        const n: f32 = @as(f32, @floatFromInt(i)) / 127.0;
        table[i] = n * n * n;
    }
    break :blk table;
};

/// Convert a linear pan (-1.0 left .. +1.0 right) to MSS 0-127 range.
pub fn panToMss(pan: f32) i32 {
    return @min(127, @max(0, @as(i32, @intFromFloat((pan * 64.0) + 64.0))));
}

// --- Startup time ---

var startup_ns: i64 = 0;
var startup_ns_mutex: std.Thread.Mutex = .{};
var startup_ns_ready: bool = false;

pub fn ensureStartupTime() void {
    if (@atomicLoad(bool, &startup_ns_ready, .acquire)) return;
    startup_ns_mutex.lock();
    defer startup_ns_mutex.unlock();
    if (!startup_ns_ready) {
        startup_ns = @intCast(std.time.nanoTimestamp());
        @atomicStore(bool, &startup_ns_ready, true, .release);
    }
}

pub fn getMsCount() u32 {
    ensureStartupTime();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const elapsed_ns: u64 = @intCast(@max(0, now_ns - startup_ns));
    return @truncate(elapsed_ns / std.time.ns_per_ms);
}

pub fn getUsCount() u32 {
    ensureStartupTime();
    const now_ns: i64 = @intCast(std.time.nanoTimestamp());
    const elapsed_ns: u64 = @intCast(@max(0, now_ns - startup_ns));
    return @truncate(elapsed_ns / std.time.ns_per_us);
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
    log("startup: Provider.init\n", .{});
    const p = Provider.init(global_allocator, null) catch {
        log("startup: Provider.init FAILED\n", .{});
        return;
    };
    log("startup: get_ASI_INTERFACE\n", .{});
    var src = get_ASI_INTERFACE();

    log("startup: registerInterface\n", .{});
    p.registerInterface("ASI codec", @intCast(src.len), &src) catch {
        log("startup: registerInterface FAILED\n", .{});
        p.deinit();
        return;
    };
    // Also register the same built-in decoder under "ASI stream" — games
    // query RIB_enumerate_providers("ASI stream", ...) to decide whether
    // MP3/OGG streaming is available.  The built-in miniaudio decoder
    // handles MP3, OGG, WAV and FLAC natively, so no external .asi plugins
    // are required.
    p.registerInterface("ASI stream", @intCast(src.len), &src) catch {
        log("startup: registerInterface ASI stream FAILED\n", .{});
    };
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
    for (global_providers.items) |p| p.deinit();
    global_providers.deinit(global_allocator);
    global_providers = .{};
    if (startup_provider) |p| {
        p.deinit();
        startup_provider = null;
    }
    logger.deinit();
}

pub fn openDigitalDriver(frequency: u32, bits: i32, channels: i32) ?*DigitalDriver {
    clearLastError();
    if (last_digital_driver) |existing| return existing;
    const ch: u32 = if (channels <= 0) 2 else @intCast(channels);
    const driver = DigitalDriver.init(global_allocator, frequency, bits, ch) catch {
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
    clearLastError();
    if (last_midi_driver) |existing| return existing;
    return MidiDriver.init(global_allocator) catch |err| {
        log("openMidiDriver: {any}\n", .{err});
        setLastError("Failed to initialize MIDI driver");
        return null;
    };
}

pub fn closeMidiDriver(driver: *MidiDriver) void {
    if (last_midi_driver == driver) last_midi_driver = null;
    // Snapshot sequences to stop, then release mutex before the potentially
    // blocking stopAndUninit calls to avoid holding the lock during audio
    // thread synchronization.
    global_sequences_mutex.lock();
    const snapshot = global_allocator.dupe(*Sequence, global_sequences.items) catch {
        // Fallback: stop sequences while holding the lock (less ideal but correct).
        for (global_sequences.items) |seq| {
            if (seq.driver == driver) seq.stopAndUninit();
        }
        global_sequences_mutex.unlock();
        driver.deinit();
        return;
    };
    global_sequences_mutex.unlock();
    defer global_allocator.free(snapshot);
    for (snapshot) |seq| {
        if (seq.driver == driver) seq.stopAndUninit();
    }
    driver.deinit();
}

comptime {
    _ = @import("main_test.zig");
}

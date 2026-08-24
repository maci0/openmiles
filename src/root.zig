const std = @import("std");
const logger = @import("utils/logger.zig");

pub const log = logger.log;
pub const fs_compat = @import("utils/fs_compat.zig");

/// Target MSS version (major*10+minor, e.g. 66 = 6.6), selected via -Dmss-version.
pub const mss_version: u16 = @import("build_options").mss_version;
pub const DynLib = @import("utils/dynlib.zig").DynLib;

pub const ma = @import("ma_c");
pub const tsf = @import("tsf_c");

/// Single-threaded Io implementation suitable for sync-primitive and fs usage
/// inside this DLL. The DLL has no `main()` to receive a `std.process.Init`,
/// so we point at the stdlib's preallocated single-threaded instance.
/// Mutex lock/unlock and futex primitives do not require async/concurrent
/// facilities, so this is safe for our use.
pub const io: std.Io = std.Io.Threaded.global_single_threaded.io();

// --- Engine type re-exports ---

const digital_mod = @import("engine/digital.zig");
pub const DigitalDriver = digital_mod.DigitalDriver;
pub const Sample = digital_mod.Sample;
pub const MixBus = digital_mod.MixBus;
pub const LimiterNode = digital_mod.LimiterNode;
pub const CompressorNode = digital_mod.CompressorNode;
pub const Sample3D = digital_mod.Sample3D;
pub const SampleStatus = digital_mod.SampleStatus;
pub const SamplePcmFormat = digital_mod.SamplePcmFormat;
pub const FalloffGraphPoint = digital_mod.FalloffGraphPoint;
pub const FalloffKind = digital_mod.FalloffKind;
pub const max_falloff_points = digital_mod.max_falloff_points;
const audio_encoding = @import("engine/audio_encoding.zig");
pub const buildWavFromPcm = audio_encoding.buildWavFromPcm;
pub const buildAdpcmWav = audio_encoding.buildAdpcmWav;
pub const wrapAdpcmInWav = audio_encoding.wrapAdpcmInWav;
pub const ima_step_table = audio_encoding.ima_step_table;
pub const ima_index_table = audio_encoding.ima_index_table;

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
pub const detectFileType = audio_detect.detectFileType;
pub const wavInfoBounded = audio_detect.wavInfoBounded;

pub const dls_container = @import("engine/dls_container.zig");
pub const StreamSource = @import("engine/stream_buffer.zig").StreamSource;
pub const soundbank = @import("engine/soundbank.zig");
pub const Bank = soundbank.Bank;
pub const event = @import("engine/event.zig");
pub const mp3 = @import("engine/mp3.zig");
pub const speaker = @import("engine/speaker.zig");

pub const get_ASI_INTERFACE = @import("engine/asi.zig").get_ASI_INTERFACE;

const xmidi = @import("engine/xmidi.zig");
pub const parseSmfTimeSigNumerator = xmidi.parseSmfTimeSigNumerator;
pub const xmidiToSmf = xmidi.xmidiToSmf;
pub const xmidiBareToSmf = xmidi.xmidiBareToSmf;

// --- Constants and types ---

pub const deg2rad = std.math.pi / 180.0;

// AIL_MAX_FILE_HEADER_SIZE bounds how far AIL_file_type scans for an MPEG frame
// sync (miscutil.cpp clamps the scan length to it). MSS 7.0 doubled it from 4096
// to 8192 — verified by disassembling AIL_file_type in the reference DLLs: 6.5h
// clamps with the immediate 0x1000, while 7.0k and 8.0e use 0x2000. A too-large
// limit can false-positive a non-MPEG file whose junk happens to contain a sync
// pattern past the real cutoff, so the value must match the target version.
pub const max_file_header_size: usize = if (mss_version >= 70) 8192 else 4096;

// MSS 8.0 added a `channel_mask` (U32) field between `channels` and `samples`
// (for multichannel WAVE_FORMAT_EXTENSIBLE data). Confirmed by disassembling
// AIL_API_set_sample_info across the reference DLLs: 8.0e and 9.1d read
// channel_mask at info+0x18 (cmp ~0U), do `channels << 16` for the multichannel
// DIG_F path, and read block_size at info+0x20 — the 10-field/40-byte layout.
// 7.0k has no channel_mask, no multichannel shift, and reads block_size at
// info+0x1c — the 9-field/36-byte layout, matching the 3.x/6.1 headers. So the
// boundary is 8.0, not 9.0.
pub const AILSOUNDINFO = if (mss_version >= 80) extern struct {
    format: i32 = 0,
    data_ptr: ?*const anyopaque = null,
    data_len: u32 = 0,
    rate: u32 = 0,
    bits: i32 = 0,
    channels: i32 = 0,
    channel_mask: u32 = 0,
    samples: u32 = 0,
    block_size: u32 = 0,
    initial_ptr: ?*const anyopaque = null,
} else extern struct {
    format: i32 = 0,
    data_ptr: ?*const anyopaque = null,
    data_len: u32 = 0,
    rate: u32 = 0,
    bits: i32 = 0,
    channels: i32 = 0,
    samples: u32 = 0,
    block_size: u32 = 0,
    initial_ptr: ?*const anyopaque = null,
};

/// ADPCMDATA (mss.h): per-stream IMA ADPCM decode state. Only used here to size
/// AILMIXINFO correctly; UINTa fields are pointer-sized.
pub const ADPCMDATA = extern struct {
    blocksize: u32 = 0,
    extrasamples: u32 = 0,
    blockleft: u32 = 0,
    step: u32 = 0,
    savesrc: usize = 0,
    sample: u32 = 0,
    destend: usize = 0,
    srcend: usize = 0,
    samplesL: u32 = 0,
    samplesR: u32 = 0,
    moresamples: [16]u16 = [_]u16{0} ** 16,
};
comptime {
    // ADPCMDATA sizes the mss_adpcm member of AILMIXINFO, so its layout sets that
    // struct's stride. Lock the mss.h field order (UINTa savesrc/destend/srcend are
    // pointer-sized; the rest U32 + U16[16]).
    const fields = @typeInfo(ADPCMDATA).@"struct".fields;
    const order = [_][]const u8{
        "blocksize",   "extrasamples", "blockleft", "step",     "savesrc",
        "sample",      "destend",      "srcend",    "samplesL", "samplesR",
        "moresamples",
    };
    if (fields.len != order.len) @compileError("ADPCMDATA field count drifted");
    for (order, 0..) |fname, i| {
        if (!std.mem.eql(u8, fields[i].name, fname)) @compileError("ADPCMDATA field order drifted at " ++ fname);
    }
}

/// AILMIXINFO (mss.h): one input to the software mixer. Begins with an
/// AILSOUNDINFO, so an AILSOUNDINFO* and an AILMIXINFO* coincide for the first
/// source; the full layout is needed to stride an array of sources.
pub const AILMIXINFO = extern struct {
    Info: AILSOUNDINFO = .{},
    mss_adpcm: ADPCMDATA = .{},
    src_fract: u32 = 0,
    left_val: i32 = 0,
    right_val: i32 = 0,
};
comptime {
    // AIL_size_processed_digital_audio / AIL_process_digital_audio take an array
    // of AILMIXINFO and stride it by @sizeOf, and they alias an AILSOUNDINFO* over
    // the first source's Info -- so Info MUST be at offset 0 and the field order
    // is ABI. Lock both (a leading-field change would mis-stride every source).
    if (@offsetOf(AILMIXINFO, "Info") != 0) @compileError("AILMIXINFO.Info must be at offset 0 (AILSOUNDINFO* aliases AILMIXINFO*)");
    const fields = @typeInfo(AILMIXINFO).@"struct".fields;
    const order = [_][]const u8{ "Info", "mss_adpcm", "src_fract", "left_val", "right_val" };
    if (fields.len != order.len) @compileError("AILMIXINFO field count drifted");
    for (order, 0..) |fname, i| {
        if (!std.mem.eql(u8, fields[i].name, fname)) @compileError("AILMIXINFO field order drifted at " ++ fname);
    }
}

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

var gpa_instance: std.heap.DebugAllocator(.{}) = .init;
pub const default_allocator = gpa_instance.allocator();
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

// MSS file callbacks (mss.h). FileHandle is a U32 token (4 bytes on x86, same
// width as a pointer). open RETURNS the file length and fills *FileHandle;
// seek takes (handle, offset, type) where type is 0=SET, 1=CUR, 2=END.
pub const SEEK_SET: u32 = 0;
pub const SEEK_END: u32 = 2;
pub var cb_file_open: ?*const fn ([*:0]const u8, *u32) callconv(.winapi) u32 = null;
pub var cb_file_close: ?*const fn (u32) callconv(.winapi) void = null;
pub var cb_file_read: ?*const fn (u32, *anyopaque, u32) callconv(.winapi) u32 = null;
pub var cb_file_seek: ?*const fn (u32, i32, u32) callconv(.winapi) i32 = null;

/// If file callbacks are set, open the file via the game's VFS, read it all into
/// a freshly-allocated slice (caller must free with global_allocator), and close it.
pub fn fileCallbackReadAll(filename: [*:0]const u8) ![]u8 {
    const open_fn = cb_file_open orelse return error.NoCallbacks;
    const close_fn = cb_file_close orelse return error.NoCallbacks;
    const read_fn = cb_file_read orelse return error.NoCallbacks;

    // open returns the file length and writes the handle to the out-param;
    // a 0 length means the file could not be opened.
    var handle: u32 = 0;
    var file_size = open_fn(filename, &handle);
    if (file_size == 0) {
        // Some VFS return 0 from open and require a seek-to-end to learn the size.
        if (cb_file_seek) |seek_fn| {
            const end_pos = seek_fn(handle, 0, SEEK_END);
            if (end_pos > 0) {
                file_size = @intCast(end_pos);
                _ = seek_fn(handle, 0, SEEK_SET);
            }
        }
        if (file_size == 0) {
            close_fn(handle);
            return error.FileNotFound;
        }
    }
    defer close_fn(handle);

    const buf = try global_allocator.alloc(u8, file_size);
    errdefer global_allocator.free(buf);
    const bytes_read = read_fn(handle, buf.ptr, file_size);
    if (bytes_read != file_size) return error.ReadFailed;
    return buf;
}

/// Read a whole file via the app's file callbacks when set, otherwise directly
/// from the filesystem. Caller frees the returned buffer with global_allocator.
pub fn readWholeFile(path: []const u8) ![]u8 {
    if (cb_file_open != null) {
        var zbuf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (path.len >= zbuf.len) return error.NameTooLong;
        @memcpy(zbuf[0..path.len], path);
        zbuf[path.len] = 0;
        return fileCallbackReadAll(@ptrCast(&zbuf));
    }
    const f = fs_compat.openFile(io, path, .{}) catch return error.FileNotFound;
    defer f.close(io);
    const sz = f.length(io) catch return error.UnknownSize;
    if (sz == 0 or sz > 256 * 1024 * 1024) return error.BadSize;
    const buf = try global_allocator.alloc(u8, @intCast(sz));
    errdefer global_allocator.free(buf);
    const n = f.readPositionalAll(io, buf, 0) catch return error.ReadFailed;
    if (n < buf.len) return error.ReadFailed;
    return buf;
}

// --- AIL file services (shared by api/file.zig and api/v9.zig) ---

/// AIL_file_read core: read a whole file into `dest` (zero-padding short
/// reads), or into a fresh malloc'd buffer when `dest` is null (free with
/// AIL_mem_free_lock). Returns null and sets the file error on failure.
pub fn ailFileRead(filename: [*:0]const u8, dest: ?*anyopaque) ?*anyopaque {
    clearFileError();
    if (cb_file_open != null) {
        const buf = fileCallbackReadAll(filename) catch null;
        if (buf) |b| {
            defer global_allocator.free(b);
            if (dest) |d| {
                @memcpy(@as([*]u8, @ptrCast(@alignCast(d)))[0..b.len], b);
                return d;
            }
            const out: [*]u8 = @ptrCast(std.c.malloc(b.len) orelse {
                setFileError("Out of memory");
                return null;
            });
            @memcpy(out[0..b.len], b);
            return out;
        }
        setFileError("File not found");
        return null;
    }
    const path = std.mem.span(filename);
    const file = fs_compat.openFile(io, path, .{}) catch {
        setFileError("File not found");
        return null;
    };
    defer file.close(io);
    const file_len = file.length(io) catch {
        setFileError("Stat failed");
        return null;
    };
    if (file_len == 0) return null;
    const size: usize = @intCast(file_len);
    if (dest) |d| {
        const buf: [*]u8 = @ptrCast(@alignCast(d));
        const n = file.readPositionalAll(io, buf[0..size], 0) catch {
            setFileError("Read error");
            return null;
        };
        if (n < size) {
            @memset(buf[n..size], 0);
        }
        return d;
    } else {
        const buf: [*]u8 = @ptrCast(std.c.malloc(size) orelse {
            setFileError("Out of memory");
            return null;
        });
        const n = file.readPositionalAll(io, buf[0..size], 0) catch {
            std.c.free(buf);
            setFileError("Read error");
            return null;
        };
        if (n < size) {
            @memset(buf[n..size], 0);
        }
        return buf;
    }
}

/// AIL_file_size core: size in bytes via the app's callbacks when set,
/// otherwise from the filesystem. Returns 0 and sets the file error on failure.
pub fn ailFileSize(filename: [*:0]const u8) u32 {
    clearFileError();
    if (cb_file_open != null) {
        const open_fn = cb_file_open.?;
        const close_fn = cb_file_close orelse return 0;
        // open returns the file length and fills the handle out-param.
        var handle: u32 = 0;
        const size = open_fn(filename, &handle);
        if (size == 0) {
            setFileError("File not found");
            return 0;
        }
        close_fn(handle);
        return size;
    }
    const path = std.mem.span(filename);
    const file = fs_compat.openFile(io, path, .{}) catch {
        setFileError("File not found");
        return 0;
    };
    defer file.close(io);
    const file_len = file.length(io) catch {
        setFileError("Stat failed");
        return 0;
    };
    if (file_len == 0) return 0;
    return @intCast(@min(file_len, std.math.maxInt(u32)));
}

// --- Provider state ---

pub var startup_provider: ?*Provider = null;
pub var asi_temp_counter: u32 = 0;

var global_providers: std.ArrayList(*Provider) = .empty;

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
    var d = fs_compat.openDir(io, dir, .{ .iterate = true }) catch |err| {
        log("loadApplicationProviders: failed to open directory '{s}': {any}\n", .{ dir, err });
        return 0;
    };
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |entry| {
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

pub var global_timers: std.ArrayList(*Timer) = .empty;
pub var global_timers_mutex: std.Io.Mutex = .init;

pub fn startAllTimers() void {
    global_timers_mutex.lockUncancelable(io);
    defer global_timers_mutex.unlock(io);
    for (global_timers.items) |t| t.start();
}

pub fn stopAllTimers() void {
    global_timers_mutex.lockUncancelable(io);
    defer global_timers_mutex.unlock(io);
    for (global_timers.items) |t| t.stop();
}

pub fn releaseAllTimers() void {
    global_timers_mutex.lockUncancelable(io);
    const items = global_timers.items;
    const snapshot = global_allocator.dupe(*Timer, items) catch {
        for (items) |t| {
            t.stop();
            t.allocator.destroy(t);
        }
        global_timers.items.len = 0;
        global_timers_mutex.unlock(io);
        return;
    };
    global_timers.items.len = 0;
    global_timers_mutex.unlock(io);
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

var global_sequences: std.ArrayList(*Sequence) = .empty;
var global_sequences_mutex: std.Io.Mutex = .init;

pub fn registerSequence(seq: *Sequence) void {
    global_sequences_mutex.lockUncancelable(io);
    defer global_sequences_mutex.unlock(io);
    global_sequences.append(global_allocator, seq) catch {
        log("registerSequence: allocation failed, sequence will not be tracked\n", .{});
    };
}

pub fn unregisterSequence(seq: *Sequence) void {
    global_sequences_mutex.lockUncancelable(io);
    defer global_sequences_mutex.unlock(io);
    for (global_sequences.items, 0..) |s, i| {
        if (s == seq) {
            _ = global_sequences.swapRemove(i);
            break;
        }
    }
}

pub fn getActiveSequenceCount() u32 {
    global_sequences_mutex.lockUncancelable(io);
    defer global_sequences_mutex.unlock(io);
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

/// NUL-terminated pointer to the stored redist directory (for the char* return
/// of AIL_set_redist_directory).
pub fn redistDirectoryZ() [*:0]const u8 {
    return &redist_directory;
}

// --- Preferences ---

// Preference numbers for the MSS 3.x..8.x ABI (mss.h). 9.x renumbered the whole
// table; see the version switch in `preferences` below. This enum is the old
// layout and is used only to seed the old-layout defaults.
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

// The preference *numbers* are part of the ABI (games pass the mss.h constant as
// an integer to AIL_set/get_preference). MSS 9.0 renumbered the entire table:
// 3.x..8.x share one layout (DIG_MIXER_CHANNELS=1, MDI_DEFAULT_VOLUME=5, N_PREFS
// =46), while 9.x uses another (DIG_MIXER_CHANNELS=3, MDI_DEFAULT_VOLUME=23,
// N_PREFS=40). The cutoff is verified by disassembling init_preferences in the
// reference DLLs: 6.5h/7.0k/8.0e write DEFAULT_DRT(131) and DEFAULT_DOBS(49152)
// 11 slots apart (old: indices 0 and 11), 9.1d writes them 13 slots apart (new:
// indices 5 and 18). So the defaults must sit at version-correct slots.
var preferences: [512]i32 = init: {
    var p = [_]i32{0} ** 512;
    if (mss_version >= 90) {
        // MSS 9.x layout + DEFAULT_* values (genericmss.cpp init_preferences).
        p[0] = 1; // AIL_MM_PERIOD (DEFAULT_AMP)
        p[1] = 16; // AIL_TIMERS
        p[2] = 1; // AIL_ENABLE_MMX_SUPPORT
        p[3] = 64; // DIG_MIXER_CHANNELS
        p[4] = 1; // DIG_ENABLE_RESAMPLE_FILTER
        p[5] = 131; // DIG_RESAMPLING_TOLERANCE
        p[6] = 1; // DIG_DS_FRAGMENT_SIZE
        p[7] = 256; // DIG_DS_FRAGMENT_CNT
        p[8] = 48; // DIG_DS_MIX_FRAGMENT_CNT
        p[9] = 32; // DIG_LEVEL_RAMP_SAMPLES
        p[10] = 500; // DIG_MAX_PREDELAY_MS
        p[11] = 1; // DIG_3D_MUTE_AT_MAX
        p[15] = 8192; // DIG_MAX_CHAIN_ELEMENT_SIZE
        p[16] = 100; // DIG_MIN_CHAIN_ELEMENT_TIME
        p[18] = 49152; // DIG_OUTPUT_BUFFER_SIZE
        p[19] = -1; // DIG_PREFERRED_WO_DEVICE (WAVE_MAPPER)
        p[21] = 8; // MDI_SEQUENCES
        p[22] = 120; // MDI_SERVICE_RATE
        p[23] = 127; // MDI_DEFAULT_VOLUME
        p[24] = 1; // MDI_QUANT_ADVANCE
        p[26] = 2; // MDI_DEFAULT_BEND_RANGE
        p[28] = 1536; // MDI_SYSEX_BUFFER_SIZE
        p[29] = 64; // DLS_VOICE_LIMIT
        p[30] = 120; // DLS_TIMEBASE
        p[32] = 1; // DLS_STREAM_BOOTSTRAP
        p[34] = 1; // DLS_ENABLE_FILTERING
        p[35] = 1; // DLS_GM_PASSTHROUGH
        p[36] = 32768; // DLS_ADPCM_TO_ASI_THRESHOLD
    } else {
        // MSS 3.x..8.x layout (Pref enum) + that era's DEFAULT_* values.
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
    }
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
/// (e.g., 30/127) produced dramatic attenuation. The curve `(v/127)^(10/6)`
/// matches `AIL_API_set_sample_volume_pan` (0.5 → −10 dB): value 30 → gain
/// ~0.090 (vs linear ~0.236). See `volume_to_gain_table`.
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
    @setEvalBranchQuota(200000);
    var table: [128]f32 = undefined;
    table[0] = 0.0;
    for (1..128) |i| {
        const n: f64 = @as(f64, @floatFromInt(i)) / 127.0;
        // MSS volume curve: gain = volume^(10/6) (0.5 -> -10 dB), per
        // AIL_API_set_sample_volume_pan in wavefile.cpp. (Was volume^3 = -18 dB.)
        table[i] = @floatCast(std.math.pow(f64, n, 10.0 / 6.0));
    }
    break :blk table;
};

/// Saturating f32 -> i32 (NaN -> 0, out-of-range -> clamped). Guards the
/// `@intFromFloat` panic when callers feed adversarial floats — including the
/// i32 -> f32 -> i32 round trip where INT_MAX rounds up to 2^31 (out of range).
pub fn satI32(v: f32) i32 {
    if (std.math.isNan(v)) return 0;
    if (v >= 2147483647.0) return std.math.maxInt(i32);
    if (v <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(v);
}

/// Saturating f64 -> i32 (NaN -> 0, out-of-range -> clamped). Same contract as
/// satI32 for sources wider than f32 -- e.g. TML event times are u32
/// milliseconds and can exceed maxInt(i32) on long/crafted sequences.
pub fn satI32F64(v: f64) i32 {
    if (std.math.isNan(v)) return 0;
    if (v >= 2147483647.0) return std.math.maxInt(i32);
    if (v <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(v);
}

/// Saturating f32 -> u32 (NaN/negative -> 0, overflow -> clamped).
pub fn satU32(v: f32) u32 {
    if (!(v >= 0)) return 0; // false for NaN and negatives
    if (v >= 4294967295.0) return std.math.maxInt(u32);
    return @intFromFloat(v);
}

/// Convert a linear pan (-1.0 left .. +1.0 right) to MSS 0-127 range.
/// Clamps the float first so NaN/huge inputs cannot panic `@intFromFloat`.
pub fn panToMss(pan: f32) i32 {
    return satI32(@min(127.0, @max(0.0, (pan * 64.0) + 64.0)));
}

// --- Startup time ---

var startup_ns: i64 = 0;
var startup_ns_mutex: std.Io.Mutex = .init;
var startup_ns_ready: bool = false;

fn nowNs() i64 {
    const ts = std.Io.Timestamp.now(io, .awake);
    return @intCast(ts.nanoseconds);
}

pub fn ensureStartupTime() void {
    if (@atomicLoad(bool, &startup_ns_ready, .acquire)) return;
    startup_ns_mutex.lockUncancelable(io);
    defer startup_ns_mutex.unlock(io);
    if (!startup_ns_ready) {
        startup_ns = nowNs();
        @atomicStore(bool, &startup_ns_ready, true, .release);
    }
}

pub fn getMsCount() u32 {
    ensureStartupTime();
    const elapsed_ns: u64 = @intCast(@max(0, nowNs() - startup_ns));
    return @truncate(elapsed_ns / std.time.ns_per_ms);
}

pub fn getUsCount() u32 {
    ensureStartupTime();
    const elapsed_ns: u64 = @intCast(@max(0, nowNs() - startup_ns));
    return @truncate(elapsed_ns / std.time.ns_per_us);
}

/// 64-bit millisecond/microsecond counters since startup (MSS v9 AIL_*_count64).
pub fn getMsCount64() u64 {
    ensureStartupTime();
    const elapsed_ns: u64 = @intCast(@max(0, nowNs() - startup_ns));
    return elapsed_ns / std.time.ns_per_ms;
}
pub fn getUsCount64() u64 {
    ensureStartupTime();
    const elapsed_ns: u64 = @intCast(@max(0, nowNs() - startup_ns));
    return elapsed_ns / std.time.ns_per_us;
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
    // MSS's AIL_shutdown releases everything startup acquired. Timer threads
    // stop first (their callbacks may touch the drivers), then MIDI sequences
    // (their voices are attached to the digital engine and must be stopped
    // before it is torn down), then the drivers themselves.
    releaseAllTimers();
    if (last_midi_driver) |m| closeMidiDriver(m);
    if (last_digital_driver) |d| closeDigitalDriver(d);
    for (global_providers.items) |p| p.deinit();
    global_providers.deinit(global_allocator);
    global_providers = .empty;
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
    const driver = DigitalDriver.init(global_allocator, frequency, bits, ch) catch |err| {
        log("openDigitalDriver: DigitalDriver.init failed: {any}\n", .{err});
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
    global_sequences_mutex.lockUncancelable(io);
    const snapshot = global_allocator.dupe(*Sequence, global_sequences.items) catch {
        // Fallback: stop sequences while holding the lock (less ideal but correct).
        for (global_sequences.items) |seq| {
            if (seq.driver == driver) seq.stopAndUninit();
        }
        global_sequences_mutex.unlock(io);
        driver.deinit();
        return;
    };
    global_sequences_mutex.unlock(io);
    defer global_allocator.free(snapshot);
    for (snapshot) |seq| {
        if (seq.driver == driver) seq.stopAndUninit();
    }
    driver.deinit();
}

// Test entry points live in test_root.zig (the test build's root module), which
// imports this file as the shared "openmiles" module so tests and the C-ABI api
// wrappers reference one set of types.

//! The `openmiles` module root: everything in the library except the exported
//! C ABI hangs off this file.
//!
//! Layering, outermost first:
//!
//!   main.zig      the DLL root, owns DllMain and the PE export table only
//!   api/*.zig     the AIL_*/Miles*/RIB_* C ABI, one module per SDK area
//!   engine/*.zig  drivers, mixers, codecs, loaders
//!   rib/          the RIB plugin/provider registry
//!   utils/*.zig   leaves: logging, wide strings, fs, dynlib, pure helpers
//!
//! Dependencies point inward from there. `api/` reaches the engine only
//! through the symbols re-exported here, never by importing an `engine/`
//! file directly. `utils/` is a leaf: it imports std and its own siblings,
//! nothing else.
//!
//! This file is both the public surface and the home of the process-wide
//! state every layer shares: the allocator, the two error buffers, the custom
//! file-I/O callbacks, and the provider, timer, driver, and sequence
//! registries. The engine modules reach those through `@import("../root.zig")`,
//! so root and engine reference each other at the file level. Keeping the
//! registries in this one hub rather than in `engine/` is what lets a driver
//! module publish to the timer and sequence registries without importing those
//! modules back.
//!
//! Section order below follows that: re-exports, then constants, then the
//! shared state, each under a `// ---` banner.
const std = @import("std");
const logger = @import("utils/logger.zig");

pub const log = logger.log;
pub const fs_compat = @import("utils/fs_compat.zig");
pub const wide = @import("utils/wide.zig");
pub const removeFirst = @import("utils/list.zig").removeFirst;
pub const satI32 = @import("utils/saturate.zig").satI32;
pub const satU32 = @import("utils/saturate.zig").satU32;

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

/// Describe a miniaudio result code for the log.
///
/// A bare `ma_result` in a log line is a number an operator cannot act on:
/// -1003 means nothing to anyone who is not holding the miniaudio header, and
/// the log is read precisely when there is no one holding anything. The code
/// stays in the line next to the description so a reader can match it against
/// upstream, and so a result miniaudio has no description for is still visible
/// as something other than an empty string.
pub fn maResultDescription(result: c_int) []const u8 {
    const described = ma.ma_result_description(result);
    if (described == null) return "(no description)";
    const text = std.mem.span(described);
    if (text.len == 0) return "(no description)";
    return text;
}

// --- Engine type re-exports ---

const digital_mod = @import("engine/digital.zig");
pub const DigitalDriver = digital_mod.DigitalDriver;
pub const Sample = digital_mod.Sample;
pub const fireSampleCallback = digital_mod.fireSampleCallback;
pub const MixBus = digital_mod.MixBus;
pub const LimiterNode = digital_mod.LimiterNode;
pub const CompressorNode = digital_mod.CompressorNode;
pub const Sample3D = digital_mod.Sample3D;
pub const SampleStatus = digital_mod.SampleStatus;
pub const SamplePcmFormat = digital_mod.SamplePcmFormat;
pub const FalloffGraphPoint = digital_mod.FalloffGraphPoint;
pub const FalloffKind = digital_mod.FalloffKind;
pub const max_falloff_points = digital_mod.max_falloff_points;
pub const max_system_state_level = digital_mod.max_system_state_level;
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
pub const releaseAllChannels = midi_mod.releaseAllChannels;

pub const Timer = @import("engine/timer.zig").Timer;
pub const Filter = @import("engine/filter.zig").Filter;
pub const Input = @import("engine/input.zig").Input;

const redbook_mod = @import("engine/redbook.zig");
pub const Redbook = redbook_mod.Redbook;
pub const RedbookStatus = redbook_mod.RedbookStatus;
pub const redbook_status_error = redbook_mod.redbook_status_error;

const rib_mod = @import("rib/provider.zig");
pub const Provider = rib_mod.Provider;
pub const getCurrentLoadingProvider = rib_mod.getCurrentLoadingProvider;
pub const Interface = rib_mod.Interface;
pub const InterfaceEntry = rib_mod.InterfaceEntry;
pub const RIB_INTERFACE_ENTRY = rib_mod.RIB_INTERFACE_ENTRY;
pub const RIB_ENTRY_TYPE = rib_mod.RIB_ENTRY_TYPE;
pub const HPROVIDER = rib_mod.HPROVIDER;
pub const RIB_alloc_provider_handle_ptr = rib_mod.RIB_alloc_provider_handle_ptr;
pub const RIB_register_interface_ptr = rib_mod.RIB_register_interface_ptr;
pub const RIB_unregister_interface_ptr = rib_mod.RIB_unregister_interface_ptr;
pub const RIB_Main_ptr = rib_mod.RIB_Main_ptr;

const audio_detect = @import("engine/audio_detect.zig");
pub const streaming_sentinel_size = audio_detect.streaming_sentinel_size;
pub const max_declared_image_size = audio_detect.max_declared_image_size;
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

/// Clamp to the 0..1 range a gain or pan is specified in, with a non-finite
/// input resolving to 0 rather than to the upper bound: std.math.clamp maps NaN
/// to hi, so a NaN level would otherwise become full volume.
pub fn clampUnit(v: f32) f32 {
    if (!std.math.isFinite(v)) return 0.0;
    return std.math.clamp(v, 0.0, 1.0);
}

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

// These two buffers are process-wide and every API entry point writes them
// from whichever game thread called, while AIL_last_error / AIL_file_error
// hand the caller a raw pointer into them. A writer that is mid-message and a
// reader would otherwise see a body with no terminator, or two threads'
// messages spliced. Serialized so a reader gets one whole message.
var error_buf_mutex: std.Io.Mutex = .init;

pub var last_error_buf: [256:0]u8 = [_:0]u8{0} ** 256;
pub var last_file_error_buf: [256:0]u8 = [_:0]u8{0} ** 256;
pub fn setLastError(msg: []const u8) void {
    error_buf_mutex.lockUncancelable(io);
    defer error_buf_mutex.unlock(io);
    writeErrorLocked(&last_error_buf, msg);
}

/// Same as `setLastError`, for a message that names the offending value (a
/// file, a sample, a byte count). A message that does not survive the buffer
/// says so rather than leaving a truncated string that reads as the whole error.
pub fn setLastErrorFmt(comptime fmt: []const u8, args: anytype) void {
    error_buf_mutex.lockUncancelable(io);
    defer error_buf_mutex.unlock(io);
    if (std.fmt.bufPrintZ(&last_error_buf, fmt, args)) |_| {} else |_| writeErrorLocked(&last_error_buf, "Error message too long");
}

pub fn clearLastError() void {
    error_buf_mutex.lockUncancelable(io);
    defer error_buf_mutex.unlock(io);
    last_error_buf[0] = 0;
}

pub fn setFileError(msg: []const u8) void {
    error_buf_mutex.lockUncancelable(io);
    defer error_buf_mutex.unlock(io);
    writeErrorLocked(&last_file_error_buf, msg);
}

/// Same as `setFileError`, for a message that names the file it applies to.
pub fn setFileErrorFmt(comptime fmt: []const u8, args: anytype) void {
    error_buf_mutex.lockUncancelable(io);
    defer error_buf_mutex.unlock(io);
    if (std.fmt.bufPrintZ(&last_file_error_buf, fmt, args)) |_| {} else |_| writeErrorLocked(&last_file_error_buf, "Error message too long");
}

/// Copy into one of the two error buffers. Callers hold error_buf_mutex.
fn writeErrorLocked(buf: *[256:0]u8, msg: []const u8) void {
    // Cut on a character boundary, not a byte one: a message naming a file
    // outside ASCII otherwise ends in half a character, and the caller reading
    // it as UTF-8 sees a broken sequence where the tail of the name should be.
    const cut = wide.utf8Prefix(msg, buf.len - 1);
    const len = cut.len;
    @memcpy(buf[0..len], msg[0..len]);
    buf[len] = 0;
}

pub fn clearFileError() void {
    error_buf_mutex.lockUncancelable(io);
    defer error_buf_mutex.unlock(io);
    last_file_error_buf[0] = 0;
}

// --- Custom file I/O callbacks ---

// MSS file callbacks (mss.h). FileHandle is a U32 token (4 bytes on x86, same
// width as a pointer). open RETURNS the file length and fills *FileHandle;
// seek takes (handle, offset, type) where type is 0=SET, 1=CUR, 2=END.
pub const SEEK_SET: u32 = 0;
pub const SEEK_END: u32 = 2;

pub const FileCallbacks = struct {
    open: ?*const fn ([*:0]const u8, *u32) callconv(.winapi) u32 = null,
    close: ?*const fn (u32) callconv(.winapi) void = null,
    read: ?*const fn (u32, *anyopaque, u32) callconv(.winapi) u32 = null,
    seek: ?*const fn (u32, i32, u32) callconv(.winapi) i32 = null,
};

var file_callbacks: FileCallbacks = .{};
var file_callbacks_mutex: std.Io.Mutex = .init;

/// Install the app's VFS, or remove it when every argument is null. The four
/// pointers are published together: a reader copies the whole set, so a load
/// cannot open with one VFS and read or close with the next one installed.
/// Argument order matches AIL_set_file_callbacks: open, close, seek, read.
pub fn setFileCallbacks(
    open_fn: ?*const fn ([*:0]const u8, *u32) callconv(.winapi) u32,
    close_fn: ?*const fn (u32) callconv(.winapi) void,
    seek_fn: ?*const fn (u32, i32, u32) callconv(.winapi) i32,
    read_fn: ?*const fn (u32, *anyopaque, u32) callconv(.winapi) u32,
) void {
    file_callbacks_mutex.lockUncancelable(io);
    defer file_callbacks_mutex.unlock(io);
    file_callbacks = .{ .open = open_fn, .close = close_fn, .read = read_fn, .seek = seek_fn };
}

/// The installed VFS, or null when the app registered no open callback. The
/// result is a copy, so the caller keeps this generation for the whole load.
pub fn currentFileCallbacks() ?FileCallbacks {
    file_callbacks_mutex.lockUncancelable(io);
    defer file_callbacks_mutex.unlock(io);
    if (file_callbacks.open == null) return null;
    return file_callbacks;
}

/// If file callbacks are set, open the file via the game's VFS, read it all into
/// a freshly-allocated slice (caller must free with global_allocator), and close it.
pub fn fileCallbackReadAll(filename: [*:0]const u8) ![]u8 {
    const cbs = currentFileCallbacks() orelse return error.NoCallbacks;
    const open_fn = cbs.open orelse return error.NoCallbacks;
    const close_fn = cbs.close orelse return error.NoCallbacks;
    const read_fn = cbs.read orelse return error.NoCallbacks;

    // open returns the file length and writes the handle to the out-param;
    // a 0 length means the file could not be opened.
    var handle: u32 = 0;
    const file_size = resolveVfsSize(cbs, open_fn(filename, &handle), handle);
    if (file_size == 0) {
        close_fn(handle);
        return error.FileNotFound;
    }
    defer close_fn(handle);

    // A VFS reports the length, and the reported value is what gets allocated
    // and read. Cap it exactly as the direct path does, so a lying or huge stat
    // result cannot turn into an allocation of arbitrary size (and, on the
    // 32-bit target, a wrap).
    if (@as(u64, file_size) > max_file_load_bytes) return error.BadSize;

    const buf = try global_allocator.alloc(u8, file_size);
    errdefer global_allocator.free(buf);
    const bytes_read = read_fn(handle, buf.ptr, file_size);
    if (bytes_read != file_size) return error.ReadFailed;
    return buf;
}

/// Largest file any load path will read into memory. A game's asset bundle is
/// far below this; a larger length is a corrupt or hostile stat result, and
/// honouring it means allocating whatever the caller claims.
pub const max_file_load_bytes: u64 = 256 * 1024 * 1024;

/// Resolve the length `open` reported for the file it just opened on `handle`.
///
/// Some VFS open fine but report length 0 until a seek-to-end names the size,
/// so a 0 result is not yet "not found". Both read paths resolve it the same
/// way; they used to carry a copy each, and the copies drifted into disagreeing
/// about closing the handle on the unresolvable path.
fn resolveVfsSize(cbs: FileCallbacks, reported: u32, handle: u32) u32 {
    if (reported != 0) return reported;
    const seek_fn = cbs.seek orelse return 0;
    const end_pos = seek_fn(handle, 0, SEEK_END);
    if (end_pos <= 0) return 0;
    _ = seek_fn(handle, 0, SEEK_SET);
    return @intCast(end_pos);
}

/// Read a whole file via the app's file callbacks when set, otherwise directly
/// from the filesystem. Caller frees the returned buffer with global_allocator.
pub fn readWholeFile(path: []const u8) ![]u8 {
    if (currentFileCallbacks() != null) {
        var zbuf: [std.fs.max_path_bytes:0]u8 = undefined;
        if (path.len >= zbuf.len) return error.NameTooLong;
        @memcpy(zbuf[0..path.len], path);
        zbuf[path.len] = 0;
        return fileCallbackReadAll(@ptrCast(&zbuf));
    }
    const f = fs_compat.openFile(io, path, .{}) catch return error.FileNotFound;
    defer f.close(io);
    const sz = f.length(io) catch return error.UnknownSize;
    if (sz == 0 or sz > max_file_load_bytes) return error.BadSize;
    const buf = try global_allocator.alloc(u8, @intCast(sz));
    errdefer global_allocator.free(buf);
    // A truncated read stops short of the size stat reported, which is the
    // shape of a write that never finished; the length check below rejects it.
    const read_len = fs_compat.readLength(path, buf.len);
    const n = f.readPositionalAll(io, buf[0..read_len], 0) catch return error.ReadFailed;
    if (n < buf.len) return error.ReadFailed;
    return buf;
}

// --- AIL file services (shared by api/file.zig and api/v9.zig) ---

/// AIL_file_read core: read a whole file into `dest` (zero-padding short
/// reads), or into a fresh malloc'd buffer when `dest` is null (free with
/// AIL_mem_free_lock). Returns null and sets the file error on failure.
pub fn ailFileRead(filename: [*:0]const u8, dest: ?*anyopaque) ?*anyopaque {
    clearFileError();
    if (currentFileCallbacks() != null) {
        const buf = fileCallbackReadAll(filename) catch |err| {
            // Name the real failure mode: a blanket "not found" would send an
            // operator chasing a missing file when the VFS read or its
            // allocation actually failed.
            setFileError(switch (err) {
                error.FileNotFound => "File not found",
                error.OutOfMemory => "Out of memory",
                else => "Read failed",
            });
            return null;
        };
        defer global_allocator.free(buf);
        if (dest) |d| {
            @memcpy(@as([*]u8, @ptrCast(@alignCast(d)))[0..buf.len], buf);
            return d;
        }
        const out: [*]u8 = @ptrCast(std.c.malloc(buf.len) orelse {
            setFileError("Out of memory");
            return null;
        });
        @memcpy(out[0..buf.len], buf);
        return out;
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
    if (file_len == 0 or file_len > max_file_load_bytes) {
        setFileError("Empty or oversized file");
        return null;
    }
    const size: usize = @intCast(file_len);
    // Through the injected length, so a schedule that models a write that never
    // finished reaches this path as well as readWholeFile's: the read stops
    // short and the tail is zero-filled below, the same shape a real short
    // read has.
    const read_len = fs_compat.readLength(path, size);
    if (dest) |d| {
        const buf: [*]u8 = @ptrCast(@alignCast(d));
        const n = file.readPositionalAll(io, buf[0..read_len], 0) catch {
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
        const n = file.readPositionalAll(io, buf[0..read_len], 0) catch {
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

/// AIL_file_size core: size in bytes via the app's callbacks when set, otherwise
/// from the filesystem. Returns 0 and sets the file error on failure. A
/// partial callback set is a failure too: the app's AIL_file_error is the only
/// signal these calls give, and a silent 0 cannot be told from a zero-length
/// file.
pub fn ailFileSize(filename: [*:0]const u8) u32 {
    clearFileError();
    if (currentFileCallbacks()) |cbs| {
        const open_fn = cbs.open orelse {
            setFileError("Read failed");
            return 0;
        };
        const close_fn = cbs.close orelse {
            setFileError("Read failed");
            return 0;
        };
        // open returns the file length and fills the handle out-param. From
        // here on the handle may be live, so every path below must close it;
        // returning early before the close leaked one VFS handle per
        // AIL_file_size call on an empty/sizeless file.
        var handle: u32 = 0;
        const size = resolveVfsSize(cbs, open_fn(filename, &handle), handle);
        close_fn(handle);
        if (size == 0) {
            setFileError("File not found");
            return 0;
        }
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
    if (file_len == 0) {
        setFileError("Empty file");
        return 0;
    }
    return @intCast(@min(file_len, std.math.maxInt(u32)));
}

// --- Provider state ---

// Atomic for the same reason as last_digital_driver below: AIL_startup and
// AIL_shutdown run on whichever thread calls them, while provider enumeration
// on another thread resolves and dereferences this pointer. A plain optional
// pointer is two words, so a reader could see a non-null tag with a null
// payload. Callers go through startupProvider().
var startup_provider: std.atomic.Value(?*Provider) = .init(null);

// Serializes startup(), which a game drives from whichever thread it happens to
// be on: AIL_startup and AIL_quick_startup both reach it, and a worker thread
// bringing the audio up while the main thread does the same is ordinary. The
// startup is check-then-act on the published provider, and an atomic load/store
// does not make that pair one step: two threads that both read null before
// either stored built two startup providers, and the one that lost the store
// was unreachable from then on, so its interfaces and name stayed allocated for
// the life of the process and shutdown freed only the winner.
//
// The lock is taken *after* the published-provider check, so the re-entrant
// AIL_startup a plugin's RIB_Main may make (the provider is published before
// the scan runs) still returns on the guard rather than deadlocking on a lock
// the same thread already holds. Nothing reached from startup()'s body takes
// this lock, so the nesting order against provider_mutex and the driver locks
// is fixed by that. shutdown() does not take it: see the note on its own
// teardown, where holding it across the timer-thread joins would deadlock.
var startup_mutex: std.Io.Mutex = .init;

pub fn startupProvider() ?*Provider {
    return startup_provider.load(.acquire);
}

// Guarded by provider_mutex. Grown by the plugin scan, read by provider
// enumeration, emptied by shutdown; an append that reallocs frees the buffer a
// concurrent reader is walking, so the slice is never handed out raw.
var global_providers: std.ArrayList(*Provider) = .empty;
var provider_mutex: std.Io.Mutex = .init;

pub fn getProviderCount() usize {
    provider_mutex.lockUncancelable(io);
    defer provider_mutex.unlock(io);
    return global_providers.items.len;
}

pub fn getProviderAt(index: usize) ?*Provider {
    provider_mutex.lockUncancelable(io);
    defer provider_mutex.unlock(io);
    if (index >= global_providers.items.len) return null;
    return global_providers.items[index];
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
    // A trailing dot or space is stripped by the Windows filesystem before the
    // name is stored, so the entry a scan reads back is not the name the scan
    // listed, and "decoder.asi " names a different file from "decoder.asi".
    if (name.len > 0 and (name[name.len - 1] == '.' or name[name.len - 1] == ' ')) return false;
    // ':' opens a named stream on NTFS ("decoder.asi:payload"), so what the
    // loader opens is not the file the directory entry named.
    if (std.mem.indexOfScalar(u8, name, ':') != null) return false;
    // A DOS device name resolves to the device, not to the file. Under Wine,
    // where the game directory is a POSIX path, "nul.asi" is a real entry that
    // a scan lists and the loader then resolves to the null device.
    const stem_end = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
    if (isDosDeviceName(name[0..stem_end])) return false;
    return true;
}

/// Longest prefix of `stem` that carries no trailing space. The path parser
/// strips trailing spaces and dots from the last component before it decides
/// what the name is, so "con .asi" is opened as the CON device and not as a
/// file called "con ". The stem ends at the first dot, so a dot is not the
/// issue here; the space is.
fn trimStemSpaces(stem: []const u8) []const u8 {
    var end = stem.len;
    while (end > 0 and stem[end - 1] == ' ') end -= 1;
    return stem[0..end];
}

/// Whether `stem`, the part of a filename before its first dot, is one of the
/// device names DOS and Windows resolve without a file behind them.
fn isDosDeviceName(raw_stem: []const u8) bool {
    const stem = trimStemSpaces(raw_stem);
    const fixed = [_][]const u8{ "CON", "PRN", "AUX", "NUL", "CLOCK$" };
    for (fixed) |d| {
        if (std.ascii.eqlIgnoreCase(stem, d)) return true;
    }
    // COM1-COM9 and LPT1-LPT9 are the numbered devices. COM0 and LPT0 name no
    // device, so a file by that name is an ordinary file on every target.
    if (stem.len != 4) return false;
    if (!std.ascii.startsWithIgnoreCase(stem, "COM") and !std.ascii.startsWithIgnoreCase(stem, "LPT")) return false;
    return stem[3] >= '1' and stem[3] <= '9';
}

/// Read one directory entry, or null at end of directory. A read error is
/// logged and ends the scan: `catch null` would hide an unreadable directory
/// behind an apparently complete enumeration, and the caller would report a
/// plugin count that silently omits whatever it never saw.
pub fn nextEntry(it: *std.Io.Dir.Iterator, dir: []const u8) ?std.Io.Dir.Entry {
    return it.next(io) catch |err| {
        log("plugin directory scan: read of '{s}' failed, scan stopped ({any})\n", .{ dir, err });
        return null;
    };
}

/// Owned copies of the plugin file names in `dir_path`, in ascending name
/// order. A directory read hands entries back in whatever order the filesystem
/// stored them, which differs between machines and between runs, so loading
/// and enumerating in read order makes the provider list a function of the
/// filesystem rather than of the directory's contents: a recorded run cannot
/// be replayed provider-for-provider, and two builds of the same game can pick
/// a different provider for the same query. Caller frees each name and the
/// list.
pub fn sortedPluginNames(allocator: std.mem.Allocator, dir_path: []const u8) !std.ArrayList([]u8) {
    var names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }
    var d = try fs_compat.openDir(io, dir_path, .{ .iterate = true });
    defer d.close(io);
    var it = d.iterate();
    while (nextEntry(&it, dir_path)) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!isPluginExtension(name)) continue;
        if (!isSafePluginFilename(name)) continue;
        // The entry name borrows the iterator's buffer, which is gone once the
        // scan ends, so the sort owns a copy.
        try names.append(allocator, try allocator.dupe(u8, name));
    }
    std.mem.sort([]u8, names.items, {}, lessThanName);
    return names;
}

fn lessThanName(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn freePluginNames(allocator: std.mem.Allocator, names: *const std.ArrayList([]u8)) void {
    for (names.items) |n| allocator.free(n);
    var list = names.*;
    list.deinit(allocator);
}

pub fn loadApplicationProviders(dir: []const u8) i32 {
    const alloc = global_allocator;
    var count: i32 = 0;
    const names = sortedPluginNames(alloc, dir) catch |err| {
        log("loadApplicationProviders: failed to open directory '{s}': {any}\n", .{ dir, err });
        return 0;
    };
    defer freePluginNames(alloc, &names);
    for (names.items) |name| {
        const full_path = std.fs.path.join(alloc, &.{ dir, name }) catch |err| {
            log("loadApplicationProviders: cannot build a path for '{s}' in '{s}' ({any})\n", .{ name, dir, err });
            continue;
        };
        // Scoped so the path is released at the end of this entry rather than at
        // the end of the scan: a defer directly in the loop body is scoped to the
        // function, so a directory of N plugins held N path copies at once.
        {
            defer alloc.free(full_path);
            // A second scan of a directory that is already loaded (the game's own
            // RIB_load_application_providers after our startup() already scanned it)
            // must not register the same module twice: the duplicate would answer
            // provider enumeration with the same codecs twice and keep a second
            // copy of the module loaded for as long as the process runs.
            var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
            const resolved = fs_compat.maybeResolveCaseInsensitivePath(full_path, &resolved_buf) orelse full_path;
            if (isProviderPathLoaded(resolved)) continue;
            const p = Provider.load(alloc, full_path) catch |err| {
                log("loadApplicationProviders: failed to load plugin '{s}': {any}\n", .{ name, err });
                continue;
            };
            if (!adoptPlugin(p, null)) continue;
            count += 1;
        }
    }
    return count;
}

/// Track a freshly loaded module in the list that owns it, or report that it
/// was not tracked (after unloading it). `owned` is the driver's own list for a
/// module loaded by a driver scan, null for one that belongs to the application
/// list; the two lists stay separate, because only the application list is what
/// RIB_enumerate_providers walks.
///
/// The identity check the scan did before Provider.load is repeated here, under
/// the lock both lists are guarded by: the module is loaded by running the
/// plugin's RIB_Main, which takes arbitrarily long, and a scan of the same
/// directory running alongside this one can register the module in between. The
/// check-then-act pair is the whole dedup, so repeating it outside the lock
/// leaves a second dlopen'd copy of the module in one of the lists, which
/// answers provider enumeration with every codec twice and lives until
/// AIL_shutdown. The redundant copy is unloaded here instead.
///
/// The lists are appended under the lock because a concurrent
/// RIB_enumerate_providers is indexing global_providers while this scan appends.
pub fn adoptPlugin(p: *Provider, owned: ?*std.ArrayList(*Provider)) bool {
    provider_mutex.lockUncancelable(io);
    defer provider_mutex.unlock(io);
    if (p.source_path) |sp| {
        if (isPluginAlreadyLoaded(global_providers.items, sp) or
            (if (owned) |list| isPluginAlreadyLoaded(list.items, sp) else false))
        {
            p.deinit();
            return false;
        }
    }
    if (owned) |list| {
        list.append(p.allocator, p) catch |err| {
            log("plugin load: cannot track loaded plugin '{s}' ({any}); it is unloaded\n", .{ p.source_path orelse "?", err });
            p.deinit();
            return false;
        };
        return true;
    }
    global_providers.append(global_allocator, p) catch |err| {
        log("plugin load: cannot track loaded plugin '{s}' ({any}); it is unloaded\n", .{ p.source_path orelse "?", err });
        p.deinit();
        return false;
    };
    return true;
}

/// Whether `path` names a module already held in the application list.
fn isProviderPathLoaded(path: []const u8) bool {
    provider_mutex.lockUncancelable(io);
    defer provider_mutex.unlock(io);
    return isPluginAlreadyLoaded(global_providers.items, path);
}

/// Whether `path` is a module one of `providers` was already loaded from, so a
/// rescan of the directory holding it adds no second copy. `path` is the
/// resolved form, which is what Provider.load records, so a differently cased
/// name on Windows is recognised as the same plugin.
pub fn isPluginAlreadyLoaded(providers: []const *Provider, path: []const u8) bool {
    for (providers) |p| {
        if (p.matchesSourcePath(path)) return true;
    }
    return false;
}

/// Whether `path` names a module this process already holds open, in the
/// application list or in `owned` (a driver's own list). A module is one
/// instance per process: both lists live until AIL_shutdown, so a game whose
/// redist directory is the directory startup already scanned would otherwise
/// keep a second dlopen'd copy of every .asi for the life of the process, each
/// with its own codec state.
pub fn isPluginLoadedAnywhere(owned: []const *Provider, path: []const u8) bool {
    if (isPluginAlreadyLoaded(owned, path)) return true;
    return isProviderPathLoaded(path);
}

// --- Timer state ---

pub var global_timers: std.ArrayList(*Timer) = .empty;
pub var global_timers_mutex: std.Io.Mutex = .init;

// start()/stop() join a timer thread, and that thread is inside a game
// callback free to call AIL_register_timer, which takes global_timers_mutex.
// Holding the lock across the join is a hard deadlock: both threads wait on the
// same mutex. So each of these snapshots the registry under the lock and does
// the per-timer work with it released. A snapshot stays valid because deinit
// unlinks and frees a timer under that same lock. releaseAllTimers is the one
// exception: it detaches the list first and relies on shutdown being single-threaded.
pub fn startAllTimers() void {
    const snapshot = snapshotTimers("startAllTimers") orelse return;
    defer global_allocator.free(snapshot);
    for (snapshot) |t| t.start();
}

pub fn stopAllTimers() void {
    const snapshot = snapshotTimers("stopAllTimers") orelse return;
    defer global_allocator.free(snapshot);
    for (snapshot) |t| t.stop();
}

/// One period of every running timer's callback, and one period of virtual
/// time forward per timer. Under a virtual clock a started timer has no thread
/// and never fires on its own, so a simulation that called AIL_start_all_timers
/// rather than starting timers one handle at a time has no other way to reach
/// them: this is the stepping counterpart of startAllTimers/stopAllTimers.
/// Does nothing unless a virtual clock is installed.
pub fn tickAllTimers() void {
    if (!clock.isVirtual()) return;
    const snapshot = snapshotTimers("tickAllTimers") orelse return;
    defer global_allocator.free(snapshot);
    for (snapshot) |t| t.tick();
}

pub fn releaseAllTimers() void {
    global_timers_mutex.lockUncancelable(io);
    const snapshot = global_allocator.dupe(*Timer, global_timers.items) catch {
        global_timers_mutex.unlock(io);
        log("releaseAllTimers: cannot snapshot the timer list; timers left registered\n", .{});
        return;
    };
    global_timers.items.len = 0;
    global_timers_mutex.unlock(io);
    defer global_allocator.free(snapshot);
    // deinit, not stop + destroy: a timer that self-stopped inside its own
    // callback still owns an unjoined thread handle, and stop() alone leaves
    // the struct freed while that run loop is unwinding through it.
    for (snapshot) |t| t.deinit();
}

fn snapshotTimers(caller: []const u8) ?[]*Timer {
    global_timers_mutex.lockUncancelable(io);
    defer global_timers_mutex.unlock(io);
    return global_allocator.dupe(*Timer, global_timers.items) catch {
        log("{s}: cannot snapshot the timer list; the registry is unchanged\n", .{caller});
        return null;
    };
}

// --- Driver state ---

// The "current driver" handles are read by every API entry point and written by
// driver open/close, which a game may drive from a worker thread while its main
// thread is calling into the API. Atomic so a reader never sees a torn
// pointer. Read them through lastDigitalDriver()/lastMidiDriver().
pub var last_digital_driver: std.atomic.Value(?*DigitalDriver) = .init(null);
pub var last_midi_driver: std.atomic.Value(?*MidiDriver) = .init(null);

pub fn lastDigitalDriver() ?*DigitalDriver {
    return last_digital_driver.load(.acquire);
}

pub fn setLastDigitalDriver(driver: ?*DigitalDriver) void {
    last_digital_driver.store(driver, .release);
}

pub fn lastMidiDriver() ?*MidiDriver {
    return last_midi_driver.load(.acquire);
}

pub fn setLastMidiDriver(driver: ?*MidiDriver) void {
    last_midi_driver.store(driver, .release);
}

/// Clear the current driver handle, but only if it is still `driver`. Closing a
/// handle the game already replaced with a newer one must not clear the newer.
pub fn clearLastDigitalDriver(driver: *DigitalDriver) void {
    _ = last_digital_driver.cmpxchgStrong(driver, null, .acq_rel, .acquire);
}

pub fn clearLastMidiDriver(driver: *MidiDriver) void {
    _ = last_midi_driver.cmpxchgStrong(driver, null, .acq_rel, .acquire);
}

// Serializes the create-if-absent sequence in openDigitalDriver/openMidiDriver
// so two threads calling AIL_open_digital_driver at once cannot both pass the
// "already open" check and build two engines (the loser would be orphaned with
// a live audio thread). Only ever held around create/publish; never around
// deinit. Lock order is this one first, then driver_table_mutex, which driver creation takes both of.
var driver_create_mutex: std.Io.Mutex = .init;

/// Handles of every live digital driver. `isKnownDriver` uses this table to
/// tell a driver handle from a Sample3D handle, so a driver that fails to land
/// in it is misclassified and its handle is written through the wrong layout.
/// The list is grown on demand rather than capped: a fixed cap turned "one game
/// opened N drivers" into memory corruption in a 3D setter. Growth can still
/// fail, and that case is reported rather than logged, because an untracked
/// driver is exactly as unsafe as no driver at all.
/// Guarded by driver_table_mutex: register/unregister run on whichever thread
/// opened or closed the driver, and isKnownDriver is called from every 3D
/// handle-dispatch entry point.
var known_drivers: std.ArrayList(*DigitalDriver) = .empty;

/// Handles of every live MIDI driver, the digital table's counterpart.
/// last_midi_driver names one driver, and every MidiDriver.init takes that slot,
/// so the second device a game opens (AIL_DLS_open, AIL_create_wave_synthesizer)
/// displaces the one it opened first. Shutdown could only reach the slot, so
/// the displaced driver kept its allocation, its soundfont and its sequences for
/// the life of the process. Guarded by the same mutex as the digital table.
var known_midi_drivers: std.ArrayList(*MidiDriver) = .empty;
var driver_table_mutex: std.Io.Mutex = .init;

/// Returns false when the handle could not be tracked. The caller must then
/// tear the driver down instead of publishing it: an untracked handle is
/// misclassified as a Sample3D by the 3D dispatch entry points.
pub fn registerDriver(driver: *DigitalDriver) bool {
    driver_table_mutex.lockUncancelable(io);
    defer driver_table_mutex.unlock(io);
    known_drivers.append(global_allocator, driver) catch {
        log("registerDriver: driver table allocation failed; this handle cannot be tracked\n", .{});
        return false;
    };
    return true;
}

pub fn unregisterDriver(driver: *DigitalDriver) void {
    driver_table_mutex.lockUncancelable(io);
    defer driver_table_mutex.unlock(io);
    removeFirst(&known_drivers, driver);
}

pub fn registerMidiDriver(driver: *MidiDriver) void {
    driver_table_mutex.lockUncancelable(io);
    defer driver_table_mutex.unlock(io);
    known_midi_drivers.append(global_allocator, driver) catch {
        // Unlike a digital driver, an untracked MIDI one is still usable: it
        // answers its own handle. What is lost is the teardown at shutdown.
        log("registerMidiDriver: driver table allocation failed; this device will not be closed at shutdown\n", .{});
    };
}

pub fn unregisterMidiDriver(driver: *MidiDriver) void {
    driver_table_mutex.lockUncancelable(io);
    defer driver_table_mutex.unlock(io);
    removeFirst(&known_midi_drivers, driver);
}

/// How many MIDI devices are live. Not an SDK surface: the test suite reads it
/// to prove a second device (a DLS open, a wave synthesizer) is closed by the
/// teardown and not only the one the "current driver" slot names.
pub fn liveMidiDriverCount() usize {
    driver_table_mutex.lockUncancelable(io);
    defer driver_table_mutex.unlock(io);
    return known_midi_drivers.items.len;
}

/// Close every device still open, not only the ones the "current driver" slots
/// name. AIL_waveOutOpen, AIL_DLS_open and AIL_create_wave_synthesizer each
/// build a device and take that slot, so a game holding more than one leaves
/// every older one unreachable from shutdown, its engine, soundfont and
/// sequences still running past it.
///
/// Both tables are taken out whole under one lock, so the deinit each close
/// runs (which unregisters) cannot mutate what this walks, and the backing
/// store goes with the drain instead of being retained for the process.
pub fn closeAllDrivers() void {
    driver_table_mutex.lockUncancelable(io);
    var midi_drivers = known_midi_drivers;
    known_midi_drivers = .empty;
    var digital_drivers = known_drivers;
    known_drivers = .empty;
    driver_table_mutex.unlock(io);
    // MIDI first: a sequence's voices are attached to the digital engine and
    // have to be stopped before it is torn down.
    for (midi_drivers.items) |m| closeMidiDriver(m);
    for (digital_drivers.items) |d| closeDigitalDriver(d);
    midi_drivers.deinit(global_allocator);
    digital_drivers.deinit(global_allocator);
}

/// AIL_serve: the per-frame tick the game drives. The mixer itself runs on the
/// audio thread, so the work here is the part that needs the game's cadence:
/// the sources that asked for automatic 3D dead reckoning advance by the time
/// since the previous serve.
pub fn serveAllDrivers() void {
    driver_table_mutex.lockUncancelable(io);
    defer driver_table_mutex.unlock(io);
    for (known_drivers.items) |d| d.serve();
}

pub fn isKnownDriver(ptr: *anyopaque) bool {
    // Fast path: the current driver is always in the table (it is registered
    // before it is published, and unregisterDriver runs after
    // clearLastDigitalDriver), so the per-frame 3D setters can dispatch on an
    // atomic load instead of taking the table mutex and walking it.
    if (lastDigitalDriver()) |d| {
        if (@as(*anyopaque, @ptrCast(d)) == ptr) return true;
    }
    driver_table_mutex.lockUncancelable(io);
    defer driver_table_mutex.unlock(io);
    for (known_drivers.items) |d| {
        if (@as(*anyopaque, @ptrCast(d)) == ptr) return true;
    }
    return false;
}

// --- Sequence state ---

var global_sequences: std.ArrayList(*Sequence) = .empty;
var global_sequences_mutex: std.Io.Mutex = .init;

/// Returns false when the sequence could not be tracked. The caller must then
/// tear the sequence down instead of handing it back: an untracked sequence is
/// skipped by closeMidiDriver, so its sound stays attached to an engine that is
/// about to be uninitialized.
pub fn registerSequence(seq: *Sequence) bool {
    global_sequences_mutex.lockUncancelable(io);
    defer global_sequences_mutex.unlock(io);
    global_sequences.append(global_allocator, seq) catch {
        log("registerSequence: sequence table allocation failed; this handle cannot be tracked\n", .{});
        return false;
    };
    return true;
}

pub fn unregisterSequence(seq: *Sequence) void {
    global_sequences_mutex.lockUncancelable(io);
    defer global_sequences_mutex.unlock(io);
    removeFirst(&global_sequences, seq);
}

pub fn getActiveSequenceCount() u32 {
    global_sequences_mutex.lockUncancelable(io);
    defer global_sequences_mutex.unlock(io);
    var count: u32 = 0;
    for (global_sequences.items) |s| {
        if (s.is_playing.load(.acquire)) count += 1;
    }
    return count;
}

/// How many sequences are tracked, playing or not. Not an SDK surface: the
/// test suite reads it to prove a driver close left no sequence naming the
/// driver it freed.
pub fn trackedSequenceCount() usize {
    global_sequences_mutex.lockUncancelable(io);
    defer global_sequences_mutex.unlock(io);
    return global_sequences.items.len;
}

// --- Redist directory ---

// AIL_set_redist_directory is documented as callable more than once per
// session, and a game may drive it from a worker thread while its main thread
// opens a driver and reads the same path. The compare-then-copy below is one
// read-modify-write of a 256-byte buffer, so it is serialized; the scan itself
// runs outside the lock on a private copy, since loadAllAsi does directory I/O
// and the caller holds the path for the whole scan.
var redist_directory: [256:0]u8 = [_:0]u8{0} ** 256;
var redist_mutex: std.Io.Mutex = .init;

pub fn setRedistDirectory(path: []const u8) void {
    log("Setting redist directory to: {s}\n", .{path});
    // A path too long for the buffer is refused, not cut. What is stored here
    // is the directory the scan below loads and executes .asi/.m3d/.flt images
    // from, and a byte prefix of a long path is very often a different real
    // directory, most obviously a parent of the intended one, so storing the
    // prefix would move the plugin search somewhere the game and the operator
    // never named. The refusal goes to stderr, where the OPENMILES_DEBUG and
    // TMPDIR reports go as well: a caller with a too-long path has no reason to
    // have a debug log turned on.
    if (path.len > redist_directory.len - 1) {
        std.debug.print(
            "openmiles: AIL_set_redist_directory: refusing a {d}-byte path (limit {d}); the previous directory is kept and no plugins are loaded\n",
            .{ path.len, redist_directory.len - 1 },
        );
        return;
    }
    redist_mutex.lockUncancelable(io);
    const unchanged = std.mem.eql(u8, getRedistDirectoryLocked(), path);
    @memcpy(redist_directory[0..path.len], path);
    redist_directory[path.len] = 0;
    redist_mutex.unlock(io);
    // The same directory set again is the same set of plugins: rescanning it
    // would load a second copy of every .asi into a driver that already has
    // them, so the reload only happens when the directory actually changed.
    if (unchanged) return;
    const driver = lastDigitalDriver() orelse return;
    const scan_path = global_allocator.dupe(u8, path) catch {
        log("setRedistDirectory: cannot copy the path; '{s}' was not rescanned\n", .{path});
        return;
    };
    defer global_allocator.free(scan_path);
    driver.loadAllAsi(scan_path);
}

pub fn getRedistDirectory() []const u8 {
    redist_mutex.lockUncancelable(io);
    defer redist_mutex.unlock(io);
    return getRedistDirectoryLocked();
}

/// getRedistDirectory with redist_mutex already held.
fn getRedistDirectoryLocked() []const u8 {
    return std.mem.sliceTo(&redist_directory, 0);
}

/// An owned copy of the stored redist directory, taken under the lock. The
/// caller frees it.
///
/// getRedistDirectory borrows the shared buffer and drops the lock before
/// handing it back, so a caller that keeps the bytes (a scan walking the path
/// for its whole run, the way openDigitalDriver does) reads them while
/// setRedistDirectory may be rewriting them under it. A caller that only
/// compares or formats the value can use the borrowing form; one that holds on
/// to it needs this.
pub fn getRedistDirectoryCopy(allocator: std.mem.Allocator) ![]u8 {
    redist_mutex.lockUncancelable(io);
    defer redist_mutex.unlock(io);
    return allocator.dupe(u8, getRedistDirectoryLocked());
}

/// NUL-terminated pointer to the stored redist directory, for the char* return
/// of AIL_set_redist_directory. A snapshot in thread-local storage: the
/// returned pointer has to stay stable (the SDK hands back the address of its
/// own buffer), and redist_directory itself is rewritten by setRedistDirectory
/// on whatever thread calls it, so a pointer into it would be read while
/// another thread was mid-memcpy.
threadlocal var redist_scratch: [256:0]u8 = [_:0]u8{0} ** 256;

pub fn redistDirectoryZ() [*:0]const u8 {
    redist_mutex.lockUncancelable(io);
    defer redist_mutex.unlock(io);
    const len = @min(getRedistDirectoryLocked().len, redist_scratch.len - 1);
    @memcpy(redist_scratch[0..len], redist_directory[0..len]);
    redist_scratch[len] = 0;
    return &redist_scratch;
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
    log("getPreference: {d} is past the {d}-slot table; the read returns 0\n", .{ number, preferences.len });
    return 0;
}

pub fn setPreference(number: u32, value: i32) i32 {
    if (number < preferences.len) {
        const old = preferences[number];
        preferences[number] = value;
        return old;
    }
    log("setPreference: {d} is past the {d}-slot table; {d} was not stored\n", .{ number, preferences.len, value });
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
    if (std.math.isNan(gain)) return 0; // otherwise the search below converges on 127
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
    // gain below table[1]: the only neighbors left are 0 (silence) and 1, so
    // compare against their midpoint instead of returning 1 unconditionally
    // (a master gain of 1e-6 is nearer to 0).
    if (hi <= 0) return if (gain <= volume_to_gain_table[1] * 0.5) 0 else 1;
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

// --- Clock ---

/// The library's only source of monotonic time. Every deadline, period, and
/// elapsed-counter read goes through here, so a test or simulation can install
/// a virtual clock and get the same run back from the same step sequence.
pub const Clock = struct {
    // A mutex, not an atomic: the 32-bit target has no 64-bit atomics, and
    // virtual time is only read while a virtual clock is installed.
    virtual_ns: i64 = 0,
    virtual_mutex: std.Io.Mutex = .init,
    virtual_enabled: std.atomic.Value(bool) = .init(false),

    pub fn isVirtual(self: *const Clock) bool {
        return self.virtual_enabled.load(.acquire);
    }

    /// Replace the platform clock with one the caller drives. Tests and
    /// simulation only: the library always starts on the real clock, and
    /// production code never calls this. Install before starting a timer,
    /// whose thread loop would otherwise spin on a deadline no wall time
    /// reaches.
    pub fn installVirtual(self: *Clock, start_ns: i64) void {
        self.virtual_mutex.lockUncancelable(io);
        self.virtual_ns = start_ns;
        self.virtual_mutex.unlock(io);
        self.virtual_enabled.store(true, .release);
    }

    /// Back to the platform clock. Virtual time is kept, not discarded, so a
    /// test that restores the clock can still read where it left off.
    pub fn restoreReal(self: *Clock) void {
        self.virtual_enabled.store(false, .release);
    }

    /// Move virtual time forward by `ns`. Never moves it backwards: a negative
    /// step would push `nowNs` below the epoch, where every elapsed counter
    /// clamps to 0 and a rewound run reads as a stalled one.
    pub fn advance(self: *Clock, ns: i64) void {
        self.virtual_mutex.lockUncancelable(io);
        self.virtual_ns += @max(0, ns);
        self.virtual_mutex.unlock(io);
    }

    pub fn nowNs(self: *Clock) i64 {
        if (self.isVirtual()) {
            self.virtual_mutex.lockUncancelable(io);
            defer self.virtual_mutex.unlock(io);
            return self.virtual_ns;
        }
        return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
    }

    /// Wait `dur`. Under a virtual clock this moves virtual time instead of
    /// blocking, so a simulated run costs no wall time and its durations are
    /// exact rather than "at least".
    pub fn sleep(self: *Clock, dur: std.Io.Duration) void {
        if (self.isVirtual()) {
            self.advance(@intCast(@max(0, dur.nanoseconds)));
            return;
        }
        io.sleep(dur, .awake) catch {};
    }
};

pub var clock: Clock = .{};

/// Nanoseconds on the library clock. Virtual when a test or simulation has
/// installed one.
pub fn nowNs() i64 {
    return clock.nowNs();
}

/// Wait `dur` on the library clock; see `Clock.sleep`.
pub fn sleep(dur: std.Io.Duration) void {
    clock.sleep(dur);
}

// --- Simulation seed ---

// The library's only source of run-to-run randomness that reaches observable
// output: the name an ASI provider image is written under. A run that reads
// its own bytes back cannot be replayed byte-for-byte while that name comes
// from OS entropy, so the seed is the second half of what a simulated run
// needs (the virtual clock is the first). Unseeded, the draw is secure
// entropy and the name stays unguessable; seeded, it is a PRNG sequence, so
// only a simulation ever gets a predictable name out of here.
var sim_prng: ?std.Random.DefaultPrng = null;
var sim_prng_mutex: std.Io.Mutex = .init;

/// Start a simulated run at a fixed epoch with `seed` as the source for every
/// invented name. The seed and the step sequence together determine the run.
pub fn startSimulation(seed: u64) void {
    sim_prng_mutex.lockUncancelable(io);
    sim_prng = std.Random.DefaultPrng.init(seed);
    sim_prng_mutex.unlock(io);
    useVirtualClock(0);
    // The seed is the run's replay key, and the caller is usually a test
    // runner that only reports the failure, so the log line is the one place
    // it survives to the report. A run whose seed was never written down
    // cannot be replayed.
    log("startSimulation: seed=0x{x}\n", .{seed});
}

/// End a simulated run: back to the platform clock and to secure entropy.
pub fn endSimulation() void {
    sim_prng_mutex.lockUncancelable(io);
    sim_prng = null;
    sim_prng_mutex.unlock(io);
    useRealClock();
}

/// True while a simulation seed is installed.
pub fn isSimulated() bool {
    sim_prng_mutex.lockUncancelable(io);
    defer sim_prng_mutex.unlock(io);
    return sim_prng != null;
}

/// Fill `buf` with bytes for a name that must not be predictable. Secure
/// entropy in production, the seeded PRNG under a simulation, and an error
/// rather than a guessable stand-in when entropy is unavailable.
pub fn randomNameBytes(buf: []u8) !void {
    sim_prng_mutex.lockUncancelable(io);
    if (sim_prng) |*prng| {
        prng.random().bytes(buf);
        sim_prng_mutex.unlock(io);
        return;
    }
    sim_prng_mutex.unlock(io);
    try io.randomSecure(buf);
}

// --- Startup time ---

var startup_ns: i64 = 0;
var startup_ns_mutex: std.Io.Mutex = .init;
var startup_ns_ready: bool = false;

pub fn ensureStartupTime() void {
    if (@atomicLoad(bool, &startup_ns_ready, .acquire)) return;
    startup_ns_mutex.lockUncancelable(io);
    defer startup_ns_mutex.unlock(io);
    if (!startup_ns_ready) {
        startup_ns = nowNs();
        @atomicStore(bool, &startup_ns_ready, true, .release);
    }
}

/// Install a virtual clock and re-base the elapsed counters on it, so
/// AIL_ms_count and friends read from the simulated epoch rather than from
/// the wall time the process happened to start at.
pub fn useVirtualClock(start_ns: i64) void {
    clock.installVirtual(start_ns);
    startup_ns_mutex.lockUncancelable(io);
    defer startup_ns_mutex.unlock(io);
    startup_ns = nowNs();
    @atomicStore(bool, &startup_ns_ready, true, .release);
}

/// Restore the platform clock and drop the elapsed-counter base, so the next
/// count starts from the new clock.
pub fn useRealClock() void {
    clock.restoreReal();
    startup_ns_mutex.lockUncancelable(io);
    defer startup_ns_mutex.unlock(io);
    startup_ns = 0;
    @atomicStore(bool, &startup_ns_ready, false, .release);
}

fn elapsedNs() u64 {
    ensureStartupTime();
    return @intCast(@max(0, nowNs() - startup_ns));
}

pub fn getMsCount() u32 {
    return @truncate(elapsedNs() / std.time.ns_per_ms);
}

pub fn getUsCount() u32 {
    return @truncate(elapsedNs() / std.time.ns_per_us);
}

/// 64-bit millisecond/microsecond counters since startup (MSS v9 AIL_*_count64).
pub fn getMsCount64() u64 {
    return elapsedNs() / std.time.ns_per_ms;
}
pub fn getUsCount64() u64 {
    return elapsedNs() / std.time.ns_per_us;
}

// --- Lifecycle functions ---
// These encapsulate the startup/shutdown and driver open/close sequences so that
// both the standard API (AIL_startup, AIL_open_digital_driver, …) and the Quick
// API (AIL_quick_startup, AIL_quick_shutdown) share the same code path without
// lateral dependencies between api/ modules. AIL_quick_shutdown only closes the two drivers; shutdown() also releases the timers, providers, and logger.

pub fn startup() void {
    clearLastError();
    if (startup_provider.load(.acquire) != null) return;
    // Second execution of the same startup, whether it is a retry on the same
    // thread or a second thread racing the first: the check above runs again
    // under the lock, so the loser finds the published provider and returns
    // without building a second one.
    startup_mutex.lockUncancelable(io);
    defer startup_mutex.unlock(io);
    if (startup_provider.load(.acquire) != null) return;
    log("startup: ensureStartupTime\n", .{});
    ensureStartupTime();
    log("startup: Provider.init\n", .{});
    const p = Provider.init(global_allocator) catch {
        log("startup: Provider.init FAILED\n", .{});
        // AIL_startup returns a use count whatever this did, so a bring-up that
        // never happened would look like a success and every later provider
        // query would answer "absent" with nothing saying why. AIL_last_error is
        // the one channel both startup entry points share.
        setLastError("Failed to initialize the startup provider");
        return;
    };
    log("startup: get_ASI_INTERFACE\n", .{});
    var src = get_ASI_INTERFACE();

    log("startup: registerInterface\n", .{});
    _ = p.registerInterface("ASI codec", @intCast(src.len), &src) catch {
        log("startup: registerInterface FAILED\n", .{});
        p.deinit();
        setLastError("Failed to register the built-in ASI codec interface");
        return;
    };
    // Also register the same built-in decoder under "ASI stream" — games
    // query RIB_enumerate_providers("ASI stream", ...) to decide whether
    // MP3/OGG streaming is available.  The built-in miniaudio decoder
    // handles MP3, OGG, WAV and FLAC natively, so no external .asi plugins
    // are required. Not fatal: streaming is a subset of what the codec
    // interface above already serves, so the provider is published either way.
    _ = p.registerInterface("ASI stream", @intCast(src.len), &src) catch {
        log("startup: registerInterface ASI stream FAILED; streaming formats are unavailable\n", .{});
        setLastError("Streaming ASI interface unavailable");
    };
    startup_provider.store(p, .release);
    // Scan for external plugins (.asi, .m3d, .flt) — games may ship
    // proprietary codecs that we don't replace yet. These supplement (not
    // replace) the built-in provider.
    log("startup: scanning CWD for external plugins\n", .{});
    const n = loadApplicationProviders(".");
    if (n > 0) log("startup: loaded {d} external plugin(s) from CWD\n", .{n});
}

pub fn shutdown() void {
    // Deliberately not under startup_mutex, unlike startup(): the first thing
    // this does is releaseAllTimers, which joins the timer threads, and a timer
    // callback is free to call AIL_startup. Holding the lock across that join
    // puts the two threads on opposite sides of it (the callback waits for the
    // lock the teardown holds, the teardown waits for the callback to return)
    // and a game that starts up from a timer callback would hang its shutdown
    // forever. A shutdown racing a startup on another thread is the narrower
    // window this leaves, and it costs no memory: the startup's provider is
    // either already published (and so freed here) or the teardown wins and the
    // startup is a fresh bring-up, which is what a caller that raced them asked
    // for.
    //
    // MSS's AIL_shutdown releases everything startup acquired. Timer threads
    // stop first (their callbacks may touch the drivers), then MIDI sequences
    // (their voices are attached to the digital engine and must be stopped
    // before it is torn down), then the drivers themselves.
    releaseAllTimers();
    closeAllDrivers();
    // The startup provider is unpublished before it is freed, and the
    // application list is emptied under the lock, so a thread enumerating
    // providers on another sees a null pointer instead of one into freed
    // memory.
    if (startup_provider.swap(null, .acq_rel)) |p| p.deinit();
    provider_mutex.lockUncancelable(io);
    defer provider_mutex.unlock(io);
    for (global_providers.items) |p| p.deinit();
    global_providers.deinit(global_allocator);
    global_providers = .empty;
    logger.deinit();
}

/// Opens the one digital driver for the process, or returns the one already
/// open. The handle is not reference counted: closeDigitalDriver must be called
/// once, for one open, and the handle must not be released afterwards.
pub fn openDigitalDriver(frequency: u32, bits: i32, channels: i32) ?*DigitalDriver {
    clearLastError();
    driver_create_mutex.lockUncancelable(io);
    defer driver_create_mutex.unlock(io);
    if (lastDigitalDriver()) |existing| return existing;
    const ch: u32 = if (channels <= 0) 2 else @intCast(channels);
    const driver = DigitalDriver.init(global_allocator, frequency, bits, ch) catch |err| {
        log("openDigitalDriver: DigitalDriver.init failed: {any}\n", .{err});
        setLastError("Failed to initialize digital driver");
        return null;
    };
    // Recorded so the guard above engages on the second open and so shutdown
    // reaches this device; without it every AIL_open_digital_driver built
    // another miniaudio engine and left it running past AIL_shutdown.
    last_digital_driver.store(driver, .release);
    const rd = getRedistDirectoryCopy(global_allocator) catch {
        log("openDigitalDriver: cannot snapshot the redist directory; no plugins were scanned\n", .{});
        return driver;
    };
    defer global_allocator.free(rd);
    if (rd.len > 0) driver.loadAllAsi(rd);
    return driver;
}

pub fn closeDigitalDriver(driver: *DigitalDriver) void {
    clearLastDigitalDriver(driver);
    driver.deinit();
}

pub fn openMidiDriver() ?*MidiDriver {
    clearLastError();
    // Opening twice hands back the driver already open (MidiDriver.init records
    // it); a second driver would take a second soundfont with no handle the
    // caller could release. Under driver_create_mutex so two threads cannot
    // both pass the "already open" check and build two drivers.
    driver_create_mutex.lockUncancelable(io);
    defer driver_create_mutex.unlock(io);
    if (lastMidiDriver()) |existing| return existing;
    return MidiDriver.init(global_allocator) catch |err| {
        log("openMidiDriver: {any}\n", .{err});
        setLastError("Failed to initialize MIDI driver");
        return null;
    };
}

pub fn closeMidiDriver(driver: *MidiDriver) void {
    clearLastMidiDriver(driver);
    // Snapshot sequences to stop, then release mutex before the potentially
    // blocking stopAndUninit calls to avoid holding the lock during audio
    // thread synchronization.
    global_sequences_mutex.lockUncancelable(io);
    const snapshot = global_allocator.dupe(*Sequence, global_sequences.items) catch {
        // Fallback: stop sequences while holding the lock (less ideal but correct).
        // The sequences are still stopped, so the engine teardown below is safe;
        // what changes is that the driver close now blocks any thread that
        // allocates or releases a sequence handle for the duration.
        log("closeMidiDriver: cannot snapshot the sequence list; the driver's sequences are stopped under the lock\n", .{});
        for (global_sequences.items) |seq| {
            if (seq.driver != driver) continue;
            seq.stopAndUninit();
            // Dropped here as well, under the lock the table is already held:
            // a sequence left behind names a driver this close frees.
            removeFirst(&global_sequences, seq);
        }
        global_sequences_mutex.unlock(io);
        driver.deinit();
        return;
    };
    global_sequences_mutex.unlock(io);
    defer global_allocator.free(snapshot);
    for (snapshot) |seq| {
        if (seq.driver != driver) continue;
        seq.stopAndUninit();
        // The sequence goes out of the table with its driver. Left in, it
        // names a driver that is freed by the end of this call, and the next
        // walk of the table compares against that freed address: a close
        // repeated with the handle the game kept, or a close after the address
        // was handed to a new driver, stopped a live driver's sequences. The
        // handle itself stays valid, so the game's own
        // AIL_release_sequence_handle still frees it.
        unregisterSequence(seq);
    }
    driver.deinit();
}

// Test entry points live in test_root.zig (the test build's root module), which
// imports this file as the shared "openmiles" module so tests and the C-ABI api
// wrappers reference one set of types.

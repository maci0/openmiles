const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;
const DigitalDriver = openmiles.DigitalDriver;
const MidiDriver = openmiles.MidiDriver;
const Sequence = openmiles.Sequence;

pub export fn AIL_DLS_load_file(driver_opt: ?*MidiDriver, filename: [*:0]const u8, flags: u32) callconv(.winapi) ?*anyopaque {
    const driver = driver_opt orelse return null;
    log("AIL_DLS_load_file(driver={*}, filename={s}, flags={d})\n", .{ driver, filename, flags });
    openmiles.clearLastError();
    // Try custom file callbacks first (e.g. for PAK-based DLS files)
    if (openmiles.cb_file_open != null) {
        const buf = openmiles.fileCallbackReadAll(filename) catch null;
        if (buf) |b| {
            defer openmiles.global_allocator.?.free(b);
            const tsf_mod = openmiles.tsf;
            if (driver.soundfont) |sf| if (driver.owns_soundfont) tsf_mod.tsf_close(sf);
            driver.soundfont = tsf_mod.tsf_load_memory(b.ptr, @intCast(b.len));
            driver.owns_soundfont = true;
            if (driver.soundfont == null) {
                openmiles.setLastError("Failed to load DLS/SF2 from callback");
                return null;
            }
            tsf_mod.tsf_set_output(driver.soundfont, tsf_mod.TSF_STEREO_INTERLEAVED, 44100, 0);
            return @ptrCast(driver.soundfont.?);
        }
    }
    return driver.loadDLS(std.mem.span(filename)) catch {
        openmiles.setLastError("Failed to load DLS/SoundFont file");
        return null;
    };
}
pub export fn AIL_DLS_unload_file(driver_opt: ?*MidiDriver, bank: *anyopaque) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    log("AIL_DLS_unload_file(driver={*}, bank={*})\n", .{ driver, bank });
    driver.unloadDLS(bank);
}
pub export fn AIL_set_filter_DLS_preference(driver_ptr: *anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const driver: *openmiles.MidiDriver = @ptrCast(@alignCast(driver_ptr));
    const name_slice = std.mem.span(name);
    const v: *const f32 = @ptrCast(@alignCast(val));
    if (std.ascii.eqlIgnoreCase(name_slice, "cutoff")) {
        driver.dls_filter_pref_cutoff = v.*;
    } else if (std.ascii.eqlIgnoreCase(name_slice, "compression")) {
        driver.dls_filter_pref_compression = v.*;
    }
}
pub export fn AIL_filter_DLS_attribute(driver_ptr: *anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const driver: *openmiles.MidiDriver = @ptrCast(@alignCast(driver_ptr));
    const name_slice = std.mem.span(name);
    const out: *f32 = @ptrCast(@alignCast(val));
    if (std.ascii.eqlIgnoreCase(name_slice, "cutoff")) {
        out.* = driver.dls_filter_pref_cutoff;
    } else if (std.ascii.eqlIgnoreCase(name_slice, "compression")) {
        out.* = driver.dls_filter_pref_compression;
    } else {
        out.* = 0.0;
    }
}
pub export fn AIL_filter_DLS_with_XMI(driver: *anyopaque, xmi: *anyopaque, dls: *anyopaque, out: *anyopaque, out_len: *u32, flags: u32) callconv(.winapi) i32 {
    _ = driver;
    _ = xmi;
    _ = dls;
    _ = out;
    _ = out_len;
    _ = flags;
    return 0;
}
pub export fn AIL_DLS_load_memory(driver: *openmiles.MidiDriver, mem: *anyopaque, flags: u32) callconv(.winapi) ?*anyopaque {
    _ = flags;
    // Load SF2 from memory using tsf
    const tsf_mod = openmiles.tsf;
    const data: [*c]const u8 = @ptrCast(@alignCast(mem));
    // Detect size from header, or fall back to 16MB sentinel for unknown formats
    const size = blk: {
        const detected = openmiles.detectAudioSize(data);
        break :blk if (detected > 0) detected else openmiles.streaming_sentinel_size;
    };
    if (driver.soundfont) |sf| {
        if (driver.owns_soundfont) tsf_mod.tsf_close(sf);
    }
    driver.soundfont = tsf_mod.tsf_load_memory(data, @intCast(size));
    driver.owns_soundfont = true;
    if (driver.soundfont == null) return null;
    driver.soundfont_size_bytes = @intCast(size);
    tsf_mod.tsf_set_output(driver.soundfont, tsf_mod.TSF_STEREO_INTERLEAVED, 44100, 0);
    return @ptrCast(driver.soundfont.?);
}
pub export fn AIL_DLS_unload(driver: *openmiles.MidiDriver, bank: *anyopaque) callconv(.winapi) void {
    driver.unloadDLS(bank);
}
pub export fn AIL_DLS_compact(driver: *openmiles.MidiDriver) callconv(.winapi) void {
    _ = driver;
}
// MSS DLS_INFO structure (6.6-era): first field is total memory usage in bytes.
// Games typically inspect only the first field for "how much RAM does the soundfont use?"
const DlsInfo = extern struct {
    total_memory: u32,
    preset_count: u32,
    instrument_count: u32,
    sample_count: u32,
};

pub export fn AIL_DLS_get_info(driver: *openmiles.MidiDriver, bank: *anyopaque, info: *anyopaque) callconv(.winapi) i32 {
    _ = bank;
    const out: *DlsInfo = @ptrCast(@alignCast(info));
    out.* = .{
        .total_memory = driver.soundfont_size_bytes,
        .preset_count = 0,
        .instrument_count = 0,
        .sample_count = 0,
    };
    return if (driver.soundfont != null) 1 else 0;
}
pub export fn AIL_DLS_get_reverb(driver: *openmiles.MidiDriver, room_type: ?*f32, level: ?*f32, reflect_time: ?*f32) callconv(.winapi) void {
    if (room_type) |p| p.* = driver.dls_reverb_room_type;
    if (level) |p| p.* = driver.dls_reverb_level;
    if (reflect_time) |p| p.* = driver.dls_reverb_reflect_time;
}
pub export fn AIL_DLS_set_reverb(driver: *openmiles.MidiDriver, room_type: f32, level: f32, reflect_time: f32) callconv(.winapi) void {
    driver.dls_reverb_room_type = room_type;
    driver.dls_reverb_level = level;
    driver.dls_reverb_reflect_time = reflect_time;
}
pub export fn AIL_DLS_open(dig_opt: ?*DigitalDriver, seq: ?*Sequence, dls: ?*anyopaque, freq: u32, bits: i32, channels: i32, flags: u32) callconv(.winapi) ?*openmiles.MidiDriver {
    const dig = dig_opt orelse return null;
    _ = dig;
    _ = seq;
    _ = freq;
    _ = bits;
    _ = channels;
    _ = flags;
    const driver = openmiles.MidiDriver.init(openmiles.global_allocator.?) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
    if (dls) |data| {
        // dls is a pointer to in-memory DLS/SF2 data (same as AIL_DLS_load_memory).
        // Detect size from RIFF header, then load it.
        const tsf_mod = openmiles.tsf;
        const raw: [*c]const u8 = @ptrCast(@alignCast(data));
        const detected = openmiles.detectAudioSize(raw);
        const size: usize = if (detected > 0) detected else openmiles.streaming_sentinel_size;
        driver.soundfont = tsf_mod.tsf_load_memory(raw, @intCast(size));
        driver.owns_soundfont = true;
        if (driver.soundfont) |sf| {
            tsf_mod.tsf_set_output(sf, tsf_mod.TSF_STEREO_INTERLEAVED, 44100, 0);
        }
    }
    return driver;
}
pub export fn AIL_DLS_close(driver: *openmiles.MidiDriver, flags: u32) callconv(.winapi) void {
    _ = flags;
    if (openmiles.last_midi_driver == driver) openmiles.last_midi_driver = null;
    driver.deinit();
}
pub export fn AIL_set_DLS_processor(driver_ptr: *anyopaque, stage: i32, processor: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    _ = stage;
    const driver: *openmiles.MidiDriver = @ptrCast(@alignCast(driver_ptr));
    const prev: ?*anyopaque = @ptrFromInt(driver.dls_processor);
    driver.dls_processor = if (processor) |p| @intFromPtr(p) else 0;
    return prev;
}
pub export fn AIL_compress_DLS(driver: *openmiles.MidiDriver, filename: [*:0]const u8, out_filename: [*:0]const u8, flags: u32, callback: ?*anyopaque) callconv(.winapi) i32 {
    _ = driver;
    _ = filename;
    _ = out_filename;
    _ = flags;
    _ = callback;
    return 0;
}
pub export fn AIL_extract_DLS(src: *anyopaque, src_len: u32, dls_out: *anyopaque, dls_len: *u32, xmi_out: *anyopaque, xmi_len: *u32, flags: u32) callconv(.winapi) i32 {
    _ = src;
    _ = src_len;
    _ = dls_out;
    _ = dls_len;
    _ = xmi_out;
    _ = xmi_len;
    _ = flags;
    return 0;
}
pub export fn AIL_find_DLS(filename: [*:0]const u8, dls_out: *anyopaque, dls_len: *u32, xmi_out: *anyopaque, xmi_len: *u32, flags: u32) callconv(.winapi) i32 {
    _ = filename;
    _ = dls_out;
    _ = dls_len;
    _ = xmi_out;
    _ = xmi_len;
    _ = flags;
    return 0;
}
pub export fn AIL_list_DLS(filename: [*:0]const u8, out_buf: *anyopaque, out_len: u32, flags: u32, callback: ?*anyopaque) callconv(.winapi) i32 {
    _ = filename;
    _ = out_buf;
    _ = out_len;
    _ = flags;
    _ = callback;
    return 0;
}
pub export fn AIL_merge_DLS_with_XMI(dls: *anyopaque, xmi: *anyopaque, out: *anyopaque, out_len: *u32) callconv(.winapi) i32 {
    _ = dls;
    _ = xmi;
    _ = out;
    _ = out_len;
    return 0;
}
pub export fn DLSClose(driver: *openmiles.MidiDriver, bank: *anyopaque) callconv(.winapi) void {
    AIL_DLS_unload(driver, bank);
}
pub export fn DLSCompactMemory(driver: *openmiles.MidiDriver) callconv(.winapi) void {
    AIL_DLS_compact(driver);
}
pub export fn DLSGetInfo(driver: *openmiles.MidiDriver, bank: *anyopaque, info: *anyopaque) callconv(.winapi) i32 {
    return AIL_DLS_get_info(driver, bank, info);
}
pub export fn DLSLoadFile(driver_opt: ?*MidiDriver, filename: [*:0]const u8, flags: u32) callconv(.winapi) ?*anyopaque {
    return AIL_DLS_load_file(driver_opt, filename, flags);
}
pub export fn DLSLoadMemFile(driver: *openmiles.MidiDriver, mem: *anyopaque, flags: u32) callconv(.winapi) ?*anyopaque {
    return AIL_DLS_load_memory(driver, mem, flags);
}
pub export fn DLSMSSOpen(dig_opt: ?*DigitalDriver, seq: ?*Sequence, dls: ?*anyopaque, freq: u32, bits: i32, channels: i32, flags: u32) callconv(.winapi) ?*openmiles.MidiDriver {
    return AIL_DLS_open(dig_opt, seq, dls, freq, bits, channels, flags);
}
pub export fn DLSMSSGetCPU(driver: *openmiles.MidiDriver) callconv(.winapi) f32 {
    _ = driver;
    // Delegate to the primary digital driver's CPU estimate (soundfont playback
    // routes through the digital driver anyway).
    if (openmiles.last_digital_driver) |dig| {
        const active: f32 = @floatFromInt(dig.getActiveSampleCount());
        return @min((active / 32.0) * 100.0, 100.0);
    }
    return 0.0;
}
pub export fn DLSSetAttribute(driver: *openmiles.MidiDriver, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    _ = driver;
    _ = name;
    _ = val;
}
pub export fn DLSUnloadAll(driver: *openmiles.MidiDriver) callconv(.winapi) void {
    _ = driver;
}
pub export fn DLSUnloadFile(driver: *openmiles.MidiDriver, bank: *anyopaque) callconv(.winapi) void {
    AIL_DLS_unload(driver, bank);
}

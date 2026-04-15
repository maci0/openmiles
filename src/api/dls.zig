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
    if (openmiles.cb_file_open != null) {
        const buf = openmiles.fileCallbackReadAll(filename) catch null;
        if (buf) |b| {
            defer openmiles.global_allocator.free(b);
            const tsf_mod = openmiles.tsf;
            const loaded = tsf_mod.tsf_load_memory(b.ptr, @intCast(b.len));
            if (loaded == null) {
                openmiles.setLastError("Failed to load DLS/SF2 from callback");
                return null;
            }
            if (driver.soundfont) |sf| if (driver.owns_soundfont) tsf_mod.tsf_close(sf);
            driver.soundfont = loaded;
            driver.owns_soundfont = true;
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
pub export fn AIL_set_filter_DLS_preference(driver_opt: ?*MidiDriver, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    const name_slice = std.mem.span(name);
    const v: *const f32 = @ptrCast(@alignCast(val));
    if (std.ascii.eqlIgnoreCase(name_slice, "cutoff")) {
        driver.dls_filter_pref_cutoff = v.*;
    } else if (std.ascii.eqlIgnoreCase(name_slice, "compression")) {
        driver.dls_filter_pref_compression = v.*;
    }
}
pub export fn AIL_filter_DLS_attribute(driver_opt: ?*MidiDriver, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const driver = driver_opt orelse return;
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
pub export fn AIL_DLS_load_memory(driver_opt: ?*MidiDriver, mem: *anyopaque, flags: u32) callconv(.winapi) ?*anyopaque {
    const driver = driver_opt orelse return null;
    _ = flags;
    // No size parameter provided — detect buffer size from the file header to avoid OOB reads.
    const tsf_mod = openmiles.tsf;
    const data: [*c]const u8 = @ptrCast(@alignCast(mem));
    const detected = openmiles.detectAudioSize(data);
    if (detected == 0) {
        log("AIL_DLS_load_memory: could not determine SF2 size from header; refusing to load\n", .{});
        openmiles.setLastError("DLS/SF2 memory buffer has unrecognized header");
        return null;
    }
    const size = detected;
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
pub export fn AIL_DLS_unload(driver_opt: ?*MidiDriver, bank: *anyopaque) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    driver.unloadDLS(bank);
}
pub export fn AIL_DLS_compact(driver_opt: ?*MidiDriver) callconv(.winapi) void {
    _ = driver_opt;
}
// MSS DLS_INFO structure (6.6-era): first field is total memory usage in bytes.
// Games typically inspect only the first field for "how much RAM does the soundfont use?"
const DlsInfo = extern struct {
    total_memory: u32,
    preset_count: u32,
    instrument_count: u32,
    sample_count: u32,
};

pub export fn AIL_DLS_get_info(driver_opt: ?*MidiDriver, bank: *anyopaque, info: *anyopaque) callconv(.winapi) i32 {
    const driver = driver_opt orelse return 0;
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
pub export fn AIL_DLS_get_reverb(driver_opt: ?*MidiDriver, room_type: ?*f32, level: ?*f32, reflect_time: ?*f32) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    if (room_type) |p| p.* = driver.dls_reverb_room_type;
    if (level) |p| p.* = driver.dls_reverb_level;
    if (reflect_time) |p| p.* = driver.dls_reverb_reflect_time;
}
pub export fn AIL_DLS_set_reverb(driver_opt: ?*MidiDriver, room_type: f32, level: f32, reflect_time: f32) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    driver.dls_reverb_room_type = room_type;
    driver.dls_reverb_level = level;
    driver.dls_reverb_reflect_time = reflect_time;
}
pub export fn AIL_DLS_open(dig_opt: ?*DigitalDriver, seq: ?*Sequence, dls: ?*anyopaque, freq: u32, bits: i32, channels: i32, flags: u32) callconv(.winapi) ?*openmiles.MidiDriver {
    _ = dig_opt orelse return null;
    _ = seq;
    _ = freq;
    _ = bits;
    _ = channels;
    _ = flags;
    const driver = openmiles.MidiDriver.init(openmiles.global_allocator) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
    if (dls) |data| {
        const tsf_mod = openmiles.tsf;
        const raw: [*c]const u8 = @ptrCast(@alignCast(data));
        const detected = openmiles.detectAudioSize(raw);
        if (detected > 0) {
            driver.soundfont = tsf_mod.tsf_load_memory(raw, @intCast(detected));
            driver.owns_soundfont = true;
            if (driver.soundfont) |sf| {
                driver.soundfont_size_bytes = @intCast(detected);
                tsf_mod.tsf_set_output(sf, tsf_mod.TSF_STEREO_INTERLEAVED, 44100, 0);
            }
        } else {
            log("AIL_DLS_open: could not determine SF2 size from header; opening without soundfont\n", .{});
        }
    }
    return driver;
}
pub export fn AIL_DLS_close(driver_opt: ?*MidiDriver, flags: u32) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    _ = flags;
    if (openmiles.last_midi_driver == driver) openmiles.last_midi_driver = null;
    driver.deinit();
}
pub export fn AIL_set_DLS_processor(driver_opt: ?*MidiDriver, stage: i32, processor: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const driver = driver_opt orelse return null;
    _ = stage;
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
pub export fn DLSClose(driver_opt: ?*MidiDriver, bank: *anyopaque) callconv(.winapi) void {
    AIL_DLS_unload(driver_opt, bank);
}
pub export fn DLSCompactMemory(driver_opt: ?*MidiDriver) callconv(.winapi) void {
    AIL_DLS_compact(driver_opt);
}
pub export fn DLSGetInfo(driver_opt: ?*MidiDriver, bank: *anyopaque, info: *anyopaque) callconv(.winapi) i32 {
    return AIL_DLS_get_info(driver_opt, bank, info);
}
pub export fn DLSLoadFile(driver_opt: ?*MidiDriver, filename: [*:0]const u8, flags: u32) callconv(.winapi) ?*anyopaque {
    return AIL_DLS_load_file(driver_opt, filename, flags);
}
pub export fn DLSLoadMemFile(driver_opt: ?*MidiDriver, mem: *anyopaque, flags: u32) callconv(.winapi) ?*anyopaque {
    return AIL_DLS_load_memory(driver_opt, mem, flags);
}
pub export fn DLSMSSOpen(dig_opt: ?*DigitalDriver, seq: ?*Sequence, dls: ?*anyopaque, freq: u32, bits: i32, channels: i32, flags: u32) callconv(.winapi) ?*openmiles.MidiDriver {
    return AIL_DLS_open(dig_opt, seq, dls, freq, bits, channels, flags);
}
pub export fn DLSMSSGetCPU(driver_opt: ?*MidiDriver) callconv(.winapi) f32 {
    _ = driver_opt;
    // MidiDriver param unused; estimates CPU from active sample count on the primary digital driver.
    if (openmiles.last_digital_driver) |dig| {
        const active: f32 = @floatFromInt(dig.getActiveSampleCount());
        return @min((active / 32.0) * 100.0, 100.0);
    }
    return 0.0;
}
pub export fn DLSSetAttribute(driver_opt: ?*MidiDriver, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    _ = driver_opt;
    _ = name;
    _ = val;
}
pub export fn DLSUnloadAll(driver_opt: ?*MidiDriver) callconv(.winapi) void {
    _ = driver_opt;
}
pub export fn DLSUnloadFile(driver_opt: ?*MidiDriver, bank: *anyopaque) callconv(.winapi) void {
    AIL_DLS_unload(driver_opt, bank);
}

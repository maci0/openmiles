const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;
const DigitalDriver = openmiles.DigitalDriver;
const MidiDriver = openmiles.MidiDriver;
const Sequence = openmiles.Sequence;
const dls_container = openmiles.dls_container;

/// Copy `src` into a buffer allocated with the C allocator so the caller can
/// release it via `AIL_mem_free_lock` (which calls `free`). Returns null on OOM.
fn cmemdup(src: []const u8) ?*anyopaque {
    const p = std.c.malloc(src.len) orelse return null;
    const dst: [*]u8 = @ptrCast(p);
    @memcpy(dst[0..src.len], src);
    return p;
}

pub fn AIL_DLS_load_file(driver_opt: ?*MidiDriver, filename: [*:0]const u8, flags: u32) callconv(.winapi) ?*anyopaque {
    const driver = driver_opt orelse return null;
    log("AIL_DLS_load_file(driver={*}, filename={s}, flags={d})\n", .{ driver, filename, flags });
    openmiles.clearLastError();
    if (openmiles.cb_file_open != null) {
        const buf = openmiles.fileCallbackReadAll(filename) catch null;
        if (buf) |b| {
            defer openmiles.global_allocator.free(b);
            const tsf_mod = openmiles.tsf;
            const loaded = tsf_mod.tsf_load_memory(b.ptr, @intCast(@min(b.len, @as(usize, std.math.maxInt(c_int)))));
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
pub fn AIL_DLS_unload_file(driver_opt: ?*MidiDriver, bank: *anyopaque) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    log("AIL_DLS_unload_file(driver={*}, bank={*})\n", .{ driver, bank });
    driver.unloadDLS(bank);
}
pub fn AIL_set_filter_DLS_preference(driver_opt: ?*MidiDriver, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    const name_slice = std.mem.span(name);
    const v: *const f32 = @ptrCast(@alignCast(val));
    if (std.ascii.eqlIgnoreCase(name_slice, "cutoff")) {
        driver.dls_filter_pref_cutoff = v.*;
    } else if (std.ascii.eqlIgnoreCase(name_slice, "compression")) {
        driver.dls_filter_pref_compression = v.*;
    }
}
pub fn AIL_filter_DLS_attribute(driver_opt: ?*MidiDriver, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
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
/// AIL_filter_DLS_with_XMI(xmi, dls, dlsout, dlssize, flags, callback)
/// Produce a DLS bank usable by the given XMI. A fully faithful implementation
/// prunes instruments the XMI never references; we instead pass the DLS through
/// unmodified (a valid superset — every referenced instrument is retained, so the
/// sequence renders identically). Returns 1 and hands back a freshly allocated
/// copy the caller frees with AIL_mem_free_lock.
pub fn AIL_filter_DLS_with_XMI(xmi: ?*const anyopaque, dls: ?*const anyopaque, dlsout: ?*?*anyopaque, dlssize: ?*u32, flags: i32, callback: ?*anyopaque) callconv(.winapi) i32 {
    _ = xmi;
    _ = flags;
    _ = callback;
    if (dlsout) |pp| pp.* = null;
    if (dlssize) |p| p.* = 0;
    const dp = dls orelse return 0;
    const raw: [*]const u8 = @ptrCast(dp);
    const sz = openmiles.detectAudioSize(raw);
    if (sz == 0) {
        openmiles.setLastError("AIL_filter_DLS_with_XMI: unrecognized DLS image");
        return 0;
    }
    const copy = cmemdup(raw[0..sz]) orelse return 0;
    if (dlsout) |pp| pp.* = copy;
    if (dlssize) |p| p.* = @intCast(sz);
    return 1;
}
pub fn AIL_DLS_load_memory(driver_opt: ?*MidiDriver, mem: *anyopaque, flags: u32) callconv(.winapi) ?*anyopaque {
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
    // `size` is taken from the file header (detectAudioSize), so an adversarial
    // header can claim ~4GB. tsf_load_memory takes a C `int`; a buffer larger
    // than that can't exist in the 32-bit target's address space, so such a
    // header is necessarily bogus — reject it instead of casting (which would
    // panic) or truncating (which would make tsf read out of bounds).
    if (size > std.math.maxInt(c_int)) {
        openmiles.setLastError("DLS/SF2 header declares an implausible size");
        return null;
    }
    if (driver.soundfont) |sf| {
        if (driver.owns_soundfont) tsf_mod.tsf_close(sf);
    }
    driver.soundfont = tsf_mod.tsf_load_memory(data, @intCast(size));
    driver.owns_soundfont = true;
    if (driver.soundfont == null) return null;
    driver.soundfont_size_bytes = @intCast(@min(size, std.math.maxInt(u32)));
    tsf_mod.tsf_set_output(driver.soundfont, tsf_mod.TSF_STEREO_INTERLEAVED, 44100, 0);
    return @ptrCast(driver.soundfont.?);
}
pub fn AIL_DLS_unload(driver_opt: ?*MidiDriver, bank: *anyopaque) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    driver.unloadDLS(bank);
}
pub fn AIL_DLS_compact(driver_opt: ?*MidiDriver) callconv(.winapi) void {
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

pub fn AIL_DLS_get_info(driver_opt: ?*MidiDriver, bank: *anyopaque, info: *anyopaque) callconv(.winapi) i32 {
    const driver = driver_opt orelse return 0;
    _ = bank;
    const out: *DlsInfo = @ptrCast(@alignCast(info));
    const presets: u32 = if (driver.soundfont) |sf| blk: {
        const n = openmiles.tsf.tsf_get_presetcount(sf);
        break :blk if (n > 0) @intCast(n) else 0;
    } else 0;
    out.* = .{
        .total_memory = driver.soundfont_size_bytes,
        .preset_count = presets,
        // TSF exposes preset count only; SF2 instrument/sample subcounts are not
        // surfaced separately, so report presets as the instrument count.
        .instrument_count = presets,
        .sample_count = 0,
    };
    return if (driver.soundfont != null) 1 else 0;
}
pub fn AIL_DLS_get_reverb(driver_opt: ?*MidiDriver, room_type: ?*f32, level: ?*f32, reflect_time: ?*f32) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    if (room_type) |p| p.* = driver.dls_reverb_room_type;
    if (level) |p| p.* = driver.dls_reverb_level;
    if (reflect_time) |p| p.* = driver.dls_reverb_reflect_time;
}
pub fn AIL_DLS_set_reverb(driver_opt: ?*MidiDriver, room_type: f32, level: f32, reflect_time: f32) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    driver.dls_reverb_room_type = room_type;
    driver.dls_reverb_level = level;
    driver.dls_reverb_reflect_time = reflect_time;
}
// 6.5/6.6 only: dry/wet level pair for the DLS device's reverb send (HDLSDEVICE
// is our MidiDriver). Stored and queried back; not actively mixed.
pub fn AIL_DLS_set_reverb_levels(driver_opt: ?*MidiDriver, dry_level: f32, wet_level: f32) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    driver.dls_reverb_dry_level = dry_level;
    driver.dls_reverb_level = wet_level;
}
pub fn AIL_DLS_get_reverb_levels(driver_opt: ?*MidiDriver, dry_level: ?*f32, wet_level: ?*f32) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    if (dry_level) |p| p.* = driver.dls_reverb_dry_level;
    if (wet_level) |p| p.* = driver.dls_reverb_level;
}
// SDK (all versions): AIL_DLS_open(HMDIDRIVER mdi, HDIGDRIVER dig,
// char const* libname, U32 flags, U32 rate, S32 bits, S32 channels) -> HDLSDEVICE.
// libname is the DLS/SF2 *file name* to load; mdi/dig are the MIDI/digital
// drivers the device renders through. Our HDLSDEVICE is a MidiDriver with the
// named library loaded as its soundfont.
pub fn AIL_DLS_open(mdi_opt: ?*MidiDriver, dig_opt: ?*DigitalDriver, libname: ?[*:0]const u8, flags: u32, rate: u32, bits: i32, channels: i32) callconv(.winapi) ?*openmiles.MidiDriver {
    _ = mdi_opt;
    _ = dig_opt;
    _ = flags;
    _ = rate;
    _ = bits;
    _ = channels;
    const driver = openmiles.MidiDriver.init(openmiles.global_allocator) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
    if (libname) |name| {
        _ = driver.loadDLS(std.mem.span(name)) catch {
            log("AIL_DLS_open: failed to load DLS library '{s}'\n", .{name});
        };
    }
    return driver;
}
pub fn AIL_DLS_close(driver_opt: ?*MidiDriver, flags: u32) callconv(.winapi) void {
    const driver = driver_opt orelse return;
    _ = flags;
    if (openmiles.last_midi_driver == driver) openmiles.last_midi_driver = null;
    driver.deinit();
}
pub fn AIL_set_DLS_processor(driver_opt: ?*MidiDriver, stage: i32, processor: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const driver = driver_opt orelse return null;
    _ = stage;
    const prev: ?*anyopaque = @ptrFromInt(driver.dls_processor);
    driver.dls_processor = if (processor) |p| @intFromPtr(p) else 0;
    return prev;
}
/// AIL_compress_DLS(dls, compression_extension, mls, mlssize, callback)
/// Compresses the DLS wave pool with an ASI codec. OpenMiles bundles only
/// decoders (via miniaudio), so encoding is unsupported; returns 0 (failure).
pub fn AIL_compress_DLS(dls: ?*const anyopaque, compression_extension: [*:0]const u8, mls: ?*?*anyopaque, mlssize: ?*u32, callback: ?*anyopaque) callconv(.winapi) i32 {
    _ = dls;
    _ = compression_extension;
    _ = callback;
    if (mls) |pp| pp.* = null;
    if (mlssize) |p| p.* = 0;
    openmiles.setLastError("AIL_compress_DLS: DLS compression (encoding) not supported");
    return 0;
}

/// AIL_extract_DLS(source, source_size, xmi_out, xmi_size, dls_out, dls_size, callback)
/// Split a merged XMI+DLS image into freshly allocated XMI and DLS copies.
/// Outputs are allocated with the C allocator; free each with AIL_mem_free_lock.
/// Returns 1 if at least one sub-image was extracted, 0 otherwise.
pub fn AIL_extract_DLS(src: ?*const anyopaque, src_len: u32, xmi_out: ?*?*anyopaque, xmi_len: ?*u32, dls_out: ?*?*anyopaque, dls_len: ?*u32, callback: ?*anyopaque) callconv(.winapi) i32 {
    _ = callback;
    if (xmi_out) |pp| pp.* = null;
    if (xmi_len) |p| p.* = 0;
    if (dls_out) |pp| pp.* = null;
    if (dls_len) |p| p.* = 0;
    const sp = src orelse return 0;
    const raw: [*]const u8 = @ptrCast(sp);
    const data = raw[0..@as(usize, src_len)];
    var found: i32 = 0;

    if (dls_container.findDls(data)) |dls_img| {
        if (cmemdup(dls_img)) |c| {
            if (dls_out) |pp| pp.* = c;
            if (dls_len) |p| p.* = @intCast(dls_img.len);
            found = 1;
        }
        // The XMI image, when present, is everything preceding the DLS bank.
        const off = @intFromPtr(dls_img.ptr) - @intFromPtr(data.ptr);
        if (off > 0 and dls_container.findXmi(data[0..off]) != null) {
            if (cmemdup(data[0..off])) |c| {
                if (xmi_out) |pp| pp.* = c;
                if (xmi_len) |p| p.* = @intCast(off);
            }
        }
    } else if (dls_container.findXmi(data)) |xmi_img| {
        if (cmemdup(xmi_img)) |c| {
            if (xmi_out) |pp| pp.* = c;
            if (xmi_len) |p| p.* = @intCast(xmi_img.len);
            found = 1;
        }
    }
    return found;
}

/// AIL_find_DLS(data, size, xmi, xmisize, dls, dlssize)
/// Locate the XMI and DLS sub-images inside a merged image without copying;
/// output pointers reference the original buffer. Returns 1 if a DLS bank is
/// present, 0 otherwise (the XMI pointer is still filled in when found).
pub fn AIL_find_DLS(data_ptr: ?*const anyopaque, size: u32, xmi_out: ?*?*anyopaque, xmi_len: ?*u32, dls_out: ?*?*anyopaque, dls_len: ?*u32) callconv(.winapi) i32 {
    if (xmi_out) |pp| pp.* = null;
    if (xmi_len) |p| p.* = 0;
    if (dls_out) |pp| pp.* = null;
    if (dls_len) |p| p.* = 0;
    const dp = data_ptr orelse return 0;
    const raw: [*]const u8 = @ptrCast(dp);
    const data = raw[0..@as(usize, size)];
    var ok: i32 = 0;

    if (dls_container.findDls(data)) |dls_img| {
        if (dls_out) |pp| pp.* = @constCast(@ptrCast(dls_img.ptr));
        if (dls_len) |p| p.* = @intCast(dls_img.len);
        ok = 1;
        const off = @intFromPtr(dls_img.ptr) - @intFromPtr(data.ptr);
        if (off > 0 and dls_container.findXmi(data[0..off]) != null) {
            if (xmi_out) |pp| pp.* = @constCast(@ptrCast(data.ptr));
            if (xmi_len) |p| p.* = @intCast(off);
        }
    } else if (dls_container.findXmi(data)) |xmi_img| {
        if (xmi_out) |pp| pp.* = @constCast(@ptrCast(xmi_img.ptr));
        if (xmi_len) |p| p.* = @intCast(xmi_img.len);
    }
    return ok;
}

/// AIL_list_DLS(dls, lst, lst_size, flags, title)
/// Build a human-readable listing of a DLS bank (instrument count from the
/// `colh` chunk). Output text is C-allocated; free with AIL_mem_free_lock.
pub fn AIL_list_DLS(dls: ?*const anyopaque, lst: ?*?*anyopaque, lst_size: ?*u32, flags: i32, title: ?[*:0]const u8) callconv(.winapi) i32 {
    _ = flags;
    if (lst) |pp| pp.* = null;
    if (lst_size) |p| p.* = 0;
    const dp = dls orelse return 0;
    const raw: [*]const u8 = @ptrCast(dp);
    const sz = openmiles.detectAudioSize(raw);
    if (sz == 0) return 0;
    const data = raw[0..sz];

    var instruments: u32 = 0;
    if (std.mem.indexOf(u8, data, "colh")) |idx| {
        if (idx + 12 <= data.len) {
            instruments = std.mem.readInt(u32, data[idx + 8 .. idx + 12][0..4], .little);
        }
    }
    const title_slice = if (title) |t| std.mem.span(t) else "DLS";
    const text = std.fmt.allocPrintSentinel(openmiles.global_allocator, "{s}\nDLS bank: {d} bytes, {d} instrument(s)\n", .{ title_slice, sz, instruments }, 0) catch return 0;
    defer openmiles.global_allocator.free(text);
    const out = cmemdup(text[0 .. text.len + 1]) orelse return 0; // include NUL
    if (lst) |pp| pp.* = out;
    if (lst_size) |p| p.* = @intCast(text.len);
    return 1;
}

/// AIL_merge_DLS_with_XMI(xmi, dls, mss, msssize)
/// Concatenate an XMI image and a DLS bank into a single merged image (the
/// format AIL_find_DLS/AIL_extract_DLS split). Output is C-allocated; free with
/// AIL_mem_free_lock. Returns 1 on success.
pub fn AIL_merge_DLS_with_XMI(xmi: ?*const anyopaque, dls: ?*const anyopaque, out: ?*?*anyopaque, out_len: ?*u32) callconv(.winapi) i32 {
    if (out) |pp| pp.* = null;
    if (out_len) |p| p.* = 0;
    const xp = xmi orelse return 0;
    const dp = dls orelse return 0;
    const xraw: [*]const u8 = @ptrCast(xp);
    const draw: [*]const u8 = @ptrCast(dp);

    const xsz = dls_container.xmiImageSizePtr(xraw);
    const dsz = openmiles.detectAudioSize(draw);
    if (xsz == 0 or dsz == 0) {
        openmiles.setLastError("AIL_merge_DLS_with_XMI: unrecognized XMI or DLS image");
        return 0;
    }

    const total = xsz + dsz;
    const buf = std.c.malloc(total) orelse return 0;
    const dst: [*]u8 = @ptrCast(buf);
    @memcpy(dst[0..xsz], xraw[0..xsz]);
    @memcpy(dst[xsz .. xsz + dsz], draw[0..dsz]);
    if (out) |pp| pp.* = buf;
    if (out_len) |p| p.* = @intCast(total);
    return 1;
}
pub fn DLSClose(driver_opt: ?*MidiDriver, bank: *anyopaque) callconv(.c) void {
    AIL_DLS_unload(driver_opt, bank);
}
pub fn DLSCompactMemory(driver_opt: ?*MidiDriver) callconv(.c) void {
    AIL_DLS_compact(driver_opt);
}
pub fn DLSGetInfo(driver_opt: ?*MidiDriver, bank: *anyopaque, info: *anyopaque) callconv(.c) i32 {
    return AIL_DLS_get_info(driver_opt, bank, info);
}
pub fn DLSLoadFile(driver_opt: ?*MidiDriver, filename: [*:0]const u8, flags: u32) callconv(.c) ?*anyopaque {
    return AIL_DLS_load_file(driver_opt, filename, flags);
}
pub fn DLSLoadMemFile(driver_opt: ?*MidiDriver, mem: *anyopaque, flags: u32) callconv(.c) ?*anyopaque {
    return AIL_DLS_load_memory(driver_opt, mem, flags);
}
pub fn DLSMSSOpen(mdi_opt: ?*MidiDriver, dig_opt: ?*DigitalDriver, libname: ?[*:0]const u8, flags: u32, rate: u32, bits: i32, channels: i32) callconv(.c) ?*openmiles.MidiDriver {
    return AIL_DLS_open(mdi_opt, dig_opt, libname, flags, rate, bits, channels);
}
pub fn DLSMSSGetCPU(driver_opt: ?*MidiDriver) callconv(.winapi) f32 {
    _ = driver_opt;
    // MidiDriver param unused; estimates CPU from active sample count on the primary digital driver.
    if (openmiles.last_digital_driver) |dig| {
        const active: f32 = @floatFromInt(dig.getActiveSampleCount());
        return @min((active / 32.0) * 100.0, 100.0);
    }
    return 0.0;
}
pub fn DLSSetAttribute(driver_opt: ?*MidiDriver, name: [*:0]const u8, val: *anyopaque) callconv(.c) void {
    const driver = driver_opt orelse return;
    const name_slice = std.mem.span(name);
    const v: *const f32 = @ptrCast(@alignCast(val));
    if (std.ascii.eqlIgnoreCase(name_slice, "cutoff")) {
        driver.dls_filter_pref_cutoff = v.*;
    } else if (std.ascii.eqlIgnoreCase(name_slice, "compression")) {
        driver.dls_filter_pref_compression = v.*;
    }
}
pub fn DLSUnloadAll(driver_opt: ?*MidiDriver) callconv(.c) void {
    const driver = driver_opt orelse return;
    if (driver.soundfont) |sf| {
        if (driver.owns_soundfont) openmiles.tsf.tsf_close(sf);
        driver.soundfont = null;
        driver.owns_soundfont = true;
        driver.soundfont_size_bytes = 0;
    }
}
pub fn DLSUnloadFile(driver_opt: ?*MidiDriver, bank: *anyopaque) callconv(.c) void {
    AIL_DLS_unload(driver_opt, bank);
}

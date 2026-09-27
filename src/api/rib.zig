const std = @import("std");
const builtin = @import("builtin");
const openmiles = @import("openmiles");
const log = openmiles.log;
const io = openmiles.io;
const wide = openmiles.wide;

const Sample = openmiles.Sample;
const Provider = openmiles.Provider;

pub fn RIB_alloc_provider_handle(module: *anyopaque) callconv(.c) ?*Provider {
    log("RIB_alloc_provider_handle(module={*})\n", .{module});
    return Provider.init(openmiles.global_allocator, module) catch |err| {
        log("Error: {any}\n", .{err});
        openmiles.setLastError("Failed to allocate provider handle");
        return null;
    };
}
pub fn RIB_free_provider_handle(provider_opt: ?*Provider) callconv(.c) void {
    const provider = provider_opt orelse return;
    log("RIB_free_provider_handle(provider={*})\n", .{provider});
    provider.deinit();
}
pub fn RIB_register_interface(provider_opt: ?*Provider, name: [*:0]const u8, count: i32, entries: ?*anyopaque) callconv(.c) void {
    const provider = provider_opt orelse return;
    log("RIB_register_interface(provider={*}, name={s}, count={d}, entries={*})\n", .{ provider, name, count, entries });
    provider.registerInterface(std.mem.span(name), count, entries) catch |err| {
        log("RIB_register_interface: failed: {any}\n", .{err});
    };
}
pub fn RIB_unregister_interface(provider_opt: ?*Provider, name: [*:0]const u8, count: i32, entries: *anyopaque) callconv(.c) void {
    const provider = provider_opt orelse return;
    log("RIB_unregister_interface(provider={*}, name={s}, count={d}, entries={*})\n", .{ provider, name, count, entries });
    provider.unregisterInterface(std.mem.span(name));
}
pub fn RIB_provider_library_handle() callconv(.winapi) ?*anyopaque {
    log("RIB_provider_library_handle()\n", .{});
    if (openmiles.getCurrentLoadingProvider()) |p| return @ptrCast(p);
    return @ptrCast(openmiles.startupProvider());
}
pub fn RIB_load_application_providers(dir: [*:0]const u8) callconv(.winapi) i32 {
    const dir_str = std.mem.span(dir);
    log("RIB_load_application_providers(dir={s})\n", .{dir_str});
    const count = openmiles.loadApplicationProviders(dir_str);
    return if (count >= 0) 1 else 0;
}
pub fn RIB_enumerate_providers(name: [*:0]const u8, next: ?*?*anyopaque, handle: ?*?*Provider) callconv(.winapi) i32 {
    const iface_name = std.mem.span(name);
    log("RIB_enumerate_providers(name='{s}', next={*}, handle={*})\n", .{ iface_name, next, handle });

    // next.* encodes cursor position: null means start, otherwise (last_returned_index + 1).
    var cursor: usize = if (next) |n| if (n.*) |v| @intFromPtr(v) else 0 else 0;

    // Indexed one at a time through the provider lock: handing the caller the
    // backing slice would let a concurrent scan's append realloc free the
    // buffer this loop is walking.
    const startup = openmiles.startupProvider();
    const global_base: usize = if (startup != null) 1 else 0;
    const total = global_base + openmiles.getProviderCount();

    while (cursor < total) : (cursor += 1) {
        const p: *Provider = if (cursor == 0 and startup != null)
            startup.?
        else
            openmiles.getProviderAt(cursor - global_base) orelse break;

        const has_iface = for (p.interfaces.items) |iface| {
            if (std.mem.eql(u8, iface.name, iface_name)) break true;
        } else false;

        if (has_iface) {
            if (handle) |h| h.* = p;
            if (next) |n| n.* = @ptrFromInt(cursor + 1);
            return 1;
        }
    }

    if (next) |n| n.* = null;
    if (handle) |h| h.* = null;
    return 0;
}
pub fn RIB_request_interface(provider_opt: ?*Provider, name: [*:0]const u8, count: i32, entries: *anyopaque) callconv(.c) i32 {
    const provider = provider_opt orelse return 0;
    log("RIB_request_interface(provider={*}, name={s}, count={d}, entries={*})\n", .{ provider, name, count, entries });
    const iface_name = std.mem.span(name);
    const dest: [*]openmiles.RIB_INTERFACE_ENTRY = @ptrCast(@alignCast(entries));
    const n: usize = @intCast(@max(0, count));

    for (provider.interfaces.items) |iface| {
        if (std.mem.eql(u8, iface.name, iface_name)) {
            for (dest[0..n]) |*entry| {
                const ename = std.mem.span(entry.name);
                if (iface.tokenFor(ename)) |tok| {
                    entry.token = tok;
                }
            }
            return 1;
        }
    }

    // Fall back: if requesting ASI codec from the startup provider, return our built-in
    if (std.mem.eql(u8, iface_name, "ASI codec")) {
        const src = openmiles.get_ASI_INTERFACE();
        const limit = @min(n, src.len);
        for (src[0..limit], 0..) |entry, i| {
            dest[i] = entry;
        }
        return 1;
    }

    return 0;
}
pub fn RIB_find_files_provider(name: [*:0]const u8, property: [*:0]const u8, filename: [*:0]const u8, search_dir: [*:0]const u8, file_ext: [*:0]const u8) callconv(.winapi) ?*Provider {
    log("RIB_find_files_provider(name='{s}', property='{s}', filename='{s}', search_dir='{s}', file_ext='{s}')\n", .{ std.mem.span(name), std.mem.span(property), std.mem.span(filename), std.mem.span(search_dir), std.mem.span(file_ext) });
    var handle: ?*Provider = null;
    _ = RIB_enumerate_providers(name, null, &handle);
    return handle;
}
/// GetTempPathW writes at most MAX_PATH UTF-16 units, terminating NUL included;
/// the UTF-8 form of a path that long needs up to three bytes per unit.
const max_temp_path_units: usize = 260;

/// Directory for the unpacked ASI image, with a trailing separator so callers
/// can append a file name to it. Returns null when no temp directory can be
/// determined, leaving the caller to fall back to the current directory.
fn tempDir(buf: []u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        const GetTempPathW = struct {
            extern "kernel32" fn GetTempPathW(nBufferLength: u32, lpBuffer: [*]u16) callconv(.winapi) u32;
        }.GetTempPathW;
        var wbuf: [max_temp_path_units]u16 = undefined;
        const len = GetTempPathW(wbuf.len, &wbuf);
        if (len == 0 or len >= wbuf.len) return null;
        if (wide.utf8LenBound(wbuf[0..len]) > buf.len) return null;
        const dir = wide.toUtf8(wbuf[0..len], buf) catch return null;
        return appendSeparator(buf, dir);
    }
    // TMPDIR is the POSIX convention; the game directory (the process cwd under
    // Wine) is the fallback, and the caller covers that case too.
    const tmp = std.c.getenv("TMPDIR") orelse return null;
    const dir = std.mem.span(@as([*:0]const u8, tmp));
    if (dir.len == 0 or dir.len > buf.len - 2) return null;
    @memcpy(buf[0..dir.len], dir);
    return appendSeparator(buf, buf[0..dir.len]);
}

fn appendSeparator(buf: []u8, dir: []const u8) ?[]const u8 {
    if (dir.len == 0) return null;
    const n = dir.len + @intFromBool(!std.fs.path.isSep(dir[dir.len - 1]));
    if (n > buf.len) return null;
    if (n != dir.len) buf[n - 1] = std.fs.path.sep;
    return buf[0..n];
}

/// Drop a temp image written for a provider that is being abandoned. Tries the
/// absolute form first, then the cwd-relative one. A file that survives both
/// attempts is never retried, because the caller's only record of the path is
/// about to go away, so the leak is reported.
fn deleteTempImage(path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, path) catch {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| {
            log("AIL_open_ASI_provider: cannot delete temp image '{s}' ({any}); it stays on disk\n", .{ path, err });
        };
    };
}

pub fn AIL_open_ASI_provider(buffer: *const anyopaque, size: u32) callconv(.winapi) ?*Provider {
    log("AIL_open_ASI_provider(buffer={*}, size={d})\n", .{ buffer, size });
    if (size < 2) {
        log("AIL_open_ASI_provider: image is {d} bytes, too short for an MZ header\n", .{size});
        openmiles.setLastError("ASI provider image is too small");
        return null;
    }
    const raw: []const u8 = @as([*]const u8, @ptrCast(@alignCast(buffer)))[0..size];
    if (raw[0] != 'M' or raw[1] != 'Z') {
        log("AIL_open_ASI_provider: image does not start with MZ\n", .{});
        openmiles.setLastError("ASI provider image is not a DOS/PE image");
        return null;
    }

    // Long enough for a maximally wide temp directory plus the fixed name tail,
    // so a non-ASCII %TEMP% cannot turn the format into a failure.
    var path_buf: [max_temp_path_units * 3 + 32:0]u8 = undefined;

    var tmp_dir_buf: [max_temp_path_units * 3]u8 = undefined;
    const tmp_dir = tempDir(&tmp_dir_buf);

    // The image is written to TEMP and then LoadLibrary'd, so the file name must
    // not be predictable: a sequential counter would let a local process plant
    // (or race-replace) om_asi_<next>.dll ahead of us and get its own code loaded
    // into this one. A random name created exclusively closes both routes.
    var path: [:0]const u8 = "";
    var created: ?std.Io.File = null;
    // Entropy for the name; without it the unpredictable-name guarantee is gone,
    // so fail closed rather than fall back to a guessable pattern.
    var id_bytes: [8]u8 = undefined;
    io.randomSecure(&id_bytes) catch |err| {
        log("AIL_open_ASI_provider: no entropy for temp file name: {any}\n", .{err});
        openmiles.setLastError("No entropy available for ASI temp file name");
        return null;
    };
    var id = std.mem.readInt(u64, &id_bytes, .little);
    const name_attempts = 4;
    for (0..name_attempts) |_| {
        path = if (tmp_dir) |dir|
            std.fmt.bufPrintZ(&path_buf, "{s}om_asi_{x:016}.dll", .{ dir, id }) catch |err| {
                log("AIL_open_ASI_provider: cannot format temp path: {any}\n", .{err});
                openmiles.setLastError("Failed to format temp path for ASI provider");
                return null;
            }
        else
            std.fmt.bufPrintZ(&path_buf, "./om_asi_{x:016}.dll", .{id}) catch |err| {
                log("AIL_open_ASI_provider: cannot format temp path: {any}\n", .{err});
                openmiles.setLastError("Failed to format temp path for ASI provider");
                return null;
            };
        if (std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true })) |f| {
            created = f;
            break;
        } else |abs_err| switch (abs_err) {
            // An occupied name retries with a fresh id; any other absolute-open
            // failure falls through to the cwd-relative attempt.
            error.PathAlreadyExists => {
                id +%= 1;
                continue;
            },
            else => {},
        }
        if (std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true })) |f| {
            created = f;
            break;
        } else |cwd_err| switch (cwd_err) {
            error.PathAlreadyExists => {
                id +%= 1;
                continue;
            },
            else => {
                log("AIL_open_ASI_provider: creating '{s}' failed ({any})\n", .{ path, cwd_err });
                openmiles.setLastError("Failed to create temp file for ASI provider");
                return null;
            },
        }
    }
    const wf = created orelse {
        log("AIL_open_ASI_provider: no free temp name after {d} collisions (last '{s}')\n", .{ name_attempts, path });
        openmiles.setLastError("Failed to create temp file for ASI provider");
        return null;
    };
    wf.writeStreamingAll(io, raw) catch |err| {
        log("AIL_open_ASI_provider: writing {d} bytes to '{s}' failed ({any})\n", .{ size, path, err });
        wf.close(io);
        deleteTempImage(path);
        openmiles.setLastError("Failed to write temp file for ASI provider");
        return null;
    };
    wf.close(io);

    // Load the provider (calls RIB_Main inside the DLL). On success the
    // Provider owns deleting the temp image: it records the path and removes
    // the file when released, once the OS has unlocked the loaded module. The
    // file must outlive the provider here — Windows cannot delete a loaded DLL.
    const p = openmiles.Provider.load(openmiles.global_allocator, path) catch |err| {
        log("AIL_open_ASI_provider: loading '{s}' failed ({any})\n", .{ path, err });
        deleteTempImage(path);
        openmiles.setLastError("Failed to load ASI provider image");
        return null;
    };
    p.temp_path = openmiles.global_allocator.dupeZ(u8, path) catch |err| {
        // Without the recorded path the temp image can never be deleted (the
        // provider would otherwise leak one loaded-DLL file per call), so fail
        // the open rather than leave the file behind.
        log("AIL_open_ASI_provider: cannot record temp path '{s}' ({any})\n", .{ path, err });
        p.deinit();
        deleteTempImage(path);
        openmiles.setLastError("Failed to record temp path for ASI provider");
        return null;
    };
    return p;
}
pub fn AIL_close_ASI_provider(provider_opt: ?*Provider) callconv(.winapi) void {
    const provider = provider_opt orelse return;
    log("AIL_close_ASI_provider(provider={*})\n", .{provider});
    provider.deinit();
}
pub fn AIL_ASI_provider_attribute(provider_opt: ?*Provider, name: [*:0]const u8) callconv(.winapi) ?*anyopaque {
    const provider = provider_opt orelse return null;
    log("AIL_ASI_provider_attribute(provider={*}, name={s})\n", .{ provider, name });
    const attr_name = std.mem.span(name);
    for (provider.interfaces.items) |iface| {
        if (iface.tokenFor(attr_name)) |token| return @ptrFromInt(token);
    }
    return null;
}
pub fn RIB_error() callconv(.c) [*:0]const u8 {
    return "No error";
}
pub fn RIB_find_file_provider(name: [*:0]const u8, property: [*:0]const u8, filename: [*:0]const u8) callconv(.c) ?*Provider {
    log("RIB_find_file_provider(name='{s}', property='{s}', filename='{s}')\n", .{ std.mem.span(name), std.mem.span(property), std.mem.span(filename) });
    var handle: ?*Provider = null;
    _ = RIB_enumerate_providers(name, null, &handle);
    return handle;
}
pub fn RIB_load_provider_library(path: [*:0]const u8) callconv(.c) ?*Provider {
    const p = openmiles.Provider.load(openmiles.global_allocator, std.mem.span(path)) catch |err| {
        log("RIB_load_provider_library: loading '{s}' failed ({any})\n", .{ std.mem.span(path), err });
        openmiles.setLastError("Failed to load provider library");
        return null;
    };
    return p;
}
pub fn RIB_free_provider_library(provider_opt: ?*Provider) callconv(.c) void {
    const provider = provider_opt orelse return;
    provider.deinit();
}
pub fn RIB_request_interface_entry(provider_opt: ?*Provider, name: [*:0]const u8, entry_type: u32, entry_name: [*:0]const u8, token: ?*usize) callconv(.c) i32 {
    _ = entry_type; // RIB_FUNCTION/RIB_PROPERTY filter; we match by name alone
    const provider = provider_opt orelse return 0;
    for (provider.interfaces.items) |iface| {
        if (std.mem.eql(u8, iface.name, std.mem.span(name))) {
            if (iface.tokenFor(std.mem.span(entry_name))) |tok| {
                if (token) |t| t.* = tok;
                return 1;
            }
        }
    }
    return 0;
}
// RIB_enumerate_interface(HPROVIDER provider, C8 *interface_name,
//                         RIB_ENTRY_TYPE type, HINTENUM *next, RIB_INTERFACE_ENTRY *dest)
// Iterates the named interface's entries, filling `dest` with each entry.
pub fn RIB_enumerate_interface(provider_opt: ?*Provider, name: [*:0]const u8, entry_type: u32, next: *?*anyopaque, dest: *openmiles.RIB_INTERFACE_ENTRY) callconv(.c) i32 {
    const provider = provider_opt orelse return 0;
    const iface_name = std.mem.span(name);
    for (provider.interfaces.items) |iface| {
        if (!std.mem.eql(u8, iface.name, iface_name)) continue;
        const idx: usize = if (next.*) |v| @intFromPtr(v) else 0;
        if (iface.entryAt(idx)) |entry| {
            dest.* = .{
                .entry_type = if (entry_type == 1) .RIB_ATTRIBUTE else .RIB_FUNCTION,
                .name = entry.name.ptr,
                .token = entry.token,
                .subtype = 0,
            };
            next.* = @ptrFromInt(idx + 1);
            return 1;
        }
        break;
    }
    next.* = null;
    return 0;
}
// RIB_type_string(void const* data, RIB_DATA_SUBTYPE subtype) — formats the value
// pointed to by `data` per its subtype into a static buffer (rib.cpp). Subtypes:
// RIB_DEC=1, RIB_HEX=2, RIB_FLOAT=3, RIB_PERCENT=4, RIB_BOOL=5, RIB_STRING=6;
// RIB_READONLY=0x80000000 is a flag stripped before the switch.
var type_string_buf: [256]u8 = undefined;
pub fn RIB_type_string(data: ?*const anyopaque, subtype: u32) callconv(.c) [*:0]const u8 {
    const d = data orelse return "";
    const st = subtype & ~@as(u32, 0x80000000);
    const slice: []const u8 = switch (st) {
        2 => std.fmt.bufPrint(&type_string_buf, "0x{X}", .{@as(*align(1) const i32, @ptrCast(d)).*}) catch return "",
        3 => std.fmt.bufPrint(&type_string_buf, "{d:.1}", .{@as(*align(1) const f32, @ptrCast(d)).*}) catch return "",
        4 => std.fmt.bufPrint(&type_string_buf, "{d:.1}%", .{@as(*align(1) const f32, @ptrCast(d)).*}) catch return "",
        5 => if (@as(*align(1) const i32, @ptrCast(d)).* != 0) "True" else "False",
        6 => return @as(*align(1) const [*:0]const u8, @ptrCast(d)).*,
        else => std.fmt.bufPrint(&type_string_buf, "{d}", .{@as(*align(1) const i32, @ptrCast(d)).*}) catch return "",
    };
    const n = @min(slice.len, type_string_buf.len - 1);
    if (slice.ptr != @as([*]const u8, &type_string_buf)) std.mem.copyForwards(u8, type_string_buf[0..n], slice[0..n]);
    type_string_buf[n] = 0;
    return @ptrCast(&type_string_buf);
}
// MIX_RIB_MAIN(HPROVIDER, U32 up_down, RIB_ALLOC*, RIB_REGISTER*, RIB_UNREGISTER*)
// is the DLL's own ASI mixer provider entry point. The miniaudio mixer is wired
// directly rather than through the RIB ASI path, so this reports success.
pub fn MIX_RIB_MAIN(provider: ?*Provider, up_down: u32, rib_alloc: ?*anyopaque, rib_reg: ?*anyopaque, rib_unreg: ?*anyopaque) callconv(.winapi) i32 {
    _ = provider;
    _ = up_down;
    _ = rib_alloc;
    _ = rib_reg;
    _ = rib_unreg;
    return 0;
}
// v7/v8 ASI mixer entry: MIX_RIB_MAIN(HPROVIDER, U32 up_down)@8. v9 widened it to
// @20 with explicit RIB alloc/register/unregister callbacks.
pub fn MIX_RIB_MAIN_v7(provider: ?*Provider, up_down: u32) callconv(.winapi) i32 {
    _ = provider;
    _ = up_down;
    return 0;
}
// v7 ASI EOB reset: @8 (HSAMPLE, buff_num); v8+ added the new_stream_position arg.
pub fn AIL_request_EOB_ASI_reset_v7(s_opt: ?*Sample, buff_num: u32) callconv(.winapi) void {
    AIL_request_EOB_ASI_reset(s_opt, buff_num, 0);
}
pub fn RIB_provider_system_data(provider_opt: ?*Provider, index: u32) callconv(.winapi) usize {
    const provider = provider_opt orelse return 0;
    if (index < 8) return provider.system_data[index];
    return 0;
}
pub fn RIB_provider_user_data(provider_opt: ?*Provider, index: u32) callconv(.winapi) usize {
    const provider = provider_opt orelse return 0;
    if (index < 8) return provider.user_data[index];
    return 0;
}
pub fn RIB_set_provider_system_data(provider_opt: ?*Provider, index: u32, value: usize) callconv(.winapi) void {
    const provider = provider_opt orelse return;
    if (index < 8) provider.system_data[index] = value;
}
pub fn RIB_set_provider_user_data(provider_opt: ?*Provider, index: u32, value: usize) callconv(.winapi) void {
    const provider = provider_opt orelse return;
    if (index < 8) provider.user_data[index] = value;
}
pub fn RIB_find_file_dec_provider(name: [*:0]const u8, property: [*:0]const u8, filename: [*:0]const u8, search_dir: [*:0]const u8, file_ext: [*:0]const u8) callconv(.winapi) ?*Provider {
    log("RIB_find_file_dec_provider(name='{s}', property='{s}', filename='{s}', search_dir='{s}', file_ext='{s}')\n", .{ std.mem.span(name), std.mem.span(property), std.mem.span(filename), std.mem.span(search_dir), std.mem.span(file_ext) });
    var handle: ?*Provider = null;
    _ = RIB_enumerate_providers(name, null, &handle);
    return handle;
}
pub fn RIB_find_provider(name: [*:0]const u8, property: [*:0]const u8, value: [*:0]const u8) callconv(.winapi) ?*Provider {
    log("RIB_find_provider(name='{s}', property='{s}', value='{s}')\n", .{ std.mem.span(name), std.mem.span(property), std.mem.span(value) });
    var handle: ?*Provider = null;
    _ = RIB_enumerate_providers(name, null, &handle);
    return handle;
}
// Real MSS: AIL_request_EOB_ASI_reset(HSAMPLE S, U32 buff_num, S32 new_stream_position) @12.
pub fn AIL_request_EOB_ASI_reset(s_opt: ?*Sample, buff_num: u32, new_stream_position: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    _ = buff_num;
    _ = new_stream_position;
    if (s.is_initialized) {
        _ = openmiles.ma.ma_sound_seek_to_pcm_frame(&s.sound, s.loop_start_frame);
        s.is_done.store(false, .release);
    }
}
/// AIL_compress_ASI(info, ext, outdata, outsize, callback)
/// Real MSS compresses the PCM described by `info` to the ASI codec implied by
/// the `ext` extension, returning a freshly malloc'd buffer in outdata/outsize.
/// OpenMiles ships only decoders for the perceptual codecs (MP3/Vorbis) via
/// miniaudio, so IMA-ADPCM — the one encoder we have — is the compressed output
/// here, mirroring AIL_compress_ADPCM. Returns 1 on success, 0 on failure.
pub fn AIL_compress_ASI(info_opt: ?*const openmiles.AILSOUNDINFO, ext: ?[*:0]const u8, outdata: ?*?*anyopaque, outsize: ?*u32, callback: ?*anyopaque) callconv(.winapi) i32 {
    _ = ext;
    _ = callback;
    const info = info_opt orelse return 0;
    if (info.data_ptr == null or info.data_len == 0 or info.bits != 16) return 0;
    const channels: u16 = @intCast(@max(1, @min(2, info.channels)));
    const pcm: [*]const i16 = @ptrCast(@alignCast(info.data_ptr.?));
    const total_per_ch: usize = @as(usize, info.data_len) / (@as(usize, channels) * 2);
    // A source shorter than one frame per channel has no samples to encode;
    // buildAdpcmWav would return a header-only image and this call would report
    // success, handing the caller a compressed file that decodes to silence.
    if (total_per_ch == 0) {
        openmiles.setLastError("AIL_compress_ASI: source holds less than one sample frame");
        return 0;
    }
    const wav = openmiles.buildAdpcmWav(openmiles.global_allocator, pcm, total_per_ch, channels, info.rate) catch |err| {
        log("AIL_compress_ASI: encoding {d} samples failed ({any})\n", .{ total_per_ch, err });
        openmiles.setLastError("AIL_compress_ASI: cannot encode the PCM source");
        return 0;
    };
    defer openmiles.global_allocator.free(wav);
    const buf: [*]u8 = @ptrCast(std.c.malloc(wav.len) orelse {
        openmiles.setLastError("AIL_compress_ASI: out of memory");
        return 0;
    });
    @memcpy(buf[0..wav.len], wav);
    if (outdata) |o| o.* = buf;
    if (outsize) |o| o.* = @intCast(wav.len);
    return 1;
}
/// AIL_decompress_ASI(indata, insize, ext, wav, wavsize, callback)
/// Decode a compressed in-memory audio image (any format miniaudio recognizes)
/// to a PCM WAV image returned in wav/wavsize (freshly malloc'd). Returns 1 on
/// success, 0 on failure.
pub fn AIL_decompress_ASI(indata: ?*const anyopaque, insize: u32, ext: ?[*:0]const u8, wav_out: ?*?*anyopaque, wavsize: ?*u32, callback: ?*anyopaque) callconv(.winapi) i32 {
    _ = ext;
    _ = callback;
    const data = indata orelse return 0;
    if (insize == 0) return 0;
    var decoder: openmiles.ma.ma_decoder = undefined;
    var config = openmiles.ma.ma_decoder_config_init(openmiles.ma.ma_format_s16, 2, 44100);
    if (openmiles.ma.ma_decoder_init_memory(data, insize, &config, &decoder) != openmiles.ma.MA_SUCCESS) {
        openmiles.setLastError("AIL_decompress_ASI: failed to open input");
        return 0;
    }
    defer _ = openmiles.ma.ma_decoder_uninit(&decoder);

    var all_pcm: std.ArrayListUnmanaged(u8) = .empty;
    defer all_pcm.deinit(openmiles.global_allocator);
    // Heap scratch (16-byte aligned): a stack buffer trips a layout-dependent
    // misaligned ma_int16 write inside miniaudio's decoder under the UBSan build.
    const chunk_buf = openmiles.global_allocator.alignedAlloc(u8, .@"16", 4096 * 4) catch {
        openmiles.setLastError("AIL_decompress_ASI: out of memory");
        return 0;
    };
    defer openmiles.global_allocator.free(chunk_buf);
    while (true) {
        var fr: u64 = 0;
        const read_result = openmiles.ma.ma_decoder_read_pcm_frames(&decoder, chunk_buf.ptr, 4096, &fr);
        // A decoder error also reports 0 frames and would end the loop as if
        // the stream had finished; fail the call instead of returning a
        // truncated image under a success return code.
        if (read_result != openmiles.ma.MA_SUCCESS and read_result != openmiles.ma.MA_AT_END) {
            log("AIL_decompress_ASI: ma_decoder_read_pcm_frames failed with {d}\n", .{read_result});
            openmiles.setLastError("AIL_decompress_ASI: decode failed mid-stream");
            return 0;
        }
        if (fr == 0) break;
        // A partial decode must be reported as a failure, not wrapped in a WAV
        // and handed back as a complete one.
        all_pcm.appendSlice(openmiles.global_allocator, chunk_buf[0..@intCast(fr * 4)]) catch {
            openmiles.setLastError("AIL_decompress_ASI: out of memory");
            return 0;
        };
    }
    if (all_pcm.items.len == 0) {
        openmiles.setLastError("AIL_decompress_ASI: the input decoded to no audio");
        return 0;
    }

    const wav = openmiles.buildWavFromPcm(openmiles.global_allocator, all_pcm.items, 2, 44100, 16) catch |err| {
        log("AIL_decompress_ASI: cannot build the output WAV ({any})\n", .{err});
        openmiles.setLastError("AIL_decompress_ASI: cannot build the output WAV");
        return 0;
    };
    defer openmiles.global_allocator.free(wav);
    const buf: [*]u8 = @ptrCast(std.c.malloc(wav.len) orelse {
        openmiles.setLastError("AIL_decompress_ASI: out of memory");
        return 0;
    });
    @memcpy(buf[0..wav.len], wav);
    if (wav_out) |o| o.* = buf;
    if (wavsize) |o| o.* = @intCast(wav.len);
    return 1;
}

// --- v8.0j+ / v9 stdcall RIB exports ------------------------------------------
// The RIB interface API switched from __cdecl (undecorated, v6-v8.0b) to
// __stdcall (decorated `_RIB_*@N`, v8.0j onward). These thin wrappers carry the
// stdcall convention for the v8+ export targets; the bodies above stay cdecl for
// the v6/v7 undecorated exports.
pub fn RIB_alloc_provider_handle_std(module: *anyopaque) callconv(.winapi) ?*Provider {
    return RIB_alloc_provider_handle(module);
}
pub fn RIB_free_provider_handle_std(provider_opt: ?*Provider) callconv(.winapi) void {
    RIB_free_provider_handle(provider_opt);
}
pub fn RIB_register_interface_std(provider_opt: ?*Provider, name: [*:0]const u8, count: i32, entries: *anyopaque) callconv(.winapi) void {
    RIB_register_interface(provider_opt, name, count, entries);
}
pub fn RIB_unregister_interface_std(provider_opt: ?*Provider, name: [*:0]const u8, count: i32, entries: *anyopaque) callconv(.winapi) void {
    RIB_unregister_interface(provider_opt, name, count, entries);
}
pub fn RIB_request_interface_std(provider_opt: ?*Provider, name: [*:0]const u8, count: i32, entries: *anyopaque) callconv(.winapi) i32 {
    return RIB_request_interface(provider_opt, name, count, entries);
}
pub fn RIB_error_std() callconv(.winapi) [*:0]const u8 {
    return RIB_error();
}
pub fn RIB_find_file_provider_std(name: [*:0]const u8, property: [*:0]const u8, filename: [*:0]const u8) callconv(.winapi) ?*Provider {
    return RIB_find_file_provider(name, property, filename);
}
pub fn RIB_load_provider_library_std(path: [*:0]const u8) callconv(.winapi) ?*Provider {
    return RIB_load_provider_library(path);
}
pub fn RIB_free_provider_library_std(provider_opt: ?*Provider) callconv(.winapi) void {
    RIB_free_provider_library(provider_opt);
}
pub fn RIB_request_interface_entry_std(provider_opt: ?*Provider, name: [*:0]const u8, entry_type: u32, entry_name: [*:0]const u8, token: ?*usize) callconv(.winapi) i32 {
    return RIB_request_interface_entry(provider_opt, name, entry_type, entry_name, token);
}
pub fn RIB_enumerate_interface_std(provider_opt: ?*Provider, name: [*:0]const u8, entry_type: u32, next: *?*anyopaque, dest: *openmiles.RIB_INTERFACE_ENTRY) callconv(.winapi) i32 {
    return RIB_enumerate_interface(provider_opt, name, entry_type, next, dest);
}
pub fn RIB_type_string_std(data: ?*const anyopaque, subtype: u32) callconv(.winapi) [*:0]const u8 {
    return RIB_type_string(data, subtype);
}

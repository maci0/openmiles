const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;

const Sample = openmiles.Sample;
const Provider = openmiles.Provider;

pub export fn RIB_alloc_provider_handle(module: *anyopaque) callconv(.winapi) ?*Provider {
    log("RIB_alloc_provider_handle(module={*})\n", .{module});
    return Provider.init(openmiles.global_allocator.?, module) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
}
pub export fn RIB_free_provider_handle(provider_opt: ?*Provider) callconv(.winapi) void {
    const provider = provider_opt orelse return;
    log("RIB_free_provider_handle(provider={*})\n", .{provider});
    provider.deinit();
}
pub export fn RIB_register_interface(provider_opt: ?*Provider, name: [*:0]const u8, count: i32, entries: *anyopaque) callconv(.winapi) void {
    const provider = provider_opt orelse return;
    log("RIB_register_interface(provider={*}, name={s}, count={d}, entries={*})\n", .{ provider, name, count, entries });
    provider.registerInterface(std.mem.span(name), count, entries) catch {};
}
pub export fn RIB_unregister_interface(provider_opt: ?*Provider, name: [*:0]const u8, count: i32, entries: *anyopaque) callconv(.winapi) void {
    const provider = provider_opt orelse return;
    log("RIB_unregister_interface(provider={*}, name={s}, count={d}, entries={*})\n", .{ provider, name, count, entries });
    provider.unregisterInterface(std.mem.span(name));
}
pub export fn RIB_provider_library_handle() callconv(.winapi) ?*anyopaque {
    log("RIB_provider_library_handle()\n", .{});
    // Return the handle of the currently-loading provider (used by plugins registering themselves)
    if (openmiles.getCurrentLoadingProvider()) |p| return @ptrCast(p);
    return @ptrCast(openmiles.startup_provider);
}
pub export fn RIB_load_application_providers(dir: [*:0]const u8) callconv(.winapi) i32 {
    const dir_str = std.mem.span(dir);
    log("RIB_load_application_providers(dir={s})\n", .{dir_str});
    const count = openmiles.loadApplicationProviders(dir_str);
    return if (count >= 0) 1 else 0; // MSS returns 1 on success
}
pub export fn RIB_enumerate_providers(name: [*:0]const u8, next: ?*?*anyopaque, handle: ?*?*Provider) callconv(.winapi) i32 {
    const iface_name = std.mem.span(name);
    log("RIB_enumerate_providers(name='{s}', next={*}, handle={*})\n", .{ iface_name, next, handle });

    // Build a flat ordered list: startup_provider first, then global providers.
    // Advance the cursor (stored as 1-based flat index) until we find a provider
    // that has the requested interface registered.
    var cursor: usize = if (next) |n| if (n.*) |v| @intFromPtr(v) else 0 else 0;

    const global_providers = openmiles.getAllProviders();
    const total = (if (openmiles.startup_provider != null) @as(usize, 1) else 0) + global_providers.len;

    while (cursor < total) : (cursor += 1) {
        const p: *Provider = if (cursor == 0 and openmiles.startup_provider != null)
            openmiles.startup_provider.?
        else blk: {
            const gi = if (openmiles.startup_provider != null) cursor - 1 else cursor;
            break :blk global_providers[gi];
        };

        // Check whether this provider has the requested interface.
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
pub export fn RIB_request_interface(provider_opt: ?*Provider, name: [*:0]const u8, count: i32, entries: *anyopaque) callconv(.winapi) i32 {
    const provider = provider_opt orelse return 0;
    log("RIB_request_interface(provider={*}, name={s}, count={d}, entries={*})\n", .{ provider, name, count, entries });
    const iface_name = std.mem.span(name);
    const dest: [*]openmiles.RIB_INTERFACE_ENTRY = @ptrCast(@alignCast(entries));
    const n: usize = @intCast(@max(0, count));

    // Search the provider's registered interfaces by name
    for (provider.interfaces.items) |iface| {
        if (std.mem.eql(u8, iface.name, iface_name)) {
            // Fill in token for each entry based on caller-supplied name field
            for (dest[0..n]) |*entry| {
                const ename = std.mem.span(entry.name);
                if (iface.entries.get(ename)) |tok| {
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
pub export fn RIB_find_files_provider(name: [*:0]const u8, property: [*:0]const u8, filename: [*:0]const u8, search_dir: [*:0]const u8, file_ext: [*:0]const u8) callconv(.winapi) ?*Provider {
    log("RIB_find_files_provider(name='{s}', property='{s}', filename='{s}', search_dir='{s}', file_ext='{s}')\n", .{ std.mem.span(name), std.mem.span(property), std.mem.span(filename), std.mem.span(search_dir), std.mem.span(file_ext) });
    var handle: ?*Provider = null;
    _ = RIB_enumerate_providers(name, null, &handle);
    return handle;
}
pub export fn AIL_open_ASI_provider(buffer: *const anyopaque, size: u32) callconv(.winapi) ?*Provider {
    log("AIL_open_ASI_provider(buffer={*}, size={d})\n", .{ buffer, size });
    if (size < 2) return null;
    const raw: []const u8 = @as([*]const u8, @ptrCast(@alignCast(buffer)))[0..size];
    // Must be a Windows PE DLL (MZ signature)
    if (raw[0] != 'M' or raw[1] != 'Z') return null;

    const id = @atomicRmw(u32, &openmiles.asi_temp_counter, .Add, 1, .monotonic);
    var path_buf: [512:0]u8 = undefined;

    // Get Windows temp directory via kernel32
    const GetTempPathA = struct {
        extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) callconv(.winapi) u32;
    }.GetTempPathA;
    var tmp_dir_buf: [260]u8 = undefined;
    const tmp_len = GetTempPathA(tmp_dir_buf.len, &tmp_dir_buf);

    const path: [:0]const u8 = if (tmp_len > 0)
        std.fmt.bufPrintZ(&path_buf, "{s}om_asi_{d}.dll", .{ tmp_dir_buf[0..tmp_len], id }) catch |err| {
            log("Error: {any}\n", .{err});
            return null;
        }
    else
        std.fmt.bufPrintZ(&path_buf, ".\\om_asi_{d}.dll", .{id}) catch |err| {
            log("Error: {any}\n", .{err});
            return null;
        };

    // Write DLL bytes to temp file
    const wf = std.fs.createFileAbsolute(path, .{}) catch
        (std.fs.cwd().createFile(path, .{}) catch |err| {
            log("Error: {any}\n", .{err});
            return null;
        });
    wf.writeAll(raw) catch {
        wf.close();
        return null;
    };
    wf.close();

    // Load the provider (calls RIB_Main inside the DLL)
    return openmiles.Provider.load(openmiles.global_allocator.?, path) catch null;
}
pub export fn AIL_close_ASI_provider(provider_opt: ?*Provider) callconv(.winapi) void {
    const provider = provider_opt orelse return;
    log("AIL_close_ASI_provider(provider={*})\n", .{provider});
    provider.deinit();
}
pub export fn AIL_ASI_provider_attribute(provider_opt: ?*Provider, name: [*:0]const u8) callconv(.winapi) ?*anyopaque {
    const provider = provider_opt orelse return null;
    log("AIL_ASI_provider_attribute(provider={*}, name={s})\n", .{ provider, name });
    const attr_name = std.mem.span(name);
    for (provider.interfaces.items) |iface| {
        if (iface.entries.get(attr_name)) |token| return @ptrFromInt(token);
    }
    return null;
}
pub export fn RIB_error() callconv(.winapi) [*:0]const u8 {
    return "No error";
}
pub export fn RIB_find_file_provider(name: [*:0]const u8, property: [*:0]const u8, filename: [*:0]const u8) callconv(.winapi) ?*Provider {
    log("RIB_find_file_provider(name='{s}', property='{s}', filename='{s}')\n", .{ std.mem.span(name), std.mem.span(property), std.mem.span(filename) });
    var handle: ?*Provider = null;
    _ = RIB_enumerate_providers(name, null, &handle);
    return handle;
}
pub export fn RIB_load_provider_library(path: [*:0]const u8) callconv(.winapi) ?*Provider {
    const p = openmiles.Provider.load(openmiles.global_allocator.?, std.mem.span(path)) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
    return p;
}
pub export fn RIB_free_provider_library(provider_opt: ?*Provider) callconv(.winapi) void {
    const provider = provider_opt orelse return;
    provider.deinit();
}
pub export fn RIB_request_interface_entry(provider_opt: ?*Provider, name: [*:0]const u8, entry_name: [*:0]const u8, token: ?*usize) callconv(.winapi) i32 {
    const provider = provider_opt orelse return 0;
    for (provider.interfaces.items) |iface| {
        if (std.mem.eql(u8, iface.name, std.mem.span(name))) {
            if (iface.entries.get(std.mem.span(entry_name))) |tok| {
                if (token) |t| t.* = tok;
                return 1;
            }
        }
    }
    return 0;
}
pub export fn RIB_enumerate_interface(provider_opt: ?*Provider, name: [*:0]const u8, next: *?*anyopaque, entry_name: *[*:0]const u8, token: *usize) callconv(.winapi) i32 {
    const provider = provider_opt orelse return 0;
    const iface_name = std.mem.span(name);
    for (provider.interfaces.items) |iface| {
        if (!std.mem.eql(u8, iface.name, iface_name)) continue;
        // Cursor is a 0-based entry index stored as a pointer-sized integer
        const idx: usize = if (next.*) |v| @intFromPtr(v) else 0;
        var i: usize = 0;
        var it = iface.entries.iterator();
        while (it.next()) |kv| {
            if (i == idx) {
                // Keys were stored with dupeZ, so key.ptr is null-terminated
                entry_name.* = @ptrCast(kv.key_ptr.*.ptr);
                token.* = kv.value_ptr.*;
                next.* = @ptrFromInt(idx + 1);
                return 1;
            }
            i += 1;
        }
        break;
    }
    next.* = null;
    return 0;
}
pub export fn RIB_type_string(data_type: u32) callconv(.winapi) [*:0]const u8 {
    return switch (data_type) {
        0 => "none",
        1 => "decimal",
        2 => "hexadecimal",
        3 => "float",
        4 => "percent",
        5 => "boolean",
        6 => "string",
        else => "unknown",
    };
}
pub export fn RIB_provider_system_data(provider_opt: ?*Provider, index: u32) callconv(.winapi) usize {
    const provider = provider_opt orelse return 0;
    if (index < 8) return provider.system_data[index];
    return 0;
}
pub export fn RIB_provider_user_data(provider_opt: ?*Provider, index: u32) callconv(.winapi) usize {
    const provider = provider_opt orelse return 0;
    if (index < 8) return provider.user_data[index];
    return 0;
}
pub export fn RIB_set_provider_system_data(provider_opt: ?*Provider, index: u32, value: usize) callconv(.winapi) void {
    const provider = provider_opt orelse return;
    if (index < 8) provider.system_data[index] = value;
}
pub export fn RIB_set_provider_user_data(provider_opt: ?*Provider, index: u32, value: usize) callconv(.winapi) void {
    const provider = provider_opt orelse return;
    if (index < 8) provider.user_data[index] = value;
}
pub export fn RIB_find_file_dec_provider(name: [*:0]const u8, property: [*:0]const u8, filename: [*:0]const u8, search_dir: [*:0]const u8, file_ext: [*:0]const u8) callconv(.winapi) ?*Provider {
    log("RIB_find_file_dec_provider(name='{s}', property='{s}', filename='{s}', search_dir='{s}', file_ext='{s}')\n", .{ std.mem.span(name), std.mem.span(property), std.mem.span(filename), std.mem.span(search_dir), std.mem.span(file_ext) });
    var handle: ?*Provider = null;
    _ = RIB_enumerate_providers(name, null, &handle);
    return handle;
}
pub export fn RIB_find_provider(name: [*:0]const u8, property: [*:0]const u8, value: [*:0]const u8) callconv(.winapi) ?*Provider {
    log("RIB_find_provider(name='{s}', property='{s}', value='{s}')\n", .{ std.mem.span(name), std.mem.span(property), std.mem.span(value) });
    var handle: ?*Provider = null;
    _ = RIB_enumerate_providers(name, null, &handle);
    return handle;
}
pub export fn AIL_request_EOB_ASI_reset(s_opt: ?*Sample, flags: u32) callconv(.winapi) void {
    const s = s_opt orelse return;
    _ = flags;
    if (s.is_initialized) {
        _ = openmiles.ma.ma_sound_seek_to_pcm_frame(&s.sound, s.loop_start_frame);
        s.is_done = false;
    }
}
pub export fn AIL_compress_ASI(provider_opt: ?*Provider, filename: [*:0]const u8, out_filename: [*:0]const u8, flags: u32) callconv(.winapi) i32 {
    const provider = provider_opt orelse return 0;
    log("AIL_compress_ASI(provider={*}, filename={s}, out_filename={s}, flags={d})\n", .{ provider, filename, out_filename, flags });
    return 0;
}
pub export fn AIL_decompress_ASI(provider_opt: ?*Provider, filename: [*:0]const u8, out_filename: [*:0]const u8, flags: u32) callconv(.winapi) i32 {
    const provider = provider_opt orelse return 0;
    log("AIL_decompress_ASI: {s} -> {s} (provider={*}, flags={d})\n", .{ filename, out_filename, provider, flags });
    // Decode input file to 16-bit stereo PCM at 44100 Hz, write as WAV
    var decoder: openmiles.ma.ma_decoder = undefined;
    var config = openmiles.ma.ma_decoder_config_init(openmiles.ma.ma_format_s16, 2, 44100);
    if (openmiles.ma.ma_decoder_init_file(filename, &config, &decoder) != openmiles.ma.MA_SUCCESS) {
        openmiles.setLastError("AIL_decompress_ASI: failed to open input");
        return 0;
    }
    defer _ = openmiles.ma.ma_decoder_uninit(&decoder);

    // Decode all frames in chunks
    var all_pcm = std.ArrayListUnmanaged(u8){};
    defer all_pcm.deinit(openmiles.global_allocator.?);
    // Pre-allocate if total length is known to avoid repeated reallocations
    {
        var total_frames: u64 = 0;
        _ = openmiles.ma.ma_decoder_get_length_in_pcm_frames(&decoder, &total_frames);
        if (total_frames > 0) {
            all_pcm.ensureTotalCapacity(openmiles.global_allocator.?, @intCast(total_frames * 4)) catch {};
        }
    }
    var chunk_buf: [4096 * 4]u8 = undefined; // 4096 frames × 4 bytes (s16 stereo)
    while (true) {
        var fr: u64 = 0;
        _ = openmiles.ma.ma_decoder_read_pcm_frames(&decoder, &chunk_buf, 4096, &fr);
        if (fr == 0) break;
        all_pcm.appendSlice(openmiles.global_allocator.?, chunk_buf[0..@intCast(fr * 4)]) catch break;
    }
    if (all_pcm.items.len == 0) return 0;

    // Wrap in a WAV container and write to output file
    const wav = openmiles.buildWavFromPcm(openmiles.global_allocator.?, all_pcm.items, 2, 44100, 16) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    defer openmiles.global_allocator.?.free(wav);

    const out_path = std.mem.span(out_filename);
    const out_file = if (std.fs.path.isAbsolute(out_path))
        std.fs.createFileAbsolute(out_path, .{}) catch |err| {
            log("Error: {any}\n", .{err});
            return 0;
        }
    else
        std.fs.cwd().createFile(out_path, .{}) catch |err| {
            log("Error: {any}\n", .{err});
            return 0;
        };
    defer out_file.close();
    out_file.writeAll(wav) catch |err| {
        log("Error: {any}\n", .{err});
        return 0;
    };
    return 1;
}

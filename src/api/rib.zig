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
    return Provider.init(openmiles.global_allocator) catch |err| {
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
    _ = provider.registerInterface(std.mem.span(name), count, entries) catch |err| {
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

    // Fall back: an "ASI codec" request for any provider handle returns our
    // built-in table, whatever the provider itself holds.
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

/// The first provider registered under `name`, or null. The MSS find_* entry
/// points take property/filename/search_dir/file_ext arguments, and the
/// enumeration here matches on the name alone, so every one of them resolves
/// to the same lookup and the extra arguments are logged, not applied.
fn findFirstProvider(name: [*:0]const u8) ?*Provider {
    var handle: ?*Provider = null;
    _ = RIB_enumerate_providers(name, null, &handle);
    return handle;
}

pub fn RIB_find_files_provider(name: [*:0]const u8, property: [*:0]const u8, filename: [*:0]const u8, search_dir: [*:0]const u8, file_ext: [*:0]const u8) callconv(.winapi) ?*Provider {
    log("RIB_find_files_provider(name='{s}', property='{s}', filename='{s}', search_dir='{s}', file_ext='{s}')\n", .{ std.mem.span(name), std.mem.span(property), std.mem.span(filename), std.mem.span(search_dir), std.mem.span(file_ext) });
    return findFirstProvider(name);
}
/// GetTempPathW writes at most MAX_PATH UTF-16 units, terminating NUL included;
/// the UTF-8 form of a path that long needs up to three bytes per unit.
const max_temp_path_units: usize = 260;

/// Length of the unpacked image's file name whatever the random id in it is:
/// "om_asi_", sixteen hex digits, ".dll".
const temp_image_name_units: usize = "om_asi_".len + 16 + ".dll".len;

/// Whether `dir` plus that file name still fits inside `limit_units` UTF-16
/// units, terminator included. Windows opens a path longer than MAX_PATH only
/// with the long-path opt-in, a registry setting a game install has not made,
/// and GetTempPathW hands back a directory of up to 259 units: a %TEMP% that
/// leaves no room for the name tail yields a path no create call can open, and
/// the image is then written to the game directory instead, the same fallback a
/// machine with no TMPDIR gets. Counted in UTF-16 units because that is what
/// the Windows limit counts, so a temp directory holding a non-ASCII character
/// is measured by the units it takes and not by the UTF-8 bytes it spells.
fn pathFitsUnitLimit(dir: []const u8, limit_units: usize) bool {
    var buf: [max_temp_path_units * 3]u16 = undefined;
    const w = wide.toWide(dir, &buf) catch return false;
    return w.len + temp_image_name_units + 1 <= limit_units;
}

/// Whether the temp directory this process resolved is one the image can be
/// written under. No other target carries a bound the path of a temp directory
/// can reach, so the check is Windows' alone.
fn tempPathFits(dir: []const u8) bool {
    if (comptime builtin.os.tag != .windows) return true;
    return pathFitsUnitLimit(dir, std.os.windows.PATH_MAX_WIDE);
}

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
        if (len == 0 or len >= wbuf.len) {
            reportTempDir("the platform temporary directory", "TMP, TEMP and the system profile directory are all unavailable");
            return null;
        }
        if (wide.utf8LenBound(wbuf[0..len]) > buf.len) return null;
        const dir = wide.toUtf8(wbuf[0..len], buf) catch return null;
        return appendSeparator(buf, dir);
    }
    // TMPDIR is the POSIX convention; the game directory (the process cwd under
    // Wine) is the fallback, and the caller covers that case too. A TMPDIR that
    // is set but unusable is reported rather than dropped: the silent part of
    // the fallback is that the unpacked image lands in the game directory, so an
    // operator whose TMPDIR is wrong would otherwise never learn why.
    const tmp = std.c.getenv("TMPDIR") orelse return null;
    return configuredTempDir(std.mem.span(@as([*:0]const u8, tmp)), buf);
}

/// Validate a configured temp directory and copy it into `buf` with a trailing
/// separator, or return null after reporting why it was rejected. Split out of
/// tempDir so the checks on a configured value are testable without writing to
/// the process environment, which the test runner would share.
fn configuredTempDir(dir: []const u8, buf: []u8) ?[]const u8 {
    if (dir.len == 0) {
        reportTempDir("TMPDIR", "is empty");
        return null;
    }
    if (dir.len > buf.len - 2) {
        reportTempDir("TMPDIR", "is too long to use");
        return null;
    }
    // POSIX requires TMPDIR to be absolute. A relative one resolves against the
    // process cwd, which under Wine is the game directory, so honouring it puts
    // the image exactly where the fallback would.
    if (!std.fs.path.isAbsolute(dir)) {
        reportTempDir("TMPDIR", "is not an absolute path");
        return null;
    }
    @memcpy(buf[0..dir.len], dir);
    return appendSeparator(buf, buf[0..dir.len]);
}

/// stderr rather than log(): the log is off unless the operator turned it on,
/// and a misconfigured TMPDIR is exactly what they are trying to find out about.
/// `source` names what was ignored, which is the environment variable on POSIX
/// and the platform's own lookup on Windows.
fn reportTempDir(source: []const u8, reason: []const u8) void {
    std.debug.print("openmiles: ignoring {s} ({s}); the ASI image is written to the current directory instead\n", .{ source, reason });
}

fn appendSeparator(buf: []u8, dir: []const u8) ?[]const u8 {
    if (dir.len == 0) return null;
    const n = dir.len + @intFromBool(!std.fs.path.isSep(dir[dir.len - 1]));
    if (n > buf.len) return null;
    if (n != dir.len) buf[n - 1] = std.fs.path.sep;
    return buf[0..n];
}

/// Drop a temp image written for a provider that is being abandoned. The path
/// is absolute when a temp directory was found and process-relative when it was
/// not, and fs_compat routes each form. A file that survives the removal is
/// never retried, because the caller's only record of the path is about to go
/// away, so the leak is reported.
fn deleteTempImage(path: []const u8) void {
    openmiles.fs_compat.deleteFile(io, path) catch |err| {
        log("AIL_open_ASI_provider: cannot delete temp image '{s}' ({any}); it stays on disk\n", .{ path, err });
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
    // A temp directory that leaves no room for the file name under the
    // platform's path limit is no more usable than no temp directory at all:
    // both write the image next to the game.
    const use_tmp_dir = if (tmp_dir) |dir| blk: {
        const fits = tempPathFits(dir);
        if (!fits) {
            // stderr as well as the log: a directory the path limit cannot hold
            // the name under is the same operator-facing misconfiguration as a
            // TMPDIR that is rejected outright, and without this the image lands
            // in the game directory with nothing said about why. The path itself
            // stays in the log, which scrubs it; stderr carries the reason only.
            reportTempDir("the resolved temporary directory", "leaves no room for the image name under the platform path limit");
            log("AIL_open_ASI_provider: temp directory '{s}' leaves no room for the image name under the path limit; writing it to the current directory\n", .{dir});
        }
        break :blk fits;
    } else false;
    // Cleared once the temp directory turns out to be unusable (no room for the
    // name, or the create fails for any reason but an occupied name), so the
    // retry below builds the process-relative path the game directory needs.
    var in_tmp_dir = use_tmp_dir;

    // The image is written to TEMP and then LoadLibrary'd, so the file name must
    // not be predictable: a sequential counter would let a local process plant
    // (or race-replace) om_asi_<next>.dll ahead of us and get its own code loaded
    // into this one. A random name created exclusively closes both routes.
    var path: [:0]const u8 = "";
    var created: ?std.Io.File = null;
    // Entropy for the name; without it the unpredictable-name guarantee is gone,
    // so fail closed rather than fall back to a guessable pattern. Under a
    // simulation the draw comes from the run's seed, so the name (and the file
    // it names) replays with the run.
    var id_bytes: [8]u8 = undefined;
    openmiles.randomNameBytes(&id_bytes) catch |err| {
        log("AIL_open_ASI_provider: no entropy for temp file name: {any}\n", .{err});
        openmiles.setLastError("No entropy available for ASI temp file name");
        return null;
    };
    var id = std.mem.readInt(u64, &id_bytes, .little);
    const name_attempts = 4;
    for (0..name_attempts) |_| {
        while (true) {
            path = if (in_tmp_dir) std.fmt.bufPrintZ(&path_buf, "{s}om_asi_{x:016}.dll", .{ tmp_dir.?, id }) catch |err| {
                log("AIL_open_ASI_provider: cannot format temp path: {any}\n", .{err});
                openmiles.setLastError("Failed to format temp path for ASI provider");
                return null;
            } else std.fmt.bufPrintZ(&path_buf, ".{c}om_asi_{x:016}.dll", .{ std.fs.path.sep, id }) catch |err| {
                log("AIL_open_ASI_provider: cannot format temp path: {any}\n", .{err});
                openmiles.setLastError("Failed to format temp path for ASI provider");
                return null;
            };
            if (!in_tmp_dir) break;
            if (std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true })) |f| {
                created = f;
                break;
            } else |abs_err| switch (abs_err) {
                // An occupied name retries with a fresh id.
                error.PathAlreadyExists => {
                    id +%= 1;
                    continue;
                },
                else => {
                    // The temp directory is unusable (not writable, not a
                    // directory, no room). Retrying the same absolute path
                    // fails the same way, so drop to the game directory and
                    // rebuild the path in its process-relative form.
                    reportTempDir("the resolved temporary directory", "cannot be written to (missing, not a directory, or read-only)");
                    log("AIL_open_ASI_provider: temp directory unusable ({any}); writing the image to the current directory\n", .{abs_err});
                    in_tmp_dir = false;
                    continue;
                },
            }
        }
        if (created != null) break;
        if (openmiles.fs_compat.createFile(io, path, .{ .exclusive = true })) |f| {
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
    // A short write leaves a temp image whose tail never reached the disk, and
    // loading that would map a module that is not the image the caller handed
    // us. The injected length is how a simulation replays that.
    const written = openmiles.fs_compat.writeAll(io, wf, path, raw) catch |err| {
        log("AIL_open_ASI_provider: writing {d} bytes to '{s}' failed ({any})\n", .{ size, path, err });
        wf.close(io);
        deleteTempImage(path);
        openmiles.setLastError("Failed to write temp file for ASI provider");
        return null;
    };
    wf.close(io);
    if (written != raw.len) {
        log("AIL_open_ASI_provider: only {d} of {d} bytes reached '{s}'; the image is discarded\n", .{ written, size, path });
        deleteTempImage(path);
        openmiles.setLastError("Failed to write temp file for ASI provider");
        return null;
    }

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
    // The same image opened twice is one module. A retried open (a game that
    // re-opens to check what it has, a wrapper that opens twice) would
    // otherwise write a second temp image, load a second copy of the same
    // module, and answer every provider query through it twice, with both
    // copies held until the process exits. The copy built above is dropped and
    // the live provider is handed back with a reference taken for this open, so
    // the second close is still owed a close of its own (see
    // Provider.releaseImage). The key is the image content, so the same bytes
    // reached through a different buffer match.
    const live = p.publishImage(openmiles.Provider.imageKeyOf(raw));
    if (live != p) {
        // This provider was never published, so freeing it drops its module and
        // deletes the temp image written for it, leaving the live one untouched.
        p.deinit();
    }
    return live;
}
pub fn AIL_close_ASI_provider(provider_opt: ?*Provider) callconv(.winapi) void {
    const provider = provider_opt orelse return;
    log("AIL_close_ASI_provider(provider={*})\n", .{provider});
    // N opens of one image are N closes: only the last unloads the module and
    // deletes its temp image, exactly as the open handed back the same handle
    // each time.
    if (!provider.releaseImage()) return;
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
    return findFirstProvider(name);
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
    const provider = provider_opt orelse return 0;
    const want: openmiles.RIB_ENTRY_TYPE = if (entry_type == 1) .RIB_ATTRIBUTE else .RIB_FUNCTION;
    for (provider.interfaces.items) |iface| {
        if (!std.mem.eql(u8, iface.name, std.mem.span(name))) continue;
        if (iface.tokenForType(std.mem.span(entry_name), want)) |tok| {
            if (token) |t| t.* = tok;
            return 1;
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
    const want: openmiles.RIB_ENTRY_TYPE = if (entry_type == 1) .RIB_ATTRIBUTE else .RIB_FUNCTION;
    for (provider.interfaces.items) |iface| {
        if (!std.mem.eql(u8, iface.name, iface_name)) continue;
        // The cursor counts entries of the requested type, and `order` is
        // registration order, so repeated calls walk that type once. Each
        // record carries the type and subtype it was registered with:
        // RIB_type_string needs the real subtype, and echoing the caller's
        // filter would make that read a no-op.
        const start: usize = if (next.*) |v| @intFromPtr(v) else 0;
        var seen: usize = 0;
        for (iface.order.items) |entry| {
            if (entry.entry_type != want) continue;
            if (seen < start) {
                seen += 1;
                continue;
            }
            dest.* = .{
                .entry_type = entry.entry_type,
                .name = entry.name.ptr,
                .token = entry.token,
                .subtype = entry.subtype,
            };
            next.* = @ptrFromInt(start + 1);
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
    return 1;
}
// v7/v8 ASI mixer entry: MIX_RIB_MAIN(HPROVIDER, U32 up_down)@8. v9 widened it to
// @20 with explicit RIB alloc/register/unregister callbacks.
pub fn MIX_RIB_MAIN_v7(provider: ?*Provider, up_down: u32) callconv(.winapi) i32 {
    _ = provider;
    _ = up_down;
    return 1;
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
    return findFirstProvider(name);
}
pub fn RIB_find_provider(name: [*:0]const u8, property: [*:0]const u8, value: [*:0]const u8) callconv(.winapi) ?*Provider {
    log("RIB_find_provider(name='{s}', property='{s}', value='{s}')\n", .{ std.mem.span(name), std.mem.span(property), std.mem.span(value) });
    return findFirstProvider(name);
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
    // C-allocated only when there is an out-pointer to take it: a copy made
    // for a caller that passed none could be freed by no one.
    if (outdata) |o| {
        const buf: [*]u8 = @ptrCast(std.c.malloc(wav.len) orelse {
            openmiles.setLastError("AIL_compress_ASI: out of memory");
            return 0;
        });
        @memcpy(buf[0..wav.len], wav);
        o.* = buf;
    }
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
    // Reserve the decoder-reported PCM size so the append below never
    // realloc-copies the decoded image it already holds, the same hint
    // decodeWavToPcm uses on the in-memory decode path. The frame count is
    // header-derived, hence spoofable, so the saturating multiply and the
    // clamp keep the hint from overflowing or panicking the usize cast on the
    // 32-bit target; the loop is bounded by real reads, so an inflated hint
    // only over-reserves. Configured output is s16 stereo, four bytes a frame.
    var length_frames: u64 = 0;
    _ = openmiles.ma.ma_decoder_get_length_in_pcm_frames(&decoder, &length_frames);
    if (length_frames > 0) {
        const pcm_bytes_per_frame: u64 = 4;
        const hint: u64 = @min(length_frames *| pcm_bytes_per_frame, std.math.maxInt(usize));
        all_pcm.ensureTotalCapacity(openmiles.global_allocator, @intCast(hint)) catch {};
    }
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
    // C-allocated only when there is an out-pointer to take it: a copy made
    // for a caller that passed none could be freed by no one.
    if (wav_out) |o| {
        const buf: [*]u8 = @ptrCast(std.c.malloc(wav.len) orelse {
            openmiles.setLastError("AIL_decompress_ASI: out of memory");
            return 0;
        });
        @memcpy(buf[0..wav.len], wav);
        o.* = buf;
    }
    if (wavsize) |o| o.* = @intCast(wav.len);
    return 1;
}

// --- v8.0j+ / v9 stdcall RIB exports ------------------------------------------
// The RIB interface API switched from __cdecl (undecorated, v6-v8.0b) to
// __stdcall (decorated `_RIB_*@N`, v8.0j onward). These thin wrappers carry the
// stdcall convention for the v8+ export targets; the `.c` bodies above are the
// ones a build before 8.0 exports under the bare name.
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

const testing = std.testing;

test "a configured TMPDIR is copied with a trailing separator" {
    var buf: [max_temp_path_units * 3]u8 = undefined;
    // The separator appendSeparator adds is std.fs.path.sep, so the
    // expectation is built from it too: on Windows the same contract reads as
    // a trailing '\', and a literal '/' in the expectation tested the host
    // rather than the code.
    const with_sep = "/var/tmp" ++ [_]u8{std.fs.path.sep};
    const out = configuredTempDir("/var/tmp", &buf).?;
    try testing.expectEqualStrings(with_sep, out);
    // An operator's trailing separator is not doubled.
    const kept = configuredTempDir(with_sep, &buf).?;
    try testing.expectEqualStrings(with_sep, kept);
}

test "a rejected TMPDIR returns null instead of a partial path" {
    var buf: [16]u8 = undefined;
    // Set but empty: an exported TMPDIR= is a broken launcher environment, and
    // reading it as "use the game directory" is what the report is for.
    try testing.expectEqual(@as(?[]const u8, null), configuredTempDir("", &buf));
    // Relative: it resolves against the cwd, which is where the fallback goes.
    try testing.expectEqual(@as(?[]const u8, null), configuredTempDir("tmp", &buf));
    try testing.expectEqual(@as(?[]const u8, null), configuredTempDir(".", &buf));
    // Longer than the buffer, with room for the separator it would need.
    try testing.expectEqual(@as(?[]const u8, null), configuredTempDir("/" ++ "a" ** 32, &buf));
}

test "a temp directory is used only while the image name still fits the limit" {
    // A directory that exactly fits the tail plus the terminator opens; one
    // character more does not, and a name over the limit is not one any create
    // call can make without the long-path opt-in.
    const fits_units = 64;
    const room = fits_units - temp_image_name_units - 1;
    try testing.expect(pathFitsUnitLimit("/" ++ "a" ** (room - 2) ++ "/", fits_units));
    try testing.expect(!pathFitsUnitLimit("/" ++ "a" ** (room - 1) ++ "/", fits_units));
    // Counted in UTF-16 units, not UTF-8 bytes: a directory of characters
    // outside ASCII spends fewer units than it spends bytes, so a byte count
    // would reject a path that opens.
    const accented = "C:\\Users\\Jos\\Aventura Épica\\Temp\\";
    const accented_units = 33; // one per character, É included once
    try testing.expect(pathFitsUnitLimit(accented, accented_units + temp_image_name_units + 1));
    try testing.expect(!pathFitsUnitLimit(accented, accented_units + temp_image_name_units));
    try testing.expect(accented.len > accented_units);
}

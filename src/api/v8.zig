//! MSS v8 additive API. The faithfully-implementable pieces are real here —
//! in-memory I/O (AIL_mem_*), case-insensitive string compares, float-to-ascii,
//! 5.1 volumes mapped to the engine, and sample 3D/rate helpers. The soundbank /
//! event / preset / environment system (a proprietary data-driven layer) has no
//! OpenMiles engine equivalent and is stubbed to link and return safe defaults.
//! Signatures from the MSS 9.x SDK mss.h.
const std = @import("std");
const openmiles = @import("openmiles");
const Sample = openmiles.Sample;
const ma = openmiles.ma;

const MSS_FIRST: usize = std.math.maxInt(usize);

/// Shared enumerator over a bank asset table (sounds/events/presets/envs).
fn enumerateAssets(bank: ?*anyopaque, next: ?*anyopaque, name: ?*anyopaque, kind: openmiles.soundbank.AssetKind) i32 {
    const b: *openmiles.Bank = @ptrCast(@alignCast(bank orelse return 0));
    const np: *usize = @ptrCast(@alignCast(next orelse return 0));
    const out: *?*anyopaque = @ptrCast(@alignCast(name orelse return 0));
    const idx: usize = if (np.* == MSS_FIRST) 0 else np.*;
    if (idx >= b.assetCount(kind)) return 0;
    const nm = b.assetName(kind, @intCast(idx)) orelse return 0;
    out.* = @constCast(@ptrCast(nm));
    np.* = idx + 1;
    return 1;
}


/// MILESMEM: an in-memory byte stream (AIL_mem_* family).
const MemStream = struct {
    buf: []u8,
    len: usize, // valid bytes (for read views == buf.len; for write grows)
    pos: usize = 0,
    owns: bool, // buf was allocated by us (free on close)
    writable: bool,
    err: bool = false,

    fn create(self_buf: []u8, length: usize, owns: bool, writable: bool) ?*MemStream {
        const m = openmiles.global_allocator.create(MemStream) catch return null;
        m.* = .{ .buf = self_buf, .len = length, .owns = owns, .writable = writable };
        return m;
    }
};

fn cstrlen(p: [*:0]const u8) usize {
    return std.mem.len(p);
}


// --- WAV cue-point ("marker") parsing -------------------------------------
// A RIFF/WAVE image can carry a 'cue ' chunk (a list of cue points, each with a
// sample offset) and a LIST/adtl/'labl' chunk mapping cue ids to names. These
// helpers walk those chunks with full bounds checking so a malformed/truncated
// image is rejected rather than over-read.

fn wavImageLen(p: [*]const u8) ?usize {
    // RIFF<size>WAVE ; total image = size + 8.
    if (p[0] != 'R' or p[1] != 'I' or p[2] != 'F' or p[3] != 'F') return null;
    if (p[8] != 'W' or p[9] != 'A' or p[10] != 'V' or p[11] != 'E') return null;
    const riff = std.mem.readInt(u32, p[4..8], .little);
    return @as(usize, riff) + 8;
}

const WavCue = struct { id: u32, offset: u32 };

/// Find a chunk by fourcc within [12, len). Returns (data_offset, data_len).
fn findChunk(img: []const u8, fourcc: *const [4]u8) ?struct { off: usize, len: usize } {
    var i: usize = 12;
    while (i + 8 <= img.len) {
        const csz = std.mem.readInt(u32, img[i + 4 ..][0..4], .little);
        const data = i + 8;
        if (data > img.len) break;
        const avail = img.len - data;
        const clen = @min(@as(usize, csz), avail);
        if (std.mem.eql(u8, img[i..][0..4], fourcc)) return .{ .off = data, .len = clen };
        i = data + clen + (clen & 1); // chunks are word-aligned
    }
    return null;
}

/// Name for cue `id` from the LIST/adtl/labl chunks, or null. The returned
/// slice points into the image (NUL-terminated there).
fn cueLabel(img: []const u8, id: u32) ?[*:0]const u8 {
    const list = findChunk(img, "LIST") orelse return null;
    if (list.len < 4 or !std.mem.eql(u8, img[list.off..][0..4], "adtl")) return null;
    var i: usize = list.off + 4;
    const end = list.off + list.len;
    while (i + 8 <= end) {
        const csz = std.mem.readInt(u32, img[i + 4 ..][0..4], .little);
        const data = i + 8;
        if (data > end) break;
        const clen = @min(@as(usize, csz), end - data);
        if (std.mem.eql(u8, img[i..][0..4], "labl") and clen >= 4) {
            const lid = std.mem.readInt(u32, img[data..][0..4], .little);
            if (lid == id) {
                const str_start = data + 4;
                // Require a NUL terminator within the chunk.
                if (std.mem.indexOfScalar(u8, img[str_start .. data + clen], 0) != null)
                    return @ptrCast(img.ptr + str_start);
            }
        }
        i = data + clen + (clen & 1);
    }
    return null;
}

fn wavCueAt(img: []const u8, n: usize) ?WavCue {
    const cue = findChunk(img, "cue ") orelse return null;
    if (cue.len < 4) return null;
    const count = std.mem.readInt(u32, img[cue.off..][0..4], .little);
    if (n >= count) return null;
    const rec = cue.off + 4 + n * 24; // each cue point is 24 bytes
    if (rec + 24 > img.len) return null;
    return .{
        .id = std.mem.readInt(u32, img[rec..][0..4], .little),
        .offset = std.mem.readInt(u32, img[rec + 20 ..][0..4], .little), // dwSampleOffset
    };
}

pub fn AIL_WAV_marker_count(wav_image: ?*const anyopaque) callconv(.winapi) i32 {
    const raw = wav_image orelse return 0;
    const p: [*]const u8 = @ptrCast(raw);
    const len = wavImageLen(p) orelse return 0;
    const img = p[0..len];
    const cue = findChunk(img, "cue ") orelse return 0;
    if (cue.len < 4) return 0;
    return @intCast(@min(std.mem.readInt(u32, img[cue.off..][0..4], .little), std.math.maxInt(i32)));
}

pub fn AIL_WAV_marker_by_index(wav_image: ?*const anyopaque, n: i32, name: ?*?[*:0]const u8) callconv(.winapi) i32 {
    const raw = wav_image orelse return -1;
    if (n < 0) return -1;
    const p: [*]const u8 = @ptrCast(raw);
    const len = wavImageLen(p) orelse return -1;
    const img = p[0..len];
    const c = wavCueAt(img, @intCast(n)) orelse return -1;
    if (name) |np| np.* = cueLabel(img, c.id);
    return @intCast(@min(c.offset, std.math.maxInt(i32)));
}

pub fn AIL_WAV_marker_by_name(wav_image: ?*const anyopaque, name: ?[*:0]const u8) callconv(.winapi) i32 {
    const raw = wav_image orelse return -1;
    const want = name orelse return -1;
    const want_s = std.mem.span(want);
    const p: [*]const u8 = @ptrCast(raw);
    const len = wavImageLen(p) orelse return -1;
    const img = p[0..len];
    const cue = findChunk(img, "cue ") orelse return -1;
    if (cue.len < 4) return -1;
    const count = std.mem.readInt(u32, img[cue.off..][0..4], .little);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const c = wavCueAt(img, i) orelse break;
        if (cueLabel(img, c.id)) |lbl| {
            if (std.mem.eql(u8, std.mem.span(lbl), want_s)) return @intCast(@min(c.offset, std.math.maxInt(i32)));
        }
    }
    return -1;
}
pub fn AIL_add_apply_environment_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: i32) callconv(.winapi) i32 {
    const e: *EventConstruct = @ptrCast(@alignCast(a0 orelse return 0));
    return if (e.addApplyEnv(a1, a2)) 1 else 0;
}
pub fn AIL_add_cache_sounds_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    const e: *EventConstruct = @ptrCast(@alignCast(a0 orelse return 0));
    return if (e.addCacheSounds(.cache_sounds, a1, a2)) 1 else 0;
}
pub fn AIL_add_comment_event_step(event: ?*anyopaque, comment: ?[*:0]const u8) callconv(.winapi) i32 {
    const e: *EventConstruct = @ptrCast(@alignCast(event orelse return 0));
    const c = if (comment) |p| std.mem.span(p) else "";
    return if (e.addComment(c)) 1 else 0;
}
pub fn AIL_add_control_sounds_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque, a4: ?*anyopaque, a5: ?*anyopaque, a6: i32, a7: f32, a8: i32, a9: i32) callconv(.winapi) i32 {
    const e: *EventConstruct = @ptrCast(@alignCast(a0 orelse return 0));
    // SDK order: labels, markerstart, markerend, position, presetname,
    // presetapply(a6), fadeout(a7), loopcount(a8), type(a9).
    const loop: u8 = @truncate(@as(u32, @bitCast(a8)));
    return if (e.addControlSounds(a1, a2, a3, a4, a5, loop, a9, a7, a6)) 1 else 0;
}
pub fn AIL_add_persist_preset_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque, a4: i32) callconv(.winapi) i32 {
    const e: *EventConstruct = @ptrCast(@alignCast(a0 orelse return 0));
    return if (e.addPersist(a1, a2, a3, a4)) 1 else 0;
}
pub fn AIL_add_sound_limit_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    const e: *EventConstruct = @ptrCast(@alignCast(a0 orelse return 0));
    return if (e.addSoundLimit(a1, a2)) 1 else 0;
}
pub fn AIL_add_start_sound_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: i32, a4: ?*anyopaque, a5: ?*anyopaque, a6: ?*anyopaque, a7: ?*anyopaque, a8: ?*anyopaque, a9: ?*anyopaque, a10: u32, a11: i32, a12: i32, a13: i32, a14: i32, a15: i32, a16: ?*anyopaque, a17: f32, a18: f32, a19: f32, a20: f32, a21: f32, a22: i32, a23: i32) callconv(.winapi) i32 {
    const e: *EventConstruct = @ptrCast(@alignCast(a0 orelse return 0));
    // SDK arg order: soundnames, presetname, presetisdynamic, eventname,
    // startmarker, endmarker, statevar, varinit, labels, streaming, canload,
    // delay, delaymax, priority, loopcount, startoffset, vol/pitch/fade, types.
    const args = openmiles.event.StartSoundArgs{
        .soundname = a1,
        .presetname = a2,
        .presetisdynamic = a3,
        .eventname = a4,
        .markerstart = a5,
        .markerend = a6,
        .statevar = a7,
        .varinit = a8,
        .labels = a9,
        .stream = @bitCast(a10),
        .canload = a11,
        .delaymin = @truncate(@as(u32, @bitCast(a12))),
        .delaymax = @truncate(@as(u32, @bitCast(a13))),
        .priority = @truncate(@as(u32, @bitCast(a14))),
        .loopcount = @truncate(@as(u32, @bitCast(a15))),
        .startoffset = a16,
        .volmin = a17,
        .volmax = a18,
        .pitchmin = a19,
        .pitchmax = a20,
        .fadeintime = a21,
        .evictiontype = a22,
        .selecttype = a23,
    };
    return if (e.addStartSound(args)) 1 else 0;
}
pub fn AIL_add_uncache_sounds_event_step(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    const e: *EventConstruct = @ptrCast(@alignCast(a0 orelse return 0));
    return if (e.addCacheSounds(.purge_sounds, a1, a2)) 1 else 0;
}
pub fn AIL_apply_environment_preset(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub fn AIL_apply_sound_preset(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub fn AIL_close_event(event: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const e: *EventConstruct = @ptrCast(@alignCast(event orelse return null));
    return @ptrCast(e.close());
}
pub fn AIL_close_soundbank(bank: ?*anyopaque) callconv(.winapi) void {
    const b: *openmiles.Bank = @ptrCast(@alignCast(bank orelse return));
    b.deinit();
}
const EventConstruct = openmiles.event.EventConstruct;
pub fn AIL_create_event() callconv(.winapi) ?*anyopaque {
    return @ptrCast(EventConstruct.create(openmiles.global_allocator));
}
pub fn AIL_debug(a0: ?*anyopaque) callconv(.c) void {
    _ = a0;

}
pub fn AIL_debug_log(a0: ?*anyopaque) callconv(.c) void {
    _ = a0;

}
pub fn AIL_enumerate_environment_presets(bank: ?*anyopaque, next: ?*anyopaque, list: ?*anyopaque, name: ?*anyopaque) callconv(.winapi) i32 {
    _ = list;
    return enumerateAssets(bank, next, name, .environments);
}
pub fn AIL_enumerate_events(bank: ?*anyopaque, next: ?*anyopaque, list: ?*anyopaque, name: ?*anyopaque) callconv(.winapi) i32 {
    _ = list;
    return enumerateAssets(bank, next, name, .events);
}
pub fn AIL_enumerate_filter_properties(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub fn AIL_enumerate_filter_sample_properties(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub fn AIL_enumerate_output_filter_driver_properties(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub fn AIL_enumerate_output_filter_sample_properties(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub fn AIL_enumerate_sample_stage_properties(a0: ?*anyopaque, a1: i32, a2: ?*anyopaque, a3: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    return 0;
}
pub fn AIL_enumerate_sound_assets(bank: ?*anyopaque, next: ?*anyopaque, name: ?*anyopaque) callconv(.winapi) i32 {
    return enumerateAssets(bank, next, name, .sounds);
}
pub fn AIL_enumerate_sound_presets(bank: ?*anyopaque, next: ?*anyopaque, list: ?*anyopaque, name: ?*anyopaque) callconv(.winapi) i32 {
    _ = list;
    return enumerateAssets(bank, next, name, .presets);
}
pub fn AIL_file_type_named(a0: ?*anyopaque, a1: ?*anyopaque, a2: u32) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub fn AIL_filter_property(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque, a4: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    return 0;
}
pub fn AIL_find_marker_in_list(a0: i32, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub fn AIL_ftoa(v: f32, buf: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const b = buf orelse return null;
    const out = @as([*]u8, @ptrCast(b));
    const slice = std.fmt.bufPrint(out[0..32], "{d}\x00", .{v}) catch {
        out[0] = 0;
        return b;
    };
    _ = slice;
    return b;
}
pub fn AIL_get_event_contents(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    // (SoundBank* bank, char const* name, U8 const** out_event)
    const b: *openmiles.Bank = @ptrCast(@alignCast(a0 orelse return 0));
    const name_p = a1 orelse return 0;
    const name = std.mem.span(@as([*:0]const u8, @ptrCast(name_p)));
    const out: *?[*]const u8 = @ptrCast(@alignCast(a2 orelse return 0));
    if (b.findEventContents(name)) |ev| {
        out.* = ev;
        return 1;
    }
    out.* = null;
    return 0;
}
pub fn AIL_get_marker_list(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub fn AIL_get_soundbank_filename(bank: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const b: *openmiles.Bank = @ptrCast(@alignCast(bank orelse return null));
    return @constCast(@ptrCast(b.filename.ptr));
}
pub fn AIL_get_soundbank_mem_usage(bank: ?*anyopaque) callconv(.winapi) i32 {
    const b: *openmiles.Bank = @ptrCast(@alignCast(bank orelse return 0));
    return b.metaSize();
}
pub fn AIL_indent(a0: i32) callconv(.c) void {
    _ = a0;

}
// Real MSS: AIL_mem_close(mem, void** data, U32* size) @12 — close a write
// stream, optionally handing the accumulated buffer (C-malloc'd, caller frees
// via AIL_mem_free_lock) back through data/size.
pub fn AIL_mem_close(mem: ?*anyopaque, data_out: ?*?*anyopaque, size_out: ?*u32) callconv(.winapi) void {
    const m: *MemStream = @ptrCast(@alignCast(mem orelse {
        if (data_out) |d| d.* = null;
        if (size_out) |s| s.* = 0;
        return;
    }));
    if (data_out) |d| {
        if (m.len > 0) {
            if (std.c.malloc(m.len)) |raw| {
                const out: [*]u8 = @ptrCast(raw);
                @memcpy(out[0..m.len], m.buf[0..m.len]);
                d.* = raw;
                if (size_out) |s| s.* = @intCast(m.len);
            } else {
                d.* = null;
                if (size_out) |s| s.* = 0;
            }
        } else {
            d.* = null;
            if (size_out) |s| s.* = 0;
        }
    }
    if (m.owns) openmiles.global_allocator.free(m.buf);
    openmiles.global_allocator.destroy(m);
}
// Real MSS: AIL_mem_create() @0 — create an empty, growable in-memory write
// stream (writes append and grow the backing buffer; see AIL_mem_close).
pub fn AIL_mem_create() callconv(.winapi) ?*anyopaque {
    const buf = openmiles.global_allocator.alloc(u8, 0) catch return null;
    const m = MemStream.create(buf, 0, true, true) orelse {
        openmiles.global_allocator.free(buf);
        return null;
    };
    return @ptrCast(m);
}
pub fn AIL_mem_create_from_existing(data: ?*anyopaque, size: i32) callconv(.winapi) ?*anyopaque {
    const d = data orelse return null;
    if (size <= 0) return null;
    const view = @as([*]u8, @ptrCast(d))[0..@intCast(size)];
    const m = MemStream.create(view, @intCast(size), false, true) orelse return null;
    return @ptrCast(m);
}
pub fn AIL_mem_error(mem: ?*anyopaque) callconv(.winapi) i32 {
    const m: *MemStream = @ptrCast(@alignCast(mem orelse return 1));
    return if (m.err) 1 else 0;
}
pub fn AIL_mem_open(data: ?*anyopaque, size: i32) callconv(.winapi) ?*anyopaque {
    const d = data orelse return null;
    if (size < 0) return null;
    const view = @as([*]u8, @ptrCast(@constCast(d)))[0..@intCast(size)];
    const m = MemStream.create(view, @intCast(size), false, false) orelse return null;
    return @ptrCast(m);
}
pub fn AIL_mem_pos(mem: ?*anyopaque) callconv(.winapi) i32 {
    const m: *MemStream = @ptrCast(@alignCast(mem orelse return 0));
    return @intCast(@min(m.pos, @as(usize, std.math.maxInt(i32))));
}
pub fn AIL_mem_printc(mem: ?*anyopaque, c: i32) callconv(.winapi) i32 {
    var ch: [1]u8 = .{@truncate(@as(u32, @bitCast(c)))};
    return AIL_mem_write(mem, &ch, 1);
}
pub fn AIL_mem_printf(mem: ?*anyopaque, fmt: ?*anyopaque) callconv(.c) i32 {
    // Variadic formatting is not bridged; write the format string verbatim.
    return AIL_mem_prints(mem, fmt);
}
pub fn AIL_mem_prints(mem: ?*anyopaque, str: ?*anyopaque) callconv(.winapi) i32 {
    const sp = str orelse return 0;
    const cstr: [*:0]const u8 = @ptrCast(sp);
    const len = std.mem.len(cstr);
    if (len == 0) return 0;
    return AIL_mem_write(mem, @constCast(@ptrCast(sp)), @intCast(@min(len, @as(usize, std.math.maxInt(i32)))));
}
pub fn AIL_mem_read(mem: ?*anyopaque, dst: ?*anyopaque, n: i32) callconv(.winapi) i32 {
    const m: *MemStream = @ptrCast(@alignCast(mem orelse return 0));
    const d = dst orelse return 0;
    if (n <= 0) return 0;
    const want: usize = @intCast(n);
    const avail = if (m.pos < m.len) m.len - m.pos else 0;
    const take = @min(want, avail);
    @memcpy(@as([*]u8, @ptrCast(d))[0..take], m.buf[m.pos .. m.pos + take]);
    m.pos += take;
    return @intCast(take);
}
pub fn AIL_mem_seek(mem: ?*anyopaque, pos: i32) callconv(.winapi) i32 {
    const m: *MemStream = @ptrCast(@alignCast(mem orelse return -1));
    const p: usize = if (pos < 0) 0 else @intCast(pos);
    m.pos = @min(p, m.buf.len);
    return @intCast(m.pos);
}
pub fn AIL_mem_size(mem: ?*anyopaque) callconv(.winapi) i32 {
    const m: *MemStream = @ptrCast(@alignCast(mem orelse return 0));
    return @intCast(@min(m.len, @as(usize, std.math.maxInt(i32))));
}
pub fn AIL_mem_write(mem: ?*anyopaque, src: ?*anyopaque, n: i32) callconv(.winapi) i32 {
    const m: *MemStream = @ptrCast(@alignCast(mem orelse return 0));
    const sp = src orelse return 0;
    if (n <= 0 or !m.writable) return 0;
    const want: usize = @intCast(n);
    // Owned write streams grow to fit (AIL_mem_create semantics); views over
    // caller memory stay fixed and truncate at the end of the buffer.
    if (m.owns and m.pos + want > m.buf.len) {
        if (openmiles.global_allocator.realloc(m.buf, m.pos + want)) |nb| {
            m.buf = nb;
        } else |_| {}
    }
    const room = if (m.pos < m.buf.len) m.buf.len - m.pos else 0;
    const take = @min(want, room);
    if (take < want) m.err = true; // truncated write
    @memcpy(m.buf[m.pos .. m.pos + take], @as([*]const u8, @ptrCast(sp))[0..take]);
    m.pos += take;
    if (m.pos > m.len) m.len = m.pos;
    return @intCast(take);
}
// AIL_next_event_step(eventString, &stepInfo, buffer, bufferSize) — decode the
// next step of the serialized event text. Writes a decoded EventStepInfo into
// the caller's scratch buffer and returns the pointer past this step, or null at
// the end (the event string is NUL-terminated).
pub fn AIL_next_event_step(event_string: ?*const anyopaque, step_out: ?*?*openmiles.event.EVENT_STEP_INFO, buffer: ?*anyopaque, buffer_size: i32) callconv(.winapi) ?*const anyopaque {
    const p: [*:0]const u8 = @ptrCast(event_string orelse return null);
    const buf = buffer orelse return null;
    const ssz = @sizeOf(openmiles.event.EVENT_STEP_INFO);
    if (buffer_size < 0 or @as(usize, @intCast(buffer_size)) < ssz) return null;
    const info: *openmiles.event.EVENT_STEP_INFO = @ptrCast(@alignCast(buf));
    // Strings are copied into the buffer space following the struct.
    const scratch_ptr: [*]u8 = @as([*]u8, @ptrCast(buf)) + ssz;
    const scratch = scratch_ptr[0 .. @as(usize, @intCast(buffer_size)) - ssz];
    const next = openmiles.event.nextStep(p, info, scratch) orelse {
        if (step_out) |so| so.* = info;
        return null;
    };
    if (step_out) |so| so.* = info;
    return @ptrCast(next);
}
pub fn AIL_open_soundbank(filename: ?*anyopaque, name: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const fn_ptr = filename orelse return null;
    const fname: [*:0]const u8 = @ptrCast(fn_ptr);
    const fname_slice = std.mem.span(fname);
    // Read the file via the configured callbacks / filesystem.
    const image = openmiles.readWholeFile(fname_slice) catch return null;
    defer openmiles.global_allocator.free(image);
    const bank = openmiles.soundbank.loadFromMemory(openmiles.global_allocator, fname_slice, image) catch {
        openmiles.setLastError("Failed to open sound bank");
        return null;
    };
    // Optional name check (4-char bank name).
    if (name) |np| {
        const want: [*:0]const u8 = @ptrCast(np);
        const have = bank.name();
        if (!std.ascii.eqlIgnoreCase(std.mem.span(want), std.mem.span(have))) {
            bank.deinit();
            openmiles.setLastError("Bank name mismatch");
            return null;
        }
    }
    return @ptrCast(bank);
}
pub fn AIL_output_filter_driver_property(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque, a4: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    return 0;
}
pub fn AIL_platform_property(a0: ?*anyopaque, a1: i32, a2: ?*anyopaque, a3: ?*anyopaque, a4: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    return 0;
}
pub fn AIL_register_falloff_function_callback(a0: ?*anyopaque, a1: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub fn AIL_register_trace_callback(a0: ?*anyopaque) callconv(.winapi) void {
    _ = a0;

}
pub fn AIL_sample_51_volume_levels(s_opt: ?*Sample, fl: ?*f32, fr: ?*f32, fc: ?*f32, lfe: ?*f32, bl: ?*f32, br: ?*f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    if (fl) |p| p.* = s.v51_levels[0];
    if (fr) |p| p.* = s.v51_levels[1];
    if (fc) |p| p.* = s.v51_levels[2];
    if (lfe) |p| p.* = s.v51_levels[3];
    if (bl) |p| p.* = s.v51_levels[4];
    if (br) |p| p.* = s.v51_levels[5];
}
pub fn AIL_sample_51_volume_pan(s_opt: ?*Sample, volume: ?*f32, pan: ?*f32, fb_pan: ?*f32, center_level: ?*f32, lfe_level: ?*f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    const fl = s.v51_levels[0];
    const fr = s.v51_levels[1];
    const bl = s.v51_levels[4];
    const br = s.v51_levels[5];
    if (volume) |p| p.* = @max(@max(fl, fr), @max(bl, br));
    const lr = fl + fr;
    if (pan) |p| p.* = if (lr > 0.0001) fr / lr else 0.5; // left..right balance
    const fb = (fl + fr) + (bl + br);
    if (fb_pan) |p| p.* = if (fb > 0.0001) (bl + br) / fb else 0.5; // front..back
    if (center_level) |p| p.* = s.v51_levels[2];
    if (lfe_level) |p| p.* = s.v51_levels[3];
}
pub fn AIL_sample_buffer_available(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return if (s.stream_active) 1 else 0; // at least one slot free to refill
}
pub fn AIL_sample_buffer_count(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return if (s.stream_active) 2 else 1; // ping-pong double buffer while streaming
}
pub fn AIL_sample_channel_count(s_opt: ?*Sample, mask: ?*u32) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    const ch: i32 = if (s.decoder) |d| @intCast(d.outputChannels) else if (s.pcm_format) |f| @intCast(f.channels) else 2;
    // Speaker mask: FL|FR for stereo, FC for mono (the common cases).
    if (mask) |m| m.* = if (ch >= 2) 0x3 else 0x4;
    return ch;
}
pub fn AIL_sample_loop_block(s_opt: ?*Sample, loop_start: ?*i32, loop_end: ?*i32) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    const bpf: u64 = s.bytesPerFrame();
    const sat = std.math.maxInt(i32);
    if (loop_start) |p| p.* = @intCast(@min(s.loop_start_frame *| bpf, sat));
    if (loop_end) |p| p.* = @intCast(@min(s.loop_end_frame *| bpf, sat));
    return if (s.loop_end_frame > 0) 1 else 0;
}
pub fn AIL_sample_output_levels(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque, a4: i32) callconv(.winapi) f32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    return 0;
}
pub fn AIL_sample_playback_delay(s_opt: ?*Sample) callconv(.winapi) i32 {
    const s = s_opt orelse return 0;
    return s.v9_playback_delay;
}
pub fn AIL_sample_playback_rate_factor(s_opt: ?*Sample) callconv(.winapi) f32 {
    const s = s_opt orelse return 1.0;
    return if (s.v7_rate_factor > 0) s.v7_rate_factor else 1.0;
}
pub fn AIL_sample_speaker_scale_factors(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;

}
pub fn AIL_sample_stage_property(a0: ?*anyopaque, a1: i32, a2: ?*anyopaque, a3: i32, a4: ?*anyopaque, a5: ?*anyopaque, a6: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    _ = a5;
    _ = a6;
    return 0;
}
// v7 uses a 6-argument @24 form (the 7-arg @28 form is 6.x and 8.x+).
pub fn AIL_sample_stage_property_v7(a0: ?*anyopaque, a1: i32, a2: ?*anyopaque, a3: i32, a4: ?*anyopaque, a5: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;
    _ = a4;
    _ = a5;
    return 0;
}
pub fn AIL_set_sample_51_volume_levels(s_opt: ?*Sample, fl: f32, fr: f32, fc: f32, lfe: f32, bl: f32, br: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.v51_levels = .{ fl, fr, fc, lfe, bl, br }; // remember all six (round-trips via the getter)
    // Engine is stereo; drive volume from the front L/R pair.
    s.setVolume(@intFromFloat(std.math.clamp(@max(fl, fr), 0.0, 1.0) * 127.0));
    const sum = fl + fr;
    if (sum > 0.0001) s.setPan(@intFromFloat(std.math.clamp(fr / sum, 0.0, 1.0) * 127.0));
}
pub fn AIL_set_sample_51_volume_pan(s_opt: ?*Sample, volume: f32, pan: f32, fb: f32, lfe: f32, fc: f32) callconv(.winapi) void {
    _ = fb;
    _ = lfe;
    _ = fc;
    const s = s_opt orelse return;
    s.setVolume(@intFromFloat(std.math.clamp(volume, 0.0, 1.0) * 127.0));
    s.setPan(@intFromFloat(std.math.clamp(pan, 0.0, 1.0) * 127.0));
}
pub fn AIL_set_sample_buffer_count(a0: ?*anyopaque, a1: i32) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    return 0;
}
pub fn AIL_set_sample_is_3D(s_opt: ?*Sample, is_3D: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    if (s.is_initialized) ma.ma_sound_set_spatialization_enabled(&s.sound, if (is_3D != 0) ma.MA_TRUE else ma.MA_FALSE);
}
pub fn AIL_set_sample_playback_delay(s_opt: ?*Sample, delay_ms: i32) callconv(.winapi) void {
    const s = s_opt orelse return;
    s.v9_playback_delay = delay_ms;
}
pub fn AIL_set_sample_playback_rate_factor(s_opt: ?*Sample, factor: f32) callconv(.winapi) void {
    const s = s_opt orelse return;
    if (s.is_initialized and factor > 0) ma.ma_sound_set_pitch(&s.sound, factor);
    s.v7_rate_factor = factor;
}
pub fn AIL_set_sample_speaker_scale_factors(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;
    _ = a2;
    _ = a3;

}
pub fn AIL_sound_asset_filename(a0: ?*anyopaque, a1: i32) callconv(.winapi) void {
    _ = a0;
    _ = a1;

}
pub fn AIL_stricmp(a: ?*anyopaque, b: ?*anyopaque) callconv(.winapi) i32 {
    const pa: [*:0]const u8 = @ptrCast(a orelse return 0);
    const pb: [*:0]const u8 = @ptrCast(b orelse return 0);
    var i: usize = 0;
    while (true) : (i += 1) {
        const ca = std.ascii.toLower(pa[i]);
        const cb = std.ascii.toLower(pb[i]);
        if (ca != cb) return @as(i32, ca) - @as(i32, cb);
        if (ca == 0) return 0;
    }
}
pub fn AIL_strnicmp(a: ?*anyopaque, b: ?*anyopaque, n: u32) callconv(.winapi) i32 {
    const pa: [*:0]const u8 = @ptrCast(a orelse return 0);
    const pb: [*:0]const u8 = @ptrCast(b orelse return 0);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ca = std.ascii.toLower(pa[i]);
        const cb = std.ascii.toLower(pb[i]);
        if (ca != cb) return @as(i32, ca) - @as(i32, cb);
        if (ca == 0) return 0;
    }
    return 0;
}
pub fn AIL_sys_debug(a0: ?*anyopaque) callconv(.c) void {
    _ = a0;

}
pub fn AIL_unapply_environment_preset(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}
pub fn AIL_unapply_sound_preset(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque) callconv(.winapi) i32 {
    _ = a0;
    _ = a1;
    _ = a2;
    return 0;
}

// --- v8-only ABI variants (narrower than the v9 forms) -----------------------
// v8 predates several v9 parameters: an extra event-queue/limit argument on the
// event-step builders, the soundbank "name" argument, the per-marker list arg,
// and the ftoa output buffer. These variants match the exact v8 decorations and
// forward to the v9 implementations, defaulting the parameters v9 later added.
// v8 form is @32 (8 args); v9 adds two trailing args (@40).
pub fn AIL_add_control_sounds_event_step_v8(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque, a4: ?*anyopaque, a5: ?*anyopaque, a6: i32, a7: f32) callconv(.winapi) i32 {
    return AIL_add_control_sounds_event_step(a0, a1, a2, a3, a4, a5, a6, a7, 0, 0);
}
// v8 form @8 (2 args); v9 adds a trailing S32 (@12).
pub fn AIL_add_apply_environment_event_step_v8(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) i32 {
    return AIL_add_apply_environment_event_step(a0, a1, 0);
}
// v8 form @16 (4 args); v9 adds a trailing S32 (@20).
pub fn AIL_add_persist_preset_event_step_v8(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: ?*anyopaque) callconv(.winapi) i32 {
    return AIL_add_persist_preset_event_step(a0, a1, a2, a3, 0);
}
// v8 form @8 (2 args); v9 dropped the second arg (@4).
pub fn AIL_get_soundbank_filename_v8(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    _ = a1;
    return AIL_get_soundbank_filename(a0);
}
pub fn AIL_add_sound_limit_event_step_v8(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) i32 {
    return AIL_add_sound_limit_event_step(a0, a1, null);
}
// v8 form is @76 (19 args); v9 adds five trailing args (@96).
pub fn AIL_add_start_sound_event_step_v8(a0: ?*anyopaque, a1: ?*anyopaque, a2: ?*anyopaque, a3: i32, a4: ?*anyopaque, a5: ?*anyopaque, a6: ?*anyopaque, a7: ?*anyopaque, a8: ?*anyopaque, a9: ?*anyopaque, a10: u32, a11: i32, a12: i32, a13: i32, a14: i32, a15: i32, a16: ?*anyopaque, a17: f32, a18: f32) callconv(.winapi) i32 {
    return AIL_add_start_sound_event_step(a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15, a16, a17, a18, 0.0, 0.0, 1.0, 0, 0);
}
pub fn AIL_find_marker_in_list_v8(a0: i32, a1: ?*anyopaque) callconv(.winapi) i32 {
    return AIL_find_marker_in_list(a0, a1, null);
}
var ftoa_buf: [32]u8 = undefined;
pub fn AIL_ftoa_v8(v: f32) callconv(.winapi) ?*anyopaque {
    return AIL_ftoa(v, &ftoa_buf);
}
pub fn AIL_open_soundbank_v8(filename: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    return AIL_open_soundbank(filename, null);
}
pub fn AIL_register_trace_callback_v8(a0: ?*anyopaque, a1: ?*anyopaque) callconv(.winapi) void {
    _ = a1;
    AIL_register_trace_callback(a0);
}
// AIL_sound_asset_filename(SoundBank* bank, char const* name, char* out_filename)
// @12 — writes "*<bankfile><soundfile>" and returns the sound's DataLen (hlbank.cpp).
pub fn AIL_sound_asset_filename_v8(bank: ?*anyopaque, name: ?*anyopaque, out: ?*anyopaque) callconv(.winapi) i32 {
    const b: *openmiles.Bank = @ptrCast(@alignCast(bank orelse return -1));
    const nm = std.mem.span(@as([*:0]const u8, @ptrCast(name orelse return -1)));
    const o: [*]u8 = @ptrCast(out orelse return -1);
    return b.soundAssetFilename(nm, o);
}
// MSSDisableThreadLibraryCalls(HMODULE)@4 — a v8 DllMain helper; no-op here.
pub fn MSSDisableThreadLibraryCalls(hmodule: ?*anyopaque) callconv(.winapi) void {
    _ = hmodule;
}

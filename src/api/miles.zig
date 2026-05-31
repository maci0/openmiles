//! Miles 9.x event-system C-ABI (`Miles*` exports). The 9.x SDK header `#define`s
//! the classic `AIL_*` event names onto these `Miles*` symbols, so 9.x games link
//! against `_MilesStartupEventSystem@16`, `_MilesSetVarI@12`, etc. rather than the
//! `AIL_*` names. The real mss32.dll (9.3f/9.3k) exports the `Miles*` set; this
//! module supplies them.
//!
//! Implemented behaviour: the event-system lifecycle (a linked list of systems
//! rooted at `g_root`), the per-system variable store, the soundbank container
//! (banks register on load; events/sounds resolve by name across them), event
//! enqueue/decode that creates tracked sound instances per start_sound step, the
//! sound-instance lifecycle (PENDING→PLAYING→COMPLETE progressed by the bank
//! sound duration), cache/purge bookkeeping (LoadedSoundCount) and the persisted-
//! preset list (PersistCount). MilesGetEventLength resolves a sound's duration
//! via the container.
//!
//! Not yet wired: actual audio playback through the miniaudio mixer (instances
//! progress by duration, not by a playing sample), the ramp/blend/LFO/persist
//! *application* to live sounds, and async file I/O (MilesAsync*) — those return
//! safe defaults.
//!
//! Divergence from the SDK, deliberately: `MilesGetVarInternal` dereferences an
//! arbitrary `i_Context` as a `U32*` to sniff the 'ESYS' tag. We instead verify
//! the pointer against our own live system list before trusting it, so a stray
//! handle yields "not found" instead of a wild read.

const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;

// MILESEVENT_ENQUEUE_* flags (mss.h).
const ENQUEUE_BUFFER_PTR: i32 = 0x1;
const ENQUEUE_FREE_EVENT: i32 = 0x2;

// MILESEVENTSTATE (mss.h _MILESEVENTSTATE) — returned by MilesGetEventSystemState.
pub const MILESEVENTSTATE = extern struct {
    CommandBufferSize: i32,
    HeapSize: i32,
    HeapRemaining: i32,
    LoadedSoundCount: i32,
    PlayingSoundCount: i32,
    LoadedBankCount: i32,
    PersistCount: i32,
    SoundBankManagementMemory: i32,
    SoundDataMemory: i32,
};

// MILESEVENTSOUNDINFO (mss.h) — one active sound instance, filled by
// MilesEnumerateSoundInstances.
pub const MILESEVENTSOUNDINFO = extern struct {
    QueuedID: u64 = 0,
    InstanceID: u64 = 0,
    EventID: u64 = 0,
    Sample: ?*anyopaque = null,
    Stream: ?*anyopaque = null,
    UserBuffer: ?*anyopaque = null,
    UserBufferLen: i32 = 0,
    Status: i32 = 0,
    Flags: u32 = 0,
    UsedDelay: i32 = 0,
    UsedVolume: f32 = 0,
    UsedPitch: f32 = 0,
    UsedSound: ?[*:0]const u8 = null,
    HasCompletionEvent: i32 = 0,
};

// MILESEVENTSOUNDSTATUS bitmask (mss.h).
const STATUS_PENDING: i32 = 0x1;
const STATUS_PLAYING: i32 = 0x2;
const STATUS_COMPLETE: i32 = 0x4;

// One tracked sound instance. The miniaudio mixer is not wired to the event VM
// yet, so instances are tracked and progressed by the sound's bank duration
// rather than by actual playback — enough for game logic that gates on whether a
// queued sound is still playing.
const SoundInstance = struct {
    queued_id: u64,
    instance_id: u64,
    status: i32,
    start_ms: u64,
    duration_ms: u32,
    sound_name: [:0]u8, // owned
    labels: [:0]u8, // owned (comma/space-separated)
    user_buffer: ?*anyopaque,
    user_buffer_len: i32,
};

// Case-insensitive glob with '*' (any run) and '?' (one char).
fn globMatch(pat: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star: ?usize = null;
    var star_ti: usize = 0;
    while (ti < text.len) {
        if (pi < pat.len and pat[pi] == '*') {
            star = pi;
            star_ti = ti;
            pi += 1;
        } else if (pi < pat.len and (pat[pi] == '?' or std.ascii.toLower(pat[pi]) == std.ascii.toLower(text[ti]))) {
            pi += 1;
            ti += 1;
        } else if (star) |s| {
            pi = s + 1;
            star_ti += 1;
            ti = star_ti;
        } else return false;
    }
    while (pi < pat.len and pat[pi] == '*') pi += 1;
    return pi == pat.len;
}

// An instance matches the label query if the query is empty (match all) or any
// comma/space-separated query term globs onto any of the instance's labels.
// (The SDK uses a richer comma-list wildcard grammar in mileseventsupport.cpp;
// this token-glob approximation covers the common stop/enumerate-by-label case
// and is strictly more correct than ignoring labels entirely.)
fn labelMatch(labels: []const u8, query: ?[*:0]const u8) bool {
    const q = if (query) |p| std.mem.span(p) else "";
    if (q.len == 0) return true;
    if (labels.len == 0) return false;
    var qit = std.mem.tokenizeAny(u8, q, ", ");
    while (qit.next()) |qterm| {
        var lit = std.mem.tokenizeAny(u8, labels, ", ");
        while (lit.next()) |lbl| {
            if (globMatch(qterm, lbl)) return true;
        }
    }
    return false;
}

var g_instances: std.ArrayListUnmanaged(*SoundInstance) = .empty;
var g_next_id: u64 = 1;

// Sounds cached into memory by cache_sounds event steps (deduped); reported as
// MILESEVENTSTATE.LoadedSoundCount and removed by purge_sounds steps.
var g_cached: std.ArrayListUnmanaged([:0]u8) = .empty;

fn cacheIndexOf(name: []const u8) ?usize {
    for (g_cached.items, 0..) |n, i| {
        if (std.mem.eql(u8, n, name)) return i;
    }
    return null;
}
fn cacheAdd(name: []const u8) void {
    if (name.len == 0 or cacheIndexOf(name) != null) return;
    const dup = openmiles.global_allocator.dupeZ(u8, name) catch return;
    g_cached.append(openmiles.global_allocator, dup) catch openmiles.global_allocator.free(dup);
}
fn cacheRemove(name: []const u8) void {
    if (cacheIndexOf(name)) |i| {
        openmiles.global_allocator.free(g_cached.swapRemove(i));
    }
}
fn cacheClear() void {
    for (g_cached.items) |n| openmiles.global_allocator.free(n);
    g_cached.clearRetainingCapacity();
}

// Persisted presets (persist event steps); enumerated by MilesEnumeratePresetPersists
// and counted in MILESEVENTSTATE.PersistCount. Keyed (deduped) by persist name.
var g_persists: std.ArrayListUnmanaged([:0]u8) = .empty;

fn persistAdd(name: []const u8) void {
    if (name.len == 0) return;
    for (g_persists.items) |n| {
        if (std.mem.eql(u8, n, name)) return; // dedup by name
    }
    const dup = openmiles.global_allocator.dupeZ(u8, name) catch return;
    g_persists.append(openmiles.global_allocator, dup) catch openmiles.global_allocator.free(dup);
}
fn persistClear() void {
    for (g_persists.items) |n| openmiles.global_allocator.free(n);
    g_persists.clearRetainingCapacity();
}

// Per-label concurrent-sound caps (MilesSetSoundLabelLimits / set_limits steps).
// Format: "label count:label2 count2" (mss.h). A new sound must fit under the cap
// of every label it carries; the oldest matching instance is evicted to make room.
const Limit = struct { label: [:0]u8, count: u32 };
var g_limits: std.ArrayListUnmanaged(Limit) = .empty;

fn limitsClear() void {
    for (g_limits.items) |l| openmiles.global_allocator.free(l.label);
    g_limits.clearRetainingCapacity();
}
fn setLimits(limits_str: []const u8) void {
    limitsClear();
    var it = std.mem.tokenizeScalar(u8, limits_str, ':');
    while (it.next()) |entry| {
        var pit = std.mem.tokenizeAny(u8, entry, " \t");
        const label = pit.next() orelse continue;
        const count_s = pit.next() orelse continue;
        const count = std.fmt.parseInt(u32, count_s, 10) catch continue;
        const dup = openmiles.global_allocator.dupeZ(u8, label) catch continue;
        g_limits.append(openmiles.global_allocator, .{ .label = dup, .count = count }) catch openmiles.global_allocator.free(dup);
    }
}
fn limitFor(label: []const u8) ?u32 {
    for (g_limits.items) |l| {
        if (std.ascii.eqlIgnoreCase(l.label, label)) return l.count;
    }
    return null;
}
fn instanceHasLabel(inst: *const SoundInstance, label: []const u8) bool {
    var lit = std.mem.tokenizeAny(u8, inst.labels, ", ");
    while (lit.next()) |lbl| {
        if (std.ascii.eqlIgnoreCase(lbl, label)) return true;
    }
    return false;
}
fn countWithLabel(label: []const u8) u32 {
    var n: u32 = 0;
    for (g_instances.items) |inst| {
        if (instanceHasLabel(inst, label)) n += 1;
    }
    return n;
}
// Evict the oldest (lowest instance_id) instance carrying `label`; returns false
// if none found.
fn evictOldestWithLabel(label: []const u8) bool {
    var oldest: ?usize = null;
    for (g_instances.items, 0..) |inst, i| {
        if (!instanceHasLabel(inst, label)) continue;
        if (oldest == null or inst.instance_id < g_instances.items[oldest.?].instance_id) oldest = i;
    }
    if (oldest) |i| {
        destroyInstance(g_instances.swapRemove(i));
        return true;
    }
    return false;
}
// Make room under each limited label of a new sound before it is added.
fn enforceLimits(labels_in: []const u8) void {
    var lit = std.mem.tokenizeAny(u8, labels_in, ", ");
    while (lit.next()) |lbl| {
        const lim = limitFor(lbl) orelse continue;
        while (countWithLabel(lbl) >= lim) {
            if (!evictOldestWithLabel(lbl)) break;
        }
    }
}
// Apply a cache/purge step's namelist (built by the decoder) to the cache set.
fn applyCacheStep(load: anytype, add: bool) void {
    const list = load.namelist orelse return;
    const n: usize = @intCast(@max(load.namecount, 0));
    var k: usize = 0;
    while (k < n) : (k += 1) {
        const p = list[k] orelse continue;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
        if (add) cacheAdd(name) else cacheRemove(name);
    }
}

fn nextId() u64 {
    const id = g_next_id;
    g_next_id += 1;
    return id;
}

// Progress PLAYING instances to COMPLETE once their bank duration has elapsed.
fn updateInstances() void {
    const now = openmiles.getMsCount64();
    for (g_instances.items) |inst| {
        if (inst.status == STATUS_PLAYING and inst.duration_ms != 0) {
            if (now -% inst.start_ms >= inst.duration_ms) inst.status = STATUS_COMPLETE;
        }
    }
}

fn destroyInstance(inst: *SoundInstance) void {
    openmiles.global_allocator.free(inst.sound_name);
    openmiles.global_allocator.free(inst.labels);
    openmiles.global_allocator.destroy(inst);
}

// Create a tracked instance for a start-sound step. soundname is taken up to the
// first ':'; its duration is resolved from the loaded-bank container.
fn createInstance(queued_id: u64, soundname_full: []const u8, labels_in: []const u8, user_buffer: ?*anyopaque, ubl: i32) void {
    enforceLimits(labels_in); // evict to make room under each labelled cap
    const cut = std.mem.indexOfScalar(u8, soundname_full, ':') orelse soundname_full.len;
    const sound = soundname_full[0..cut];
    const dur: u32 = openmiles.soundbank.containerSoundDurationMs(sound) orelse 0;
    const name = openmiles.global_allocator.dupeZ(u8, sound) catch return;
    const labels = openmiles.global_allocator.dupeZ(u8, labels_in) catch {
        openmiles.global_allocator.free(name);
        return;
    };
    const inst = openmiles.global_allocator.create(SoundInstance) catch {
        openmiles.global_allocator.free(name);
        openmiles.global_allocator.free(labels);
        return;
    };
    inst.* = .{
        .queued_id = queued_id,
        .instance_id = nextId(),
        .status = STATUS_PENDING,
        .start_ms = openmiles.getMsCount64(),
        .duration_ms = dur,
        .sound_name = name,
        .labels = labels,
        .user_buffer = user_buffer,
        .user_buffer_len = ubl,
    };
    g_instances.append(openmiles.global_allocator, inst) catch {
        destroyInstance(inst);
    };
}

// Parse an event's bytecode and create an instance per start-sound step.
fn enqueueParse(event: ?[*]const u8, user_buffer: ?*anyopaque, ubl: i32, flags: i32) u64 {
    if (event == null) return 0;
    const qid = nextId();
    if (event) |ev| {
        var step: openmiles.event.EVENT_STEP_INFO = undefined;
        var scratch: [512]u8 align(8) = undefined;
        var cur: ?[*:0]const u8 = @ptrCast(ev);
        var guard: u32 = 0;
        while (cur != null and guard < 256) : (guard += 1) {
            const next = openmiles.event.nextStep(cur.?, &step, &scratch);
            if (next == null) break;
            if (step.type == @intFromEnum(openmiles.event.StepType.start_sound)) {
                const sn = step.u.start.soundname;
                const lb = step.u.start.labels;
                const lbl: []const u8 = if (lb.str) |lp| lp[0..@intCast(@max(lb.len, 0))] else "";
                if (sn.str) |sp| createInstance(qid, sp[0..@intCast(@max(sn.len, 0))], lbl, user_buffer, ubl);
            } else if (step.type == @intFromEnum(openmiles.event.StepType.cache_sounds)) {
                applyCacheStep(step.u.load, true);
            } else if (step.type == @intFromEnum(openmiles.event.StepType.purge_sounds)) {
                applyCacheStep(step.u.load, false);
            } else if (step.type == @intFromEnum(openmiles.event.StepType.persist)) {
                const pn = step.u.persist.name;
                if (pn.str) |sp| persistAdd(sp[0..@intCast(@max(pn.len, 0))]);
            }
            cur = next;
        }
        if (flags & ENQUEUE_FREE_EVENT != 0) std.c.free(@constCast(@ptrCast(ev)));
    }
    return qid;
}

const Var = struct {
    next: ?*Var = null,
    name: []u8,
    is_float: bool,
    i: i32 = 0,
    f: f32 = 0,
};

const EventSystem = struct {
    next: ?*EventSystem = null,
    vars: ?*Var = null,
    driver: ?*anyopaque = null,
    command_buffer_size: i32 = 0,
};

var g_root: ?*EventSystem = null;
var g_user_rand: ?*anyopaque = null;
var g_error_cb: ?*anyopaque = null;
var g_async_running: bool = false;

// Resolve an event-system context: 0 means the default (root) system; a non-zero
// value is trusted only if it identifies one of our live systems.
fn resolveSystem(ctx: usize) ?*EventSystem {
    if (ctx == 0) return g_root;
    var s = g_root;
    while (s) |sys| : (s = sys.next) {
        if (@intFromPtr(sys) == ctx) return sys;
    }
    return null;
}

fn setVar(sys: *EventSystem, name: [*:0]const u8, is_float: bool, ival: i32, fval: f32) void {
    const key = std.mem.span(name);
    var v = sys.vars;
    while (v) |vd| : (v = vd.next) {
        if (std.ascii.eqlIgnoreCase(vd.name, key)) {
            vd.is_float = is_float;
            vd.i = ival;
            vd.f = fval;
            return;
        }
    }
    const dup = openmiles.global_allocator.dupe(u8, key) catch return;
    const nv = openmiles.global_allocator.create(Var) catch {
        openmiles.global_allocator.free(dup);
        return;
    };
    nv.* = .{ .next = sys.vars, .name = dup, .is_float = is_float, .i = ival, .f = fval };
    sys.vars = nv;
}

fn getVar(ctx: usize, name: [*:0]const u8, is_float: bool, out: *anyopaque) i32 {
    const sys = resolveSystem(ctx) orelse return 0;
    const key = std.mem.span(name);
    var v = sys.vars;
    while (v) |vd| : (v = vd.next) {
        if (std.ascii.eqlIgnoreCase(vd.name, key)) {
            if (vd.is_float != is_float) return 0;
            if (is_float) {
                const o: *f32 = @ptrCast(@alignCast(out));
                o.* = vd.f;
            } else {
                const o: *i32 = @ptrCast(@alignCast(out));
                o.* = vd.i;
            }
            return 1;
        }
    }
    return 0;
}

fn freeSystem(sys: *EventSystem) void {
    var v = sys.vars;
    while (v) |vd| {
        const nxt = vd.next;
        openmiles.global_allocator.free(vd.name);
        openmiles.global_allocator.destroy(vd);
        v = nxt;
    }
    openmiles.global_allocator.destroy(sys);
}

// --- lifecycle ---------------------------------------------------------------

pub fn MilesStartupEventSystem(driver: ?*anyopaque, command_buf_len: i32, memory_buf: ?[*]u8, memory_len: i32) callconv(.winapi) ?*anyopaque {
    _ = memory_buf;
    _ = memory_len;
    if (g_root) |r| return @ptrCast(r);
    const sys = openmiles.global_allocator.create(EventSystem) catch return null;
    sys.* = .{ .driver = driver, .command_buffer_size = command_buf_len };
    g_root = sys;
    log("MilesStartupEventSystem(driver={*}, cmdbuf={d})\n", .{ driver, command_buf_len });
    return @ptrCast(sys);
}

pub fn MilesAddEventSystem(driver: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    const sys = openmiles.global_allocator.create(EventSystem) catch return null;
    sys.* = .{ .driver = driver };
    // append to the tail of the list (root must stay at index 0)
    if (g_root) |r| {
        var tail = r;
        while (tail.next) |n| tail = n;
        tail.next = sys;
    } else {
        g_root = sys;
    }
    return @ptrCast(sys);
}

pub fn MilesShutdownEventSystem() callconv(.winapi) void {
    for (g_instances.items) |inst| destroyInstance(inst);
    g_instances.clearRetainingCapacity();
    cacheClear();
    persistClear();
    limitsClear();
    var s = g_root;
    while (s) |sys| {
        const nxt = sys.next;
        freeSystem(sys);
        s = nxt;
    }
    g_root = null;
}

pub fn MilesGetEventSystemState(system: ?*anyopaque, state: ?*MILESEVENTSTATE) callconv(.winapi) void {
    const o = state orelse return;
    o.* = std.mem.zeroes(MILESEVENTSTATE);
    o.LoadedBankCount = @intCast(openmiles.soundbank.loadedCount());
    o.LoadedSoundCount = @intCast(g_cached.items.len);
    o.PersistCount = @intCast(g_persists.items.len);
    updateInstances();
    for (g_instances.items) |inst| {
        if (inst.status == STATUS_PLAYING) o.PlayingSoundCount += 1;
    }
    if (resolveSystem(@intFromPtr(system))) |sys| {
        o.CommandBufferSize = sys.command_buffer_size;
    }
}

// --- variables ---------------------------------------------------------------

pub fn MilesSetVarI(system: usize, name: [*:0]const u8, value: i32) callconv(.winapi) void {
    const sys = resolveSystem(system) orelse return;
    setVar(sys, name, false, value, 0);
}
pub fn MilesSetVarF(system: usize, name: [*:0]const u8, value: f32) callconv(.winapi) void {
    const sys = resolveSystem(system) orelse return;
    setVar(sys, name, true, 0, value);
}
pub fn MilesGetVarI(context: usize, name: [*:0]const u8, out_value: ?*i32) callconv(.winapi) i32 {
    return getVar(context, name, false, out_value orelse return 0);
}
pub fn MilesGetVarF(context: usize, name: [*:0]const u8, out_value: ?*f32) callconv(.winapi) i32 {
    return getVar(context, name, true, out_value orelse return 0);
}

// --- event queue + sound instances -------------------------------------------

pub fn MilesEnqueueEvent(event: ?[*]const u8, user_buffer: ?*anyopaque, user_buffer_len: i32, flags: i32, event_filter: u64) callconv(.winapi) u64 {
    _ = event_filter;
    return enqueueParse(event, user_buffer, user_buffer_len, flags);
}
pub fn MilesEnqueueEventContext(context: ?*anyopaque, event: ?[*]const u8, user_buffer: ?*anyopaque, user_buffer_len: i32, flags: i32, event_filter: u64) callconv(.winapi) u64 {
    _ = context;
    _ = event_filter;
    return enqueueParse(event, user_buffer, user_buffer_len, flags);
}
pub fn MilesEnqueueEventByName(name: ?[*:0]const u8) callconv(.winapi) u64 {
    const nm = std.mem.span(name orelse return 0);
    const ev = openmiles.soundbank.containerFindEvent(nm) orelse return 0;
    return enqueueParse(ev, null, 0, 0);
}
// Processing moves new (pending) instances to playing and starts their clock.
pub fn MilesBeginEventQueueProcessing() callconv(.winapi) i32 {
    const now = openmiles.getMsCount64();
    for (g_instances.items) |inst| {
        if (inst.status == STATUS_PENDING) {
            inst.status = STATUS_PLAYING;
            inst.start_ms = now;
        }
    }
    return 0;
}
// Completion reaps finished instances.
pub fn MilesCompleteEventQueueProcessing() callconv(.winapi) i32 {
    updateInstances();
    var i: usize = 0;
    while (i < g_instances.items.len) {
        if (g_instances.items[i].status == STATUS_COMPLETE) {
            destroyInstance(g_instances.swapRemove(i));
        } else i += 1;
    }
    return 0;
}
pub fn MilesClearEventQueue() callconv(.winapi) void {
    for (g_instances.items) |inst| destroyInstance(inst);
    g_instances.clearRetainingCapacity();
}

pub fn MilesStartSoundInstance(bank: ?*anyopaque, sound_name: ?[*:0]const u8, loop_count: u32, stream: i32, labels: ?[*:0]const u8, user_buffer: ?*anyopaque, user_buffer_len: i32, user_buffer_flags: i32) callconv(.winapi) u64 {
    _ = loop_count;
    _ = stream;
    _ = user_buffer_flags;
    _ = bank;
    const nm = sound_name orelse return 0;
    const lbl: []const u8 = if (labels) |p| std.mem.span(p) else "";
    const qid = nextId();
    createInstance(qid, std.mem.span(nm), lbl, user_buffer, user_buffer_len);
    return qid;
}
// Stop/Pause/Resume operate over instances matching both the status filter
// (filter 0 = all) and the label query (null/empty = all). Returns the count.
// Without a wired mixer, pause/resume have no audible effect but report the
// matching count for API faithfulness.
fn matchFilter(inst: *const SoundInstance, labels: ?[*:0]const u8, filter: u64) bool {
    const status_ok = filter == 0 or (@as(u64, @intCast(inst.status)) & filter) != 0;
    return status_ok and labelMatch(inst.labels, labels);
}
pub fn MilesStopSoundInstances(labels: ?[*:0]const u8, filter: u64) callconv(.winapi) u64 {
    var n: u64 = 0;
    var i: usize = 0;
    while (i < g_instances.items.len) {
        if (matchFilter(g_instances.items[i], labels, filter)) {
            destroyInstance(g_instances.swapRemove(i));
            n += 1;
        } else i += 1;
    }
    return n;
}
pub fn MilesPauseSoundInstances(labels: ?[*:0]const u8, filter: u64) callconv(.winapi) u64 {
    var n: u64 = 0;
    for (g_instances.items) |inst| {
        if (matchFilter(inst, labels, filter)) n += 1;
    }
    return n;
}
pub fn MilesResumeSoundInstances(labels: ?[*:0]const u8, filter: u64) callconv(.winapi) u64 {
    return MilesPauseSoundInstances(labels, filter);
}
pub fn MilesEnumerateSoundInstances(system: ?*anyopaque, io_next: ?*?*anyopaque, status: i32, labels: ?[*:0]const u8, search_for_id: u64, out_info: ?*anyopaque) callconv(.winapi) i32 {
    _ = system;
    _ = search_for_id;
    const np = io_next orelse return 0;
    updateInstances();
    const filter: u64 = if (status == 0) 0xffffffff else @intCast(@as(u32, @bitCast(status)));
    // MSS_FIRST sentinel ((HMSSENUM)-1) starts a fresh walk at index 0.
    const first = @intFromPtr(np.*) == std.math.maxInt(usize);
    var idx: usize = if (first) 0 else @intFromPtr(np.*);
    while (idx < g_instances.items.len) : (idx += 1) {
        const inst = g_instances.items[idx];
        if ((@as(u64, @intCast(inst.status)) & filter) == 0) continue;
        if (!labelMatch(inst.labels, labels)) continue;
        if (out_info) |oi| {
            const o: *MILESEVENTSOUNDINFO = @ptrCast(@alignCast(oi));
            o.* = .{
                .QueuedID = inst.queued_id,
                .InstanceID = inst.instance_id,
                .EventID = inst.queued_id,
                .UserBuffer = inst.user_buffer,
                .UserBufferLen = inst.user_buffer_len,
                .Status = inst.status,
                .UsedSound = inst.sound_name.ptr,
            };
        }
        np.* = @ptrFromInt(idx + 1);
        return 1;
    }
    np.* = @ptrFromInt(idx);
    return 0;
}
pub fn MilesEnumeratePresetPersists(system: ?*anyopaque, io_next: ?*?*anyopaque, out_name: ?*?[*:0]const u8) callconv(.winapi) i32 {
    _ = system;
    const np = io_next orelse return 0;
    const first = @intFromPtr(np.*) == std.math.maxInt(usize) or @intFromPtr(np.*) == 0;
    const idx: usize = if (first) 0 else @intFromPtr(np.*);
    if (idx >= g_persists.items.len) {
        np.* = @ptrFromInt(idx);
        if (out_name) |o| o.* = null;
        return 0;
    }
    if (out_name) |o| o.* = g_persists.items[idx].ptr;
    np.* = @ptrFromInt(idx + 1);
    return 1;
}
pub fn MilesSetSoundStartOffset(instance: usize, offset: i32, is_ms: i32) callconv(.winapi) void {
    _ = instance;
    _ = offset;
    _ = is_ms;
}
pub fn MilesSetSoundLabelLimits(system: ?*anyopaque, sound_limits: ?[*:0]const u8) callconv(.winapi) i32 {
    _ = system;
    setLimits(if (sound_limits) |p| std.mem.span(p) else "");
    return 1;
}

// --- sound banks / events (loader not yet ported) ----------------------------

pub fn MilesAddSoundBank(filename: ?[*:0]const u8, name: ?[*:0]const u8) callconv(.winapi) ?*anyopaque {
    _ = name;
    const fname = std.mem.span(filename orelse return null);
    const image = openmiles.readWholeFile(fname) catch return null;
    defer openmiles.global_allocator.free(image);
    const bank = openmiles.soundbank.loadFromMemory(openmiles.global_allocator, fname, image) catch {
        openmiles.setLastError("Failed to add sound bank");
        return null;
    };
    return @ptrCast(bank);
}
pub fn MilesReleaseSoundBank(bank: ?*anyopaque) callconv(.winapi) i32 {
    const b: *openmiles.Bank = @ptrCast(@alignCast(bank orelse return 0));
    b.deinit();
    return 1;
}
pub fn MilesFindEvent(bank: ?*anyopaque, event_name: ?[*:0]const u8) callconv(.winapi) ?[*]const u8 {
    const b: *openmiles.Bank = @ptrCast(@alignCast(bank orelse return null));
    const name = std.mem.span(event_name orelse return null);
    return b.findEventContents(name);
}
// MilesGetEventLength(name): find the event across loaded banks, locate its first
// start_sound step, and return that sound's playback duration in ms
// (Container_GetEvent -> first start sound -> Container_GetSound.DurationMs).
pub fn MilesGetEventLength(event_name: ?[*:0]const u8) callconv(.winapi) i32 {
    const name = std.mem.span(event_name orelse return 0);
    const ev = openmiles.soundbank.containerFindEvent(name) orelse return 0;
    var step: openmiles.event.EVENT_STEP_INFO = undefined;
    var scratch: [512]u8 align(8) = undefined;
    var cur: ?[*:0]const u8 = @ptrCast(ev);
    var guard: u32 = 0;
    while (cur != null and guard < 256) : (guard += 1) {
        const next = openmiles.event.nextStep(cur.?, &step, &scratch);
        if (next == null) break;
        if (step.type == @intFromEnum(openmiles.event.StepType.start_sound)) {
            const sn = step.u.start.soundname;
            const sp = sn.str orelse return 0;
            const full = sp[0..@intCast(@max(sn.len, 0))];
            const cut = std.mem.indexOfScalar(u8, full, ':') orelse full.len;
            if (openmiles.soundbank.containerSoundDurationMs(full[0..cut])) |ms| return @intCast(ms);
            return 0;
        }
        cur = next;
    }
    return 0;
}
// Human-readable diagnostic dump (mss.h AIL_text_dump_event_system). Mirrors the
// SDK's header lines; the returned buffer is malloc'd for the caller to free.
pub fn MilesTextDumpEventSystem() callconv(.winapi) ?[*:0]u8 {
    var sys_count: i32 = 0;
    var s = g_root;
    while (s) |sys| : (s = sys.next) sys_count += 1;
    updateInstances();
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "Event System Count: {d}\nSystem #1\nSound Source Count: {d}\nSound Instance Count: {d}\nPersistent Preset Count: {d}\nLoaded Bank Count: {d}\n", .{
        sys_count,
        g_cached.items.len,
        g_instances.items.len,
        g_persists.items.len,
        openmiles.soundbank.loadedCount(),
    }) catch return null;
    const out: [*]u8 = @ptrCast(std.c.malloc(text.len + 1) orelse return null);
    @memcpy(out[0..text.len], text);
    out[text.len] = 0;
    return @ptrCast(out);
}

// --- callbacks / config (stored or no-op) ------------------------------------

pub fn MilesRegisterRand(rand: ?*anyopaque) callconv(.winapi) void {
    g_user_rand = rand;
}
pub fn MilesSetEventErrorCallback(callback: ?*anyopaque) callconv(.winapi) void {
    g_error_cb = callback;
}
pub fn MilesEventSetAuditionFunctions(functions: ?*const anyopaque) callconv(.c) void {
    _ = functions;
}
pub fn MilesGetBankFunctions() callconv(.winapi) ?*const anyopaque {
    return null;
}
pub fn MilesSetBankFunctions(functions: ?*const anyopaque) callconv(.winapi) void {
    _ = functions;
}
pub fn MilesUseTelemetry(context: ?*anyopaque) callconv(.winapi) void {
    _ = context;
}
pub fn MilesUseTmLite(context: ?*anyopaque) callconv(.winapi) void {
    _ = context;
}

// --- async file I/O (not yet ported) -----------------------------------------

pub fn MilesAsyncStartup() callconv(.winapi) i32 {
    g_async_running = true;
    return 1;
}
pub fn MilesAsyncShutdown() callconv(.winapi) i32 {
    g_async_running = false;
    return 1;
}
pub fn MilesAsyncFileRead(request: ?*anyopaque) callconv(.winapi) i32 {
    _ = request;
    return 0;
}
pub fn MilesAsyncFileCancel(request: ?*anyopaque) callconv(.winapi) i32 {
    _ = request;
    return 0;
}
pub fn MilesAsyncFileStatus(request: ?*anyopaque, ms: u32) callconv(.winapi) i32 {
    _ = request;
    _ = ms;
    return 0;
}
pub fn MilesAsyncSetPaused(is_paused: i32) callconv(.winapi) void {
    _ = is_paused;
}
pub fn MilesRequeueAsyncs() callconv(.winapi) void {}

// --- v8 ABI variants ---------------------------------------------------------
// v8 exported a smaller, single-global-system Miles API: several calls lacked the
// HEVENTSYSTEM context that v9 added, AddSoundBank lacked the name argument, the
// sound-instance ID was U32 (widened to U64 in v9), and StartupEventSystem
// carried an extra trailing slot. These variants match the v8 decorations and
// forward to the v9 implementations.
pub fn MilesStartupEventSystem_v8(driver: ?*anyopaque, command_buf_len: i32, memory_buf: ?[*]u8, memory_len: i32, extra: i32) callconv(.winapi) ?*anyopaque {
    _ = extra;
    return MilesStartupEventSystem(driver, command_buf_len, memory_buf, memory_len);
}
pub fn MilesAddSoundBank_v8(filename: ?[*:0]const u8) callconv(.winapi) ?*anyopaque {
    return MilesAddSoundBank(filename, null);
}
pub fn MilesGetEventSystemState_v8(state: ?*MILESEVENTSTATE) callconv(.winapi) void {
    MilesGetEventSystemState(null, state);
}
pub fn MilesSetSoundLabelLimits_v8(sound_limits: ?[*:0]const u8) callconv(.winapi) i32 {
    return MilesSetSoundLabelLimits(null, sound_limits);
}
pub fn MilesEnumeratePresetPersists_v8(io_next: ?*?*anyopaque, out_name: ?*?[*:0]const u8) callconv(.winapi) i32 {
    return MilesEnumeratePresetPersists(null, io_next, out_name);
}
pub fn MilesEnumerateSoundInstances_v8(system: ?*anyopaque, io_next: ?*?*anyopaque, status: i32, labels: ?[*:0]const u8, search_for_id: u32, out_info: ?*anyopaque) callconv(.winapi) i32 {
    return MilesEnumerateSoundInstances(system, io_next, status, labels, search_for_id, out_info);
}

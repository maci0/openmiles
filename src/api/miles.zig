//! Miles 9.x event-system C-ABI (`Miles*` exports). The 9.x SDK header `#define`s
//! the classic `AIL_*` event names onto these `Miles*` symbols, so 9.x games link
//! against `_MilesStartupEventSystem@16`, `_MilesSetVarI@12`, etc. rather than the
//! `AIL_*` names. The real mss32.dll (9.3f/9.3k) exports the `Miles*` set; this
//! module supplies them.
//!
//! Faithful behaviour is implemented for the parts that are self-contained: the
//! event-system lifecycle (a linked list of systems rooted at `g_root`) and the
//! per-system variable store (the `context == 0` "default system" path and the
//! explicit-system-pointer path from `MilesGetVarInternal`/`Var_SetInstance`).
//! The command queue, sound-bank loader, sound-instance manager and async file
//! I/O are large interlocking subsystems (MilesEventExec.cpp, ~3800 LOC); until
//! those are ported, their entry points return the same empty-state values the
//! real functions return when nothing is loaded (no instances, no banks, queue
//! empty), so games that probe them behave correctly rather than crashing.
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

// --- command queue (events are consumed/freed; no executor yet) --------------

fn consumeEvent(event: ?[*]const u8, flags: i32) u64 {
    if (event) |e| {
        if (flags & ENQUEUE_FREE_EVENT != 0) std.c.free(@constCast(@ptrCast(e)));
    }
    return 0;
}

pub fn MilesEnqueueEvent(event: ?[*]const u8, user_buffer: ?*anyopaque, user_buffer_len: i32, flags: i32, event_filter: u64) callconv(.winapi) u64 {
    _ = user_buffer;
    _ = user_buffer_len;
    _ = event_filter;
    return consumeEvent(event, flags);
}
pub fn MilesEnqueueEventContext(context: ?*anyopaque, event: ?[*]const u8, user_buffer: ?*anyopaque, user_buffer_len: i32, flags: i32, event_filter: u64) callconv(.winapi) u64 {
    _ = context;
    _ = user_buffer;
    _ = user_buffer_len;
    _ = event_filter;
    return consumeEvent(event, flags);
}
pub fn MilesEnqueueEventByName(name: ?[*:0]const u8) callconv(.winapi) u64 {
    _ = name;
    return 0;
}
pub fn MilesBeginEventQueueProcessing() callconv(.winapi) i32 {
    return 0;
}
pub fn MilesCompleteEventQueueProcessing() callconv(.winapi) i32 {
    return 0;
}
pub fn MilesClearEventQueue() callconv(.winapi) void {}

// --- sound instances (none active until the executor is ported) --------------

pub fn MilesStartSoundInstance(bank: ?*anyopaque, sound_name: ?[*:0]const u8, loop_count: u32, stream: i32, labels: ?[*:0]const u8, user_buffer: ?*anyopaque, user_buffer_len: i32, user_buffer_flags: i32) callconv(.winapi) u64 {
    _ = bank;
    _ = sound_name;
    _ = loop_count;
    _ = stream;
    _ = labels;
    _ = user_buffer;
    _ = user_buffer_len;
    _ = user_buffer_flags;
    return 0;
}
pub fn MilesStopSoundInstances(labels: ?[*:0]const u8, filter: u64) callconv(.winapi) u64 {
    _ = labels;
    _ = filter;
    return 0;
}
pub fn MilesPauseSoundInstances(labels: ?[*:0]const u8, filter: u64) callconv(.winapi) u64 {
    _ = labels;
    _ = filter;
    return 0;
}
pub fn MilesResumeSoundInstances(labels: ?[*:0]const u8, filter: u64) callconv(.winapi) u64 {
    _ = labels;
    _ = filter;
    return 0;
}
pub fn MilesEnumerateSoundInstances(system: ?*anyopaque, io_next: ?*?*anyopaque, status: i32, labels: ?[*:0]const u8, search_for_id: u64, out_info: ?*anyopaque) callconv(.winapi) i32 {
    _ = system;
    _ = status;
    _ = labels;
    _ = search_for_id;
    _ = out_info;
    if (io_next) |n| n.* = null;
    return 0;
}
pub fn MilesEnumeratePresetPersists(system: ?*anyopaque, io_next: ?*?*anyopaque, out_name: ?*?[*:0]const u8) callconv(.winapi) i32 {
    _ = system;
    if (io_next) |n| n.* = null;
    if (out_name) |o| o.* = null;
    return 0;
}
pub fn MilesSetSoundStartOffset(instance: usize, offset: i32, is_ms: i32) callconv(.winapi) void {
    _ = instance;
    _ = offset;
    _ = is_ms;
}
pub fn MilesSetSoundLabelLimits(system: ?*anyopaque, sound_limits: ?[*:0]const u8) callconv(.winapi) i32 {
    _ = system;
    _ = sound_limits;
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
pub fn MilesTextDumpEventSystem() callconv(.winapi) ?[*:0]u8 {
    return null;
}

// --- callbacks / config (stored or no-op) ------------------------------------

pub fn MilesRegisterRand(rand: ?*anyopaque) callconv(.winapi) void {
    g_user_rand = rand;
}
pub fn MilesSetEventErrorCallback(callback: ?*anyopaque) callconv(.winapi) void {
    g_error_cb = callback;
}
pub fn MilesEventSetAuditionFunctions(functions: ?*const anyopaque) callconv(.winapi) void {
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

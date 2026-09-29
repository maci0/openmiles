//! Miles 9.x event-system C-ABI (`Miles*` exports). The 9.x SDK header `#define`s
//! the classic `AIL_*` event names onto these `Miles*` symbols, so 9.x games link
//! against `_MilesStartupEventSystem@16`, `_MilesSetVarI@12`, etc. rather than the
//! `AIL_*` names. The real mss32.dll (9.3f/9.3k) exports the `Miles*` set; this
//! module supplies them.
//!
//! This file is the ABI: the two `extern` records a caller sees and the
//! `callconv(.winapi)` functions that fill them. The state those functions act
//! on lives in `engine/miles_events.zig`, so nothing here is reachable except
//! through an export.
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
const ev = openmiles.miles_events;

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

// The completion sweep, plus the number of instances still playing once it
// has run. Callers that need the count take it from here rather than walking
// g_instances a second time: a per-frame MilesGetEventSystemState over a few
// hundred live instances otherwise sweeps the list and then reads it again,
// and reads the clock twice per poll. Callers that do not want the count
// discard it. `now` is passed in so a caller that is already walking the list
// can expire entries inline instead of running a separate pass.
fn updateInstancesAt(now: u64) u32 {
    var playing: u32 = 0;
    for (ev.g_instances.items) |inst| {
        const was_playing = inst.status == ev.STATUS_PLAYING;
        ev.expireInstanceAt(inst, now);
        if (was_playing and inst.status == ev.STATUS_PLAYING) playing += 1;
    }
    return playing;
}

// --- lifecycle ---------------------------------------------------------------

pub fn MilesStartupEventSystem(driver: ?*anyopaque, command_buf_len: i32, memory_buf: ?[*]u8, memory_len: i32) callconv(.winapi) ?*anyopaque {
    _ = memory_buf;
    _ = memory_len;
    // Check-then-publish: without the lock two threads both read an empty g_root
    // and each installs a system, and the loser's handle is unreachable from
    // the list shutdown walks, so it and its variables are never freed.
    ev.stateLock();
    defer ev.stateUnlock();
    if (ev.g_root) |r| return @ptrCast(r);
    const sys = openmiles.global_allocator.create(ev.EventSystem) catch {
        openmiles.setLastError("MilesStartupEventSystem: cannot allocate the event system");
        return null;
    };
    sys.* = .{ .driver = driver, .command_buffer_size = command_buf_len };
    ev.g_root = sys;
    log("MilesStartupEventSystem(driver={*}, cmdbuf={d})\n", .{ driver, command_buf_len });
    return @ptrCast(sys);
}

pub fn MilesAddEventSystem(driver: ?*anyopaque) callconv(.winapi) ?*anyopaque {
    ev.stateLock();
    defer ev.stateUnlock();
    const sys = openmiles.global_allocator.create(ev.EventSystem) catch {
        openmiles.setLastError("MilesAddEventSystem: cannot allocate the event system");
        return null;
    };
    sys.* = .{ .driver = driver };
    // append to the tail of the list (root must stay at index 0)
    if (ev.g_root) |r| {
        var tail = r;
        while (tail.next) |n| tail = n;
        tail.next = sys;
    } else {
        ev.g_root = sys;
    }
    return @ptrCast(sys);
}

pub fn MilesShutdownEventSystem() callconv(.winapi) void {
    // Held across the frees: a concurrent enqueue that re-added an instance
    // after the list was deinitialized would append into a slice whose backing
    // array the allocator had already taken back.
    ev.stateLock();
    defer ev.stateUnlock();
    for (ev.g_instances.items) |inst| ev.destroyInstance(inst);
    // The backing array is the only allocation the instance list owns, and
    // clearRetainingCapacity would hand it to nobody: every session that
    // started a sound leaked it at shutdown. deinit returns it to the allocator
    // installed here, which is the one that grew it in a caller that swaps
    // allocators around this call.
    ev.g_instances.deinit(openmiles.global_allocator);
    // deinit leaves items undefined, and every walk of the list (the
    // enumeration, the label eviction) reads it before the next append. The
    // empty slice is what those walks need, not the undefined pointer
    // `.empty` carries.
    ev.g_instances = .{ .items = &.{}, .capacity = 0 };
    ev.cacheClear();
    ev.persistClear();
    ev.limitsClear();
    var s = ev.g_root;
    while (s) |sys| {
        const nxt = sys.next;
        ev.freeSystem(sys);
        s = nxt;
    }
    ev.g_root = null;
}

pub fn MilesGetEventSystemState(system: ?*anyopaque, state: ?*MILESEVENTSTATE) callconv(.winapi) void {
    const o = state orelse return;
    ev.stateLock();
    defer ev.stateUnlock();
    o.* = std.mem.zeroes(MILESEVENTSTATE);
    o.LoadedBankCount = @intCast(openmiles.soundbank.loadedCount());
    o.LoadedSoundCount = @intCast(ev.g_cached.count());
    o.PersistCount = @intCast(ev.g_persists.items.len);
    o.PlayingSoundCount = @intCast(updateInstancesAt(openmiles.getMsCount64()));
    if (ev.resolveSystem(@intFromPtr(system))) |sys| {
        o.CommandBufferSize = sys.command_buffer_size;
    }
}

// --- variables ---------------------------------------------------------------

pub fn MilesSetVarI(system: usize, name: [*:0]const u8, value: i32) callconv(.winapi) void {
    ev.stateLock();
    defer ev.stateUnlock();
    const sys = ev.resolveSystem(system) orelse return;
    ev.setVar(sys, name, false, value, 0);
}
pub fn MilesSetVarF(system: usize, name: [*:0]const u8, value: f32) callconv(.winapi) void {
    ev.stateLock();
    defer ev.stateUnlock();
    const sys = ev.resolveSystem(system) orelse return;
    ev.setVar(sys, name, true, 0, value);
}
pub fn MilesGetVarI(context: usize, name: [*:0]const u8, out_value: ?*i32) callconv(.winapi) i32 {
    const ov = out_value orelse return 0;
    ev.stateLock();
    defer ev.stateUnlock();
    return ev.getVar(context, name, false, ov);
}
pub fn MilesGetVarF(context: usize, name: [*:0]const u8, out_value: ?*f32) callconv(.winapi) i32 {
    const ov = out_value orelse return 0;
    ev.stateLock();
    defer ev.stateUnlock();
    return ev.getVar(context, name, true, ov);
}

// --- event queue + sound instances -------------------------------------------

pub fn MilesEnqueueEvent(event: ?[*]const u8, user_buffer: ?*anyopaque, user_buffer_len: i32, flags: i32, event_filter: u64) callconv(.winapi) u64 {
    _ = event_filter;
    return ev.enqueueParse(event, user_buffer, user_buffer_len, flags);
}
pub fn MilesEnqueueEventContext(context: ?*anyopaque, event: ?[*]const u8, user_buffer: ?*anyopaque, user_buffer_len: i32, flags: i32, event_filter: u64) callconv(.winapi) u64 {
    _ = context;
    _ = event_filter;
    return ev.enqueueParse(event, user_buffer, user_buffer_len, flags);
}
pub fn MilesEnqueueEventByName(name: ?[*:0]const u8) callconv(.winapi) u64 {
    const nm = std.mem.span(name orelse return 0);
    // The event string belongs to the bank it was found in, and the walk below
    // reads it step by step, so the bank is held for the whole parse: a
    // concurrent MilesReleaseSoundBank would otherwise free it mid-walk.
    const found = openmiles.soundbank.containerFindEventOwned(nm) orelse return 0;
    defer found.bank.deinit();
    return ev.enqueueParse(found.data, null, 0, 0);
}
// Pending instances become playing and start their clock here.
pub fn MilesBeginEventQueueProcessing() callconv(.winapi) i32 {
    ev.stateLock();
    defer ev.stateUnlock();
    const now = openmiles.getMsCount64();
    for (ev.g_instances.items) |inst| {
        if (inst.status == ev.STATUS_PENDING) {
            inst.status = ev.STATUS_PLAYING;
            // An instance paused before its queue turn keeps the pause: stamping
            // start_ms here would restart its clock and let it expire while the
            // caller still holds it suspended.
            if (inst.paused) inst.paused_at_ms = now else inst.start_ms = now;
        }
    }
    return 0;
}
pub fn MilesCompleteEventQueueProcessing() callconv(.winapi) i32 {
    ev.stateLock();
    defer ev.stateUnlock();
    // One pass, one clock reading: expire inline as the walk visits each
    // instance and drop it in the same visit. The separate expiry sweep this
    // replaced walked the whole list first and the removal walk walked it again,
    // so a game that completes its event queue every frame paid two passes over
    // every live instance and two reads of the clock to reap them.
    const now = openmiles.getMsCount64();
    var i: usize = 0;
    while (i < ev.g_instances.items.len) {
        const inst = ev.g_instances.items[i];
        ev.expireInstanceAt(inst, now);
        if (inst.status == ev.STATUS_COMPLETE) {
            ev.destroyInstance(ev.g_instances.swapRemove(i));
        } else i += 1;
    }
    return 0;
}
pub fn MilesClearEventQueue() callconv(.winapi) void {
    ev.stateLock();
    defer ev.stateUnlock();
    for (ev.g_instances.items) |inst| ev.destroyInstance(inst);
    ev.g_instances.clearRetainingCapacity();
}

pub fn MilesStartSoundInstance(bank: ?*anyopaque, sound_name: ?[*:0]const u8, loop_count: u32, stream: i32, labels: ?[*:0]const u8, user_buffer: ?*anyopaque, user_buffer_len: i32, user_buffer_flags: i32) callconv(.winapi) u64 {
    _ = loop_count;
    _ = stream;
    _ = user_buffer_flags;
    _ = bank;
    const nm = sound_name orelse return 0;
    const lbl: []const u8 = if (labels) |p| std.mem.span(p) else "";
    // The id and the instance it names are one allocation of state: taking the
    // id under a separate lock would let another thread's enqueue publish a
    // higher id first and reorder the enumerate walk.
    ev.stateLock();
    defer ev.stateUnlock();
    const qid = ev.nextId();
    // The handle a caller holds from here is the instance ID, the one
    // AILSOUNDINSTANCE reports; the queue ID belongs to MilesEnqueueEvent and
    // names the batch the step came from.
    return ev.createInstance(qid, std.mem.span(nm), lbl, user_buffer, user_buffer_len);
}
pub fn MilesStopSoundInstances(labels: ?[*:0]const u8, filter: u64) callconv(.winapi) u64 {
    ev.stateLock();
    defer ev.stateUnlock();
    var n: u64 = 0;
    var i: usize = 0;
    while (i < ev.g_instances.items.len) {
        if (ev.matchFilter(ev.g_instances.items[i], labels, filter)) {
            ev.destroyInstance(ev.g_instances.swapRemove(i));
            n += 1;
        } else i += 1;
    }
    return n;
}
pub fn MilesPauseSoundInstances(labels: ?[*:0]const u8, filter: u64) callconv(.winapi) u64 {
    ev.stateLock();
    defer ev.stateUnlock();
    const now = openmiles.getMsCount64();
    var n: u64 = 0;
    for (ev.g_instances.items) |inst| {
        if (inst.paused) continue;
        if (!ev.matchFilter(inst, labels, filter)) continue;
        ev.pauseInstanceAt(inst, now);
        n += 1;
    }
    return n;
}
pub fn MilesResumeSoundInstances(labels: ?[*:0]const u8, filter: u64) callconv(.winapi) u64 {
    ev.stateLock();
    defer ev.stateUnlock();
    const now = openmiles.getMsCount64();
    var n: u64 = 0;
    for (ev.g_instances.items) |inst| {
        if (!inst.paused) continue;
        if (!ev.matchFilter(inst, labels, filter)) continue;
        ev.resumeInstanceAt(inst, now);
        n += 1;
    }
    return n;
}
pub fn MilesEnumerateSoundInstances(system: ?*anyopaque, io_next: ?*?*anyopaque, status: i32, labels: ?[*:0]const u8, search_for_id: u64, out_info: ?*anyopaque) callconv(.winapi) i32 {
    _ = system;
    _ = search_for_id;
    const np = io_next orelse return 0;
    ev.stateLock();
    defer ev.stateUnlock();
    // One clock reading serves both the expiry sweep and the candidate scan
    // below, which expires each instance inline as it visits it rather than
    // sweeping the list in a pass of its own. A game draining the walk pays
    // one pass per call instead of two, and a resumed walk sees the same
    // statuses the separate sweep would have left behind.
    const now = openmiles.getMsCount64();
    const filter: u64 = if (status == 0) 0xffffffff else @intCast(@as(u32, @bitCast(status)));
    // The cursor carries the instance_id of the last entry handed out, not its
    // position in g_instances, and the walk visits entries in id order rather
    // than array order.
    //
    // A positional cursor stops naming the same entry the moment the list is
    // compacted, and the list is compacted under the caller's feet: the
    // documented MSS walk is enumerate-then-act, so a game stops the instances
    // it just enumerated (MilesStopSoundInstances swap-removes) and calls back
    // in to continue.
    //
    // instance_id is monotonic and never reused (nextId), so it is a stable
    // identity, but it is NOT array order: a swap-remove moves the tail entry
    // into the freed slot, so a lower id can sit after a higher one. Selecting
    // the lowest matching id above the cursor is therefore what makes the walk
    // resumable: an id-ordered sequence is total and every entry appears
    // exactly once, however the array is shuffled beneath it, and a stop
    // between two calls cannot make the walk skip or repeat. An instance
    // enqueued mid-walk has a higher id and is not reported, matching an SDK
    // walk over a snapshot. The scan is per call over the handful of live
    // instances, which the label caps keep small.
    //
    // MSS_FIRST sentinel ((HMSSENUM)-1) starts a fresh walk, the same
    // convention MilesEnumeratePresetPersists uses. 0 is accepted as a fresh
    // walk too: no instance ever holds id 0 (nextId starts at 1), so it is
    // unambiguously the start rather than a resume point.
    const cursor_raw = @intFromPtr(np.*);
    const after_id: u64 = if (cursor_raw == std.math.maxInt(usize) or cursor_raw == 0) 0 else cursor_raw;
    var found: ?*ev.SoundInstance = null;
    for (ev.g_instances.items) |inst| {
        ev.expireInstanceAt(inst, now);
        if (inst.instance_id <= after_id) continue;
        if ((@as(u64, @intCast(inst.status)) & filter) == 0) continue;
        if (!ev.labelMatch(inst.labels, labels)) continue;
        if (found == null or inst.instance_id < found.?.instance_id) found = inst;
    }
    const inst = found orelse return 0;
    // The cursor is a pointer, so the id travels through the target's address
    // space rather than as a u64: @ptrFromInt on a 64-bit id does not compile
    // for a 32-bit target, which is what the shipped x86 DLL is. The ids are
    // sequential from 1, one per created instance, so they stay inside the
    // address space as long as a process can run, and the round trip through
    // usize the read above performs is exact. The bound is checked rather than
    // truncated, so an id that somehow outgrew it ends the walk instead of
    // wrapping the cursor back to an earlier id and repeating entries.
    if (inst.instance_id > std.math.maxInt(usize)) {
        log("MilesEnumerateSoundInstances: instance id {d} does not fit the cursor on this target; ending the walk\n", .{inst.instance_id});
        return 0;
    }
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
    np.* = @ptrFromInt(@as(usize, @intCast(inst.instance_id)));
    return 1;
}
pub fn MilesEnumeratePresetPersists(system: ?*anyopaque, io_next: ?*?*anyopaque, out_name: ?*?[*:0]const u8) callconv(.winapi) i32 {
    _ = system;
    const np = io_next orelse return 0;
    ev.stateLock();
    defer ev.stateUnlock();
    const first = @intFromPtr(np.*) == std.math.maxInt(usize) or @intFromPtr(np.*) == 0;
    const idx: usize = if (first) 0 else @intFromPtr(np.*);
    if (idx >= ev.g_persists.items.len) {
        np.* = @ptrFromInt(idx);
        if (out_name) |o| o.* = null;
        return 0;
    }
    if (out_name) |o| o.* = ev.g_persists.items[idx].ptr;
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
    ev.stateLock();
    defer ev.stateUnlock();
    // The return stays 1: the SDK reports success for a limits string it
    // accepted, and a partially applied one is still applied. What was dropped
    // is named in the log and through AIL_last_error, so the caller can see
    // that a cap it expected is not enforcing.
    const dropped = ev.setLimits(if (sound_limits) |p| std.mem.span(p) else "");
    if (dropped > 0) {
        openmiles.setLastErrorFmt("MilesSetSoundLabelLimits: {d} limit entries were malformed and are not enforced", .{dropped});
    }
    return 1;
}

// --- sound banks / events ----------------------------------------------------

pub fn MilesAddSoundBank(filename: ?[*:0]const u8, name: ?[*:0]const u8) callconv(.winapi) ?*anyopaque {
    const fname = std.mem.span(filename orelse return null);
    const image = openmiles.readWholeFile(fname) catch |err| {
        // Same signal as AIL_open_soundbank: a silent null here would leave the
        // game (and the log) with no reason for the failed bank load.
        log("MilesAddSoundBank: read '{s}' failed ({any})\n", .{ fname, err });
        openmiles.setLastError("Failed to read sound bank file");
        return null;
    };
    defer openmiles.global_allocator.free(image);
    const bank = openmiles.soundbank.loadFromMemory(openmiles.global_allocator, fname, image) catch |err| {
        // Same signal as AIL_open_soundbank: the parse error names which check
        // rejected the bank (NotABank / BadVersion / BadMetaSize / BadAssetTable).
        log("MilesAddSoundBank: parse '{s}' failed ({any})\n", .{ fname, err });
        openmiles.setLastError("Failed to add sound bank");
        return null;
    };
    // `name` is accepted and dropped: the bank keeps the name its file carries
    // (mss.h), so a caller that passes a different one neither renames the bank
    // nor loses the load.
    _ = name;
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
    // Held for the walk: the steps are read out of the bank's metadata, which
    // a concurrent release would free.
    const found = openmiles.soundbank.containerFindEventOwned(name) orelse return 0;
    defer found.bank.deinit();
    var walker: ev.StepWalker = undefined;
    walker.init(found.data);
    while (walker.next()) |st| {
        if (st.type != @intFromEnum(openmiles.event.StepType.start_sound)) continue;
        const sn = st.u.start.soundname;
        const sp = sn.str orelse return 0;
        const full = sp[0..@intCast(@max(sn.len, 0))];
        const cut = std.mem.indexOfScalar(u8, full, ':') orelse full.len;
        // Saturating: the duration is a raw u32 field from the soundbank file, so
        // a bank declaring 0x80000000 ms would panic the narrowing cast.
        if (openmiles.soundbank.containerSoundDurationMs(full[0..cut])) |ms| return openmiles.satI32(@floatFromInt(ms));
        return 0;
    }
    return 0;
}
// Human-readable diagnostic dump (mss.h AIL_text_dump_event_system). Mirrors the
// SDK's header lines; the returned buffer is malloc'd for the caller to free.
pub fn MilesTextDumpEventSystem() callconv(.winapi) ?[*:0]u8 {
    ev.stateLock();
    defer ev.stateUnlock();
    var sys_count: i32 = 0;
    var s = ev.g_root;
    while (s) |sys| : (s = sys.next) sys_count += 1;
    ev.updateInstances();
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "Event System Count: {d}\nSystem #1\nSound Source Count: {d}\nSound Instance Count: {d}\nPersistent Preset Count: {d}\nLoaded Bank Count: {d}\n", .{
        sys_count,
        ev.g_cached.count(),
        ev.g_instances.items.len,
        ev.g_persists.items.len,
        openmiles.soundbank.loadedCount(),
    }) catch {
        openmiles.setLastError("Cannot format the event system status");
        return null;
    };
    const out: [*]u8 = @ptrCast(std.c.malloc(text.len + 1) orelse {
        openmiles.setLastError("Cannot allocate the event system status");
        return null;
    });
    @memcpy(out[0..text.len], text);
    out[text.len] = 0;
    return @ptrCast(out);
}

// --- callbacks / config (no-op) ----------------------------------------------
//
// The event system runs on the engine's own mixer, which draws no randomness and
// routes no error reporting, so these have nothing to bind to. They accept the
// call and drop the pointer rather than storing a callback nothing ever invokes.

pub fn MilesRegisterRand(rand: ?*anyopaque) callconv(.winapi) void {
    _ = rand;
}
pub fn MilesSetEventErrorCallback(callback: ?*anyopaque) callconv(.winapi) void {
    _ = callback;
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
//
// Startup reports success so a game's bracket call is satisfied, but nothing
// reads the state: MilesAsyncFileRead below returns 0 (failed) for every
// request, so no file is ever served asynchronously.

pub fn MilesAsyncStartup() callconv(.winapi) i32 {
    return 1;
}
pub fn MilesAsyncShutdown() callconv(.winapi) i32 {
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
//
// MilesStartupEventSystem_v8 below is the exception: no export table entry
// routes to it, because a v8 build emits the @16 form, so it stays callable
// internally and from tests without becoming a PE export.
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

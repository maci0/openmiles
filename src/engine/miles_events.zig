//! The Miles* 9.x event system: the state the `Miles*` C ABI in
//! `api/miles.zig` is a front for, kept out of the ABI file so the ABI file
//! holds wrappers and this holds the behavior.
//!
//! What lives here: the event-system list and its per-system variable tables,
//! the tracked sound instances, and the cache / persist / per-label limit
//! registries the `cache_sounds`, `purge_sounds`, `persist` and `set_limits`
//! event steps maintain. `engine/event.zig` is the other half: it decodes an
//! event string into steps, and this module walks those steps and keeps the
//! state they mutate. The AIL_* ABI reaches the decoder directly; the Miles*
//! ABI reaches it through `enqueueParse` here.

const std = @import("std");
const root = @import("../root.zig");

// MILESEVENT_ENQUEUE_* flags (mss.h).
const ENQUEUE_FREE_EVENT: i32 = 0x2;

// MILESEVENTSOUNDSTATUS bitmask (mss.h).
pub const STATUS_PENDING: i32 = 0x1;
pub const STATUS_PLAYING: i32 = 0x2;
pub const STATUS_COMPLETE: i32 = 0x4;

// One tracked sound instance. The miniaudio mixer is not wired to the event VM
// yet, so instances are tracked and progressed by the sound's bank duration
// rather than by actual playback — enough for game logic that gates on whether a
// queued sound is still playing.
pub const SoundInstance = struct {
    queued_id: u64,
    instance_id: u64,
    status: i32,
    start_ms: u64,
    duration_ms: u32,
    sound_name: [:0]u8, // owned
    labels: [:0]u8, // owned (comma/space-separated)
    user_buffer: ?*anyopaque,
    user_buffer_len: i32,
    // A paused instance holds its place in the lifecycle (MSS has no PAUSED
    // status bit) but stops accruing elapsed time: pause stamps the reading and
    // resume moves start_ms forward by the gap, so the same rule the sweep uses
    // to expire a PLAYING instance cannot expire one that was not playing.
    paused: bool = false,
    paused_at_ms: u64 = 0,
    // Set while the instance is a selected eviction victim, so the compaction
    // pass tests membership by field instead of by scanning the victim list
    // once per instance.
    evict_mark: bool = false,
};

// Case-insensitive glob with '*' (any run) and '?' (one character).
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
            // '?' is one character, not one byte: the continuation bytes of a
            // multi-byte character go with their lead byte, or the wildcard would
            // match half a code point and then fail on the other half.
            if (pat[pi - 1] == '?') {
                while (ti < text.len and text[ti] & 0xC0 == 0x80) : (ti += 1) {}
            }
        } else if (star) |s| {
            pi = s + 1;
            // The retry starts at a character boundary, the same rule the '?'
            // branch follows. Advancing one byte at a time let it restart on a
            // continuation byte, where a pattern byte could match the tail of a
            // character the pattern never named: "*\xA9b" matched "a<e-acute>b"
            // by lining its lone 0xA9 up with the trailing byte of the e-acute,
            // so a label query in a legacy code page selected instances whose
            // labels it does not equal.
            star_ti += 1;
            while (star_ti < text.len and text[star_ti] & 0xC0 == 0x80) : (star_ti += 1) {}
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
pub fn labelMatch(labels: []const u8, query: ?[*:0]const u8) bool {
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

// The event-system state below (instances, id counter, cache, persists, label
// limits, the system list and its variable tables) is process-global, and every
// one of it is reachable from a Miles entry point, which a game may call from
// any thread: the SDK's own walk is enumerate-then-act from the main loop
// while a worker enqueues events, the same split root.zig's atomic "current
// driver" slots assume. None of the containers is safe under that split.
// An ArrayListUnmanaged append and a StringHashMap put each write a length and a
// capacity alongside the storage they point at, so two threads in one list
// corrupt the heap rather than merely losing an entry; nextId is a
// read-modify-write, so two instances take the same id and the resumable
// enumerate walk skips and repeats entries; the system list walk reads a
// half-linked list and hands back a freed system. One lock covers all of it.
//
// Lock order: this lock is outermost. The leaf lookups below (the bank container
// duration/event lookups) take soundbank's registry lock, and that file never
// calls back here, so the order is one-way and cannot cycle. It is the only
// lock this file takes, and a public entry point is never called while it is
// held.
var state_mutex: std.Io.Mutex = .init;

pub fn stateLock() void {
    state_mutex.lockUncancelable(root.io);
}
pub fn stateUnlock() void {
    state_mutex.unlock(root.io);
}

pub var g_instances: std.ArrayListUnmanaged(*SoundInstance) = .empty;
var g_next_id: u64 = 1;

// Sounds cached into memory by cache_sounds event steps (deduped); reported as
// MILESEVENTSTATE.LoadedSoundCount and removed by purge_sounds steps.
// Names are keyed case-insensitively, the way the bank container resolves them
// (soundbank's name index is lowercased), so cache_sounds("KICK") and
// purge_sounds("KICK") address the same entry.

// Every name-keyed registry in this file keys a hash map on the lowercased
// name and owns the key, so a name match is a hash lookup rather than a scan
// with a case-insensitive compare per entry. Same shape as the bank's name
// index (soundbank.zig), which resolves event and sound names the same way.
// The one exception is g_persists, which keeps an ordered array because
// MilesEnumeratePresetPersists walks it by position; a game's persisted
// preset list is short enough for the dedup scan to cost nothing.

// A case-lowercased probe key, in a stack buffer when the name fits (the
// common case, no allocation) and on the heap otherwise. Same shape as the
// bank's index probe. Filled in place: `key` points into the NameKey, so the
// NameKey has to outlive the probe, not be returned by value.
const NameKey = struct {
    buf: [128]u8 = undefined,
    key: []const u8 = "",
    heap: ?[]u8 = null,

    fn init(self: *NameKey, name: []const u8) void {
        self.* = .{};
        if (name.len < self.buf.len) {
            for (name, 0..) |c, i| self.buf[i] = std.ascii.toLower(c);
            self.key = self.buf[0..name.len];
            return;
        }
        // Too long to probe from the stack. A failed copy leaves the key empty,
        // so the name reads as absent: the same direction a failed insert takes.
        const dup = root.global_allocator.alloc(u8, name.len) catch return;
        for (name, 0..) |c, i| dup[i] = std.ascii.toLower(c);
        self.heap = dup;
        self.key = dup;
    }

    fn deinit(self: *NameKey) void {
        if (self.heap) |h| root.global_allocator.free(h);
    }
};

/// An owned lowercased copy of `name`, for a registry key.
fn lowerDupe(name: []const u8) ?[]u8 {
    const dup = root.global_allocator.alloc(u8, name.len) catch return null;
    for (name, 0..) |c, i| dup[i] = std.ascii.toLower(c);
    return dup;
}

pub var g_cached: std.StringHashMapUnmanaged(void) = .empty;

fn cacheAdd(name: []const u8) void {
    if (name.len == 0) return;
    var probe: NameKey = undefined;
    probe.init(name);
    defer probe.deinit();
    if (g_cached.contains(probe.key)) return;
    const key = lowerDupe(name) orelse return;
    g_cached.put(root.global_allocator, key, {}) catch root.global_allocator.free(key);
}
fn cacheRemove(name: []const u8) void {
    var probe: NameKey = undefined;
    probe.init(name);
    defer probe.deinit();
    if (g_cached.fetchRemove(probe.key)) |kv| {
        root.global_allocator.free(kv.key);
    }
}
pub fn cacheClear() void {
    var it = g_cached.keyIterator();
    while (it.next()) |k| root.global_allocator.free(k.*);
    g_cached.deinit(root.global_allocator);
    g_cached = .empty;
}

// Persisted presets (persist event steps); enumerated by MilesEnumeratePresetPersists
// and counted in MILESEVENTSTATE.PersistCount. Keyed (deduped) by persist name.
pub var g_persists: std.ArrayListUnmanaged([:0]u8) = .empty;

fn persistAdd(name: []const u8) void {
    if (name.len == 0) return;
    // Case-blind, like every other name registry in this file (see NameKey): a
    // preset persisted as "Menu" and again as "menu" is one preset, so
    // PersistCount counts it once and the enumerator yields it once. An
    // exact-byte compare stored both, so the count overstated what was
    // persisted and two entries named the same preset.
    for (g_persists.items) |n| {
        if (std.ascii.eqlIgnoreCase(n, name)) return;
    }
    const dup = root.global_allocator.dupeZ(u8, name) catch return;
    g_persists.append(root.global_allocator, dup) catch root.global_allocator.free(dup);
}
pub fn persistClear() void {
    for (g_persists.items) |n| root.global_allocator.free(n);
    g_persists.clearRetainingCapacity();
}

// Per-label concurrent-sound caps (MilesSetSoundLabelLimits / set_limits steps).
// Format: "label count:label2 count2" (mss.h). A new sound must fit under the cap
// of every label it carries; the oldest matching instance is evicted to make room.
// Keyed on the lowercased label (see NameKey); the count is the value, so the
// label is stored once, as the key the map owns.
var g_limits: std.StringHashMapUnmanaged(u32) = .empty;

pub fn limitsClear() void {
    var it = g_limits.keyIterator();
    while (it.next()) |k| root.global_allocator.free(k.*);
    g_limits.deinit(root.global_allocator);
    g_limits = .empty;
}
/// Install the per-label concurrent-sound caps from `"label count:label2 count2"`.
/// Returns the entries that were dropped, having named each in the log. The
/// caller reports a failure from this: a cap that did not install is not a cap,
/// and the process grows sound instances without limit, so a caller told
/// "applied" for a string it silently could not parse is worse than one told
/// nothing.
pub fn setLimits(limits_str: []const u8) u32 {
    limitsClear();
    var dropped: u32 = 0;
    var it = std.mem.tokenizeScalar(u8, limits_str, ':');
    while (it.next()) |entry| {
        var pit = std.mem.tokenizeAny(u8, entry, " \t");
        const label = pit.next() orelse {
            // An empty segment between two colons is not a malformed entry, it
            // is the string ending in a separator. Nothing is dropped, and
            // saying otherwise would report a well-formed string as broken.
            if (entry.len == 0) continue;
            root.log("MilesSetSoundLabelLimits: entry '{s}' names no label; the cap is not applied\n", .{entry});
            dropped += 1;
            continue;
        };
        const count_s = pit.next() orelse {
            root.log("MilesSetSoundLabelLimits: entry '{s}' names no count for label '{s}'; the cap is not applied\n", .{ entry, label });
            dropped += 1;
            continue;
        };
        const count = std.fmt.parseInt(u32, count_s, 10) catch {
            root.log("MilesSetSoundLabelLimits: count '{s}' for label '{s}' is not a number; the cap is not applied\n", .{ count_s, label });
            dropped += 1;
            continue;
        };
        // A label repeated in one string is one entry, the last count winning.
        // put() on a name the map already owns keeps the key it stored and drops
        // the one passed in, so the dupe went with it: every repeated label
        // leaked a copy of its name on each set_limits step.
        var probe: NameKey = undefined;
        probe.init(label);
        defer probe.deinit();
        if (g_limits.getPtr(probe.key)) |slot| {
            slot.* = count;
            continue;
        }
        const key = lowerDupe(probe.key) orelse {
            root.log("MilesSetSoundLabelLimits: cannot copy the name of label '{s}'; the cap is not applied\n", .{label});
            dropped += 1;
            continue;
        };
        g_limits.put(root.global_allocator, key, count) catch {
            root.global_allocator.free(key);
            root.log("MilesSetSoundLabelLimits: cannot store the cap for label '{s}'; the cap is not applied\n", .{label});
            dropped += 1;
        };
    }
    return dropped;
}
fn limitFor(label: []const u8) ?u32 {
    var probe: NameKey = undefined;
    probe.init(label);
    defer probe.deinit();
    return g_limits.get(probe.key);
}
fn instanceHasLabel(inst: *const SoundInstance, label: []const u8) bool {
    var lit = std.mem.tokenizeAny(u8, inst.labels, ", ");
    while (lit.next()) |lbl| {
        if (std.ascii.eqlIgnoreCase(lbl, label)) return true;
    }
    return false;
}
// Evict the oldest instances carrying `label` until a slot is free under `lim`
// (a cap of 0 evicts every one of them). The matches are gathered and ordered
// by instance_id once, rather than rescanning the whole list to recount and
// re-find the minimum after each eviction.
fn evictOldestWithLabel(label: []const u8, lim: u32) void {
    const cap: usize = lim;
    // Count the matches before gathering them. Every start-sound step runs this
    // for each of its labels, and the ordinary case is a list already under the
    // cap, which evicts nothing: growing and releasing a list of every match to
    // discover that cost one allocation and two passes over the instances per
    // label per step, for a decision the count alone settles.
    var matched: usize = 0;
    for (g_instances.items) |inst| {
        if (instanceHasLabel(inst, label)) matched += 1;
    }
    if (matched < cap) return;
    // Now the list is over the cap and the gather is the work: reserve against
    // the count just taken rather than the whole instance list, which is
    // larger whenever any instance carries a different label.
    var matches: std.ArrayListUnmanaged(*SoundInstance) = .empty;
    defer matches.deinit(root.global_allocator);
    matches.ensureTotalCapacity(root.global_allocator, matched) catch {};
    for (g_instances.items) |inst| {
        if (!instanceHasLabel(inst, label)) continue;
        // A scan that cannot finish leaves the cap unenforced and the new sound
        // pushes the instance count past it, so say the limit was not applied
        // rather than let the caller read a bounded count as a true one.
        matches.append(root.global_allocator, inst) catch {
            root.setLastErrorFmt("Cannot enforce the concurrent-sound limit for label '{s}'", .{label});
            return;
        };
    }
    std.sort.block(*SoundInstance, matches.items, {}, struct {
        fn lt(_: void, a: *SoundInstance, b: *SoundInstance) bool {
            return a.instance_id < b.instance_id;
        }
    }.lt);
    // One slot short of the cap is enough room for the sound being added; a cap
    // of 0 has no slot, so it evicts all matches.
    const victims = matches.items[0..@min(matches.items.len, matches.items.len - cap + 1)];
    // Compact the array in one pass, testing the mark rather than the victim's
    // identity. The victims are ordered by instance_id, not by position, so
    // membership by value was a scan of the victim list per instance, an O(N·V)
    // pass that a cap of 0 over N instances turned into O(N^2) pointer compares
    // on a single start-sound step. The write cursor never passes the read
    // cursor, so the in-place compaction is safe.
    for (victims) |victim| victim.evict_mark = true;
    var w: usize = 0;
    for (g_instances.items) |inst| {
        if (inst.evict_mark) {
            destroyInstance(inst);
            continue;
        }
        g_instances.items[w] = inst;
        w += 1;
    }
    g_instances.shrinkRetainingCapacity(w);
}
// Make room under each limited label of a new sound before it is added.
fn enforceLimits(labels_in: []const u8) void {
    var lit = std.mem.tokenizeAny(u8, labels_in, ", ");
    while (lit.next()) |lbl| {
        const lim = limitFor(lbl) orelse continue;
        evictOldestWithLabel(lbl, lim);
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

pub fn nextId() u64 {
    const id = g_next_id;
    g_next_id += 1;
    return id;
}

// Suspend one instance's clock at `now`. The status is left alone: an
// enumeration filtered on MILESEVENTSOUNDSTATUS_PLAYING still has to see it.
pub fn pauseInstanceAt(inst: *SoundInstance, now: u64) void {
    if (inst.paused) return;
    inst.paused = true;
    inst.paused_at_ms = now;
}

/// Resume one instance, crediting the paused span back to its start so the time
/// it spent suspended does not count against its duration.
pub fn resumeInstanceAt(inst: *SoundInstance, now: u64) void {
    if (!inst.paused) return;
    inst.paused = false;
    if (now > inst.paused_at_ms) inst.start_ms += now - inst.paused_at_ms;
}

// Progress one instance to COMPLETE once its bank duration has elapsed against
// a clock reading the caller already took. Factored out so a caller walking
// g_instances for another reason expires each instance in the visit it already
// makes, rather than sweeping the list in a pass of its own first.
pub fn expireInstanceAt(inst: *SoundInstance, now: u64) void {
    if (inst.status != STATUS_PLAYING) return;
    // Not wrapping arithmetic: installing a virtual clock rebases the ms
    // counter, so an instance started before the rebase reads as already
    // elapsed under `-%` and completes on the first poll.
    const elapsed: u64 = if (now > inst.start_ms) @intCast(now - inst.start_ms) else 0;
    if (elapsed >= inst.duration_ms) inst.status = STATUS_COMPLETE;
}

// Progress every PLAYING instance to COMPLETE. A zero duration (sound
// unresolvable in any loaded bank) completes as soon as processing starts:
// without this the instance would sit PLAYING forever and
// MilesCompleteEventQueueProcessing would never reap it, growing g_instances by
// one entry per enqueued event on games that loop event queues.
pub fn updateInstances() void {
    const now = root.getMsCount64();
    for (g_instances.items) |inst| expireInstanceAt(inst, now);
}

pub fn destroyInstance(inst: *SoundInstance) void {
    root.global_allocator.free(inst.sound_name);
    root.global_allocator.free(inst.labels);
    root.global_allocator.destroy(inst);
}

// Create a tracked instance for a start-sound step. soundname is taken up to the
// first ':'; its duration is resolved from the loaded-bank container.
pub fn createInstance(queued_id: u64, soundname_full: []const u8, labels_in: []const u8, user_buffer: ?*anyopaque, ubl: i32) u64 {
    enforceLimits(labels_in); // evict to make room under each labelled cap
    const cut = std.mem.indexOfScalar(u8, soundname_full, ':') orelse soundname_full.len;
    const sound = soundname_full[0..cut];
    const dur: u32 = root.soundbank.containerSoundDurationMs(sound) orelse 0;
    const name = root.global_allocator.dupeZ(u8, sound) catch return 0;
    const labels = root.global_allocator.dupeZ(u8, labels_in) catch {
        root.global_allocator.free(name);
        return 0;
    };
    const inst = root.global_allocator.create(SoundInstance) catch {
        root.global_allocator.free(name);
        root.global_allocator.free(labels);
        return 0;
    };
    inst.* = .{
        .queued_id = queued_id,
        .instance_id = nextId(),
        .status = STATUS_PENDING,
        .start_ms = root.getMsCount64(),
        .duration_ms = dur,
        .sound_name = name,
        .labels = labels,
        .user_buffer = user_buffer,
        .user_buffer_len = ubl,
    };
    g_instances.append(root.global_allocator, inst) catch {
        destroyInstance(inst);
        return 0;
    };
    return inst.instance_id;
}

// Shared walk over an event string's decoded steps: nextStep with a per-walk
// scratch buffer, bounded at 256 steps so a corrupt/cyclic string cannot spin.
// Steps whose decode fails end the walk (the partial step is not reported),
// matching both call sites.
pub const StepWalker = struct {
    step: root.event.EVENT_STEP_INFO = undefined,
    scratch: [512]u8 align(8) = undefined,
    cur: ?[*:0]const u8,
    guard: u32 = 0,

    // The walker is ~740 bytes (a step record plus a scratch buffer), and it is
    // built once per enqueued event, so it is initialized in place rather than
    // returned by value.
    pub fn init(self: *StepWalker, event: ?[*]const u8) void {
        self.* = .{ .cur = @ptrCast(event) };
    }

    pub fn next(self: *StepWalker) ?*const root.event.EVENT_STEP_INFO {
        const c = self.cur orelse return null;
        if (self.guard >= 256) return null;
        self.guard += 1;
        self.cur = root.event.nextStep(c, &self.step, &self.scratch) orelse return null;
        return &self.step;
    }
};

// Parse an event's bytecode and create an instance per start-sound step. The
// whole parse runs under state_mutex: it allocates ids, appends instances and
// edits the cache/presists/limits registries, and a game's worker thread
// enqueueing while its main thread drains the queue is the ordinary case.
pub fn enqueueParse(event: ?[*]const u8, user_buffer: ?*anyopaque, ubl: i32, flags: i32) u64 {
    if (event == null) return 0;
    stateLock();
    defer stateUnlock();
    var walker: StepWalker = undefined;
    walker.init(event);
    const qid = nextId();
    while (walker.next()) |st| {
        if (st.type == @intFromEnum(root.event.StepType.start_sound)) {
            const sn = st.u.start.soundname;
            const lb = st.u.start.labels;
            const lbl: []const u8 = if (lb.str) |lp| lp[0..@intCast(@max(lb.len, 0))] else "";
            if (sn.str) |sp| _ = createInstance(qid, sp[0..@intCast(@max(sn.len, 0))], lbl, user_buffer, ubl);
        } else if (st.type == @intFromEnum(root.event.StepType.cache_sounds)) {
            applyCacheStep(st.u.load, true);
        } else if (st.type == @intFromEnum(root.event.StepType.purge_sounds)) {
            applyCacheStep(st.u.load, false);
        } else if (st.type == @intFromEnum(root.event.StepType.persist)) {
            const pn = st.u.persist.name;
            if (pn.str) |sp| persistAdd(sp[0..@intCast(@max(pn.len, 0))]);
        } else if (st.type == @intFromEnum(root.event.StepType.set_limits)) {
            // Caps the event declares in its own text, not only the ones a game
            // installs out of band with MilesSetSoundLabelLimits. The walk is in
            // event order, so a limits step gates the start-sound steps after it.
            const ls = st.u.limits.limits;
            if (ls.str) |lp| {
                const dropped = setLimits(lp[0..@intCast(@max(ls.len, 0))]);
                if (dropped > 0) {
                    root.setLastErrorFmt("set_limits step: {d} limit entries were malformed and are not enforced", .{dropped});
                }
            }
        }
    }
    if (flags & ENQUEUE_FREE_EVENT != 0) std.c.free(@ptrCast(@constCast(event.?)));
    return qid;
}

// One event variable. The name is the map key, lowercased and owned by the
// table, so a get or set is a hash lookup however many variables a game's
// event script declares.
const Var = struct {
    is_float: bool,
    i: i32 = 0,
    f: f32 = 0,
};

// The variables of one event system, keyed on the lowercased name.
const VarTable = std.StringHashMapUnmanaged(Var);

pub const EventSystem = struct {
    next: ?*EventSystem = null,
    vars: VarTable = .empty,
    driver: ?*anyopaque = null,
    command_buffer_size: i32 = 0,
};

pub var g_root: ?*EventSystem = null;

// Resolve an event-system context: 0 means the default (root) system; a non-zero
// value is trusted only if it identifies one of our live systems.
pub fn resolveSystem(ctx: usize) ?*EventSystem {
    if (ctx == 0) return g_root;
    var s = g_root;
    while (s) |sys| : (s = sys.next) {
        if (@intFromPtr(sys) == ctx) return sys;
    }
    return null;
}

pub fn setVar(sys: *EventSystem, name: [*:0]const u8, is_float: bool, ival: i32, fval: f32) void {
    const value: Var = .{ .is_float = is_float, .i = ival, .f = fval };
    var probe: NameKey = undefined;
    probe.init(std.mem.span(name));
    defer probe.deinit();
    if (sys.vars.getPtr(probe.key)) |slot| {
        slot.* = value;
        return;
    }
    // Not a name already in the table (the case-blind probe above would have
    // found it), so the key is a copy the table owns.
    const key = lowerDupe(probe.key) orelse return;
    sys.vars.put(root.global_allocator, key, value) catch root.global_allocator.free(key);
}

pub fn getVar(ctx: usize, name: [*:0]const u8, is_float: bool, out: *anyopaque) i32 {
    const sys = resolveSystem(ctx) orelse return 0;
    var probe: NameKey = undefined;
    probe.init(std.mem.span(name));
    defer probe.deinit();
    const vd = sys.vars.get(probe.key) orelse return 0;
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

pub fn freeSystem(sys: *EventSystem) void {
    var it = sys.vars.keyIterator();
    while (it.next()) |k| root.global_allocator.free(k.*);
    sys.vars.deinit(root.global_allocator);
    root.global_allocator.destroy(sys);
}

// An instance matches a stop/pause/resume filter when its status bit is in the
// filter (filter 0 = all) and its labels match the query (null/empty = all).
pub fn matchFilter(inst: *const SoundInstance, labels: ?[*:0]const u8, filter: u64) bool {
    const status_ok = filter == 0 or (@as(u64, @intCast(inst.status)) & filter) != 0;
    return status_ok and labelMatch(inst.labels, labels);
}
const testing = std.testing;

test "glob: a retry after '*' restarts on a character boundary" {
    // "*" then a lone continuation byte then "b" must not match "a<e-acute>b".
    // The 0xA9 in the pattern is not the e-acute (U+00E9 is C3 A9), so the only
    // way this could match is by lining the pattern byte up with the trailing
    // byte of a character the pattern never named.
    try testing.expect(!globMatch("*\xA9b", "a\u{00e9}b"));
    // The same pattern with the whole character does match, and so does a
    // pattern that wildcards the character: the fix rejects only the split.
    try testing.expect(globMatch("*\u{00e9}b", "a\u{00e9}b"));
    try testing.expect(globMatch("*\xe2\x98\x83b", "a\u{2603}b"));
    try testing.expect(globMatch("*?*", "a\u{00e9}b"));
    // A continuation byte names no character, so a pattern holding one cannot
    // match a text holding that character, whatever the wildcards do.
    try testing.expect(!globMatch("*?\xA9*", "a\u{00e9}b"));
}

test "glob: '?' consumes one character, '*' any run" {
    try testing.expect(globMatch("kick", "kick"));
    try testing.expect(!globMatch("kick", "kicks"));
    try testing.expect(globMatch("k?ck", "kick"));
    // One '?' is one character, so a two-character name needs two.
    try testing.expect(!globMatch("??", "\u{00e9}"));
    try testing.expect(globMatch("??", "a\u{00e9}"));
    try testing.expect(globMatch("*.wav", "caf\u{00e9}.wav"));
    try testing.expect(globMatch("*", ""));
    try testing.expect(globMatch("", ""));
    try testing.expect(!globMatch("", "a"));
    // ASCII behavior is unchanged: every retry position is already a boundary.
    try testing.expect(globMatch("*bcd", "abcd"));
    try testing.expect(!globMatch("*bce", "abcd"));
}

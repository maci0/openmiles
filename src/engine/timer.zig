const std = @import("std");
const root = @import("../root.zig");
const io = root.io;

/// Provides high-resolution periodic timer callbacks for applications, executing on a dedicated background thread.
pub const Timer = struct {
    callback: *const fn (u32) callconv(.winapi) void,
    user_data: u32 = 0,
    period_us: u32 = 10000,
    is_running: bool = false,
    thread: ?std.Thread = null,
    // OS id of the timer thread once run() enters (0 while unknown). Lets
    // stop() detect a self-stop from inside the callback: joining the current
    // thread from its own callback would deadlock, so the handle is left for
    // deinit()/a later external stop to reap.
    thread_id: std.atomic.Value(std.Thread.Id) = .init(0),
    // Set when deinit runs on the timer thread itself, i.e. from inside the
    // callback. The run loop is still unwinding through this struct and writes
    // to it again on the way out, so the destroy belongs to the loop, not to
    // deinit. Clear on no path: a retiring timer never runs again.
    retiring: std.atomic.Value(bool) = .init(false),
    // Serializes start/stop/deinit lifecycle transitions so concurrent
    // AIL_start_timer/AIL_stop_timer calls from different game threads cannot
    // both pass the is_running check (double spawn: two run loops firing the
    // callback concurrently and one leaked thread handle) or race the
    // self.thread handle read against the join. Never taken by the run loop;
    // always acquired *after* global_timers_mutex when nested.
    state_mutex: std.Io.Mutex = .init,
    allocator: std.mem.Allocator,

    pub fn getPeriodUs(self: *Timer) u32 {
        return @atomicLoad(u32, &self.period_us, .acquire);
    }

    /// Shortest period the run loop can honor. A zero period leaves the sleep
    /// slice empty, so the loop fires the callback back-to-back with no delay
    /// and pins a core; callers that convert a rate to a period (hertz, PIT
    /// divisor) truncate to 0 below this floor.
    pub const min_period_us: u32 = 1;

    pub fn setPeriodUs(self: *Timer, us: u64) void {
        const clamped: u64 = @max(@min(us, std.math.maxInt(u32)), min_period_us);
        @atomicStore(u32, &self.period_us, @intCast(clamped), .release);
    }

    pub fn init(allocator: std.mem.Allocator, callback: *const fn (u32) callconv(.winapi) void) !*Timer {
        const self = try allocator.create(Timer);
        errdefer allocator.destroy(self);
        self.* = .{
            .callback = callback,
            .allocator = allocator,
        };
        root.global_timers_mutex.lockUncancelable(io);
        defer root.global_timers_mutex.unlock(io);
        try root.global_timers.append(root.global_allocator, self);
        return self;
    }

    pub fn deinit(self: *Timer) void {
        // One hold of state_mutex across the whole teardown. Releasing it
        // between the stop and the join (as stop() does) would let a
        // concurrent AIL_start_timer spawn a fresh run loop onto a struct that
        // is about to be destroyed, and would hand the join a loop whose
        // is_running had been set true again. run() never takes state_mutex,
        // so holding it across the join is safe.
        self.state_mutex.lockUncancelable(io);
        @atomicStore(bool, &self.is_running, false, .release);
        if (self.thread_id.load(.acquire) == std.Thread.getCurrentId()) {
            // Deinit from inside the callback: this is the run loop's own
            // thread, so it cannot be joined, and the loop touches this struct
            // again on the way out. Hand it the destroy instead.
            self.retiring.store(true, .release);
            self.state_mutex.unlock(io);
            self.unlinkFromGlobalList(false);
            return;
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.state_mutex.unlock(io);
        self.unlinkFromGlobalList(true);
    }

    /// Drop this timer from the global registry, and free it when `free_self`.
    /// The free happens under the lock, and only once the thread is joined, so
    /// a snapshot taken by startAllTimers/stopAllTimers under the same lock
    /// cannot be left holding a freed pointer. A retiring timer is not freed
    /// here: its own run loop still reads it and does the destroy on the way
    /// out. Taken after state_mutex is released so the global->state nesting
    /// order those callers use can never invert.
    fn unlinkFromGlobalList(self: *Timer, free_self: bool) void {
        root.global_timers_mutex.lockUncancelable(io);
        defer root.global_timers_mutex.unlock(io);
        for (root.global_timers.items, 0..) |t, i| {
            if (t == self) {
                _ = root.global_timers.swapRemove(i);
                break;
            }
        }
        if (free_self) self.allocator.destroy(self);
    }

    pub fn start(self: *Timer) void {
        // tryLock, not lock: the retire branch below joins a run loop that is
        // still unwinding inside the callback, and that callback is free to
        // call back into the API, including start on this same timer. Blocking
        // here would put that callback on the other side of the join it is
        // waiting for. A concurrent start is dropped instead: whichever caller
        // holds the lock leaves the timer running, and start is idempotent.
        if (!self.state_mutex.tryLock()) return;
        defer self.state_mutex.unlock(io);
        if (self.retiring.load(.acquire)) return;
        if (@atomicLoad(bool, &self.is_running, .acquire)) return;
        if (self.thread) |stale| {
            // A self-stop leaves its run loop alive until the callback returns,
            // with is_running cleared and the handle still owned here. Spawning
            // over that handle would give two loops firing the callback
            // concurrently and drop the old handle unjoined, so the old loop is
            // retired first. Starting from inside that loop's own callback is a
            // plain resume: the same loop keeps running once the callback
            // returns, and joining it here would join the current thread.
            if (self.thread_id.load(.acquire) == std.Thread.getCurrentId()) {
                @atomicStore(bool, &self.is_running, true, .release);
                return;
            }
            @atomicStore(bool, &self.is_running, false, .release);
            stale.join();
            self.thread = null;
            self.thread_id.store(0, .release);
        }
        @atomicStore(bool, &self.is_running, true, .release);
        self.thread_id.store(0, .release);
        // No thread under a virtual clock: nothing advances time on its own, so
        // the run loop would fire the callback as fast as the CPU allows. The
        // timer still counts as running; tick() drives it one period at a time.
        if (root.clock.isVirtual()) return;
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch |err| {
            @atomicStore(bool, &self.is_running, false, .release);
            // A dead timer thread means the app's callbacks never fire; that
            // must not fail silently (games poll via timer callbacks and would
            // hang waiting for state that is never produced).
            root.log("Timer.start: thread spawn failed ({any}); timer callbacks will not run\n", .{err});
            return;
        };
    }

    pub fn stop(self: *Timer) void {
        // Self-stop from inside the callback: taking state_mutex here could
        // deadlock against an external stop that is joining this very thread,
        // and joining self is fatal anyway. Just clear the flag; the run loop
        // exits once the callback returns, and deinit() reaps the handle.
        if (self.thread_id.load(.acquire) == std.Thread.getCurrentId()) {
            @atomicStore(bool, &self.is_running, false, .release);
            return;
        }
        self.state_mutex.lockUncancelable(io);
        defer self.state_mutex.unlock(io);
        if (!@atomicLoad(bool, &self.is_running, .acquire)) return;
        @atomicStore(bool, &self.is_running, false, .release);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Fire one period of the callback and move virtual time forward by one
    /// period. How a timer runs while a virtual clock is installed: a test or
    /// simulation calls this once per period it means to elapse, so the
    /// callback sequence is a function of the step sequence alone. Does
    /// nothing unless a virtual clock is installed and the timer is running.
    pub fn tick(self: *Timer) void {
        if (!root.clock.isVirtual()) return;
        if (!@atomicLoad(bool, &self.is_running, .acquire)) return;
        self.callback(self.getUserData());
        root.clock.advance(@as(i64, self.getPeriodUs()) * std.time.ns_per_us);
    }

    pub fn getUserData(self: *Timer) u32 {
        return @atomicLoad(u32, &self.user_data, .acquire);
    }
    pub fn setUserData(self: *Timer, data: u32) void {
        @atomicStore(u32, &self.user_data, data, .release);
    }

    // Longest single sleep slice. The timer period can be set as high as
    // ~71 minutes (maxInt(u32) us); sleeping that whole span in one call would
    // make stop() block on join until it elapsed. Wake at least this often to
    // re-check is_running so stop() stays responsive.
    const max_slice_ns: i128 = 50 * std.time.ns_per_ms;

    fn run(self: *Timer) void {
        self.thread_id.store(std.Thread.getCurrentId(), .release);
        // The id names a *live* run loop, so it is cleared on the way out. Left
        // set after the loop exits it outlives the thread it identifies, and
        // the OS recycles thread ids: a later unrelated thread that happened to
        // get this one would compare equal in start() and take the self-resume
        // branch, leaving the timer "running" with no loop to fire the callback.
        // Clearing it also means an external stop() after the loop is gone never
        // mistakes itself for the callback thread.
        defer {
            self.thread_id.store(0, .release);
            // A deinit that ran on this thread left the destroy to the loop:
            // the callback's caller is still unwinding through this struct.
            if (self.retiring.load(.acquire)) self.allocator.destroy(self);
        }
        var next_ns: i128 = root.nowNs();
        while (@atomicLoad(bool, &self.is_running, .acquire)) {
            self.callback(self.getUserData());
            const period_ns: i128 = @as(i128, self.getPeriodUs()) * std.time.ns_per_us;
            next_ns += period_ns;
            // A callback that overran its period leaves next_ns in the past, and
            // every following iteration would then fire back-to-back with no
            // sleep. Resync to now so a late callback delays one tick instead of
            // spinning the loop.
            const after_cb: i128 = root.nowNs();
            if (next_ns < after_cb) next_ns = after_cb;
            // Sleep toward next_ns in bounded slices, bailing out promptly once
            // stop() clears is_running.
            while (@atomicLoad(bool, &self.is_running, .acquire)) {
                // A virtual clock installed under a running thread has no wall
                // time left to wait on; exit rather than spin on a deadline that
                // only moves when someone steps it.
                if (root.clock.isVirtual()) return;
                const now: i128 = root.nowNs();
                const remaining = next_ns - now;
                if (remaining <= 0) break;
                const slice = @min(remaining, max_slice_ns);
                root.sleep(std.Io.Duration.fromNanoseconds(@intCast(slice)));
            }
        }
    }
};

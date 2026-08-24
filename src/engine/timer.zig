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

    pub fn setPeriodUs(self: *Timer, us: u64) void {
        @atomicStore(u32, &self.period_us, @intCast(@min(us, std.math.maxInt(u32))), .release);
    }

    pub fn init(allocator: std.mem.Allocator, callback: *const fn (u32) callconv(.winapi) void) !*Timer {
        const self = try allocator.create(Timer);
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
        self.stop();
        // A self-stopped timer left its handle behind (stop from inside the
        // callback cannot join); reap it here before the struct is destroyed.
        // state_mutex is released before global_timers_mutex is taken so the
        // global->state nesting order of startAllTimers/stopAllTimers can
        // never invert.
        self.state_mutex.lockUncancelable(io);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.state_mutex.unlock(io);
        root.global_timers_mutex.lockUncancelable(io);
        for (root.global_timers.items, 0..) |t, i| {
            if (t == self) {
                _ = root.global_timers.swapRemove(i);
                break;
            }
        }
        root.global_timers_mutex.unlock(io);
        self.allocator.destroy(self);
    }

    pub fn start(self: *Timer) void {
        self.state_mutex.lockUncancelable(io);
        defer self.state_mutex.unlock(io);
        if (@atomicLoad(bool, &self.is_running, .acquire)) return;
        @atomicStore(bool, &self.is_running, true, .release);
        self.thread_id.store(0, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            @atomicStore(bool, &self.is_running, false, .release);
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
        var next_ns: i128 = std.Io.Timestamp.now(io, .awake).nanoseconds;
        while (@atomicLoad(bool, &self.is_running, .acquire)) {
            self.callback(self.getUserData());
            const period_ns: i128 = @as(i128, self.getPeriodUs()) * std.time.ns_per_us;
            next_ns += period_ns;
            // Sleep toward next_ns in bounded slices, bailing out promptly once
            // stop() clears is_running.
            while (@atomicLoad(bool, &self.is_running, .acquire)) {
                const now = std.Io.Timestamp.now(io, .awake).nanoseconds;
                const remaining = next_ns - now;
                if (remaining <= 0) break;
                const slice = @min(remaining, max_slice_ns);
                const dur = std.Io.Duration.fromNanoseconds(@intCast(slice));
                io.sleep(dur, .awake) catch {};
            }
        }
    }
};

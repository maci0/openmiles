const std = @import("std");
const root = @import("../root.zig");

/// Provides high-resolution periodic timer callbacks for applications, executing on a dedicated background thread.
pub const Timer = struct {
    callback: *const fn (u32) callconv(.winapi) void,
    user_data: u32 = 0,
    period_us: u32 = 10000,
    is_running: bool = false,
    thread: ?std.Thread = null,
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
        root.global_timers_mutex.lock();
        defer root.global_timers_mutex.unlock();
        try root.global_timers.append(root.global_allocator, self);
        return self;
    }

    pub fn deinit(self: *Timer) void {
        self.stop();
        root.global_timers_mutex.lock();
        for (root.global_timers.items, 0..) |t, i| {
            if (t == self) {
                _ = root.global_timers.swapRemove(i);
                break;
            }
        }
        root.global_timers_mutex.unlock();
        self.allocator.destroy(self);
    }

    pub fn start(self: *Timer) void {
        if (@atomicLoad(bool, &self.is_running, .acquire)) return;
        @atomicStore(bool, &self.is_running, true, .release);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch {
            @atomicStore(bool, &self.is_running, false, .release);
            return;
        };
    }

    pub fn stop(self: *Timer) void {
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

    fn run(self: *Timer) void {
        var next_ns: i128 = std.time.nanoTimestamp();
        while (@atomicLoad(bool, &self.is_running, .acquire)) {
            self.callback(self.getUserData());
            const period_ns: i128 = @as(i128, self.getPeriodUs()) * std.time.ns_per_us;
            next_ns += period_ns;
            const now = std.time.nanoTimestamp();
            const remaining = next_ns - now;
            if (remaining > 0) {
                std.Thread.sleep(@intCast(remaining));
            }
        }
    }
};

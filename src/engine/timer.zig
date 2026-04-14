const std = @import("std");
const root = @import("../root.zig");

/// Provides high-resolution periodic timer callbacks for applications, executing on a dedicated background thread.
pub const Timer = struct {
    callback: *const fn (u32) callconv(.winapi) void,
    user_data: u32 = 0,
    period_us: u64 = 10000,
    period_mutex: std.Thread.Mutex = .{},
    is_running: bool = false,
    thread: ?std.Thread = null,
    allocator: std.mem.Allocator,

    pub fn getPeriodUs(self: *Timer) u64 {
        self.period_mutex.lock();
        defer self.period_mutex.unlock();
        return self.period_us;
    }

    pub fn setPeriodUs(self: *Timer, us: u64) void {
        self.period_mutex.lock();
        defer self.period_mutex.unlock();
        self.period_us = us;
    }

    pub fn init(allocator: std.mem.Allocator, callback: *const fn (u32) callconv(.winapi) void) !*Timer {
        const self = try allocator.create(Timer);
        self.* = .{
            .callback = callback,
            .allocator = allocator,
        };
        if (root.global_allocator) |ga| {
            root.global_timers_mutex.lock();
            defer root.global_timers_mutex.unlock();
            root.global_timers.append(ga, self) catch {};
        }
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

    fn run(self: *Timer) void {
        var next_ns: i128 = std.time.nanoTimestamp();
        while (@atomicLoad(bool, &self.is_running, .acquire)) {
            self.callback(self.user_data);
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

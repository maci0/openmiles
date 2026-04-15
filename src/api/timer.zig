const openmiles = @import("openmiles");
const log = openmiles.log;

pub export fn AIL_register_timer(callback: *const fn (u32) callconv(.winapi) void) callconv(.winapi) ?*anyopaque {
    log("AIL_register_timer(callback={*})\n", .{callback});
    openmiles.clearLastError();
    const timer = openmiles.Timer.init(openmiles.global_allocator, callback) catch |err| {
        log("Error: {any}\n", .{err});
        openmiles.setLastError("Failed to register timer");
        return null;
    };
    return @ptrCast(timer);
}
pub export fn AIL_set_timer_frequency(timer_opt: ?*openmiles.Timer, hertz: u32) callconv(.winapi) void {
    const timer = timer_opt orelse return;
    log("AIL_set_timer_frequency(timer={*}, hertz={d})\n", .{ timer, hertz });
    if (hertz > 0) timer.setPeriodUs(1_000_000 / @as(u64, hertz));
}
pub export fn AIL_set_timer_period(timer_opt: ?*openmiles.Timer, us: u32) callconv(.winapi) void {
    const timer = timer_opt orelse return;
    log("AIL_set_timer_period(timer={*}, us={d})\n", .{ timer, us });
    timer.setPeriodUs(@as(u64, us));
}
pub export fn AIL_set_timer_user_data(timer_opt: ?*openmiles.Timer, data: u32) callconv(.winapi) void {
    const timer = timer_opt orelse return;
    log("AIL_set_timer_user_data(timer={*}, data={d})\n", .{ timer, data });
    timer.setUserData(data);
}
pub export fn AIL_start_timer(timer_opt: ?*openmiles.Timer) callconv(.winapi) void {
    const timer = timer_opt orelse return;
    log("AIL_start_timer(timer={*})\n", .{timer});
    timer.start();
}
pub export fn AIL_stop_timer(timer_opt: ?*openmiles.Timer) callconv(.winapi) void {
    const timer = timer_opt orelse return;
    log("AIL_stop_timer(timer={*})\n", .{timer});
    timer.stop();
}
pub export fn AIL_release_timer_handle(timer_opt: ?*openmiles.Timer) callconv(.winapi) void {
    const timer = timer_opt orelse return;
    log("AIL_release_timer_handle(timer={*})\n", .{timer});
    timer.deinit();
}
pub export fn AIL_start_all_timers() callconv(.winapi) void {
    log("AIL_start_all_timers()\n", .{});
    openmiles.startAllTimers();
}
pub export fn AIL_stop_all_timers() callconv(.winapi) void {
    log("AIL_stop_all_timers()\n", .{});
    openmiles.stopAllTimers();
}
pub export fn AIL_get_timer_highest_delay() callconv(.winapi) u32 {
    return 10;
}
// Timer divisor is not applicable in our implementation (single-rate timers).
pub export fn AIL_set_timer_divisor(timer_opt: ?*openmiles.Timer, divisor: u32) callconv(.winapi) void {
    _ = timer_opt;
    _ = divisor;
}
pub export fn AIL_set_timer_user(timer_opt: ?*openmiles.Timer, user: u32) callconv(.winapi) void {
    const t = timer_opt orelse return;
    t.setUserData(user);
}
pub export fn AIL_release_all_timers() callconv(.winapi) void {
    openmiles.releaseAllTimers();
}

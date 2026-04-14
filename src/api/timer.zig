const openmiles = @import("openmiles");
const log = openmiles.log;

pub export fn AIL_register_timer(callback: *const fn (u32) callconv(.winapi) void) callconv(.winapi) ?*anyopaque {
    log("AIL_register_timer(callback={*})\n", .{callback});
    const timer = openmiles.Timer.init(openmiles.global_allocator.?, callback) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
    return @ptrCast(timer);
}
pub export fn AIL_set_timer_frequency(timer_ptr: *anyopaque, hertz: u32) callconv(.winapi) void {
    log("AIL_set_timer_frequency(timer={*}, hertz={d})\n", .{ timer_ptr, hertz });
    const timer: *openmiles.Timer = @ptrCast(@alignCast(timer_ptr));
    if (hertz > 0) timer.setPeriodUs(1_000_000 / @as(u64, hertz));
}
pub export fn AIL_set_timer_period(timer_ptr: *anyopaque, us: u32) callconv(.winapi) void {
    log("AIL_set_timer_period(timer={*}, us={d})\n", .{ timer_ptr, us });
    const timer: *openmiles.Timer = @ptrCast(@alignCast(timer_ptr));
    timer.setPeriodUs(@as(u64, us));
}
pub export fn AIL_set_timer_user_data(timer_ptr: *anyopaque, data: u32) callconv(.winapi) void {
    log("AIL_set_timer_user_data(timer={*}, data={d})\n", .{ timer_ptr, data });
    const timer: *openmiles.Timer = @ptrCast(@alignCast(timer_ptr));
    timer.user_data = data;
}
pub export fn AIL_start_timer(timer_ptr: *anyopaque) callconv(.winapi) void {
    log("AIL_start_timer(timer={*})\n", .{timer_ptr});
    const timer: *openmiles.Timer = @ptrCast(@alignCast(timer_ptr));
    timer.start();
}
pub export fn AIL_stop_timer(timer_ptr: *anyopaque) callconv(.winapi) void {
    log("AIL_stop_timer(timer={*})\n", .{timer_ptr});
    const timer: *openmiles.Timer = @ptrCast(@alignCast(timer_ptr));
    timer.stop();
}
pub export fn AIL_release_timer_handle(timer_ptr: *anyopaque) callconv(.winapi) void {
    log("AIL_release_timer_handle(timer={*})\n", .{timer_ptr});
    const timer: *openmiles.Timer = @ptrCast(@alignCast(timer_ptr));
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
pub export fn AIL_set_timer_divisor(timer: *anyopaque, divisor: u32) callconv(.winapi) void {
    _ = timer;
    _ = divisor;
}
// Legacy alias for AIL_set_timer_user_data (older MSS versions).
pub export fn AIL_set_timer_user(timer: *anyopaque, user: u32) callconv(.winapi) void {
    const t: *openmiles.Timer = @ptrCast(@alignCast(timer));
    t.user_data = user;
}
pub export fn AIL_release_all_timers() callconv(.winapi) void {
    openmiles.releaseAllTimers();
}

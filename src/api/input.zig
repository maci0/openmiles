const openmiles = @import("openmiles");
const log = openmiles.log;

pub export fn AIL_open_input(device: *anyopaque) callconv(.winapi) ?*openmiles.Input {
    _ = device;
    openmiles.clearLastError();
    const input = openmiles.Input.init(openmiles.global_allocator) catch |err| {
        log("AIL_open_input failed: {any}\n", .{err});
        openmiles.setLastError("Failed to open input device");
        return null;
    };
    log("AIL_open_input: input={*}\n", .{input});
    return input;
}
pub export fn AIL_close_input(input_ptr: ?*openmiles.Input) callconv(.winapi) void {
    const input = input_ptr orelse return;
    log("AIL_close_input: input={*}\n", .{input});
    input.deinit();
}
pub export fn AIL_set_input_state(input_ptr: ?*openmiles.Input, state: i32) callconv(.winapi) void {
    const input = input_ptr orelse return;
    log("AIL_set_input_state: input={*}, state={d}\n", .{ input, state });
    if (state != 0) {
        input.start();
    } else {
        input.stop();
    }
}
pub export fn AIL_get_input_info(input_ptr: ?*openmiles.Input) callconv(.winapi) u32 {
    const input = input_ptr orelse return 0;
    const info = input.getInfo();
    return info.samples;
}

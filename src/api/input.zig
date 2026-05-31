const openmiles = @import("openmiles");
const log = openmiles.log;

pub fn AIL_open_input(device: *anyopaque) callconv(.winapi) ?*openmiles.Input {
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
pub fn AIL_close_input(input_ptr: ?*openmiles.Input) callconv(.winapi) void {
    const input = input_ptr orelse return;
    log("AIL_close_input: input={*}\n", .{input});
    input.deinit();
}
// v4/v5 ABI: AIL_input_open(AIL_INPUT_INFO*, ?, ?)@12 — renamed to the 1-arg
// AIL_open_input@4 in v6. The 4.0h disassembly shows three @12 slots (the info
// struct plus two further values); we open the capture device the same way and
// ignore the extra two. AIL_input_close@4 is the v4 spelling of AIL_close_input.
pub fn AIL_input_open(info: ?*anyopaque, a1: usize, a2: usize) callconv(.winapi) ?*openmiles.Input {
    _ = info;
    _ = a1;
    _ = a2;
    openmiles.clearLastError();
    const input = openmiles.Input.init(openmiles.global_allocator) catch |err| {
        log("AIL_input_open failed: {any}\n", .{err});
        openmiles.setLastError("Failed to open input device");
        return null;
    };
    return input;
}
pub fn AIL_set_input_state(input_ptr: ?*openmiles.Input, state: i32) callconv(.winapi) i32 {
    const input = input_ptr orelse return 0;
    log("AIL_set_input_state: input={*}, state={d}\n", .{ input, state });
    // SDK (capture.cpp): a no-op (already in the requested state) returns the
    // current input_enabled flag; a successful enable OR disable returns 1.
    const want: i32 = if (state != 0) 1 else 0;
    const cur = @atomicLoad(i32, &input.state, .acquire);
    if (cur == want) return cur;
    if (want != 0) input.start() else input.stop();
    return 1;
}
pub fn AIL_input_info(input_ptr: ?*openmiles.Input) callconv(.winapi) u32 {
    const input = input_ptr orelse return 0;
    const info = input.getInfo();
    return info.samples;
}

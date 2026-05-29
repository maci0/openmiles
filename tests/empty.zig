const std = @import("std");

extern fn play_test_main(argc: c_int, argv: [*]const [*]const u8) c_int;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const c_args = try gpa.alloc([*c]const u8, args.len);
    defer gpa.free(c_args);
    for (args, 0..) |arg, i| {
        c_args[i] = @ptrCast(arg.ptr);
    }
    _ = play_test_main(@intCast(args.len), @ptrCast(c_args.ptr));
}

const std = @import("std");

extern fn play_test_main(argc: c_int, argv: [*]const [*]const u8) c_int;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    
    const c_args = try allocator.alloc([*c]const u8, args.len);
    defer allocator.free(c_args);
    for (args, 0..) |arg, i| {
        c_args[i] = @ptrCast(arg.ptr);
    }
    
    _ = play_test_main(@intCast(args.len), @ptrCast(c_args.ptr));
}

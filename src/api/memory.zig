//! Memory API (MSS v4+). Split into its own module so `-Dmss-version` can gate
//! it cleanly out of v3 builds.

const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;

// App-provided allocator callbacks are stored for round-tripping; OpenMiles uses
// its own allocator internally.
var stored_malloc_fn: ?*anyopaque = null;
var stored_free_fn: ?*anyopaque = null;

pub fn AIL_mem_alloc_lock(size: u32) callconv(.winapi) ?*anyopaque {
    log("AIL_mem_alloc_lock(size={d})\n", .{size});
    return std.c.malloc(size);
}
pub fn AIL_mem_free_lock(ptr: *anyopaque) callconv(.winapi) void {
    log("AIL_mem_free_lock(ptr={*})\n", .{ptr});
    std.c.free(ptr);
}
pub fn AIL_mem_use_malloc(malloc_fn: ?*anyopaque) callconv(.winapi) void {
    stored_malloc_fn = malloc_fn;
}
pub fn AIL_mem_use_free(free_fn: ?*anyopaque) callconv(.winapi) void {
    stored_free_fn = free_fn;
}
pub fn AIL_set_mem_callbacks(malloc_fn: ?*anyopaque, free_fn: ?*anyopaque) callconv(.winapi) void {
    stored_malloc_fn = malloc_fn;
    stored_free_fn = free_fn;
}

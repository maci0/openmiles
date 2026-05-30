//! Filter API (MSS v6+). Split into its own module so `-Dmss-version` can gate
//! it cleanly out of older-version builds.

const std = @import("std");
const openmiles = @import("openmiles");
const log = openmiles.log;
const DigitalDriver = openmiles.DigitalDriver;
const Sample = openmiles.Sample;
const Provider = openmiles.Provider;
const Filter = openmiles.Filter;

const builtin_filter_name: [*:0]const u8 = "OpenMiles Low-Pass Filter";
const filter_attr_names = [_][*:0]const u8{ "Cutoff", "Order" };

pub export fn AIL_open_filter(provider_opt: ?*Provider, driver_opt: ?*DigitalDriver) callconv(.winapi) ?*anyopaque {
    const provider = provider_opt orelse return null;
    const driver = driver_opt orelse return null;
    log("AIL_open_filter(provider={*}, driver={*})\n", .{ provider, driver });
    const filter = Filter.init(provider, driver) catch |err| {
        log("Error: {any}\n", .{err});
        return null;
    };
    return @ptrCast(filter);
}
pub export fn AIL_close_filter(filter_ptr: *anyopaque) callconv(.winapi) void {
    log("AIL_close_filter(filter={*})\n", .{filter_ptr});
    const filter: *Filter = @ptrCast(@alignCast(filter_ptr));
    filter.deinit();
}
pub export fn AIL_set_sample_filter(HSAMPLE_opt: ?*Sample, filter_ptr: *anyopaque, priority: i32) callconv(.winapi) void {
    const HSAMPLE = HSAMPLE_opt orelse return;
    _ = priority;
    log("AIL_set_sample_filter(HSAMPLE={*}, filter={*})\n", .{ HSAMPLE, filter_ptr });
    const filter: *Filter = @ptrCast(@alignCast(filter_ptr));
    filter.attachSample(HSAMPLE);
}
pub export fn AIL_filter_attribute(filter_ptr: *anyopaque, name: [*:0]const u8, value: *anyopaque) callconv(.winapi) void {
    log("AIL_filter_attribute(filter={*}, name={s})\n", .{ filter_ptr, name });
    const filter: *const Filter = @ptrCast(@alignCast(filter_ptr));
    const name_slice = std.mem.span(name);
    const result = filter.getAttribute(name_slice);
    const out: *f32 = @ptrCast(@alignCast(value));
    out.* = result;
}
pub export fn AIL_set_filter_attribute(filter_ptr: *anyopaque, name: [*:0]const u8, value: *anyopaque) callconv(.winapi) void {
    const val: *const f32 = @ptrCast(@alignCast(value));
    log("AIL_set_filter_attribute(filter={*}, name={s}, value={d})\n", .{ filter_ptr, name, val.* });
    const filter: *Filter = @ptrCast(@alignCast(filter_ptr));
    const name_slice = std.mem.span(name);
    filter.setAttribute(name_slice, val.*);
}
// AIL_enumerate_filters(HPROENUM *next, HPROVIDER *dest, C8 **name)
pub export fn AIL_enumerate_filters(next: *?*anyopaque, dest: *?*Provider, name: *[*:0]const u8) callconv(.winapi) i32 {
    const idx: usize = if (next.*) |v| @intFromPtr(v) else 0;
    if (idx == 0) {
        dest.* = openmiles.startup_provider;
        name.* = builtin_filter_name;
        next.* = @ptrFromInt(@as(usize, 1));
        return 1;
    }
    next.* = null;
    dest.* = null;
    return 0;
}
pub export fn AIL_enumerate_filter_attributes(filter: *anyopaque, next: *?*anyopaque, name: *[*:0]const u8) callconv(.winapi) i32 {
    _ = filter;
    const idx: usize = if (next.* == null) 0 else @intFromPtr(next.*);
    if (idx >= filter_attr_names.len) return 0;
    name.* = filter_attr_names[idx];
    next.* = @ptrFromInt(idx + 1);
    return 1;
}
pub export fn AIL_enumerate_filter_sample_attributes(filter: *anyopaque, next: *?*anyopaque, name: *[*:0]const u8) callconv(.winapi) i32 {
    _ = filter;
    const idx: usize = if (next.* == null) 0 else @intFromPtr(next.*);
    if (idx >= filter_attr_names.len) return 0;
    name.* = filter_attr_names[idx];
    next.* = @ptrFromInt(idx + 1);
    return 1;
}
pub export fn AIL_filter_sample_attribute(s_opt: ?*Sample, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const s = s_opt orelse return;
    if (s.attached_filter) |filter| {
        const out: *f32 = @ptrCast(@alignCast(val));
        out.* = filter.getAttribute(std.mem.span(name));
    }
}
pub export fn AIL_set_filter_sample_preference(s_opt: ?*Sample, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const s = s_opt orelse return;
    if (s.attached_filter) |filter| {
        const v: *const f32 = @ptrCast(@alignCast(val));
        filter.setAttribute(std.mem.span(name), v.*);
    }
}
pub export fn AIL_set_filter_preference(filter_ptr: *anyopaque, name: [*:0]const u8, val: *anyopaque) callconv(.winapi) void {
    const filter: *Filter = @ptrCast(@alignCast(filter_ptr));
    const v: *const f32 = @ptrCast(@alignCast(val));
    filter.setAttribute(std.mem.span(name), v.*);
}

//! Legacy MSS 6.x-only exports.
//!
//! These names are the v6 "resource library" and sample-attribute persistence
//! surface. No reference DLL (3.6a..9.1d) and no public SDK header ever carried
//! them, so they are in `never_export` (see src/main.zig) and are never PE
//! exports: a title probing for them by name fails to link, the same as it does
//! against the real DLL. We reproduce them as ABI-faithful stubs, correct
//! stdcall arity (so the caller's stack is balanced) with safe default
//! returns, so internal and test callers resolve the symbol.

const openmiles = @import("openmiles");
const log = openmiles.log;
const Sample = openmiles.Sample;

// AIL_open_library(char const *name, U32 flags) -> HLIB   (@8)
pub fn AIL_open_library(name: ?[*:0]const u8, flags: u32) callconv(.winapi) ?*anyopaque {
    if (name) |n| log("AIL_open_library(name={s}, flags={d})\n", .{ n, flags }) else log("AIL_open_library(name=null, flags={d})\n", .{flags});
    return null; // No embedded library container is mounted.
}

// AIL_close_library(HLIB lib)   (@4)
pub fn AIL_close_library(lib: ?*anyopaque) callconv(.winapi) void {
    log("AIL_close_library(lib={?*})\n", .{lib});
}

// AIL_library_resource_filename(HLIB lib, S32 index, char *buf, S32 buf_len) -> char*   (@16)
pub fn AIL_library_resource_filename(lib: ?*anyopaque, index: i32, buf: ?*anyopaque, buf_len: i32) callconv(.winapi) ?*anyopaque {
    log("AIL_library_resource_filename(lib={?*}, index={d}, buf={?*}, len={d})\n", .{ lib, index, buf, buf_len });
    return null;
}

// AIL_load_sample_attributes(HSAMPLE S, void const *attribs) -> S32   (@8)
pub fn AIL_load_sample_attributes(s: ?*Sample, attribs: ?*anyopaque) callconv(.winapi) i32 {
    log("AIL_load_sample_attributes(s={?*}, attribs={?*})\n", .{ s, attribs });
    return 0;
}

// AIL_save_sample_attributes(HSAMPLE S, void *attribs) -> S32   (@8)
pub fn AIL_save_sample_attributes(s: ?*Sample, attribs: ?*anyopaque) callconv(.winapi) i32 {
    log("AIL_save_sample_attributes(s={?*}, attribs={?*})\n", .{ s, attribs });
    return 0;
}

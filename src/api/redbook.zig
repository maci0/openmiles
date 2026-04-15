const openmiles = @import("openmiles");
const log = openmiles.log;

pub export fn AIL_redbook_open(drive: u32) callconv(.winapi) ?*openmiles.Redbook {
    log("AIL_redbook_open(drive={d})\n", .{drive});
    return openmiles.Redbook.init(openmiles.global_allocator, drive) catch {
        openmiles.setLastError("Failed to open Redbook device");
        return null;
    };
}
pub export fn AIL_redbook_close(hb: ?*openmiles.Redbook) callconv(.winapi) void {
    const rb = hb orelse return;
    log("AIL_redbook_close(hb={*})\n", .{rb});
    rb.deinit();
}
pub export fn AIL_redbook_play(hb: ?*openmiles.Redbook, start: u32, end: u32) callconv(.winapi) u32 {
    const rb = hb orelse return 0;
    log("AIL_redbook_play(hb={*}, start={d}, end={d})\n", .{ rb, start, end });
    rb.play(start, end);
    return 1;
}
pub export fn AIL_redbook_stop(hb: ?*openmiles.Redbook) callconv(.winapi) u32 {
    const rb = hb orelse return 0;
    log("AIL_redbook_stop(hb={*})\n", .{rb});
    rb.stop();
    return 1;
}
pub export fn AIL_redbook_pause(hb: ?*openmiles.Redbook) callconv(.winapi) u32 {
    const rb = hb orelse return 0;
    log("AIL_redbook_pause(hb={*})\n", .{rb});
    rb.pause();
    return 1;
}
pub export fn AIL_redbook_resume(hb: ?*openmiles.Redbook) callconv(.winapi) u32 {
    const rb = hb orelse return 0;
    log("AIL_redbook_resume(hb={*})\n", .{rb});
    rb.resumePlayback();
    return 1;
}
pub export fn AIL_redbook_status(hb: ?*openmiles.Redbook) callconv(.winapi) u32 {
    const rb = hb orelse return 0;
    return @intFromEnum(rb.status);
}
pub export fn AIL_redbook_tracks(hb: ?*openmiles.Redbook) callconv(.winapi) u32 {
    const rb = hb orelse return 0;
    return rb.trackCount();
}
pub export fn AIL_redbook_eject(hb: ?*openmiles.Redbook) callconv(.winapi) u32 {
    const rb = hb orelse return 0;
    rb.stop();
    return 1;
}
pub export fn AIL_redbook_retract(hb: ?*openmiles.Redbook) callconv(.winapi) u32 {
    _ = hb;
    return 1;
}
pub export fn AIL_redbook_id(hb: ?*openmiles.Redbook) callconv(.winapi) [*:0]const u8 {
    _ = hb;
    return "";
}
pub export fn AIL_redbook_open_drive(drive: [*:0]const u8) callconv(.winapi) ?*openmiles.Redbook {
    log("AIL_redbook_open_drive(drive={s})\n", .{drive});
    return openmiles.Redbook.init(openmiles.global_allocator, 0) catch {
        openmiles.setLastError("Failed to open Redbook drive");
        return null;
    };
}
pub export fn AIL_redbook_position(hb: ?*openmiles.Redbook) callconv(.winapi) u32 {
    const rb = hb orelse return 0;
    return rb.getPosition();
}
pub export fn AIL_redbook_track(hb: ?*openmiles.Redbook) callconv(.winapi) u32 {
    const rb = hb orelse return 0;
    return rb.current_track;
}
pub export fn AIL_redbook_track_info(hb: ?*openmiles.Redbook, track: u32, start_ms: ?*u32, end_ms: ?*u32) callconv(.winapi) void {
    _ = hb;
    _ = track;
    if (start_ms) |p| p.* = 0;
    if (end_ms) |p| p.* = 0;
}
pub export fn AIL_redbook_set_volume(hb: ?*openmiles.Redbook, volume: i32) callconv(.winapi) void {
    const rb = hb orelse return;
    rb.volume = @intCast(@min(@max(volume, 0), 127));
}
pub export fn AIL_redbook_volume(hb: ?*openmiles.Redbook) callconv(.winapi) i32 {
    const rb = hb orelse return 0;
    return @intCast(rb.volume);
}

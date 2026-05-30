//! MSS event constructor + step iterator.
//!
//! The Miles runtime builds an "event" by appending steps to an
//! HMSSEVENTCONSTRUCT (AIL_create_event + AIL_add_*_event_step), then finalizes
//! it with AIL_close_event into a serialized byte string that the runtime later
//! walks with AIL_next_event_step.
//!
//! The on-disk Miles event bytecode is a proprietary, undocumented format, so a
//! soundbank's *pre-built* event data cannot be executed faithfully. What we can
//! make real is the round trip of a runtime-constructed event: this module uses
//! a self-consistent encoding so create -> add steps -> close -> next_event_step
//! recovers exactly the steps that were appended.

const std = @import("std");
const root = @import("../root.zig");

/// Step type tags (a stable internal enumeration; not the Miles opcodes).
pub const StepType = enum(i32) {
    end = 0,
    comment = 1,
    clear_state = 2,
    start_sound = 3,
    cache_sounds = 4,
    uncache_sounds = 5,
    apply_environment = 6,
    persist_preset = 7,
    sound_limit = 8,
    control_sounds = 9,
    ramp = 10,
    setblend = 11,
    set_lfo = 12,
    move_var = 13,
    enable_limit = 14,
    exec_event = 15,
    _,
};

/// Decoded step handed back by AIL_next_event_step. `payload`/`payload_len`
/// point into the event string (valid while it lives).
pub const EventStepInfo = extern struct {
    event_type: i32 = 0,
    payload: ?[*]const u8 = null,
    payload_len: i32 = 0,
};

/// Builder accumulating serialized steps. Each step is encoded as
/// [i32 type][i32 payload_len][payload bytes].
pub const EventConstruct = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator) ?*EventConstruct {
        const self = allocator.create(EventConstruct) catch return null;
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn addStep(self: *EventConstruct, t: StepType, payload: []const u8) bool {
        const a = self.allocator;
        var hdr: [8]u8 = undefined;
        std.mem.writeInt(i32, hdr[0..4], @intFromEnum(t), .little);
        std.mem.writeInt(i32, hdr[4..8], @intCast(payload.len), .little);
        self.bytes.appendSlice(a, &hdr) catch return false;
        self.bytes.appendSlice(a, payload) catch return false;
        return true;
    }

    /// Finalize: append the END terminator and return a malloc'd byte string the
    /// caller owns (matching AIL_close_event's U8* return). The construct itself
    /// is freed.
    pub fn close(self: *EventConstruct) ?[*]u8 {
        _ = self.addStep(.end, &.{});
        const len = self.bytes.items.len;
        const out: [*]u8 = @ptrCast(std.c.malloc(len) orelse {
            self.deinit();
            return null;
        });
        @memcpy(out[0..len], self.bytes.items);
        self.deinit();
        return out;
    }

    pub fn deinit(self: *EventConstruct) void {
        self.bytes.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

/// Decode the step at `p` into `info`. Returns the pointer just past this step,
/// or null at the END terminator / on a malformed record. `limit` bounds reads.
pub fn nextStep(p: [*]const u8, limit: usize, info: *EventStepInfo) ?[*]const u8 {
    if (limit < 8) return null;
    const t = std.mem.readInt(i32, p[0..4], .little);
    const plen_raw = std.mem.readInt(i32, p[4..8], .little);
    if (t == @intFromEnum(StepType.end)) return null;
    if (plen_raw < 0) return null;
    const plen: usize = @intCast(plen_raw);
    if (8 + plen > limit) return null;
    info.* = .{
        .event_type = t,
        .payload = if (plen > 0) p + 8 else null,
        .payload_len = @intCast(plen),
    };
    return p + 8 + plen;
}

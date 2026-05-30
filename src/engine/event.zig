//! MSS event constructor — byte-faithful port of the Miles event-string format
//! (MSS 9.x SDK mssevent.cpp). An event is built by appending steps and is
//! serialized as a semicolon-delimited *text* string (not opaque bytecode):
//!
//!   "<VER>;<version>;"  then for each step  "<TYPE>;<field>;<field>;..."
//!
//! where <VER>/<TYPE> are the step-type enum value biased by '0'. Numbers use
//! the same %x / %04x / %f formats the SDK uses, so the produced bytes match the
//! real library. AIL_create_event/add_*_event_step write here; AIL_close_event
//! returns the finished string; AIL_next_event_step decodes the leading type.

const std = @import("std");

/// Step-type enum (values from mss.h); the on-wire char is value + '0'.
pub const StepType = enum(i32) {
    start_sound = 1,
    control_sounds = 2,
    apply_env = 3,
    comment = 4,
    cache_sounds = 5,
    purge_sounds = 6,
    set_limits = 7,
    persist = 8,
    version = 9,
    ramp = 10,
    set_blend = 11,
    clear_state = 12,
    exec_event = 13,
    enable_limit = 14,
    set_lfo = 15,
    _,
};

pub const CURRENT_EVENT_VERSION = 4;

pub const EventStepInfo = extern struct {
    event_type: i32 = 0,
    payload: ?[*]const u8 = null,
    payload_len: i32 = 0,
};

pub const EventConstruct = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator) ?*EventConstruct {
        const self = allocator.create(EventConstruct) catch return null;
        self.* = .{ .allocator = allocator };
        // Version header: '<VERSION+'0'>;<version>;'
        self.printType(.version);
        self.print(";{d};", .{CURRENT_EVENT_VERSION});
        return self;
    }

    fn printType(self: *EventConstruct, t: StepType) void {
        const c: u8 = @intCast(@as(i32, @intFromEnum(t)) + '0');
        self.bytes.append(self.allocator, c) catch {};
    }
    fn print(self: *EventConstruct, comptime fmt: []const u8, args: anytype) void {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.bytes.appendSlice(self.allocator, s) catch {};
    }
    fn raw(self: *EventConstruct, s: []const u8) void {
        self.bytes.appendSlice(self.allocator, s) catch {};
    }

    /// Append a comment step: "<COMMENT>;<text>;".
    pub fn addComment(self: *EventConstruct, text: []const u8) bool {
        self.printType(.comment);
        self.raw(";");
        self.raw(text);
        self.raw(";");
        return true;
    }
    /// Append a clear-state step: "<CLEARSTATE>;".
    pub fn addClearState(self: *EventConstruct) bool {
        self.printType(.clear_state);
        self.raw(";");
        return true;
    }
    /// Append a two-string step (cache/purge sounds): "<TYPE>;<a>;<b>;".
    pub fn addTwoStrings(self: *EventConstruct, t: StepType, a: []const u8, b: []const u8) bool {
        self.printType(t);
        self.raw(";");
        self.raw(a);
        self.raw(";");
        self.raw(b);
        self.raw(";");
        return true;
    }
    /// Append a single-string step (exec_event/apply_env): "<TYPE>;<s>;".
    pub fn addOneString(self: *EventConstruct, t: StepType, s: []const u8) bool {
        self.printType(t);
        self.raw(";");
        self.raw(s);
        self.raw(";");
        return true;
    }
    /// Append a bare step (no fields beyond the leading ';').
    pub fn addBare(self: *EventConstruct, t: StepType) bool {
        self.printType(t);
        self.raw(";");
        return true;
    }

    /// Finalize: NUL-terminate and return a malloc'd copy the caller owns.
    pub fn close(self: *EventConstruct) ?[*]u8 {
        self.bytes.append(self.allocator, 0) catch {};
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

/// Decode the leading step type of an event string and return a pointer past
/// the type+';' prefix (skipping the version header). Returns null at end. Full
/// per-field decode into EventStepInfo is the SDK's large per-type parser; we
/// surface the step type and its remaining text.
pub fn nextStep(event_string: [*:0]const u8, info: *EventStepInfo) ?[*:0]const u8 {
    var p = event_string;
    if (p[0] == 0) return null;
    const t: i32 = @as(i32, p[0]) - '0';
    if (t == @intFromEnum(StepType.version)) {
        // Skip "<VER>;<num>;" then continue to the first real step.
        p += 1;
        if (p[0] == ';') p += 1;
        while (p[0] != 0 and p[0] != ';') p += 1;
        if (p[0] == ';') p += 1;
        if (p[0] == 0 or p[0] == '\r' or p[0] == '\n') return null;
        return nextStep(p, info);
    }
    info.event_type = t;
    p += 1;
    if (p[0] == ';') p += 1;
    info.payload = @ptrCast(p);
    // Scan to the end of this step's text region (best-effort: to the next type
    // char would require per-type field counts; expose the rest of the string).
    var len: i32 = 0;
    while (p[0] != 0) : (p += 1) len += 1;
    info.payload_len = len;
    return null; // single-step decode; multi-step field-accurate walk is TODO
}

//! MSS event constructor + step decoder — a faithful port of the Miles event
//! system (MSS 9.x SDK mssevent.cpp). An event is a semicolon-delimited *text*
//! string: a "<VER>;<version>;" header then "<TYPE>;<field>;..." per step, where
//! <VER>/<TYPE> are the EVENT_STEPTYPE enum value biased by '0'. The constructor
//! emits exactly those bytes; AIL_next_event_step decodes one step into an
//! EVENT_STEP_INFO laid out byte-for-byte like the SDK struct, copying string
//! fields into the caller's scratch buffer (after the struct) as the SDK does.

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

/// MSSSTRINGC: a counted string (pointer + length).
pub const MSSStringC = extern struct { str: ?[*]const u8 = null, len: i32 = 0 };

// Union sub-structs, matching the SDK EVENT_STEP_INFO union field-for-field.
pub const StartStep = extern struct {
    soundname: MSSStringC = .{},
    presetname: MSSStringC = .{},
    eventname: MSSStringC = .{},
    labels: MSSStringC = .{},
    markerstart: MSSStringC = .{},
    markerend: MSSStringC = .{},
    startoffset: MSSStringC = .{},
    statevar: MSSStringC = .{},
    varinit: MSSStringC = .{},
    stream: u32 = 0,
    volmin: f32 = 0,
    volmax: f32 = 0,
    pitchmin: f32 = 0,
    pitchmax: f32 = 0,
    fadeintime: f32 = 0,
    delaymin: u16 = 0,
    delaymax: u16 = 0,
    canload: u8 = 0,
    priority: u8 = 0,
    loopcount: u8 = 0,
    evictiontype: u8 = 0,
    selecttype: u8 = 0,
    presetisdynamic: u8 = 0,
};
pub const ControlStep = extern struct {
    labels: MSSStringC = .{},
    markerstart: MSSStringC = .{},
    markerend: MSSStringC = .{},
    position: MSSStringC = .{},
    presetname: MSSStringC = .{},
    fadeouttime: f32 = 0,
    presetapplytype: u8 = 0,
    loopcount: u8 = 0,
    type: u8 = 0,
};
pub const EnvStep = extern struct { envname: MSSStringC = .{}, isdynamic: u8 = 0 };
pub const CommentStep = extern struct { comment: MSSStringC = .{} };
pub const LoadStep = extern struct { lib: MSSStringC = .{}, namelist: ?[*]const ?[*]const u8 = null, namecount: i32 = 0 };
pub const LimitsStep = extern struct { limits: MSSStringC = .{}, name: MSSStringC = .{} };
pub const PersistStep = extern struct { name: MSSStringC = .{}, presetname: MSSStringC = .{}, labels: MSSStringC = .{}, isdynamic: u8 = 0 };
pub const RampStep = extern struct {
    name: MSSStringC = .{},
    labels: MSSStringC = .{},
    target: MSSStringC = .{},
    time: f32 = 0,
    type: u8 = 0,
    apply_to_new: u8 = 0,
    interpolate_type: u8 = 0,
};
pub const BlendStep = extern struct {
    name: MSSStringC = .{},
    inmin: [10]f32 = [_]f32{0} ** 10,
    inmax: [10]f32 = [_]f32{0} ** 10,
    outmin: [10]f32 = [_]f32{0} ** 10,
    outmax: [10]f32 = [_]f32{0} ** 10,
    minp: [10]f32 = [_]f32{0} ** 10,
    maxp: [10]f32 = [_]f32{0} ** 10,
    count: u8 = 0,
};
pub const ExecStep = extern struct { eventname: MSSStringC = .{} };
pub const EnableLimitStep = extern struct { limitname: MSSStringC = .{} };
pub const SetLfoStep = extern struct {
    name: MSSStringC = .{},
    base: MSSStringC = .{},
    amplitude: MSSStringC = .{},
    freq: MSSStringC = .{},
    invert: i32 = 0,
    polarity: i32 = 0,
    waveform: i32 = 0,
    dutycycle: i32 = 0,
    islfo: i32 = 0,
};

pub const StepUnion = extern union {
    start: StartStep,
    control: ControlStep,
    env: EnvStep,
    comment: CommentStep,
    load: LoadStep,
    limits: LimitsStep,
    persist: PersistStep,
    ramp: RampStep,
    blend: BlendStep,
    exec: ExecStep,
    enablelimit: EnableLimitStep,
    setlfo: SetLfoStep,
};

pub const EVENT_STEP_INFO = extern struct {
    type: i32 = 0,
    u: StepUnion = undefined,
};
// Back-compat alias used by older call sites/tests.
pub const EventStepInfo = EVENT_STEP_INFO;

// ---------------------------------------------------------------------------
// Constructor (byte-faithful write side)
// ---------------------------------------------------------------------------
pub const EventConstruct = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator) ?*EventConstruct {
        const self = allocator.create(EventConstruct) catch return null;
        self.* = .{ .allocator = allocator };
        self.printType(.version);
        self.print(";{d};", .{CURRENT_EVENT_VERSION});
        return self;
    }
    fn printType(self: *EventConstruct, t: StepType) void {
        self.bytes.append(self.allocator, @intCast(@as(i32, @intFromEnum(t)) + '0')) catch {};
    }
    fn print(self: *EventConstruct, comptime fmt: []const u8, args: anytype) void {
        var buf: [64]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.bytes.appendSlice(self.allocator, s) catch {};
    }
    fn raw(self: *EventConstruct, s: []const u8) void {
        self.bytes.appendSlice(self.allocator, s) catch {};
    }
    pub fn addComment(self: *EventConstruct, text: []const u8) bool {
        self.printType(.comment);
        self.raw(";");
        self.raw(text);
        self.raw(";");
        return true;
    }
    pub fn addClearState(self: *EventConstruct) bool {
        self.printType(.clear_state);
        self.raw(";");
        return true;
    }
    pub fn addOneString(self: *EventConstruct, t: StepType, s: []const u8) bool {
        self.printType(t);
        self.raw(";");
        self.raw(s);
        self.raw(";");
        return true;
    }
    pub fn addBare(self: *EventConstruct, t: StepType) bool {
        self.printType(t);
        self.raw(";");
        return true;
    }
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

// ---------------------------------------------------------------------------
// Decoder (faithful read side)
// ---------------------------------------------------------------------------
const Decoder = struct {
    p: [*]const u8, // cursor into the event string
    wp: [*]u8, // write cursor (caller buffer, after the struct)
    wlimit: [*]u8,
    overflow: bool = false,

    fn hexDigit(c: u8) u8 {
        var w = c -% '0';
        if (w > 9) w = c -% 'a' +% 10;
        return w;
    }
    fn setupString(self: *Decoder, x: *MSSStringC) void {
        x.str = self.p;
        var len: i32 = 0;
        while (self.p[0] != ';' and self.p[0] != 0) : (self.p += 1) len += 1;
        x.len = len;
        if (self.p[0] == ';') self.p += 1;
    }
    fn copyString(self: *Decoder, x: *MSSStringC) void {
        const n: usize = @intCast(@max(0, x.len));
        if (@intFromPtr(self.wp) + n + 1 >= @intFromPtr(self.wlimit)) {
            self.overflow = true;
            return;
        }
        if (x.str) |src| @memcpy(self.wp[0..n], src[0..n]);
        x.str = self.wp;
        self.wp += n;
        self.wp[0] = 0;
        self.wp += 1;
    }
    fn copyDigit(self: *Decoder, x: anytype) void {
        const w = hexDigit(self.p[0]);
        self.p += 2; // digit + ';'
        x.* = @intCast(w);
    }
    fn copyUChar(self: *Decoder, x: *u8) void {
        const w1 = hexDigit(self.p[0]);
        self.p += 1;
        const w2 = hexDigit(self.p[0]);
        self.p += 2; // second digit + ';'
        x.* = w1 *% 16 +% w2;
    }
    fn copyUShort(self: *Decoder, x: *u16) void {
        const d1 = hexDigit(self.p[0]);
        self.p += 1;
        const d2 = hexDigit(self.p[0]);
        self.p += 1;
        const d3 = hexDigit(self.p[0]);
        self.p += 1;
        const d4 = hexDigit(self.p[0]);
        self.p += 2; // fourth digit + ';'
        x.* = @as(u16, d1) *% 4096 +% @as(u16, d2) *% 256 +% @as(u16, d3) *% 16 +% d4;
    }
    fn copyFloat(self: *Decoder, x: *f32) void {
        var len: usize = 0;
        while (self.p[len] != ';' and self.p[len] != 0) len += 1;
        x.* = std.fmt.parseFloat(f32, self.p[0..len]) catch 0;
        self.p += len + 1;
    }
};

/// Decode the next step of `event_string` into `step` (an EVENT_STEP_INFO at the
/// start of the caller buffer; strings are copied into `scratch` after it).
/// Returns the cursor past this step, or null at end. Mirrors AIL_next_event_step.
pub fn nextStep(event_string: [*:0]const u8, step: *EVENT_STEP_INFO, scratch: []u8) ?[*:0]const u8 {
    if (event_string[0] == 0) return null;
    var d = Decoder{ .p = event_string, .wp = scratch.ptr, .wlimit = scratch.ptr + scratch.len };
    const t: i32 = @as(i32, event_string[0]) - '0';
    step.type = t;
    const st: StepType = @enumFromInt(t);
    switch (st) {
        .version => {
            d.p += 2; // type + ';'
            var len: usize = 0;
            while (d.p[len] != ';' and d.p[len] != 0) len += 1;
            const ver = std.fmt.parseInt(i32, d.p[0..len], 10) catch -1;
            d.p += len + 1;
            if (ver != CURRENT_EVENT_VERSION) return null;
            if (d.p[0] == 0 or d.p[0] == '\r' or d.p[0] == '\n') return null;
            return nextStep(@ptrCast(d.p), step, scratch);
        },
        .comment => {
            d.p += 2;
            d.setupString(&step.u.comment.comment);
            d.copyString(&step.u.comment.comment);
        },
        .clear_state => {
            d.p += 2;
        },
        .exec_event => {
            d.p += 2;
            d.setupString(&step.u.exec.eventname);
            d.copyString(&step.u.exec.eventname);
        },
        .apply_env => {
            d.p += 2;
            d.setupString(&step.u.env.envname);
            d.copyString(&step.u.env.envname);
            d.copyDigit(&step.u.env.isdynamic);
        },
        .enable_limit => {
            d.p += 2;
            d.setupString(&step.u.enablelimit.limitname);
            d.copyString(&step.u.enablelimit.limitname);
        },
        .cache_sounds, .purge_sounds => {
            d.p += 2;
            d.setupString(&step.u.load.lib);
            d.copyString(&step.u.load.lib);
            // (sound name list is parsed by the SDK into namelist; we keep lib.)
        },
        .set_limits => {
            d.p += 2;
            d.setupString(&step.u.limits.name);
            d.copyString(&step.u.limits.name);
            d.setupString(&step.u.limits.limits);
            d.copyString(&step.u.limits.limits);
        },
        .persist => {
            d.p += 2;
            d.setupString(&step.u.persist.presetname);
            d.copyString(&step.u.persist.presetname);
            d.setupString(&step.u.persist.name);
            d.copyString(&step.u.persist.name);
            d.setupString(&step.u.persist.labels);
            d.copyString(&step.u.persist.labels);
            d.copyDigit(&step.u.persist.isdynamic);
        },
        .ramp => {
            d.p += 2;
            d.setupString(&step.u.ramp.name);
            d.copyString(&step.u.ramp.name);
            d.setupString(&step.u.ramp.labels);
            d.copyString(&step.u.ramp.labels);
            d.copyFloat(&step.u.ramp.time);
            d.setupString(&step.u.ramp.target);
            d.copyString(&step.u.ramp.target);
            d.copyDigit(&step.u.ramp.type);
            d.copyDigit(&step.u.ramp.apply_to_new);
            d.copyDigit(&step.u.ramp.interpolate_type);
        },
        .control_sounds => {
            d.p += 2;
            d.setupString(&step.u.control.labels);
            d.copyString(&step.u.control.labels);
            d.setupString(&step.u.control.markerstart);
            d.copyString(&step.u.control.markerstart);
            d.setupString(&step.u.control.markerend);
            d.copyString(&step.u.control.markerend);
            d.setupString(&step.u.control.position);
            d.copyString(&step.u.control.position);
            d.setupString(&step.u.control.presetname);
            d.copyString(&step.u.control.presetname);
            d.copyDigit(&step.u.control.type);
            d.copyFloat(&step.u.control.fadeouttime);
            d.copyDigit(&step.u.control.presetapplytype);
        },
        .set_lfo => {
            d.p += 2;
            d.setupString(&step.u.setlfo.name);
            d.copyString(&step.u.setlfo.name);
            d.setupString(&step.u.setlfo.base);
            d.copyString(&step.u.setlfo.base);
            d.setupString(&step.u.setlfo.amplitude);
            d.copyString(&step.u.setlfo.amplitude);
            d.setupString(&step.u.setlfo.freq);
            d.copyString(&step.u.setlfo.freq);
            d.copyDigit(&step.u.setlfo.invert);
            d.copyDigit(&step.u.setlfo.polarity);
            d.copyDigit(&step.u.setlfo.waveform);
            d.copyUChar(@ptrCast(&step.u.setlfo.dutycycle));
        },
        .start_sound => {
            d.p += 2;
            const s = &step.u.start;
            d.setupString(&s.soundname);
            d.copyString(&s.soundname);
            d.setupString(&s.presetname);
            d.copyString(&s.presetname);
            d.setupString(&s.eventname);
            d.copyString(&s.eventname);
            d.setupString(&s.markerstart);
            d.copyString(&s.markerstart);
            d.setupString(&s.markerend);
            d.copyString(&s.markerend);
            d.setupString(&s.labels);
            d.copyString(&s.labels);
            d.setupString(&s.statevar);
            d.copyString(&s.statevar);
            d.setupString(&s.varinit);
            d.copyString(&s.varinit);
            d.copyDigit(&s.stream);
            d.copyDigit(&s.canload);
            d.copyDigit(&s.presetisdynamic);
            d.copyUShort(&s.delaymin);
            d.copyUShort(&s.delaymax);
            d.copyUChar(&s.priority);
            d.copyUChar(&s.loopcount);
            d.setupString(&s.startoffset);
            d.copyString(&s.startoffset);
            d.copyFloat(&s.volmin);
            d.copyFloat(&s.volmax);
            d.copyFloat(&s.pitchmin);
            d.copyFloat(&s.pitchmax);
            d.copyFloat(&s.fadeintime);
            d.copyDigit(&s.evictiontype);
            d.copyDigit(&s.selecttype);
        },
        else => return null, // unknown step type
    }
    if (d.overflow) return null;
    return @ptrCast(d.p);
}

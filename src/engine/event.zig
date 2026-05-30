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
    move_var = 16,
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
pub const MoveVarStep = extern struct {
    name: MSSStringC = .{},
    times: [2]f32 = [_]f32{0} ** 2,
    interp_types: [2]i32 = [_]i32{0} ** 2,
    values: [3]f32 = [_]f32{0} ** 3,
};
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
    movevar: MoveVarStep,
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
// Arguments to addStartSound, in the order the start-sound step encodes them.
pub const StartSoundArgs = struct {
    soundname: ?*const anyopaque,
    presetname: ?*const anyopaque,
    presetisdynamic: i32,
    eventname: ?*const anyopaque,
    markerstart: ?*const anyopaque,
    markerend: ?*const anyopaque,
    statevar: ?*const anyopaque,
    varinit: ?*const anyopaque,
    labels: ?*const anyopaque,
    stream: i32,
    canload: i32,
    delaymin: u16,
    delaymax: u16,
    priority: u8,
    loopcount: u8,
    startoffset: ?*const anyopaque,
    volmin: f32,
    volmax: f32,
    pitchmin: f32,
    pitchmax: f32,
    fadeintime: f32,
    evictiontype: i32,
    selecttype: i32,
};

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
    // --- field encoders (mirror the SDK AIL_mem_print* calls and the decoder) ---
    // A string field: content followed by the ';' separator (AIL_mem_prints + ';').
    fn fieldStr(self: *EventConstruct, s: []const u8) void {
        self.raw(s);
        self.raw(";");
    }
    // A C-string argument passed through the C ABI as an opaque pointer.
    fn fieldCStr(self: *EventConstruct, p: ?*const anyopaque) void {
        if (p) |ptr| {
            self.fieldStr(std.mem.span(@as([*:0]const u8, @ptrCast(ptr))));
        } else {
            self.fieldStr("");
        }
    }
    fn hexChar(v: u8) u8 {
        return if (v < 10) '0' + v else 'a' + (v - 10);
    }
    // A single nibble field (decoder copyDigit: one hex char + ';').
    fn fieldDigit(self: *EventConstruct, v: anytype) void {
        self.bytes.append(self.allocator, hexChar(@as(u8, @intCast(@as(i64, v) & 0xf)))) catch {};
        self.raw(";");
    }
    // A byte field as two hex chars + ';' (decoder copyUChar; SDK "%02x"-style).
    fn fieldUChar(self: *EventConstruct, v: u8) void {
        self.bytes.append(self.allocator, hexChar(v >> 4)) catch {};
        self.bytes.append(self.allocator, hexChar(v & 0xf)) catch {};
        self.raw(";");
    }
    // A u16 field as four hex chars + ';' (decoder copyUShort; SDK "%04x").
    fn fieldUShort(self: *EventConstruct, v: u16) void {
        self.bytes.append(self.allocator, hexChar(@intCast((v >> 12) & 0xf))) catch {};
        self.bytes.append(self.allocator, hexChar(@intCast((v >> 8) & 0xf))) catch {};
        self.bytes.append(self.allocator, hexChar(@intCast((v >> 4) & 0xf))) catch {};
        self.bytes.append(self.allocator, hexChar(@intCast(v & 0xf))) catch {};
        self.raw(";");
    }
    // A float field, C "%f" (six decimals) + ';' (decoder copyFloat: parse to ';').
    fn fieldFloat(self: *EventConstruct, v: f32) void {
        self.print("{d:.6};", .{v});
    }
    // --- faithful multi-field step builders (mirror mssevent.cpp) --------------
    pub fn addCacheSounds(self: *EventConstruct, t: StepType, lib: ?*const anyopaque, sounds: ?*const anyopaque) bool {
        if (lib == null or sounds == null) return false;
        self.printType(t);
        self.raw(";");
        self.fieldCStr(lib);
        self.fieldCStr(sounds);
        return true;
    }
    pub fn addApplyEnv(self: *EventConstruct, name: ?*const anyopaque, is_dynamic: i32) bool {
        if (name == null) return false;
        self.printType(.apply_env);
        self.raw(";");
        self.fieldCStr(name);
        self.fieldDigit(@as(i32, if (is_dynamic != 0) 1 else 0));
        return true;
    }
    pub fn addSoundLimit(self: *EventConstruct, name: ?*const anyopaque, limits: ?*const anyopaque) bool {
        if (name == null) return false;
        self.printType(.set_limits);
        self.raw(";");
        self.fieldCStr(name);
        self.fieldCStr(limits);
        return true;
    }
    pub fn addPersist(self: *EventConstruct, preset: ?*const anyopaque, name: ?*const anyopaque, labels: ?*const anyopaque, is_dynamic: i32) bool {
        if (preset == null) return false;
        self.printType(.persist);
        self.raw(";");
        self.fieldCStr(preset);
        self.fieldCStr(name);
        self.fieldCStr(labels);
        self.fieldDigit(is_dynamic);
        return true;
    }
    pub fn addRamp(self: *EventConstruct, name: ?*const anyopaque, labels: ?*const anyopaque, time: f32, target: ?*const anyopaque, type_: i32, apply_to_new: i32, interp: i32) bool {
        if (name == null) return false;
        self.printType(.ramp);
        self.raw(";");
        self.fieldCStr(name);
        self.fieldCStr(labels);
        self.fieldFloat(time);
        self.fieldCStr(target);
        self.fieldDigit(type_);
        self.fieldDigit(apply_to_new);
        self.fieldDigit(interp);
        return true;
    }
    pub fn addControlSounds(self: *EventConstruct, labels: ?*const anyopaque, marker_start: ?*const anyopaque, marker_end: ?*const anyopaque, position: ?*const anyopaque, preset: ?*const anyopaque, loop_count: u8, type_: i32, fade_out: f32, preset_apply: i32) bool {
        self.printType(.control_sounds);
        self.raw(";");
        self.fieldCStr(labels);
        self.fieldCStr(marker_start);
        self.fieldCStr(marker_end);
        self.fieldCStr(position);
        self.fieldCStr(preset);
        self.fieldUChar(loop_count);
        self.fieldDigit(type_);
        self.fieldFloat(fade_out);
        self.fieldDigit(preset_apply);
        return true;
    }
    pub fn addSetLfo(self: *EventConstruct, name: ?*const anyopaque, base: ?*const anyopaque, amplitude: ?*const anyopaque, freq: ?*const anyopaque, invert: i32, polarity: i32, waveform: i32, duty_cycle: i32, is_lfo: i32) bool {
        if (name == null) return false;
        self.printType(.set_lfo);
        self.raw(";");
        self.fieldCStr(name);
        self.fieldCStr(base);
        self.fieldCStr(amplitude);
        self.fieldCStr(freq);
        // SDK: "%d;%d;%d;%2x;%d;" with !!invert, !!polarity, waveform & 3,
        // dutycycle & 255, !!isLFO.
        self.fieldDigit(@as(i32, if (invert != 0) 1 else 0));
        self.fieldDigit(@as(i32, if (polarity != 0) 1 else 0));
        self.fieldDigit(waveform & 3);
        self.fieldUChar(@truncate(@as(u32, @bitCast(duty_cycle))));
        self.fieldDigit(@as(i32, if (is_lfo != 0) 1 else 0));
        return true;
    }
    pub fn addMoveVar(self: *EventConstruct, name: ?*const anyopaque, times: ?[*]const f32, interp_types: ?[*]const i32, values: ?[*]const f32) bool {
        self.printType(.move_var);
        self.raw(";");
        self.fieldCStr(name);
        const t = times orelse return false;
        const it = interp_types orelse return false;
        const v = values orelse return false;
        self.fieldFloat(t[0]);
        self.fieldFloat(t[1]);
        self.print("{d};", .{it[0]});
        self.print("{d};", .{it[1]});
        self.fieldFloat(v[0]);
        self.fieldFloat(v[1]);
        self.fieldFloat(v[2]);
        return true;
    }
    pub fn addSetBlend(self: *EventConstruct, name: ?*const anyopaque, sound_count: i32, in_min: ?[*]const f32, in_max: ?[*]const f32, out_min: ?[*]const f32, out_max: ?[*]const f32, min_p: ?[*]const f32, max_p: ?[*]const f32) bool {
        const imin = in_min orelse return false;
        const imax = in_max orelse return false;
        const omin = out_min orelse return false;
        const omax = out_max orelse return false;
        const mnp = min_p orelse return false;
        const mxp = max_p orelse return false;
        const count: usize = @intCast(@min(@max(sound_count, 0), 10));
        // SDK: "%c;%s;%d;" then count*"%f;%f;%f;%f;%f;%f;".
        self.printType(.set_blend);
        self.raw(";");
        self.fieldCStr(name);
        self.print("{d};", .{count});
        for (0..count) |i| {
            self.fieldFloat(imin[i]);
            self.fieldFloat(imax[i]);
            self.fieldFloat(omin[i]);
            self.fieldFloat(omax[i]);
            self.fieldFloat(mnp[i]);
            self.fieldFloat(mxp[i]);
        }
        return true;
    }
    pub fn addStartSound(self: *EventConstruct, args: StartSoundArgs) bool {
        if (args.soundname == null) return false;
        self.printType(.start_sound);
        self.raw(";");
        self.fieldCStr(args.soundname);
        self.fieldCStr(args.presetname);
        self.fieldCStr(args.eventname);
        self.fieldCStr(args.markerstart);
        self.fieldCStr(args.markerend);
        self.fieldCStr(args.labels);
        self.fieldCStr(args.statevar);
        self.fieldCStr(args.varinit);
        self.fieldDigit(args.stream);
        self.fieldDigit(args.canload);
        self.fieldDigit(args.presetisdynamic);
        self.fieldUShort(args.delaymin);
        self.fieldUShort(args.delaymax);
        self.fieldUChar(args.priority);
        self.fieldUChar(args.loopcount);
        self.fieldCStr(args.startoffset);
        self.fieldFloat(args.volmin);
        self.fieldFloat(args.volmax);
        self.fieldFloat(args.pitchmin);
        self.fieldFloat(args.pitchmax);
        self.fieldFloat(args.fadeintime);
        self.fieldDigit(args.evictiontype);
        self.fieldDigit(args.selecttype);
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
    // A decimal integer field written with "%d" (may be more than one digit).
    fn copyDecimal(self: *Decoder, x: *i32) void {
        var len: usize = 0;
        while (self.p[len] != ';' and self.p[len] != 0) len += 1;
        x.* = std.fmt.parseInt(i32, self.p[0..len], 10) catch 0;
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
    // Zero the union so fields the decoder writes partially (e.g. a byte via
    // copyUChar into a wider field) and fields a step doesn't use read back clean.
    step.u = std.mem.zeroes(StepUnion);
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
            // The SDK splits the second field into namelist/namecount; we keep the
            // library name and consume the sound list so iteration stays aligned.
            var sounds: MSSStringC = .{};
            d.setupString(&sounds);
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
            d.copyUChar(&step.u.control.loopcount);
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
            d.copyDigit(&step.u.setlfo.islfo);
        },
        .set_blend => {
            d.p += 2;
            d.setupString(&step.u.blend.name);
            d.copyString(&step.u.blend.name);
            var count: i32 = 0;
            d.copyDecimal(&count);
            const n: usize = @intCast(@min(@max(count, 0), 10));
            step.u.blend.count = @intCast(n);
            for (0..n) |i| {
                d.copyFloat(&step.u.blend.inmin[i]);
                d.copyFloat(&step.u.blend.inmax[i]);
                d.copyFloat(&step.u.blend.outmin[i]);
                d.copyFloat(&step.u.blend.outmax[i]);
                d.copyFloat(&step.u.blend.minp[i]);
                d.copyFloat(&step.u.blend.maxp[i]);
            }
        },
        .move_var => {
            d.p += 2;
            d.setupString(&step.u.movevar.name);
            d.copyString(&step.u.movevar.name);
            d.copyFloat(&step.u.movevar.times[0]);
            d.copyFloat(&step.u.movevar.times[1]);
            d.copyDecimal(&step.u.movevar.interp_types[0]);
            d.copyDecimal(&step.u.movevar.interp_types[1]);
            d.copyFloat(&step.u.movevar.values[0]);
            d.copyFloat(&step.u.movevar.values[1]);
            d.copyFloat(&step.u.movevar.values[2]);
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

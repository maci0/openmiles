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

/// Version headers one event string may chain. Each header re-enters the decoder,
/// so an unbounded chain in a crafted bank would exhaust the stack; a real event
/// string carries at most one leading header.
const max_version_headers = 4;

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

// ---------------------------------------------------------------------------
// Constructor (byte-faithful write side)
// ---------------------------------------------------------------------------
// Arguments to addStartSound; the wire order is the one it writes, not this one.
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
    // Set when an append runs out of memory mid-build. The step builders keep
    // appending after that, but close() must refuse to hand out the result: a
    // truncated event string would decode as garbage inside the event VM with
    // no signal at all.
    failed: bool = false,

    pub fn create(allocator: std.mem.Allocator) ?*EventConstruct {
        const self = allocator.create(EventConstruct) catch return null;
        self.* = .{ .allocator = allocator };
        self.printType(.version);
        self.print(";{d};", .{CURRENT_EVENT_VERSION});
        if (self.failed) {
            self.deinit();
            return null;
        }
        return self;
    }
    fn printType(self: *EventConstruct, t: StepType) void {
        self.bytes.append(self.allocator, @intCast(@as(i32, @intFromEnum(t)) + '0')) catch {
            self.failed = true;
        };
    }
    fn print(self: *EventConstruct, comptime fmt: []const u8, args: anytype) void {
        var buf: [64]u8 = undefined;
        // An overflow of the scratch buffer is a construction failure like any
        // other: a field silently dropped would decode as garbage downstream.
        const s = std.fmt.bufPrint(&buf, fmt, args) catch {
            self.failed = true;
            return;
        };
        self.bytes.appendSlice(self.allocator, s) catch {
            self.failed = true;
        };
    }
    fn raw(self: *EventConstruct, s: []const u8) void {
        self.bytes.appendSlice(self.allocator, s) catch {
            self.failed = true;
        };
    }
    pub fn addComment(self: *EventConstruct, text: []const u8) bool {
        return self.addOneString(.comment, text);
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
        self.bytes.append(self.allocator, hexChar(@as(u8, @intCast(@as(i64, v) & 0xf)))) catch {
            self.failed = true;
        };
        self.raw(";");
    }
    // A byte field as two hex chars + ';' (decoder copyUChar; SDK "%02x"-style).
    fn fieldUChar(self: *EventConstruct, v: u8) void {
        self.bytes.append(self.allocator, hexChar(v >> 4)) catch {
            self.failed = true;
        };
        self.bytes.append(self.allocator, hexChar(v & 0xf)) catch {
            self.failed = true;
        };
        self.raw(";");
    }
    // A u16 field as four hex chars + ';' (decoder copyUShort; SDK "%04x").
    fn fieldUShort(self: *EventConstruct, v: u16) void {
        self.bytes.append(self.allocator, hexChar(@intCast((v >> 12) & 0xf))) catch {
            self.failed = true;
        };
        self.bytes.append(self.allocator, hexChar(@intCast((v >> 8) & 0xf))) catch {
            self.failed = true;
        };
        self.bytes.append(self.allocator, hexChar(@intCast((v >> 4) & 0xf))) catch {
            self.failed = true;
        };
        self.bytes.append(self.allocator, hexChar(@intCast(v & 0xf))) catch {
            self.failed = true;
        };
        self.raw(";");
    }
    // A float field, C "%f" (six decimals) + ';' (decoder copyFloat: parse to ';').
    // A non-finite value would print as "nan"/"inf", text no decoder can use as
    // a step field, so emit the 0 that copyFloat falls back to.
    fn fieldFloat(self: *EventConstruct, v: f32) void {
        self.print("{d:.6};", .{if (std.math.isFinite(v)) v else 0.0});
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
        // Validate before emitting: a rejected step must leave the stream
        // unchanged, or the half-written head decodes as a truncated step and
        // every step before it is lost.
        const t = times orelse return false;
        const it = interp_types orelse return false;
        const v = values orelse return false;
        self.printType(.move_var);
        self.raw(";");
        self.fieldCStr(name);
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
        // A build that hit an allocation failure is structurally truncated;
        // returning it would look like success while the VM decodes garbage.
        if (self.failed) {
            self.deinit();
            return null;
        }
        self.bytes.append(self.allocator, 0) catch {
            self.deinit();
            return null;
        };
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
    // Step past the type byte and its ';' separator. A string that ends at the
    // type byte carries no step body, so the terminator is checked before the
    // advance: stepping over it would leave the cursor past the end of the
    // string, and every field read after this walks from there.
    fn stepTypeSep(self: *Decoder) bool {
        if (self.p[1] == 0) return false;
        self.p += 2;
        return true;
    }
    fn setupString(self: *Decoder, x: *MSSStringC) void {
        x.str = self.p;
        var len: i32 = 0;
        while (self.p[0] != ';' and self.p[0] != 0) : (self.p += 1) len += 1;
        x.len = len;
        if (self.p[0] == ';') self.p += 1;
    }
    /// Read one `;`-delimited string field and copy it into the working
    /// buffer. The two halves always run together: setupString records where
    /// the source text sits and copyString emits it, so a step never keeps one
    /// without the other.
    fn copyField(self: *Decoder, x: *MSSStringC) void {
        self.setupString(x);
        self.copyString(x);
    }
    fn copyString(self: *Decoder, x: *MSSStringC) void {
        const n: usize = @intCast(@max(0, x.len));
        // Compared as a subtraction, not `wp + n + 1 >= wlimit`: that sum wraps
        // on the 32-bit target and lets a large length through the check.
        if (n + 1 > @intFromPtr(self.wlimit) -| @intFromPtr(self.wp)) {
            self.overflow = true;
            return;
        }
        if (x.str) |src| @memcpy(self.wp[0..n], src[0..n]);
        x.str = self.wp;
        self.wp += n;
        self.wp[0] = 0;
        self.wp += 1;
    }
    // Consume the ';' separator after a fixed-width field; flag overflow (so
    // nextStep bails) at a premature NUL rather than stepping past the string end.
    fn eatSep(self: *Decoder) void {
        if (self.p[0] == ';') {
            self.p += 1;
        } else if (self.p[0] == 0) {
            self.overflow = true;
        } else {
            self.p += 1; // tolerate a stray byte, as the original did
        }
    }
    // Read one hex nibble at the cursor and advance; stop (flag overflow) at NUL.
    fn nibble(self: *Decoder) ?u8 {
        if (self.p[0] == 0) {
            self.overflow = true;
            return null;
        }
        const w = hexDigit(self.p[0]);
        self.p += 1;
        return w;
    }
    fn copyDigit(self: *Decoder, x: anytype) void {
        const w = self.nibble() orelse {
            x.* = 0;
            return;
        };
        x.* = @intCast(w);
        self.eatSep();
    }
    fn copyUChar(self: *Decoder, x: *u8) void {
        const w1 = self.nibble() orelse {
            x.* = 0;
            return;
        };
        const w2 = self.nibble() orelse {
            x.* = w1;
            return;
        };
        x.* = w1 *% 16 +% w2;
        self.eatSep();
    }
    fn copyUShort(self: *Decoder, x: *u16) void {
        var v: u16 = 0;
        var i: u8 = 0;
        while (i < 4) : (i += 1) {
            const d = self.nibble() orelse {
                x.* = v;
                return;
            };
            v = v *% 16 +% d;
        }
        x.* = v;
        self.eatSep();
    }
    // Scan a "%f"/"%d"-style field up to its ';' separator and advance past it;
    // flag overflow (so nextStep bails) at a premature NUL rather than stepping
    // past the string end, like eatSep/nibble do.
    fn fieldText(self: *Decoder) []const u8 {
        var len: usize = 0;
        while (self.p[len] != ';' and self.p[len] != 0) len += 1;
        const s = self.p[0..len];
        self.p += len;
        if (self.p[0] == ';') {
            self.p += 1;
        } else {
            self.overflow = true;
        }
        return s;
    }
    fn copyFloat(self: *Decoder, x: *f32) void {
        // parseFloat accepts "nan", "-nan", "inf" and "-inf" as valid text, so a
        // step string carrying one decodes to a non-finite value that every
        // later comparison silently fails (NaN != NaN, and @min/@max skip it).
        // Map a non-finite field to the same 0 an unparsable one gets.
        const v = std.fmt.parseFloat(f32, self.fieldText()) catch 0;
        x.* = if (std.math.isFinite(v)) v else 0;
    }
    // A decimal integer field written with "%d" (may be more than one digit).
    fn copyDecimal(self: *Decoder, x: *i32) void {
        x.* = std.fmt.parseInt(i32, self.fieldText(), 10) catch 0;
    }
    // Split the colon-separated cache/purge sound list into namelist/namecount,
    // mirroring the SDK: reserve `count` pointers in the scratch buffer, copy the
    // list, and null-terminate each name in place.
    fn parseNameList(self: *Decoder, load: *LoadStep) void {
        const start = self.p;
        var pp = self.p;
        var count: i32 = 0;
        while (pp[0] != ';' and pp[0] != 0) : (pp += 1) {
            if (pp[0] == ':') count += 1;
        }
        if (@intFromPtr(pp) != @intFromPtr(start)) count += 1;
        const str_len: usize = @intFromPtr(pp) - @intFromPtr(start);
        const ncount: usize = @intCast(@max(count, 0));
        const ptr_size = @sizeOf(usize);
        const w = (@intFromPtr(self.wp) + ptr_size - 1) & ~@as(usize, ptr_size - 1);
        const list_bytes = ncount * ptr_size;
        // Saturating throughout: ncount and str_len both come out of a
        // bank-supplied string, so on the 32-bit target a large enough field
        // wraps the sum below and the bound would pass for a write that lands
        // past wlimit.
        if (w +| list_bytes +| str_len + 1 >= @intFromPtr(self.wlimit)) {
            self.overflow = true;
            self.p = pp;
            if (self.p[0] == ';') self.p += 1;
            return;
        }
        const namelist: [*]?[*]const u8 = @ptrFromInt(w);
        // Null the reserved slots first: a trailing-colon list (e.g. "a:b:") counts
        // one more entry than it writes, so the last slot would otherwise hold
        // uninitialized scratch memory that a consumer could deref as a wild pointer.
        for (0..ncount) |z| namelist[z] = null;
        load.namecount = count;
        load.namelist = @ptrCast(namelist);
        const str_dst: [*]u8 = @ptrFromInt(w + list_bytes);
        if (str_len > 0) @memcpy(str_dst[0..str_len], start[0..str_len]);
        str_dst[str_len] = 0;
        self.wp = @ptrFromInt(w + list_bytes + str_len + 1);
        var writer: usize = 0;
        var trailer: usize = 0;
        var current: usize = 0;
        while (writer < str_len) : (writer += 1) {
            if (str_dst[writer] == ':') {
                if (current < ncount) namelist[current] = @ptrCast(str_dst + trailer);
                trailer = writer + 1;
                current += 1;
                str_dst[writer] = 0;
            }
        }
        if (writer != trailer and current < ncount) namelist[current] = @ptrCast(str_dst + trailer);
        self.p = pp;
        if (self.p[0] == ';') self.p += 1;
    }
};

/// Decode the next step of `event_string` into `step` (an EVENT_STEP_INFO at the
/// start of the caller buffer; strings are copied into `scratch` after it).
/// Returns the cursor past this step, or null at end. Mirrors AIL_next_event_step.
pub fn nextStep(event_string: [*:0]const u8, step: *EVENT_STEP_INFO, scratch: []u8) ?[*:0]const u8 {
    return nextStepDepth(event_string, step, scratch, 0);
}

fn nextStepDepth(event_string: [*:0]const u8, step: *EVENT_STEP_INFO, scratch: []u8, version_headers: u32) ?[*:0]const u8 {
    if (event_string[0] == 0) return null;
    var d = Decoder{ .p = event_string, .wp = scratch.ptr, .wlimit = scratch.ptr + scratch.len };
    const t: i32 = @as(i32, event_string[0]) - '0';
    // The step-type byte is file data: a tag outside the enum range must end the
    // walk, not trap the conversion.
    if (t < @intFromEnum(StepType.start_sound) or t > @intFromEnum(StepType.move_var)) return null;
    const st: StepType = @enumFromInt(t);
    step.type = t;
    // Zero the union so fields the decoder writes partially (e.g. a byte via
    // copyUChar into a wider field) and fields a step doesn't use read back clean.
    step.u = std.mem.zeroes(StepUnion);
    switch (st) {
        .version => {
            if (version_headers >= max_version_headers) return null;
            if (!d.stepTypeSep()) return null;
            const ver = std.fmt.parseInt(i32, d.fieldText(), 10) catch -1;
            if (ver != CURRENT_EVENT_VERSION) return null;
            if (d.p[0] == 0 or d.p[0] == '\r' or d.p[0] == '\n') return null;
            return nextStepDepth(@ptrCast(d.p), step, scratch, version_headers + 1);
        },
        .comment => {
            if (!d.stepTypeSep()) return null;
            d.copyField(&step.u.comment.comment);
        },
        .clear_state => {
            if (!d.stepTypeSep()) return null;
        },
        .exec_event => {
            if (!d.stepTypeSep()) return null;
            d.copyField(&step.u.exec.eventname);
        },
        .apply_env => {
            if (!d.stepTypeSep()) return null;
            d.copyField(&step.u.env.envname);
            d.copyDigit(&step.u.env.isdynamic);
        },
        .enable_limit => {
            if (!d.stepTypeSep()) return null;
            d.copyField(&step.u.enablelimit.limitname);
        },
        .cache_sounds, .purge_sounds => {
            if (!d.stepTypeSep()) return null;
            d.copyField(&step.u.load.lib);
            d.parseNameList(&step.u.load);
        },
        .set_limits => {
            if (!d.stepTypeSep()) return null;
            d.copyField(&step.u.limits.name);
            d.copyField(&step.u.limits.limits);
        },
        .persist => {
            if (!d.stepTypeSep()) return null;
            d.copyField(&step.u.persist.presetname);
            d.copyField(&step.u.persist.name);
            d.copyField(&step.u.persist.labels);
            d.copyDigit(&step.u.persist.isdynamic);
        },
        .ramp => {
            if (!d.stepTypeSep()) return null;
            d.copyField(&step.u.ramp.name);
            d.copyField(&step.u.ramp.labels);
            d.copyFloat(&step.u.ramp.time);
            d.copyField(&step.u.ramp.target);
            d.copyDigit(&step.u.ramp.type);
            d.copyDigit(&step.u.ramp.apply_to_new);
            d.copyDigit(&step.u.ramp.interpolate_type);
        },
        .control_sounds => {
            if (!d.stepTypeSep()) return null;
            d.copyField(&step.u.control.labels);
            d.copyField(&step.u.control.markerstart);
            d.copyField(&step.u.control.markerend);
            d.copyField(&step.u.control.position);
            d.copyField(&step.u.control.presetname);
            d.copyUChar(&step.u.control.loopcount);
            d.copyDigit(&step.u.control.type);
            d.copyFloat(&step.u.control.fadeouttime);
            d.copyDigit(&step.u.control.presetapplytype);
        },
        .set_lfo => {
            if (!d.stepTypeSep()) return null;
            d.copyField(&step.u.setlfo.name);
            d.copyField(&step.u.setlfo.base);
            d.copyField(&step.u.setlfo.amplitude);
            d.copyField(&step.u.setlfo.freq);
            d.copyDigit(&step.u.setlfo.invert);
            d.copyDigit(&step.u.setlfo.polarity);
            d.copyDigit(&step.u.setlfo.waveform);
            d.copyUChar(@ptrCast(&step.u.setlfo.dutycycle));
            d.copyDigit(&step.u.setlfo.islfo);
        },
        .set_blend => {
            if (!d.stepTypeSep()) return null;
            d.copyField(&step.u.blend.name);
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
            if (!d.stepTypeSep()) return null;
            d.copyField(&step.u.movevar.name);
            d.copyFloat(&step.u.movevar.times[0]);
            d.copyFloat(&step.u.movevar.times[1]);
            d.copyDecimal(&step.u.movevar.interp_types[0]);
            d.copyDecimal(&step.u.movevar.interp_types[1]);
            d.copyFloat(&step.u.movevar.values[0]);
            d.copyFloat(&step.u.movevar.values[1]);
            d.copyFloat(&step.u.movevar.values[2]);
        },
        .start_sound => {
            if (!d.stepTypeSep()) return null;
            const s = &step.u.start;
            d.copyField(&s.soundname);
            d.copyField(&s.presetname);
            d.copyField(&s.eventname);
            d.copyField(&s.markerstart);
            d.copyField(&s.markerend);
            d.copyField(&s.labels);
            d.copyField(&s.statevar);
            d.copyField(&s.varinit);
            d.copyDigit(&s.stream);
            d.copyDigit(&s.canload);
            d.copyDigit(&s.presetisdynamic);
            d.copyUShort(&s.delaymin);
            d.copyUShort(&s.delaymax);
            d.copyUChar(&s.priority);
            d.copyUChar(&s.loopcount);
            d.copyField(&s.startoffset);
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

test "a non-finite float field decodes to 0 rather than reaching the step" {
    const testing = std.testing;
    var step: EVENT_STEP_INFO = undefined;
    var scratch: [256]u8 align(8) = undefined;

    // parseFloat reads "nan" and "inf" as valid text, so a step string can
    // carry a value that every later comparison silently mishandles.
    _ = nextStep(":n;l;nan;tg;0;0;0;", &step, &scratch) orelse return error.TestUnexpectedResult;
    try testing.expect(std.math.isFinite(step.u.ramp.time));
    try testing.expectEqual(@as(f32, 0), step.u.ramp.time);

    _ = nextStep(":n;l;-inf;tg;0;0;0;", &step, &scratch) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f32, 0), step.u.ramp.time);

    // A finite field is unaffected.
    _ = nextStep(":n;l;2.500000;tg;0;0;0;", &step, &scratch) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(f32, 2.5), step.u.ramp.time);
}

test "nextStep stops at a premature NUL inside float/decimal fields" {
    const testing = std.testing;
    var step: EVENT_STEP_INFO = undefined;
    var scratch: [256]u8 align(8) = undefined;

    // Ramp (type ':') whose float field ("1.") is cut off by the terminator:
    // the decoder must flag overflow and stop instead of stepping past the NUL
    // and decoding whatever follows it in memory.
    try testing.expectEqual(@as(?[*:0]const u8, null), nextStep(":n;l;1.", &step, &scratch));
    // move_var (type '@', 16) truncated inside a decimal interp_type field.
    try testing.expectEqual(@as(?[*:0]const u8, null), nextStep("@n;1.5;2.0;1", &step, &scratch));
    // A bare version header ends the event cleanly (no steps follow).
    try testing.expectEqual(@as(?[*:0]const u8, null), nextStep("9;4", &step, &scratch));

    // Well-formed equivalents still decode fully.
    try testing.expect(nextStep(":n;l;1.;t;1;0;2;", &step, &scratch) != null);
}

test "nextStep stops at a version header cut off after the type byte" {
    const testing = std.testing;
    var step: EVENT_STEP_INFO = undefined;
    var scratch: [256]u8 align(8) = undefined;

    // "9" alone: the version step skips its type byte and the ';' after it.
    // With the string ending there, that skip lands on the terminator, and
    // scanning for the version field from there would read whatever follows
    // the string in memory. It must be refused instead.
    try testing.expectEqual(@as(?[*:0]const u8, null), nextStep("9", &step, &scratch));
    // A header with a separator but no version number stops at the same place.
    try testing.expectEqual(@as(?[*:0]const u8, null), nextStep("9;", &step, &scratch));
    // A well-formed header ("9;4;") is consumed and the step behind it is what
    // comes back: the cursor points past that step, not at its first byte.
    const after = nextStep("9;4;<;", &step, &scratch).?;
    try testing.expectEqual(@intFromEnum(StepType.clear_state), step.type);
    try testing.expect(after[0] == 0);
}

test "nextStep refuses every step type whose body is cut off after the type byte" {
    const testing = std.testing;
    var step: EVENT_STEP_INFO = undefined;
    var scratch: [256]u8 align(8) = undefined;

    // Every step type steps past its type byte and the ';' separator before it
    // reads any field. A string that ends at the type byte has neither, so the
    // step would advance the cursor onto the terminator and every field read
    // from there would walk off the end of the buffer. One representative per
    // step type, all of which take the same path. The type byte is '0' + the
    // StepType value, so the values past 9 run into punctuation.
    const truncated = [_][*:0]const u8{
        "1", // start_sound
        "2", // control_sounds
        "3", // apply_env
        "4", // comment
        "5", // cache_sounds
        "6", // purge_sounds
        "7", // set_limits
        "8", // persist
        "9;", // version, separator present but no field
        ":", // ramp
        ";", // set_blend
        "<", // clear_state
        "=", // exec_event
        ">", // enable_limit
        "?", // set_lfo
        "@", // move_var
    };
    for (truncated) |s| {
        try testing.expectEqual(@as(?[*:0]const u8, null), nextStep(s, &step, &scratch));
    }
}

const std = @import("std");
const root = @import("../root.zig");
const ma = root.ma;
const log = root.log;
const fs_compat = root.fs_compat;
const io = root.io;

const deg2rad = root.deg2rad;
const buildWavFromPcm = root.buildWavFromPcm;

/// MSS SPEED_OF_SOUND from wavefile.cpp (0.355 m/ms) — used so miniaudio's
/// Doppler scale matches Miles for the same raw game velocities.
const mss_speed_of_sound: f32 = 0.355;
const StreamSource = @import("stream_buffer.zig").StreamSource;

/// MSS S3D falloff graph point (MSSGRAPHPOINT in mss.h): a distance/value point
/// plus in/out tangents. Layout must stay identical to the SDK struct so a
/// caller's `MSSGRAPHPOINT*` can be `@memcpy`'d in verbatim.
pub const FalloffGraphPoint = extern struct { x: f32, y: f32, itx: f32, ity: f32, otx: f32, oty: f32, itype: i32, otype: i32 };
/// MILES_MAX_FALLOFF_GRAPH_POINTS (mss.h). A pointcount above this is rejected.
pub const max_falloff_points: usize = 5;
/// The four S3D falloff graphs a sample carries: volume, exclusion, lowpass, spread.
pub const FalloffKind = enum(usize) { volume = 0, exclusion = 1, lowpass = 2, spread = 3 };

/// Saturating f32 -> u64 (NaN/negative -> 0, overflow -> clamped). Guards the
/// `@intFromFloat` panic when external callers pass negative/huge positions.
fn satU64(v: f32) u64 {
    if (!(v >= 0)) return 0; // false for NaN and negatives
    if (v >= 1.8446744e19) return std.math.maxInt(u64);
    return @intFromFloat(v);
}

/// Normalize a 3-vector in place, matching MSS RAD_vector_normalize (m3d.cpp):
/// a vector shorter than 1e-4 is left unchanged (avoids divide-by-zero).
fn normalize3(v: *[3]f32) void {
    const len = @sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (len > 0.0001) {
        v[0] /= len;
        v[1] /= len;
        v[2] /= len;
    }
}

/// Saturating f32 -> i32 (NaN -> 0, out-of-range -> clamped).
fn satI32(v: f32) i32 {
    if (std.math.isNan(v)) return 0;
    if (v >= 2147483647.0) return std.math.maxInt(i32);
    if (v <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(v);
}

/// Apply an MSS loop count to a miniaudio sound: count 0 means infinite looping.
fn applyLoopCount(sound: *ma.ma_sound, count: i32) void {
    ma.ma_sound_set_looping(sound, if (count == 0) ma.MA_TRUE else ma.MA_FALSE);
}

/// Translate an MSS byte-offset loop block into miniaudio frame ranges. Works on
/// any sample type exposing `bytesPerFrame`, `loop_start_frame`, `loop_end_frame`
/// and `decoder` (Sample and Sample3D share the exact same logic).
fn applyLoopBlock(self: anytype, start_bytes: i32, end_bytes: i32) void {
    const bpf = self.bytesPerFrame();
    if (start_bytes >= 0 and bpf > 0) {
        self.loop_start_frame = @as(u64, @intCast(start_bytes)) / @as(u64, bpf);
    } else {
        self.loop_start_frame = 0;
    }
    if (end_bytes > 0 and bpf > 0) {
        self.loop_end_frame = @as(u64, @intCast(end_bytes)) / @as(u64, bpf);
        if (self.decoder) |d| {
            _ = ma.ma_data_source_set_range_in_pcm_frames(d, 0, self.loop_end_frame);
        }
    } else {
        self.loop_end_frame = 0;
        if (self.decoder) |d| {
            _ = ma.ma_data_source_set_range_in_pcm_frames(d, 0, std.math.maxInt(u64));
        }
    }
}

/// A peak soft-limiter as a custom miniaudio node: passes audio below the knee
/// untouched and saturates peaks toward unity so a bus can't clip.
pub const LimiterNode = extern struct {
    base: ma.ma_node_base,

    const knee: f32 = 0.7;
    pub fn softClip(x: f32) f32 {
        const a = @abs(x);
        if (a <= knee) return x;
        const over = (a - knee) / (1.0 - knee);
        const shaped = knee + (1.0 - knee) * std.math.tanh(over);
        return if (x < 0) -shaped else shaped;
    }
    fn process(node: ?*ma.ma_node, ppIn: [*c][*c]const f32, pInCount: [*c]u32, ppOut: [*c][*c]f32, pOutCount: [*c]u32) callconv(.c) void {
        _ = node;
        const n = @min(pInCount.*, pOutCount.*);
        const total: usize = @as(usize, n) * 2; // stereo
        const in = ppIn[0];
        const out = ppOut[0];
        var i: usize = 0;
        while (i < total) : (i += 1) out[i] = softClip(in[i]);
        pInCount.* = n;
        pOutCount.* = n;
    }
    const vtable = ma.ma_node_vtable{
        .onProcess = &process,
        .onGetRequiredInputFrameCount = null,
        .inputBusCount = 1,
        .outputBusCount = 1,
        .flags = 0,
    };
};

/// A peak compressor as a custom miniaudio node: smoothly reduces gain on signal
/// above the threshold by the given ratio (envelope follower with fast attack /
/// slow release).
pub const CompressorNode = extern struct {
    base: ma.ma_node_base,
    env: f32 = 1.0,

    const threshold: f32 = 0.5;
    const ratio: f32 = 4.0;
    const attack: f32 = 0.25; // per-sample smoothing toward a lower gain
    const release: f32 = 0.0015; // slower recovery
    pub fn process(node: ?*ma.ma_node, ppIn: [*c][*c]const f32, pInCount: [*c]u32, ppOut: [*c][*c]f32, pOutCount: [*c]u32) callconv(.c) void {
        const self: *CompressorNode = @ptrCast(@alignCast(node.?));
        const n = @min(pInCount.*, pOutCount.*);
        const in = ppIn[0];
        const out = ppOut[0];
        var f: usize = 0;
        while (f < n) : (f += 1) {
            const l = in[f * 2];
            const r = in[f * 2 + 1];
            const peak = @max(@abs(l), @abs(r));
            var target: f32 = 1.0;
            if (peak > threshold) target = (threshold + (peak - threshold) / ratio) / peak;
            const coef: f32 = if (target < self.env) attack else release;
            self.env += (target - self.env) * coef;
            out[f * 2] = l * self.env;
            out[f * 2 + 1] = r * self.env;
        }
        pInCount.* = n;
        pOutCount.* = n;
    }
    const vtable = ma.ma_node_vtable{
        .onProcess = &process,
        .onGetRequiredInputFrameCount = null,
        .inputBusCount = 1,
        .outputBusCount = 1,
        .flags = 0,
    };
};

/// A v9 mixer bus: a miniaudio sound group that samples route their output to,
/// so a submix can be controlled (volume) independently of the master.
pub const MixBus = struct {
    group: ma.ma_sound_group,
    index: i32,
    driver: *DigitalDriver,
    limiter: ?*LimiterNode = null,
    compressor: ?*CompressorNode = null,

    pub fn setVolume(self: *MixBus, vol: f32) void {
        ma.ma_sound_group_set_volume(&self.group, vol);
    }

    /// Insert (on) or remove (off) a peak limiter between this bus and the
    /// engine endpoint.
    pub fn enableLimiter(self: *MixBus, on: bool) void {
        const eng = &self.driver.engine;
        const endpoint = ma.ma_engine_get_endpoint(eng);
        if (on and self.limiter == null) {
            // One effect node per bus: tear down a compressor first, else both
            // would attach to the same insert point and the second attach would
            // orphan (and leak) the first while corrupting the bus routing.
            if (self.compressor != null) self.installCompressor(false);
            const node = self.driver.allocator.create(LimiterNode) catch {
                // No error channel on this void API; say why the effect is absent
                // or a later enableLimiter(true) query will lie.
                log("MixBus.enableLimiter: node allocation failed\n", .{});
                return;
            };
            var chans = [_]u32{2};
            var cfg = ma.ma_node_config_init();
            cfg.vtable = &LimiterNode.vtable;
            cfg.inputBusCount = 1;
            cfg.outputBusCount = 1;
            cfg.pInputChannels = &chans;
            cfg.pOutputChannels = &chans;
            if (ma.ma_node_init(ma.ma_engine_get_node_graph(eng), &cfg, null, @ptrCast(node)) != ma.MA_SUCCESS) {
                self.driver.allocator.destroy(node);
                return;
            }
            _ = ma.ma_node_attach_output_bus(@ptrCast(node), 0, endpoint, 0);
            _ = ma.ma_node_attach_output_bus(@ptrCast(&self.group.engineNode), 0, @ptrCast(node), 0);
            self.limiter = node;
        } else if (!on and self.limiter != null) {
            // Route the bus straight back to the endpoint, then free the node.
            _ = ma.ma_node_attach_output_bus(@ptrCast(&self.group.engineNode), 0, endpoint, 0);
            ma.ma_node_uninit(@ptrCast(self.limiter.?), null);
            self.driver.allocator.destroy(self.limiter.?);
            self.limiter = null;
        }
    }

    /// Install (or, with on=false, remove) a compressor between this bus and the
    /// engine endpoint. One effect node per bus; installing replaces any
    /// existing limiter on the slot.
    pub fn installCompressor(self: *MixBus, on: bool) void {
        const eng = &self.driver.engine;
        const endpoint = ma.ma_engine_get_endpoint(eng);
        if (on and self.compressor == null) {
            // One effect node per bus: tear down a limiter first so the two
            // slots can't both point at the same insert (which would leak the
            // displaced node and leave the bus graph in an inconsistent state).
            if (self.limiter != null) self.enableLimiter(false);
            const node = self.driver.allocator.create(CompressorNode) catch {
                log("MixBus.installCompressor: node allocation failed\n", .{});
                return;
            };
            var chans = [_]u32{2};
            var cfg = ma.ma_node_config_init();
            cfg.vtable = &CompressorNode.vtable;
            cfg.inputBusCount = 1;
            cfg.outputBusCount = 1;
            cfg.pInputChannels = &chans;
            cfg.pOutputChannels = &chans;
            if (ma.ma_node_init(ma.ma_engine_get_node_graph(eng), &cfg, null, @ptrCast(node)) != ma.MA_SUCCESS) {
                self.driver.allocator.destroy(node);
                return;
            }
            node.env = 1.0; // ma_node_init zeroed our state; restore unity gain
            _ = ma.ma_node_attach_output_bus(@ptrCast(node), 0, endpoint, 0);
            _ = ma.ma_node_attach_output_bus(@ptrCast(&self.group.engineNode), 0, @ptrCast(node), 0);
            self.compressor = node;
        } else if (!on and self.compressor != null) {
            _ = ma.ma_node_attach_output_bus(@ptrCast(&self.group.engineNode), 0, endpoint, 0);
            ma.ma_node_uninit(@ptrCast(self.compressor.?), null);
            self.driver.allocator.destroy(self.compressor.?);
            self.compressor = null;
        }
    }

    /// Route a sample's output through this bus instead of straight to the
    /// engine endpoint. Returns true on success.
    pub fn route(self: *MixBus, s: *Sample) bool {
        if (!s.is_initialized) return false;
        return ma.ma_node_attach_output_bus(
            @ptrCast(&s.sound.engineNode),
            0,
            @ptrCast(&self.group.engineNode),
            0,
        ) == ma.MA_SUCCESS;
    }
};

pub const SampleStatus = enum(u32) {
    free = 1, // SMP_FREE
    done = 2, // SMP_DONE
    playing = 4, // SMP_PLAYING
    stopped = 8, // SMP_STOPPED
    playing_but_released = 16, // SMP_PLAYINGBUTRELEASED
};

pub const DigitalDriver = struct {
    engine: ma.ma_engine,
    allocator: std.mem.Allocator,
    providers: std.ArrayListUnmanaged(*root.Provider),
    timers: std.ArrayListUnmanaged(*root.Timer),
    samples: std.ArrayListUnmanaged(*Sample),
    // v9 system-state stack: saved master-volume per push level.
    system_state_stack: std.ArrayListUnmanaged(f32) = .empty,
    // v9 bus mixer: submix groups samples can be routed to.
    buses: std.ArrayListUnmanaged(*MixBus) = .empty,
    // Per-mix callback (AILMIXERCB) invoked from the engine's process hook.
    mix_callback: ?*const fn (?*DigitalDriver) callconv(.winapi) void = null,
    samples_3d: std.ArrayListUnmanaged(*Sample3D) = .empty,
    rolloff_factor: f32 = 1.0,
    doppler_factor: f32 = 1.0,
    distance_factor: f32 = 1.0,
    room_type: i32 = 0,
    speaker_type: i32 = 0,
    // MSS v7 unified-API master-reverb / room state (stored; queried back).
    v7_master_reverb_decay: f32 = 0.0,
    v7_master_reverb_predelay: f32 = 0.0,
    v7_master_reverb_damping: f32 = 0.0,
    v7_master_reverb_dry: f32 = 1.0,
    // SDK genericdig.cpp inits reverb[0].master_wet = 1.0F (a NEUTRAL multiplier
    // for per-sample wet sends -- not added reverb, since samples default to
    // wet_level 0). Defaulting it to 0 would zero all sample reverb.
    v7_master_reverb_wet: f32 = 1.0,
    v7_room_type: i32 = 0,
    // DSP processor callbacks [input_stage, output_stage]. Stored for query
    // round-tripping; not invoked (miniaudio manages its own processing graph).
    driver_processors: [2]usize = .{ 0, 0 },
    // Filters opened against this driver (tracked for cleanup on driver close).
    filters: std.ArrayListUnmanaged(*root.Filter) = .empty,

    pub fn init(allocator: std.mem.Allocator, frequency: u32, bits: i32, channels: u32) !*DigitalDriver {
        _ = bits;
        log("DigitalDriver.init called: freq={d}, channels={d}\n", .{ frequency, channels });
        const self = try allocator.create(DigitalDriver);
        log("DigitalDriver.init: self={*}\n", .{@as(*anyopaque, self)});
        self.* = .{
            .engine = undefined,
            .allocator = allocator,
            .providers = .empty,
            .timers = .empty,
            .samples = .empty,
            .samples_3d = .empty,
        };
        var config = ma.ma_engine_config_init();
        if (@import("builtin").is_test) {
            config.noDevice = ma.MA_TRUE;
        }
        // Clamp to miniaudio's supported ranges; insane values (e.g. a 2-billion
        // channel count from a bogus AIL_quick_startup call) otherwise abort
        // inside ma_engine_init. MA_MAX_CHANNELS is 254; max standard rate 384k.
        config.sampleRate = if (frequency == 0) 44100 else @min(frequency, 384000);
        config.channels = if (channels == 0) 2 else @min(channels, 254);
        config.onProcess = &mixDispatch; // drives AIL_register_mix_callback
        config.pProcessUserData = self;
        const result = ma.ma_engine_init(&config, &self.engine);
        if (result != ma.MA_SUCCESS) {
            log("ma_engine_init failed: {d}\n", .{result});
            allocator.destroy(self);
            return error.EngineInitFailed;
        }
        if (self.engine.pDevice != null) {
            log("ma_engine_init success. Backend: {s}\n", .{ma.ma_get_backend_name(self.engine.pDevice.*.pContext.*.backend)});
        } else {
            log("ma_engine_init success. (No Device)\n", .{});
        }

        // MSS computes Doppler with SPEED_OF_SOUND = 0.355 m/ms (wavefile.cpp),
        // comparing it directly to the raw game-supplied velocities (distance_
        // factor / doppler_factor both default to 1). miniaudio defaults to
        // 343.3 m/s, so the SAME velocity would yield a ~1000x weaker pitch
        // shift. Match MSS's constant so Doppler is at the right scale (first
        // order it then equals MSS's c/(c+v); the OpenAL form diverges only
        // near the speed of sound, where both clamp).
        if (ma.ma_engine_get_listener_count(&self.engine) > 0) {
            ma.ma_spatializer_listener_set_speed_of_sound(&self.engine.listeners[0], mss_speed_of_sound);
        }

        root.last_digital_driver = self;
        root.registerDriver(self);
        return self;
    }

    /// Engine onProcess hook: fires once per mixed block on the audio thread.
    pub fn mixDispatch(user: ?*anyopaque, frames: [*c]f32, frame_count: u64) callconv(.c) void {
        _ = frames;
        _ = frame_count;
        const self: *DigitalDriver = @ptrCast(@alignCast(user orelse return));
        // Read on the audio thread; written on the app thread via
        // AIL_register_mix_callback. Atomic to avoid a torn/half-published pointer.
        if (@atomicLoad(?*const fn (?*DigitalDriver) callconv(.winapi) void, &self.mix_callback, .acquire)) |cb| cb(self);
    }

    /// Allocate a new mixer bus (a miniaudio sound group) samples can route to.
    pub fn allocateBus(self: *DigitalDriver) ?*MixBus {
        const bus = self.allocator.create(MixBus) catch return null;
        bus.* = .{ .group = undefined, .index = @intCast(self.buses.items.len), .driver = self };
        if (ma.ma_sound_group_init(&self.engine, 0, null, &bus.group) != ma.MA_SUCCESS) {
            self.allocator.destroy(bus);
            return null;
        }
        self.buses.append(self.allocator, bus) catch {
            ma.ma_sound_group_uninit(&bus.group);
            self.allocator.destroy(bus);
            return null;
        };
        return bus;
    }

    pub fn busAt(self: *DigitalDriver, index: i32) ?*MixBus {
        if (index < 0 or index >= self.buses.items.len) return null;
        return self.buses.items[@intCast(index)];
    }

    pub fn freeAllBusses(self: *DigitalDriver) void {
        for (self.buses.items) |bus| {
            bus.enableLimiter(false); // detach + free any effect nodes first
            bus.installCompressor(false);
            ma.ma_sound_group_uninit(&bus.group);
            self.allocator.destroy(bus);
        }
        self.buses.clearRetainingCapacity();
    }

    pub fn deinit(self: *DigitalDriver) void {
        if (root.last_digital_driver == self) root.last_digital_driver = null;
        root.unregisterDriver(self);
        self.freeAllBusses();
        self.buses.deinit(self.allocator);
        self.system_state_stack.deinit(self.allocator);
        for (self.providers.items) |p| {
            p.deinit();
        }
        self.providers.deinit(self.allocator);
        for (self.timers.items) |t| {
            t.deinit();
        }
        self.timers.deinit(self.allocator);
        // Free any filters that weren't explicitly closed by the game. Mark
        // driver_is_dead so Filter.deinit skips engine-graph touches (the
        // engine is about to be torn down) and skips updating this list.
        for (self.filters.items) |f| {
            f.driver_is_dead = true;
            f.deinit();
        }
        self.filters.deinit(self.allocator);
        // Tear down all samples before the engine (miniaudio requires this order).
        // Mark driver_is_dead so deinit() skips the swapRemove on these lists.
        for (self.samples.items) |s| {
            s.driver_is_dead = true;
            s.deinit();
        }
        self.samples.deinit(self.allocator);
        for (self.samples_3d.items) |s| {
            s.driver_is_dead = true;
            s.deinit();
        }
        self.samples_3d.deinit(self.allocator);
        ma.ma_engine_uninit(&self.engine);
        self.allocator.destroy(self);
    }

    pub fn loadAllAsi(self: *DigitalDriver, redist_dir: []const u8) void {
        const alloc = self.allocator;
        var d = fs_compat.openDir(io, redist_dir, .{ .iterate = true }) catch |err| {
            log("loadAllAsi: failed to open directory '{s}': {any}\n", .{ redist_dir, err });
            return;
        };
        defer d.close(io);
        var it = d.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const name = entry.name;
            if (!root.isPluginExtension(name)) continue;
            if (!root.isSafePluginFilename(name)) continue;
            const full_path = std.fs.path.join(alloc, &.{ redist_dir, name }) catch continue;
            defer alloc.free(full_path);
            const p = root.Provider.load(alloc, full_path) catch |err| {
                log("loadAllAsi: failed to load plugin '{s}': {any}\n", .{ name, err });
                continue;
            };
            self.providers.append(alloc, p) catch {
                p.deinit();
            };
        }
    }

    pub fn setMasterVolume(self: *DigitalDriver, volume: f32) void {
        log("DigitalDriver.setMasterVolume: f32={d}\n", .{volume});
        _ = ma.ma_engine_set_volume(&self.engine, volume);
    }

    pub fn getMasterVolume(self: *DigitalDriver) f32 {
        return ma.ma_engine_get_volume(&self.engine);
    }

    /// MSS scales the Doppler velocity by distance_factor * doppler_factor
    /// (wavefile.cpp: `velocity *= D3D->distance_factor * D3D->doppler_factor`).
    /// miniaudio's per-sound doppler factor multiplies the velocity the same
    /// way, so feeding it the product reproduces both knobs.
    pub fn effectiveDoppler(self: *const DigitalDriver) f32 {
        return self.distance_factor * self.doppler_factor;
    }

    pub fn getActiveSampleCount(self: *DigitalDriver) u32 {
        var count: u32 = 0;
        for (self.samples.items) |s| {
            if (s.status() == .playing) count += 1;
        }
        return count;
    }

    pub fn get3DActiveSampleCount(self: *DigitalDriver) u32 {
        var count: u32 = 0;
        for (self.samples_3d.items) |s| {
            if (s.status() == .playing) count += 1;
        }
        return count;
    }

    // MSS is left-handed (forward=+Z); miniaudio is right-handed (forward=-Z).
    // We negate Z crossing the miniaudio boundary so the spatializer reproduces
    // MSS geometry, while stored/returned values stay in MSS space. See the note
    // at Sample3D.setPosition.
    pub fn setListenerPosition(self: *DigitalDriver, x: f32, y: f32, z: f32) void {
        ma.ma_engine_listener_set_position(&self.engine, 0, x, y, -z);
    }

    pub fn setListenerVelocity(self: *DigitalDriver, x: f32, y: f32, z: f32) void {
        ma.ma_engine_listener_set_velocity(&self.engine, 0, x, y, -z);
    }

    pub fn setListenerDirection(self: *DigitalDriver, fx: f32, fy: f32, fz: f32) void {
        // SDK (m3d.cpp) normalizes the listener face on orientation set, so the
        // getter round-trips a unit vector regardless of the input magnitude.
        var v = [3]f32{ fx, fy, fz };
        normalize3(&v);
        ma.ma_engine_listener_set_direction(&self.engine, 0, v[0], v[1], -v[2]);
    }

    pub fn setListenerWorldUp(self: *DigitalDriver, ux: f32, uy: f32, uz: f32) void {
        var v = [3]f32{ ux, uy, uz }; // SDK normalizes the listener up vector too
        normalize3(&v);
        ma.ma_engine_listener_set_world_up(&self.engine, 0, v[0], v[1], -v[2]);
    }

    pub fn getListenerPosition(self: *DigitalDriver) ma.ma_vec3f {
        var v = ma.ma_engine_listener_get_position(&self.engine, 0);
        v.z = -v.z;
        return v;
    }

    pub fn getListenerVelocity(self: *DigitalDriver) ma.ma_vec3f {
        var v = ma.ma_engine_listener_get_velocity(&self.engine, 0);
        v.z = -v.z;
        return v;
    }

    pub fn getListenerDirection(self: *DigitalDriver) ma.ma_vec3f {
        var v = ma.ma_engine_listener_get_direction(&self.engine, 0);
        v.z = -v.z;
        return v;
    }

    pub fn getListenerWorldUp(self: *DigitalDriver) ma.ma_vec3f {
        var v = ma.ma_engine_listener_get_world_up(&self.engine, 0);
        v.z = -v.z;
        return v;
    }

    pub fn getDevice(self: *DigitalDriver) ?*ma.ma_device {
        return ma.ma_engine_get_device(&self.engine);
    }

    pub fn getSampleRate(self: *DigitalDriver) u32 {
        return ma.ma_engine_get_sample_rate(&self.engine);
    }

    pub fn getChannels(self: *DigitalDriver) u32 {
        return ma.ma_engine_get_channels(&self.engine);
    }
};

pub const SamplePcmFormat = struct {
    channels: u16,
    bits: u16,
};

/// Source bytes-per-frame (channels * bits/8) parsed from a WAV/RIFF header,
/// or null if the data is not a WAV we can read a `fmt ` chunk from. Walks the
/// chunk list like AIL_WAV_info; used to give AIL_sample_granularity the SDK's
/// source-format basis instead of miniaudio's decoded frame size.
fn wavSourceBytesPerFrame(data: []const u8) ?u32 {
    if (data.len < 44) return null;
    if (!std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WAVE")) return null;
    var off: usize = 12;
    while (off + 8 <= data.len) {
        const tag = data[off .. off + 4];
        const csize = std.mem.readInt(u32, data[off + 4 .. off + 8][0..4], .little);
        off += 8;
        if (std.mem.eql(u8, tag, "fmt ") and csize >= 16 and off + 16 <= data.len) {
            const channels = std.mem.readInt(u16, data[off + 2 .. off + 4][0..2], .little);
            const bits = std.mem.readInt(u16, data[off + 14 .. off + 16][0..2], .little);
            if (channels == 0 or bits == 0) return null;
            return @as(u32, channels) * (@as(u32, bits) / 8);
        }
        const next = off +| csize +| (csize & 1);
        if (next <= off) return null;
        off = next;
    }
    return null;
}

pub const Sample = struct {
    driver: *DigitalDriver,
    sound: ma.ma_sound,
    decoder: ?*ma.ma_decoder = null,
    is_initialized: bool = false,
    is_done: bool = false, // true when all loops exhausted (avoids false .done from ma_sound_at_end)
    is_paused: bool = false, // MSS: paused samples still report SMP_PLAYING (4)
    // The SDK inits a sample to SMP_DONE and only reports SMP_STOPPED after an
    // explicit AIL_stop_sample. This flag distinguishes "never played / done"
    // (SMP_DONE) from "explicitly stopped" (SMP_STOPPED).
    was_stopped: bool = false,
    // Whether the sample has ever been started. The Quick API uses this to tell
    // QSTAT_LOADED (loaded, never played) from QSTAT_DONE (played and finished),
    // since both map to SMP_DONE at the sample level.
    has_played: bool = false,
    volume: f32 = 1.0,
    original_volume: i32 = 127,
    pan: f32 = 0.0, // value handed to miniaudio's balance panner
    original_pan: i32 = 64, // the 0..127 pan the app set (64 = center), for the getter
    // Exact float volume/pan (0..1) the app set via the F32 API (SDK keeps
    // save_volume/save_pan as floats). The F32 getters return these so the
    // round-trip is exact, not quantized through the i32 0..127 fields.
    save_vol_f: f32 = 1.0,
    save_pan_f: f32 = 0.5,
    // 5.1 volume/pan params the app set (AIL_set_sample_51_volume_pan), returned
    // verbatim by its getter. Defaults per wavefile.cpp (save_fb_pan/center/low).
    v51_fb_pan: f32 = 0.5,
    v51_center_level: f32 = 1.0,
    v51_sub_level: f32 = 1.0,
    // MSS low-pass cutoff is normalized 0..1 (1.0 = fully open / no filtering),
    // not Hz. Stored so the getter round-trips even with no filter attached;
    // applied to the attached filter as cutoff*Nyquist Hz. Default 1.0 matches
    // MSS (S->low_pass_cutoff defaults to 1.0F, wavefile.cpp).
    low_pass_cutoff_norm: f32 = 1.0,
    pitch: f32 = 1.0,
    target_rate: ?f32 = null,
    loop_count: i32 = 1,
    loops_remaining: i32 = 1,
    loop_start_frame: u64 = 0,
    loop_end_frame: u64 = 0, // 0 = play to end of file
    owned_buffer: ?[]u8 = null,
    driver_is_dead: bool = false,
    eos_callback: usize = 0,
    eob_callback: usize = 0,
    sob_callback: usize = 0,
    pcm_format: ?SamplePcmFormat = null,
    // AILSOUNDINFO channel_mask: ~0U means "default mapping" (standard mono/
    // stereo WAVs); an explicit speaker mask only comes from WAVEFORMATEXTENSIBLE
    // or AIL_set_sample_info. AIL_sample_channel_count returns this verbatim.
    channel_mask: u32 = ~@as(u32, 0),
    // Streaming double-buffer ring count set via AIL_set_sample_buffer_count
    // Ring-buffer count (valid 2..8). SDK AIL_init_sample sets this to 2 via
    // AIL_set_sample_buffer_count(S,2), so 2 is the default for any live sample.
    n_buffers: i32 = 2,
    // Ring head: the slot AIL_load_sample_buffer(MSS_BUFFER_HEAD) resolves to.
    stream_head: i32 = 0,
    // Which buffer ID was last loaded via AIL_load_sample_buffer (for EOB callback parameter)
    last_loaded_buffer: i32 = 0,
    user_data: [8]u32 = [_]u32{0} ** 8,
    // Bounded memory context for streaming formats loaded from raw pointers (freed on deinit)
    bounded_mem_ctx: ?*BoundedMemCtx = null,
    // Filter attached to this sample (set by AIL_set_sample_filter)
    attached_filter: ?*root.Filter = null,
    // DSP processor callbacks [input_stage, output_stage]. Stored but not
    // actively invoked (miniaudio manages its own processing graph).
    sample_processors: [2]usize = .{ 0, 0 },
    // ADPCM block size hint (stored for round-tripping; miniaudio handles decoding).
    adpcm_block_size: u32 = 0,
    // Double-buffered streaming (MSS AIL_load_sample_buffer ping-pong). When
    // active, `sound` is driven by `stream_src` instead of a decoder.
    stream_src: StreamSource = undefined,
    stream_active: bool = false,
    cached_length_frames: u64 = 0,
    // Source-format bytes-per-frame parsed from the loaded WAV header (channels *
    // bits/8). 0 = unknown (non-WAV / raw): AIL_sample_granularity then falls back
    // to the decoder-output frame size. The SDK's SS_granularity is the SOURCE
    // sample format, not whatever miniaudio decodes to, so this keeps granularity
    // stable and faithful (e.g. mono-8 -> 1, not the decoder's promoted size).
    src_bpf: u32 = 0,
    reverb_node: ?*ma.ma_delay_node = null,
    reverb_room_type: f32 = 0.0,
    reverb_level: f32 = 0.0, // wet level
    reverb_dry_level: f32 = 1.0, // dry level (independent of wet; SDK default 1.0)
    reverb_reflect_time: f32 = 0.0,
    // MSS v7 unified-API attenuation hints (stored; queried back).
    v7_obstruction: f32 = 0.0,
    v7_occlusion: f32 = 0.0,
    v7_exclusion: f32 = 0.0,
    v7_rate_factor: f32 = 1.0,
    // v7 unified-API 3D orientation (HSAMPLE). The SDK (m3d.cpp) normalizes both
    // face and up on set and returns the stored vectors; default face = +X,
    // up = +Y (wavefile.cpp). Stored here so the getter round-trips faithfully.
    s3d_face: [3]f32 = .{ 1, 0, 0 },
    s3d_up: [3]f32 = .{ 0, 1, 0 },
    // HSAMPLE.is_3D: set TRUE when a 3D position/segment is specified, cleared on
    // re-init. AIL_sample_3D_position and AIL_set_sample_is_3D return it (S32).
    is_3D: i32 = 0,
    // HSAMPLE.S3D.auto_3D_atten: stored by AIL_set_sample_3D_distances, returned
    // by AIL_sample_3D_distances.
    s3d_auto_atten: i32 = 0,
    // HSAMPLE.S3D.max_dist / min_dist: the source of truth for the 3D distance
    // getter (the SDK stores these in the S3D struct regardless of whether the
    // voice is initialized; miniaudio's get_*_distance is only valid once the
    // ma_sound exists, so a field round-trips uninitialized samples too).
    // Defaults match wavefile.cpp AIL_init_sample: max 200.0, min 1.0.
    s3d_max_dist: f32 = 200.0,
    s3d_min_dist: f32 = 1.0,
    // HSAMPLE.S3D.position / velocity in MSS (left-handed +Z) space -- the source
    // of truth for the AIL_sample_3D_position/velocity getters (the SDK returns
    // S3D.position/velocity verbatim regardless of init state; the ma_sound copy
    // carries the negated Z for miniaudio's right-handed space).
    s3d_pos: [3]f32 = .{ 0, 0, 0 },
    s3d_vel: [3]f32 = .{ 0, 0, 0 },
    // HSAMPLE.S3D cone, in degrees / linear gain -- the source of truth for the
    // AIL_sample_3D_cone getter (the SDK stores DEGS_TO_DIAMS internally and the
    // getter returns DIAMS_TO_DEGS, i.e. the original degrees; outer_volume is
    // stored verbatim). Defaults match wavefile.cpp AIL_init_sample: 360/360/1.0.
    s3d_cone_inner_deg: f32 = 360.0,
    s3d_cone_outer_deg: f32 = 360.0,
    s3d_cone_outer_vol: f32 = 1.0,
    // HSAMPLE.S3D.falloff_function: per-sample 3D falloff callback. Stored and
    // returned by AIL_register_falloff_function_callback (null = engine default).
    falloff_cb: ?*anyopaque = null,
    // v9 sample attributes (synchronized control / buses / system levels).
    v9_id: i32 = 0,
    v9_bus: i32 = 0,
    v9_level_mask: u8 = 0xFF,
    v9_spread: f32 = 0.0,
    // S3D falloff graphs (volume, exclusion, lowpass, spread). Stored verbatim
    // per AIL_set_sample_3D_*_falloff; count 0 = no graph. Mirrors HSAMPLE.S3D.
    falloff_count: [4]u8 = [_]u8{0} ** 4,
    falloff_graph: [4][max_falloff_points]FalloffGraphPoint = undefined,
    v9_schedule_time: u64 = 0,
    v9_playback_delay: i32 = 0, // ms before playback starts (AIL_set_sample_playback_delay)
    // 5.1 per-speaker volume levels: FL, FR, FC, LFE, BL, BR.
    v51_levels: [6]f32 = [_]f32{1.0} ** 6,
    // Per-driver-channel speaker scale factors (HSAMPLE.speaker_levels), indexed
    // by output channel 0..MAX_SPEAKERS-1. Set/read by AIL_*_sample_speaker_scale_factors.
    speaker_levels: [9]f32 = [_]f32{1.0} ** 9,
    // user_channel_levels[dest_chan][src_chan] mixing matrix (wavefile.cpp). Set
    // via AIL_set_sample_channel_levels; read via AIL_sample_channel_levels. When
    // not explicitly set, the getter synthesizes the default mono/stereo routing.
    user_channel_levels: [9][9]f32 = [_][9]f32{[_]f32{0} ** 9} ** 9,
    user_channel_levels_set: bool = false,

    /// Fire the app's EOB then EOS callback (AILSAMPLECB: void callback(HSAMPLE S),
    /// single arg; the app queries buffer state separately). EOB first so
    /// double-buffer streaming games can refill before seeing end-of-sample.
    fn fireEobThenEosCallbacks(self: *Sample) void {
        if (self.eob_callback != 0) {
            const cb: *const fn (?*anyopaque) callconv(.winapi) void = @ptrFromInt(self.eob_callback);
            cb(@ptrCast(self));
        }
        if (self.eos_callback != 0) {
            const cb: *const fn (?*anyopaque) callconv(.winapi) void = @ptrFromInt(self.eos_callback);
            cb(@ptrCast(self));
        }
    }

    fn eosCallbackBridge(pUserData: ?*anyopaque, pSound: ?*ma.ma_sound) callconv(.c) void {
        _ = pSound;
        const self: *Sample = @ptrCast(@alignCast(pUserData.?));
        // All looping is handled manually here (miniaudio looping is disabled).
        // loops_remaining <= 0: infinite (0 = documented infinite, negative = treated same).
        if (self.loops_remaining <= 0) {
            // Infinite loop - restart from loop start
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, self.loop_start_frame);
            _ = ma.ma_sound_start(&self.sound);
            return;
        } else if (self.loops_remaining > 1) {
            self.loops_remaining -= 1;
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, self.loop_start_frame);
            _ = ma.ma_sound_start(&self.sound);
            return;
        }
        // loops_remaining == 1: last iteration done
        self.is_done = true;
        self.fireEobThenEosCallbacks();
    }

    pub fn init(driver: *DigitalDriver) !*Sample {
        const self = try driver.allocator.create(Sample);
        errdefer driver.allocator.destroy(self);
        self.* = .{
            .driver = driver,
            .sound = undefined,
            .decoder = null,
            .owned_buffer = null,
        };
        try driver.samples.append(driver.allocator, self);
        log("Sample.init: s={*}\n", .{self});
        return self;
    }

    pub fn deinit(self: *Sample) void {
        log("Sample.deinit: s={*}\n", .{self});
        if (!self.driver_is_dead) {
            for (self.driver.samples.items, 0..) |s, i| {
                if (s == self) {
                    _ = self.driver.samples.swapRemove(i);
                    break;
                }
            }
        }
        // Detach from any attached Filter first — Filter's attached_samples
        // list would otherwise hold a dangling pointer after we're freed.
        if (self.attached_filter) |f| {
            f.detachSample(self);
        }
        self.removeReverb();
        self.cleanupPlaybackState();
        self.driver.allocator.destroy(self);
    }

    fn cleanupPlaybackState(self: *Sample) void {
        if (self.is_initialized) {
            ma.ma_sound_uninit(&self.sound);
            self.is_initialized = false;
        }
        if (self.stream_active) {
            self.stream_src.deinit();
            self.stream_active = false;
        }
        if (self.decoder) |d| {
            _ = ma.ma_decoder_uninit(d);
            self.driver.allocator.destroy(d);
            self.decoder = null;
        }
        if (self.bounded_mem_ctx) |ctx| {
            self.driver.allocator.destroy(ctx);
            self.bounded_mem_ctx = null;
        }
        if (self.owned_buffer) |buf| {
            self.driver.allocator.free(buf);
            self.owned_buffer = null;
        }
    }

    /// Shared post-init tail of every decoder-backed Sample load: adopt the
    /// decoder, cache the length, apply stored rate/volume/pan state, register
    /// the EOS bridge, and re-apply any loop range. No fallible step here;
    /// callers assign their ownership fields (owned buffer/bounded ctx) first.
    fn finishDecoderLoad(self: *Sample, decoder: *ma.ma_decoder) void {
        self.decoder = decoder;
        self.is_initialized = true;
        self.is_done = false;
        self.is_paused = false;
        _ = ma.ma_sound_get_length_in_pcm_frames(&self.sound, &self.cached_length_frames);

        if (self.target_rate) |tr| {
            const native_rate = @as(f32, @floatFromInt(decoder.outputSampleRate));
            if (native_rate > 0) self.pitch = tr / native_rate;
        }

        ma.ma_sound_set_volume(&self.sound, self.volume);
        ma.ma_sound_set_pan(&self.sound, self.pan);
        ma.ma_sound_set_pitch(&self.sound, self.pitch);
        // Disable miniaudio looping on load; start() re-enables it for infinite
        // loops (count == 0). Finite loop counting is handled by the EOS bridge.
        ma.ma_sound_set_looping(&self.sound, 0);
        _ = ma.ma_sound_set_end_callback(&self.sound, Sample.eosCallbackBridge, self);
        if (self.loop_end_frame > 0) {
            _ = ma.ma_data_source_set_range_in_pcm_frames(decoder, 0, self.loop_end_frame);
        }
    }

    pub fn loadFromOwnedMemory(self: *Sample, data: []u8) !void {
        self.cleanupPlaybackState();

        const decoder = try self.driver.allocator.create(ma.ma_decoder);
        errdefer self.driver.allocator.destroy(decoder);
        var result = ma.ma_decoder_init_memory(data.ptr, data.len, null, decoder);
        if (result != ma.MA_SUCCESS) return error.DecoderInitFailed;

        result = ma.ma_sound_init_from_data_source(&self.driver.engine, @ptrCast(decoder), ma.MA_SOUND_FLAG_NO_SPATIALIZATION, null, &self.sound);
        if (result != ma.MA_SUCCESS) {
            _ = ma.ma_decoder_uninit(decoder);
            return error.SampleLoadFailed;
        }
        // Take ownership only after all fallible steps succeed, so callers' catch
        // paths can safely free the buffer on failure without causing a double-free
        // through a later Sample.deinit.
        self.owned_buffer = data;
        self.finishDecoderLoad(decoder);

        log("Sample.loadFromOwnedMemory success: s={*}, vol={d}, pan={d}, pitch={d}, loop={d}\n", .{ self, self.volume, self.pan, self.pitch, self.loop_count });
    }

    /// Context for bounded memory read/seek callbacks used by ma_decoder_init.
    /// Allows miniaudio to read from a raw pointer without creating an unsafe
    /// Zig slice that may extend past the real allocation.
    pub const BoundedMemCtx = struct {
        base: [*]const u8,
        size: usize,
        cursor: usize,
    };

    pub fn boundedMemRead(pDecoder: [*c]ma.ma_decoder, pBufferOut: ?*anyopaque, bytesToRead: usize, pBytesRead: ?*usize) callconv(.c) ma.ma_result {
        const user_data = pDecoder.*.pUserData orelse {
            if (pBytesRead) |br| br.* = 0;
            return ma.MA_INVALID_ARGS;
        };
        const ctx: *BoundedMemCtx = @ptrCast(@alignCast(user_data));
        if (ctx.cursor >= ctx.size) {
            if (pBytesRead) |br| br.* = 0;
            return ma.MA_AT_END;
        }
        const available = ctx.size - ctx.cursor;
        const to_read = @min(bytesToRead, available);
        const dst: [*]u8 = @ptrCast(pBufferOut.?);
        @memcpy(dst[0..to_read], ctx.base[ctx.cursor..][0..to_read]);
        ctx.cursor += to_read;
        if (pBytesRead) |br| br.* = to_read;
        return if (to_read < bytesToRead) ma.MA_AT_END else ma.MA_SUCCESS;
    }

    pub fn boundedMemSeek(pDecoder: [*c]ma.ma_decoder, byteOffset: ma.ma_int64, origin: ma.ma_seek_origin) callconv(.c) ma.ma_result {
        const user_data = pDecoder.*.pUserData orelse return ma.MA_INVALID_ARGS;
        const ctx: *BoundedMemCtx = @ptrCast(@alignCast(user_data));
        const new_pos: i64 = switch (origin) {
            ma.ma_seek_origin_start => byteOffset,
            ma.ma_seek_origin_current => @as(i64, @intCast(ctx.cursor)) + byteOffset,
            ma.ma_seek_origin_end => @as(i64, @intCast(ctx.size)) + byteOffset,
            else => return ma.MA_INVALID_ARGS,
        };
        if (new_pos < 0 or new_pos > @as(i64, @intCast(ctx.size))) return ma.MA_INVALID_ARGS;
        ctx.cursor = @intCast(new_pos);
        return ma.MA_SUCCESS;
    }

    pub fn loadFromUnownedMemoryUnknownSize(self: *Sample, data_ptr: [*]const u8) !void {
        const detected = root.detectAudioSize(data_ptr);
        if (detected == 0) {
            // Format unrecognized. With only a bare pointer there is no size to
            // bound reads by, and miniaudio's format probing would over-read any
            // buffer smaller than its detection window. Refuse — matching MSS,
            // which fails set_sample_file on data it can't identify.
            log("Sample.loadFromUnownedMemoryUnknownSize: unrecognized format, refusing\n", .{});
            return error.UnsupportedAudioFormat;
        }
        if (detected != root.streaming_sentinel_size) {
            log("Sample.loadFromUnownedMemoryUnknownSize detected size: {d}\n", .{detected});
            try self.loadFromMemory(data_ptr[0..detected], false);
        } else {
            // Streaming formats (OGG/MP3/FLAC): the sentinel is not a real
            // length, so a fake slice that large could run past the caller's
            // allocation. Read through bounded callbacks instead (mirrors
            // Sample3D.loadFromUnownedPointer).
            try self.loadFromBoundedPointer(data_ptr, root.streaming_sentinel_size);
        }
    }

    /// Load audio from a raw pointer using custom ma_decoder read/seek callbacks.
    /// This avoids creating a Zig slice of unknown length — miniaudio reads through
    /// callbacks that bounds-check against `max_size`, returning EOF if exceeded.
    pub fn loadFromBoundedPointer(self: *Sample, data_ptr: [*]const u8, max_size: usize) !void {
        self.cleanupPlaybackState();
        log("Sample.loadFromBoundedPointer mounting bounded stream (max_size={d})\n", .{max_size});

        // Allocate the bounded context alongside the decoder so it persists for playback
        const ctx = try self.driver.allocator.create(BoundedMemCtx);
        errdefer self.driver.allocator.destroy(ctx);
        ctx.* = .{ .base = data_ptr, .size = max_size, .cursor = 0 };

        const decoder = try self.driver.allocator.create(ma.ma_decoder);
        errdefer self.driver.allocator.destroy(decoder);
        var result = ma.ma_decoder_init(boundedMemRead, boundedMemSeek, @ptrCast(ctx), null, decoder);
        if (result != ma.MA_SUCCESS) {
            // ctx/decoder are freed by their errdefers on this error return.
            return error.DecoderInitFailed;
        }

        result = ma.ma_sound_init_from_data_source(&self.driver.engine, @ptrCast(decoder), ma.MA_SOUND_FLAG_NO_SPATIALIZATION, null, &self.sound);
        if (result != ma.MA_SUCCESS) {
            _ = ma.ma_decoder_uninit(decoder);
            // decoder allocation and ctx are freed by their errdefers.
            return error.SampleLoadFailed;
        }
        self.bounded_mem_ctx = ctx;
        // Bounded mounts serve non-WAV streaming formats only; clear any
        // source-format hint left by a previous load (loadFromMemory would
        // recompute it; there is no WAV header to parse here).
        self.src_bpf = 0;
        self.finishDecoderLoad(decoder);

        log("Sample.loadFromBoundedPointer success: s={*}, vol={d}, pan={d}, pitch={d}, loop={d}\n", .{ self, self.volume, self.pan, self.pitch, self.loop_count });
    }

    pub fn loadFromMemory(self: *Sample, data: []const u8, copy_data: bool) !void {
        self.cleanupPlaybackState();
        log("Sample.loadFromMemory mounting buffer of size: {d}\n", .{data.len});

        var internal_data = data;
        var owned_copy: ?[]u8 = null;
        if (copy_data) {
            owned_copy = try self.driver.allocator.dupe(u8, data);
            internal_data = owned_copy.?;
        }
        // Free the copy if any subsequent step fails — but DON'T assign
        // self.owned_buffer until the whole init succeeds, or we risk a
        // double-free when the caller retries or deinit runs.
        errdefer if (owned_copy) |c| self.driver.allocator.free(c);

        const decoder = try self.driver.allocator.create(ma.ma_decoder);
        errdefer self.driver.allocator.destroy(decoder);
        var result = ma.ma_decoder_init_memory(internal_data.ptr, internal_data.len, null, decoder);
        if (result != ma.MA_SUCCESS) return error.DecoderInitFailed;

        result = ma.ma_sound_init_from_data_source(&self.driver.engine, @ptrCast(decoder), ma.MA_SOUND_FLAG_NO_SPATIALIZATION, null, &self.sound);
        if (result != ma.MA_SUCCESS) {
            _ = ma.ma_decoder_uninit(decoder);
            return error.SampleLoadFailed;
        }
        self.owned_buffer = owned_copy;
        self.src_bpf = wavSourceBytesPerFrame(internal_data) orelse 0;
        self.finishDecoderLoad(decoder);

        log("Sample.loadFromMemory success: s={*}, vol={d}, pan={d}, pitch={d}, loop={d}\n", .{ self, self.volume, self.pan, self.pitch, self.loop_count });
    }

    pub fn loadFromFile(self: *Sample, path: []const u8) !void {
        // Read file into memory so owned_buffer is set (required for AIL_quick_copy)
        const file = fs_compat.openFile(io, path, .{}) catch return error.FileNotFound;
        defer file.close(io);
        const file_len = file.length(io) catch return error.FileNotFound;
        if (file_len == 0) return error.FileNotFound;
        const size: usize = @intCast(file_len);
        const buf = try self.driver.allocator.alloc(u8, size);
        errdefer self.driver.allocator.free(buf);
        const n = file.readPositionalAll(io, buf, 0) catch return error.ReadFailed;
        // A short read means the file shrank or became unreadable mid-load; the
        // truncated image would decode as garbage (or fail confusingly inside
        // miniaudio), so refuse it like readWholeFile does.
        if (n < size) return error.ReadFailed;
        // loadFromOwnedMemory takes ownership of buf directly, avoiding a redundant copy
        try self.loadFromOwnedMemory(buf);
    }

    pub fn load(self: *Sample, data: *anyopaque, size: i32) !void {
        const raw: [*]const u8 = @ptrCast(data);
        if (size > 0) {
            try self.loadFromMemory(raw[0..@intCast(size)], false);
        } else {
            // Size unknown — detect from header or use bounded pointer for safety
            try self.loadFromUnownedMemoryUnknownSize(raw);
        }
    }

    pub fn setAddress(self: *Sample, data: *anyopaque, size: u32) !void {
        const raw: []const u8 = @as([*]const u8, @ptrCast(data))[0..@intCast(size)];
        if (self.pcm_format) |fmt| {
            const rate: u32 = if (self.target_rate) |r| root.satU32(r) else 22050;
            const wav = try buildWavFromPcm(self.driver.allocator, raw, fmt.channels, rate, fmt.bits);
            errdefer self.driver.allocator.free(wav);
            try self.loadFromOwnedMemory(wav);
        } else {
            try self.loadFromMemory(raw, false);
        }
    }

    /// DIG_F_MONO_8=0, DIG_F_MONO_16=1, DIG_F_STEREO_8=2, DIG_F_STEREO_16=3
    pub fn setType(self: *Sample, format: u32, flags: u32) void {
        _ = flags;
        const channels: u16 = if (format == 0 or format == 1) 1 else 2;
        const bits: u16 = if (format == 0 or format == 2) 8 else 16;
        self.pcm_format = .{ .channels = channels, .bits = bits };
    }

    /// Bridge a StreamSource buffer-drain into the sample's registered EOB
    /// callback. `ctx` is the owning Sample. Runs outside the stream lock.
    fn streamEobBridge(ctx: ?*anyopaque, buf_index: i32, buf_len: u32, buf_addr: ?*anyopaque) void {
        const self: *Sample = @ptrCast(@alignCast(ctx.?));
        self.last_loaded_buffer = buf_index;
        _ = buf_len;
        _ = buf_addr;
        if (self.eob_callback != 0) {
            const cb: *const fn (?*anyopaque) callconv(.winapi) void = @ptrFromInt(self.eob_callback);
            cb(@ptrCast(self));
        }
    }

    /// Feed one buffer into the MSS double-buffer stream (zero-copy: the app
    /// retains ownership until its EOB fires). Lazily builds the streaming
    /// `ma_sound` on first call, using the format from `AIL_set_sample_type`.
    /// A zero `len` submits an end-of-stream marker.
    pub fn loadStreamBuffer(self: *Sample, index: usize, data: *anyopaque, len: u32) !void {
        if (!self.stream_active) {
            // Tear down any prior decoder-based playback before switching modes.
            self.cleanupPlaybackState();
            const fmt = self.pcm_format orelse SamplePcmFormat{ .channels = 2, .bits = 16 };
            const rate: u32 = if (self.target_rate) |r| root.satU32(r) else 22050;
            try self.stream_src.init(fmt.bits, fmt.channels, rate, streamEobBridge, self);
            errdefer self.stream_src.deinit();
            // Size the transport's ring to the configured buffer count so every
            // slot AIL_load_sample_buffer accepts is actually storable.
            self.stream_src.slot_count =
                @intCast(@min(@max(self.n_buffers, 2), StreamSource.max_slots));

            const res = ma.ma_sound_init_from_data_source(&self.driver.engine, @ptrCast(&self.stream_src.base), ma.MA_SOUND_FLAG_NO_SPATIALIZATION, null, &self.sound);
            if (res != ma.MA_SUCCESS) return error.SampleLoadFailed;
            self.stream_active = true;
            self.is_initialized = true;
            self.is_done = false;
            ma.ma_sound_set_volume(&self.sound, self.volume);
            ma.ma_sound_set_pan(&self.sound, self.pan);
            ma.ma_sound_set_pitch(&self.sound, self.pitch);
            ma.ma_sound_set_looping(&self.sound, 0);
            _ = ma.ma_sound_set_end_callback(&self.sound, Sample.eosCallbackBridge, self);
        }
        self.stream_src.loadBuffer(index, data, @intCast(len));
    }

    /// Index of a stream buffer slot free to fill (0/1), or -1 if both are full.
    pub fn streamBufferReady(self: *Sample) i32 {
        if (!self.stream_active) return -1;
        return self.stream_src.bufferReady();
    }

    pub fn reset(self: *Sample) void {
        self.removeReverb();
        if (self.is_initialized) _ = ma.ma_sound_stop(&self.sound);
        self.cleanupPlaybackState();
        self.volume = 1.0;
        self.original_volume = 127;
        self.save_vol_f = 1.0;
        self.pan = 0.0;
        self.original_pan = 64;
        self.save_pan_f = 0.5;
        self.pitch = 1.0;
        self.target_rate = null;
        self.loop_count = 1;
        self.loops_remaining = 1;
        self.loop_start_frame = 0;
        self.loop_end_frame = 0;
        self.is_done = false;
        self.is_paused = false;
        // Re-init returns the sample to the fresh SMP_DONE / never-played state.
        self.was_stopped = false;
        self.has_played = false;
        self.eos_callback = 0;
        self.eob_callback = 0;
        self.sob_callback = 0;
        self.pcm_format = null;
        self.channel_mask = ~@as(u32, 0);
        self.n_buffers = 2; // AIL_init_sample sets the ring count to 2 (mssdig.cpp)
        self.stream_head = 0;
        self.speaker_levels = [_]f32{1.0} ** 9;
        self.user_channel_levels_set = false;
        self.falloff_count = [_]u8{0} ** 4;
        self.s3d_face = .{ 1, 0, 0 };
        self.s3d_up = .{ 0, 1, 0 };
        self.is_3D = 0; // AIL_init_sample clears 3D state (mssdig.cpp)
        self.s3d_auto_atten = 0;
        self.s3d_max_dist = 200.0; // wavefile.cpp AIL_init_sample defaults
        self.s3d_min_dist = 1.0;
        self.s3d_pos = .{ 0, 0, 0 };
        self.s3d_vel = .{ 0, 0, 0 };
        self.s3d_cone_inner_deg = 360.0; // wavefile.cpp AIL_init_sample defaults
        self.s3d_cone_outer_deg = 360.0;
        self.s3d_cone_outer_vol = 1.0;
        self.falloff_cb = null;
        self.last_loaded_buffer = 0;
        self.user_data = [_]u32{0} ** 8;
        // SDK wavefile.cpp AIL_init_sample also resets the level / reverb / filter
        // / occlusion state of a reused handle to its defaults:
        //   set_sample_volume_levels(1,1); low_pass_cutoff[*]=1; sys_level=1;
        //   dry_level=1; wet_level=0; exclusion=obstruction=occlusion=0.
        self.v51_levels = [_]f32{1.0} ** 6; // volume_levels(1,1) -> front/back 1.0
        self.v51_fb_pan = 0.5;
        self.v51_center_level = 1.0;
        self.v51_sub_level = 1.0;
        self.low_pass_cutoff_norm = 1.0; // fully open (no filtering)
        self.reverb_dry_level = 1.0;
        self.reverb_level = 0.0; // wet
        self.reverb_room_type = 0.0;
        self.v7_obstruction = 0.0;
        self.v7_occlusion = 0.0;
        self.v7_exclusion = 0.0;
        // NB: src_bpf is a property of the loaded source data, not a parameter --
        // AIL_init_sample does not reload, so it is left intact (recomputed only
        // on the next load).
        // SDK sets adpcm.blocksize = 256 on init; our 0 sentinel means "derive
        // granularity from bytes-per-frame" (the right default for a fresh/PCM
        // sample). Clearing it prevents a reused ADPCM handle from reporting a
        // stale block size via AIL_sample_granularity.
        self.adpcm_block_size = 0;
    }

    /// Store an S3D falloff graph (AIL_set_sample_3D_*_falloff). Mirrors the SDK:
    /// pointcount above MILES_MAX_FALLOFF_GRAPH_POINTS is rejected (no change);
    /// 0 clears the graph; otherwise the points are copied in verbatim.
    pub fn setFalloff(self: *Sample, kind: FalloffKind, graph: ?[*]const FalloffGraphPoint, pointcount: i32) void {
        if (pointcount < 0 or pointcount > max_falloff_points) return;
        const idx = @intFromEnum(kind);
        const n: u8 = @intCast(pointcount);
        self.falloff_count[idx] = n;
        if (n > 0) {
            const pts = graph orelse {
                self.falloff_count[idx] = 0; // null graph with a positive count = no graph
                return;
            };
            @memcpy(self.falloff_graph[idx][0..n], pts[0..n]);
        }
    }

    /// Set the unified-API (HSAMPLE) 3D orientation. Normalizes face and up like
    /// the SDK and stores them; also pushes the (z-negated) face direction to
    /// miniaudio for cone attenuation. The up vector has no miniaudio analogue
    /// for a sound, but is retained so the getter round-trips faithfully.
    pub fn setOrientation(self: *Sample, fx: f32, fy: f32, fz: f32, ux: f32, uy: f32, uz: f32) void {
        self.s3d_face = .{ fx, fy, fz };
        self.s3d_up = .{ ux, uy, uz };
        normalize3(&self.s3d_face);
        normalize3(&self.s3d_up);
        if (self.is_initialized) {
            ma.ma_sound_set_direction(&self.sound, self.s3d_face[0], self.s3d_face[1], -self.s3d_face[2]);
        }
    }

    pub fn start(self: *Sample) void {
        log("Sample.start: s={*}\n", .{self});
        self.loops_remaining = self.loop_count;
        self.is_done = false;
        self.is_paused = false;
        self.was_stopped = false;
        self.has_played = true;
        if (self.is_initialized) {
            applyLoopCount(&self.sound, self.loop_count);
            // SDK wavefile.cpp AIL_API_start_sample rewinds to the beginning
            // (buf[tail].pos = 0) before playing -- it does NOT resume from the
            // current position. Continuing from where a sample was stopped is
            // AIL_resume_sample's role (Sample.resumePlayback).
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, 0);

            const res = ma.ma_sound_start(&self.sound);
            log("Sample.start: ma_sound_start returned {d}\n", .{res});
        }
        if (self.sob_callback != 0) {
            const cb: *const fn (?*anyopaque) callconv(.winapi) void = @ptrFromInt(self.sob_callback);
            cb(@ptrCast(self));
        }
    }

    pub fn stop(self: *Sample) void {
        log("Sample.stop: s={*}\n", .{self});
        // SDK wavefile.cpp AIL_API_stop_sample: no-op unless the sample is
        // currently SMP_PLAYING -- a DONE / STOPPED / never-started sample keeps
        // its status. Only a playing sample transitions to SMP_STOPPED.
        if (self.status() != .playing) return;
        if (self.is_initialized) {
            // SDK stop_sample does NOT rewind -- it stops in place so that
            // AIL_resume_sample continues from the stop point. (A subsequent
            // AIL_start_sample is what rewinds to the beginning.)
            _ = ma.ma_sound_stop(&self.sound);
        }
        self.is_done = false;
        self.is_paused = false;
        self.was_stopped = true;
    }

    pub fn end(self: *Sample) void {
        // SDK wavefile.cpp AIL_API_end_sample: stop the voice, mark it SMP_DONE,
        // and -- only if it was not ALREADY done -- fire the EOB then EOS
        // callbacks once. It does not rewind (position is left at the stop point;
        // a later AIL_start_sample is what rewinds).
        const already_done = self.status() == .done;
        if (self.is_initialized) {
            _ = ma.ma_sound_stop(&self.sound);
        }
        self.is_done = true;
        if (already_done) return;
        self.fireEobThenEosCallbacks();
    }

    pub fn pause(self: *Sample) void {
        log("Sample.pause: s={*}\n", .{self});
        if (self.is_initialized and !self.is_paused and ma.ma_sound_is_playing(&self.sound) != 0) {
            _ = ma.ma_sound_stop(&self.sound);
            self.is_paused = true;
        }
    }

    pub fn resumePlayback(self: *Sample) void {
        log("Sample.resume: s={*}\n", .{self});
        if (self.is_initialized) {
            // In legacy MSS, AIL_resume_sample can be used to start a newly loaded
            // sample as well as unpause, though it does not reset loop state.
            _ = ma.ma_sound_start(&self.sound);
            self.is_paused = false;
        }
    }

    pub fn status(self: *Sample) SampleStatus {
        if (self.is_done) return .done;
        if (self.is_paused) return .playing; // MSS: paused samples report SMP_PLAYING
        if (self.is_initialized) {
            if (ma.ma_sound_is_playing(&self.sound) != 0) return .playing;
            if (ma.ma_sound_at_end(&self.sound) != 0) return .done;
        }
        // Never played, or finished playing -> SMP_DONE; only after an explicit
        // AIL_stop_sample -> SMP_STOPPED (the SDK inits samples to SMP_DONE).
        return if (self.was_stopped) .stopped else .done;
    }

    pub fn setVolume(self: *Sample, volume: i32) void {
        self.original_volume = volume;
        self.save_vol_f = @as(f32, @floatFromInt(std.math.clamp(volume, 0, 127))) / 127.0;
        self.volume = root.mssVolumeToGain(volume);
        log("Sample.setVolume: s={*}, i32={d}, gain={d}\n", .{ self, volume, self.volume });
        if (self.is_initialized) ma.ma_sound_set_volume(&self.sound, self.volume);
    }

    // NOTE: the legacy 0..127 setPan uses a linear balance ((pan-64)/64), whereas
    // the v7 float AIL_set_sample_volume_pan uses MSS's 0.3-power constant-power
    // law (verified against wavefile.cpp). The pan law lives in the mixer
    // (left/right_volume = gain*pow(ratio,0.3)), so the integer path arguably
    // should use the same curve — but the pre-v7 source isn't in the SDK dump to
    // confirm, and changing this core path on inference is risky. Left as linear
    // pending old-MSS source; do not "fix" without it.
    pub fn setPan(self: *Sample, pan: i32) void {
        self.original_pan = std.math.clamp(pan, 0, 127);
        self.save_pan_f = @as(f32, @floatFromInt(self.original_pan)) / 127.0;
        self.pan = std.math.clamp((@as(f32, @floatFromInt(pan)) - 64.0) / 64.0, -1.0, 1.0);
        log("Sample.setPan: s={*}, i32={d}, f32={d}\n", .{ self, pan, self.pan });
        if (self.is_initialized) ma.ma_sound_set_pan(&self.sound, self.pan);
    }

    pub fn setVolumePan(self: *Sample, volume: i32, pan: i32) void {
        self.setVolume(volume);
        self.setPan(pan);
    }

    // The combined AIL_set_sample_volume_pan / AIL_set_stream_volume_pan take F32
    // volume and pan in 0.0..1.0 (0.5 = centre), unlike the separate S32 0..127
    // setters. Map linearly onto the same engine path so the perceptual volume
    // curve and pan handling stay consistent.
    pub fn setVolumePanF(self: *Sample, volume: f32, pan: f32) void {
        // NaN fails safe (silence, centre): clamp() would map NaN to the upper
        // bound (@min/@max skip NaN), i.e. garbage input -> full volume.
        const v = if (std.math.isNan(volume)) 0.0 else std.math.clamp(volume, 0.0, 1.0);
        const p = if (std.math.isNan(pan)) 0.5 else std.math.clamp(pan, 0.0, 1.0);
        self.original_volume = @intFromFloat(v * 127.0);
        self.original_pan = @intFromFloat(p * 127.0);
        // SDK AIL_API_set_sample_volume_pan stores save_volume = pow(volume,10/6)
        // and save_pan = pan VERBATIM (no clamp); the getter returns
        // pow(save_volume,6/10) == volume (for volume>=0) and save_pan as-is.
        // Store the raw inputs so the F32 getter round-trips exactly -- only the
        // gain/i32 math below uses the clamped v/p (real pow domain + valid mix).
        self.save_vol_f = volume; // verbatim for the F32 getter (no clamp, no quantization)
        self.save_pan_f = pan;
        // Exact MSS law (AIL_API_set_sample_volume_pan, wavefile.cpp):
        //   gain  = volume^(10/6)            (0.5 -> -10 dB)
        //   left  = gain * (1-pan)^0.3       right = gain * pan^0.3
        //   (pan==0.5 center uses 0.5^0.3 = 0.812252196)
        const gain = std.math.pow(f32, v, 10.0 / 6.0);
        // Per-channel pan ratios (gain-independent, so the pan position survives
        // even at zero volume, as MSS keeps save_pan separate from the gains).
        const lr_left: f32 = if (p == 0.5) 0.812252196 else std.math.pow(f32, 1.0 - p, 0.3);
        const lr_right: f32 = if (p == 0.5) 0.812252196 else std.math.pow(f32, p, 0.3);
        // SDK: a 4+ channel output applies an extra 0.812252196 front/back balance
        // factor to the front L/R gains (wavefile.cpp); a stereo output does not.
        const fb: f32 = if (ma.ma_engine_get_channels(&self.driver.engine) >= 4) 0.812252196 else 1.0;
        // Reproduce gain*lr_left / gain*lr_right through miniaudio's balance panner
        // (out_left = vol*(pan<=0?1:1-pan), out_right = vol*(pan>=0?1:1+pan)).
        const vol = gain * @max(lr_left, lr_right) * fb;
        var pan_bal: f32 = 0.0;
        if (lr_left >= lr_right) {
            if (lr_left > 0.0) pan_bal = (lr_right / lr_left) - 1.0; // in [-1, 0]
        } else {
            if (lr_right > 0.0) pan_bal = 1.0 - (lr_left / lr_right); // in [0, 1]
        }
        // Mirror AIL_API_set_sample_volume_pan's channel bookkeeping (wavefile.cpp)
        // so the volume_pan/levels getters report consistent values.
        // left_volume/right_volume = gain*pan-ratio*fb; back mirrors front;
        // center = (L+R)/2; low = center; fb_pan/center/low save = neutral.
        const lvol = gain * lr_left * fb;
        const rvol = gain * lr_right * fb;
        self.v51_levels[0] = lvol; // f_left
        self.v51_levels[1] = rvol; // f_right
        self.v51_levels[2] = lvol; // b_left = left
        self.v51_levels[3] = rvol; // b_right = right
        self.v51_levels[4] = (lvol + rvol) / 2.0; // center
        self.v51_levels[5] = self.v51_levels[4]; // low = center
        self.v51_fb_pan = 0.5;
        self.v51_center_level = 1.0;
        self.v51_sub_level = 1.0;
        self.volume = vol;
        self.pan = pan_bal;
        if (self.is_initialized) {
            ma.ma_sound_set_volume(&self.sound, vol);
            ma.ma_sound_set_pan(&self.sound, pan_bal);
        }
    }

    /// AIL_API_set_sample_volume_levels (wavefile.cpp): store the linear L/R
    /// scalars verbatim (front pair of v51_levels), reconstruct save_pan/
    /// save_volume for the volume_pan getter, and drive the stereo engine.
    pub fn setVolumeLevels(self: *Sample, left: f32, right: f32) void {
        var save_pan: f32 = 0.5;
        var save_volume: f32 = 0;
        if (left > 0.0001) {
            const rl = right / left;
            const ratio = std.math.pow(f32, rl, 10.0 / 3.0);
            if (std.math.isInf(ratio) and rl > 0) {
                // right/left^10/3 overflowed: the exact limit of
                // ratio/(ratio+1) is 1 and pow(pan,-0.3) -> 1, so pin both.
                save_pan = 1.0;
                save_volume = right;
            } else if (!std.math.isNan(ratio)) {
                save_pan = ratio / (ratio + 1);
                save_volume = if (save_pan < 0.0001) left else right * std.math.pow(f32, save_pan, -0.3);
            }
            // NaN ratio (non-finite input levels): keep the neutral defaults.
        } else if (right > 0.0001) {
            save_pan = 1.0;
            save_volume = right;
        }
        self.v51_levels = .{ left, right, left, right, save_volume, save_volume };
        self.v51_fb_pan = 0.5;
        const vol = std.math.clamp(@max(left, right), 0.0, 1.0);
        self.setVolume(@intFromFloat(vol * 127.0));
        const sum = left + right;
        if (sum > 0.0001) self.setPan(@intFromFloat(std.math.clamp(right / sum, 0.0, 1.0) * 127.0));
        // setVolume/setPan clobbered save_*; overwrite with the exact reconstruction.
        self.save_pan_f = std.math.clamp(save_pan, 0.0, 1.0);
        self.save_vol_f = std.math.pow(f32, @max(save_volume, 0.0), 6.0 / 10.0);
    }

    /// Set reverb parameters for this sample. Creates or updates a ma_delay_node
    /// inserted between the sample's sound and the engine endpoint.
    pub fn setReverb(self: *Sample, room_type: f32, level: f32, reflect_time: f32) void {
        self.reverb_room_type = room_type;
        self.reverb_level = level;
        self.reverb_reflect_time = reflect_time;
        log("Sample.setReverb: s={*}, room={d}, level={d}, time={d}\n", .{ self, room_type, level, reflect_time });

        // `!(x > 0.001)` rejects NaN as well as non-positive values.
        if (!(level > 0.001) or !(reflect_time > 0.001)) {
            self.removeReverb();
            return;
        }
        if (!self.is_initialized) return;

        const sample_rate = ma.ma_engine_get_sample_rate(&self.driver.engine);
        const channels = ma.ma_engine_get_channels(&self.driver.engine);
        // Clamp the reflection delay to a sane span (<=1s) so huge/Inf inputs
        // can't overflow the @intFromFloat conversion or exceed the delay node.
        const max_delay: u64 = @as(u64, sample_rate);
        const delay_frames: u32 = @intCast(@max(@as(u64, 1), @min(satU64(reflect_time * @as(f32, @floatFromInt(sample_rate))), max_delay)));
        // Map room_type to decay: higher room_type = longer decay tail.
        // Clamp below too: a negative decay inverts the feedback phase
        // (clamp() also bounds NaN to 0.95 instead of passing it through).
        const decay: f32 = std.math.clamp(room_type * 0.15, 0.0, 0.95);

        if (self.reverb_node) |node| {
            ma.ma_delay_node_set_wet(node, level);
            // Drive the node dry from the independently-stored dry level (set via
            // AIL_set_sample_reverb_levels; SDK default 1.0) so that control
            // actually reaches the audio, instead of a fixed wet-derived value.
            ma.ma_delay_node_set_dry(node, std.math.clamp(self.reverb_dry_level, 0.0, 1.0));
            ma.ma_delay_node_set_decay(node, decay);
        } else {
            const node = self.driver.allocator.create(ma.ma_delay_node) catch {
                log("Sample.setReverb: failed to allocate delay node\n", .{});
                return;
            };
            const config = ma.ma_delay_node_config_init(channels, sample_rate, delay_frames, decay);
            const result = ma.ma_delay_node_init(@ptrCast(&self.driver.engine), &config, null, node);
            if (result != ma.MA_SUCCESS) {
                log("Sample.setReverb: delay node init failed: {d}\n", .{result});
                self.driver.allocator.destroy(node);
                return;
            }
            // Wire: sound → delay_node → endpoint
            const endpoint = ma.ma_engine_get_endpoint(&self.driver.engine);
            _ = ma.ma_node_attach_output_bus(@ptrCast(node), 0, endpoint, 0);
            _ = ma.ma_node_attach_output_bus(@ptrCast(&self.sound), 0, @ptrCast(node), 0);
            ma.ma_delay_node_set_wet(node, level);
            ma.ma_delay_node_set_dry(node, std.math.clamp(self.reverb_dry_level, 0.0, 1.0));
            self.reverb_node = node;
        }
    }

    /// Remove reverb from this sample, re-routing sound directly to the endpoint.
    fn removeReverb(self: *Sample) void {
        if (self.reverb_node) |node| {
            // Stop the sound before rewiring so the audio thread doesn't walk
            // through a node that's about to be freed.
            const was_playing = self.is_initialized and (ma.ma_sound_is_playing(&self.sound) != 0);
            if (was_playing) _ = ma.ma_sound_stop(&self.sound);
            if (self.is_initialized) {
                _ = ma.ma_node_attach_output_bus(
                    @ptrCast(&self.sound),
                    0,
                    ma.ma_engine_get_endpoint(&self.driver.engine),
                    0,
                );
            }
            _ = ma.ma_node_detach_output_bus(@ptrCast(node), 0);
            ma.ma_delay_node_uninit(node, null);
            self.driver.allocator.destroy(node);
            self.reverb_node = null;
            if (was_playing) _ = ma.ma_sound_start(&self.sound);
        }
    }

    pub fn getReverb(self: *const Sample) struct { room_type: f32, level: f32, reflect_time: f32 } {
        return .{
            .room_type = self.reverb_room_type,
            .level = self.reverb_level,
            .reflect_time = self.reverb_reflect_time,
        };
    }

    fn nativeRate(self: *const Sample) f32 {
        if (self.decoder) |d| return @floatFromInt(d.outputSampleRate);
        return @floatFromInt(ma.ma_engine_get_sample_rate(&self.driver.engine));
    }

    /// Effective pitch = (playback_rate / native) * playback_rate_factor, matching
    /// MSS's effective rate = original_playback_rate * playback_rate_factor. The
    /// rate and the factor compose rather than overwriting each other.
    pub fn applyEffectivePitch(self: *Sample) void {
        if (!self.is_initialized or self.decoder == null) return;
        const native = self.nativeRate();
        const base = self.target_rate orelse native;
        self.pitch = if (native > 0) (base / native) * self.v7_rate_factor else self.v7_rate_factor;
        ma.ma_sound_set_pitch(&self.sound, self.pitch);
    }

    pub fn setPlaybackRate(self: *Sample, rate: i32) void {
        // SDK (AIL_API_set_sample_playback_rate): a rate <= 0 is ignored, the
        // current rate is left unchanged.
        if (rate <= 0) return;
        self.target_rate = @floatFromInt(rate);
        self.applyEffectivePitch();
    }

    /// Set the low-pass cutoff using MSS's normalized 0..1 convention (1.0 =
    /// fully open). Stored for round-tripping; converted to the attached
    /// filter's Hz domain as cutoff*Nyquist when a filter is present.
    pub fn setLowPassNormalized(self: *Sample, norm: f32) void {
        // MSS (update_low_pass_coef): cutoff < 0 or >= 0.999 means fully open
        // (stored back as 1.0); otherwise the value is kept as-is.
        const eff: f32 = if (!(norm >= 0.0) or norm >= 0.999) 1.0 else norm;
        self.low_pass_cutoff_norm = eff;
        const f = self.attached_filter orelse return;
        const rate = ma.ma_engine_get_sample_rate(&self.driver.engine);
        const nyquist = @as(f64, @floatFromInt(rate)) / 2.0;
        f.setCutoff(@as(f64, eff) * nyquist);
    }

    /// Return the normalized 0..1 low-pass cutoff the app set (MSS default 1.0).
    pub fn getLowPassNormalized(self: *const Sample) f32 {
        return self.low_pass_cutoff_norm;
    }

    pub fn setLoopCount(self: *Sample, count: i32) void {
        self.loop_count = count;
        self.loops_remaining = count;
        log("Sample.setLoopCount: s={*}, count={d}\n", .{ self, count });
        // MSS uses 0 for infinite looping.
        if (self.is_initialized) {
            applyLoopCount(&self.sound, count);
        }
    }

    pub fn bytesPerFrame(self: *const Sample) u32 {
        if (self.decoder) |d| {
            const bps = ma.ma_get_bytes_per_sample(d.outputFormat);
            return bps * @as(u32, @intCast(d.outputChannels));
        }
        // Fallback: use pcm_format if known, else assume 16-bit stereo
        if (self.pcm_format) |fmt| {
            return @as(u32, fmt.channels) * (@as(u32, fmt.bits) / 8);
        }
        return 4;
    }

    pub fn setLoopBlock(self: *Sample, start_bytes: i32, end_bytes: i32) void {
        applyLoopBlock(self, start_bytes, end_bytes);
    }

    pub fn getPosition(self: *Sample) u32 {
        if (self.is_initialized) {
            var cursor: u64 = 0;
            _ = ma.ma_sound_get_cursor_in_pcm_frames(&self.sound, &cursor);
            const bpf = self.bytesPerFrame();
            return @as(u32, @intCast(@min(cursor * @as(u64, bpf), std.math.maxInt(u32))));
        }
        return 0;
    }

    pub fn setPosition(self: *Sample, pos: u32) void {
        if (self.is_initialized) {
            const bpf = self.bytesPerFrame();
            // SDK (AIL_API_set_sample_position) rounds the byte offset to the
            // nearest granularity (= bytes-per-frame here) boundary, not floors.
            const frame: u64 = if (bpf > 0) (@as(u64, pos) + bpf / 2) / bpf else 0;
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, frame);
        }
    }

    pub const MsPosition = struct { total: i32, current: i32 };

    pub fn getMsPosition(self: *Sample) MsPosition {
        var pos = MsPosition{ .total = 0, .current = 0 };
        if (self.is_initialized and self.decoder != null) {
            var cursor: u64 = 0;
            _ = ma.ma_sound_get_cursor_in_pcm_frames(&self.sound, &cursor);
            // ms uses the effective playback rate (rate*factor), matching the SDK's
            // datarate and AIL_set_sample_ms_position, so the round-trip holds.
            const native = @as(f32, @floatFromInt(self.decoder.?.outputSampleRate));
            const effective = (self.target_rate orelse native) * self.v7_rate_factor;
            const ms_per_frame: f32 = if (effective > 0) 1000.0 / effective else 0;
            pos.current = satI32(@as(f32, @floatFromInt(cursor)) * ms_per_frame);
            pos.total = satI32(@as(f32, @floatFromInt(self.cached_length_frames)) * ms_per_frame);
        }
        return pos;
    }

    pub fn setMsPosition(self: *Sample, ms: i32) void {
        if (self.is_initialized and self.decoder != null) {
            // SDK uses effective_rate = original_playback_rate * playback_rate_
            // factor (wavefile.cpp), not the native rate, so an explicitly-set
            // playback rate/factor maps ms onto the source position correctly.
            const native = @as(f32, @floatFromInt(self.decoder.?.outputSampleRate));
            const effective = (self.target_rate orelse native) * self.v7_rate_factor;
            // Negative positions clamp to the start (satU64 maps <0/NaN to 0).
            const frame = satU64(@as(f32, @floatFromInt(ms)) * effective / 1000.0);
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, frame);
        }
    }
};

pub const Sample3D = struct {
    driver: *DigitalDriver,
    sound: ma.ma_sound,
    decoder: ?*ma.ma_decoder = null,
    owned_buffer: ?[]u8 = null,
    is_initialized: bool = false,
    is_done: bool = false,
    is_paused: bool = false,
    was_stopped: bool = false, // SMP_STOPPED only after explicit stop (else SMP_DONE)
    driver_is_dead: bool = false,
    volume: f32 = 1.0,
    original_volume: i32 = 127,
    pitch: f32 = 1.0,
    target_rate: ?f32 = null,
    loop_count: i32 = 1,
    loops_remaining: i32 = 1,
    loop_start_frame: u64 = 0,
    loop_end_frame: u64 = 0,
    eos_callback: usize = 0,
    obstruction: f32 = 0.0,
    occlusion: f32 = 0.0,
    exclusion: f32 = 0.0,
    effects_level: f32 = 0.0,
    auto_update: bool = false,
    velocity_x: f32 = 0.0,
    velocity_y: f32 = 0.0,
    velocity_z: f32 = 0.0,
    pos_x: f32 = 0.0,
    pos_y: f32 = 0.0,
    pos_z: f32 = 0.0,
    min_distance: f32 = 1.0,
    max_distance: f32 = 200.0, // MSS default (wavefile.cpp: min_dist=1, max_dist=200)
    cone_inner_rad: f32 = 360.0 * deg2rad,
    cone_outer_rad: f32 = 360.0 * deg2rad,
    cone_outer_volume: f32 = 1.0,
    // MSS default orientation (wavefile.cpp): face = +X (1,0,0), up = +Y (0,1,0).
    orient_fx: f32 = 1.0,
    orient_fy: f32 = 0.0,
    orient_fz: f32 = 0.0,
    orient_ux: f32 = 0.0,
    orient_uy: f32 = 1.0,
    orient_uz: f32 = 0.0,
    user_data: [8]u32 = [_]u32{0} ** 8,
    bounded_mem_ctx: ?*Sample.BoundedMemCtx = null,
    cached_length_frames: u64 = 0,

    fn eosCallbackBridge(pUserData: ?*anyopaque, pSound: ?*ma.ma_sound) callconv(.c) void {
        _ = pSound;
        const self: *Sample3D = @ptrCast(@alignCast(pUserData.?));
        // loops_remaining <= 0: infinite (0 = documented, negative = treated same).
        if (self.loops_remaining <= 0) {
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, self.loop_start_frame);
            _ = ma.ma_sound_start(&self.sound);
            return;
        } else if (self.loops_remaining > 1) {
            self.loops_remaining -= 1;
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, self.loop_start_frame);
            _ = ma.ma_sound_start(&self.sound);
            return;
        }
        self.is_done = true;
        if (self.eos_callback != 0) {
            const cb: *const fn (?*anyopaque) callconv(.winapi) void = @ptrFromInt(self.eos_callback);
            cb(@ptrCast(self));
        }
    }

    fn bytesPerFrame(self: *const Sample3D) u32 {
        if (self.decoder) |d| {
            const bps = ma.ma_get_bytes_per_sample(d.outputFormat);
            return bps * @as(u32, @intCast(d.outputChannels));
        }
        return 4;
    }

    pub fn setLoopBlock(self: *Sample3D, start_bytes: i32, end_bytes: i32) void {
        applyLoopBlock(self, start_bytes, end_bytes);
    }

    pub fn init(driver: *DigitalDriver) !*Sample3D {
        const self = try driver.allocator.create(Sample3D);
        errdefer driver.allocator.destroy(self);
        self.* = .{ .driver = driver, .sound = undefined };
        try driver.samples_3d.append(driver.allocator, self);
        return self;
    }

    pub fn deinit(self: *Sample3D) void {
        if (!self.driver_is_dead) {
            for (self.driver.samples_3d.items, 0..) |s, i| {
                if (s == self) {
                    _ = self.driver.samples_3d.swapRemove(i);
                    break;
                }
            }
        }
        self.cleanupPlaybackState();
        self.driver.allocator.destroy(self);
    }

    fn cleanupPlaybackState(self: *Sample3D) void {
        if (self.is_initialized) {
            ma.ma_sound_uninit(&self.sound);
            self.is_initialized = false;
        }
        if (self.decoder) |d| {
            _ = ma.ma_decoder_uninit(d);
            self.driver.allocator.destroy(d);
            self.decoder = null;
        }
        if (self.bounded_mem_ctx) |ctx| {
            self.driver.allocator.destroy(ctx);
            self.bounded_mem_ctx = null;
        }
        if (self.owned_buffer) |buf| {
            self.driver.allocator.free(buf);
            self.owned_buffer = null;
        }
    }

    /// Shared post-init tail of every decoder-backed Sample3D load: adopt the
    /// decoder, cache the length, apply stored rate/volume state, register the
    /// EOS bridge, and re-apply all stored spatial settings (they may have been
    /// set before audio loaded). No fallible step here; callers assign their
    /// ownership fields first.
    fn finishDecoderLoad(self: *Sample3D, decoder: *ma.ma_decoder) void {
        self.decoder = decoder;
        self.is_initialized = true;
        self.is_done = false;
        self.is_paused = false;
        _ = ma.ma_sound_get_length_in_pcm_frames(&self.sound, &self.cached_length_frames);

        if (self.target_rate) |tr| {
            const native_rate = @as(f32, @floatFromInt(decoder.outputSampleRate));
            if (native_rate > 0) self.pitch = tr / native_rate;
        }

        self.applyVolume();
        ma.ma_sound_set_pitch(&self.sound, self.pitch);
        // Disable miniaudio looping on load; start() re-enables it for infinite
        // loops. Finite loop counting is handled by the EOS bridge.
        ma.ma_sound_set_looping(&self.sound, 0);
        _ = ma.ma_sound_set_end_callback(&self.sound, Sample3D.eosCallbackBridge, self);
        if (self.driver.rolloff_factor != 1.0) ma.ma_sound_set_rolloff(&self.sound, self.driver.rolloff_factor);
        if (self.driver.effectiveDoppler() != 1.0) ma.ma_sound_set_doppler_factor(&self.sound, self.driver.effectiveDoppler());
        ma.ma_sound_set_position(&self.sound, self.pos_x, self.pos_y, -self.pos_z);
        ma.ma_sound_set_velocity(&self.sound, self.velocity_x, self.velocity_y, -self.velocity_z);
        ma.ma_sound_set_min_distance(&self.sound, self.min_distance);
        ma.ma_sound_set_max_distance(&self.sound, self.max_distance);
        self.applyCone();
        ma.ma_sound_set_direction(&self.sound, self.orient_fx, self.orient_fy, -self.orient_fz);
        if (self.loop_end_frame > 0) {
            _ = ma.ma_data_source_set_range_in_pcm_frames(decoder, 0, self.loop_end_frame);
        }
    }

    pub fn loadFromOwnedMemory(self: *Sample3D, data: []u8) !void {
        self.cleanupPlaybackState();

        const decoder = try self.driver.allocator.create(ma.ma_decoder);
        errdefer self.driver.allocator.destroy(decoder);
        var result = ma.ma_decoder_init_memory(data.ptr, data.len, null, decoder);
        if (result != ma.MA_SUCCESS) return error.DecoderInitFailed;

        result = ma.ma_sound_init_from_data_source(&self.driver.engine, @ptrCast(decoder), 0, null, &self.sound);
        if (result != ma.MA_SUCCESS) {
            _ = ma.ma_decoder_uninit(decoder);
            return error.SoundInitFailed;
        }
        // Take ownership only after all fallible steps succeed (see Sample.loadFromOwnedMemory).
        self.owned_buffer = data;
        self.finishDecoderLoad(decoder);
    }

    pub fn loadFromMemory(self: *Sample3D, data: []const u8, copy_data: bool) !void {
        self.cleanupPlaybackState();

        var internal_data = data;
        var owned_copy: ?[]u8 = null;
        if (copy_data) {
            owned_copy = try self.driver.allocator.dupe(u8, data);
            internal_data = owned_copy.?;
        }
        errdefer if (owned_copy) |c| self.driver.allocator.free(c);

        const decoder = try self.driver.allocator.create(ma.ma_decoder);
        errdefer self.driver.allocator.destroy(decoder);
        var result = ma.ma_decoder_init_memory(internal_data.ptr, internal_data.len, null, decoder);
        if (result != ma.MA_SUCCESS) return error.DecoderInitFailed;

        // Spatialization enabled by default (no MA_SOUND_FLAG_NO_SPATIALIZATION)
        result = ma.ma_sound_init_from_data_source(&self.driver.engine, @ptrCast(decoder), 0, null, &self.sound);
        if (result != ma.MA_SUCCESS) {
            _ = ma.ma_decoder_uninit(decoder);
            return error.SoundInitFailed;
        }
        self.owned_buffer = owned_copy;
        self.finishDecoderLoad(decoder);
    }

    fn loadFromBoundedPointer(self: *Sample3D, data_ptr: [*]const u8, max_size: usize) !void {
        self.cleanupPlaybackState();

        const ctx = try self.driver.allocator.create(Sample.BoundedMemCtx);
        errdefer self.driver.allocator.destroy(ctx);
        ctx.* = .{ .base = data_ptr, .size = max_size, .cursor = 0 };

        const decoder = try self.driver.allocator.create(ma.ma_decoder);
        errdefer self.driver.allocator.destroy(decoder);
        var result = ma.ma_decoder_init(Sample.boundedMemRead, Sample.boundedMemSeek, @ptrCast(ctx), null, decoder);
        if (result != ma.MA_SUCCESS) {
            // ctx/decoder are freed by their errdefers on this error return.
            return error.DecoderInitFailed;
        }

        result = ma.ma_sound_init_from_data_source(&self.driver.engine, @ptrCast(decoder), 0, null, &self.sound);
        if (result != ma.MA_SUCCESS) {
            _ = ma.ma_decoder_uninit(decoder);
            // decoder allocation and ctx are freed by their errdefers.
            return error.SoundInitFailed;
        }
        self.bounded_mem_ctx = ctx;
        self.finishDecoderLoad(decoder);
    }

    pub fn loadFromUnownedPointer(self: *Sample3D, data_ptr: [*]const u8) !void {
        const detected = root.detectAudioSize(data_ptr);
        if (detected == 0) {
            // Unrecognized format: cannot bound reads from a bare pointer
            // (see Sample.loadFromUnownedMemoryUnknownSize). Refuse.
            return error.UnsupportedAudioFormat;
        }
        if (detected != root.streaming_sentinel_size) {
            try self.loadFromMemory(data_ptr[0..detected], true);
        } else {
            try self.loadFromBoundedPointer(data_ptr, root.streaming_sentinel_size);
        }
    }

    pub fn loadFromPcm(self: *Sample3D, pcm_data: []const u8, channels: u16, rate: u32, bits: u16) !void {
        // Build a temp WAV; loadFromOwnedMemory will take ownership of the buffer
        const wav = try buildWavFromPcm(self.driver.allocator, pcm_data, channels, rate, bits);
        errdefer self.driver.allocator.free(wav);
        try self.loadFromOwnedMemory(wav);
    }

    pub fn start(self: *Sample3D) void {
        self.loops_remaining = self.loop_count;
        self.is_done = false;
        self.is_paused = false;
        self.was_stopped = false;
        if (self.is_initialized) {
            applyLoopCount(&self.sound, self.loop_count);
            // SDK AIL_API_start_3D_sample rewinds to the beginning before playing
            // (AIL_resume_3D_sample is what continues from the current position).
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, 0);
            _ = ma.ma_sound_start(&self.sound);
        }
    }

    pub fn stop(self: *Sample3D) void {
        // Match the 2D AIL_API_stop_sample contract: a no-op unless currently
        // SMP_PLAYING (DONE/STOPPED/never-started keep their status), and it
        // stops in place WITHOUT rewinding so AIL_resume_3D_sample continues
        // from the stop point. (A later AIL_start_3D_sample is what rewinds.)
        if (self.status() != .playing) return;
        if (self.is_initialized) {
            _ = ma.ma_sound_stop(&self.sound);
        }
        self.is_done = false;
        self.is_paused = false;
        self.was_stopped = true;
    }

    pub fn end(self: *Sample3D) void {
        // SDK AIL_API_end_sample (the 3D handle is an HSAMPLE): stop, mark
        // SMP_DONE, and fire the EOS callback once -- only if it was not already
        // done. No rewind (a later AIL_start_3D_sample is what rewinds).
        const already_done = self.status() == .done;
        if (self.is_initialized) {
            _ = ma.ma_sound_stop(&self.sound);
        }
        self.is_done = true;
        if (already_done) return;
        if (self.eos_callback != 0) {
            const cb: *const fn (?*anyopaque) callconv(.winapi) void = @ptrFromInt(self.eos_callback);
            cb(@ptrCast(self));
        }
    }

    pub fn pause(self: *Sample3D) void {
        if (self.is_initialized and !self.is_paused and ma.ma_sound_is_playing(&self.sound) != 0) {
            _ = ma.ma_sound_stop(&self.sound);
            self.is_paused = true;
        }
    }

    pub fn resumePlayback(self: *Sample3D) void {
        if (self.is_initialized and self.is_paused) {
            _ = ma.ma_sound_start(&self.sound);
            self.is_paused = false;
        }
    }

    pub fn status(self: *Sample3D) SampleStatus {
        if (self.is_done) return .done;
        // Paused 3D samples report SMP_STOPPED (8), unlike 2D where paused reports SMP_PLAYING (4).
        if (self.is_paused) return .stopped;
        if (self.is_initialized) {
            if (ma.ma_sound_is_playing(&self.sound) != 0) return .playing;
            if (ma.ma_sound_at_end(&self.sound) != 0) return .done;
        }
        // Never played / finished -> SMP_DONE; only explicit stop -> SMP_STOPPED.
        return if (self.was_stopped) .stopped else .done;
    }

    pub fn applyCone(self: *Sample3D) void {
        if (self.is_initialized) {
            ma.ma_sound_set_cone(&self.sound, self.cone_inner_rad, self.cone_outer_rad, self.cone_outer_volume);
        }
    }

    fn applyVolume(self: *Sample3D) void {
        if (self.is_initialized) {
            // MSS software 3D (m3d.cpp): obstruction has NO mix effect (it is only
            // volume-attenuated on EAX hardware, which we don't emulate); occlusion
            // drives a low-pass cutoff, not volume. The legacy H3DSAMPLE path has
            // no per-voice filter, so occlusion is approximated as a loudness
            // reduction here. Obstruction is intentionally omitted.
            // occlusion is stored verbatim (SDK m3d.cpp); clamp to [0,1] only
            // here, for the loudness-reduction approximation, so the getter can
            // still hand back out-of-range values faithfully.
            const occ = @min(1.0, @max(0.0, self.occlusion));
            const eff = self.volume * (1.0 - occ);
            ma.ma_sound_set_volume(&self.sound, @max(0.0, eff));
        }
    }

    pub fn setVolume(self: *Sample3D, volume: i32) void {
        self.original_volume = volume;
        self.volume = root.mssVolumeToGain(volume);
        self.applyVolume();
    }

    pub fn setObstruction(self: *Sample3D, val: f32) void {
        // SDK m3d.cpp AIL_API_set_sample_obstruction: stores verbatim, no clamp
        // (and software 3D applies no mix effect for obstruction anyway).
        self.obstruction = val;
    }

    pub fn setOcclusion(self: *Sample3D, val: f32) void {
        // SDK stores verbatim; the mix-side clamp lives in applyVolume().
        self.occlusion = val;
        self.applyVolume();
    }

    pub fn setLoopCount(self: *Sample3D, count: i32) void {
        self.loop_count = count;
        self.loops_remaining = count;
        if (self.is_initialized) {
            applyLoopCount(&self.sound, count);
        }
    }

    pub fn setPlaybackRate(self: *Sample3D, rate: i32) void {
        // SDK: a rate <= 0 is ignored, the current rate is left unchanged
        // (matches the 2D Sample.setPlaybackRate guard).
        if (rate <= 0) return;
        const tr = @as(f32, @floatFromInt(rate));
        self.target_rate = tr;
        if (self.is_initialized) {
            if (self.decoder) |d| {
                const native_rate = @as(f32, @floatFromInt(d.outputSampleRate));
                if (native_rate > 0) self.pitch = tr / native_rate;
                ma.ma_sound_set_pitch(&self.sound, self.pitch);
            }
        }
    }

    pub fn getOffset(self: *Sample3D) u32 {
        if (self.is_initialized) {
            var cursor: u64 = 0;
            _ = ma.ma_sound_get_cursor_in_pcm_frames(&self.sound, &cursor);
            const bpf = self.bytesPerFrame();
            return @as(u32, @intCast(@min(cursor * @as(u64, bpf), std.math.maxInt(u32))));
        }
        return 0;
    }

    pub fn setOffset(self: *Sample3D, pos: u32) void {
        if (self.is_initialized) {
            const bpf = self.bytesPerFrame();
            // Round to the nearest frame boundary, matching the 2D
            // Sample.setPosition (AIL_API_set_sample_position rounds, not floors)
            // so the offset round-trip via getOffset holds.
            const frame: u64 = if (bpf > 0) (@as(u64, pos) + bpf / 2) / bpf else 0;
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, frame);
        }
    }

    pub fn getLength(self: *Sample3D) u32 {
        if (self.is_initialized) {
            const bpf = self.bytesPerFrame();
            // Saturating multiply: cached_length_frames is header-derived and
            // could overflow u64 before the clamp.
            return @as(u32, @intCast(@min(self.cached_length_frames *| @as(u64, bpf), std.math.maxInt(u32))));
        }
        return 0;
    }

    pub fn getMsPosition(self: *Sample3D) Sample.MsPosition {
        var pos = Sample.MsPosition{ .total = 0, .current = 0 };
        if (self.is_initialized and self.decoder != null) {
            var cursor: u64 = 0;
            _ = ma.ma_sound_get_cursor_in_pcm_frames(&self.sound, &cursor);
            // Use the effective playback rate (an explicitly-set rate overrides
            // native), matching the 2D Sample.getMsPosition so the ms round-trip
            // holds when a 3D sample's playback rate was changed.
            const native = @as(f32, @floatFromInt(self.decoder.?.outputSampleRate));
            const effective = self.target_rate orelse native;
            const ms_per_frame: f32 = if (effective > 0) 1000.0 / effective else 0;
            pos.current = satI32(@as(f32, @floatFromInt(cursor)) * ms_per_frame);
            pos.total = satI32(@as(f32, @floatFromInt(self.cached_length_frames)) * ms_per_frame);
        }
        return pos;
    }

    pub fn setMsPosition(self: *Sample3D, ms: i32) void {
        if (self.is_initialized and self.decoder != null) {
            // Effective rate (explicit playback rate overrides native), matching
            // the 2D Sample.setMsPosition so an explicitly-set rate maps ms onto
            // the source position correctly.
            const native = @as(f32, @floatFromInt(self.decoder.?.outputSampleRate));
            const effective = self.target_rate orelse native;
            const frame = satU64(@as(f32, @floatFromInt(ms)) * effective / 1000.0);
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, frame);
        }
    }

    pub fn setMinMaxDistance(self: *Sample3D, min_dist: f32, max_dist: f32) void {
        // Match the SDK (m3d.cpp): swap so min <= max. miniaudio's distance
        // attenuation is undefined when min_distance > max_distance.
        var lo = min_dist;
        var hi = max_dist;
        if (lo > hi) {
            const tmp = lo;
            lo = hi;
            hi = tmp;
        }
        self.min_distance = lo;
        self.max_distance = hi;
        if (self.is_initialized) {
            ma.ma_sound_set_min_distance(&self.sound, lo);
            ma.ma_sound_set_max_distance(&self.sound, hi);
        }
    }

    // 3D coordinate handedness: MSS is LEFT-handed (forward=+Z, up=+Y, right =
    // up x forward = +X; confirmed by the SDK defaults listen_face=(0,0,1),
    // listen_up=(0,1,0), listen_cross=(1,0,0) in genericdig.cpp). miniaudio is
    // RIGHT-handed (forward=-Z). We negate Z on every coordinate crossing the
    // miniaudio boundary (sample + listener; position/velocity/direction; set,
    // and the listener getters) so the spatializer reproduces MSS geometry,
    // while stored values and getters stay in MSS space.
    pub fn setPosition(self: *Sample3D, x: f32, y: f32, z: f32) void {
        self.pos_x = x;
        self.pos_y = y;
        self.pos_z = z;
        if (self.is_initialized) {
            ma.ma_sound_set_position(&self.sound, x, y, -z);
        }
    }

    /// Explicit dead-reckoning step for AIL_3D_update_position: advance the
    /// position by velocity over `dt_ms` milliseconds, unconditionally (unlike
    /// the auto-tick updatePosition, which is gated on the auto_update flag).
    pub fn updatePositionExplicit(self: *Sample3D, dt_ms: f32) void {
        if (!(dt_ms == dt_ms) or std.math.isInf(dt_ms)) return; // NaN/Inf guard
        // SDK m3d.cpp: velocity is per-millisecond, so position advances by
        // velocity * dt_ms directly (NOT dt/1000); early-out when velocity is
        // ~0, mirroring AIL_API_update_listener_3D_position.
        const eps: f32 = 0.0001; // MSS_EPSILON
        if (@abs(self.velocity_x) < eps and @abs(self.velocity_y) < eps and @abs(self.velocity_z) < eps) return;
        self.pos_x += self.velocity_x * dt_ms;
        self.pos_y += self.velocity_y * dt_ms;
        self.pos_z += self.velocity_z * dt_ms;
        if (self.is_initialized) {
            ma.ma_sound_set_position(&self.sound, self.pos_x, self.pos_y, -self.pos_z);
        }
    }
    pub fn setVelocity(self: *Sample3D, x: f32, y: f32, z: f32) void {
        self.velocity_x = x;
        self.velocity_y = y;
        self.velocity_z = z;
        if (self.is_initialized) {
            ma.ma_sound_set_velocity(&self.sound, x, y, -z);
        }
    }

    pub fn updatePosition(self: *Sample3D, dt_ms: f32) void {
        if (!self.auto_update) return;
        if (!(dt_ms == dt_ms) or std.math.isInf(dt_ms)) return; // NaN/Inf guard
        // SDK m3d.cpp: velocity is per-millisecond, advance by velocity * dt_ms.
        // Dead reckoning is a geometric op on the object (like
        // updatePositionExplicit): the stored position moves even before a
        // sound is loaded; only the ma_sound push waits for initialization.
        if (self.velocity_x == 0 and self.velocity_y == 0 and self.velocity_z == 0) return;
        self.pos_x += self.velocity_x * dt_ms;
        self.pos_y += self.velocity_y * dt_ms;
        self.pos_z += self.velocity_z * dt_ms;
        if (self.is_initialized) {
            ma.ma_sound_set_position(&self.sound, self.pos_x, self.pos_y, -self.pos_z);
        }
    }
    pub fn setOrientation(self: *Sample3D, fx: f32, fy: f32, fz: f32, ux: f32, uy: f32, uz: f32) void {
        // SDK (m3d.cpp) normalizes face & up before storing; the getter returns
        // the stored unit vectors. (Zero-length vectors are left unchanged.)
        var face = [3]f32{ fx, fy, fz };
        var up = [3]f32{ ux, uy, uz };
        normalize3(&face);
        normalize3(&up);
        self.orient_fx = face[0];
        self.orient_fy = face[1];
        self.orient_fz = face[2];
        self.orient_ux = up[0];
        self.orient_uy = up[1];
        self.orient_uz = up[2];
        if (self.is_initialized) {
            ma.ma_sound_set_direction(&self.sound, face[0], face[1], -face[2]);
        }
    }
};

// --- Callback ABI regression tests -------------------------------------------
// These register REAL stdcall callbacks (not null) and drive the bridges that
// invoke them, asserting the single-arg HSAMPLE signature that the SDK mandates
// (AILSAMPLECB = void(HSAMPLE)). A wrong arity here corrupts the mixer-thread
// stack at runtime, a class of bug synthetic null-callback fuzzing cannot see.
const CbProbe = struct {
    var eob_hs: ?*anyopaque = null;
    var eos_hs: ?*anyopaque = null;
    var eob_calls: u32 = 0;
    var eos_calls: u32 = 0;
    fn reset() void {
        eob_hs = null;
        eos_hs = null;
        eob_calls = 0;
        eos_calls = 0;
    }
    fn onEob(s: ?*anyopaque) callconv(.winapi) void {
        eob_hs = s;
        eob_calls += 1;
    }
    fn onEos(s: ?*anyopaque) callconv(.winapi) void {
        eos_hs = s;
        eos_calls += 1;
    }
};

test "EOB/EOS callbacks fire with single HSAMPLE arg" {
    const s = try std.testing.allocator.create(Sample);
    defer std.testing.allocator.destroy(s);
    s.* = undefined;
    s.loops_remaining = 1;
    s.is_done = false;
    s.eob_callback = @intFromPtr(&CbProbe.onEob);
    s.eos_callback = @intFromPtr(&CbProbe.onEos);
    s.sob_callback = 0;
    CbProbe.reset();
    // Final-loop completion path: must fire EOB then EOS, each with HSAMPLE only.
    Sample.eosCallbackBridge(s, null);
    try std.testing.expect(s.is_done);
    try std.testing.expectEqual(@as(u32, 1), CbProbe.eob_calls);
    try std.testing.expectEqual(@as(u32, 1), CbProbe.eos_calls);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(s)), CbProbe.eob_hs);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(s)), CbProbe.eos_hs);
}

test "EOB stream bridge fires with single HSAMPLE arg" {
    const s = try std.testing.allocator.create(Sample);
    defer std.testing.allocator.destroy(s);
    s.* = undefined;
    s.eob_callback = @intFromPtr(&CbProbe.onEob);
    s.last_loaded_buffer = 0;
    CbProbe.reset();
    // Buffer-drain bridge passes through buf_index/len/addr but the app callback
    // receives only HSAMPLE.
    Sample.streamEobBridge(@ptrCast(s), 1, 4096, null);
    try std.testing.expectEqual(@as(i32, 1), s.last_loaded_buffer);
    try std.testing.expectEqual(@as(u32, 1), CbProbe.eob_calls);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(s)), CbProbe.eob_hs);
}

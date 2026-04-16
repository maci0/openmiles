const std = @import("std");
const root = @import("../root.zig");
const ma = root.ma;
const log = root.log;
const fs_compat = root.fs_compat;

const deg2rad = root.deg2rad;
const buildWavFromPcm = root.buildWavFromPcm;

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
    samples_3d: std.ArrayListUnmanaged(*Sample3D) = .{},
    rolloff_factor: f32 = 1.0,
    doppler_factor: f32 = 1.0,
    distance_factor: f32 = 1.0,
    room_type: i32 = 0,
    speaker_type: i32 = 0,
    // DSP processor callbacks [input_stage, output_stage]. Stored for query
    // round-tripping; not invoked (miniaudio manages its own processing graph).
    driver_processors: [2]usize = .{ 0, 0 },
    // Filters opened against this driver (tracked for cleanup on driver close).
    filters: std.ArrayListUnmanaged(*root.Filter) = .{},
    // Captured output buffer for AIL_process_digital_audio. Populated by
    // the onProcess callback each time the audio thread renders a buffer.
    capture_buf: std.ArrayListUnmanaged(f32) = .{},
    capture_mutex: std.Thread.Mutex = .{},
    capture_enabled: bool = false,

    pub fn init(allocator: std.mem.Allocator, frequency: u32, bits: i32, channels: u32) !*DigitalDriver {
        _ = bits;
        log("DigitalDriver.init called: freq={d}, channels={d}\n", .{ frequency, channels });
        const self = try allocator.create(DigitalDriver);
        log("DigitalDriver.init: self={*}\n", .{@as(*anyopaque, self)});
        self.* = .{
            .engine = undefined,
            .allocator = allocator,
            .providers = .{},
            .timers = .{},
            .samples = .{},
            .samples_3d = .{},
        };
        var config = ma.ma_engine_config_init();
        if (@import("builtin").is_test) {
            config.noDevice = ma.MA_TRUE;
        }
        config.sampleRate = frequency;
        config.channels = channels;
        if (frequency == 0) config.sampleRate = 44100;
        if (channels == 0) config.channels = 2;
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

        // Install an onProcess callback so AIL_process_digital_audio can
        // capture the engine's mixed output without interfering with playback.
        self.engine.onProcess = onProcessCapture;
        self.engine.pProcessUserData = @ptrCast(self);

        root.last_digital_driver = self;
        root.registerDriver(self);
        return self;
    }

    pub fn deinit(self: *DigitalDriver) void {
        if (root.last_digital_driver == self) root.last_digital_driver = null;
        root.unregisterDriver(self);
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
        self.capture_buf.deinit(self.allocator);
        ma.ma_engine_uninit(&self.engine);
        self.allocator.destroy(self);
    }

    pub fn loadAllAsi(self: *DigitalDriver, redist_dir: []const u8) void {
        const alloc = self.allocator;
        var d = fs_compat.openDir(redist_dir, .{ .iterate = true }) catch |err| {
            log("loadAllAsi: failed to open directory '{s}': {any}\n", .{ redist_dir, err });
            return;
        };
        defer d.close();
        var it = d.iterate();
        while (it.next() catch null) |entry| {
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

    /// Called from the audio thread each time the engine renders a buffer.
    /// Copies the mixed float frames into the capture ring so that
    /// AIL_process_digital_audio can return them to the game.
    fn onProcessCapture(pUserData: ?*anyopaque, pFramesOut: [*c]f32, frameCount: ma.ma_uint64) callconv(.c) void {
        const self: *DigitalDriver = @ptrCast(@alignCast(pUserData.?));
        if (!self.capture_enabled) return;
        const channels = ma.ma_engine_get_channels(&self.engine);
        const sample_count: usize = @as(usize, @intCast(frameCount)) * channels;
        if (!self.capture_mutex.tryLock()) return;
        defer self.capture_mutex.unlock();
        // Keep only the latest buffer; games typically call process_digital_audio
        // once per frame expecting the most recent rendered block.
        self.capture_buf.clearRetainingCapacity();
        if (self.capture_buf.capacity >= sample_count) {
            self.capture_buf.appendSliceAssumeCapacity(pFramesOut[0..sample_count]);
        }
    }

    /// Enable the capture path and pre-allocate the buffer so the audio
    /// thread callback never needs to allocate.
    pub fn enableCapture(self: *DigitalDriver) void {
        if (self.capture_enabled) return;
        const channels = ma.ma_engine_get_channels(&self.engine);
        const rate = ma.ma_engine_get_sample_rate(&self.engine);
        // Pre-allocate for ~50ms of audio (a generous render buffer).
        const cap: usize = @as(usize, rate / 20) * channels;
        self.capture_buf.ensureTotalCapacity(self.allocator, cap) catch {};
        self.capture_enabled = true;
    }

    /// Read captured frames into a caller-supplied buffer. Returns the
    /// number of BYTES written. Converts from float to 16-bit PCM.
    pub fn readCaptured(self: *DigitalDriver, dest: [*]u8, max_bytes: usize) u32 {
        self.capture_mutex.lock();
        defer self.capture_mutex.unlock();
        const channels = ma.ma_engine_get_channels(&self.engine);
        const sample_count = self.capture_buf.items.len;
        const frame_count = if (channels == 0) 0 else sample_count / channels;
        // Convert f32 → s16 into dest
        const out_frames = @min(frame_count, max_bytes / (channels * 2));
        const out_samples = out_frames * channels;
        const out: [*]i16 = @ptrCast(@alignCast(dest));
        for (0..out_samples) |i| {
            const clamped = @max(-1.0, @min(1.0, self.capture_buf.items[i]));
            out[i] = @intFromFloat(clamped * 32767.0);
        }
        return @intCast(out_samples * 2);
    }

    pub fn setListenerPosition(self: *DigitalDriver, x: f32, y: f32, z: f32) void {
        ma.ma_engine_listener_set_position(&self.engine, 0, x, y, z);
    }

    pub fn setListenerVelocity(self: *DigitalDriver, x: f32, y: f32, z: f32) void {
        ma.ma_engine_listener_set_velocity(&self.engine, 0, x, y, z);
    }

    pub fn setListenerDirection(self: *DigitalDriver, fx: f32, fy: f32, fz: f32) void {
        ma.ma_engine_listener_set_direction(&self.engine, 0, fx, fy, fz);
    }

    pub fn setListenerWorldUp(self: *DigitalDriver, ux: f32, uy: f32, uz: f32) void {
        ma.ma_engine_listener_set_world_up(&self.engine, 0, ux, uy, uz);
    }

    pub fn getListenerPosition(self: *DigitalDriver) ma.ma_vec3f {
        return ma.ma_engine_listener_get_position(&self.engine, 0);
    }

    pub fn getListenerVelocity(self: *DigitalDriver) ma.ma_vec3f {
        return ma.ma_engine_listener_get_velocity(&self.engine, 0);
    }

    pub fn getListenerDirection(self: *DigitalDriver) ma.ma_vec3f {
        return ma.ma_engine_listener_get_direction(&self.engine, 0);
    }

    pub fn getListenerWorldUp(self: *DigitalDriver) ma.ma_vec3f {
        return ma.ma_engine_listener_get_world_up(&self.engine, 0);
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

pub const Sample = struct {
    driver: *DigitalDriver,
    sound: ma.ma_sound,
    decoder: ?*ma.ma_decoder = null,
    is_initialized: bool = false,
    is_done: bool = false, // true when all loops exhausted (avoids false .done from ma_sound_at_end)
    is_paused: bool = false, // MSS: paused samples still report SMP_PLAYING (4)
    volume: f32 = 1.0,
    original_volume: i32 = 127,
    pan: f32 = 0.0,
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
    cached_length_frames: u64 = 0,
    reverb_node: ?*ma.ma_delay_node = null,
    reverb_room_type: f32 = 0.0,
    reverb_level: f32 = 0.0,
    reverb_reflect_time: f32 = 0.0,

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
        // Fire EOB (End Of Buffer) callback — used by double-buffer streaming games to refill buffers.
        // Signature: void callback(HSAMPLE S, S32 buff_num, U32 buff_size, void const *buff_addr)
        if (self.eob_callback != 0) {
            const buf_ptr: ?*anyopaque = if (self.owned_buffer) |b| @ptrCast(b.ptr) else null;
            const buf_len: u32 = if (self.owned_buffer) |b| @intCast(@min(b.len, std.math.maxInt(u32))) else 0;
            const cb: *const fn (?*anyopaque, i32, u32, ?*anyopaque) callconv(.winapi) void = @ptrFromInt(self.eob_callback);
            cb(@ptrCast(self), self.last_loaded_buffer, buf_len, buf_ptr);
        }
        if (self.eos_callback != 0) {
            const cb: *const fn (?*anyopaque) callconv(.winapi) void = @ptrFromInt(self.eos_callback);
            cb(@ptrCast(self));
        }
    }

    pub fn init(driver: *DigitalDriver) !*Sample {
        const self = try driver.allocator.create(Sample);
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
        if (self.is_initialized) {
            ma.ma_sound_uninit(&self.sound);
        }
        if (self.decoder) |d| {
            _ = ma.ma_decoder_uninit(d);
            self.driver.allocator.destroy(d);
        }
        if (self.bounded_mem_ctx) |ctx| {
            self.driver.allocator.destroy(ctx);
        }
        if (self.owned_buffer) |buf| {
            self.driver.allocator.free(buf);
        }
        self.driver.allocator.destroy(self);
    }

    fn cleanupPlaybackState(self: *Sample) void {
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
        self.decoder = decoder;
        self.is_initialized = true;
        self.is_done = false;
        self.is_paused = false;
        _ = ma.ma_sound_get_length_in_pcm_frames(&self.sound, &self.cached_length_frames);

        if (self.target_rate) |tr| {
            const native_rate = @as(f32, @floatFromInt(decoder.outputSampleRate));
            self.pitch = tr / native_rate;
        }

        log("Sample.loadFromOwnedMemory success: s={*}, vol={d}, pan={d}, pitch={d}, loop={d}\n", .{ self, self.volume, self.pan, self.pitch, self.loop_count });
        ma.ma_sound_set_volume(&self.sound, self.volume);
        ma.ma_sound_set_pan(&self.sound, self.pan);
        ma.ma_sound_set_pitch(&self.sound, self.pitch);
        ma.ma_sound_set_looping(&self.sound, 0);
        _ = ma.ma_sound_set_end_callback(&self.sound, Sample.eosCallbackBridge, self);
        if (self.loop_end_frame > 0) {
            _ = ma.ma_data_source_set_range_in_pcm_frames(decoder, 0, self.loop_end_frame);
        }
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
        if (detected > 0) {
            // Format recognized — for WAV/AIFF this is the real size; for streaming
            // formats (OGG/MP3/FLAC) it is a 16 MB sentinel window.
            log("Sample.loadFromUnownedMemoryUnknownSize detected size: {d}\n", .{detected});
            try self.loadFromMemory(data_ptr[0..detected], false);
        } else {
            // Format unrecognized (detected == 0) — use bounded decoder as a safe
            // fallback to avoid creating a Zig slice past the real allocation.
            log("Sample.loadFromUnownedMemoryUnknownSize using bounded decoder (unknown format)\n", .{});
            try self.loadFromBoundedPointer(data_ptr, root.streaming_sentinel_size);
        }
    }

    /// Load audio from a raw pointer using custom ma_decoder read/seek callbacks.
    /// This avoids creating a Zig slice of unknown length — miniaudio reads through
    /// callbacks that bounds-check against `max_size`, returning EOF if exceeded.
    fn loadFromBoundedPointer(self: *Sample, data_ptr: [*]const u8, max_size: usize) !void {
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
            self.driver.allocator.destroy(ctx);
            return error.DecoderInitFailed;
        }

        result = ma.ma_sound_init_from_data_source(&self.driver.engine, @ptrCast(decoder), ma.MA_SOUND_FLAG_NO_SPATIALIZATION, null, &self.sound);
        if (result != ma.MA_SUCCESS) {
            _ = ma.ma_decoder_uninit(decoder);
            self.driver.allocator.destroy(ctx);
            return error.SampleLoadFailed;
        }
        self.decoder = decoder;
        self.bounded_mem_ctx = ctx;
        self.is_initialized = true;
        self.is_done = false;
        self.is_paused = false;
        _ = ma.ma_sound_get_length_in_pcm_frames(&self.sound, &self.cached_length_frames);

        if (self.target_rate) |tr| {
            const native_rate = @as(f32, @floatFromInt(decoder.outputSampleRate));
            self.pitch = tr / native_rate;
        }

        log("Sample.loadFromBoundedPointer success: s={*}, vol={d}, pan={d}, pitch={d}, loop={d}\n", .{ self, self.volume, self.pan, self.pitch, self.loop_count });
        ma.ma_sound_set_volume(&self.sound, self.volume);
        ma.ma_sound_set_pan(&self.sound, self.pan);
        ma.ma_sound_set_pitch(&self.sound, self.pitch);
        ma.ma_sound_set_looping(&self.sound, 0);
        _ = ma.ma_sound_set_end_callback(&self.sound, Sample.eosCallbackBridge, self);
        if (self.loop_end_frame > 0) {
            _ = ma.ma_data_source_set_range_in_pcm_frames(decoder, 0, self.loop_end_frame);
        }
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
        self.decoder = decoder;
        self.is_initialized = true;
        self.is_done = false;
        self.is_paused = false;
        _ = ma.ma_sound_get_length_in_pcm_frames(&self.sound, &self.cached_length_frames);

        if (self.target_rate) |tr| {
            const native_rate = @as(f32, @floatFromInt(decoder.outputSampleRate));
            self.pitch = tr / native_rate;
        }

        log("Sample.loadFromMemory success: s={*}, vol={d}, pan={d}, pitch={d}, loop={d}\n", .{ self, self.volume, self.pan, self.pitch, self.loop_count });
        ma.ma_sound_set_volume(&self.sound, self.volume);
        ma.ma_sound_set_pan(&self.sound, self.pan);
        ma.ma_sound_set_pitch(&self.sound, self.pitch);
        // Disable miniaudio looping on load; start() re-enables it for infinite loops (count == 0).
        // Finite loop counting is handled in the EOS callback.
        ma.ma_sound_set_looping(&self.sound, 0);
        _ = ma.ma_sound_set_end_callback(&self.sound, Sample.eosCallbackBridge, self);
        // Re-apply loop end range if set
        if (self.loop_end_frame > 0) {
            _ = ma.ma_data_source_set_range_in_pcm_frames(decoder, 0, self.loop_end_frame);
        }
    }

    pub fn loadFromFile(self: *Sample, path: []const u8) !void {
        // Read file into memory so owned_buffer is set (required for AIL_quick_copy)
        const file = fs_compat.openFile(path, .{}) catch return error.FileNotFound;
        defer file.close();
        const stat_size = (file.stat() catch return error.FileNotFound).size;
        if (stat_size <= 0) return error.FileNotFound;
        const size: usize = @intCast(stat_size);
        const buf = try self.driver.allocator.alloc(u8, size);
        errdefer self.driver.allocator.free(buf);
        _ = file.readAll(buf) catch return error.FileNotFound;
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
            const rate: u32 = if (self.target_rate) |r| @intFromFloat(r) else 22050;
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

    pub fn reset(self: *Sample) void {
        self.removeReverb();
        if (self.is_initialized) _ = ma.ma_sound_stop(&self.sound);
        self.cleanupPlaybackState();
        self.volume = 1.0;
        self.original_volume = 127;
        self.pan = 0.0;
        self.pitch = 1.0;
        self.target_rate = null;
        self.loop_count = 1;
        self.loops_remaining = 1;
        self.loop_start_frame = 0;
        self.loop_end_frame = 0;
        self.is_done = false;
        self.is_paused = false;
        self.eos_callback = 0;
        self.eob_callback = 0;
        self.sob_callback = 0;
        self.pcm_format = null;
        self.last_loaded_buffer = 0;
        self.user_data = [_]u32{0} ** 8;
    }

    pub fn start(self: *Sample) void {
        log("Sample.start: s={*}\n", .{self});
        self.loops_remaining = self.loop_count;
        self.is_done = false;
        self.is_paused = false;
        if (self.is_initialized) {
            if (self.loop_count == 0) {
                ma.ma_sound_set_looping(&self.sound, ma.MA_TRUE);
            } else {
                ma.ma_sound_set_looping(&self.sound, ma.MA_FALSE);
            }
            // AIL_start_sample resumes from the current position unless the sample has reached the end.
            if (ma.ma_sound_at_end(&self.sound) != 0) {
                _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, 0);
            }

            const res = ma.ma_sound_start(&self.sound);
            log("Sample.start: ma_sound_start returned {d}\n", .{res});
        }
        if (self.sob_callback != 0) {
            const buf_ptr: ?*anyopaque = if (self.owned_buffer) |b| @ptrCast(b.ptr) else null;
            const buf_len: u32 = if (self.owned_buffer) |b| @intCast(@min(b.len, std.math.maxInt(u32))) else 0;
            const cb: *const fn (?*anyopaque, i32, u32, ?*anyopaque) callconv(.winapi) void = @ptrFromInt(self.sob_callback);
            cb(@ptrCast(self), self.last_loaded_buffer, buf_len, buf_ptr);
        }
    }

    pub fn stop(self: *Sample) void {
        log("Sample.stop: s={*}\n", .{self});
        if (self.is_initialized) {
            _ = ma.ma_sound_stop(&self.sound);
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, self.loop_start_frame);
        }
        self.is_done = false;
        self.is_paused = false;
    }

    pub fn end(self: *Sample) void {
        if (self.is_initialized) {
            _ = ma.ma_sound_stop(&self.sound);
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, 0);
        }
        self.is_done = true;
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
            return .stopped;
        }
        return .stopped;
    }

    pub fn setVolume(self: *Sample, volume: i32) void {
        self.original_volume = volume;
        self.volume = root.mssVolumeToGain(volume);
        log("Sample.setVolume: s={*}, i32={d}, gain={d}\n", .{ self, volume, self.volume });
        if (self.is_initialized) ma.ma_sound_set_volume(&self.sound, self.volume);
    }

    pub fn setPan(self: *Sample, pan: i32) void {
        self.pan = std.math.clamp((@as(f32, @floatFromInt(pan)) - 64.0) / 64.0, -1.0, 1.0);
        log("Sample.setPan: s={*}, i32={d}, f32={d}\n", .{ self, pan, self.pan });
        if (self.is_initialized) ma.ma_sound_set_pan(&self.sound, self.pan);
    }

    pub fn setVolumePan(self: *Sample, volume: i32, pan: i32) void {
        self.setVolume(volume);
        self.setPan(pan);
    }

    /// Set reverb parameters for this sample. Creates or updates a ma_delay_node
    /// inserted between the sample's sound and the engine endpoint.
    pub fn setReverb(self: *Sample, room_type: f32, level: f32, reflect_time: f32) void {
        self.reverb_room_type = room_type;
        self.reverb_level = level;
        self.reverb_reflect_time = reflect_time;
        log("Sample.setReverb: s={*}, room={d}, level={d}, time={d}\n", .{ self, room_type, level, reflect_time });

        if (level <= 0.001 or reflect_time <= 0.001) {
            self.removeReverb();
            return;
        }
        if (!self.is_initialized) return;

        const sample_rate = ma.ma_engine_get_sample_rate(&self.driver.engine);
        const channels = ma.ma_engine_get_channels(&self.driver.engine);
        const delay_frames: u32 = @intFromFloat(@max(1.0, reflect_time * @as(f32, @floatFromInt(sample_rate))));
        // Map room_type to decay: higher room_type = longer decay tail
        const decay: f32 = @min(0.95, room_type * 0.15);

        if (self.reverb_node) |node| {
            ma.ma_delay_node_set_wet(node, level);
            ma.ma_delay_node_set_dry(node, 1.0 - level * 0.5);
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
            ma.ma_delay_node_set_dry(node, 1.0 - level * 0.5);
            self.reverb_node = node;
        }
    }

    /// Remove reverb from this sample, re-routing sound directly to the endpoint.
    fn removeReverb(self: *Sample) void {
        if (self.reverb_node) |node| {
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
        }
    }

    pub fn getReverb(self: *const Sample) struct { room_type: f32, level: f32, reflect_time: f32 } {
        return .{
            .room_type = self.reverb_room_type,
            .level = self.reverb_level,
            .reflect_time = self.reverb_reflect_time,
        };
    }

    pub fn setPlaybackRate(self: *Sample, rate: i32) void {
        const tr = @as(f32, @floatFromInt(rate));
        self.target_rate = tr;
        if (self.is_initialized) {
            if (self.decoder) |d| {
                const native_rate = @as(f32, @floatFromInt(d.outputSampleRate));
                self.pitch = tr / native_rate;
                log("Sample.setPlaybackRate: s={*}, rate={d}, native={d}, pitch={d}\n", .{ self, rate, native_rate, self.pitch });
                ma.ma_sound_set_pitch(&self.sound, self.pitch);
            }
        } else {
            log("Sample.setPlaybackRate: s={*}, rate={d} (deferred)\n", .{ self, rate });
        }
    }

    pub fn setLoopCount(self: *Sample, count: i32) void {
        self.loop_count = count;
        self.loops_remaining = count;
        log("Sample.setLoopCount: s={*}, count={d}\n", .{ self, count });
        // MSS uses 0 for infinite looping.
        if (self.is_initialized) {
            if (count == 0) {
                ma.ma_sound_set_looping(&self.sound, ma.MA_TRUE);
            } else {
                ma.ma_sound_set_looping(&self.sound, ma.MA_FALSE);
            }
        }
    }

    fn bytesPerFrame(self: *const Sample) u32 {
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
            const frame: u64 = if (bpf > 0) pos / bpf else 0;
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, frame);
        }
    }

    pub const MsPosition = struct { total: i32, current: i32 };

    pub fn getMsPosition(self: *Sample) MsPosition {
        var pos = MsPosition{ .total = 0, .current = 0 };
        if (self.is_initialized and self.decoder != null) {
            var cursor: u64 = 0;
            _ = ma.ma_sound_get_cursor_in_pcm_frames(&self.sound, &cursor);
            const rate = @as(f32, @floatFromInt(self.decoder.?.outputSampleRate));
            const ms_per_frame = 1000.0 / rate;
            pos.current = @as(i32, @intFromFloat(@as(f32, @floatFromInt(cursor)) * ms_per_frame));
            pos.total = @as(i32, @intFromFloat(@as(f32, @floatFromInt(self.cached_length_frames)) * ms_per_frame));
        }
        return pos;
    }

    pub fn setMsPosition(self: *Sample, ms: i32) void {
        if (self.is_initialized and self.decoder != null) {
            const rate = @as(f32, @floatFromInt(self.decoder.?.outputSampleRate));
            const frame = @as(u64, @intFromFloat(@as(f32, @floatFromInt(ms)) * rate / 1000.0));
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
    effects_level: f32 = 0.0,
    auto_update: bool = false,
    velocity_x: f32 = 0.0,
    velocity_y: f32 = 0.0,
    velocity_z: f32 = 0.0,
    pos_x: f32 = 0.0,
    pos_y: f32 = 0.0,
    pos_z: f32 = 0.0,
    min_distance: f32 = 1.0,
    max_distance: f32 = 100.0,
    cone_inner_rad: f32 = 360.0 * deg2rad,
    cone_outer_rad: f32 = 360.0 * deg2rad,
    cone_outer_volume: f32 = 1.0,
    orient_fx: f32 = 0.0,
    orient_fy: f32 = 0.0,
    orient_fz: f32 = 1.0,
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

    pub fn init(driver: *DigitalDriver) !*Sample3D {
        const self = try driver.allocator.create(Sample3D);
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
        if (self.is_initialized) {
            ma.ma_sound_uninit(&self.sound);
        }
        if (self.decoder) |d| {
            _ = ma.ma_decoder_uninit(d);
            self.driver.allocator.destroy(d);
        }
        if (self.bounded_mem_ctx) |ctx| {
            self.driver.allocator.destroy(ctx);
        }
        if (self.owned_buffer) |buf| {
            self.driver.allocator.free(buf);
        }
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
        self.decoder = decoder;
        self.is_initialized = true;
        self.is_done = false;
        self.is_paused = false;
        _ = ma.ma_sound_get_length_in_pcm_frames(&self.sound, &self.cached_length_frames);

        if (self.target_rate) |tr| {
            const native_rate = @as(f32, @floatFromInt(decoder.outputSampleRate));
            self.pitch = tr / native_rate;
        }

        ma.ma_sound_set_volume(&self.sound, self.volume);
        ma.ma_sound_set_pitch(&self.sound, self.pitch);
        ma.ma_sound_set_looping(&self.sound, 0);
        _ = ma.ma_sound_set_end_callback(&self.sound, Sample3D.eosCallbackBridge, self);
        if (self.loop_end_frame > 0) {
            _ = ma.ma_data_source_set_range_in_pcm_frames(decoder, 0, self.loop_end_frame);
        }
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
        self.decoder = decoder;
        self.is_initialized = true;
        self.is_done = false;
        self.is_paused = false;
        _ = ma.ma_sound_get_length_in_pcm_frames(&self.sound, &self.cached_length_frames);

        if (self.target_rate) |tr| {
            const native_rate = @as(f32, @floatFromInt(decoder.outputSampleRate));
            self.pitch = tr / native_rate;
        }

        self.applyVolume();
        ma.ma_sound_set_pitch(&self.sound, self.pitch);
        ma.ma_sound_set_looping(&self.sound, 0);
        _ = ma.ma_sound_set_end_callback(&self.sound, Sample3D.eosCallbackBridge, self);
        if (self.driver.rolloff_factor != 1.0) ma.ma_sound_set_rolloff(&self.sound, self.driver.rolloff_factor);
        if (self.driver.doppler_factor != 1.0) ma.ma_sound_set_doppler_factor(&self.sound, self.driver.doppler_factor);
        // Re-apply stored spatial settings (may have been set before audio loaded)
        ma.ma_sound_set_position(&self.sound, self.pos_x, self.pos_y, self.pos_z);
        ma.ma_sound_set_velocity(&self.sound, self.velocity_x, self.velocity_y, self.velocity_z);
        ma.ma_sound_set_min_distance(&self.sound, self.min_distance);
        ma.ma_sound_set_max_distance(&self.sound, self.max_distance);
        self.applyCone();
        ma.ma_sound_set_direction(&self.sound, self.orient_fx, self.orient_fy, self.orient_fz);
        if (self.loop_end_frame > 0) {
            _ = ma.ma_data_source_set_range_in_pcm_frames(decoder, 0, self.loop_end_frame);
        }
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
            self.driver.allocator.destroy(ctx);
            return error.DecoderInitFailed;
        }

        result = ma.ma_sound_init_from_data_source(&self.driver.engine, @ptrCast(decoder), 0, null, &self.sound);
        if (result != ma.MA_SUCCESS) {
            _ = ma.ma_decoder_uninit(decoder);
            self.driver.allocator.destroy(ctx);
            return error.SoundInitFailed;
        }
        self.decoder = decoder;
        self.bounded_mem_ctx = ctx;
        self.is_initialized = true;
        self.is_done = false;
        self.is_paused = false;
        _ = ma.ma_sound_get_length_in_pcm_frames(&self.sound, &self.cached_length_frames);

        if (self.target_rate) |tr| {
            const native_rate = @as(f32, @floatFromInt(decoder.outputSampleRate));
            self.pitch = tr / native_rate;
        }

        self.applyVolume();
        ma.ma_sound_set_pitch(&self.sound, self.pitch);
        ma.ma_sound_set_looping(&self.sound, 0);
        _ = ma.ma_sound_set_end_callback(&self.sound, Sample3D.eosCallbackBridge, self);
        if (self.driver.rolloff_factor != 1.0) ma.ma_sound_set_rolloff(&self.sound, self.driver.rolloff_factor);
        if (self.driver.doppler_factor != 1.0) ma.ma_sound_set_doppler_factor(&self.sound, self.driver.doppler_factor);
        ma.ma_sound_set_position(&self.sound, self.pos_x, self.pos_y, self.pos_z);
        ma.ma_sound_set_velocity(&self.sound, self.velocity_x, self.velocity_y, self.velocity_z);
        ma.ma_sound_set_min_distance(&self.sound, self.min_distance);
        ma.ma_sound_set_max_distance(&self.sound, self.max_distance);
        self.applyCone();
        ma.ma_sound_set_direction(&self.sound, self.orient_fx, self.orient_fy, self.orient_fz);
        if (self.loop_end_frame > 0) {
            _ = ma.ma_data_source_set_range_in_pcm_frames(decoder, 0, self.loop_end_frame);
        }
    }

    pub fn loadFromUnownedPointer(self: *Sample3D, data_ptr: [*]const u8) !void {
        const detected = root.detectAudioSize(data_ptr);
        if (detected > 0 and detected != root.streaming_sentinel_size) {
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
        if (self.is_initialized) {
            if (self.loop_count == 0) {
                ma.ma_sound_set_looping(&self.sound, ma.MA_TRUE);
            } else {
                ma.ma_sound_set_looping(&self.sound, ma.MA_FALSE);
            }
            if (ma.ma_sound_at_end(&self.sound) != 0) {
                _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, 0);
            }
            _ = ma.ma_sound_start(&self.sound);
        }
    }

    pub fn stop(self: *Sample3D) void {
        if (self.is_initialized) {
            _ = ma.ma_sound_stop(&self.sound);
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, self.loop_start_frame);
        }
        self.is_done = false;
        self.is_paused = false;
    }

    pub fn end(self: *Sample3D) void {
        if (self.is_initialized) {
            _ = ma.ma_sound_stop(&self.sound);
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, 0);
        }
        self.is_done = true;
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
            return .stopped;
        }
        return .stopped;
    }

    pub fn applyCone(self: *Sample3D) void {
        if (self.is_initialized) {
            ma.ma_sound_set_cone(&self.sound, self.cone_inner_rad, self.cone_outer_rad, self.cone_outer_volume);
        }
    }

    fn applyVolume(self: *Sample3D) void {
        if (self.is_initialized) {
            // Obstruction: attenuates direct sound path (0=clear, 1=fully blocked)
            // Occlusion: attenuates all sound paths (0=clear, 1=fully occluded)
            const eff = self.volume * (1.0 - self.obstruction * 0.5) * (1.0 - self.occlusion);
            ma.ma_sound_set_volume(&self.sound, @max(0.0, eff));
        }
    }

    pub fn setVolume(self: *Sample3D, volume: i32) void {
        self.original_volume = volume;
        self.volume = root.mssVolumeToGain(volume);
        self.applyVolume();
    }

    pub fn setObstruction(self: *Sample3D, val: f32) void {
        self.obstruction = @min(1.0, @max(0.0, val));
        self.applyVolume();
    }

    pub fn setOcclusion(self: *Sample3D, val: f32) void {
        self.occlusion = @min(1.0, @max(0.0, val));
        self.applyVolume();
    }

    pub fn setLoopCount(self: *Sample3D, count: i32) void {
        self.loop_count = count;
        self.loops_remaining = count;
        if (self.is_initialized) {
            if (count == 0) {
                ma.ma_sound_set_looping(&self.sound, ma.MA_TRUE);
            } else {
                ma.ma_sound_set_looping(&self.sound, ma.MA_FALSE);
            }
        }
    }

    pub fn setPlaybackRate(self: *Sample3D, rate: i32) void {
        const tr = @as(f32, @floatFromInt(rate));
        self.target_rate = tr;
        if (self.is_initialized) {
            if (self.decoder) |d| {
                const native_rate = @as(f32, @floatFromInt(d.outputSampleRate));
                self.pitch = tr / native_rate;
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
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, if (bpf > 0) pos / bpf else 0);
        }
    }

    pub fn getLength(self: *Sample3D) u32 {
        if (self.is_initialized) {
            const bpf = self.bytesPerFrame();
            return @as(u32, @intCast(@min(self.cached_length_frames * @as(u64, bpf), std.math.maxInt(u32))));
        }
        return 0;
    }

    pub fn getMsPosition(self: *Sample3D) Sample.MsPosition {
        var pos = Sample.MsPosition{ .total = 0, .current = 0 };
        if (self.is_initialized and self.decoder != null) {
            var cursor: u64 = 0;
            _ = ma.ma_sound_get_cursor_in_pcm_frames(&self.sound, &cursor);
            const rate = @as(f32, @floatFromInt(self.decoder.?.outputSampleRate));
            const ms_per_frame = 1000.0 / rate;
            pos.current = @as(i32, @intFromFloat(@as(f32, @floatFromInt(cursor)) * ms_per_frame));
            pos.total = @as(i32, @intFromFloat(@as(f32, @floatFromInt(self.cached_length_frames)) * ms_per_frame));
        }
        return pos;
    }

    pub fn setMsPosition(self: *Sample3D, ms: i32) void {
        if (self.is_initialized and self.decoder != null) {
            const rate = @as(f32, @floatFromInt(self.decoder.?.outputSampleRate));
            const frame = @as(u64, @intFromFloat(@as(f32, @floatFromInt(ms)) * rate / 1000.0));
            _ = ma.ma_sound_seek_to_pcm_frame(&self.sound, frame);
        }
    }

    pub fn setMinMaxDistance(self: *Sample3D, min_dist: f32, max_dist: f32) void {
        self.min_distance = min_dist;
        self.max_distance = max_dist;
        if (self.is_initialized) {
            ma.ma_sound_set_min_distance(&self.sound, min_dist);
            ma.ma_sound_set_max_distance(&self.sound, max_dist);
        }
    }

    pub fn setPosition(self: *Sample3D, x: f32, y: f32, z: f32) void {
        self.pos_x = x;
        self.pos_y = y;
        self.pos_z = z;
        if (self.is_initialized) {
            ma.ma_sound_set_position(&self.sound, x, y, z);
        }
    }
    pub fn setVelocity(self: *Sample3D, x: f32, y: f32, z: f32) void {
        self.velocity_x = x;
        self.velocity_y = y;
        self.velocity_z = z;
        if (self.is_initialized) {
            ma.ma_sound_set_velocity(&self.sound, x, y, z);
        }
    }

    pub fn updatePosition(self: *Sample3D, dt_s: f32) void {
        if (!self.auto_update or !self.is_initialized) return;
        if (self.velocity_x == 0 and self.velocity_y == 0 and self.velocity_z == 0) return;
        self.pos_x += self.velocity_x * dt_s;
        self.pos_y += self.velocity_y * dt_s;
        self.pos_z += self.velocity_z * dt_s;
        ma.ma_sound_set_position(&self.sound, self.pos_x, self.pos_y, self.pos_z);
    }
    pub fn setOrientation(self: *Sample3D, fx: f32, fy: f32, fz: f32, ux: f32, uy: f32, uz: f32) void {
        self.orient_fx = fx;
        self.orient_fy = fy;
        self.orient_fz = fz;
        self.orient_ux = ux;
        self.orient_uy = uy;
        self.orient_uz = uz;
        if (self.is_initialized) {
            ma.ma_sound_set_direction(&self.sound, fx, fy, fz);
        }
    }
};

const std = @import("std");
const root = @import("../root.zig");
const ma = root.ma;
const log = root.log;

/// Audio capture device wrapping a miniaudio ma_device in capture mode.
/// Created via AIL_open_input, controlled via AIL_set_input_state, queried
/// via AIL_get_input_info.
pub const Input = struct {
    device: ma.ma_device,
    allocator: std.mem.Allocator,
    state: i32 = 0, // 0 = stopped, 1 = recording
    sample_rate: u32 = 44100,
    channels: u32 = 1,
    bits: u32 = 16,
    // Ring buffer of captured PCM (bounded to ~1 second)
    buffer: std.ArrayListUnmanaged(u8) = .{},
    max_buffer_bytes: usize = 44100 * 2, // 1s of 16-bit mono
    mutex: std.Thread.Mutex = .{},
    is_initialized: bool = false,
    // Snapshot of the buffer handed to getInfo(). Lives until the next getInfo()
    // call so the caller's returned pointer remains valid even while capture continues.
    snapshot: std.ArrayListUnmanaged(u8) = .{},

    pub fn init(allocator: std.mem.Allocator) !*Input {
        const self = try allocator.create(Input);
        self.* = .{
            .device = undefined,
            .allocator = allocator,
        };

        var config = ma.ma_device_config_init(ma.ma_device_type_capture);
        config.capture.format = ma.ma_format_s16;
        config.capture.channels = self.channels;
        config.sampleRate = self.sample_rate;
        config.dataCallback = captureCallback;
        config.pUserData = @ptrCast(self);

        const result = ma.ma_device_init(null, &config, &self.device);
        if (result != ma.MA_SUCCESS) {
            log("Input.init: ma_device_init failed: {d}\n", .{result});
            allocator.destroy(self);
            return error.CaptureDeviceInitFailed;
        }
        self.is_initialized = true;
        self.max_buffer_bytes = self.sample_rate * self.channels * (self.bits / 8);
        // Pre-allocate so the audio-thread callback never hits the allocator.
        self.buffer.ensureTotalCapacity(self.allocator, self.max_buffer_bytes) catch {};
        self.snapshot.ensureTotalCapacity(self.allocator, self.max_buffer_bytes) catch {};
        return self;
    }

    pub fn deinit(self: *Input) void {
        if (self.is_initialized) {
            _ = ma.ma_device_stop(&self.device);
            ma.ma_device_uninit(&self.device);
        }
        self.buffer.deinit(self.allocator);
        self.snapshot.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn start(self: *Input) void {
        if (!self.is_initialized) return;
        _ = ma.ma_device_start(&self.device);
        @atomicStore(i32, &self.state, 1, .release);
    }

    pub fn stop(self: *Input) void {
        if (!self.is_initialized) return;
        _ = ma.ma_device_stop(&self.device);
        @atomicStore(i32, &self.state, 0, .release);
    }

    fn captureCallback(pDevice: ?*ma.ma_device, pOutput: ?*anyopaque, pInput: ?*const anyopaque, frameCount: ma.ma_uint32) callconv(.c) void {
        _ = pOutput;
        const self: *Input = @ptrCast(@alignCast(pDevice.?.pUserData));
        const in_ptr: [*]const u8 = @ptrCast(pInput.?);
        const bytes_per_frame = self.channels * (self.bits / 8);
        const byte_count: usize = @as(usize, frameCount) * bytes_per_frame;
        // Truncate incoming chunks larger than the ring capacity (keep the tail).
        const incoming = if (byte_count > self.max_buffer_bytes)
            in_ptr[(byte_count - self.max_buffer_bytes)..byte_count]
        else
            in_ptr[0..byte_count];

        if (!self.mutex.tryLock()) return;
        defer self.mutex.unlock();

        // Ring-buffer behavior: drop oldest data if we exceed max_buffer_bytes
        if (self.buffer.items.len + incoming.len > self.max_buffer_bytes) {
            const overflow = (self.buffer.items.len + incoming.len) - self.max_buffer_bytes;
            if (overflow >= self.buffer.items.len) {
                self.buffer.clearRetainingCapacity();
            } else {
                std.mem.copyForwards(u8, self.buffer.items[0..], self.buffer.items[overflow..]);
                self.buffer.items.len -= overflow;
            }
        }
        if (self.buffer.capacity >= self.buffer.items.len + incoming.len) {
            self.buffer.appendSliceAssumeCapacity(incoming);
        }
        // else: silently drop — never allocate on the audio thread
    }

    /// Capture state for basic query (rate, channels, bits, data buffer).
    pub const InputInfo = extern struct {
        format: u32 = 0,
        data_ptr: ?*const anyopaque = null,
        data_len: u32 = 0,
        rate: u32 = 0,
        bits: u32 = 0,
        channels: u32 = 0,
        samples: u32 = 0,
        block_size: u32 = 0,
        initial_ptr: ?*const anyopaque = null,
    };

    pub fn getInfo(self: *Input) InputInfo {
        self.mutex.lock();
        // Swap buffer and snapshot under the lock — O(1) instead of copying.
        // The old buffer becomes the snapshot (caller reads it); the old
        // snapshot (cleared) becomes the new capture target.
        const tmp = self.snapshot;
        self.snapshot = self.buffer;
        self.buffer = tmp;
        self.buffer.clearRetainingCapacity();
        self.mutex.unlock();
        const bytes_per_sample = self.channels * (self.bits / 8);
        const samples: u32 = if (bytes_per_sample == 0) 0 else @as(u32, @intCast(self.snapshot.items.len)) / bytes_per_sample;
        return .{
            .format = 0,
            .data_ptr = if (self.snapshot.items.len > 0) @ptrCast(self.snapshot.items.ptr) else null,
            .data_len = @intCast(self.snapshot.items.len),
            .rate = self.sample_rate,
            .bits = self.bits,
            .channels = self.channels,
            .samples = samples,
            .block_size = bytes_per_sample,
            .initial_ptr = null,
        };
    }
};

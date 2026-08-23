//! Double-buffered streaming source for the MSS buffer-feed API.
//!
//! MSS lets an app stream raw PCM by ping-ponging app-owned buffers: it polls
//! `AIL_sample_buffer_ready` for a free slot, fills it with `AIL_load_sample_buffer`,
//! and the mixer drains the ring in order, firing the End-Of-Buffer callback as
//! each buffer drains so the app can refill it. A zero-length buffer signals
//! end-of-stream. The SDK ring depth is configurable (AIL_set_sample_buffer_count,
//! 2..8); this source carries up to that many slots so the configured ring count
//! and the transport can never disagree (a submission beyond the transport would
//! otherwise be silently dropped while the loader reported success).
//!
//! This implements that contract as a custom `ma_data_source`: buffers are
//! referenced in place (never copied — the app owns them until its EOB fires) and
//! the engine's resampler/converter handles format adaptation to the device.

const std = @import("std");
const root = @import("../root.zig");
const ma = root.ma;
const io = root.io;

/// Signature of the End-Of-Buffer hook: (ctx, buffer_index, buffer_len, buffer_addr).
pub const EobHook = *const fn (?*anyopaque, i32, u32, ?*anyopaque) void;

const Slot = struct {
    data: ?[*]const u8 = null,
    len: usize = 0,
    pos: usize = 0,
    eof: bool = false, // app submitted a zero-length buffer (end of stream)
};

pub const StreamSource = struct {
    /// Maximum ring depth (MILES sample buffer count limit, mss.h: 2..8).
    pub const max_slots: usize = 8;

    base: ma.ma_data_source_base = undefined,
    format: ma.ma_format = ma.ma_format_s16,
    channels: u32 = 2,
    sample_rate: u32 = 22050,
    frame_size: usize = 4,
    mutex: std.Io.Mutex = .init,
    slots: [max_slots]Slot = [_]Slot{.{}} ** max_slots,
    // Active ring depth. Fixed at stream creation from the sample's configured
    // buffer count (AIL_set_sample_buffer_count); indices beyond it are invalid.
    slot_count: usize = 2,
    current: usize = 0,
    cursor_frames: u64 = 0,
    starved: bool = false,
    ended: bool = false,
    eob_hook: ?EobHook = null,
    hook_ctx: ?*anyopaque = null,

    var vtable: ma.ma_data_source_vtable = .{
        .onRead = onRead,
        .onSeek = onSeek,
        .onGetDataFormat = onGetDataFormat,
        .onGetCursor = onGetCursor,
        .onGetLength = onGetLength,
        .onSetLooping = null,
        .flags = 0,
    };

    /// `bits` is 8 or 16; 8-bit is treated as unsigned PCM, 16-bit as signed,
    /// matching the MSS DIG_F_* raw formats.
    pub fn init(self: *StreamSource, bits: u16, channels: u16, sample_rate: u32, hook: ?EobHook, ctx: ?*anyopaque) !void {
        // A zero channel count yields frame_size==0, which would divide-by-zero
        // in the read path. Reject it at the boundary rather than crash later.
        if (channels == 0) return error.InvalidParam;
        const fmt: ma.ma_format = if (bits <= 8) ma.ma_format_u8 else ma.ma_format_s16;
        const bytes_per_sample: usize = if (bits <= 8) 1 else 2;
        self.* = .{
            .format = fmt,
            .channels = channels,
            .sample_rate = sample_rate,
            .frame_size = bytes_per_sample * @as(usize, channels),
            .eob_hook = hook,
            .hook_ctx = ctx,
        };
        var cfg = ma.ma_data_source_config_init();
        cfg.vtable = &vtable;
        if (ma.ma_data_source_init(&cfg, &self.base) != ma.MA_SUCCESS) return error.StreamInitFailed;
    }

    pub fn deinit(self: *StreamSource) void {
        ma.ma_data_source_uninit(&self.base);
    }

    /// Submit a buffer into slot `index`. A zero `len` marks end-of-stream.
    pub fn loadBuffer(self: *StreamSource, index: usize, data: ?*const anyopaque, len: usize) void {
        if (index >= self.slot_count) return;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (len == 0 or data == null) {
            self.slots[index] = .{ .eof = true };
        } else {
            self.slots[index] = .{ .data = @ptrCast(data), .len = len, .pos = 0 };
        }
        self.starved = false;
        self.ended = false;
    }

    /// Index of a slot free to be filled, or -1 if the ring is full.
    pub fn bufferReady(self: *StreamSource) i32 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        for (0..self.slot_count) |i| {
            if (self.slots[i].data == null and !self.slots[i].eof) return @intCast(i);
        }
        return -1;
    }

    /// Whether the mixer underran (both slots empty) since the last submit.
    /// Read under the lock because `onRead` (audio thread) writes `starved`.
    pub fn isStarved(self: *StreamSource) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.starved;
    }

    pub fn bufferInfo(self: *StreamSource, pos0: *u32, len0: *u32, pos1: *u32, len1: *u32) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        pos0.* = @intCast(self.slots[0].pos);
        len0.* = @intCast(self.slots[0].len);
        pos1.* = @intCast(self.slots[1].pos);
        len1.* = @intCast(self.slots[1].len);
    }

    // --- ma_data_source vtable ---------------------------------------------

    fn onRead(pds: ?*anyopaque, frames_out: ?*anyopaque, frame_count: u64, frames_read: ?*u64) callconv(.c) ma.ma_result {
        const self: *StreamSource = @ptrCast(@alignCast(pds.?));
        const out_base: ?[*]u8 = if (frames_out) |p| @ptrCast(p) else null;
        const fc: usize = @intCast(frame_count);

        // EOB events captured under lock, fired after unlock to avoid re-entrant
        // deadlock if the app refills from within its callback. Sized so every
        // slot of the deepest ring can drain within one read.
        var eob_events: [max_slots]struct { idx: i32, len: u32, addr: ?*anyopaque } = undefined;
        var eob_n: usize = 0;
        var total: usize = 0;
        var at_end = false;

        self.mutex.lockUncancelable(io);
        while (total < fc) {
            const slot = &self.slots[self.current];

            if (slot.eof) {
                at_end = true;
                break;
            }
            if (slot.data == null) {
                // Current slot empty — advance to the next ring slot holding
                // data or an end marker; if none, underrun.
                var next: ?usize = null;
                for (1..self.slot_count) |k| {
                    const idx = (self.current + k) % self.slot_count;
                    if (self.slots[idx].data != null or self.slots[idx].eof) {
                        next = idx;
                        break;
                    }
                }
                if (next) |idx| {
                    self.current = idx;
                    continue;
                }
                self.starved = true;
                break; // leave the rest of the output as the caller-zeroed silence
            }

            const avail = slot.len - slot.pos;
            if (avail == 0) {
                // Buffer drained: capture EOB, free the slot, advance.
                if (self.eob_hook != null and eob_n < eob_events.len) {
                    eob_events[eob_n] = .{
                        .idx = @intCast(self.current),
                        .len = @intCast(slot.len),
                        .addr = @ptrCast(@constCast(slot.data)),
                    };
                    eob_n += 1;
                }
                slot.* = .{};
                self.current = (self.current + 1) % self.slot_count;
                continue;
            }

            const want_bytes = (fc - total) * self.frame_size;
            const take = @min(avail, want_bytes);
            const take_frames = take / self.frame_size;
            if (take_frames == 0) break;
            if (out_base) |ob| {
                const dst = ob + total * self.frame_size;
                @memcpy(dst[0 .. take_frames * self.frame_size], slot.data.?[slot.pos .. slot.pos + take_frames * self.frame_size]);
            }
            slot.pos += take_frames * self.frame_size;
            total += take_frames;
        }
        self.cursor_frames += total;
        if (at_end) self.ended = true;
        self.mutex.unlock(io);

        // Fire EOB callbacks outside the lock.
        if (self.eob_hook) |hook| {
            for (eob_events[0..eob_n]) |ev| {
                hook(self.hook_ctx, ev.idx, ev.len, ev.addr);
            }
        }

        // On underrun, emit silence for the unfilled remainder so the voice keeps
        // running rather than being treated as ended.
        if (!at_end and total < fc) {
            if (out_base) |ob| {
                const start = total * self.frame_size;
                const end = fc * self.frame_size;
                @memset(ob[start..end], 0);
            }
            total = fc;
        }

        if (frames_read) |fr| fr.* = total;
        return if (at_end) ma.MA_AT_END else ma.MA_SUCCESS;
    }

    fn onSeek(pds: ?*anyopaque, frame_index: u64) callconv(.c) ma.ma_result {
        // A live stream cannot seek; accept a rewind-to-0 as a no-op so the
        // engine's start path succeeds, reject everything else.
        _ = pds;
        return if (frame_index == 0) ma.MA_SUCCESS else ma.MA_NOT_IMPLEMENTED;
    }

    fn onGetDataFormat(pds: ?*anyopaque, format: ?*ma.ma_format, channels: ?*u32, sample_rate: ?*u32, channel_map: ?[*]ma.ma_channel, channel_map_cap: usize) callconv(.c) ma.ma_result {
        _ = channel_map;
        _ = channel_map_cap;
        const self: *StreamSource = @ptrCast(@alignCast(pds.?));
        if (format) |p| p.* = self.format;
        if (channels) |p| p.* = self.channels;
        if (sample_rate) |p| p.* = self.sample_rate;
        return ma.MA_SUCCESS;
    }

    fn onGetCursor(pds: ?*anyopaque, cursor: ?*u64) callconv(.c) ma.ma_result {
        const self: *StreamSource = @ptrCast(@alignCast(pds.?));
        if (cursor) |p| p.* = self.cursor_frames;
        return ma.MA_SUCCESS;
    }

    fn onGetLength(pds: ?*anyopaque, length: ?*u64) callconv(.c) ma.ma_result {
        // Streamed length is unknown/unbounded.
        _ = pds;
        if (length) |p| p.* = 0;
        return ma.MA_NOT_IMPLEMENTED;
    }
};

const std = @import("std");
const root = @import("../root.zig");
const log = root.log;
const io = root.io;

fn nowMs() i64 {
    const ts = std.Io.Timestamp.now(io, .awake);
    return @intCast(@divTrunc(ts.nanoseconds, std.time.ns_per_ms));
}

// SDK REDBOOK constants: ERROR=0, PLAYING=1, PAUSED=2, STOPPED=3. The 0 slot is
// ERROR (returned for a null handle), NOT stopped.
pub const RedbookStatus = enum(u32) {
    playing = 1,
    paused = 2,
    stopped = 3,
};

/// Software Redbook (CD audio) emulation.
///
/// Modern systems rarely have CD drives, so OpenMiles emulates a Redbook
/// handle that tracks play/pause state and track positions without doing
/// actual audio. This lets legacy games that call Redbook APIs proceed
/// normally (check tracks, request playback) even though no audio will play.
///
/// Games that treat "Redbook unavailable" as fatal will be able to
/// initialise and continue; games that expected audio feedback will
/// behave as if the CD drive is present but silent.
pub const Redbook = struct {
    allocator: std.mem.Allocator,
    drive: u32 = 0,
    current_track: u32 = 0,
    track_end: u32 = 0,
    status: RedbookStatus = .stopped,
    volume: u32 = 127,
    /// Monotonic-clock reading (ms) when playback started; paired with nowMs()
    /// so position math is immune to system-time steps (NTP, manual change).
    play_start_ms: i64 = 0,
    paused_position_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator, drive: u32) !*Redbook {
        const self = try allocator.create(Redbook);
        self.* = .{ .allocator = allocator, .drive = drive };
        return self;
    }

    pub fn deinit(self: *Redbook) void {
        self.allocator.destroy(self);
    }

    pub fn play(self: *Redbook, start: u32, end: u32) void {
        self.current_track = start;
        self.track_end = end;
        self.status = .playing;
        self.play_start_ms = nowMs();
        self.paused_position_ms = 0;
    }

    pub fn stop(self: *Redbook) void {
        self.status = .stopped;
        self.current_track = 0;
        self.paused_position_ms = 0;
    }

    pub fn pause(self: *Redbook) void {
        if (self.status == .playing) {
            self.paused_position_ms = nowMs() - self.play_start_ms;
            self.status = .paused;
        }
    }

    pub fn resumePlayback(self: *Redbook) void {
        if (self.status == .paused) {
            self.play_start_ms = nowMs() - self.paused_position_ms;
            self.status = .playing;
        }
    }

    pub fn getPosition(self: *Redbook) u32 {
        const clamp = struct {
            fn f(ms: i64) u32 {
                if (ms < 0) return 0;
                if (ms > std.math.maxInt(u32)) return std.math.maxInt(u32);
                return @intCast(ms);
            }
        }.f;
        return switch (self.status) {
            .playing => clamp(nowMs() - self.play_start_ms),
            .paused => clamp(self.paused_position_ms),
            .stopped => 0,
        };
    }

    pub fn trackCount(self: *const Redbook) u32 {
        _ = self;
        // No physical disc — most games gracefully handle 0 tracks by falling
        // back to internal music. Returning 0 is the honest answer.
        return 0;
    }
};

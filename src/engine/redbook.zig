const std = @import("std");
const root = @import("../root.zig");
const log = root.log;

fn nowMs() i64 {
    return @divTrunc(root.nowNs(), std.time.ns_per_ms);
}

// REDBOOK_* codes as src/mss.h defines them: STOPPED=0, PLAYING=1, PAUSED=2.
// The ERROR code (3) is only ever returned by the API wrapper, for a null
// handle; it is not a state a live Redbook can be in, so it is not an enum
// variant here.
pub const RedbookStatus = enum(u32) {
    stopped = 0,
    playing = 1,
    paused = 2,
};

/// The REDBOOK_ERROR code src/mss.h defines; returned when no handle is given.
pub const redbook_status_error: u32 = 3;

/// Software Redbook (CD audio) emulation.
///
/// Modern systems rarely have CD drives, so OpenMiles emulates a Redbook
/// handle that tracks play/pause state and track positions without doing
/// actual audio. Games that check tracks or request playback proceed
/// normally; games that wait for audio feedback see a present but silent
/// drive.
pub const Redbook = struct {
    allocator: std.mem.Allocator,
    current_track: u32 = 0,
    track_end: u32 = 0,
    status: RedbookStatus = .stopped,
    volume: u32 = 127,
    /// Monotonic-clock reading (ms) when playback started; paired with nowMs()
    /// so position math is immune to system-time steps (NTP, manual change).
    play_start_ms: i64 = 0,
    paused_position_ms: i64 = 0,

    pub fn init(allocator: std.mem.Allocator) !*Redbook {
        const self = try allocator.create(Redbook);
        self.* = .{ .allocator = allocator };
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

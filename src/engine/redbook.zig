const std = @import("std");
const root = @import("../root.zig");
const log = root.log;

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
pub const RedbookStatus = enum(u32) {
    stopped = 0,
    playing = 1,
    paused = 2,
};

pub const Redbook = struct {
    allocator: std.mem.Allocator,
    drive: u32 = 0,
    current_track: u32 = 0,
    track_end: u32 = 0,
    status: RedbookStatus = .stopped,
    volume: u32 = 127,
    /// Wall-clock timestamp (ms) when playback started.
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
        self.play_start_ms = std.time.milliTimestamp();
        self.paused_position_ms = 0;
    }

    pub fn stop(self: *Redbook) void {
        self.status = .stopped;
        self.current_track = 0;
        self.paused_position_ms = 0;
    }

    pub fn pause(self: *Redbook) void {
        if (self.status == .playing) {
            self.paused_position_ms = std.time.milliTimestamp() - self.play_start_ms;
            self.status = .paused;
        }
    }

    pub fn resumePlayback(self: *Redbook) void {
        if (self.status == .paused) {
            self.play_start_ms = std.time.milliTimestamp() - self.paused_position_ms;
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
            .playing => clamp(std.time.milliTimestamp() - self.play_start_ms),
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

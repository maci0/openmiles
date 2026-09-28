//! Saturating float-to-integer conversions.
//!
//! These guard the `@intFromFloat` panic against adversarial floats, which
//! reach the engine from decoded images, plugin-supplied lengths, and the
//! i32 -> f32 -> i32 round trip that carries an out-of-range value. A leaf
//! module: nothing here touches engine state, so any layer may use it.

const std = @import("std");

/// Saturating float -> i32 (NaN -> 0, out-of-range -> clamped). Guards the
/// `@intFromFloat` panic when callers feed adversarial floats -- including the
/// i32 -> f32 -> i32 round trip where INT_MAX rounds up to 2^31 (out of range),
/// and TML event times (u32 milliseconds) that can exceed maxInt(i32) on
/// long/crafted sequences. f32 arguments widen losslessly.
pub fn satI32(v: f64) i32 {
    if (std.math.isNan(v)) return 0;
    if (v >= 2147483647.0) return std.math.maxInt(i32);
    if (v <= -2147483648.0) return std.math.minInt(i32);
    return @intFromFloat(v);
}

/// Saturating float -> u32 (NaN/negative -> 0, overflow -> clamped). Accepts
/// f32 or f64 so wide callers keep their precision.
pub fn satU32(v: anytype) u32 {
    if (!(v >= 0)) return 0; // false for NaN and negatives
    if (v >= 4294967295.0) return std.math.maxInt(u32);
    return @intFromFloat(v);
}

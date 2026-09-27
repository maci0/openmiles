const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const wide = @import("wide.zig");

const io: std.Io = std.Io.Threaded.global_single_threaded.io();

// Bound the on-disk debug log. The file is opened append-only (truncate = false),
// so a long-running or repeatedly-loaded host process would otherwise grow
// openmiles.log without limit (multi-GB files observed in the field). Once the
// log reaches this size, console / OutputDebugString output continues but no
// further bytes are written to disk. Enabling logging is controlled separately
// by OPENMILES_DEBUG; this only caps how large the file may become.
const max_log_bytes: u64 = 64 * 1024 * 1024; // 64 MiB

var log_file: ?std.Io.File = null;
var log_offset: u64 = 0;
var initialized = false;
var config_logged = false;
var debug_enabled = false;
var mutex: std.Io.Mutex = .init;

// The W (UTF-16) entry points, not the A ones: the value of a UTF-8 env var
// name and log text is not confined to the process ANSI code page.
extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: [*]u16, nSize: u32) callconv(.winapi) u32;
extern "kernel32" fn OutputDebugStringW(lpOutputString: [*:0]const u16) callconv(.winapi) void;

// OPENMILES_DEBUG accepts these, case-insensitively. Anything else is a
// misconfiguration, not a request to disable the log, and is reported on
// stderr rather than left to disable logging silently.
const debug_on_values = [_][]const u8{ "1", "true", "yes", "on" };
const debug_off_values = [_][]const u8{ "0", "false", "no", "off" };

fn parseDebugFlag(value: []const u8) ?bool {
    // An empty value is "set to empty", not "off": an exported
    // OPENMILES_DEBUG= with nothing after the '=' is a broken launcher
    // environment, and reading it as off hides the fact.
    if (value.len == 0) return null;
    for (debug_on_values) |v| if (std.ascii.eqlIgnoreCase(value, v)) return true;
    for (debug_off_values) |v| if (std.ascii.eqlIgnoreCase(value, v)) return false;
    return null;
}

fn applyDebugEnvValue(value: []const u8) void {
    if (parseDebugFlag(value)) |enabled| {
        debug_enabled = enabled;
        return;
    }
    // stderr, not log(): the log is what the operator was trying to turn on,
    // so a message in it would never be seen. This is the one message init
    // always emits.
    std.debug.print(
        "openmiles: ignoring OPENMILES_DEBUG='{s}': expected 1/0, true/false, yes/no, or on/off\n",
        .{value},
    );
}

pub fn init() void {
    if (@atomicLoad(bool, &initialized, .acquire)) return;
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (@atomicLoad(bool, &initialized, .acquire)) return;

    // The shipped library logs by default in a Debug build; the test build does
    // not (build_options.log_by_default is false there), because the suite runs
    // in the repository root and an appending debug log there grows to
    // max_log_bytes on every run and floods the test output. OPENMILES_DEBUG
    // still turns it on for whichever run wants the trace.
    debug_enabled = builtin.mode == .Debug and build_options.log_by_default;

    if (builtin.os.tag == .windows) {
        // The UTF-8 destination is sized in bytes from the unit count: a value
        // holding a character outside ASCII needs up to three bytes per unit, so
        // a 1:1 buffer would fail the conversion and leave the build-mode default.
        const value_units = 256;
        var name_wbuf: [64]u16 = undefined;
        var wbuf: [value_units]u16 = undefined;
        var buf: [value_units * 3]u8 = undefined;
        // A conversion failure leaves debug_enabled at its build-mode default
        // rather than aborting init, so the log file still opens.
        if (wide.toWide("OPENMILES_DEBUG", &name_wbuf)) |name| {
            const len = GetEnvironmentVariableW(name.ptr, &wbuf, wbuf.len);
            if (len > 0 and len < wbuf.len) {
                if (wide.toUtf8(wbuf[0..len], &buf)) |val| {
                    applyDebugEnvValue(val);
                } else |_| {}
            }
        } else |_| {}
    } else {
        if (std.c.getenv("OPENMILES_DEBUG")) |val_ptr| {
            applyDebugEnvValue(std.mem.span(@as([*:0]const u8, val_ptr)));
        }
    }

    if (debug_enabled) {
        if (std.Io.Dir.cwd().createFile(io, "openmiles.log", .{
            .truncate = false,
        })) |f| {
            log_offset = f.length(io) catch 0;
            log_file = f;
        } else |err| {
            // The log is the only record of what this process did. Losing it
            // silently leaves an operator with no trace at all, and since
            // log() returns early on any write failure, say so once here,
            // before the sink is gone.
            std.debug.print("openmiles: cannot open openmiles.log for appending: {t}\n", .{err});
        }
    }
    @atomicStore(bool, &initialized, true, .release);
}

pub fn deinit() void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);
    if (log_file) |f| {
        f.close(io);
        log_file = null;
    }
    @atomicStore(bool, &initialized, false, .release);
    @atomicStore(bool, &config_logged, false, .release);
}

/// Record the effective configuration once per init, so a log that opens can be
/// read back as "logging is on, from the build mode, into this file" without
/// the reader having to know the variable that asked for it.
fn logConfigOnce() void {
    if (@atomicLoad(bool, &config_logged, .acquire)) return;
    @atomicStore(bool, &config_logged, true, .release);
    log("openmiles: debug log on ({s} build, default {s}), appending to openmiles.log in the current directory, cap {d} bytes\n", .{
        @tagName(builtin.mode),
        if (build_options.log_by_default) "on" else "off",
        max_log_bytes,
    });
}

/// Neutralize control characters in an untrusted substring (a path, a VFS name,
/// an error string) before it is written to the log.
///
/// A filename carrying CR, ESC, or a bare LF can end the current record early
/// and forge the next one, so a reader (or a downstream log shipper) sees a
/// line the library never wrote. Tab and newline are the library's own framing
/// and stay as they are.
fn sanitizeText(text: []u8) void {
    for (text) |*c| {
        if ((c.* < 0x20 and c.* != '\n' and c.* != '\t') or c.* == 0x7f) c.* = '.';
    }
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled and @atomicLoad(bool, &initialized, .acquire)) return;
    init();
    if (!debug_enabled) return;
    logConfigOnce();
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    // The formatted message can carry an untrusted path or name, so scrub it
    // before it reaches any sink.
    sanitizeText(msg);
    const out = msg[0..msg.len];

    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    if (builtin.os.tag == .windows) {
        var w_buf: [1025]u16 = undefined;
        if (wide.toWide(out, &w_buf)) |w| {
            OutputDebugStringW(w.ptr);
        } else |_| {}
    } else {
        std.debug.print("{s}", .{out});
    }

    if (log_file) |f| {
        if (log_offset < max_log_bytes) {
            f.writePositionalAll(io, out, log_offset) catch return;
            log_offset += out.len;
        }
    }
}

const testing = std.testing;

test "OPENMILES_DEBUG accepts the documented values in any case" {
    for (debug_on_values) |v| {
        try testing.expectEqual(true, parseDebugFlag(v).?);
    }
    // Case is not a configuration difference: an operator on a case-insensitive
    // expectation writes "True" and "OFF" as readily as "true" and "0".
    for ([_][]const u8{ "TRUE", "True", "YES", "On" }) |v| {
        try testing.expectEqual(true, parseDebugFlag(v).?);
    }
    for ([_][]const u8{ "FALSE", "False", "NO", "Off" }) |v| {
        try testing.expectEqual(false, parseDebugFlag(v).?);
    }
    for (debug_off_values) |v| {
        try testing.expectEqual(false, parseDebugFlag(v).?);
    }
}

test "an unrecognized OPENMILES_DEBUG is rejected, not read as off" {
    // A typo silently disabling the log is the failure this guards: the
    // operator asks for a trace and gets none with no message.
    for ([_][]const u8{ "", " ", "2", "enabled", "TRUE-ish", "t", "no!", "-1" }) |v| {
        try testing.expectEqual(@as(?bool, null), parseDebugFlag(v));
    }
}

test "log text from an untrusted name cannot forge a record" {
    var forged = "C:\\evil.wav\r\nopenmiles: sample loaded\x1b[2K".*;
    sanitizeText(&forged);
    // CR and ESC are neutralized; the LF survives as the library's own line
    // framing, so a name can start a line but cannot rewrite or erase one.
    try testing.expectEqualStrings(
        "C:\\evil.wav.\nopenmiles: sample loaded.[2K",
        &forged,
    );

    var framing = "line one\nline two\ttabbed".*;
    sanitizeText(&framing);
    try testing.expectEqualStrings("line one\nline two\ttabbed", &framing);
}

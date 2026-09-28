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

/// Where the log goes when OPENMILES_LOG_PATH is unset. Relative, so it lands
/// in the current directory.
const default_log_name = "openmiles.log";
/// Longest path OPENMILES_LOG_PATH may name. Longer than this is refused:
/// the buffer that holds the path for the life of the process is this size.
const max_log_path_bytes = 1024;

// One formatted record. A record that does not fit is not written silently: see
// the overflow marker in log(). Sized to hold a long path plus its context.
const max_log_record_bytes = 1024;

var log_file: ?std.Io.File = null;
var log_offset: u64 = 0;
var initialized = false;
var config_logged = false;
var debug_enabled = false;
var debug_source: []const u8 = "the build default";
var log_path_buf: [max_log_path_bytes]u8 = undefined;
var log_path_len: usize = default_log_name.len;
var write_error_reported = false;
var mutex: std.Io.Mutex = .init;

// The W (UTF-16) entry points, not the A ones: the value of a UTF-8 env var
// name and log text is not confined to the process ANSI code page.
extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: [*]u16, nSize: u32) callconv(.winapi) u32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn OutputDebugStringW(lpOutputString: [*:0]const u16) callconv(.winapi) void;

const error_envvar_not_found: u32 = 203;

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

fn logPath() []const u8 {
    return log_path_buf[0..log_path_len];
}

fn setDefaultLogPath() void {
    @memcpy(log_path_buf[0..default_log_name.len], default_log_name);
    log_path_len = default_log_name.len;
}

/// Install `value` as the log path, or keep the default and say why. Empty
/// and oversized values are misconfiguration, not a request to write nowhere.
fn applyLogPath(value: []const u8) void {
    if (value.len == 0 or value.len >= max_log_path_bytes) {
        std.debug.print(
            "openmiles: ignoring OPENMILES_LOG_PATH ({s}); using {s} in the current directory\n",
            .{ if (value.len == 0) "empty" else "too long", default_log_name },
        );
        setDefaultLogPath();
        return;
    }
    @memcpy(log_path_buf[0..value.len], value);
    log_path_len = value.len;
}

fn openLog(path: []const u8) ?std.Io.File {
    const opened = if (std.fs.path.isAbsolute(path))
        std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = false })
    else
        std.Io.Dir.cwd().createFile(io, path, .{ .truncate = false });
    return opened catch |err| {
        std.debug.print("openmiles: cannot open '{s}' for appending: {t}\n", .{ path, err });
        return null;
    };
}

fn applyDebugEnvValue(value: []const u8) void {
    if (parseDebugFlag(value)) |enabled| {
        debug_enabled = enabled;
        // The config line below names where the value came from, so a log
        // that says "off" is readable as "the environment asked for off" and
        // not as "nothing asked for anything".
        debug_source = "OPENMILES_DEBUG";
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
    debug_source = "the build default";
    setDefaultLogPath();

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
        if (wide.toWide("OPENMILES_LOG_PATH", &name_wbuf)) |name| {
            var path_w: [max_log_path_bytes]u16 = undefined;
            var path_utf8: [max_log_path_bytes * 3]u8 = undefined;
            const len = GetEnvironmentVariableW(name.ptr, &path_w, path_w.len);
            if (len == 0) {
                if (GetLastError() != error_envvar_not_found) applyLogPath("");
            } else if (len >= path_w.len) {
                applyLogPath(&[_]u8{'x'} ** max_log_path_bytes);
            } else if (wide.toUtf8(path_w[0..len], &path_utf8)) |val| {
                applyLogPath(val);
            } else |_| {
                std.debug.print(
                    "openmiles: ignoring OPENMILES_LOG_PATH (not valid UTF-8); using {s} in the current directory\n",
                    .{default_log_name},
                );
                setDefaultLogPath();
            }
        } else |_| {}
    } else {
        if (std.c.getenv("OPENMILES_DEBUG")) |val_ptr| {
            applyDebugEnvValue(std.mem.span(@as([*:0]const u8, val_ptr)));
        }
        if (std.c.getenv("OPENMILES_LOG_PATH")) |val_ptr| {
            applyLogPath(std.mem.span(@as([*:0]const u8, val_ptr)));
        }
    }

    if (debug_enabled) {
        if (openLog(logPath())) |f| {
            // Records are written positionally at log_offset, so an offset of 0
            // on a file that already holds records overwrites the ones there.
            // A file whose length cannot be read is therefore not appended to
            // at all: closing it keeps the existing log intact and the process
            // console-only, which is visible, rather than silently destroying
            // the history and appearing to succeed.
            if (f.length(io)) |start| {
                log_offset = start;
                log_file = f;
            } else |_| {
                std.debug.print(
                    "openmiles: cannot size '{s}'; leaving it untouched and logging to the console only\n",
                    .{logPath()},
                );
                f.close(io);
            }
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
    @atomicStore(bool, &write_error_reported, false, .release);
}

/// Record the effective configuration once per init, so a log that opens can be
/// read back as "logging is on or off, from the build default or from
/// OPENMILES_DEBUG, into this file" without the reader having to know the
/// variable that asked for it.
///
/// The mss_version the DLL was built for is in the same line because it is the
/// one piece of configuration a consumer cannot query at runtime: the value a
/// game was compiled against is the OPENMILES_MSS_VERSION define in its own
/// build, and nothing in the loaded image confirms the two agree. The log is
/// where a mismatch becomes visible.
fn logConfigOnce() void {
    if (@atomicLoad(bool, &config_logged, .acquire)) return;
    @atomicStore(bool, &config_logged, true, .release);
    log("openmiles: debug log {s}, enabled by {s} ({s} build, default {s}), mss_version {d}, appending to '{s}', cap {d} bytes\n", .{
        if (debug_enabled) "on" else "off",
        debug_source,
        @tagName(builtin.mode),
        if (build_options.log_by_default) "on" else "off",
        build_options.mss_version,
        logPath(),
        max_log_bytes,
    });
}

/// Neutralize control and invisible characters in an untrusted substring (a
/// path, a VFS name, an error string) before it is written to the log.
///
/// A filename carrying CR, ESC, or a bare LF can end the current record early
/// and forge the next one, so a reader (or a downstream log shipper) sees a
/// line the library never wrote. Tab and newline are the library's own framing
/// and stay as they are. The C1 controls are terminal controls of the same
/// kind as ESC and are two UTF-8 bytes each, so a bytewise pass never saw them:
/// a name carrying CSI (U+009B) moved the cursor exactly as one carrying ESC
/// does. The invisible formatting characters (bidi overrides, zero-width
/// joiners, the BOM) are not controls at all, and a name carrying U+202E
/// renders reversed in whatever reads the log.
///
/// Returns the scrubbed length: a neutralized multi-byte character is replaced
/// by the single byte '.', so the text is shorter than the buffer it came from.
fn sanitizeText(text: []u8) usize {
    var read: usize = 0;
    var write: usize = 0;
    while (read < text.len) {
        const width = std.unicode.utf8ByteSequenceLength(text[read]) catch 1;
        const end = @min(read + width, text.len);
        const cp = std.unicode.utf8Decode(text[read..end]) catch {
            // Not a character: the byte is kept as it came in, since the input
            // was already broken and the log is not where to repair it.
            text[write] = text[read];
            read += 1;
            write += 1;
            continue;
        };
        if (neutralizeCodepoint(cp)) {
            text[write] = '.';
            write += 1;
        } else {
            std.mem.copyForwards(u8, text[write..][0 .. end - read], text[read..end]);
            write += end - read;
        }
        read = end;
    }
    return write;
}

// C1 controls: the 8-bit set, of which CSI (0x9B) and NEL (0x85) drive a
// terminal the way ESC (0x1B) does.
const c1_first: u21 = 0x80;
const c1_last: u21 = 0x9f;
// Bidi embedding, override and isolate: reordering characters that render a
// name differently from the bytes the log actually holds.
const bidi_format_first: u21 = 0x202a;
const bidi_format_last: u21 = 0x202e;
const bidi_isolate_first: u21 = 0x2066;
const bidi_isolate_last: u21 = 0x2069;

fn neutralizeCodepoint(cp: u21) bool {
    if (cp == '\n' or cp == '\t') return false;
    if (cp < 0x20 or cp == 0x7f) return true;
    if (cp >= c1_first and cp <= c1_last) return true;
    if (cp >= bidi_format_first and cp <= bidi_format_last) return true;
    if (cp >= bidi_isolate_first and cp <= bidi_isolate_last) return true;
    // ZERO WIDTH SPACE / NON-JOINER / JOINER, WORD JOINER, BOM.
    if (cp == 0x200b or cp == 0x200c or cp == 0x200d or cp == 0x2060 or cp == 0xfeff) return true;
    return false;
}

/// Write one record when logging is enabled. Self-initializes: a call before
/// init() opens the log even when debug logging is off, and a call after
/// deinit() reopens it, so a first call never has to know the lifecycle.
pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled and @atomicLoad(bool, &initialized, .acquire)) return;
    init();
    if (!debug_enabled) return;
    logConfigOnce();
    var buf: [max_log_record_bytes]u8 = undefined;
    var over_buf: [wide_record_units]u8 = undefined;
    const out = formatRecord(&buf, &over_buf, fmt, args);
    emit(out);
}

/// Render one record into `buf`, or an overflow marker into `over_buf` when the
/// formatted text does not fit. bufPrint yields nothing on overflow, so the
/// record has to be replaced rather than dropped: the content is gone, but the
/// loss is on the record and the format string names the call site that caused
/// it. Returns a slice into one of the two buffers.
fn formatRecord(
    buf: []u8,
    over_buf: []u8,
    comptime fmt: []const u8,
    args: anytype,
) []const u8 {
    const msg = std.fmt.bufPrint(buf, fmt, args) catch {
        return std.fmt.bufPrint(
            over_buf,
            "openmiles: log record exceeded {d} bytes and was dropped: {s}\n",
            .{ buf.len, fmt },
        ) catch "";
    };
    // The formatted message can carry an untrusted path or name, so scrub it
    // before it reaches any sink.
    return msg[0..sanitizeText(msg)];
}

/// Wide sink buffer. Sized for the overflow marker as well as a normal record,
/// so a dropped record still reaches OutputDebugString instead of failing the
/// conversion and vanishing.
const wide_record_units = max_log_record_bytes + 128 + 1;

/// Write one record to every enabled sink. The caller has already formatted and
/// sanitized it, so this is the only place that knows about the console, the
/// debug stream, and the on-disk log.
fn emit(out: []const u8) void {
    mutex.lockUncancelable(io);
    defer mutex.unlock(io);

    if (builtin.os.tag == .windows) {
        var w_buf: [wide_record_units]u16 = undefined;
        if (wide.toWide(out, &w_buf)) |w| {
            OutputDebugStringW(w.ptr);
        } else |_| {}
    } else {
        std.debug.print("{s}", .{out});
    }

    if (log_file) |f| {
        if (log_offset < max_log_bytes) {
            f.writePositionalAll(io, out, log_offset) catch |err| {
                // The file is the sink an operator reads after the fact, so a
                // failing write is not a record to be dropped quietly: say so
                // once, on the console that is still working, and leave the
                // handle in place so a later write may still succeed.
                if (!write_error_reported) {
                    write_error_reported = true;
                    std.debug.print(
                        "openmiles: cannot write to '{s}' ({t}); further records are console-only\n",
                        .{ logPath(), err },
                    );
                }
                return;
            };
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

test "OPENMILES_LOG_PATH selects the file and rejects an empty or oversized value" {
    setDefaultLogPath();
    applyLogPath("traces/om.log");
    try testing.expectEqualStrings("traces/om.log", logPath());
    applyLogPath("");
    try testing.expectEqualStrings(default_log_name, logPath());
    applyLogPath(&[_]u8{'p'} ** max_log_path_bytes);
    try testing.expectEqualStrings(default_log_name, logPath());
    applyLogPath("/var/tmp/openmiles.log");
    try testing.expectEqualStrings("/var/tmp/openmiles.log", logPath());
}

test "an unrecognized OPENMILES_DEBUG is rejected, not read as off" {
    // A typo silently disabling the log is the failure this guards: the
    // operator asks for a trace and gets none with no message.
    for ([_][]const u8{ "", " ", "2", "enabled", "TRUE-ish", "t", "no!", "-1" }) |v| {
        try testing.expectEqual(@as(?bool, null), parseDebugFlag(v));
    }
}

test "an oversized record is replaced by a marker, not dropped silently" {
    var buf: [64]u8 = undefined;
    var over_buf: [192]u8 = undefined;
    const long = "x" ** 200;
    const out = formatRecord(&buf, &over_buf, "{s}", .{long});
    // The record did not fit, so the marker names the failure and the format
    // string, rather than the caller receiving an empty log line.
    try testing.expect(out.len > 0);
    try testing.expect(std.mem.indexOf(u8, out, "was dropped") != null);
    try testing.expect(std.mem.indexOf(u8, out, "{s}") != null);
}

test "log text from an untrusted name cannot forge a record" {
    var forged = "C:\\evil.wav\r\nopenmiles: sample loaded\x1b[2K".*;
    const forged_out = &forged;
    // CR and ESC are neutralized; the LF survives as the library's own line
    // framing, so a name can start a line but cannot rewrite or erase one.
    try testing.expectEqualStrings(
        "C:\\evil.wav.\nopenmiles: sample loaded.[2K",
        forged_out[0..sanitizeText(&forged)],
    );

    var framing = "line one\nline two\ttabbed".*;
    const framing_out = &framing;
    try testing.expectEqualStrings("line one\nline two\ttabbed", framing_out[0..sanitizeText(&framing)]);
}

test "a C1 control in a name is neutralized like ESC" {
    // U+009B (CSI) is two bytes, so a bytewise pass let it through untouched:
    // a name carrying it moved the terminal cursor as surely as one carrying
    // ESC. U+0085 (NEL) likewise ends a line in some readers.
    var name = "a\u{009B}2Kb\u{0085}c".*;
    const out = &name;
    try testing.expectEqualStrings("a.2Kb.c", out[0..sanitizeText(&name)]);
}

test "invisible formatting characters in a name are neutralized" {
    // U+202E RIGHT-TO-LEFT OVERRIDE renders what follows reversed, so a name
    // carrying it reads as a different name than the log holds.
    var name = "invoice\u{202E}fdp.exe\u{200B}ini".*;
    const out = &name;
    try testing.expectEqualStrings("invoice.fdp.exe.ini", out[0..sanitizeText(&name)]);
}

test "non-ascii text in a name survives the scrub" {
    var name = "Juegos/Aventura Épica 🎮.asi".*;
    const out = &name;
    try testing.expectEqualStrings("Juegos/Aventura Épica 🎮.asi", out[0..sanitizeText(&name)]);
}

test "a byte that is not a character is kept as it came in" {
    var name = [_]u8{ 'a', 0xff, 'b' };
    try testing.expectEqual(@as(usize, 3), sanitizeText(&name));
    try testing.expectEqualSlices(u8, &.{ 'a', 0xff, 'b' }, &name);
}

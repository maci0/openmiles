//! src/mss.h is the C declaration a consumer compiles against, so a number in
//! it is as much a contract as an export in main.zig. scripts/check_header.py
//! already holds the header's function declarations against the export table;
//! what it cannot see is a constant, and the AILFILETYPE_* block is the one
//! place the header hands a consumer a raw number to compare a return value
//! against. The two drift silently: the header keeps compiling, the engine
//! renumbers, and every consumer's file-type switch quietly falls through to
//! its default arm.
//!
//! So the constants are read out of the header and driven through the real
//! classifier, one fixture per name. A fixture that stops classifying the way
//! the header says fails here rather than in a game.

const std = @import("std");
const testing = std.testing;
const openmiles = @import("openmiles");
const api_v8 = @import("api/v8.zig");

const header = @embedFile("mss.h");

/// One AILFILETYPE_* name, without the AILFILETYPE_ prefix, and the value
/// src/mss.h gives it. The name is a slice of the embedded header itself rather
/// than a built string, so the parsed table holds no pointer a later
/// comptime allocation could invalidate.
const Constant = struct { name: []const u8, value: i32 };

const define_prefix = "#define ";
const file_type_prefix = define_prefix ++ "AILFILETYPE_";

/// The header's AILFILETYPE_* block, read once at compile time. Lookups go
/// through this rather than re-scanning, so the parse is paid for once however
/// many names a test resolves. Fixed-capacity and copied out by value: a global
/// cannot point into a comptime var.
const Parsed = struct { items: [64]Constant, len: usize };

const file_type_constants: Parsed = blk: {
    @setEvalBranchQuota(500_000);
    var buf: [64]Constant = undefined;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, header, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, file_type_prefix)) continue;
        const rest = trimmed[file_type_prefix.len..];
        const space = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
        buf[n] = .{
            .name = rest[0..space],
            .value = std.fmt.parseInt(i32, std.mem.trim(u8, rest[space..], " \t"), 10) catch continue,
        };
        n += 1;
    }
    break :blk .{ .items = buf, .len = n };
};

/// The value src/mss.h gives AILFILETYPE_<name>, or a compile error when the
/// header does not carry that name: a row whose constant was renamed has to
/// stop the build, not quietly pass.
fn aILFileType(comptime name: []const u8) i32 {
    // The search runs at comptime even when the caller is a runtime one, so
    // only a name the header dropped reaches the compile error.
    const value: ?i32 = comptime blk: {
        for (file_type_constants.items[0..file_type_constants.len]) |c| {
            if (std.mem.eql(u8, c.name, name)) break :blk c.value;
        }
        break :blk null;
    };
    return value orelse @compileError("mss.h declares no AILFILETYPE_" ++ name);
}

/// The value behind a `#define <name> <decimal>` line outside the AILFILETYPE
/// block, or null when the header has no such define. A parenthesized value
/// (MSS_BUFFER_HEAD spells its -1 that way) parses the same as a bare one. The
/// block above is pre-parsed because it is the one read once per fixture; a
/// one-off lookup scans for itself.
fn headerDefine(comptime name: []const u8) ?i32 {
    return comptime blk: {
        @setEvalBranchQuota(500_000);
        const prefix = define_prefix ++ name;
        var lines = std.mem.splitScalar(u8, header, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t");
            if (!std.mem.startsWith(u8, trimmed, prefix)) continue;
            var rest = std.mem.trim(u8, trimmed[prefix.len..], " \t");
            if (rest.len >= 2 and rest[0] == '(' and rest[rest.len - 1] == ')') {
                rest = std.mem.trim(u8, rest[1 .. rest.len - 1], " \t");
            }
            break :blk std.fmt.parseInt(i32, rest, 10) catch null;
        }
        break :blk null;
    };
}

test "mss.h declares exactly the AILFILETYPE_* set this test drives" {
    // 22 declares, 22 driven: a constant added to the header without a fixture
    // here is one no run has checked against the engine.
    try testing.expectEqual(@as(usize, 22), file_type_constants.len);
}

// A 4-byte frame header plus padding: the sync scan wants 0xFxx on the first
// two bytes, a non-all-ones word, and a byte 2 whose top six bits are not set.
const mpeg_l1 = "\xFF\xF7\x00\x00\x00\x00\x00\x00";
const mpeg_l2 = "\xFF\xF5\x00\x00\x00\x00\x00\x00";
const mpeg_l3 = "\xFF\xF3\x00\x00\x00\x00\x00\x00";

const pcm_wav = "RIFF" ++ "\x2C\x00\x00\x00" ++ "WAVE" ++ "fmt " ++ "\x10\x00\x00\x00" ++
    "\x01\x00\x02\x00" ++ "\x44\xAC\x00\x00" ++ "\x88\x58\x01\x00" ++
    "\x04\x00\x10\x00" ++ "data" ++ "\x00\x00\x00\x00";

// IMA ADPCM at 4 bits: format tag 0x0011 is what separates ADPCM_WAV from
// OTHER_WAV on a WAV this parser accepts.
const adpcm_wav = "RIFF" ++ "\x70\x00\x00\x00" ++ "WAVE" ++
    "fmt " ++ "\x10\x00\x00\x00" ++ "\x11\x00\x01\x00" ++ "\x22\x56\x00\x00" ++
    "\x00\x2C\x00\x00" ++ "\x00\x01\x04\x00" ++
    "fact" ++ "\x04\x00\x00\x00" ++ "\x40\x00\x00\x00" ++
    "data" ++ "\x40\x00\x00\x00" ++ "\x11\x22\x33\x44" ++ "\x55" ** 60;

// Two more plain WAVs, distinguished only by their fmt format tag: 0x0003 is a
// codec this build has no name for, so the classifier falls back to
// OTHER_WAV, while 0x0069 at 4 bits is XBOX ADPCM and keeps its own code. Both
// go in a 16-byte fmt chunk, because the chunk walk stops at WAVE_FORMATEXTENSIBLE
// whose SubFormat is not PCM.
const other_wav = "RIFF" ++ "\x2C\x00\x00\x00" ++ "WAVE" ++ "fmt " ++ "\x10\x00\x00\x00" ++
    "\x03\x00\x01\x00" ++ "\x44\xAC\x00\x00" ++ "\x88\x58\x01\x00" ++
    "\x04\x00\x10\x00" ++ "data" ++ "\x00\x00\x00\x00";

const xbox_adpcm_wav = "RIFF" ++ "\x2C\x00\x00\x00" ++ "WAVE" ++ "fmt " ++ "\x10\x00\x00\x00" ++
    "\x69\x00\x01\x00" ++ "\x44\xAC\x00\x00" ++ "\x88\x58\x01\x00" ++
    "\x04\x00\x04\x00" ++ "data" ++ "\x00\x00\x00\x00";

const ogg = "OggS" ++ "\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00" ++ "\x00" ** 120;
const speex = "OggS" ++ "\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00" ++ "Speex   " ++ "Speex   " ++ "1.2rc1";
const voc = "Creative Voice File\x1A" ++ "\x1A\x00\x00";
const midi = "MThd" ++ "\x00\x00\x00\x06\x00\x01\x00\x01\x01\xE0";
const xmidi = "FORM" ++ "\x10\x00\x00\x00" ++ "XDIR" ++ "CAT " ++ "\x04\x00\x00\x00" ++ "XMID";
const dls = "RIFF" ++ "\x08\x00\x00\x00" ++ "DLS " ++ "\x01\x00";
const mls = "RIFF" ++ "\x08\x00\x00\x00" ++ "MLS " ++ "\x01\x00";
const binka = "1FCB" ++ "\x00\x00\x00\x00";

test "mss.h AILFILETYPE_* names classify what the header says they do" {
    // Each row drives a real image through the same path AIL_file_type takes.
    const images = [_]struct { name: []const u8, image: []const u8 }{
        .{ .name = "PCM_WAV", .image = pcm_wav },
        .{ .name = "ADPCM_WAV", .image = adpcm_wav },
        .{ .name = "OTHER_WAV", .image = other_wav },
        .{ .name = "XBOX_ADPCM_WAV", .image = xbox_adpcm_wav },
        .{ .name = "VOC", .image = voc },
        .{ .name = "MIDI", .image = midi },
        .{ .name = "XMIDI", .image = xmidi },
        .{ .name = "DLS", .image = dls },
        .{ .name = "MLS", .image = mls },
        .{ .name = "MPEG_L1_AUDIO", .image = mpeg_l1 },
        .{ .name = "MPEG_L2_AUDIO", .image = mpeg_l2 },
        .{ .name = "MPEG_L3_AUDIO", .image = mpeg_l3 },
        .{ .name = "OGG_VORBIS", .image = ogg },
        .{ .name = "OGG_SPEEX", .image = speex },
        .{ .name = "BINKA", .image = binka },
    };
    // inline: the constant behind each row's name is resolved at compile time,
    // so a name the header dropped is a compile error here rather than a row
    // that quietly passes.
    inline for (images) |row| {
        const got = openmiles.detectFileType(@constCast(row.image.ptr), @intCast(row.image.len));
        try testing.expectEqual(aILFileType(row.name), got);
    }
}

test "mss.h AILFILETYPE_* names the suffix-only codes reach" {
    // Voxware and Speex voice files carry no magic of their own, so these six
    // exist only on the AIL_file_type_named path.
    const named = [_]struct { name: []const u8, file: [:0]const u8 }{
        .{ .name = "V12_VOICE", .file = "voice.v12" },
        .{ .name = "V24_VOICE", .file = "voice.V24" },
        .{ .name = "V29_VOICE", .file = "voice.v29" },
        .{ .name = "S8_VOICE", .file = "voice.speex8" },
        .{ .name = "S16_VOICE", .file = "voice.speex16" },
        .{ .name = "S32_VOICE", .file = "voice.speex32" },
    };
    inline for (named) |row| {
        const got = api_v8.AIL_file_type_named(@constCast(pcm_wav.ptr), row.file, @intCast(pcm_wav.len));
        try testing.expectEqual(aILFileType(row.name), got);
    }
}

test "AILFILETYPE_UNKNOWN is 0, and is what an unusable buffer reports" {
    try testing.expectEqual(@as(i32, 0), aILFileType("UNKNOWN"));
    // Shorter than the 8 bytes the classifier reads before it starts.
    const stub = "RIFF";
    try testing.expectEqual(
        aILFileType("UNKNOWN"),
        openmiles.detectFileType(@constCast(stub.ptr), @intCast(stub.len)),
    );
    // A suffix that names no known voice format leaves the content to decide.
    try testing.expectEqual(
        aILFileType("PCM_WAV"),
        api_v8.AIL_file_type_named(@constCast(pcm_wav.ptr), "voice", @intCast(pcm_wav.len)),
    );
}

test "MSS_BUFFER_HEAD is the -1 AIL_load_sample_buffer resolves a ring head from" {
    // The header spells the head slot as a name, and the engine reads it as a
    // literal -1 out of the argument, so a sign change in either shows up here.
    try testing.expectEqual(@as(i32, -1), headerDefine("MSS_BUFFER_HEAD").?);
}

//! Unit and behavior tests for the engine and the C-ABI wrappers.
//!
//! Scope of this file: a test drives a real exported entry point and asserts
//! the value the SDK documents it returns, or asserts a documented state
//! transition (a status word, a write-then-read-back, a buffer parsed byte by
//! byte). "Did not crash" belongs in fuzz_test.zig / api_coverage_test.zig,
//! which exist to reach every symbol and every shape of bad input; those are
//! deliberately not the standard here.
//!
//! Conventions:
//!   * `testing.allocator` everywhere, so a leak fails the test that leaked.
//!     The exceptions are named in place (fixtures that hand a pointer to
//!     process-global state, platform paths that only resolve off-device).
//!   * No sleeps as a substitute for a poll. Where a value advances with the
//!     clock, the test polls to a bound and then asserts, so a swallowed sleep
//!     error cannot pass a stalled clock and a slow machine cannot fail.
//!   * A global the API promises to outlive the test (preferences, the redist
//!     directory, the file callbacks) is restored through `defer`, because
//!     every test in the binary shares it.
//!   * Fixtures are built from known bytes, so the expected value is written
//!     out rather than recomputed by the same code under test.
//!
//! Related files: fuzz_test.zig and fuzz_native_test.zig (random/adversarial
//! input, crash-only), api_coverage_test.zig (every export reached once),
//! rib_test.zig (registry ordering), engine_test_root.zig (test blocks inside
//! the engine modules themselves).

const std = @import("std");
const testing = std.testing;
const openmiles = @import("openmiles");

// Fixture: a Sample on a 44100 Hz stereo driver, preloaded with pcm_len zero
// bytes as a mono/stereo 16-bit WAV. The caller owns the driver (s.driver)
// and the sample; deinit the driver after the sample.
fn loadedSample(allocator: std.mem.Allocator, pcm_len: usize, channels: u16, rate: u32) !*openmiles.Sample {
    const drv = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    errdefer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    errdefer s.deinit();
    const pcm = try allocator.alloc(u8, pcm_len);
    defer allocator.free(pcm);
    @memset(pcm, 0);
    const wav = try openmiles.buildWavFromPcm(allocator, pcm, channels, rate, 16);
    defer allocator.free(wav);
    try s.loadFromMemory(wav, true);
    return s;
}

// 100 ms of silence as a mono 8-bit 44100 Hz WAV; the caller owns the buffer.
fn zeroWav(allocator: std.mem.Allocator) ![]u8 {
    const pcm = [_]u8{0} ** 4410;
    return openmiles.buildWavFromPcm(allocator, &pcm, 1, 44100, 8);
}

test "DigitalDriver init and deinit" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    try testing.expectEqual(@as(usize, 0), driver.samples.items.len);
    try testing.expectEqual(@as(usize, 0), driver.samples_3d.items.len);
    try testing.expectEqual(@as(f32, 1.0), driver.distance_factor);
}

test "Sample allocation and basic properties" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();
    try testing.expectEqual(sample.driver, driver);
    try testing.expect(!sample.is_initialized);

    sample.setVolume(64);
    // MSS curve: gain = (64/127)^(10/6) ≈ 0.319 (0.5 vol -> -10 dB).
    try testing.expect(sample.volume > 0.30 and sample.volume < 0.33);
    try testing.expectEqual(@as(i32, 64), sample.original_volume);

    sample.setPan(32);
    // pan is (32 - 64) / 64.0 = -0.5
    try testing.expectEqual(@as(f32, -0.5), sample.pan);
}

test "MidiDriver init and deinit" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    try testing.expectEqual(@as(f32, 1.0), driver.master_volume);
    try testing.expectEqual(@as(?*openmiles.tsf.tsf, null), driver.soundfont);
}

// A soundfont load that fails must leave the driver as one run left it: the
// bank already loaded stays loaded. Releasing it before the replacement was
// known to be good made a retried load (a level change re-reading the bank, a
// retry after a transient read error) silence every sequence.
test "MidiDriver a failed soundfont load keeps the loaded bank" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    // Stand in for an already-loaded bank: owns_soundfont is false so the
    // driver does not try to tsf_close the sentinel on deinit.
    const sentinel: *openmiles.tsf.tsf = @ptrFromInt(0x1000);
    driver.soundfont = sentinel;
    driver.owns_soundfont = false;

    try testing.expectError(error.SoundFontLoadFailed, driver.loadSoundfont("no-such-bank.sf2"));
    try testing.expectEqual(sentinel, driver.soundfont.?);
}

// A bank handle stays valid until it is unloaded, so loading a file the driver
// already has must hand back that bank. Reloading it closed the one the game
// was still holding and returned a second copy, so every repeat of the load
// (a retry after a read error, a scene reloaded, a "is it loaded?" check) left
// one more dangling handle behind.
test "MidiDriver loading the same soundfont file twice keeps one bank" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    // Stand in for the bank a first load left behind: the sentinel stands in
    // for the tsf it returned, and owns_soundfont is false so deinit does not
    // close it. The recorded path is the resolved form loadSoundfont records.
    const sentinel: *openmiles.tsf.tsf = @ptrFromInt(0x1000);
    const resolved = try openmiles.fs_compat.dupeResolvedPathZ(allocator, "level1.sf2");
    defer allocator.free(resolved);
    driver.soundfont = sentinel;
    driver.owns_soundfont = false;
    driver.soundfont_path = try allocator.dupeZ(u8, resolved);
    driver.soundfont_refs = 1;

    try driver.loadSoundfont("level1.sf2");
    try testing.expectEqual(sentinel, driver.soundfont.?);
    // Two loads of one bank, so the first unload only answers one of them.
    driver.unloadDLS(sentinel);
    try testing.expectEqual(sentinel, driver.soundfont.?);

    // The last unload drops the bank and the record with it, so a load of the
    // same file afterwards is a real load rather than a repeat of a finished
    // one.
    driver.unloadDLS(sentinel);
    try testing.expectEqual(@as(?*openmiles.tsf.tsf, null), driver.soundfont);
    try testing.expectEqual(@as(?[:0]u8, null), driver.soundfont_path);
    try testing.expectError(error.SoundFontLoadFailed, driver.loadSoundfont("level1.sf2"));
}

// The same for an image load, keyed on the buffer: a retry that hands the same
// image back is still the same bank.
test "MidiDriver loading the same soundfont image twice keeps one bank" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const sentinel: *openmiles.tsf.tsf = @ptrFromInt(0x2000);
    const image = "RIFF\x24\x00\x00\x00sfbkLIST";
    driver.soundfont = sentinel;
    driver.owns_soundfont = false;
    driver.soundfont_image_ptr = @intFromPtr(image.ptr);
    driver.soundfont_image_size = @intCast(image.len);
    driver.soundfont_refs = 1;

    const first = try driver.loadSoundfontImage(image.ptr, @intCast(image.len));
    try testing.expectEqual(sentinel, first);
    try testing.expectEqual(sentinel, driver.soundfont.?);
    // The same buffer, so the second load is the bank already in place.
    try testing.expectEqual(sentinel, try driver.loadSoundfontImage(image.ptr, @intCast(image.len)));
}

// AIL_DLS_load_file reads through the file callbacks into a buffer it releases
// when it returns, so the record of which buffer the bank came from has to go
// with the memory: the next image the allocator hands out at that address is a
// different image, and answering its load with this bank would give the game a
// soundfont it never asked for.
test "MidiDriver forgets the image identity of a buffer the caller frees" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const sentinel: *openmiles.tsf.tsf = @ptrFromInt(0x3000);
    const image = "RIFF\x24\x00\x00\x00sfbkLIST";
    driver.soundfont = sentinel;
    driver.owns_soundfont = false;
    driver.soundfont_image_ptr = @intFromPtr(image.ptr);
    driver.soundfont_image_size = @intCast(image.len);
    driver.soundfont_refs = 1;

    driver.forgetSoundfontImage(image.ptr, @intCast(image.len));
    try testing.expectEqual(@as(?*openmiles.tsf.tsf, null), driver.soundfontFromImage(image.ptr, @intCast(image.len)));
    // The bank and the reference its load took both stay: releasing the source
    // image is not an unload.
    try testing.expectEqual(sentinel, driver.soundfont.?);
    try testing.expectEqual(@as(u32, 1), driver.soundfont_refs);
    // A different size at the same address is a different image too.
    driver.soundfont_image_ptr = @intFromPtr(image.ptr);
    driver.soundfont_image_size = @intCast(image.len);
    try testing.expectEqual(@as(?*openmiles.tsf.tsf, null), driver.soundfontFromImage(image.ptr, @intCast(image.len - 1)));
}

// The callback route holds no image identity (the buffer is gone with the
// call), so the name of the file is what a repeated load of it is matched on.
// Without it the second AIL_DLS_load_file of one file read the bytes again,
// closed the bank the game was still holding, and returned a second copy.
test "MidiDriver a bank loaded over the file callbacks is found by its name" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const sentinel: *openmiles.tsf.tsf = @ptrFromInt(0x4000);
    driver.soundfont = sentinel;
    driver.owns_soundfont = false;
    driver.soundfont_refs = 1;
    try driver.adoptSoundfontFilename("level2.sf2");

    // The repeat hands back the bank in place, not a load of its own.
    try testing.expectEqual(@as(?*anyopaque, @ptrCast(sentinel)), driver.retainSoundfontForFile("level2.sf2"));
    try testing.expectEqual(sentinel, driver.soundfont.?);
    try testing.expectEqual(@as(u32, 2), driver.soundfont_refs);
    // A different file is not that bank, so it is loaded rather than matched.
    try testing.expectEqual(@as(?*anyopaque, null), driver.retainSoundfontForFile("other.sf2"));

    // Two loads of one bank, so the first unload only answers one of them and
    // the second drops the bank and the record with it.
    driver.unloadDLS(sentinel);
    try testing.expectEqual(sentinel, driver.soundfont.?);
    driver.unloadDLS(sentinel);
    try testing.expectEqual(@as(?*openmiles.tsf.tsf, null), driver.soundfont);
    try testing.expectEqual(@as(?[:0]u8, null), driver.soundfont_path);
}

test "MidiDriver ms-per-frame stays finite for any output rate" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    driver.sample_rate = 44100;
    try testing.expectApproxEqAbs(@as(f64, 1000.0 / 44100.0), driver.msPerFrame(), 1e-12);

    // An engine with no playback device reports a rate of 0. The unguarded
    // 1000/rate is +inf, and one added to Sequence.time_ms on the audio thread
    // turns every later position read into INF and every diff into NaN.
    driver.sample_rate = 0;
    try testing.expectEqual(@as(f64, 0), driver.msPerFrame());
}

test "Provider registry and finding" {
    const allocator = testing.allocator;
    const provider = try openmiles.Provider.init(allocator);
    defer provider.deinit();

    try testing.expectEqualStrings("unknown", provider.name);

    var entry = openmiles.RIB_INTERFACE_ENTRY{
        .entry_type = .RIB_FUNCTION,
        .name = "TestFunction",
        .token = 0x1234,
        .subtype = 0,
    };
    _ = try provider.registerInterface("TestInterface", 1, &entry);

    var found = false;
    for (provider.interfaces.items) |iface| {
        if (std.mem.eql(u8, iface.name, "TestInterface")) {
            if (iface.tokenFor("TestFunction")) |token| {
                try testing.expectEqual(@as(usize, 0x1234), token);
                found = true;
            }
        }
    }
    try testing.expect(found);
}

test "Sequence basic properties" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const seq = try openmiles.Sequence.init(driver);
    defer seq.deinit();

    try testing.expectEqual(seq.driver, driver);
    try testing.expectEqual(@as(i32, 1), seq.loop_count);

    seq.setLoopCount(5);
    try testing.expectEqual(@as(i32, 5), seq.loop_count);
}

test "Sequence ms position saturates instead of panicking beyond i32" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const seq = try openmiles.Sequence.init(driver);
    defer seq.deinit();

    // TML event times are u32 milliseconds, so total_ms can exceed maxInt(i32)
    // on a long/crafted sequence; time_ms accumulates unbounded in playback.
    seq.total_ms = 4294967295.0; // u32 max
    seq.time_ms = 4e12; // ~46 days of playback
    const pos = seq.getMsPosition();
    try testing.expectEqual(std.math.maxInt(i32), pos.total);
    try testing.expectEqual(std.math.maxInt(i32), pos.current);

    // In-range values keep the plain truncating conversion.
    seq.time_ms = 1234.0;
    try testing.expectEqual(@as(i32, 1234), seq.getMsPosition().current);
}

test "Sequence setMsPosition clamps beat math for tiny ms_per_beat" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const seq = try openmiles.Sequence.init(driver);
    defer seq.deinit();

    // A crafted tempo event (1 us/beat) yields ms_per_beat = 0.001; seeking near
    // i32-max ms then divides to ~2.1e12 beats, far past i32 range.
    seq.ms_per_beat = 0.001;
    seq.setMsPosition(2000000000);
    try testing.expectEqual(@as(f64, 2000000000.0), seq.time_ms);
    // beats_elapsed saturates at maxInt-1 so the +1 bookkeeping cannot overflow.
    const beats: i32 = std.math.maxInt(i32) - 1;
    try testing.expectEqual(@mod(beats, seq.beats_per_measure) + 1, seq.current_beat_in_measure.load(.acquire));
    try testing.expectEqual(@divTrunc(beats, seq.beats_per_measure) + 1, seq.current_measure.load(.acquire));

    // Extreme negative seeks clamp symmetrically without panicking.
    seq.setMsPosition(std.math.minInt(i32));
}

test "Provider registry allows duplicate interface names" {
    const allocator = testing.allocator;
    const provider = try openmiles.Provider.init(allocator);
    defer provider.deinit();

    var entry = openmiles.RIB_INTERFACE_ENTRY{
        .entry_type = .RIB_FUNCTION,
        .name = "DupFunction",
        .token = 0x9999,
        .subtype = 0,
    };
    _ = try provider.registerInterface("TestIface", 1, &entry);
    const count_before = provider.interfaces.items.len;
    // Registering again should add a second entry (no dedup); verify it doesn't crash
    _ = try provider.registerInterface("TestIface", 1, &entry);
    try testing.expectEqual(count_before + 1, provider.interfaces.items.len);
}

test "detectAudioSize RIFF/WAVE" {
    // RIFF header: "RIFF" + 4-byte LE body size. Total = body + 8.
    const header = [_]u8{ 'R', 'I', 'F', 'F', 0x10, 0x00, 0x00, 0x00 } ++ [_]u8{0} ** 8;
    try testing.expectEqual(@as(usize, 0x10 + 8), openmiles.detectAudioSize(&header));
}

test "detectAudioSize IFF/FORM" {
    // FORM header: "FORM" + 4-byte BE body size. Total = body + 8.
    const header = [_]u8{ 'F', 'O', 'R', 'M', 0x00, 0x00, 0x00, 0x20 } ++ [_]u8{0} ** 8;
    try testing.expectEqual(@as(usize, 0x20 + 8), openmiles.detectAudioSize(&header));
}

test "detectAudioSize unknown format returns 0" {
    const header = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00, 0x00, 0x00 } ++ [_]u8{0} ** 8;
    try testing.expectEqual(@as(usize, 0), openmiles.detectAudioSize(&header));
}

test "detectAudioSize OGG returns sentinel" {
    const header = [_]u8{ 'O', 'g', 'g', 'S', 0x00, 0x00, 0x00, 0x00 } ++ [_]u8{0} ** 8;
    try testing.expectEqual(openmiles.streaming_sentinel_size, openmiles.detectAudioSize(&header));
}

test "detectAudioSize MP3 sync word returns sentinel" {
    const header = [_]u8{ 0xFF, 0xFB, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00 } ++ [_]u8{0} ** 8;
    try testing.expectEqual(openmiles.streaming_sentinel_size, openmiles.detectAudioSize(&header));
}

test "detectAudioSize MP3 ID3 tag returns sentinel" {
    const header = [_]u8{ 'I', 'D', '3', 0x04, 0x00, 0x00, 0x00, 0x00 } ++ [_]u8{0} ** 8;
    try testing.expectEqual(openmiles.streaming_sentinel_size, openmiles.detectAudioSize(&header));
}

test "detectAudioSize FLAC returns sentinel" {
    const header = [_]u8{ 'f', 'L', 'a', 'C', 0x00, 0x00, 0x00, 0x00 } ++ [_]u8{0} ** 8;
    try testing.expectEqual(openmiles.streaming_sentinel_size, openmiles.detectAudioSize(&header));
}

test "a lying RIFF/FORM body size clamps to max_declared_image_size" {
    // These sniffers take a bare pointer with no length, so the returned extent
    // is the only thing standing between a crafted header and a read up to
    // ~4 GiB past the caller's buffer. Every declared-size path must clamp:
    // 0xFFFFFFFF is the worst a u32 field can carry, and a size just under the
    // cap is the boundary the clamp must not clip.
    const lying_le = [_]u8{ 'R', 'I', 'F', 'F', 0xFF, 0xFF, 0xFF, 0xFF } ++ [_]u8{0} ** 8;
    try testing.expectEqual(openmiles.max_declared_image_size, openmiles.detectAudioSize(&lying_le));

    // detectMidiSize has no RIFF branch: an unrecognized tag reports the
    // streaming sentinel, which is the same bound reached by a different route.
    try testing.expectEqual(openmiles.streaming_sentinel_size, openmiles.detectMidiSize(&lying_le));

    // FORM reads the same field big-endian. A small BE body (0x10) is 0x10000000
    // read little-endian, which the clamp would hide, so the exact 24 proves
    // the byte order is honored rather than masked by the clamp.
    const form_be = [_]u8{ 'F', 'O', 'R', 'M', 0x00, 0x00, 0x00, 0x10 } ++ [_]u8{0} ** 8;
    try testing.expectEqual(@as(usize, 0x10 + 8), openmiles.detectAudioSize(&form_be));

    // The clamp boundary. max_declared_image_size is 0x10000000, so a body of
    // 0x0FFFFFF8 lands body + 8 exactly on the cap; one byte either side shows
    // which side of the clamp a given header falls on. LE bytes of 0x0FFFFFF8.
    const at_cap = [_]u8{ 'R', 'I', 'F', 'F', 0xF8, 0xFF, 0xFF, 0x0F } ++ [_]u8{0} ** 8;
    try testing.expectEqual(openmiles.max_declared_image_size, openmiles.detectAudioSize(&at_cap));
    // One byte over the cap clips to the same value rather than growing.
    const over_cap = [_]u8{ 'R', 'I', 'F', 'F', 0xF9, 0xFF, 0xFF, 0x0F } ++ [_]u8{0} ** 8;
    try testing.expectEqual(openmiles.max_declared_image_size, openmiles.detectAudioSize(&over_cap));
    // One byte under the cap is the true declared extent, not the cap.
    const under_cap = [_]u8{ 'R', 'I', 'F', 'F', 0xF7, 0xFF, 0xFF, 0x0F } ++ [_]u8{0} ** 8;
    try testing.expectEqual(openmiles.max_declared_image_size - 1, openmiles.detectAudioSize(&under_cap));
}

test "detectMidiSize returns the sentinel for a MIDI track walk that leaves the image" {
    // Two ways an MThd header can push the track cursor past what a pointer of
    // unknown length can safely be walked: a huge header length puts the first
    // track beyond the streaming sentinel, and a huge track length walks one
    // track too far. Both must report the sentinel (a bounded read) instead of
    // summing header-declared sizes into a plausible-looking extent.
    // hdr_size = 0xFFFFFFFF, 1 track: 8 + hdr_size is already past the sentinel.
    const huge_hdr = [_]u8{
        'M',  'T',  'h',  'd',  0xFF, 0xFF, 0xFF, 0xFF,
        0x00, 0x01, 0x00, 0x01, 0x00, 0x78,
    } ++ [_]u8{0} ** 16;
    try testing.expectEqual(openmiles.streaming_sentinel_size, openmiles.detectMidiSize(&huge_hdr));

    // hdr_size = 6 (first track at 14), track length 0xFFFFFFFF: the walk
    // consumes the 8-byte chunk header and then a length past the sentinel.
    const huge_track = [_]u8{
        'M',  'T',  'h',  'd',  0x00, 0x00, 0x00, 0x06,
        0x00, 0x01, 0x00, 0x01, 0x00, 0x78, 'M',  'T',
        'r',  'k',  0xFF, 0xFF, 0xFF, 0xFF,
    } ++ [_]u8{0} ** 16;
    try testing.expectEqual(openmiles.streaming_sentinel_size, openmiles.detectMidiSize(&huge_track));

    // One byte under the walk limit is still walked, so the result is that exact
    // extent and not the sentinel. The bound is `trk_len > sentinel - pos - 8`
    // with pos = 14, so the largest walkable length is sentinel - 23; one more
    // short-circuits, which the huge_track case above already covers.
    const just_under = [_]u8{
        'M',  'T',  'h',  'd',  0x00, 0x00, 0x00, 0x06,
        0x00, 0x01, 0x00, 0x01, 0x00, 0x78,
        'M', 'T', 'r', 'k', 0x00, 0xFF, 0xFF, 0xE9, // BE 0x00FFFFE9 = sentinel - 23
    } ++ [_]u8{0} ** 16;
    try testing.expectEqual(
        openmiles.streaming_sentinel_size - 1,
        openmiles.detectMidiSize(&just_under),
    );
}

test "Sequence volume set and get roundtrip" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const seq = try openmiles.Sequence.init(driver);
    defer seq.deinit();

    seq.setVolume(100, 0);
    try testing.expectEqual(@as(i32, 100), seq.getVolume());

    seq.setVolume(0, 0);
    try testing.expectEqual(@as(i32, 0), seq.getVolume());
}

test "Sample setType sets PCM format" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    // DIG_F_MONO_8 = 0
    sample.setType(0, 0);
    try testing.expectEqual(@as(u16, 1), sample.pcm_format.?.channels);
    try testing.expectEqual(@as(u16, 8), sample.pcm_format.?.bits);

    // DIG_F_STEREO_16 = 3
    sample.setType(3, 0);
    try testing.expectEqual(@as(u16, 2), sample.pcm_format.?.channels);
    try testing.expectEqual(@as(u16, 16), sample.pcm_format.?.bits);
}

test "Sample reset clears all state" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    sample.setVolume(50);
    sample.setPan(100);
    sample.setType(3, 0);

    sample.reset();

    try testing.expectEqual(@as(f32, 1.0), sample.volume);
    try testing.expectEqual(@as(i32, 127), sample.original_volume);
    try testing.expectEqual(@as(f32, 0.0), sample.pan);
    try testing.expectEqual(@as(f32, 1.0), sample.pitch);
    try testing.expectEqual(@as(i32, 1), sample.loop_count);
    try testing.expectEqual(@as(?openmiles.SamplePcmFormat, null), sample.pcm_format);
}

test "Preference get and set" {
    const pref = @intFromEnum(openmiles.Pref.DIG_MIXER_CHANNELS);
    const old = openmiles.setPreference(pref, 42);
    defer _ = openmiles.setPreference(pref, old);
    try testing.expectEqual(@as(i32, 42), openmiles.getPreference(pref));
}

test "Preference out of bounds returns 0" {
    try testing.expectEqual(@as(i32, 0), openmiles.getPreference(999));
    try testing.expectEqual(@as(i32, 0), openmiles.setPreference(999, 1));

    // The table is 512 slots: 511 is the last valid index and must store and
    // read back, 512 is the first invalid one and must be dropped. Probing
    // only 999 would not catch an off-by-one that reserved the last slot.
    const last: u32 = 511;
    const old_last = openmiles.setPreference(last, 0x5A5A);
    defer _ = openmiles.setPreference(last, old_last);
    try testing.expectEqual(@as(i32, 0x5A5A), openmiles.getPreference(last));
    try testing.expectEqual(@as(i32, 0), openmiles.setPreference(last + 1, 7));
    try testing.expectEqual(@as(i32, 0), openmiles.getPreference(last + 1));
}

test "buildWavFromPcm produces valid RIFF header" {
    const allocator = testing.allocator;
    const pcm = [_]u8{ 0x00, 0x01, 0x02, 0x03 };
    const wav = try openmiles.buildWavFromPcm(allocator, &pcm, 1, 22050, 8);
    defer allocator.free(wav);

    // Check RIFF header
    try testing.expectEqualStrings("RIFF", wav[0..4]);
    try testing.expectEqualStrings("WAVE", wav[8..12]);
    try testing.expectEqualStrings("fmt ", wav[12..16]);
    try testing.expectEqualStrings("data", wav[36..40]);

    // data chunk size should equal pcm length
    const data_size = std.mem.readInt(u32, wav[40..44], .little);
    try testing.expectEqual(@as(u32, 4), data_size);

    // PCM data should be at offset 44
    try testing.expectEqualSlices(u8, &pcm, wav[44..48]);
}

test "xmidiBareToSmf produces valid SMF with note-on and synthetic note-off" {
    const allocator = testing.allocator;
    // Minimal bare FORM/XMID with one Note-On (ch0, note 60, vel 100, dur 120 ticks)
    // EVNT data: delta=0, 0x90, note=0x3C, vel=0x64, VLQ(120)=0x78
    const evnt_data = [_]u8{ 0x00, 0x90, 0x3C, 0x64, 0x78 };
    const xmidi = [_]u8{
        'F', 'O', 'R', 'M',
        0x00, 0x00, 0x00, 0x11, // body size = 17 (4 + 8 + 5)
        'X',  'M',  'I',  'D',
        'E',  'V',  'N',  'T',
        0x00, 0x00, 0x00, 0x05,
    } ++ evnt_data;

    const smf = try openmiles.xmidiBareToSmf(allocator, &xmidi);
    defer allocator.free(smf);

    // Valid SMF header
    try testing.expectEqualStrings("MThd", smf[0..4]);
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, smf[8..10], .big)); // format 0
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, smf[10..12], .big)); // 1 track
    try testing.expectEqual(@as(u16, 120), std.mem.readInt(u16, smf[12..14], .big)); // PPQ=120
    try testing.expectEqualStrings("MTrk", smf[14..18]);

    // SMF must contain note-on (0x90 0x3C 0x64) and synthetic note-off (0x80 0x3C)
    var found_note_on = false;
    var found_note_off = false;
    for (0..smf.len -| 2) |i| {
        if (smf[i] == 0x90 and smf[i + 1] == 0x3C and smf[i + 2] == 0x64) found_note_on = true;
        if (smf[i] == 0x80 and smf[i + 1] == 0x3C) found_note_off = true;
    }
    try testing.expect(found_note_on);
    try testing.expect(found_note_off);

    // Must end with End-of-Track meta event (0xFF 0x2F 0x00)
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0x2F, 0x00 }, smf[smf.len - 3 ..]);
}

test "xmidiToSmf with XDIR wrapper produces valid SMF" {
    const allocator = testing.allocator;
    // XDIR-wrapped XMIDI: FORM/XDIR → CAT /XMID → FORM/XMID → EVNT
    const evnt_data = [_]u8{ 0x00, 0x90, 0x3C, 0x64, 0x78 };
    const xmidi = [_]u8{
        'F', 'O', 'R', 'M',
        0x00, 0x00, 0x00, 0x29, // outer body = 41 (4 + 37)
        'X',  'D',  'I',  'R',
        'C',  'A',  'T',  ' ',
        0x00, 0x00, 0x00, 0x1D, // cat body = 29 (4 + 25)
        'X',  'M',  'I',  'D',
        'F',  'O',  'R',  'M',
        0x00, 0x00, 0x00, 0x11, // inner body = 17 (4 + 8 + 5)
        'X',  'M',  'I',  'D',
        'E',  'V',  'N',  'T',
        0x00, 0x00, 0x00, 0x05,
    } ++ evnt_data;

    const smf = try openmiles.xmidiToSmf(allocator, &xmidi, 0);
    defer allocator.free(smf);

    try testing.expectEqualStrings("MThd", smf[0..4]);
    try testing.expectEqualStrings("MTrk", smf[14..18]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xFF, 0x2F, 0x00 }, smf[smf.len - 3 ..]);
}

test "xmidiBareToSmf preserves tempo meta event" {
    const allocator = testing.allocator;
    // EVNT with tempo (120 BPM = 500000 µs = 0x07A120) then a note
    const evnt_data = [_]u8{
        0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20, // tempo meta
        0x00, 0x90, 0x3C, 0x64, 0x78, // note-on
    };
    const xmidi = [_]u8{
        'F', 'O', 'R', 'M',
        0x00, 0x00, 0x00, 0x18, // body = 24 (4 + 8 + 12)
        'X',  'M',  'I',  'D',
        'E',  'V',  'N',  'T',
        0x00, 0x00, 0x00, 0x0C, // 12 bytes
    } ++ evnt_data;

    const smf = try openmiles.xmidiBareToSmf(allocator, &xmidi);
    defer allocator.free(smf);

    // Search for the file's tempo bytes (0x07 0xA1 0x20) in the output
    var found_tempo = false;
    for (0..smf.len -| 2) |i| {
        if (smf[i] == 0x07 and smf[i + 1] == 0xA1 and smf[i + 2] == 0x20) {
            found_tempo = true;
            break;
        }
    }
    try testing.expect(found_tempo);
}

test "xmidiBareToSmf returns error on invalid data" {
    const allocator = testing.allocator;
    // 4 bytes is too short (needs >= 12)
    const too_short = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try testing.expectError(error.TooShort, openmiles.xmidiBareToSmf(allocator, &too_short));

    // 12 bytes with wrong magic → NotForm
    const bad_magic = [_]u8{ 'N', 'O', 'P', 'E', 0x00, 0x00, 0x00, 0x04, 'X', 'M', 'I', 'D' };
    try testing.expectError(error.NotForm, openmiles.xmidiBareToSmf(allocator, &bad_magic));
}

test "parseSmfTimeSigNumerator extracts time signature" {
    // SMF with time sig 3/4: FF 58 04 03 02 18 08
    const smf = [_]u8{
        'M', 'T', 'h', 'd', 0x00, 0x00, 0x00, 0x06, // MThd, size=6
        0x00, 0x00, 0x00, 0x01, 0x00, 0x78, // format 0, 1 track, PPQ=120
        'M', 'T', 'r', 'k', 0x00, 0x00, 0x00, 0x0C, // MTrk, size=12
        0x00, 0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08, // delta=0, time sig 3/4
        0x00, 0xFF, 0x2F, 0x00, // end of track
    };
    try testing.expectEqual(@as(i32, 3), openmiles.parseSmfTimeSigNumerator(&smf));
}

test "parseSmfTimeSigNumerator returns 4 when no time sig present" {
    // SMF with only end-of-track, no time signature
    const smf = [_]u8{
        'M',  'T',  'h',  'd',  0x00, 0x00, 0x00, 0x06,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x78, 'M',  'T',
        'r',  'k',  0x00, 0x00, 0x00, 0x04, 0x00, 0xFF,
        0x2F, 0x00,
    };
    try testing.expectEqual(@as(i32, 4), openmiles.parseSmfTimeSigNumerator(&smf));
}

test "detectAudioSize for MThd MIDI format" {
    // MThd with 1 track, track data = 4 bytes → total = 14 + 8 + 4 = 26
    const midi = [_]u8{
        'M', 'T', 'h', 'd', 0x00, 0x00, 0x00, 0x06,
        0x00, 0x00, 0x00, 0x01, 0x00, 0x78, // 1 track
        'M',  'T',  'r',  'k',  0x00, 0x00,
        0x00, 0x04, 0x00, 0xFF, 0x2F, 0x00,
    };
    try testing.expectEqual(@as(usize, 26), openmiles.detectAudioSize(&midi));
}

test "Sample initial status is done (SMP_DONE), not stopped" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();
    // SDK inits a sample to SMP_DONE; SMP_STOPPED is only after an explicit stop.
    try testing.expectEqual(openmiles.SampleStatus.done, sample.status());
}

test "Sequence initial status is done when uninitialized" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const seq = try openmiles.Sequence.init(driver);
    defer seq.deinit();

    // Per MSS spec: uninitialized sequence reports SEQ_DONE
    try testing.expectEqual(openmiles.MidiStatus.done, seq.status());

    // An initialized-but-never-played sequence is SEQ_DONE; only after an
    // explicit AIL_stop_sequence is it SEQ_STOPPED (SEQ_DONE = finished or not
    // yet played). Drive the status() logic via the flags directly.
    seq.is_initialized = true;
    seq.was_stopped.store(false, .release);
    try testing.expectEqual(openmiles.MidiStatus.done, seq.status());
    seq.was_stopped.store(true, .release);
    try testing.expectEqual(openmiles.MidiStatus.stopped, seq.status());
    seq.is_initialized = false; // restore so deinit doesn't touch the undefined sound
}

test "setLastError and clearLastError" {
    openmiles.setLastError("test error message");
    try testing.expectEqualStrings("test error message", std.mem.sliceTo(&openmiles.last_error_buf, 0));

    openmiles.clearLastError();
    try testing.expectEqual(@as(u8, 0), openmiles.last_error_buf[0]);
}

test "setFileError and clearFileError" {
    openmiles.setFileError("file not found");
    try testing.expectEqualStrings("file not found", std.mem.sliceTo(&openmiles.last_file_error_buf, 0));

    openmiles.clearFileError();
    try testing.expectEqual(@as(u8, 0), openmiles.last_file_error_buf[0]);
}

test "setLastError truncates long messages" {
    const long_msg = "A" ** 300;
    openmiles.setLastError(long_msg);
    defer openmiles.clearLastError();
    const stored = std.mem.sliceTo(&openmiles.last_error_buf, 0);
    try testing.expectEqual(@as(usize, 255), stored.len);
}

test "isPluginExtension identifies valid extensions" {
    try testing.expect(openmiles.isPluginExtension("decoder.asi"));
    try testing.expect(openmiles.isPluginExtension("reverb.m3d"));
    try testing.expect(openmiles.isPluginExtension("filter.flt"));
    try testing.expect(openmiles.isPluginExtension("DECODER.ASI"));
    try testing.expect(openmiles.isPluginExtension("reverb.M3D"));
}

test "isPluginExtension rejects invalid extensions" {
    try testing.expect(!openmiles.isPluginExtension("file.dll"));
    try testing.expect(!openmiles.isPluginExtension("file.wav"));
    try testing.expect(!openmiles.isPluginExtension("asi")); // too short
    try testing.expect(!openmiles.isPluginExtension(""));
}

test "isSafePluginFilename rejects names that do not name a file" {
    // Escaping the scan directory.
    try testing.expect(!openmiles.isSafePluginFilename("../decoder.asi"));
    try testing.expect(!openmiles.isSafePluginFilename("sub/decoder.asi"));
    try testing.expect(!openmiles.isSafePluginFilename("sub\\decoder.asi"));
    // A trailing dot or space is dropped before the name is stored, so the
    // entry read back is not the name that was scanned.
    try testing.expect(!openmiles.isSafePluginFilename("decoder.asi "));
    try testing.expect(!openmiles.isSafePluginFilename("decoder.asi."));
    // ':' opens an NTFS named stream rather than the file the entry names.
    try testing.expect(!openmiles.isSafePluginFilename("decoder.asi:payload"));
    // DOS device names resolve to a device, and under Wine such an entry is a
    // real file in a POSIX game directory.
    for ([_][]const u8{
        "NUL.asi",
        "nul.asi",
        "CON.asi",
        "prn.asi",
        "aux.m3d",
        "CLOCK$.flt",
        "COM1.asi",
        "lpt9.flt",
        "NUL",
        // A space before the extension is stripped by the path parser before
        // the name is resolved, so these are the same devices, not files.
        "NUL .asi",
        "con .asi",
        "COM1 .m3d",
        "CLOCK$ .flt",
    }) |name| {
        testing.expect(!openmiles.isSafePluginFilename(name)) catch |err| {
            std.debug.print("expected '{s}' to be rejected\n", .{name});
            return err;
        };
    }
}

test "isSafePluginFilename accepts ordinary plugin names" {
    for ([_][]const u8{
        "decoder.asi",
        "Miles Sound Decoder.asi",
        "reverb_v2.m3d",
        "COM0.asi",
        "NULL.asi",
        "CONSOLE.asi",
    }) |name| {
        testing.expect(openmiles.isSafePluginFilename(name)) catch |err| {
            std.debug.print("expected '{s}' to be accepted\n", .{name});
            return err;
        };
    }
}

test "registerDriver and isKnownDriver" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);

    // Driver should be known after init (init calls registerDriver)
    try testing.expect(openmiles.isKnownDriver(@ptrCast(driver)));

    // After deinit (which calls unregisterDriver), it should no longer be known
    driver.deinit();
    try testing.expect(!openmiles.isKnownDriver(@ptrCast(driver)));
}

test "Sample3D init deinit and default properties" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    try testing.expectEqual(@as(usize, 1), driver.samples_3d.items.len);
    try testing.expectEqual(@as(f32, 1.0), s.volume);
    try testing.expectEqual(@as(f32, 1.0), s.min_distance);
    try testing.expectEqual(@as(f32, 200.0), s.max_distance); // MSS default (wavefile.cpp)
    // MSS default orientation: face = +X, up = +Y.
    try testing.expectEqual(@as(f32, 1.0), s.orient_fx);
    try testing.expectEqual(@as(f32, 0.0), s.orient_fz);
    try testing.expectEqual(@as(f32, 1.0), s.orient_uy);
    try testing.expect(!s.is_initialized);

    // Fresh, unloaded 3D sample reports the 11025 init default (original_playback_
    // rate), mirroring the 2D getter — not the 44100 device rate.
    const sp: ?*anyopaque = @ptrCast(s);
    try testing.expectEqual(@as(i32, 11025), api_3d.AIL_3D_sample_playback_rate(sp));
    api_3d.AIL_set_3D_sample_playback_rate(sp, 32000);
    try testing.expectEqual(@as(i32, 32000), api_3d.AIL_3D_sample_playback_rate(sp));

    s.deinit();
    try testing.expectEqual(@as(usize, 0), driver.samples_3d.items.len);
}

test "3D loop count getter reports the remaining count like the 2D one" {
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();
    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();
    const sp: ?*anyopaque = @ptrCast(s);
    // MSS S->loop_count is the field that decrements during playback, so the
    // getter mirrors AIL_sample_loop_count rather than reporting the app-set
    // original.
    try testing.expectEqual(@as(i32, 1), api_3d.AIL_3D_sample_loop_count(sp));
    api_3d.AIL_set_3D_sample_loop_count(sp, 3);
    try testing.expectEqual(@as(i32, 3), api_3d.AIL_3D_sample_loop_count(sp));
    try testing.expectEqual(@as(i32, 3), s.loops_remaining.load(.acquire));
}

test "buildWavFromPcm stereo 16-bit" {
    const allocator = testing.allocator;
    // 4 bytes = 1 stereo frame at 16-bit (2 channels * 2 bytes)
    const pcm = [_]u8{ 0x00, 0x01, 0x80, 0xFF };
    const wav = try openmiles.buildWavFromPcm(allocator, &pcm, 2, 44100, 16);
    defer allocator.free(wav);

    try testing.expectEqualStrings("RIFF", wav[0..4]);
    try testing.expectEqualStrings("WAVE", wav[8..12]);

    // fmt chunk: channels
    const channels = std.mem.readInt(u16, wav[22..24], .little);
    try testing.expectEqual(@as(u16, 2), channels);

    // fmt chunk: sample rate
    const rate = std.mem.readInt(u32, wav[24..28], .little);
    try testing.expectEqual(@as(u32, 44100), rate);

    // fmt chunk: bits per sample
    const bits = std.mem.readInt(u16, wav[34..36], .little);
    try testing.expectEqual(@as(u16, 16), bits);

    // data chunk size
    const data_size = std.mem.readInt(u32, wav[40..44], .little);
    try testing.expectEqual(@as(u32, 4), data_size);
}

test "buildWavFromPcm zero-length PCM" {
    const allocator = testing.allocator;
    const pcm = [_]u8{};
    const wav = try openmiles.buildWavFromPcm(allocator, &pcm, 1, 22050, 8);
    defer allocator.free(wav);

    try testing.expectEqualStrings("RIFF", wav[0..4]);
    const data_size = std.mem.readInt(u32, wav[40..44], .little);
    try testing.expectEqual(@as(u32, 0), data_size);
    // Total WAV = 44 bytes header + 0 data
    try testing.expectEqual(@as(usize, 44), wav.len);
}

test "detectMidiSize for FORM/XMID header" {
    const data = [_]u8{
        'F', 'O', 'R', 'M',
        0x00, 0x00, 0x00, 0x10, // body = 16
    } ++ [_]u8{0} ** 16;
    try testing.expectEqual(@as(usize, 24), openmiles.detectMidiSize(&data)); // 16 + 8
}

test "detectMidiSize unknown format returns sentinel" {
    const data = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x00, 0x00, 0x00 } ++ [_]u8{0} ** 8;
    try testing.expectEqual(openmiles.streaming_sentinel_size, openmiles.detectMidiSize(&data));
}

test "getMsCount returns monotonically increasing values" {
    const t1 = openmiles.getMsCount();
    // Poll until the clock ticks (bounded) rather than trusting a fixed sleep:
    // a swallowed sleep error must not fail the assertion, a stalled clock must.
    var waited: u32 = 0;
    while (openmiles.getMsCount() == t1 and waited < 5000) : (waited += 10) {
        openmiles.io.sleep(std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
    }
    try testing.expect(openmiles.getMsCount() > t1);
}

test "getUsCount returns monotonically increasing values" {
    const t1 = openmiles.getUsCount();
    var waited: u32 = 0;
    while (openmiles.getUsCount() == t1 and waited < 5000) : (waited += 10) {
        openmiles.io.sleep(std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
    }
    try testing.expect(openmiles.getUsCount() > t1);
}

test "getRedistDirectory is empty when none is set" {
    // The redist directory is a process global. Asserting that it "starts"
    // empty only holds while no earlier test left a value behind, so pin the
    // state the API actually promises: a cleared directory reads back empty.
    openmiles.setRedistDirectory("./om_redist_probe");
    openmiles.setRedistDirectory("");
    defer openmiles.setRedistDirectory("");
    try testing.expectEqual(@as(usize, 0), openmiles.getRedistDirectory().len);
}

test "setRedistDirectory and getRedistDirectory roundtrip" {
    openmiles.setRedistDirectory("./test_plugins");
    defer openmiles.setRedistDirectory("");
    try testing.expectEqualStrings("./test_plugins", openmiles.getRedistDirectory());
}

test "getRedistDirectoryCopy hands back an owned copy that outlives a rewrite" {
    // getRedistDirectory borrows the shared buffer, so a caller that holds the
    // bytes across a set reads whatever the set left there. The copy is taken
    // under the lock and is the caller's to free, which is what the plugin scan
    // in openDigitalDriver walks for its whole run.
    openmiles.setRedistDirectory("./om_copy_first");
    const copy = try openmiles.getRedistDirectoryCopy(testing.allocator);
    defer testing.allocator.free(copy);
    openmiles.setRedistDirectory("./om_copy_second");
    try testing.expectEqualStrings("./om_copy_first", copy);
    // The borrowed read follows the rewrite, which is what makes the copy the
    // form a caller that holds the path has to use.
    try testing.expectEqualStrings("./om_copy_second", openmiles.getRedistDirectory());

    openmiles.setRedistDirectory("");
    const empty = try openmiles.getRedistDirectoryCopy(testing.allocator);
    defer testing.allocator.free(empty);
    try testing.expectEqual(@as(usize, 0), empty.len);
    openmiles.setRedistDirectory("");
}

test "AIL_set_redist_directory returns the stored directory pointer (SDK char*)" {
    const api_digital = @import("api/digital.zig");
    defer openmiles.setRedistDirectory("");
    const ret = api_digital.AIL_set_redist_directory("/opt/miles");
    try testing.expectEqualStrings("/opt/miles", std.mem.span(ret));
    // AIL_MIDI_handle_release now returns S32 (1 = released).
    const mh = @import("api/midi.zig");
    var scratch: u8 = 0;
    try testing.expectEqual(@as(i32, 1), mh.AIL_MIDI_handle_release(@ptrCast(&scratch)));
}

test "setRedistDirectory refuses a path longer than the buffer" {
    // A long path is refused, not cut. A byte prefix of it is usually a real
    // directory (a parent of the intended one), and the stored value is the
    // directory .asi/.m3d/.flt images are loaded and executed from, so cutting
    // would move the plugin search somewhere the caller never named. The
    // previous directory survives the refusal.
    openmiles.setRedistDirectory("./test_plugins");
    defer openmiles.setRedistDirectory("");
    const long_path = "/" ++ "a" ** 300;
    openmiles.setRedistDirectory(long_path);
    try testing.expectEqualStrings("./test_plugins", openmiles.getRedistDirectory());
    openmiles.setRedistDirectory("");
    openmiles.setRedistDirectory(long_path);
    try testing.expectEqual(@as(usize, 0), openmiles.getRedistDirectory().len);
}

test "a WAV declaring a 4 GiB RIFF body is inspected, not trapped" {
    // The RIFF body size is a file-controlled u32. On the 32-bit target
    // (mss32.dll) usize is u32, so an unchecked `body + 8` is a checked
    // overflow and a 12-byte file traps the host process. The header walk must
    // clamp to the known length instead, which leaves no data chunk here.
    var hdr = [_]u8{ 'R', 'I', 'F', 'F', 0xFF, 0xFF, 0xFF, 0xFF, 'W', 'A', 'V', 'E' };
    var info: openmiles.AILSOUNDINFO = undefined;
    try testing.expectEqual(@as(i32, 0), openmiles.wavInfoBounded(&hdr, hdr.len, &info));
    // With a data chunk inside the declared body, the parse still succeeds and
    // reports only the bytes actually present.
    const full = [_]u8{
        'R', 'I', 'F', 'F', 0xFF, 0xFF, 0xFF, 0xFF, 'W', 'A', 'V', 'E', //
        'f', 'm', 't', ' ', 16, 0, 0, 0, //
        1, 0, 1, 0, 0x44, 0xAC, 0, 0, //
        0x88, 0x58, 0x01, 0,   2, 0, 16, 0, //
        'd',  'a',  't',  'a', 4, 0, 0,  0,
        1,    2,    3,    4,
    };
    try testing.expectEqual(@as(i32, 1), openmiles.wavInfoBounded(&full, full.len, &info));
    try testing.expectEqual(@as(u32, 4), info.data_len);
}

test "mssVolumeToGain boundary values" {
    try testing.expectEqual(@as(f32, 0.0), openmiles.mssVolumeToGain(0));
    try testing.expectEqual(@as(f32, 0.0), openmiles.mssVolumeToGain(-5));
    try testing.expectEqual(@as(f32, 1.0), openmiles.mssVolumeToGain(127));
    try testing.expectEqual(@as(f32, 1.0), openmiles.mssVolumeToGain(200));

    // The 0..127 -> gain table is the SDK's volume_pan curve gain=(v/127)^(10/6)
    // (wavefile.cpp AIL_API_set_sample_volume_pan), NOT the old v^3 it replaced.
    // Pin three interior points so a regression to v^3 (which gives 0.016/0.128/
    // 0.43 here) is caught, not just the 0.30..0.33 mid band.
    inline for (.{ .{ 32, 0.1005 }, .{ 64, 0.3191 }, .{ 96, 0.6273 } }) |c| {
        try testing.expect(@abs(openmiles.mssVolumeToGain(c[0]) - c[1]) < 0.001);
    }
}

test "gainToMssVolume boundary values" {
    try testing.expectEqual(@as(i32, 0), openmiles.gainToMssVolume(0.0));
    try testing.expectEqual(@as(i32, 0), openmiles.gainToMssVolume(-1.0));
    try testing.expectEqual(@as(i32, 127), openmiles.gainToMssVolume(1.0));
    try testing.expectEqual(@as(i32, 127), openmiles.gainToMssVolume(2.0));
    // A gain below the table's first entry is nearer to 0 than to 1.
    try testing.expectEqual(@as(i32, 0), openmiles.gainToMssVolume(1e-6));
    try testing.expectEqual(@as(i32, 1), openmiles.gainToMssVolume(openmiles.mssVolumeToGain(1) * 0.9));
}

test "mssVolumeToGain and gainToMssVolume roundtrip" {
    const test_values = [_]i32{ 0, 1, 32, 64, 100, 126, 127 };
    for (test_values) |v| {
        const gain = openmiles.mssVolumeToGain(v);
        const back = openmiles.gainToMssVolume(gain);
        try testing.expectEqual(v, back);
    }
}

test "lockChannel and releaseChannel" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    for (&openmiles.locked_channels.*) |*slot| slot.* = null;

    const seq = try openmiles.Sequence.init(driver);
    defer seq.deinit();

    const ch = openmiles.lockChannel(seq);
    try testing.expect(ch >= 0 and ch <= 15);
    try testing.expect(ch != 9);

    openmiles.releaseChannel(seq, ch);
    try testing.expectEqual(@as(?*anyopaque, null), openmiles.locked_channels[@intCast(ch)]);
}

test "lockChannel skips percussion channel 9" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    // Defensively clear any leaked channel locks from prior tests
    for (&openmiles.locked_channels.*) |*slot| slot.* = null;

    var seqs: [15]*openmiles.Sequence = undefined;
    var channels: [15]i32 = undefined;
    var count: usize = 0;
    defer {
        for (0..count) |i| {
            openmiles.releaseChannel(seqs[i], channels[i]);
            seqs[i].deinit();
        }
    }

    for (0..15) |_| {
        const seq = try openmiles.Sequence.init(driver);
        const ch = openmiles.lockChannel(seq);
        if (ch < 0) {
            seq.deinit();
            break;
        }
        try testing.expect(ch != 9);
        seqs[count] = seq;
        channels[count] = ch;
        count += 1;
    }

    // All 15 non-percussion channels (0-8, 10-15) must be locked
    try testing.expectEqual(@as(usize, 15), count);

    // 16th lock attempt must fail (all channels taken)
    const extra_seq = try openmiles.Sequence.init(driver);
    defer extra_seq.deinit();
    try testing.expectEqual(@as(i32, -1), openmiles.lockChannel(extra_seq));
}

test "closing a MIDI driver releases the channels it locked" {
    const allocator = testing.allocator;
    for (&openmiles.locked_channels.*) |*slot| slot.* = null;
    defer {
        for (&openmiles.locked_channels.*) |*slot| slot.* = null;
    }

    const first = try openmiles.MidiDriver.init(allocator);
    var owned: usize = 0;
    while (openmiles.lockChannel(@ptrCast(first)) >= 0) owned += 1;
    try testing.expectEqual(@as(usize, 15), owned); // channel 9 is not lockable
    first.deinit();

    // Every slot the dead driver held is free again; otherwise each
    // open/close cycle would cost the process lockable channels and
    // AIL_lock_channel would answer -1 for the rest of the run.
    for (openmiles.locked_channels.*) |slot| {
        try testing.expectEqual(@as(?*anyopaque, null), slot);
    }
    const second = try openmiles.MidiDriver.init(allocator);
    defer second.deinit();
    try testing.expect(openmiles.lockChannel(@ptrCast(second)) >= 0);
}

test "freeing a sequence releases the channels it locked" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();
    for (&openmiles.locked_channels.*) |*slot| slot.* = null;

    const seq = try openmiles.Sequence.init(driver);
    const ch = openmiles.lockChannel(@ptrCast(seq));
    try testing.expect(ch >= 0);
    seq.deinit();
    try testing.expectEqual(@as(?*anyopaque, null), openmiles.locked_channels[@intCast(ch)]);
}

test "preference defaults match MSS spec at version-correct indices" {
    // The preference *numbers* are ABI: a game passes the mss.h constant for its
    // target version. MSS 9.0 renumbered the table (verified by disassembling
    // init_preferences), so the defaults must land at the version-correct slots.
    const get = openmiles.getPreference;
    if (openmiles.mss_version >= 90) {
        // 9.x numbering (include/mss.h) + 9.x DEFAULT_* values.
        try testing.expectEqual(@as(i32, 1), get(0)); // AIL_MM_PERIOD (DEFAULT_AMP=1)
        try testing.expectEqual(@as(i32, 16), get(1)); // AIL_TIMERS
        try testing.expectEqual(@as(i32, 64), get(3)); // DIG_MIXER_CHANNELS
        try testing.expectEqual(@as(i32, 131), get(5)); // DIG_RESAMPLING_TOLERANCE
        try testing.expectEqual(@as(i32, 49152), get(18)); // DIG_OUTPUT_BUFFER_SIZE
        try testing.expectEqual(@as(i32, 120), get(22)); // MDI_SERVICE_RATE
        try testing.expectEqual(@as(i32, 127), get(23)); // MDI_DEFAULT_VOLUME
        try testing.expectEqual(@as(i32, 2), get(26)); // MDI_DEFAULT_BEND_RANGE
        // Old-layout slot must NOT carry the old default any more.
        try testing.expectEqual(@as(i32, 16), get(1)); // not DIG_MIXER_CHANNELS=64
    } else {
        // 3.x..8.x numbering (Pref enum) + that era's DEFAULT_* values.
        const P = openmiles.Pref;
        try testing.expectEqual(@as(i32, 131), get(@intFromEnum(P.DIG_RESAMPLING_TOLERANCE)));
        try testing.expectEqual(@as(i32, 64), get(@intFromEnum(P.DIG_MIXER_CHANNELS)));
        try testing.expectEqual(@as(i32, 127), get(@intFromEnum(P.DIG_DEFAULT_VOLUME)));
        try testing.expectEqual(@as(i32, 120), get(@intFromEnum(P.MDI_SERVICE_RATE)));
        try testing.expectEqual(@as(i32, 8), get(@intFromEnum(P.MDI_SEQUENCES)));
        try testing.expectEqual(@as(i32, 127), get(@intFromEnum(P.MDI_DEFAULT_VOLUME)));
        try testing.expectEqual(@as(i32, 5), get(@intFromEnum(P.AIL_MM_PERIOD)));
    }
}

test "detectMidiSize MThd with multiple tracks" {
    const midi = [_]u8{
        'M', 'T', 'h', 'd', 0x00, 0x00, 0x00, 0x06,
        0x00, 0x01, 0x00, 0x02, 0x00, 0x78, // format 1, 2 tracks
        'M',  'T',  'r',  'k',  0x00, 0x00,
        0x00, 0x04,
        0x00, 0xFF, 0x2F, 0x00, // track 1: 4 bytes
        'M',  'T',  'r',  'k',
        0x00, 0x00, 0x00, 0x04,
        0x00, 0xFF, 0x2F, 0x00, // track 2: 4 bytes
    };
    // 14 (header) + 8+4 (track 1) + 8+4 (track 2) = 38
    try testing.expectEqual(@as(usize, 38), openmiles.detectMidiSize(&midi));
}

test "setFileError truncates long messages" {
    const long_msg = "B" ** 300;
    openmiles.setFileError(long_msg);
    defer openmiles.clearFileError();
    const stored = std.mem.sliceTo(&openmiles.last_file_error_buf, 0);
    try testing.expectEqual(@as(usize, 255), stored.len);
}

test "error and path buffers cut on a character boundary" {
    // Every message in these buffers names a file the library did not author,
    // and a game directory outside ASCII is ordinary. The 255-byte cut lands
    // inside a character of a long one, so what is stored has to drop that
    // character whole: a lead byte left in the buffer is a broken sequence for
    // the caller reading it as UTF-8.
    openmiles.setLastError("cannot open \u{1F600}" ++ "x" ** 300);
    defer openmiles.clearLastError();
    try testing.expect(std.unicode.utf8ValidateSlice(std.mem.sliceTo(&openmiles.last_error_buf, 0)));

    openmiles.setFileError("cannot read \u{00e9}" ++ "y" ** 300);
    defer openmiles.clearFileError();
    try testing.expect(std.unicode.utf8ValidateSlice(std.mem.sliceTo(&openmiles.last_file_error_buf, 0)));

    // A path that does not fit the redist buffer is refused rather than cut, so
    // nothing is stored; the two error buffers above are the ones that cut, and
    // each has to drop a partial character whole.
    openmiles.setRedistDirectory("/games/" ++ "\u{1F600}" ** 64);
    defer openmiles.setRedistDirectory("");
    const stored = openmiles.getRedistDirectory();
    try testing.expectEqual(@as(usize, 0), stored.len);
}

test "xmidiToSmf returns error on invalid data" {
    const allocator = testing.allocator;
    const too_short = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF };
    try testing.expectError(error.TooShort, openmiles.xmidiToSmf(allocator, &too_short, 0));

    // Valid FORM but not XDIR
    const not_xdir = [_]u8{
        'F', 'O', 'R', 'M', 0x00, 0x00, 0x00, 0x04,
        'X', 'M', 'I', 'D',
    };
    try testing.expectError(error.NotXdir, openmiles.xmidiToSmf(allocator, &not_xdir, 0));
}

test "Sample3D setMinMaxDistance" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    s.setMinMaxDistance(5.0, 200.0);
    try testing.expectEqual(@as(f32, 5.0), s.min_distance);
    try testing.expectEqual(@as(f32, 200.0), s.max_distance);

    // SDK swaps when min > max so the stored pair is always ordered.
    s.setMinMaxDistance(300.0, 10.0);
    try testing.expectEqual(@as(f32, 10.0), s.min_distance);
    try testing.expectEqual(@as(f32, 300.0), s.max_distance);
}

test "Sample3D setVolume uses cubic curve" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    s.setVolume(127);
    try testing.expectEqual(@as(f32, 1.0), s.volume);

    s.setVolume(0);
    try testing.expectEqual(@as(f32, 0.0), s.volume);
}

test "Sample3D setPosition updates coordinates" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    s.setPosition(1.0, 2.0, 3.0);
    try testing.expectEqual(@as(f32, 1.0), s.pos_x);
    try testing.expectEqual(@as(f32, 2.0), s.pos_y);
    try testing.expectEqual(@as(f32, 3.0), s.pos_z);
}

test "Sample3D initial status is done (SMP_DONE), not stopped" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    try testing.expectEqual(openmiles.SampleStatus.done, s.status());
}

test "Sequence setChannelMap and getPhysicalChannel" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const seq = try openmiles.Sequence.init(driver);
    defer seq.deinit();

    // Default: identity mapping
    try testing.expectEqual(@as(i32, 5), seq.getPhysicalChannel(5));

    seq.setChannelMap(5, 10);
    try testing.expectEqual(@as(i32, 10), seq.getPhysicalChannel(5));

    // Clamping: out-of-range logical/physical
    seq.setChannelMap(-1, 20);
    try testing.expectEqual(@as(i32, 15), seq.getPhysicalChannel(-1));
}

test "DigitalDriver getActiveSampleCount" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    try testing.expectEqual(@as(u32, 0), driver.getActiveSampleCount(std.math.maxInt(u32)));

    const s1 = try openmiles.Sample.init(driver);
    defer s1.deinit();
    const s2 = try openmiles.Sample.init(driver);
    defer s2.deinit();
    // Uninitialized samples are stopped, not playing
    try testing.expectEqual(@as(u32, 0), driver.getActiveSampleCount(std.math.maxInt(u32)));

    // The counter is what AIL_digital_CPU_percent scales by, so a sample that
    // is actually playing must raise it and stopping that sample must lower it
    // again. Asserting only the zero cases would pass if the loop counted
    // nothing at all.
    const wav = try zeroWav(allocator);
    defer allocator.free(wav);
    try s1.loadFromMemory(wav, true);
    try s2.loadFromMemory(wav, true);
    s1.start();
    try testing.expectEqual(openmiles.SampleStatus.playing, s1.status());
    try testing.expectEqual(@as(u32, 1), driver.getActiveSampleCount(std.math.maxInt(u32)));
    s2.start();
    try testing.expectEqual(@as(u32, 2), driver.getActiveSampleCount(std.math.maxInt(u32)));
    s1.stop();
    try testing.expectEqual(@as(u32, 1), driver.getActiveSampleCount(std.math.maxInt(u32)));
    s2.end(); // done, not stopped: still not playing
    try testing.expectEqual(@as(u32, 0), driver.getActiveSampleCount(std.math.maxInt(u32)));
}

test "releaseChannel ignores out-of-range channel" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const seq = try openmiles.Sequence.init(driver);
    defer seq.deinit();

    // Lock one channel so a buggy out-of-range release has visible state to
    // corrupt: it must neither clear the valid slot nor touch any other slot.
    for (&openmiles.locked_channels.*) |*slot| slot.* = null;
    const ch = openmiles.lockChannel(seq);
    try testing.expect(ch >= 0 and ch <= 15);

    openmiles.releaseChannel(seq, -1);
    openmiles.releaseChannel(seq, 16);
    openmiles.releaseChannel(seq, 100);

    for (&openmiles.locked_channels.*, 0..) |*slot, i| {
        if (i == @as(usize, @intCast(ch))) {
            try testing.expectEqual(@as(?*anyopaque, @ptrCast(seq)), slot.*);
        } else {
            try testing.expectEqual(@as(?*anyopaque, null), slot.*);
        }
    }

    // The in-range release still works afterwards.
    openmiles.releaseChannel(seq, ch);
    try testing.expectEqual(@as(?*anyopaque, null), openmiles.locked_channels[@intCast(ch)]);
}

test "Sample setLoopCount" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    try testing.expectEqual(@as(i32, 1), sample.loop_count);

    sample.setLoopCount(0);
    try testing.expectEqual(@as(i32, 0), sample.loop_count);

    sample.setLoopCount(5);
    try testing.expectEqual(@as(i32, 5), sample.loop_count);
}

test "Sample setPlaybackRate" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    sample.setPlaybackRate(22050);
    try testing.expectEqual(@as(?f32, 22050.0), sample.target_rate);
}

test "Sequence startTempoFade instant" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const seq = try openmiles.Sequence.init(driver);
    defer seq.deinit();

    // Instant change (duration <= 0)
    seq.startTempoFade(240, 0);
    try testing.expectEqual(@as(i32, 240), seq.user_bpm);
    try testing.expect(!seq.tempo_fade_active);
}

test "Sequence startTempoFade gradual" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const seq = try openmiles.Sequence.init(driver);
    defer seq.deinit();

    seq.startTempoFade(240, 1000);
    try testing.expectEqual(@as(i32, 240), seq.user_bpm);
    try testing.expect(seq.tempo_fade_active);
    try testing.expectEqual(@as(f64, 1000.0), seq.tempo_fade_duration_ms);
}

test "Sample3D setObstruction and setOcclusion" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    s.setObstruction(0.75);
    try testing.expectEqual(@as(f32, 0.75), s.obstruction);

    s.setOcclusion(0.5);
    try testing.expectEqual(@as(f32, 0.5), s.occlusion);
}

test "Sample3D obstruction has no volume effect; occlusion attenuates (m3d model)" {
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();
    try s.loadFromMemory(wav, false);
    s.setVolume(127); // gain ~1.0
    const base = openmiles.ma.ma_sound_get_volume(&s.sound);
    // Obstruction: stored, but no change to the mixed volume.
    s.setObstruction(0.9);
    try testing.expect(@abs(openmiles.ma.ma_sound_get_volume(&s.sound) - base) < 0.001);
    // Occlusion 0.5: volume scaled by (1 - 0.5).
    s.setOcclusion(0.5);
    try testing.expect(@abs(openmiles.ma.ma_sound_get_volume(&s.sound) - base * 0.5) < 0.01);
}

test "Sample3D setVelocity" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    s.setVelocity(10.0, 20.0, 30.0);
    try testing.expectEqual(@as(f32, 10.0), s.velocity_x);
    try testing.expectEqual(@as(f32, 20.0), s.velocity_y);
    try testing.expectEqual(@as(f32, 30.0), s.velocity_z);
}

test "Sample3D setLoopCount" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    try testing.expectEqual(@as(i32, 1), s.loop_count);

    s.setLoopCount(0);
    try testing.expectEqual(@as(i32, 0), s.loop_count);

    s.setLoopCount(3);
    try testing.expectEqual(@as(i32, 3), s.loop_count);
}

test "isSafePluginFilename rejects path traversal" {
    try testing.expect(!openmiles.isSafePluginFilename("../evil.asi"));
    try testing.expect(!openmiles.isSafePluginFilename("foo/../bar.asi"));
    try testing.expect(!openmiles.isSafePluginFilename("sub/plugin.asi"));
    try testing.expect(!openmiles.isSafePluginFilename("sub\\plugin.asi"));
    try testing.expect(!openmiles.isSafePluginFilename("..\\evil.asi"));
}

test "isSafePluginFilename accepts safe names" {
    try testing.expect(openmiles.isSafePluginFilename("decoder.asi"));
    try testing.expect(openmiles.isSafePluginFilename("my_plugin.m3d"));
    try testing.expect(openmiles.isSafePluginFilename("reverb.flt"));
    try testing.expect(openmiles.isSafePluginFilename(""));
    try testing.expect(openmiles.isSafePluginFilename("a"));
}

test "loadApplicationProviders skips corrupt plugins and missing directories" {
    // Games ship broken third-party .asi files; discovery must filter by
    // extension, skip unloadable candidates, and keep running (count 0, no
    // provider registered, no crash) -- the same graceful-degradation contract
    // native_rib_test exercises manually against real plugins.
    const io = openmiles.io;
    const cwd = std.Io.Dir.cwd();
    const dirname = "om_prov_scan_test";
    cwd.createDir(io, dirname, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer cwd.deleteTree(io, dirname) catch {};
    try cwd.writeFile(io, .{ .sub_path = dirname ++ "/readme.txt", .data = "not a plugin" });
    try cwd.writeFile(io, .{ .sub_path = dirname ++ "/broken.asi", .data = "\xDE\xAD\xBE\xEF" ** 4 });

    const before = openmiles.getProviderCount();
    try testing.expectEqual(@as(i32, 0), openmiles.loadApplicationProviders(dirname));
    try testing.expectEqual(before, openmiles.getProviderCount());

    // A nonexistent directory is reported and returns 0 rather than crashing.
    try testing.expectEqual(@as(i32, 0), openmiles.loadApplicationProviders(dirname ++ "/missing"));
}

test "sortedPluginNames returns the directory's plugins in name order" {
    // The scan feeds provider registration and RIB_enumerate_providers, so the
    // list it produces must depend on the directory's contents and nothing
    // else. A directory read returns entries in filesystem order, so the names
    // are created here in reverse and the result is asserted sorted.
    const io = openmiles.io;
    const cwd = std.Io.Dir.cwd();
    const dirname = "om_prov_sort_test";
    cwd.createDir(io, dirname, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer cwd.deleteTree(io, dirname) catch {};
    for ([_][]const u8{ "zulu.asi", "mike.m3d", "alpha.flt", "readme.txt", "nested" }) |name| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dirname, name });
        try cwd.writeFile(io, .{ .sub_path = path, .data = "x" });
    }

    const names = try openmiles.sortedPluginNames(testing.allocator, dirname);
    defer openmiles.freePluginNames(testing.allocator, &names);
    // Only plugins, ascending: the .txt is filtered by extension and the
    // traversal order of the filesystem is not observable here.
    const expected = [_][]const u8{ "alpha.flt", "mike.m3d", "zulu.asi" };
    try testing.expectEqual(expected.len, names.items.len);
    for (expected, names.items) |want, got| try testing.expectEqualStrings(want, got);
}

test "unregistering an interface name removes every registration of it" {
    // A provider can hold two registrations under one name (RIB_Main may call
    // register more than once). Unregistering must take both: dropping only
    // the first would leave a copy still answering entry lookups, and the
    // second unregister would then still change state.
    const p = try openmiles.Provider.init(testing.allocator);
    defer p.deinit();

    var cut = [_]openmiles.RIB_INTERFACE_ENTRY{.{
        .entry_type = .RIB_ATTRIBUTE,
        .name = "cutoff",
        .token = 1,
        .subtype = 0,
    }};
    var keep = [_]openmiles.RIB_INTERFACE_ENTRY{.{
        .entry_type = .RIB_ATTRIBUTE,
        .name = "master",
        .token = 2,
        .subtype = 0,
    }};
    _ = try p.registerInterface("filter", 1, &cut);
    _ = try p.registerInterface("other", 1, &keep);
    _ = try p.registerInterface("filter", 1, &cut);
    try testing.expectEqual(@as(usize, 3), p.interfaces.items.len);

    p.unregisterInterface("filter");
    try testing.expectEqual(@as(usize, 1), p.interfaces.items.len);
    try testing.expectEqualStrings("other", p.interfaces.items[0].name);
    try testing.expectEqual(@as(?usize, null), p.interfaces.items[0].tokenFor("cutoff"));

    // A second unregister of the same name is a no-op, not another change.
    p.unregisterInterface("filter");
    try testing.expectEqual(@as(usize, 1), p.interfaces.items.len);
}

test "registering an interface rejects a count that is negative or over the ceiling" {
    // Both counts come from the loaded module. A negative one would index
    // backwards; an absurd one drives a name dupe and a hash insert per
    // declared entry, growing the interface by a number the module chose. The
    // rejection must be loud: silently registering nothing hands the plugin an
    // empty interface it believes it filled.
    const p = try openmiles.Provider.init(testing.allocator);
    defer p.deinit();

    var entry = [_]openmiles.RIB_INTERFACE_ENTRY{.{
        .entry_type = .RIB_ATTRIBUTE,
        .name = "cutoff",
        .token = 1,
        .subtype = 0,
    }};
    try testing.expectError(error.NegativeEntryCount, p.registerInterface("neg", -1, &entry));
    try testing.expectError(error.TooManyEntries, p.registerInterface("huge", 65537, &entry));
    try testing.expectError(error.MissingEntryArray, p.registerInterface("empty", 1, null));
    try testing.expectEqual(@as(usize, 0), p.interfaces.items.len);
}

test "unregistering by handle drops only the interface it names" {
    // A plugin unregisters through the handle RIB_register_interface handed it,
    // so a name-keyed drop is not reachable for it. The handle is specific to
    // one registration: the interface the plugin no longer serves must stop
    // answering entry lookups while the one it kept stays.
    const p = try openmiles.Provider.init(testing.allocator);
    defer p.deinit();

    var cut = [_]openmiles.RIB_INTERFACE_ENTRY{.{
        .entry_type = .RIB_ATTRIBUTE,
        .name = "cutoff",
        .token = 1,
        .subtype = 0,
    }};
    var keep = [_]openmiles.RIB_INTERFACE_ENTRY{.{
        .entry_type = .RIB_ATTRIBUTE,
        .name = "master",
        .token = 2,
        .subtype = 0,
    }};
    const cut_iface = try p.registerInterface("filter", 1, &cut);
    const keep_iface = try p.registerInterface("other", 1, &keep);
    // Handles are not reused, so unregistering one can never name the other.
    try testing.expect(cut_iface.handle != 0);
    try testing.expect(cut_iface.handle != keep_iface.handle);
    try testing.expectEqual(@as(?usize, 2), keep_iface.tokenFor("master"));

    p.unregisterInterfaceHandle(cut_iface.handle);
    try testing.expectEqual(@as(usize, 1), p.interfaces.items.len);
    try testing.expectEqualStrings("other", p.interfaces.items[0].name);
    try testing.expectEqual(@as(?usize, null), p.interfaces.items[0].tokenFor("cutoff"));
    try testing.expectEqual(@as(?usize, 2), p.interfaces.items[0].tokenFor("master"));

    // A handle already dropped, and one no registration ever issued, change
    // nothing: a plugin that unregisters twice (or unregisters a handle from a
    // provider it is not loading into) must not corrupt the list.
    p.unregisterInterfaceHandle(cut_iface.handle);
    p.unregisterInterfaceHandle(0);
    try testing.expectEqual(@as(usize, 1), p.interfaces.items.len);
    p.unregisterInterfaceHandle(keep_iface.handle);
    try testing.expectEqual(@as(usize, 0), p.interfaces.items.len);
}

test "an interface handle counter that has run out refuses to reuse a handle" {
    const allocator = testing.allocator;
    const p = try openmiles.Provider.init(allocator);
    defer p.deinit();

    var entry = openmiles.RIB_INTERFACE_ENTRY{
        .entry_type = .RIB_ATTRIBUTE,
        .name = "gain",
        .token = 7,
        .subtype = 0,
    };
    // The counter is pointer-sized: the handle reaches a plugin as a
    // pointer-sized integer, so on the 32-bit build that ships it cannot run
    // past what that integer holds.
    p.next_handle = std.math.maxInt(usize);
    try testing.expectError(
        error.InterfaceHandlesExhausted,
        p.registerInterface("exhausted", 1, &entry),
    );
    try testing.expectEqual(@as(usize, 0), p.interfaces.items.len);
}

test "loading the same plugin path twice is recognised as one provider" {
    // A rescan of a plugin directory must not load a second copy of a module
    // that is already up; the resolved path is the identity, so the same file
    // reached by a second path is skipped too.
    //
    // build.zig makes the test step depend on installing mock.asi, so under
    // `zig build test` the fixture is always present; a missing one is broken
    // wiring, not an absent optional input, and must not report a green run
    // with the whole dlopen path untested.
    const img_path = "zig-out/bin/plugins/mock.asi";
    std.Io.Dir.cwd().access(openmiles.io, img_path, .{}) catch return error.MissingMockPlugin;

    const p = try openmiles.Provider.load(testing.allocator, img_path);
    defer p.deinit();

    const loaded = [_]*openmiles.Provider{p};
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = openmiles.fs_compat.maybeResolveCaseInsensitivePath(img_path, &path_buf) orelse img_path;
    try testing.expect(openmiles.isPluginAlreadyLoaded(&loaded, resolved));
    try testing.expect(!openmiles.isPluginAlreadyLoaded(&loaded, "zig-out/bin/plugins/other.asi"));
    // A provider that was never loaded from a file matches nothing.
    const bare = try openmiles.Provider.init(testing.allocator);
    defer bare.deinit();
    try testing.expect(!openmiles.isPluginAlreadyLoaded(&.{bare}, resolved));
}

test "opening the same in-memory plugin image twice keeps one module" {
    // AIL_open_ASI_provider is the one load path that had no identity to dedup
    // on: a second open of the same bytes wrote a second temp image and loaded
    // a second copy of the module, and both stayed up until the process ended.
    // The key is the image content, so the same bytes reached through another
    // buffer are the same module, and a different image is a different one.
    const image = "MZ\x90\x00 the same plugin, opened twice";
    const key = openmiles.Provider.imageKeyOf(image);
    const copy = try testing.allocator.dupe(u8, image);
    defer testing.allocator.free(copy);
    try testing.expectEqual(key, openmiles.Provider.imageKeyOf(copy));
    const other_key = openmiles.Provider.imageKeyOf("MZ\x90\x00 a different plugin");
    try testing.expect(!std.meta.eql(key, other_key));

    const first = try openmiles.Provider.init(testing.allocator);
    try testing.expectEqual(first, first.publishImage(key));
    try testing.expectEqual(@as(usize, 1), openmiles.Provider.openImageCount());

    // The second open is answered from the registry: one module, and one more
    // close owed for the open that took the reference.
    const second = try openmiles.Provider.init(testing.allocator);
    try testing.expectEqual(first, second.publishImage(key));
    try testing.expectEqual(@as(usize, 1), openmiles.Provider.openImageCount());
    // The copy the second open built is not published, and dropping it leaves
    // the live one and its registry entry alone.
    second.deinit();
    try testing.expectEqual(@as(usize, 1), openmiles.Provider.openImageCount());

    // Different bytes are a different module, tracked alongside.
    const other = try openmiles.Provider.init(testing.allocator);
    try testing.expectEqual(other, other.publishImage(other_key));
    try testing.expectEqual(@as(usize, 2), openmiles.Provider.openImageCount());

    // Two opens, two closes: the first leaves the module loaded, the second
    // takes it down and empties the registry, so a repeated open cannot leave
    // the count (or the modules) growing.
    try testing.expect(!first.releaseImage());
    try testing.expectEqual(@as(usize, 2), openmiles.Provider.openImageCount());
    try testing.expect(first.releaseImage());
    first.deinit();
    try testing.expectEqual(@as(usize, 1), openmiles.Provider.openImageCount());
    try testing.expect(other.releaseImage());
    other.deinit();
    try testing.expectEqual(@as(usize, 0), openmiles.Provider.openImageCount());
}

test "AIL_open_digital_driver twice returns the driver already open" {
    // The second open must be the first driver: a second miniaudio engine would
    // keep playing past the close the caller makes on the handle it holds.
    defer {
        if (openmiles.lastDigitalDriver()) |d| openmiles.closeDigitalDriver(d);
    }
    openmiles.setLastDigitalDriver(null);
    const first = openmiles.openDigitalDriver(44100, 16, 2) orelse return error.NoDriver;
    const second = openmiles.openDigitalDriver(22050, 8, 1) orelse return error.NoDriver;
    try testing.expectEqual(first, second);
    try testing.expectEqual(first, openmiles.lastDigitalDriver().?);
}

test "AIL_open_midi_driver twice returns the driver already open" {
    defer {
        if (openmiles.lastMidiDriver()) |m| openmiles.closeMidiDriver(m);
    }
    openmiles.setLastMidiDriver(null);
    const first = openmiles.openMidiDriver() orelse return error.NoDriver;
    const second = openmiles.openMidiDriver() orelse return error.NoDriver;
    try testing.expectEqual(first, second);
    try testing.expectEqual(first, openmiles.lastMidiDriver().?);
}

test "teardown closes every MIDI device, not only the current one" {
    // AIL_DLS_open and AIL_create_wave_synthesizer each build a device and take
    // the "current driver" slot, so a game holding two left the first one
    // unreachable from shutdown: its allocation, its soundfont and its sequences
    // stayed for the life of the process.
    defer openmiles.closeAllDrivers();
    openmiles.setLastMidiDriver(null);
    const first = openmiles.openMidiDriver() orelse return error.NoDriver;
    const second = openmiles.MidiDriver.init(openmiles.global_allocator) catch return error.NoDriver;
    try testing.expectEqual(second, openmiles.lastMidiDriver().?);
    try testing.expect(first != second);
    try testing.expectEqual(2, openmiles.liveMidiDriverCount());

    openmiles.closeAllDrivers();
    try testing.expectEqual(0, openmiles.liveMidiDriverCount());
    try testing.expect(openmiles.lastMidiDriver() == null);
}

// A driver close frees the driver, its engine and its soundfont. A game that
// reaches its close from two paths (a DLS close and a MIDI close on the same
// device, a shutdown path that also runs the game's own teardown) hands the
// same handle to the close twice, and the second one uninitializes an engine
// over freed memory and destroys the allocation again. The test allocator is
// the leak checker, so that second free fails the test rather than passing
// quietly.
test "closing a driver twice closes it once" {
    const allocator = testing.allocator;

    const dig = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    openmiles.closeDigitalDriver(dig);
    try testing.expect(openmiles.lastDigitalDriver() == null);
    // The repeat finds no live handle to claim and changes nothing.
    openmiles.closeDigitalDriver(dig);

    const midi = try openmiles.MidiDriver.init(allocator);
    openmiles.closeMidiDriver(midi);
    try testing.expectEqual(@as(usize, 0), openmiles.liveMidiDriverCount());
    try testing.expect(openmiles.lastMidiDriver() == null);
    openmiles.closeMidiDriver(midi);
    try testing.expectEqual(@as(usize, 0), openmiles.liveMidiDriverCount());
    try testing.expect(openmiles.lastMidiDriver() == null);
}

test "setRedistDirectory with the same path does not rescan it" {
    // AIL_set_redist_directory is called more than once per session by several
    // games; an identical path must not push a second copy of every .asi into
    // the open driver.
    defer {
        if (openmiles.lastDigitalDriver()) |d| openmiles.closeDigitalDriver(d);
        openmiles.setRedistDirectory("");
    }
    openmiles.setLastDigitalDriver(null);
    const driver = openmiles.openDigitalDriver(44100, 16, 2) orelse return error.NoDriver;

    openmiles.setRedistDirectory("zig-out/bin/plugins");
    const after_first = driver.providers.items.len;
    openmiles.setRedistDirectory("zig-out/bin/plugins");
    try testing.expectEqual(after_first, driver.providers.items.len);
    try testing.expectEqualStrings("zig-out/bin/plugins", openmiles.getRedistDirectory());
}

test "a redist directory startup already scanned loads no second copy" {
    // Startup scans the application directory into the global provider list,
    // and a game's AIL_set_redist_directory then names that same directory. The
    // driver must not dlopen a second copy of a module the process already
    // holds: both copies stay loaded until AIL_shutdown.
    std.Io.Dir.cwd().access(openmiles.io, "zig-out/bin/plugins/mock.asi", .{}) catch return error.MissingMockPlugin;
    defer {
        if (openmiles.lastDigitalDriver()) |d| openmiles.closeDigitalDriver(d);
        openmiles.setRedistDirectory("");
    }
    openmiles.setLastDigitalDriver(null);
    const driver = openmiles.openDigitalDriver(44100, 16, 2) orelse return error.NoDriver;

    _ = openmiles.loadApplicationProviders("zig-out/bin/plugins");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = openmiles.fs_compat.maybeResolveCaseInsensitivePath("zig-out/bin/plugins/mock.asi", &path_buf) orelse "zig-out/bin/plugins/mock.asi";
    try testing.expect(openmiles.isPluginLoadedAnywhere(&.{}, resolved));
    const after_scan = driver.providers.items.len;
    openmiles.setRedistDirectory("zig-out/bin/plugins");
    try testing.expectEqual(after_scan, driver.providers.items.len);
}

test "adopting a module already in the plugin list unloads the second copy" {
    // A scan checks a module's identity, then loads it (running the plugin's
    // RIB_Main, which takes as long as it likes), and only then tracks it. A
    // scan of the same directory running alongside it can register the module
    // in that window. adoptPlugin is where the identity is re-checked under the
    // lock both lists share, so the second copy is unloaded instead of tracked
    // and held for the life of the process.
    //
    // The fixture is installed by `zig build` and the test step depends on that
    // install, so a missing file is broken wiring; returning quietly here would
    // report a green run with adoptPlugin untested.
    const img_path = "zig-out/bin/plugins/mock.asi";
    std.Io.Dir.cwd().access(openmiles.io, img_path, .{}) catch return error.MissingMockPlugin;
    // A copy under a path of its own, so the identity under test is one no
    // other test in this process has registered. The copy needs a directory
    // component: the loader resolves a bare file name as a system library.
    const dir_name = "om_adopt_dedup_test";
    const cwd = std.Io.Dir.cwd();
    cwd.createDir(openmiles.io, dir_name, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer cwd.deleteTree(openmiles.io, dir_name) catch {};
    const copy_path = dir_name ++ "/mock.asi";
    try cwd.copyFile(img_path, cwd, copy_path, openmiles.io, .{});

    var owned: std.ArrayList(*openmiles.Provider) = .empty;
    defer {
        for (owned.items) |p| p.deinit();
        owned.deinit(testing.allocator);
    }
    const first = try openmiles.Provider.load(testing.allocator, copy_path);
    try testing.expect(openmiles.adoptPlugin(first, &owned));

    // Same file, loaded again: this is the copy the racing scan produced.
    const second = try openmiles.Provider.load(testing.allocator, copy_path);
    try testing.expect(!openmiles.adoptPlugin(second, &owned));
    try testing.expectEqual(@as(usize, 1), owned.items.len);
}

test "RIB plugin loading registers the mock provider's interface end to end" {
    // The only automated coverage of the dynamic-plugin path (dlopen/LoadLibrary
    // + RIB_Main + interface registration). The fixture is installed by
    // `zig build` into zig-out/bin/plugins/mock.asi, and build.zig makes the
    // test step depend on that install, so a missing file is broken wiring. A
    // quiet return here would report a green run with the dlopen path untested.
    const img_path = "zig-out/bin/plugins/mock.asi";
    std.Io.Dir.cwd().access(openmiles.io, img_path, .{}) catch return error.MissingMockPlugin;

    const p = try openmiles.Provider.load(testing.allocator, img_path);
    defer p.deinit();

    try testing.expectEqualStrings("mock.asi", p.name);
    var found_engine = false;
    for (p.interfaces.items) |iface| {
        if (!std.mem.eql(u8, iface.name, "ASI digital audio engine")) continue;
        found_engine = true;
        // mock_asi.c registers exactly one entry; its token must survive the
        // load intact (a broken segment copy or missing relocation pass used
        // to crash or corrupt this data before registration completed).
        const token = iface.tokenFor("Input data type") orelse return error.MissingEntry;
        try testing.expectEqual(@as(usize, 0x1234), token);
    }
    try testing.expect(found_engine);
}

test "DigitalDriver setMasterVolume and getMasterVolume" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    driver.setMasterVolume(0.5);
    const vol = driver.getMasterVolume();
    try testing.expect(vol > 0.49 and vol < 0.51);
}

test "DigitalDriver get3DActiveSampleCount" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    try testing.expectEqual(@as(u32, 0), driver.get3DActiveSampleCount(std.math.maxInt(u32)));

    // 3D voices live in their own list: a playing 3D sample must raise the 3D
    // count and leave the 2D count alone (AIL_digital_CPU_percent adds them).
    // Without the playing case this would pass on a counter that never counts.
    const wav = try zeroWav(allocator);
    defer allocator.free(wav);
    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();
    try s.loadFromMemory(wav, true);
    try testing.expectEqual(@as(u32, 0), driver.get3DActiveSampleCount(std.math.maxInt(u32)));
    s.start();
    try testing.expectEqual(openmiles.SampleStatus.playing, s.status());
    try testing.expectEqual(@as(u32, 1), driver.get3DActiveSampleCount(std.math.maxInt(u32)));
    try testing.expectEqual(@as(u32, 0), driver.getActiveSampleCount(std.math.maxInt(u32)));
    s.stop();
    try testing.expectEqual(@as(u32, 0), driver.get3DActiveSampleCount(std.math.maxInt(u32)));
}

test "Sample setVolume and setPan land on the engine fields" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    sample.setVolume(64);
    sample.setPan(32);
    try testing.expect(sample.volume > 0.30 and sample.volume < 0.33); // MSS curve ^(10/6)
    try testing.expectEqual(@as(f32, -0.5), sample.pan);
}

// The registry is global and shared: AIL_active_sequence_count reports how
// many tracked sequences are playing, so registering, playing, stopping and
// releasing must each move it. Asserting only the empty-registry zero would
// pass if the counter always answered 0 or if register/unregister did nothing.
test "getActiveSequenceCount follows register, play, stop and release" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const before = openmiles.getActiveSequenceCount();

    const s1 = try openmiles.Sequence.init(driver);
    // A registered but unplayed sequence is not active.
    try testing.expectEqual(before, openmiles.getActiveSequenceCount());
    s1.is_playing.store(true, .release);
    try testing.expectEqual(before + 1, openmiles.getActiveSequenceCount());

    const s2 = try openmiles.Sequence.init(driver);
    s2.is_playing.store(true, .release);
    try testing.expectEqual(before + 2, openmiles.getActiveSequenceCount());
    // Stopping one leaves the other counted.
    s1.is_playing.store(false, .release);
    try testing.expectEqual(before + 1, openmiles.getActiveSequenceCount());

    // deinit unregisters, so a released sequence stops being counted even
    // while its is_playing flag is still set.
    s2.deinit();
    try testing.expectEqual(before, openmiles.getActiveSequenceCount());
    s1.deinit();
    try testing.expectEqual(before, openmiles.getActiveSequenceCount());
}

// A sequence names the driver that made it, and the table it is tracked in is
// walked by pointer. A driver close marks its sequences orphaned rather than
// dropping them: the entry is what a release is matched against, and dropping
// it would leave a handle the game still holding unclaimable. An orphan is
// skipped by every walk, so the freed driver address it keeps is never compared
// against a live one.
test "closing a MIDI driver orphans its sequences until they are released" {
    const allocator = testing.allocator;
    const before = openmiles.trackedSequenceCount();
    const live_before = openmiles.liveSequenceCount();

    const driver = try openmiles.MidiDriver.init(allocator);
    const seq = try openmiles.Sequence.init(driver);
    try testing.expectEqual(before + 1, openmiles.trackedSequenceCount());
    try testing.expectEqual(live_before + 1, openmiles.liveSequenceCount());

    openmiles.closeMidiDriver(driver);
    // Tracked, so the game's release is still claimable, but no longer live.
    try testing.expectEqual(before + 1, openmiles.trackedSequenceCount());
    try testing.expectEqual(live_before, openmiles.liveSequenceCount());

    // The handle the game holds is still its own: releasing it after the close
    // frees the sequence and takes it out of the table.
    seq.deinit();
    try testing.expectEqual(before, openmiles.trackedSequenceCount());
}

// The free behind a release is not idempotent: a second one uninitializes a
// sound and a data source over freed memory and hands the allocator an address
// it has already released. A game that releases a handle from two paths (its
// own teardown and a sequence-closing driver) reaches it twice, and the state
// after that has to be the state one release left.
test "releasing a sequence handle twice releases it once" {
    const allocator = testing.allocator;
    const before = openmiles.trackedSequenceCount();
    const driver = try openmiles.MidiDriver.init(allocator);
    const seq = try openmiles.Sequence.init(driver);
    try testing.expectEqual(before + 1, openmiles.trackedSequenceCount());

    seq.deinit();
    try testing.expectEqual(before, openmiles.trackedSequenceCount());
    // The allocator is the leak checker, so a second free of the same handle
    // fails this test rather than passing quietly.
    seq.deinit();
    try testing.expectEqual(before, openmiles.trackedSequenceCount());

    driver.deinit();
}

test "Sample end sets done status" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    try testing.expectEqual(openmiles.SampleStatus.done, sample.status()); // SMP_DONE default

    sample.end();
    try testing.expectEqual(openmiles.SampleStatus.done, sample.status());
}

test "AIL_stop_sample is a no-op unless the sample is SMP_PLAYING (SDK)" {
    // SDK wavefile.cpp AIL_API_stop_sample early-outs unless status==SMP_PLAYING,
    // so stopping a never-played or finished sample must NOT report SMP_STOPPED.
    const s = try loadedSample(testing.allocator, 64, 1, 8000);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();

    // Never started -> SMP_DONE; stop must leave it DONE (not STOPPED).
    try testing.expectEqual(@as(u32, 2), dg.AIL_sample_status(s)); // SMP_DONE
    dg.AIL_stop_sample(s);
    try testing.expectEqual(@as(u32, 2), dg.AIL_sample_status(s)); // still SMP_DONE

    // Finished sample (end -> DONE): stop is likewise a no-op.
    s.end();
    dg.AIL_stop_sample(s);
    try testing.expectEqual(@as(u32, 2), dg.AIL_sample_status(s)); // still SMP_DONE
}

test "Sample start on uninitialized resets done flag" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    sample.end();
    try testing.expectEqual(openmiles.SampleStatus.done, sample.status());

    // start() on an uninitialized sample can't actually play; status stays
    // SMP_DONE (not SMP_STOPPED -- nothing was explicitly stopped).
    sample.start();
    try testing.expectEqual(openmiles.SampleStatus.done, sample.status());
}

test "AIL_set/stream_reverb + AIL_quick_set_reverb param roles (level, reflect, decay)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    const sq = @import("api/stream.zig");
    const qk2 = @import("api/quick.zig");
    // Stream set/get round-trips with the SDK slot order.
    sq.AIL_set_stream_reverb(s, 0.5, 0.1, 0.8); // level, reflect, decay
    var level: f32 = 0;
    var reflect: f32 = 0;
    var decay: f32 = 0;
    sq.AIL_stream_reverb(s, &level, &reflect, &decay);
    try testing.expect(@abs(level - 0.5) < 0.001 and @abs(reflect - 0.1) < 0.001 and @abs(decay - 0.8) < 0.001);
    // quick_set_reverb uses the same order; verify via the sample-reverb getter.
    qk2.AIL_quick_set_reverb(s, 0.25, 0.2, 0.6);
    dg.AIL_sample_reverb(s, &level, &reflect, &decay);
    try testing.expect(@abs(level - 0.25) < 0.001 and @abs(reflect - 0.2) < 0.001 and @abs(decay - 0.6) < 0.001);
}

test "AIL_set/sample_reverb param roles: (level, reflect_time, decay_time) (SDK)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    // SDK order: reverb_level, reverb_reflect_time, reverb_decay_time.
    dg.AIL_set_sample_reverb(s, 0.5, 0.1, 0.8);
    var level: f32 = 0;
    var reflect: f32 = 0;
    var decay: f32 = 0;
    dg.AIL_sample_reverb(s, &level, &reflect, &decay);
    try testing.expect(@abs(level - 0.5) < 0.001); // wet level round-trips in slot 1
    try testing.expect(@abs(reflect - 0.1) < 0.001); // reflect time in slot 2
    try testing.expect(@abs(decay - 0.8) < 0.001); // decay time in slot 3 (was misread as room_type)
}

test "Sample setReverb and getReverb roundtrip" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    sample.setReverb(2.5, 0.7, 0.3);
    const rev = sample.getReverb();
    try testing.expectEqual(@as(f32, 2.5), rev.room_type);
    try testing.expectEqual(@as(f32, 0.7), rev.level);
    try testing.expectEqual(@as(f32, 0.3), rev.reflect_time);
}

test "Sample setReverb with zero level clears reverb" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    sample.setReverb(2.5, 0.7, 0.3);
    sample.setReverb(0.0, 0.0, 0.0);
    const rev = sample.getReverb();
    try testing.expectEqual(@as(f32, 0.0), rev.room_type);
    try testing.expectEqual(@as(f32, 0.0), rev.level);
    try testing.expectEqual(@as(f32, 0.0), rev.reflect_time);
}

test "reloading a reverbed sample frees its delay node (no leaks)" {
    // A sample given reverb and then reloaded used to keep the delay node
    // allocated and wired to the engine: every load path tears the playback
    // state down and remounts, so a game that reloads a streaming sample with
    // reverb set leaked one node per reload for as long as it kept streaming.
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    var pcm: [512]u8 = undefined;
    const wav = try openmiles.buildWavFromPcm(allocator, &pcm, 1, 44100, 16);
    defer allocator.free(wav);

    try sample.loadFromOwnedMemory(try allocator.dupe(u8, wav));
    sample.setReverb(2.5, 0.7, 0.3);
    try testing.expect(sample.reverb_node != null);
    // Reload several times; each mount must release the previous node, so the
    // leak-checked allocator sees a steady state rather than one node per pass.
    for (0..4) |_| {
        const copy = try allocator.dupe(u8, wav);
        errdefer allocator.free(copy);
        try sample.loadFromOwnedMemory(copy);
        try testing.expect(sample.reverb_node == null);
        sample.setReverb(2.5, 0.7, 0.3);
        try testing.expect(sample.reverb_node != null);
    }
}

test "Sample3D setOrientation stores all components" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    s.setOrientation(1.0, 0.0, 0.0, 0.0, 1.0, 0.0);
    try testing.expectEqual(@as(f32, 1.0), s.orient_fx);
    try testing.expectEqual(@as(f32, 0.0), s.orient_fy);
    try testing.expectEqual(@as(f32, 0.0), s.orient_fz);
    try testing.expectEqual(@as(f32, 0.0), s.orient_ux);
    try testing.expectEqual(@as(f32, 1.0), s.orient_uy);
    try testing.expectEqual(@as(f32, 0.0), s.orient_uz);

    // SDK normalizes face & up: (0,0,5)->(0,0,1), (0,3,4)->(0,0.6,0.8).
    s.setOrientation(0.0, 0.0, 5.0, 0.0, 3.0, 4.0);
    try testing.expect(@abs(s.orient_fz - 1.0) < 0.001 and @abs(s.orient_fx) < 0.001);
    try testing.expect(@abs(s.orient_uy - 0.6) < 0.001 and @abs(s.orient_uz - 0.8) < 0.001);
}

test "AIL_set_sample_file loads a whole image and reports failure on garbage" {
    // The C entry point games call to hand a sample its audio: 1 on success, 0
    // on a load that failed (with AIL_last_error naming it). Nothing asserted it
    // before, so a regression to "always return 1" or "always 0" was invisible.
    const api_digital = @import("api/digital.zig");
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample.init(driver);
    defer s.deinit();
    try testing.expect(!s.is_initialized);

    const wav = try zeroWav(testing.allocator);
    defer testing.allocator.free(wav);
    // A negative block means "the whole image"; the size is read from the header.
    try testing.expectEqual(@as(i32, 1), api_digital.AIL_set_sample_file(s, wav.ptr, -1));
    try testing.expect(s.is_initialized);
    try testing.expectEqual(openmiles.SampleStatus.done, s.status()); // loaded, never played

    // An explicit size takes the same path and must agree with the header read.
    const s2 = try openmiles.Sample.init(driver);
    defer s2.deinit();
    try testing.expectEqual(@as(i32, 1), api_digital.AIL_set_sample_file(s2, wav.ptr, @intCast(wav.len)));
    try testing.expect(s2.is_initialized);

    // Garbage is the negative case: the load fails, the return says so, and the
    // sample is not left half-initialized claiming a working sound.
    const s3 = try openmiles.Sample.init(driver);
    defer s3.deinit();
    var junk = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF } ** 4;
    try testing.expectEqual(@as(i32, 0), api_digital.AIL_set_sample_file(s3, @ptrCast(&junk), -1));
    try testing.expect(!s3.is_initialized);
    try testing.expect(!std.mem.eql(u8, "No error", std.mem.span(api_digital.AIL_last_error())));

    // A null handle is the SDK null guard, not a load.
    try testing.expectEqual(@as(i32, 0), api_digital.AIL_set_sample_file(null, wav.ptr, -1));
}

test "Sample loadFromMemory initializes sample" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    try testing.expect(!sample.is_initialized);

    const wav = try zeroWav(allocator);
    defer allocator.free(wav);

    try sample.loadFromMemory(wav, true);
    try testing.expect(sample.is_initialized);
    try testing.expectEqual(openmiles.SampleStatus.done, sample.status()); // loaded, never played -> SMP_DONE
}

test "Sample loadFromBoundedPointer mounts via bounded callbacks" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    const wav = try zeroWav(allocator);
    defer allocator.free(wav);

    // The size-less pointer path mounts through bounded read/seek callbacks
    // instead of fabricating a slice the caller's buffer may not back.
    try sample.loadFromBoundedPointer(wav.ptr, wav.len);
    try testing.expect(sample.is_initialized);
    try testing.expect(sample.bounded_mem_ctx != null);
    // No WAV header is parsed on this path, so the source-format hint must
    // not survive from any previous load.
    try testing.expectEqual(@as(u32, 0), sample.src_bpf);

    // A streaming sentinel (OGG/MP3/FLAC) routes here too. Reads are bounded by
    // the 16 MB sentinel window, so the backing allocation must cover it for
    // failure to be deterministic; the all-zero payload makes every decoder
    // reject the stream once it hits the window's end.
    const s2 = try openmiles.Sample.init(driver);
    defer s2.deinit();
    const ogg = try allocator.alloc(u8, openmiles.streaming_sentinel_size + 1);
    defer allocator.free(ogg);
    @memcpy(ogg[0..4], "OggS");
    @memset(ogg[4..], 0);
    try testing.expectError(error.DecoderInitFailed, s2.loadFromUnownedMemoryUnknownSize(ogg.ptr));
    try testing.expect(!s2.is_initialized);
}

var sob_cb_fired: bool = false;
fn testSobCallback(s: ?*anyopaque) callconv(.winapi) void {
    _ = s;
    sob_cb_fired = true;
}

var eos_cb_count: u32 = 0;
fn testEosCallback(s: ?*anyopaque) callconv(.winapi) void {
    _ = s;
    eos_cb_count += 1;
}

test "AIL_stream_loop_count: -1 on null, remaining count otherwise (SDK preload path)" {
    // SDK mssstrm.cpp returns -1 for a null stream and, for a preloaded stream,
    // delegates to AIL_sample_loop_count (the remaining loop count).
    try testing.expectEqual(@as(i32, -1), api_stream.AIL_stream_loop_count(null));

    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();
    const s = try openmiles.Sample.init(driver);
    defer s.deinit();
    const wav = try zeroWav(testing.allocator);
    defer testing.allocator.free(wav);
    try s.loadFromMemory(wav, false);

    api_stream.AIL_set_stream_loop_count(s, 3);
    try testing.expectEqual(@as(i32, 3), api_stream.AIL_stream_loop_count(s));
    // Consistent with the sample-handle view of the same loop count.
    try testing.expectEqual(@as(i32, 3), dg.AIL_sample_loop_count(s));

    // AIL_stream_position returns S32 -1 on a null stream (mssstrm.cpp), and the
    // byte position otherwise.
    try testing.expectEqual(@as(i32, -1), api_stream.AIL_stream_position(null));
    try testing.expectEqual(@as(i32, 0), api_stream.AIL_stream_position(s)); // fresh: pos 0
}

test "AIL_stream_status: paused/never-started -> SMP_STOPPED, playing -> PLAYING (SDK)" {
    // SDK mssstrm.cpp: a stream's status differs from a plain sample's -- a
    // paused or not-yet-started stream is SMP_STOPPED (a paused 2D sample would
    // be SMP_PLAYING; a never-started one SMP_DONE).
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();
    const s = try openmiles.Sample.init(driver);
    defer s.deinit();
    const pcm = [_]u8{0} ** 8820;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 44100, 8);
    defer testing.allocator.free(wav);
    try s.loadFromMemory(wav, false);

    // Null stream -> SMP error -1 (S32).
    try testing.expectEqual(@as(i32, -1), api_stream.AIL_stream_status(null));
    // Opened but never started -> SMP_STOPPED (8), not SMP_DONE.
    try testing.expectEqual(@as(i32, 8), api_stream.AIL_stream_status(s));
    // Started -> SMP_PLAYING (4).
    api_stream.AIL_start_stream(s);
    try testing.expectEqual(@as(i32, 4), api_stream.AIL_stream_status(s));
    // Paused -> SMP_STOPPED (8), unlike a paused 2D sample (which is SMP_PLAYING).
    api_stream.AIL_pause_stream(s, 1);
    try testing.expectEqual(@as(i32, 8), api_stream.AIL_stream_status(s));
    try testing.expectEqual(@as(u32, 4), dg.AIL_sample_status(s)); // 2D view still PLAYING
    // Unpaused -> SMP_PLAYING again.
    api_stream.AIL_pause_stream(s, 0);
    try testing.expectEqual(@as(i32, 4), api_stream.AIL_stream_status(s));
}

test "AIL_end_3D_sample fires the 3D EOS callback once (live->DONE only)" {
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();
    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();
    const wav = try zeroWav(testing.allocator);
    defer testing.allocator.free(wav);
    try s.loadFromMemory(wav, true);
    const sp: *anyopaque = @ptrCast(s);

    eos_cb_count = 0;
    _ = api_3d.AIL_register_3D_EOS_callback(sp, @ptrCast(@constCast(&testEosCallback)));

    // Fresh (already SMP_DONE) -> end fires nothing.
    api_3d.AIL_end_3D_sample(sp);
    try testing.expectEqual(@as(u32, 0), eos_cb_count);
    // Start -> playing, end -> one firing.
    api_3d.AIL_start_3D_sample(sp);
    api_3d.AIL_end_3D_sample(sp);
    try testing.expectEqual(@as(u32, 1), eos_cb_count);
    // Already done -> no re-fire.
    api_3d.AIL_end_3D_sample(sp);
    try testing.expectEqual(@as(u32, 1), eos_cb_count);
}

test "AIL_end_sample fires the EOS callback once (only on the live->DONE transition)" {
    // SDK wavefile.cpp AIL_API_end_sample sets SMP_DONE and fires EOB+EOS only if
    // the sample was not already done -- so ending a never-played (already SMP_DONE)
    // sample fires nothing, and a second end() does not re-fire.
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();
    const s = try openmiles.Sample.init(driver);
    defer s.deinit();
    const wav = try zeroWav(testing.allocator);
    defer testing.allocator.free(wav);
    try s.loadFromMemory(wav, true);

    eos_cb_count = 0;
    _ = dg.AIL_register_EOS_callback(s, @ptrCast(@constCast(&testEosCallback)));

    // Fresh sample is already SMP_DONE -> end() fires nothing.
    dg.AIL_end_sample(s);
    try testing.expectEqual(@as(u32, 0), eos_cb_count);

    // Start (now SMP_PLAYING), then end -> one EOS firing.
    dg.AIL_start_sample(s);
    dg.AIL_end_sample(s);
    try testing.expectEqual(@as(u32, 1), eos_cb_count);

    // Already done again -> no re-fire.
    dg.AIL_end_sample(s);
    try testing.expectEqual(@as(u32, 1), eos_cb_count);
}

test "AIL_register_SOB_callback: the callback actually fires on AIL_start_sample" {
    // The registration round-trip is covered elsewhere; this checks the harder
    // property -- that a registered Start-Of-Buffer callback is genuinely invoked
    // (with the AILSAMPLECB void(HSAMPLE) signature) when the sample starts, not
    // merely stored. Start fires SOB synchronously, so this is deterministic.
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();
    const s = try openmiles.Sample.init(driver);
    defer s.deinit();
    const wav = try zeroWav(allocator);
    defer allocator.free(wav);
    try s.loadFromMemory(wav, true);

    sob_cb_fired = false;
    const prev = dg.AIL_register_SOB_callback(s, @ptrCast(@constCast(&testSobCallback)));
    try testing.expectEqual(@as(?*anyopaque, null), prev); // no prior callback
    dg.AIL_start_sample(s);
    try testing.expect(sob_cb_fired);
}

test "Sample loadFromMemory then start and stop lifecycle" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    const wav = try zeroWav(allocator);
    defer allocator.free(wav);

    try sample.loadFromMemory(wav, true);

    sample.start();
    try testing.expectEqual(openmiles.SampleStatus.playing, sample.status());

    sample.stop();
    try testing.expectEqual(openmiles.SampleStatus.stopped, sample.status());

    sample.start();
    sample.end();
    try testing.expectEqual(openmiles.SampleStatus.done, sample.status());
}

test "paused 2D sample reports SMP_PLAYING, paused 3D reports SMP_STOPPED" {
    // MSS quirk: a paused 2D sample keeps reporting SMP_PLAYING (4), but a
    // paused 3D sample reports SMP_STOPPED (8). Games poll these to decide
    // whether to restart a voice, so the divergence must be preserved exactly.
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();
    const wav = try zeroWav(allocator);
    defer allocator.free(wav);

    const s2 = try openmiles.Sample.init(driver);
    defer s2.deinit();
    try s2.loadFromMemory(wav, true);
    s2.start();
    try testing.expectEqual(openmiles.SampleStatus.playing, s2.status());
    s2.pause();
    try testing.expectEqual(openmiles.SampleStatus.playing, s2.status()); // still PLAYING
    s2.resumePlayback();
    try testing.expectEqual(openmiles.SampleStatus.playing, s2.status());

    const s3 = try openmiles.Sample3D.init(driver);
    defer s3.deinit();
    try s3.loadFromMemory(wav, true);
    s3.start();
    try testing.expectEqual(openmiles.SampleStatus.playing, s3.status());
    s3.pause();
    try testing.expectEqual(openmiles.SampleStatus.stopped, s3.status()); // STOPPED, not PLAYING
}

test "AIL_quick_status returns QSTAT_* values, not the SMP_* bitmask" {
    // The Quick API has its own status enum: QSTAT_DONE=1, QSTAT_LOADED=2,
    // QSTAT_PLAYING=3 — distinct from SMP_FREE=1/DONE=2/PLAYING=4/STOPPED=8.
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();
    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();
    const wav = try zeroWav(allocator);
    defer allocator.free(wav);
    try sample.loadFromMemory(wav, true);

    try testing.expectEqual(@as(i32, 2), api_quick.AIL_quick_status(sample)); // QSTAT_LOADED
    sample.start();
    try testing.expectEqual(@as(i32, 3), api_quick.AIL_quick_status(sample)); // QSTAT_PLAYING
    sample.end();
    try testing.expectEqual(@as(i32, 1), api_quick.AIL_quick_status(sample)); // QSTAT_DONE
}

test "AIL_quick_play returns S32 success (1) and 0 for a null handle" {
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();
    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();
    const pcm = [_]u8{0} ** 256;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 8);
    defer testing.allocator.free(wav);
    try sample.loadFromMemory(wav, true);
    try testing.expectEqual(@as(i32, 1), api_quick.AIL_quick_play(sample, 1)); // playing -> 1
    try testing.expectEqual(@as(i32, 0), api_quick.AIL_quick_play(null, 1)); // SDK null guard
}

test "AIL_quick_load_mem owns its image, so AIL_quick_copy duplicates the audio" {
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();
    openmiles.setLastDigitalDriver(driver);
    defer openmiles.setLastDigitalDriver(null);

    const pcm = [_]u8{0} ** 256;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 8);
    defer testing.allocator.free(wav);

    const loaded = api_quick.AIL_quick_load_mem(wav.ptr, @intCast(wav.len)) orelse return error.QuickLoadFailed;
    defer api_quick.AIL_quick_unload(loaded);

    const copy = api_quick.AIL_quick_copy(loaded) orelse return error.QuickCopyFailed;
    defer api_quick.AIL_quick_unload(copy);

    // The copy plays the same audio as the source. A borrow-the-caller's-buffer
    // load left the copy holding nothing, so it reported QSTAT_LOADED forever
    // and produced silence.
    try testing.expectEqual(loaded.getMsPosition().total, copy.getMsPosition().total);
    try testing.expectEqual(@as(i32, 2), api_quick.AIL_quick_status(copy)); // QSTAT_LOADED
    try testing.expectEqual(@as(i32, 1), api_quick.AIL_quick_play(copy, 1));
}

test "AIL_startup returns an incrementing use count (SDK refcount)" {
    const api_digital = @import("api/digital.zig");
    // Order-independent: each call bumps the use count by 1 and returns the new
    // value. (openmiles.startup() itself is idempotent, so this is safe to repeat.)
    const c1 = api_digital.AIL_startup();
    const c2 = api_digital.AIL_startup();
    try testing.expect(c1 >= 1);
    try testing.expectEqual(c1 + 1, c2);
}

test "concurrent startups leave exactly one startup provider" {
    // A game that brings the audio up from a worker thread while its main
    // thread does the same runs startup() twice at once. The claim on the
    // published provider is a load followed by a store, so the two threads
    // could both read null and both build a provider: the one that lost the
    // store was unreachable from then on, keeping its interfaces and name
    // allocated for the life of the process while shutdown freed only the
    // winner. Each thread reading the provider back after its own call is what
    // exposes that: on the racing build the two disagree, because one of them
    // is reading a provider the other has already replaced.
    const api_digital = @import("api/digital.zig");
    // The count is process-global and earlier tests left uses outstanding, so
    // drain it to get the engine down, then put a startup back at the end: the
    // state the suite expects to inherit.
    while (api_digital.startupUseCount() > 0) api_digital.AIL_shutdown();
    try testing.expectEqual(@as(?*openmiles.Provider, null), openmiles.startupProvider());

    const thread_count = 8;
    const CB = struct {
        var gate: std.atomic.Value(u32) = .init(0);
        var seen: [thread_count]?*openmiles.Provider = .{null} ** thread_count;

        fn worker(slot: usize) void {
            // All threads leave the gate together, so the calls overlap the
            // window the claim is made in rather than running one after another.
            _ = gate.fetchAdd(1, .release);
            while (gate.load(.acquire) < thread_count) std.atomic.spinLoopHint();
            openmiles.startup();
            seen[slot] = openmiles.startupProvider();
        }
    };

    var handles: [thread_count]std.Thread = undefined;
    for (&handles, 0..) |*h, i| h.* = try std.Thread.spawn(.{}, CB.worker, .{i});
    for (handles) |h| h.join();

    const published = openmiles.startupProvider();
    try testing.expect(published != null);
    for (CB.seen) |p| try testing.expectEqual(published, p);

    // The teardown reaches every provider a startup built, so nothing of the
    // racing run is left holding memory.
    api_digital.AIL_shutdown();
    try testing.expectEqual(@as(?*openmiles.Provider, null), openmiles.startupProvider());
    try testing.expectEqual(@as(i32, 1), api_digital.AIL_startup());
    try testing.expect(openmiles.startupProvider() != null);
}

test "AIL_shutdown holds the engine up until the last use count is released" {
    const api_digital = @import("api/digital.zig");
    // Two startups and two shutdowns, in the order a game that nests the Quick
    // API inside the standard one calls them, must leave what one startup and
    // one shutdown leaves: the engine is up after the first shutdown, and the
    // teardown lands on the last. The count is process-global and other tests
    // above have left it above zero, so drain it here and put a startup back,
    // which is the state the suite expects to inherit.
    const drained = api_digital.AIL_startup();
    try testing.expect(drained >= 2);
    api_digital.AIL_shutdown();
    // Still one use outstanding, so nothing may have been released.
    try testing.expect(openmiles.startupProvider() != null);

    // Release every remaining use. shutdown() beyond the count is a no-op
    // rather than a second teardown, so a caller that double-shuts down is the
    // same as one that does not.
    while (api_digital.startupUseCount() > 0) {
        api_digital.AIL_shutdown();
    }
    try testing.expectEqual(@as(?*openmiles.Provider, null), openmiles.startupProvider());
    api_digital.AIL_shutdown();
    try testing.expectEqual(@as(?*openmiles.Provider, null), openmiles.startupProvider());

    // A startup after the teardown brings the engine back, and the next
    // shutdown takes it down again: the cycle is repeatable.
    try testing.expectEqual(@as(i32, 1), api_digital.AIL_startup());
    try testing.expect(openmiles.startupProvider() != null);
    api_digital.AIL_shutdown();
    try testing.expectEqual(@as(?*openmiles.Provider, null), openmiles.startupProvider());

    // Leave the engine up for the tests that follow.
    _ = api_digital.AIL_startup();
    try testing.expect(openmiles.startupProvider() != null);
}

test "AIL_set/listener_relative_receiver_array round-trips the spec list (SDK)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    // Default: empty.
    var nr: i32 = -1;
    _ = api_v7.AIL_listener_relative_receiver_array(drv, &nr);
    try testing.expectEqual(@as(i32, 0), nr);
    // Store two receiver specs.
    var specs = [_]api_v7.MSS_RECEIVER_LIST{ .{}, .{} };
    specs[0].direction = .{ .x = 1, .y = 0, .z = 0 };
    specs[0].n_speakers_affected = 3;
    specs[1].direction = .{ .x = 0, .y = 0, .z = -1 };
    specs[1].speaker_level[0] = 0.75;
    api_v7.AIL_set_listener_relative_receiver_array(drv, &specs, 2);
    const got = api_v7.AIL_listener_relative_receiver_array(drv, &nr) orelse return error.NullArray;
    try testing.expectEqual(@as(i32, 2), nr);
    const arr: [*]api_v7.MSS_RECEIVER_LIST = @ptrCast(@alignCast(got));
    try testing.expectEqual(@as(f32, 1.0), arr[0].direction.x);
    try testing.expectEqual(@as(i32, 3), arr[0].n_speakers_affected);
    try testing.expectEqual(@as(f32, -1.0), arr[1].direction.z);
    try testing.expectEqual(@as(f32, 0.75), arr[1].speaker_level[0]);
    // n_receivers is clamped to MAX_RECEIVER_SPECS (32).
    api_v7.AIL_set_listener_relative_receiver_array(drv, &specs, 9999);
    _ = api_v7.AIL_listener_relative_receiver_array(drv, &nr);
    try testing.expectEqual(@as(i32, 32), nr);
    // Null driver: getter reports 0 / null.
    api_v7.AIL_set_listener_relative_receiver_array(drv, &specs, 2);
    try testing.expectEqual(@as(?*anyopaque, null), api_v7.AIL_listener_relative_receiver_array(null, &nr));
    try testing.expectEqual(@as(i32, 0), nr);
}

test "AIL_speaker_configuration returns the default stereo speaker array (SDK)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    var n_phys: i32 = 0;
    var n_log: i32 = 0;
    var falloff: f32 = 0;
    const pos_one = api_v7.AIL_speaker_configuration(drv, &n_phys, &n_log, &falloff, null) orelse return error.NullArray;
    const pos: [*]api_v7.MSSVECTOR3D = @ptrCast(pos_one);
    try testing.expectEqual(@as(i32, 2), n_phys);
    try testing.expectEqual(@as(i32, 2), n_log);
    // Default stereo (genericdig.cpp MSS_MC_STEREO): ±45° in the horizontal
    // plane -> x=∓1/√2, y=0, z=1/√2.
    const r: f32 = 0.707106781;
    try testing.expect(@abs(pos[0].x + r) < 0.0001 and @abs(pos[0].y) < 0.0001 and @abs(pos[0].z - r) < 0.0001);
    try testing.expect(@abs(pos[1].x - r) < 0.0001 and @abs(pos[1].y) < 0.0001 and @abs(pos[1].z - r) < 0.0001);
    // Null driver returns NULL.
    try testing.expectEqual(@as(?*api_v7.MSSVECTOR3D, null), api_v7.AIL_speaker_configuration(null, &n_phys, &n_log, &falloff, null));

    // AIL_set_speaker_configuration round-trips falloff_power and the positions.
    var newpos = [_]api_v7.MSSVECTOR3D{ .{ .x = 1, .y = 2, .z = 3 }, .{ .x = -1, .y = -2, .z = -3 } };
    api_v7.AIL_set_speaker_configuration(drv, &newpos, 2, 0.65);
    const pos2: [*]api_v7.MSSVECTOR3D = @ptrCast(api_v7.AIL_speaker_configuration(drv, &n_phys, &n_log, &falloff, null).?);
    try testing.expect(@abs(falloff - 0.65) < 0.0001);
    try testing.expect(pos2[0].x == 1 and pos2[0].y == 2 and pos2[0].z == 3);
    try testing.expect(pos2[1].x == -1 and pos2[1].z == -3);
    // Null array / 0 channels changes only the falloff power (positions retained).
    api_v7.AIL_set_speaker_configuration(drv, null, 0, 0.9);
    _ = api_v7.AIL_speaker_configuration(drv, &n_phys, &n_log, &falloff, null);
    try testing.expect(@abs(falloff - 0.9) < 0.0001);
    try testing.expect(pos2[0].x == 1); // unchanged
    // Null driver is a no-op (doesn't touch state).
    api_v7.AIL_set_speaker_configuration(null, &newpos, 2, 0.1);
    _ = api_v7.AIL_speaker_configuration(drv, &n_phys, &n_log, &falloff, null);
    try testing.expect(@abs(falloff - 0.9) < 0.0001); // still 0.9, not 0.1
}

test "output_speaker_index matches the SDK MSS_SPEAKER->channel map" {
    // wavefile.cpp output_speaker_index[logical_channels][MSS_SPEAKER]. Verify the
    // distinctive (non-sequential) entries so an accidental edit to the multi-
    // channel routing table is caught. MSS_SPEAKER: FL=0 FR=1 FC=2 LFE=3 BL=4
    // BR=5 FLC=6 FRC=7 BC=8 SL=9 SR=10.
    const T = @import("api/v8.zig").output_speaker_index;
    // Stereo: only FL/FR map; FC is absent.
    try testing.expectEqual(@as(i8, 0), T[2][0]); // FL
    try testing.expectEqual(@as(i8, 1), T[2][1]); // FR
    try testing.expectEqual(@as(i8, -1), T[2][2]); // FC -> none
    // Dolby ProLogic (3 ch): FL,FR, and BACK_CENTER (idx 8) -> channel 2; FC absent.
    try testing.expectEqual(@as(i8, -1), T[3][2]); // FC -> none
    try testing.expectEqual(@as(i8, 2), T[3][8]); // BC -> 2
    // 5.1: FL..BR are 0..5 with LFE=3, FC=2; BC absent.
    try testing.expectEqual(@as(i8, 2), T[6][2]); // FC
    try testing.expectEqual(@as(i8, 3), T[6][3]); // LFE
    try testing.expectEqual(@as(i8, 5), T[6][5]); // BR
    try testing.expectEqual(@as(i8, -1), T[6][8]); // BC -> none
    // 6.1: adds BACK_CENTER -> channel 6.
    try testing.expectEqual(@as(i8, 6), T[7][8]); // BC -> 6
    // 7.1: adds SIDE_LEFT/RIGHT (idx 9/10) -> 6/7; BC absent.
    try testing.expectEqual(@as(i8, -1), T[8][8]); // BC -> none
    try testing.expectEqual(@as(i8, 6), T[8][9]); // SL -> 6
    try testing.expectEqual(@as(i8, 7), T[8][10]); // SR -> 7
    // 8.1: BC=6, SL=7, SR=8.
    try testing.expectEqual(@as(i8, 6), T[9][8]); // BC -> 6
    try testing.expectEqual(@as(i8, 7), T[9][9]); // SL -> 7
    try testing.expectEqual(@as(i8, 8), T[9][10]); // SR -> 8
    // Invalid (0) row and mono are fully -1 / single.
    try testing.expectEqual(@as(i8, -1), T[0][0]);
    try testing.expectEqual(@as(i8, 0), T[1][0]);
    try testing.expectEqual(@as(i8, -1), T[1][1]);

    // output_speaker_order (channel -> MSS_SPEAKER) must be the exact inverse:
    // for every config m and output channel c carrying speaker s>=0, the forward
    // map sends s back to c; and unused channels are -1. This locks both tables
    // and their mutual consistency.
    const ORD = @import("api/v7.zig").output_speaker_order;
    for (0..10) |m| {
        for (0..18) |c| {
            const s = ORD[m][c];
            if (s < 0) continue;
            try testing.expectEqual(@as(i8, @intCast(c)), T[m][@intCast(s)]);
        }
        // And the forward map's non-(-1) entries are exactly covered by the order.
        for (0..18) |s| {
            const c = T[m][s];
            if (c < 0) continue;
            try testing.expectEqual(@as(i32, @intCast(s)), ORD[m][@intCast(c)]);
        }
    }
    // Spot-check distinctive order rows: 7.1 channels 6/7 are SIDE_LEFT/RIGHT(9/10),
    // 8.1 channel 6 is BACK_CENTER(8).
    try testing.expectEqual(@as(i32, 9), ORD[8][6]);
    try testing.expectEqual(@as(i32, 10), ORD[8][7]);
    try testing.expectEqual(@as(i32, 8), ORD[9][6]);
}

test "AIL_set/sample_channel_levels round-trip + default routing (SDK)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2); // stereo out
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    s.channel_mask = ~@as(u32, 0); // FL->src0, FR->src1
    s.pcm_format = .{ .channels = 2, .bits = 16 }; // stereo source

    // Default (unset): stereo identity. (FL->FL)=1, (FR->FR)=1, (FL->FR)=0.
    const src = [_]i32{ 0, 1, 0 }; // source speakers: FL, FR, FL
    const dst = [_]i32{ 0, 1, 1 }; // dest speakers:   FL, FR, FR
    var out = [_]f32{ -1, -1, -1 };
    api_v7.AIL_sample_channel_levels(s, &src, &dst, &out[0], 3);
    try testing.expectEqual(@as(f32, 1.0), out[0]); // FL->FL
    try testing.expectEqual(@as(f32, 1.0), out[1]); // FR->FR
    try testing.expectEqual(@as(f32, 0.0), out[2]); // FL->FR (off-diagonal)

    // Explicitly set FL->FR to 0.5; it round-trips, diagonal defaults retained.
    const sset = [_]i32{0};
    const dset = [_]i32{1};
    const lset = [_]f32{0.5};
    api_v7.AIL_set_sample_channel_levels(s, &sset, &dset, &lset[0], 1);
    api_v7.AIL_sample_channel_levels(s, &src, &dst, &out[0], 3);
    try testing.expectEqual(@as(f32, 1.0), out[0]); // FL->FL still 1 (default kept)
    try testing.expectEqual(@as(f32, 1.0), out[1]); // FR->FR still 1
    try testing.expectEqual(@as(f32, 0.5), out[2]); // FL->FR now 0.5

    // Null args reset to defaults: FL->FR back to 0.
    api_v7.AIL_set_sample_channel_levels(s, null, null, null, 0);
    api_v7.AIL_sample_channel_levels(s, &src, &dst, &out[0], 3);
    try testing.expectEqual(@as(f32, 0.0), out[2]);
}

test "AIL_set/sample_channel_levels_v7 round-trips through the identity matrix" {
    // The v7 entry points have no src/dst speaker arrays, so they synthesize an
    // identity matrix: logical output channel i carries source channel i. It
    // has to be a real array, not a forwarded null: null src/dst is the v8
    // reset path, so a wrapper that passed nulls through would report success
    // and hand the caller back the defaults it had just replaced.
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2); // stereo out
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    s.channel_mask = ~@as(u32, 0); // FL->src0, FR->src1
    s.pcm_format = .{ .channels = 2, .bits = 16 }; // stereo source

    var out = [_]f32{ -1, -1 };
    api_v7.AIL_sample_channel_levels_v7(s, &out[0]);
    try testing.expectEqual(@as(f32, 1.0), out[0]); // FL->FL default
    try testing.expectEqual(@as(f32, 1.0), out[1]); // FR->FR default

    const set = [_]f32{ 0.25, 0.75 };
    api_v7.AIL_set_sample_channel_levels_v7(s, &set[0], 2);
    out = .{ -1, -1 };
    api_v7.AIL_sample_channel_levels_v7(s, &out[0]);
    try testing.expectEqual(@as(f32, 0.25), out[0]);
    try testing.expectEqual(@as(f32, 0.75), out[1]);

    // A count of zero with a real array is not the null-args reset: the levels
    // the caller just set survive it.
    api_v7.AIL_set_sample_channel_levels_v7(s, &set[0], 0);
    out = .{ -1, -1 };
    api_v7.AIL_sample_channel_levels_v7(s, &out[0]);
    try testing.expectEqual(@as(f32, 0.25), out[0]);
    try testing.expectEqual(@as(f32, 0.75), out[1]);

    // A null level array is the reset, the same as the v8 form.
    api_v7.AIL_set_sample_channel_levels_v7(s, null, 0);
    out = .{ -1, -1 };
    api_v7.AIL_sample_channel_levels_v7(s, &out[0]);
    try testing.expectEqual(@as(f32, 1.0), out[0]);
    try testing.expectEqual(@as(f32, 1.0), out[1]);

    // Null handles on either side are no-ops, not crashes.
    api_v7.AIL_sample_channel_levels_v7(null, &out[0]);
    api_v7.AIL_sample_channel_levels_v7(s, null);
    api_v7.AIL_set_sample_channel_levels_v7(null, &set[0], 2);
    out = .{ -1, -1 };
    api_v7.AIL_sample_channel_levels_v7(s, &out[0]);
    try testing.expectEqual(@as(f32, 1.0), out[0]);
    try testing.expectEqual(@as(f32, 1.0), out[1]);
}

test "AIL_set/sample_speaker_scale_factors round-trip via the channel map (SDK)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2); // stereo
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    // Stereo map: FRONT_LEFT(0)->ch0, FRONT_RIGHT(1)->ch1, others unmapped.
    const idx = [_]i32{ 0, 1, 4 }; // FL, FR, BACK_LEFT(unmapped in stereo)
    const set_lv = [_]f32{ 0.25, 0.75, 0.9 };
    api_v8b.AIL_set_sample_speaker_scale_factors(s, &idx, &set_lv, 3);
    // The mapped channels store their levels; the unmapped one is dropped.
    try testing.expect(@abs(s.speaker_levels[0] - 0.25) < 0.0001);
    try testing.expect(@abs(s.speaker_levels[1] - 0.75) < 0.0001);
    // Read back via the inverse mapping.
    var out = [_]f32{ -1, -1, -1 };
    api_v8b.AIL_sample_speaker_scale_factors(s, &idx, &out, 3);
    try testing.expect(@abs(out[0] - 0.25) < 0.0001 and @abs(out[1] - 0.75) < 0.0001);
    try testing.expectEqual(@as(f32, -1), out[2]); // BACK_LEFT unmapped -> left untouched
    // Null/zero guards: no crash, no change.
    api_v8b.AIL_set_sample_speaker_scale_factors(null, &idx, &set_lv, 3);
    api_v8b.AIL_set_sample_speaker_scale_factors(s, null, &set_lv, 3);
    api_v8b.AIL_set_sample_speaker_scale_factors(s, &idx, &set_lv, 0);
}

test "AIL_set/speaker_reverb_levels round-trip; AIL_get_marker_list reports empty (SDK)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2); // stereo
    defer drv.deinit();
    var wet: ?*f32 = null;
    var dry: ?*f32 = null;
    var idx: ?*const anyopaque = null;
    // Reset to defaults (null arrays) -> all responses 1.0; returns channel count.
    api_v7.AIL_set_speaker_reverb_levels(drv, null, null, null, 0);
    try testing.expectEqual(@as(i32, 2), api_v7.AIL_speaker_reverb_levels(drv, &wet, &dry, &idx));
    try testing.expect(wet != null and dry != null and idx != null);
    try testing.expectEqual(@as(f32, 1.0), wet.?.*); // FRONT_LEFT default
    // The speaker order for stereo is FL(0), FR(1).
    const order: [*]const i32 = @ptrCast(@alignCast(idx.?));
    try testing.expectEqual(@as(i32, 0), order[0]);
    try testing.expectEqual(@as(i32, 1), order[1]);
    // Set FRONT_RIGHT(1) wet=0.3, dry=0.7; reads back at driver channel 1.
    const spk = [_]i32{1};
    const w = [_]f32{0.3};
    const d = [_]f32{0.7};
    api_v7.AIL_set_speaker_reverb_levels(drv, &w[0], &d[0], &spk[0], 1);
    _ = api_v7.AIL_speaker_reverb_levels(drv, &wet, &dry, &idx);
    const wa: [*]const f32 = @ptrCast(@alignCast(wet.?));
    const da: [*]const f32 = @ptrCast(@alignCast(dry.?));
    try testing.expectEqual(@as(f32, 0.3), wa[1]);
    try testing.expectEqual(@as(f32, 0.7), da[1]);
    try testing.expectEqual(@as(f32, 1.0), wa[0]); // FL untouched
    // Null driver -> 0.
    try testing.expectEqual(@as(i32, 0), api_v7.AIL_speaker_reverb_levels(null, &wet, &dry, &idx));
    // No marker list modelled: returns 0 (null handle).
    try testing.expectEqual(@as(isize, 0), api_v8b.AIL_get_marker_list(null, null));
}

test "AIL_register_falloff_function_callback returns the sample's prior callback" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    const cb1: *anyopaque = @ptrFromInt(0xBEEF);
    const cb2: *anyopaque = @ptrFromInt(0xCAFE);
    // Fresh sample: no callback installed -> first call returns null.
    try testing.expectEqual(@as(?*anyopaque, null), api_v8b.AIL_register_falloff_function_callback(s, cb1));
    try testing.expectEqual(@as(?*anyopaque, cb1), api_v8b.AIL_register_falloff_function_callback(s, cb2));
    try testing.expectEqual(@as(?*anyopaque, cb2), api_v8b.AIL_register_falloff_function_callback(s, null));
    // Null sample returns 0 (SDK guard).
    try testing.expectEqual(@as(?*anyopaque, null), api_v8b.AIL_register_falloff_function_callback(null, cb1));
}

test "AIL_configure_logging returns the previous trace callback (SDK)" {
    const cb1: *anyopaque = @ptrFromInt(0x111);
    const cb2: *anyopaque = @ptrFromInt(0x222);
    // Establish a baseline, then each call returns the prior trace callback.
    _ = api_v9.AIL_configure_logging(null, cb1, 0);
    try testing.expectEqual(@as(?*anyopaque, cb1), api_v9.AIL_configure_logging(null, cb2, 1));
    try testing.expectEqual(@as(?*anyopaque, cb2), api_v9.AIL_configure_logging(null, null, 0));
}

test "AIL_mem_use_malloc/free return the previously installed callback (SDK)" {
    const mem = @import("api/memory.zig");
    const a: *anyopaque = @ptrFromInt(0x1000);
    const b: *anyopaque = @ptrFromInt(0x2000);
    // Establish a known baseline (A), then each set returns the prior callback.
    _ = mem.AIL_mem_use_malloc(a);
    try testing.expectEqual(@as(?*anyopaque, a), mem.AIL_mem_use_malloc(b));
    try testing.expectEqual(@as(?*anyopaque, b), mem.AIL_mem_use_malloc(null)); // null reverts to default
    _ = mem.AIL_mem_use_free(a);
    try testing.expectEqual(@as(?*anyopaque, a), mem.AIL_mem_use_free(b));
    try testing.expectEqual(@as(?*anyopaque, b), mem.AIL_mem_use_free(null));
}

test "AIL_set_timer_user stores new and returns the previous value (SDK)" {
    const api_timer = @import("api/timer.zig");
    const t = api_timer.AIL_register_timer(noopTimerCb) orelse return error.NoTimer;
    const tt: *openmiles.Timer = @ptrCast(@alignCast(t));
    defer api_timer.AIL_release_timer_handle(tt);
    // Fresh timer's user value is 0; first set returns the old 0.
    try testing.expectEqual(@as(u32, 0), api_timer.AIL_set_timer_user(tt, 0x1234));
    // Next set returns the previously stored value.
    try testing.expectEqual(@as(u32, 0x1234), api_timer.AIL_set_timer_user(tt, 0xABCD));
    try testing.expectEqual(@as(u32, 0xABCD), tt.getUserData());
    // Null handle returns 0.
    try testing.expectEqual(@as(u32, 0), api_timer.AIL_set_timer_user(null, 5));
}

test "timer can stop itself from inside its callback without deadlocking" {
    const T = openmiles.Timer;
    var fired = std.atomic.Value(u32).init(0);
    const H = struct {
        var timer_ptr: ?*T = null;
        var counter: *std.atomic.Value(u32) = undefined;
        fn cb(_: u32) callconv(.winapi) void {
            _ = counter.fetchAdd(1, .monotonic);
            // One-shot pattern from MSS games: stop your own timer from the
            // callback. Must not join/deadlock on the calling thread.
            if (timer_ptr) |t| t.stop();
        }
    };
    H.counter = &fired;
    const t = try T.init(openmiles.global_allocator, H.cb);
    defer t.deinit();
    H.timer_ptr = t;
    t.setPeriodUs(1_000);
    t.start();
    // The callback stops the timer on its first fire; give it a generous
    // window, then require that the thread actually wound down.
    var waited: u32 = 0;
    while (fired.load(.monotonic) == 0 and waited < 5000) : (waited += 10) {
        openmiles.io.sleep(std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
    }
    try testing.expect(fired.load(.monotonic) >= 1);
    try testing.expect(!@atomicLoad(bool, &t.is_running, .acquire));
}

test "AIL_file_type classifies WAV/MIDI/XMIDI/OGG/VOC/BINKA/DLS/MLS (SDK)" {
    // Complete PCM WAV — AIL_WAV_info (and thus file_type) needs a data chunk.
    const pcm = [_]u8{0} ** 32;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    try testing.expectEqual(@as(i32, 1), api_file.AIL_file_type(wav.ptr, @intCast(wav.len))); // PCM_WAV

    // IMA ADPCM WAV (tag 0x11, bits 4, block_align 512) -> ADPCM_WAV(2).
    var adpcm = [_]u8{
        'R',  'I',  'F', 'F', 0,  0, 0, 0, 'W',  'A', 'V', 'E',
        'f',  'm',  't', ' ', 16, 0, 0, 0, 0x11, 0,   1,   0,
        0x40, 0x1f, 0,   0,   0,  0, 0, 0, 0,    2,   4,   0,
        'd',  'a',  't', 'a', 16, 0, 0, 0, 0,    0,   0,   0,
        0,    0,    0,   0,   0,  0, 0, 0, 0,    0,   0,   0,
    };
    adpcm[4] = @truncate(@as(u32, adpcm.len) - 8);
    try testing.expectEqual(@as(i32, 2), api_file.AIL_file_type(&adpcm, adpcm.len)); // ADPCM_WAV

    var midi = [_]u8{ 'M', 'T', 'h', 'd', 0, 0, 0, 6 };
    try testing.expectEqual(@as(i32, 5), api_file.AIL_file_type(&midi, midi.len)); // MIDI
    var xmidi = [_]u8{ 'F', 'O', 'R', 'M', 0, 0, 0, 0, 'X', 'D', 'I', 'R' };
    try testing.expectEqual(@as(i32, 6), api_file.AIL_file_type(&xmidi, xmidi.len)); // XMIDI

    var ogg = [_]u8{ 'O', 'g', 'g', 'S', 0, 0, 0, 0, 1, 2, 3, 4 };
    try testing.expectEqual(@as(i32, 16), api_file.AIL_file_type(&ogg, ogg.len)); // OGG_VORBIS
    var speex = [_]u8{ 'O', 'g', 'g', 'S', 0, 0, 0, 0, 0, 0, 0, 0, 'S', 'p', 'e', 'e', 'x', 0, 0, 0 };
    try testing.expectEqual(@as(i32, 20), api_file.AIL_file_type(&speex, speex.len)); // OGG_SPEEX

    var voc = [_]u8{ 'C', 'r', 'e', 'a', 't', 'i', 'v', 'e', ' ' };
    try testing.expectEqual(@as(i32, 4), api_file.AIL_file_type(&voc, voc.len)); // VOC
    var binka = [_]u8{ '1', 'F', 'C', 'B', 0, 0, 0, 0 }; // *(S32*)=='BCF1' on LE
    try testing.expectEqual(@as(i32, 24), api_file.AIL_file_type(&binka, binka.len)); // BINKA
    var dls = [_]u8{ 'R', 'I', 'F', 'F', 0, 0, 0, 0, 'D', 'L', 'S', ' ' };
    try testing.expectEqual(@as(i32, 9), api_file.AIL_file_type(&dls, dls.len)); // DLS
    var mls = [_]u8{ 'R', 'I', 'F', 'F', 0, 0, 0, 0, 'M', 'L', 'S', ' ' };
    try testing.expectEqual(@as(i32, 10), api_file.AIL_file_type(&mls, mls.len)); // MLS

    var junk = [_]u8{ 'J', 'U', 'N', 'K', 0, 0, 0, 0 };
    try testing.expectEqual(@as(i32, 0), api_file.AIL_file_type(&junk, junk.len)); // UNKNOWN
}

test "AIL_file_type MPEG scan honors the version-dependent header-size cap" {
    // AIL_MAX_FILE_HEADER_SIZE bounds the MPEG frame-sync scan: 4096 before MSS
    // 7.0, 8192 from 7.0 on (verified by disassembling AIL_file_type). Place a
    // valid MPEG-1 Layer III frame sync (FF FB 90 00) at offset 5000 -- inside the
    // 8192 window but past the 4096 one -- so the classification flips on version.
    var buf = [_]u8{0} ** 5104;
    buf[5000] = 0xFF;
    buf[5001] = 0xFB;
    buf[5002] = 0x90;
    buf[5003] = 0x00;
    const got = api_file.AIL_file_type(&buf, buf.len);
    if (openmiles.mss_version >= 70) {
        try testing.expectEqual(@as(i32, 13), got); // MPEG_L3_AUDIO: scan reaches 5000
    } else {
        try testing.expectEqual(@as(i32, 0), got); // UNKNOWN: scan stops at 4096
    }
}

test "AIL_compress_ADPCM/decompress_ADPCM round-trip through raw-block AILSOUNDINFO" {
    // Original 16-bit mono PCM: a slow ramp (ADPCM tracks it well).
    var pcm: [2000]i16 = undefined;
    for (&pcm, 0..) |*s, i| s.* = @intCast(@as(i32, @intCast(i % 200)) * 50 - 5000);
    var in: openmiles.AILSOUNDINFO = .{};
    in.data_ptr = @ptrCast(&pcm);
    in.data_len = pcm.len * 2;
    in.format = 1;
    in.bits = 16;
    in.channels = 1;
    in.rate = 22050;

    var adpcm_ptr: *anyopaque = undefined;
    var adpcm_size: u32 = 0;
    try testing.expect(dg.AIL_compress_ADPCM(&in, &adpcm_ptr, &adpcm_size) != 0);
    defer std.c.free(adpcm_ptr);
    const adpcm_wav = @as([*]const u8, @ptrCast(adpcm_ptr))[0..adpcm_size];

    // AIL_WAV_info reports the raw ADPCM block data (format 0x11, bits 4), which
    // is exactly what AIL_decompress_ADPCM expects (SDK convention).
    var mid: openmiles.AILSOUNDINFO = .{};
    try testing.expect(dg.AIL_WAV_info(@ptrCast(@constCast(adpcm_wav.ptr)), &mid) != 0);
    try testing.expectEqual(@as(i32, 0x11), mid.format);
    try testing.expectEqual(@as(i32, 4), mid.bits);
    // SDK block alignment for mono @ 22050: 256<<0 * ((22050+5000)/11025=2) = 512.
    try testing.expectEqual(@as(u32, 512), mid.block_size);

    var out_ptr: *anyopaque = undefined;
    var out_size: u32 = 0;
    try testing.expect(dg.AIL_decompress_ADPCM(&mid, &out_ptr, &out_size) != 0);
    defer std.c.free(out_ptr);

    // The output is a valid 16-bit PCM WAV with the source's channels/rate.
    var outi: openmiles.AILSOUNDINFO = .{};
    try testing.expect(dg.AIL_WAV_info(out_ptr, &outi) != 0);
    try testing.expectEqual(@as(i32, 1), outi.format); // PCM
    try testing.expectEqual(@as(i32, 16), outi.bits);
    try testing.expectEqual(@as(i32, 1), outi.channels);
    try testing.expectEqual(@as(u32, 22050), outi.rate);
    // The SDK sizes the decoded output to exactly info->samples frames
    // (samples*ch*16/8); the IMA block padding is trimmed, so the frame count is
    // the declared sample count exactly -- not the block-rounded total.
    try testing.expectEqual(mid.samples, outi.samples);
    try testing.expectEqual(@as(u32, 2000), outi.samples);

    // Fidelity: the decoded PCM must actually track the source ramp -- not just
    // carry a correct header. A decoder that emitted silence or garbage would
    // satisfy every structural check above. IMA ADPCM stores the first sample of
    // each block verbatim and tracks a smooth slope tightly, so compare the clean
    // monotonic run before the first sawtooth wrap (i in 0..199) within a lossy
    // tolerance. Read via byte offsets to avoid any alignment assumption.
    const dec: [*]const u8 = @ptrCast(outi.data_ptr.?);
    try testing.expect(outi.data_len >= 190 * 2);
    var max_err: i32 = 0;
    for (0..190) |i| {
        const dv = std.mem.readInt(i16, dec[i * 2 ..][0..2], .little);
        const ad: i32 = @intCast(@abs(@as(i32, dv) - @as(i32, pcm[i])));
        max_err = @max(max_err, ad);
    }
    try testing.expect(max_err < 1500);

    // SDK validation guards: non-IMA format and zero samples both return 0.
    mid.format = 1;
    try testing.expectEqual(@as(i32, 0), dg.AIL_decompress_ADPCM(&mid, &out_ptr, &out_size));
    mid.format = 0x11;
    mid.samples = 0;
    try testing.expectEqual(@as(i32, 0), dg.AIL_decompress_ADPCM(&mid, &out_ptr, &out_size));
}

test "IMA ADPCM step/index tables match the SDK (mssadpcm.cpp) byte-for-byte" {
    // The round-trip tests only prove our encode/decode are self-consistent; if
    // both shared a corrupted table they'd still round-trip while diverging from
    // real MSS. Lock the tables directly to the SDK's step[] and next_step[].
    const enc = openmiles; // tables re-exported through root
    const sdk_step = [89]i32{
        7,     8,     9,     10,    11,    12,    13,    14,    16,    17,    19,    21,    23,
        25,    28,    31,    34,    37,    41,    45,    50,    55,    60,    66,    73,    80,
        88,    97,    107,   118,   130,   143,   157,   173,   190,   209,   230,   253,   279,
        307,   337,   371,   408,   449,   494,   544,   598,   658,   724,   796,   876,   963,
        1060,  1166,  1282,  1411,  1552,  1707,  1878,  2066,  2272,  2499,  2749,  3024,  3327,
        3660,  4026,  4428,  4871,  5358,  5894,  6484,  7132,  7845,  8630,  9493,  10442, 11487,
        12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    };
    try testing.expectEqual(@as(usize, 89), enc.ima_step_table.len);
    for (sdk_step, 0..) |v, i| try testing.expectEqual(v, enc.ima_step_table[i]);
    const sdk_next = [16]i32{ -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8 };
    for (sdk_next, 0..) |v, i| try testing.expectEqual(v, enc.ima_index_table[i]);
}

test "buildAdpcmWav carries the IMA step index across block headers (MSS parity)" {
    // MSS (mssadpcm.cpp) carries the step index across blocks; each block header
    // stores the value carried in from the prior block, not a fresh 0. With a
    // loud, fast-adapting signal the step index saturates within the first block,
    // so the SECOND block's header step-index byte must be non-zero -- the old
    // per-block reset wrote 0 there, diverging from MSS from block 2 on.
    const allocator = testing.allocator;
    // mono @ 11025 Hz -> block_size 256, spb 505; >505 samples spans 2 blocks.
    var pcm: [1100]i16 = undefined;
    for (&pcm, 0..) |*s, i| s.* = if (i % 2 == 0) @as(i16, 12000) else @as(i16, -12000);
    const wav = try openmiles.buildAdpcmWav(allocator, &pcm, pcm.len, 1, 11025);
    defer allocator.free(wav);

    // Header is 60 bytes (RIFF/fmt(20)/fact/data); block_size 256. The second
    // block's header begins at 60 + 256; its byte +2 is the carried step index.
    const block_size: usize = 256;
    const second_block_stepidx = wav[60 + block_size + 2];
    try testing.expect(second_block_stepidx != 0);
    try testing.expect(second_block_stepidx <= 88); // valid IMA step index range
    // First block always starts at step index 0 (MSS inits lstepi=0 once).
    try testing.expectEqual(@as(u8, 0), wav[60 + 2]);
}

test "AIL_compress_ADPCM: SDK block alignment, 8-bit input, and validation guards" {
    // Block alignment scales with rate: 256<<(ch/2), ×(rate+5000)/11025 above 11025.
    const cases = [_]struct { ch: i32, rate: u32, blk: u32 }{
        .{ .ch = 1, .rate = 8000, .blk = 256 }, // <= 11025 -> base 256 (mono)
        .{ .ch = 2, .rate = 8000, .blk = 512 }, // base 512 (stereo)
        .{ .ch = 1, .rate = 44100, .blk = 1024 }, // 256 * ((44100+5000)/11025=4)
        .{ .ch = 2, .rate = 44100, .blk = 2048 }, // 512 * 4
    };
    var pcm = [_]i16{0} ** 64;
    for (cases) |c| {
        var info: openmiles.AILSOUNDINFO = .{};
        info.data_ptr = @ptrCast(&pcm);
        info.data_len = pcm.len * 2;
        info.format = 1;
        info.bits = 16;
        info.channels = c.ch;
        info.rate = c.rate;
        var op: *anyopaque = undefined;
        var os: u32 = 0;
        try testing.expect(dg.AIL_compress_ADPCM(&info, &op, &os) != 0);
        defer std.c.free(op);
        var wi: openmiles.AILSOUNDINFO = .{};
        try testing.expect(dg.AIL_WAV_info(op, &wi) != 0);
        try testing.expectEqual(c.blk, wi.block_size);
    }
    // 8-bit unsigned PCM is accepted (promoted to 16-bit) and compresses.
    var u8pcm = [_]u8{128} ** 64;
    var info8: openmiles.AILSOUNDINFO = .{};
    info8.data_ptr = @ptrCast(&u8pcm);
    info8.data_len = u8pcm.len;
    info8.format = 1;
    info8.bits = 8;
    info8.channels = 1;
    info8.rate = 22050;
    var op8: *anyopaque = undefined;
    var os8: u32 = 0;
    try testing.expect(dg.AIL_compress_ADPCM(&info8, &op8, &os8) != 0);
    std.c.free(op8);
    // Validation: non-PCM format and unsupported bit depth are rejected.
    info8.format = 0x11; // already compressed
    try testing.expectEqual(@as(i32, 0), dg.AIL_compress_ADPCM(&info8, &op8, &os8));
    info8.format = 1;
    info8.bits = 24; // unsupported
    try testing.expectEqual(@as(i32, 0), dg.AIL_compress_ADPCM(&info8, &op8, &os8));
}

test "AIL_file_type detects MPEG audio by frame sync (MP3 = layer III)" {
    // ID3v2 header (10 bytes, size 0) then an MPEG-1 Layer III frame sync.
    var mp3 = [_]u8{ 'I', 'D', '3', 3, 0, 0, 0, 0, 0, 0, 0xFF, 0xFB, 0x90, 0x00, 0, 0, 0, 0 };
    try testing.expectEqual(@as(i32, 13), api_file.AIL_file_type(&mp3, mp3.len)); // MPEG_L3_AUDIO
}

test "AIL_redbook_status returns REDBOOK_* codes (STOPPED=0, ERROR=3)" {
    // Values are the REDBOOK_* defines in src/mss.h; the engine enum only holds
    // the three a live drive can be in.
    try testing.expectEqual(@as(u32, 0), @intFromEnum(openmiles.RedbookStatus.stopped));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(openmiles.RedbookStatus.playing));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(openmiles.RedbookStatus.paused));
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator);
    defer rb.deinit();
    try testing.expectEqual(@as(u32, 0), api_redbook.AIL_redbook_status(rb)); // REDBOOK_STOPPED
    try testing.expectEqual(@as(u32, 3), api_redbook.AIL_redbook_status(null)); // REDBOOK_ERROR
}

test "AILSOUNDINFO layout: channel_mask present only for v8+" {
    // 3.x/6.1/6.5/7.0 have 9 fields (36 bytes); 8.0 added channel_mask between
    // `channels` and `samples` -> 10 fields (40 bytes), retained in 9.x. Verified
    // by disassembling AIL_API_set_sample_info: 8.0e/9.1d read channel_mask at
    // info+0x18 and block_size at +0x20; 7.0k reads block_size at +0x1c with no
    // channel_mask. A wrong layout shifts samples/block_size/initial_ptr and
    // corrupts what a game reads. Offsets in bytes depend on pointer size (4 on
    // the x86 DLL, 8 on the native test target), so assert pointer-size-
    // independent properties: field presence and ordering.
    const T = openmiles.AILSOUNDINFO;
    if (openmiles.mss_version >= 80) {
        try testing.expect(@hasField(T, "channel_mask"));
        try testing.expect(@offsetOf(T, "channels") < @offsetOf(T, "channel_mask"));
        try testing.expect(@offsetOf(T, "channel_mask") < @offsetOf(T, "samples"));
    } else {
        try testing.expect(!@hasField(T, "channel_mask"));
    }
    try testing.expect(@offsetOf(T, "channels") < @offsetOf(T, "samples"));
    try testing.expect(@offsetOf(T, "samples") < @offsetOf(T, "block_size"));
}

test "AIL_WAV_info reports the WAVE format tag and SDK fields" {
    const allocator = testing.allocator;
    // PCM stereo 16-bit -> format is the WAVE tag WAVE_FORMAT_PCM = 1 (NOT DIG_F_).
    const pcm = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(allocator, &pcm, 2, 44100, 16);
    defer allocator.free(wav);
    var info: openmiles.AILSOUNDINFO = .{};
    try testing.expect(dg.AIL_WAV_info(@ptrCast(wav.ptr), &info) != 0);
    try testing.expectEqual(@as(i32, 1), info.format); // WAVE_FORMAT_PCM
    try testing.expectEqual(@as(i32, 16), info.bits);
    try testing.expectEqual(@as(i32, 2), info.channels);
    try testing.expectEqual(@as(u32, 44100), info.rate);
    // samples is the per-channel frame count ((data_len*8)/(bits*channels)):
    // 64 bytes of 16-bit stereo is 16 frames, and the SDK sizes decoded output
    // as samples*channels*16/8.
    try testing.expectEqual(@as(u32, 16), info.samples);
    try testing.expect(info.data_ptr != null);
    try testing.expect(info.initial_ptr != null); // SDK: always data_ptr, not null
    if (@hasField(openmiles.AILSOUNDINFO, "channel_mask")) {
        try testing.expectEqual(~@as(u32, 0), info.channel_mask);
    }

    // IMA ADPCM (wFormatTag=0x11) stereo -> format is the WAVE tag 0x11 (17).
    var adpcm = [_]u8{
        'R',  'I',  'F', 'F', 44, 0, 0, 0, 'W',  'A', 'V', 'E',
        'f',  'm',  't', ' ', 16, 0, 0, 0, 0x11, 0,   2,   0,
        0x44, 0xAC, 0,   0,   0,  0, 0, 0, 0,    0,   4,   0,
        'd',  'a',  't', 'a', 8,  0, 0, 0, 0,    0,   0,   0,
        0,    0,    0,   0,
    };
    var info2: openmiles.AILSOUNDINFO = .{};
    try testing.expect(dg.AIL_WAV_info(&adpcm, &info2) != 0);
    try testing.expectEqual(@as(i32, 0x11), info2.format); // WAVE_FORMAT_IMA_ADPCM
}

test "AIL_WAV_file_write interprets the DIG_F format code (not a bit depth)" {
    const data = [_]u8{0} ** 64;
    // Relative scratch path: "/tmp" is not writable on Windows (no C:\tmp), so
    // keep the file next to the test's working directory and clean it up.
    const path = "om_wavfmt_test.wav";
    defer std.Io.Dir.cwd().deleteFile(openmiles.io, path) catch {};
    const H = struct {
        fn readWav(p: []const u8, buf: []u8) ![]u8 {
            const io = openmiles.io;
            const f = try openmiles.fs_compat.openFile(io, p, .{});
            defer f.close(io);
            const n: usize = @intCast(try f.length(io));
            _ = try f.readPositionalAll(io, buf[0..n], 0);
            return buf[0..n];
        }
    };
    var rb: [512]u8 = undefined;
    // DIG_F format 3 = DIG_F_16BITS_MASK|DIG_F_STEREO_MASK -> 16-bit stereo.
    try testing.expectEqual(@as(i32, 1), dg.AIL_WAV_file_write(path, @ptrCast(@constCast(&data)), data.len, 22050, 3));
    const b = try H.readWav(path, &rb);
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, b[22..][0..2], .little)); // channels
    try testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, b[34..][0..2], .little)); // bits
    // DIG_F format 0 -> 8-bit mono.
    try testing.expectEqual(@as(i32, 1), dg.AIL_WAV_file_write(path, @ptrCast(@constCast(&data)), data.len, 22050, 0));
    const b2 = try H.readWav(path, &rb);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, b2[22..][0..2], .little));
    try testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, b2[34..][0..2], .little));

    // DIG_F_MULTICHANNEL_MASK (16) packs the channel count in the high 16 bits.
    // MSS 8.0+ writes that count; pre-8.0 has no multichannel path (bit 16 was
    // DIG_F_USING_ASI there) so it falls back to the stereo bit -> here, mono.
    const mc_format: i32 = (6 << 16) | 16 | 1; // 6ch, multichannel, 16-bit
    try testing.expectEqual(@as(i32, 1), dg.AIL_WAV_file_write(path, @ptrCast(@constCast(&data)), data.len, 22050, mc_format));
    const b3 = try H.readWav(path, &rb);
    const got_ch = std.mem.readInt(u16, b3[22..][0..2], .little);
    if (openmiles.mss_version >= 80) {
        try testing.expectEqual(@as(u16, 6), got_ch); // multichannel count honored
        // block_align = ch*bits/8 = 6*2 = 12; avg_bps = rate*block_align.
        try testing.expectEqual(@as(u16, 12), std.mem.readInt(u16, b3[32..][0..2], .little));
        try testing.expectEqual(@as(u32, 22050 * 12), std.mem.readInt(u32, b3[28..][0..4], .little));
    } else {
        try testing.expectEqual(@as(u16, 1), got_ch); // no multichannel: stereo bit unset -> mono
    }
}

test "AIL_WAV_info handles WAVEFORMATEXTENSIBLE PCM (format->1, channel_mask, reject non-PCM)" {
    // fmt chunk = 40 bytes (WAVEFORMATEXTENSIBLE), data = 16 bytes (stereo 16-bit).
    const mk = struct {
        fn build(buf: []u8, guid: [16]u8) void {
            @memset(buf, 0);
            @memcpy(buf[0..4], "RIFF");
            const riff: u32 = @intCast(buf.len - 8);
            buf[4] = @truncate(riff);
            buf[5] = @truncate(riff >> 8);
            @memcpy(buf[8..12], "WAVE");
            @memcpy(buf[12..16], "fmt ");
            buf[16] = 40; // fmt chunk size
            buf[20] = 0xFE;
            buf[21] = 0xFF; // format_tag = 0xFFFE (EXTENSIBLE)
            buf[22] = 2; // channels
            buf[24] = 0x44;
            buf[25] = 0xAC; // 44100
            buf[32] = 4; // block_align = 4 (= channels*2)
            buf[34] = 16; // bits
            buf[36] = 22; // cbSize
            buf[38] = 16; // validBitsPerSample
            buf[40] = 0x03; // dwChannelMask = FL|FR
            @memcpy(buf[44..60], &guid); // SubFormat GUID
            @memcpy(buf[60..64], "data");
            buf[64] = 16; // data_len
        }
    };
    const pcm_guid = [16]u8{ 0x01, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71 };
    var buf: [84]u8 = undefined; // 12 + 8 + 40 + 8 + 16
    mk.build(&buf, pcm_guid);
    var info: openmiles.AILSOUNDINFO = .{};
    try testing.expect(dg.AIL_WAV_info(&buf, &info) != 0);
    try testing.expectEqual(@as(i32, 1), info.format); // reported as plain PCM
    if (@hasField(openmiles.AILSOUNDINFO, "channel_mask"))
        try testing.expectEqual(@as(u32, 0x3), info.channel_mask); // from dwChannelMask
    try testing.expectEqual(@as(u32, 4), info.samples); // 16 bytes * 8 / (16 bits * 2 channels)
    // A non-PCM subformat (IEEE float GUID) is rejected.
    const float_guid = [16]u8{ 0x03, 0, 0, 0, 0, 0, 0x10, 0, 0x80, 0, 0, 0xaa, 0, 0x38, 0x9b, 0x71 };
    mk.build(&buf, float_guid);
    var info2: openmiles.AILSOUNDINFO = .{};
    try testing.expectEqual(@as(i32, 0), dg.AIL_WAV_info(&buf, &info2));
}

test "AIL_WAV_info computes IMA ADPCM sample count via the SDK block formula" {
    // Production-like block_align so the formula (not the degenerate <spb0 path)
    // runs: stereo, block_align=512, data_len=1024 (2 blocks). SDK (wavefile.cpp):
    //   spb0 = 4 << (channels/2) = 8
    //   samples_per_block = 1 + (512-8)*8/8 = 505
    //   samples = ceil(1024/512) * 505 = 2 * 505 = 1010
    const data_len: u32 = 1024;
    const buf = try testing.allocator.alloc(u8, 44 + data_len);
    defer testing.allocator.free(buf);
    @memset(buf, 0);
    @memcpy(buf[0..4], "RIFF");
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    buf[16] = 16; // fmt chunk size
    buf[20] = 0x11; // IMA ADPCM
    buf[22] = 2; // channels
    buf[24] = 0x44;
    buf[25] = 0xAC; // 44100
    buf[32] = 0x00;
    buf[33] = 0x02; // block_align = 512
    buf[34] = 4; // bits
    @memcpy(buf[36..40], "data");
    buf[40] = 0x00;
    buf[41] = 0x04; // data_len = 1024
    const riff_size: u32 = @intCast(buf.len - 8);
    buf[4] = @truncate(riff_size);
    buf[5] = @truncate(riff_size >> 8);
    var info: openmiles.AILSOUNDINFO = .{};
    try testing.expect(dg.AIL_WAV_info(buf.ptr, &info) != 0);
    try testing.expectEqual(@as(i32, 0x11), info.format);
    try testing.expectEqual(@as(u32, 512), info.block_size);
    try testing.expectEqual(@as(u32, 1010), info.samples);
}

test "AIL_WAV_info clamps a data chunk longer than the image (no over-read)" {
    // A crafted WAV declares a 4 GiB data chunk but carries 4 bytes of audio.
    // info.data_len must be the bytes actually present, so a consumer that
    // decodes or copies data_len bytes stays inside the caller's buffer.
    var buf: [48]u8 = undefined;
    @memset(&buf, 0);
    @memcpy(buf[0..4], "RIFF");
    @memcpy(buf[8..12], "WAVE");
    @memcpy(buf[12..16], "fmt ");
    buf[16] = 16; // fmt chunk size
    buf[22] = 1; // channels
    buf[24] = 0x44;
    buf[25] = 0xAC; // 44100
    buf[32] = 2; // block_align
    buf[34] = 16; // bits
    @memcpy(buf[36..40], "data");
    @memcpy(buf[40..44], &[_]u8{ 0xFF, 0xFF, 0xFF, 0xFF }); // declares 0xFFFFFFFF
    const riff_size: u32 = @intCast(buf.len - 8);
    buf[4] = @truncate(riff_size);
    buf[5] = @truncate(riff_size >> 8);

    var info: openmiles.AILSOUNDINFO = .{};
    try testing.expect(dg.AIL_WAV_info(&buf, &info) != 0);
    try testing.expectEqual(@as(u32, 4), info.data_len); // 48 - 44
    try testing.expectEqual(@as(u32, 2), info.samples); // 4 bytes * 8 / (16 bits * 1 ch)
}

test "AIL_load_sample_buffer returns the resolved slot (-1 on bad input) (SDK)" {
    const api_digital = @import("api/digital.zig");
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    var info: openmiles.AILSOUNDINFO = .{};
    info.channels = 1;
    info.bits = 16;
    _ = api_v7.AIL_set_sample_info(s, &info); // give it a PCM format -> streaming path
    var buf = [_]u8{0} ** 64;
    const p: *anyopaque = @ptrCast(&buf);
    // n_buffers defaults to 2: slots 0 and 1 are valid and echoed back.
    try testing.expectEqual(@as(i32, 0), api_digital.AIL_load_sample_buffer(s, 0, p, 64));
    try testing.expectEqual(@as(i32, 1), api_digital.AIL_load_sample_buffer(s, 1, p, 64));
    // Slot >= n_buffers (2) is rejected with -1.
    try testing.expectEqual(@as(i32, -1), api_digital.AIL_load_sample_buffer(s, 2, p, 64));
    // MSS_BUFFER_HEAD (-1) resolves to the ring head and advances it (0,1,0,...).
    // A second sample, so the head walks free slots: on `s` both are taken by
    // the loads above, and a submission into a taken slot is refused.
    const s2 = try openmiles.Sample.init(drv);
    defer s2.deinit();
    _ = api_v7.AIL_set_sample_info(s2, &info);
    const h0 = api_digital.AIL_load_sample_buffer(s2, -1, p, 64);
    const h1 = api_digital.AIL_load_sample_buffer(s2, -1, p, 64);
    try testing.expect(h0 >= 0 and h1 >= 0 and h0 != h1);
    // The head came back around to a slot that still holds its buffer: the
    // repeat is reported, not taken.
    try testing.expectEqual(@as(i32, -1), api_digital.AIL_load_sample_buffer(s2, -1, p, 64));
    // Null sample -> -1.
    try testing.expectEqual(@as(i32, -1), api_digital.AIL_load_sample_buffer(null, 0, p, 64));
}

test "AIL_sample_buffer_info: null -> head/tail -1, return is starved not success (SDK)" {
    var pos: u32 = 99;
    var len: u32 = 99;
    var head: i32 = 99;
    var tail: i32 = 99;
    // Null sample: pos/len 0, head/tail -1, return 0.
    try testing.expectEqual(@as(i32, 0), dg.AIL_sample_buffer_info(null, 0, &pos, &len, &head, &tail));
    try testing.expectEqual(@as(u32, 0), pos);
    try testing.expectEqual(@as(u32, 0), len);
    try testing.expectEqual(@as(i32, -1), head);
    try testing.expectEqual(@as(i32, -1), tail);

    // A loaded (whole-buffer) sample isn't starved -> returns 0, reports len.
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    const pcm = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    try s.loadFromMemory(wav, false);
    head = 99;
    tail = 99;
    // Not streaming and not starved -> return 0; head/tail report the ring pointer (0).
    try testing.expectEqual(@as(i32, 0), dg.AIL_sample_buffer_info(s, 0, &pos, &len, &head, &tail));
    try testing.expectEqual(@as(i32, 0), head);
    try testing.expectEqual(@as(i32, 0), tail);
}

test "AIL_init_sample return-class version split: void (<=7) vs S32 (8+)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    // Pre-8.0 form is void (the table exports AIL_init_sample@4 through v6.6,
    // and AIL_init_sample_v7@12 at v7).
    dg.AIL_init_sample(s);
    // MSS 8.0 changed it to S32 init_sample(HSAMPLE, S32 format) -> 1 on success,
    // 0 on a null handle (the table exports AIL_init_sample_v8@8 from 8.0 on).
    try testing.expectEqual(@as(i32, 1), dg.AIL_init_sample_v8(s, 0));
    try testing.expectEqual(@as(i32, 0), dg.AIL_init_sample_v8(null, 0));
}

test "AIL_set/sample_buffer_count validates [2,8] and round-trips" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    // Default after init -> 2 (SDK AIL_init_sample calls set_sample_buffer_count(S,2)).
    try testing.expectEqual(@as(i32, 2), api_v8b.AIL_sample_buffer_count(s));
    // Valid count -> stored, setter returns 1.
    try testing.expectEqual(@as(i32, 1), api_v8b.AIL_set_sample_buffer_count(s, 4));
    try testing.expectEqual(@as(i32, 4), api_v8b.AIL_sample_buffer_count(s));
    // Out-of-range -> rejected (0), count unchanged.
    try testing.expectEqual(@as(i32, 0), api_v8b.AIL_set_sample_buffer_count(s, 1));
    try testing.expectEqual(@as(i32, 0), api_v8b.AIL_set_sample_buffer_count(s, 9));
    try testing.expectEqual(@as(i32, 4), api_v8b.AIL_sample_buffer_count(s));
}

test "AIL_stream_filled_percent is 1.0 for a loaded (preloaded) stream" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try testing.expectEqual(@as(f32, 0.0), api_v9.AIL_stream_filled_percent(s)); // not loaded yet
    try s.loadFromMemory(wav, false);
    try testing.expectEqual(@as(f32, 1.0), api_v9.AIL_stream_filled_percent(s)); // preloaded
    try testing.expectEqual(@as(f32, 0.0), api_v9.AIL_stream_filled_percent(null));
}

test "AIL_file_type_named delegates to file_type, special-cases voice suffixes" {
    const allocator = testing.allocator;
    const pcm = [_]u8{0} ** 16;
    const wav = try openmiles.buildWavFromPcm(allocator, &pcm, 1, 8000, 16);
    defer allocator.free(wav);
    // No special suffix -> delegates to AIL_file_type(data) -> PCM_WAV (1).
    try testing.expectEqual(@as(i32, 1), api_v8b.AIL_file_type_named(@ptrCast(wav.ptr), "sound.wav", @intCast(wav.len)));
    // All six voice suffixes (case-insensitive) short-circuit, ignoring the data.
    try testing.expectEqual(@as(i32, 17), api_v8b.AIL_file_type_named(@ptrCast(wav.ptr), "voice.v12", @intCast(wav.len)));
    try testing.expectEqual(@as(i32, 18), api_v8b.AIL_file_type_named(@ptrCast(wav.ptr), "voice.V24", @intCast(wav.len)));
    try testing.expectEqual(@as(i32, 19), api_v8b.AIL_file_type_named(@ptrCast(wav.ptr), "voice.v29", @intCast(wav.len)));
    try testing.expectEqual(@as(i32, 21), api_v8b.AIL_file_type_named(@ptrCast(wav.ptr), "v.Speex8", @intCast(wav.len)));
    try testing.expectEqual(@as(i32, 22), api_v8b.AIL_file_type_named(@ptrCast(wav.ptr), "v.speex16", @intCast(wav.len)));
    try testing.expectEqual(@as(i32, 23), api_v8b.AIL_file_type_named(@ptrCast(wav.ptr), "v.SPEEX32", @intCast(wav.len)));
    // .speex16 must not be shadowed by the .speex8/.speex32 checks (distinct suffixes).
    try testing.expectEqual(@as(i32, 22), api_v8b.AIL_file_type_named(null, "track.speex16", 0));
    // Null data, no special suffix -> 0 (UNKNOWN).
    try testing.expectEqual(@as(i32, 0), api_v8b.AIL_file_type_named(null, "x.bin", 0));
}

test "AIL_sample_loaded_len reports remaining unplayed bytes" {
    const s = try loadedSample(testing.allocator, 16000, 1, 8000); // mono16 -> 8000 frames
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();
    // Whole sample loaded, cursor at 0 -> 8000 frames * 2 bytes = 16000.
    try testing.expectEqual(@as(i32, 16000), api_v9.AIL_sample_loaded_len(s));
    // Seek to the middle (byte 8000 -> frame 4000) -> 4000 frames remaining = 8000 bytes.
    dg.AIL_set_sample_position(s, 8000);
    try testing.expectEqual(@as(i32, 8000), api_v9.AIL_sample_loaded_len(s));
    // Null -> 0.
    try testing.expectEqual(@as(i32, 0), api_v9.AIL_sample_loaded_len(null));
}

test "AIL_sample_ms_lookup converts ms to a byte position (SDK)" {
    const s = try loadedSample(testing.allocator, 8000, 1, 8000); // 8000 Hz mono16, bpf=2
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();
    // datarate = 8000 * 2 = 16000 bytes/sec; 1000 ms -> 16000 bytes.
    var actual: i32 = 0;
    try testing.expectEqual(@as(u32, 16000), api_v9.AIL_sample_ms_lookup(s, 1000, &actual));
    try testing.expectEqual(@as(i32, 1000), actual); // actualms = the input
    // 250 ms -> 4000 bytes.
    try testing.expectEqual(@as(u32, 4000), api_v9.AIL_sample_ms_lookup(s, 250, null));
    // Null sample -> ~0U.
    try testing.expectEqual(~@as(u32, 0), api_v9.AIL_sample_ms_lookup(null, 100, null));
}

test "ms_position uses the effective playback rate (rate*factor) round-trip" {
    const s = try loadedSample(testing.allocator, 32000, 1, 8000); // 16000 mono-16 frames
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();

    // Play at 2x native (16000 Hz). 500 ms of output -> 8000 source frames.
    dg.AIL_set_sample_playback_rate(s, 16000);
    s.setMsPosition(500);
    const p = s.getMsPosition();
    try testing.expect(@abs(p.current - 500) <= 2); // round-trips at the effective rate
    // total is the playback DURATION at the effective rate: 16000 frames / 16000 Hz
    // = 1000 ms (a 2-second native sample plays in 1 s at 2x), not the 2000 ms it
    // would report at the native rate.
    try testing.expect(@abs(p.total - 1000) <= 2);
    var cursor: u64 = 0;
    _ = openmiles.ma.ma_sound_get_cursor_in_pcm_frames(&s.sound, &cursor);
    try testing.expect(cursor >= 7990 and cursor <= 8010); // ~8000 source frames
}

test "AIL_set_sample_position rounds to the granularity boundary (SDK)" {
    const s = try loadedSample(testing.allocator, 4096, 2, 44100); // stereo16, bpf=4
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();
    // 102 rounds to the nearest 4-byte boundary -> 104 (frame 26), not 100.
    dg.AIL_set_sample_position(s, 102);
    try testing.expectEqual(@as(u32, 104), dg.AIL_sample_position(s));
    // An aligned offset is unchanged.
    dg.AIL_set_sample_position(s, 200);
    try testing.expectEqual(@as(u32, 200), dg.AIL_sample_position(s));
}

test "AIL_start_sample rewinds to the beginning (SDK buf[tail].pos = 0)" {
    // SDK AIL_API_start_sample resets position to 0 before playing -- it does
    // not continue from where the sample was (that is AIL_resume_sample's job).
    const s = try loadedSample(testing.allocator, 4096, 2, 44100);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();

    dg.AIL_set_sample_position(s, 200); // seek partway in
    try testing.expectEqual(@as(u32, 200), dg.AIL_sample_position(s));
    dg.AIL_start_sample(s); // must rewind to 0
    try testing.expectEqual(@as(u32, 0), dg.AIL_sample_position(s));
}

test "AIL_sample_granularity returns bytes-per-frame (SDK SS_granularity)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [128]u8 align(2) = [_]u8{0} ** 128;
    // Stereo 16-bit -> granularity 4 (DIG_F_STEREO_16).
    const wav_st = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 2, 44100, 16);
    defer testing.allocator.free(wav_st);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav_st, false);
    try testing.expectEqual(@as(u32, 4), dg.AIL_sample_granularity(s));
    // Mono 16-bit -> granularity 2.
    const wav_mono = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav_mono);
    const s2 = try openmiles.Sample.init(drv);
    defer s2.deinit();
    try s2.loadFromMemory(wav_mono, false);
    try testing.expectEqual(@as(u32, 2), dg.AIL_sample_granularity(s2));
    // Null handle -> 0.
    try testing.expectEqual(@as(u32, 0), dg.AIL_sample_granularity(null));
}

test "AIL_set_sample_info channel_mask round-trips via channel_count" {
    if (!@hasField(openmiles.AILSOUNDINFO, "channel_mask")) return; // v8+ field only
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    var info: openmiles.AILSOUNDINFO = .{};
    info.channels = 2;
    info.bits = 16;
    info.channel_mask = 0x3; // explicit FL|FR
    try testing.expectEqual(@as(i32, 1), api_v7.AIL_set_sample_info(s, &info)); // SDK: 1 on success
    var mask: u32 = 0;
    _ = api_v8b.AIL_sample_channel_count(s, &mask);
    try testing.expectEqual(@as(u32, 0x3), mask);
    // Null sample returns 0 (SDK guard).
    try testing.expectEqual(@as(i32, 0), api_v7.AIL_set_sample_info(null, &info));
}

test "AIL_set_sample_info channel-count selection matches per-version SDK logic" {
    // Verified by disassembling AIL_API_set_sample_info: v8/v9 preserve the true
    // channel count for >2 channels (multichannel path), while v7 and earlier have
    // no multichannel path and downgrade anything that isn't exactly 2 to mono.
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();

    var info: openmiles.AILSOUNDINFO = .{};
    info.bits = 16;

    // 1 channel -> mono on every version.
    info.channels = 1;
    _ = api_v7.AIL_set_sample_info(s, &info);
    try testing.expectEqual(@as(u16, 1), s.pcm_format.?.channels);

    // 2 channels -> stereo on every version.
    info.channels = 2;
    _ = api_v7.AIL_set_sample_info(s, &info);
    try testing.expectEqual(@as(u16, 2), s.pcm_format.?.channels);

    // 6 channels (5.1): v8+ preserves the count (multichannel); v7 falls back to
    // mono because only exactly-2 is treated as stereo there.
    info.channels = 6;
    _ = api_v7.AIL_set_sample_info(s, &info);
    if (@hasField(openmiles.AILSOUNDINFO, "channel_mask")) {
        try testing.expectEqual(@as(u16, 6), s.pcm_format.?.channels);
    } else {
        try testing.expectEqual(@as(u16, 1), s.pcm_format.?.channels);
    }
}

test "AIL_sample_playback_rate defaults to 11025 on a fresh, unloaded sample" {
    // SDK AIL_API_init_sample seeds S->original_playback_rate = 11025, and the
    // getter returns that field verbatim. A freshly allocated+init'd sample that
    // has not loaded a file and has no app-set rate must therefore report 11025,
    // not the device/mixer rate. Loading a file overwrites it with the native rate.
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try testing.expectEqual(@as(i32, 11025), dg.AIL_sample_playback_rate(s));
    // An explicit set still round-trips.
    dg.AIL_set_sample_playback_rate(s, 32000);
    try testing.expectEqual(@as(i32, 32000), dg.AIL_sample_playback_rate(s));
    // Null guard: SDK returns 0.
    try testing.expectEqual(@as(i32, 0), dg.AIL_sample_playback_rate(null));
}

test "AIL_sample_reverb_levels round-trips and zeroes out-params on null" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();

    // Fresh default: dry=1.0, wet=0.0 (SDK init).
    var dry: f32 = -1;
    var wet: f32 = -1;
    api_v7.AIL_sample_reverb_levels(s, &dry, &wet);
    try testing.expectEqual(@as(f32, 1.0), dry);
    try testing.expectEqual(@as(f32, 0.0), wet);

    // Round-trip an explicit set.
    api_v7.AIL_set_sample_reverb_levels(s, 0.7, 0.3);
    api_v7.AIL_sample_reverb_levels(s, &dry, &wet);
    try testing.expectEqual(@as(f32, 0.7), dry);
    try testing.expectEqual(@as(f32, 0.3), wet);

    // Null handle: SDK (AIL_API_sample_reverb_levels) writes 0.0 to BOTH out-
    // params rather than leaving them untouched (unlike the volume getters).
    dry = 9;
    wet = 9;
    api_v7.AIL_sample_reverb_levels(null, &dry, &wet);
    try testing.expectEqual(@as(f32, 0.0), dry);
    try testing.expectEqual(@as(f32, 0.0), wet);
}

test "AIL_set_input_state returns 0 for a null handle (SDK guard)" {
    const api_input = @import("api/input.zig");
    // Null handle: no device needed, deterministic. SDK returns 0.
    try testing.expectEqual(@as(i32, 0), api_input.AIL_set_input_state(null, 1));
    try testing.expectEqual(@as(i32, 0), api_input.AIL_set_input_state(null, 0));
}

test "AIL_size_processed_digital_audio counts points from data_len (SDK)" {
    var info: openmiles.AILSOUNDINFO = .{};
    info.format = 1; // WAVE_FORMAT_PCM
    info.bits = 16;
    info.channels = 1;
    info.rate = 8000;
    info.data_len = 1600; // 800 16-bit mono points

    // Same rate/format (mono 16-bit) -> 800 points * 2 bytes + 256 slop = 1856.
    try testing.expectEqual(@as(i32, 1856), dg.AIL_size_processed_digital_audio(8000, 1, 1, &info));
    // Upsample 2x -> 1600 points * 2 + 256 = 3456.
    try testing.expectEqual(@as(i32, 3456), dg.AIL_size_processed_digital_audio(16000, 1, 1, &info));
    // Stereo 16-bit dest (format 3): point size = 4 -> 800 * 4 + 256 = 3456.
    try testing.expectEqual(@as(i32, 3456), dg.AIL_size_processed_digital_audio(8000, 3, 1, &info));

    // IMA ADPCM source: the SDK counts 2 samples per byte (points <<= 1), unlike
    // the 16-bit PCM path that halves the byte count. 400 ADPCM bytes -> 800
    // mono points; dest mono 16-bit @ same rate -> 800*2 + 256 = 1856 (same as
    // the 1600-byte PCM case above, since 400 nibbles-pairs decode to 800 samples).
    var adpcm: openmiles.AILSOUNDINFO = .{};
    adpcm.format = 0x0011; // WAVE_FORMAT_IMA_ADPCM
    adpcm.bits = 4;
    adpcm.channels = 1;
    adpcm.rate = 8000;
    adpcm.data_len = 400;
    try testing.expectEqual(@as(i32, 1856), dg.AIL_size_processed_digital_audio(8000, 1, 1, &adpcm));
    // Stereo ADPCM: 800 bytes -> 1600 samples, halved for stereo pairs -> 800
    // points; dest stereo 16-bit (format 3, point size 4) -> 800*4 + 256 = 3456.
    adpcm.channels = 2;
    adpcm.data_len = 800;
    try testing.expectEqual(@as(i32, 3456), dg.AIL_size_processed_digital_audio(8000, 3, 1, &adpcm));
}

test "AIL_process_digital_audio mixes PCM sources into the dest buffer" {
    // Two mono 16-bit sources at 8000 Hz; dest mono 16-bit @ 8000 (no resample).
    var a = [_]i16{ 100, 200, 300, 400 };
    var b = [_]i16{ 10, 20, 30, 40 };
    var srcs = [_]openmiles.AILMIXINFO{ .{}, .{} };
    srcs[0].Info = .{ .format = 1, .bits = 16, .channels = 1, .rate = 8000, .data_len = a.len * 2, .data_ptr = @ptrCast(&a) };
    srcs[1].Info = .{ .format = 1, .bits = 16, .channels = 1, .rate = 8000, .data_len = b.len * 2, .data_ptr = @ptrCast(&b) };
    var dest: [4]i16 = .{ 0, 0, 0, 0 };
    const n = dg.AIL_process_digital_audio(@ptrCast(&dest), @intCast(dest.len * 2), 8000, 1, 2, @ptrCast(&srcs));
    // 4 mono 16-bit points -> 8 bytes.
    try testing.expectEqual(@as(i32, 8), n);
    // Each dest sample is the (clamped) sum of the two sources.
    try testing.expectEqual(@as(i16, 110), dest[0]);
    try testing.expectEqual(@as(i16, 220), dest[1]);
    try testing.expectEqual(@as(i16, 330), dest[2]);
    try testing.expectEqual(@as(i16, 440), dest[3]);

    // Output is bounded by dest_size: a 2-point dest takes only the first 2.
    var small: [2]i16 = .{ 0, 0 };
    const n2 = dg.AIL_process_digital_audio(@ptrCast(&small), 4, 8000, 1, 2, @ptrCast(&srcs));
    try testing.expectEqual(@as(i32, 4), n2);
    try testing.expectEqual(@as(i16, 110), small[0]);
    try testing.expectEqual(@as(i16, 220), small[1]);

    // Guards: null dest / null src / zero sources / zero rate all return 0.
    try testing.expectEqual(@as(i32, 0), dg.AIL_process_digital_audio(null, 8, 8000, 1, 2, @ptrCast(&srcs)));
    try testing.expectEqual(@as(i32, 0), dg.AIL_process_digital_audio(@ptrCast(&dest), 8, 8000, 1, 0, @ptrCast(&srcs)));
    try testing.expectEqual(@as(i32, 0), dg.AIL_process_digital_audio(@ptrCast(&dest), 8, 0, 1, 2, @ptrCast(&srcs)));
}

test "AIL_process_digital_audio frees a decode buffer of a source that runs out mid-mix" {
    // An 8-bit source is promoted to an owned 16-bit buffer the mixer frees
    // itself. Sources are dropped from the mix partitions the moment they
    // exhaust, so a short one leaves the partitions before the sweep that frees
    // the buffers runs: without a free at the drop the buffer leaks once per
    // mix call, on the caller's most repeated path.
    const saved = openmiles.global_allocator;
    openmiles.global_allocator = testing.allocator;
    defer openmiles.global_allocator = saved;

    // Long 16-bit source sets the output length; the short 8-bit one exhausts
    // after 2 points and is dropped from the partition.
    var long_src = [_]i16{ 1, 1, 1, 1, 1, 1, 1, 1 };
    var short_u8 = [_]u8{ 128, 128, 128, 128 };
    var srcs = [_]openmiles.AILMIXINFO{ .{}, .{} };
    srcs[0].Info = .{ .format = 1, .bits = 16, .channels = 1, .rate = 8000, .data_len = long_src.len * 2, .data_ptr = @ptrCast(&long_src) };
    srcs[1].Info = .{ .format = 1, .bits = 8, .channels = 1, .rate = 8000, .data_len = short_u8.len, .data_ptr = @ptrCast(&short_u8) };
    var dest: [8]i16 = .{ 0, 0, 0, 0, 0, 0, 0, 0 };
    // Output runs to the long source's 8 points, so the 4-point 8-bit source
    // is dropped partway through.
    const n = dg.AIL_process_digital_audio(@ptrCast(&dest), @intCast(dest.len * 2), 8000, 1, 2, @ptrCast(&srcs));
    try testing.expectEqual(@as(i32, 16), n);
}

test "AIL_process_digital_audio widens 8-bit sources over the prefix it reaches" {
    // An 8-bit source is widened to (v - 128) << 8. Only the samples the mix
    // reaches are converted, so a source longer than the output must still
    // produce the same samples, and a resampled one must pick the same source
    // points the cursor names.
    const ramp = [_]u8{ 128, 129, 130, 200, 0, 255, 128, 128, 140, 150, 160, 170, 180, 190, 200, 210 };
    var srcs = [_]openmiles.AILMIXINFO{.{}};
    srcs[0].Info = .{ .format = 1, .bits = 8, .channels = 1, .rate = 8000, .data_len = ramp.len, .data_ptr = @ptrCast(&ramp) };

    // A dest shorter than the source reaches only the leading points.
    var short_dest: [4]i16 = undefined;
    const short_n = dg.AIL_process_digital_audio(@ptrCast(&short_dest), @intCast(short_dest.len * 2), 8000, 1, 1, @ptrCast(&srcs));
    try testing.expectEqual(@as(i32, 8), short_n);
    for (short_dest, 0..) |v, k| {
        try testing.expectEqual(@as(i16, (@as(i16, ramp[k]) - 128) << 8), v);
    }

    // The whole source, when the output reaches all of it.
    var full_dest: [ramp.len]i16 = undefined;
    const full_n = dg.AIL_process_digital_audio(@ptrCast(&full_dest), @intCast(full_dest.len * 2), 8000, 1, 1, @ptrCast(&srcs));
    try testing.expectEqual(@as(i32, @as(i32, @intCast(ramp.len * 2))), full_n);
    for (full_dest, 0..) |v, k| {
        try testing.expectEqual(@as(i16, (@as(i16, ramp[k]) - 128) << 8), v);
    }

    // Upsampled 2:1, so output frame j reads source point 2j and the reached
    // prefix runs past half the source.
    var up_srcs = [_]openmiles.AILMIXINFO{.{}};
    up_srcs[0].Info = .{ .format = 1, .bits = 8, .channels = 1, .rate = 16000, .data_len = ramp.len, .data_ptr = @ptrCast(&ramp) };
    var up: [8]i16 = undefined;
    const up_n = dg.AIL_process_digital_audio(@ptrCast(&up), @intCast(up.len * 2), 8000, 1, 1, @ptrCast(&up_srcs));
    try testing.expectEqual(@as(i32, 16), up_n);
    for (up, 0..) |v, j| {
        try testing.expectEqual(@as(i16, (@as(i16, ramp[j * 2]) - 128) << 8), v);
    }
}

test "AIL_process_digital_audio resamples at floor(j*src_rate/dest_rate)" {
    // Mono 16-bit ramp source at 11025 Hz into an 8000 Hz mono dest. Output
    // frame j must take source point floor(j*11025/8000) — the nearest-
    // neighbour mapping the SDK mixer uses. Pins the division-free cursor
    // against the closed form; the second source has no data (zero points)
    // and must contribute nothing.
    var src: [64]i16 = undefined;
    for (&src, 0..) |*v, k| v.* = @intCast(k);
    var srcs = [_]openmiles.AILMIXINFO{ .{}, .{} };
    srcs[0].Info = .{ .format = 1, .bits = 16, .channels = 1, .rate = 11025, .data_len = src.len * 2, .data_ptr = @ptrCast(&src) };
    var dest: [32]i16 = undefined;
    const n = dg.AIL_process_digital_audio(@ptrCast(&dest), @intCast(dest.len * 2), 8000, 1, 2, @ptrCast(&srcs));
    // 32 mono 16-bit points -> 64 bytes (bounded by dest_size, not the
    // source's 46-point resampled length).
    try testing.expectEqual(@as(i32, 64), n);
    for (dest, 0..) |v, j| {
        const want: i16 = @intCast(j * 11025 / 8000);
        try testing.expectEqual(want, v);
    }
}

test "AIL_size_processed_digital_audio takes the max over multiple sources (SDK)" {
    // Two AILMIXINFO sources; the function sizes for the largest after resampling.
    var srcs = [_]openmiles.AILMIXINFO{ .{}, .{} };
    srcs[0].Info = .{ .format = 1, .bits = 16, .channels = 1, .rate = 8000, .data_len = 1600 }; // 800 pts
    srcs[1].Info = .{ .format = 1, .bits = 16, .channels = 1, .rate = 8000, .data_len = 4000 }; // 2000 pts (max)
    // dest mono 16-bit @ 8000: 2000 * 2 + 256 = 4256.
    try testing.expectEqual(@as(i32, 4256), dg.AIL_size_processed_digital_audio(8000, 1, 2, &srcs));
    // Order independent: same result with the larger source first.
    const tmp = srcs[0];
    srcs[0] = srcs[1];
    srcs[1] = tmp;
    try testing.expectEqual(@as(i32, 4256), dg.AIL_size_processed_digital_audio(8000, 1, 2, &srcs));
}

test "Redbook init deinit and default state" {
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator);
    defer rb.deinit();

    try testing.expectEqual(openmiles.RedbookStatus.stopped, rb.status);
    try testing.expectEqual(@as(u32, 0), rb.current_track);
    try testing.expectEqual(@as(u32, 127), rb.volume);
    try testing.expectEqual(@as(u32, 0), rb.trackCount());
}

test "Redbook play sets playing state" {
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator);
    defer rb.deinit();

    rb.play(1, 5);
    try testing.expectEqual(openmiles.RedbookStatus.playing, rb.status);
    // AIL_redbook_play takes ms offsets, not a track number: the track stays 0
    // (the emulated drive has none) and the position starts at the offset.
    try testing.expectEqual(@as(u32, 0), rb.current_track);
    try testing.expectEqual(@as(u32, 5), rb.track_end);
    try testing.expect(rb.getPosition() >= 1);
}

test "Redbook stop resets state" {
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator);
    defer rb.deinit();

    rb.play(3, 10);
    rb.stop();
    try testing.expectEqual(openmiles.RedbookStatus.stopped, rb.status);
    try testing.expectEqual(@as(u32, 0), rb.current_track);
    try testing.expectEqual(@as(u32, 0), rb.getPosition());
}

test "Redbook pause and resume lifecycle" {
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator);
    defer rb.deinit();

    rb.pause();
    try testing.expectEqual(openmiles.RedbookStatus.stopped, rb.status);

    rb.play(1, 5);
    rb.pause();
    try testing.expectEqual(openmiles.RedbookStatus.paused, rb.status);

    rb.resumePlayback();
    try testing.expectEqual(openmiles.RedbookStatus.playing, rb.status);

    rb.resumePlayback();
    try testing.expectEqual(openmiles.RedbookStatus.playing, rb.status);
}

test "Redbook getPosition returns 0 when stopped" {
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator);
    defer rb.deinit();

    try testing.expectEqual(@as(u32, 0), rb.getPosition());
}

test "Redbook getPosition advances during playback" {
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator);
    defer rb.deinit();

    rb.play(1, 5);
    // Poll until the position ticks (bounded): robust to a swallowed sleep
    // error, still fails if playback never advances the position.
    var pos: u32 = 0;
    var waited: u32 = 0;
    while (pos == 0 and waited < 5000) : (waited += 10) {
        pos = rb.getPosition();
        if (pos > 0) break;
        openmiles.io.sleep(std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
    }
    try testing.expect(pos > 0);
}

test "Redbook paused position is stable" {
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator);
    defer rb.deinit();

    rb.play(1, 5);
    // Let some playback elapse, then pause; a paused redbook reports the frozen
    // pause-time position, so two later reads must be identical.
    var waited: u32 = 0;
    while (rb.getPosition() == 0 and waited < 5000) : (waited += 10) {
        openmiles.io.sleep(std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
    }
    rb.pause();
    const p1 = rb.getPosition();
    try testing.expect(p1 > 0);
    openmiles.io.sleep(std.Io.Duration.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
    const p2 = rb.getPosition();
    try testing.expectEqual(p1, p2);
}

test "buildAdpcmWav mono produces valid RIFF header" {
    const allocator = testing.allocator;
    const pcm = [_]i16{ 0, 100, -100, 200, -200, 300, -300, 400 };
    const wav = try openmiles.buildAdpcmWav(allocator, &pcm, pcm.len, 1, 22050);
    defer allocator.free(wav);

    try testing.expectEqualStrings("RIFF", wav[0..4]);
    try testing.expectEqualStrings("WAVE", wav[8..12]);
    try testing.expectEqualStrings("fmt ", wav[12..16]);

    const format_tag = std.mem.readInt(u16, wav[20..22], .little);
    try testing.expectEqual(@as(u16, 0x0011), format_tag);

    const channels = std.mem.readInt(u16, wav[22..24], .little);
    try testing.expectEqual(@as(u16, 1), channels);

    const rate = std.mem.readInt(u32, wav[24..28], .little);
    try testing.expectEqual(@as(u32, 22050), rate);
}

test "buildAdpcmWav stereo produces valid RIFF header" {
    const allocator = testing.allocator;
    const pcm = [_]i16{ 0, 0, 100, -100, 200, -200, 300, -300 };
    const wav = try openmiles.buildAdpcmWav(allocator, &pcm, pcm.len / 2, 2, 44100);
    defer allocator.free(wav);

    try testing.expectEqualStrings("RIFF", wav[0..4]);
    try testing.expectEqualStrings("WAVE", wav[8..12]);

    const format_tag = std.mem.readInt(u16, wav[20..22], .little);
    try testing.expectEqual(@as(u16, 0x0011), format_tag);

    const channels = std.mem.readInt(u16, wav[22..24], .little);
    try testing.expectEqual(@as(u16, 2), channels);
}

test "buildAdpcmWav zero channels returns error" {
    const allocator = testing.allocator;
    const pcm = [_]i16{0};
    try testing.expectError(error.InvalidParam, openmiles.buildAdpcmWav(allocator, &pcm, 1, 0, 22050));
}

test "buildAdpcmWav contains fact and data chunks" {
    const allocator = testing.allocator;
    const pcm = [_]i16{ 0, 100, -100, 200 };
    const wav = try openmiles.buildAdpcmWav(allocator, &pcm, pcm.len, 1, 22050);
    defer allocator.free(wav);

    var found_fact = false;
    var found_data = false;
    var i: usize = 12;
    while (i + 8 <= wav.len) {
        const chunk_id = wav[i .. i + 4];
        const chunk_size = std.mem.readInt(u32, wav[i + 4 ..][0..4], .little);
        if (std.mem.eql(u8, chunk_id, "fact")) found_fact = true;
        if (std.mem.eql(u8, chunk_id, "data")) found_data = true;
        i += 8 + chunk_size;
    }
    try testing.expect(found_fact);
    try testing.expect(found_data);
}

test "Timer init deinit and default properties" {
    const dummy_cb = struct {
        fn cb(_: u32) callconv(.winapi) void {}
    }.cb;
    const allocator = testing.allocator;
    const timer = try openmiles.Timer.init(allocator, dummy_cb);

    try testing.expectEqual(@as(u32, 10000), timer.getPeriodUs());
    try testing.expectEqual(@as(u32, 0), timer.getUserData());
    try testing.expect(!timer.is_running);

    timer.deinit();
}

test "Timer setPeriodUs and setUserData" {
    const dummy_cb = struct {
        fn cb(_: u32) callconv(.winapi) void {}
    }.cb;
    const allocator = testing.allocator;
    const timer = try openmiles.Timer.init(allocator, dummy_cb);
    defer timer.deinit();

    timer.setPeriodUs(5000);
    try testing.expectEqual(@as(u32, 5000), timer.getPeriodUs());

    timer.setUserData(42);
    try testing.expectEqual(@as(u32, 42), timer.getUserData());
}

test "AIL_set_timer_frequency/period/divisor convert to the right period (SDK)" {
    const api_timer = @import("api/timer.zig");
    const dummy_cb = struct {
        fn cb(_: u32) callconv(.winapi) void {}
    }.cb;
    const timer = try openmiles.Timer.init(testing.allocator, dummy_cb);
    defer timer.deinit();

    // frequency: SDK genericmss.cpp -> set_timer_period(1000000 / hertz).
    api_timer.AIL_set_timer_frequency(timer, 1000); // 1000 Hz -> 1000 us
    try testing.expectEqual(@as(u32, 1000), timer.getPeriodUs());
    api_timer.AIL_set_timer_frequency(timer, 60); // 60 Hz -> 16666 us
    try testing.expectEqual(@as(u32, 16666), timer.getPeriodUs());

    // period: microseconds verbatim.
    api_timer.AIL_set_timer_period(timer, 4000);
    try testing.expectEqual(@as(u32, 4000), timer.getPeriodUs());

    // divisor: legacy 8254 PIT, period = divisor / 1193180 s. 1193 ticks ~ 999 us.
    api_timer.AIL_set_timer_divisor(timer, 1193);
    try testing.expectEqual(@as(u32, 1193 * 1_000_000 / 1_193_180), timer.getPeriodUs());
    // Divisor 0 means 65536 (full PIT reload) ~ 54925 us.
    api_timer.AIL_set_timer_divisor(timer, 0);
    try testing.expectEqual(@as(u32, 65536 * 1_000_000 / 1_193_180), timer.getPeriodUs());

    // A rate above 1 MHz (and a zero period) truncate to a 0 us period, which
    // would leave the run loop with an empty sleep slice; the floor keeps the
    // loop sleeping instead of spinning the callback at full speed.
    api_timer.AIL_set_timer_frequency(timer, 2_000_000);
    try testing.expectEqual(openmiles.Timer.min_period_us, timer.getPeriodUs());
    api_timer.AIL_set_timer_period(timer, 0);
    try testing.expectEqual(openmiles.Timer.min_period_us, timer.getPeriodUs());

    // Null timer: all are no-ops (no crash).
    api_timer.AIL_set_timer_frequency(null, 100);
    api_timer.AIL_set_timer_period(null, 100);
    api_timer.AIL_set_timer_divisor(null, 100);
}

test "Timer start and stop lifecycle" {
    var called = std.atomic.Value(u32).init(0);
    const State = struct {
        var flag: *std.atomic.Value(u32) = undefined;
    };
    State.flag = &called;
    const cb = struct {
        fn f(_: u32) callconv(.winapi) void {
            _ = State.flag.fetchAdd(1, .monotonic);
        }
    }.f;
    const allocator = testing.allocator;
    const timer = try openmiles.Timer.init(allocator, cb);
    defer timer.deinit();

    timer.setPeriodUs(1000);
    timer.start();
    try testing.expect(timer.is_running);

    // The callback runs on its own thread; poll for the first fire (generous
    // window, same pattern as the self-stopping timer test) instead of trusting
    // a fixed sleep on a possibly loaded machine.
    var waited: u32 = 0;
    while (called.load(.monotonic) == 0 and waited < 5000) : (waited += 10) {
        openmiles.io.sleep(std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
    }
    timer.stop();
    try testing.expect(!timer.is_running);

    try testing.expect(called.load(.monotonic) > 0);
}

test "Timer double start is idempotent" {
    const dummy_cb = struct {
        fn cb(_: u32) callconv(.winapi) void {}
    }.cb;
    const allocator = testing.allocator;
    const timer = try openmiles.Timer.init(allocator, dummy_cb);
    defer timer.deinit();

    timer.start();
    timer.start();
    try testing.expect(timer.is_running);
    timer.stop();
    try testing.expect(!timer.is_running);
}

test "Timer double stop is safe" {
    // The risk a second stop carries is not the flag it leaves behind but the
    // state it leaves the loop in, so the timer is started again afterwards:
    // a stop that tore down the thread while the first was still joining it
    // leaves a timer that reports stopped and never runs again.
    var called = std.atomic.Value(u32).init(0);
    const State = struct {
        var flag: *std.atomic.Value(u32) = undefined;
    };
    State.flag = &called;
    const cb = struct {
        fn f(_: u32) callconv(.winapi) void {
            _ = State.flag.fetchAdd(1, .monotonic);
        }
    }.f;
    const allocator = testing.allocator;
    const timer = try openmiles.Timer.init(allocator, cb);
    defer timer.deinit();

    timer.stop();
    timer.stop();
    try testing.expect(!timer.is_running);

    timer.setPeriodUs(1000);
    timer.start();
    try testing.expect(timer.is_running);
    var waited: u32 = 0;
    while (called.load(.monotonic) == 0 and waited < 5000) : (waited += 10) {
        openmiles.io.sleep(std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
    }
    timer.stop();
    try testing.expect(!timer.is_running);
    try testing.expect(called.load(.monotonic) > 0);
}

test "Timer concurrent start/stop never runs overlapping loops" {
    // Detector for the double-spawn race: two threads passing the is_running
    // check simultaneously used to spawn two run loops, which fire the
    // callback concurrently (plus one leaked thread handle). A single loop can
    // never overlap itself, so any nonzero entry count is a proven race.
    const CB = struct {
        var active: std.atomic.Value(u32) = .init(0);
        var overlapped: std.atomic.Value(bool) = .init(false);
        fn cb(_: u32) callconv(.winapi) void {
            if (active.fetchAdd(1, .acq_rel) != 0) overlapped.store(true, .release);
            var spins: u32 = 0;
            while (spins < 200) : (spins += 1) std.atomic.spinLoopHint();
            _ = active.fetchSub(1, .acq_rel);
        }
        fn worker(t: *openmiles.Timer) void {
            for (0..200) |_| {
                t.start();
                t.stop();
            }
        }
    };
    const timer = try openmiles.Timer.init(openmiles.global_allocator, CB.cb);
    defer timer.deinit();

    var handles: [4]std.Thread = undefined;
    for (&handles) |*h| h.* = try std.Thread.spawn(.{}, CB.worker, .{timer});
    for (handles) |h| h.join();

    try testing.expect(!CB.overlapped.load(.acquire));
    try testing.expect(!timer.is_running);
}

test "Timer restart while a self-stopped callback is still running keeps one loop" {
    // A self-stop from inside the callback cannot join its own thread, so the
    // run loop is still alive (and its handle still owned by the Timer) when the
    // callback returns. Starting again at that moment used to spawn a second
    // loop over the old handle: both fired the callback concurrently, the old
    // handle was never joined, and deinit() freed the struct under the old loop.
    const CB = struct {
        var timer: *openmiles.Timer = undefined;
        var active: std.atomic.Value(u32) = .init(0);
        var overlapped: std.atomic.Value(bool) = .init(false);
        var restart_issued: std.atomic.Value(bool) = .init(false);
        var once: std.atomic.Value(bool) = .init(false);
        var fired: std.atomic.Value(u32) = .init(0);

        fn cb(_: u32) callconv(.winapi) void {
            if (active.fetchAdd(1, .acq_rel) != 0) overlapped.store(true, .release);
            _ = fired.fetchAdd(1, .monotonic);
            // First fire: stop from inside the callback, then block until the
            // other thread has asked for a restart. The restart is issued
            // before it calls start(), so the callback is still running when
            // start() runs: exactly the window the fix covers.
            if (!once.swap(true, .acq_rel)) {
                timer.stop();
                while (!restart_issued.load(.acquire)) std.atomic.spinLoopHint();
            }
            _ = active.fetchSub(1, .acq_rel);
        }

        fn restarter() void {
            // Wait for the self-stop to have landed, not merely for the first
            // fire: `fired` is bumped before the callback reaches stop(), so a
            // restart issued on that alone can beat the stop. start() would then
            // see the timer still running, return without respawning, and the
            // callback's own stop() would clear is_running for good — the
            // "timer is still running" assertion below reads false while the
            // library did exactly what it was asked. is_running cleared with
            // `fired` set is the window this test covers: the callback has
            // self-stopped and has not returned yet.
            while (fired.load(.monotonic) == 0 or @atomicLoad(bool, &timer.is_running, .acquire)) std.atomic.spinLoopHint();
            restart_issued.store(true, .release);
            timer.start();
        }
    };
    const timer = try openmiles.Timer.init(openmiles.global_allocator, CB.cb);
    defer timer.deinit();
    CB.timer = timer;
    timer.setPeriodUs(200);

    const helper = try std.Thread.spawn(.{}, CB.restarter, .{});
    timer.start();
    helper.join();

    try testing.expect(!CB.overlapped.load(.acquire));
    try testing.expect(timer.is_running);
    // The single surviving loop still ticks after the handover.
    const before = CB.fired.load(.monotonic);
    var waited: u32 = 0;
    while (CB.fired.load(.monotonic) == before and waited < 5000) : (waited += 10) {
        openmiles.io.sleep(std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
    }
    try testing.expect(CB.fired.load(.monotonic) > before);
}

test "Timer restart from inside its own callback resumes the same loop" {
    // start() from the callback cannot join the thread it is running on, so it
    // must resume the existing loop instead of spawning a second one. Before
    // the retire branch existed this either spawned a second loop or blocked on
    // state_mutex forever; either way the single surviving loop is the one the
    // callback returns into.
    const CB = struct {
        var timer: *openmiles.Timer = undefined;
        var fires: std.atomic.Value(u32) = .init(0);
        var active: std.atomic.Value(u32) = .init(0);
        var overlapped: std.atomic.Value(bool) = .init(false);

        fn cb(_: u32) callconv(.winapi) void {
            if (active.fetchAdd(1, .acq_rel) != 0) overlapped.store(true, .release);
            const n = fires.fetchAdd(1, .monotonic);
            // First fire: stop and start again from the callback itself.
            if (n == 0) {
                timer.stop();
                timer.start();
            }
            _ = active.fetchSub(1, .acq_rel);
        }
    };
    const timer = try openmiles.Timer.init(openmiles.global_allocator, CB.cb);
    defer timer.deinit();
    CB.timer = timer;
    timer.setPeriodUs(200);
    timer.start();

    const before = CB.fires.load(.monotonic);
    var waited: u32 = 0;
    while (CB.fires.load(.monotonic) < before + 3 and waited < 5000) : (waited += 10) {
        openmiles.io.sleep(std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
    }
    try testing.expect(CB.fires.load(.monotonic) >= before + 3);
    try testing.expect(!CB.overlapped.load(.acquire));
}

test "virtual clock replays a timer run from its step sequence" {
    // The point of the virtual clock: the callback sequence and the timestamps
    // it sees come from the steps taken, not from how fast the host is. The
    // same steps replay to the same trace, and no wall time is spent.
    const Recorder = struct {
        var stamps: [8]i64 = undefined;
        var count: u32 = 0;
        fn cb(_: u32) callconv(.winapi) void {
            if (count < stamps.len) {
                stamps[count] = openmiles.nowNs();
                count += 1;
            }
        }
        fn reset() void {
            count = 0;
        }
    };
    const periods = [_]u32{ 1000, 1000, 2500, 1000, 1000, 1000, 1000, 1000 };
    var first: [8]i64 = undefined;
    var second: [8]i64 = undefined;

    for (0..2) |replay| {
        openmiles.useVirtualClock(0);
        defer openmiles.useRealClock();
        Recorder.reset();

        const timer = try openmiles.Timer.init(testing.allocator, Recorder.cb);
        defer timer.deinit();

        // Counters are re-based on the virtual epoch, not on process start.
        try testing.expectEqual(@as(u32, 0), openmiles.getMsCount());

        timer.start();
        // No thread under a virtual clock: the steps below are the whole run.
        try testing.expectEqual(@as(?std.Thread, null), timer.thread);
        for (periods) |us| {
            timer.setPeriodUs(us);
            timer.tick();
        }
        timer.stop();
        try testing.expectEqual(@as(u32, periods.len), Recorder.count);
        @memcpy(if (replay == 0) &first else &second, &Recorder.stamps);
    }

    // Each stamp is the sum of the periods before it, exactly.
    var expected: i64 = 0;
    for (periods, 0..) |us, i| {
        try testing.expectEqual(expected, first[i]);
        expected += @as(i64, us) * std.time.ns_per_us;
    }
    try testing.expectEqualSlices(i64, &first, &second);
}

test "tickAllTimers steps every registered timer and is inert on the real clock" {
    // A simulation that starts the whole timer set has no thread to wait on,
    // so tickAllTimers is the only way its callbacks fire.
    const Recorder = struct {
        var fired: u32 = 0;
        var stamps: [4]i64 = undefined;
        fn cb(_: u32) callconv(.winapi) void {
            if (fired < stamps.len) stamps[fired] = openmiles.nowNs();
            fired += 1;
        }
    };

    openmiles.useVirtualClock(0);
    defer openmiles.useRealClock();
    Recorder.fired = 0;

    const fast = try openmiles.Timer.init(testing.allocator, Recorder.cb);
    defer fast.deinit();
    const slow = try openmiles.Timer.init(testing.allocator, Recorder.cb);
    defer slow.deinit();
    fast.setPeriodUs(1000);
    slow.setPeriodUs(4000);

    openmiles.startAllTimers();
    try testing.expectEqual(@as(?std.Thread, null), fast.thread);
    try testing.expectEqual(@as(i64, 0), openmiles.nowNs());

    // Registered after the start, so it is running-free: a step must not fire
    // a timer nobody started.
    const idle = try openmiles.Timer.init(testing.allocator, Recorder.cb);
    defer idle.deinit();
    idle.setPeriodUs(1000);

    // Deltas, not absolutes: an earlier test that left a timer registered
    // would be stepped by the same call, and this test pins the periods it
    // started itself rather than the whole registry's total.
    const t0 = openmiles.nowNs();
    openmiles.tickAllTimers();
    // Two running timers fired once each, and time moved by the sum of their
    // periods, not by the wall time the step took.
    try testing.expectEqual(@as(u32, 2), Recorder.fired);
    try testing.expectEqual(@as(i64, 5_000_000), openmiles.nowNs() - t0);
    // Each callback sees the time as it stood at its own step, in registration
    // order: the first reads 0, the second the period the first advanced. The
    // whole step is the sum of the two periods, with no wall time in it.
    try testing.expectEqualSlices(i64, &.{ t0, t0 + 1_000_000 }, Recorder.stamps[0..2]);

    const t1 = openmiles.nowNs();
    openmiles.tickAllTimers();
    try testing.expectEqual(@as(u32, 4), Recorder.fired);
    try testing.expectEqual(@as(i64, 5_000_000), openmiles.nowNs() - t1);

    const t2 = openmiles.nowNs();
    openmiles.stopAllTimers();
    openmiles.tickAllTimers();
    try testing.expectEqual(@as(u32, 4), Recorder.fired);
    try testing.expectEqual(@as(i64, 0), openmiles.nowNs() - t2);

    // On the real clock there is no step to take: the run loops own the periods
    // and a step would double-fire them.
    openmiles.useRealClock();
    const before = openmiles.nowNs();
    openmiles.tickAllTimers();
    try testing.expectEqual(@as(u32, 4), Recorder.fired);
    try testing.expect(openmiles.nowNs() >= before);
}

test "virtual clock sleep advances time instead of blocking" {
    openmiles.useVirtualClock(1_000_000);
    defer openmiles.useRealClock();
    try testing.expectEqual(@as(i64, 1_000_000), openmiles.nowNs());

    // AIL_delay(250) would block a quarter second on the real clock.
    @import("api/digital.zig").AIL_delay(250);
    try testing.expectEqual(@as(i64, 1_000_000 + 250 * std.time.ns_per_ms), openmiles.nowNs());
    try testing.expectEqual(@as(u32, 250), openmiles.getMsCount());

    api_v9.AIL_sleep(50);
    try testing.expectEqual(@as(u32, 300), openmiles.getMsCount());
    try testing.expectEqual(@as(u32, 300_000), openmiles.getUsCount());
}

test "real clock restored after a virtual-clock run" {
    openmiles.useVirtualClock(0);
    openmiles.clock.advance(std.time.ns_per_s);
    openmiles.useRealClock();
    // Off the virtual epoch and back on a monotonic one that is not zero.
    const real_now = openmiles.nowNs();
    try testing.expect(real_now > std.time.ns_per_s);
    try testing.expect(openmiles.getMsCount() < 60_000);
}

test "simulation seed replays invented names, and production entropy does not" {
    // The seed is the second half of a replayable run: the virtual clock fixes
    // the time, this fixes the one name the run invents (the temporary file an
    // ASI provider image is written under). Same seed, same name.
    const Names = struct {
        fn draw() [3][8]u8 {
            var out: [3][8]u8 = undefined;
            for (&out) |*n| openmiles.randomNameBytes(n) catch unreachable;
            return out;
        }
    };

    openmiles.startSimulation(0xC0FFEE);
    try testing.expect(openmiles.isSimulated());
    try testing.expectEqual(@as(i64, 0), openmiles.nowNs());
    const first = Names.draw();

    openmiles.startSimulation(0xC0FFEE);
    const replay = Names.draw();
    try testing.expectEqualSlices(u8, &first[0], &replay[0]);

    openmiles.startSimulation(0xC0FFEF);
    const other = Names.draw();
    try testing.expect(!std.mem.eql(u8, &first[0], &other[0]));

    // A seed fixes the names, not their shape: consecutive draws differ, so
    // two providers in one run do not collide on one name.
    openmiles.startSimulation(0xC0FFEE);
    const seq = Names.draw();
    try testing.expect(!std.mem.eql(u8, &seq[0], &seq[1]));
    try testing.expect(!std.mem.eql(u8, &seq[1], &seq[2]));

    openmiles.endSimulation();
    try testing.expect(!openmiles.isSimulated());

    // Unseeded, the bytes come from the platform: eight draws in a row all
    // landing on one value would mean the simulation PRNG is still live.
    var prev: [8]u8 = undefined;
    var cur: [8]u8 = undefined;
    try openmiles.randomNameBytes(&prev);
    var differs = false;
    for (0..8) |_| {
        try openmiles.randomNameBytes(&cur);
        if (!std.mem.eql(u8, &prev, &cur)) differs = true;
        prev = cur;
    }
    try testing.expect(differs);
}

test "injected file faults reach the whole-file read path" {
    // A failing open and a short read are the two faults a real disk will not
    // produce on demand, and both are the sort a simulation has to replay.
    const io = openmiles.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = "RIFFxxxxWAVEfmt ";
    const file = try tmp.dir.createFile(io, "bank.mbnk", .{});
    try file.writeStreamingAll(io, body);
    file.close(io);

    // Relative to the cwd, which is where the test binary runs from.
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/bank.mbnk", .{&tmp.sub_path});

    const whole = try openmiles.readWholeFile(path);
    defer openmiles.global_allocator.free(whole);
    try testing.expectEqualStrings(body, whole);

    const Faults = struct {
        var fail_open: bool = true;
        var keep: usize = 8;
        fn open(p: []const u8) ?anyerror {
            if (!fail_open) return null;
            return if (std.mem.endsWith(u8, p, "bank.mbnk")) error.AccessDenied else null;
        }
        fn truncate(p: []const u8) ?usize {
            _ = p;
            return keep;
        }
    };
    const open_fault: openmiles.fs_compat.Fault = .{ .open = Faults.open };
    const truncate_fault: openmiles.fs_compat.Fault = .{ .truncate_read = Faults.truncate };
    defer openmiles.fs_compat.fault = null;

    openmiles.fs_compat.fault = &open_fault;
    // The seam itself reports the injected error verbatim; readWholeFile maps
    // every open failure to FileNotFound, which is what its callers see.
    try testing.expectError(error.AccessDenied, openmiles.fs_compat.openFile(io, path, .{}));
    try testing.expectError(error.FileNotFound, openmiles.readWholeFile(path));
    // A sample load names the same failure apart from a missing file: a
    // denied or malformed name reported as FileNotFound sends an operator
    // looking for a file that was there all along.
    {
        const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
        defer drv.deinit();
        const s = try openmiles.Sample.init(drv);
        defer s.deinit();
        try testing.expectError(error.FileOpenFailed, s.loadFromFile(path));
    }
    // Other paths are untouched by a schedule that names this one.
    Faults.fail_open = false;
    Faults.keep = 4;
    openmiles.fs_compat.fault = &truncate_fault;
    try testing.expectError(error.ReadFailed, openmiles.readWholeFile(path));

    openmiles.fs_compat.fault = null;
    const again = try openmiles.readWholeFile(path);
    defer openmiles.global_allocator.free(again);
    try testing.expectEqualStrings(body, again);
}

test "injected short reads reach AIL_file_read and the sample load" {
    // readWholeFile is not the only reader: a schedule that models a write that
    // never finished has to shorten these two as well, or a replay diverges
    // from the run that produced the failure.
    const io = openmiles.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = "RIFFxxxxWAVEfmt ";
    const file = try tmp.dir.createFile(io, "clip.wav", .{});
    try file.writeStreamingAll(io, body);
    file.close(io);

    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/clip.wav", .{&tmp.sub_path});
    var path_z_buf: [256]u8 = undefined;
    const path_z = try std.fmt.bufPrintZ(&path_z_buf, "{s}", .{path});

    const Faults = struct {
        var keep: usize = 8;
        fn truncate(p: []const u8) ?usize {
            _ = p;
            return keep;
        }
    };
    const truncate_fault: openmiles.fs_compat.Fault = .{ .truncate_read = Faults.truncate };
    defer openmiles.fs_compat.fault = null;

    // AIL_file_read zero-fills the tail the read did not reach, out to the
    // file's own length, in both the caller-buffer and malloc'd-buffer forms.
    // Past that length the caller's buffer is left alone.
    openmiles.fs_compat.fault = &truncate_fault;
    var dst: [32]u8 = @splat(0xAA);
    try testing.expect(@intFromPtr(api_file.AIL_file_read(path_z.ptr, &dst)) == @intFromPtr(&dst));
    try testing.expectEqualStrings("RIFFxxxx", dst[0..8]);
    try testing.expectEqualSlices(u8, &[_]u8{0} ** (body.len - 8), dst[8..body.len]);
    try testing.expectEqualSlices(u8, &[_]u8{0xAA} ** (dst.len - body.len), dst[body.len..]);

    const owned = api_file.AIL_file_read(path_z.ptr, null) orelse return error.MissingFileReadResult;
    defer std.c.free(owned);
    const owned_slice: []u8 = @as([*]u8, @ptrCast(owned))[0..body.len];
    try testing.expectEqualStrings("RIFFxxxx", owned_slice[0..8]);
    try testing.expectEqualSlices(u8, &[_]u8{0} ** (body.len - 8), owned_slice[8..]);

    // A sample load refuses the short read rather than decoding a truncated
    // image, which is the behaviour the fault models.
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try testing.expectError(error.ReadFailed, s.loadFromFile(path));

    openmiles.fs_compat.fault = null;
    try testing.expectEqual(@intFromPtr(&dst), @intFromPtr(api_file.AIL_file_read(path_z.ptr, &dst)));
    try testing.expectEqualStrings(body, dst[0..body.len]);
}

test "injected short writes store only the named prefix" {
    // The temp image is the only file the library writes, and a write that
    // stops short would otherwise be loaded as a module the caller never
    // handed over. The write goes through the same schedule as the reads, so a
    // simulation can produce a partial file.
    const io = openmiles.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = "MZ\x90\x00not-a-pe-image";

    // Relative to the cwd, which is where the test binary runs from.
    var path_buf: [256]u8 = undefined;
    const abs = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/image.asi", .{&tmp.sub_path});

    const Faults = struct {
        var keep: usize = 4;
        fn truncate(p: []const u8) ?usize {
            if (!std.mem.endsWith(u8, p, "image.asi")) return null;
            return keep;
        }
    };
    const fault: openmiles.fs_compat.Fault = .{ .truncate_write = Faults.truncate };
    defer openmiles.fs_compat.fault = null;

    const f = try openmiles.fs_compat.createFile(io, abs, .{});
    openmiles.fs_compat.fault = &fault;
    const written = try openmiles.fs_compat.writeAll(io, f, abs, body);
    f.close(io);
    // The caller is told how much landed, so it can refuse the file instead of
    // treating a partial write as a complete one.
    try testing.expectEqual(@as(usize, 4), written);

    // A schedule naming another path leaves this write whole.
    Faults.keep = body.len + 16; // longer than the buffer, so the clamp is what holds
    const f2 = try openmiles.fs_compat.createFile(io, abs, .{ .truncate = true });
    openmiles.fs_compat.fault = &fault;
    try testing.expectEqual(body.len, try openmiles.fs_compat.writeAll(io, f2, abs, body));
    f2.close(io);

    const round_trip = try openmiles.readWholeFile(abs);
    defer openmiles.global_allocator.free(round_trip);
    try testing.expectEqualStrings(body, round_trip);
}

test "injected delete failures and the absolute temp-image create reach the seam" {
    // The ASI image is created by absolute route and removed from either
    // provider teardown or the failed-open path. Both went straight to std.Io,
    // so a schedule could not fail a create that lands under the temp
    // directory, and could not replay an image that stays on disk because it
    // was still mapped.
    const io = openmiles.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const body = "MZ\x90\x00image";

    var path_buf: [256]u8 = undefined;
    const rel = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/om_asi_image.dll", .{&tmp.sub_path});

    const Faults = struct {
        var fail: bool = false;
        fn open(p: []const u8) ?anyerror {
            if (!fail) return null;
            return if (std.mem.endsWith(u8, p, "om_asi_image.dll")) error.AccessDenied else null;
        }
        fn remove(p: []const u8) ?anyerror {
            if (!fail) return null;
            return if (std.mem.endsWith(u8, p, "om_asi_image.dll")) error.PermissionDenied else null;
        }
    };
    const fault: openmiles.fs_compat.Fault = .{ .open = Faults.open, .remove = Faults.remove };
    defer openmiles.fs_compat.fault = null;

    // Unfaulted: the absolute create, the write, and the delete all pass.
    // The absolute form is what AIL_open_ASI_provider builds from the temp
    // directory, so the path has to be one for the call to mean anything.
    const cwd_z = try std.process.currentPathAlloc(io, openmiles.global_allocator);
    defer openmiles.global_allocator.free(cwd_z);
    var abs_buf: [512]u8 = undefined;
    const abs = try std.fmt.bufPrint(&abs_buf, "{s}/{s}", .{ cwd_z, rel });
    const f = try openmiles.fs_compat.createFileAbsolute(io, abs, .{ .exclusive = true });
    openmiles.fs_compat.fault = &fault;
    try testing.expectEqual(body.len, try openmiles.fs_compat.writeAll(io, f, abs, body));
    f.close(io);

    // The same three calls, with the schedule failing this path. The create is
    // the one that used to slip past the seam.
    Faults.fail = true;
    try testing.expectError(error.AccessDenied, openmiles.fs_compat.createFileAbsolute(io, abs, .{ .exclusive = true }));
    // The relative form is the same call, so the schedule names it too.
    try testing.expectError(error.AccessDenied, openmiles.fs_compat.createFile(io, rel, .{ .exclusive = true }));
    // A removal the schedule fails leaves the file in place, and reports why.
    try testing.expectError(error.PermissionDenied, openmiles.fs_compat.deleteFile(io, abs));
    // Another path is untouched by a schedule that names this one.
    try testing.expectError(error.FileNotFound, openmiles.fs_compat.deleteFile(io, ".zig-cache/tmp/absent-image.dll"));

    openmiles.fs_compat.fault = null;
    Faults.fail = false;
    // With the schedule gone the file is still there, which is what the
    // injection models: a locked image is not removed by asking again.
    const still_there = try openmiles.fs_compat.openFile(io, abs, .{});
    still_there.close(io);
    try openmiles.fs_compat.deleteFile(io, abs);
    try testing.expectError(error.FileNotFound, openmiles.fs_compat.openFile(io, abs, .{}));
}

test "Sequence setChannelMap out-of-range physical clamps" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const seq = try openmiles.Sequence.init(driver);
    defer seq.deinit();

    seq.setChannelMap(0, 20);
    try testing.expectEqual(@as(i32, 15), seq.getPhysicalChannel(0));

    seq.setChannelMap(0, -5);
    try testing.expectEqual(@as(i32, 0), seq.getPhysicalChannel(0));
}

test "preference defaults cover the 3.x..8.x Pref values" {
    // Pref is the 3.x..8.x numbering; 9.x renumbered the table (covered by the
    // version-aware test above), so this old-layout sweep only applies pre-9.0.
    // It pins the preferences named below, not every member of the table.
    if (openmiles.mss_version >= 90) return;
    const P = openmiles.Pref;
    try testing.expectEqual(@as(i32, 64), openmiles.getPreference(@intFromEnum(P.DIG_MIXER_CHANNELS)));
    try testing.expectEqual(@as(i32, 1), openmiles.getPreference(@intFromEnum(P.MDI_QUANT_ADVANCE)));
    try testing.expectEqual(@as(i32, 0), openmiles.getPreference(@intFromEnum(P.MDI_ALLOW_LOOP_BRANCHING)));
    try testing.expectEqual(@as(i32, 2), openmiles.getPreference(@intFromEnum(P.MDI_DEFAULT_BEND_RANGE)));
    try testing.expectEqual(@as(i32, 0), openmiles.getPreference(@intFromEnum(P.MDI_DOUBLE_NOTE_OFF)));
    try testing.expectEqual(@as(i32, 1536), openmiles.getPreference(@intFromEnum(P.MDI_SYSEX_BUFFER_SIZE)));
    try testing.expectEqual(@as(i32, 49152), openmiles.getPreference(@intFromEnum(P.DIG_OUTPUT_BUFFER_SIZE)));
    try testing.expectEqual(@as(i32, 5), openmiles.getPreference(@intFromEnum(P.AIL_MM_PERIOD)));
    try testing.expectEqual(@as(i32, 1), openmiles.getPreference(@intFromEnum(P.DIG_ENABLE_RESAMPLE_FILTER)));
    try testing.expectEqual(@as(i32, 2048), openmiles.getPreference(@intFromEnum(P.DIG_DECODE_BUFFER_SIZE)));
}

test "preference set returns old value" {
    const pref = @intFromEnum(openmiles.Pref.DIG_MIXER_CHANNELS);
    const original = openmiles.getPreference(pref);
    defer _ = openmiles.setPreference(pref, original);

    const old = openmiles.setPreference(pref, 99);
    try testing.expectEqual(original, old);
    try testing.expectEqual(@as(i32, 99), openmiles.getPreference(pref));

    const old2 = openmiles.setPreference(pref, 50);
    try testing.expectEqual(@as(i32, 99), old2);
}

test "registerDriver fills slots and unregisterDriver frees them" {
    const allocator = testing.allocator;
    const d1 = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    const d2 = try openmiles.DigitalDriver.init(allocator, 22050, 8, 1);

    try testing.expect(openmiles.isKnownDriver(@ptrCast(d1)));
    try testing.expect(openmiles.isKnownDriver(@ptrCast(d2)));

    d1.deinit();
    try testing.expect(!openmiles.isKnownDriver(@ptrCast(d1)));
    try testing.expect(openmiles.isKnownDriver(@ptrCast(d2)));

    d2.deinit();
    try testing.expect(!openmiles.isKnownDriver(@ptrCast(d2)));
}

test "a driver handle stays classifiable past any fixed table size" {
    // isKnownDriver is what tells a driver handle from a Sample3D handle, so a
    // driver missing from the table would have a listener position written
    // through the Sample3D layout. There is no cap on how many drivers are live.
    const allocator = testing.allocator;
    var drivers: [12]*openmiles.DigitalDriver = undefined;
    for (&drivers) |*d| {
        d.* = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    }
    for (drivers) |d| try testing.expect(openmiles.isKnownDriver(@ptrCast(d)));
    for (drivers) |d| d.deinit();
    for (drivers) |d| try testing.expect(!openmiles.isKnownDriver(@ptrCast(d)));
}

test "Sample setPlaybackRate ignores rate <= 0 (SDK behavior)" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    sample.setPlaybackRate(22050);
    try testing.expectEqual(@as(?f32, 22050.0), sample.target_rate);

    // SDK (AIL_API_set_sample_playback_rate): rate <= 0 is ignored, leaving the
    // current rate unchanged -- not stored as 0.
    sample.setPlaybackRate(0);
    try testing.expectEqual(@as(?f32, 22050.0), sample.target_rate);
    sample.setPlaybackRate(-100);
    try testing.expectEqual(@as(?f32, 22050.0), sample.target_rate);
}

test "playback rate and rate_factor compose into the pitch (not overwrite)" {
    const s = try loadedSample(testing.allocator, 64, 1, 8000);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();

    // native = 8000. rate 4000 -> pitch 0.5.
    dg.AIL_set_sample_playback_rate(s, 4000);
    try testing.expect(@abs(openmiles.ma.ma_sound_get_pitch(&s.sound) - 0.5) < 0.001);
    // factor 2.0 composes: pitch = 0.5 * 2.0 = 1.0 (does not reset to 2.0).
    api_v8.AIL_set_sample_playback_rate_factor(s, 2.0);
    try testing.expect(@abs(openmiles.ma.ma_sound_get_pitch(&s.sound) - 1.0) < 0.001);
    // factor <= 0 is ignored (pitch unchanged, factor getter stays 2.0).
    api_v8.AIL_set_sample_playback_rate_factor(s, -1.0);
    try testing.expect(@abs(openmiles.ma.ma_sound_get_pitch(&s.sound) - 1.0) < 0.001);
    try testing.expectEqual(@as(f32, 2.0), api_v8.AIL_sample_playback_rate_factor(s));
    // SDK (wavefile.cpp): a null handle returns 0.0, not the 1.0 default.
    try testing.expectEqual(@as(f32, 0.0), api_v8.AIL_sample_playback_rate_factor(null));
}

test "loop_block setter: -2 keeps current offset, start>end swaps (SDK)" {
    const s = try loadedSample(testing.allocator, 4096, 1, 8000); // mono 16-bit, bpf=2
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();

    var ls: i32 = 0;
    var le: i32 = 0;
    dg.AIL_set_sample_loop_block(s, 100, 200);
    _ = api_v8b.AIL_sample_loop_block(s, &ls, &le);
    try testing.expectEqual(@as(i32, 100), ls);
    try testing.expectEqual(@as(i32, 200), le);

    // -2 start keeps the current start (100); end updates to 400.
    dg.AIL_set_sample_loop_block(s, -2, 400);
    _ = api_v8b.AIL_sample_loop_block(s, &ls, &le);
    try testing.expectEqual(@as(i32, 100), ls);
    try testing.expectEqual(@as(i32, 400), le);

    // start > end -> swapped.
    dg.AIL_set_sample_loop_block(s, 600, 300);
    _ = api_v8b.AIL_sample_loop_block(s, &ls, &le);
    try testing.expectEqual(@as(i32, 300), ls);
    try testing.expectEqual(@as(i32, 600), le);
}

test "AIL_sample_playback_rate defaults to the file's native rate" {
    const s = try loadedSample(testing.allocator, 64, 1, 8000);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();
    // No explicit rate set: the getter must report the file's 8000 Hz (like the
    // SDK's original_playback_rate set at load), not a hardcoded 44100.
    try testing.expectEqual(@as(i32, 8000), dg.AIL_sample_playback_rate(s));
}

test "DigitalDriver multiple samples tracked correctly" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s1 = try openmiles.Sample.init(driver);
    const s2 = try openmiles.Sample.init(driver);
    const s3 = try openmiles.Sample.init(driver);
    try testing.expectEqual(@as(usize, 3), driver.samples.items.len);

    s2.deinit();
    try testing.expectEqual(@as(usize, 2), driver.samples.items.len);

    s1.deinit();
    s3.deinit();
    try testing.expectEqual(@as(usize, 0), driver.samples.items.len);
}

test "Sample3D and Sample coexist in same driver" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();
    const s3d = try openmiles.Sample3D.init(driver);
    defer s3d.deinit();

    try testing.expectEqual(@as(usize, 1), driver.samples.items.len);
    try testing.expectEqual(@as(usize, 1), driver.samples_3d.items.len);
}

test "Sample pause and resume lifecycle" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    const wav = try zeroWav(allocator);
    defer allocator.free(wav);

    try sample.loadFromMemory(wav, true);

    sample.start();
    try testing.expectEqual(openmiles.SampleStatus.playing, sample.status());

    sample.pause();
    try testing.expect(sample.is_paused);

    sample.resumePlayback();
    try testing.expect(!sample.is_paused);
}

test "Sample pause on uninitialized is no-op" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    sample.pause();
    try testing.expect(!sample.is_paused);

    sample.resumePlayback();
    try testing.expect(!sample.is_paused);
}

test "DigitalDriver listener position roundtrip" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    driver.setListenerPosition(1.0, 2.0, 3.0);
    const pos = driver.getListenerPosition();
    try testing.expectEqual(@as(f32, 1.0), pos.x);
    try testing.expectEqual(@as(f32, 2.0), pos.y);
    try testing.expectEqual(@as(f32, 3.0), pos.z);
}

test "3D coords negated at the miniaudio boundary (MSS left-handed -> ma right-handed)" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();
    driver.setListenerPosition(1.0, 2.0, 3.0);
    // MSS-space getter returns +Z unchanged...
    try testing.expectEqual(@as(f32, 3.0), driver.getListenerPosition().z);
    // ...but miniaudio stores the negated Z (the handedness conversion).
    const raw = openmiles.ma.ma_engine_listener_get_position(&driver.engine, 0);
    try testing.expectEqual(@as(f32, -3.0), raw.z);
    try testing.expectEqual(@as(f32, 1.0), raw.x); // X/Y unchanged
}

test "DigitalDriver listener velocity roundtrip" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    driver.setListenerVelocity(4.0, 5.0, 6.0);
    const vel = driver.getListenerVelocity();
    try testing.expectEqual(@as(f32, 4.0), vel.x);
    try testing.expectEqual(@as(f32, 5.0), vel.y);
    try testing.expectEqual(@as(f32, 6.0), vel.z);
}

test "DigitalDriver listener direction roundtrip" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    driver.setListenerDirection(0.0, 0.0, -1.0);
    const dir = driver.getListenerDirection();
    try testing.expectEqual(@as(f32, 0.0), dir.x);
    try testing.expectEqual(@as(f32, 0.0), dir.y);
    try testing.expectEqual(@as(f32, -1.0), dir.z);
}

test "DigitalDriver getSampleRate and getChannels match init" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    try testing.expectEqual(@as(u32, 44100), driver.getSampleRate());
    try testing.expectEqual(@as(u32, 2), driver.getChannels());
}

test "Sample getPosition returns 0 when uninitialized" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    try testing.expectEqual(@as(u32, 0), sample.getPosition());
}

test "Sample getMsPosition returns zeros when uninitialized" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    const pos = sample.getMsPosition();
    try testing.expectEqual(@as(i32, 0), pos.total);
    try testing.expectEqual(@as(i32, 0), pos.current);
}

test "Sample3D setPlaybackRate" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    s.setPlaybackRate(22050);
    try testing.expectEqual(@as(?f32, 22050.0), s.target_rate);
}

test "Sample3D getMsPosition returns zeros when uninitialized" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    const pos = s.getMsPosition();
    try testing.expectEqual(@as(i32, 0), pos.total);
    try testing.expectEqual(@as(i32, 0), pos.current);
}

test "DigitalDriver listener world-up roundtrip" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    driver.setListenerWorldUp(0.0, 1.0, 0.0);
    const up = driver.getListenerWorldUp();
    try testing.expectEqual(@as(f32, 0.0), up.x);
    try testing.expectEqual(@as(f32, 1.0), up.y);
    try testing.expectEqual(@as(f32, 0.0), up.z);
}

test "listener 3D orientation normalizes face & up like the SDK" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    // Non-unit face (0,0,5)->(0,0,1) and non-axis up (0,3,4)->(0,0.6,0.8).
    api_3d.AIL_set_listener_3D_orientation(drv, 0, 0, 5, 0, 3, 4);
    var fx: f32 = 0;
    var fy: f32 = 0;
    var fz: f32 = 0;
    var ux: f32 = 0;
    var uy: f32 = 0;
    var uz: f32 = 0;
    api_v7.AIL_listener_3D_orientation(drv, &fx, &fy, &fz, &ux, &uy, &uz);
    try testing.expect(@abs(fx) < 0.001 and @abs(fy) < 0.001 and @abs(fz - 1) < 0.001);
    try testing.expect(@abs(ux) < 0.001 and @abs(uy - 0.6) < 0.001 and @abs(uz - 0.8) < 0.001);
}

test "AIL_update_listener_3D_position advances by velocity * dt_ms (per-ms)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    api_3d.AIL_set_listener_3D_position(drv, 0, 0, 0);
    // Listener velocity is per-millisecond (magnitude 1 = no scale): 2/ms on +x,
    // -1/ms on +z (Z round-trips through the negate-on-set/negate-on-get pair).
    api_3d.AIL_set_listener_3D_velocity(drv, 2, 0, -1, 1);
    var x: f32 = 0;
    var y: f32 = 0;
    var z: f32 = 0;
    api_v7.AIL_listener_3D_velocity(drv, &x, &y, &z);
    try testing.expectApproxEqAbs(@as(f32, 2.0), x, 0.001);
    try testing.expectApproxEqAbs(@as(f32, -1.0), z, 0.001);

    // SDK m3d.cpp: position += velocity * dt_ms. 50 ms -> +100 x, -50 z.
    api_v7.AIL_update_listener_3D_position(drv, 50);
    api_v7.AIL_listener_3D_position(drv, &x, &y, &z);
    try testing.expectApproxEqAbs(@as(f32, 100.0), x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, -50.0), z, 0.01);

    // Zero velocity -> update is a no-op (early-out below MSS_EPSILON).
    api_3d.AIL_set_listener_3D_velocity(drv, 0, 0, 0, 1);
    api_v7.AIL_update_listener_3D_position(drv, 1000);
    api_v7.AIL_listener_3D_position(drv, &x, &y, &z);
    try testing.expectApproxEqAbs(@as(f32, 100.0), x, 0.01);
}

test "AIL_update_3D_position advances by velocity * dt_ms (per-ms)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const h3 = api_3d.AIL_allocate_3D_sample_handle(drv) orelse return error.NoSample;
    defer api_3d.AIL_release_3D_sample_handle(h3);
    // Sample velocity is per-millisecond (magnitude 1 = no scale): 2/ms on +x.
    api_3d.AIL_set_3D_velocity(h3, 2, 0, 0, 1);
    var x: f32 = 0;
    var y: f32 = 0;
    var z: f32 = 0;
    api_3d.AIL_3D_velocity(@constCast(h3), &x, &y, &z);
    try testing.expectApproxEqAbs(@as(f32, 2.0), x, 0.001);

    // SDK m3d.cpp: position += velocity * dt_ms. 50 ms -> +100 x. Dead
    // reckoning works before any audio is loaded (stored position only).
    api_3d.AIL_auto_update_3D_position(@constCast(h3), 1);
    api_3d.AIL_update_3D_position(@constCast(h3), 50);
    api_3d.AIL_3D_position(@constCast(h3), &x, &y, &z);
    try testing.expectApproxEqAbs(@as(f32, 100.0), x, 0.01);

    // The v5 legacy explicit form advances by the same per-ms units.
    api_3d.AIL_3D_auto_update_position(@constCast(h3), 1);
    api_3d.AIL_3D_update_position(@constCast(h3), 25);
    api_3d.AIL_3D_position(@constCast(h3), &x, &y, &z);
    try testing.expectApproxEqAbs(@as(f32, 150.0), x, 0.01);
}

test "AIL_update_3D_position ignores NaN/Inf dt instead of poisoning position" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const h3 = api_3d.AIL_allocate_3D_sample_handle(drv) orelse return error.NoSample;
    defer api_3d.AIL_release_3D_sample_handle(h3);
    api_3d.AIL_set_3D_velocity(h3, 2, 0, 0, 1);
    api_3d.AIL_auto_update_3D_position(@constCast(h3), 1);
    // A NaN or Inf dt must be dropped like the listener/explicit paths do:
    // NaN += anything sticks forever and would feed NaN into the mixer's
    // distance-attenuation math on every later tick.
    api_3d.AIL_update_3D_position(@constCast(h3), std.math.nan(f32));
    api_3d.AIL_update_3D_position(@constCast(h3), std.math.inf(f32));
    var x: f32 = -1;
    var y: f32 = -1;
    var z: f32 = -1;
    api_3d.AIL_3D_position(@constCast(h3), &x, &y, &z);
    try testing.expectEqual(@as(f32, 0.0), x);
    try testing.expectEqual(@as(f32, 0.0), y);
    try testing.expectEqual(@as(f32, 0.0), z);
}

test "AIL_serve advances auto-updated 3D sources by the frame, not by process uptime" {
    openmiles.useVirtualClock(0);
    defer openmiles.useRealClock();
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const h3 = api_3d.AIL_allocate_3D_sample_handle(drv) orelse return error.NoSample;
    defer api_3d.AIL_release_3D_sample_handle(h3);
    api_3d.AIL_set_3D_velocity(h3, 2, 0, 0, 1); // 2 units/ms on +x
    api_3d.AIL_auto_update_3D_position(@constCast(h3), 1);
    var x: f32 = 0;

    // The first serve has no previous frame to measure against, so the time the
    // clock had already run cannot be integrated: a host up for a day would
    // otherwise jump the source by 2 * 86_400_000 on the first tick.
    openmiles.clock.advance(10 * std.time.ns_per_s);
    drv.serve();
    api_3d.AIL_3D_position(@constCast(h3), &x, null, null);
    try testing.expectEqual(@as(f32, 0.0), x);

    // A 240 Hz game frame is 4.17 ms; a millisecond-truncated delta still lands
    // here, but a sub-millisecond frame would have been dropped entirely.
    openmiles.clock.advance(std.time.ns_per_s / 240);
    drv.serve();
    api_3d.AIL_3D_position(@constCast(h3), &x, null, null);
    try testing.expectApproxEqAbs(@as(f32, 2.0 * 1000.0 / 240.0), x, 0.001);

    // Half a millisecond: nothing a millisecond-truncated reading could carry.
    openmiles.clock.advance(std.time.ns_per_ms / 2);
    drv.serve();
    api_3d.AIL_3D_position(@constCast(h3), &x, null, null);
    try testing.expectApproxEqAbs(@as(f32, 2.0 * 1000.0 / 240.0 + 1.0), x, 0.001);
}

test "AIL_init_sample resets level/reverb/filter/occlusion state to defaults (SDK)" {
    // SDK wavefile.cpp AIL_init_sample restores a reused handle to its defaults:
    // volume_levels 1/1, low_pass 1.0, dry 1.0, wet 0.0, obstruction/occlusion/
    // exclusion 0. Our reset() must do the same or a reused sample keeps stale state.
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();
    const s = try openmiles.Sample.init(driver);
    defer s.deinit();
    const pcm = [_]u8{0} ** 4410;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 44100, 16); // mono16 -> bpf 2
    defer testing.allocator.free(wav);
    try s.loadFromMemory(wav, false);

    // Granularity reflects the SOURCE format (mono-16 = 2), stable regardless of
    // what miniaudio decodes to.
    try testing.expectEqual(@as(u32, 2), dg.AIL_sample_granularity(s));

    // Dirty the state.
    api_v7.AIL_set_sample_reverb_levels(s, 0.3, 0.7);
    api_v7.AIL_set_sample_low_pass_cut_off(s, 0, 0.4);
    api_v7.AIL_set_sample_obstruction(s, 0.9);
    api_v7.AIL_set_sample_occlusion(s, 0.8);
    api_v7.AIL_set_sample_volume_levels(s, 0.2, 0.6);
    // Source-format granularity is unchanged by reverb/level rebuilds.
    try testing.expectEqual(@as(u32, 2), dg.AIL_sample_granularity(s));
    dg.AIL_set_sample_adpcm_block_size(s, 512); // stale ADPCM block size
    try testing.expectEqual(@as(u32, 512), dg.AIL_sample_granularity(s)); // now reports the block size

    // Re-init.
    dg.AIL_init_sample(s);

    var dry: f32 = -1;
    var wet: f32 = -1;
    api_v7.AIL_sample_reverb_levels(s, &dry, &wet);
    try testing.expectApproxEqAbs(@as(f32, 1.0), dry, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), wet, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), api_v7.AIL_sample_low_pass_cut_off(s, 0), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), api_v7.AIL_sample_obstruction(s), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), api_v7.AIL_sample_occlusion(s), 0.001);
    var lft: f32 = -1;
    var rgt: f32 = -1;
    api_v7.AIL_sample_volume_levels(s, &lft, &rgt);
    try testing.expectApproxEqAbs(@as(f32, 1.0), lft, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), rgt, 0.001);
    // adpcm block size cleared -> granularity back to the source-format frame
    // size (mono-16 = 2), no longer the stale 512.
    try testing.expectEqual(@as(u32, 2), dg.AIL_sample_granularity(s));
}

test "fresh driver master reverb levels default to dry=1.0, wet=1.0 (SDK init)" {
    // SDK genericdig.cpp inits reverb[0].master_dry = master_wet = 1.0F. master_wet
    // is a neutral multiplier for per-sample wet sends; defaulting it to 0 would
    // silence all reverb.
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    var dry: f32 = -1;
    var wet: f32 = -1;
    api_v7.AIL_digital_master_reverb_levels(drv, 0, &dry, &wet);
    try testing.expectApproxEqAbs(@as(f32, 1.0), dry, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), wet, 0.0001);
}

test "the _v7 spellings forward to bus 0 with their arguments in slot order" {
    // The v7 names predate the bus index the v9 bus mixer inserted as the second
    // argument, so each one forwards to the wider form with a literal 0 in that
    // slot. A slot-order slip is invisible from either name alone: the getters
    // take the same argument positions, so a transposed pair would read back
    // exactly what was written. Read the wide form back by slot instead.
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();

    api_v7.AIL_set_digital_master_reverb_levels_v7(drv, 0.3, 0.7);
    var dry: f32 = -1;
    var wet: f32 = -1;
    api_v7.AIL_digital_master_reverb_levels(drv, 0, &dry, &wet);
    try testing.expectApproxEqAbs(@as(f32, 0.3), dry, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.7), wet, 0.0001);

    // decay, predelay, damping: three f32s, so a shifted argument lands in a
    // neighbouring slot and still looks like a plausible value.
    api_v7.AIL_set_digital_master_reverb_v7(drv, 1.5, 0.02, 0.25);
    var decay: f32 = -1;
    var predelay: f32 = -1;
    var damping: f32 = -1;
    api_v7.AIL_digital_master_reverb(drv, 0, &decay, &predelay, &damping);
    try testing.expectApproxEqAbs(@as(f32, 1.5), decay, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.02), predelay, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), damping, 0.0001);

    // Room type: the setter also applies the EAX preset, which is how the bus
    // index is caught if it lands somewhere other than slot 0.
    api_v7.AIL_set_room_type_v7(drv, 2);
    try testing.expectEqual(@as(i32, 2), api_v7.AIL_room_type(drv, 0));
    api_v7.AIL_digital_master_reverb_levels(drv, 0, &dry, &wet);
    try testing.expectApproxEqAbs(@as(f32, 1.0), dry, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.417), wet, 0.0001);

    // Sample low-pass: the channel slot is the one the v9 form takes.
    api_v7.AIL_set_sample_low_pass_cut_off_v7(s, 0.4);
    try testing.expectApproxEqAbs(@as(f32, 0.4), api_v7.AIL_sample_low_pass_cut_off(s, 0), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.4), api_v7.AIL_sample_low_pass_cut_off_v7(s), 0.0001);
    // A null handle keeps the SDK's "no filtering" reading rather than crashing.
    try testing.expectEqual(@as(f32, 1.0), api_v7.AIL_sample_low_pass_cut_off_v7(null));
}

test "AIL_set_room_type applies the EAX preset to the master reverb (m3d.cpp rooms[])" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    // EAX_ENVIRONMENT_ROOM (index 2): { level 0.417, time 0.4, predelay 0.666,
    // damping 0.003 }; the setter applies dry=1.0, wet=level, decay/predelay/damping.
    api_v7.AIL_set_room_type(drv, 0, 2);
    try testing.expectEqual(@as(i32, 2), api_v7.AIL_room_type(drv, 0)); // room_type verbatim
    var dry: f32 = 0;
    var wet: f32 = 0;
    api_v7.AIL_digital_master_reverb_levels(drv, 0, &dry, &wet);
    try testing.expectApproxEqAbs(@as(f32, 1.0), dry, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.417), wet, 0.0001);
    var time: f32 = 0;
    var predelay: f32 = 0;
    var damping: f32 = 0;
    api_v7.AIL_digital_master_reverb(drv, 0, &time, &predelay, &damping);
    try testing.expectApproxEqAbs(@as(f32, 0.4), time, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.666), predelay, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.003), damping, 0.0001);

    // AIL_set_digital_master_room_type forwards to set_room_type(dig,0,rt).
    api_v7.AIL_set_digital_master_room_type(drv, 22); // UNDERWATER: wet 1.0
    api_v7.AIL_digital_master_reverb_levels(drv, 0, &dry, &wet);
    try testing.expectApproxEqAbs(@as(f32, 1.0), wet, 0.0001);

    // Out-of-range room_type: stored verbatim, preset NOT applied (no OOB read).
    api_v7.AIL_set_room_type(drv, 0, 9999);
    try testing.expectEqual(@as(i32, 9999), api_v7.AIL_room_type(drv, 0));
    api_v7.AIL_digital_master_reverb_levels(drv, 0, &dry, &wet);
    try testing.expectApproxEqAbs(@as(f32, 1.0), wet, 0.0001); // unchanged from UNDERWATER
}

test "AIL_sample_3D_distances round-trips via the S3D struct (uninitialized too)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv); // not loaded/initialized
    defer s.deinit();

    var maxd: f32 = -1;
    var mind: f32 = -1;
    var atten: i32 = -1;
    // Fresh defaults match wavefile.cpp AIL_init_sample: max 200, min 1, atten 0.
    api_v7.AIL_sample_3D_distances(s, &maxd, &mind, &atten);
    try testing.expectApproxEqAbs(@as(f32, 200.0), maxd, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), mind, 0.001);
    try testing.expectEqual(@as(i32, 0), atten);

    // Round-trip on an uninitialized sample (the bug: previously returned 0/0).
    api_v7.AIL_set_sample_3D_distances(s, 100.0, 5.0, 1);
    api_v7.AIL_sample_3D_distances(s, &maxd, &mind, &atten);
    try testing.expectApproxEqAbs(@as(f32, 100.0), maxd, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5.0), mind, 0.001);
    try testing.expectEqual(@as(i32, 1), atten);

    // SDK swaps the pair when min > max so min_dist <= max_dist holds.
    api_v7.AIL_set_sample_3D_distances(s, 10.0, 50.0, 0); // max=10 < min=50 -> swap
    api_v7.AIL_sample_3D_distances(s, &maxd, &mind, &atten);
    try testing.expectApproxEqAbs(@as(f32, 50.0), maxd, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 10.0), mind, 0.001);
}

test "AIL_3D_sample_distances round-trips max/min in header param order" {
    // Mss.h: AIL_set_3D_sample_distances(S, max_dist, min_dist) and the getter
    // AIL_3D_sample_distances(S, *max_dist, *min_dist) -- max FIRST, min SECOND.
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s3p = api_3d.AIL_allocate_3D_sample_handle(drv) orelse return error.AllocFailed;
    const s3: *openmiles.Sample3D = @ptrCast(@alignCast(s3p));

    api_3d.AIL_set_3D_sample_distances(s3p, 100.0, 5.0); // max=100, min=5
    var max_d: f32 = -1;
    var min_d: f32 = -1;
    api_3d.AIL_3D_sample_distances(s3, &max_d, &min_d);
    try testing.expectEqual(@as(f32, 100.0), max_d);
    try testing.expectEqual(@as(f32, 5.0), min_d);

    api_3d.AIL_3D_sample_distances(null, &max_d, &min_d); // null: no write/crash
    try testing.expectEqual(@as(f32, 100.0), max_d);
}

test "Sample3D loadFromMemory and start stop lifecycle" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    const wav = try zeroWav(allocator);
    defer allocator.free(wav);

    try s.loadFromMemory(wav, true);
    try testing.expect(s.is_initialized);
    try testing.expectEqual(openmiles.SampleStatus.done, s.status()); // loaded, never played -> SMP_DONE

    s.start();
    try testing.expectEqual(openmiles.SampleStatus.playing, s.status());

    s.stop();
    try testing.expectEqual(openmiles.SampleStatus.stopped, s.status());

    s.start();
    s.end();
    try testing.expectEqual(openmiles.SampleStatus.done, s.status());
}

test "Sample3D pause and resume lifecycle" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    const wav = try zeroWav(allocator);
    defer allocator.free(wav);

    try s.loadFromMemory(wav, true);

    s.start();
    try testing.expectEqual(openmiles.SampleStatus.playing, s.status());

    s.pause();
    try testing.expect(s.is_paused);

    s.resumePlayback();
    try testing.expect(!s.is_paused);
}

test "Sample3D getOffset and getLength return 0 when uninitialized" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    try testing.expectEqual(@as(u32, 0), s.getOffset());
    try testing.expectEqual(@as(u32, 0), s.getLength());
}

test "Sample setLoopBlock stores frame boundaries" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    const wav = try zeroWav(allocator);
    defer allocator.free(wav);

    try sample.loadFromMemory(wav, true);

    sample.setLoopBlock(100, 1000);
    try testing.expect(sample.loop_start_frame > 0);
    try testing.expect(sample.loop_end_frame > 0);
    try testing.expect(sample.loop_end_frame > sample.loop_start_frame);

    sample.setLoopBlock(0, -1);
    try testing.expectEqual(@as(u64, 0), sample.loop_start_frame);
    try testing.expectEqual(@as(u64, 0), sample.loop_end_frame);
}

test "Sample setPosition on initialized sample" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    const wav = try zeroWav(allocator);
    defer allocator.free(wav);

    try sample.loadFromMemory(wav, true);

    sample.setPosition(0);
    try testing.expectEqual(@as(u32, 0), sample.getPosition());
}

test "Redbook trackCount returns 0" {
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator);
    defer rb.deinit();

    try testing.expectEqual(@as(u32, 0), rb.trackCount());
}

test "Sample3D setLoopBlock stores frame boundaries" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    s.setLoopBlock(0, -1);
    try testing.expectEqual(@as(u64, 0), s.loop_start_frame);
    try testing.expectEqual(@as(u64, 0), s.loop_end_frame);

    s.setLoopBlock(100, 1000);
    try testing.expect(s.loop_start_frame > 0);
    try testing.expect(s.loop_end_frame > 0);
}

test "Sample3D loadFromPcm initializes sample" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    const pcm = [_]u8{0} ** 4410;
    try s.loadFromPcm(&pcm, 1, 44100, 8);
    try testing.expect(s.is_initialized);
    try testing.expectEqual(openmiles.SampleStatus.done, s.status()); // loaded, never played -> SMP_DONE
}

test "Sequence setVolume boundary values" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const seq = try openmiles.Sequence.init(driver);
    defer seq.deinit();

    seq.setVolume(127, 0);
    try testing.expectEqual(@as(i32, 127), seq.getVolume());

    seq.setVolume(-1, 0);
    try testing.expectEqual(@as(i32, 0), seq.getVolume());
}

// ---------------------------------------------------------------------------
// DLS/XMI container split-join (AIL_find_DLS / AIL_extract_DLS / AIL_merge_*)
// ---------------------------------------------------------------------------

// Minimal but well-formed XMIDI image: FORM/XDIR group followed by CAT /XMID.
const test_xmi = [_]u8{
    'F', 'O', 'R', 'M', 0x00, 0x00, 0x00, 0x0E, // FORM, BE body=14
    'X', 'D', 'I', 'R',
    'I', 'N', 'F', 'O', 0x00, 0x00, 0x00, 0x02, 0xAA, 0xBB, // INFO chunk (2 bytes)
    'C', 'A', 'T', ' ', 0x00, 0x00, 0x00, 0x08, // CAT, BE body=8
    'X', 'M', 'I', 'D', 0x01, 0x02, 0x03, 0x04, // XMID + 4 payload bytes
}; // total = 38

// Minimal DLS RIFF with a colh chunk reporting 3 instruments.
const test_dls = [_]u8{
    'R', 'I', 'F', 'F', 0x10, 0x00, 0x00, 0x00, // RIFF, LE body=16
    'D', 'L', 'S', ' ',
    'c', 'o', 'l', 'h', 0x04, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, // 3 instruments
}; // total = 24

test "dls_container xmiImageSize spans FORM+CAT groups" {
    try testing.expectEqual(@as(usize, 38), openmiles.dls_container.xmiImageSize(&test_xmi));
    try testing.expectEqual(@as(usize, 38), openmiles.dls_container.xmiImageSizePtr(&test_xmi));
}

test "dls_container splits a merged XMI+DLS image" {
    const merged = test_xmi ++ test_dls;
    const dls = openmiles.dls_container.findDls(&merged) orelse return error.NoDls;
    try testing.expectEqual(@as(usize, 24), dls.len);
    try testing.expectEqual(@as(usize, 38), @intFromPtr(dls.ptr) - @intFromPtr(&merged[0]));

    const xmi = openmiles.dls_container.findXmi(&merged) orelse return error.NoXmi;
    try testing.expectEqual(@as(usize, 38), xmi.len);
}

test "dls_container DLS-only and XMI-only images" {
    try testing.expect(openmiles.dls_container.findDls(&test_xmi) == null);
    try testing.expect(openmiles.dls_container.findXmi(&test_dls) == null);
    const d = openmiles.dls_container.findDls(&test_dls) orelse return error.NoDls;
    try testing.expectEqual(@as(usize, 24), d.len);
}

test "AIL_list_DLS reads a lying header for the size but not past the scan window" {
    const mem = @import("api/memory.zig");
    // The bank header declares far more than the buffer holds, which is what a
    // hostile DLS image looks like: the size is reported to the caller, but the
    // colh scan stays inside a window the ABI's length-less pointer can support.
    var img: [256]u8 = undefined;
    @memset(&img, 0);
    @memcpy(img[0..4], "RIFF");
    std.mem.writeInt(u32, img[4..8], 0xFFFF_FFF0, .little);
    @memcpy(img[8..12], "sfbk");
    // colh near the front: a real bank puts it there, and it must still be found.
    @memcpy(img[12..16], "colh");
    std.mem.writeInt(u32, img[16..20], 4, .little);
    std.mem.writeInt(u32, img[20..24], 7, .little);

    var lst: ?*anyopaque = null;
    var lsz: u32 = 0;
    try testing.expectEqual(@as(i32, 1), api_dls.AIL_list_DLS(&img, &lst, &lsz, 0, null));
    defer if (lst) |p| mem.AIL_mem_free_lock(p);
    try testing.expect(lsz > 0);

    // The same bank with colh pushed past the scan window is not read: the
    // listing reports no instruments rather than walking off the caller's buffer.
    var far: [128 * 1024 + 64]u8 = undefined;
    @memset(&far, 0);
    @memcpy(far[0..4], "RIFF");
    std.mem.writeInt(u32, far[4..8], 0xFFFF_FFF0, .little);
    @memcpy(far[8..12], "sfbk");
    const far_colh = 128 * 1024 + 16;
    @memcpy(far[far_colh..][0..4], "colh");
    std.mem.writeInt(u32, far[far_colh + 4 ..][0..4], 4, .little);
    std.mem.writeInt(u32, far[far_colh + 8 ..][0..4], 99, .little);

    var lst2: ?*anyopaque = null;
    var lsz2: u32 = 0;
    try testing.expectEqual(@as(i32, 1), api_dls.AIL_list_DLS(&far, &lst2, &lsz2, 0, null));
    defer if (lst2) |p| mem.AIL_mem_free_lock(p);
    const text = std.mem.span(@as([*:0]const u8, @ptrCast(lst2.?)));
    try testing.expect(std.mem.indexOf(u8, text, "0 instrument") != null);
}

// ---------------------------------------------------------------------------
// Double-buffered streaming source (AIL_load_sample_buffer ping-pong)
// ---------------------------------------------------------------------------

const StreamTestCtx = struct {
    eob_count: u32 = 0,
    last_idx: i32 = -1,
    last_len: u32 = 0,
    // The address the app submitted, so a drain can be checked against the
    // bytes the app still owns rather than against a bare count.
    last_addr: ?*anyopaque = null,
};

fn streamTestHook(ctx: ?*anyopaque, idx: i32, len: u32, addr: ?*anyopaque) void {
    const c: *StreamTestCtx = @ptrCast(@alignCast(ctx.?));
    c.eob_count += 1;
    c.last_idx = idx;
    c.last_len = len;
    c.last_addr = addr;
}

test "StreamSource ping-pongs two buffers and fires EOB on drain" {
    var ctx = StreamTestCtx{};
    var ss: openmiles.StreamSource = undefined;
    try ss.init(16, 2, 44100, streamTestHook, &ctx); // 16-bit stereo → 4 bytes/frame
    defer ss.deinit();

    const buf_a = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }; // 2 frames
    const buf_b = [_]u8{ 11, 12, 13, 14, 15, 16, 17, 18 }; // 2 frames
    _ = ss.loadBuffer(0, &buf_a, buf_a.len);
    _ = ss.loadBuffer(1, &buf_b, buf_b.len);
    try testing.expectEqual(@as(i32, -1), ss.bufferReady()); // both full

    var out: [16]u8 = undefined; // 4 frames
    var read: u64 = 0;
    const r = openmiles.ma.ma_data_source_read_pcm_frames(&ss.base, &out, 4, &read);
    try testing.expectEqual(openmiles.ma.MA_SUCCESS, r);
    try testing.expectEqual(@as(u64, 4), read);
    try testing.expectEqualSlices(u8, &buf_a, out[0..8]);
    try testing.expectEqualSlices(u8, &buf_b, out[8..16]);
    // Buffer 0 drained mid-read → EOB(0) fired once, slot 0 now free.
    try testing.expectEqual(@as(u32, 1), ctx.eob_count);
    try testing.expectEqual(@as(i32, 0), ctx.last_idx);
    try testing.expectEqual(@as(i32, 0), ss.bufferReady());
}

// miniaudio reports MA_AT_END on the read that yields 0 frames, so a source is
// drained in a loop until it says so; the return value is the frame count read.
fn drainToEnd(ss: *openmiles.StreamSource, out: []u8, bytes_per_frame: u64) !u64 {
    var total: u64 = 0;
    var guard: u32 = 0;
    while (guard < 8) : (guard += 1) {
        var read: u64 = 0;
        const r = openmiles.ma.ma_data_source_read_pcm_frames(&ss.base, out[@intCast(total * bytes_per_frame)..].ptr, bytes_per_frame - total, &read);
        total += read;
        if (r == openmiles.ma.MA_AT_END) return total;
        if (read == 0) return error.StreamNeverSignalledEnd;
    }
    return error.StreamNeverSignalledEnd;
}

test "StreamSource zero-length buffer signals end of stream" {
    var ss: openmiles.StreamSource = undefined;
    try ss.init(16, 2, 44100, null, null);
    defer ss.deinit();

    const buf_a = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }; // 2 frames
    _ = ss.loadBuffer(0, &buf_a, buf_a.len);
    _ = ss.loadBuffer(1, null, 0); // EOF marker

    // Total decoded frames must be exactly buf_a's 2 before EOF.
    var out: [16]u8 = undefined;
    const total = try drainToEnd(&ss, &out, 4);
    try testing.expectEqual(@as(u64, 2), total);
    try testing.expectEqualSlices(u8, &buf_a, out[0..8]);
}

test "StreamSource underrun emits silence and keeps playing" {
    var ss: openmiles.StreamSource = undefined;
    try ss.init(16, 1, 22050, null, null); // 16-bit mono → 2 bytes/frame
    defer ss.deinit();

    const buf_a = [_]u8{ 9, 9 }; // 1 frame
    _ = ss.loadBuffer(0, &buf_a, buf_a.len);

    var out: [8]u8 = [_]u8{0xAA} ** 8; // request 4 frames, only 1 available
    var read: u64 = 0;
    const r = openmiles.ma.ma_data_source_read_pcm_frames(&ss.base, &out, 4, &read);
    try testing.expectEqual(openmiles.ma.MA_SUCCESS, r); // not ended — starved
    try testing.expectEqual(@as(u64, 4), read); // padded with silence
    try testing.expectEqualSlices(u8, &buf_a, out[0..2]);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 6), out[2..8]); // silence
}

// A buffer whose length is not a whole number of frames must still drain: the
// trailing bytes are not a frame and cannot be completed from the next
// submission, so they are dropped and the slot fires EOB and moves on. (Before,
// the sub-frame remainder left `avail` nonzero while yielding 0 whole frames, so
// the read loop broke on every call and the sample never reached EOS.)
test "StreamSource drains a buffer ending mid-frame" {
    var ctx = StreamTestCtx{};
    var ss: openmiles.StreamSource = undefined;
    try ss.init(16, 2, 44100, streamTestHook, &ctx); // 16-bit stereo → 4 bytes/frame
    defer ss.deinit();

    // 2 whole frames plus 3 stray bytes.
    const buf_a = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 0xEE, 0xEE, 0xEE };
    _ = ss.loadBuffer(0, &buf_a, buf_a.len);
    _ = ss.loadBuffer(1, null, 0); // EOF marker

    var out: [16]u8 = undefined;
    // Reached end of stream instead of wedging, and the 2 whole frames survived.
    const total = try drainToEnd(&ss, &out, 4);
    try testing.expectEqual(@as(u64, 2), total);
    try testing.expectEqualSlices(u8, buf_a[0..8], out[0..8]);
    try testing.expectEqual(@as(u32, 1), ctx.eob_count);
    try testing.expectEqual(@as(i32, 0), ctx.last_idx);
}

// The configured ring depth (AIL_set_sample_buffer_count, 2..8) must be honored
// by the transport: a 4-deep ring stores and drains slots 0..3 in order, firing
// EOB per drain. (Regression: the transport used to be a fixed ping-pong and
// silently dropped submissions to slot >= 2 while the loader reported success.)
test "StreamSource honors a 4-slot ring end to end" {
    var ctx = StreamTestCtx{};
    var ss: openmiles.StreamSource = undefined;
    try ss.init(16, 2, 44100, streamTestHook, &ctx); // 16-bit stereo → 4 bytes/frame
    defer ss.deinit();
    ss.setSlotCount(4); // the public path the driver's buffer-count setter uses

    const buf_a = [_]u8{ 1, 2, 3, 4 }; // 1 frame each
    const buf_b = [_]u8{ 5, 6, 7, 8 };
    const buf_c = [_]u8{ 9, 10, 11, 12 };
    const buf_d = [_]u8{ 13, 14, 15, 16 };
    _ = ss.loadBuffer(0, &buf_a, buf_a.len);
    _ = ss.loadBuffer(1, &buf_b, buf_b.len);
    _ = ss.loadBuffer(2, &buf_c, buf_c.len);
    _ = ss.loadBuffer(3, &buf_d, buf_d.len);
    try testing.expectEqual(@as(i32, -1), ss.bufferReady()); // ring full

    var out: [20]u8 = [_]u8{0xAA} ** 20; // request 5 frames; only 4 are queued
    var read: u64 = 0;
    const r = openmiles.ma.ma_data_source_read_pcm_frames(&ss.base, &out, 5, &read);
    try testing.expectEqual(openmiles.ma.MA_SUCCESS, r); // underrun, not ended
    try testing.expectEqual(@as(u64, 5), read); // 5th frame padded with silence
    try testing.expectEqualSlices(u8, &buf_a, out[0..4]);
    try testing.expectEqualSlices(u8, &buf_b, out[4..8]);
    try testing.expectEqualSlices(u8, &buf_c, out[8..12]);
    try testing.expectEqualSlices(u8, &buf_d, out[12..16]);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 4), out[16..20]);
    // Every drain fired its hook, in ring order.
    try testing.expectEqual(@as(u32, 4), ctx.eob_count);
    try testing.expectEqual(@as(i32, 3), ctx.last_idx);
    // All four slots are free again.
    try testing.expectEqual(@as(i32, 0), ss.bufferReady());
}

// A buffer handed to loadBuffer twice must leave the ring as one submission
// left it: the queued samples are played and their EOB fires once. Overwriting
// an occupied slot would drop those samples without an EOB, so a retried feed
// would truncate the stream.
test "StreamSource a repeated submit into a live slot keeps the first buffer" {
    var ctx = StreamTestCtx{};
    var ss: openmiles.StreamSource = undefined;
    try ss.init(16, 2, 44100, streamTestHook, &ctx); // 16-bit stereo → 4 bytes/frame
    defer ss.deinit();

    const buf_a = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }; // 2 frames
    const buf_b = [_]u8{ 9, 9, 9, 9, 9, 9, 9, 9 }; // the repeat
    _ = ss.loadBuffer(0, &buf_a, buf_a.len);
    // The repeat is reported, not taken: the caller has to learn that its
    // submission was dropped.
    try testing.expect(!ss.loadBuffer(0, &buf_b, buf_b.len));
    // The repeat did not free the slot, and did not replace the queued data:
    // the other slot is still the only one the app may fill.
    try testing.expectEqual(@as(i32, 1), ss.bufferReady());

    var out: [16]u8 = undefined;
    var read: u64 = 0;
    // 4 frames requested: 2 from buf_a, then the drain, then underrun padding.
    const r = openmiles.ma.ma_data_source_read_pcm_frames(&ss.base, &out, 4, &read);
    try testing.expectEqual(openmiles.ma.MA_SUCCESS, r);
    try testing.expectEqual(@as(u64, 4), read);
    try testing.expectEqualSlices(u8, &buf_a, out[0..8]);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 8), out[8..16]);
    try testing.expectEqual(@as(u32, 1), ctx.eob_count);
    try testing.expectEqual(@as(i32, 0), ctx.last_idx);
    try testing.expectEqual(@as(u32, buf_a.len), ctx.last_len);
    // The hook must hand back the address the app submitted, since that is the
    // buffer the app now owns again; handing back the repeat instead would
    // make it free the wrong one.
    try testing.expectEqualSlices(u8, &buf_a, @as([*]const u8, @ptrCast(ctx.last_addr.?))[0..buf_a.len]);
    // Drained: the slot is free again and takes a new buffer, which plays.
    try testing.expectEqual(@as(i32, 0), ss.bufferReady());
    _ = ss.loadBuffer(0, &buf_b, buf_b.len);
    var out2: [16]u8 = undefined;
    var read2: u64 = 0;
    const r2 = openmiles.ma.ma_data_source_read_pcm_frames(&ss.base, &out2, 4, &read2);
    try testing.expectEqual(openmiles.ma.MA_SUCCESS, r2);
    try testing.expectEqual(@as(u64, 4), read2);
    try testing.expectEqualSlices(u8, &buf_b, out2[0..8]);
    try testing.expectEqual(@as(u32, 2), ctx.eob_count);
}

// --- MSS v8/v9 implemented utilities ----------------------------------------
const api_v8 = @import("api/v8.zig");
const api_v9 = @import("api/v9.zig");
const dg = @import("api/digital.zig");
const api_file = @import("api/file.zig");
const api_quick = @import("api/quick.zig");
const api_redbook = @import("api/redbook.zig");

test "AIL_quick_set_volume: S32 0..127 form vs F32 0..1 form (version split)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    // S32 form (exported through 6.1): volume/extravol are 0..127.
    // 64 scaled by extravol 127/127 -> 64.
    api_quick.AIL_quick_set_volume(s, 64, 127);
    try testing.expectEqual(@as(i32, 64), s.original_volume);
    // F32 form (6.2+, the quick_set_volume_f32 backing): volume/extravol are 0..1.
    // 0.5 * 1.0 -> 0.5*127 = 63.
    api_quick.AIL_quick_set_volume_f32(s, 0.5, 1.0);
    try testing.expectEqual(@as(i32, 63), s.original_volume);
    // F32 clamps to 0..1, so an out-of-range 2.0 saturates to full (127) -- NOT
    // the bit-reinterpreted garbage the S32 path would produce for a float.
    api_quick.AIL_quick_set_volume_f32(s, 2.0, 1.0);
    try testing.expectEqual(@as(i32, 127), s.original_volume);
}

test "v8 AIL_mem in-memory stream round-trips" {
    const m = api_v8.AIL_mem_create() orelse return error.NoMem;
    defer _ = api_v8.AIL_mem_close(m, null, null);
    var src = "hello world".*;
    try testing.expectEqual(@as(i32, 11), api_v8.AIL_mem_write(m, &src, 11));
    try testing.expectEqual(@as(i32, 11), api_v8.AIL_mem_pos(m));
    try testing.expectEqual(@as(i32, 11), api_v8.AIL_mem_size(m));
    try testing.expectEqual(@as(i32, 0), api_v8.AIL_mem_seek(m, 0));
    var dst: [16]u8 = undefined;
    try testing.expectEqual(@as(i32, 11), api_v8.AIL_mem_read(m, &dst, 11));
    try testing.expectEqualSlices(u8, "hello world", dst[0..11]);
    // Read past end returns 0; write past capacity truncates + flags error.
    try testing.expectEqual(@as(i32, 0), api_v8.AIL_mem_read(m, &dst, 8));
}

test "AIL_mem_close returns S32 1 and hands back the buffer + size (SDK)" {
    // SDK (miscutil.cpp): S32 return, 1 on success; *size and *buf are filled.
    const m = api_v8.AIL_mem_create() orelse return error.NoMem;
    var src = "payload!".*;
    try testing.expectEqual(@as(i32, 8), api_v8.AIL_mem_write(m, &src, 8));
    var data: ?*anyopaque = null;
    var size: u32 = 0;
    try testing.expectEqual(@as(i32, 1), api_v8.AIL_mem_close(m, &data, &size)); // S32 success
    try testing.expectEqual(@as(u32, 8), size);
    try testing.expect(data != null);
    const got: [*]const u8 = @ptrCast(data.?);
    try testing.expectEqualSlices(u8, "payload!", got[0..8]);
    std.c.free(data); // AIL_mem_close hands back a malloc'd copy
    // SDK: a NULL handle returns 1 and writes nothing (the body is `if (m)`).
    var d2: ?*anyopaque = @ptrFromInt(0xABCD);
    var s2: u32 = 0xDEAD;
    try testing.expectEqual(@as(i32, 1), api_v8.AIL_mem_close(null, &d2, &s2));
    try testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0xABCD)), d2); // untouched
    try testing.expectEqual(@as(u32, 0xDEAD), s2); // untouched
}

test "v8 AIL_mem_open read-only view" {
    var data = "abcdef".*;
    const m = api_v8.AIL_mem_open(&data, 6) orelse return error.NoMem;
    defer _ = api_v8.AIL_mem_close(m, null, null);
    var dst: [8]u8 = undefined;
    try testing.expectEqual(@as(i32, 3), api_v8.AIL_mem_read(m, &dst, 3));
    try testing.expectEqualSlices(u8, "abc", dst[0..3]);
}

test "v8 case-insensitive string compares" {
    var a = "Hello".*;
    var b = "hELLo".*;
    var c = "World".*;
    try testing.expectEqual(@as(i32, 0), api_v8.AIL_stricmp(&a, &b));
    try testing.expect(api_v8.AIL_stricmp(&a, &c) != 0);
    try testing.expectEqual(@as(i32, 0), api_v8.AIL_strnicmp(&a, &c, 0));
    var d = "HELxx".*;
    try testing.expectEqual(@as(i32, 0), api_v8.AIL_strnicmp(&a, &d, 3));
    try testing.expect(api_v8.AIL_strnicmp(&a, &d, 4) != 0);
}

test "v9 64-bit counters advance monotonically and time conversions" {
    // Each clock must strictly advance (bounded poll, same pattern as the
    // getMsCount/getUsCount tests) -- a frozen or backwards counter breaks
    // every ms-position/dead-reckoning consumer, so >= alone is not enough.
    const t0 = api_v9.AIL_ms_count64();
    var waited: u32 = 0;
    while (api_v9.AIL_ms_count64() == t0 and waited < 5000) : (waited += 10) {
        openmiles.io.sleep(std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
    }
    try testing.expect(api_v9.AIL_ms_count64() > t0);

    const us0 = api_v9.AIL_us_count64();
    waited = 0;
    while (api_v9.AIL_us_count64() == us0 and waited < 5000) : (waited += 10) {
        openmiles.io.sleep(std.Io.Duration.fromNanoseconds(10 * std.time.ns_per_ms), .awake) catch {};
    }
    try testing.expect(api_v9.AIL_us_count64() > us0);

    // Conversions: ms -> us ticks and back.
    try testing.expectEqual(@as(u64, 5000), api_v9.AIL_ms_to_time(5));
    try testing.expectEqual(@as(u64, 5), api_v9.AIL_time_to_ms(5000));
}

// --- MSS v8 SoundBank loader (synthetic bank) -------------------------------

fn buildSyntheticBank(buf: []u8) usize {
    @memset(buf, 0);
    const w = std.mem.writeInt;
    // Header
    w(u32, buf[0..4], (@as(u32, 'B') << 24) | (@as(u32, 'A') << 16) | (@as(u32, 'N') << 8) | 'K', .little); // Tag
    w(i32, buf[4..8], 8, .little); // Version
    // meta_size filled below
    w(u32, buf[20..24], 0, .little); // events off (count 0)
    w(u32, buf[24..28], 0, .little); // envs
    w(u32, buf[28..32], 0, .little); // presets
    w(u32, buf[32..36], 60, .little); // sounds table at offset 60
    w(u32, buf[40..44], 0, .little); // event_count
    w(u32, buf[44..48], 0, .little); // env_count
    w(u32, buf[48..52], 0, .little); // preset_count
    w(u32, buf[52..56], 2, .little); // sound_count
    @memcpy(buf[56..60], "TST\x00"); // SoundBankName[4]
    // Sounds table (2 AssetEntry, 8 bytes each) at 60
    w(u32, buf[60..64], 76, .little); // Sounds[0].NameOffset
    w(u32, buf[64..68], 0, .little);
    w(u32, buf[68..72], 81, .little); // Sounds[1].NameOffset
    w(u32, buf[72..76], 0, .little);
    // String table
    @memcpy(buf[76..81], "kick\x00");
    @memcpy(buf[81..87], "snare\x00");
    const meta_size: usize = 87;
    w(i32, buf[8..12], @intCast(meta_size), .little);
    return meta_size;
}

test "v8 SoundBank loads and enumerates assets (synthetic)" {
    var img: [128]u8 = undefined;
    const sz = buildSyntheticBank(&img);
    const bank = try openmiles.soundbank.loadFromMemory(testing.allocator, "test.bank", img[0..sz]);
    defer bank.deinit();
    try testing.expectEqual(@as(i32, @intCast(sz)), bank.metaSize());
    try testing.expectEqualStrings("TST", std.mem.span(bank.name()));
    try testing.expectEqual(@as(u32, 2), bank.assetCount(.sounds));
    try testing.expectEqualStrings("kick", std.mem.span(bank.assetName(.sounds, 0).?));
    try testing.expectEqualStrings("snare", std.mem.span(bank.assetName(.sounds, 1).?));
    try testing.expect(bank.assetName(.sounds, 2) == null); // out of range
    try testing.expectEqual(@as(u32, 0), bank.assetCount(.events));
}

test "v8 SoundBank name is terminated when all 4 chars are non-NUL" {
    // SoundBankName[4] is a fixed-width field; a bank using all four bytes must
    // not send the C-string scan past the metadata allocation (over-read).
    var img: [128]u8 = undefined;
    const sz = buildSyntheticBank(&img);
    @memcpy(img[56..60], "ABCD");
    const bank = try openmiles.soundbank.loadFromMemory(testing.allocator, "test.bank", img[0..sz]);
    defer bank.deinit();
    try testing.expectEqualStrings("ABCD", std.mem.span(bank.name()));
}

test "v8 SoundBank rejects non-bank and truncated data" {
    try testing.expectError(error.TooShort, openmiles.soundbank.loadFromMemory(testing.allocator, "x", "short"));
    var img: [128]u8 = undefined;
    const sz = buildSyntheticBank(&img);
    // Corrupt the tag.
    img[0] = 'X';
    try testing.expectError(error.NotABank, openmiles.soundbank.loadFromMemory(testing.allocator, "x", img[0..sz]));
    // Lying sound_count -> asset table escapes meta.
    _ = buildSyntheticBank(&img);
    std.mem.writeInt(u32, img[52..56], 1000, .little);
    try testing.expectError(error.BadAssetTable, openmiles.soundbank.loadFromMemory(testing.allocator, "x", img[0..sz]));
}

test "v9 sample groups operate on samples by id" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const a = try openmiles.Sample.init(drv);
    defer a.deinit();
    const b = try openmiles.Sample.init(drv);
    defer b.deinit();
    const c = try openmiles.Sample.init(drv);
    defer c.deinit();
    api_v9.AIL_set_sample_id(a, 5);
    api_v9.AIL_set_sample_id(b, 5);
    api_v9.AIL_set_sample_id(c, 7);
    // Start group 5, re-tagging matched samples to 9.
    api_v9.AIL_start_sample_group(drv, 5, 9);
    try testing.expectEqual(@as(i32, 9), api_v9.AIL_sample_id(a));
    try testing.expectEqual(@as(i32, 9), api_v9.AIL_sample_id(b));
    try testing.expectEqual(@as(i32, 7), api_v9.AIL_sample_id(c)); // untouched
    // A non-matching group id is a no-op.
    api_v9.AIL_stop_sample_group(drv, 1234, 0);
    try testing.expectEqual(@as(i32, 9), api_v9.AIL_sample_id(a));
}

const api_v7 = @import("api/v7.zig");
const api_stream = @import("api/stream.zig");
const api_3d = @import("api/3d.zig");
const api_dls = @import("api/dls.zig");
const api_midi = @import("api/midi.zig");

test "AIL_open_stream_by_sample (6.1a leaked internal) is a safe null stub" {
    // Undocumented, never in any header; no behavior to reproduce. The contract
    // we hold is that it links and returns a defined failure (null) for any args.
    try testing.expectEqual(@as(?*openmiles.Sample, null), api_stream.AIL_open_stream_by_sample(null, null, null, 0));
    var scratch: [4]u8 = .{ 1, 2, 3, 4 };
    const p: *anyopaque = @ptrCast(&scratch);
    try testing.expectEqual(@as(?*openmiles.Sample, null), api_stream.AIL_open_stream_by_sample(p, p, p, -1));
}

test "AIL_decompress_ASI decodes to a WAV (runs the decode loop; align-safe)" {
    const api_rib = @import("api/rib.zig");
    // A real PCM WAV (mono) that miniaudio can decode through the ASI path.
    const pcm = [_]u8{0} ** 512;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 22050, 16);
    defer testing.allocator.free(wav);
    var out_ptr: ?*anyopaque = null;
    var out_size: u32 = 0;
    const rc = api_rib.AIL_decompress_ASI(wav.ptr, @intCast(wav.len), null, &out_ptr, &out_size, null);
    try testing.expectEqual(@as(i32, 1), rc);
    try testing.expect(out_ptr != null and out_size > 0);
    defer std.c.free(out_ptr);
    // Output is a valid 16-bit PCM WAV (the decode loop wrote i16 samples).
    var info: openmiles.AILSOUNDINFO = .{};
    try testing.expect(dg.AIL_WAV_info(out_ptr.?, &info) != 0);
    try testing.expectEqual(@as(i32, 1), info.format);
    try testing.expectEqual(@as(i32, 16), info.bits);
}

test "AIL_MIDI_to_XMI allocates the output and returns it via XMIDI** (SDK)" {
    const smf = [_]u8{ 'M', 'T', 'h', 'd', 1, 2, 3, 4, 5, 6, 7, 8 };
    // Size query: null output pointer, just reports the size.
    var size: u32 = 0;
    try testing.expectEqual(@as(i32, 1), api_midi.AIL_MIDI_to_XMI(@ptrCast(@constCast(&smf)), smf.len, null, &size, 0));
    try testing.expectEqual(@as(u32, smf.len), size);
    // Conversion: the function allocates a buffer and returns its pointer; the
    // caller's pointer variable is NOT overwritten with the data (no overflow).
    var out_ptr: ?*anyopaque = null;
    size = 0;
    try testing.expectEqual(@as(i32, 1), api_midi.AIL_MIDI_to_XMI(@ptrCast(@constCast(&smf)), smf.len, &out_ptr, &size, 0));
    try testing.expect(out_ptr != null);
    try testing.expectEqual(@as(u32, smf.len), size);
    const got: [*]const u8 = @ptrCast(out_ptr.?);
    try testing.expectEqualSlices(u8, &smf, got[0..smf.len]);
    std.c.free(out_ptr);
    // Empty input -> 0, output pointer set null.
    out_ptr = @ptrFromInt(0x1234);
    try testing.expectEqual(@as(i32, 0), api_midi.AIL_MIDI_to_XMI(@ptrCast(@constCast(&smf)), 0, &out_ptr, &size, 0));
    try testing.expectEqual(@as(?*anyopaque, null), out_ptr);
}

test "AIL_lock_channel/release_channel take the MIDI driver handle (SDK)" {
    const driver = try openmiles.MidiDriver.init(testing.allocator);
    defer driver.deinit();
    for (&openmiles.locked_channels.*) |*slot| slot.* = null;
    const ch = api_midi.AIL_lock_channel(driver); // HMDIDRIVER, not a sequence
    try testing.expect(ch >= 0 and ch <= 15 and ch != 9);
    try testing.expect(openmiles.locked_channels[@intCast(ch)] != null);
    api_midi.AIL_release_channel(driver, ch);
    try testing.expectEqual(@as(?*anyopaque, null), openmiles.locked_channels[@intCast(ch)]);
}
test "v9 update_sample_3D_position dead-reckons by velocity" {
    const s = try loadedSample(testing.allocator, 64, 1, 8000);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();
    api_v7.AIL_set_sample_3D_position(s, 0, 0, 0);
    api_v7.AIL_set_sample_3D_velocity(s, 10, 0, 0, 1); // 10 units/ms on +x (magnitude 1)
    // SDK m3d.cpp: position += velocity * dt_ms (velocity is per-millisecond, so
    // dt is used directly). 10/ms over 25 ms -> +250 on x.
    api_v7.AIL_update_sample_3D_position(s, 25);
    var px: f32 = 0;
    _ = api_v7.AIL_sample_3D_position(s, &px, null, null);
    try testing.expectApproxEqAbs(@as(f32, 250.0), px, 0.01);
    // NaN dt is ignored (no crash, position unchanged).
    api_v7.AIL_update_sample_3D_position(s, std.math.nan(f32));
    _ = api_v7.AIL_sample_3D_position(s, &px, null, null);
    try testing.expectApproxEqAbs(@as(f32, 250.0), px, 0.01);
    // Zero velocity -> update is a no-op (SDK early-outs below MSS_EPSILON).
    api_v7.AIL_set_sample_3D_velocity(s, 0, 0, 0, 1);
    api_v7.AIL_update_sample_3D_position(s, 1000);
    _ = api_v7.AIL_sample_3D_position(s, &px, null, null);
    try testing.expectApproxEqAbs(@as(f32, 250.0), px, 0.01);
}

test "v7 set_sample_3D_velocity scales the direction by magnitude" {
    const s = try loadedSample(testing.allocator, 64, 1, 8000);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();
    // SDK multiplies each component by magnitude before storing. Unit +x dir × 7.
    api_v7.AIL_set_sample_3D_velocity(s, 1, 0, 0, 7);
    var vx: f32 = 0;
    var vy: f32 = 0;
    var vz: f32 = 0;
    api_v7.AIL_sample_3D_velocity(s, &vx, &vy, &vz);
    try testing.expect(@abs(vx - 7) < 0.001 and @abs(vy) < 0.001 and @abs(vz) < 0.001);
    // magnitude 0 yields a zero velocity vector (not the old "ignored" behavior).
    api_v7.AIL_set_sample_3D_velocity(s, 3, 4, 5, 0);
    api_v7.AIL_sample_3D_velocity(s, &vx, &vy, &vz);
    try testing.expect(@abs(vx) < 0.001 and @abs(vy) < 0.001 and @abs(vz) < 0.001);
}

test "v7 unified 3D pos/vel/orient round-trip in MSS left-handed space" {
    const s = try loadedSample(testing.allocator, 64, 1, 8000);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();

    // Position: set MSS-space (1,2,3), the getter returns the same values.
    api_v7.AIL_set_sample_3D_position(s, 1, 2, 3);
    var px: f32 = 0;
    var py: f32 = 0;
    var pz: f32 = 0;
    try testing.expectEqual(@as(i32, 1), api_v7.AIL_sample_3D_position(s, &px, &py, &pz)); // is_3D now set
    try testing.expect(@abs(px - 1) < 0.001 and @abs(py - 2) < 0.001 and @abs(pz - 3) < 0.001);
    // miniaudio stores Z negated (right-handed boundary).
    try testing.expect(@abs(openmiles.ma.ma_sound_get_position(&s.sound).z - (-3)) < 0.001);

    // Velocity round-trips with Z preserved in MSS space (magnitude 1 = no scale).
    api_v7.AIL_set_sample_3D_velocity(s, 4, 5, 6, 1);
    var vx: f32 = 0;
    var vy: f32 = 0;
    var vz: f32 = 0;
    api_v7.AIL_sample_3D_velocity(s, &vx, &vy, &vz);
    try testing.expect(@abs(vx - 4) < 0.001 and @abs(vy - 5) < 0.001 and @abs(vz - 6) < 0.001);

    // Orientation face round-trips; +Z forward stays +Z forward.
    api_v7.AIL_set_sample_3D_orientation(s, 0, 0, 1, 0, 1, 0);
    var fx: f32 = 0;
    var fy: f32 = 0;
    var fz: f32 = 0;
    var ux: f32 = 0;
    var uy: f32 = 0;
    var uz: f32 = 0;
    api_v7.AIL_sample_3D_orientation(s, &fx, &fy, &fz, &ux, &uy, &uz);
    try testing.expect(@abs(fx) < 0.001 and @abs(fy) < 0.001 and @abs(fz - 1) < 0.001);
    try testing.expect(@abs(ux) < 0.001 and @abs(uy - 1) < 0.001 and @abs(uz) < 0.001);
}

test "v7 3D position/velocity round-trip via S3D struct (uninitialized sample)" {
    // The SDK returns S3D.position/velocity verbatim regardless of init state;
    // reading ma_sound (only valid post-load) lost values set before loading.
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv); // never loaded -> not initialized
    defer s.deinit();

    var px: f32 = -1;
    var py: f32 = -1;
    var pz: f32 = -1;
    // Fresh, un-positioned sample: is_3D=0, position 0,0,0.
    try testing.expectEqual(@as(i32, 0), api_v7.AIL_sample_3D_position(s, &px, &py, &pz));
    try testing.expect(px == 0 and py == 0 and pz == 0);

    api_v7.AIL_set_sample_3D_position(s, 11, 22, 33);
    try testing.expectEqual(@as(i32, 1), api_v7.AIL_sample_3D_position(s, &px, &py, &pz)); // 3D enabled
    try testing.expectEqual(@as(f32, 11), px);
    try testing.expectEqual(@as(f32, 22), py);
    try testing.expectEqual(@as(f32, 33), pz); // Z not flipped on the way out

    var vx: f32 = 0;
    var vy: f32 = 0;
    var vz: f32 = 0;
    api_v7.AIL_set_sample_3D_velocity(s, 2, 3, 4, 5); // magnitude 5 -> (10,15,20)
    api_v7.AIL_sample_3D_velocity(s, &vx, &vy, &vz);
    try testing.expectEqual(@as(f32, 10), vx);
    try testing.expectEqual(@as(f32, 15), vy);
    try testing.expectEqual(@as(f32, 20), vz);

    // update advances position by velocity * dt_ms even before init.
    api_v7.AIL_set_sample_3D_velocity(s, 1, 0, 0, 1);
    api_v7.AIL_update_sample_3D_position(s, 10); // +10 on x
    _ = api_v7.AIL_sample_3D_position(s, &px, null, null);
    try testing.expectEqual(@as(f32, 21), px); // 11 + 1*10
}

test "AIL_3D_sample_attribute Position returns MSS-space Z (not negated) when live" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample3D.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false); // is_initialized = true (exercises the bug path)

    api_3d.AIL_set_3D_position(@as(*anyopaque, @ptrCast(s)), 1.0, 2.0, 3.0);
    var pos: [3]f32 = .{ 0, 0, 0 };
    api_3d.AIL_3D_sample_attribute(@as(*anyopaque, @ptrCast(s)), "Position", @ptrCast(&pos));
    try testing.expectApproxEqAbs(@as(f32, 1.0), pos[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), pos[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 3.0), pos[2], 0.001); // +Z, not -3
    // Consistent with the dedicated getter.
    var gx: f32 = 0;
    var gy: f32 = 0;
    var gz: f32 = 0;
    api_3d.AIL_3D_position(@as(*anyopaque, @ptrCast(s)), &gx, &gy, &gz);
    try testing.expectApproxEqAbs(@as(f32, 3.0), gz, 0.001);
}

test "AIL_sample_3D_cone round-trips inner/outer degrees + verbatim outer_volume" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv); // uninitialized
    defer s.deinit();

    var inner: f32 = -1;
    var outer: f32 = -1;
    var gain: f32 = -1;
    // Defaults match wavefile.cpp AIL_init_sample: 360/360/1.0.
    api_v7.AIL_sample_3D_cone(s, &inner, &outer, &gain);
    try testing.expectApproxEqAbs(@as(f32, 360.0), inner, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 360.0), outer, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), gain, 0.001);

    // Round-trip (uninitialized): degrees recovered exactly, outer_volume verbatim.
    api_v7.AIL_set_sample_3D_cone(s, 30.0, 90.0, 0.25);
    api_v7.AIL_sample_3D_cone(s, &inner, &outer, &gain);
    try testing.expectApproxEqAbs(@as(f32, 30.0), inner, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 90.0), outer, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), gain, 0.001);

    // SDK stores outer_volume verbatim (no clamp) -> out-of-range round-trips.
    api_v7.AIL_set_sample_3D_cone(s, 45.0, 120.0, 1.5);
    api_v7.AIL_sample_3D_cone(s, &inner, &outer, &gain);
    try testing.expectApproxEqAbs(@as(f32, 1.5), gain, 0.001);
}

test "v7/v8 is_3D: position enables it, getter & set_sample_is_3D return it (SDK)" {
    const s = try loadedSample(testing.allocator, 64, 1, 8000);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();
    var a: f32 = 0;
    // Fresh sample is not yet 3D: getter returns 0.
    try testing.expectEqual(@as(i32, 0), api_v7.AIL_sample_3D_position(s, &a, &a, &a));
    // Specifying a 3D position enables 3D (stays set).
    api_v7.AIL_set_sample_3D_position(s, 1, 2, 3);
    try testing.expectEqual(@as(i32, 1), api_v7.AIL_sample_3D_position(s, &a, &a, &a));
    // AIL_set_sample_is_3D stores onoff verbatim and returns the previous value.
    try testing.expectEqual(@as(i32, 1), api_v8.AIL_set_sample_is_3D(s, 0)); // old was 1
    try testing.expectEqual(@as(i32, 0), api_v7.AIL_sample_3D_position(s, &a, &a, &a));
    try testing.expectEqual(@as(i32, 0), api_v8.AIL_set_sample_is_3D(s, 7)); // old was 0
    try testing.expectEqual(@as(i32, 7), api_v7.AIL_sample_3D_position(s, &a, &a, &a)); // verbatim store
    // Re-init clears 3D state.
    s.reset();
    try testing.expectEqual(@as(i32, 0), api_v7.AIL_sample_3D_position(s, &a, &a, &a));
}

test "v7 set_sample_3D_orientation normalizes face & up and round-trips both" {
    const s = try loadedSample(testing.allocator, 64, 1, 8000);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();
    // Non-unit face (0,0,5) -> (0,0,1); non-unit, non-axis up (0,3,4) -> (0,0.6,0.8).
    api_v7.AIL_set_sample_3D_orientation(s, 0, 0, 5, 0, 3, 4);
    var fx: f32 = 0;
    var fy: f32 = 0;
    var fz: f32 = 0;
    var ux: f32 = 0;
    var uy: f32 = 0;
    var uz: f32 = 0;
    api_v7.AIL_sample_3D_orientation(s, &fx, &fy, &fz, &ux, &uy, &uz);
    try testing.expect(@abs(fx) < 0.001 and @abs(fy) < 0.001 and @abs(fz - 1) < 0.001);
    try testing.expect(@abs(ux) < 0.001 and @abs(uy - 0.6) < 0.001 and @abs(uz - 0.8) < 0.001);
    // A zero-length vector is left unchanged (SDK guards len > 1e-4): up stays (0,0,0).
    api_v7.AIL_set_sample_3D_orientation(s, 1, 0, 0, 0, 0, 0);
    api_v7.AIL_sample_3D_orientation(s, &fx, &fy, &fz, &ux, &uy, &uz);
    try testing.expect(@abs(ux) < 0.001 and @abs(uy) < 0.001 and @abs(uz) < 0.001);
}

test "v7 sample_volume_levels returns the L/R scalars verbatim (SDK)" {
    const s = try loadedSample(testing.allocator, 64, 1, 8000);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();

    // The SDK stores left_volume/right_volume verbatim and the getter returns
    // them exactly -- no quantization through volume+pan.
    api_v7.AIL_set_sample_volume_levels(s, 0.8, 0.2);
    var l: f32 = 0;
    var r: f32 = 0;
    api_v7.AIL_sample_volume_levels(s, &l, &r);
    try testing.expectEqual(@as(f32, 0.8), l);
    try testing.expectEqual(@as(f32, 0.2), r);

    // set_sample_volume_levels also reconstructs save_pan/save_volume (wavefile.cpp):
    // ratio=(0.2/0.8)^(10/3)=0.00982 -> save_pan=0.00972;
    // save_volume=0.2*save_pan^-0.3=0.803 -> volume_pan returns save_volume^0.6=0.876.
    var vol: f32 = 0;
    var pan: f32 = 0;
    api_v7.AIL_sample_volume_pan(s, &vol, &pan);
    try testing.expect(@abs(pan - 0.00972) < 0.001);
    try testing.expect(@abs(vol - 0.876) < 0.003);

    // Setting via volume_pan also updates the reported L/R scalars
    // (left=gain*0.812..., right=gain*0.812... for centre, vol=1).
    dg.AIL_set_sample_volume_pan(s, 1.0, 0.5);
    api_v7.AIL_sample_volume_levels(s, &l, &r);
    try testing.expect(@abs(l - 0.812252196) < 0.001 and @abs(r - 0.812252196) < 0.001);
}

test "set_sample_volume_pan applies the 4+ channel front/back factor (SDK)" {
    // Stereo (<4 ch): centre vol=1 -> L/R = 0.812252196 (no extra factor).
    const st = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer st.deinit();
    const ss = try openmiles.Sample.init(st);
    defer ss.deinit();
    ss.setVolumePanF(1.0, 0.5);
    try testing.expect(@abs(ss.v51_levels[0] - 0.812252196) < 0.0005);
    // 5.1 (>=4 ch): the SDK multiplies the front L/R by an extra 0.812252196.
    const mc = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 6);
    defer mc.deinit();
    try testing.expect(openmiles.ma.ma_engine_get_channels(&mc.engine) >= 4); // 6ch honored (noDevice)
    const ms = try openmiles.Sample.init(mc);
    defer ms.deinit();
    ms.setVolumePanF(1.0, 0.5);
    try testing.expect(@abs(ms.v51_levels[0] - (0.812252196 * 0.812252196)) < 0.0005);

    // Same via the public API path (AIL_set_sample_volume_pan -> volume_levels).
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const ms2 = try openmiles.Sample.init(mc);
    defer ms2.deinit();
    try ms2.loadFromMemory(wav, false);
    dg.AIL_set_sample_volume_pan(ms2, 1.0, 0.5);
    var l: f32 = 0;
    var r: f32 = 0;
    api_v7.AIL_sample_volume_levels(ms2, &l, &r);
    try testing.expect(@abs(l - (0.812252196 * 0.812252196)) < 0.0005);
    try testing.expect(@abs(r - (0.812252196 * 0.812252196)) < 0.0005);
}

test "a non-finite volume level fails safe to silence" {
    // clamp() maps NaN to the upper bound (@min/@max skip NaN), so the peak
    // taken here used to reach unity gain from garbage input. setVolumePanF
    // already guards the same way; the level path has to agree with it.
    const s = try loadedSample(testing.allocator, 64, 1, 8000);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();

    s.setVolumeLevels(std.math.nan(f32), std.math.nan(f32));
    try testing.expectEqual(@as(i32, 0), dg.AIL_sample_volume(s));
}

test "infinite volume levels fail safe to centre, not hard right" {
    // Inf + Inf is Inf, so the L/R balance ratio is NaN. clamp() maps NaN to
    // the upper bound, which drove the pan to 127 (hard right) on top of the
    // full volume the peak already gives; centre is the neutral answer.
    const s = try loadedSample(testing.allocator, 64, 1, 8000);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();

    s.setVolumeLevels(std.math.inf(f32), std.math.inf(f32));
    // 0.5 * 127 truncates to 63, the same centre the pan=0.5 float setter stores.
    try testing.expectEqual(@as(i32, 63), dg.AIL_sample_pan(s));

    // A finite pair still balances the usual way.
    s.setVolumeLevels(1.0, 0.0);
    try testing.expectEqual(@as(i32, 0), dg.AIL_sample_pan(s));
}

test "v7 master reverb decay/predelay/damping all round-trip" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    api_v7.AIL_set_digital_master_reverb(drv, 0, 1.5, 0.02, 0.7);
    var t: f32 = 0;
    var pd: f32 = 0;
    var dmp: f32 = 0;
    api_v7.AIL_digital_master_reverb(drv, 0, &t, &pd, &dmp);
    try testing.expect(@abs(t - 1.5) < 0.001);
    try testing.expect(@abs(pd - 0.02) < 0.001); // formerly hardcoded to 0
    try testing.expect(@abs(dmp - 0.7) < 0.001); // formerly hardcoded to 0
}

test "6.5/6.6 stream volume/reverb/low-pass round-trip" {
    const s = try loadedSample(testing.allocator, 64, 1, 8000);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();

    // Stream volume levels reconstruct like the sample form.
    api_stream.AIL_set_stream_volume_levels(s, 0.8, 0.2);
    var l: f32 = 0;
    var r: f32 = 0;
    api_stream.AIL_stream_volume_levels(s, &l, &r);
    try testing.expect(l > r and @abs(l - 0.8) < 0.02 and @abs(r - 0.2) < 0.02);

    // Combined volume/pan getter returns what the setter stored.
    api_stream.AIL_set_stream_volume_pan(s, 0.5, 0.75);
    var vol: f32 = 0;
    var pan: f32 = 0;
    api_stream.AIL_stream_volume_pan(s, &vol, &pan);
    try testing.expect(@abs(vol - 0.5) < 0.02 and @abs(pan - 0.75) < 0.02);

    // Reverb dry/wet stored independently.
    api_stream.AIL_set_stream_reverb_levels(s, 0.3, 0.6);
    var dry: f32 = 0;
    var wet: f32 = 0;
    api_stream.AIL_stream_reverb_levels(s, &dry, &wet);
    try testing.expect(@abs(dry - 0.3) < 0.001 and @abs(wet - 0.6) < 0.001);

    // Low-pass cutoff is MSS's normalized 0..1 (default 1.0 = fully open). It
    // round-trips through the stored value regardless of filter attachment.
    try testing.expectEqual(@as(f32, 1.0), api_stream.AIL_stream_low_pass_cut_off(s)); // default open
    try testing.expectEqual(@as(f32, 1.0), api_stream.AIL_stream_low_pass_cut_off(null)); // null -> open, not 0
    api_stream.AIL_set_stream_low_pass_cut_off(s, 0.5);
    try testing.expectEqual(@as(f32, 0.5), api_stream.AIL_stream_low_pass_cut_off(s));
    api_stream.AIL_set_stream_low_pass_cut_off(s, 4000.0); // >= 0.999 -> fully open
    try testing.expectEqual(@as(f32, 1.0), api_stream.AIL_stream_low_pass_cut_off(s));
}

test "6.5/6.6 3D sample exclusion round-trips" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample3D.init(drv);
    defer s.deinit();
    api_3d.AIL_set_3D_sample_exclusion(s, 0.42);
    try testing.expect(@abs(api_3d.AIL_3D_sample_exclusion(s) - 0.42) < 0.001);
    // SDK m3d.cpp stores verbatim -- out-of-range must round-trip un-clamped.
    api_3d.AIL_set_3D_sample_exclusion(s, 5.0);
    try testing.expectEqual(@as(f32, 5.0), api_3d.AIL_3D_sample_exclusion(s));
    api_3d.AIL_set_3D_sample_exclusion(s, -2.0);
    try testing.expectEqual(@as(f32, -2.0), api_3d.AIL_3D_sample_exclusion(s));
    // Obstruction & occlusion likewise store verbatim (m3d.cpp).
    api_3d.AIL_set_3D_sample_obstruction(s, 3.5);
    try testing.expectEqual(@as(f32, 3.5), api_3d.AIL_3D_sample_obstruction(s));
    api_3d.AIL_set_3D_sample_occlusion(s, 2.25);
    try testing.expectEqual(@as(f32, 2.25), api_3d.AIL_3D_sample_occlusion(s));
}

test "6.5/6.6 DLS reverb levels and master room type round-trip" {
    const md = try openmiles.MidiDriver.init(testing.allocator);
    defer md.deinit();
    api_dls.AIL_DLS_set_reverb_levels(md, 0.25, 0.7);
    var dry: f32 = 0;
    var wet: f32 = 0;
    api_dls.AIL_DLS_get_reverb_levels(md, &dry, &wet);
    try testing.expect(@abs(dry - 0.25) < 0.001 and @abs(wet - 0.7) < 0.001);

    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    api_v7.AIL_set_digital_master_room_type(drv, 3);
    try testing.expectEqual(@as(i32, 3), api_v7.AIL_room_type_v7(drv));
}

test "v9 system-state push/pop tracks depth and restores volume" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    drv.setMasterVolume(1.0);
    try testing.expectEqual(@as(u8, 0), api_v9.AIL_system_state_level(drv));
    api_v9.AIL_push_system_state(drv, 0, 0);
    try testing.expectEqual(@as(u8, 1), api_v9.AIL_system_state_level(drv));
    drv.setMasterVolume(0.25); // change while pushed
    api_v9.AIL_pop_system_state(drv, 0); // restores 1.0
    try testing.expectEqual(@as(u8, 0), api_v9.AIL_system_state_level(drv));
    try testing.expect(@abs(drv.getMasterVolume() - 1.0) < 0.001);
}

test "v9 system-state push/pop pairs every level with its own volume" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    // Each push records a distinct volume, then every level is changed after
    // the push. A pop that reached the wrong level's entry would restore one of
    // the other volumes here. The value is read back through the engine rather
    // than assumed, so the test holds whatever the engine stores.
    var pushed: [4]f32 = undefined;
    for (0..4) |i| {
        drv.setMasterVolume(0.1 * @as(f32, @floatFromInt(i + 1)));
        pushed[i] = drv.getMasterVolume();
        api_v9.AIL_push_system_state(drv, 0, 0);
        try testing.expectEqual(@as(u8, @intCast(i + 1)), api_v9.AIL_system_state_level(drv));
    }
    for (0..4) |i| {
        try testing.expect(pushed[i] != pushed[3 - i]);
        drv.setMasterVolume(0.9);
        api_v9.AIL_pop_system_state(drv, 0);
        try testing.expectEqual(@as(u8, @intCast(3 - i)), api_v9.AIL_system_state_level(drv));
        try testing.expectEqual(pushed[3 - i], drv.getMasterVolume());
    }
}

test "v9 system-state level cap keeps pushes and pops paired" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    drv.setMasterVolume(0.5);
    const pushed_volume = drv.getMasterVolume();
    for (0..openmiles.max_system_state_level) |_| api_v9.AIL_push_system_state(drv, 0, 0);
    try testing.expectEqual(@as(u8, @intCast(openmiles.max_system_state_level)), api_v9.AIL_system_state_level(drv));
    // A push past the cap must not raise the level, and the pop that pairs with
    // it must not reach a volume an inner level saved.
    drv.setMasterVolume(0.75);
    api_v9.AIL_push_system_state(drv, 0, 0);
    try testing.expectEqual(@as(u8, @intCast(openmiles.max_system_state_level)), api_v9.AIL_system_state_level(drv));
    api_v9.AIL_pop_system_state(drv, 0);
    try testing.expectEqual(@as(u8, @intCast(openmiles.max_system_state_level - 1)), api_v9.AIL_system_state_level(drv));
    try testing.expectEqual(pushed_volume, drv.getMasterVolume());
}

test "distance_factor folds into the per-sample Doppler factor (matches MSS)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample3D.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);
    // MSS: velocity *= distance_factor * doppler_factor. ma's per-sound doppler
    // factor must therefore carry the product, not just doppler_factor.
    api_3d.AIL_set_3D_doppler_factor(drv, 2.0);
    api_3d.AIL_set_3D_distance_factor(drv, 3.0);
    try testing.expect(@abs(openmiles.ma.ma_sound_get_doppler_factor(&s.sound) - 6.0) < 0.001);
}

test "3D distance/doppler/rolloff factors: 1.0 default, 0.0 on null handle (SDK)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    // A fresh driver defaults all three factors to 1.0.
    try testing.expectEqual(@as(f32, 1.0), api_3d.AIL_3D_distance_factor(drv));
    try testing.expectEqual(@as(f32, 1.0), api_3d.AIL_3D_doppler_factor(drv));
    try testing.expectEqual(@as(f32, 1.0), api_3d.AIL_3D_rolloff_factor(drv));
    // SDK (mssds3d.cpp): a null handle returns 0.0, NOT the 1.0 default --
    // `if (!dig) return 0.0f;`.
    try testing.expectEqual(@as(f32, 0.0), api_3d.AIL_3D_distance_factor(null));
    try testing.expectEqual(@as(f32, 0.0), api_3d.AIL_3D_doppler_factor(null));
    try testing.expectEqual(@as(f32, 0.0), api_3d.AIL_3D_rolloff_factor(null));
}

test "occlusion drives the low-pass cutoff (m3d.cpp model), obstruction does not" {
    const s = try loadedSample(testing.allocator, 64, 1, 8000);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();

    // A null handle returns 1.0 (fully open), never 0 (SDK wavefile.cpp).
    try testing.expectEqual(@as(f32, 1.0), api_v7.AIL_sample_low_pass_cut_off(null, 0));
    // Fresh sample: obstruction/occlusion/exclusion default to 0.0 (init_sample),
    // and a null handle returns 0.0 (SDK m3d.cpp guards).
    try testing.expectEqual(@as(f32, 0.0), api_v7.AIL_sample_obstruction(s));
    try testing.expectEqual(@as(f32, 0.0), api_v7.AIL_sample_occlusion(s));
    try testing.expectEqual(@as(f32, 0.0), api_v7.AIL_sample_exclusion(s));
    try testing.expectEqual(@as(f32, 0.0), api_v7.AIL_sample_obstruction(null));
    try testing.expectEqual(@as(f32, 0.0), api_v7.AIL_sample_occlusion(null));
    try testing.expectEqual(@as(f32, 0.0), api_v7.AIL_sample_exclusion(null));
    // occlusion=0.75 -> cutoff = (1-0.75)+0.01 = 0.26 (muffled).
    api_v7.AIL_set_sample_occlusion(s, 0.75);
    try testing.expect(@abs(api_v7.AIL_sample_low_pass_cut_off(s, 0) - 0.26) < 0.001);
    // occlusion=0 -> cutoff 1.01 -> fully open (1.0).
    api_v7.AIL_set_sample_occlusion(s, 0.0);
    try testing.expectEqual(@as(f32, 1.0), api_v7.AIL_sample_low_pass_cut_off(s, 0));
    // obstruction is stored only (no low-pass effect in the software model).
    api_v7.AIL_set_sample_obstruction(s, 0.9);
    try testing.expectEqual(@as(f32, 1.0), api_v7.AIL_sample_low_pass_cut_off(s, 0));
    try testing.expect(@abs(api_v7.AIL_sample_obstruction(s) - 0.9) < 0.001);
    // m3d.cpp stores these verbatim (no clamp); out-of-range values round-trip.
    api_v7.AIL_set_sample_obstruction(s, 1.7);
    try testing.expectEqual(@as(f32, 1.7), api_v7.AIL_sample_obstruction(s));
    api_v7.AIL_set_sample_exclusion(s, 2.5);
    try testing.expectEqual(@as(f32, 2.5), api_v7.AIL_sample_exclusion(s));
}

test "Doppler uses MSS speed of sound (0.355), not miniaudio's 343.3 default" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    // MSS games supply raw velocities compared against SPEED_OF_SOUND=0.355;
    // miniaudio's 343.3 default would make the same velocity ~1000x weaker.
    const c = openmiles.ma.ma_spatializer_listener_get_speed_of_sound(&drv.engine.listeners[0]);
    try testing.expect(@abs(c - 0.355) < 0.0001);
}

test "Sample3D.getLength saturates on an overflowing frame count (no panic)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample3D.init(drv);
    defer s.deinit();
    // A malformed file could make the decoder report an absurd frame count;
    // length_in_bytes = frames * bytesPerFrame must saturate, not overflow u64
    // (which would panic in a safe build) nor wrap.
    s.is_initialized = true; // exercise the arithmetic path (noDevice leaves it false)
    s.cached_length_frames = std.math.maxInt(u64);
    const len = s.getLength();
    s.is_initialized = false; // restore so deinit doesn't touch the half-init sound
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), len);
}

test "AIL_DLS_load_memory rejects an implausibly-large header size (no panic)" {
    const md = try openmiles.MidiDriver.init(testing.allocator);
    defer md.deinit();
    // "RIFF" with a 0xFFFFFFFF size field -> detectAudioSize returns ~4GB, which
    // exceeds maxInt(c_int); the loader must reject it (return null) rather than
    // panic on the cast or hand tsf an out-of-range size.
    var buf = [_]u8{ 'R', 'I', 'F', 'F', 0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0 };
    try testing.expect(api_dls.AIL_DLS_load_memory(md, &buf, 0) == null);
    // A valid 'RIFF' size that simply isn't a soundfont also returns null safely.
    std.mem.writeInt(u32, buf[4..8], 4, .little); // body=4 -> total 12 == buf len
    try testing.expect(api_dls.AIL_DLS_load_memory(md, &buf, 0) == null);

    // AIL_DLS_open(mdi, dig, libname, ...) takes a file NAME; a null/missing
    // library just opens the device without a soundfont (no crash).
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const dls_drv = api_dls.AIL_DLS_open(md, drv, null, 0, 44100, 16, 2);
    try testing.expect(dls_drv != null);
    if (dls_drv) |d| api_dls.AIL_DLS_close(d, 0);
}

test "AIL_DLS_get_info writes AILDLSINFO to param 2 and PercentCPU to param 3 (SDK)" {
    const md = try openmiles.MidiDriver.init(testing.allocator);
    defer md.deinit();
    // AILDLSINFO is 148 bytes: char Description[128] + 5 S32.
    const AILDLSINFO = extern struct {
        Description: [128]u8,
        MaxDLSMemory: i32,
        CurrentDLSMemory: i32,
        LargestSize: i32,
        GMAvailable: i32,
        GMBankSize: i32,
    };
    var info: AILDLSINFO = undefined;
    var cpu: i32 = -1;
    api_dls.AIL_DLS_get_info(md, &info, &cpu);
    // The description is written into param 2 (not the CPU S32).
    try testing.expect(std.mem.startsWith(u8, &info.Description, "OpenMiles DLS"));
    // No soundfont loaded -> GM not available, memory 0; CPU% written to param 3.
    try testing.expectEqual(@as(i32, 0), info.GMAvailable);
    try testing.expectEqual(@as(i32, 0), cpu);
    // Null out-params and null driver are safe no-ops.
    api_dls.AIL_DLS_get_info(md, null, null);
    api_dls.AIL_DLS_get_info(null, &info, &cpu);
}

test "clearing the soundfont source drops the size AIL_DLS_get_info reports" {
    const md = try openmiles.MidiDriver.init(testing.allocator);
    defer md.deinit();
    // Stand in for a bank whose size was captured on load; forgetting the
    // source has to forget it, or get_info answers with the length of a bank
    // that is no longer loaded.
    md.soundfont_size_bytes = 4096;
    md.clearSoundfontSource();
    try testing.expectEqual(@as(u32, 0), md.soundfont_size_bytes);
}

test "v7 set_sample_3D_distances orders the min/max pair (SDK swap)" {
    const s = try loadedSample(testing.allocator, 64, 1, 8000);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();
    api_v7.AIL_set_sample_3D_position(s, 0, 0, 0);
    // Normal order (max=100, min=3) is preserved.
    api_v7.AIL_set_sample_3D_distances(s, 100.0, 3.0, 0);
    try testing.expect(@abs(openmiles.ma.ma_sound_get_min_distance(&s.sound) - 3.0) < 0.01);
    try testing.expect(@abs(openmiles.ma.ma_sound_get_max_distance(&s.sound) - 100.0) < 0.01);
    // Reversed args (max=5, min=80) get swapped so min <= max holds.
    api_v7.AIL_set_sample_3D_distances(s, 5.0, 80.0, 0);
    try testing.expect(@abs(openmiles.ma.ma_sound_get_min_distance(&s.sound) - 5.0) < 0.01);
    try testing.expect(@abs(openmiles.ma.ma_sound_get_max_distance(&s.sound) - 80.0) < 0.01);

    // auto_3D_wet_atten round-trips through the getter (SDK S3D.auto_3D_atten).
    api_v7.AIL_set_sample_3D_distances(s, 100.0, 10.0, 1);
    var mx: f32 = 0;
    var mn: f32 = 0;
    var atten: i32 = -1;
    api_v7.AIL_sample_3D_distances(s, &mx, &mn, &atten);
    try testing.expectEqual(@as(i32, 1), atten);
    try testing.expect(@abs(mx - 100.0) < 0.01 and @abs(mn - 10.0) < 0.01);
    api_v7.AIL_set_sample_3D_distances(s, 100.0, 10.0, 0);
    api_v7.AIL_sample_3D_distances(s, &mx, &mn, &atten);
    try testing.expectEqual(@as(i32, 0), atten);
}

test "v9 set_sample_3D_volume_falloff maps graph range to distance attenuation" {
    const s = try loadedSample(testing.allocator, 64, 1, 8000);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();
    api_v7.AIL_set_sample_3D_position(s, 0, 0, 0);
    // Graph: near=2.0, far=50.0 (X = distance).
    var graph = [_]api_v9.MSSGraphPoint{
        .{ .x = 2.0, .y = 1.0, .itx = 0, .ity = 0, .otx = 0, .oty = 0, .itype = 0, .otype = 0 },
        .{ .x = 50.0, .y = 0.0, .itx = 0, .ity = 0, .otx = 0, .oty = 0, .itype = 0, .otype = 0 },
    };
    api_v9.AIL_set_sample_3D_volume_falloff(s, &graph, 2);
    try testing.expect(@abs(openmiles.ma.ma_sound_get_min_distance(&s.sound) - 2.0) < 0.01);
    try testing.expect(@abs(openmiles.ma.ma_sound_get_max_distance(&s.sound) - 50.0) < 0.01);
    // The graph is stored verbatim on the sample (mirrors HSAMPLE.S3D).
    try testing.expectEqual(@as(u8, 2), s.falloff_count[@intFromEnum(openmiles.FalloffKind.volume)]);
}

test "v9 falloff setters store all four graphs and honor the SDK pointcount guard" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    const zero: openmiles.FalloffGraphPoint = .{ .x = 0, .y = 0, .itx = 0, .ity = 0, .otx = 0, .oty = 0, .itype = 0, .otype = 0 };
    var graph = [_]api_v9.MSSGraphPoint{zero} ** 5;
    graph[0].x = 1.0;
    graph[2].x = 9.0;
    // exclusion / lowpass / spread all store the count and points.
    api_v9.AIL_set_sample_3D_exclusion_falloff(s, &graph, 3);
    api_v9.AIL_set_sample_3D_lowpass_falloff(s, &graph, 4);
    api_v9.AIL_set_sample_3D_spread_falloff(s, &graph, 5);
    try testing.expectEqual(@as(u8, 3), s.falloff_count[@intFromEnum(openmiles.FalloffKind.exclusion)]);
    try testing.expectEqual(@as(u8, 4), s.falloff_count[@intFromEnum(openmiles.FalloffKind.lowpass)]);
    try testing.expectEqual(@as(u8, 5), s.falloff_count[@intFromEnum(openmiles.FalloffKind.spread)]);
    try testing.expect(s.falloff_graph[@intFromEnum(openmiles.FalloffKind.lowpass)][2].x == 9.0);
    // pointcount > MILES_MAX_FALLOFF_GRAPH_POINTS (5) is rejected: count unchanged.
    api_v9.AIL_set_sample_3D_lowpass_falloff(s, &graph, 6);
    try testing.expectEqual(@as(u8, 4), s.falloff_count[@intFromEnum(openmiles.FalloffKind.lowpass)]);
    // pointcount 0 clears the graph.
    api_v9.AIL_set_sample_3D_spread_falloff(s, &graph, 0);
    try testing.expectEqual(@as(u8, 0), s.falloff_count[@intFromEnum(openmiles.FalloffKind.spread)]);
    // A null graph with a positive count is a safe no-op (count cleared, no crash).
    api_v9.AIL_set_sample_3D_exclusion_falloff(s, null, 2);
    try testing.expectEqual(@as(u8, 0), s.falloff_count[@intFromEnum(openmiles.FalloffKind.exclusion)]);
}

test "v9 bus mixer allocates, routes samples, and frees" {
    const s = try loadedSample(testing.allocator, 64, 1, 8000);
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();
    // Allocate a bus and route the sample to it.
    const bus = api_v9.AIL_allocate_bus(drv) orelse return error.NoBus;
    try testing.expectEqual(@as(usize, 1), drv.buses.items.len);
    api_v9.AIL_set_sample_bus(s, 0);
    try testing.expectEqual(@as(i32, 0), api_v9.AIL_sample_bus(s));
    // bus_sample_handle(0) returns the same bus object.
    try testing.expectEqual(bus, api_v9.AIL_bus_sample_handle(drv, 0).?);
    // Bus volume control reaches the group without crashing.
    const mb: *openmiles.MixBus = @ptrCast(@alignCast(bus));
    mb.setVolume(0.5);
    api_v9.AIL_free_all_busses(drv);
    try testing.expectEqual(@as(usize, 0), drv.buses.items.len);
}

const api_v8b = @import("api/v8.zig");
test "v8 sample channel_count and loop_block report real state" {
    const s = try loadedSample(testing.allocator, 128, 1, 8000); // mono
    const drv = s.driver;
    defer drv.deinit();
    defer s.deinit();
    var mask: u32 = 0;
    try testing.expectEqual(@as(i32, 1), api_v8b.AIL_sample_channel_count(s, &mask)); // mono
    // SDK: standard WAVs report channel_mask = ~0U ("default mapping"), not a
    // pre-resolved speaker mask.
    try testing.expectEqual(~@as(u32, 0), mask);
    // No loop block set: offsets are 0, and the return is the loop count
    // (orig_loop_count, default 1 -- the SDK returns the count, not a found-flag).
    var ls: i32 = -1;
    var le: i32 = -1;
    try testing.expectEqual(@as(i32, 1), api_v8b.AIL_sample_loop_block(s, &ls, &le));
    try testing.expectEqual(@as(i32, 0), ls);
    try testing.expectEqual(@as(i32, 0), le);
    // After AIL_set_sample_loop_count(3), loop_block returns the original 3,
    // while AIL_sample_loop_count returns the (pre-play) remaining, also 3.
    dg.AIL_set_sample_loop_count(s, 3);
    try testing.expectEqual(@as(i32, 3), api_v8b.AIL_sample_loop_block(s, null, null));
    try testing.expectEqual(@as(i32, 3), dg.AIL_sample_loop_count(s));
    // SDK null guards: AIL_API_sample_loop_count and AIL_API_sample_buffer_available
    // both return -1 on a null handle (NOT 0).
    try testing.expectEqual(@as(i32, -1), dg.AIL_sample_loop_count(null));
    try testing.expectEqual(@as(i32, -1), api_v8b.AIL_sample_buffer_available(null));
}

test "v8 5.1 volume levels round-trip and volume_pan channel order" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    // SDK channel order: f_left, f_right, b_left, b_right, center, sub.
    api_v8b.AIL_set_sample_51_volume_levels(s, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6);
    var f_left: f32 = 0;
    var f_right: f32 = 0;
    var b_left: f32 = 0;
    var b_right: f32 = 0;
    var center: f32 = 0;
    var sub: f32 = 0;
    api_v8b.AIL_sample_51_volume_levels(s, &f_left, &f_right, &b_left, &b_right, &center, &sub);
    try testing.expect(@abs(f_left - 0.1) < 0.001 and @abs(f_right - 0.2) < 0.001);
    try testing.expect(@abs(b_left - 0.3) < 0.001 and @abs(b_right - 0.4) < 0.001);
    try testing.expect(@abs(center - 0.5) < 0.001 and @abs(sub - 0.6) < 0.001);

    // The levels reported after set_51_volume_pan must use the same channel
    // order: with pan=fb_pan=0.5 and volume=1, center/sub carry their levels
    // (1.0) while the four corners get left*front etc. -- center must NOT land
    // in a back-channel slot (the bug this guards against).
    api_v8b.AIL_set_sample_51_volume_pan(s, 1.0, 0.5, 0.5, 1.0, 1.0);
    api_v8b.AIL_sample_51_volume_levels(s, &f_left, &f_right, &b_left, &b_right, &center, &sub);
    try testing.expectEqual(@as(f32, 1.0), center); // sv*center_level = 1
    try testing.expectEqual(@as(f32, 1.0), sub); // sv*sub_level = 1
    const corner = 0.812252196 * 0.812252196; // (left=front)*front
    try testing.expect(@abs(f_left - corner) < 0.001 and @abs(b_right - corner) < 0.001);
}

test "v8 WAV cue markers parse from cue/labl chunks" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const al = testing.allocator;
    const H = struct {
        b: *std.ArrayListUnmanaged(u8),
        a: std.mem.Allocator,
        fn s(self: @This(), bytes: []const u8) !void {
            try self.b.appendSlice(self.a, bytes);
        }
        fn u32le(self: @This(), v: u32) !void {
            var t: [4]u8 = undefined;
            std.mem.writeInt(u32, &t, v, .little);
            try self.b.appendSlice(self.a, &t);
        }
        fn u16le(self: @This(), v: u16) !void {
            var t: [2]u8 = undefined;
            std.mem.writeInt(u16, &t, v, .little);
            try self.b.appendSlice(self.a, &t);
        }
    };
    const h = H{ .b = &buf, .a = al };
    try h.s("RIFF");
    const riff_size_pos = buf.items.len;
    try h.u32le(0); // patched later
    try h.s("WAVE");
    try h.s("fmt ");
    try h.u32le(16);
    try h.u16le(1);
    try h.u16le(1);
    try h.u32le(8000);
    try h.u32le(16000);
    try h.u16le(2);
    try h.u16le(16);
    try h.s("data");
    try h.u32le(0);
    try h.s("cue ");
    try h.u32le(4 + 48); // count field + two 24-byte cue points
    try h.u32le(2); // count
    // cue point 0
    try h.u32le(1); // id
    try h.u32le(100); // position
    try h.s("data");
    try h.u32le(0);
    try h.u32le(0);
    try h.u32le(100); // sampleOffset
    // cue point 1 (exercises the n*24 stride)
    try h.u32le(2); // id
    try h.u32le(500); // position
    try h.s("data");
    try h.u32le(0);
    try h.u32le(0);
    try h.u32le(500); // sampleOffset
    try h.s("LIST");
    try h.u32le(4 + (8 + 10) + (8 + 8)); // adtl + labl("start") + labl("end")
    try h.s("adtl");
    try h.s("labl");
    try h.u32le(4 + 6); // id + "start\0"
    try h.u32le(1); // cue id
    try h.s("start\x00");
    try h.s("labl");
    try h.u32le(4 + 4); // id + "end\0"
    try h.u32le(2); // cue id
    try h.s("end\x00");
    std.mem.writeInt(u32, buf.items[riff_size_pos..][0..4], @intCast(buf.items.len - 8), .little);

    const img: *const anyopaque = @ptrCast(buf.items.ptr);
    try testing.expectEqual(@as(i32, 2), api_v8b.AIL_WAV_marker_count(img));
    var name: ?[*:0]const u8 = null;
    try testing.expectEqual(@as(i32, 100), api_v8b.AIL_WAV_marker_by_index(img, 0, &name));
    try testing.expect(name != null);
    try testing.expectEqualStrings("start", std.mem.span(name.?));
    // Second marker: the 24-byte stride must land on cue point 1 and its label.
    try testing.expectEqual(@as(i32, 500), api_v8b.AIL_WAV_marker_by_index(img, 1, &name));
    try testing.expectEqualStrings("end", std.mem.span(name.?));
    // Out-of-range and negative indices return -1 (SDK guard).
    try testing.expectEqual(@as(i32, -1), api_v8b.AIL_WAV_marker_by_index(img, 2, &name));
    try testing.expectEqual(@as(i32, -1), api_v8b.AIL_WAV_marker_by_index(img, -1, &name));
    try testing.expectEqual(@as(i32, 100), api_v8b.AIL_WAV_marker_by_name(img, "start"));
    try testing.expectEqual(@as(i32, 500), api_v8b.AIL_WAV_marker_by_name(img, "end"));
    try testing.expectEqual(@as(i32, -1), api_v8b.AIL_WAV_marker_by_name(img, "nope"));
    // Null-image guards.
    try testing.expectEqual(@as(i32, 0), api_v8b.AIL_WAV_marker_count(null));
    try testing.expectEqual(@as(i32, -1), api_v8b.AIL_WAV_marker_by_name(null, "start"));
}

test "v9 bus limiter: soft-clip math + attach/detach lifecycle" {
    // Soft-clip: below the knee passes through; peaks saturate below unity.
    try testing.expect(@abs(openmiles.LimiterNode.softClip(0.5) - 0.5) < 0.0001);
    const hi = openmiles.LimiterNode.softClip(2.0);
    try testing.expect(hi > 0.7 and hi < 1.0);
    try testing.expect(@abs(openmiles.LimiterNode.softClip(-2.0) + hi) < 0.0001); // odd symmetry
    // The tabulated curve must still track tanh over its whole useful range: the
    // table replaces a libm call per sample, and this is what bounds that cost.
    var step: usize = 0;
    while (step <= 400) : (step += 1) {
        const x = 0.7 + @as(f32, @floatFromInt(step)) * 0.01; // 0.7 .. 4.7
        const shaped = openmiles.LimiterNode.softClip(x);
        const want = 0.7 + 0.3 * @as(f32, @floatCast(std.math.tanh(@as(f64, @floatFromInt(step)) * 0.01 / 0.3)));
        try testing.expect(@abs(shaped - want) < 1e-5);
    }
    // Past the table the curve saturates at unity, and NaN stays non-finite.
    try testing.expectEqual(@as(f32, 1.0), openmiles.LimiterNode.softClip(1e6));
    try testing.expect(std.math.isNan(openmiles.LimiterNode.softClip(std.math.nan(f32))));

    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const bus = api_v9.AIL_allocate_bus(drv) orelse return error.NoBus;
    const mb: *openmiles.MixBus = @ptrCast(@alignCast(bus));
    api_v9.AIL_bus_enable_limiter(drv, 0, 1);
    try testing.expect(mb.limiter != null);
    api_v9.AIL_bus_enable_limiter(drv, 0, 0);
    try testing.expect(mb.limiter == null);
    api_v9.AIL_bus_enable_limiter(drv, 0, 1); // re-enable; freed by driver deinit
}

test "v9 bus compressor installs and reduces peaks" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const bus = api_v9.AIL_allocate_bus(drv) orelse return error.NoBus;
    const mb: *openmiles.MixBus = @ptrCast(@alignCast(bus));
    try testing.expectEqual(@as(i32, 1), api_v9.AIL_install_bus_compressor(drv, 0, 0, -1));
    try testing.expect(mb.compressor != null);
    // Drive a loud block through the node's process and confirm the envelope
    // pulls gain below unity (peaks are compressed).
    const node = mb.compressor.?;
    var in_buf = [_]f32{0.9} ** 64; // 32 stereo frames at 0.9 (> threshold 0.5)
    var out_buf = [_]f32{0} ** 64;
    var ip: [*c]const f32 = &in_buf;
    var op: [*c]f32 = &out_buf;
    var inc: u32 = 32;
    var outc: u32 = 32;
    openmiles.CompressorNode.process(@ptrCast(node), &ip, &inc, &op, &outc);
    try testing.expect(node.env < 1.0); // gain reduced
    try testing.expect(out_buf[0] < 0.9); // output attenuated
}

var mix_cb_hits: u32 = 0;
fn testMixCb(_: ?*openmiles.DigitalDriver) callconv(.winapi) void {
    mix_cb_hits += 1;
}
test "v9 register_mix_callback fires per engine mix" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    mix_cb_hits = 0;
    const prev = api_v9.AIL_register_mix_callback(drv, @ptrCast(@constCast(&testMixCb)));
    try testing.expect(prev == null); // no previous callback
    // The engine fires mixDispatch per mixed block on a real device; invoke it
    // directly here (noDevice test mode) to confirm it routes to the callback.
    openmiles.DigitalDriver.mixDispatch(@ptrCast(drv), null, 0);
    openmiles.DigitalDriver.mixDispatch(@ptrCast(drv), null, 0);
    try testing.expectEqual(@as(u32, 2), mix_cb_hits);
    // Unregister; returns our callback as the previous one.
    const back = api_v9.AIL_register_mix_callback(drv, null);
    try testing.expect(back != null);
}

test "v8 playback delay + MMX available" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    api_v8b.AIL_set_sample_playback_delay(s, 250);
    try testing.expectEqual(@as(i32, 250), api_v8b.AIL_sample_playback_delay(s));
    try testing.expectEqual(@as(i32, 1), dg.AIL_MMX_available());
}

test "playback delay holds the voice until the delay elapses on the engine clock" {
    const allocator = testing.allocator;
    const drv = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    const wav = try zeroWav(allocator);
    defer allocator.free(wav);
    try s.loadFromMemory(wav, true);

    // No delay: the voice starts in the next mixed buffer.
    dg.AIL_start_sample(s);
    try testing.expectEqual(@as(u64, 0), s.scheduled_start_frames);

    // 250 ms at 44100 is 11025 frames past the engine clock's reading at start.
    api_v8b.AIL_set_sample_playback_delay(s, 250);
    dg.AIL_start_sample(s);
    const delayed: u64 = 11025;
    try testing.expect(s.scheduled_start_frames >= delayed);
    try testing.expect(s.scheduled_start_frames < delayed + 44100 / 10);

    // The delay is an attribute, so it applies to every start until cleared.
    dg.AIL_start_sample(s);
    try testing.expect(s.scheduled_start_frames >= delayed);
    api_v8b.AIL_set_sample_playback_delay(s, 0);
    dg.AIL_start_sample(s);
    try testing.expectEqual(@as(u64, 0), s.scheduled_start_frames);

    // An absolute AIL_schedule_start_sample still wins over the relative delay.
    api_v8b.AIL_set_sample_playback_delay(s, 250);
    api_v9.AIL_schedule_start_sample(s, 500);
    try testing.expectEqual(
        @as(u64, 22050),
        s.scheduled_start_frames,
    );
}

const api_v7b = @import("api/v7.zig");
test "MP3 inspector parses real Layer III frames" {
    // Two MPEG-1 Layer III frames, 128 kbps, 44100 Hz, stereo (header FF FB 90 00).
    // frame size = 144*128000/44100 = 417 bytes each.
    const frame_size = 417;
    var img: [frame_size * 2]u8 = [_]u8{0} ** (frame_size * 2);
    inline for (.{ 0, frame_size }) |base| {
        img[base + 0] = 0xFF;
        img[base + 1] = 0xFB;
        img[base + 2] = 0x90;
        img[base + 3] = 0x00;
    }
    var es: openmiles.mp3.MP3_INFO = undefined;
    api_v7b.AIL_inspect_MP3(&es, &img, img.len); // void in the SDK; success is shown by enumerate below
    // First frame.
    try testing.expectEqual(@as(i32, 1), api_v7b.AIL_enumerate_MP3_frames(&es));
    try testing.expectEqual(@as(i32, 44100), es.sample_rate);
    try testing.expectEqual(@as(i32, 128000), es.bit_rate);
    try testing.expectEqual(@as(i32, 2), es.channels_per_sample);
    try testing.expectEqual(@as(i32, 1152), es.samples_per_frame);
    try testing.expectEqual(@as(i32, 0), es.byte_offset);
    // Second frame at offset 417.
    try testing.expectEqual(@as(i32, 1), api_v7b.AIL_enumerate_MP3_frames(&es));
    try testing.expectEqual(@as(i32, frame_size), es.byte_offset);
    // End.
    try testing.expectEqual(@as(i32, 0), api_v7b.AIL_enumerate_MP3_frames(&es));
}

// A free-format header (bitrate_index 0) computes to a zero-byte frame. It used
// to be clamped to 0 and reported as a valid frame, which advanced neither the
// cursor nor the remaining-byte count: AIL_enumerate_MP3_frames returned 1
// forever on the same header, so the app's `while (AIL_enumerate_MP3_frames(&s))`
// loop never terminated. The enumerator must skip past it and reach the end.
test "MP3 inspector skips a free-format zero-length frame instead of looping" {
    // A valid 128 kbps frame (FF FB 90 00, 417 bytes) followed by two free-format
    // headers (bitrate_index 0) that no tabulated bitrate can size.
    var img: [417 + 8]u8 = [_]u8{0} ** (417 + 8);
    inline for (.{ 0, 417, 421 }) |base| {
        img[base + 0] = 0xFF;
        img[base + 1] = 0xFB;
        img[base + 2] = 0x90;
        img[base + 3] = 0x00;
    }
    img[417 + 2] = 0x00; // bitrate_index 0 → free format
    img[421 + 2] = 0x00;
    var es: openmiles.mp3.MP3_INFO = undefined;
    api_v7b.AIL_inspect_MP3(&es, &img, img.len);

    try testing.expectEqual(@as(i32, 1), api_v7b.AIL_enumerate_MP3_frames(&es));
    try testing.expectEqual(@as(i32, 0), es.byte_offset);
    try testing.expectEqual(@as(i32, 128000), es.bit_rate);
    // The two free-format headers are not frames; the scan runs off the end.
    try testing.expectEqual(@as(i32, 0), api_v7b.AIL_enumerate_MP3_frames(&es));
}

test "MP3 bitrate/sample-rate tables match the MPEG Layer III spec" {
    // The inspector tests only probe a couple of table entries; lock the full
    // MPEG-1 / MPEG-2(.5) Layer III bitrate and sample-rate tables so a corrupted
    // entry (e.g. a wrong 320 kbps or 48 kHz value) is caught directly.
    const br = openmiles.mp3.MPEG_bit_rate;
    // MPEG-2/2.5 Layer III bitrates (index 0 = free).
    try testing.expectEqualSlices(i32, &.{ 0, 8000, 16000, 24000, 32000, 40000, 48000, 56000, 64000, 80000, 96000, 112000, 128000, 144000, 160000 }, &br[0]);
    // MPEG-1 Layer III bitrates.
    try testing.expectEqualSlices(i32, &.{ 0, 32000, 40000, 48000, 56000, 64000, 80000, 96000, 112000, 128000, 160000, 192000, 224000, 256000, 320000 }, &br[1]);
    const sr = openmiles.mp3.MPEG_sample_rate;
    try testing.expectEqualSlices(i32, &.{ 22050, 24000, 16000, 22050 }, &sr[0][0]); // MPEG-2
    try testing.expectEqualSlices(i32, &.{ 44100, 48000, 32000, 44100 }, &sr[0][1]); // MPEG-1
    try testing.expectEqualSlices(i32, &.{ 11025, 12000, 8000, 11025 }, &sr[1][0]); // MPEG-2.5
}

test "MP3 inspector: mono channel mode and 192 kbps bitrate index" {
    // MPEG-1 Layer III, 192 kbps, 44100 Hz, MONO. Header FF FB B0 C0:
    //   byte2 = 1011(idx 11 -> 192k) 00(44100) 0(pad) 0  = 0xB0
    //   byte3 = 11(mono) ...                              = 0xC0
    // Exercises a different bitrate-table index and the mono channel mode than
    // the stereo/128k case above. frame size = 144*192000/44100 = 626; two frames
    // so the first is confirmed by the second's sync.
    const frame_size = 626;
    var img: [frame_size * 2]u8 = [_]u8{0} ** (frame_size * 2);
    inline for (.{ 0, frame_size }) |base| {
        img[base + 0] = 0xFF;
        img[base + 1] = 0xFB;
        img[base + 2] = 0xB0;
        img[base + 3] = 0xC0;
    }
    var es: openmiles.mp3.MP3_INFO = undefined;
    api_v7b.AIL_inspect_MP3(&es, &img, img.len); // void in the SDK; success is shown by enumerate below
    try testing.expectEqual(@as(i32, 1), api_v7b.AIL_enumerate_MP3_frames(&es));
    try testing.expectEqual(@as(i32, 44100), es.sample_rate);
    try testing.expectEqual(@as(i32, 192000), es.bit_rate);
    try testing.expectEqual(@as(i32, 1), es.channels_per_sample); // mono
    try testing.expectEqual(@as(i32, 1152), es.samples_per_frame);
}

test "MP3 inspector: MPEG-2 Layer III is 576 samples/frame at the lower rates" {
    // MPEG-2 Layer III, 64 kbps, 22050 Hz, stereo. Header FF F3 80 00:
    //   byte1 = 1111 0011: sync, version 10 (MPEG-2), layer 01 (L3), protection 1
    //   byte2 = 1000(idx 8 -> 64k in the MPEG-2 table) 00(22050) 0(pad) 0 = 0x80
    // MPEG-2/2.5 Layer III has half the samples per frame (576, not 1152) and the
    // frame-size multiplier 72 instead of 144 -- frame size = 72*64000/22050 = 208.
    const frame_size = 208;
    var img: [frame_size * 2]u8 = [_]u8{0} ** (frame_size * 2);
    inline for (.{ 0, frame_size }) |base| {
        img[base + 0] = 0xFF;
        img[base + 1] = 0xF3;
        img[base + 2] = 0x80;
        img[base + 3] = 0x00;
    }
    var es: openmiles.mp3.MP3_INFO = undefined;
    api_v7b.AIL_inspect_MP3(&es, &img, img.len); // void in the SDK; success is shown by enumerate below
    try testing.expectEqual(@as(i32, 1), api_v7b.AIL_enumerate_MP3_frames(&es));
    try testing.expectEqual(@as(i32, 22050), es.sample_rate);
    try testing.expectEqual(@as(i32, 64000), es.bit_rate);
    try testing.expectEqual(@as(i32, 2), es.channels_per_sample); // stereo
    try testing.expectEqual(@as(i32, 576), es.samples_per_frame); // half of MPEG-1
}

test "event constructor + decoder round-trip (byte-faithful text)" {
    const ev = api_v8b.AIL_create_event() orelse return error.NoEvent;
    _ = api_v9.AIL_add_clear_state_event_step(ev);
    _ = api_v8b.AIL_add_comment_event_step(ev, "hello");
    _ = api_v9.AIL_add_exec_event_event_step(ev, "boom");
    const str = api_v8b.AIL_close_event(ev) orelse return error.NoStr;
    defer std.c.free(str);
    // Byte-exact Miles text.
    try testing.expectEqualStrings("9;4;<;4;hello;=;boom;", std.mem.span(@as([*:0]const u8, @ptrCast(str))));
    // Decode each step.
    var buf: [512]u8 align(8) = undefined;
    var sp: ?*openmiles.event.EVENT_STEP_INFO = null;
    var cur: ?*const anyopaque = @ptrCast(str);
    // clear_state
    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expectEqual(@intFromEnum(openmiles.event.StepType.clear_state), sp.?.type);
    // comment "hello"
    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expectEqual(@intFromEnum(openmiles.event.StepType.comment), sp.?.type);
    const c = sp.?.u.comment.comment;
    try testing.expectEqualStrings("hello", c.str.?[0..@intCast(c.len)]);
    // exec_event "boom"
    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expectEqual(@intFromEnum(openmiles.event.StepType.exec_event), sp.?.type);
    const e2 = sp.?.u.exec.eventname;
    try testing.expectEqualStrings("boom", e2.str.?[0..@intCast(e2.len)]);
    // end
    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expect(cur == null);
}

test "event decoder rejects a step-type tag outside the enum range" {
    // A step-type byte is file data; '0' and '@' decode to tags the StepType enum
    // has no case for, and must end the walk instead of trapping the conversion.
    var buf: [256]u8 align(8) = undefined;
    var step: openmiles.event.EVENT_STEP_INFO = undefined;
    for ([_][:0]const u8{ "0;4;", "@;4;" }) |bad| {
        try testing.expect(openmiles.event.nextStep(bad.ptr, &step, &buf) == null);
    }
    // A leading version header still decodes into the step after it.
    const ok = openmiles.event.nextStep("9;4;<;", &step, &buf).?;
    try testing.expectEqual(@intFromEnum(openmiles.event.StepType.clear_state), step.type);
    try testing.expect(ok[0] == 0);
}

test "event decoder bounds the version-header chain" {
    // A crafted bank can repeat the header; each one re-enters the decoder, so
    // the chain has to end somewhere instead of eating the stack.
    var buf: [256]u8 align(8) = undefined;
    var step: openmiles.event.EVENT_STEP_INFO = undefined;
    const chained = "9;4;9;4;9;4;9;4;9;4;9;4;<;";
    try testing.expect(openmiles.event.nextStep(chained.ptr, &step, &buf) == null);
}

const api_dls_t = @import("api/dls.zig");
const api_timer_t = @import("api/timer.zig");

test "DLS unload C-ABI variants free a loaded soundfont" {
    // The soundfont fixture is gitignored ("provide your own"); on machines
    // without it (e.g. CI) there is nothing to assert, so skip quietly.
    std.Io.Dir.cwd().access(openmiles.io, "test_media/test.sf2", .{}) catch return;
    const hm = try openmiles.MidiDriver.init(testing.allocator);
    defer hm.deinit();
    // Each unload variant frees the bank, so reload a fresh one before the next.
    inline for (.{
        api_dls_t.AIL_DLS_unload,
        api_dls_t.AIL_DLS_unload_file,
        api_dls_t.DLSClose,
        api_dls_t.DLSUnloadFile,
    }) |unloadFn| {
        const bank = api_dls_t.AIL_DLS_load_file(hm, "test_media/test.sf2", 0) orelse return error.SoundfontFixtureMissing;
        try testing.expect(hm.soundfont != null);
        unloadFn(hm, bank);
        try testing.expect(hm.soundfont == null);
    }
}

fn noopTimerCb(_: u32) callconv(.winapi) void {}

test "release_all_timers frees registered timers and registration still works" {
    const h1 = api_timer_t.AIL_register_timer(noopTimerCb);
    try testing.expect(h1 != null);
    api_timer_t.AIL_release_all_timers();
    // Registry usable again after a bulk release.
    const h2 = api_timer_t.AIL_register_timer(noopTimerCb);
    try testing.expect(h2 != null);
    api_timer_t.AIL_release_all_timers();
}

const api_miles_t = @import("api/miles.zig");

test "Miles event-system variables roundtrip on default and named systems" {
    const sys = api_miles_t.MilesStartupEventSystem(null, 0, null, 0);
    defer api_miles_t.MilesShutdownEventSystem();
    try testing.expect(sys != null);

    api_miles_t.MilesSetVarI(0, "hp", 42); // default system == context 0
    api_miles_t.MilesSetVarF(0, "vol", 0.5);
    var iv: i32 = 0;
    var fv: f32 = 0;
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesGetVarI(0, "hp", &iv));
    try testing.expectEqual(@as(i32, 42), iv);
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesGetVarF(0, "vol", &fv));
    try testing.expectEqual(@as(f32, 0.5), fv);

    // type mismatch and unknown name both report "not found"
    try testing.expectEqual(@as(i32, 0), api_miles_t.MilesGetVarF(0, "hp", &fv));
    try testing.expectEqual(@as(i32, 0), api_miles_t.MilesGetVarI(0, "missing", &iv));

    // case-insensitive update of an existing var (AIL_stricmp semantics)
    api_miles_t.MilesSetVarI(0, "HP", 7);
    _ = api_miles_t.MilesGetVarI(0, "hp", &iv);
    try testing.expectEqual(@as(i32, 7), iv);

    // a second system has an independent variable namespace
    const sys2 = api_miles_t.MilesAddEventSystem(null);
    try testing.expect(sys2 != null);
    try testing.expectEqual(@as(i32, 0), api_miles_t.MilesGetVarI(@intFromPtr(sys2.?), "hp", &iv));
    api_miles_t.MilesSetVarI(@intFromPtr(sys2.?), "hp", 99);
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesGetVarI(@intFromPtr(sys2.?), "hp", &iv));
    try testing.expectEqual(@as(i32, 99), iv);
    // default system unchanged by the named-system write
    _ = api_miles_t.MilesGetVarI(0, "hp", &iv);
    try testing.expectEqual(@as(i32, 7), iv);
}

// The cap map owns the lowercased label it stores, so a limits string naming
// one label twice is one entry and the name handed to the second put is freed
// rather than dropped: a set_limits step repeated over a bank of them leaked a
// copy of every repeat. The leak-checked allocator is what makes it visible,
// the map holding one entry either way.
test "Miles label limits take a repeated label once and leak no name" {
    const saved = openmiles.global_allocator;
    openmiles.global_allocator = testing.allocator;
    defer openmiles.global_allocator = saved;
    // Registered after the allocator swap, so the instances the eviction walk
    // allocates are freed while testing.allocator is still installed.
    api_miles_t.MilesShutdownEventSystem();
    defer api_miles_t.MilesShutdownEventSystem();

    _ = api_miles_t.MilesSetSoundLabelLimits(null, "music 2:sfx 1:MUSIC 5:music 7");
    // Resetting empties the map, and with it every name the string carried.
    _ = api_miles_t.MilesSetSoundLabelLimits(null, "");
    // The v8 entry point reaches the same map.
    _ = api_miles_t.MilesSetSoundLabelLimits_v8("music 3:music 3");
    _ = api_miles_t.MilesSetSoundLabelLimits_v8("");

    // The one entry is observable through what the cap does at start time: a
    // repeat is one entry with the last count winning, whether the repeat
    // differs in case or only in spelling. "music 2:music 1" caps at 1, so the
    // second start evicts the first; a map that kept both counts (2 and 1) or
    // the earlier one would leave two instances alive.
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesSetSoundLabelLimits(null, "music 2:music 1"));
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("dup1"), 0, 0, cstr2("music"), null, 0, 0);
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("dup2"), 0, 0, cstr2("music"), null, 0, 0);
    var info: api_miles_t.MILESEVENTSOUNDINFO = undefined;
    var nx: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
    var count: i32 = 0;
    while (api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, cstr2("music"), 0, @ptrCast(&info)) == 1) count += 1;
    try testing.expectEqual(@as(i32, 1), count);

    // The same repeat written in a different case collapses the same way, and a
    // cap of 0 is a real value: it evicts every instance carrying the label
    // before the new one is added, so the survivor is the new sound alone. A
    // map that kept the earlier count (2) would have left dup2 alive beside it.
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesSetSoundLabelLimits(null, "MUSIC 2:music 0"));
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("dup3"), 0, 0, cstr2("music"), null, 0, 0);
    nx = @ptrFromInt(std.math.maxInt(usize));
    count = 0;
    var seen_dup2 = false;
    while (api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, cstr2("music"), 0, @ptrCast(&info)) == 1) {
        count += 1;
        if (std.mem.eql(u8, std.mem.span(info.UsedSound.?), "dup2")) seen_dup2 = true;
    }
    try testing.expectEqual(@as(i32, 1), count);
    try testing.expect(!seen_dup2);
    // The map is a process global the next test would inherit, so hand back an
    // empty one rather than a live cap on a common label.
    _ = api_miles_t.MilesSetSoundLabelLimits(null, "");
}

// bufPrint leaves the buffer unterminated; the AIL_* calls take C strings.
fn zprint(buf: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    const written = std.fmt.bufPrint(buf, fmt, args) catch unreachable;
    buf[written.len] = 0;
    return buf[0..written.len :0];
}

test "Miles event variables hold a long name and many entries" {
    // The variable table is keyed on a lowercased name held in a fixed stack
    // buffer, so a name longer than that buffer has to be found on the heap
    // and still match case-insensitively, and a table with many entries has to
    // return the right one for each of them.
    const sys = api_miles_t.MilesStartupEventSystem(null, 0, null, 0);
    defer api_miles_t.MilesShutdownEventSystem();
    try testing.expect(sys != null);

    // A name past the 128-byte stack buffer the key probe holds it in, so the
    // table has to keep the name on the heap and still match it case-blind.
    const long_name = "var" ++ ("x" ** 200) ++ "end";
    var long_buf: [long_name.len + 1]u8 = undefined;
    for (long_name, 0..) |c, i| long_buf[i] = c;
    long_buf[long_name.len] = 0;
    const long_z: [:0]const u8 = long_buf[0..long_name.len :0];

    api_miles_t.MilesSetVarI(0, long_z, 5);
    var iv: i32 = 0;
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesGetVarI(0, long_z, &iv));
    try testing.expectEqual(@as(i32, 5), iv);

    var up_buf: [long_name.len + 1]u8 = undefined;
    for (long_name, 0..) |c, i| up_buf[i] = std.ascii.toUpper(c);
    up_buf[long_name.len] = 0;
    const upper: [:0]const u8 = up_buf[0..long_name.len :0];
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesGetVarI(0, upper, &iv));

    var buf: [32]u8 = undefined;
    for (0..64) |n| {
        const name = zprint(&buf, "v{d}", .{n});
        api_miles_t.MilesSetVarI(0, name, @intCast(n));
    }
    for (0..64) |n| {
        const name = zprint(&buf, "V{d}", .{n});
        try testing.expectEqual(@as(i32, 1), api_miles_t.MilesGetVarI(0, name, &iv));
        try testing.expectEqual(@as(i32, @intCast(n)), iv);
    }
}

test "Miles empty-state queries return documented empty values" {
    _ = api_miles_t.MilesStartupEventSystem(null, 256, null, 0);
    defer api_miles_t.MilesShutdownEventSystem();
    var state: api_miles_t.MILESEVENTSTATE = undefined;
    api_miles_t.MilesGetEventSystemState(null, &state);
    try testing.expectEqual(@as(i32, 256), state.CommandBufferSize);
    try testing.expectEqual(@as(i32, 0), state.PlayingSoundCount);
    try testing.expectEqual(@as(i32, 0), state.LoadedBankCount);
    try testing.expectEqual(@as(u64, 0), api_miles_t.MilesEnqueueEvent(null, null, 0, 0, 0));
    try testing.expect(api_miles_t.MilesFindEvent(null, "x") == null);
    try testing.expectEqual(@as(i32, 0), api_miles_t.MilesGetEventLength("x"));
}

test "Miles event system frees all systems and variables (no leaks)" {
    // Route the module's allocations through the leak-checked test allocator.
    const saved = openmiles.global_allocator;
    openmiles.global_allocator = testing.allocator;
    defer openmiles.global_allocator = saved;

    _ = api_miles_t.MilesStartupEventSystem(null, 0, null, 0);
    // many vars on the default system, plus several extra systems each with vars
    var n: i32 = 0;
    while (n < 32) : (n += 1) {
        var buf: [16]u8 = undefined;
        const name = std.fmt.bufPrintZ(&buf, "var{d}", .{n}) catch unreachable;
        api_miles_t.MilesSetVarI(0, name, n);
        api_miles_t.MilesSetVarF(0, name, @floatFromInt(n)); // overwrite path
    }
    var k: i32 = 0;
    while (k < 8) : (k += 1) {
        const sys = api_miles_t.MilesAddEventSystem(null) orelse continue;
        api_miles_t.MilesSetVarI(@intFromPtr(sys), "hp", k);
    }
    // Sound instances live in a list that grows its own backing array, so
    // starting one is what makes the list an allocation shutdown has to free.
    // Without this the leak check below never sees the list at all.
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("leakcheck"), 0, 0, cstr2("sfx"), null, 0, 0);
    // Shutdown must free every system, its variable list, and the instance
    // list's storage; if it leaks, the test allocator flags it at teardown.
    api_miles_t.MilesShutdownEventSystem();
}

fn cstr(s: [*:0]const u8) ?*anyopaque {
    return @ptrCast(@constCast(s));
}

test "ramp event step encodes byte-faithfully and round-trips" {
    const ev = api_v8b.AIL_create_event() orelse return error.NoEvent;
    _ = api_v9.AIL_add_ramp_event_step(ev, cstr("vol"), cstr("music"), 2.5, cstr("0.8"), 3, 1, 2);
    const str = api_v8b.AIL_close_event(ev) orelse return error.NoStr;
    defer std.c.free(str);
    try testing.expectEqualStrings("9;4;:;vol;music;2.500000;0.8;3;1;2;", std.mem.span(@as([*:0]const u8, @ptrCast(str))));

    var buf: [512]u8 align(8) = undefined;
    var sp: ?*openmiles.event.EVENT_STEP_INFO = null;
    var cur: ?*const anyopaque = @ptrCast(str);
    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expectEqual(@intFromEnum(openmiles.event.StepType.ramp), sp.?.type);
    const r = sp.?.u.ramp;
    try testing.expectEqualStrings("vol", r.name.str.?[0..@intCast(r.name.len)]);
    try testing.expectEqualStrings("music", r.labels.str.?[0..@intCast(r.labels.len)]);
    try testing.expectApproxEqAbs(@as(f32, 2.5), r.time, 0.0001);
    try testing.expectEqualStrings("0.8", r.target.str.?[0..@intCast(r.target.len)]);
    try testing.expectEqual(@as(u8, 3), r.type);
    try testing.expectEqual(@as(u8, 1), r.apply_to_new);
    try testing.expectEqual(@as(u8, 2), r.interpolate_type);
    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expect(cur == null);
}

test "control_sounds and start_sound steps round-trip all fields" {
    const ev = api_v8b.AIL_create_event() orelse return error.NoEvent;
    // control: labels, ms, me, pos, preset, presetapply=4, fadeout=1.5, loopcount=7, type=5
    _ = api_v8b.AIL_add_control_sounds_event_step(ev, cstr("amb"), cstr("a"), cstr("b"), cstr("p"), cstr("pre"), 4, 1.5, 7, 5);
    // start_sound: full field set
    _ = api_v8b.AIL_add_start_sound_event_step(ev, cstr("snd"), cstr("pst"), 1, cstr("evt"), cstr("ms"), cstr("me"), cstr("sv"), cstr("vi"), cstr("lbl"), 1, 0, 100, 200, 5, 3, cstr("off"), 0.1, 0.9, 0.5, 1.5, 0.25, 2, 1);
    const str = api_v8b.AIL_close_event(ev) orelse return error.NoStr;
    defer std.c.free(str);

    var buf: [1024]u8 align(8) = undefined;
    var sp: ?*openmiles.event.EVENT_STEP_INFO = null;
    var cur: ?*const anyopaque = @ptrCast(str);
    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expectEqual(@intFromEnum(openmiles.event.StepType.control_sounds), sp.?.type);
    const c = sp.?.u.control;
    try testing.expectEqualStrings("amb", c.labels.str.?[0..@intCast(c.labels.len)]);
    try testing.expectEqualStrings("pre", c.presetname.str.?[0..@intCast(c.presetname.len)]);
    try testing.expectEqual(@as(u8, 7), c.loopcount);
    try testing.expectEqual(@as(u8, 5), c.type);
    try testing.expectApproxEqAbs(@as(f32, 1.5), c.fadeouttime, 0.0001);
    try testing.expectEqual(@as(u8, 4), c.presetapplytype);

    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expectEqual(@intFromEnum(openmiles.event.StepType.start_sound), sp.?.type);
    const s = sp.?.u.start;
    try testing.expectEqualStrings("snd", s.soundname.str.?[0..@intCast(s.soundname.len)]);
    try testing.expectEqualStrings("lbl", s.labels.str.?[0..@intCast(s.labels.len)]);
    try testing.expectEqualStrings("off", s.startoffset.str.?[0..@intCast(s.startoffset.len)]);
    try testing.expectEqual(@as(u16, 100), s.delaymin);
    try testing.expectEqual(@as(u16, 200), s.delaymax);
    try testing.expectEqual(@as(u8, 5), s.priority);
    try testing.expectEqual(@as(u8, 3), s.loopcount);
    try testing.expectEqual(@as(u8, 1), s.presetisdynamic);
    try testing.expectApproxEqAbs(@as(f32, 0.1), s.volmin, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.5), s.pitchmax, 0.0001);
    try testing.expectEqual(@as(u8, 2), s.evictiontype);
    try testing.expectEqual(@as(u8, 1), s.selecttype);

    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expect(cur == null);
}

test "set_lfo, enable_limit and move_var steps round-trip" {
    const ev = api_v8b.AIL_create_event() orelse return error.NoEvent;
    _ = api_v9.AIL_add_set_lfo_event_step(ev, cstr("lvol"), cstr("0.5"), cstr("0.3"), cstr("2.0"), 1, 0, 2, 200, 1);
    _ = api_v9.AIL_add_enable_limit_event_step(ev, cstr("mylimit"));
    var times = [_]f32{ 1.0, 2.0 };
    var interps = [_]i32{ 2, 3 };
    var values = [_]f32{ 0.0, 0.5, 1.0 };
    _ = api_v9.AIL_add_move_var_event_step(ev, cstr("hp"), &times, &interps, &values);
    const str = api_v8b.AIL_close_event(ev) orelse return error.NoStr;
    defer std.c.free(str);

    var buf: [512]u8 align(8) = undefined;
    var sp: ?*openmiles.event.EVENT_STEP_INFO = null;
    var cur: ?*const anyopaque = @ptrCast(str);
    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expectEqual(@intFromEnum(openmiles.event.StepType.set_lfo), sp.?.type);
    const l = sp.?.u.setlfo;
    try testing.expectEqualStrings("lvol", l.name.str.?[0..@intCast(l.name.len)]);
    try testing.expectEqualStrings("0.5", l.base.str.?[0..@intCast(l.base.len)]);
    try testing.expectEqualStrings("2.0", l.freq.str.?[0..@intCast(l.freq.len)]);
    try testing.expectEqual(@as(i32, 1), l.invert);
    try testing.expectEqual(@as(i32, 2), l.waveform);
    try testing.expectEqual(@as(i32, 200), l.dutycycle);
    try testing.expectEqual(@as(i32, 1), l.islfo);

    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expectEqual(@intFromEnum(openmiles.event.StepType.enable_limit), sp.?.type);
    const el = sp.?.u.enablelimit.limitname;
    try testing.expectEqualStrings("mylimit", el.str.?[0..@intCast(el.len)]);

    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expectEqual(@intFromEnum(openmiles.event.StepType.move_var), sp.?.type);
    const mv = sp.?.u.movevar;
    try testing.expectEqualStrings("hp", mv.name.str.?[0..@intCast(mv.name.len)]);
    try testing.expectApproxEqAbs(@as(f32, 1.0), mv.times[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), mv.times[1], 0.0001);
    try testing.expectEqual(@as(i32, 2), mv.interp_types[0]);
    try testing.expectEqual(@as(i32, 3), mv.interp_types[1]);
    try testing.expectApproxEqAbs(@as(f32, 0.5), mv.values[1], 0.0001);

    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expect(cur == null);
}

test "set_blend step round-trips name, count and per-sound curves" {
    const ev = api_v8b.AIL_create_event() orelse return error.NoEvent;
    var in_min = [_]f32{ 0.1, 0.2 };
    var in_max = [_]f32{ 0.9, 1.0 };
    var out_min = [_]f32{ 0.0, 0.1 };
    var out_max = [_]f32{ 1.0, 0.8 };
    var min_p = [_]f32{ -1.0, -0.5 };
    var max_p = [_]f32{ 1.0, 0.5 };
    _ = api_v9.AIL_add_setblend_event_step(ev, cstr("blend1"), 2, &in_min, &in_max, &out_min, &out_max, &min_p, &max_p);
    const str = api_v8b.AIL_close_event(ev) orelse return error.NoStr;
    defer std.c.free(str);

    var buf: [1024]u8 align(8) = undefined;
    var sp: ?*openmiles.event.EVENT_STEP_INFO = null;
    var cur: ?*const anyopaque = @ptrCast(str);
    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expectEqual(@intFromEnum(openmiles.event.StepType.set_blend), sp.?.type);
    const b = sp.?.u.blend;
    try testing.expectEqualStrings("blend1", b.name.str.?[0..@intCast(b.name.len)]);
    try testing.expectEqual(@as(u8, 2), b.count);
    try testing.expectApproxEqAbs(@as(f32, 0.1), b.inmin[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0), b.inmax[1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -0.5), b.minp[1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), b.maxp[1], 0.0001);
    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expect(cur == null);
}

test "cache_sounds step splits the colon-separated sound list into namelist" {
    const ev = api_v8b.AIL_create_event() orelse return error.NoEvent;
    _ = api_v8b.AIL_add_cache_sounds_event_step(ev, cstr("bank"), cstr("a:bee:cee"));
    const str = api_v8b.AIL_close_event(ev) orelse return error.NoStr;
    defer std.c.free(str);
    var buf: [512]u8 align(8) = undefined;
    var sp: ?*openmiles.event.EVENT_STEP_INFO = null;
    var cur: ?*const anyopaque = @ptrCast(str);
    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expectEqual(@intFromEnum(openmiles.event.StepType.cache_sounds), sp.?.type);
    const ld = sp.?.u.load;
    try testing.expectEqualStrings("bank", ld.lib.str.?[0..@intCast(ld.lib.len)]);
    try testing.expectEqual(@as(i32, 3), ld.namecount);
    const list = ld.namelist.?;
    try testing.expectEqualStrings("a", std.mem.span(@as([*:0]const u8, @ptrCast(list[0].?))));
    try testing.expectEqualStrings("bee", std.mem.span(@as([*:0]const u8, @ptrCast(list[1].?))));
    try testing.expectEqualStrings("cee", std.mem.span(@as([*:0]const u8, @ptrCast(list[2].?))));
    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expect(cur == null);
}

test "EVENT_STEP_INFO union member layouts match the SDK field order" {
    const ev = openmiles.event;
    const ssc = @sizeOf(ev.MSSStringC); // {const char* str; S32 len}
    // start: 9 counted strings, then stream (U32) at offset 9*ssc.
    try testing.expectEqual(@as(usize, 0), @offsetOf(ev.StartStep, "soundname"));
    try testing.expectEqual(ssc, @offsetOf(ev.StartStep, "presetname"));
    try testing.expectEqual(9 * ssc, @offsetOf(ev.StartStep, "stream"));
    // control: 5 strings then fadeouttime (F32).
    try testing.expectEqual(5 * ssc, @offsetOf(ev.ControlStep, "fadeouttime"));
    // load: lib, then namelist pointer, then namecount.
    try testing.expectEqual(@as(usize, 0), @offsetOf(ev.LoadStep, "lib"));
    try testing.expectEqual(ssc, @offsetOf(ev.LoadStep, "namelist"));
    // ramp: name, labels, target (3 strings) then time (F32).
    try testing.expectEqual(3 * ssc, @offsetOf(ev.RampStep, "time"));
    // setlfo: 4 strings then invert..islfo (5 x S32).
    try testing.expectEqual(4 * ssc, @offsetOf(ev.SetLfoStep, "invert"));
    try testing.expectEqual(4 * ssc + 4 * @sizeOf(i32), @offsetOf(ev.SetLfoStep, "islfo"));
    // movevar: name then time[2], interp_types[2], values[3].
    try testing.expectEqual(ssc, @offsetOf(ev.MoveVarStep, "times"));
    // EVENT_STEP_INFO: type tag at offset 0.
    try testing.expectEqual(@as(usize, 0), @offsetOf(ev.EVENT_STEP_INFO, "type"));
    // blend is the largest union member (6 x [10]F32 plus name and count).
    try testing.expect(@sizeOf(ev.StepUnion) >= @sizeOf(ev.BlendStep));
    try testing.expect(@sizeOf(ev.MSSStringC) == 2 * @sizeOf(usize) or @sizeOf(ev.MSSStringC) == @sizeOf(usize) + @sizeOf(i32));
}

fn buildEventBank(buf: []u8) usize {
    const sb = openmiles.soundbank;
    @memset(buf, 0);
    std.mem.writeInt(u32, buf[0..4], sb.BANK_TAG, .little);
    std.mem.writeInt(i32, buf[4..8], 8, .little); // version
    std.mem.writeInt(u32, buf[20..24], 60, .little); // events table offset
    std.mem.writeInt(u32, buf[40..44], 1, .little); // event count
    @memcpy(buf[56..60], "tb\x00\x00"); // SoundBankName[4]
    // events table: entry 0 = { NameOffset=68, DataOffset=73 }
    std.mem.writeInt(u32, buf[60..64], 68, .little);
    std.mem.writeInt(u32, buf[64..68], 73, .little);
    @memcpy(buf[68..73], "boom\x00");
    const data = "9;4;<;";
    @memcpy(buf[73 .. 73 + data.len], data);
    buf[73 + data.len] = 0;
    const total = 73 + data.len + 1;
    std.mem.writeInt(i32, buf[8..12], @intCast(total), .little); // meta_size
    return total;
}

test "soundbank loader resolves event assets and bytecode" {
    var img: [128]u8 = undefined;
    const n = buildEventBank(&img);
    const bank = try openmiles.soundbank.loadFromMemory(testing.allocator, "syn.mbnk", img[0..n]);
    defer bank.deinit();
    try testing.expectEqual(@as(u32, 1), bank.assetCount(.events));
    try testing.expectEqual(@as(u32, 0), bank.assetCount(.sounds));
    try testing.expectEqualStrings("boom", std.mem.span(bank.assetName(.events, 0).?));
    const ev = bank.findEventContents("boom") orelse return error.NoEvent;
    try testing.expectEqualStrings("9;4;<;", std.mem.span(@as([*:0]const u8, @ptrCast(ev))));
    try testing.expect(bank.findEventContents("BOOM") != null); // case-insensitive
    try testing.expect(bank.findEventContents("missing") == null);
    try testing.expect(bank.assetName(.events, 1) == null); // out of range
}

test "MilesFindEvent and MilesReleaseSoundBank operate on a loaded bank" {
    var img: [128]u8 = undefined;
    const n = buildEventBank(&img);
    // The file-read path (readWholeFile) is shared with AIL_open_soundbank and is
    // fuzzed; here we exercise the C-ABI query/release on a directly-loaded bank.
    const bank = try openmiles.soundbank.loadFromMemory(openmiles.global_allocator, "syn.mbnk", img[0..n]);
    const bptr: ?*anyopaque = @ptrCast(bank);
    const ev = api_miles_t.MilesFindEvent(bptr, "boom") orelse return error.NoEvent;
    try testing.expectEqualStrings("9;4;<;", std.mem.span(@as([*:0]const u8, @ptrCast(ev))));
    try testing.expect(api_miles_t.MilesFindEvent(bptr, "nope") == null);
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesReleaseSoundBank(bptr));
}

test "MilesGetEventSystemState reports the live loaded-bank count" {
    var img: [128]u8 = undefined;
    const n = buildEventBank(&img);
    var state: api_miles_t.MILESEVENTSTATE = undefined;
    api_miles_t.MilesGetEventSystemState(null, &state);
    const base = state.LoadedBankCount; // order-independent baseline
    const b1 = try openmiles.soundbank.loadFromMemory(openmiles.global_allocator, "a.mbnk", img[0..n]);
    const b2 = try openmiles.soundbank.loadFromMemory(openmiles.global_allocator, "b.mbnk", img[0..n]);
    api_miles_t.MilesGetEventSystemState(null, &state);
    try testing.expectEqual(base + 2, state.LoadedBankCount);
    b1.deinit();
    b2.deinit();
    api_miles_t.MilesGetEventSystemState(null, &state);
    try testing.expectEqual(base, state.LoadedBankCount);
}

test "the bank name check compares over the field, not the caller's length" {
    // SoundBankName[4] is a fixed four-byte field, and "café" is five bytes: the
    // field holds the first three and the lead byte of the é, and the bank's
    // own read-back drops the partial character. Comparing the caller's whole
    // string against that three-byte result rejects the name the field does
    // spell, so the bank never opens.
    var img: [128]u8 = undefined;
    const n = buildEventBank(&img);
    @memcpy(img[56..60], "caf\xC3"[0..4]);

    const write = struct {
        fn go(bytes: []const u8) !void {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            const f = try tmp.dir.createFile(openmiles.io, "n.mbnk", .{});
            try f.writeStreamingAll(openmiles.io, bytes);
            f.close(openmiles.io);
            var path_buf: [256]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/n.mbnk", .{&tmp.sub_path});
            const path_z: [:0]u8 = try openmiles.global_allocator.dupeZ(u8, path);
            defer openmiles.global_allocator.free(path_z);

            const before = openmiles.soundbank.loadedCount();
            // The name the field spells, in a spelling the field is one byte
            // too short for, opens the bank.
            const want: [:0]const u8 = "caf\u{00e9}";
            const bank = api_v8b.AIL_open_soundbank(@ptrCast(path_z.ptr), @ptrCast(@constCast(want.ptr))) orelse return error.OpenFailed;
            try testing.expectEqual(before + 1, openmiles.soundbank.loadedCount());
            api_v8b.AIL_close_soundbank(bank);

            // A name the field cannot spell is still a mismatch, in the byte
            // where the two first differ.
            const other: [:0]const u8 = "musi";
            try testing.expect(api_v8b.AIL_open_soundbank(@ptrCast(path_z.ptr), @ptrCast(@constCast(other.ptr))) == null);
            try testing.expectEqual(before, openmiles.soundbank.loadedCount());
        }
    };
    try write.go(img[0..n]);
}

test "opening the same soundbank file twice loads one bank" {
    // A game that opens a bank, does not see what it expected, and opens it
    // again must end up where one open leaves it: one bank in the container, one
    // copy of the metadata, and a close that matches each open.
    var img: [128]u8 = undefined;
    const n = buildEventBank(&img);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = openmiles.io;
    {
        const file = try tmp.dir.createFile(io, "once.mbnk", .{});
        try file.writeStreamingAll(io, img[0..n]);
        file.close(io);
    }
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}/once.mbnk", .{&tmp.sub_path});
    const path_z: [:0]u8 = try openmiles.global_allocator.dupeZ(u8, path);
    defer openmiles.global_allocator.free(path_z);

    const before = openmiles.soundbank.loadedCount();
    const first = api_v8b.AIL_open_soundbank(@ptrCast(path_z.ptr), null) orelse return error.OpenFailed;
    const second = api_v8b.AIL_open_soundbank(@ptrCast(path_z.ptr), null) orelse return error.OpenFailed;
    try testing.expectEqual(@intFromPtr(first), @intFromPtr(second));
    try testing.expectEqual(before + 1, openmiles.soundbank.loadedCount());

    // The event is resolvable through either handle, and the first close leaves
    // it resolvable: the second open is still open.
    const ev = api_miles_t.MilesFindEvent(first, "boom") orelse return error.NoEvent;
    try testing.expectEqualStrings("9;4;<;", std.mem.span(@as([*:0]const u8, @ptrCast(ev))));
    api_v8b.AIL_close_soundbank(first);
    try testing.expectEqual(before + 1, openmiles.soundbank.loadedCount());
    try testing.expect(api_miles_t.MilesFindEvent(second, "boom") != null);

    api_v8b.AIL_close_soundbank(second);
    try testing.expectEqual(before, openmiles.soundbank.loadedCount());
}

test "AIL_get_event_contents returns the event bytecode pointer" {
    var img: [128]u8 = undefined;
    const n = buildEventBank(&img);
    const bank = try openmiles.soundbank.loadFromMemory(openmiles.global_allocator, "syn.mbnk", img[0..n]);
    defer bank.deinit();
    const bptr: ?*anyopaque = @ptrCast(bank);
    var ev: ?[*]const u8 = null;
    try testing.expectEqual(@as(i32, 1), api_v8b.AIL_get_event_contents(bptr, cstr("boom"), @ptrCast(&ev)));
    try testing.expectEqualStrings("9;4;<;", std.mem.span(@as([*:0]const u8, @ptrCast(ev.?))));
    try testing.expectEqual(@as(i32, 0), api_v8b.AIL_get_event_contents(bptr, cstr("nope"), @ptrCast(&ev)));
    try testing.expect(ev == null);
}

test "AIL_sound_asset_filename formats *<bank><sound> and returns DataLen" {
    var img: [200]u8 = undefined;
    @memset(&img, 0);
    const sb = openmiles.soundbank;
    std.mem.writeInt(u32, img[0..4], sb.BANK_TAG, .little);
    std.mem.writeInt(i32, img[4..8], 8, .little);
    std.mem.writeInt(u32, img[32..36], 60, .little); // sounds table offset
    std.mem.writeInt(u32, img[52..56], 1, .little); // sound count
    @memcpy(img[56..60], "g\x00\x00\x00");
    std.mem.writeInt(u32, img[60..64], 68, .little); // Sounds[0].NameOffset
    std.mem.writeInt(u32, img[64..68], 80, .little); // Sounds[0].DataOffset -> Sound struct
    @memcpy(img[68..73], "shot\x00");
    // Sound struct at 80: FileNameOffset (Sound+4) = 40 -> filename at 120
    std.mem.writeInt(u32, img[84..88], 40, .little);
    // MILESBANKSOUNDINFO.DataLen at Sound+12(Info)+12 = 104
    std.mem.writeInt(i32, img[104..108], 12345, .little);
    @memcpy(img[120..129], "shot.wav\x00");
    const total: i32 = 129;
    std.mem.writeInt(i32, img[8..12], total, .little);

    const bank = try openmiles.soundbank.loadFromMemory(openmiles.global_allocator, "guns.mbnk", img[0..@intCast(total)]);
    defer bank.deinit();
    var out: [128]u8 = undefined;
    const dl = api_v8b.AIL_sound_asset_filename_v8(@ptrCast(bank), cstr("shot"), @ptrCast(&out));
    try testing.expectEqual(@as(i32, 12345), dl);
    try testing.expectEqualStrings("*guns.mbnkshot.wav", std.mem.span(@as([*:0]const u8, @ptrCast(&out))));
    try testing.expectEqual(@as(i32, -1), api_v8b.AIL_sound_asset_filename_v8(@ptrCast(bank), cstr("nope"), @ptrCast(&out)));
}

test "AIL_sound_asset_info copies MILESBANKSOUNDINFO and returns buffer requirement" {
    var img: [200]u8 = undefined;
    @memset(&img, 0);
    const sb = openmiles.soundbank;
    std.mem.writeInt(u32, img[0..4], sb.BANK_TAG, .little);
    std.mem.writeInt(i32, img[4..8], 8, .little);
    std.mem.writeInt(u32, img[32..36], 60, .little);
    std.mem.writeInt(u32, img[52..56], 1, .little);
    @memcpy(img[56..60], "g\x00\x00\x00");
    std.mem.writeInt(u32, img[60..64], 68, .little);
    std.mem.writeInt(u32, img[64..68], 80, .little);
    @memcpy(img[68..73], "shot\x00");
    // Sound struct at 80. Info occupies 92..136, so the filename goes after it.
    std.mem.writeInt(u32, img[84..88], 56, .little); // FileNameOffset (Sound+4) -> 80+56=136
    // Info at Sound+12 = 92: ChannelCount=2, Rate=44100 (Info+8), DataLen=12345 (Info+12)
    std.mem.writeInt(i32, img[92..96], 2, .little);
    std.mem.writeInt(i32, img[100..104], 44100, .little);
    std.mem.writeInt(i32, img[104..108], 12345, .little);
    @memcpy(img[136..145], "shot.wav\x00");
    const total: i32 = 145;
    std.mem.writeInt(i32, img[8..12], total, .little);

    const bank = try openmiles.soundbank.loadFromMemory(openmiles.global_allocator, "guns.mbnk", img[0..@intCast(total)]);
    defer bank.deinit();
    var fnbuf: [128]u8 = undefined;
    var info: [44]u8 = undefined;
    const req = api_v9.AIL_sound_asset_info(@ptrCast(bank), cstr("shot"), @ptrCast(&fnbuf), @ptrCast(&info));
    try testing.expectEqual(@as(i32, 2 + 9 + 8), req);
    try testing.expectEqualStrings("*guns.mbnkshot.wav", std.mem.span(@as([*:0]const u8, @ptrCast(&fnbuf))));
    try testing.expectEqual(@as(i32, 2), std.mem.readInt(i32, info[0..4], .little)); // ChannelCount
    try testing.expectEqual(@as(i32, 44100), std.mem.readInt(i32, info[8..12], .little)); // Rate
    try testing.expectEqual(@as(i32, 12345), std.mem.readInt(i32, info[12..16], .little)); // DataLen
    // querying with null output buffers still returns the requirement
    try testing.expectEqual(@as(i32, 19), api_v9.AIL_sound_asset_info(@ptrCast(bank), cstr("shot"), null, null));
}

test "MilesGetEventLength resolves first start-sound duration via the container" {
    // Build a start-sound event that references sound "boom".
    const ev = api_v8b.AIL_create_event() orelse return error.NoEvent;
    _ = api_v8b.AIL_add_start_sound_event_step(ev, cstr("boom:0:"), null, 0, null, null, null, null, null, null, 0, 0, 0, 0, 0, 0, null, 0, 0, 0, 0, 0, 0, 0);
    const estr = api_v8b.AIL_close_event(ev) orelse return error.NoStr;
    defer std.c.free(estr);
    const etext = std.mem.span(@as([*:0]const u8, @ptrCast(estr)));
    const elen = etext.len + 1;

    var img: [512]u8 = undefined;
    @memset(&img, 0);
    const sb = openmiles.soundbank;
    std.mem.writeInt(u32, img[0..4], sb.BANK_TAG, .little);
    std.mem.writeInt(i32, img[4..8], 8, .little);
    std.mem.writeInt(u32, img[20..24], 60, .little); // events table @60
    std.mem.writeInt(u32, img[32..36], 68, .little); // sounds table @68
    std.mem.writeInt(u32, img[40..44], 1, .little); // event count
    std.mem.writeInt(u32, img[52..56], 1, .little); // sound count
    @memcpy(img[56..60], "b\x00\x00\x00");
    std.mem.writeInt(u32, img[60..64], 76, .little); // Events[0].NameOffset -> "evt"
    std.mem.writeInt(u32, img[64..68], 100, .little); // Events[0].DataOffset -> event text
    std.mem.writeInt(u32, img[68..72], 82, .little); // Sounds[0].NameOffset -> "boom"
    std.mem.writeInt(u32, img[72..76], 300, .little); // Sounds[0].DataOffset -> Sound struct
    @memcpy(img[76..80], "evt\x00");
    @memcpy(img[82..87], "boom\x00");
    @memcpy(img[100 .. 100 + elen], etext.ptr[0..elen]);
    // Sound struct @300: DurationMs is at Sound+12(Info)+24 = 336.
    std.mem.writeInt(u32, img[336..340], 4500, .little);
    std.mem.writeInt(i32, img[8..12], 344, .little); // meta_size

    const bank = try openmiles.soundbank.loadFromMemory(openmiles.global_allocator, "fx.mbnk", img[0..344]);
    defer bank.deinit();
    try testing.expectEqual(@as(i32, 4500), api_miles_t.MilesGetEventLength(cstr2("evt")));
    try testing.expectEqual(@as(i32, 0), api_miles_t.MilesGetEventLength(cstr2("missing")));
}

fn cstr2(s: [*:0]const u8) [*:0]const u8 {
    return s;
}

test "Miles sound instance lifecycle: enqueue, enumerate, process, stop" {
    _ = api_miles_t.MilesStopSoundInstances(null, 0); // clear any leftover

    // Bank with sound "boom" of 4500 ms.
    var img: [200]u8 = undefined;
    @memset(&img, 0);
    const sb = openmiles.soundbank;
    std.mem.writeInt(u32, img[0..4], sb.BANK_TAG, .little);
    std.mem.writeInt(i32, img[4..8], 8, .little);
    std.mem.writeInt(u32, img[32..36], 60, .little); // sounds table @60
    std.mem.writeInt(u32, img[52..56], 1, .little); // sound count
    std.mem.writeInt(u32, img[60..64], 76, .little); // Sounds[0].NameOffset
    std.mem.writeInt(u32, img[64..68], 80, .little); // Sounds[0].DataOffset -> Sound @80
    @memcpy(img[76..81], "boom\x00");
    std.mem.writeInt(u32, img[116..120], 4500, .little); // DurationMs at Sound+36
    std.mem.writeInt(i32, img[8..12], 120, .little);
    const bank = try openmiles.soundbank.loadFromMemory(openmiles.global_allocator, "fx.mbnk", img[0..120]);
    defer bank.deinit();

    // A start-sound event referencing "boom".
    const ev = api_v8b.AIL_create_event() orelse return error.NoEvent;
    _ = api_v8b.AIL_add_start_sound_event_step(ev, cstr("boom:0:"), null, 0, null, null, null, null, null, null, 0, 0, 0, 0, 0, 0, null, 0, 0, 0, 0, 0, 0, 0);
    const estr = api_v8b.AIL_close_event(ev) orelse return error.NoStr;
    const qid = api_miles_t.MilesEnqueueEvent(@ptrCast(estr), null, 0, 0x2, 0); // FREE_EVENT
    defer _ = api_miles_t.MilesStopSoundInstances(null, 0);
    try testing.expect(qid != 0);

    var nx: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize)); // MSS_FIRST
    var info: api_miles_t.MILESEVENTSOUNDINFO = undefined;
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0x1, null, 0, @ptrCast(&info)));
    try testing.expectEqualStrings("boom", std.mem.span(info.UsedSound.?));
    try testing.expectEqual(@as(i32, 0x1), info.Status); // PENDING
    try testing.expectEqual(@as(i32, 0), api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0x1, null, 0, @ptrCast(&info)));

    _ = api_miles_t.MilesBeginEventQueueProcessing();
    var state: api_miles_t.MILESEVENTSTATE = undefined;
    api_miles_t.MilesGetEventSystemState(null, &state);
    try testing.expectEqual(@as(i32, 1), state.PlayingSoundCount);

    try testing.expectEqual(@as(u64, 1), api_miles_t.MilesStopSoundInstances(null, 0));
    nx = @ptrFromInt(std.math.maxInt(usize));
    try testing.expectEqual(@as(i32, 0), api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, null, 0, @ptrCast(&info)));
}

test "cache_sounds/purge_sounds events update LoadedSoundCount" {
    _ = api_miles_t.MilesStopSoundInstances(null, 0);
    api_miles_t.MilesClearEventQueue();
    api_miles_t.MilesShutdownEventSystem(); // clears the cache set

    var state: api_miles_t.MILESEVENTSTATE = undefined;
    api_miles_t.MilesGetEventSystemState(null, &state);
    const base = state.LoadedSoundCount;

    // Cache three sounds.
    const ev = api_v8b.AIL_create_event() orelse return error.NoEvent;
    _ = api_v8b.AIL_add_cache_sounds_event_step(ev, cstr("lib"), cstr("a:bee:cee"));
    const e1 = api_v8b.AIL_close_event(ev) orelse return error.NoStr;
    _ = api_miles_t.MilesEnqueueEvent(@ptrCast(e1), null, 0, 0x2, 0);
    api_miles_t.MilesGetEventSystemState(null, &state);
    try testing.expectEqual(base + 3, state.LoadedSoundCount);

    // Duplicate cache is deduped.
    const ev2 = api_v8b.AIL_create_event() orelse return error.NoEvent;
    _ = api_v8b.AIL_add_cache_sounds_event_step(ev2, cstr("lib"), cstr("a:bee"));
    const e2 = api_v8b.AIL_close_event(ev2) orelse return error.NoStr;
    _ = api_miles_t.MilesEnqueueEvent(@ptrCast(e2), null, 0, 0x2, 0);
    api_miles_t.MilesGetEventSystemState(null, &state);
    try testing.expectEqual(base + 3, state.LoadedSoundCount);

    // So is the same name in another case: the container resolves sound names
    // case-insensitively, so "BEE" is the sound already cached as "bee".
    const ev2b = api_v8b.AIL_create_event() orelse return error.NoEvent;
    _ = api_v8b.AIL_add_cache_sounds_event_step(ev2b, cstr("lib"), cstr("BEE:a"));
    const e2b = api_v8b.AIL_close_event(ev2b) orelse return error.NoStr;
    _ = api_miles_t.MilesEnqueueEvent(@ptrCast(e2b), null, 0, 0x2, 0);
    api_miles_t.MilesGetEventSystemState(null, &state);
    try testing.expectEqual(base + 3, state.LoadedSoundCount);

    // Purge two.
    const ev3 = api_v8b.AIL_create_event() orelse return error.NoEvent;
    _ = api_v8b.AIL_add_uncache_sounds_event_step(ev3, cstr("lib"), cstr("a:cee"));
    const e3 = api_v8b.AIL_close_event(ev3) orelse return error.NoStr;
    _ = api_miles_t.MilesEnqueueEvent(@ptrCast(e3), null, 0, 0x2, 0);
    api_miles_t.MilesGetEventSystemState(null, &state);
    try testing.expectEqual(base + 1, state.LoadedSoundCount);

    // A purge that differs only in case still evicts the cached sound.
    const ev4 = api_v8b.AIL_create_event() orelse return error.NoEvent;
    _ = api_v8b.AIL_add_uncache_sounds_event_step(ev4, cstr("lib"), cstr("BEE"));
    const e4 = api_v8b.AIL_close_event(ev4) orelse return error.NoStr;
    _ = api_miles_t.MilesEnqueueEvent(@ptrCast(e4), null, 0, 0x2, 0);
    api_miles_t.MilesGetEventSystemState(null, &state);
    try testing.expectEqual(base, state.LoadedSoundCount);

    api_miles_t.MilesShutdownEventSystem();
}

test "persist events populate PersistCount and MilesEnumeratePresetPersists" {
    api_miles_t.MilesShutdownEventSystem(); // clear persists/cache/instances

    const ev = api_v8b.AIL_create_event() orelse return error.NoEvent;
    // persist(preset, name, labels, isdynamic): the persist's identity is "name".
    _ = api_v8b.AIL_add_persist_preset_event_step(ev, cstr("preset_a"), cstr("save1"), cstr(""), 0);
    const e1 = api_v8b.AIL_close_event(ev) orelse return error.NoStr;
    _ = api_miles_t.MilesEnqueueEvent(@ptrCast(e1), null, 0, 0x2, 0);

    var state: api_miles_t.MILESEVENTSTATE = undefined;
    api_miles_t.MilesGetEventSystemState(null, &state);
    try testing.expectEqual(@as(i32, 1), state.PersistCount);

    var nx: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
    var name: ?[*:0]const u8 = null;
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesEnumeratePresetPersists(null, &nx, &name));
    try testing.expectEqualStrings("save1", std.mem.span(name.?));
    try testing.expectEqual(@as(i32, 0), api_miles_t.MilesEnumeratePresetPersists(null, &nx, &name));

    // Re-persisting the same name is deduped.
    const ev2 = api_v8b.AIL_create_event() orelse return error.NoEvent;
    _ = api_v8b.AIL_add_persist_preset_event_step(ev2, cstr("preset_b"), cstr("save1"), cstr(""), 0);
    const e2 = api_v8b.AIL_close_event(ev2) orelse return error.NoStr;
    _ = api_miles_t.MilesEnqueueEvent(@ptrCast(e2), null, 0, 0x2, 0);
    api_miles_t.MilesGetEventSystemState(null, &state);
    try testing.expectEqual(@as(i32, 1), state.PersistCount);

    // And so is the same name in another case: the persist registry is keyed
    // the way every other name registry here is, so "SAVE1" is the persist
    // already stored as "save1" rather than a second one.
    const ev3 = api_v8b.AIL_create_event() orelse return error.NoEvent;
    _ = api_v8b.AIL_add_persist_preset_event_step(ev3, cstr("preset_c"), cstr("SAVE1"), cstr(""), 0);
    const e3 = api_v8b.AIL_close_event(ev3) orelse return error.NoStr;
    _ = api_miles_t.MilesEnqueueEvent(@ptrCast(e3), null, 0, 0x2, 0);
    api_miles_t.MilesGetEventSystemState(null, &state);
    try testing.expectEqual(@as(i32, 1), state.PersistCount);
    nx = @ptrFromInt(std.math.maxInt(usize));
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesEnumeratePresetPersists(null, &nx, &name));
    try testing.expectEqual(@as(i32, 0), api_miles_t.MilesEnumeratePresetPersists(null, &nx, &name));

    api_miles_t.MilesShutdownEventSystem();
}

test "Miles sound instances filter by label query" {
    api_miles_t.MilesShutdownEventSystem();
    // Two start-sound instances with different labels.
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("music_a"), 0, 0, cstr2("music"), null, 0, 0);
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("sfx_a"), 0, 0, cstr2("sfx,gun"), null, 0, 0);
    defer api_miles_t.MilesShutdownEventSystem();

    // Enumerate by label "music" -> only the music instance.
    var nx: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
    var info: api_miles_t.MILESEVENTSOUNDINFO = undefined;
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, cstr2("music"), 0, @ptrCast(&info)));
    try testing.expectEqualStrings("music_a", std.mem.span(info.UsedSound.?));
    try testing.expectEqual(@as(i32, 0), api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, cstr2("music"), 0, @ptrCast(&info)));

    // Glob: "gu*" matches the "gun" label.
    nx = @ptrFromInt(std.math.maxInt(usize));
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, cstr2("gu*"), 0, @ptrCast(&info)));

    // Stop only "sfx" -> one removed, music remains.
    try testing.expectEqual(@as(u64, 1), api_miles_t.MilesStopSoundInstances(cstr2("sfx"), 0));
    nx = @ptrFromInt(std.math.maxInt(usize));
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, null, 0, @ptrCast(&info)));
    try testing.expectEqualStrings("music_a", std.mem.span(info.UsedSound.?));
}

test "MilesSetSoundLabelLimits caps concurrent sounds per label (evicts oldest)" {
    api_miles_t.MilesShutdownEventSystem();
    defer api_miles_t.MilesShutdownEventSystem();
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesSetSoundLabelLimits(null, cstr2("music 2:sfx 4")));

    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("m1"), 0, 0, cstr2("music"), null, 0, 0);
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("m2"), 0, 0, cstr2("music"), null, 0, 0);
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("m3"), 0, 0, cstr2("music"), null, 0, 0);

    // Only 2 "music" instances survive; the oldest (m1) was evicted.
    var count: i32 = 0;
    var seen_m1 = false;
    var nx: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
    var info: api_miles_t.MILESEVENTSOUNDINFO = undefined;
    while (api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, cstr2("music"), 0, @ptrCast(&info)) == 1) {
        count += 1;
        if (std.mem.eql(u8, std.mem.span(info.UsedSound.?), "m1")) seen_m1 = true;
    }
    try testing.expectEqual(@as(i32, 2), count);
    try testing.expect(!seen_m1);

    // sfx limit of 4 leaves a single sfx untouched.
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("s1"), 0, 0, cstr2("sfx"), null, 0, 0);
    nx = @ptrFromInt(std.math.maxInt(usize));
    var sfx: i32 = 0;
    while (api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, cstr2("sfx"), 0, @ptrCast(&info)) == 1) sfx += 1;
    try testing.expectEqual(@as(i32, 1), sfx);
}

test "label wildcard '?' spans a whole multi-byte character" {
    api_miles_t.MilesShutdownEventSystem();
    defer api_miles_t.MilesShutdownEventSystem();

    // "caf\u{00E9}" is five bytes and four characters. A '?' is one character, so
    // "caf?" must match it and "caf" alone must not.
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("m1"), 0, 0, cstr2("caf\u{00E9}"), null, 0, 0);
    var nx: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
    var info: api_miles_t.MILESEVENTSOUNDINFO = undefined;
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, cstr2("caf?"), 0, @ptrCast(&info)));
    nx = @ptrFromInt(std.math.maxInt(usize));
    try testing.expectEqual(@as(i32, 0), api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, cstr2("caf"), 0, @ptrCast(&info)));
}

test "label limits evict the oldest instances by id after the list is shuffled" {
    api_miles_t.MilesShutdownEventSystem();
    defer api_miles_t.MilesShutdownEventSystem();
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesSetSoundLabelLimits(null, cstr2("music 2")));

    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("m1"), 0, 0, cstr2("music"), null, 0, 0);
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("m2"), 0, 0, cstr2("music"), null, 0, 0);
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("x1"), 0, 0, cstr2("other"), null, 0, 0);
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("m3"), 0, 0, cstr2("music"), null, 0, 0);
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("m4"), 0, 0, cstr2("music"), null, 0, 0);
    // Stopping the middle entry moves the last one into its slot, so the list
    // order no longer tracks instance_id.
    try testing.expectEqual(@as(u64, 1), api_miles_t.MilesStopSoundInstances(cstr2("other"), 0));
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("m5"), 0, 0, cstr2("music"), null, 0, 0);

    // Cap 2 over 4 music instances: the three oldest by id (m1, m2, m3) go.
    var seen_m1 = false;
    var seen_m2 = false;
    var seen_m3 = false;
    var seen_m4 = false;
    var seen_m5 = false;
    var nx: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
    var info: api_miles_t.MILESEVENTSOUNDINFO = undefined;
    var count: i32 = 0;
    while (api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, cstr2("music"), 0, @ptrCast(&info)) == 1) {
        count += 1;
        const used = std.mem.span(info.UsedSound.?);
        if (std.mem.eql(u8, used, "m1")) seen_m1 = true;
        if (std.mem.eql(u8, used, "m2")) seen_m2 = true;
        if (std.mem.eql(u8, used, "m3")) seen_m3 = true;
        if (std.mem.eql(u8, used, "m4")) seen_m4 = true;
        if (std.mem.eql(u8, used, "m5")) seen_m5 = true;
    }
    try testing.expectEqual(@as(i32, 2), count);
    try testing.expect(!seen_m1);
    try testing.expect(!seen_m2);
    try testing.expect(!seen_m3);
    try testing.expect(seen_m4);
    try testing.expect(seen_m5);

    // A cap of 0 evicts every existing instance carrying the label before the new
    // one is added, so only the sound just started survives.
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesSetSoundLabelLimits(null, cstr2("music 0")));
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("m6"), 0, 0, cstr2("music"), null, 0, 0);
    nx = @ptrFromInt(std.math.maxInt(usize));
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, cstr2("music"), 0, @ptrCast(&info)));
    try testing.expectEqualStrings("m6", std.mem.span(info.UsedSound.?));
}

test "zero-duration instances complete on processing instead of accumulating" {
    api_miles_t.MilesShutdownEventSystem();
    defer api_miles_t.MilesShutdownEventSystem();

    // No bank is loaded, so both sounds resolve to duration 0. Before queue
    // processing they are tracked (PENDING); Begin+Complete must reap them
    // rather than leave them PLAYING forever (unbounded per-event growth).
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("unknown_a"), 0, 0, cstr2(""), null, 0, 0);
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("unknown_b"), 0, 0, cstr2(""), null, 0, 0);
    var nx: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
    var info: api_miles_t.MILESEVENTSOUNDINFO = undefined;
    var pending: i32 = 0;
    while (api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0x1, null, 0, @ptrCast(&info)) == 1) pending += 1;
    try testing.expectEqual(@as(i32, 2), pending); // PENDING before processing

    _ = api_miles_t.MilesBeginEventQueueProcessing();
    _ = api_miles_t.MilesCompleteEventQueueProcessing();

    nx = @ptrFromInt(std.math.maxInt(usize));
    try testing.expectEqual(@as(i32, 0), api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, null, 0, @ptrCast(&info)));
    var state: api_miles_t.MILESEVENTSTATE = undefined;
    api_miles_t.MilesGetEventSystemState(null, &state);
    try testing.expectEqual(@as(i32, 0), state.PlayingSoundCount);
}

test "an instance enumeration walk survives stopping instances mid-walk" {
    api_miles_t.MilesShutdownEventSystem();
    defer api_miles_t.MilesShutdownEventSystem();

    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("a"), 0, 0, cstr2("grp,a"), null, 0, 0);
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("b"), 0, 0, cstr2("grp,b"), null, 0, 0);
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("c"), 0, 0, cstr2("grp,c"), null, 0, 0);
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("d"), 0, 0, cstr2("grp,d"), null, 0, 0);

    // The documented MSS pattern: enumerate, act on what came back, keep
    // walking. Stopping an entry compacts the list under the cursor, so a
    // cursor naming a position rather than an identity would resume on whatever
    // slid into the freed slot and never report the rest. Each instance also
    // carries its own label so the walk stops exactly the one it enumerated.
    var seen: usize = 0;
    var seen_c = false;
    var nx: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
    var info: api_miles_t.MILESEVENTSOUNDINFO = undefined;
    while (api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, cstr2("grp"), 0, @ptrCast(&info)) == 1) {
        seen += 1;
        const used = std.mem.span(info.UsedSound.?);
        if (std.mem.eql(u8, used, "c")) seen_c = true;
        try testing.expectEqual(@as(u64, 1), api_miles_t.MilesStopSoundInstances(cstr2(used), 0));
    }
    try testing.expectEqual(@as(usize, 4), seen);
    try testing.expect(seen_c);

    // Everything the walk acted on is gone.
    try testing.expectEqual(@as(u64, 0), api_miles_t.MilesStopSoundInstances(cstr2("grp"), 0));
}

test "container resolves bank-prefixed sound names (Container_GetSound)" {
    var img: [200]u8 = undefined;
    @memset(&img, 0);
    const sb = openmiles.soundbank;
    std.mem.writeInt(u32, img[0..4], sb.BANK_TAG, .little);
    std.mem.writeInt(i32, img[4..8], 8, .little);
    std.mem.writeInt(u32, img[32..36], 60, .little);
    std.mem.writeInt(u32, img[52..56], 1, .little);
    std.mem.writeInt(u32, img[60..64], 76, .little);
    std.mem.writeInt(u32, img[64..68], 80, .little);
    @memcpy(img[76..81], "boom\x00");
    std.mem.writeInt(u32, img[116..120], 4500, .little); // DurationMs at Sound+36
    std.mem.writeInt(i32, img[8..12], 120, .little);
    const bank = try openmiles.soundbank.loadFromMemory(openmiles.global_allocator, "fx.mbnk", img[0..120]);
    defer bank.deinit();
    // "<bank>/<sound>" and the bare name both resolve; an unknown name does not.
    try testing.expectEqual(@as(?u32, 4500), openmiles.soundbank.containerSoundDurationMs("fx/boom"));
    try testing.expectEqual(@as(?u32, 4500), openmiles.soundbank.containerSoundDurationMs("boom"));
    try testing.expectEqual(@as(?u32, null), openmiles.soundbank.containerSoundDurationMs("nope"));
}

test "soundbank rejects lying u32 sound offsets without overflowing" {
    var img: [200]u8 = undefined;
    @memset(&img, 0);
    const sb = openmiles.soundbank;
    std.mem.writeInt(u32, img[0..4], sb.BANK_TAG, .little);
    std.mem.writeInt(i32, img[4..8], 8, .little);
    std.mem.writeInt(u32, img[32..36], 60, .little);
    std.mem.writeInt(u32, img[52..56], 1, .little);
    std.mem.writeInt(u32, img[60..64], 76, .little);
    // DataOffset = maxInt(u32): every offset computation on this record must
    // widen/saturate instead of overflowing a u32 addition (panic in safe
    // builds, wrap -> bogus reads in release).
    std.mem.writeInt(u32, img[64..68], std.math.maxInt(u32), .little);
    @memcpy(img[76..81], "boom\x00");
    std.mem.writeInt(i32, img[8..12], 120, .little);
    const bank = try sb.loadFromMemory(testing.allocator, "evil.mbnk", img[0..120]);
    defer bank.deinit();

    var fname: [64]u8 = undefined;
    try testing.expectEqual(@as(i32, -1), bank.soundAssetFilename("boom", &fname));
    try testing.expectEqual(@as(u8, 0), fname[0]);
    try testing.expectEqual(@as(i32, 0), bank.soundAssetInfo("boom", &fname, null));
    try testing.expectEqual(@as(u8, 0), fname[0]);
    // Found by name but its record lies past the metadata: duration reports 0.
    try testing.expectEqual(@as(?u32, 0), sb.containerSoundDurationMs("boom"));
}

test "MilesTextDumpEventSystem reports system/instance/persist counts" {
    api_miles_t.MilesShutdownEventSystem();
    defer api_miles_t.MilesShutdownEventSystem();
    _ = api_miles_t.MilesStartupEventSystem(null, 0, null, 0);
    _ = api_miles_t.MilesStartSoundInstance(null, cstr2("a"), 0, 0, cstr2(""), null, 0, 0);
    const dump = api_miles_t.MilesTextDumpEventSystem() orelse return error.NoDump;
    defer std.c.free(dump);
    const text = std.mem.span(@as([*:0]const u8, @ptrCast(dump)));
    try testing.expect(std.mem.indexOf(u8, text, "Event System Count: 1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Sound Instance Count: 1") != null);
}

test "MilesEnqueueEventByName resolves the event from the container and enqueues it" {
    api_miles_t.MilesShutdownEventSystem();
    defer api_miles_t.MilesShutdownEventSystem();

    // Build a start-sound event referencing "boom" and store it in a bank under "evt".
    const ev = api_v8b.AIL_create_event() orelse return error.NoEvent;
    _ = api_v8b.AIL_add_start_sound_event_step(ev, cstr("boom:0:"), null, 0, null, null, null, null, null, cstr("ambient"), 0, 0, 0, 0, 0, 0, null, 0, 0, 0, 0, 0, 0, 0);
    const estr = api_v8b.AIL_close_event(ev) orelse return error.NoStr;
    defer std.c.free(estr);
    const etext = std.mem.span(@as([*:0]const u8, @ptrCast(estr)));
    const elen = etext.len + 1;

    var img: [512]u8 = undefined;
    @memset(&img, 0);
    const sb = openmiles.soundbank;
    std.mem.writeInt(u32, img[0..4], sb.BANK_TAG, .little);
    std.mem.writeInt(i32, img[4..8], 8, .little);
    std.mem.writeInt(u32, img[20..24], 60, .little); // events table
    std.mem.writeInt(u32, img[32..36], 68, .little); // sounds table
    std.mem.writeInt(u32, img[40..44], 1, .little);
    std.mem.writeInt(u32, img[52..56], 1, .little);
    std.mem.writeInt(u32, img[60..64], 76, .little); // event name @76
    std.mem.writeInt(u32, img[64..68], 100, .little); // event data @100
    std.mem.writeInt(u32, img[68..72], 82, .little); // sound name @82
    std.mem.writeInt(u32, img[72..76], 300, .little); // Sound struct @300
    @memcpy(img[76..80], "evt\x00");
    @memcpy(img[82..87], "boom\x00");
    @memcpy(img[100 .. 100 + elen], etext.ptr[0..elen]);
    std.mem.writeInt(u32, img[336..340], 2000, .little); // DurationMs at Sound+36
    std.mem.writeInt(i32, img[8..12], 344, .little);
    const bank = try openmiles.soundbank.loadFromMemory(openmiles.global_allocator, "amb.mbnk", img[0..344]);
    defer bank.deinit();

    // Enqueue by name -> creates a "boom" instance with the event's labels.
    try testing.expect(api_miles_t.MilesEnqueueEventByName(cstr2("evt")) != 0);
    try testing.expectEqual(@as(u64, 0), api_miles_t.MilesEnqueueEventByName(cstr2("nope")));

    var nx: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
    var info: api_miles_t.MILESEVENTSOUNDINFO = undefined;
    try testing.expectEqual(@as(i32, 1), api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, cstr2("ambient"), 0, @ptrCast(&info)));
    try testing.expectEqualStrings("boom", std.mem.span(info.UsedSound.?));
}

test "cache_sounds namelist handles a trailing colon without a wild slot" {
    const ev = api_v8b.AIL_create_event() orelse return error.NoEvent;
    // Trailing-colon list: counts 3 entries but writes only "a","b".
    _ = api_v8b.AIL_add_cache_sounds_event_step(ev, cstr("lib"), cstr("a:b:"));
    const str = api_v8b.AIL_close_event(ev) orelse return error.NoStr;
    defer std.c.free(str);
    var buf: [512]u8 align(8) = undefined;
    var sp: ?*openmiles.event.EVENT_STEP_INFO = null;
    var cur: ?*const anyopaque = @ptrCast(str);
    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expectEqual(@intFromEnum(openmiles.event.StepType.cache_sounds), sp.?.type);
    const ld = sp.?.u.load;
    const list = ld.namelist.?;
    try testing.expectEqualStrings("a", std.mem.span(@as([*:0]const u8, @ptrCast(list[0].?))));
    try testing.expectEqualStrings("b", std.mem.span(@as([*:0]const u8, @ptrCast(list[1].?))));
    // The over-counted trailing slot must be null (not uninitialized scratch).
    if (ld.namecount >= 3) try testing.expect(list[2] == null);
    cur = api_v8b.AIL_next_event_step(cur, &sp, &buf, buf.len);
    try testing.expect(cur == null);
}

test "set_sample_volume_pan maps F32 0..1 to the engine volume/pan scale" {
    const hd = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer hd.deinit();
    const s = try openmiles.Sample.init(hd);
    defer s.deinit();
    dg.AIL_set_sample_volume_pan(s, 1.0, 0.5); // full volume, centre pan
    try testing.expectEqual(@as(i32, 127), s.original_volume);
    try testing.expectApproxEqAbs(@as(f32, 0.0), s.pan, 0.02);
    dg.AIL_set_sample_volume_pan(s, 0.0, 0.0); // silent, hard left
    try testing.expectEqual(@as(i32, 0), s.original_volume);
    try testing.expectApproxEqAbs(@as(f32, -1.0), s.pan, 0.02);
    dg.AIL_set_sample_volume_pan(s, 0.5, 1.0); // half, hard right
    try testing.expectEqual(@as(i32, 63), s.original_volume);
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.pan, 0.02);
}

test "volume/pan match the exact MSS curve (gain = volume^(10/6))" {
    // wavefile.cpp: gain = volume^(10/6) (0.5 -> -10 dB ~= 0.3162), pan law
    // left=gain*(1-pan)^0.3, right=gain*pan^0.3, center uses 0.5^0.3=0.812252.
    try testing.expectEqual(@as(f32, 0.0), openmiles.mssVolumeToGain(0));
    try testing.expectEqual(@as(f32, 1.0), openmiles.mssVolumeToGain(127));
    try testing.expectApproxEqAbs(@as(f32, 0.319), openmiles.mssVolumeToGain(64), 0.01);

    const hd = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer hd.deinit();
    const s = try openmiles.Sample.init(hd);
    defer s.deinit();
    s.setVolumePanF(1.0, 0.0); // hard left
    try testing.expectApproxEqAbs(@as(f32, -1.0), s.pan, 0.001);
    s.setVolumePanF(1.0, 1.0); // hard right
    try testing.expectApproxEqAbs(@as(f32, 1.0), s.pan, 0.001);
    s.setVolumePanF(1.0, 0.5); // center -> pan 0, vol = 1*0.812 (MSS center cut)
    try testing.expectApproxEqAbs(@as(f32, 0.0), s.pan, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.8123), s.volume, 0.01);

    // AIL_sample_pan must still report the 0..127 pan the app set, not the
    // internal balance-panner value (regression guard for the curve change).
    s.setVolumePanF(1.0, 0.25);
    try testing.expectEqual(@as(i32, 31), dg.AIL_sample_pan(s)); // 0.25*127
    dg.AIL_set_sample_pan(s, 100);
    try testing.expectEqual(@as(i32, 100), dg.AIL_sample_pan(s));

    // The F32 AIL_sample_volume_pan getter returns the original 0..1 vol/pan
    // the app set (the SDK inverts the gain curve / returns save_pan), not the
    // internal balance-pan value.
    dg.AIL_set_sample_volume_pan(s, 0.8, 0.25);
    var gv: f32 = 0;
    var gp: f32 = 0;
    api_v7.AIL_sample_volume_pan(s, &gv, &gp);
    // Exact float round-trip (no i32 0..127 quantization).
    try testing.expectApproxEqAbs(@as(f32, 0.8), gv, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), gp, 0.0001);

    // SDK wavefile.cpp stores save_volume = pow(volume,10/6) and save_pan
    // verbatim (no clamp); the getter returns pow(save_volume,6/10) == volume
    // for volume >= 0 and save_pan as-is -- so out-of-range values round-trip.
    dg.AIL_set_sample_volume_pan(s, 1.5, 0.9);
    api_v7.AIL_sample_volume_pan(s, &gv, &gp);
    try testing.expectApproxEqAbs(@as(f32, 1.5), gv, 0.0001); // NOT clamped to 1.0
    try testing.expectApproxEqAbs(@as(f32, 0.9), gp, 0.0001);

    // Null handle: the getter leaves the caller's out-params UNTOUCHED (it does
    // not zero them, unlike AIL_sample_reverb_levels).
    gv = 7.0;
    gp = 8.0;
    api_v7.AIL_sample_volume_pan(null, &gv, &gp);
    try testing.expectEqual(@as(f32, 7.0), gv);
    try testing.expectEqual(@as(f32, 8.0), gp);
}

test "5.1 set_levels reconstructs save_pan/fb_pan/volume (inverts volume_pan)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    // Set via volume_pan, read the six levels, feed them back through set_levels,
    // then query volume_pan -- the params must come back (the SDK reconstruction).
    api_v8.AIL_set_sample_51_volume_pan(s, 0.8, 0.5, 0.5, 0.7, 0.3);
    var fl: f32 = 0;
    var fr: f32 = 0;
    var bl: f32 = 0;
    var br: f32 = 0;
    var c: f32 = 0;
    var sub: f32 = 0;
    api_v8.AIL_sample_51_volume_levels(s, &fl, &fr, &bl, &br, &c, &sub);
    api_v8.AIL_set_sample_51_volume_levels(s, fl, fr, bl, br, c, sub);
    var v: f32 = 0;
    var p: f32 = 0;
    var fb: f32 = 0;
    var cl: f32 = 0;
    var sl: f32 = 0;
    api_v8.AIL_sample_51_volume_pan(s, &v, &p, &fb, &cl, &sl);
    try testing.expectApproxEqAbs(@as(f32, 0.8), v, 0.005);
    try testing.expectApproxEqAbs(@as(f32, 0.5), p, 0.005);
    try testing.expectApproxEqAbs(@as(f32, 0.5), fb, 0.005);
    try testing.expectApproxEqAbs(@as(f32, 0.7), cl, 0.005);
    try testing.expectApproxEqAbs(@as(f32, 0.3), sl, 0.005);
}

test "AIL_set/sample_51_volume_pan round-trips the params verbatim" {
    // The getter must return the params the app set (save_*), not values derived
    // from the computed channel levels.
    const hd = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer hd.deinit();
    const s = try openmiles.Sample.init(hd);
    defer s.deinit();
    api_v8.AIL_set_sample_51_volume_pan(s, 0.8, 0.3, 0.7, 0.5, 0.9);
    var v: f32 = 0;
    var p: f32 = 0;
    var fb: f32 = 0;
    var c: f32 = 0;
    var sub: f32 = 0;
    api_v8.AIL_sample_51_volume_pan(s, &v, &p, &fb, &c, &sub);
    try testing.expectApproxEqAbs(@as(f32, 0.8), v, 0.02);
    try testing.expectApproxEqAbs(@as(f32, 0.3), p, 0.02);
    try testing.expectApproxEqAbs(@as(f32, 0.7), fb, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), c, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.9), sub, 0.001);
}

test "AIL_set/sample_reverb_levels round-trips dry and wet independently" {
    const hd = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer hd.deinit();
    const s = try openmiles.Sample.init(hd);
    defer s.deinit();
    // dry and wet are independent in MSS (they need not sum to 1).
    api_v7.AIL_set_sample_reverb_levels(s, 0.5, 0.3);
    var dry: f32 = 0;
    var wet: f32 = 0;
    api_v7.AIL_sample_reverb_levels(s, &dry, &wet);
    try testing.expectApproxEqAbs(@as(f32, 0.5), dry, 0.001); // not 1-0.3
    try testing.expectApproxEqAbs(@as(f32, 0.3), wet, 0.001);
    // The SDK stores dry/wet verbatim (no clamp); out-of-range values round-trip
    // even though the engine drives the reverb node with a clamped wet.
    api_v7.AIL_set_sample_reverb_levels(s, 1.5, 1.8);
    api_v7.AIL_sample_reverb_levels(s, &dry, &wet);
    try testing.expectEqual(@as(f32, 1.5), dry);
    try testing.expectEqual(@as(f32, 1.8), wet);
}

test "digital master volume is linear (vol/127), not the sample-volume curve" {
    // The master volume is a linear final gain (F32 master sets dig->master_volume
    // directly), unlike the perceptual ^(10/6) sample-volume curve.
    const hd = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer hd.deinit();
    dg.AIL_set_digital_master_volume(hd, 64);
    try testing.expectApproxEqAbs(@as(f32, 0.504), hd.getMasterVolume(), 0.01); // 64/127, not ~0.319
    try testing.expectEqual(@as(i32, 64), dg.AIL_digital_master_volume(hd)); // round-trip
    dg.AIL_set_digital_master_volume(hd, 127);
    try testing.expectApproxEqAbs(@as(f32, 1.0), hd.getMasterVolume(), 0.001);
}

test "AIL_digital_master_volume_level (F32) round-trips verbatim, null->0, default 1.0" {
    // SDK genericdig.cpp: default dig->master_volume = 1.0F; the F32 setter
    // stores verbatim (NO clamp) and the getter returns the raw field.
    try testing.expectEqual(@as(f32, 0.0), api_v7.AIL_digital_master_volume_level(null));
    const hd = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer hd.deinit();
    try testing.expectApproxEqAbs(@as(f32, 1.0), api_v7.AIL_digital_master_volume_level(hd), 0.001); // default
    api_v7.AIL_set_digital_master_volume_level(hd, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), api_v7.AIL_digital_master_volume_level(hd), 0.001);
    // Out-of-range value must survive the round-trip un-clamped (SDK stores verbatim).
    api_v7.AIL_set_digital_master_volume_level(hd, 1.5);
    try testing.expectApproxEqAbs(@as(f32, 1.5), api_v7.AIL_digital_master_volume_level(hd), 0.001);
    api_v7.AIL_set_digital_master_volume_level(null, 0.3); // null setter: no crash
}

test "AIL_digital_configuration reports rate + DIG_F_* format, null-safe" {
    // SDK genericdig.cpp: *rate = dig->DMA_rate; *format = dig->hw_format.
    // Our 16-bit miniaudio backend => DIG_F_MONO_16=1 / DIG_F_STEREO_16=3.
    var rate: i32 = -1;
    var format: i32 = -1;
    dg.AIL_digital_configuration(null, &rate, &format, null); // null driver: no write
    try testing.expectEqual(@as(i32, -1), rate);
    try testing.expectEqual(@as(i32, -1), format);

    const stereo = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer stereo.deinit();
    dg.AIL_digital_configuration(stereo, &rate, &format, null);
    try testing.expectEqual(@as(i32, 44100), rate);
    try testing.expectEqual(@as(i32, 3), format); // DIG_F_STEREO_16

    const mono = try openmiles.DigitalDriver.init(testing.allocator, 22050, 16, 1);
    defer mono.deinit();
    dg.AIL_digital_configuration(mono, &rate, &format, null);
    try testing.expectEqual(@as(i32, 22050), rate);
    try testing.expectEqual(@as(i32, 1), format); // DIG_F_MONO_16
}

test "AIL_3D_position/velocity/orientation round-trip (H3DPOBJECT: sample + listener)" {
    // Getters return exactly what the setters stored; AIL_set_3D_velocity scales
    // each component by `magnitude` (m3d.cpp set_listener_3D_velocity -> *_vector
    // with dX*magnitude), so the getter sees the pre-scaled value.
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s3 = api_3d.AIL_allocate_3D_sample_handle(drv) orelse return error.AllocFailed;

    var x: f32 = 0;
    var y: f32 = 0;
    var z: f32 = 0;

    // --- Sample3D (the "else" H3DPOBJECT branch) ---
    api_3d.AIL_set_3D_position(s3, 1.0, 2.0, 3.0);
    api_3d.AIL_3D_position(s3, &x, &y, &z);
    try testing.expectEqual(@as(f32, 1.0), x);
    try testing.expectEqual(@as(f32, 2.0), y);
    try testing.expectEqual(@as(f32, 3.0), z);

    api_3d.AIL_set_3D_velocity(s3, 1.0, 2.0, 3.0, 2.0); // magnitude=2 -> (2,4,6)
    api_3d.AIL_3D_velocity(s3, &x, &y, &z);
    try testing.expectEqual(@as(f32, 2.0), x);
    try testing.expectEqual(@as(f32, 4.0), y);
    try testing.expectEqual(@as(f32, 6.0), z);

    var fx: f32 = 0;
    var fy: f32 = 0;
    var fz: f32 = 0;
    var ux: f32 = 0;
    var uy: f32 = 0;
    var uz: f32 = 0;
    api_3d.AIL_set_3D_orientation(s3, 0.0, 0.0, -1.0, 0.0, 1.0, 0.0);
    api_3d.AIL_3D_orientation(s3, &fx, &fy, &fz, &ux, &uy, &uz);
    try testing.expectEqual(@as(f32, -1.0), fz);
    try testing.expectEqual(@as(f32, 1.0), uy);

    // --- listener (the isKnownDriver branch of the same polymorphic getter) ---
    const lobj: *anyopaque = @ptrCast(drv);
    api_3d.AIL_set_3D_position(lobj, -5.0, 6.0, 7.0);
    api_3d.AIL_3D_position(lobj, &x, &y, &z);
    try testing.expectEqual(@as(f32, -5.0), x);
    try testing.expectEqual(@as(f32, 6.0), y);
    try testing.expectEqual(@as(f32, 7.0), z);
}

test "AIL_redbook_set_volume_level returns the previous volume (F32)" {
    const rb = try openmiles.Redbook.init(testing.allocator);
    defer rb.deinit();
    _ = api_v7.AIL_redbook_set_volume_level(rb, 0.8);
    const prev = api_v7.AIL_redbook_set_volume_level(rb, 0.3); // returns the prior 0.8
    try testing.expectApproxEqAbs(@as(f32, 0.8), prev, 0.02);
    try testing.expectApproxEqAbs(@as(f32, 0.3), api_v7.AIL_redbook_volume_level(rb), 0.02);
}

// A minimal in-memory VFS exercising the MSS file-callback ABI.
var vfs_data: []const u8 = "";
var vfs_pos: u32 = 0;
fn vfsOpen(name: [*:0]const u8, handle: *u32) callconv(.winapi) u32 {
    _ = name;
    handle.* = 0xABCD; // arbitrary token
    vfs_pos = 0;
    return @intCast(vfs_data.len); // MSS open returns the file length
}
fn vfsClose(h: u32) callconv(.winapi) void {
    _ = h;
}
fn vfsSeek(h: u32, offset: i32, typ: u32) callconv(.winapi) i32 {
    _ = h;
    vfs_pos = switch (typ) {
        openmiles.SEEK_SET => @intCast(@max(offset, 0)),
        openmiles.SEEK_END => @intCast(@max(@as(i64, @intCast(vfs_data.len)) + offset, 0)),
        else => vfs_pos +% @as(u32, @bitCast(offset)),
    };
    return @intCast(vfs_pos);
}
fn vfsRead(h: u32, buffer: *anyopaque, bytes: u32) callconv(.winapi) u32 {
    _ = h;
    const remain: u32 = @intCast(vfs_data.len - vfs_pos);
    const n = @min(bytes, remain);
    @memcpy(@as([*]u8, @ptrCast(buffer))[0..n], vfs_data[vfs_pos..][0..n]);
    vfs_pos += n;
    return n;
}

test "file callbacks route through the VFS with the correct ABI" {
    vfs_data = "Hello VFS payload!";
    // SDK order: (open, close, seek, read). If seek/read were swapped, the read
    // below would invoke the seek callback and fail.
    api_file.AIL_set_file_callbacks(@ptrCast(@constCast(&vfsOpen)), @ptrCast(@constCast(&vfsClose)), @ptrCast(@constCast(&vfsSeek)), @ptrCast(@constCast(&vfsRead)));
    defer api_file.AIL_set_file_callbacks(null, null, null, null);

    // AIL_file_size returns open()'s length value.
    try testing.expectEqual(@as(u32, @intCast(vfs_data.len)), api_file.AIL_file_size("any"));

    // AIL_file_read pulls the whole file through open->read->close.
    var dst: [64]u8 = undefined;
    const r = api_file.AIL_file_read("any", &dst);
    try testing.expect(r != null);
    try testing.expectEqualStrings("Hello VFS payload!", dst[0..vfs_data.len]);

    // The _info tracking variants (the REAL exports; the plain names are
    // __FILE__/__LINE__ macros) must do the same work, not return null/0.
    const fname: ?*anyopaque = @ptrCast(@constCast("any"));
    try testing.expectEqual(@as(i32, @intCast(vfs_data.len)), api_v9.AIL_file_size_info(fname, null, 0));
    var dst2: [64]u8 = undefined;
    const r2 = api_v9.AIL_file_read_info(fname, &dst2, null, 0);
    try testing.expect(r2 != null);
    try testing.expectEqualStrings("Hello VFS payload!", dst2[0..vfs_data.len]);
    // Null filename is guarded (no deref of the span).
    try testing.expectEqual(@as(i32, 0), api_v9.AIL_file_size_info(null, null, 0));
}

// A VFS whose open reports length 0 (empty or sizeless file). Counts closes so
// the test can pin that AIL_file_size releases the handle on every path -- open
// hands out a live token even when it cannot name a size.
var zero_len_open_calls: u32 = 0;
var zero_len_close_calls: u32 = 0;
var zero_len_seek_end: i32 = 0;
fn zeroLenOpen(name: [*:0]const u8, handle: *u32) callconv(.winapi) u32 {
    _ = name;
    zero_len_open_calls += 1;
    handle.* = 0xBEEF;
    return 0;
}
fn zeroLenClose(h: u32) callconv(.winapi) void {
    if (h == 0xBEEF) zero_len_close_calls += 1;
}
fn zeroLenSeek(h: u32, offset: i32, typ: u32) callconv(.winapi) i32 {
    _ = h;
    if (typ == openmiles.SEEK_END and offset == 0) return zero_len_seek_end;
    return 0;
}

test "AIL_file_size closes the VFS handle when open reports length 0" {
    api_file.AIL_set_file_callbacks(@ptrCast(@constCast(&zeroLenOpen)), @ptrCast(@constCast(&zeroLenClose)), @ptrCast(@constCast(&zeroLenSeek)), @ptrCast(@constCast(&vfsRead)));
    defer api_file.AIL_set_file_callbacks(null, null, null, null);

    // No seek fallback: size stays 0, but the opened handle must still be closed.
    zero_len_open_calls = 0;
    zero_len_close_calls = 0;
    zero_len_seek_end = 0;
    try testing.expectEqual(@as(u32, 0), api_file.AIL_file_size("empty"));
    try testing.expectEqual(@as(u32, 1), zero_len_open_calls);
    try testing.expectEqual(@as(u32, 1), zero_len_close_calls);
    // The failed probe sets the documented error state.
    try testing.expectEqualStrings("File not found", std.mem.span(api_file.AIL_file_error()));

    // Seek-to-end names a size for a length-0 open: the fallback value is
    // returned and the handle is closed exactly once more.
    zero_len_close_calls = 0;
    zero_len_seek_end = 42;
    try testing.expectEqual(@as(u32, 42), api_file.AIL_file_size("sizeless"));
    try testing.expectEqual(@as(u32, 1), zero_len_close_calls);
}

test "AIL_mem_alloc_lock_info actually allocates (the real exported allocator)" {
    // AIL_mem_alloc_lock(size) is a macro for AIL_mem_alloc_lock_info(size,
    // __FILE__, __LINE__), so the _info form must allocate, not return null.
    const p = api_v9.AIL_mem_alloc_lock_info(64, null, 0);
    try testing.expect(p != null);
    // Writable, and freeable via the matching AIL_mem_free_lock.
    const bytes: [*]u8 = @ptrCast(p.?);
    bytes[0] = 0xAB;
    bytes[63] = 0xCD;
    try testing.expectEqual(@as(u8, 0xAB), bytes[0]);
    const mem = @import("api/memory.zig");
    mem.AIL_mem_free_lock(p.?);
}

// The accessors and guards the section above leaves untouched: the init-time
// parameter check, the ring-depth clamp, the read-back of play position, the
// underrun flag, and the index bound on submit.
test "StreamSource.init rejects a zero channel count" {
    // Zero channels yields frame_size 0, which divides by zero in the read
    // path, so the ring has to refuse it at the boundary.
    var ss: openmiles.StreamSource = undefined;
    try testing.expectError(error.InvalidParam, ss.init(16, 0, 44100, null, null));
}

test "StreamSource.setSlotCount clamps to the SDK ring range" {
    var ss: openmiles.StreamSource = undefined;
    try ss.init(16, 1, 22050, null, null);
    defer ss.deinit();

    var pos: u32 = 0;
    var len: u32 = 0;
    const pcm = [_]u8{0} ** 8;

    // Below mss.h's low end: the ring still offers min_slots fillable slots.
    ss.setSlotCount(0);
    _ = ss.loadBuffer(0, &pcm, pcm.len);
    _ = ss.loadBuffer(1, &pcm, pcm.len);
    try testing.expectEqual(@as(i32, -1), ss.bufferReady());

    // Above its high end: the deepest ring is max_slots, and an index past it
    // is not a submission but silently dropped, so the app's fill is reported
    // as taken by a ring that will never play it.
    ss.setSlotCount(99);
    var i: usize = 2;
    while (i < openmiles.StreamSource.max_slots) : (i += 1) _ = ss.loadBuffer(i, &pcm, pcm.len);
    try testing.expectEqual(@as(i32, -1), ss.bufferReady());
    // Past the ring depth, slotInfo reports empty rather than reading outside
    // the slot array.
    ss.slotInfo(openmiles.StreamSource.max_slots, &pos, &len);
    try testing.expectEqual(@as(u32, 0), pos);
    try testing.expectEqual(@as(u32, 0), len);
    ss.slotInfo(openmiles.StreamSource.max_slots - 1, &pos, &len);
    try testing.expectEqual(@as(u32, 0), pos);
    try testing.expectEqual(@as(u32, pcm.len), len);
}

test "StreamSource.loadBuffer ignores a slot index past the ring depth" {
    var ss: openmiles.StreamSource = undefined;
    try ss.init(16, 1, 22050, null, null);
    defer ss.deinit();

    // A 2-deep ring is the default; slot 2 belongs to no configured ring.
    const pcm = [_]u8{0xAB} ** 8;
    _ = ss.loadBuffer(2, &pcm, pcm.len);

    var pos: u32 = 0;
    var len: u32 = 0;
    ss.slotInfo(2, &pos, &len);
    try testing.expectEqual(@as(u32, 0), pos);
    try testing.expectEqual(@as(u32, 0), len);
    // The rejection leaves the real ring untouched, so slot 0 is still free.
    try testing.expectEqual(@as(i32, 0), ss.bufferReady());
}

test "StreamSource.bufferInfo reports each slot's play position and length" {
    var ss: openmiles.StreamSource = undefined;
    try ss.init(16, 1, 22050, null, null);
    defer ss.deinit();

    var pos0: u32 = 0;
    var len0: u32 = 0;
    var pos1: u32 = 0;
    var len1: u32 = 0;
    ss.bufferInfo(&pos0, &len0, &pos1, &len1);
    try testing.expectEqual(@as(u32, 0), pos0);
    try testing.expectEqual(@as(u32, 0), len0);
    try testing.expectEqual(@as(u32, 0), pos1);
    try testing.expectEqual(@as(u32, 0), len1);

    const first = [_]u8{0} ** 8;
    const second = [_]u8{0} ** 4;
    _ = ss.loadBuffer(0, &first, first.len);
    _ = ss.loadBuffer(1, &second, second.len);

    // Two 16-bit mono frames out of slot 0. Slot 1 has not been touched, so its
    // position must still read 0 with its full length pending.
    var out: [4]u8 = undefined;
    var read: u64 = 0;
    _ = openmiles.ma.ma_data_source_read_pcm_frames(&ss.base, &out, 2, &read);
    try testing.expectEqual(@as(u64, 2), read);

    ss.bufferInfo(&pos0, &len0, &pos1, &len1);
    try testing.expectEqual(@as(u32, 4), pos0);
    try testing.expectEqual(@as(u32, first.len), len0);
    try testing.expectEqual(@as(u32, 0), pos1);
    try testing.expectEqual(@as(u32, second.len), len1);
}

test "StreamSource.isStarved latches until the next submission" {
    var ss: openmiles.StreamSource = undefined;
    try ss.init(16, 1, 22050, null, null);
    defer ss.deinit();

    try testing.expect(!ss.isStarved());

    // An underrun is what a starved ring reports; a submit that lands clears
    // the flag, which is the "the app refilled in time" signal.
    var out: [8]u8 = undefined;
    var read: u64 = 0;
    _ = openmiles.ma.ma_data_source_read_pcm_frames(&ss.base, &out, 4, &read);
    try testing.expectEqual(@as(u64, 4), read);
    try testing.expect(ss.isStarved());

    _ = ss.loadBuffer(0, &[_]u8{0} ** 4, 4);
    try testing.expect(!ss.isStarved());
}

test "a miniaudio result code reaches the log as something an operator can act on" {
    // The failure lines this formats are the ones a field log is read for: no
    // playback device under Wine is the common report, and a bare -1003 tells
    // the reader nothing. The code stays alongside the description so the line
    // can still be matched against upstream.
    const ok = openmiles.maResultDescription(openmiles.ma.MA_SUCCESS);
    try testing.expect(ok.len > 0);
    try testing.expect(!std.mem.eql(u8, ok, "(no description)"));

    // An unlisted code still comes back as text ("Unknown error"), never as a
    // blank: the fallback exists for a null or empty string, which the C API
    // does not currently produce, and a blank would erase the code's meaning
    // from the line that carries it.
    try testing.expect(openmiles.maResultDescription(-123456).len > 0);
    try testing.expectEqualStrings("Unknown error", openmiles.maResultDescription(-123456));
}

test "concurrent Miles starts, drains and queries lose no instance" { // A game's worker thread starting sounds while its main thread drains the
    // queue and reads the state is the ordinary split. Every registry behind
    // these calls is process-global: the instance list appends and grows its own
    // backing array, the id counter is a read-modify-write, and the status walk
    // reads the list while the drain swap-removes from it. The claim is
    // arithmetic, not timing: every started instance must be reachable in the
    // walk, so a torn length, a lost growth or a duplicated id shows up as a
    // count below the number of starts.
    _ = api_miles_t.MilesStartupEventSystem(null, 256, null, 0);
    defer api_miles_t.MilesShutdownEventSystem();
    api_miles_t.MilesClearEventQueue();

    const thread_count = 4;
    const per_thread = 250;
    const CB = struct {
        var gate: std.atomic.Value(u32) = .init(0);

        fn starter(slot: usize) void {
            _ = gate.fetchAdd(1, .release);
            while (gate.load(.acquire) < thread_count) std.atomic.spinLoopHint();
            var i: usize = 0;
            while (i < per_thread) : (i += 1) {
                // A distinct label per thread and per iteration, so the stop
                // filter below is exact rather than an approximation.
                var buf: [32]u8 = undefined;
                const nm = std.fmt.bufPrintZ(&buf, "s{d}_{d}", .{ slot, i }) catch unreachable;
                var lb: [32]u8 = undefined;
                const label = std.fmt.bufPrintZ(&lb, "w{d}", .{slot}) catch unreachable;
                _ = api_miles_t.MilesStartSoundInstance(null, nm, 0, 0, label, null, 0, 0);
            }
        }

        fn reader() void {
            _ = gate.fetchAdd(1, .release);
            while (gate.load(.acquire) < thread_count) std.atomic.spinLoopHint();
            var i: usize = 0;
            while (i < per_thread) : (i += 1) {
                var st: api_miles_t.MILESEVENTSTATE = undefined;
                api_miles_t.MilesGetEventSystemState(null, &st);
                var nx: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
                var info: api_miles_t.MILESEVENTSOUNDINFO = undefined;
                _ = api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, null, 0, @ptrCast(&info));
            }
        }
    };

    var handles: [thread_count + 1]std.Thread = undefined;
    for (handles[0..thread_count], 0..) |*h, i| h.* = try std.Thread.spawn(.{}, CB.starter, .{i});
    handles[thread_count] = try std.Thread.spawn(.{}, CB.reader, .{});
    for (handles) |h| h.join();

    // Every start is reachable in the walk, and every entry is distinct: the
    // cursor is the instance id, so two instances sharing one would make the
    // second unreachable and the count fall short.
    var seen: usize = 0;
    var nx: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
    var info: api_miles_t.MILESEVENTSOUNDINFO = undefined;
    while (api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, null, 0, @ptrCast(&info)) == 1) {
        seen += 1;
        if (seen > thread_count * per_thread) return error.TooManyInstances;
    }
    try testing.expectEqual(@as(usize, thread_count * per_thread), seen);
    try testing.expectEqual(@as(u64, @intCast(seen)), milesLiveInstanceCount());
}

// Live instances as the module's own walk reports them. The concurrent test
// asserts against this rather than reaching into the module's list, so the
// number checked is the one a game would see.
fn milesLiveInstanceCount() usize {
    var n: usize = 0;
    var nx: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));
    var info: api_miles_t.MILESEVENTSOUNDINFO = undefined;
    while (api_miles_t.MilesEnumerateSoundInstances(null, &nx, 0, null, 0, @ptrCast(&info)) == 1) n += 1;
    return n;
}

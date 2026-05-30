const std = @import("std");
const testing = std.testing;
const openmiles = @import("openmiles");

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
    // Cubic curve: gain = (64/127)^3 ≈ 0.128
    try testing.expect(sample.volume > 0.12 and sample.volume < 0.14);
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

test "Provider registry and finding" {
    const allocator = testing.allocator;
    const provider = try openmiles.Provider.init(allocator, null);
    defer provider.deinit();

    try testing.expectEqualStrings("unknown", provider.name);

    var entry = openmiles.RIB_INTERFACE_ENTRY{
        .entry_type = .RIB_FUNCTION,
        .name = "TestFunction",
        .token = 0x1234,
        .subtype = 0,
    };
    try provider.registerInterface("TestInterface", 1, &entry);

    var found = false;
    for (provider.interfaces.items) |iface| {
        if (std.mem.eql(u8, iface.name, "TestInterface")) {
            if (iface.entries.get("TestFunction")) |token| {
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

test "Provider registry allows duplicate interface names" {
    const allocator = testing.allocator;
    const provider = try openmiles.Provider.init(allocator, null);
    defer provider.deinit();

    var entry = openmiles.RIB_INTERFACE_ENTRY{
        .entry_type = .RIB_FUNCTION,
        .name = "DupFunction",
        .token = 0x9999,
        .subtype = 0,
    };
    try provider.registerInterface("TestIface", 1, &entry);
    const count_before = provider.interfaces.items.len;
    // Registering again should add a second entry (no dedup); verify it doesn't crash
    try provider.registerInterface("TestIface", 1, &entry);
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

test "Sample initial status is stopped" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();
    try testing.expectEqual(openmiles.SampleStatus.stopped, sample.status());
}

test "Sequence initial status is done when uninitialized" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const seq = try openmiles.Sequence.init(driver);
    defer seq.deinit();

    // Per MSS spec: uninitialized sequence reports SEQ_DONE
    try testing.expectEqual(openmiles.MidiStatus.done, seq.status());
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
    try testing.expectEqual(@as(f32, 100.0), s.max_distance);
    try testing.expect(!s.is_initialized);

    s.deinit();
    try testing.expectEqual(@as(usize, 0), driver.samples_3d.items.len);
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
    openmiles.io.sleep(std.Io.Duration.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
    const t2 = openmiles.getMsCount();
    try testing.expect(t2 > t1);
}

test "getUsCount returns monotonically increasing values" {
    const t1 = openmiles.getUsCount();
    openmiles.io.sleep(std.Io.Duration.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
    const t2 = openmiles.getUsCount();
    try testing.expect(t2 > t1);
}

test "getRedistDirectory returns empty initially" {
    const dir = openmiles.getRedistDirectory();
    try testing.expectEqual(@as(usize, 0), dir.len);
}

test "setRedistDirectory and getRedistDirectory roundtrip" {
    openmiles.setRedistDirectory("./test_plugins");
    defer openmiles.setRedistDirectory("");
    try testing.expectEqualStrings("./test_plugins", openmiles.getRedistDirectory());
}

test "setRedistDirectory truncates long paths" {
    const long_path = "/" ++ "a" ** 300;
    openmiles.setRedistDirectory(long_path);
    defer openmiles.setRedistDirectory("");
    const stored = openmiles.getRedistDirectory();
    try testing.expectEqual(@as(usize, 255), stored.len);
}

test "mssVolumeToGain boundary values" {
    try testing.expectEqual(@as(f32, 0.0), openmiles.mssVolumeToGain(0));
    try testing.expectEqual(@as(f32, 0.0), openmiles.mssVolumeToGain(-5));
    try testing.expectEqual(@as(f32, 1.0), openmiles.mssVolumeToGain(127));
    try testing.expectEqual(@as(f32, 1.0), openmiles.mssVolumeToGain(200));

    const mid_gain = openmiles.mssVolumeToGain(64);
    try testing.expect(mid_gain > 0.12 and mid_gain < 0.14);
}

test "gainToMssVolume boundary values" {
    try testing.expectEqual(@as(i32, 0), openmiles.gainToMssVolume(0.0));
    try testing.expectEqual(@as(i32, 0), openmiles.gainToMssVolume(-1.0));
    try testing.expectEqual(@as(i32, 127), openmiles.gainToMssVolume(1.0));
    try testing.expectEqual(@as(i32, 127), openmiles.gainToMssVolume(2.0));
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
    try testing.expectEqual(@as(?*openmiles.Sequence, null), openmiles.locked_channels[@intCast(ch)]);
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

test "preference defaults match MSS spec" {
    const P = openmiles.Pref;
    try testing.expectEqual(@as(i32, 131), openmiles.getPreference(@intFromEnum(P.DIG_RESAMPLING_TOLERANCE)));
    try testing.expectEqual(@as(i32, 127), openmiles.getPreference(@intFromEnum(P.DIG_DEFAULT_VOLUME)));
    try testing.expectEqual(@as(i32, 120), openmiles.getPreference(@intFromEnum(P.MDI_SERVICE_RATE)));
    try testing.expectEqual(@as(i32, 8), openmiles.getPreference(@intFromEnum(P.MDI_SEQUENCES)));
    try testing.expectEqual(@as(i32, 127), openmiles.getPreference(@intFromEnum(P.MDI_DEFAULT_VOLUME)));
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

test "Sample3D initial status is stopped" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    try testing.expectEqual(openmiles.SampleStatus.stopped, s.status());
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

    try testing.expectEqual(@as(u32, 0), driver.getActiveSampleCount());

    const s1 = try openmiles.Sample.init(driver);
    defer s1.deinit();
    const s2 = try openmiles.Sample.init(driver);
    defer s2.deinit();
    // Uninitialized samples are stopped, not playing
    try testing.expectEqual(@as(u32, 0), driver.getActiveSampleCount());
}

test "releaseChannel ignores out-of-range channel" {
    const allocator = testing.allocator;
    const driver = try openmiles.MidiDriver.init(allocator);
    defer driver.deinit();

    const seq = try openmiles.Sequence.init(driver);
    defer seq.deinit();

    // Should not crash or corrupt state
    openmiles.releaseChannel(seq, -1);
    openmiles.releaseChannel(seq, 16);
    openmiles.releaseChannel(seq, 100);
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

test "panToMss converts linear pan to MSS range" {
    try testing.expectEqual(@as(i32, 64), openmiles.panToMss(0.0));
    try testing.expectEqual(@as(i32, 0), openmiles.panToMss(-1.0));
    try testing.expectEqual(@as(i32, 127), openmiles.panToMss(1.0));
    try testing.expectEqual(@as(i32, 0), openmiles.panToMss(-2.0));
    try testing.expectEqual(@as(i32, 127), openmiles.panToMss(5.0));
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

    try testing.expectEqual(@as(u32, 0), driver.get3DActiveSampleCount());

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();
    try testing.expectEqual(@as(u32, 0), driver.get3DActiveSampleCount());
}

test "Sample setVolumePan sets both" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    sample.setVolumePan(64, 32);
    try testing.expect(sample.volume > 0.12 and sample.volume < 0.14);
    try testing.expectEqual(@as(f32, -0.5), sample.pan);
}

test "getActiveSequenceCount returns 0 with no sequences" {
    try testing.expectEqual(@as(u32, 0), openmiles.getActiveSequenceCount());
}

test "Sample end sets done status" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    try testing.expectEqual(openmiles.SampleStatus.stopped, sample.status());

    sample.end();
    try testing.expectEqual(openmiles.SampleStatus.done, sample.status());
}

test "Sample start on uninitialized resets done flag" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    sample.end();
    try testing.expectEqual(openmiles.SampleStatus.done, sample.status());

    sample.start();
    try testing.expectEqual(openmiles.SampleStatus.stopped, sample.status());
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
}

test "Sample loadFromMemory initializes sample" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    try testing.expect(!sample.is_initialized);

    const pcm = [_]u8{0} ** 4410;
    const wav = try openmiles.buildWavFromPcm(allocator, &pcm, 1, 44100, 8);
    defer allocator.free(wav);

    try sample.loadFromMemory(wav, true);
    try testing.expect(sample.is_initialized);
    try testing.expectEqual(openmiles.SampleStatus.stopped, sample.status());
}

test "Sample loadFromMemory then start and stop lifecycle" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    const pcm = [_]u8{0} ** 4410;
    const wav = try openmiles.buildWavFromPcm(allocator, &pcm, 1, 44100, 8);
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

test "Redbook init deinit and default state" {
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator, 0);
    defer rb.deinit();

    try testing.expectEqual(openmiles.RedbookStatus.stopped, rb.status);
    try testing.expectEqual(@as(u32, 0), rb.current_track);
    try testing.expectEqual(@as(u32, 127), rb.volume);
    try testing.expectEqual(@as(u32, 0), rb.trackCount());
}

test "Redbook play sets playing state" {
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator, 0);
    defer rb.deinit();

    rb.play(1, 5);
    try testing.expectEqual(openmiles.RedbookStatus.playing, rb.status);
    try testing.expectEqual(@as(u32, 1), rb.current_track);
    try testing.expectEqual(@as(u32, 5), rb.track_end);
}

test "Redbook stop resets state" {
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator, 0);
    defer rb.deinit();

    rb.play(3, 10);
    rb.stop();
    try testing.expectEqual(openmiles.RedbookStatus.stopped, rb.status);
    try testing.expectEqual(@as(u32, 0), rb.current_track);
    try testing.expectEqual(@as(u32, 0), rb.getPosition());
}

test "Redbook pause and resume lifecycle" {
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator, 0);
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
    const rb = try openmiles.Redbook.init(allocator, 0);
    defer rb.deinit();

    try testing.expectEqual(@as(u32, 0), rb.getPosition());
}

test "Redbook getPosition advances during playback" {
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator, 0);
    defer rb.deinit();

    rb.play(1, 5);
    openmiles.io.sleep(std.Io.Duration.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
    const pos = rb.getPosition();
    try testing.expect(pos > 0);
}

test "Redbook paused position is stable" {
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator, 0);
    defer rb.deinit();

    rb.play(1, 5);
    openmiles.io.sleep(std.Io.Duration.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
    rb.pause();
    const p1 = rb.getPosition();
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

    openmiles.io.sleep(std.Io.Duration.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
    timer.stop();
    try testing.expect(!timer.is_running);

    const count = called.load(.monotonic);
    try testing.expect(count > 0);
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
    const dummy_cb = struct {
        fn cb(_: u32) callconv(.winapi) void {}
    }.cb;
    const allocator = testing.allocator;
    const timer = try openmiles.Timer.init(allocator, dummy_cb);
    defer timer.deinit();

    timer.stop();
    timer.stop();
    try testing.expect(!timer.is_running);
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

test "preference defaults cover all documented prefs" {
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

test "Sample setPlaybackRate with 0 stores zero" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const sample = try openmiles.Sample.init(driver);
    defer sample.deinit();

    sample.setPlaybackRate(22050);
    try testing.expectEqual(@as(?f32, 22050.0), sample.target_rate);

    sample.setPlaybackRate(0);
    try testing.expectEqual(@as(?f32, 0.0), sample.target_rate);
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

    const pcm = [_]u8{0} ** 4410;
    const wav = try openmiles.buildWavFromPcm(allocator, &pcm, 1, 44100, 8);
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

test "Sample3D loadFromMemory and start stop lifecycle" {
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    const s = try openmiles.Sample3D.init(driver);
    defer s.deinit();

    const pcm = [_]u8{0} ** 4410;
    const wav = try openmiles.buildWavFromPcm(allocator, &pcm, 1, 44100, 8);
    defer allocator.free(wav);

    try s.loadFromMemory(wav, true);
    try testing.expect(s.is_initialized);
    try testing.expectEqual(openmiles.SampleStatus.stopped, s.status());

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

    const pcm = [_]u8{0} ** 4410;
    const wav = try openmiles.buildWavFromPcm(allocator, &pcm, 1, 44100, 8);
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

    const pcm = [_]u8{0} ** 4410;
    const wav = try openmiles.buildWavFromPcm(allocator, &pcm, 1, 44100, 8);
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

    const pcm = [_]u8{0} ** 4410;
    const wav = try openmiles.buildWavFromPcm(allocator, &pcm, 1, 44100, 8);
    defer allocator.free(wav);

    try sample.loadFromMemory(wav, true);

    sample.setPosition(0);
    try testing.expectEqual(@as(u32, 0), sample.getPosition());
}

test "Redbook trackCount returns 0" {
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator, 0);
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
    try testing.expectEqual(openmiles.SampleStatus.stopped, s.status());
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

// ---------------------------------------------------------------------------
// Double-buffered streaming source (AIL_load_sample_buffer ping-pong)
// ---------------------------------------------------------------------------

const StreamTestCtx = struct {
    eob_count: u32 = 0,
    last_idx: i32 = -1,
    last_len: u32 = 0,
};

fn streamTestHook(ctx: ?*anyopaque, idx: i32, len: u32, addr: ?*anyopaque) void {
    _ = addr;
    const c: *StreamTestCtx = @ptrCast(@alignCast(ctx.?));
    c.eob_count += 1;
    c.last_idx = idx;
    c.last_len = len;
}

test "StreamSource ping-pongs two buffers and fires EOB on drain" {
    var ctx = StreamTestCtx{};
    var ss: openmiles.StreamSource = undefined;
    try ss.init(16, 2, 44100, streamTestHook, &ctx); // 16-bit stereo → 4 bytes/frame
    defer ss.deinit();

    const buf_a = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }; // 2 frames
    const buf_b = [_]u8{ 11, 12, 13, 14, 15, 16, 17, 18 }; // 2 frames
    ss.loadBuffer(0, &buf_a, buf_a.len);
    ss.loadBuffer(1, &buf_b, buf_b.len);
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

test "StreamSource zero-length buffer signals end of stream" {
    var ss: openmiles.StreamSource = undefined;
    try ss.init(16, 2, 44100, null, null);
    defer ss.deinit();

    const buf_a = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 }; // 2 frames
    ss.loadBuffer(0, &buf_a, buf_a.len);
    ss.loadBuffer(1, null, 0); // EOF marker

    // miniaudio reports MA_AT_END on the read that yields 0 frames, so drain in
    // a loop; total decoded frames must be exactly buf_a's 2 before EOF.
    var out: [16]u8 = undefined;
    var total: u64 = 0;
    var hit_end = false;
    var guard: u32 = 0;
    while (guard < 8) : (guard += 1) {
        var read: u64 = 0;
        const r = openmiles.ma.ma_data_source_read_pcm_frames(&ss.base, out[@intCast(total * 4)..].ptr, 4 - total, &read);
        total += read;
        if (r == openmiles.ma.MA_AT_END) {
            hit_end = true;
            break;
        }
        if (read == 0) break;
    }
    try testing.expect(hit_end);
    try testing.expectEqual(@as(u64, 2), total);
    try testing.expectEqualSlices(u8, &buf_a, out[0..8]);
}

test "StreamSource underrun emits silence and keeps playing" {
    var ss: openmiles.StreamSource = undefined;
    try ss.init(16, 1, 22050, null, null); // 16-bit mono → 2 bytes/frame
    defer ss.deinit();

    const buf_a = [_]u8{ 9, 9 }; // 1 frame
    ss.loadBuffer(0, &buf_a, buf_a.len);

    var out: [8]u8 = [_]u8{0xAA} ** 8; // request 4 frames, only 1 available
    var read: u64 = 0;
    const r = openmiles.ma.ma_data_source_read_pcm_frames(&ss.base, &out, 4, &read);
    try testing.expectEqual(openmiles.ma.MA_SUCCESS, r); // not ended — starved
    try testing.expectEqual(@as(u64, 4), read); // padded with silence
    try testing.expectEqualSlices(u8, &buf_a, out[0..2]);
    try testing.expectEqualSlices(u8, &([_]u8{0} ** 6), out[2..8]); // silence
}

// --- MSS v8/v9 implemented utilities ----------------------------------------
const api_v8 = @import("api/v8.zig");
const api_v9 = @import("api/v9.zig");

test "v8 AIL_mem in-memory stream round-trips" {
    const m = api_v8.AIL_mem_create() orelse return error.NoMem;
    defer api_v8.AIL_mem_close(m, null, null);
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

test "v8 AIL_mem_open read-only view" {
    var data = "abcdef".*;
    const m = api_v8.AIL_mem_open(&data, 6) orelse return error.NoMem;
    defer api_v8.AIL_mem_close(m, null, null);
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

test "v9 64-bit counters and time conversions" {
    const t0 = api_v9.AIL_ms_count64();
    const us0 = api_v9.AIL_us_count64();
    try testing.expect(api_v9.AIL_ms_count64() >= t0);
    try testing.expect(us0 >= t0); // us >= ms in absolute count
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
test "v9 update_sample_3D_position dead-reckons by velocity" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);
    api_v7.AIL_set_sample_3D_position(s, 0, 0, 0);
    api_v7.AIL_set_sample_3D_velocity(s, 10, 0, 0, 0); // 10 units/sec on +x
    api_v7.AIL_update_sample_3D_position(s, 1000); // advance 1 second
    const p = openmiles.ma.ma_sound_get_position(&s.sound);
    try testing.expect(p.x > 9.0 and p.x < 11.0); // ~10
    // NaN dt is ignored (no crash, position unchanged).
    api_v7.AIL_update_sample_3D_position(s, std.math.nan(f32));
    const p2 = openmiles.ma.ma_sound_get_position(&s.sound);
    try testing.expect(p2.x > 9.0 and p2.x < 11.0);
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

test "v9 set_sample_3D_volume_falloff maps graph range to distance attenuation" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);
    api_v7.AIL_set_sample_3D_position(s, 0, 0, 0);
    // Graph: near=2.0, far=50.0 (X = distance).
    var graph = [_]api_v9.MSSGraphPoint{
        .{ .x = 2.0, .y = 1.0, .itx = 0, .ity = 0, .otx = 0, .oty = 0, .itype = 0, .otype = 0 },
        .{ .x = 50.0, .y = 0.0, .itx = 0, .ity = 0, .otx = 0, .oty = 0, .itype = 0, .otype = 0 },
    };
    api_v9.AIL_set_sample_3D_volume_falloff(s, &graph, 2);
    try testing.expect(@abs(openmiles.ma.ma_sound_get_min_distance(&s.sound) - 2.0) < 0.01);
    try testing.expect(@abs(openmiles.ma.ma_sound_get_max_distance(&s.sound) - 50.0) < 0.01);
}

test "v9 bus mixer allocates, routes samples, and frees" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);
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
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [128]u8 align(2) = [_]u8{0} ** 128;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16); // mono
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);
    var mask: u32 = 0;
    try testing.expectEqual(@as(i32, 1), api_v8b.AIL_sample_channel_count(s, &mask)); // mono
    try testing.expectEqual(@as(u32, 0x4), mask); // FC
    // No loop set yet.
    var ls: i32 = -1;
    var le: i32 = -1;
    try testing.expectEqual(@as(i32, 0), api_v8b.AIL_sample_loop_block(s, &ls, &le));
}

test "v8 5.1 volume levels round-trip" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    api_v8b.AIL_set_sample_51_volume_levels(s, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6);
    var fl: f32 = 0;
    var fr: f32 = 0;
    var fc: f32 = 0;
    var lfe: f32 = 0;
    var bl: f32 = 0;
    var br: f32 = 0;
    api_v8b.AIL_sample_51_volume_levels(s, &fl, &fr, &fc, &lfe, &bl, &br);
    try testing.expect(@abs(fc - 0.3) < 0.001 and @abs(lfe - 0.4) < 0.001 and @abs(br - 0.6) < 0.001);
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
    try h.u32le(4 + 24);
    try h.u32le(1); // count
    try h.u32le(1); // id
    try h.u32le(100); // position
    try h.s("data");
    try h.u32le(0);
    try h.u32le(0);
    try h.u32le(100); // sampleOffset
    try h.s("LIST");
    try h.u32le(4 + 8 + 4 + 6);
    try h.s("adtl");
    try h.s("labl");
    try h.u32le(4 + 6);
    try h.u32le(1); // cue id
    try h.s("start\x00");
    std.mem.writeInt(u32, buf.items[riff_size_pos..][0..4], @intCast(buf.items.len - 8), .little);

    const img: *const anyopaque = @ptrCast(buf.items.ptr);
    try testing.expectEqual(@as(i32, 1), api_v8b.AIL_WAV_marker_count(img));
    var name: ?[*:0]const u8 = null;
    try testing.expectEqual(@as(i32, 100), api_v8b.AIL_WAV_marker_by_index(img, 0, &name));
    try testing.expect(name != null);
    try testing.expectEqualStrings("start", std.mem.span(name.?));
    try testing.expectEqual(@as(i32, 100), api_v8b.AIL_WAV_marker_by_name(img, "start"));
    try testing.expectEqual(@as(i32, -1), api_v8b.AIL_WAV_marker_by_name(img, "nope"));
}

test "v9 bus limiter: soft-clip math + attach/detach lifecycle" {
    // Soft-clip: below the knee passes through; peaks saturate below unity.
    try testing.expect(@abs(openmiles.LimiterNode.softClip(0.5) - 0.5) < 0.0001);
    const hi = openmiles.LimiterNode.softClip(2.0);
    try testing.expect(hi > 0.7 and hi < 1.0);
    try testing.expect(@abs(openmiles.LimiterNode.softClip(-2.0) + hi) < 0.0001); // odd symmetry

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

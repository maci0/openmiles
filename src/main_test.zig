const std = @import("std");
const testing = std.testing;
const openmiles = @import("root.zig");

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
    std.Thread.sleep(50 * std.time.ns_per_ms);
    const t2 = openmiles.getMsCount();
    try testing.expect(t2 > t1);
}

test "getUsCount returns monotonically increasing values" {
    const t1 = openmiles.getUsCount();
    std.Thread.sleep(50 * std.time.ns_per_ms);
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
    std.Thread.sleep(50 * std.time.ns_per_ms);
    const pos = rb.getPosition();
    try testing.expect(pos > 0);
}

test "Redbook paused position is stable" {
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator, 0);
    defer rb.deinit();

    rb.play(1, 5);
    std.Thread.sleep(50 * std.time.ns_per_ms);
    rb.pause();
    const p1 = rb.getPosition();
    std.Thread.sleep(50 * std.time.ns_per_ms);
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

    std.Thread.sleep(50 * std.time.ns_per_ms);
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

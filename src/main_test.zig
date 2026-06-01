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
    seq.was_stopped = false;
    try testing.expectEqual(openmiles.MidiStatus.done, seq.status());
    seq.was_stopped = true;
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
    try testing.expect(mid_gain > 0.30 and mid_gain < 0.33); // MSS curve ^(10/6)
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
    try testing.expect(sample.volume > 0.30 and sample.volume < 0.33); // MSS curve ^(10/6)
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

    try testing.expectEqual(openmiles.SampleStatus.done, sample.status()); // SMP_DONE default

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
    try testing.expectEqual(openmiles.SampleStatus.done, sample.status()); // loaded, never played -> SMP_DONE
}

var sob_cb_fired: bool = false;
fn testSobCallback(s: ?*anyopaque) callconv(.winapi) void {
    _ = s;
    sob_cb_fired = true;
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
    const pcm = [_]u8{0} ** 4410;
    const wav = try openmiles.buildWavFromPcm(allocator, &pcm, 1, 44100, 8);
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

test "paused 2D sample reports SMP_PLAYING, paused 3D reports SMP_STOPPED" {
    // MSS quirk: a paused 2D sample keeps reporting SMP_PLAYING (4), but a
    // paused 3D sample reports SMP_STOPPED (8). Games poll these to decide
    // whether to restart a voice, so the divergence must be preserved exactly.
    const allocator = testing.allocator;
    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();
    const pcm = [_]u8{0} ** 4410;
    const wav = try openmiles.buildWavFromPcm(allocator, &pcm, 1, 44100, 8);
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
    const pcm = [_]u8{0} ** 4410;
    const wav = try openmiles.buildWavFromPcm(allocator, &pcm, 1, 44100, 8);
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

test "AIL_startup returns an incrementing use count (SDK refcount)" {
    const api_digital = @import("api/digital.zig");
    // Order-independent: each call bumps the use count by 1 and returns the new
    // value. (openmiles.startup() itself is idempotent, so this is safe to repeat.)
    const c1 = api_digital.AIL_startup();
    const c2 = api_digital.AIL_startup();
    try testing.expect(c1 >= 1);
    try testing.expectEqual(c1 + 1, c2);
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
    // Default stereo: ±45° in the left-handed frame -> x=∓1/√2, z=1/√2.
    const r: f32 = 0.707106781;
    try testing.expect(@abs(pos[0].x + r) < 0.0001 and @abs(pos[0].z - r) < 0.0001);
    try testing.expect(@abs(pos[1].x - r) < 0.0001 and @abs(pos[1].z - r) < 0.0001);
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

test "AIL_file_type classifies WAV/MIDI/XMIDI/OGG/VOC/BINKA/DLS/MLS (SDK)" {
    // Complete PCM WAV — AIL_WAV_info (and thus file_type) needs a data chunk.
    const pcm = [_]u8{0} ** 32;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    try testing.expectEqual(@as(i32, 1), api_file.AIL_file_type(wav.ptr, @intCast(wav.len))); // PCM_WAV

    // IMA ADPCM WAV (tag 0x11, bits 4, block_align 512) -> ADPCM_WAV(2).
    var adpcm = [_]u8{
        'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'A', 'V', 'E',
        'f', 'm', 't', ' ', 16, 0, 0, 0,
        0x11, 0, 1, 0, 0x40, 0x1f, 0, 0, 0, 0, 0, 0, 0, 2, 4, 0,
        'd', 'a', 't', 'a', 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
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
    try testing.expect(dg.AIL_WAV_info(@constCast(@ptrCast(adpcm_wav.ptr)), &mid) != 0);
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

    // SDK validation guards: non-IMA format and zero samples both return 0.
    mid.format = 1;
    try testing.expectEqual(@as(i32, 0), dg.AIL_decompress_ADPCM(&mid, &out_ptr, &out_size));
    mid.format = 0x11;
    mid.samples = 0;
    try testing.expectEqual(@as(i32, 0), dg.AIL_decompress_ADPCM(&mid, &out_ptr, &out_size));
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

test "AIL_redbook_status returns REDBOOK_* codes (STOPPED=3, ERROR=0)" {
    // SDK: REDBOOK_ERROR=0, REDBOOK_PLAYING=1, REDBOOK_PAUSED=2, REDBOOK_STOPPED=3.
    try testing.expectEqual(@as(u32, 1), @intFromEnum(openmiles.RedbookStatus.playing));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(openmiles.RedbookStatus.paused));
    try testing.expectEqual(@as(u32, 3), @intFromEnum(openmiles.RedbookStatus.stopped));
    const allocator = testing.allocator;
    const rb = try openmiles.Redbook.init(allocator, 0);
    defer rb.deinit();
    try testing.expectEqual(@as(u32, 3), api_redbook.AIL_redbook_status(rb)); // STOPPED, not 0
    try testing.expectEqual(@as(u32, 0), api_redbook.AIL_redbook_status(null)); // ERROR (null handle)
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
    // samples = (data_len*8)/bits = total interleaved samples (64B -> 32).
    try testing.expectEqual(@as(u32, 32), info.samples);
    try testing.expect(info.data_ptr != null);
    try testing.expect(info.initial_ptr != null); // SDK: always data_ptr, not null
    if (@hasField(openmiles.AILSOUNDINFO, "channel_mask")) {
        try testing.expectEqual(~@as(u32, 0), info.channel_mask);
    }

    // IMA ADPCM (wFormatTag=0x11) stereo -> format is the WAVE tag 0x11 (17).
    var adpcm = [_]u8{
        'R', 'I', 'F', 'F', 44, 0, 0, 0, 'W', 'A', 'V', 'E',
        'f', 'm', 't', ' ', 16, 0, 0, 0,
        0x11, 0, 2, 0, 0x44, 0xAC, 0, 0, 0, 0, 0, 0, 0, 0, 4, 0,
        'd', 'a', 't', 'a', 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    };
    var info2: openmiles.AILSOUNDINFO = .{};
    try testing.expect(dg.AIL_WAV_info(&adpcm, &info2) != 0);
    try testing.expectEqual(@as(i32, 0x11), info2.format); // WAVE_FORMAT_IMA_ADPCM
}

test "AIL_WAV_file_write interprets the DIG_F format code (not a bit depth)" {
    const data = [_]u8{0} ** 64;
    const path = "/tmp/om_wavfmt_test.wav";
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
    try testing.expectEqual(@as(i32, 1), dg.AIL_WAV_file_write(path, @constCast(@ptrCast(&data)), data.len, 22050, 3));
    const b = try H.readWav(path, &rb);
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, b[22..][0..2], .little)); // channels
    try testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, b[34..][0..2], .little)); // bits
    // DIG_F format 0 -> 8-bit mono.
    try testing.expectEqual(@as(i32, 1), dg.AIL_WAV_file_write(path, @constCast(@ptrCast(&data)), data.len, 22050, 0));
    const b2 = try H.readWav(path, &rb);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, b2[22..][0..2], .little));
    try testing.expectEqual(@as(u16, 8), std.mem.readInt(u16, b2[34..][0..2], .little));

    // DIG_F_MULTICHANNEL_MASK (16) packs the channel count in the high 16 bits.
    // MSS 8.0+ writes that count; pre-8.0 has no multichannel path (bit 16 was
    // DIG_F_USING_ASI there) so it falls back to the stereo bit -> here, mono.
    const mc_format: i32 = (6 << 16) | 16 | 1; // 6ch, multichannel, 16-bit
    try testing.expectEqual(@as(i32, 1), dg.AIL_WAV_file_write(path, @constCast(@ptrCast(&data)), data.len, 22050, mc_format));
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
    try testing.expectEqual(@as(u32, 8), info.samples); // 16 bytes * 8 / 16 bits
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
    const h0 = api_digital.AIL_load_sample_buffer(s, -1, p, 64);
    const h1 = api_digital.AIL_load_sample_buffer(s, -1, p, 64);
    try testing.expect(h0 >= 0 and h1 >= 0 and h0 != h1);
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
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm = [_]u8{0} ** 16000; // mono16 -> 8000 frames
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);
    // Whole sample loaded, cursor at 0 -> 8000 frames * 2 bytes = 16000.
    try testing.expectEqual(@as(i32, 16000), api_v9.AIL_sample_loaded_len(s));
    // Seek to the middle (byte 8000 -> frame 4000) -> 4000 frames remaining = 8000 bytes.
    dg.AIL_set_sample_position(s, 8000);
    try testing.expectEqual(@as(i32, 8000), api_v9.AIL_sample_loaded_len(s));
    // Null -> 0.
    try testing.expectEqual(@as(i32, 0), api_v9.AIL_sample_loaded_len(null));
}

test "AIL_sample_ms_lookup converts ms to a byte position (SDK)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm = [_]u8{0} ** 8000;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16); // 8000 Hz mono16, bpf=2
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);
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
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm = [_]u8{0} ** 32000; // 16000 mono-16 frames
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16); // native 8000
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);

    // Play at 2x native (16000 Hz). 500 ms of output -> 8000 source frames.
    dg.AIL_set_sample_playback_rate(s, 16000);
    s.setMsPosition(500);
    const p = s.getMsPosition();
    try testing.expect(@abs(p.current - 500) <= 2); // round-trips at the effective rate
    var cursor: u64 = 0;
    _ = openmiles.ma.ma_sound_get_cursor_in_pcm_frames(&s.sound, &cursor);
    try testing.expect(cursor >= 7990 and cursor <= 8010); // ~8000 source frames
}

test "AIL_set_sample_position rounds to the granularity boundary (SDK)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [4096]u8 align(2) = [_]u8{0} ** 4096;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 2, 44100, 16); // stereo16, bpf=4
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);
    // 102 rounds to the nearest 4-byte boundary -> 104 (frame 26), not 100.
    dg.AIL_set_sample_position(s, 102);
    try testing.expectEqual(@as(u32, 104), dg.AIL_sample_position(s));
    // An aligned offset is unchanged.
    dg.AIL_set_sample_position(s, 200);
    try testing.expectEqual(@as(u32, 200), dg.AIL_sample_position(s));
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
    // Pref is the 3.x..8.x numbering; 9.x renumbered the table (covered by the
    // version-aware test above), so this old-layout sweep only applies pre-9.0.
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
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);

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
}

test "loop_block setter: -2 keeps current offset, start>end swaps (SDK)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [4096]u8 align(2) = [_]u8{0} ** 4096;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16); // mono 16-bit, bpf=2
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);

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
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);
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
const dg = @import("api/digital.zig");
const api_file = @import("api/file.zig");
const api_quick = @import("api/quick.zig");
const api_redbook = @import("api/redbook.zig");

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
    try testing.expectEqual(@as(i32, 1), api_midi.AIL_MIDI_to_XMI(@constCast(@ptrCast(&smf)), smf.len, null, &size, 0));
    try testing.expectEqual(@as(u32, smf.len), size);
    // Conversion: the function allocates a buffer and returns its pointer; the
    // caller's pointer variable is NOT overwritten with the data (no overflow).
    var out_ptr: ?*anyopaque = null;
    size = 0;
    try testing.expectEqual(@as(i32, 1), api_midi.AIL_MIDI_to_XMI(@constCast(@ptrCast(&smf)), smf.len, &out_ptr, &size, 0));
    try testing.expect(out_ptr != null);
    try testing.expectEqual(@as(u32, smf.len), size);
    const got: [*]const u8 = @ptrCast(out_ptr.?);
    try testing.expectEqualSlices(u8, &smf, got[0..smf.len]);
    std.c.free(out_ptr);
    // Empty input -> 0, output pointer set null.
    out_ptr = @ptrFromInt(0x1234);
    try testing.expectEqual(@as(i32, 0), api_midi.AIL_MIDI_to_XMI(@constCast(@ptrCast(&smf)), 0, &out_ptr, &size, 0));
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
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);
    api_v7.AIL_set_sample_3D_position(s, 0, 0, 0);
    api_v7.AIL_set_sample_3D_velocity(s, 10, 0, 0, 1); // 10 units/sec on +x (magnitude 1)
    api_v7.AIL_update_sample_3D_position(s, 1000); // advance 1 second
    const p = openmiles.ma.ma_sound_get_position(&s.sound);
    try testing.expect(p.x > 9.0 and p.x < 11.0); // ~10
    // NaN dt is ignored (no crash, position unchanged).
    api_v7.AIL_update_sample_3D_position(s, std.math.nan(f32));
    const p2 = openmiles.ma.ma_sound_get_position(&s.sound);
    try testing.expect(p2.x > 9.0 and p2.x < 11.0);
}

test "v7 set_sample_3D_velocity scales the direction by magnitude" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);
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
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);

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

test "v7/v8 is_3D: position enables it, getter & set_sample_is_3D return it (SDK)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);
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
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);
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
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);

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
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);

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
    // Clamped to [0,1].
    api_3d.AIL_set_3D_sample_exclusion(s, 5.0);
    try testing.expect(@abs(api_3d.AIL_3D_sample_exclusion(s) - 1.0) < 0.001);
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

test "occlusion drives the low-pass cutoff (m3d.cpp model), obstruction does not" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);

    // A null handle returns 1.0 (fully open), never 0 (SDK wavefile.cpp).
    try testing.expectEqual(@as(f32, 1.0), api_v7.AIL_sample_low_pass_cut_off(null, 0));
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

test "v7 set_sample_3D_distances orders the min/max pair (SDK swap)" {
    const drv = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer drv.deinit();
    const pcm: [64]u8 align(2) = [_]u8{0} ** 64;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);
    const s = try openmiles.Sample.init(drv);
    defer s.deinit();
    try s.loadFromMemory(wav, false);
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
    try testing.expectEqual(@as(i32, 1), api_v7b.AIL_inspect_MP3(&es, &img, img.len));
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

const api_dls_t = @import("api/dls.zig");
const api_timer_t = @import("api/timer.zig");

test "DLS unload C-ABI variants free a loaded soundfont" {
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
    // Shutdown must free every system and its variable list; if it leaks, the
    // test allocator flags it at test teardown.
    api_miles_t.MilesShutdownEventSystem();
}

fn cstr(s: [*:0]const u8) ?*anyopaque {
    return @constCast(@ptrCast(s));
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

    // Purge two.
    const ev3 = api_v8b.AIL_create_event() orelse return error.NoEvent;
    _ = api_v8b.AIL_add_uncache_sounds_event_step(ev3, cstr("lib"), cstr("a:cee"));
    const e3 = api_v8b.AIL_close_event(ev3) orelse return error.NoStr;
    _ = api_miles_t.MilesEnqueueEvent(@ptrCast(e3), null, 0, 0x2, 0);
    api_miles_t.MilesGetEventSystemState(null, &state);
    try testing.expectEqual(base + 1, state.LoadedSoundCount);

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

test "AIL_redbook_set_volume_level returns the previous volume (F32)" {
    const rb = try openmiles.Redbook.init(testing.allocator, 0);
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
    api_file.AIL_set_file_callbacks(@constCast(@ptrCast(&vfsOpen)), @constCast(@ptrCast(&vfsClose)), @constCast(@ptrCast(&vfsSeek)), @constCast(@ptrCast(&vfsRead)));
    defer api_file.AIL_set_file_callbacks(null, null, null, null);

    // AIL_file_size returns open()'s length value.
    try testing.expectEqual(@as(u32, @intCast(vfs_data.len)), api_file.AIL_file_size("any"));

    // AIL_file_read pulls the whole file through open->read->close.
    var dst: [64]u8 = undefined;
    const r = api_file.AIL_file_read("any", &dst);
    try testing.expect(r != null);
    try testing.expectEqualStrings("Hello VFS payload!", dst[0..vfs_data.len]);
}

//! Fuzz / robustness suite.
//!
//! Each test drives an API or parser with thousands of pseudo-random and
//! adversarial inputs (truncated headers, lying length fields, huge/zero sizes)
//! using a fixed-seed PRNG so failures reproduce. The safe-mode build turns any
//! out-of-bounds access, integer overflow, or unreachable into a panic, so a
//! green run means every fuzzed surface handled the garbage without UB.
//!
//! Pure parsers (slice-bounded) and the streaming source are fuzzed directly;
//! the C-ABI sample/sequence entry points are fuzzed against a device-less
//! engine (miniaudio initializes with "No Device").

const std = @import("std");
const testing = std.testing;
const openmiles = @import("openmiles");
// C-ABI export modules — reachable now that the test build shares the openmiles
// module with the api wrappers (see test_root.zig).
const api_digital = @import("api/digital.zig");
const api_redbook = @import("api/redbook.zig");
const api_quick = @import("api/quick.zig");
const api_dls = @import("api/dls.zig");
const api_midi = @import("api/midi.zig");
const api_3d = @import("api/3d.zig");
const api_timer = @import("api/timer.zig");

fn freeLock(p: ?*anyopaque) void {
    if (p) |ptr| api_digital.AIL_mem_free_lock(ptr);
}

fn dummyTimerCb(_: u32) callconv(.winapi) void {}

const ITERS = 3000;

/// Fill `buf` with `len` random bytes and return the slice.
fn randBytes(rand: std.Random, buf: []u8, len: usize) []u8 {
    const n = @min(len, buf.len);
    rand.bytes(buf[0..n]);
    return buf[0..n];
}

// --- Pure container/parsers -------------------------------------------------

test "fuzz dls_container.findDls/findXmi/xmiImageSize" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE01);
    const rand = prng.random();
    var buf: [8192]u8 = undefined;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        const data = randBytes(rand, &buf, len);
        // Occasionally plant a real signature to exercise the parse branches.
        if (data.len >= 12 and rand.boolean()) {
            const sig = if (rand.boolean()) "RIFF" else "FORM";
            @memcpy(data[0..4], sig);
        }
        _ = openmiles.dls_container.findDls(data);
        _ = openmiles.dls_container.findXmi(data);
        _ = openmiles.dls_container.xmiImageSize(data);
    }
}

test "fuzz xmidiToSmf with random and truncated data" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE02);
    const rand = prng.random();
    var buf: [4096]u8 = undefined;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        const data = randBytes(rand, &buf, len);
        if (data.len >= 12 and rand.boolean()) {
            @memcpy(data[0..4], "FORM");
            if (rand.boolean()) @memcpy(data[8..12], "XDIR") else @memcpy(data[8..12], "XMID");
        }
        const seq = rand.intRangeAtMost(usize, 0, 4);
        // May succeed or error; on success the result must be freed (no leak).
        if (openmiles.xmidiToSmf(testing.allocator, data, seq)) |smf| {
            testing.allocator.free(smf);
        } else |_| {}
    }
}

test "fuzz WAV PCM/ADPCM encoders with random params" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE03);
    const rand = prng.random();
    var pcm: [2048]u8 = undefined;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        const len = rand.intRangeAtMost(usize, 0, pcm.len);
        _ = randBytes(rand, &pcm, len);
        // Adversarial channels/rate (incl. values that overflow naive size math).
        const channels = if (rand.boolean()) rand.intRangeAtMost(u16, 0, 8) else rand.int(u16);
        const rate = if (rand.boolean()) rand.intRangeAtMost(u32, 0, 192000) else rand.int(u32);
        const bits: u16 = if (rand.boolean()) 8 else 16;
        if (openmiles.buildWavFromPcm(testing.allocator, pcm[0..len], channels, rate, bits)) |w| {
            testing.allocator.free(w);
        } else |_| {}

        // ADPCM: pcm reinterpreted as i16 samples; bound total_per_ch to the buffer.
        const ch_a = if (rand.boolean()) rand.intRangeAtMost(u16, 0, 4) else rand.int(u16);
        const samples_i16 = len / 2;
        const max_per_ch = if (ch_a == 0) 0 else samples_i16 / ch_a;
        const total_per_ch = if (max_per_ch == 0) 0 else rand.intRangeAtMost(usize, 0, max_per_ch);
        const pcm16: [*]const i16 = @ptrCast(@alignCast(&pcm));
        if (openmiles.buildAdpcmWav(testing.allocator, pcm16, total_per_ch, ch_a, rate)) |w| {
            testing.allocator.free(w);
        } else |_| {}
    }
}

test "fuzz AIL_compress/decompress_ADPCM with adversarial AILSOUNDINFO" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE14);
    const rand = prng.random();
    var buf: [2048]u8 = undefined;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        const len = rand.intRangeAtMost(u32, 0, buf.len);
        _ = randBytes(rand, &buf, len);
        // data_len matches the real buffer (the API trusts the ptr/len pair);
        // format/rate/bits/channels are adversarial.
        var info = openmiles.AILSOUNDINFO{
            .format = rand.int(i32),
            .data_ptr = &buf,
            .data_len = len,
            .rate = if (rand.boolean()) rand.intRangeAtMost(u32, 0, 192000) else rand.int(u32),
            .bits = if (rand.boolean()) 16 else rand.int(i32),
            .channels = if (rand.boolean()) rand.intRangeAtMost(i32, 1, 2) else rand.int(i32),
            .samples = rand.int(u32),
            .block_size = rand.int(u32),
            .initial_ptr = null,
        };
        var out: *anyopaque = undefined;
        var osz: u32 = 0;
        if (api_digital.AIL_compress_ADPCM(&info, &out, &osz) != 0) freeLock(out);
        osz = 0;
        // decompress: feed a (sometimes RIFF-headed) buffer back through.
        if (len >= 16 and rand.boolean()) @memcpy(buf[0..4], "RIFF");
        info.data_ptr = &buf;
        info.data_len = len;
        if (api_digital.AIL_decompress_ADPCM(&info, &out, &osz) != 0) freeLock(out);
    }
}

test "lying chunk sizes do not overflow the cursor" {
    // FORM with a 0xFFFFFFFF body size (would overflow `8 + size` on 32-bit).
    var form = [_]u8{ 'F', 'O', 'R', 'M', 0xFF, 0xFF, 0xFF, 0xFF } ++ [_]u8{ 'X', 'D', 'I', 'R' } ++ [_]u8{0} ** 16;
    const fsz = openmiles.dls_container.xmiImageSize(&form);
    try testing.expect(fsz <= form.len);

    // MThd claiming a huge header length and track count.
    var mthd = [_]u8{ 'M', 'T', 'h', 'd', 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01, 0xFF, 0xFF, 0x01, 0xE0 } ++ [_]u8{0} ** 16;
    const msz = openmiles.dls_container.xmiImageSize(&mthd);
    try testing.expect(msz <= mthd.len);

    // xmidiToSmf must reject (not hang/crash) a FORM/XDIR with a lying size.
    if (openmiles.xmidiToSmf(testing.allocator, &form, 0)) |smf| {
        testing.allocator.free(smf);
    } else |_| {}
}

// --- Double-buffer streaming source ----------------------------------------

test "fuzz StreamSource random feeds and reads" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE04);
    const rand = prng.random();
    var src_buf: [4096]u8 = undefined;
    rand.bytes(&src_buf);
    var out: [2048]u8 = undefined;

    var trial: usize = 0;
    while (trial < 200) : (trial += 1) {
        const bits: u16 = if (rand.boolean()) 8 else 16;
        const channels = rand.intRangeAtMost(u16, 1, 2);
        var ss: openmiles.StreamSource = undefined;
        try ss.init(bits, channels, rand.intRangeAtMost(u32, 1, 96000), null, null);
        defer ss.deinit();

        var step: usize = 0;
        while (step < 30) : (step += 1) {
            switch (rand.intRangeAtMost(u8, 0, 3)) {
                0 => {
                    const idx = rand.intRangeAtMost(usize, 0, 3); // includes out-of-range >1
                    const off = rand.intRangeAtMost(usize, 0, src_buf.len);
                    const blen = rand.intRangeAtMost(usize, 0, src_buf.len - off);
                    ss.loadBuffer(idx, src_buf[off..].ptr, blen);
                },
                1 => {
                    const want = rand.intRangeAtMost(u64, 0, out.len / 4);
                    var read: u64 = 0;
                    _ = openmiles.ma.ma_data_source_read_pcm_frames(&ss.base, &out, want, &read);
                },
                2 => _ = ss.bufferReady(),
                3 => {
                    var a: u32 = 0;
                    var b: u32 = 0;
                    var c: u32 = 0;
                    var d: u32 = 0;
                    ss.bufferInfo(&a, &b, &c, &d);
                },
                else => unreachable,
            }
        }
    }
}

// --- C-ABI sample/sequence entry points (device-less engine) ---------------

test "fuzz AIL sample buffer/address APIs with garbage" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE05);
    const rand = prng.random();
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();

    var buf: [2048]u8 = undefined;
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const s = openmiles.Sample.init(driver) catch continue;
        defer s.deinit();
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        _ = randBytes(rand, &buf, len);

        // Random raw PCM format then feed buffers (exercises StreamSource path).
        s.setType(rand.intRangeAtMost(u32, 0, 3), 0);
        const nbuf = rand.intRangeAtMost(usize, 0, 3);
        var k: usize = 0;
        while (k < nbuf) : (k += 1) {
            s.loadStreamBuffer(rand.intRangeAtMost(usize, 0, 1), &buf, @intCast(len)) catch {};
        }
        // Also exercise the whole-image decode path with garbage.
        if (len > 0) s.setAddress(&buf, @intCast(len)) catch {};
        _ = s.status();
    }
}

const adv_i32 = [_]i32{ std.math.minInt(i32), -1_000_000, -1, 0, 1, 127, 44100, 1_000_000, std.math.maxInt(i32) };
const adv_f32 = [_]f32{ std.math.nan(f32), std.math.inf(f32), -std.math.inf(f32), -1.0e30, -1.0, 0.0, 1.0e-30, 1.0, 1.0e30 };

test "fuzz Sample scalar setters with adversarial values" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE07);
    const rand = prng.random();
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();

    // A small valid 16-bit mono WAV so the sample is fully initialized.
    const pcm = [_]u8{0} ** 256;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);

    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        const s = openmiles.Sample.init(driver) catch continue;
        defer s.deinit();
        s.loadFromMemory(wav, false) catch continue;

        const iv = adv_i32[rand.intRangeLessThan(usize, 0, adv_i32.len)];
        const f1 = adv_f32[rand.intRangeLessThan(usize, 0, adv_f32.len)];
        const f2 = adv_f32[rand.intRangeLessThan(usize, 0, adv_f32.len)];
        const f3 = adv_f32[rand.intRangeLessThan(usize, 0, adv_f32.len)];
        switch (rand.intRangeAtMost(u8, 0, 7)) {
            0 => s.setVolume(iv),
            1 => s.setPan(iv),
            2 => s.setPlaybackRate(iv),
            3 => s.setLoopCount(iv),
            4 => s.setMsPosition(iv),
            5 => s.setPosition(@bitCast(iv)),
            6 => s.setLoopBlock(iv, adv_i32[rand.intRangeLessThan(usize, 0, adv_i32.len)]),
            7 => s.setReverb(f1, f2, f3),
            else => unreachable,
        }
    }
}

test "fuzz Sample3D spatial setters with adversarial floats" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE08);
    const rand = prng.random();
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();

    var i: usize = 0;
    while (i < 1500) : (i += 1) {
        const s = openmiles.Sample3D.init(driver) catch continue;
        defer s.deinit();
        const f1 = adv_f32[rand.intRangeLessThan(usize, 0, adv_f32.len)];
        const f2 = adv_f32[rand.intRangeLessThan(usize, 0, adv_f32.len)];
        const f3 = adv_f32[rand.intRangeLessThan(usize, 0, adv_f32.len)];
        const iv = adv_i32[rand.intRangeLessThan(usize, 0, adv_i32.len)];
        switch (rand.intRangeAtMost(u8, 0, 4)) {
            0 => s.setPosition(f1, f2, f3),
            1 => s.setVolume(iv),
            2 => s.setMsPosition(iv),
            3 => s.setPlaybackRate(iv),
            4 => s.setLoopBlock(iv, iv),
            else => unreachable,
        }
    }
}

test "fuzz Sequence control with adversarial values" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE09);
    const rand = prng.random();
    const mdi = try openmiles.MidiDriver.init(testing.allocator);
    defer mdi.deinit();

    var i: usize = 0;
    while (i < 1500) : (i += 1) {
        const seq = openmiles.Sequence.init(mdi) catch continue;
        defer seq.deinit();
        const iv = adv_i32[rand.intRangeLessThan(usize, 0, adv_i32.len)];
        const iv2 = adv_i32[rand.intRangeLessThan(usize, 0, adv_i32.len)];
        switch (rand.intRangeAtMost(u8, 0, 4)) {
            0 => seq.setVolume(iv, iv2),
            1 => seq.startTempoFade(iv, iv2),
            2 => seq.setLoopCount(iv),
            3 => seq.setMsPosition(iv),
            4 => _ = seq.status(),
            else => unreachable,
        }
    }
}

test "fuzz Filter cutoff/order with adversarial values" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE0A);
    const rand = prng.random();
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();
    const provider = try openmiles.Provider.init(testing.allocator, null);
    defer provider.deinit();
    const filter = openmiles.Filter.init(provider, driver) catch return;
    defer filter.deinit();

    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        const f = adv_f32[rand.intRangeLessThan(usize, 0, adv_f32.len)];
        switch (rand.intRangeAtMost(u8, 0, 3)) {
            0 => filter.setAttribute("Cutoff", f),
            1 => filter.setAttribute("Order", f),
            2 => filter.setCutoff(@floatCast(f)),
            3 => _ = filter.getAttribute(if (rand.boolean()) "Order" else "Cutoff"),
            else => unreachable,
        }
    }
}

test "fuzz Sample3D effect setters with adversarial floats" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE0B);
    const rand = prng.random();
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();

    var i: usize = 0;
    while (i < 1500) : (i += 1) {
        const s = openmiles.Sample3D.init(driver) catch continue;
        defer s.deinit();
        const a = adv_f32[rand.intRangeLessThan(usize, 0, adv_f32.len)];
        const b = adv_f32[rand.intRangeLessThan(usize, 0, adv_f32.len)];
        const c = adv_f32[rand.intRangeLessThan(usize, 0, adv_f32.len)];
        switch (rand.intRangeAtMost(u8, 0, 5)) {
            0 => s.setObstruction(a),
            1 => s.setOcclusion(a),
            2 => s.setMinMaxDistance(a, b),
            3 => s.setVelocity(a, b, c),
            4 => s.setOrientation(a, b, c, a, b, c),
            5 => s.applyCone(),
            else => unreachable,
        }
    }
}

test "fuzz AIL_WAV_info chunk walk (C-ABI export)" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE0C);
    const rand = prng.random();
    var buf: [1024]u8 = undefined;
    var info: openmiles.AILSOUNDINFO = undefined;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        rand.bytes(&buf);
        // Self-consistent RIFF/WAVE shell (the size-less API trusts the declared
        // RIFF size as its bound); chunk bytes stay random to fuzz the walk.
        @memcpy(buf[0..4], "RIFF");
        const body = rand.intRangeAtMost(u32, 0, @as(u32, buf.len - 8));
        std.mem.writeInt(u32, buf[4..8][0..4], body, .little);
        @memcpy(buf[8..12], "WAVE");
        if (rand.boolean()) @memcpy(buf[12..16], "fmt ");
        _ = api_digital.AIL_WAV_info(&buf, &info);
    }
}

test "fuzz AIL_redbook drive/track ops (C-ABI export)" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE0D);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const drive = adv_i32[rand.intRangeLessThan(usize, 0, adv_i32.len)];
        const rb = api_redbook.AIL_redbook_open_drive(drive) orelse continue;
        defer api_redbook.AIL_redbook_close(rb);
        const t1: u32 = @bitCast(adv_i32[rand.intRangeLessThan(usize, 0, adv_i32.len)]);
        const t2: u32 = @bitCast(adv_i32[rand.intRangeLessThan(usize, 0, adv_i32.len)]);
        switch (rand.intRangeAtMost(u8, 0, 4)) {
            0 => _ = api_redbook.AIL_redbook_play(rb, t1, t2),
            1 => _ = api_redbook.AIL_redbook_track_info(rb, t1, null, null),
            2 => api_redbook.AIL_redbook_set_volume(rb, @bitCast(t1)),
            3 => _ = api_redbook.AIL_redbook_status(rb),
            4 => _ = api_redbook.AIL_redbook_position(rb),
            else => unreachable,
        }
    }
}

test "fuzz AIL_quick API with garbage data and adversarial scalars" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE0E);
    const rand = prng.random();
    var buf: [2048]u8 = undefined;
    var i: usize = 0;
    while (i < 600) : (i += 1) {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        _ = randBytes(rand, &buf, len);
        // Occasionally a valid-ish WAV header to reach the load path.
        if (len >= 16 and rand.boolean()) {
            @memcpy(buf[0..4], "RIFF");
            std.mem.writeInt(u32, buf[4..8][0..4], @intCast(if (len >= 8) len - 8 else 0), .little);
            @memcpy(buf[8..12], "WAVE");
        }
        const s = api_quick.AIL_quick_load_mem(&buf, @intCast(len)) orelse continue;
        defer api_quick.AIL_quick_unload(s);
        const iv = adv_i32[rand.intRangeLessThan(usize, 0, adv_i32.len)];
        const f1 = adv_f32[rand.intRangeLessThan(usize, 0, adv_f32.len)];
        switch (rand.intRangeAtMost(u8, 0, 6)) {
            0 => api_quick.AIL_quick_play(s, iv),
            1 => api_quick.AIL_quick_set_volume(s, iv),
            2 => api_quick.AIL_quick_set_speed(s, iv),
            3 => api_quick.AIL_quick_set_ms_position(s, iv),
            4 => api_quick.AIL_quick_set_reverb(s, f1, f1, f1),
            5 => _ = api_quick.AIL_quick_ms_position(s),
            6 => _ = api_quick.AIL_quick_ms_length(s),
            else => unreachable,
        }
    }
}

test "fuzz AIL digital sample seek/position exports with adversarial values" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE0F);
    const rand = prng.random();
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();
    const pcm = [_]u8{0} ** 256;
    const wav = try openmiles.buildWavFromPcm(testing.allocator, &pcm, 1, 8000, 16);
    defer testing.allocator.free(wav);

    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        const s = openmiles.Sample.init(driver) catch continue;
        defer s.deinit();
        s.loadFromMemory(wav, false) catch continue;
        const iv = adv_i32[rand.intRangeLessThan(usize, 0, adv_i32.len)];
        switch (rand.intRangeAtMost(u8, 0, 5)) {
            0 => api_digital.AIL_set_sample_ms_position(s, iv),
            1 => api_digital.AIL_set_sample_position(s, @bitCast(iv)),
            2 => api_digital.AIL_set_sample_playback_rate(s, iv),
            3 => api_digital.AIL_set_sample_volume(s, iv),
            4 => api_digital.AIL_set_sample_pan(s, iv),
            5 => api_digital.AIL_set_sample_loop_count(s, iv),
            else => unreachable,
        }
    }
}

test "fuzz DLS container exports (find/extract/merge/list/filter)" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE10);
    const rand = prng.random();
    var buf: [4096]u8 = undefined;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        const data = randBytes(rand, &buf, len);
        // Plant RIFF/DLS or FORM signatures to reach the real split branches.
        if (data.len >= 12 and rand.boolean()) {
            @memcpy(data[0..4], "RIFF");
            @memcpy(data[8..12], "DLS ");
            std.mem.writeInt(u32, data[4..8][0..4], @intCast(if (len >= 8) len - 8 else 0), .little);
        }

        // find_DLS returns interior pointers (do not free).
        var xo: ?*anyopaque = null;
        var xl: u32 = 0;
        var do_: ?*anyopaque = null;
        var dl: u32 = 0;
        _ = api_dls.AIL_find_DLS(data.ptr, @intCast(len), &xo, &xl, &do_, &dl);

        // extract_DLS allocates copies (free with AIL_mem_free_lock).
        var exo: ?*anyopaque = null;
        var exl: u32 = 0;
        var edo: ?*anyopaque = null;
        var edl: u32 = 0;
        _ = api_dls.AIL_extract_DLS(data.ptr, @intCast(len), &exo, &exl, &edo, &edl, null);
        freeLock(exo);
        freeLock(edo);

        // list_DLS allocates a text buffer.
        var lst: ?*anyopaque = null;
        var lsz: u32 = 0;
        _ = api_dls.AIL_list_DLS(data.ptr, &lst, &lsz, 0, null);
        freeLock(lst);

        // merge/filter: split the buffer into two halves as xmi/dls inputs.
        if (len >= 24) {
            const half = len / 2;
            var mo: ?*anyopaque = null;
            var ml: u32 = 0;
            _ = api_dls.AIL_merge_DLS_with_XMI(data.ptr, data[half..].ptr, &mo, &ml);
            freeLock(mo);
            var fo: ?*anyopaque = null;
            var fl: u32 = 0;
            _ = api_dls.AIL_filter_DLS_with_XMI(data.ptr, data[half..].ptr, &fo, &fl, 0, null);
            freeLock(fo);
        }
    }
}

test "fuzz AIL_MIDI_to_XMI with random data" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE11);
    const rand = prng.random();
    var buf: [2048]u8 = undefined;
    var out: [4096]u8 = undefined;
    var i: usize = 0;
    while (i < ITERS) : (i += 1) {
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        _ = randBytes(rand, &buf, len);
        if (len >= 4 and rand.boolean()) @memcpy(buf[0..4], "MThd");
        var out_len: u32 = out.len;
        _ = api_midi.AIL_MIDI_to_XMI(&buf, @intCast(len), &out, &out_len, 0);
    }
}

test "fuzz AIL_set_3D_sample_info with adversarial AILSOUNDINFO" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE15);
    const rand = prng.random();
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();
    var buf: [1024]u8 = undefined;
    var i: usize = 0;
    while (i < 600) : (i += 1) {
        const s = openmiles.Sample3D.init(driver) catch continue;
        defer s.deinit();
        const len = rand.intRangeAtMost(u32, 1, buf.len);
        _ = randBytes(rand, &buf, len);
        var info = openmiles.AILSOUNDINFO{
            .format = rand.int(i32),
            .data_ptr = &buf,
            .data_len = len,
            .rate = if (rand.boolean()) 44100 else rand.int(u32),
            .bits = rand.int(i32), // adversarial — was @intCast'd to u16 unguarded
            .channels = rand.int(i32), // adversarial
            .samples = rand.int(u32),
            .block_size = rand.int(u32),
            .initial_ptr = null,
        };
        _ = api_3d.AIL_set_3D_sample_info(@ptrCast(s), &info);
    }
}

test "fuzz 3D spatial exports with adversarial floats (C-ABI)" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE12);
    const rand = prng.random();
    const driver = try openmiles.DigitalDriver.init(testing.allocator, 44100, 16, 2);
    defer driver.deinit();

    var i: usize = 0;
    while (i < 1500) : (i += 1) {
        const s = openmiles.Sample3D.init(driver) catch continue;
        defer s.deinit();
        const obj: *anyopaque = @ptrCast(s);
        const a = adv_f32[rand.intRangeLessThan(usize, 0, adv_f32.len)];
        const b = adv_f32[rand.intRangeLessThan(usize, 0, adv_f32.len)];
        const c = adv_f32[rand.intRangeLessThan(usize, 0, adv_f32.len)];
        const iv = adv_i32[rand.intRangeLessThan(usize, 0, adv_i32.len)];
        switch (rand.intRangeAtMost(u8, 0, 4)) {
            0 => api_3d.AIL_set_3D_position(obj, a, b, c),
            1 => api_3d.AIL_set_3D_velocity(obj, a, b, c, a),
            2 => api_3d.AIL_set_3D_orientation(obj, a, b, c, a, b, c),
            3 => api_3d.AIL_set_3D_sample_distances(obj, a, b),
            4 => api_3d.AIL_set_3D_sample_cone(obj, a, b, iv),
            else => unreachable,
        }
    }
}

test "fuzz timer config with adversarial periods" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE13);
    const rand = prng.random();
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const timer = api_timer.AIL_register_timer(dummyTimerCb) orelse continue;
        const t: *openmiles.Timer = @ptrCast(@alignCast(timer));
        defer api_timer.AIL_release_timer_handle(t);
        const v: u32 = @bitCast(adv_i32[rand.intRangeLessThan(usize, 0, adv_i32.len)]);
        // Includes 0 -> exercises any divide-by-zero in frequency->period.
        if (rand.boolean()) api_timer.AIL_set_timer_frequency(t, v) else api_timer.AIL_set_timer_period(t, v);
    }
}

test "fuzz AIL_init_sequence with random MIDI/XMI data" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE06);
    const rand = prng.random();
    const mdi = try openmiles.MidiDriver.init(testing.allocator);
    defer mdi.deinit();

    var buf: [4096]u8 = undefined;
    var i: usize = 0;
    while (i < 500) : (i += 1) {
        const seq = openmiles.Sequence.init(mdi) catch continue;
        defer seq.deinit();
        const len = rand.intRangeAtMost(usize, 0, buf.len);
        _ = randBytes(rand, &buf, len);
        if (rand.boolean() and len >= 4) @memcpy(buf[0..4], "MThd");
        seq.loadMidi(buf[0..len], rand.intRangeAtMost(usize, 0, 3)) catch {};
        _ = seq.status();
    }
}

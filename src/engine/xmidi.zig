const std = @import("std");

// ---------------------------------------------------------------------------
// XMIDI → Standard MIDI (SMF) converter
// ---------------------------------------------------------------------------
// XMIDI is an IFF-based format: FORM/XDIR → CAT /XMID → repeated FORM/XMID
// blocks, each containing an EVNT chunk with MIDI-like events.
// Key difference from SMF: every Note-On is followed by a VLQ "note duration"
// field (ticks until note-off); explicit Note-Off events are rare but possible in the
// EVNT data.  Delta times are VLQ-encoded tick counts (PPQ = 120).
// ---------------------------------------------------------------------------

/// Scan an SMF byte slice for the first time signature meta event (0xFF 0x58)
/// and return the numerator (beats per measure). Returns 4 if not found.
/// Uses a proper SMF event parser to avoid false matches on VLQ continuation bytes.
pub fn parseSmfTimeSigNumerator(smf: []const u8) i32 {
    // MThd = 14 bytes, MTrk tag = 4 bytes, MTrk length = 4 bytes → track data starts at 22
    if (smf.len < 22) return 4;
    const trk_len: usize = std.mem.readInt(u32, smf[18..22][0..4], .big);
    const trk_end = @min(22 + trk_len, smf.len);
    var i: usize = 22;
    while (i < trk_end) {
        // Skip VLQ delta time
        while (i < trk_end and smf[i] & 0x80 != 0) : (i += 1) {}
        if (i >= trk_end) break;
        i += 1; // consume final VLQ byte
        if (i >= trk_end) break;
        const status = smf[i];
        i += 1;
        if (status == 0xFF) {
            // Meta event
            if (i >= trk_end) break;
            const meta_type = smf[i];
            i += 1;
            // Read VLQ meta length
            var meta_len: u32 = 0;
            while (i < trk_end) {
                const b = smf[i];
                i += 1;
                meta_len = (meta_len << 7) | (b & 0x7F);
                if (b & 0x80 == 0) break;
            }
            if (meta_type == 0x58 and meta_len >= 1 and i < trk_end) {
                return @max(1, @as(i32, @intCast(smf[i])));
            }
            if (meta_type == 0x2F) break; // End of Track
            i +|= meta_len;
        } else if (status == 0xF0 or status == 0xF7) {
            // SysEx — VLQ length then data
            var len: u32 = 0;
            while (i < trk_end) {
                const b = smf[i];
                i += 1;
                len = (len << 7) | (b & 0x7F);
                if (b & 0x80 == 0) break;
            }
            i +|= len;
        } else {
            // Channel event: 1 or 2 data bytes depending on message type
            const etype = status & 0xF0;
            const data_bytes: usize = switch (etype) {
                0xC0, 0xD0 => 1,
                else => 2,
            };
            i += data_bytes;
        }
    }
    return 4;
}

fn readBe32(data: []const u8, pos: usize) u32 {
    if (pos + 4 > data.len) return 0;
    return std.mem.readInt(u32, data[pos..][0..4], .big);
}

fn readVlq(data: []const u8, pos: *usize) u32 {
    var result: u32 = 0;
    var bytes_read: u8 = 0;
    while (pos.* < data.len) {
        const b = data[pos.*];
        pos.* += 1;
        result = (result << 7) | (b & 0x7F);
        bytes_read += 1;
        if (b & 0x80 == 0) break;
        if (bytes_read >= 4) break;
    }
    return result;
}

fn writeVlq(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: u32) !void {
    var v = value;
    var buf: [5]u8 = undefined;
    var i: usize = 0;
    buf[i] = @truncate(v & 0x7F);
    v >>= 7;
    i += 1;
    while (v > 0) {
        buf[i] = @truncate((v & 0x7F) | 0x80);
        v >>= 7;
        i += 1;
    }
    var lo: usize = 0;
    var hi: usize = i - 1;
    while (lo < hi) {
        const tmp = buf[lo];
        buf[lo] = buf[hi];
        buf[hi] = tmp;
        lo += 1;
        hi -= 1;
    }
    try list.appendSlice(allocator, buf[0..i]);
}

/// Find the EVNT chunk for the given sequence index inside XMIDI data.
fn findEvntChunk(data: []const u8, seq_num: usize) ![]const u8 {
    if (data.len < 12) return error.TooShort;
    if (!std.mem.eql(u8, data[0..4], "FORM")) return error.NotXmidi;
    const outer_sz: usize = readBe32(data, 4);
    if (data.len < 8 + outer_sz) return error.Truncated;
    if (!std.mem.eql(u8, data[8..12], "XDIR")) return error.NotXdir;

    var pos: usize = 12;
    const outer_end: usize = @min(8 + outer_sz, data.len);

    while (pos + 8 <= outer_end) {
        const cid = data[pos .. pos + 4];
        const csz: usize = readBe32(data, pos + 4);
        const cend: usize = @min(pos + 8 + csz, data.len);

        if (std.mem.eql(u8, cid, "CAT ") and pos + 12 <= cend and
            std.mem.eql(u8, data[pos + 8 .. pos + 12], "XMID"))
        {
            // Walk FORM/XMID children
            var ipos: usize = pos + 12;
            var count: usize = 0;
            while (ipos + 8 <= cend) {
                const iid = data[ipos .. ipos + 4];
                const isz: usize = readBe32(data, ipos + 4);
                const iend: usize = @min(ipos + 8 + isz, cend);

                if (std.mem.eql(u8, iid, "FORM") and ipos + 12 <= iend and
                    std.mem.eql(u8, data[ipos + 8 .. ipos + 12], "XMID"))
                {
                    if (count == seq_num) {
                        // Found target sequence — find its EVNT chunk
                        var epos: usize = ipos + 12;
                        while (epos + 8 <= iend) {
                            const eid = data[epos .. epos + 4];
                            const esz: usize = readBe32(data, epos + 4);
                            if (std.mem.eql(u8, eid, "EVNT")) {
                                const evnt_end: usize = @min(epos + 8 + esz, iend);
                                return data[epos + 8 .. evnt_end];
                            }
                            epos += 8 + esz;
                            if (esz & 1 != 0) epos += 1; // IFF even-byte padding
                        }
                        return error.NoEvntChunk;
                    }
                    count += 1;
                }
                ipos += 8 + isz;
                if (isz & 1 != 0) ipos += 1;
            }
            return error.SequenceNotFound;
        }

        pos += 8 + csz;
        if (csz & 1 != 0) pos += 1;
    }
    return error.NoCatChunk;
}

/// Handle bare FORM/XMID (single sequence without XDIR wrapper).
fn findBareEvnt(data: []const u8) ![]const u8 {
    if (data.len < 12) return error.TooShort;
    if (!std.mem.eql(u8, data[0..4], "FORM")) return error.NotForm;
    const form_sz: usize = readBe32(data, 4);
    const form_end = @min(8 + form_sz, data.len);
    if (!std.mem.eql(u8, data[8..12], "XMID")) return error.NotXmid;
    var pos: usize = 12;
    while (pos + 8 <= form_end) {
        const cid = data[pos .. pos + 4];
        const csz: usize = readBe32(data, pos + 4);
        if (std.mem.eql(u8, cid, "EVNT")) {
            return data[pos + 8 .. @min(pos + 8 + csz, form_end)];
        }
        pos += 8 + csz;
        if (csz & 1 != 0) pos += 1;
    }
    return error.NoEvntChunk;
}

fn evntDataToSmf(allocator: std.mem.Allocator, evnt: []const u8) ![]u8 {
    // Each SMF event: fixed-size (abs_time + up to 8 data bytes)
    const SmfEvent = struct {
        abs_time: u32,
        len: u8,
        data: [8]u8,
    };

    var events: std.ArrayListUnmanaged(SmfEvent) = .{};
    defer events.deinit(allocator);
    // Pre-allocate: each event is ~3 bytes minimum, note-on generates 2 events (on + synthetic off)
    try events.ensureTotalCapacity(allocator, evnt.len / 2);

    var pos: usize = 0;
    var abs_time: u32 = 0;

    while (pos < evnt.len) {
        const delta = readVlq(evnt, &pos);
        abs_time +|= delta;
        if (pos >= evnt.len) break;

        const status = evnt[pos];
        pos += 1;

        if (status == 0xFF) {
            // Meta event
            if (pos >= evnt.len) break;
            const mtype = evnt[pos];
            pos += 1;
            const mlen = readVlq(evnt, &pos);
            if (mtype == 0x51 and mlen == 3 and pos + 3 <= evnt.len) {
                // Tempo — pass through
                var ev: SmfEvent = undefined;
                ev.abs_time = abs_time;
                ev.len = 6;
                ev.data[0] = 0xFF;
                ev.data[1] = 0x51;
                ev.data[2] = 0x03;
                ev.data[3] = evnt[pos];
                ev.data[4] = evnt[pos + 1];
                ev.data[5] = evnt[pos + 2];
                try events.append(allocator, ev);
            } else if (mtype == 0x58 and mlen == 4 and pos + 4 <= evnt.len) {
                // Time signature — pass through
                var ev: SmfEvent = undefined;
                ev.abs_time = abs_time;
                ev.len = 7;
                ev.data[0] = 0xFF;
                ev.data[1] = 0x58;
                ev.data[2] = 0x04;
                ev.data[3] = evnt[pos];
                ev.data[4] = evnt[pos + 1];
                ev.data[5] = evnt[pos + 2];
                ev.data[6] = evnt[pos + 3];
                try events.append(allocator, ev);
            }
            pos +|= mlen;
            if (pos > evnt.len) break;
            continue;
        }

        if (status == 0xF0 or status == 0xF7) {
            const slen = readVlq(evnt, &pos);
            pos +|= slen;
            if (pos > evnt.len) break;
            continue;
        }

        const etype = status & 0xF0;

        switch (etype) {
            0x80 => {
                // Note Off
                if (pos + 1 >= evnt.len) break;
                var ev: SmfEvent = undefined;
                ev.abs_time = abs_time;
                ev.len = 3;
                ev.data[0] = status;
                ev.data[1] = evnt[pos];
                ev.data[2] = evnt[pos + 1];
                pos += 2;
                try events.append(allocator, ev);
            },
            0x90 => {
                // Note On — XMIDI appends a VLQ note-duration after velocity
                if (pos + 1 >= evnt.len) break;
                const note = evnt[pos];
                pos += 1;
                const vel = evnt[pos];
                pos += 1;
                var ev: SmfEvent = undefined;
                ev.abs_time = abs_time;
                ev.len = 3;
                ev.data[0] = status;
                ev.data[1] = note;
                ev.data[2] = vel;
                try events.append(allocator, ev);
                // XMIDI always has a duration VLQ after Note On, even for vel=0
                const dur = readVlq(evnt, &pos);
                if (vel > 0) {
                    // Schedule synthetic note-off
                    var off: SmfEvent = undefined;
                    off.abs_time = abs_time +| dur;
                    off.len = 3;
                    off.data[0] = 0x80 | (status & 0x0F);
                    off.data[1] = note;
                    off.data[2] = 0x40;
                    try events.append(allocator, off);
                }
            },
            0xA0, 0xB0, 0xE0 => {
                // Aftertouch / Control Change / Pitch Bend (2 data bytes)
                if (pos + 1 >= evnt.len) break;
                var ev: SmfEvent = undefined;
                ev.abs_time = abs_time;
                ev.len = 3;
                ev.data[0] = status;
                ev.data[1] = evnt[pos];
                ev.data[2] = evnt[pos + 1];
                pos += 2;
                try events.append(allocator, ev);
            },
            0xC0, 0xD0 => {
                // Program Change / Channel Pressure (1 data byte)
                if (pos >= evnt.len) break;
                var ev: SmfEvent = undefined;
                ev.abs_time = abs_time;
                ev.len = 2;
                ev.data[0] = status;
                ev.data[1] = evnt[pos];
                pos += 1;
                try events.append(allocator, ev);
            },
            0xF0 => {
                // Remaining system messages (0xF1-0xF6, 0xF8-0xFE) not caught above.
                // Status byte is consumed but no data bytes are skipped — if any of
                // these rare messages carry data bytes, parsing would be corrupted.
                // In practice they should not appear in XMIDI EVNT chunks.
            },
            else => break,
        }
    }

    // Sort by absolute time; at same tick: meta events first, then note-offs, then note-ons, etc.
    std.sort.block(SmfEvent, events.items, {}, struct {
        fn lt(_: void, a: SmfEvent, b: SmfEvent) bool {
            if (a.abs_time != b.abs_time) return a.abs_time < b.abs_time;
            const aMeta = a.data[0] == 0xFF;
            const bMeta = b.data[0] == 0xFF;
            if (aMeta != bMeta) return aMeta; // meta events before all channel events
            return (a.data[0] & 0xF0) < (b.data[0] & 0xF0);
        }
    }.lt);

    // Build MTrk data
    var track: std.ArrayListUnmanaged(u8) = .{};
    defer track.deinit(allocator);
    // Pre-allocate: each event contributes ~4-8 bytes (VLQ delta + data), plus header/footer
    track.ensureTotalCapacity(allocator, events.items.len * 6 + 11) catch {};

    // XMIDI uses 120 ticks/second.  With PPQ=120, tempo must be 60 BPM = 1 000 000 µs/beat
    // so that 1 SMF tick = 1 000 000/120 µs = 8 333 µs = 1/120 second.
    try track.appendSlice(allocator, &[_]u8{ 0x00, 0xFF, 0x51, 0x03, 0x0F, 0x42, 0x40 });

    var prev: u32 = 0;
    for (events.items) |ev| {
        const delta: u32 = if (ev.abs_time >= prev) ev.abs_time - prev else 0;
        prev = ev.abs_time;
        try writeVlq(&track, allocator, delta);
        try track.appendSlice(allocator, ev.data[0..ev.len]);
    }
    try track.appendSlice(allocator, &[_]u8{ 0x00, 0xFF, 0x2F, 0x00 }); // End of Track

    // Assemble final SMF — exact size is known: 14 (MThd) + 8 (MTrk header) + track data
    var smf: std.ArrayListUnmanaged(u8) = .{};
    try smf.ensureTotalCapacity(allocator, 22 + track.items.len);

    // MThd
    try smf.appendSlice(allocator, "MThd");
    try smf.appendSlice(allocator, &[_]u8{ 0x00, 0x00, 0x00, 0x06 }); // chunk size = 6
    try smf.appendSlice(allocator, &[_]u8{ 0x00, 0x00 }); // format 0
    try smf.appendSlice(allocator, &[_]u8{ 0x00, 0x01 }); // 1 track
    try smf.appendSlice(allocator, &[_]u8{ 0x00, 0x78 }); // PPQ = 120

    // MTrk
    try smf.appendSlice(allocator, "MTrk");
    const tlen: u32 = @intCast(track.items.len);
    try smf.append(allocator, @truncate(tlen >> 24));
    try smf.append(allocator, @truncate(tlen >> 16));
    try smf.append(allocator, @truncate(tlen >> 8));
    try smf.append(allocator, @truncate(tlen));
    try smf.appendSlice(allocator, track.items);

    return smf.toOwnedSlice(allocator);
}

pub fn xmidiToSmf(allocator: std.mem.Allocator, data: []const u8, seq_num: usize) ![]u8 {
    const evnt = try findEvntChunk(data, seq_num);
    return evntDataToSmf(allocator, evnt);
}

pub fn xmidiBareToSmf(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    const evnt = try findBareEvnt(data);
    return evntDataToSmf(allocator, evnt);
}

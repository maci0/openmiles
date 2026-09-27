//! RIB provider/interface registry tests.
//!
//! The contract under test is that a game replaying a recorded run sees the
//! same interfaces and the same entries in the same order every time, so
//! enumeration walks the provider's registration order rather than whatever
//! order a hash map happens to store its keys in.

const std = @import("std");
const testing = std.testing;
const openmiles = @import("openmiles");
const rib = @import("api/rib.zig");

const Entry = openmiles.RIB_INTERFACE_ENTRY;

fn entry(comptime name: [:0]const u8, token: usize) Entry {
    return .{ .entry_type = .RIB_ATTRIBUTE, .name = name.ptr, .token = token, .subtype = 0 };
}

/// Registers `entries` under `iface_name` on a fresh provider and returns it.
fn providerWith(iface_name: [:0]const u8, entries: []const Entry) !*openmiles.Provider {
    const p = try openmiles.Provider.init(testing.allocator);
    errdefer p.deinit();
    _ = try p.registerInterface(iface_name, @intCast(entries.len), @ptrCast(@constCast(entries.ptr)));
    return p;
}

test "RIB_enumerate_interface yields entries in registration order" {
    const registered = [_]Entry{
        entry("zeta mixer", 0x10),
        entry("alpha codec", 0x20),
        entry("mid volume", 0x30),
        entry("beta rate", 0x40),
        entry("omega tempo", 0x50),
    };
    const p = try providerWith("ASI digital audio engine", &registered);
    defer p.deinit();

    var cursor: ?*anyopaque = null;
    var got: [registered.len]Entry = undefined;
    var n: usize = 0;
    while (n < got.len) {
        var out: Entry = undefined;
        try testing.expectEqual(1, rib.RIB_enumerate_interface(p, "ASI digital audio engine", 1, &cursor, &out));
        got[n] = out;
        n += 1;
    }
    // Past the last entry the call must report exhaustion, not wrap around.
    var past: Entry = undefined;
    try testing.expectEqual(0, rib.RIB_enumerate_interface(p, "ASI digital audio engine", 1, &cursor, &past));
    try testing.expectEqual(@as(?*anyopaque, null), cursor);

    for (registered, got) |want, seen| {
        try testing.expectEqualStrings(std.mem.span(want.name), std.mem.span(seen.name));
        try testing.expectEqual(want.token, seen.token);
    }
}

test "RIB_enumerate_interface entry names stay readable after later registrations" {
    // A name handed to a C caller is a raw pointer, and a caller is entitled to
    // read it after the provider registers more entries. Storing names in a
    // hash map fails this, because growing the map frees the key storage the
    // pointer refers to.
    const p = try openmiles.Provider.init(testing.allocator);
    defer p.deinit();

    const first = [_]Entry{entry("held open", 1)};
    _ = try p.registerInterface("ASI digital audio engine", 1, @ptrCast(@constCast(&first)));

    var cursor: ?*anyopaque = null;
    var out: Entry = undefined;
    try testing.expectEqual(1, rib.RIB_enumerate_interface(p, "ASI digital audio engine", 1, &cursor, &out));
    const held: [*c]const u8 = out.name;

    const filler_count = 64;
    var names: [filler_count][24:0]u8 = undefined;
    var extra: [filler_count]Entry = undefined;
    for (&extra, &names, 0..) |*e, *n, i| {
        _ = std.fmt.bufPrint(n[0..23], "filler entry {d}", .{i}) catch unreachable;
        n[23] = 0;
        e.* = .{ .entry_type = .RIB_ATTRIBUTE, .name = n, .token = 0x1000 + i, .subtype = 0 };
    }
    _ = try p.registerInterface("ASI digital audio engine", filler_count, @ptrCast(@constCast(&extra[0])));

    try testing.expectEqualStrings("held open", std.mem.span(@as([*:0]const u8, @ptrCast(held))));
    try testing.expectEqual(@as(usize, 1), out.token);
}

test "a repeated entry name updates its token in place" {
    // A provider whose entry array names the same entry twice resolves to the
    // later token, and the name keeps its first slot so the enumeration order
    // of the surrounding entries is unaffected.
    const iface = try openmiles.Interface.init(testing.allocator, "filter");
    defer iface.deinit();

    try iface.add("cutoff", 1);
    try iface.add("order", 2);
    try iface.add("cutoff", 99);

    try testing.expectEqual(@as(?usize, 99), iface.tokenFor("cutoff"));
    try testing.expectEqual(@as(?usize, 2), iface.tokenFor("order"));
    try testing.expectEqual(@as(?usize, null), iface.tokenFor("resonance"));

    try testing.expectEqualStrings("cutoff", iface.entryAt(0).?.name);
    try testing.expectEqual(@as(usize, 99), iface.entryAt(0).?.token);
    try testing.expectEqualStrings("order", iface.entryAt(1).?.name);
    try testing.expectEqual(@as(?openmiles.InterfaceEntry, null), iface.entryAt(2));
}

test "registering the same interface name twice keeps both registrations" {
    // RIB_Main calls register once per interface, so two calls with the same
    // name are two interfaces, and RIB_enumerate_interface matches the first.
    const p = try openmiles.Provider.init(testing.allocator);
    defer p.deinit();

    const first = [_]Entry{entry("cutoff", 1)};
    const second = [_]Entry{ entry("cutoff", 99), entry("order", 2) };
    _ = try p.registerInterface("filter", 1, @ptrCast(@constCast(&first[0])));
    _ = try p.registerInterface("filter", 2, @ptrCast(@constCast(&second[0])));
    try testing.expectEqual(@as(usize, 2), p.interfaces.items.len);

    const iface = p.interfaces.items[0];
    try testing.expectEqual(@as(?usize, 1), iface.tokenFor("cutoff"));
    try testing.expectEqual(@as(?usize, null), iface.tokenFor("order"));
}

test "RIB_enumerate_interface on an unknown interface reports exhaustion" {
    const registered = [_]Entry{entry("anything", 1)};
    const p = try providerWith("ASI digital audio engine", &registered);
    defer p.deinit();

    var cursor: ?*anyopaque = null;
    var out: Entry = undefined;
    try testing.expectEqual(0, rib.RIB_enumerate_interface(p, "no such interface", 1, &cursor, &out));
    try testing.expectEqual(@as(?*anyopaque, null), cursor);
}

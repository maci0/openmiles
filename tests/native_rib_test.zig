//! Integration harness for real dynamic-plugin discovery (the RIB dlopen path
//! the `zig build test` binary cannot exercise: it links musl statically, where
//! dlopen is a stub that always fails). Mirrors tests/rib_test.c's contract:
//! after scanning ./plugins at least one provider must load and register an
//! interface -- specifically the mock plugin's "ASI digital audio engine" with
//! its "Input data type" token (src/bindings/mock_asi.c) -- otherwise this
//! exits non-zero. Run from zig-out/bin after `zig build`.

const std = @import("std");
const openmiles = @import("openmiles");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    // Fixture check: the directory must exist and hold at least one *.asi/*.m3d/
    // *.flt candidate. Without this, a stale/missing install silently scanned
    // nothing while the harness still exited 0.
    var candidates: usize = 0;
    plugins: {
        var d = std.Io.Dir.cwd().openDir(openmiles.io, "plugins", .{ .iterate = true }) catch |err| {
            std.debug.print("FAIL: cannot open ./plugins ({any}); run `zig build` so bin/plugins/mock.asi is installed next to this executable\n", .{err});
            break :plugins;
        };
        defer d.close(openmiles.io);
        var it = d.iterate();
        while (it.next(openmiles.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (openmiles.isPluginExtension(entry.name)) candidates += 1;
        }
    }
    if (candidates == 0) return error.NoPluginCandidates;

    std.debug.print("Scanning './plugins' for ASI providers (Native)...\n", .{});
    driver.loadAllAsi("./plugins");

    std.debug.print("Total providers found: {d}\n", .{driver.providers.items.len});
    for (driver.providers.items) |p| {
        std.debug.print("Provider: {s}\n", .{p.name});
        for (p.interfaces.items) |iface| {
            std.debug.print("  Interface: {s}\n", .{iface.name});
            var eit = iface.entries.iterator();
            while (eit.next()) |e| {
                std.debug.print("    Entry: {s} (token 0x{x})\n", .{ e.key_ptr.*, e.value_ptr.* });
            }
        }
    }

    // Pass criteria: a provider loaded AND the mock's RIB_Main registration
    // landed end to end (interface name + entry token from mock_asi.c).
    for (driver.providers.items) |p| {
        for (p.interfaces.items) |iface| {
            if (!std.mem.eql(u8, iface.name, "ASI digital audio engine")) continue;
            const token = iface.entries.get("Input data type") orelse continue;
            if (token != 0x1234) {
                std.debug.print("FAIL: 'Input data type' token is 0x{x}, expected 0x1234\n", .{token});
                return error.WrongMockToken;
            }
            std.debug.print("PASSED: mock provider registered its interface\n", .{});
            return;
        }
    }
    if (driver.providers.items.len == 0) {
        std.debug.print("FAIL: no provider loaded from {d} candidate(s). If the error above is 'Function not implemented', this executable is statically linked against musl, which cannot dlopen; run the Windows harness instead.\n", .{candidates});
    } else {
        std.debug.print("FAIL: providers loaded but none registered 'ASI digital audio engine'\n", .{});
    }
    return error.PluginContractFailed;
}

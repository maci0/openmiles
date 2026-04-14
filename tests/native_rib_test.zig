const std = @import("std");
const openmiles = @import("openmiles");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const driver = try openmiles.DigitalDriver.init(allocator, 44100, 16, 2);
    defer driver.deinit();

    std.debug.print("Scanning './plugins' for ASI providers (Native)...\n", .{});
    driver.loadAllAsi("./plugins");

    std.debug.print("Total providers found: {d}\n", .{driver.providers.items.len});
    for (driver.providers.items) |p| {
        std.debug.print("Provider: {s}\n", .{p.name});
        for (p.interfaces.items) |iface| {
            std.debug.print("  Interface: {s}\n", .{iface.name});
        }
    }
}

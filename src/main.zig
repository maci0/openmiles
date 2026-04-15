const openmiles = @import("openmiles");

// --- API Exports ---
// Comptime-import all API modules so their exported C symbols end up in the
// final shared library.  No other state lives here — shared state is in
// root.zig (the `openmiles` module) to keep the dependency graph one-way:
//   main.zig  -->  api/*.zig  -->  openmiles (root.zig)

comptime {
    _ = @import("api/3d.zig");
    _ = @import("api/dls.zig");
    _ = @import("api/midi.zig");
    _ = @import("api/rib.zig");
    _ = @import("api/timer.zig");
    _ = @import("api/quick.zig");
    _ = @import("api/digital.zig");
    _ = @import("api/stream.zig");
    _ = @import("api/redbook.zig");
    _ = @import("api/input.zig");
    _ = @import("api/file.zig");
}

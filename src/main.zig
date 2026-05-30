const openmiles = @import("openmiles");

// --- API Exports ---
// Comptime-import all API modules so their exported C symbols end up in the
// final shared library.  No other state lives here — shared state is in
// root.zig (the `openmiles` module) to keep the dependency graph one-way:
//   main.zig  -->  api/*.zig  -->  openmiles (root.zig)

const mss_version = @import("build_options").mss_version;

comptime {
    // Always present (Core/Digital/Sample/Stream/MIDI/Redbook/Timer ship since v3).
    _ = @import("api/digital.zig");
    _ = @import("api/dls.zig");
    _ = @import("api/midi.zig");
    _ = @import("api/timer.zig");
    _ = @import("api/stream.zig");
    _ = @import("api/redbook.zig");
    _ = @import("api/file.zig");

    // Version-gated API groups so the export table matches the target release.
    if (mss_version >= 40) _ = @import("api/memory.zig"); // Memory API (v4+)
    if (mss_version >= 40) _ = @import("api/rib.zig"); // RIB/ASI + compression (v4+)
    if (mss_version >= 40) _ = @import("api/quick.zig"); // Quick API (v4+)
    if (mss_version >= 40) _ = @import("api/input.zig"); // Input recording (v4+)
    if (mss_version >= 50) _ = @import("api/3d.zig"); // 3D audio (v5+)
    if (mss_version >= 60) _ = @import("api/filter.zig"); // Filter API (v6+)
    if (mss_version >= 70) _ = @import("api/v7.zig"); // Unified v7+ API (additive)
}

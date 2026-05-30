//! Test build root.
//!
//! Pulls in the unit/fuzz test files plus every C-ABI api module so that:
//!   * the engine tests in main_test.zig / fuzz_test.zig run, and
//!   * the exported AIL_* / RIB_* wrappers compile and are reachable for fuzzing.
//!
//! All of these import the shared "openmiles" module (src/root.zig), so the
//! types they exchange are identical — unlike importing root.zig by path, which
//! would create a second, incompatible module instance.

comptime {
    _ = @import("main_test.zig");
    _ = @import("fuzz_test.zig");
    _ = @import("api_coverage_test.zig");

    // C-ABI surface — mirrors src/main.zig so the exports are part of the test
    // binary and their logic is exercised.
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

//! Test root for engine-internal unit tests.
//!
//! A file's `test` blocks are only included in a test binary when that file is
//! pulled in with `_ = @import(...)`. The engine modules live inside the
//! openmiles module and exercise private bridges, so they cannot be imported
//! into test_root (a file may belong to only one module). This file is the root
//! of a separate test artifact that force-includes the engine sources so their
//! `test` blocks run.

comptime {
    _ = @import("engine/digital.zig");
    _ = @import("engine/midi.zig");
}

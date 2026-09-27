# Changelog

All notable changes to OpenMiles are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Release process

- `build.zig.zon`'s `.version` is the single source of truth for the release
  version. Bump it in the same commit as the change, never on the tag itself.
- A release is a git tag `v<version>` matching that version exactly. The release
  workflow fails if the tag and `.version` disagree, so a build can never be
  published under a name the package does not claim.
- The release workflow runs the test suite, cross-compiles the DLL, and smoke
  tests the produced binary (32-bit PE, core exports present) before packaging.
- Compatibility is per `-Dmss-version`, not per OpenMiles release. Each value
  swept by `scripts/check_all_versions.sh` (`3`, `4`, `5`, `6.1`, `6.5`, `7`,
  `8`, `9`) reproduces its reference `mss32.dll` export table with zero missing
  exports, so an OpenMiles release that keeps those counts is a drop-in
  replacement for the same game set as the previous one. A release that changes
  a count below is breaking for the affected version and must say so in its
  Breaking section. `6` / `6.6` (66) and `6.0` (60) have no committed reference
  DLL and are not swept; `scripts/check_header.py` checks them against the
  export table, and `scripts/check_versions.py` fails if a `-Dmss-version`
  value is neither swept nor listed as unswept with a reason.
- ABI parity is checked by `scripts/check_all_versions.sh` against reference
  DLLs under `references/` (not committed; supply them locally to run it).

## [Unreleased]

No version has been tagged yet. `build.zig.zon` still reads `0.0.0`, so
everything below is unreleased.

### Added

- One clock for the whole library (`openmiles.clock`). Every period, deadline,
  and elapsed counter now reads it, so a test or simulation can install a
  virtual one: `openmiles.useVirtualClock(0)` re-bases the elapsed counters,
  `openmiles.clock.advance(ns)` steps time, and `openmiles.sleep(d)` moves it
  instead of blocking. A `Timer` started under a virtual clock spawns no
  thread; `timer.tick()` fires one period at a time, so a run replays from its
  step sequence. `AIL_sleep` and `AIL_delay` follow the installed clock.
- File-fault injection at the library's only I/O seam (`fs_compat.fault`):
  a schedule can fail an open by path or cut a whole-file read short, which a
  real disk will not do on demand. Null in production.
- `mss.h` declares the file I/O surface: `AIL_file_error`, `AIL_file_read`,
  `AIL_file_size`, `AIL_file_write`, `AIL_file_type`, `AIL_file_type_named`,
  `AIL_set_file_callbacks` and `AIL_set_file_async_callbacks`, plus the
  `AIL_FILE_*` callback typedefs and the `SEEK_SET`/`SEEK_CUR`/`SEEK_END`
  constants the seek callback takes. A game that installs a VFS had no way to
  declare the calls it makes, and a file failure had no declaration for the
  only signal that reports it.
- `make check-header` now compares the `AILSOUNDINFO` field order in `mss.h`
  against `src/root.zig` for every `-Dmss-version`.
- `AIL_set_timer_divisor` for the legacy 8254 PIT timer rate.

### Fixed

- `mss.h` declared the pre-8.0 `AILSOUNDINFO` (9 fields, 36 bytes) for every
  version, so a v8 or v9 build read `channel_mask` at +0x18 and `block_size` at
  +0x20 out of a 36-byte caller struct. `channel_mask` is now declared from
  8.0 on, and the x86 layout is pinned with `_Static_assert`.
- `DigitalDriver.init` dereferenced `pDevice.pContext` to name the audio backend
  after checking only `pDevice`. `ma_engine_init` succeeds with a null
  `pContext` on a machine with no output device, so the diagnostic line crashed
  the process on the one machine most likely to have no device.
- CI runs the project's own `make lint` (zig fmt + ruff + shellcheck) and
  compiles C with warnings as errors.
- `ruff check` and `ruff format` over `scripts/`, so the lint gate's own
  scripts are linted; `ruff.toml` pins the rule set, including the ARG, ERA,
  FBT, ICN, and PYI groups.
- `make check-pins` (run by `make lint`) fails when the Zig and ruff versions
  named in the Makefile, `ci.yml`, and `build.zig.zon` disagree, and when a
  workflow that builds the tree stops taking its Zig from `build.zig.zon`.
- `make check-versions` (run by `make lint`) fails when a `-Dmss-version` value
  is not parity-swept, is not declared unswept with a reason, or is missing
  from the version set `scripts/check_header.py` resolves the header for.
  `scripts/check_all_versions.sh` prints the values it did not build.
- Fuzz targets for the event-step decoder and the XMIDI parser
  (`src/fuzz_native_test.zig`).
- Vendored dependency checksums are documented for `deps/`.
- `CONTRIBUTING.md`: pinned-tool setup, the edit-test loop, what a change is
  expected to carry, and how the vendored and generated files are checked.

### Fixed

- The timer run loop, the Redbook clock, and `AIL_delay` / `AIL_sleep` read
  `std.Io.Timestamp` and slept on the real clock directly, so their timing did
  not pass through the library's elapsed-time base. They read the central
  clock now.
- The test build failed to compile: `AIL_open_digital_driver` and
  `AIL_open_midi_driver` tests read and cleared the current-driver handle
  directly, which stopped compiling when the handle was made private. They go
  through `lastDigitalDriver` / `setLastDigitalDriver` and their MIDI
  counterparts.
- `zig fmt` clean again (`src/engine/midi.zig`), so `make lint` passes.
- A digital driver handle that could not enter the handle table is misread as a
  `Sample3D` by every 3D setter, which then writes a listener position through
  the wrong layout. The table was capped at eight drivers, so the ninth open
  produced exactly that: it now grows on demand, and an open that still cannot
  be tracked fails the call instead of publishing an untracked handle.
- UTF-8 destinations were sized in UTF-16 units, so a path carrying any
  character outside ASCII was reported as too long and dropped. Buffers are
  sized from `wide.utf8LenBound` (three bytes per unit) in the temp-path,
  ASI-unpack, and log paths.
- A `?` wildcard in a file glob matched one byte, so it could match half a
  multi-byte character and then fail on the rest. It matches one character.
- `Timer.setPeriodUs` accepted 0, which left the run loop with an empty sleep
  and fired the callback back to back on one core. The period is clamped to
  `Timer.min_period_us`, so a rate that truncates to 0 hz runs at the floor
  rather than spinning.
- The event-step decoder read past the end of the string when a version header
  ended at its type byte (`"9"`, `"9;"`). Found by the new fuzz target.
- Repeated opens no longer duplicate state: `AIL_open_digital_driver` records
  the driver it opened, so a second call returns that driver instead of
  building another miniaudio engine (and `AIL_shutdown` now reaches it), and a
  MIDI sequence asking for its implicit digital driver reuses the open one
  rather than leaking an engine per sequence. A plugin directory scanned twice
  (`RIB_load_application_providers` after startup, or `AIL_set_redist_directory`
  set to the same path twice) loads each module once, matched on its resolved
  path, and `RIB_unregister_interface` drops every registration made under the
  name instead of leaving a copy behind.
- `RIB_enumerate_interface` yields a provider's entries in registration order.
  It previously walked a hash map, so the order a game saw depended on the key
  bytes and the map's rehash history rather than on what the provider
  registered, and the `name` pointer it handed out was freed by the next
  registration that grew the map. Entry names now live in the interface and
  stay readable until the provider is freed.
- `Interface` and `Provider.init` leaked the interface name / provider name when
  the allocation that followed it failed.
- Sample and stream behaviour brought in line with the MSS SDK: state machines
  and callback ordering for `AIL_start_sample`, `AIL_stop_sample`,
  `AIL_end_sample`, `AIL_end_3D_sample`, `AIL_stream_status`,
  `AIL_stream_position`, `AIL_stream_loop_count`, and `AIL_service_stream`,
  including the documented null and error return values.
- 3D audio: velocity units for the listener update and `AIL_3D_sample_attribute`
  (negated Z), and round-tripping of position, velocity, orientation, cone,
  and distance attributes through the `S3D` struct instead of the backend
  handles.
- `AIL_init_sample` now resets level, reverb, filter, and occlusion state and
  clears `adpcm_block_size` on re-init, and `AIL_sample_granularity` reports
  the source format rather than the decoder's output.
- 3D sample velocity units and a soundbank offset overflow.
- Timer self-stop deadlock, unbounded event-instance growth, and an ASI
  temporary-file leak.
- The debug log is capped at 64 MiB per process instead of growing without
  limit.
- Bounds and overflow handling across the parsers and the audio surface: file
  header sniffing, ID3v2 and SMF meta lengths, XMIDI image extents, MP3
  sample rates, WAV parsing, and the stream ring size from the configured
  sample buffer count.
- Load failures that were previously swallowed are now reported, with the
  VFS handle leak and dangling filter pointer on the error path fixed.
- `openmiles.log` and mock plugin loading after Windows cross-builds.

### Changed

- Unknown-size sample loads go through bounded callbacks.
- MIDI sequence beat and millisecond conversions saturate instead of
  overflowing `i32`.
- The test build no longer enables the debug log by default, so a `make test`
  run does not append engine trace to `openmiles.log` in the repository root
  or bury a failing test in it. `OPENMILES_DEBUG=1` turns it back on for a
  run; a Debug build of the library still logs by default.

### Known gaps

- The v8/v9 event execution VM tracks sound instances (lifecycle, durations,
  label filtering, per-label caps) but does not yet route them through the
  mixer for audio output, so event-driven sounds are queryable but silent.
  See `docs/API_STATUS.md` for the per-function matrix.

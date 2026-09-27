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
- Compatibility is per `-Dmss-version`, not per OpenMiles release. Each
  supported value (3 through 9) reproduces its reference `mss32.dll` export
  table with zero missing exports, so an OpenMiles release that keeps those
  counts is a drop-in replacement for the same game set as the previous one.
  A release that changes a count below is breaking for the affected version and
  must say so in its Breaking section.
- ABI parity is checked by `scripts/check_all_versions.sh` against reference
  DLLs under `references/` (not committed; supply them locally to run it).

## [Unreleased]

No version has been tagged yet. `build.zig.zon` still reads `0.0.0`, so
everything below is unreleased.

### Added

- `AIL_set_timer_divisor` for the legacy 8254 PIT timer rate.
- CI runs the project's own `make lint` (zig fmt + shellcheck) and compiles C
  with warnings as errors.
- Vendored dependency checksums are documented for `deps/`.

### Fixed

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

### Known gaps

- The v8/v9 event execution VM tracks sound instances (lifecycle, durations,
  label filtering, per-label caps) but does not yet route them through the
  mixer for audio output, so event-driven sounds are queryable but silent.
  See `docs/API_STATUS.md` for the per-function matrix.

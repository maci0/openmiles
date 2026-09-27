# Changelog

All notable changes to OpenMiles are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and releases follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Release process

- `build.zig.zon`'s `.version` is the single source of truth for the release
  version. Bump it in the same commit as the change, never on the tag itself.
- A release is a git tag `v<version>` matching that version exactly. The release
  workflow fails if the tag and `.version` disagree, so a build can never be
  published under a name the package does not claim. It fails the same way when
  `CHANGELOG.md` has no `## [<version>]` section, so a version cannot be tagged
  with its notes still sitting under `## [Unreleased]`.
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
- The first tagged release decides the stability promise. While the version is
  `0.x`, SemVer promises nothing: a minor bump may carry a behavioural break,
  and the export table, not the version number, is the compatibility contract a
  consumer checks (`make check-header`, `make check-versions`). Reaching `1.0`
  means every `-Dmss-version` surface, and the struct layouts `mss.h` declares,
  are stable from there, and any later change to one is a major bump with a
  Breaking section naming the version it affects.

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
- `openmiles.releaseAllChannels(owner)` drops every MIDI channel lock held by
  `owner` (`MidiDriver` and `Sequence` call it from their teardown). A lock
  outlived the handle that took it, so a game that closed a MIDI driver, or
  freed a sequence that had locked a channel, permanently spent one of the 15
  lockable channels until `AIL_lock_channel` answered -1 for the rest of the
  process.
- `make lint` runs yamllint over `.github/workflows`, with the rule set in
  `.yamllint` and the version pinned by `YAMLLINT_VERSION` the same way ruff
  is. `make check-pins` now fails when the Makefile and `ci.yml` disagree on
  it.
- ruff's `S` (flake8-bandit) group is selected in `ruff.toml`, so the gate
  scripts are checked for the insecure patterns bandit names, not only for
  style and correctness.
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
- Fuzz targets for the event-step decoder, the XMIDI parser, the SoundBank
  loader, and the WAV container readers (`src/fuzz_native_test.zig`), the last
  two with size and count invariants checked after every input.
- Vendored dependency checksums are documented for `deps/`.
- `CONTRIBUTING.md`: pinned-tool setup, the edit-test loop, what a change is
  expected to carry, and how the vendored and generated files are checked.
- `scripts/requirements-dev.txt` pins the one third-party Python package the
  gates need, `pefile`, which `scripts/check_exports.py` imports to read a
  reference DLL's export table. `make parity` checked for it up front and
  named the install command, and `CONTRIBUTING.md` documents it as the single
  exception to "nothing else is fetched": `make lint` and CI still need
  nothing beyond the standard library.
- The release archive and its checksum file, `*.zip` and `release/`, are
  ignored. `scripts/package_release.sh` writes both into the tree it runs in,
  and the release workflow publishes them, so a local run no longer leaves an
  artifact that can be committed by accident.

### Fixed

- `make lint` failed on a clean tree: `ruff check` reported the fixed-argv
  `zig cc` call in `check_header.py` under the bandit rules, and every
  `docs/THREAT_MODEL.md` `file:line` reference whose line had moved since it
  was written failed the anchor check. The compiler call resolves `zig` through
  `shutil.which` and names the missing binary instead of raising, and the
  threat model references point at the line the anchor is on.
- `make test FILTER=<substring>` reported success when the substring matched no
  test name, so a typo read as a green run. A filter that matches nothing is
  now refused, naming the filter.
- `make help` did not list `check-yaml` or `check-parity-tools`.
- `mss.h` declared the pre-8.0 `AILSOUNDINFO` (9 fields, 36 bytes) for every
  version, so a v8 or v9 build read `channel_mask` at +0x18 and `block_size` at
  +0x20 out of a 36-byte caller struct. `channel_mask` is now declared from
  8.0 on, and the x86 layout is pinned with `_Static_assert`.
- `DigitalDriver.init` dereferenced `pDevice.pContext` to name the audio backend
  after checking only `pDevice`. `ma_engine_init` succeeds with a null
  `pContext` on a machine with no output device, so the diagnostic line crashed
  the process on the one machine most likely to have no device.
- The ELF fixup walk read one dynamic entry past the mapped image whenever the
  entry count was odd, and applied a `DT_RELA` `r_offset` without checking it,
  so a crafted plugin image could have the loader write anywhere in the address
  space. The scan now stops on complete pairs, and a fixup slot outside the
  image or not 8-byte aligned fails the load.
- The ELF fixup bounded the program header table with a `u64` sum narrowed to
  `usize`, which in a ReleaseFast build is an unchecked truncation: a crafted
  `e_phoff` plus `e_phentsize * e_phnum` wrapping `u64` passed the bound and
  walked a table starting far outside the mapping. The sum is compared in `u64`
  now, so a wrapped table fails the load.
- `Timer.start` blocked on the state mutex, which the self-stop path joins: a
  callback that restarted its own timer deadlocked against the run loop it was
  running on. A restart over a live handle now retires the old loop first (and
  from inside that loop, resumes it rather than joining the current thread), and
  a concurrent start is dropped instead of queued behind the join.
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
  VFS handle leak and dangling filter pointer on the error path fixed. A
  mid-stream decoder error also reports zero frames, indistinguishable from a
  clean end of file, so `AIL_decompress_ADPCM` and the ADPCM source decode
  failed the load instead of handing back a silently short image, and an ASI
  stream reports a failed read or seek as a failure rather than as the end of
  the stream or a position it never reached.
- Repeated `AIL_stream_*Buffer` submits and a soundfont load that failed part
  way through left the stream in a state where a retry could not complete, so
  both are re-run safe now.
- Opening the same soundbank file twice registered two banks: a second copy of
  the metadata in the container, `LoadedBankCount` counting one file twice, and
  the second copy answering a name lookup the first already owned. One bank per
  file now: an open of a file already in the container returns the bank it holds
  and takes a reference, and each open needs its own close.
- Soundbank name resolution picked a hash-map winner rather than load order, and
  a bank that failed to load left its index entries allocated. Names resolve in
  load order and the indexes are freed on the failure path.
- MIDI and digital driver state shared with the audio thread (sequence status,
  3D handles, quick-sample slots, driver channels) was read and written without
  synchronization; those accesses are atomic and the last-driver handles are
  published with a release store.
- `openmiles.log` and mock plugin loading after Windows cross-builds.
- 26 `file:line` anchors in `docs/THREAT_MODEL.md` pointed at lines the named
  symbol had since moved off, so `make check-threat-model` (run by
  `make lint`, and by CI) failed on a clean tree and every mitigation claim
  the model makes was unresolvable. The anchors now name the line the
  referenced code is on.
- `scripts/check_all_versions.sh` built each `-Dmss-version` with whatever zig
  was on PATH, so a parity verdict could be produced by a compiler nobody
  audited. It refuses any version other than the one `build.zig.zon` declares,
  as `make check-toolchain` already does for the rest of the build.
- The release archive and its `SHA256SUMS` were built from two separate file
  lists, so the checksums could name an entry the archive did not contain (or
  miss one it did), and packaging the same inputs on two machines produced
  different bytes because the MS-DOS entry timestamps followed the host
  timezone. Both are written from the same entry list now, and the archive is
  byte-identical across hosts; the release workflow repackages under a different
  `TZ` and `LC_ALL` and compares.

### Changed

- `OPENMILES_DEBUG` accepts `yes`/`no` and `on`/`off` beside `1`/`0` and
  `true`/`false`, in any case, and a value outside that set is reported on
  stderr instead of silently meaning off. `OPENMILES_DEBUG=yes` previously
  disabled the very log it asked for, with no message. A `TMPDIR` that is
  empty, too long, or relative is reported the same way rather than quietly
  relocating the ASI image to the game directory. The README now has a
  *Configuration* section listing both variables, their values, and their
  defaults.
- The shipped `mss32.dll` is linked stripped. It no longer carries a CodeView
  directory, so the build directory cannot reach the artifact through the PDB
  GUID, and two builds of one commit at different paths produce the same bytes.
- `make parity` installs its per-version builds under `zig-out/parity` instead
  of overwriting the shipped `zig-out/bin/mss32.dll` with a Debug build of
  another release.
- Every release-archive entry is staged with mode 0644, so a build output's
  executable bit cannot reach the zip bytes.
- Unknown-size sample loads go through bounded callbacks.
- MIDI sequence beat and millisecond conversions saturate instead of
  overflowing `i32`.
- The v9 bus limiter interpolates a 1024-entry `tanh` table, saturating above
  the input 8.0 where the shaped output has already reached 1.0 in `f32`, instead
  of calling `tanh` per sample above the knee. The per-label sound-cap eviction
  no longer scans the instance list on every insert.
- The test build no longer enables the debug log by default, so a `make test`
  run does not append engine trace to `openmiles.log` in the repository root
  or bury a failing test in it. `OPENMILES_DEBUG=1` turns it back on for a
  run; a Debug build of the library still logs by default.
- The `make` gates resolve the Python interpreter (`python3`, or `python` where
  that is the name on PATH) and run the `scripts/*.py` gates through it,
  instead of executing each one through its shebang, so they run on a host
  where the `python3` name does not exist.
- The temp ASI image falls back to the platform separator when no temp
  directory can be determined, instead of a literal `/`.

### Known gaps

- The v8/v9 event execution VM tracks sound instances (lifecycle, durations,
  label filtering, per-label caps) but does not yet route them through the
  mixer for audio output, so event-driven sounds are queryable but silent.
  See `docs/API_STATUS.md` for the per-function matrix.

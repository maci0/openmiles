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
- The release workflow runs the same analysis gate as `make lint`, the test
  suite, cross-compiles the DLL, and smoke tests the produced binary (32-bit PE,
  core exports present) before packaging.
- The published release notes are that `## [<version>]` section verbatim, not
  a generated commit list: the tag check already fails without it, and an
  empty section fails the publish rather than shipping a release whose notes
  say nothing.
- A published version is immutable. A `workflow_dispatch` re-run of a tag is the
  retry for a run that failed before it published. Either trigger refuses a tag
  that already has a release, so neither a retry nor a re-pushed tag can
  replace the archive a consumer has already fetched and recorded against
  `SHA256SUMS`. A fix to a published release ships as a new version.
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
- The first tagged release decides the stability promise. While the version is
  `0.x`, SemVer promises nothing: a minor bump may carry a behavioural break,
  and the export table, not the version number, is the compatibility contract a
  consumer checks (`make check-header`, `make check-versions`). Reaching `1.0`
  means every `-Dmss-version` surface, and the struct layouts `mss.h` declares,
  are stable from there, and any later change to one is a major bump with a
  Breaking section naming the version it affects.

## [Unreleased]

### Added

- The release archive carries a generated `BUILDINFO.txt` recording the Zig
  version, target and optimize mode the shipped DLL was built with, read from
  `build.zig.zon`. `deps/SHA256SUMS` and `SBOM.cdx.json` already said which
  third-party code the DLL carries and what the vendored headers hash to, but
  nothing in the archive said what compiled it, so a rebuild had no toolchain to
  reach for. Every field comes from the tree or from `SOURCE_DATE_EPOCH`, never
  from the packaging host, so the archive stays byte-identical across hosts.

### Changed

- The Quick API's three entry points that allocate a sample share one
  `newQuickSample` helper, and `AIL_quick_load`'s VFS-or-disk read is now
  `loadQuickSample`. Same handles, same last-error text, same log lines.

### Fixed

- A loop restart that miniaudio refuses no longer reports success. The
  end-of-sound bridge dropped the result of `ma_sound_seek_to_pcm_frame` and
  `ma_sound_start` and returned "loop again", so a sample whose loop start lies
  past the end of the decoded image (a block `setLoopBlock` accepts, since it
  only checks that the block spans a frame) stayed `SMP_PLAYING` forever, never
  fired its end callback, and, on an infinite loop count, spun the audio thread
  for the life of the process. A failed seek or start is now named in the log
  and reported as the end of the sound.
- A truncated or foreign SMF is no longer measured as a complete image.
  `smfImageSize` answered `data.len` when its track walk ran out of data or met
  a chunk that was not `MTrk`, so `findXmi` handed the trailing DLS bank back as
  part of the music image and `AIL_merge_DLS_with_XMI` wrote the two out as one
  file. Those paths now report 0, matching what the sibling pointer-based walker
  already answered and what the module's contract says.
- `AIL_set_3D_sample_info` bounds `data_len` against the 256 MiB image cap before
  slicing, as every other untrusted image in the library is bounded. `channels`
  and `bits` were already clamped, so a game with a bad `AILSOUNDINFO` asked for
  a 4 GiB slice over a pointer of unknown extent.
- `LoadLibraryW` failures are no longer all reported as `FileNotFound`. A path
  that failed to convert to UTF-16, a plugin whose *imports* are missing, and a
  plugin whose `DllMain` refused now reach the caller as distinct errors, and
  the Win32 code is carried out to the load log beside the plugin name.
- A soundbank's name index that fails to build says so. The bank still loads and
  still answers every lookup, on the linear-scan path, but nothing recorded that
  the index was abandoned.
- `AIL_allocate_bus` names which of its three failures (allocation, miniaudio
  group init, list append) produced the null, and carries the `ma_result`
  description for the init failure. `AIL_list_DLS` records why it rejected an
  image instead of leaving `AIL_last_error` holding the previous failed call's
  message. `AIL_redbook_open` and `AIL_redbook_open_drive` log the error their
  `catch` was discarding.
- Capture chunks dropped by `Input.captureCallback` (contended lock, or a ring
  with no room) are counted and readable through `Input.droppedChunkCount`.
  Losing audio silently left a busy device indistinguishable from a quiet one.
- A case-insensitive path that resolves but still fails to open now logs both
  the first and the retry's error, instead of reporting only the retry's and
  losing a permission failure to a "File not found". `createFile` and
  `createFileAbsolute` get the retry the opens already had, so a name MSS
  resolves case-insensitively can be written as well as read.
- The three blocking external calls with no timeout (`LoadLibraryW`,
  `ma_device_init`, `FindFirstFileW`) are recorded in `docs/THREAT_MODEL.md`
  with the reason a bound is not inlined and the value one would take.
- `MilesSetSoundLabelLimits` and a `set_limits` step name every limit entry they
  could not parse or store, and record the count through `AIL_last_error`. The
  call still returns 1: the caps that parsed are applied, and a caller told
  "failed" for a partly applied string would not know which half is live.
- `scripts/check_all_versions.sh` sorted its unswept-version report with
  `sort -V`, a GNU extension BSD `sort` rejects, so the parity sweep died before
  printing a row on a macOS or BSD host. The order is now built from `awk`,
  `sort` and `cut`, and the same sequence comes out.
- The ELF plugin-image fixup applied no relocations on a 32-bit Linux target,
  and on a riscv64 or ppc64 one, because `relative_reloc_type` named only
  x86_64 and aarch64. The writable-segment repair still ran, so a plugin loaded
  on those targets kept link-time addresses in its data and crashed on the first
  dereference. riscv64 and ppc64 are now rebased as well; a 32-bit target still
  gets the segment repair without them, because std.elf names no `R_386`
  RELATIVE value to apply.
- `CONTRIBUTING.md` claimed the library builds on any host Zig supports. It
  does not on aarch64, on any operating system, and the README already said so.
  The claim now names the exclusion, and it states that the two `scripts/*.sh`
  gates need bash rather than the `sh` their shebangs are read as.
- The temporary ASI provider image is created with `Permissions.fromMode(0o600)`
  rather than a bare `0o600`. `std.Io.File.Permissions` is a non-exhaustive enum,
  not a mode integer, so the tree did not compile at all: every `zig build` and
  `make test` on a non-Windows target failed with `expected type
  'Io.File.Permissions__enum_2901', found 'comptime_int'`. The owner-only mode
  itself is unchanged.
- The parity setup steps in `CONTRIBUTING.md` and `scripts/requirements.txt`
  now create the virtual environment `uv pip install` requires, instead of
  naming an install command that stops with `No virtual environment found`.
  `.venv/` is gitignored, and `make check-parity-tools` names the same three
  steps.
- 90 of the 197 `file:line anchor` references in `docs/THREAT_MODEL.md` were
  stale, so `make lint` and CI failed on a clean checkout. All 197 resolve again.

### Added

- `scripts/package_release.sh` writes `<output.zip>.sha256` beside the archive,
  and the release attaches it. The `SHA256SUMS` a release already published
  names the files *inside* the zip, so a consumer who downloaded the archive
  and had not unpacked it had no record of the archive's own bytes to check
  them against.
- `scripts/check_workflow_shell.py`, in `make lint` and therefore in CI: every
  `run:` block in `.github` is extracted and shellchecked as bash. The shell in
  a workflow installs the pinned tools, cross-checks `build.zig.zon` against the
  tag, and reads the shipped PE header; yamllint read those blocks as YAML, so
  a quoting mistake in one passed lint and failed on the runner. A finding names
  the workflow and the step it came from.
- `scripts/check_config_docs.py`, in `make lint` and therefore in CI: the log
  cap, the log path limit, the `TMPDIR` limit, the default log file name, and
  the spellings `OPENMILES_DEBUG` accepts are constants in `src/`, and every
  one of them was also a number written out in the README and the threat model.
  Widening a limit in a source left both documents quoting the old one, so an
  operator setting a `OPENMILES_LOG_PATH` the library had stopped accepting read
  a document that said otherwise, with every gate green. The script reads the
  constants back and asserts the documents name them.
- `scripts/check_versions.py` also reads the accepted `-Dmss-version` set from
  the header's side. A value added to `src/mss.h` and to `check_header.py`
  without a matching entry in `build.zig` compiled for every consumer and for
  every version probe the header gate runs, because each of those selects a
  value `build.zig` does know, and the two lists were only compared with each
  other. The gate now rejects a header value no build encodes, and compares the
  two defaults it never read: `build.zig`'s `orelse "9"` and `mss.h`'s
  `OPENMILES_MSS_VERSION 90`, which is what a consumer that defines nothing
  gets. It also compares the `-Dmss-version=<...>` list and the default beside
  it in the README, which is where a consumer picks a version from ahead of
  `zig build --help`, and which nothing had read until now.
- `scripts/check_toolchain_pins.py` checks the Zig version in the README's build
  requirements against `.minimum_zig_version`. It was the one pin written in
  prose, and a bump that missed it left the front page asking for a compiler
  `make build` refuses, with every gate in the tree green.

### Changed

- `scripts/check_vendored.py` fails a `README.md` dependency table that
  disagrees with `deps/README.md` on a library's version, upstream, or license,
  and fails a vendored library the table does not list. The table is the first
  thing a reader of the repository, and of the release archive, sees, and it was
  the one copy of the version a scanner matches an advisory against that no gate
  checked: a header swap updated `deps/README.md`, `deps/SHA256SUMS` and
  `SBOM.cdx.json`, and left the front page naming the superseded version.
- `scripts/check_vendored.py` fails a vendored entry whose **Source** is not an
  `https` URL on an approved host. Version, upstream commit and digest were all
  verified, so a header arriving from a lookalike host carrying the right bytes
  and a plausible commit id passed every check; the commit names a revision, not
  a repository. Both upstreams resolve to `github.com`, named in `SOURCE_HOSTS`.
- `ci.yml` reads the `UV_VERSION`, `RUFF_VERSION` and `YAMLLINT_VERSION` pins out
  of the `Makefile` instead of repeating them, the way `release.yml` already
  did, and `make check-pins` now fails a workflow that types one of its own.
- XMIDI conversion orders a same-tick control or program change before a
  same-tick note-on. Sorting by raw status byte put the note-on first, and an
  XMIDI sequence opens at delta 0 with its volume, pan and reset-controllers
  writes ahead of the first note, so every sequence's first note rendered at the
  soundfont's default volume and pan.
- `make check-parity-tools` asks `scripts/check_exports.py --check-deps` whether
  `pefile` imported, instead of a `python -c 'import pefile'` one-liner in the
  makefile. The probe belongs to the script that owns the dependency, and a
  parity run launched without `pefile` now names the missing package instead of
  ending on an `ImportError` traceback.

### Fixed
- `src/api_coverage_test.zig` compiled again: the file/input coverage test built
  a `const` payload and `@ptrCast` it to `AIL_file_write`'s `void FAR *`, which
  discards the const qualifier, so `zig build test` failed to build the test
  binary at all.
- The Windows temporary directory is now reported for every reason it is
  refused. A `%TEMP%` longer than `MAX_PATH`, one that will not convert to a
  path this build can use, and an environment with no temporary directory were
  two of them the same "TMP, TEMP and the system profile directory are all
  unavailable", and the first two were silent: the image went to the game
  directory with nothing on stderr to say why. Each reports its own cause, and
  the too-long case names the variables to shorten.
- The configuration a run starts from no longer inherits the previous run's
  `OPENMILES_DEBUG` echo. `debug_from_env` was set when an export was read and
  never cleared, so a process that loaded the library twice, with the export
  gone the second time, printed a configuration line about a build default that
  nothing had asked about. `init()` and `deinit()` both reset it beside the
  build defaults they own.
- `docs/THREAT_MODEL.md` re-anchored at `src/engine/midi.zig`: the XMIDI loop
  stack, its depth check and the per-buffer jump budget had moved, so
  `make lint` failed `check-threat-model` on every run. The three mitigations
  the model cites were always in the file; only the line numbers were stale.
- `docs/THREAT_MODEL.md` re-anchored across `src/api/`, `src/engine/`,
  `src/root.zig` and `src/fuzz_native_test.zig`, which had drifted the same
  way: `make lint` failed `check-threat-model` on 90 references.
  `scripts/check_threat_model_refs.py --update` re-aimed each one at the line
  its anchor is on now.
- `AIL_set_3D_sample_loop_block` and `AIL_set_stream_loop_block` apply the SDK
  loop-block argument rules the 2D `AIL_set_sample_loop_block` already did:
  both offsets `-2` is a no-op, a single `-2` keeps that side's current
  offset, and a reversed pair is swapped. The 3D and stream entry points
  passed the pair straight through, so `-2` cleared the loop block instead of
  leaving it alone, and a game that gave the block the SDK way round (a common
  habit, since the 2D call accepts it) got a sample that played through once.
  The normalization is now `openmiles.resolveLoopBlock`, shared by all three.
- `AIL_stop_sequence` on a sequence that never reached a sound reports
  `SEQ_STOPPED`. `Sequence.status` returned `SEQ_DONE` for every sequence that
  was not initialized, which is checked before the stop flag, so a game that
  starts a sequence, falls back when the driver cannot play it, and then stops
  it could never observe `SEQ_STOPPED`.
- `AIL_set_sequence_ms_position` applies the tempo events it passes over even
  when the driver has no soundfont loaded. The seek consumes every event before
  the target whether or not it applies it, so the tempo in force at the seek
  point was being skipped, and beat and measure were recalculated from the
  file's initial tempo.
- `AIL_load_sample_buffer` leaves the ring's head cursor on the slot it names
  when the submission is refused. The cursor advanced before the feed, so a
  refusal left it one slot ahead, and the next `MSS_BUFFER_HEAD` call skipped
  the slot `AIL_sample_buffer_ready` had just reported as free.
- `AIL_enumerate_filter_attributes` clears the name on the terminal call, as
  its own comment says it does. It wrote the first attribute's name instead, so
  a caller reading the name before the return value got `"Cutoff"` back from a
  call that reported no attribute.

## [0.3.0] - 2026-09-28

Digital driver lifecycle counting, SoundFont thread safety, Miles event-system hardening, ASI codec fuzzing, reproducible release packaging.

### Breaking

The PE export table is unchanged, so a game that only drops in `mss32.dll` is
unaffected by everything below. The breaks are in the two surfaces a source
consumer compiles against: the Zig API under `src/` and `mss.h`.

Zig API, for a project that consumes the package as a dependency
(`b.dependency("openmiles", ...)`):

- `fileCallbackReadAll` takes the allocator it allocates from:
  `fileCallbackReadAll(filename)` is now
  `fileCallbackReadAll(allocator, filename)`. The returned buffer belongs to
  that allocator and must be freed with it, so a caller that passed only the
  filename no longer compiles, and one that freed the old buffer with its own
  allocator is now freeing across allocators.
- `parseSmfTimeSigNumerator` is gone, renamed `parseSmfBeatsPerMeasure`. It
  always returned the measure's quarter-note beat count (the time-signature
  denominator), never the numerator its old name promised, so the new name is
  what the return value already was.
- `unregisterSequence(seq)` is gone. `claimSequenceRelease(seq) bool` replaces
  it: the release is now a claim under the lock, and it reports whether the
  handle was still tracked. A handle it does not name has already been freed, so
  a caller that released twice now has to act on the `false` instead of freeing
  twice.
- `registerSequence(seq)` returns `bool`, reporting whether the handle was
  tracked. A caller that discards the result is unaffected; a caller that stored
  the function in a `*const fn (*Sequence) void` no longer type-checks. A
  `false` means the handle could not be tracked, and the caller owns tearing it
  down.
- `maybeResolveCaseInsensitivePath` moved from `openmiles` to
  `openmiles.fs_compat`, next to the other filesystem helpers that call it. The
  signature is unchanged.
- `satI32`, `satU32` and `removeFirst` are now re-exports of
  `utils/saturate.zig` and `utils/list.zig` rather than definitions in the
  module root. They keep their signatures, so `openmiles.satI32(v)` still
  compiles; a caller importing `openmiles/utils/saturate.zig` by path gets the
  same functions.

`mss.h`:

- `MilesSetVarI`, `MilesSetVarF`, `MilesGetVarI` and `MilesGetVarF` take
  `void* system` where they took `U32 system`. The handle is what
  `MilesStartupEventSystem` returns, so the new type is the one the rest of the
  event-system calls in the header already use. The parameter is one pointer
  wide on every target and the stdcall decoration is unchanged, so a binary
  linked against the old header still resolves and runs; a source consumer that
  copied the handle into its own `U32` must drop that copy.

### Added

- Coverage-guided fuzz targets for `AIL_decompress_ASI` and for the
  `AIL_compress_ASI` / `AIL_decompress_ASI` pair. The decompressor was the one
  untrusted-input surface with no harness: it takes an image of unknown
  provenance and hands back a buffer whose length is what bounds every later
  read, and nothing in the C ABI re-checks it. The targets plant a container
  tag or a WAV header with sizes the bytes behind them do not honour, and
  assert that a decode which reports success returns a PCM image whose data
  chunk lies inside the buffer its own length describes, and that a call
  which fails hands back no buffer at all. The round trip asserts the
  compressor's own output: the fact-chunk frame count, the data chunk inside
  the image, and that the decoder reads back what the encoder wrote.
- `AIL_serve` advances the 3D sources that asked for automatic position updating, by the time since the previous serve. The flag `AIL_auto_update_3D_position` sets had no effect before, and the call was a documented no-op.
- A `set_limits` step inside an event installs the per-label caps its text declares, the same call `MilesSetSoundLabelLimits` makes. Only the out-of-band call applied them.
- `mss.h` is installed to `zig-out/include/mss.h` and ships in the release
  archive next to `mss32.dll`. The header is the only thing a consumer
  compiles against, and until now a release archive handed a caller a DLL that
  no new code could call without pulling the source tree for the header.
- `mss.h` documents that `AIL_set_sample_file`'s `block` argument is not
  meaningful, since the call always reads a whole image out of memory.
- `openmiles.tickAllTimers()` fires every registered, running timer once and advances the virtual clock by the sum of their periods. A simulated run that starts the whole timer set through `AIL_start_all_timers` has no thread to wait on, so it had no way to reach those callbacks; it had to start and step the timers one handle at a time.
- `openmiles.startSimulation(seed)` logs the seed. The seed is a run's replay key and the caller is usually a test runner that reports only the failure, so a run whose seed was never written down could not be replayed.
- Every `openmiles.log` record opens with a fixed-width UTC timestamp
  (`2026-09-28T08:27:37.123Z`), milliseconds included. A record carried no time
  at all, so a log read after the session that produced it could say what
  happened but never when, and a log that hit the 64 MiB cap or interleaved
  lines from two engine instances could not be sorted back into order. The
  first line names the format.
- `-Dmss_version` is accepted as a spelling of `-Dmss-version`. `zig build`
  can only pass an option whose name has no hyphen through
  `b.dependency("openmiles", .{.mss_version = 9})`, because the struct field
  becomes a `-D` flag, so a project consuming the package as a Zig dependency
  could not select the version at all: the call failed on an unknown option, and
  without it the module always compiled as 9.0. The README's "Using the Zig
  module" section documents the dependency path.

### Changed

- The digital driver is reference counted, and `AIL_waveOutOpen` takes a
  reference on the one the process already has instead of building a second
  miniaudio engine. Both entry points name the same device, so a game that
  opens through one and closes through the other, or opens through both, used
  to get two audio devices on one output (the second open can fail outright)
  and two independent teardowns of a handle the other still held. Opens are
  counted, the device is torn down with the last close, and `AIL_shutdown`
  still forces it down whatever is outstanding.
- A miniaudio result code in a log line is printed with the text miniaudio
  returns for it, next to the code, rather than the code alone. `ma_engine_init
  failed: -1003` is unreadable to anyone who is not holding the miniaudio
  header, and a field log is read precisely when there is no one holding
  anything; no-playback-device under Wine is the common report, and it now
  names the reason. Every site that logged a `ma_result` uses the same
  `root.maResultDescription` helper.

- The C warning set gains six groups the tree already passes: `-Wenum-conversion`,
  `-Winit-self`, `-Wredundant-decls`, `-Wnested-externs`, `-Wpointer-arith` and
  `-Wstrict-overflow=2`. They are declared once in `build.zig` and repeated by
  `scripts/check_header.py` and `scripts/check_examples.py`, which
  `scripts/check_toolchain_pins.py` holds to the same list. A signed overflow
  that is only undefined once the optimizer assumes it cannot happen now fails
  the build rather than the release it reaches.
- `ruff.toml` selects `ASYNC`, `FA`, `FAST`, `PD`, `SLOT`, `TCH`, `TD` and
  `YTT`. They sat out because nothing in the tree could trip them yet, which is
  a reason to leave a rule off until it has something to say, not a reason to
  leave it off: the first script that blocks inside an async function, or leaves
  a `TODO` in the gate that is itself the gate, is what they were there to
  catch. `ANN` and `D` stay out, and say so.
- Both workflows run the test suite as `zig build test --summary all`, the
  invocation `make test` uses. Without the summary a green run ends on the
  `failed command: ... --listen=-` line zig prints after a test artifact writes
  to stderr, and the `N/N tests passed` line that settles it never appears.
- A release archive carries the security policy, the contributor guide, and the
  `docs/` its own README links, and the vendored attribution and digests keep
  the `deps/` paths the README links them by instead of a flat `VENDORED.md`
  and `DEPS-SHA256SUMS`. Every relative link in the shipped tree resolved to a
  file the archive did not hold.
- The `zig fetch` package carries `LICENSE`, the docs, and the scripts the
  vendored-dependency records name, and no longer lists `test_media/`.
  `zig fetch` of a local directory copies the working tree rather than the
  index, so listing a gitignored fixtures directory swept whatever media a
  developer had locally into the package.
- The release job runs the same analysis gate as `make lint` before it builds
  anything. A tag is published with no merge gate in between, so a release cut
  from a commit the CI gate refused, or re-run after a linter moved, could
  publish a tree the merge gate says is not shippable. The ruff and yamllint
  versions are read from the Makefile rather than repeated in the workflow.
- `make lint` lints `.github` rather than `.github/workflows`, so the dependabot
  config is checked beside the workflows it steers.
- The event-system completion sweep is a single pass over the live instances.
  `MilesGetEventSystemState` took the count of still-playing instances from
  the sweep rather than walking the list a second time, and
  `MilesEnumerateSoundInstances` expires each instance as it visits it against
  one clock reading rather than sweeping in a pass of its own, so a game
  polling state per frame over a few hundred live instances no longer reads the
  clock twice and sweeps the list twice per poll. Every instance is still
  visited and expired on every call, so a walk handed out in one call and
  resumed in the next sees the same statuses the separate sweep left behind.
- uv, which installs the two linters, is pinned to a `UV_VERSION` in the
  Makefile. `ci.yml` repeated a version of its own and `release.yml` repeated
  it a second time, and nothing compared the two, so a bump in one left the
  other installing a different installer. `scripts/check_toolchain_pins.py`
  now holds `ci.yml` to the Makefile and holds `release.yml` to reading it.

### Fixed

- 46 of the 192 `file:line anchor` references in `docs/THREAT_MODEL.md` named
  a line the anchor had moved off, so `scripts/check_threat_model_refs.py` and
  with it `make lint` and CI failed. Every one was re-anchored to the line its
  anchor now sits on, and `MilesAddSoundBank` (which moved without a uniform
  file shift) was re-aimed by hand.
- The first close of a digital driver tore the device down even when a second
  open was still outstanding. Opens are counted (`AIL_open_digital_driver` and
  `AIL_waveOutOpen` are two names for the one process-wide device), but the
  close path destroyed the driver instead of dropping one open, so a game
  holding the handle through both names lost its audio device, its mixer and
  its source list, and every later call through the surviving handle ran
  against a freed engine. The claim that guards against a repeated close now
  moves the open count and keeps the driver in the table an open still refers
  to; the device goes away with the last close, so a close of a handle the
  table no longer names is still ignored.
- Loading, unloading, or replacing a SoundFont could deadlock the process
  against its own audio thread. The swap published the replacement and then
  spun on the render-claim count while holding the driver lock, so a render
  inside a game callback that called back into a load blocked on that lock, and
  neither thread moved again. The publish now happens under the lock and the
  wait runs with it released, the wait is bounded
  (`MidiDriver.swap_wait_budget_ms`), and a bank the bound expires on is held
  back for the next swap rather than freed under a live render.
- The driver's SoundFont pointer was read as a plain field on the audio thread
  while a game thread wrote it, and the API entry points that call into the bank
  (`AIL_channel_notes`, `AIL_controller_value`, the channel-voice and sysex
  senders, `AIL_register_ICA_array`, `AIL_set_XMIDI_master_volume`) took no
  claim on it, so a concurrent swap could close the bank between the read and
  the call. The pointer is read through `MidiDriver.currentSoundfont()`, and
  those entry points claim the bank for the duration of the call. A newly
  loaded bank is given its output format before it is published rather than
  after, so no render can read a half-configured one.
- The debug log read its enabled flag, its configuration source, and the log
  path as plain globals from any thread that logged, while `init()` was writing
  them. The flag is read and written atomically, and the configuration record is
  rendered under the lock `init()` holds, so a record cannot name a path that is
  being overwritten.
- `AIL_close_digital_driver` tore the device down on the first close instead of
  the last. Opens are counted, and a second open through `AIL_open_digital_driver`
  or `AIL_waveOutOpen` takes a reference on the driver the first one built, but
  the close path ignored the count and destroyed the engine unconditionally. A
  game that opened the device through both names and closed it through either
  was left holding a handle to an uninitialised engine over freed memory, and
  its second close was reported as a close of a driver that was already gone. The
  close now drops one open and tears the device down only when it drops the
  last, leaving a driver another open still owns published and tracked.
- The release archive shipped `deps/SHA256SUMS` and `SBOM.cdx.json` without the
  vendored headers those records describe. Unpacking it and running
  `sha256sum -c deps/SHA256SUMS` failed on all five entries, and the SBOM's
  component digests resolved to nothing, so the archive's own verification
  records were decoration. The headers now ship beside them, which is what the
  README already told a consumer the archive was for.
- `make check-release-archive` (part of `make lint`, and so of both CI and the
  release job's gate) asserts the archive carries every file `deps/SHA256SUMS`
  records and every file the shipped docs link, reading the entry list back out
  of `package_release.sh`. The packager stages what its list names and never
  looked at what those files point at, so a header vendored or a doc written
  after the list was last edited produced an archive nobody noticed was
  incomplete until a consumer hit it.
- `AIL_open_soundbank`'s optional name check compared the caller's whole string
  against the bank's four-byte `SoundBankName` field. A name the field spells
  but that is longer than the field, or that the field's own read-back is
  shorter than because a character was cut in half (`"café"` stored as `caf`
  plus a lead byte), reported "Bank name mismatch" and refused a bank that was
  the one asked for. The compare now runs over the field's width.
- A plugin file whose stem ended in a space (`con .asi`, `com1 .m3d`) passed
  the plugin filename check, because the device name was matched against the
  untrimmed stem. The path parser strips the space before it resolves the name,
  so the entry the scan listed resolved to the device, not to a file. The stem
  is trimmed the same way before the device name is matched.
- A log record that was not valid UTF-8 (a caller-supplied path, a plugin RIB
  name, or a bank asset name spelled in a legacy code page) reached the file
  sink and was dropped whole by `OutputDebugStringW`, so the two sinks
  disagreed about what was logged. The debug stream now gets the record up to
  the first byte that is not a character.
- `zig build -Dtarget=x86-windows` did not compile. `MilesEnumerateSoundInstances`
  carries the instance id it is walking through the caller's `io_next` pointer
  and built that pointer from the 64-bit id, which a 32-bit target rejects, so
  the shipped DLL, the CI cross-compile step and `make cross` all failed. The
  id now travels through the target's address space, which the read on the way
  back in already assumed.
- `scripts/package_release.sh` accepted a `SOURCE_DATE_EPOCH` up to 9999 and
  stamped an archive no tool could reproduce. A zip entry's timestamp is 7 bits
  of years past 1980, so a later epoch is not clamped to the top of the range
  but wrapped: an entry asked to carry 9999-12-31 comes back out of the archive
  reading 2064. The accepted range now ends where the format does,
  2107-12-31T23:59:58Z. The BSD timestamp path also formatted a two-digit year,
  so on a host without `touch -d` any epoch past 2068 was stamped 1999 and
  produced an archive that differed from the one the GNU path built for the
  same input; it now stamps the four-digit year both touches accept.
- `make harnesses` named `./native_rib_test` on every Windows POSIX shell.
  The `.exe` suffix was resolved from a `findstring` that matched only the
  `MINGW` family, so Cygwin and an MSYS2 `msys` shell ran a name the build
  never installed. All four Windows families are matched now.
- `DigitalDriver.init` assigned to a field the struct no longer has, so the
  whole test suite stopped compiling. The first-serve baseline it was writing
  is taken by `serve` itself, which is where the nanosecond reading and the
  "already served" flag it belongs to now live.
- A temporary directory that was accepted and then turned out to be unusable
  (the platform resolves none, it leaves no room for the image name under the
  path limit, or the image cannot be written there) was reported only through
  the debug log, which is off unless the operator turned it on. Every one of
  them ends with the ASI image unpacked into the game directory, so an operator
  with a wrong `TMPDIR` learned nothing. They now go to stderr, as a rejected
  `TMPDIR` already did.
- `AIL_serve` integrated the process uptime into the first frame it advanced an
  auto-updated 3D source, because the previous-frame reading started at zero
  rather than at the driver's first serve. A host up for a day moved every
  moving source by `velocity * 86_400_000` on the driver's first tick. The first
  serve now only takes its reading, and the delta is carried in nanoseconds, so
  a frame shorter than a millisecond (a 240 Hz game loop) advances the source
  instead of truncating to no time at all.
- `AIL_set_sample_playback_delay` scheduled the voice from a whole-millisecond
  reading of the engine's PCM counter and converted it back to frames, which
  rounds the start point down to a millisecond (44 frames at 44.1 kHz) and can
  land it in the past, where the voice plays at once instead of waiting. The
  delay is now added to the engine's frame counter directly.
- `docs/THREAT_MODEL.md` named 48 file:line anchors that no longer sit on the
  line they point at, so `scripts/check_threat_model_refs.py` failed and
  `make lint` was red. Every reference now resolves; each was re-pointed at the
  code it describes rather than at the nearest line carrying the same name.
- On Windows, an `OPENMILES_DEBUG` set to the empty string, longer than the
  value buffer, or not valid UTF-8 was ignored without a word, where the other
  systems report it. `GetEnvironmentVariableW` returns 0 both for a variable
  that does not exist and for one set to nothing, and the two were read the
  same way, so an exported-but-empty setting left the build default in place
  silently. Both variables now classify the read the same way on every
  platform, and a rejected value that is too long to be worth echoing is
  reported by reason rather than by value.
- Forty-four further `file:line` anchors in `docs/THREAT_MODEL.md` that no
  longer resolved, which failed `make check-threat-model` and with it
  `make lint`.
- Four `file:line` references in `docs/THREAT_MODEL.md` pointed two lines above
  the code they claim, so `make lint` failed on a clean tree and the mitigation
  claims behind them were no longer checkable.
- The release workflow held a write token for every step in the job, and
  refused to overwrite a published release only on a manual re-run. The
  workflow token is now read-only for the job and granted write to the
  release-creation step alone, and the immutability check runs on a tag push
  too, so a re-pushed tag cannot replace the archive and `SHA256SUMS` a
  consumer already fetched.
- Sixteen `file:line` anchors in `docs/THREAT_MODEL.md` that no longer
  resolved, which failed `make check-threat-model` and with it `make lint` and
  the CI lint step. The anchors are refreshed to the lines the named code now
  sits on.
- `AIL_open_ASI_provider` loading a second copy of a module already open from
  the same image. Every other load path dedups on identity (a resolved plugin
  path, a soundbank file, a soundfont); this one had none, so a retried open
  wrote a second temp image, loaded a second copy, and answered provider
  queries through both until the process ended. The image's content is now the
  identity, a repeat open is answered with the module already loaded, and N
  opens need N closes: the module is unloaded and its temp image deleted by the
  last `AIL_close_ASI_provider`.
- Three claims in `docs/` that the code contradicts. `docs/EXPORT_PARITY.md`
  put the 6.5/6.6-only exclusion pair in the same ver 65-66 group as the ten
  other functions added in that pass; `src/main.zig` gates
  `AIL_set_3D_sample_exclusion` and `AIL_3D_sample_exclusion` at ver 61-66,
  because they first appear in the 6.1d patch. Both files also said the
  `never_export` wrappers stay reachable from the project's C harnesses; they
  are not, since those harnesses resolve entry points by name through
  `GetProcAddress` and `LOAD_FUNC_EX` aborts on a name the DLL does not export.
  `tests/midi_test.c`, `tests/full_suite.c`, and `tests/rib_test.c` name four of
  them, and named the v6.1 to v7.0 sequence surface as a requirement, so none of
  the three ran against a v8 or v9 build. A name no Miles release exported now
  loads optionally: the harnesses report it, skip the part that needs it, and
  exit 0, so a build without the sequence surface is a skip rather than a
  failure and `rib_test` still runs its provider scan.
- `AIL_send_channel_voice_message` sends the full 14-bit pitch bend (8192 centre). It masked the high byte to 6 bits, so a wheel at centre or full up reached the soundfont as a bend down.
- `AIL_resume_sample` on a sample that had finished clears SMP_DONE. The voice played again while its status still read done, so a game polling status saw a finished voice.
- `AIL_load_sample_buffer` reports a buffer that was refused (the slot still held an unsubmitted one) as -1 with the reason in `AIL_last_error`, and fires no SOB, instead of returning the slot as loaded. A null buffer ends the stream on a streaming sample and is refused on a whole-image one.
- `AIL_update_3D_position` advances a source whether or not automatic updating is on. A v6.1+ game that only called it never moved its source, while the v5 spelling of the same call did.
- `AIL_3D_provider_attribute` and `AIL_set_3D_provider_preference` resolve the open digital driver instead of casting the provider handle to one. An enumerated `HPROVIDER` is a RIB provider, so the pair read and wrote past the end of it.
- `AIL_set_3D_sample_preference` for "Minimum distance" and "Maximum distance" applies the SDK's min <= max swap, as `AIL_set_3D_sample_distances` does. Writing the field alone could leave the pair in the order the spatializer leaves undefined.
- `MilesAddSoundBank` accepts a name that differs from the bank's and drops it, as `mss.h` says, instead of failing the load with "Bank name mismatch".
- `AIL_set_input_state` returns 1 for a disable it carried out. It reported the state reached, which is 0, so a successful stop read as a failure.
- `AIL_open_ASI_provider` writes the plugin image to the game directory when the temp directory cannot hold it (unwritable, not a directory), instead of retrying the same absolute path and failing.
- `AIL_file_size` sets the file error when the app installed only part of the callback set, so a 0 can be told from a zero-length file.
- `AIL_DLS_close` stops the sequences allocated on the device before the driver they read through is destroyed.
- A soundfont loaded from memory renders at the open device's rate, as the file path does. It was fixed at 44100, so a 22050 Hz device played it an octave down.
- `AIL_redbook_play` takes millisecond offsets: `AIL_redbook_position` counts from the offset given, and `AIL_redbook_track` (a track number on a drive with no disc) stays 0 instead of reporting the offset as a track.
- `openmiles.clock.advance` ignores a negative step, as its contract says. A rewind put virtual time below the epoch, where every elapsed counter reads 0.
- A limits string naming the same label twice keeps the last count and no longer leaks the duplicate key.
- `tests/test_utils.h` declared `AIL_startup` as returning `void` while
  `mss.h` and the implementation both return `S32`, so the harness's view of
  the ABI disagreed with the one a consumer compiles against. `full_suite.c`
  now checks the startup result rather than discarding it.
- A soundfont loaded through the file callbacks is no longer keyed to the buffer the callback read it into. That buffer is released when `AIL_DLS_load_file` returns, so the next image the allocator handed out at the same address, with a size its header matched, was answered with the earlier bank instead of being loaded.
- `DLSUnloadAll` reports no size for a bank it has released. `AIL_DLS_get_info` answers with the size unconditionally, so a released bank kept reporting the length of an image it no longer held.
- A bank name that does not fit `SoundBankName[4]` keeps whole characters. The 4-byte field cut a name like `café` mid-character, and `AIL_open_soundbank` matches the result against the name the game asked for.
- The log neutralizes the C1 controls, the bidi embedding and override characters, the isolates, and the zero-width and BOM characters in a path, VFS name, or error string. A name carrying U+009B moved the cursor as one carrying ESC does, and U+202E rendered reversed in whatever reads the log.
- A GM/GS/XG reset SysEx names the channel and the controller of a reset control the soundfont could not apply. A rejected one leaves that channel half reset, with voices still sounding and the old volume and pan in place.
- A plugin module that opens but exports no `RIB_Main` is named in the log. The scan counted it and the provider was adopted, so every interface query answered absent with nothing saying why.
- The remaining `docs/THREAT_MODEL.md` anchors, the ones a commit since 0.2.0 moved, resolve again. `make check-threat-model`, and with it `make lint` and the release job's gate, was failing on a tree the changelog above says is clean.
- Two `file:line` anchors in the event-bytecode row of `docs/THREAT_MODEL.md`
  had drifted with the event decoder. The `nextStep` anchor no longer sat on the
  line that declares it, and the `copyString` anchor resolved only because a doc
  comment names the function, which is the false pass the check's own docstring
  warns about. Both now point at the definitions.
- The release-archive section of `README.md` described the archive as the DLL,
  the license, the README, the changelog, and the vendored attribution. It has
  also carried `mss.h` and `SBOM.cdx.json` since the header started shipping, so
  a reader had no way to learn from it that the archive holds the header they
  compile against.
- The Miles event-system registries were unguarded. The instance list, the id
  counter, the sound cache, the persists, the label limits and the system list
  are all process-global and all reachable from a Miles entry point, which a game
  may call from any thread, and none of the containers was safe under that
  split: an `ArrayListUnmanaged` append and a `StringHashMap` put each write a
  length and a capacity beside the storage they point at, so two threads in one
  list corrupt the heap rather than merely losing an entry; the id counter is a
  read-modify-write, so two instances took the same id and the resumable
  enumerate walk skipped and repeated entries; the system list walk read a
  half-linked list and handed back a freed system. One lock covers all of it,
  held outermost, since the leaf bank lookups take soundbank's registry lock and
  that file never calls back here. `MilesStartupEventSystem` now publishes
  under it, so two threads starting a system cannot both install one and strand
  the loser's handle where the shutdown walk cannot reach it.
- `RIB_type_string` and the v8 `AIL_ftoa` returned a pointer to a process-global
  buffer, so a game reading the string on one thread while another formatted a
  value had its characters rewritten mid-read. Both buffers are per-thread now,
  which keeps the SDK's own last-call-wins contract and stops the two threads
  from sharing it.
- `AIL_shutdown` closed one MIDI driver. Every `MidiDriver.init` took the same
  "current driver" slot, so the second device a game opened (`AIL_DLS_open`, a
  wave synthesizer) displaced the one it opened first and only the slot was
  reachable at teardown. The displaced driver kept its allocation, its soundfont
  and its sequences for the life of the process. Every live MIDI driver is
  tracked and closed at shutdown, as the digital table already was.
- `MilesShutdownEventSystem` cleared the instance list retaining its capacity,
  which handed the backing array to nobody: every session that started a sound
  leaked it. The list is returned to the allocator that grew it, and left as the
  empty slice the enumeration and the label eviction need rather than the
  undefined pointer `deinit` leaves.
- Every open failure reported "File not found", so an operator hunting a
  permission denial, a host-rejected name, or a path that is a directory was
  sent after a file that was there all along. `AIL_file_error` now names the
  cases a caller can act on, and carries the error name for the rest rather than
  folding them into absence.
- A failed audio-node attach was ignored, so the bus was silenced or the sample
  left dry while every later query reported the effect as installed and running.
  A `MixBus` slot whose node cannot take the bus's output is unlinked, the node
  destroyed and the slot left empty, and a `Sample.setReverb` whose delay node
  cannot be wired puts the sound back on the endpoint and drops the node. The
  queries read an empty slot as "effect off", which is now the truth.
- `Filter.setCutoff` and the "Order" attribute recorded the new value and left
  the LPF node on the old configuration when the rewire failed, so every later
  read reported a filter that was not in effect. Both keep the previous value and
  name the refusal in the log.
- `AIL_set_redist_directory` measured its path against a byte budget of 256 and
  refused anything longer. The SDK's buffer holds MAX_PATH, and one UTF-16 unit
  spells up to three UTF-8 bytes, so 200 CJK characters is 200 units and 600
  bytes: a path half the Windows limit long was reported as too long, the
  previous directory was kept, and no plugin was loaded. The bound is now
  MAX_PATH in UTF-16 units, with the store sized to hold it.
- `AIL_set_sample_playback_delay` scheduled the voice from the miniaudio engine
  counter, which the audio thread advances on wall time. Under a virtual clock
  that is the one playback deadline a step sequence cannot reproduce, since the
  same steps placed the voice at a different point on every run. The stepped
  library clock is read instead, counted from the first reading, so the frames
  a delay is added to are a function of the steps alone.
- Thirty-two `file:line` anchors in `docs/THREAT_MODEL.md` were stale again,
  and the threat-model check was failing `make lint` and with it the release
  job's gate. The shift that accounts for each file's references is re-applied
  and the remaining `MilesAddSoundBank` anchor, which the shift did not account
  for, points at the definition rather than at a call site that names it.

## [0.2.0] - 2026-09-28

CI and test fixes that landed after 0.1.0, plus the GitHub Actions bumps merged with them.

### Changed

- The Ubuntu CI job installs uv 0.12.19 before ruff and yamllint. The runner image has pipx and not uv, so the lint gate exited 127 before any check ran.
- The release workflow reads the changelog section by version prefix, so a heading with a date (`## [0.2.0] - 2026-09-28`) is the notes that ship. Matching the whole line against `## [v0.2.0]` published an empty body.
- `actions/checkout` is 7.0.1, `actions/cache` is 6.1.0, and `softprops/action-gh-release` is 3.0.3.

### Fixed

- The fuzz-all export sweep runs on a virtual clock, bounds the locked allocations it requests, and closes the driver `AIL_waveOutOpen` builds each round. On Windows those leaks exhausted the process commit charge and killed the test with no assertion.
- The timer self-stop test waits until `is_running` is clear before it restarts the timer. Restarting on the first fire could beat `stop()` and leave the timer stopped.
- The configured TMPDIR test expects the platform path separator, so a Windows run checks a trailing backslash instead of a hardcoded slash.

## [0.1.0] - 2026-09-27

First tagged release. While the version is `0.x`, a minor bump may carry a
behavioural change. The export table, not this version, is the compatibility
contract.

### Fixed

- `OPENMILES_LOG_PATH` chooses the debug log file, absolute or relative to the
  current directory. Unset, empty, or longer than 1024 bytes keeps
  `openmiles.log` in the current directory and says so. The log's first line
  names the path that was opened.
- `SOURCE_DATE_EPOCH` outside the range a zip entry can record
  (1980-01-01 through 9999-12-31), or not a non-negative integer, fails
  `scripts/package_release.sh` instead of clamping the stamp or reporting
  `invalid date`.
- `AIL_startup`'s use count and the decision that the last `AIL_shutdown`
  tears the engine down are one compare-exchange. Two threads shutting down
  the last use both used to pass the check and both run teardown.
- Sample EOS, EOB, and SOB callbacks are swapped atomically. The pointer a
  register call returns is the one it replaced, including when the audio
  thread is firing the previous callback.
- The four file VFS callbacks are installed and copied as one set. A load
  cannot open a file with one VFS and read or close it with the next set a
  concurrent `AIL_set_file_callbacks` installed.
- Replacing a soundfont publishes the new bank, waits until in-flight renders
  release the claim they took, and only then closes the bank it displaced.
- An XMIDI FOR/NEXT whose body never advances the clock stops after 256 jumps
  in one buffer. A count of 0 whose next message is the matching NEXT used to
  re-dispatch that NEXT forever, because a jump costs no frames.
- A RIB interface entry keeps the type and subtype it was registered with.
  `RIB_request_interface_entry` misses when the caller asks for the other
  type, and `RIB_enumerate_interface` reports the stored type and subtype
  instead of echoing the caller's filter and a subtype of 0.
- The per-sample falloff graphs are sized from `FalloffKind`, so adding a
  kind widens the arrays instead of writing past the last one.
- `AIL_set_redist_directory` stored a path longer than its 255-byte buffer
  truncated to that buffer, and then scanned the truncated prefix for `.asi`,
  `.m3d`, and `.flt` images to load and execute. A byte prefix of a long path is
  usually a different real directory, most often a parent of the intended one,
  so an over-long install path silently moved the plugin search somewhere the
  game and the operator never named. A path that does not fit is now refused:
  the previous directory stays, no plugins are loaded, and the refusal is
  reported on stderr. Paths that fit behave exactly as before.
- `AIL_WAV_info` and every `AIL_file_type` that inspects a WAV header computed
  the chunk-walk end as `riff_size + 8` without saturating, on a size read from
  four file-controlled bytes. On the 32-bit target `usize` is `u32`, so a file
  declaring a 0xffffffff RIFF body trapped the host process from a 12-byte
  header; the add now saturates and clamps to the known buffer length, matching
  the three sibling size computations in the same file.
- The event name-list bound in `AIL_next_event_step` summed the scratch
  cursor, the pointer array, and the field length without saturating. A
  bank-supplied string large enough to wrap the sum on the 32-bit target would
  pass the check and write outside the caller's scratch buffer. The chain now
  saturates, so a wrapped sum fails the bound instead of passing it.
- `AIL_set_sample_playback_delay` stored its value and read it back, and no
  start ever applied it, so a game that staggered sounds by a few hundred
  milliseconds heard them all at once. The delay is a sample attribute, so
  every `AIL_start_sample` now schedules the voice for `now + delay` on the
  engine's own clock (`DigitalDriver.engineTimeMs`, a mixer-millisecond reading
  of the engine PCM counter, so a system-time step cannot move it).
  `AIL_schedule_start_sample`, called after the start, still overrides with its
  absolute point. Before, `AIL_set_sample_playback_delay` followed by
  `AIL_start_sample` started the voice immediately; after, it starts once the
  delay has elapsed, which is what the SDK documents.
- `AIL_stream_info` reported a hardcoded `44100 * 2 * 2` datarate and a
  `DIG_F` value of 3 for any stream with no decoder attached, whatever the
  driver was actually opened at. A driver at 22050 described its streams as
  carrying twice the data they did, and a caller sizing a buffer from the
  datarate over-ran by that factor. The reported rate and `sndtype` now come
  from the driver's own sample rate and channel count (mono reports `1`,
  stereo and wider `3`), falling back to 44100 / 2 only when the driver reports
  neither.
- A NaN level or cone argument reached the spatializer. `AIL_set_3D_sample_cone`
  and the `AIL_set_3D_sample_preference` "Cone inner/outer angle" attributes
  stored NaN directly, `applyCone` handed it on, and the matching getter handed
  it back to the app. A NaN angle now leaves the stored (omnidirectional) cone
  alone, the same fail-safe the volume entry points use. `AIL_set_sample_51_volume_levels`
  clamped NaN to its upper bound, so a garbage level pair came out at full
  volume; it is silence now.
- `AIL_list_DLS` scanned the whole size the DLS header declares, and the ABI
  gives it a length-less pointer, so a header claiming more than it holds was
  read past the caller's buffer. The `colh` chunk a listing actually needs sits
  in the first few hundred bytes of any well-formed bank, so the scan is bounded
  to a 64 KiB prefix. The declared size is still what the function reports to the
  caller; only the scan window changed.
- The EVNT-to-SMF conversion reserved its event list straight from the chunk
  length. An EVNT chunk is file-controlled and the whole-file load cap still
  admits a 256 MiB image, which that ratio turned into a multi-gigabyte
  reservation that failed and aborted the load of a file that would otherwise
  convert. The reservation is capped at 64k events and the list grows on demand
  past that, as it already did whenever the estimate ran short.
- The debug log dropped records two ways. A record longer than the 1 KiB
  formatting buffer was discarded silently, and a write that failed was
  discarded silently, leaving the file as the only record of what the process
  did with no note that it had stopped. An oversized record now becomes a
  marker naming the failure and the format string, and a failing write is
  reported once on the console and leaves the handle in place. A log file whose
  length cannot be read is no longer appended to at all: records are written
  positionally from a known offset, so an offset of 0 overwrote the history
  that was already there and the run looked as if it had succeeded. That case
  now logs to the console only and says so.
- `AIL_load_sample_buffer` reported a rejected buffer as an ordinary failure. A
  whole-image load that failed returned -1 with `AIL_last_error` untouched, so a
  game checking the error saw a stale message or none. Both the ping-pong feed
  and the whole-image path now set `AIL_last_error` naming the buffer number and
  the reason.
- Resolving an event's step bytecode by name returned bytes owned by a soundbank
  that a concurrent `MilesReleaseSoundBank` could free under the caller still
  walking them, because the registry lock does not keep the bank alive past the
  lookup. `containerFindEventOwned` takes the reference under the same lock that
  resolves the name and hands back the bank to drop when the walk is done; the
  borrowing `containerFindEvent` stays for callers that already hold a reference.
- `openDigitalDriver` fell back to the shared redist path buffer when its private
  copy could not be allocated, and scanned from it, which is the race the copy
  existed to avoid. The snapshot is taken under the lock or not at all: a failed
  allocation now leaves the driver open with no plugin scan, and says so in the
  log. `openmiles.getRedistDirectoryCopy` is that snapshot for a caller that
  needs to hold the path.
- Both plugin scans held one path copy per plugin for the whole scan, because a
  `defer` in the loop body is scoped to the function, not the iteration. The body
  is scoped now, so a directory of N plugins holds one path at a time.
- `scripts/check_all_versions.sh` let the build's own chatter land on stdout
  between the rows of the machine-readable table it documents, and printed its
  unswept versions in whatever order bash's associative array happened to iterate
  them, so the report changed between runs. Build output goes to stderr and the
  unswept list is sorted by version.
- `scripts/check_exports.py` returned 2 for a reference DLL that could not be
  read, which is the same code a bad command line returns, so a broken reference
  read as a typo in the invocation. An unreadable or non-PE DLL is now 1, as the
  sibling gates report a check that could not run, and 2 stays a bad invocation.
- `openmiles.startup()` claimed the startup provider with an atomic load
  followed by a store, which is not one step. A game that called `AIL_startup`
  (or `AIL_quick_startup`) from a worker thread while its main thread did the
  same could have both calls read "no provider", build one each, and have the
  second store overwrite the first: the losing provider was unreachable from
  then on, so its interfaces and name stayed allocated for the life of the
  process while `AIL_shutdown` freed only the winner. The claim is made under a
  lock now, so the second call finds the published provider and returns.
  `openmiles.shutdown()` deliberately stays outside that lock: it joins the
  timer threads, and a timer callback is free to call `AIL_startup`, so holding
  the lock across the joins would deadlock that game.
- A plugin file whose name Windows resolves to a device rather than a file was
  scanned and loaded: `isSafePluginFilename` rejected `..`, `/` and `\` but
  accepted `NUL.asi`, `COM1.asi` and friends, which DOS and Windows resolve to
  the device, `decoder.asi:payload`, an NTFS named stream, and a name with a
  trailing dot or space, which the filesystem drops before storing it. Under
  Wine the game directory is a POSIX path, so such an entry is a real file that
  the scan lists and the loader then resolves to something else. The name check
  rejects all of them now.
- The ASI image was written under `%TEMP%` whatever the path length that made.
  `GetTempPathW` returns a directory of up to 259 units and the fixed file name
  adds more, and Windows opens a path over `MAX_PATH` only with the long-path
  opt-in, so a deep `%TEMP%` produced a path no create call could open and the
  provider failed to load. The temp directory is now used only while the
  composed path fits the platform's unit limit, and the game directory is the
  fallback, the same one a machine with no `TMPDIR` already got. The limit is
  measured in UTF-16 units, so a `%TEMP%` holding a non-ASCII character is not
  rejected for spending more bytes than it spends units.
- The 32-bit build that ships, `zig build -Dtarget=x86-windows`, did not
  compile: the per-provider interface handle counter was a `u64` assigned to a
  `usize` handle, which the x86 target cannot hold. The counter is pointer-sized
  now, and a counter that has run out of handles fails the registration instead
  of wrapping into a handle an earlier interface already had.
- `rib_register_interface` unwrapped a null interface on the error path, so a
  plugin that failed to register (a negative entry count, a null entry array, an
  OOM) crashed the host instead of being told 0. It returns 0, and
  `Provider.registerInterface` returns the interface it stored rather than an
  optional that is never null.
- Loading a sequence over a stopped one left it reporting `SEQ_STOPPED`; the
  load path cleared the playing, paused and done flags but not the stopped one.
  A reload now reports `SEQ_DONE`, as a fresh `init_sequence` does.
- The unregister callback a plugin is handed at `RIB_Main` did nothing:
  `rib_unregister_interface` discarded its handle, and `rib_register_interface`
  returned 0 or 1 rather than an interface handle, so a plugin that dropped an
  interface at shutdown left every one of its entries in the provider registry.
  `RIB_request_interface` and `AIL_ASI_provider_attribute` then resolved tokens
  for an interface the module had already torn down. `RIB_register_interface`
  now returns the handle of the interface it stored, and the callback removes
  exactly that interface. Handles come from a per-provider counter that never
  reuses a value, so a handle a plugin still holds cannot name a later
  registration. The host-side `RIB_unregister_interface(provider, name, ...)`
  export is unchanged.
- `docs/THREAT_MODEL.md`: the `path:line anchor` references had drifted off the
  lines they name, so `make check-threat-model` failed and took `make lint` and
  `make check` with it. The ASI temp-file controls now point at the entropy
  draw and the exclusive create as they are written today, and the
  plugin-scanning references at the current `loadApplicationProviders` and
  `loadAllAsi` call sites. The WAV write path, the sample loader and the mixer
  cap had drifted the same way; they now point at `AIL_WAV_file_write`,
  `createFile`, `max_mix_operations`, `Sample.loadFromFile`, `Sample.load` and
  the `root.max_file_load_bytes` check as they are written today.
- `make lint`: the gate ran `zig fmt --check` from whatever zig was on PATH,
  while `build` and `test` refused to run against anything but the version in
  `build.zig.zon`. A local format check now runs against the pinned toolchain
  too, so a green run means what CI's green run means.

### Breaking

- `Provider.init` takes only the allocator. It previously took a second
  `module: ?*anyopaque` argument and discarded it (`_ = module`), so a Zig
  caller passes one argument now instead of two. No `Provider` field changes,
  and the C export `RIB_alloc_provider_handle(module)` still takes the module
  pointer, so `mss32.dll`'s export table and every C consumer are unaffected.
  Both breaks in this release are Zig-only.
- `Provider.registerInterface` returns `!?*Interface`: the interface it
  stored, or null when the plugin's arguments were rejected. A Zig caller that
  discards the result needs an explicit `_ =`. The handle that comes with it is
  what the plugin's unregister callback takes, so this is how a caller reaches
  that path.

### Added

- `scripts/gen_sbom.py` checks each vendored header's license against the
  project's GPL-3.0-only grant instead of only recording it. Those headers are
  compiled into the shipped DLL, so a grant the project cannot redistribute
  under GPL is a compliance failure, and without the check it would reach the
  inventory looking like any other entry. `make check-sbom` fails on one.
- Fuzz coverage for the Miles event enqueue and the state it owns, in
  `src/fuzz_native_test.zig`: the fuzzer drives the shipped event constructor
  and then reads back the enqueued instances, the persisted count, and the cache
  bookkeeping, so a step that is accepted but not retained fails the run.

- `zig build test -Dsanitize`, `make sanitize`: the test suite with every C
  translation unit instrumented by the undefined-behaviour sanitizer. Zig's own
  safety checks are already on in the Debug build the plain suite uses; this
  adds the UB the bindings and the vendored `tsf.h` / `miniaudio.h` code can
  hit, which nothing in the tree looked for. `-Dsanitize` forces Debug, since
  the sanitizer reports against the safety checks and the debug info. CI runs
  it as its own step on the Linux leg, and `make check` includes it.

- C sources compile with the correctness and portability warning groups the
  tree already passes, on top of `-Wall -Wextra -Werror`: `-Wpedantic`,
  `-Wshadow`, `-Wstrict-prototypes`, `-Wold-style-definition`, `-Wvla`,
  `-Wformat=2` and `-Wwrite-strings`. Three counter-flags keep the vendored
  headers from failing the build, each for vendored code only: `tml.h` declares
  an anonymous union, `miniaudio.h` passes a format string through a parameter,
  and `tsf.h` computes member offsets from a null pointer.
- `make check-pins` fails when the C warning set in `scripts/check_header.py`
  drifts from `c_flags` in `build.zig`, so the header gate cannot compile
  `mss.h` under a weaker set than the one the build uses.
- `zig build` rejects a `-Dtest-filter` that names no test before it compiles
  anything, instead of running zero tests and exiting 0. The check used to live
  only in the `make test` recipe, so `zig build test -Dtest-filter=typo`
  reported a green run that had tested nothing.
- ruff's `BLE`, `PGH`, `SLF` and `T10` groups are selected in `ruff.toml`, so
  the gate scripts are checked for a swallowed `except`, a bare `# noqa` that
  silences every rule on the line, a reach into another object's private
  member, and a leftover breakpoint.
- ruff's `FLY` group is selected in `ruff.toml`, so a string join or an
  f-string with nothing to interpolate in it is caught as the runtime work it
  asks for on every call.
- `make check-pins` also fails when the C warning set in
  `scripts/check_examples.py` drifts from `c_flags` in `build.zig`, so a
  documentation snippet cannot compile under a weaker set than the build and
  the header gate use.
- `ruff.toml`'s `target-version` is `py310`, the floor the scripts actually
  need: `check_vendored.py` annotates a `NamedTuple` field as `str | None`,
  which a class body evaluates on import, so 3.9 raises `TypeError`. It read
  `py38`, so ruff was applying 3.8 rules to code that cannot run on 3.8.
  `make check-pins` fails when the interpreter running the gates is below the
  floor `ruff.toml` declares, which otherwise surfaces halfway through a gate
  as a `TypeError` with the sweep unrun.
- The file:line references in `docs/THREAT_MODEL.md` were stale: the functions
  and call sites they name had moved, so the controls the model reports as
  mitigated pointed at lines that no longer carry them. The anchors now resolve,
  which is what `make check-threat-model` asserts.
- `SBOM.cdx.json`: a CycloneDX inventory of the third-party code a release
  carries, generated by `scripts/gen_sbom.py` from `deps/README.md`,
  `deps/SHA256SUMS`, `scripts/requirements.txt`, and `build.zig.zon`, and
  shipped inside the release archive next to the attribution and digests.
  `make check-sbom` regenerates it and fails when the committed file no longer
  matches the tree, so a header swap or a pip bump cannot publish a stale
  inventory. Every component names the upstream package (`TinyMidiLoader`, not
  `tml.h`), which is what a CVE database matches on.
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
- `AIL_last_error` and `AIL_file_error` hand back a raw pointer into a buffer any other thread may be rewriting. The writers are now serialized under `error_buf_mutex`, so two threads can no longer splice their messages together or leave one unterminated, but the pointer a caller holds is still into the live buffer and is not stable across a later `setLastError`.
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
- `scripts/requirements.txt` pins the one third-party Python package the
  gates need, `pefile`, which `scripts/check_exports.py` imports to read a
  reference DLL's export table. `make parity` checked for it up front and
  named the install command, and `CONTRIBUTING.md` documents it as the single
  exception to "nothing else is fetched": `make lint` and CI still need
  nothing beyond the standard library.
- The release archive and its checksum file, `*.zip` and `release/`, are
  ignored. `scripts/package_release.sh` writes both into the tree it runs in,
  and the release workflow publishes them, so a local run no longer leaves an
  artifact that can be committed by accident.
- The release workflow refuses a `workflow_dispatch` re-run of a tag that
  already has a release, so a retry after a failed run cannot republish over an
  archive a consumer has already fetched. A published version is republished
  only as a new version.

### Fixed

- A second `AIL_DLS_load_file` or `AIL_DLS_load_memory` of the source already
  loaded closed the bank the game was still holding and returned a second copy
  of it, so a retried load left one dangling handle per repeat. A load naming
  the bank already in place keeps it and returns that same handle, and the
  loads it took are counted: N loads of one bank need N unloads before it
  closes, so the state after load, load, unload, unload is the state one load
  and one unload left. A game that loaded a bank and then reloaded the same
  file and unloaded once no longer has a valid bank.
- `AIL_process_digital_audio` freed an exhausted source's decode buffer only
  when the source stayed in the stereo or mono partition. A mix call that
  outran the shortest source dropped it from the partition first, so its owned
  buffer was never freed and leaked on every such call.
- Reloading a sample leaked its reverb node: only `Sample.deinit` released it,
  so a game that gave a sample reverb and then reloaded the stream kept the
  delay node allocated and still wired to the engine, one per reload, for as
  long as it kept streaming. Every load path and `reset()` release it now, and
  the sound is rewired before it is uninitialised.
- `AIL_sequence_position` reported beat 1, measure 1 for the whole of a playing
  sequence unless the game had also registered a beat callback: the beat clock
  only advanced on the callback path. It now advances on its own, and resyncs to
  the derived position when one render buffer crosses more beats than the
  per-call budget allows, instead of leaving the clock permanently behind.
- `AIL_quick_load_mem` mounted the caller's buffer without copying it, so the
  handle read memory the app was free to reuse and `AIL_quick_copy` had nothing
  to duplicate: it returned a handle holding no audio at all, which then played
  silence and reported `QSTAT_LOADED` forever. The quick handle now owns a copy
  of the image, and `AIL_quick_copy` fails with `AIL_last_error` set rather than
  reporting success for a sample that holds no image.
- `make lint` failed on a clean checkout: 29 of the 109 `file:line anchor`
  references in `docs/THREAT_MODEL.md` pointed at a line the named anchor had
  moved off, so `check_threat_model_refs.py` (part of `make lint`, part of
  `make check`, and a CI step through both) reported them and exited 1. The
  anchors are re-pointed at the line each identifier now sits on; the model
  describes the same controls as before.
- Plugin discovery loaded providers in directory-read order, which the
  filesystem chooses and changes between machines and between runs, so
  `RIB_enumerate_providers` answered in an order no replay could reproduce and
  two installs of the same redist directory could hand a query to different
  providers. `openmiles.sortedPluginNames` now collects the plugin names first
  and sorts them, and both scans (`loadApplicationProviders` and
  `DigitalDriver.loadAllAsi`) load in that order.
- `make lint` was red on a clean tree: 32 `docs/THREAT_MODEL.md` `file:line`
  anchors in `src/root.zig`, `src/api/digital.zig`, `src/api/v8.zig` and
  `src/engine/soundbank.zig` named lines their anchors had moved off, and
  `zig fmt --check` rejected `src/root.zig`. Every mitigation the model claims
  was a claim nobody re-checked. All 103 references resolve again, and the
  anchors point at the line each symbol is defined on.
- `AIL_shutdown` tore the engine down on the first call, not the last. A game
  that calls `AIL_startup` twice and `AIL_shutdown` once per startup was left
  with no startup provider and no drivers, while the use count still reported
  one outstanding use, so the same call sequence ended in a different state
  depending on how many times startup had run. The count now gates the teardown
  and `openmiles.shutdown()` is reached only at zero; a repeated shutdown past
  zero stays harmless.
- `AIL_last_error` and `AIL_file_error` name a process-wide buffer that every
  entry point writes from whichever thread called, with no lock. Two writers
  could interleave and splice their messages, or leave one unterminated. The
  writes are serialized now; both accessors still hand back a pointer into the
  live buffer, so a caller that must keep the text copies it out.
- `AIL_set_redist_directory` returned a pointer into the library's live path
  buffer, which another thread's call rewrites under the reader. It returns a
  per-thread snapshot of the same string now, so the pointer is as stable as
  the SDK's own.
- `startAllTimers` / `stopAllTimers` held the global timer registry lock across
  a per-timer `start` / `stop`, and both join a timer thread whose callback is
  free to call `AIL_register_timer` and take that same lock: a timer that
  registered itself deadlocked the shutdown it was running on. Each snapshots
  the registry under the lock and works with it released.
- `releaseAllTimers` stopped and destroyed each timer outside the registry lock,
  so a snapshot taken by `startAllTimers` / `stopAllTimers` could be left
  holding a freed pointer. The unlink and the free happen under the lock, once
  the thread is joined.
- `Timer.deinit` released its state mutex between the stop and the join, so a
  concurrent `AIL_start_timer` could spawn a fresh run loop onto a struct that
  was about to be destroyed. It holds the mutex across the whole teardown, and a
  `deinit` called from inside the callback (the run loop's own thread, which
  cannot be joined and still reads the struct on the way out) hands the destroy
  to the run loop instead of freeing under it.
- A soundbank's reference drop and its unregister from the registry were two
  separate steps, so a concurrent open of the same file could find the bank,
  take a reference, and then have it torn down under it, and two concurrent
  closes could lose a decrement. The decrement, the last-reference test and the
  unregister are one step under the registry lock.
- Reloading a MIDI sequence freed the previous `tml` handle without holding the
  sequence state mutex, so the audio thread could still be walking the old
  message chain when it was freed. The swap of the handle and the fields
  rewritten from the new list now happen under that mutex; the parse stays
  outside it.
- `make lint` failed on a clean tree: two `src/root.zig` `else` clauses were
  wrapped across two lines, which `zig fmt` joins, so the first check a
  contributor runs reported a formatting violation with nothing changed on
  their side. Both are on one line now.
- `make lint` failed on a clean tree: 36 `docs/THREAT_MODEL.md` `file:line`
  anchors named lines their definitions had moved off, in `src/root.zig`,
  `src/api/digital.zig`, `src/engine/digital.zig` and
  `src/engine/soundbank.zig`, so the threat model read as claiming a mitigation
  at a place a reader would not find it. Every reference points at the line its
  anchor is on again, including the three that name a call site rather than a
  definition.
- `make lint` failed on a clean tree: eight `docs/THREAT_MODEL.md` `file:line`
  anchors in `src/engine/midi.zig` and `src/engine/digital.zig` named lines
  their definitions had moved off, so the threat model read as claiming a
  mitigation at a place a reader would not find it. The references point at the
  line each anchor is on again.
- `make check-header`, `check-versions`, `check-vendored`, `check-pins`, and
  `check-threat-model` ran their script as a program on a machine with neither
  `python3` nor `python`, so they failed with the shell's own `env: ... No such
  file or directory` and exit 127, naming neither the missing interpreter nor
  the target that needs it. They depend on a new `check-interpreter`
  preflight, which reports the same message the other preflights use.
- The tests in `tests/` are named in `CONTRIBUTING.md` as the place a change
  carries its tests, but nothing runs them, locally or in CI: the C harnesses
  `LoadLibrary` the built DLL and `native_rib_test` needs a `dlopen` the musl
  test binaries cannot do, so they are Windows-only and hand-run. The file
  says so, and says how to run them.
- A malformed line in `deps/SHA256SUMS` was printed and then ignored, so
  `make check-vendored` reported the finding and still exited 0 while claiming
  every vendored file matched. The line is a finding now, and the gate fails on
  it.
- `check_header.py` and `check_threat_model_refs.py` exited 2 when zig or
  `docs/THREAT_MODEL.md` was missing. 2 is the bad-invocation code; a check
  that could not run exits 1, as every other gate does.
- `check_threat_model_refs.py` sent its findings to stderr while the other
  gates report findings on stdout, so a script reading the report of a failing
  gate saw nothing.
- `scripts/check_all_versions.sh` called `python3` directly, where the
  Makefile and CONTRIBUTING both resolve `python3` or `python`; a host that
  names it `python` failed the parity sweep with no message.
- `make help` told the reader that every individual check target takes
  `--help`. `make check-header --help` is make's own help, prints it, and runs
  no check, so the help named a way to get usage that does not exist; it now
  names the script to run.
- `make lint` was red on a clean tree: every `docs/THREAT_MODEL.md`
  `file:line` reference into `src/root.zig`, `src/api/v8.zig` and
  `src/engine/event.zig` that had moved since it was written failed the anchor
  check. The anchors are the callback VFS, the whole-file read cap, the plugin
  scan, the two soundbank entry points and the event step decode, at the lines
  they are defined on.
- `make lint` failed on a clean tree: `ruff check` reported the fixed-argv
  `zig cc` call in `check_header.py` under the bandit rules, and every
  `docs/THREAT_MODEL.md` `file:line` reference whose line had moved since it
  was written failed the anchor check. The compiler call resolves `zig` through
  `shutil.which` and names the missing binary instead of raising, and the
  threat model references point at the line the anchor is on.
- Eight `docs/THREAT_MODEL.md` `file:line` references in `src/engine/midi.zig`
  and `src/engine/digital.zig` had drifted again, so `make lint` was red on a
  clean tree and the lint job of `.github/workflows/ci.yml` failed on every
  push. The anchors are the loop-stack fields and the three sample loaders at
  the lines they are defined on.
- `make cross` did not assert the pinned toolchain, so a stray `zig` on PATH
  produced the shipped `x86-windows` DLL with nothing comparing it against the
  references. It now runs `check-toolchain` first, like `build` and `test`.
- A `scripts/__pycache__/*.pyc` was committed, and nothing kept the interpreter
  from writing another next to the gates. Both are ignored now.
- `make test FILTER=<substring>` reported success when the substring matched no
  test name, so a typo read as a green run. A filter that matches nothing is
  now refused, naming the filter.
- `make help` did not list `check-yaml` or `check-parity-tools`.
- A soundfont load adopted the digital engine's sample rate unchecked, and the
  MIDI render loop computed its milliseconds-per-frame as `1000.0 / rate` with
  no guard. An engine with no playback device reports a rate of 0, so
  `time_ms` gained an infinity on the first buffer and every position read
  after it was INF, NaN, or saturated to the counter maximum. The rate is only
  adopted when it is non-zero, and the conversion is
  `MidiDriver.msPerFrame`, which reports 0 for a rate-less driver.
- The UTF-8 round-trip fuzz asked `utf8ByteSequenceLength` for the length of a
  code point, but that function reads a sequence's first byte, so a code point
  above U+FFFF reported 1 and the space check stopped protecting
  `utf8Encode`. The suite aborted on the first run that drew one.
- `docs/THREAT_MODEL.md` named file:line anchors that no longer resolved: 31
  references pointed at lines an edit had moved, so every mitigation it claims
  was a claim nobody re-checked. All 101 references resolve again, and
  `make check-threat-model` (in `make lint`) is what keeps them honest.
- A vendored header's origin was recorded as a version string alone, so
  `deps/SHA256SUMS` proved which bytes shipped without proving which upstream
  release they came from, and the update checklist in `deps/README.md` asked
  for a commit id no entry carried. Each vendored entry now names the commit
  it was fetched from (miniaudio `0.11.25`, TinySoundFont `tsf.h` and
  `tml.h`, each verified byte-for-byte against upstream), and
  `scripts/check_vendored.py` fails a vendored file whose entry names no
  commit and does not claim the file first-party.
- A vendored header's recorded version was never compared with the version the
  header states in its own bytes, and that recorded version is what
  `scripts/gen_sbom.py` writes into `SBOM.cdx.json`. A header upgraded without
  the `deps/README.md` entry would have put the superseded version in the
  inventory a vulnerability scanner matches against, so every advisory
  published for the release that actually shipped would miss. `check_vendored.py`
  reads the version out of each header now (miniaudio's
  `MA_VERSION_MAJOR/MINOR/REVISION`, the line 1 banner of the two
  TinySoundFont headers) and fails a mismatch, or a vendored header that states
  no version a check could read.
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
- The debug log's first line names the `-Dmss-version` the loaded DLL was built
  for. A game compiled against a different `OPENMILES_MSS_VERSION` than the DLL
  it loads had no way to see the mismatch: nothing in the image reports the
  version it was built as.
- The shipped `mss32.dll` is linked stripped. It no longer carries a CodeView
  directory, so the build directory cannot reach the artifact through the PDB
  GUID, and two builds of one commit at different paths produce the same bytes.
- `make parity` installs its per-version builds under `zig-out/parity` instead
  of overwriting the shipped `zig-out/bin/mss32.dll` with a Debug build of
  another release.
- Every release-archive entry is staged with mode 0644, so a build output's
  executable bit cannot reach the zip bytes.
- `scripts/requirements-dev.txt` is `scripts/requirements.txt`. Dependabot's
  pip ecosystem only discovers the plain name, so the one third-party package
  the project declares (`pefile`) had no update path at all; `.github/dependabot.yml`
  now watches `/scripts` for it alongside the GitHub Actions.
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

[Unreleased]: https://github.com/maci0/openmiles/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/maci0/openmiles/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/maci0/openmiles/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/maci0/openmiles/releases/tag/v0.1.0

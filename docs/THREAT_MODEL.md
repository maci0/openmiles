# OpenMiles threat model

Last reviewed: 2026-09-27. Scope: `mss32.dll` as deployed next to a game
executable, the C exports in `src/api/`, the engine in `src/engine/`, the RIB
plugin loader in `src/rib/`, and the vendored headers in `deps/`.

Every reference below is written as `path:line anchor`, and
`scripts/check_threat_model_refs.py` asserts the anchor is on that line, so a
reference that drifts fails the `make lint` gate rather than misleading the next
pass.

OpenMiles is a library loaded into an unprivileged, single-user desktop process.
It opens no listening socket, serves no HTTP or RPC, and has no database,
multi-tenant, or remote-admin surface. No code in `src/` references `ws2_32`,
`winhttp`, or `wininet`. The model below therefore covers two boundaries that
matter: **game process to DLL** and **file system (or the game's VFS) to DLL**,
plus the **environment** and **deployment artifact** boundaries (the
`.asi`/`.m3d`/`.flt` plugins the DLL loads and executes).

Owner and review cadence are not defined by this repository; a security owner has
to set both.

## Risk-ranked summary

| # | Threat | Boundary | Impact | Status |
|---|--------|----------|--------|--------|
| 1 | Untrusted plugin image written to the temp directory and `LoadLibrary`'d | file/env to process | Code execution as the game user | Mitigated: unpredictable name, exclusive create (`src/api/rib.zig:220 randomSecure`, `src/api/rib.zig:240 exclusive`) |
| 2 | `.asi`/`.m3d`/`.flt` files in the game directory, or in a game-named redist directory, loaded and executed at startup | file to process | Code execution as the game user | Unmitigated by design: the host game's own directory is trusted. Listed in [Deployment](#4-deployment-artifact-boundary) |
| 3 | A plugin image parsed by the ELF fixup on a static-musl Linux build (`applyElfFixups`) | file to process | Crash, in-process memory corruption | Partial: program header table and `DT_RELA` slots bounded in `u64`/image space (`src/utils/dynlib.zig:58 programHeaderTableFits`) |
| 4 | `AIL_WAV_file_write` creates or truncates a game-named path | game to DLL, DLL to disk | Overwrite of any file the game user can write | Unmitigated by ABI necessity (`src/api/digital.zig:942 AIL_WAV_file_write`) |
| 5 | Malformed soundbank / event bytecode (`.BANK`) | file to process | Crash, in-process memory corruption, audio DoS | Partial: bounds chokepoint in `src/engine/soundbank.zig:222 rdU32`, step decode bounded in `src/engine/event.zig:483 copyString`) |
| 6 | Malformed XMIDI / MIDI sequence | file to process | Crash, memory exhaustion | Partial: saturating cursor arithmetic, fixed loop stack (`src/engine/xmidi.zig:377 xmidiToSmf`, `src/engine/midi.zig:245 xmidi_loop_stack`) |
| 7 | Malformed or oversized audio file (MP3/OGG/WAV/FLAC) | file to process | Crash, memory exhaustion | Partial: declared-size caps in `src/engine/audio_detect.zig:15 max_declared_image_size`, whole-file cap in `src/engine/digital.zig:1153 root.max_file_load_bytes`; the decode itself is delegated to miniaudio and TinySoundFont (`src/engine/digital.zig:1148 loadFromFile`) |
| 8 | App VFS callback reports an arbitrary file size | game to DLL | Heap exhaustion in the game process | Mitigated: same 256 MiB cap as the direct path (`src/root.zig:346 max_file_load_bytes`) |
| 9 | Caller-supplied pointer/length pairs trusted verbatim | game to DLL | Read/write of game memory on a bad call | Unmitigated by ABI necessity (see [Game process boundary](#1-game-process-boundary)) |
| 10 | Debug logging enabled by environment variable | environment to process | Verbose internal logging to disk, paths and asset names disclosed | Mitigated: opt-in, 64 MiB cap (`src/utils/logger.zig:14 max_log_bytes`) |
| 11 | `TMPDIR` redirects the ASI image write | environment to process | PE image written into an attacker-chosen directory | Unmitigated (`src/api/rib.zig:143 TMPDIR`) |

## 1. Game process boundary

Everything crossing this boundary arrives through a C export in `src/api/`. The
host game is inside the process and therefore fully trusted for memory safety:
these are not remote attack vectors, they are the ABI contract.

- Raw pointer plus length pairs with no length validation: `AIL_file_type`
  (`src/api/file.zig:17 AIL_file_type`), `AIL_file_write`
  (`src/api/file.zig:20 AIL_file_write`), `AIL_load_sample_buffer`
  (`src/api/digital.zig:419 AIL_load_sample_buffer`), `AIL_set_sample_address`
  (`src/api/digital.zig:261 AIL_set_sample_address`), `AIL_quick_load_mem`
  (`src/api/quick.zig:55 AIL_quick_load_mem`).
- `AIL_file_read` (`src/api/file.zig:11 AIL_file_read`) returns a pointer to a
  whole file the caller must `AIL_mem_free_lock`, or writes it into a
  caller-supplied `dest` of unknown size. With `dest` null the size is
  materialised twice: once by the VFS read (`src/root.zig:317 fileCallbackReadAll`)
  and again by a `malloc` of the same length (`src/root.zig:408 std.c.malloc`).
  Both copies are bounded by the same 256 MiB cap, so the peak is twice the cap
  rather than an arbitrary length, but a game that supplies a `dest` smaller than
  the file still has it overrun: the copy is a raw `@memcpy` with no length.
- Game-supplied VFS function pointers installed as globals and then called by
  the loader: `AIL_set_file_callbacks` (`src/api/file.zig:44 AIL_set_file_callbacks`).
  `AIL_set_file_async_callbacks` (`src/api/file.zig:51 AIL_set_file_async_callbacks`)
  discards the supplied async callback and delegates to the synchronous form, so
  a game that installs async callbacks has them invoked synchronously.
- Game-supplied callbacks stored but never invoked: `AIL_set_mem_callbacks`
  (`src/api/memory.zig:48 AIL_set_mem_callbacks`), `AIL_mem_use_malloc`
  (`src/api/memory.zig:36 AIL_mem_use_malloc`). A game that installs a custom
  allocator is silently ignored and the module allocates from its own heap.
- Path inputs: `AIL_set_redist_directory` (`src/api/digital.zig:50 AIL_set_redist_directory`),
  `AIL_quick_load` (`src/api/quick.zig:21 AIL_quick_load`), `RIB_load_application_providers`
  (`src/api/rib.zig:41 RIB_load_application_providers`).
- `AIL_WAV_file_write` (`src/api/digital.zig:942 AIL_WAV_file_write`) takes a
  game-supplied filename and creates or truncates the file at that path, then
  writes a WAV built from a game-supplied `(data, len)` pair
  (`src/api/digital.zig:971 createFile`). It is the only export that writes
  audio output to disk, and the write is a truncating create rather than an
  append, so a caller-chosen name destroys whatever was there. No path
  validation, no extension check, no prompt. The `AIL_file_write` export
  (`src/api/file.zig:20 AIL_file_write`) reaches the same create path for
  arbitrary bytes.

There is no `AIL_open_file`/`AIL_close_file`/`HSFILE` handle API. The whole file
service surface is `src/api/file.zig` plus the callback VFS in `src/root.zig:310 cb_file_open`.

## 2. File system to process

Data files opened by the game and handed to the DLL. These are the inputs a
hostile file, download, or mod pack reaches.

| Input | Entry point | Notes |
|-------|-------------|-------|
| Audio file | `AIL_load_sample` / `AIL_open_stream` / `AIL_quick_load` -> `Sample.loadFromFile` (`src/engine/digital.zig:1148 loadFromFile`) | Rejects a zero length and anything above the shared 256 MiB cap (`src/engine/digital.zig:1153 root.max_file_load_bytes`, `src/root.zig:358 max_file_load_bytes`), then allocates the whole file. |
| Audio in memory | `Sample.load` (`src/engine/digital.zig:1168 load`) | A positive caller length is used as a slice length with no cap; a zero or negative length falls to `loadFromUnownedMemoryUnknownSize`, which derives a bounded image from the header. The uncapped case is the in-process ABI, not a file input. |
| XMIDI / MIDI | `AIL_init_sequence` -> `xmidiToSmf` (`src/engine/xmidi.zig:377 xmidiToSmf`) | Declared extents clamped to the buffer with saturating arithmetic; VLQ continuation capped at 4 bytes (`src/engine/xmidi.zig:80 bytes_read`); FOR/NEXT loop stack fixed at 8 with a depth check (`src/engine/midi.zig:244 xmidi_loop_depth`). |
| BANK soundbank | `AIL_open_soundbank` (`src/api/v8.zig:523 AIL_open_soundbank`), `AIL_open_soundbank_v8` (`src/api/v8.zig:930 AIL_open_soundbank_v8`) -> `loadFromMemory` (`src/engine/soundbank.zig:520 loadFromMemory`) | Tag, version, and `meta_size` validated before any allocation; every offset read passes through the bounds-checked `rdU32` (`src/engine/soundbank.zig:222 rdU32`); metadata is NUL-terminated by an allocated sentinel. |
| Event bytecode | `AIL_next_event_step` (`src/api/v8.zig:503 AIL_next_event_step`) -> `nextStep` (`src/engine/event.zig:626 nextStep`) | Step type is range-checked before the enum conversion, the header chain is depth-limited, and string copies refuse to pass `wlimit` (`src/engine/event.zig:483 copyString`). |
| DLS container | `AIL_extract_DLS` / `AIL_find_DLS` / `AIL_list_DLS` / `AIL_merge_DLS_with_XMI` | Pointer images capped at 256 MiB (`src/engine/dls_container.zig:74 max_ptr_image_size`); merged image size checked with `std.math.add`. `AIL_list_DLS` takes a pointer with no length and derives one from the header, so a lying RIFF size drives a scan past the caller's buffer (`src/api/dls.zig:351 AIL_list_DLS`). |
| MP3 frame walk | `AIL_inspect_MP3` (`src/api/v7.zig:809 AIL_inspect_MP3`), `AIL_enumerate_MP3_frames` (`src/api/v7.zig:821 AIL_enumerate_MP3_frames`) | Frame walk is bounded by the image, not by a frame count (`src/engine/mp3.zig:189 enumerateFrames`). |

Amplification and quota notes: there is no rate limit, quota, or frame-count
cap anywhere in the module. The whole-file reads scale with the input, and
`ensureTotalCapacity(allocator, evnt.len / 2)` in the XMIDI path
(`src/engine/xmidi.zig:204 ensureTotalCapacity`) pre-allocates several times the
chunk size from a caller-supplied image, with `OutOfMemory` as the only backstop.

## 3. Environment boundary

Two environment variables are read, both through the process environment rather
than any validated config file. Both values are checked before use, and a
rejected one is reported on stderr with the reason.

- `OPENMILES_DEBUG` (`src/utils/logger.zig:88 GetEnvironmentVariableW`):
  enables verbose logging to `openmiles.log` in the current directory, capped at
  64 MiB (`src/utils/logger.zig:14 max_log_bytes`). Debug builds enable it by
  default (`src/utils/logger.zig:74 builtin.mode`), so a debug build in a shared
  directory discloses asset names, file paths, and internal state to any local
  user who can read the file. A value outside the documented set is refused
  rather than read as off, so a typo cannot silently suppress the only trace a
  failure leaves (`src/utils/logger.zig:35 parseDebugFlag`).
- `TMPDIR` (`src/api/rib.zig:143 TMPDIR`): the non-Windows directory the
  in-memory ASI image is written to. Any process that can set the game
  process's environment chooses where a PE image is written and loaded from.
  A `TMPDIR` that is empty, too long, or relative is refused
  (`src/api/rib.zig:166 reportTempDir`), and a set one that does not exist falls
  through to the cwd-relative `./om_asi_*.dll` form
  (`src/api/rib.zig:229 om_asi_`), which lands in the game directory instead.
  Unmitigated.
- `GetTempPathW` (`src/api/rib.zig:128 GetTempPathW`): on Windows, `TEMP` is
  per-user, so the write is confined to the user's own profile.
- No registry, no network configuration, no service installation, no scheduled
  job, no IPC endpoint.

## 4. Deployment artifact boundary

Two entry points load plugin code, and both end at the same `Provider.load`
choke point, loading every file with a plugin extension through the OS loader.

1. `AIL_startup` (`src/api/digital.zig:18 AIL_startup`) reaches `startup()`,
   which scans the current working directory: `loadApplicationProviders(".")`
   (`src/root.zig:1280 loadApplicationProviders`, defined at
   `src/root.zig:606 loadApplicationProviders`).
2. `AIL_set_redist_directory` (`src/api/digital.zig:50 AIL_set_redist_directory`)
   records a game-supplied directory, and `loadAllAsi` scans it
   (`src/engine/digital.zig:552 loadAllAsi`), called on a directory change
   (`src/root.zig:905 loadAllAsi`) and again when a digital driver opens
   (`src/root.zig:1330 loadAllAsi`). The directory is not restricted to the game
   directory: the game names any path, so a redist directory pointing at a
   download or per-user shared folder extends plugin execution to every plugin
   extension found there.

Controls present, on both scans:

- Extension allowlist `.asi`, `.m3d`, `.flt` (`src/root.zig:542 isPluginExtension`).
- Filename rejection of `..`, `/`, `\` so a directory entry cannot escape the
  scan directory (`src/root.zig:548 isSafePluginFilename`).
- A rescan that finds an already-loaded module skips it, so one module is
  loaded once per process: `src/root.zig:663 isPluginAlreadyLoaded` for the
  application list, and `src/root.zig:676 isPluginLoadedAnywhere` for the
  redist scan, which also skips modules the application list already holds.
- The loaded module runs in-process with the game's full authority. This is the
  original MSS design, and plugins are unsigned.

Gaps:

- No signature check, no allowlist of known plugins, no prompt. Any file with a
  plugin extension in the game directory, or in a directory the game points the
  redist search at, executes with game privileges.
- `Provider.load` resolves the path case-insensitively before loading
  (`src/rib/provider.zig:115 maybeResolveCaseInsensitivePath`), so a symlink or
  alternate-case name reaches whatever the resolver finds.
- Windows DLL search order applies to a relative path, so a plugin name that
  also exists in the system directory can resolve elsewhere than the scanned
  directory. Nothing in the loader pins the resolved path after resolution.
- A loaded plugin registers RIB interfaces the module then calls back with data
  files. That is a privilege transition the model must name: a plugin's codec
  entry points run with the game process's full authority, and the module
  hands them pointers derived from untrusted files.

## 5. In-memory ASI image boundary

`AIL_open_ASI_provider` (`src/api/rib.zig:190 AIL_open_ASI_provider`) takes a PE
image in memory, writes it to a temporary file, and loads it.

Controls present:

- The file name is `om_asi_<random>.dll` with 64 bits of entropy from
  `io.randomSecure`; failure to obtain entropy fails closed rather than falling
  back to a guessable name (`src/api/rib.zig:220 randomSecure`).
- The file is created with `.exclusive = true` (`src/api/rib.zig:240 exclusive`),
  so a planted name cannot be opened for overwrite and a race replacement loses.
- The file is deleted after the module is unloaded (`src/rib/provider.zig:156 deinit`).

Gaps:

- A local process running as the same user can still list the temp directory and
  race between create and load. Windows would need a section-backed or
  `LOCKFILE_EXCLUSIVE` handle kept open across the load to close this.
- The `TMPDIR` environment input above chooses the directory.
- The non-Windows fallback writes `./om_asi_*.dll` into the current directory
  (`src/api/rib.zig:235 om_asi_`), which is the game directory and therefore a
  more visible location than a temp directory.
- The image is only checked for an `MZ` signature before being written and loaded
  (`src/api/rib.zig:197 raw`); no further validation is possible, since
  the caller wants arbitrary code to run.

## 6. Assets and impact

- **Host process integrity.** The DLL runs inside the game. A successful memory
  corruption in a parser is code execution as the game user, with whatever that
  user can reach: save files, the user's documents, the game directory, network
  sessions the game holds. This is the single highest-impact outcome.
- **Availability.** A crash in a decoder takes down the game. A crafted bank or
  XMIDI that allocates unboundedly takes down the machine's available memory.
- **Audio output.** Corrupted 3D or reverb state is a functional defect, not a
  security one.
- **Local confidentiality.** The debug log and the temp plugin file are the only
  places the module writes data it chose. Two exports also write to a
  caller-named path: `AIL_WAV_file_write` and `AIL_file_write`, both
  truncating creates. None of these holds credentials: OpenMiles stores no
  secrets, no keys, and no user data of any kind. The exposure is overwrite
  of a file the game user can write, not disclosure of one.
- **No remote assets, no network egress.** The module never opens a socket.

## 7. Mitigation map

| Control | Where | Covers |
|---------|-------|--------|
| Whole-file read cap, 256 MiB | `src/root.zig:358 max_file_load_bytes` | Oversized file allocation on every whole-file read path, direct (`src/root.zig:373 max_file_load_bytes`) and VFS (`src/root.zig:346 max_file_load_bytes`) |
| Whole-file read cap on the sample loader | `src/engine/digital.zig:1153 root.max_file_load_bytes` | Oversized audio file through `AIL_load_sample` / `AIL_open_stream` |
| Declared container size cap, 256 MiB | `src/engine/audio_detect.zig:15 max_declared_image_size` | Lying RIFF/FORM headers |
| Pointer image cap, 256 MiB | `src/engine/dls_container.zig:74 max_ptr_image_size` | Lying DLS container sizes over bare pointers |
| Bounds-checked offset read | `src/engine/soundbank.zig:222 rdU32` | Every BANK offset and count |
| Saturating cursor arithmetic and clamped chunk ends | `src/engine/xmidi.zig:377 xmidiToSmf` | Lying XMIDI chunk sizes |
| Fixed loop stack with depth check | `src/engine/midi.zig:245 xmidi_loop_stack` | XMIDI FOR/NEXT recursion |
| Unpredictable exclusive temp file | `src/api/rib.zig:214 exclusive` | Temp-file pre-planting and name race |
| Plugin extension allowlist and separator rejection | `src/root.zig:542 isPluginExtension` | Directory traversal in the CWD plugin scan |
| Step-type range check, header depth limit, `wlimit`-bounded string copies | `src/engine/event.zig:483 copyString` | Crafted event bytecode |
| Log cap, 64 MiB | `src/utils/logger.zig:14 max_log_bytes` | Unbounded debug log growth |
| Fuzz harness over every export that takes input | `src/fuzz_all_test.zig:37 test` | Regression coverage on the export surface |
| Native-path fuzz harness | `src/fuzz_native_test.zig:222 test` | Regression coverage on non-Windows paths |
| Export-parity and unit suites | `src/main_test.zig:28 test`, `src/api_coverage_test.zig:57 test` | ABI regressions |

Single points of failure:

- `fileCallbackReadAll` (`src/root.zig:317 fileCallbackReadAll`) is the only
  place a VFS-reported file length becomes an allocation. It re-checks
  `max_file_load_bytes` itself (`src/root.zig:346 max_file_load_bytes`)
  rather than inheriting the cap from `readWholeFile`
  (`src/root.zig:362 readWholeFile`), which returns its result before reaching
  that function's own direct-path check. That
  duplication is deliberate but is the thing to re-verify: a cap added to
  `readWholeFile` alone would leave the VFS boundary open, and a new whole-file
  read path that skips this function inherits no cap.
- `Provider.load` (`src/rib/provider.zig:107 load`) is the single choke point for
  every code-execution path, whether the module came from disk or from the temp
  file.
- The C ABI shape itself: several exports take `(pointer, length)` with no way to
  validate the length, so those calls are only as safe as the game.

## 8. Response readiness

- Security-relevant events leave one trace: the `openmiles.log` debug log, which
  is off by default in release builds. There is no audit record of which bank,
  soundbank, or plugin image was loaded, and no record of a failed load beyond a
  log line.
- No documented path from "vulnerability reported" to "fix shipped" exists in
  this repository. Reporting contact and supported versions are in
  [SECURITY.md](../SECURITY.md).

## Unmitigated threats, ranked

1. Unsigned plugin execution from the game directory (`src/root.zig:606 loadApplicationProviders`),
   and from any directory the game hands to `AIL_set_redist_directory`
   (`src/engine/digital.zig:552 loadAllAsi`). Inherent to the compatibility
   target; a documented deployment note is the available mitigation.
2. `AIL_WAV_file_write` truncates and overwrites a caller-named path
   (`src/api/digital.zig:971 createFile`) with no extension check, no path
   validation, and no append. A hostile in-process caller already has the
   game's authority, so the exposure is to a buggy or confused game writing
   over a file it did not mean to name.
3. `AIL_file_read` writes the whole file into a caller-supplied `dest` with a raw
   `@memcpy` and no length argument (`src/root.zig:408 std.c.malloc` path and the
   `dest` branch above it), so a game that hands in a short buffer has it
   overrun by the file length. The ABI passes no destination capacity, so this
   cannot be closed inside the module.
4. XMIDI event pre-allocation with no ceiling (`src/engine/xmidi.zig:204 ensureTotalCapacity`).
5. `AIL_list_DLS` derives a length from a caller pointer's header and scans up
   to 256 MiB past it (`src/api/dls.zig:351 AIL_list_DLS`).
6. No frame-count or duration limit on MP3 enumeration
   (`src/engine/mp3.zig:189 enumerateFrames`): bounded by the caller's loop, not
   by the module.
7. `TMPDIR` chooses the directory the ASI image is written to
   (`src/api/rib.zig:143 TMPDIR`).
8. Debug logging of paths and asset names in a game directory a second local
   user can read (`src/utils/logger.zig:74 builtin.mode`).

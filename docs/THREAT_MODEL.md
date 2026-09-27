# OpenMiles threat model

Last reviewed: 2026-09-27. Scope: `mss32.dll` as deployed next to a game
executable, the C exports in `src/api/`, the engine in `src/engine/`, the RIB
plugin loader in `src/rib/`, and the vendored headers in `deps/`.

OpenMiles is a library loaded into an unprivileged, single-user desktop process.
It opens no listening socket, serves no HTTP or RPC, and has no database,
multi-tenant, or remote-admin surface. The model below therefore covers two
boundaries that matter: **game process to DLL** and **file system (or the game's
VFS) to DLL**, plus the **deployment artifact** boundary (the `.asi`/`.m3d`/`.flt`
plugins the DLL loads and executes).

Owner and review cadence are not defined by this repository; a security owner has
to set both.

## Risk-ranked summary

| # | Threat | Boundary | Impact | Status |
|---|--------|----------|--------|--------|
| 1 | Untrusted plugin image written to `%TEMP%` and `LoadLibrary`'d | file to process | Code execution as the game user | Mitigated: unpredictable name, exclusive create (`src/api/rib.zig:118-176`) |
| 2 | `.asi`/`.m3d`/`.flt` files in the game directory loaded and executed at `AIL_startup` | file to process | Code execution as the game user | Unmitigated by design: the host game's own directory is trusted. Listed in [Deployment](#6-deployment-artifact-boundary) |
| 3 | Malformed soundbank / event bytecode (`.BANK`) | file to process | Crash, in-process memory corruption, audio DoS | Partial: bounds chokepoint in `src/engine/soundbank.zig:138`, step decode bounded in `src/engine/event.zig` |
| 4 | Malformed XMIDI / MIDI sequence | file to process | Crash, memory exhaustion | Partial: saturating cursor arithmetic, fixed loop stack (`src/engine/xmidi.zig`, `src/engine/midi.zig:196`) |
| 5 | Malformed or oversized audio file (MP3/OGG/WAV/FLAC) | file to process | Crash, memory exhaustion | Partial: declared-size caps in `src/engine/audio_detect.zig`; no cap on the raw file read (`src/engine/digital.zig:1004`) |
| 6 | App VFS callback reports an arbitrary file size | game to DLL | Heap exhaustion in the game process | Unmitigated (`src/root.zig:247`) |
| 7 | Caller-supplied pointer/length pairs trusted verbatim | game to DLL | Read/write of game memory on a bad call | Unmitigated by ABI necessity (see [Game process boundary](#1-game-process-boundary)) |
| 8 | Debug logging enabled by environment variable | environment to process | Verbose internal logging to disk, paths and asset names disclosed | Mitigated: opt-in, 64 MiB cap (`src/utils/logger.zig:12`) |

## 1. Game process boundary

Everything crossing this boundary arrives through a C export in `src/api/`. The
host game is inside the process and therefore fully trusted for memory safety:
these are not remote attack vectors, they are the ABI contract.

- Raw pointer plus length pairs with no length validation: `AIL_file_type`
  (`src/api/file.zig:17`), `AIL_file_write` (`src/api/file.zig:20`),
  `AIL_load_sample_buffer` (`src/api/digital.zig:402`),
  `AIL_set_sample_address` (`src/api/digital.zig:245`),
  `AIL_quick_load_mem` (`src/api/quick.zig:55`).
- Game-supplied VFS function pointers installed as globals and then called by
  the loader: `AIL_set_file_callbacks` (`src/api/file.zig:35`).
  `AIL_set_file_async_callbacks` (`src/api/file.zig:43`) discards the supplied
  async callback and delegates to the synchronous form, so a game that installs
  async callbacks has them invoked synchronously.
- Game-supplied callbacks stored but never invoked: `AIL_set_mem_callbacks`,
  `AIL_mem_use_malloc` (`src/api/memory.zig:36`). A game that installs a custom
  allocator is silently ignored and the module allocates from its own heap.
- Path inputs: `AIL_set_redist_directory` (`src/api/digital.zig:29`),
  `AIL_quick_load` (`src/api/quick.zig:21`), `RIB_load_application_providers`
  (`src/api/rib.zig:40`).

There is no `AIL_open_file`/`AIL_close_file`/`HSFILE` handle API. The whole file
service surface is `src/api/file.zig` plus the callback VFS in `src/root.zig:240`.

## 2. File system to process

Data files opened by the game and handed to the DLL. These are the inputs a
hostile file, download, or mod pack reaches.

| Input | Entry point | Notes |
|-------|-------------|-------|
| Audio file | `AIL_load_sample` / `AIL_open_stream` / `AIL_quick_load` -> `Sample.loadFromFile` (`src/engine/digital.zig:1004`) | Rejects only a zero length, then allocates the whole file. The 256 MiB cap in `readWholeFile` (`src/root.zig:279`) applies only to that helper. |
| Audio in memory | `Sample.load` (`src/engine/digital.zig:1018`) | Caller length used as a slice length with no cap. |
| XMIDI / MIDI | `AIL_init_sequence` (`src/api/midi.zig:40`) -> `xmidiToSmf` (`src/engine/xmidi.zig:375`) | Declared extents clamped to the buffer with saturating arithmetic (`src/engine/xmidi.zig:114-185`); VLQ continuation capped at 4 bytes (`src/engine/xmidi.zig:71`); FOR/NEXT loop stack fixed at 8 with a depth check (`src/engine/midi.zig:196`, `:411`). |
| BANK soundbank | `AIL_open_soundbank` (`src/api/v8.zig:515`) -> `loadFromMemory` (`src/engine/soundbank.zig:413`) | Tag, version, and `meta_size` validated before any allocation; every offset read passes through the bounds-checked `rdU32` (`src/engine/soundbank.zig:138`); metadata is NUL-terminated by an allocated sentinel (`src/engine/soundbank.zig:426-429`). |
| Event bytecode | `AIL_next_event_step` (`src/api/v8.zig:499`) -> `nextStep` (`src/engine/event.zig:619`) | Step type is range-checked before the enum conversion, the header chain is depth-limited, and string copies refuse to pass `wlimit` (`src/engine/event.zig:480`). |
| DLS container | `AIL_extract_DLS` / `AIL_find_DLS` / `AIL_list_DLS` / `AIL_merge_DLS_with_XMI` (`src/api/dls.zig:262-359`) | Pointer images capped at 256 MiB (`src/engine/dls_container.zig:74`); merged image size checked with `std.math.add` (`src/api/dls.zig:378`). `AIL_list_DLS` takes a pointer with no length and derives one from the header, so a lying RIFF size drives a scan past the caller's buffer (`src/api/dls.zig:336`). |
| MP3 frame walk | `AIL_inspect_MP3`, `AIL_enumerate_MP3_frames` (`src/api/v7.zig:806-818`) | Frame walk is bounded by the image, not by a frame count (`src/engine/mp3.zig:175`); table indices validated before lookup (`src/engine/mp3.zig:233`). |

Amplification and quota notes: there is no rate limit, quota, or frame-count
cap anywhere in the module. The whole-file reads scale with the input, and
`ensureTotalCapacity(allocator, evnt.len / 2)` in the XMIDI path
(`src/engine/xmidi.zig:202`) pre-allocates several times the chunk size from a
caller-supplied image, with `OutOfMemory` as the only backstop.

## 3. Environment boundary

- `OPENMILES_DEBUG` (`src/utils/logger.zig:35`): enables verbose logging to
  `openmiles.log` in the current directory, capped at 64 MiB. Debug builds enable
  it by default (`src/utils/logger.zig:33`), so a debug build in a shared
  directory discloses asset names, file paths, and internal state to any local
  user who can read the file.
- `GetTempPathA` (`src/api/rib.zig:118`): selects the directory the in-memory ASI
  image is written to. On a shared Windows install, `TEMP` is per-user, so the
  write is confined to the user's own profile.
- No registry, no network configuration, no service installation, no scheduled
  job, no IPC endpoint.

## 4. Deployment artifact boundary

`AIL_startup` scans the current working directory and loads every file with a
plugin extension through the OS loader: `loadApplicationProviders(".")`
(`src/root.zig:859`, `:444`).

Controls present:

- Extension allowlist `.asi`, `.m3d`, `.flt` (`src/root.zig:432`).
- Filename rejection of `..`, `/`, `\` so a directory entry cannot escape the
  scan directory (`src/root.zig:437`).
- The loaded module runs in-process with the game's full authority. This is the
  original MSS design, and plugins are unsigned.

Gaps:

- No signature check, no allowlist of known plugins, no prompt. Any file with a
  plugin extension in the game directory executes with game privileges.
- `Provider.load` resolves the path case-insensitively before loading
  (`src/rib/provider.zig:106`, `src/utils/fs_compat.zig:44`), so a symlink or
  alternate-case name reaches whatever the resolver finds.
- Windows DLL search order applies to a relative path, so a plugin name that
  also exists in the system directory can resolve elsewhere than the scanned
  directory. Nothing in the loader pins the resolved path after resolution.

## 5. In-memory ASI image boundary

`AIL_open_ASI_provider` (`src/api/rib.zig:113`) takes a PE image in memory,
writes it to a temporary file, and loads it.

Controls present:

- The file name is `om_asi_<random>.dll` with 64 bits of entropy from
  `io.randomSecure` (`src/api/rib.zig:139-149`); failure to obtain entropy fails
  closed rather than falling back to a guessable name.
- The file is created with `.exclusive = true` (`src/api/rib.zig:152`,
  `:167`), so a planted name cannot be opened for overwrite and a race
  replacement loses.
- The file is deleted after the module is unloaded (`src/rib/provider.zig:122`).

Gaps:

- A local process running as the same user can still list the temp directory and
  race between create and `LoadLibrary`. Windows would need a section-backed or
  `LOCKFILE_EXCLUSIVE` handle kept open across the load to close this.
- The non-Windows fallback writes `./om_asi_*.dll` into the current directory
  (`src/api/rib.zig:161`), which is the game directory and therefore a more
  visible location than `TEMP`.
- The image is only checked for an `MZ` signature before being written and loaded
  (`src/api/rib.zig:120`); no further validation is possible, since the caller
  wants arbitrary code to run.

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
  places the module writes to disk. Neither holds credentials: OpenMiles stores
  no secrets, no keys, and no user data of any kind.
- **No remote assets, no network egress.** The module never opens a socket.

## 7. Mitigation map

| Control | Where | Covers |
|---------|-------|--------|
| Whole-file read cap, 256 MiB | `src/root.zig:279` | Oversized file allocation on the direct-filesystem read path only |
| Declared container size caps, 256 MiB / 16 MiB | `src/engine/audio_detect.zig:9-15`, `src/engine/dls_container.zig:74` | Lying RIFF/FORM headers over bare pointers |
| Bounds-checked offset read | `src/engine/soundbank.zig:138` | Every BANK offset and count |
| Saturating cursor arithmetic and clamped chunk ends | `src/engine/xmidi.zig:114-185` | Lying XMIDI chunk sizes |
| Fixed loop stack with depth check | `src/engine/midi.zig:196`, `:411` | XMIDI FOR/NEXT recursion |
| Unpredictable exclusive temp file | `src/api/rib.zig:139-176` | Temp-file pre-planting and name race |
| Plugin extension allowlist and separator rejection | `src/root.zig:432-441` | Directory traversal in the CWD plugin scan |
| Step-type range check, header depth limit, `wlimit`-bounded string copies | `src/engine/event.zig:619-641`, `:480` | Crafted event bytecode |
| Log cap, 64 MiB | `src/utils/logger.zig` | Unbounded debug log growth |
| Fuzz harness over every export that takes input | `src/fuzz_all_test.zig` | Regression coverage on the export surface |
| Export-parity and unit suites | `src/main_test.zig`, `src/api_coverage_test.zig` | ABI regressions |

Single points of failure:

- `readWholeFile` / `fileCallbackReadAll` (`src/root.zig:247`) is the only place
  a file length becomes an allocation, and the cap lives only on the direct path.
  Fixing the size cap in one function and not the other leaves the boundary open.
- `Provider.load` (`src/rib/provider.zig:88`) is the single choke point for every
  code-execution path, whether the module came from disk or from the temp file.
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

1. Unsigned plugin execution from the game directory (`src/root.zig:859`).
   Inherent to the compatibility target; a documented deployment note is the
   available mitigation.
2. Uncapped whole-file allocation in `Sample.loadFromFile`
   (`src/engine/digital.zig:1004`) and in the VFS path
   (`src/root.zig:272`): a large or lying file size turns into a large
   allocation, with `OutOfMemory` as the only outcome.
3. Game-VFS-reported size trusted for allocation (`src/root.zig:272`). A hostile
   or buggy VFS makes the game allocate whatever it says.
4. `AIL_list_DLS` derives a length from a caller pointer's header and scans up
   to 256 MiB past it (`src/api/dls.zig:336`).
5. XMIDI event pre-allocation with no ceiling (`src/engine/xmidi.zig:202`).
6. No frame-count or duration limit on MP3 enumeration
   (`src/engine/mp3.zig:175`): bounded by the caller's loop, not by the module.
7. Debug logging of paths and asset names in a game directory a second local
   user can read (`src/utils/logger.zig:49`).

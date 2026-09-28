# OpenMiles threat model

Last reviewed: 2026-09-28. Scope: `mss32.dll` as deployed next to a game
executable, the C exports in `src/api/`, the engine in `src/engine/`, the RIB
plugin loader in `src/rib/`, and the vendored headers in `deps/`.

Every reference below is written as `path:line anchor`, and
`scripts/check_threat_model_refs.py` asserts the anchor is on that line, so a
reference that drifts fails the `make lint` gate rather than misleading the next
pass. An edit that moves code re-anchors the references with
`scripts/check_threat_model_refs.py --update`, which prints every line number it
moves; read that list before committing it.

OpenMiles is a library loaded into an unprivileged, single-user desktop process.
It opens no listening socket, serves no HTTP or RPC, and has no database,
multi-tenant, or remote-admin surface. No code in `src/` references `ws2_32`,
`winhttp`, or `wininet`. The model below therefore covers two boundaries that
matter: **game process to DLL** and **file system (or the game's VFS) to DLL**,
plus the **environment** and **deployment artifact** boundaries (the plugin code
the DLL loads and executes: `.asi`/`.m3d`/`.flt` files found by a directory
scan, and any caller-named path handed straight to the loader).

Owner and review cadence are not defined by this repository; a security owner has
to set both.

## Risk-ranked summary

| # | Threat | Boundary | Impact | Status |
|---|--------|----------|--------|--------|
| 1 | Untrusted plugin image written to the temp directory and `LoadLibrary`'d | file/env to process | Code execution as the game user | Mitigated: unpredictable name, exclusive create (`src/api/rib.zig:294 randomNameBytes`, `src/api/rib.zig:318 exclusive`) |
| 2 | `.asi`/`.m3d`/`.flt` files in the game directory, or in a game-named redist directory, loaded and executed at startup | file to process | Code execution as the game user | Unmitigated by design: the host game's own directory is trusted. Listed in [Deployment](#4-deployment-artifact-boundary) |
| 3 | `RIB_load_provider_library` loads a game-named path as code, skipping every check the directory scans apply | game to DLL | Code execution as the game user, from any extension and any path | Unmitigated: reaches the same `Provider.load` with no extension allowlist, no filename check, and no already-loaded dedup (`src/api/rib.zig:450 RIB_load_provider_library`) |
| 4 | A plugin image parsed by the ELF fixup on a Linux build with no libc, or with static musl (`src/utils/dynlib.zig:28 needs_elf_fixup`, `src/utils/dynlib.zig:84 applyElfFixups`) | file to process | Crash, in-process memory corruption | Partial: program header table, dynamic-section walk, and `DT_RELA` slots bounded in `u64`/image space (`src/utils/dynlib.zig:71 programHeaderTableFits`, `src/utils/dynlib.zig:119 dyn_entries`) |
| 5 | `AIL_WAV_file_write` creates or truncates a game-named path | game to DLL, DLL to disk | Overwrite of any file the game user can write | Unmitigated by ABI necessity (`src/api/digital.zig:1042 AIL_WAV_file_write`) |
| 6 | Malformed soundbank / event bytecode (`.BANK`) | file to process | Crash, in-process memory corruption, audio DoS | Partial: bounds chokepoint in `src/engine/soundbank.zig:272 rdU32`, step decode bounded in `src/engine/event.zig:541 copyString`) |
| 7 | Malformed XMIDI / MIDI sequence | file to process | Crash, memory exhaustion | Partial: saturating cursor arithmetic, fixed loop stack (`src/engine/xmidi.zig:383 xmidiToSmf`, `src/engine/midi.zig:497 xmidi_loop_stack`), and a per-buffer jump budget (`src/engine/midi.zig:418 max_xmidi_jumps_per_buffer`) |
| 8 | Malformed or oversized audio file (MP3/OGG/WAV/FLAC) | file to process | Crash, memory exhaustion | Partial: declared-size caps in `src/engine/audio_detect.zig:15 max_declared_image_size`, whole-file cap in `src/engine/digital.zig:1348 root.max_file_load_bytes`; the decode itself is delegated to miniaudio and TinySoundFont (`src/engine/digital.zig:1336 loadFromFile`) |
| 9 | App VFS callback reports an arbitrary file size | game to DLL | Heap exhaustion in the game process | Mitigated: same 256 MiB cap as the direct path (`src/root.zig:427 max_file_load_bytes`) |
| 10 | Caller-supplied pointer/length pairs trusted verbatim | game to DLL | Read/write of game memory on a bad call | Unmitigated by ABI necessity (see [Game process boundary](#1-game-process-boundary)) |
| 11 | Debug logging enabled by environment variable | environment to process | Verbose internal logging to disk, paths and asset names disclosed | Mitigated: opt-in, 64 MiB cap (`src/utils/logger.zig:14 max_log_bytes`) |
| 12 | `TMPDIR` redirects the ASI image write | environment to process | PE image written into an attacker-chosen directory | Unmitigated (`src/api/rib.zig:183 TMPDIR`) |

## 1. Game process boundary

Everything crossing this boundary arrives through a C export in `src/api/`. The
host game is inside the process and therefore fully trusted for memory safety:
these are not remote attack vectors, they are the ABI contract.

- Raw pointer plus length pairs with no length validation: `AIL_file_type`
  (`src/api/file.zig:17 AIL_file_type`), `AIL_file_write`
  (`src/api/file.zig:25 AIL_file_write`), `AIL_load_sample_buffer`
  (`src/api/digital.zig:434 AIL_load_sample_buffer`), `AIL_set_sample_address`
  (`src/api/digital.zig:277 AIL_set_sample_address`), `AIL_quick_load_mem`
  (`src/api/quick.zig:58 AIL_quick_load_mem`).
- `AIL_file_read` (`src/api/file.zig:11 AIL_file_read`) returns a pointer to a
  whole file the caller must `AIL_mem_free_lock`, or writes it into a
  caller-supplied `dest` of unknown size. With `dest` null the size is
  materialised twice: once by the VFS read (`src/root.zig:395 fileCallbackReadAll`)
  and again by a `malloc` of the same length (`src/root.zig:492 std.c.malloc`).
  Both copies are bounded by the same 256 MiB cap, so the peak is twice the cap
  rather than an arbitrary length, but a game that supplies a `dest` smaller than
  the file still has it overrun: the copy is a raw `@memcpy` with no length.
- Game-supplied VFS function pointers installed as globals and then called by
  the loader: `AIL_set_file_callbacks` (`src/api/file.zig:56 AIL_set_file_callbacks`).
  `AIL_set_file_async_callbacks` (`src/api/file.zig:65 AIL_set_file_async_callbacks`)
  discards the supplied async callback and delegates to the synchronous form, so
  a game that installs async callbacks has them invoked synchronously.
- Game-supplied callbacks stored but never invoked: `AIL_set_mem_callbacks`
  (`src/api/memory.zig:48 AIL_set_mem_callbacks`), `AIL_mem_use_malloc`
  (`src/api/memory.zig:36 AIL_mem_use_malloc`). A game that installs a custom
  allocator is silently ignored and the module allocates from its own heap.
- Path inputs: `AIL_set_redist_directory` (`src/api/digital.zig:76 AIL_set_redist_directory`),
  `AIL_quick_load` (`src/api/quick.zig:21 AIL_quick_load`), `RIB_load_application_providers`
  (`src/api/rib.zig:41 RIB_load_application_providers`).
- `AIL_WAV_file_write` (`src/api/digital.zig:1042 AIL_WAV_file_write`) takes a
  game-supplied filename and creates or truncates the file at that path, then
  writes a WAV built from a game-supplied `(data, len)` pair
  (`src/api/digital.zig:1076 createFile`). It is the only export that writes
  audio output to disk, and the write is a truncating create rather than an
  append, so a caller-chosen name destroys whatever was there. No path
  validation, no extension check, no prompt. The `AIL_file_write` export
  (`src/api/file.zig:25 AIL_file_write`) reaches the same create path for
  arbitrary bytes.

There is no `AIL_open_file`/`AIL_close_file`/`HSFILE` handle API. The file
service surface is `src/api/file.zig`, the v9 spellings
(`src/api/v9.zig:103 AIL_file_read_info`, `src/api/v9.zig:111 AIL_file_size_info`,
which forward to the same uncapped-`dest` write described above), and the
callback VFS in `src/root.zig:371 setFileCallbacks`.

Callbacks are a second game-to-DLL-to-game boundary and the set is larger than
the four named above. Stored and later invoked, several of them on the audio
thread: `AIL_register_EOS_callback` (`src/api/digital.zig:200 AIL_register_EOS_callback`),
`AIL_register_mix_callback` (`src/api/v9.zig:282 AIL_register_mix_callback`),
`AIL_set_sample_processor` (`src/api/digital.zig:547 AIL_set_sample_processor`),
`AIL_register_stream_callback` (`src/api/stream.zig:116 AIL_register_stream_callback`),
`AIL_register_beat_callback` (`src/api/midi.zig:398 AIL_register_beat_callback`),
and `AIL_configure_logging` (`src/api/v9.zig:84 AIL_configure_logging`). Like the
file callbacks, these are the ABI contract rather than an attack vector: the
module calls back into the game it was loaded by, and a plugin that has already
run holds the game's authority anyway. They are named here so the boundary count
is right, not because each is a threat.

`AIL_register_timer` (`src/api/timer.zig:4 AIL_register_timer`) is the one
concurrency boundary in the module: it spawns a module-owned thread
(`src/engine/timer.zig:136 std.Thread.spawn`) that invokes a game function
pointer on a stack the game does not own. It is not an IPC endpoint, and the
thread is the module's own rather than an external one, so the "no IPC
endpoint" claim in [Environment boundary](#3-environment-boundary) still holds.

## 2. File system to process

Data files opened by the game and handed to the DLL. These are the inputs a
hostile file, download, or mod pack reaches.

| Input | Entry point | Notes |
|-------|-------------|-------|
| Audio file | `AIL_open_stream` / `AIL_quick_load` / `AIL_quick_load_and_play` -> `Sample.loadFromFile` (`src/engine/digital.zig:1336 loadFromFile`) | Rejects a zero length and anything above the shared 256 MiB cap (`src/engine/digital.zig:1348 root.max_file_load_bytes`), then allocates the whole file. That check is the direct-filesystem branch only: with a VFS installed the same three entry points read through `fileCallbackReadAll` (`src/root.zig:395 fileCallbackReadAll`) and are capped by the shared cap there (`src/root.zig:427 max_file_load_bytes`) instead. |
| Audio in memory | `Sample.load` (`src/engine/digital.zig:1363 load`) | A positive caller length is used as a slice length with no cap; a zero or negative length falls to `loadFromUnownedMemoryUnknownSize`, which derives a bounded image from the header. The uncapped case is the in-process ABI, not a file input. |
| XMIDI / MIDI | `AIL_init_sequence` -> `xmidiToSmf` (`src/engine/xmidi.zig:383 xmidiToSmf`) | Declared extents clamped to the buffer with saturating arithmetic; VLQ continuation capped at 4 bytes (`src/engine/xmidi.zig:85 bytes_read`); FOR/NEXT loop stack fixed at 8 with a depth check (`src/engine/midi.zig:496 xmidi_loop_depth`). |
| BANK soundbank | `AIL_open_soundbank` (`src/api/v8.zig:534 AIL_open_soundbank`), `AIL_open_soundbank_v8` (`src/api/v8.zig:967 AIL_open_soundbank_v8`), `MilesAddSoundBank` (`src/api/miles.zig:378 MilesAddSoundBank`) -> `loadFromMemory` (`src/engine/soundbank.zig:625 loadFromMemory`) | Tag and version are validated before any allocation; every offset read passes through the bounds-checked `rdU32` (`src/engine/soundbank.zig:272 rdU32`); metadata is NUL-terminated by an allocated sentinel. `meta_size` is checked after a path dupe and a registry reserve (`src/engine/soundbank.zig:635 dupeResolvedPathZ`, `src/engine/soundbank.zig:46 registryReserve`), so it is not validated before the first allocation; both of those are sized by the caller's path, not by file content. |
| Bank asset path | `AIL_sound_asset_info` (`src/api/v9.zig:201 AIL_sound_asset_info`) -> `soundAssetInfo` (`src/engine/soundbank.zig:565 soundAssetInfo`) | Writes `*<bank file name><sound file name>` into a caller buffer that the ABI passes no size for, from two names that come out of the bank file. Bounded by the module instead: a pair over `max_asset_path_bytes` is reported unresolved and nothing is written (`src/engine/soundbank.zig:211 max_asset_path_bytes`). `AIL_sound_asset_filename` (`src/api/v8.zig:885 AIL_sound_asset_filename`) is a no-op stub. |
| Event bytecode | `AIL_next_event_step` (`src/api/v8.zig:518 AIL_next_event_step`) -> `nextStep` (`src/engine/event.zig:702 nextStep`) | Step type is range-checked before the enum conversion, the header chain is depth-limited, and string copies refuse to pass `wlimit` (`src/engine/event.zig:541 copyString`). |
| DLS container | `AIL_extract_DLS` / `AIL_find_DLS` / `AIL_list_DLS` / `AIL_merge_DLS_with_XMI` / `AIL_filter_DLS_with_XMI` (`src/api/dls.zig:107 AIL_filter_DLS_with_XMI`) | Pointer images capped at 256 MiB (`src/engine/dls_container.zig:74 max_ptr_image_size`); merged image size checked with `std.math.add`. `AIL_list_DLS` takes a pointer with no length and derives one from the header, so a lying RIFF size would otherwise drive a scan past the caller's buffer; only a 64 KiB prefix of the declared image is dereferenced (`src/api/dls.zig:395 list_dls_scan_limit`, `src/api/dls.zig:400 AIL_list_DLS`). The `cmemdup` paths read up to the declared 256 MiB from a bare pointer. |
| DLS / SF2 soundfont load | `AIL_DLS_load_file` (`src/api/dls.zig:21 AIL_DLS_load_file`), `AIL_DLS_load_memory` (`src/api/dls.zig:127 AIL_DLS_load_memory`) | The VFS read is capped by the shared 256 MiB cap; the memory form takes a declared size and rejects only what exceeds `maxInt(c_int)`. The SF2 parse itself is delegated to TinySoundFont, so the container bounds here are the only ones the module applies. |
| WAV cue markers | `AIL_WAV_marker_count` (`src/api/v8.zig:143 AIL_WAV_marker_count`), `AIL_WAV_marker_by_index` (`src/api/v8.zig:150 AIL_WAV_marker_by_index`), `AIL_WAV_marker_by_name` (`src/api/v8.zig:161 AIL_WAV_marker_by_name`) | A full RIFF chunk walk over a length-less image, bounded by the same 256 MiB declared-size cap rather than by the caller's buffer. |
| Event string enqueue | `MilesEnqueueEvent` (`src/api/miles.zig:184 MilesEnqueueEvent`), `MilesEnqueueEventByName` (`src/api/miles.zig:193 MilesEnqueueEventByName`), `MilesStartSoundInstance` (`src/api/miles.zig:234 MilesStartSoundInstance`) | The Miles event path is separate from `AIL_next_event_step` and reaches the same event decoder. The Miles fuzz harness covers it (`src/fuzz_native_test.zig:1722 test`). |
| SMF conversion and listing | `AIL_MIDI_to_XMI` (`src/api/midi.zig:197 AIL_MIDI_to_XMI`), `AIL_list_MIDI` (`src/api/midi.zig:220 AIL_list_MIDI`) | `AIL_list_MIDI` has a 14-byte header floor and no upper bound; `AIL_MIDI_to_XMI` sizes its output from the caller-supplied input length. |
| File type sniffing | `AIL_file_type` (`src/api/file.zig:17 AIL_file_type`), `AIL_file_type_named` (`src/api/v8.zig:324 AIL_file_type_named`) -> `detectFileType` (`src/engine/audio_detect.zig:109 detectFileType`) | Walks WAV/AIFF/MIDI/MP3/OGG/FLAC headers of a caller buffer. The SMF sniffer `AIL_init_sequence` reaches is bounded by the 16 MiB streaming sentinel (`src/engine/audio_detect.zig:9 streaming_sentinel_size`), not by the 256 MiB declared-image cap the DLS pointer path uses. |
| MP3 frame walk | `AIL_inspect_MP3` (`src/api/v7.zig:833 AIL_inspect_MP3`), `AIL_enumerate_MP3_frames` (`src/api/v7.zig:845 AIL_enumerate_MP3_frames`) | Frame walk is bounded by the image, not by a frame count (`src/engine/mp3.zig:199 enumerateFrames`). |

Amplification and quota notes: there is no rate limit, quota, or frame-count
cap anywhere in the module. The whole-file reads scale with the input. The 256 MiB
cap is per allocation, not a process ceiling: `AIL_merge_DLS_with_XMI` sums two
capped images and can reach roughly twice it in a single `malloc`
(`src/api/dls.zig:454 std.math.add`, `src/api/dls.zig:461 std.c.malloc`), and
`AIL_file_read` holds two copies of the same file at once
(`src/root.zig:492 std.c.malloc`). The one
amplifying reservation, the XMIDI event list, is capped rather than sized from
the chunk: `ensureTotalCapacity` takes `@min(evnt.len / 2, max_preallocated_events)`
(`src/engine/xmidi.zig:214 ensureTotalCapacity`) against a 64K-event ceiling
(`src/engine/xmidi.zig:74 max_preallocated_events`), and the list grows on
demand past the cap.

## 3. Environment boundary

Three environment variables are read, each through the process environment
rather than any validated config file. Each value is checked before use, and a
rejected one is reported on stderr with the reason.

- `OPENMILES_DEBUG` (`src/utils/logger.zig:188 GetEnvironmentVariableW`):
  enables verbose logging, capped at 64 MiB (`src/utils/logger.zig:14 max_log_bytes`).
  Debug builds enable it by default (`src/utils/logger.zig:173 builtin.mode`), so
  a debug build in a shared directory discloses asset names, file paths, and
  internal state to any local user who can read the file. A value outside the
  documented set is refused rather than read as off, so a typo cannot silently
  suppress the only trace a failure leaves (`src/utils/logger.zig:70 parseDebugFlag`).
- `OPENMILES_LOG_PATH` (`src/utils/logger.zig:208 GetEnvironmentVariableW`):
  chooses the debug log file. Unset, empty, or longer than 1024 bytes keeps
  `openmiles.log` in the current directory. A path the process can write is
  otherwise followed, so the log can be placed outside a shared game directory.
- `TMPDIR` (`src/api/rib.zig:183 TMPDIR`): the non-Windows directory the
  in-memory ASI image is written to. Any process that can set the game
  process's environment chooses where a PE image is written and loaded from.
  A `TMPDIR` that is empty, too long, or relative is refused
  (`src/api/rib.zig:219 reportTempDir`), and a set one that does not exist falls
  through to the cwd-relative `./om_asi_*.dll` form
  (`src/api/rib.zig:312 om_asi_`), which lands in the game directory instead.
  Unmitigated.
- `GetTempPathW` (`src/api/rib.zig:170 GetTempPathW`): on Windows, `TEMP` is
  per-user, so the write is confined to the user's own profile. A directory that
  leaves no room for the file name under `MAX_PATH`, which the long-path opt-in
  and not the process decides, falls back to the game directory rather than
  failing to load the image (`src/api/rib.zig:150 pathFitsUnitLimit`). Every
  fall back to the game directory, the resolved directory being absent,
  too full for the name, or unwritable alike, is reported on stderr
  (`src/api/rib.zig:219 reportTempDir`) and not only through the debug log, so
  the choice an environment made is visible to whoever is running the game.
- No registry, no network configuration, no service installation, no scheduled
  job, no IPC endpoint.

A run that exports `OPENMILES_DEBUG` also gets the effective configuration on
stderr, once, whether the value asked for the log on or off
(`src/utils/logger.zig:323 echoConfigOnce`). The `off` case is the one with no
log to read the answer out of. What the line carries is the build mode, the
`mss_version` the image was built for, and the log path: no secret, since the
only values the library takes are paths and a boolean, and the path is scrubbed
of control characters first (`src/utils/logger.zig:284 writeConfigLine`).

## 4. Deployment artifact boundary

Three entry points load plugin code, and all three end at the same
`Provider.load` choke point, which hands the path to the OS loader.

1. `AIL_startup` (`src/api/digital.zig:18 AIL_startup`) reaches `startup()`,
   which scans the current working directory: `loadApplicationProviders(".")`
   (`src/root.zig:744 loadApplicationProviders`).
2. `AIL_set_redist_directory` (`src/api/digital.zig:76 AIL_set_redist_directory`)
   records a game-supplied directory, and `loadAllAsi` scans it
   (`src/engine/digital.zig:691 loadAllAsi`), called on a directory change
   (`src/root.zig:1160 loadAllAsi`) and again when a digital driver opens
   (`src/root.zig:1664 loadAllAsi`). The directory is not restricted to the game
   directory: the game names any path, so a redist directory pointing at a
   download or per-user shared folder extends plugin execution to every plugin
   extension found there.
3. `RIB_load_provider_library` (`src/api/rib.zig:450 RIB_load_provider_library`,
   and its stdcall alias `src/api/rib.zig:748 RIB_load_provider_library_std`)
   calls `Provider.load` directly on a game-supplied path
   (`src/api/rib.zig:451 std.mem.span`). This path is exported from v4 through
   v9 and is reachable from a stock game with no scan, no `AIL_startup`, and no
   redist directory configured. See [Plugin load without a scan](#4a-plugin-load-without-a-scan).

Controls present, on both scans:

- Extension allowlist `.asi`, `.m3d`, `.flt` (`src/root.zig:642 isPluginExtension`).
- Filename rejection of `..`, `/`, `\`, a trailing dot or space, `:` (an NTFS
  named stream), and the DOS device names `CON`, `PRN`, `AUX`, `NUL`, `CLOCK$`,
  `COM1`-`COM9`, `LPT1`-`LPT9`, so a directory entry cannot escape the scan
  directory and cannot name a device the loader resolves instead of a file.
  The device name is matched after the path parser's own trailing-space strip,
  so `con .asi` is rejected as `CON` and not read as a file called `con `
  (`src/root.zig:648 isSafePluginFilename`).
- A rescan that finds an already-loaded module skips it, so one module is
  loaded once per process: `src/root.zig:836 isPluginAlreadyLoaded` for the
  application list, and `src/root.zig:849 isPluginLoadedAnywhere` for the
  redist scan, which also skips modules the application list already holds.
- The loaded module runs in-process with the game's full authority. This is the
  original MSS design, and plugins are unsigned.

Gaps:

- No signature check, no allowlist of known plugins, no prompt. Any file with a
  plugin extension in the game directory, or in a directory the game points the
  redist search at, executes with game privileges.
- `Provider.load` resolves the path case-insensitively before loading
  (`src/rib/provider.zig:146 maybeResolveCaseInsensitivePath`), so a symlink or
  alternate-case name reaches whatever the resolver finds.
- Windows DLL search order applies to a relative path, so a plugin name that
  also exists in the system directory can resolve elsewhere than the scanned
  directory. Nothing in the loader pins the resolved path after resolution.
- A loaded plugin registers RIB interfaces the module then calls back with data
  files. That is a privilege transition the model must name: a plugin's codec
  entry points run with the game process's full authority, and the module
  hands them pointers derived from untrusted files.

## 4a. Plugin load without a scan

`RIB_load_provider_library` is a code-execution entry point that the controls in
[Deployment artifact boundary](#4-deployment-artifact-boundary) do not reach.
Every control listed there is a property of the two *scans*, and this call site
performs no scan:

| Control | Applies to a scan | Applies to `RIB_load_provider_library` |
|---------|-------------------|-------------------------------------------|
| Extension allowlist `.asi`/`.m3d`/`.flt` | `src/root.zig:642 isPluginExtension` | No: the extension is never inspected, so any file the OS loader accepts is loaded |
| Filename safety: `..`, separators, NTFS streams, DOS device names | `src/root.zig:648 isSafePluginFilename` | No: a path with `..` segments, a named stream, or a device name reaches the loader |
| Already-loaded dedup, one module per process | `src/root.zig:836 isPluginAlreadyLoaded`, `src/root.zig:849 isPluginLoadedAnywhere` | No: the same module can be loaded repeatedly, and a module the application list already holds is loaded again |
| Random exclusive temp file | `src/api/rib.zig:318 exclusive` | No: it never takes the in-memory image path at all |

`Provider.load` itself performs no path validation. It takes the basename as the
display name, resolves the path case-insensitively, and opens it
(`src/rib/provider.zig:138 load`). So the two scans are the only place any path
check exists in the module.

Assessment: the caller is inside the process and is trusted for memory safety
under the same rule as the rest of [Game process boundary](#1-game-process-boundary),
so this is the ABI contract rather than a remote vector. It is listed as threat
#3 because a game that builds this path from a data file (a mod directory, a
downloaded content folder, a save file) turns a data-controlled string into a
code-execution path with no extension filter and no name check in between, which
is a strictly weaker position than either scan. There is no fix proposed here;
the gap is recorded for sec-review.

## 5. In-memory ASI image boundary

`AIL_open_ASI_provider` (`src/api/rib.zig:238 AIL_open_ASI_provider`) takes a PE
image in memory, writes it to a temporary file, and loads it.

Controls present:

- The file name is `om_asi_<random>.dll` with 64 bits of entropy from
  `openmiles.randomNameBytes`, which draws from the run's seeded PRNG under a
  simulation and otherwise from `io.randomSecure`; failure to obtain entropy
  fails closed rather than falling back to a guessable name
  (`src/root.zig:1483 randomNameBytes`, called from
  `src/api/rib.zig:294 randomNameBytes`).
- The file is created with `.exclusive = true` (`src/api/rib.zig:318 exclusive`),
  so a planted name cannot be opened for overwrite and a race replacement loses.
- The file is deleted after the module is unloaded (`src/rib/provider.zig:194 deinit`).
  The removal goes through the same fault seam as the rest of the file I/O
  (`src/utils/fs_compat.zig:292 deleteFile`), so the locked-image case, where
  the file stays on disk for the life of the process, is a step a replay can
  reproduce rather than one that needs a real load to provoke.

Gaps:

- A local process running as the same user can still list the temp directory and
  race between create and load. Windows would need a section-backed or
  `LOCKFILE_EXCLUSIVE` handle kept open across the load to close this.
- The `TMPDIR` environment input above chooses the directory.
- The non-Windows fallback writes `./om_asi_*.dll` into the current directory
  (`src/api/rib.zig:312 om_asi_`), which is the game directory and therefore a
  more visible location than a temp directory.
- The image is only checked for an `MZ` signature before being written and loaded
  (`src/api/rib.zig:249 raw`); no further validation is possible, since
  the caller wants arbitrary code to run.
- A repeated open of the same image is answered from the open-image registry
  (`src/rib/provider.zig:358 publishImage`) with the module already loaded, and
  the copy built for the repeat is unloaded before the open returns, so a retry
  leaves one module and one temp image rather than one of each per attempt. The
  key is the image's content, so it holds whatever the caller supplies; the
  registry is process state, not a trust decision, and the image behind an
  entry has been through the same checks as the first one.

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
| Whole-file read cap, 256 MiB | `src/root.zig:427 max_file_load_bytes` | Oversized file allocation on every whole-file read path: the VFS branch checks it at `src/root.zig:415 max_file_load_bytes`, the direct branch at `src/root.zig:457 max_file_load_bytes`, and `AIL_file_read` before its `malloc` at `src/root.zig:509 max_file_load_bytes` |
| Whole-file read cap on the sample loader | `src/engine/digital.zig:1348 root.max_file_load_bytes` | Oversized audio file through `AIL_open_stream` / `AIL_quick_load` on the direct-filesystem branch; the VFS branch is covered by the shared cap above |
| Declared container size cap, 256 MiB | `src/engine/audio_detect.zig:15 max_declared_image_size` | Lying RIFF/FORM headers |
| Pointer image cap, 256 MiB | `src/engine/dls_container.zig:74 max_ptr_image_size` | Lying DLS container sizes over bare pointers |
| Bounds-checked offset read | `src/engine/soundbank.zig:272 rdU32` | Every BANK offset and count |
| Bank asset-path cap, MAX_PATH | `src/engine/soundbank.zig:211 max_asset_path_bytes` | A bank naming a sound with an arbitrarily long file name writing past a game buffer sized from the requirement `AIL_sound_asset_info` returned |
| ELF dynamic-section walk bounded by the image | `src/utils/dynlib.zig:119 dyn_entries` | A plugin image with no `DT_NULL` inside its mapping driving the relocation scan past the end of the map |
| Bounded `AIL_list_DLS` scan, 64 KiB | `src/api/dls.zig:395 list_dls_scan_limit` | A lying DLS header size driving a scan past a length-less caller pointer |
| Saturating cursor arithmetic and clamped chunk ends | `src/engine/xmidi.zig:383 xmidiToSmf` | Lying XMIDI chunk sizes |
| XMIDI event pre-allocation ceiling, 64K events | `src/engine/xmidi.zig:74 max_preallocated_events` | A file-controlled EVNT chunk sizing a multi-gigabyte reservation |
| Fixed loop stack with depth check | `src/engine/midi.zig:497 xmidi_loop_stack` | XMIDI FOR/NEXT recursion |
| Per-buffer XMIDI jump budget, 256 | `src/engine/midi.zig:418 max_xmidi_jumps_per_buffer` | A zero-frame FOR/NEXT body spinning the audio thread; a full loop stack degrades to a log line rather than an out-of-bounds write |
| Unpredictable exclusive temp file | `src/api/rib.zig:318 exclusive` | Temp-file pre-planting and name race |
| Redist rescan only on an actual path change | `src/root.zig:1146 unchanged` | Repeated directory walks and double plugin loads from a game that re-sets the same redist path |
| Bank registry returns the loaded bank for a repeated path | `src/engine/soundbank.zig:84 registryAcquireBySource` | Duplicate copies of one bank accumulating on reload |
| Stream ring depth clamped to the SDK range | `src/engine/stream_buffer.zig:129 clamped` | Caller-supplied buffer count turning into an oversized ring |
| Plugin extension allowlist and separator rejection | `src/root.zig:642 isPluginExtension` | Directory traversal in the CWD plugin scan |
| Step-type range check, header depth limit, `wlimit`-bounded string copies | `src/engine/event.zig:541 copyString` | Crafted event bytecode |
| Log cap, 64 MiB | `src/utils/logger.zig:14 max_log_bytes` | Unbounded debug log growth |
| Fuzz harness over every export that takes input | `src/fuzz_all_test.zig:35 test` | Regression coverage on the export surface |
| Native-path fuzz harness | `src/fuzz_native_test.zig:244 test` | Regression coverage on non-Windows paths |
| Miles event-enqueue fuzz harness | `src/fuzz_native_test.zig:1722 test` | Crafted event strings driving the instance list, the cache and persist sets, and the per-label caps |
| Export-parity and unit suites | `src/main_test.zig:25 test`, `src/api_coverage_test.zig:45 test` | ABI regressions |

Single points of failure:

- `fileCallbackReadAll` (`src/root.zig:395 fileCallbackReadAll`) is the only
  place a VFS-reported file length becomes an allocation. It re-checks
  `max_file_load_bytes` itself (`src/root.zig:415 max_file_load_bytes`)
  rather than inheriting a cap from `readWholeFile`
  (`src/root.zig:446 readWholeFile`), which returns the VFS result at
  `src/root.zig:395 fileCallbackReadAll` before reaching its own direct-path
  check at `src/root.zig:457 max_file_load_bytes`. That duplication is
  deliberate but is the thing to re-verify: a cap added to `readWholeFile`
  alone would leave the VFS boundary open, and a new whole-file read path that
  skips this function inherits no cap.
- `Provider.load` (`src/rib/provider.zig:138 load`) is the single choke point for
  every code-execution path, whether the module came from disk or from the temp
  file.
- The C ABI shape itself: several exports take `(pointer, length)` with no way to
  validate the length, so those calls are only as safe as the game.

## 8. Abuse cases

Business-logic abuse, not memory corruption: a caller inside the process that
behaves correctly but against the module's interest. The module has no quota, no
rate limit, and no per-session budget, so every case below is bounded by
something other than a control in this tree.

- **Aggregate bank memory is uncapped across distinct files.** The 256 MiB cap
  is per whole-file read, not per process, and the bank registry
  (`src/engine/soundbank.zig:46 registryReserve`) reserves a slot with no count
  limit. A game, or a mod pack driving one, that opens many distinct `.BANK`
  files and keeps the handles retains every parsed metadata block
  (`src/engine/soundbank.zig:231 meta`). Repeating the *same* file does not
  accumulate: a second load of one path returns the already-loaded bank
  (`src/engine/soundbank.zig:84 registryAcquireBySource`), so the abuse needs
  distinct paths, which a download folder supplies.
- **A redist directory pointed at a shared or download folder widens plugin
  execution.** `AIL_set_redist_directory` (`src/api/digital.zig:76 AIL_set_redist_directory`) records whatever the game passes and
  `loadAllAsi` (`src/engine/digital.zig:691 loadAllAsi`) loads every plugin
  extension it finds there. The game is not restricted to its own directory, so
  a game that honours a per-user or downloaded content path is a plugin
  execution path the user did not install. The rescan-on-change check
  (`src/root.zig:1146 unchanged`) bounds the work to a directory that actually
  changed, so a game that re-sets the same path each time does not re-walk it,
  but a game that alternates between two paths re-walks both.
- **Write-path abuse through `AIL_WAV_file_write`.** The export creates or
  truncates a caller-named file (`src/api/digital.zig:1076 createFile`). A game
  that builds the name from a level or save name turns a data-file-controlled
  string into a path: `..` segments in the name are not rejected, and the write
  follows them. The caller is in-process, so this is a confused-deputy case
  rather than a remote one: the module becomes the write primitive for a string
  it did not validate.
- **No client-side-only enforcement exists to trust.** Nothing in this module
  is a browser or a wire protocol: there is no client, so the "trust the client
  to enforce" class does not apply. The nearest equivalent is the game trusting
  the module's own validation, which is why the parser bounds in
  [Mitigation map](#7-mitigation-map) are the whole of the file-input
  defence.
- **Unbounded work per call, bounded work per process.** Stream ring depth is
  clamped to the SDK range (`src/engine/stream_buffer.zig:129 clamped`), and
  mix operations are capped (`src/api/digital.zig:810 max_mix_operations`), but
  a caller can still make a decode take arbitrarily long by naming an
  arbitrarily long file within the 256 MiB cap, with no timeout anywhere in
  the module.

## 9. Response readiness

- Security-relevant events leave one trace: the `openmiles.log` debug log, which
  is off by default in release builds. There is no audit record of which bank,
  soundbank, or plugin image was loaded, and no record of a failed load beyond a
  log line.
- The intake half of a disclosure path is documented, the response half is not.
  [SECURITY.md](../SECURITY.md) names the channel (a private GitHub security
  advisory), the report contents it wants, the supported-version policy, and an
  explicit in-scope and out-of-scope list; `CONTRIBUTING.md` requires a landed
  change to carry a changelog entry, tests, and a `docs/API_STATUS.md` update.
  What is undefined is the timeline: SECURITY.md states there is no disclosure
  deadline or embargo policy yet, and no owner or triage SLA is set anywhere in
  the repository. A previous revision of this model claimed no path existed at
  all, which SECURITY.md contradicted; the accurate statement is that triage
  priority is documented and timing is not.

## Unmitigated threats, ranked

1. Unsigned plugin execution from the game directory (`src/root.zig:744 loadApplicationProviders`),
   and from any directory the game hands to `AIL_set_redist_directory`
   (`src/engine/digital.zig:691 loadAllAsi`). Inherent to the compatibility
   target; a documented deployment note is the available mitigation.
2. `RIB_load_provider_library` loads a game-named path as code with no extension
   allowlist, no filename safety check, and no already-loaded dedup
   (`src/api/rib.zig:450 RIB_load_provider_library`), so it is a code-execution
   path with fewer controls than either directory scan. See
   [Plugin load without a scan](#4a-plugin-load-without-a-scan).
3. `AIL_WAV_file_write` truncates and overwrites a caller-named path
   (`src/api/digital.zig:1076 createFile`) with no extension check, no path
   validation, and no append. A hostile in-process caller already has the
   game's authority, so the exposure is to a buggy or confused game writing
   over a file it did not mean to name.
4. `AIL_file_read` writes the whole file into a caller-supplied `dest` with a raw
   `@memcpy` and no length argument (`src/root.zig:492 std.c.malloc` path and the
   `dest` branch above it), so a game that hands in a short buffer has it
   overrun by the file length. The ABI passes no destination capacity, so this
   cannot be closed inside the module. `AIL_file_read_info`
   (`src/api/v9.zig:103 AIL_file_read_info`) forwards to the same write.
5. No cap on the number of loaded banks, so a caller that keeps the handles
   for many distinct `.BANK` files retains every parsed metadata block
   (`src/engine/soundbank.zig:46 registryReserve`). Per-read 256 MiB is not a
   process budget.
6. No frame-count or duration limit on MP3 enumeration
   (`src/engine/mp3.zig:199 enumerateFrames`): bounded by the caller's loop, not
   by the module.
7. `TMPDIR` chooses the directory the ASI image is written to
   (`src/api/rib.zig:183 TMPDIR`).
8. Debug logging of paths and asset names in a game directory a second local
   user can read (`src/utils/logger.zig:173 builtin.mode`).
9. The `AIL_mem_*` in-memory stream family (`src/api/v8.zig:396 AIL_mem_close`)
   copies the whole stream into a second `malloc` on close, with no cap beyond
   whatever grew the buffer. The same uncapped-length shape as `AIL_file_read`.

# Export Parity vs Real Miles DLLs

The real `mss32.dll` export table is the ABI ground truth: its decorated names
(e.g. `_AIL_init_sample@8`) are exactly what the import library games linked
against resolves by name, including the stdcall byte-count `@N`. A faithful
build must export the same names with the same decoration.

## Tooling

`scripts/check_exports.py <ours.dll> <reference.dll> [--names-only]` diffs the
two export tables and reports MISSING / DECORATION-MISMATCH / EXTRA. Its exit
code is `missing + mismatch`, so it can gate CI and track progress.

Reference DLLs in-tree:
- v5: `references/MSS-5.x/nolf-sdk-plugins/mss32.dll` (332 exports)
- v6: `references/MSS-6.1/Tools/win/mss32.dll` (355; matches Examples/win)
- v7: `references/MSS-7.x/ragnarok-online-redist/mss32.dll` (332)

## Status

**v6 MISSING: 0 / v7 MISSING: 0** (v5: 2). Every function in the real 6.1 and
7.x export tables is now reproduced with matching stdcall decoration. Resolved
across several passes:

1. 79 spatial/sample/filter functions were implemented with correct decoration
   but over-gated to `.ver=70/80`; floors lowered to `.ver=60`.
2. Reverb/room-type/MIX_RIB_MAIN no-bus variants extended down to v6.
3. 7 version-split functions (arity dips in v7) given v6-specific `.ver=60
   .ver_max=69` entries reusing the large default impl.
4. 4 already-implemented functions (`AIL_ftoa`, `AIL_register_trace_callback`,
   `MSSDisableThreadLibraryCalls`, `AIL_quick_set_low_pass_cut_off`) re-gated to
   their true version ranges (verified against the v5/v6/v7 DLLs).
5. 6 genuinely-missing functions implemented in `src/api/legacy.zig` +
   `AIL_quick_load_named_mem` in `quick.zig`: the 6.x-only embedded-library and
   sample-attribute exports (`AIL_open_library`, `AIL_close_library`,
   `AIL_library_resource_filename`, `AIL_load_sample_attributes`,
   `AIL_save_sample_attributes`). All ABI-faithful stubs with safe defaults,
   fuzzed in `fuzz_all_test.zig`.

## Calling-convention split (resolved)

The real DLL exports the public RIB-interface and DLS APIs as **undecorated
__cdecl** (12 `RIB_*` + 9 `DLS*`), while the AIL_* surface, the RIB
provider-management calls, and `DLSMSSGetCPU` stay **__stdcall/decorated**.
Reproduced via callconv(.c) on those 21 functions plus a `.cdecl` flag on their
export targets. (No .DEF file needed — Zig emits the bare name for cdecl.)

## Result: v5 / v6 / v7 / v8 / v9 are byte-for-byte exact

Against a representative mainline DLL for each major version the export tables
match exactly (0 missing, 0 decoration mismatch):

- v5 vs `MSS-5.x/5.0m-mss32.dll` (also 5.0r): 0 / 0
- v6 vs `MSS-6.0/6.0m-mss32.dll` (also 6.0k): 0 / 0
- v7 vs `MSS-7.x/ragnarok-online-redist/mss32.dll`: 0 / 0
- v8 vs `MSS-8.x/8.0j-mss32.dll`: 0 / 0
- v9 vs `MSS-9.x/9.1d-mss32.dll`: 0 / 0

### v8/v9 specifics

- The RIB interface API switches from __cdecl (undecorated, v6-v8.0b) to
  __stdcall (decorated, v8.0j+/v9); the DLS API is dropped in v8. The debug
  functions (`AIL_debug`, `AIL_indent`, `AIL_mem_printf`, ...) and
  `MilesEventSetAuditionFunctions` are __cdecl in v8/v9.
- v9 targets the **9.1+ family** (bus_index reverb/room args, added in 9.1);
  9.0e is the early-9.0 outlier.
- Several event-step builders gain trailing args in v9
  (`add_apply_environment` @8→@12, `add_control_sounds` @32→@40,
  `add_persist_preset` @16→@20, `add_start_sound` @76→@96); v8 gets the shorter
  forms. `get_soundbank_filename` instead *loses* an arg in v9 (@8→@4).

### Choosing a representative point release

Some functions oscillate arity across point releases, so one `-Dmss-version`
build cannot match every sub-release. We target the **dominant family** per
major version and stay internally consistent:

- `AIL_init_sample`: @4 (v3-6.0) → @8 (6.1) → @12 (v7) → @8 (v8).
- `AIL_sample_buffer_info`: @20 (v5, 6.0, v7) → @24 (6.1).
- `AIL_request_EOB_ASI_reset`: @8 (6.0) → @12 (6.1) → @8 (7.0b-d) → @12 (7.0h+).

For v6 we pick the **6.0 mainline** (the ~12-release 6.0a-6.0m family): @4 / @20
/ @8 respectively. This means v6 differs from the rarer 6.1 point release on
those three symbols — an unavoidable trade-off, documented here.

> Note: `MSS-5.x/nolf-sdk-plugins/mss32.dll` is an atypical build (it reports
> the v6-style `@12`/`AIL_open_input` shapes); use `5.0m`/`5.0r` as the v5
> reference instead.

### Next frontier: EXTRA exports

`MISSING` and `DECORATION MISMATCH` are both 0 for v5-v9, so every function a
game *calls* resolves with the correct name and stdcall byte-count. The
remaining axis is EXTRA exports — symbols we export that a given version's DLL
did not have:

| ver | ours | reference | EXTRA |
|-----|------|-----------|-------|
| v4  | 348  | 313       | 35    |
| v5  | 376  | 315       | 61    |
| v6  | 479  | 341       | 138   |
| v7  | 480  | 332       | 148   |
| v8  | 566  | 323       | 243   |
| v9  | 635  | 355       | 280   |

EXTRA breaks down into two very different groups:

1. **Sub-version variance (the large majority).** Of v9's ~280 extras, only 17
   are absent from *every* Miles DLL; the other ~263 are genuine Miles functions
   that simply aren't in the one sub-version we diff against (they exist in other
   9.x point releases, or are earlier functions a later release dropped).
   Exporting these is a benign superset — the build serves more titles, not
   fewer — and forcing EXTRA to 0 against one sub-version would *reduce* fidelity
   to the others.

2. **Truly spurious (17, in no Miles DLL or SDK header).** `RIB_MAIN` (removed —
   real plugins export `RIB_Main`; the host exports `MIX_RIB_MAIN`),
   `DllMainCRTStartup` (a Zig/lld entry-point artifact), and 15 convenience
   wrappers the project added (`AIL_pause_sequence`, `AIL_quick_stop`,
   `AIL_open_midi_driver`, ...). The wrappers are harmless for real games (never
   named in any header) and several back the project's own C tests, so they are
   kept deliberately.

**Why not auto-raise floors:** lowering EXTRA by raising each function's `.ver`
floor to its first-appearance is unsafe to automate. A first-appearance map
built from the reference DLLs cannot cleanly separate 6.0 from 6.1 (different
directories, overlapping majors), and an over-raise silently turns an EXTRA into
a MISSING — regressing the verified byte-exact parity. The byte-exact
MISSING/MISMATCH result (every function a game *calls* resolves with the correct
ABI) is the load-bearing fidelity guarantee; EXTRA-trimming is deferred as
careful, individually-verified work.

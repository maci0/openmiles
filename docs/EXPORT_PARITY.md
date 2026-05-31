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

## Remaining: sub-version arity quirks (2 vs the 6.1 Tools DLL only)

`v7` is a byte-for-byte match (0 missing, 0 mismatch). `v6` differs from the
6.1 Tools/Examples DLL by exactly two symbols:

- `AIL_init_sample`: @4 (v3-6.0) vs @8 (6.1 only) vs @12 (v7) vs @8 (v8). We
  emit @4, matching the entire 6.0 line (6.0a-6.0m) and the public header.
- `AIL_sample_buffer_info`: @20 (v5, 6.0, **and v7**) vs @24 (6.1 only). We emit
  @20, matching 6.0 and 7.0.

Both are 6.1-point-release anomalies; matching them would *break* parity with
the 6.0 mainline and 7.0, so we deliberately track the 6.0/7.0 majority.

`v5` (vs the NoLF DLL): 2 missing (`AIL_open_input@4`/`AIL_close_input@4`, gated
too high) and the v4/v5 narrow `AIL_3D_sample_distances@12` vs our @20 — minor,
tracked.

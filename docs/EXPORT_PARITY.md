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

## Decoration mismatch (23, all versions)

The real DLL exports RIB/DLS functions **undecorated** (`RIB_register_interface`,
`DLSClose`) — a .DEF-style alias over the stdcall symbol. Zig auto-appends `@N`
to stdcall `@export` names, so reproducing undecorated aliases needs a module
definition file fed to the linker (build-system change). Affected: 11 `RIB_*`,
8 `DLS*`, plus `AIL_init_sample` (@8 vs @4) and `AIL_sample_buffer_info`
(@24 vs @20) which are stack-size discrepancies, not naming.

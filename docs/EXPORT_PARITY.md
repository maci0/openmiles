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

## Status (v6 vs 6.1)

Missing went 103 → 24 after lowering the version floor on 79 spatial/sample/
filter functions that 6.1 shipped but were over-gated to v7/v8. Remaining v6
gaps:

### Truly unimplemented in 6.1 (10) — need function bodies
- `AIL_close_library@4`, `AIL_open_library@8`, `AIL_library_resource_filename@16`
- `AIL_load_sample_attributes@8`, `AIL_save_sample_attributes@8`
- `AIL_quick_load_named_mem@12`, `AIL_quick_set_low_pass_cut_off@12`
- `AIL_ftoa@4`, `AIL_register_trace_callback@8`, `MSSDisableThreadLibraryCalls@4`

### Arity mismatch — my signature differs from 6.1 (7), needs v6-specific variant
- `AIL_room_type` real `@4` vs mine `@8`; `AIL_set_room_type` real `@8` vs `@12`
- `AIL_digital_master_reverb` real `@16` vs `@20`; `AIL_set_digital_master_reverb` `@16` vs `@20`
- `AIL_digital_master_reverb_levels` real `@12` vs `@16`; `AIL_set_…` `@12` vs `@16`
- `MIX_RIB_MAIN` real `@8` vs `@20`

### Version-split, deferred from the floor-lowering batch (7)
Functions whose v7 variant differs in arity from the v8+ variant; the correct v6
arity must be confirmed against 6.1 before lowering:
`AIL_request_EOB_ASI_reset`, `AIL_set_sample_low_pass_cut_off`,
`AIL_sample_low_pass_cut_off`, `AIL_sample_channel_levels`,
`AIL_set_sample_channel_levels`, `AIL_set_speaker_reverb_levels`,
`AIL_calculate_3D_channel_levels`.

## Decoration mismatch (23, all versions)

The real DLL exports RIB/DLS functions **undecorated** (`RIB_register_interface`,
`DLSClose`) — a .DEF-style alias over the stdcall symbol. Zig auto-appends `@N`
to stdcall `@export` names, so reproducing undecorated aliases needs a module
definition file fed to the linker (build-system change). Affected: 11 `RIB_*`,
8 `DLS*`, plus `AIL_init_sample` (@8 vs @4) and `AIL_sample_buffer_info`
(@24 vs @20) which are stack-size discrepancies, not naming.

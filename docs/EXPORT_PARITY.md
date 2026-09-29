# Export Parity vs Real Miles DLLs

The real `mss32.dll` export table is the ABI ground truth: its decorated names
(e.g. `_AIL_init_sample@8`) are exactly what the import library games linked
against resolves by name, including the stdcall byte-count `@N`. A faithful
build must export the same names with the same decoration.

## Tooling

`scripts/check_exports.py <ours.dll> <reference.dll> [--names-only] [--strict]` diffs the
two export tables and reports MISSING / DECORATION-MISMATCH / EXTRA on stdout.
It exits `0` when the tables match, `1` when discrepancies were found, and `2`
on a bad invocation (unknown flag, missing file, non-PE input), so it gates CI
on the status alone; `scripts/check_all_versions.sh [--strict]` sweeps every
version. The sweep writes the report to stdout and everything about the run to
stderr, so piping stdout into a reader still yields a well-formed table.

Reference DLLs are not committed (`references/` is gitignored). The canonical
per-version set the sweep uses is the `REF` map in
`scripts/check_all_versions.sh`: 3.6a, 4.0h, 5.0b, 6.1d, 6.5h, 7.0k, 8.0e,
9.1d. Other point releases appear in the historical notes below, where a
different DLL was diffed against.

## Status

**v6 MISSING: 0 / v7 MISSING: 0**. Every function in the real 6.1 and
7.x export tables is reproduced with matching stdcall decoration: version floors
lowered to each symbol's true first appearance, and v6-specific entries added for
the version-split functions. The 6.x-only exports that have no implementation at
all (`AIL_open_library`, `AIL_close_library`, `AIL_library_resource_filename`,
`AIL_load_sample_attributes`, `AIL_save_sample_attributes`) are in
`never_export`, so no build emits them; their implementations stay callable
from the Zig tests and are fuzzed in `fuzz_all_test.zig`.
`AIL_quick_load_named_mem` is a real v7 export (no build other than v7 emits
it), not a `never_export` entry.

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

- `AIL_init_sample`: @4 (v3 through 6.6) → @12 (v7) → @8 (v8).
- `AIL_sample_buffer_info`: @20 (v3 through v7) → @24 (v8).
- `AIL_request_EOB_ASI_reset`: @8 (6.0 through 6.6) → @12 (v7 onward).

For v6 we pick the **6.0 mainline** (the ~12-release 6.0a-6.0m family): @4 / @20
/ @8 respectively. This means v6 differs from the rarer 6.1 point release on
`AIL_init_sample` and `AIL_sample_buffer_info` — an unavoidable trade-off,
documented here.

> Note: `MSS-5.x/nolf-sdk-plugins/mss32.dll` is an atypical build (it reports
> the v6-style `@12`/`AIL_open_input` shapes); use `5.0m`/`5.0r` as the v5
> reference instead.

### Next frontier: EXTRA exports

> The per-version "ours" counts in the tables below are from the sweep runs
> recorded here, which predate the current export table: the default v9 build
> now emits 394 distinct exports (`objdump -p` on
> `zig build -Dtarget=x86-windows`), not the 635 those tables carry. Those 394
> are the 392 names the `src/main.zig` table emits plus the two the build adds
> outside it: `AIL_sprintf` (a `/EXPORT:` directive) and `_DllMainCRTStartup@12`
> (a linker artifact, see below). Treat
> them as the record of a past run, not the current count. The live count comes
> from the built DLL or from `scripts/check_all_versions.sh`; the load-bearing
> claim is the MISSING/DECORATION diff, not the export total. The v6 row's
> reference is a 6.0 mainline binary, which is not one of the references
> `scripts/check_all_versions.sh` names, so that row cannot be reproduced by the
> shipped sweep.

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

2. **Truly spurious (in no Miles DLL or SDK header).** `never_export` in
   `src/main.zig` lists 36 such names: 11 first-generation mistakes, 13
   wrong-name duplicates (a real Miles export exists under a different name,
   which is also emitted, so MISSING stays 0), and 12 v6 "resource library",
   sample-attribute-persistence, and `*_attribute`/`*_preference` spellings the
   real DSP-property surface never used. Their implementations stay callable
   from the Zig tests, which link the module directly. A C harness that
   resolves one of these names by name through `GetProcAddress` no longer finds
   it. The harnesses that still name a `never_export` entry
   (`AIL_open_midi_driver`, `AIL_close_midi_driver`, `AIL_ASI_provider_attribute`,
   `AIL_set_timer_user_data`) load them with `LOAD_FUNC_OPT` in
   `tests/test_utils.h` and skip the section when the symbol is absent, so they
   still run against a current DLL.

   `RIB_MAIN` is a third of a kind and needs no suppression: it was a
   wrong-name duplicate (real plugins export `RIB_Main`, the host exports
   `MIX_RIB_MAIN`) and was renamed rather than dropped, so it is not in the
   table at all.

**EXTRA bounding.** Using a presence map computed over *all* 148
reference DLLs (per-function set of major versions it appears in), every target
was bounded to `[first_appearance, last_appearance]`:

- 24 floors raised (functions gated below first-appearance, e.g.
  `AIL_open_digital_driver` leaking into v3-v5 — v5 uses `AIL_waveOutOpen`).
- 119 `ver_max` caps (functions dropped before v9, e.g. `AIL_waveOutOpen` and
  the pre-sample-handle `AIL_set_3D_position/velocity/orientation` family,
  superseded by `AIL_*_sample_3D_*` in v7).
- `AIL_debug_printf` (a `/EXPORT:`-directive variadic) gated to ≤v8.

Each change was applied only where provably safe (no reference outside the new
range exports the symbol) and re-verified: **all of v4-v9 stay byte-exact (0
missing, 0 mismatch)**. This dropped EXTRA sharply (v7 148→46, v8 243→128,
v9 280→159).

**Remaining EXTRA is sub-version variance, plus one linker artifact:**

1. *Artifacts:* `DllMainCRTStartup` is a Zig/lld entry-point artifact, never a
   real Miles export. It is still in the shipped table as
   `_DllMainCRTStartup@12`: `never_export` only filters the `src/main.zig`
   targets loop, so it cannot suppress a symbol the linker adds on its own.
   It is benign for the load-bearing guarantee, since parity here is
   MISSING/DECORATION, and an absent name would be the failure mode that
   matters. The convenience wrappers counted above *were* eliminated, by
   `never_export`.

The byte-exact MISSING/MISMATCH result remains the load-bearing fidelity
guarantee; EXTRA is now at its safe floor.

## 6.5/6.6 sub-line audit

The byte-exact claim above was originally re-verified against one mainline DLL
per major. A later sweep that diffed the `-Dmss-version=6.5` build against the
**6.5/6.6** references (rather than a 6.0 mainline) surfaced a real sub-line
gap that the single-DLL check had masked:

- **low-pass cutoff arity.** `AIL_set/sample/quick_set_low_pass_cut_off` first
  appear in 6.5 in the narrow no-channel form (`set @8` / `get @4`), carried
  through 7.x; v8 widened them with a channel parameter (`@12` / `@8`). The
  gating exported the wide v8 form for all of 6.x. Re-gated: the `_v7`
  no-channel variant covers ver 65-70, the wide form 80+, and 6.0/6.1 (which
  never had it) no longer export it.
- **12 functions present only in the 6.5/6.6 sub-line** were absent: per-stream
  `volume_levels` / `volume_pan` getter / `reverb_levels` / `low_pass_cut_off`,
  `AIL_set/3D_sample_exclusion`, `AIL_DLS_set/get_reverb_levels`, and
  `AIL_set_digital_master_room_type`. All were added, and all are gone by 7.0,
  but they do not share one floor: the exclusion pair first appears in the
  6.1d patch and is gated ver 61-66, the other ten ver 65-66 (a stream handle is
  a Sample, so the stream forms mirror the sample ones).

This took 6.5/6.6 from 16 discrepancies to **1**, then **0** (see below).

**`stream_background` — resolved.** An undocumented internal symbol leaked into
the 6.1-6.6 export tables with sub-version-varying decoration: `__fastcall`
`@stream_background@0` in 6.1/6.5, undecorated `stream_background` in 6.6,
absent in 6.0 and 8.x+ (and present as `stream_background` in some 7.x). The
inconsistent decoration confirms it is an accidental export, not an API — no
SDK header declares it and no game links it by name. Rather than leave it as a
gap, it is reproduced exactly: a no-op C stub (`mss_stream_background_stub`)
backs a version-gated `/EXPORT:` drectve that emits the reference's exact export
name (`@stream_background@0` for ver 61, the undecorated `stream_background`
for ver 65 and 66). The
export *name* is just a string in the table, so a single cdecl stub serves both
forms. **Every version in `scripts/check_all_versions.sh` is now 0 MISSING /
0 DECORATION MISMATCH against its canonical reference DLL.** The 6.5/6.6 audit
above used a 6.6 reference that is not committed, so the shipped sweep cannot
re-verify `-Dmss-version=6` / `6.6`; `scripts/check_all_versions.sh` lists it
under `UNSWEPT` with that reason, and `scripts/check_versions.py` fails if an
accepted `-Dmss-version` value is neither swept nor listed there.

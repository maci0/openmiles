#!/usr/bin/env bash
# Per-version export-parity sweep: build each -Dmss-version and diff its export
# table against the canonical reference mss32.dll for that release.
#
# This is the regression guard for the version-cutoff work: every shipped MSS
# version is reproduced symbol-for-symbol (correct stdcall @N decoration), so a
# game linking any of these import libraries resolves every symbol it needs and
# the export table is not bloated beyond the reference.
#
# Pass criteria per version: MISSING = 0 and DECORATION = 0. EXTRA is reported
# but, except for the single linker-emitted DllMainCRTStartup entry symbol (and
# the v9 functions newer than the 9.1d binary snapshot), should stay 0.
#
# Usage: scripts/check_all_versions.sh [--strict]
#   --strict folds EXTRA into the per-version pass/fail too.
set -u
cd "$(dirname "$0")/.."

STRICT=""
[ "${1:-}" = "--strict" ] && STRICT="--strict"

# version -> canonical reference DLL
declare -A REF=(
  [3]=references/MSS-3.x/3.6a-mss32.dll
  [5]=references/MSS-5.x/5.0b-mss32.DLL
  [6.1]=references/MSS-6.1/6.1d-mss32.dll
  [6.5]=references/MSS-6.5/6.5h-mss32.dll
  [7]=references/MSS-7.x/7.0k-mss32.dll
  [8]=references/MSS-8.x/8.0e-Mss32.dll
  [9]=references/MSS-9.x/9.1d-mss32.dll
)

fail=0
for ver in 3 5 6.1 6.5 7 8 9; do
  ref="${REF[$ver]}"
  if [ ! -f "$ref" ]; then echo "v$ver: reference missing ($ref) -- skipped"; continue; fi
  if ! zig build -Dmss-version="$ver" -Dtarget=x86-windows 2>/dev/null; then
    echo "v$ver: BUILD FAILED"; fail=1; continue
  fi
  out=$(python3 scripts/check_exports.py zig-out/bin/mss32.dll "$ref" --names-only $STRICT 2>/dev/null)
  rc=$?
  m=$(echo "$out" | grep '^MISSING'    | grep -oE '[0-9]+$')
  d=$(echo "$out" | grep '^DECORATION' | grep -oE '[0-9]+')
  e=$(echo "$out" | grep '^EXTRA'      | grep -oE '[0-9]+$')
  status="ok"
  if [ "$rc" -ne 0 ]; then status="FAIL"; fail=1; fi
  printf "v%-4s MISSING=%-3s DECORATION=%-3s EXTRA=%-3s  %s\n" "$ver" "$m" "$d" "$e" "$status"
done

if [ "$fail" -ne 0 ]; then
  echo "RESULT: FAIL"; exit 1
fi
echo "RESULT: all versions match their reference export tables"

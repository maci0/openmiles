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
# The reference set covers one mainline binary per selectable major version
# plus the 6.1 and 6.5 sub-lines. The 6, 6.0, and 6.6 selects share the 6.0
# mainline surface and are not swept separately; a change to their gating needs
# a 6.0/6.6 reference added here before the sweep can vouch for it.
#
# Usage: scripts/check_all_versions.sh [--strict]
#   --strict folds EXTRA into the per-version pass/fail too.
#
# Exit status: 0 every version matched, 1 a build/diff failed or a version had
# no reference DLL to check against, 2 bad invocation.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

usage() {
  cat <<EOF
Usage: scripts/check_all_versions.sh [--strict]

Builds every supported -Dmss-version and diffs its export table against the
canonical reference mss32.dll for that release.

Options:
  --strict  fail on EXTRA (symbols we export that the reference lacks)
  -h, --help  show this help
EOF
}

STRICT=""
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT="--strict" ;;
    -h | --help) usage; exit 0 ;;
    *)
      printf '%s: unknown argument: %s\n' "${0##*/}" "$arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# version -> canonical reference DLL
declare -A REF=(
  [3]=references/MSS-3.x/3.6a-mss32.dll
  [4]=references/MSS-4.x/4.0h-mss32.dll
  [5]=references/MSS-5.x/5.0b-mss32.DLL
  [6.1]=references/MSS-6.1/6.1d-mss32.dll
  [6.5]=references/MSS-6.5/6.5h-mss32.dll
  [7]=references/MSS-7.x/7.0k-mss32.dll
  [8]=references/MSS-8.x/8.0e-Mss32.dll
  [9]=references/MSS-9.x/9.1d-mss32.dll
)

VERSIONS=(3 4 5 6.1 6.5 7 8 9)
fail=0
skipped=()
for ver in "${VERSIONS[@]}"; do
  ref="${REF[$ver]}"
  if [ ! -f "$ref" ]; then
    echo "v$ver: reference missing ($ref) -- skipped"
    skipped+=("$ver")
    continue
  fi
  if ! zig build -Dmss-version="$ver" -Dtarget=x86-windows; then
    echo "v$ver: BUILD FAILED"
    fail=1
    continue
  fi
  out=$(python3 scripts/check_exports.py zig-out/bin/mss32.dll "$ref" --names-only $STRICT)
  rc=$?
  m=$(printf '%s\n' "$out" | sed -n 's/^MISSING[^:]*: \([0-9]*\)$/\1/p')
  d=$(printf '%s\n' "$out" | sed -n 's/^DECORATION[^:]*: \([0-9]*\)$/\1/p')
  e=$(printf '%s\n' "$out" | sed -n 's/^EXTRA[^:]*: \([0-9]*\)$/\1/p')
  status="ok"
  # An unparsable report is a broken checker run, not a pass.
  if [ "$rc" -ne 0 ] || [ -z "$m" ] || [ -z "$d" ] || [ -z "$e" ]; then
    status="FAIL"
    fail=1
  fi
  printf "v%-4s MISSING=%-3s DECORATION=%-3s EXTRA=%-3s  %s\n" "$ver" "${m:-?}" "${d:-?}" "${e:-?}" "$status"
done

if [ "${#skipped[@]}" -ne 0 ]; then
  echo "RESULT: FAIL (no reference DLL for: ${skipped[*]})"
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: all versions match their reference export tables"

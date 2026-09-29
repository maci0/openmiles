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
# plus the 6.1 and 6.5 sub-lines. Every accepted -Dmss-version value is either
# in VERSIONS or in UNSWEPT with a reason, and scripts/check_versions.py fails
# if one is neither, so a new select cannot ship without either a reference or
# a written statement that it has none.
#
# Usage: scripts/check_all_versions.sh [--strict]
#   --strict folds EXTRA into the per-version pass/fail too.
#
# The per-version builds install under zig-out/parity, never zig-out itself.
#
# Exit status: 0 every version matched, 1 a build/diff failed or a version had
# no reference DLL to check against, 2 bad invocation.
#
# stdout is the report: one table row per version, then the values that were
# not swept, then the RESULT line. Diagnostics about the run (a missing
# reference, a failed build, whatever the checker wrote to stderr) go to
# stderr, so piping stdout into a reader still yields a well-formed table.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

usage() {
  cat <<EOF
Usage: scripts/check_all_versions.sh [--strict]

Builds every supported -Dmss-version and diffs its export table against the
canonical reference mss32.dll for that release.

Options:
  --strict    fail on EXTRA (symbols we export that the reference lacks)
  -h, --help  show this help

Exit status: 0 every version matched, 1 a build/diff failed or a version had
no reference DLL, 2 bad invocation.
EOF
}

# Parsed before the toolchain preflight below, so --help and a bad flag answer
# the same way on a host with no zig or no interpreter as on one that has both:
# the argument is what was asked about, and a host missing a build tool is not
# an argument error.
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

command -v zig >/dev/null || { echo "error: zig not found on PATH" >&2; exit 1; }

# The parity gate's interpreter is resolved, not assumed, for the reason the
# Makefile gives for PYTHON: `python3` is the name on Linux and macOS,
# `python` the one a Windows install puts on PATH, and this script is a gate
# CI may run from a Git Bash checkout.
PYTHON=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
[ -n "$PYTHON" ] || { echo "error: neither python3 nor python found on PATH" >&2; exit 1; }

# Every build below is compared against a reference DLL, so a stray zig on PATH
# would produce a verdict nobody audited. Makefile's check-toolchain refuses
# exactly that; the sweep calls zig directly, so it repeats the check.
zig_version=$(sed -n 's/^[[:space:]]*\.minimum_zig_version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' build.zig.zon)
[ -n "$zig_version" ] || { echo "error: no .minimum_zig_version in build.zig.zon" >&2; exit 1; }
have=$(zig version)
[ "$have" = "$zig_version" ] || { echo "error: zig $zig_version required, found $have" >&2; exit 1; }

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

# Accepted -Dmss-version values with no reference DLL in this sweep. Each
# reason says what the shipped gate does and does not prove for that build; the
# only gate these values have is scripts/check_header.py, which checks the
# header against the export table but never against a real Miles DLL.
declare -A UNSWEPT=(
  [6]='same build as 6.6: neither is the 6.0 or 6.5 surface, so neither reference covers them'
  [6.6]='same build as 6; the 6.5/6.6 sub-line result in docs/EXPORT_PARITY.md came from a local sweep whose references are not committed'
  [6.0]='no 6.0 reference DLL; the 6.1d and 6.5h references bracket a different surface'
)
fail=0
skipped=()
# Each version is installed under its own prefix: the sweep's builds are
# Debug DLLs for other releases, and overwriting zig-out/bin/mss32.dll with
# one leaves a stale artifact exactly where the shipped DLL is picked up from.
out_prefix=zig-out/parity
dll="$out_prefix/bin/mss32.dll"
# One scratch file for the checker's stderr, cleared per version so a message
# is never attributed to the version after it.
errfile=$(mktemp)
trap 'rm -f "$errfile"' EXIT
for ver in "${VERSIONS[@]}"; do
  ref="${REF[$ver]}"
  if [ ! -f "$ref" ]; then
    # stderr, not stdout: stdout carries one table row per version, and a
    # sentence in the middle of it breaks anything reading the table.
    echo "v$ver: reference missing ($ref) -- skipped" >&2
    skipped+=("$ver")
    continue
  fi
  # The build's own chatter goes to stderr whatever stream its runner chooses:
  # stdout carries one table row per version and a "Build Summary:" block in the
  # middle of it breaks anything reading that table.
  if ! zig build --prefix "$out_prefix" -Dmss-version="$ver" -Dtarget=x86-windows >&2; then
    echo "v$ver: BUILD FAILED" >&2
    fail=1
    continue
  fi
  # check_exports.py exits 0 or 1 for a verdict and 2 for a bad invocation, so
  # a nonzero rc is a parity failure, not a crash. Its stderr is kept in a
  # file rather than folded into the table: it is written only when the checker
  # could not run at all (an unreadable DLL, one that is not a PE image), and
  # dropping it left a crashed checker printing the same "?" row as a genuine
  # parity failure, with nothing to tell the two apart.
  rc=0
  : >"$errfile"
  out=$("$PYTHON" scripts/check_exports.py "$dll" "$ref" --names-only ${STRICT:+"$STRICT"} 2>"$errfile") || rc=$?
  m=$(printf '%s\n' "$out" | grep '^MISSING'    | grep -oE '[0-9]+$' || true)
  d=$(printf '%s\n' "$out" | grep '^DECORATION' | grep -oE '[0-9]+$' || true)
  e=$(printf '%s\n' "$out" | grep '^EXTRA'      | grep -oE '[0-9]+$' || true)
  status="ok"
  # An unparsable report is a broken checker run, not a pass.
  if [ "$rc" -ne 0 ] || [ -z "$m" ] || [ -z "$d" ] || [ -z "$e" ]; then
    status="FAIL"
    fail=1
  fi
  if [ -s "$errfile" ]; then
    sed 's/^/    /' "$errfile" >&2
  fi
  printf "v%-4s MISSING=%-3s DECORATION=%-3s EXTRA=%-3s  %s\n" "$ver" "${m:-?}" "${d:-?}" "${e:-?}" "$status"
done

# A green sweep says nothing about a value it never built, so name the ones it
# skipped by declaration. scripts/check_versions.py keeps this list in step with
# the values -Dmss-version accepts.
# A bash associative array has no defined key order, so iterating it directly
# printed the unswept values in a different sequence from run to run. Sorted by
# version, the report is a stable table a reader can diff across runs.
while IFS= read -r ver; do
  [ -n "$ver" ] || continue
  printf 'v%-4s not swept: %s\n' "$ver" "${UNSWEPT[$ver]}"
done < <(printf '%s\n' "${!UNSWEPT[@]}" | sort -V)

if [ "${#skipped[@]}" -ne 0 ]; then
  echo "RESULT: FAIL (no reference DLL for: ${skipped[*]})"
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: all versions match their reference export tables"

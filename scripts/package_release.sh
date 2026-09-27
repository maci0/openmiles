#!/usr/bin/env bash
# Package the built Windows DLL into the release archive.
#
#   Usage: scripts/package_release.sh <output.zip> [<sha256sums>]
#
# Reads zig-out/bin/mss32.dll (build it first with
# `zig build -Dtarget=x86-windows -Doptimize=ReleaseFast`).
#
# The second argument, when given, receives a SHA256SUMS listing every entry of
# the archive, in archive order, and nothing else: a checksum file naming files
# the archive does not contain fails `sha256sum -c` on the consumer side, so the
# two are written from the same list.
#
# The archive is byte-identical for identical inputs: entries are staged in the
# explicit order below rather than the filesystem order of a glob, every entry
# takes one mtime (SOURCE_DATE_EPOCH, defaulting to the HEAD commit time) and
# one mode, and `zip -X` omits the uid/gid and extended-timestamp extra fields
# that would otherwise record the packaging host. The GNU and BSD spellings of
# the digests and of the timestamp are both handled, so a host that ships
# `shasum` and a `touch` without `-d` produces the same archive bytes.
#
# Exit status: 0 archive written, 1 packaging failed, 2 bad invocation.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

usage() {
  cat <<EOF
Usage: scripts/package_release.sh <output.zip> [<sha256sums>]

Packages zig-out/bin/mss32.dll and its licence and attribution files into
<release>.zip, stamped with SOURCE_DATE_EPOCH so the bytes are reproducible.

Arguments:
  <output.zip>    archive to write, replaced if it exists
  [<sha256sums>]  optional SHA256SUMS listing every archive entry, in
                  archive order

Options:
  -h, --help  show this help
EOF
}

# This script takes positionals only. A leading dash is a mistyped flag, not a
# file name, and passing it through would create a file named after it (or
# fail deep inside dirname), so it is rejected as a usage error here where the
# message can name the mistake. -h and --help are answered from any position,
# not just the first, so `package_release.sh out.zip --help` prints help
# instead of packaging with --help as the checksum path.
for arg in "$@"; do
  case "$arg" in
    -h | --help)
      usage
      exit 0
      ;;
    -?*)
      printf '%s: unknown option: %s\n' "${0##*/}" "$arg" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$#" -eq 0 ]; then
  printf '%s: missing <output.zip>\n' "${0##*/}" >&2
  usage >&2
  exit 2
fi

if [ "$#" -gt 2 ]; then
  printf '%s: expected at most 2 arguments, got %s\n' "${0##*/}" "$#" >&2
  usage >&2
  exit 2
fi

# zip renders each entry's mtime as an MS-DOS *local* date and time, so the
# host timezone lands in the archive bytes: the same epoch packaged under
# TZ=UTC and TZ=Asia/Tokyo produces two different zips. Pin the conversion,
# and the collation of anything the tool sorts, for this process and every
# child it spawns.
export TZ=UTC
export LC_ALL=C

command -v zip >/dev/null 2>&1 || {
  echo "error: zip not found on PATH (needed to build the release archive)" >&2
  exit 1
}

# Digests. `sha256sum` is GNU coreutils; the BSD/macOS spelling is
# `shasum -a 256`, and both write the same "<digest>  <name>" line `sha256sum -c`
# reads. Probe the capability rather than the OS name, and name the tool that is
# missing so a host without either says which one to install.
if command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$@"; }
elif command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$@"; }
else
  echo "error: neither sha256sum nor shasum found on PATH (needed for the checksums file)" >&2
  exit 1
fi

# Timestamps. `touch -d @epoch` is GNU; BSD touch takes only `-t`, and reading
# an epoch is `date -r` there and `date -d @` here. Both spellings name the
# same instant, and TZ is pinned to UTC above, so the archive bytes do not
# depend on which one the host has.
stamp_mtime() {
  local file=$1 stamp
  if touch -d "@$epoch" "$file" 2>/dev/null; then return 0; fi
  stamp=$(date -u -r "$epoch" +%y%m%d%H%M.%S 2>/dev/null) ||
    stamp=$(date -u -d "@$epoch" +%y%m%d%H%M.%S 2>/dev/null) || {
      echo "error: cannot read SOURCE_DATE_EPOCH=$epoch as a date (need 'date -r' or 'date -d @')" >&2
      return 1
    }
  touch -t "$stamp" "$file"
}

OUT=$1
SUMS=${2:-}

# archive entry name : path in the build tree, in the order they go into the zip
entries=(
  "mss32.dll:zig-out/bin/mss32.dll"
  "LICENSE:LICENSE"
  "README.md:README.md"
  "CHANGELOG.md:CHANGELOG.md"
  # The vendored headers are compiled into the DLL, not shipped as source, but
  # the project license covers redistributing them under their own terms, so
  # the attribution and the reviewed digests travel with the binary.
  "VENDORED.md:deps/README.md"
  "DEPS-SHA256SUMS:deps/SHA256SUMS"
  # The CycloneDX inventory, so a consumer or a vulnerability scanner can read
  # what third-party code the DLL carries without unpacking this repository. It
  # is generated from the same records VENDORED.md carries and checked by
  # `make check-sbom`, so it cannot describe a tree it was not built from.
  "SBOM.cdx.json:SBOM.cdx.json"
)
for e in "${entries[@]}"; do
  src=${e#*:}
  if [ ! -f "$src" ]; then
    echo "error: $src not found in $(pwd)" >&2
    if [ "$src" = "zig-out/bin/mss32.dll" ]; then
      echo "  run: zig build -Dtarget=x86-windows -Doptimize=ReleaseFast" >&2
    fi
    exit 1
  fi
done

# Stamped once, so every entry shares it. Outside a git checkout there is no
# commit time to read, and a fallback to the host clock would quietly make two
# packagings differ, so say what to set instead.
epoch=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || true)}
if [ -z "$epoch" ]; then
  echo "error: no commit time available; set SOURCE_DATE_EPOCH" >&2
  exit 1
fi

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

names=()
for e in "${entries[@]}"; do
  name=${e%%:*}
  cp "${e#*:}" "$stage/$name"
  # zip records the mode in the central directory, and a build output is
  # usually 0755 while a checked-in file is 0644, so the staging umask would
  # otherwise reach the archive bytes. One mode for every entry.
  chmod 0644 "$stage/$name"
  stamp_mtime "$stage/$name"
  names+=("$name")
done

if [ -n "$SUMS" ]; then
  mkdir -p "$(dirname "$SUMS")"
  # Absolute before the cd below, which is relative to the staging directory.
  sums_abs=$(cd "$(dirname "$SUMS")" && pwd)/$(basename "$SUMS")
  # Digests of the staged copies, which are byte-for-byte the archive entries.
  (cd "$stage" && sha256 "${names[@]}" > "$sums_abs")
  echo "wrote $sums_abs ($(wc -l < "$sums_abs") entries)"
fi

rm -f "$OUT"
# -X: no extra file attributes. -9: max compression, deterministic for a given
# zlib. Entry order comes from ${names[@]}, not from a directory read.
out_abs=$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")
(cd "$stage" && zip -X -9 -q "$out_abs" "${names[@]}")

echo "wrote $out_abs ($(wc -c < "$out_abs") bytes, epoch $epoch)"

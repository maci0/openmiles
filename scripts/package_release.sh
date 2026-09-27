#!/usr/bin/env bash
# Package the built Windows DLL into the release archive.
#
# Usage: scripts/package_release.sh <output.zip>
#   Reads zig-out/bin/mss32.dll (build it first with
#   `zig build -Dtarget=x86-windows -Doptimize=ReleaseFast`).
#
# The archive is byte-identical for identical inputs: entries are staged in the
# explicit order below rather than the filesystem order of a glob, every entry
# takes one mtime (SOURCE_DATE_EPOCH, defaulting to the HEAD commit time), and
# `zip -X` omits the uid/gid and extended-timestamp extra fields that would
# otherwise record the packaging host.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

OUT=${1:?"usage: scripts/package_release.sh <output.zip>"}

# archive entry name : path in the build tree, in the order they go into the zip
entries=(
  "mss32.dll:zig-out/bin/mss32.dll"
  "LICENSE:LICENSE"
  "README.md:README.md"
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

# Stamped once, so every entry shares it.
epoch=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct)}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

names=()
for e in "${entries[@]}"; do
  name=${e%%:*}
  cp "${e#*:}" "$stage/$name"
  touch -d "@$epoch" "$stage/$name"
  names+=("$name")
done

rm -f "$OUT"
# -X: no extra file attributes. -9: max compression, deterministic for a given
# zlib. Entry order comes from ${names[@]}, not from a directory read.
out_abs=$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")
(cd "$stage" && zip -X -9 -q "$out_abs" "${names[@]}")

echo "wrote $out_abs ($(wc -c < "$out_abs") bytes, epoch $epoch)"

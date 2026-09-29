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
# two are written from the same list. Those digests are of the files inside the
# zip, so the archive's own digest is written beside it as <output.zip>.sha256
# on every run, and the release publishes it next to the zip.
#
# The archive is byte-identical for identical inputs: entries are staged in the
# explicit order below rather than the filesystem order of a glob, every entry
# takes one mtime (SOURCE_DATE_EPOCH, defaulting to the HEAD commit time) and
# one mode, and `zip -X` omits the uid/gid and extended-timestamp extra fields
# that would otherwise record the packaging host. The GNU and BSD spellings of
# the digests and of the timestamp are both handled, so a host that ships
# `shasum` and a `touch` without `-d` produces the same archive bytes.
#
# The DLL is checked to be the 32-bit PE image the x86-windows ReleaseFast
# cross-compile produces before anything is staged. `zig-out/bin/mss32.dll` is
# a path any build of this project can leave a file at, so the path alone does
# not say the bytes in it are the ones the archive is defined to carry.
#
# Exit status: 0 archive written, 1 packaging failed, 2 bad invocation.
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

usage() {
  cat <<EOF
Usage: scripts/package_release.sh <output.zip> [<sha256sums>]

Packages zig-out/bin/mss32.dll and its licence and attribution files into
<release>.zip, stamped with SOURCE_DATE_EPOCH so the bytes are reproducible.

The DLL is refused unless it is the 32-bit PE image the x86-windows
ReleaseFast cross-compile produces, so a Debug build, a build for another
target, or a leftover from an earlier run is not published as a win32 release.

Writes <output.zip>.sha256 beside the archive on every run: the digests of
the entries inside the zip say nothing about the bytes of the zip, and the
archive is the artifact a consumer downloads.

Arguments:
  <output.zip>    archive to write, replaced if it exists
  [<sha256sums>]  optional SHA256SUMS listing every archive entry, in
                  archive order

Writes:
  <output.zip>.sha256  SHA-256 of the archive, naming it by base name so
                       sha256sum -c runs in the download directory

Options:
  -h, --help  show this help

Environment:
  SOURCE_DATE_EPOCH  mtime stamped on every archive entry, as a Unix epoch.
                     Defaults to the HEAD commit time; set it to reproduce an
                     archive from a tree that is not a git checkout. Must be an
                     integer in 315532800..4354819198 (1980-01-01..2107-12-31):
                     a zip entry cannot record anything outside that, and an
                     older value would be clamped to 1980-01-01.

Exit status: 0 archive written, 1 packaging failed, 2 bad invocation.
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

# Bounds are what a zip entry can actually record: the MS-DOS epoch it clamps
# anything older to, and the last instant its timestamp field can spell. The
# field is 7 bits of years past 1980, so the top of the range is 2107-12-31
# 23:59:58, at the format's 2-second resolution. A later epoch is not stored as
# itself and not clamped to the top either: zip wraps the 7-bit year, and an
# entry asked to carry 9999-12-31 comes back out of the archive reading 2064.
min_epoch=315532800   # 1980-01-01T00:00:00Z
max_epoch=4354819198  # 2107-12-31T23:59:58Z
epoch=${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || true)}
if [ -z "$epoch" ]; then
  echo "error: no commit time available; set SOURCE_DATE_EPOCH" >&2
  exit 1
fi
# touch -d "@<n>" wants seconds since the epoch. An unvalidated value reaches
# it as-is and comes back as "invalid date", which says nothing about the
# variable that has to change. A pre-1980 integer stamps successfully and zip
# then clamps it, so the archive would not carry the time that was asked for.
case $epoch in
  *[!0-9]*)
    echo "error: SOURCE_DATE_EPOCH='$epoch' is not a non-negative integer" >&2
    echo "  expected seconds since the Unix epoch, e.g. SOURCE_DATE_EPOCH=1750000000" >&2
    exit 2
    ;;
esac
if [ "${#epoch}" -gt 12 ] || [ "$((10#$epoch))" -lt "$min_epoch" ] || [ "$((10#$epoch))" -gt "$max_epoch" ]; then
  echo "error: SOURCE_DATE_EPOCH=$epoch is outside $min_epoch..$max_epoch (1980-01-01..2107-12-31)" >&2
  echo "  a zip entry cannot record it: older stamps are clamped to 1980-01-01" >&2
  echo "  and a later one wraps to a year between 1980 and 2064" >&2
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

command -v od >/dev/null 2>&1 || {
  echo "error: od not found on PATH (needed to check that the DLL is a 32-bit PE)" >&2
  exit 1
}

# Timestamps. `touch -d @epoch` is GNU; BSD touch takes only `-t`, and reading
# an epoch is `date -r` there and `date -d @` here. Both spellings name the
# same instant, and TZ is pinned to UTC above, so the archive bytes do not
# depend on which one the host has.
#
# The stamp carries a four-digit year, which both touches accept as the [[CC]YY]
# form. A two-digit one does not survive the range: `date -u -r 4354819198
# +%y` gives 07, and `touch -t 0712312359.58` stamps 1999 instead, so an epoch
# past 2068 would be packaged differently by a host on the BSD path than by one
# that takes the GNU branch, and the reproducibility the archive is built for
# would hold only below 2069.
stamp_mtime() {
  local file=$1 stamp
  if touch -d "@$epoch" "$file" 2>/dev/null; then return 0; fi
  stamp=$(date -u -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null) ||
    stamp=$(date -u -d "@$epoch" +%Y%m%d%H%M.%S 2>/dev/null) || {
      echo "error: cannot read SOURCE_DATE_EPOCH=$epoch as a date (need 'date -r' or 'date -d @')" >&2
      return 1
    }
  touch -t "$stamp" "$file"
}

OUT=$1
SUMS=${2:-}

# The archive path is the caller's to place, so its directory has to exist
# already: `cd "$(dirname ...)" && pwd` under `set -e` dies with cd's own
# message, which names a directory and not the argument that pointed at it.
# Checking here, before anything is staged, also keeps a typo'd archive path
# from leaving a checksums file describing an archive that was never produced.
# The checksums path is not checked: the script creates that directory itself
# (below), so `release/SHA256SUMS` is usable in a tree that has no release/
# yet, which is what the release workflow does on a fresh checkout.
# 1, not 2: the invocation was well formed, the packaging could not run.
if [ ! -d "$(dirname "$OUT")" ]; then
  echo "error: output archive directory does not exist: $(dirname "$OUT")" >&2
  echo "  create it, or pass a path under an existing directory" >&2
  exit 1
fi

# archive entry name : path in the build tree, in the order they go into the zip
entries=(
  "mss32.dll:zig-out/bin/mss32.dll"
  # The header a consumer compiles against. Without it the archive is a DLL
  # nobody new code can call, and every user has to pull the source tree.
  "mss.h:zig-out/include/mss.h"
  "LICENSE:LICENSE"
  "README.md:README.md"
  "CHANGELOG.md:CHANGELOG.md"
  # The security contact travels with the binary: a consumer who finds a
  # problem in the DLL needs the address to report it to, and it is one of
  # the links the shipped README already carries.
  "SECURITY.md:SECURITY.md"
  # Contributor setup, for the same reason: the README links it twice, and a
  # link that 404s in an unpacked archive is a link that names a file the
  # archive does not hold.
  "CONTRIBUTING.md:CONTRIBUTING.md"
  # The vendored headers, the attribution, and the reviewed digests. The
  # project license covers redistributing the headers under their own terms,
  # and they keep the paths the README links them by: renamed to a flat
  # VENDORED.md, every one of those links is dead in an unpacked archive.
  #
  # The headers themselves ship because the two records that describe them
  # ship, and a record a consumer cannot check is not a record. deps/SHA256SUMS
  # names every header below and SBOM.cdx.json repeats those digests, so an
  # archive holding the manifests and not the files fails `sha256sum -c
  # deps/SHA256SUMS` on all of them the moment it is unpacked, and the bytes
  # README.md pins the consumer to are the only ones a consumer cannot obtain
  # from what they downloaded. `make check-release-archive` fails when a header
  # is vendored and the archive does not carry it.
  "deps/README.md:deps/README.md"
  "deps/SHA256SUMS:deps/SHA256SUMS"
  "deps/miniaudio.h:deps/miniaudio.h"
  "deps/tml.h:deps/tml.h"
  "deps/tsf.h:deps/tsf.h"
  "deps/tsf_tml.h:deps/tsf_tml.h"
  "deps/windows_stub.h:deps/windows_stub.h"
  # The docs the shipped README links: the API status matrix, the support and
  # version tables, the plugin coverage list, the threat model, and the logo
  # its first line renders. Every one of those links is in the README a
  # consumer reads, so an archive without them documents a tree that is not
  # there.
  "docs/logo.svg:docs/logo.svg"
  "docs/API_STATUS.md:docs/API_STATUS.md"
  "docs/MSS_API_MATRIX.md:docs/MSS_API_MATRIX.md"
  "docs/MSS_PLUGINS.md:docs/MSS_PLUGINS.md"
  "docs/MSS_VERSION_HISTORY.md:docs/MSS_VERSION_HISTORY.md"
  "docs/THREAT_MODEL.md:docs/THREAT_MODEL.md"
  # The CycloneDX inventory, so a consumer or a vulnerability scanner can read
  # what third-party code the DLL carries without unpacking this repository. It
  # is generated from the same records deps/README.md carries and checked by
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

# The archive is a win32 drop-in, so what it stages as mss32.dll has to be the
# 32-bit PE the cross-compile produces. Nothing about the path says which build
# left it there: a plain `zig build` on a Windows host, a Debug or
# ReleaseSafe build of the right target, and a build for some other target all
# put a file at zig-out/bin/mss32.dll, and the script would stage whichever
# one it found and publish it under a win32 name. The release workflow catches
# it with objdump before packaging; the README also documents this script as the
# local path, so the check belongs here and reads the file rather than trusting
# the name.
#
# od is used rather than `file`, whose output is a sentence that differs across
# host locales and versions, and the two multi-byte fields are assembled from
# hex by hand rather than read with a native-width od conversion, so a big-endian
# host reads the same values off disk.
require_i386_pe() {
  local f=$1 size sig lfanew_hex off pe machine
  size=$(wc -c < "$f")
  # DOS stub, then the little-endian 4-byte offset of the PE header at 0x3c.
  sig=$(od -An -tx1 -N2 "$f" 2>/dev/null | tr -d ' \n')
  if [ "$sig" != "4d5a" ]; then
    echo "error: $f is not a PE image (no MZ signature at offset 0)" >&2
    return 1
  fi
  lfanew_hex=$(od -An -tx1 -j60 -N4 "$f" 2>/dev/null | tr -d ' \n')
  if [ "${#lfanew_hex}" -ne 8 ]; then
    echo "error: $f is $size bytes, too short to hold a PE header" >&2
    return 1
  fi
  off=$((16#${lfanew_hex:6:2} * 16777216 + 16#${lfanew_hex:4:2} * 65536 +
    16#${lfanew_hex:2:2} * 256 + 16#${lfanew_hex:0:2}))
  if [ "$off" -le 0 ] || [ $((off + 6)) -gt "$size" ]; then
    echo "error: $f has no PE header where its own header points (offset $off)" >&2
    return 1
  fi
  pe=$(od -An -tx1 -j "$off" -N4 "$f" 2>/dev/null | tr -d ' \n')
  if [ "$pe" != "50450000" ]; then
    echo "error: $f has no PE signature at offset $off" >&2
    return 1
  fi
  # IMAGE_FILE_MACHINE_I386, 0x014c, little-endian on disk.
  machine=$(od -An -tx1 -j $((off + 4)) -N2 "$f" 2>/dev/null | tr -d ' \n')
  if [ "$machine" != "4c01" ]; then
    echo "error: $f is a PE image but not 32-bit x86 (machine 0x$machine)" >&2
    return 1
  fi
}
if ! require_i386_pe zig-out/bin/mss32.dll; then
  echo "  run: zig build -Dtarget=x86-windows -Doptimize=ReleaseFast" >&2
  exit 1
fi

# Stamped once, so every entry shares it. `epoch` was checked above, before
# any file is required, so a bad SOURCE_DATE_EPOCH fails as a usage error
# rather than as a missing DLL.

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

names=()
for e in "${entries[@]}"; do
  name=${e%%:*}
  # An entry name may carry a directory (deps/, docs/), so the parent has to
  # exist before the copy. mkdir -p on a flat name is a no-op on the parent,
  # which is the staging root itself.
  mkdir -p "$(dirname "$stage/$name")"
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

# The digest of the archive, beside the archive, after it is written: the
# optional SHA256SUMS above names the entries *inside* the zip, so a consumer
# who has downloaded the zip and not unpacked it has nothing to check the
# bytes they fetched against. The name recorded is the base name, so
# `sha256sum -c` runs in the directory the download landed in. Written for
# every run, not only when SUMS is given: the archive is the artifact, and
# this file is the only record of its bytes.
(cd "$(dirname "$out_abs")" && sha256 "$(basename "$out_abs")" > "$(basename "$out_abs").sha256")
echo "wrote $out_abs.sha256"

echo "wrote $out_abs ($(wc -c < "$out_abs") bytes, epoch $epoch)"

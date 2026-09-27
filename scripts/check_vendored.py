#!/usr/bin/env python3
"""Verify every file in deps/ against the SHA-256 digests in deps/SHA256SUMS.

The vendored headers are downloaded from upstream, not resolved through a
package manager, so nothing else in the tree records which bytes were reviewed.
A header swapped in without a matching line in SHA256SUMS, or a line edited to
match a header that arrived from somewhere unexpected, both compile and both
ship. This check closes that gap: `make lint` runs it, so CI rejects either.

deps/README.md documents where each file comes from and under which license;
this script is the machine-readable half of the same record.

Usage:
    scripts/check_vendored.py [--update]

    --update  rewrite deps/SHA256SUMS from the files on disk, for a deliberate
              header swap. Review the diff before committing it: the point of
              the check is that changing a digest is a conscious act.

Exit code 0 when deps/ and SHA256SUMS agree.
"""
import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEPS = ROOT / "deps"
SUMS = DEPS / "SHA256SUMS"
CHUNK = 1 << 20


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(CHUNK), b""):
            h.update(block)
    return h.hexdigest()


# README.md documents the deps, it is not itself a vendored artifact.
NOT_VENDORED = {SUMS.name, "README.md"}


def vendored_files():
    return sorted(p for p in DEPS.iterdir() if p.is_file() and p.name not in NOT_VENDORED)


def read_sums():
    recorded = {}
    for lineno, raw in enumerate(SUMS.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(maxsplit=1)
        if len(parts) != 2 or len(parts[0]) != 64:
            print(f"SHA256SUMS:{lineno} MALFORMED  {raw!r}")
            continue
        recorded[parts[1].strip().lstrip("*")] = parts[0]
    return recorded


def main():
    update = "--update" in sys.argv[1:]
    files = vendored_files()
    on_disk = {p.name: digest(p) for p in files}

    if update:
        SUMS.write_text("".join(f"{on_disk[n]}  {n}\n" for n in sorted(on_disk)))
        print(f"updated {SUMS.relative_to(ROOT)} with {len(on_disk)} entries")
        return 0

    recorded = read_sums()
    problems = []

    for name in sorted(on_disk):
        if name not in recorded:
            problems.append(f"{name} UNRECORDED  no digest in SHA256SUMS")
        elif recorded[name] != on_disk[name]:
            problems.append(f"{name} MISMATCH   recorded {recorded[name]}")

    for name in sorted(recorded):
        if name not in on_disk:
            problems.append(f"{name} MISSING    recorded in SHA256SUMS but absent from deps/")

    for p in problems:
        print(p)

    if problems:
        print(f"{len(problems)} vendored file(s) disagree with {SUMS.relative_to(ROOT)}")
        return 1

    print(f"{len(on_disk)} vendored file(s) match {SUMS.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

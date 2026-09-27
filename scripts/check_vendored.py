#!/usr/bin/env python3
"""Verify every file in deps/ against the SHA-256 digests in deps/SHA256SUMS.

The vendored headers are downloaded from upstream, not resolved through a
package manager, so nothing else in the tree records which bytes were reviewed.
A header swapped in without a matching line in SHA256SUMS, or a line edited to
match a header that arrived from somewhere unexpected, both compile and both
ship. This check closes that gap: `make lint` runs it, so CI rejects either.

deps/README.md documents where each file comes from and under which license,
including the upstream commit each vendored header was taken from; this script
is the machine-readable half of the same record, and rejects a vendored header
whose entry names no commit.

--update rewrites deps/SHA256SUMS from the files on disk, for a deliberate
header swap. Review the diff before committing it: the point of the check is
that changing a digest is a conscious act.

Exit code 0 when deps/ and SHA256SUMS agree.
"""

import argparse
import hashlib
import re
import sys
from pathlib import Path
from typing import NamedTuple

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

# A SHA256SUMS line is "<hex digest>  <path>": a two-field record whose digest
# field is the full 64 hex characters of a SHA-256.
SUMS_FIELDS = 2
DIGEST_HEX_CHARS = 64

README = DEPS / "README.md"

# deps/README.md records each vendored header's provenance as a bulleted field
# in that file's section: "**Commit:** `<40 hex>`" for the upstream revision it
# was fetched from, plus the version, source URL, and license. The first-party
# files (tsf_tml.h, windows_stub.h) have no upstream and so carry no commit.
COMMIT_RE = re.compile(r"^[-*]\s+\*\*Commit:\*\*\s*`([0-9a-f]{40})`", re.MULTILINE)
VERSION_RE = re.compile(r"^[-*]\s+\*\*Version:\*\*\s*(.+?)\s*$", re.MULTILINE)
PACKAGE_RE = re.compile(r"^[-*]\s+\*\*Package:\*\*\s*`?([A-Za-z0-9_.-]+)`?", re.MULTILINE)
SOURCE_RE = re.compile(r"^[-*]\s+\*\*Source:\*\*\s*(\S+)", re.MULTILINE)
LICENSE_RE = re.compile(r"^[-*]\s+\*\*License:\*\*\s*(.+?)\s*$", re.MULTILINE)
PURPOSE_RE = re.compile(r"^[-*]\s+\*\*Purpose:\*\*\s*(.+?)\s*$", re.MULTILINE)
SECTION_RE = re.compile(r"^##\s+(.+)$", re.MULTILINE)
NAME_RE = re.compile(r"[A-Za-z0-9_.-]+\.h")
FIRST_PARTY_RE = re.compile(r"first-party")


class Entry(NamedTuple):
    """What deps/README.md claims about one file in deps/."""

    package: str | None
    version: str | None
    commit: str | None
    source: str | None
    license: str | None
    purpose: str | None
    first_party: bool


def readme_entries():
    """Map each deps/ file named in a README section to how it is claimed.

    A file reaches this check one of two ways: a section recording the upstream
    commit it was vendored from, or a section saying it is first-party. A
    section that claims neither leaves the origin of the bytes unrecorded.

    gen_sbom.py reads the same records, so the provenance in the SBOM and the
    provenance this check enforces come from one parse of one file.
    """
    text = README.read_text()
    entries = {}
    for m in SECTION_RE.finditer(text):
        rest = text[m.end() :]
        nxt = rest.find("\n## ")
        body = rest if nxt < 0 else rest[:nxt]
        commit = COMMIT_RE.search(body)
        first_party = not commit and bool(FIRST_PARTY_RE.search(body))
        version = VERSION_RE.search(body)
        source = SOURCE_RE.search(body)
        license_ = LICENSE_RE.search(body)
        purpose = PURPOSE_RE.search(body)
        package = PACKAGE_RE.search(body)
        entry = Entry(
            package=package.group(1) if package else None,
            version=version.group(1) if version else None,
            commit=commit.group(1) if commit else None,
            source=source.group(1) if source else None,
            license=license_.group(1) if license_ else None,
            purpose=purpose.group(1) if purpose else None,
            first_party=first_party,
        )
        for name in NAME_RE.findall(m.group(1)):
            entries[name] = entry
    return entries


def vendored_files():
    return sorted(p for p in DEPS.iterdir() if p.is_file() and p.name not in NOT_VENDORED)


def read_sums():
    """Recorded digests by name, plus the SHA256SUMS lines that parse as none.

    A malformed line is returned rather than printed here: it is a check
    failure like any other, so it has to reach the problems list the exit
    status is computed from. Printed from inside the parse, it left the gate
    green over a line that records no digest at all.
    """
    recorded = {}
    malformed = []
    for lineno, raw in enumerate(SUMS.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(maxsplit=1)
        if len(parts) != SUMS_FIELDS or len(parts[0]) != DIGEST_HEX_CHARS:
            malformed.append(f"SHA256SUMS:{lineno} MALFORMED  {raw!r}")
            continue
        recorded[parts[1].strip().lstrip("*")] = parts[0]
    return recorded, malformed


def main():
    parser = argparse.ArgumentParser(
        prog="check_vendored.py",
        description=__doc__,
        epilog="Exit status: 0 deps/ matches SHA256SUMS, 1 they disagree, 2 bad invocation.",
    )
    parser.add_argument(
        "--update",
        action="store_true",
        help="rewrite deps/SHA256SUMS from the files on disk, for a deliberate header swap",
    )
    args = parser.parse_args()

    files = vendored_files()
    on_disk = {p.name: digest(p) for p in files}

    if args.update:
        SUMS.write_text("".join(f"{on_disk[n]}  {n}\n" for n in sorted(on_disk)))
        print(f"updated {SUMS.relative_to(ROOT)} with {len(on_disk)} entries")
        return 0

    recorded, malformed = read_sums()
    problems = list(malformed)

    for name in sorted(on_disk):
        if name not in recorded:
            problems.append(f"{name} UNRECORDED  no digest in SHA256SUMS")
        elif recorded[name] != on_disk[name]:
            problems.append(f"{name} MISMATCH   recorded {recorded[name]}")

    problems += [
        f"{name} MISSING    recorded in SHA256SUMS but absent from deps/"
        for name in sorted(recorded)
        if name not in on_disk
    ]

    entries = readme_entries()
    for name in sorted(on_disk):
        entry = entries.get(name)
        if entry is None:
            problems.append(f"{name} UNDOCUMENTED  no section in {README.relative_to(ROOT)}")
        elif entry.commit is None and not entry.first_party:
            problems.append(
                f"{name} NOPROVENANCE  its {README.relative_to(ROOT)} section names no upstream "
                f"commit and does not claim the file first-party"
            )

    for p in problems:
        print(p)

    if problems:
        print(f"{len(problems)} finding(s) disagree with {SUMS.relative_to(ROOT)}")
        return 1

    print(f"{len(on_disk)} vendored file(s) match {SUMS.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

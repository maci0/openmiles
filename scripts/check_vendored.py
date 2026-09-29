#!/usr/bin/env python3
"""Verify every file in deps/ against the SHA-256 digests in deps/SHA256SUMS.

The vendored headers are downloaded from upstream, not resolved through a
package manager, so nothing else in the tree records which bytes were reviewed.
A header swapped in without a matching line in SHA256SUMS, or a line edited to
match a header that arrived from somewhere unexpected, both compile and both
ship. This check closes that gap: `make lint` runs it, so CI rejects either.

deps/README.md documents where each file comes from and under which license,
including the upstream commit each vendored header was taken from; this script
is the machine-readable half of the same record. It rejects a vendored header
whose entry names no commit, whose version disagrees with the version in its own
bytes, or whose Source is not one of the approved upstream hosts.

The shipped README.md states the same three facts a second time, in a table a
reader sees before anything else. Nothing cross-checked the two, so a header
swap left the front page naming the version that shipped before it. This asserts
that table against the record deps/README.md keeps, which is the one gen_sbom.py
derives SBOM.cdx.json from.

--update rewrites deps/SHA256SUMS from the files on disk, for a deliberate
header swap. Review the diff before committing it: the point of the check is
that changing a digest is a conscious act.
"""

import argparse
import hashlib
import re
import sys
from pathlib import Path
from typing import NamedTuple

PROG = "check_vendored.py"

# Walk up for the project marker rather than assuming a fixed depth, so the
# gate runs the same from the repo root, from scripts/, and from a build dir.
for ROOT in Path(__file__).resolve().parents:
    if (ROOT / "build.zig.zon").is_file():
        break
else:  # pragma: no cover - the script always lives inside the repository
    # 1, not 2: nothing about the invocation is wrong, the check cannot run.
    # Every gate reserves 2 for a bad argument.
    print("error: build.zig.zon not found above scripts/", file=sys.stderr)
    sys.exit(1)

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

# The version a vendored file states in its own bytes, read two ways because
# upstream states it two ways. miniaudio carries the triple in macros; the two
# TinySoundFont headers carry no version macro at all, so theirs is the banner
# on line 1, which is the only place upstream states it. Reading the bytes is
# the point: the version in deps/README.md is what gen_sbom.py writes into
# SBOM.cdx.json, and a scanner matches an advisory against that string. A
# header swapped for a newer release with the README entry left behind puts
# the superseded version in the inventory, so every advisory published for the
# release that actually shipped is a miss.
#
# Where a vendored header may come from. Both upstreams are GitHub repos, and
# a single approved host is a short enough list to hold in the head: the point
# is that a Source line naming any other URL fails here, at the moment the tree
# is linted, rather than at the moment somebody believes it. deps/README.md's
# update checklist asks for a download from the listed URL, and this is the
# machine-readable half of that instruction.
#
# A header fetched from a lookalike host carrying a matching name and a
# plausible commit-shaped string would otherwise pass every other check here:
# the digest records which bytes shipped, and nothing else in the tree records
# which host they came from. Both entries resolve to github.com today, so a
# vendor that moves off it is a deliberate edit to this set, not an accident.
SOURCE_SCHEME = "https"
SOURCE_HOSTS = {"github.com"}

# README.md is the front page of the release archive as well as of the
# repository, so its dependency table is a second hand-written copy of the
# version, upstream, and license of every vendored header. It is read here for
# the same reason deps/README.md is: the record that a scanner matches an
# advisory against, and the attribution a consumer reads, cannot be one that
# drifts from the bytes. The table is parsed only inside its own section, so the
# document's other tables are not read as dependency rows.
SHIPPED_README = ROOT / "README.md"
DEPENDENCIES_HEADING = "Dependencies"
SHIPPED_ROW_RE = re.compile(
    r"^\|\s*\[(?P<package>[^\]]+)\]\((?P<source>[^)]+)\)\s*"
    r"\|\s*(?P<version>[^|]+?)\s*\|\s*(?P<license>[^|]+?)\s*\|[^|]*\|\s*$",
    re.MULTILINE,
)


# A license written the way upstream writes it carries a parenthetical that
# annotates the grant rather than adding one ("MIT-0 / Public Domain
# (Dual-licensed)"). The shipped table drops the annotation and keeps the grant,
# because a front-page table cell is not the place for it, so the two are
# compared on what they grant. Splitting on "/" and dropping anything from the
# first "(" leaves the same tokens gen_sbom.py writes into SBOM.cdx.json.
def license_tokens(declared):
    return {t.split("(", 1)[0].strip().lower() for t in declared.split("/") if t.strip()}


# A repository URL is "https://host/owner/repo"; anything shorter is a page
# rather than the repository a commit id can be fetched from.
SOURCE_PATH_PARTS = 2
SOURCE_URL_RE = re.compile(r"^(?P<scheme>[a-z][a-z0-9+.-]*)://(?P<host>[^/?#]+)/?(?P<path>[^?#]*)")

VERSION_MACROS = ("MA_VERSION_MAJOR", "MA_VERSION_MINOR", "MA_VERSION_REVISION")
VERSION_MACRO_RES = tuple(
    re.compile(rf"^#define\s+{macro}\s+(\d+)\s*$", re.MULTILINE) for macro in VERSION_MACROS
)
BANNER_RE = re.compile(r"^/\*\s*\S+\s+-\s+v(\d+(?:\.\d+)*)\s+-")


def header_version(path):
    """The version path states in its own bytes, or None if it states none."""
    # Vendored headers are kept byte for byte and upstream ships tsf.h and
    # tml.h with CRLF, so decode leniently and let the regexes absorb the \r:
    # an undecodable byte in someone else's header is not this check's finding.
    text = path.read_text(encoding="utf-8", errors="replace")
    parts = []
    for pattern in VERSION_MACRO_RES:
        match = pattern.search(text)
        if match is None:
            parts = []
            break
        parts.append(match.group(1))
    if parts:
        return ".".join(parts)
    match = BANNER_RE.search(text)
    return match.group(1) if match else None


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
    text = README.read_text(encoding="utf-8")
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


def source_problems(name, source):
    """Why a vendored entry's recorded Source is not one of the approved upstreams."""
    if source is None:
        return [f"{name} NOSOURCE  its section records no source URL"]
    match = SOURCE_URL_RE.match(source)
    if match is None:
        return [f"{name} BADSOURCE  source {source!r} is not an absolute URL"]
    if match.group("scheme") != SOURCE_SCHEME:
        return [f"{name} BADSOURCE  source {source!r} is not {SOURCE_SCHEME}://"]
    host = match.group("host").lower()
    if host not in SOURCE_HOSTS:
        allowed = ", ".join(sorted(SOURCE_HOSTS))
        return [f"{name} BADSOURCE  source host {host!r} is not one of {allowed}"]
    parts = [p for p in match.group("path").split("/") if p]
    if len(parts) < SOURCE_PATH_PARTS:
        return [f"{name} BADSOURCE  source {source!r} names no repository"]
    return []


def entry_problems(name, entry):
    """What deps/README.md claims about one file in deps/ fails to hold.

    A first-party file has no upstream and no upstream version, so the commit,
    the version and the source checks do not apply to it.
    """
    readme = README.relative_to(ROOT)
    findings = []
    if entry is None:
        findings.append(f"{name} UNDOCUMENTED  no section in {readme}")
    elif entry.first_party:
        return findings
    elif entry.commit is None:
        findings.append(
            f"{name} NOPROVENANCE  its {readme} section names no upstream commit and does not "
            f"claim the file first-party"
        )
    elif entry.version is None:
        findings.append(f"{name} NOVERSION  its {readme} section records no version")
        findings += source_problems(name, entry.source)
    else:
        findings += source_problems(name, entry.source)
        stated = header_version(DEPS / name)
        if stated is None:
            findings.append(
                f"{name} UNREADABLE-VERSION  states no version in its own bytes, so the "
                f"{entry.version!r} its {readme} section claims is unchecked"
            )
        elif stated != entry.version.removeprefix("v"):
            findings.append(
                f"{name} VERSION  {readme} claims {entry.version!r}, the file states {stated}"
            )
    return findings


def shipped_readme_rows():
    """The dependency table README.md ships, as a list of row dicts.

    Only the Dependencies section is read. A row is a table line whose first
    cell is a link to the upstream and whose next two cells are the version and
    the license, which is the shape of the table and of no other in the
    document. A section with no such row yields nothing, and the caller says so
    rather than treating a rewritten table as one that agrees.
    """
    text = SHIPPED_README.read_text(encoding="utf-8")
    for m in SECTION_RE.finditer(text):
        if m.group(1).strip() != DEPENDENCIES_HEADING:
            continue
        rest = text[m.end() :]
        nxt = rest.find("\n## ")
        body = rest if nxt < 0 else rest[:nxt]
        return [row.groupdict() for row in SHIPPED_ROW_RE.finditer(body)]
    return []


def shipped_readme_problems(entries):
    """Where README.md's dependency table disagrees with deps/README.md.

    Two hand-written records of the same three facts, and a header swap updates
    the one the SBOM is generated from without touching the one a reader sees
    first. The version is the field that matters: it is what a scanner matches
    an advisory against, so a front page left on the superseded version states
    that the release carries code no advisory was ever checked against.
    """
    readme = SHIPPED_README.relative_to(ROOT)
    vendored = {entry.package: entry for entry in entries.values() if not entry.first_party}
    rows = shipped_readme_rows()
    if not rows:
        return [
            f"{readme} NOTABLE  no dependency table under its ## {DEPENDENCIES_HEADING} heading"
        ]

    findings = []
    listed = set()
    for row in rows:
        package = row["package"]
        listed.add(package)
        entry = vendored.get(package)
        if entry is None:
            findings.append(
                f"{readme} UNKNOWN  its table lists {package}, which "
                f"{README.relative_to(ROOT)} records no vendored package for"
            )
            continue
        if None in (entry.version, entry.source, entry.license):
            # entry_problems already reported the field deps/README.md is
            # missing, and comparing a row against None here would repeat it as
            # a disagreement the reader has to unpick.
            continue
        if row["source"] != entry.source:
            findings.append(
                f"{readme} SOURCE  {package} links {row['source']}, "
                f"{README.relative_to(ROOT)} records {entry.source}"
            )
        if row["version"] != entry.version:
            findings.append(
                f"{readme} VERSION  {package} states {row['version']}, "
                f"{README.relative_to(ROOT)} records {entry.version}"
            )
        if license_tokens(row["license"]) != license_tokens(entry.license):
            findings.append(
                f"{readme} LICENSE  {package} states {row['license']!r}, "
                f"{README.relative_to(ROOT)} records {entry.license!r}"
            )
    findings += [
        f"{readme} UNLISTED  {package} is vendored but its table does not list it"
        for package in sorted(vendored)
        if package not in listed
    ]
    return findings


def vendored_files():
    return sorted(p for p in DEPS.iterdir() if p.is_file() and p.name not in NOT_VENDORED)


def unrecorded_dirs():
    """Subdirectories under deps/, which the digest list cannot describe.

    SHA256SUMS names files in deps/ itself, and vendored_files() skips
    everything that is not one. build.zig puts deps/ on the include path for
    the translate-C step, so a header in a subdirectory is reachable and
    compiles into the DLL while carrying no digest, no upstream commit and no
    SBOM entry: third-party code with no recorded provenance. Flattening is
    the fix; until then the directory is a finding, under --update too, since
    that mode rewrites the digests from the same flat view.
    """
    return sorted(p.name for p in DEPS.iterdir() if p.is_dir())


def read_sums():
    """Recorded digests by name, plus the SHA256SUMS lines that parse as none.

    A malformed line is returned rather than printed here: it is a check
    failure like any other, so it has to reach the problems list the exit
    status is computed from. Printed from inside the parse, it left the gate
    green over a line that records no digest at all.
    """
    recorded = {}
    malformed = []
    for lineno, raw in enumerate(SUMS.read_text(encoding="utf-8").splitlines(), 1):
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
        prog=PROG,
        # The docstring is laid out as prose and a column-aligned finding list;
        # the default formatter reflows both into one paragraph, which is what
        # turned the finding names into run-on text.
        formatter_class=argparse.RawDescriptionHelpFormatter,
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

    nested = [
        f"{name}/ UNINVENTORIED  a subdirectory of deps/ carries no digest, "
        "upstream commit or SBOM entry"
        for name in unrecorded_dirs()
    ]
    if nested:
        for finding in nested:
            print(finding)
        print(f"{len(nested)} finding(s) disagree with {SUMS.relative_to(ROOT)}")
        return 1

    if args.update:
        # Bytes, not write_text: deps/ is `-text` in .gitattributes so the digests
        # are checked against the bytes on disk, and a Windows run would
        # otherwise write CRLF into them.
        SUMS.write_bytes("".join(f"{on_disk[n]}  {n}\n" for n in sorted(on_disk)).encode())
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
        problems += entry_problems(name, entries.get(name))

    problems += shipped_readme_problems(entries)

    for p in problems:
        print(p)

    if problems:
        print(f"{len(problems)} finding(s) disagree with the recorded dependency state")
        return 1

    print(
        f"{len(on_disk)} vendored file(s) match {SUMS.relative_to(ROOT)}, and the "
        f"dependency table in {SHIPPED_README.relative_to(ROOT)} matches {README.relative_to(ROOT)}"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as exc:
        # A file this gate reads is missing or unparsable: the invocation was
        # fine, the check could not run. 1, the code the sibling gates use for
        # the same condition, not a traceback.
        print(f"{PROG}: {exc}", file=sys.stderr)
        sys.exit(1)

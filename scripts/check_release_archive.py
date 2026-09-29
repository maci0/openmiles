#!/usr/bin/env python3
"""Assert the release archive carries every file the files it carries refer to.

scripts/package_release.sh ships deps/SHA256SUMS and SBOM.cdx.json beside the
DLL, and both name digests of the vendored headers. An archive holding those
records without the files they describe is not a package a consumer can check:
unpacking it and running `sha256sum -c deps/SHA256SUMS` fails on every entry,
and the digests are decoration. The same holds for the documentation: a
relative link from a shipped file to one the archive does not hold is dead on
arrival.

Both are silent. The packaging script stages what its list names and never
looks at what those files point at, and a header vendored or a doc written
after the list was last edited ships an archive nobody notices is incomplete
until a consumer hits it. This gate closes the gap: `make lint` runs it, so CI
rejects either.

The entry list is read out of package_release.sh rather than restated here, so
the gate and the packager cannot disagree about what ships.
"""

import argparse
import posixpath
import re
import sys
from pathlib import Path

PROG = "check_release_archive.py"

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

PACKAGER = ROOT / "scripts" / "package_release.sh"
SUMS = ROOT / "deps" / "SHA256SUMS"

# One entry of package_release.sh's `entries` array: "archive name:tree path",
# inside double quotes and indented. A comment line and the array's own
# delimiters cannot match it, which is what lets the list be read without
# running the packager or shelling out to a shell.
ENTRY_RE = re.compile(r'^\s+"(?P<name>[^":]+):(?P<src>[^"]+)"\s*$', re.MULTILINE)

# A Markdown inline link or image: the target is the first field inside the
# parentheses. Optional title text and a bare "#anchor" are stripped by the
# caller, not here.
LINK_RE = re.compile(r"\]\(([^)]*)\)")

# A SHA256SUMS line is "<hex digest>  <path>"; the path is the second field.
SUMS_LINE_RE = re.compile(r"^(?P<digest>[0-9a-f]{64})\s+(?P<path>\S.*)$")

# Two entries a shipped file can link that resolve without the archive: a
# target with a scheme is a URL, and a target that is only an anchor names a
# heading in the file that carries it.
EXTERNAL_SCHEMES = ("http://", "https://", "mailto:", "ftp://")


def parse_entries(text: str) -> list[tuple[str, str]]:
    """Return the (archive name, tree path) pairs package_release.sh stages."""
    return [(m["name"], m["src"]) for m in ENTRY_RE.finditer(text)]


def read_sums(text: str) -> list[str]:
    """Return the paths deps/SHA256SUMS records, in file order."""
    return [m["path"] for m in map(SUMS_LINE_RE.match, text.splitlines()) if m]


def link_target(raw: str) -> str | None:
    """Return the relative path a Markdown link points at, or None.

    None means the target does not name a file in the archive at all: an empty
    target, a URL, or a bare anchor. A target is "<path>", "<path>#anchor",
    "<path>?query", or "<path> \"title\"", and only the first field names a
    file.
    """
    target = raw.split(maxsplit=1)[0].strip() if raw.strip() else ""
    target = target.split("#", 1)[0].split("?", 1)[0]
    if not target or target.startswith(EXTERNAL_SCHEMES):
        return None
    return target


def main() -> int:
    ap = argparse.ArgumentParser(
        prog=PROG,
        # The docstring is laid out as prose in paragraphs; the default
        # formatter reflows it into one wall of text, the reason every sibling
        # gate passes this.
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__,
        epilog="Exit status: 0 the archive carries what it names, 1 it does not, 2 bad invocation.",
    )
    ap.parse_args()

    entries = parse_entries(PACKAGER.read_text(encoding="utf-8"))
    if not entries:
        print(
            f"{PROG}: no entries parsed from {PACKAGER.relative_to(ROOT)}; "
            "the entry list is what this gate reads",
            file=sys.stderr,
        )
        return 1
    shipped = {name for name, _ in entries}

    problems: list[str] = []

    # A record that describes files the archive does not carry cannot be
    # checked by whoever unpacked it. deps/SHA256SUMS is the one that ships, so
    # every path it records has to ship beside it.
    for path in read_sums(SUMS.read_text(encoding="utf-8")):
        name = posixpath.join("deps", path)
        if name not in shipped:
            problems.append(
                f"{name} is recorded in {SUMS.relative_to(ROOT)} "
                "but the release archive does not carry it"
            )

    # A relative link out of a shipped file is dead on arrival unless the
    # archive carries what it names. Resolution happens against the shipped
    # entry's own directory, because the archive is unpacked flat and the link
    # was written from that file's place in the tree.
    for name, src in entries:
        src_path = ROOT / src
        if src_path.suffix != ".md" or not src_path.is_file():
            continue
        here = posixpath.dirname(name)
        text = src_path.read_text(encoding="utf-8")
        for m in LINK_RE.finditer(text):
            target = link_target(m.group(1))
            if target is None:
                continue
            resolved = posixpath.normpath(posixpath.join(here, target))
            if resolved not in shipped:
                line = text.count("\n", 0, m.start()) + 1
                problems.append(
                    f"{name}:{line} links {target}, which the release archive does not carry"
                )

    for p in problems:
        print(p)

    if problems:
        print(
            f"{len(problems)} finding(s) the release archive cannot satisfy; "
            "add the entry to package_release.sh"
        )
        return 1

    print(
        f"{len(entries)} copied archive entry/entries carry every file "
        f"{SUMS.relative_to(ROOT)} records and every file the shipped docs link"
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

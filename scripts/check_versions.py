#!/usr/bin/env python3
"""Check that every `-Dmss-version` value is covered by a parity gate.

The export table is the whole consumer contract: a game links mss32.dll by
import name, so a select that ships without being diffed against a real Miles
DLL is a select nobody has checked. Four places have to agree on which
selects exist and which of them are swept:

  build.zig               parseMssVersion: the values `-Dmss-version` accepts
  src/mss.h               the #error listing the values OPENMILES_MSS_VERSION
                          accepts, which is what rejects the rest at compile time
  scripts/check_header.py SUPPORTED_VERSIONS: the header resolves its guards for
  scripts/check_all_versions.sh VERSIONS / UNSWEPT: the export-parity sweep

Reported per value:

  UNKNOWN    a value the sweep names that -Dmss-version does not accept
  UNGUARDED  an accepted value the header checker does not resolve
  UNSWEPT    an accepted value with no reference DLL, or a reference entry
             with no reason beside it
  CONFLICT   two of the four lists disagree

Exit code 0 when every accepted value is either swept against a reference DLL
or declared unswept with a reason.
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD_ZIG = ROOT / "build.zig"
CHECK_HEADER = ROOT / "scripts" / "check_header.py"
MSS_H = ROOT / "src" / "mss.h"
CHECK_ALL_VERSIONS = ROOT / "scripts" / "check_all_versions.sh"

# .k = "<name>", .v = <encoded>, the last field of each entry line.
BUILD_VERSION_RE = re.compile(r'\.k\s*=\s*"([^"]+)"\s*,\s*\.v\s*=\s*(\d+)')
HEADER_VERSIONS_RE = re.compile(r"^SUPPORTED_VERSIONS\s*=\s*\[([^\]]*)\]", re.MULTILINE)
# [name] or [name]='reason', one per line inside the array.
SCRIPT_ENTRY_RE = re.compile(r"^\s*\[([^\]]+)\](?:\s*=\s*'([^']*)')?\s*$")


def array_body(text: str, name: str) -> str:
    """Return the text inside the `( ... )` array assigned to `name`.

    Covers both spellings: a one-line list of bare names (`VERSIONS=(3 4)`) and
    a multi-line `declare -A` of `[name]='reason'` entries.
    """
    match = re.search(rf"^(?:declare\s+-A\s+)?{name}=\((.*?)\)", text, re.MULTILINE | re.DOTALL)
    if not match:
        msg = f"no {name}=( ... ) array found"
        raise ValueError(msg)
    return match.group(1)


def parse_build_versions(text: str) -> dict[str, int]:
    """Accepted -Dmss-version values, as {name: encoded}."""
    return {name: int(encoded) for name, encoded in BUILD_VERSION_RE.findall(text)}


def parse_header_versions(text: str) -> set[int]:
    """The encoded values scripts/check_header.py resolves the header for."""
    match = HEADER_VERSIONS_RE.search(text)
    if not match:
        msg = "no SUPPORTED_VERSIONS list found in check_header.py"
        raise ValueError(msg)
    return {int(v) for v in re.findall(r"\d+", match.group(1))}


def parse_script_entries(text: str, name: str) -> dict[str, str | None]:
    """Entries of a shell array as {name: reason}, reason None when absent."""
    entries = {}
    for line in array_body(text, name).splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        if "[" not in stripped:  # a one-line list of bare names, e.g. VERSIONS=(3 4)
            for value in stripped.split():
                entries[value] = None
            continue
        entry = SCRIPT_ENTRY_RE.match(stripped)
        if entry is None:
            msg = f"unparsable {name} entry: {stripped!r}"
            raise ValueError(msg)
        entries[entry.group(1)] = entry.group(2)
    return entries


def parse_header_error_versions(text: str) -> set[int]:
    """The encoded values src/mss.h's #error names in its rejection message.

    mss.h validates OPENMILES_MSS_VERSION against a list spelled out in the
    #error text, because a preprocessor cannot loop over it. That makes the
    message a third place the accepted set is written down; this reads it back
    so a version added to the map and dropped from the header is a reported
    problem rather than a consumer's compile error.
    """
    match = re.search(r'#error\s+"OPENMILES_MSS_VERSION must be one of ([\d,\s]+?)\s*\(', text)
    if not match:
        msg = "no OPENMILES_MSS_VERSION #error in src/mss.h"
        raise ValueError(msg)
    return {int(v) for v in re.findall(r"\d+", match.group(1))}


def main():
    argparse.ArgumentParser(
        prog="check_versions.py",
        description=__doc__,
        epilog="Exit status: 0 every value is swept or declared unswept, 1 a value is not, "
        "2 bad invocation.",
    ).parse_args()

    build_versions = parse_build_versions(BUILD_ZIG.read_text())
    header_versions = parse_header_versions(CHECK_HEADER.read_text())
    header_error_versions = parse_header_error_versions(MSS_H.read_text())
    sweep_text = CHECK_ALL_VERSIONS.read_text()
    swept = set(parse_script_entries(sweep_text, "VERSIONS"))
    unswept = parse_script_entries(sweep_text, "UNSWEPT")

    problems = []

    if header_error_versions != header_versions:
        problems.append(
            "CONFLICT   mss.h rejects "
            f"{sorted(header_error_versions)} but check_header.py resolves "
            f"{sorted(header_versions)}; the two must be the same set"
        )

    problems += [
        f"UNKNOWN    {name}: swept but -Dmss-version does not accept it"
        for name in sorted(swept - set(build_versions))
    ]
    problems += [
        f"CONFLICT   {name}: both swept and declared unswept"
        for name in sorted(set(swept) & set(unswept))
    ]

    for name, encoded in sorted(build_versions.items()):
        if name in swept:
            continue
        if name not in unswept:
            problems.append(
                f"UNGUARDED  {name}: accepted by -Dmss-version, absent from both "
                f"VERSIONS and UNSWEPT in check_all_versions.sh"
            )
        elif not unswept[name]:
            problems.append(f"UNSWEPT    {name}: no reference DLL and no stated reason")
        if encoded not in header_versions:
            problems.append(
                f"UNGUARDED  {name}: encodes {encoded}, which check_header.py does not resolve"
            )

    for problem in problems:
        print(problem)

    covered = sorted(swept & set(build_versions), key=lambda n: (build_versions[n], n))
    print(f"swept against a reference DLL: {', '.join(covered)}")
    gaps = sorted(set(build_versions) - swept, key=lambda n: (build_versions[n], n))
    if gaps:
        print(f"no reference DLL: {', '.join(gaps)}")

    return 1 if problems else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as exc:
        print(f"check_versions: {exc}", file=sys.stderr)
        sys.exit(1)

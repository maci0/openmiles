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
  README.md                    the -Dmss-version=<...> list, and the default beside it

Reported per value:

  UNKNOWN    a value the sweep names that -Dmss-version does not accept
  UNGUARDED  an accepted value the header checker does not resolve
  UNSWEPT    an accepted value with no reference DLL, or a reference entry
             with no reason beside it
  CONFLICT   two of the four lists disagree, or a value the header accepts
             that no -Dmss-version builds

The header's list is also checked from the other side, against the default it
falls back to. A header value no build encodes is a version a consumer can
compile against and the tree never builds, so the gate that proves the four
lists agree has to notice it appearing there first.
"""

import argparse
import re
import sys
from pathlib import Path

PROG = "check_versions.py"

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

BUILD_ZIG = ROOT / "build.zig"
CHECK_HEADER = ROOT / "scripts" / "check_header.py"
MSS_H = ROOT / "src" / "mss.h"
README = ROOT / "README.md"
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


def parse_header_default(text: str) -> int:
    """The encoded value mss.h falls back to when a consumer defines none."""
    match = re.search(r"^#define\s+OPENMILES_MSS_VERSION\s+(\d+)", text, re.MULTILINE)
    if not match:
        msg = "no OPENMILES_MSS_VERSION default in src/mss.h"
        raise ValueError(msg)
    return int(match.group(1))


def parse_build_default(text: str) -> str:
    """The -Dmss-version value build.zig takes when the caller names none.

    It is the value a plain `zig build` ships, so a consumer who compiles
    against the installed header with no -D defines has to get the same build.
    """
    match = re.search(
        r'b\.option\(\[\]const u8, "mss_version".*?orelse\s+"([^"]+)"', text, re.DOTALL
    )
    if not match:
        msg = "no default -Dmss-version in build.zig"
        raise ValueError(msg)
    return match.group(1)


def parse_readme_versions(text: str) -> list[str]:
    """The accepted set the README spells, in the order it lists it.

    The README is where a consumer picks a version from, so its list is the
    one they read rather than `zig build --help`, which prints the same set
    from build.zig. A version added to the build and not to the README is a
    version that exists and is undiscoverable.
    """
    match = re.search(r"`-Dmss-version=<([^>]+)>`", text)
    if not match:
        msg = "no -Dmss-version=<...> list in README.md"
        raise ValueError(msg)
    return match.group(1).split("|")


def parse_readme_default(text: str) -> str:
    """The default the README names beside that list."""
    match = re.search(r"`-Dmss-version=<[^>]+>`\s*\(default `([^`]+)`\)", text)
    if not match:
        msg = "no default named beside the -Dmss-version list in README.md"
        raise ValueError(msg)
    return match.group(1)


def header_problems(build_versions, header_versions, header_error_versions):
    """Report every way the header's accepted set differs from the build's.

    The two header lists were only compared with each other, which catches one
    of the two directions. A value the header accepts that no build produces is
    the other: it compiles for a consumer, and for every version probe
    check_header.py runs, because each of those selects a value build.zig does
    know. Nothing else in the tree would notice it.
    """
    problems = []
    if header_error_versions != header_versions:
        problems.append(
            "CONFLICT   mss.h rejects "
            f"{sorted(header_error_versions)} but check_header.py resolves "
            f"{sorted(header_versions)}; the two must be the same set"
        )
    problems.extend(
        f"CONFLICT   {encoded}: the header accepts it, but no -Dmss-version value "
        "encodes it, so no build in the tree can ship it"
        for encoded in sorted(
            (header_error_versions | header_versions) - set(build_versions.values())
        )
    )
    return problems


def default_problems(build_versions, build_default, header_default, header_error_versions):
    """Report the two defaults that have to name the same build.

    The default is written once in the file a consumer compiles against and
    once in the file a builder configures, and neither can see the other: a
    consumer who defines no version gets the header's, a build that names none
    gets build.zig's, and the two disagreeing is an ABI-shaped DLL nobody asked
    for.
    """
    problems = []
    if build_default not in build_versions:
        problems.append(
            f"CONFLICT   build.zig defaults to -Dmss-version={build_default}, which "
            "-Dmss-version does not accept"
        )
    elif build_versions[build_default] != header_default:
        problems.append(
            f"CONFLICT   build.zig defaults to {build_default} "
            f"({build_versions[build_default]}) but mss.h defaults "
            f"OPENMILES_MSS_VERSION to {header_default}"
        )
    if header_default not in header_error_versions:
        problems.append(
            f"CONFLICT   mss.h defaults OPENMILES_MSS_VERSION to {header_default}, "
            "which its own #error does not accept"
        )
    return problems


def readme_problems(build_versions, build_default, readme):
    """Report a README whose version list or default is not the build's.

    The README is where a consumer picks a version from, ahead of
    `zig build --help`, which prints the same set from build.zig. A version the
    build takes and the README does not list is a version that exists and is
    undiscoverable, and a default named in one place and not the other sends
    the reader to rebuild a version they were never going to get.
    """
    problems = []
    readme_versions = parse_readme_versions(readme)
    if set(readme_versions) != set(build_versions):
        only_build = sorted(set(build_versions) - set(readme_versions))
        only_readme = sorted(set(readme_versions) - set(build_versions))
        problems.append(
            f"CONFLICT   the README lists {readme_versions} but -Dmss-version accepts "
            f"{sorted(build_versions)} (build only: {only_build or 'none'}; "
            f"README only: {only_readme or 'none'})"
        )
    readme_default = parse_readme_default(readme)
    if readme_default != build_default:
        problems.append(
            f"CONFLICT   the README names {readme_default} as the default "
            f"-Dmss-version, build.zig takes {build_default}"
        )
    return problems


def main():
    argparse.ArgumentParser(
        prog=PROG,
        # The docstring is laid out as prose and a column-aligned list of the
        # files that must agree; the default formatter reflows both into
        # one paragraph, losing the alignment that makes it readable.
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__,
        epilog="Exit status: 0 every value is swept or declared unswept, 1 a value is not, "
        "2 bad invocation.",
    ).parse_args()

    build_versions = parse_build_versions(BUILD_ZIG.read_text(encoding="utf-8"))
    header_versions = parse_header_versions(CHECK_HEADER.read_text(encoding="utf-8"))
    mss_h = MSS_H.read_text(encoding="utf-8")
    header_error_versions = parse_header_error_versions(mss_h)
    header_default = parse_header_default(mss_h)
    build_default = parse_build_default(BUILD_ZIG.read_text(encoding="utf-8"))
    readme = README.read_text(encoding="utf-8")
    sweep_text = CHECK_ALL_VERSIONS.read_text(encoding="utf-8")
    swept = set(parse_script_entries(sweep_text, "VERSIONS"))
    unswept = parse_script_entries(sweep_text, "UNSWEPT")

    problems = header_problems(build_versions, header_versions, header_error_versions)
    problems += default_problems(
        build_versions, build_default, header_default, header_error_versions
    )
    problems += readme_problems(build_versions, build_default, readme)

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
        # A file this gate reads is missing or unparsable: the invocation was
        # fine, the check could not run. 1, the code the sibling gates use for
        # the same condition, not a traceback.
        print(f"{PROG}: {exc}", file=sys.stderr)
        sys.exit(1)

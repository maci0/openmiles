#!/usr/bin/env python3
"""Check that every toolchain pin in the tree names the same version.

`make check-toolchain` and `make check-python` refuse to run against a Zig or
ruff or yamllint other than the one the tree declares, so a developer's green
run and CI's green run only mean the same thing if the pins agree.
build.zig.zon names the zig version once, and the Makefile and the CI workflow
read it from there; the ruff and yamllint versions are Makefile literals that CI
repeats. Nothing otherwise keeps them in step, and a stale CI pin is invisible:
CI installs the old tool, the old tool is happy with the old tree, and the merge
goes green.

The same drift applies to the C warning set, which build.zig declares once and
check_header.py repeats to compile mss.h on its own.

So this reads the pins back out of each file and compares them, reporting:

  DRIFT     a file that must derive its pin, or names a different version
  UNPINNED  a file that must name a version does not
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAKEFILE = ROOT / "Makefile"
CI_YML = ROOT / ".github" / "workflows" / "ci.yml"
RELEASE_YML = ROOT / ".github" / "workflows" / "release.yml"
ZON = ROOT / "build.zig.zon"
BUILD_ZIG = ROOT / "build.zig"
CHECK_HEADER = ROOT / "scripts" / "check_header.py"

# Makefile variable -> (files that must repeat it, pattern naming the pin).
PINS = {
    "RUFF_VERSION": (CI_YML, r"uv tool install ruff=={v}"),
    "YAMLLINT_VERSION": (CI_YML, r"uv tool install yamllint=={v}"),
}

# Workflows that build the tree, so each has to take its zig from build.zig.zon
# rather than repeating it.
ZIG_WORKFLOWS = (CI_YML, RELEASE_YML)

# The C warning set is declared once, as c_flags in build.zig, and
# check_header.py repeats it to compile mss.h on its own. The two are the same
# list, so a warning added to the build and not to the header gate compiles in
# one place and not the other, which is the drift this reports.
C_FLAGS_BUILD_ZIG_RE = re.compile(r"const c_flags = \[_\]\[\]const u8\{(?P<body>.*?)\};", re.DOTALL)
C_FLAGS_HEADER_RE = re.compile(r'"cc",(?P<body>.*?)str\(tu\)', re.DOTALL)
QUOTED_RE = re.compile(r'"(-W[A-Za-z0-9=-]+|-std=[A-Za-z0-9]+)"')


def read(path):
    if not path.is_file():
        print(f"{path.relative_to(ROOT)} MISSING   expected file is absent")
        return None
    return path.read_text()


def makefile_var(text, name):
    m = re.search(rf"^{name}\s*:=\s*(\S+)\s*$", text, re.MULTILINE)
    if not m:
        print(f"Makefile UNPINNED  {name} is not defined")
        return None
    return m.group(1)


def first(text, pattern, label, path):
    m = re.search(pattern, text, re.MULTILINE)
    if not m:
        print(f"{path.relative_to(ROOT)} UNPINNED  no {label}")
        return None
    return m.group(1)


def makefile_zig(makefile, floor):
    """The zig version the Makefile gate runs, and True if it is derived.

    The Makefile reads the version out of build.zig.zon so it is declared
    once, so the assignment is a `$(shell sed ...)` reference, not a literal.
    A literal is the second declaration this script exists to prevent, so it
    reads as drift. The value itself is the zon floor the Makefile extracts.
    """
    m = re.search(r"^ZIG_VERSION\s*:=\s*(.+)$", makefile, re.MULTILINE)
    if not m:
        print("Makefile UNPINNED  ZIG_VERSION is not defined")
        return None, False
    if ".minimum_zig_version" not in m.group(1):
        print("Makefile DRIFT     ZIG_VERSION is a literal, not read from build.zig.zon")
        return None, False
    if not floor:
        return None, False
    return floor, True


def zig_workflow_problems(path, text):
    """Report every way a workflow that builds the tree drifts off build.zig.zon.

    A literal `version:` on setup-zig builds with a compiler nobody audited,
    and it is invisible: that workflow is happy with the tree it built. A
    cache key not built from the same step output restores a cache produced
    by a different compiler.
    """
    label = path.relative_to(ROOT)
    bad = []
    if ".minimum_zig_version" not in text:
        print(f"{label} UNPINNED  never reads the zig version from build.zig.zon")
        bad.append("ZIG_VERSION source")
    for m in re.finditer(r"^\s*version:\s*(.+)$", text, re.MULTILINE):
        if "steps.zig.outputs.version" not in m.group(1):
            print(f"{label} DRIFT     setup-zig version is a literal, not the pinned one")
            bad.append("ZIG_VERSION setup step")
    keys = re.findall(r"^\s*key:.*$", text, re.MULTILINE)
    if not keys:
        print(f"{label} UNPINNED  no Zig cache key")
        bad.append("ZIG_VERSION cache key")
    elif any("steps.zig.outputs.version" not in k for k in keys):
        print(f"{label} DRIFT     Zig cache key does not use the pinned version")
        bad.append("ZIG_VERSION cache key")
    elif re.search(r"zig-\d+\.\d+", text):
        print(f"{label} DRIFT     a literal zig version sits outside build.zig.zon")
        bad.append("ZIG_VERSION literal")
    return bad


def c_flag_problems():
    """Report any disagreement between the two copies of the C warning set."""
    bad = []
    sources = (
        (BUILD_ZIG, C_FLAGS_BUILD_ZIG_RE, "c_flags"),
        (CHECK_HEADER, C_FLAGS_HEADER_RE, "the zig cc argv list"),
    )
    found = {}
    for path, pattern, label in sources:
        text = read(path)
        if text is None:
            bad.append(f"{path.name} missing")
            continue
        m = pattern.search(text)
        if not m:
            print(f"{path.relative_to(ROOT)} UNPINNED  no {label}")
            bad.append(f"{path.name} C flags")
            continue
        found[path] = QUOTED_RE.findall(m.group("body"))
    if len(found) != len(sources):
        return bad
    build_flags = found[BUILD_ZIG]
    header_flags = found[CHECK_HEADER]
    if "-Werror" not in build_flags:
        print("build.zig DRIFT     c_flags does not promote warnings to errors")
        bad.append("build.zig C flags")
    if build_flags != header_flags:
        only_build = sorted(set(build_flags) - set(header_flags))
        only_header = sorted(set(header_flags) - set(build_flags))
        print(
            f"{CHECK_HEADER.relative_to(ROOT)} DRIFT     the C warning set differs from "
            f"c_flags in build.zig (build only: {', '.join(only_build) or 'none'}; "
            f"header only: {', '.join(only_header) or 'none'})"
        )
        bad.append("check_header.py C flags")
    return bad


def main():
    argparse.ArgumentParser(
        prog="check_toolchain_pins.py",
        # The docstring is laid out as prose and a finding list; the default
        # formatter reflows both into one paragraph.
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__,
        epilog="Exit status: 0 every pin agrees, 1 they disagree, 2 bad invocation.",
    ).parse_args()

    makefile = read(MAKEFILE)
    if makefile is None:
        return 1
    problems = []

    ci = read(CI_YML)
    if ci is None:
        return 1
    zon = read(ZON)
    if zon is None:
        return 1

    floor = first(zon, r"\.minimum_zig_version\s*=\s*\"([^\"]+)\"", "minimum_zig_version", ZON)
    zig, zig_ok = makefile_zig(makefile, floor)
    if not zig_ok:
        problems.append("ZIG_VERSION")

    pins = {name: makefile_var(makefile, name) for name in PINS}
    for name, (path, pattern) in PINS.items():
        value = pins[name]
        if value is None:
            problems.append(name)
            continue
        # The pattern is built from the pin, so a file naming a different
        # version reads as UNPINNED: that is the drift case.
        if not re.search(pattern.format(v=re.escape(value)), ci, re.MULTILINE):
            print(f"{path.relative_to(ROOT)} UNPINNED  no '{name}' pin of {value}")
            problems.append(name)

    for path in ZIG_WORKFLOWS:
        text = read(path)
        if text is None:
            problems.append(f"{path.name} missing")
            continue
        problems.extend(zig_workflow_problems(path, text))

    problems.extend(c_flag_problems())

    if problems:
        print(f"{len(problems)} toolchain pin(s) disagree: {', '.join(problems)}")
        print("build.zig.zon pins zig; the Makefile literals pin ruff and yamllint. Match them.")
        return 1

    print(
        f"toolchain pins agree: zig {zig}, ruff {pins['RUFF_VERSION']}, "
        f"yamllint {pins['YAMLLINT_VERSION']}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

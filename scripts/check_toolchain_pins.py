#!/usr/bin/env python3
"""Check that every toolchain pin in the tree names the same version.

`make check-toolchain` and `make check-python` refuse to run against a Zig or
ruff other than the one the tree declares, so a developer's green run and CI's
green run only mean the same thing if the pins agree. build.zig.zon names the
zig version once, and the Makefile and the CI workflow read it from there; the
ruff version is a Makefile literal that CI repeats. Nothing otherwise keeps
them in step, and a stale CI pin is invisible: CI installs the old tool, the
old tool is happy with the old tree, and the merge goes green.

So this reads the pins back out of each file and compares them, reporting:

  DRIFT     a file that must derive its pin, or names a different version
  UNPINNED  a file that must name a version does not

Usage:
    scripts/check_toolchain_pins.py

Exit code 0 when every pin agrees.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAKEFILE = ROOT / "Makefile"
CI_YML = ROOT / ".github" / "workflows" / "ci.yml"
RELEASE_YML = ROOT / ".github" / "workflows" / "release.yml"
ZON = ROOT / "build.zig.zon"

# Makefile variable -> (files that must repeat it, pattern naming the pin).
PINS = {
    "RUFF_VERSION": (CI_YML, r"uv tool install ruff=={v}"),
}

# Workflows that build the tree, so each has to take its zig from build.zig.zon
# rather than repeating it.
ZIG_WORKFLOWS = (CI_YML, RELEASE_YML)


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


def main():
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

    if problems:
        print(f"{len(problems)} toolchain pin(s) disagree: {', '.join(problems)}")
        print("build.zig.zon pins zig; the Makefile literal pins ruff. Match them.")
        return 1

    print(f"toolchain pins agree: zig {zig}, ruff {pins['RUFF_VERSION']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Check that every toolchain pin in the tree names the same version.

`make check-toolchain` and `make check-python` refuse to run against a Zig or
ruff other than the one the Makefile names, so a developer's green run and CI's
green run only mean the same thing if the pins agree. The versions are written
down in several places by necessity: the Makefile (the gate), the CI workflow
(what it installs, and what its cache key is keyed on), and build.zig.zon (the
floor for a consumer resolving this package). Nothing otherwise keeps them in
step, and a stale CI pin is invisible: CI installs the old tool, the old tool
is happy with the old tree, and the merge goes green.

So this reads the pins back out of each file and compares them, reporting:

  DRIFT     a file pins a different version than the Makefile
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
ZON = ROOT / "build.zig.zon"

# Makefile variable -> (files that must repeat it, pattern naming the pin).
PINS = {
    "ZIG_VERSION": (CI_YML, r"version:\s*{v}"),
    "RUFF_VERSION": (CI_YML, r"uv tool install ruff=={v}"),
}


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


def main():
    makefile = read(MAKEFILE)
    if makefile is None:
        return 1
    problems = []

    pins = {name: makefile_var(makefile, name) for name in PINS}
    ci = read(CI_YML)
    if ci is None:
        return 1
    zon = read(ZON)
    if zon is None:
        return 1

    for name, (path, pattern) in PINS.items():
        if pins[name] is None:
            problems.append(name)
            continue
        # The pattern is built from the pin, so a file naming a different
        # version reads as UNPINNED: that is the drift case.
        if not re.search(pattern.format(v=re.escape(pins[name])), ci, re.MULTILINE):
            print(f"{path.relative_to(ROOT)} UNPINNED  no '{name}' pin of {pins[name]}")
            problems.append(name)

    # The CI cache key carries the toolchain version; a key left on an older
    # version restores a cache built by a different compiler.
    zig = pins["ZIG_VERSION"]
    if zig and not re.search(rf"zig-{re.escape(zig)}-\$\{{\{{ hashFiles", ci):
        problems.append("ZIG_VERSION cache key")

    floor = first(zon, r"\.minimum_zig_version\s*=\s*\"([^\"]+)\"", "minimum_zig_version", ZON)
    if zig and floor and floor != zig:
        print(f"build.zig.zon DRIFT   .minimum_zig_version is {floor}, Makefile pins {zig}")
        problems.append("ZIG_VERSION")

    if problems:
        print(f"{len(problems)} toolchain pin(s) disagree: {', '.join(problems)}")
        print("Makefile pins are the reference; update the files above to match.")
        return 1

    print(f"toolchain pins agree: zig {zig}, ruff {pins['RUFF_VERSION']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

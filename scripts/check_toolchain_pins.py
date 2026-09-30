#!/usr/bin/env python3
"""Check that every toolchain pin in the tree names the same version.

`make check-toolchain` and `make check-python` refuse to run against a Zig or
ruff or yamllint other than the one the tree declares, so a developer's green
run and CI's green run only mean the same thing if the pins agree.
build.zig.zon names the zig version once, and the Makefile and both workflows
read it from there; the uv, ruff, and yamllint versions are Makefile literals
that ci.yml and release.yml each read out of the Makefile rather than repeat.
Nothing otherwise keeps them in step, and a stale pin is invisible: CI installs
the old tool, the old tool is happy with the old tree, and the merge goes
green. A release cut from a tag with no merge gate in front of it is the case
that hides longest, which is why both workflows are held to reading the
Makefile rather than typing a version of their own.

The same drift applies to the C warning set, which build.zig declares once and
the two gates that compile C on their own repeat: check_header.py for mss.h,
check_examples.py for the snippets in the documentation.

The README names the Zig version in prose, and nothing else reads a version
out of prose. It is also the page that decides whether a contributor's first
command works, so a pin bump that stops there leaves the front page asking for
a compiler every gate in the tree refuses, and the drift is invisible to all
of them.

The gates themselves run on whatever `python3` the host resolves, so the
interpreter is the fourth pin: ruff.toml names the floor the scripts need, and
this asserts the one running is at or above it. Below it, a gate dies halfway
through with a TypeError from its own annotations, and the other gates report
nothing at all.

So this reads the pins back out of each file and compares them, reporting:

  DRIFT     a file that must derive its pin, or names a different version
  UNPINNED  a file that must name a version does not
  TOO OLD   the interpreter is below the floor ruff.toml declares
"""

import argparse
import re
import sys
from pathlib import Path

PROG = "check_toolchain_pins.py"

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

MAKEFILE = ROOT / "Makefile"
README = ROOT / "README.md"
CI_YML = ROOT / ".github" / "workflows" / "ci.yml"
RELEASE_YML = ROOT / ".github" / "workflows" / "release.yml"
ZON = ROOT / "build.zig.zon"
BUILD_ZIG = ROOT / "build.zig"
CHECK_HEADER = ROOT / "scripts" / "check_header.py"
CHECK_EXAMPLES = ROOT / "scripts" / "check_examples.py"
RUFF_TOML = ROOT / "ruff.toml"

# Makefile variables that name a tool version. Each is a literal here and
# nowhere else: both workflows that install these tools read them out of the
# Makefile, and this script is what holds them to that.
PINS = ("UV_VERSION", "RUFF_VERSION", "YAMLLINT_VERSION")

# The workflows that install the pinned linters, each of which has to take every
# pin out of the Makefile rather than repeating it. A literal in either is a
# version nothing compares: the analyzer set that gates a merge, and the one
# that cuts a release from a tag with no merge gate in front of it, can then
# differ from the tree's, and the drift is invisible in the way that matters
# (CI installs the old tool, the old tool is happy with the old tree).
DERIVED_PINS = ((CI_YML, PINS), (RELEASE_YML, PINS))

# Workflows that build the tree, so each has to take its zig from build.zig.zon
# rather than repeating it.
ZIG_WORKFLOWS = (CI_YML, RELEASE_YML)

# The C warning set is declared once, as c_flags in build.zig, and repeated by
# the two gates that compile C on their own: check_header.py for mss.h, and
# check_examples.py for the snippets in the documentation. All three are the
# same list, so a warning added to the build and to only one gate compiles in
# one place and not the others, which is the drift this reports. Leaving the
# examples gate out of the comparison is the same defect one step further
# down: a documentation snippet would then pass under a laxer set than the
# build compiles the library with, and the copy a consumer starts from is the
# one least worth trusting.
C_FLAGS_BUILD_ZIG_RE = re.compile(r"const c_flags = \[_\]\[\]const u8\{(?P<body>.*?)\};", re.DOTALL)
C_FLAGS_HEADER_RE = re.compile(r'"cc",(?P<body>.*?)str\(tu\)', re.DOTALL)
C_FLAGS_EXAMPLES_RE = re.compile(r"^CFLAGS = \[(?P<body>.*?)^\]", re.DOTALL | re.MULTILINE)
QUOTED_RE = re.compile(r'"(-W[A-Za-z0-9=-]+|-std=[A-Za-z0-9]+)"')


def read(path):
    if not path.is_file():
        print(f"{path.relative_to(ROOT)} MISSING   expected file is absent")
        return None
    return path.read_text(encoding="utf-8")


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
        # setup-uv reads the uv-pin step, which derived_pin_problems holds to
        # the Makefile UV_VERSION.
        if "steps.uv-pin.outputs.version" in m.group(1):
            continue
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


def derived_pin_problems(path, text, names):
    """Report a workflow that repeats a pin the Makefile already owns.

    A literal in either workflow is invisible in the way that matters. On the
    merge gate CI installs whatever the literal says and the old tool is happy
    with the tree it gates; on a release the tag is cut with no merge gate in
    front of it, so the analyzer set that ships can be one no other run has
    ever used. Reading the Makefile leaves a single copy, and a pin the gate
    does not compare is a pin that drifts.
    """
    bad = []
    for name in names:
        if f"s/^{name} := " not in text:
            print(f"{path.relative_to(ROOT)} UNPINNED  does not read {name} from the Makefile")
            bad.append(name)
    if re.search(r"(?:uv tool install|pipx install) [\"']?[a-z-]+==\d", text):
        print(f"{path.relative_to(ROOT)} DRIFT     a tool version is a literal, not the pinned one")
        bad.append("tool literals")
    return bad


def c_flag_problems():
    """Report any disagreement between the copies of the C warning set."""
    bad = []
    sources = (
        (BUILD_ZIG, C_FLAGS_BUILD_ZIG_RE, "c_flags"),
        (CHECK_HEADER, C_FLAGS_HEADER_RE, "the zig cc argv list"),
        (CHECK_EXAMPLES, C_FLAGS_EXAMPLES_RE, "the zig cc CFLAGS list"),
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
    if "-Werror" not in build_flags:
        print("build.zig DRIFT     c_flags does not promote warnings to errors")
        bad.append("build.zig C flags")
    for path, flags in found.items():
        if path == BUILD_ZIG or flags == build_flags:
            continue
        only_build = sorted(set(build_flags) - set(flags))
        only_other = sorted(set(flags) - set(build_flags))
        print(
            f"{path.relative_to(ROOT)} DRIFT     the C warning set differs from "
            f"c_flags in build.zig (build only: {', '.join(only_build) or 'none'}; "
            f"gate only: {', '.join(only_other) or 'none'})"
        )
        bad.append(f"{path.name} C flags")
    return bad


def readme_zig_problems(floor):
    """Report a README whose build requirements name another Zig.

    The README is the page a new contributor reads before anything else, and
    the version in it is the one instruction they act on. A pin bump that
    misses it is worse than a stale comment elsewhere: `make build` then
    refuses on the compiler the front page told them to install, and the only
    evidence is a version line three screens into a build failure.
    """
    if not floor:
        return ["ZIG_VERSION source"]
    text = read(README)
    if text is None:
        return ["README.md missing"]
    # One version is named, in the build requirements. Reading every `Zig x.y.z`
    # rather than that one line keeps a second mention (a flag example, a
    # changelog quote) from making the gate pass or fail on the wrong one.
    stated = re.search(r"^Requires \[Zig ([\d.]+)\]", text, re.MULTILINE)
    if not stated:
        print("README.md UNPINNED  the build requirements name no Zig version")
        return ["README ZIG_VERSION"]
    if stated.group(1) != floor:
        print(
            f"README.md DRIFT     build requirements name Zig {stated.group(1)}, "
            f"build.zig.zon pins {floor}"
        )
        return ["README ZIG_VERSION"]
    return []


def interpreter_problems():
    """Report an interpreter below the floor ruff.toml declares.

    ruff.toml's target-version is what the scripts are written against; the
    gate runs on whatever python3 the host resolved. A host under that floor
    does not fail the way a version check fails: the module importing it dies
    on its own annotations, part-way through the sweep, having reported
    nothing, so the tree reads as half-checked rather than rejected.
    """
    text = read(RUFF_TOML)
    if text is None:
        return ["ruff.toml missing"]
    m = re.search(r'^target-version\s*=\s*"(?P<major>py)(?P<minor>\d)(\d+)"', text, re.MULTILINE)
    if not m:
        print("ruff.toml UNPINNED  no target-version for the scripts to be written against")
        return ["ruff.toml target-version"]
    floor = (int(m.group("minor")), int(m.group(3)))
    if sys.version_info[:2] < floor:
        running = ".".join(str(n) for n in sys.version_info[:2])
        print(
            f"TOO OLD            python {running} cannot import the gates; "
            f"ruff.toml declares py{floor[0]}{floor[1]}"
        )
        return ["interpreter floor"]
    return []


def main():
    argparse.ArgumentParser(
        prog=PROG,
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

    zon = read(ZON)
    if zon is None:
        return 1

    floor = first(zon, r"\.minimum_zig_version\s*=\s*\"([^\"]+)\"", "minimum_zig_version", ZON)
    zig, zig_ok = makefile_zig(makefile, floor)
    if not zig_ok:
        problems.append("ZIG_VERSION")

    pins = {name: makefile_var(makefile, name) for name in PINS}
    problems.extend(name for name, value in pins.items() if value is None)

    for path in ZIG_WORKFLOWS:
        text = read(path)
        if text is None:
            problems.append(f"{path.name} missing")
            continue
        problems.extend(zig_workflow_problems(path, text))

    for path, names in DERIVED_PINS:
        text = read(path)
        if text is None:
            problems.append(f"{path.name} missing")
            continue
        problems.extend(derived_pin_problems(path, text, names))

    problems.extend(c_flag_problems())
    problems.extend(readme_zig_problems(floor))
    problems.extend(interpreter_problems())

    if problems:
        print(f"{len(problems)} toolchain pin(s) disagree: {', '.join(problems)}")
        print("build.zig.zon pins zig; the Makefile literals pin uv, ruff, and yamllint.")
        print("ruff.toml pins the Python floor; run the gates on an interpreter that meets it.")
        return 1

    print(
        f"toolchain pins agree: zig {zig}, uv {pins['UV_VERSION']}, "
        f"ruff {pins['RUFF_VERSION']}, yamllint {pins['YAMLLINT_VERSION']}"
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

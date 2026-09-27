#!/usr/bin/env python3
"""Compile the C snippets in the documentation against src/mss.h.

A consumer copies a snippet out of the README before reading anything else, so
a snippet that names a function the header does not declare, or that trips the
warning set build.zig compiles C with, is a broken first step. Prose is not
checked; only fenced ```c blocks, which is where every compilable example in
this repository lives.

Each block is compiled once, with the OPENMILES_MSS_VERSION it sets (90, the
default build, when it sets none), so a snippet that uses a declaration its own
version build does not provide fails here rather than at the consumer's link
step.

This reports:

  COMPILE  the block does not compile as C99 with the project's warning set

and reports the count it checked, so a document that stops carrying examples is
visible rather than silent.
"""

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# Walk up for the project marker rather than assuming a fixed depth, so the
# gate runs the same from the repo root, from scripts/, and from a build dir.
for ROOT in Path(__file__).resolve().parents:
    if (ROOT / "build.zig.zon").is_file():
        break
else:  # pragma: no cover - the script always lives inside the repository
    print("error: build.zig.zon not found above scripts/", file=sys.stderr)
    sys.exit(2)

MSS_H = ROOT / "src" / "mss.h"
DOCS = [ROOT / "README.md", *sorted((ROOT / "docs").glob("*.md"))]

# Fenced C blocks: an opening ```c line, everything up to the closing fence.
BLOCK_RE = re.compile(r"^```c[ \t]*\n(.*?)^```[ \t]*$", re.MULTILINE | re.DOTALL)

# The version a block selects, if it names one itself. A block that omits it
# gets the default build, so it is checked against the declarations that build
# exports.
VERSION_RE = re.compile(r"^\s*#\s*define\s+OPENMILES_MSS_VERSION\s+(\d+)", re.MULTILINE)

# The warning set build.zig compiles C with, and the one check_header.py
# compiles the header under, so a snippet that passes here is the same
# translation unit a consumer's build would accept.
CFLAGS = [
    "-c",
    "-std=c99",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-Wpedantic",
    "-Wno-c11-extensions",
    "-Wshadow",
    "-Wstrict-prototypes",
    "-Wold-style-definition",
    "-Wvla",
    "-Wformat=2",
    "-Wno-format-nonliteral",
    "-Wwrite-strings",
]


def main():
    parser = argparse.ArgumentParser(
        prog="check_examples.py",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__,
        epilog="Exit status: 0 every snippet compiles, 1 one does not, 2 bad invocation.",
    )
    parser.parse_args()

    zig = shutil.which("zig")
    if zig is None:
        print(
            "error: zig not found on PATH; `make check-toolchain` names the version",
            file=sys.stderr,
        )
        # 1, not 2: the invocation was fine, the check could not run. Every
        # gate reserves 2 for a bad argument.
        sys.exit(1)

    problems = []
    checked = 0
    for doc in DOCS:
        if not doc.is_file():
            continue
        text = doc.read_text()
        for index, block in enumerate(BLOCK_RE.findall(text), start=1):
            checked += 1
            line = text[: text.index(block)].count("\n") + 1
            version_match = VERSION_RE.search(block)
            version = version_match.group(1) if version_match else "90"
            with tempfile.TemporaryDirectory() as tmp:
                unit = Path(tmp) / "example.c"
                unit.write_text(block)
                # S603: a fixed argv list with no shell, built here rather than
                # from input, running the zig resolved by the caller. The only
                # path handed to it is the temp file this block was just
                # written to; nothing from a document reaches argv.
                proc = subprocess.run(  # noqa: S603
                    [
                        zig,
                        "cc",
                        *CFLAGS,
                        str(unit),
                        f"-I{MSS_H.parent}",
                        "-o",
                        str(Path(tmp) / "example.o"),
                    ],
                    capture_output=True,
                    text=True,
                    check=False,
                )
            if proc.returncode != 0:
                problems.append(
                    f"{doc.relative_to(ROOT)}:{line} COMPILE    "
                    f"block {index} (OPENMILES_MSS_VERSION={version}) does not compile: "
                    + " ".join(proc.stderr.split())[:400]
                )

    for problem in problems:
        print(problem)
    print(f"checked {checked} C snippet(s) against {MSS_H.relative_to(ROOT)}")

    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

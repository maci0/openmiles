#!/usr/bin/env python3
"""Shellcheck the `run:` blocks of the GitHub Actions workflows.

`make lint` shellchecks scripts/*.sh, but a workflow's shell is a second body of
the same code: it unpins the toolchain, cross-checks build.zig.zon against the
tag being released, and reads the PE headers of the shipped DLL. yamllint reads
it as YAML, so a quoting mistake or an unchecked substitution in one of those
blocks parses cleanly and fails on the runner instead, where the fix is a
re-run of a release rather than a commit.

Every `run:` step is extracted verbatim, inline scalar and block scalar alike,
and handed to shellcheck as one bash script per workflow, so the whole set is
checked on every `make lint` and a new step is checked by writing it.

  PARSE       a workflow has no readable `run:` block (a step whose shell is
              assembled from an expression shellcheck cannot read), which
              means a step escaped the gate and has to be named here
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import NamedTuple

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

WORKFLOWS = ROOT / ".github"

# `run:` as a mapping key, with or without the `-` of a list item, holding
# either an inline scalar or the indicator of a block scalar. The scalar is the
# rest of the line, so a one-line step like `run: make lint` is read as the
# command it runs rather than as the block indicator alone.
RUN_RE = re.compile(r"^(?P<indent>[ \t]*)(?:-[ \t]+)?run:[ \t]*(?P<scalar>.*?)[ \t]*$")
# The step's own `name:`, which is what a finding has to point a reader at. The
# last one seen before the `run:` key belongs to the same step.
NAME_RE = re.compile(r"^[ \t]*(?:-[ \t]+)?name:[ \t]*(?P<name>\S.*?)[ \t]*$")
# The block scalar indicators, with either chomping indicator attached. The
# content is passed to shellcheck as written, so a folded `>` is read as the
# lines it is rather than as the single string YAML would produce; both are
# shell the runner executes line by line.
BLOCK_SCALARS = frozenset({"|", "|-", "|+", ">", ">-", ">+"})
# The shell every `run:` step is executed with unless the step says otherwise,
# which none of the workflows in this tree do. Set as a directive rather than as
# a flag so the file handed to shellcheck carries it too.
BASH_DIRECTIVE = "# shellcheck shell=bash"
# A finding as shellcheck reports it against the concatenated script, which
# carries no file name of its own: it is stdin, which it names as `-`.
FINDING_RE = re.compile(
    r"^(?:<stdin>|-):(?P<line>\d+):(?P<column>\d+): (?P<level>\S+): (?P<text>.*)$"
)

PROG = "check_workflow_shell.py"


class Block(NamedTuple):
    """One `run:` step, and where in the concatenated script it starts."""

    # The workflow, the step name, and the line the step's `run:` key is on.
    label: str
    # 1-based line in the script handed to shellcheck where the body starts.
    start: int


def workflow_files() -> list[Path]:
    """Every YAML file under .github, workflows and dependabot alike.

    dependabot.yml is linted by yamllint for the same reason the workflows are,
    and it grows `run:` blocks of its own as an ecosystem is added; a file that
    is only checked when a step is added by hand is a file that will not be.
    """
    found = sorted(
        path
        for pattern in ("*.yml", "*.yaml")
        for path in WORKFLOWS.rglob(pattern)
        if path.is_file()
    )
    if not found:
        message = f"no workflow files under {WORKFLOWS.relative_to(ROOT)}"
        raise ValueError(message)
    return found


def parse(path: Path) -> tuple[str, list[Block]]:
    """Split one workflow into the script shellcheck reads and where each step is.

    The parser reads the two shapes a `run:` key takes and nothing else, so a
    workflow that used a YAML anchor to build its shell, or an expression for
    the body, is reported rather than passed over: a step the gate cannot read
    is a step nothing checks.
    """
    lines = path.read_text(encoding="utf-8").splitlines()
    parts: list[str] = [BASH_DIRECTIVE]
    blocks: list[Block] = []
    name = ""
    index = 0
    while index < len(lines):
        line = lines[index]
        matched = NAME_RE.match(line)
        if matched:
            name = matched.group("name")
        run = RUN_RE.match(line)
        if run is None:
            index += 1
            continue
        scalar = run.group("scalar")
        indent = len(run.group("indent"))
        if not scalar:
            # `- run:` with nothing after it: either a block scalar whose
            # indicator sits on the next line, or a key with no value at all.
            # Neither is a shell this gate can read.
            message = f"{path.relative_to(ROOT)}:{index + 1}: 'run:' with no shell on the same line"
            raise ValueError(message)
        if scalar in BLOCK_SCALARS:
            body, index = read_block(lines, index + 1, indent)
        else:
            body = [scalar]
            index += 1
        while body and not body[-1].strip():
            body.pop()
        if not body:
            message = (
                f"{path.relative_to(ROOT)}:{index}: '{name or 'unnamed step'}' has an "
                "empty run block"
            )
            raise ValueError(message)
        where = f"{path.relative_to(ROOT)}: {name or 'unnamed step'}"
        # A blank line between the blocks keeps a finding's line count readable
        # in shellcheck's own output, and the directive is line 1 of the script
        # whether there is one block or twenty.
        if len(parts) > 1:
            parts.append("")
        parts.append(f"# {where}")
        blocks.append(Block(where, len(parts) + 1))
        parts.extend(body)
    return "\n".join(parts) + "\n", blocks


def read_block(lines: list[str], start: int, indent: int) -> tuple[list[str], int]:
    """Read a block scalar's lines, stripped of the indent that introduces it.

    The first non-blank line sets the block's own indentation, and every line
    indented at least as far belongs to it. A line indented no further ends the
    block, which is the case the sibling `name:` key is in.
    """
    body: list[str] = []
    base: int | None = None
    index = start
    while index < len(lines):
        line = lines[index]
        if not line.strip():
            body.append("")
            index += 1
            continue
        width = len(line) - len(line.lstrip())
        if width <= indent:
            break
        if base is None:
            base = width
        body.append(line[base:])
        index += 1
    return body, index


def check(shellcheck: Path, script: str, blocks: list[Block]) -> list[str]:
    """Run shellcheck over one workflow's concatenated script.

    Returns the findings, each rewritten to name the step it came from: the
    script handed to shellcheck is a temporary concatenation, so the line
    number alone points at nothing a reader can open.
    """
    # S603: a fixed argv list with no shell, running the shellcheck resolved
    # below. The only thing reaching stdin is the script built from the
    # workflows in this repository; nothing untrusted reaches argv.
    proc = subprocess.run(  # noqa: S603
        [str(shellcheck), "--format=gcc", "-"],
        input=script,
        capture_output=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    findings = []
    for line in proc.stdout.splitlines():
        found = FINDING_RE.match(line)
        if found is None:
            findings.append(line)
            continue
        line_no = int(found.group("line"))
        step = "the workflow"
        for block in reversed(blocks):
            if block.start <= line_no:
                step = block.label
                break
        findings.append(
            f"{step}: {found.group('text')} (script line {line_no}, column {found.group('column')})"
        )
    if proc.returncode not in (0, 1) and not findings:
        # shellcheck exits above 1 on a failure of its own: a bad option, a
        # missing file. The report says so, and no finding list would.
        findings.append(proc.stderr.strip() or f"shellcheck exited {proc.returncode}")
    return findings


def main() -> int:
    parser = argparse.ArgumentParser(
        prog=PROG,
        # The docstring is laid out as prose and a short list of what cannot be
        # read; the default formatter reflows the list into the prose.
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__,
        epilog="Exit status: 0 every run block is clean, 1 one is not, 2 bad invocation.",
    )
    parser.parse_args()

    shellcheck = shutil.which("shellcheck")
    if shellcheck is None:
        print(
            "error: shellcheck not found on PATH; 'make lint' shellchecks "
            "scripts/*.sh and the workflow run blocks",
            file=sys.stderr,
        )
        return 1

    total = 0
    problems: list[str] = []
    for path in workflow_files():
        script, blocks = parse(path)
        total += len(blocks)
        findings = check(Path(shellcheck), script, blocks)
        if findings:
            problems.extend(findings)
            continue
        print(f"{path.relative_to(ROOT)}: {len(blocks)} run block(s) clean")

    if problems:
        print(f"{len(problems)} shellcheck finding(s) in the workflow run blocks:")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print(f"workflow shell: {total} run block(s) shellcheck clean")
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

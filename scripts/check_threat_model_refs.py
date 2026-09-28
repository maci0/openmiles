#!/usr/bin/env python3
"""Check the file:line anchor references in docs/THREAT_MODEL.md.

A threat model is only useful if a reader can open each reference and find the
code it claims. Editing moves lines, so a model written once goes stale within a
few commits and its "partial" and "mitigated" verdicts become claims nobody
re-verified, which is worse than naming the gap.

Each reference is written as `path:line anchor`. The anchor is an identifier
that must appear on exactly that line, so a moved or deleted definition fails
here rather than silently misdirecting the next pass.

  MISSINGFILE  the referenced path does not exist
  BADLINE      the line number is outside the file
  NOMATCH      the anchor is not on that line
  UNPARSED     a backticked `path:line` reference carries no anchor
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# A source path (has an extension we ship), a line number, and a bare anchor
# identifier. Ranges are deliberately not accepted: "138-176" cannot be checked
# against a single anchor, and that is the form that went stale in the first
# place.
REF_RE = re.compile(
    r"`(?P<path>[\w./-]+\.(?:zig|py|sh|h|yml|yaml|zon)):(?P<line>\d+)\s+"
    r"(?P<anchor>[A-Za-z_][\w.]*)`"
)
# Any backticked `path:digits...` token, the whole reference shape including a
# missing or malformed anchor. Every one of these has to be matched by REF_RE,
# so a half-written reference is reported rather than skipped.
CANDIDATE_RE = re.compile(r"`(?P<path>[\w./-]+\.(?:zig|py|sh|h|yml|yaml|zon)):\d[^`]*`")

PROG = "check_threat_model_refs.py"

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

DOC = ROOT / "docs" / "THREAT_MODEL.md"


def anchor_re(anchor: str) -> re.Pattern[str]:
    """Match `anchor` as a whole identifier, not as a piece of a longer one.

    A plain substring test is a false pass waiting to happen: `exclusive`
    matches a comment saying a name is "created exclusively", so the reference
    keeps resolving after the code it points at has moved off that line, which
    is the exact drift this check exists to catch. The boundaries are word
    characters only, so a qualified call still resolves: `loadAllAsi` is found
    in `driver.loadAllAsi(scan_path)`.

    The anchor is the document's own text, never the source's, so it is quoted
    rather than interpolated as a pattern.
    """
    return re.compile(rf"(?<!\w){re.escape(anchor)}(?!\w)")


def main() -> int:
    parser = argparse.ArgumentParser(
        prog=PROG,
        # The docstring is laid out as prose and a column-aligned list of the
        # four finding kinds; the default formatter reflows both into one
        # paragraph, losing the list.
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__,
        epilog="Exit status: 0 every reference resolves, 1 one does not, 2 bad invocation.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="print each reference that resolves, not just the summary",
    )
    args = parser.parse_args()

    if not DOC.exists():
        # 1, not 2: nothing about the invocation is wrong, the check could not
        # run. Every gate reserves 2 for a bad argument.
        print(f"error: {DOC} not found", file=sys.stderr)
        return 1

    text = DOC.read_text(encoding="utf-8")
    problems: list[str] = []
    checked = 0

    for candidate in CANDIDATE_RE.finditer(text):
        if REF_RE.fullmatch(candidate.group(0)):
            continue
        problems.append(
            f"UNPARSED {candidate.group(0)[1:]}: a reference is `path:line anchor`, "
            f"with the anchor present"
        )

    for match in REF_RE.finditer(text):
        checked += 1
        path = match.group("path")
        line_no = int(match.group("line"))
        anchor = match.group("anchor")

        target = ROOT / path
        if not target.exists():
            problems.append(f"MISSINGFILE {path}:{line_no} {anchor}: {path} does not exist")
            continue

        lines = target.read_text(encoding="utf-8", errors="replace").splitlines()
        if not 1 <= line_no <= len(lines):
            problems.append(f"BADLINE {path}:{line_no} {anchor}: file has {len(lines)} lines")
            continue

        if not anchor_re(anchor).search(lines[line_no - 1]):
            problems.append(f"NOMATCH {path}:{line_no} {anchor}: anchor is not on that line")
        elif args.verbose:
            print(f"ok {path}:{line_no} {anchor}")

    # Findings are the result of the check, so they go to stdout alongside the
    # passing summary, the way the sibling gates report. stderr carries the
    # hard errors above, the ones that mean the check never ran.
    if problems:
        print(f"{len(problems)} threat model reference problem(s):")
        for problem in problems:
            print(f"  {problem}")
        return 1

    print(f"threat model: {checked} file:line reference(s) resolve")
    return 0


if __name__ == "__main__":
    sys.exit(main())

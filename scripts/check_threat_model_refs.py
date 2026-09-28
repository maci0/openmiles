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

Editing the sources moves every reference into the edited file by the same
amount, so `--update` re-anchors them: the line shift that accounts for most of
a file's references is applied to that file's references, and each rewrite is
printed for review before the file is written. A reference the shift does not
account for is left alone and reported with the lines its anchor now sits on,
because pointing it at a neighbouring occurrence would be a false pass.
"""

from __future__ import annotations

import argparse
import re
import sys
from collections import Counter
from pathlib import Path
from typing import NamedTuple

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


class Stale(NamedTuple):
    """A reference whose anchor is no longer on the line the document names."""

    path: str
    line: int
    anchor: str
    # Every line the anchor is on now. More than one means the identifier is
    # not unique in the file and the shift, not a search, decides.
    hits: list[int]
    # Byte span of the line number in the document.
    span: tuple[int, int]


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


def anchor_lines(lines: list[str], anchor: str) -> list[int]:
    """Every 1-based line the anchor is on, in file order."""
    rx = anchor_re(anchor)
    return [i + 1 for i, line in enumerate(lines) if rx.search(line)]


def file_shift(stale: list[Stale]) -> int:
    """The one line shift that explains the most stale references in a file.

    Drift is an edit above the reference, so the references into one file move
    together. The shift that accounts for the most of them is the one the
    document was written against. A reference the shift does not account for
    points at code that moved differently, and --update leaves it alone rather
    than re-aiming it at whichever line happens to be closest: a reference that
    resolves to the wrong occurrence is a false pass, which is what this gate
    exists to prevent.
    """
    counts: Counter[int] = Counter()
    for ref in stale:
        for hit in ref.hits:
            counts[hit - ref.line] += 1
    return min(counts, key=lambda d: (-counts[d], abs(d), d))


def scan(
    match: re.Match[str],
    args: argparse.Namespace,
    problems: list[str],
    stale: dict[str, list[Stale]],
) -> None:
    """Judge one reference: append a finding, or collect it for --update.

    Both accumulators are mutated in place. A reference the file does not
    resolve at all is a finding either way; only --update collects the rest.
    """
    path = match.group("path")
    line_no = int(match.group("line"))
    anchor = match.group("anchor")

    target = ROOT / path
    if not target.exists():
        problems.append(f"MISSINGFILE {path}:{line_no} {anchor}: {path} does not exist")
        return None

    lines = target.read_text(encoding="utf-8", errors="replace").splitlines()
    if not 1 <= line_no <= len(lines):
        problems.append(f"BADLINE {path}:{line_no} {anchor}: file has {len(lines)} lines")
        return None

    if anchor_re(anchor).search(lines[line_no - 1]):
        if args.verbose:
            print(f"ok {path}:{line_no} {anchor}")
        return None

    if args.update:
        stale.setdefault(path, []).append(
            Stale(path, line_no, anchor, anchor_lines(lines, anchor), match.span("line"))
        )
    else:
        problems.append(f"NOMATCH {path}:{line_no} {anchor}: anchor is not on that line")
    return problems, stale, None


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
    parser.add_argument(
        "--update",
        action="store_true",
        help=(
            "re-anchor stale references by the line shift that accounts for most "
            "of each file's, then check again; a reference that shift does not "
            "account for is left alone and reported"
        ),
    )
    args = parser.parse_args()

    if not DOC.exists():
        # 1, not 2: nothing about the invocation is wrong, the check could not
        # run. Every gate reserves 2 for a bad argument.
        print(f"error: {DOC} not found", file=sys.stderr)
        return 1

    # Bytes, not read_text: --update writes the file back, and a read that
    # normalises CRLF would hand back a document with its line endings changed.
    text = DOC.read_bytes().decode("utf-8")
    problems: list[str] = []
    checked = 0
    # Stale references per file, and the (start, end, replacement) spans of the
    # line numbers --update rewrites.
    stale: dict[str, list[Stale]] = {}
    rewrites: list[tuple[int, int, str]] = []

    for candidate in CANDIDATE_RE.finditer(text):
        if REF_RE.fullmatch(candidate.group(0)):
            continue
        problems.append(
            f"UNPARSED {candidate.group(0)[1:]}: a reference is `path:line anchor`, "
            f"with the anchor present"
        )

    for match in REF_RE.finditer(text):
        checked += 1
        scan(match, args, problems, stale)

    for path, refs in stale.items():
        shift = file_shift(refs)
        for ref in refs:
            moved = ref.line + shift
            if moved not in ref.hits:
                where = ", ".join(str(h) for h in ref.hits) or "nowhere in the file"
                problems.append(
                    f"NOMATCH {path}:{ref.line} {ref.anchor}: anchor is not on that line "
                    f"(it is on {where})"
                )
                continue
            print(f"{path}:{ref.line} -> {moved}  {ref.anchor}")
            rewrites.append((*ref.span, str(moved)))

    if rewrites:
        # Last reference first, so the offsets collected in document order stay
        # valid as the text ahead of them grows.
        for start, end, replacement in sorted(rewrites, reverse=True):
            text = text[:start] + replacement + text[end:]
        DOC.write_bytes(text.encode("utf-8"))
        print(f"rewrote {len(rewrites)} reference(s) in {DOC.relative_to(ROOT)}")

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
    try:
        sys.exit(main())
    except (OSError, ValueError) as exc:
        # A file this gate reads is missing or unparsable: the invocation was
        # fine, the check could not run. 1, the code the sibling gates use for
        # the same condition, not a traceback.
        print(f"{PROG}: {exc}", file=sys.stderr)
        sys.exit(1)

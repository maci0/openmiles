#!/usr/bin/env python3
"""Export-parity checker: diff our built mss32.dll against a real Miles DLL.

The real DLL's decorated export table (e.g. `_AIL_init_sample@8`) is the ABI
ground truth — it is exactly what the import library games linked against
resolves by name, including the stdcall byte-count decoration. A faithful
reimplementation must export the same names with the same `@N`.
"""

import argparse
import re
import sys

try:
    import pefile
except ImportError:
    # Deferred rather than fatal so `--check-deps` can answer the question the
    # Makefile's parity preflight asks without a `python -c` one-liner in the
    # Makefile itself, which is a second language in a command that belongs to
    # one. Every other path reports the same missing package.
    pefile = None

EXIT_OK = 0
PROG = "check_exports.py"
# 1 covers both a parity difference and a check that could not run at all: an
# unreadable DLL, or a file that is not a PE image. The invocation was fine in
# both cases, which is what every sibling gate means by 1 and what keeps 2 for
# a bad invocation alone, so a script reading the code can tell a broken
# reference DLL from a typo on the command line.
EXIT_FAIL = 1
# argparse's own exit code, for a missing or misspelled argument.
EXIT_USAGE = 2


DEPS_HINT = "pefile not importable; uv pip install -r scripts/requirements.txt"


def exports(path):
    """Export names of a PE image, or raise ValueError naming the bad input."""
    if pefile is None:
        raise ValueError(DEPS_HINT)
    try:
        pe = pefile.PE(path, fast_load=True)
    except OSError as exc:
        msg = f"cannot read {path}: {exc.strerror}"
        raise ValueError(msg) from exc
    except pefile.PEFormatError as exc:
        msg = f"{path} is not a PE image"
        raise ValueError(msg) from exc
    try:
        pe.parse_data_directories(
            directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_EXPORT"]]
        )
        out = set()
        if hasattr(pe, "DIRECTORY_ENTRY_EXPORT"):
            for e in pe.DIRECTORY_ENTRY_EXPORT.symbols:
                if e.name:
                    out.add(e.name.decode())
        return out
    finally:
        pe.close()


def norm(n):
    """Strip leading underscore and trailing @N so the same function compares
    equal regardless of stdcall decoration."""
    return re.sub(r"@\d+$", "", n.lstrip("_"))


def main(argv=None):
    # Before argparse: the preflight runs this with no DLL arguments at all, and
    # it only wants to know whether the third-party import resolved.
    if argv is None:
        argv = sys.argv[1:]
    if argv == ["--check-deps"]:
        if pefile is None:
            print(f"{PROG}: {DEPS_HINT}", file=sys.stderr)
            return EXIT_FAIL
        return EXIT_OK

    parser = argparse.ArgumentParser(
        prog=PROG,
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description="Diff a built mss32.dll export table against a real Miles DLL.",
        epilog=(
            "Exit status: 0 export tables match, 1 discrepancies found or a DLL "
            "could not be read, 2 bad invocation."
        ),
    )
    parser.add_argument("ours", metavar="OURS.dll", help="DLL we built")
    parser.add_argument("reference", metavar="REFERENCE.dll", help="real Miles DLL")
    parser.add_argument(
        "--check-deps",
        action="store_true",
        help="report whether pefile is importable, and exit (pass it alone)",
    )
    parser.add_argument(
        "--names-only",
        action="store_true",
        help="print the discrepancy counts only, not the symbol names",
    )
    parser.add_argument(
        "--strict",
        action="store_true",
        help="fail on EXTRA too (we export symbols the reference lacks)",
    )
    args = parser.parse_args(argv)

    try:
        ours = exports(args.ours)
        ref = exports(args.reference)
    except ValueError as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        return EXIT_FAIL

    on = {norm(x): x for x in ours}
    rn = {norm(x): x for x in ref}

    missing = sorted(k for k in rn if k not in on)
    deco = sorted(k for k in (set(rn) & set(on)) if rn[k] != on[k])
    extra = sorted(k for k in on if k not in rn)

    print(f"ours={len(ours)}  reference={len(ref)}")
    print(f"MISSING (in reference, absent from ours): {len(missing)}")
    if not args.names_only:
        for k in missing:
            print(f"    {rn[k]}")
    print(f"DECORATION MISMATCH (wrong @N or underscore): {len(deco)}")
    if not args.names_only:
        for k in deco:
            print(f"    reference={rn[k]:44} ours={on[k]}")
    print(f"EXTRA (in ours, not in reference): {len(extra)}")
    if not args.names_only:
        for k in extra:
            print(f"    {on[k]}")

    diffs = len(missing) + len(deco) + (len(extra) if args.strict else 0)
    return EXIT_FAIL if diffs else EXIT_OK


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as exc:
        # A DLL named on the command line is missing or unparsable: the
        # invocation was fine, the check could not run. 1, the code the
        # sibling gates use for the same condition, not a traceback.
        print(f"{PROG}: {exc}", file=sys.stderr)
        sys.exit(EXIT_FAIL)

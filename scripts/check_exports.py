#!/usr/bin/env python3
"""Export-parity checker: diff our built mss32.dll against a real Miles DLL.

The real DLL's decorated export table (e.g. `_AIL_init_sample@8`) is the ABI
ground truth — it is exactly what the import library games linked against
resolves by name, including the stdcall byte-count decoration. A faithful
reimplementation must export the same names with the same `@N`.

Usage:
    scripts/check_exports.py <ours.dll> <reference.dll> [--names-only]

Exit code is the number of (missing + decoration-mismatch) discrepancies, so it
can gate CI / track progress across iterations.
"""
import sys
import re
import pefile


def exports(path):
    pe = pefile.PE(path, fast_load=True)
    pe.parse_data_directories(
        directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_EXPORT"]]
    )
    out = set()
    if hasattr(pe, "DIRECTORY_ENTRY_EXPORT"):
        for e in pe.DIRECTORY_ENTRY_EXPORT.symbols:
            if e.name:
                out.add(e.name.decode())
    return out


def norm(n):
    """Strip leading underscore and trailing @N so the same function compares
    equal regardless of stdcall decoration."""
    return re.sub(r"@\d+$", "", n.lstrip("_"))


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    names_only = "--names-only" in sys.argv
    if len(args) != 2:
        print(__doc__)
        return 2
    ours_path, ref_path = args
    ours, ref = exports(ours_path), exports(ref_path)
    on = {norm(x): x for x in ours}
    rn = {norm(x): x for x in ref}

    missing = sorted(k for k in rn if k not in on)
    deco = sorted(k for k in (set(rn) & set(on)) if rn[k] != on[k])
    extra = sorted(k for k in on if k not in rn)

    print(f"ours={len(ours)}  reference={len(ref)}")
    print(f"MISSING (in reference, absent from ours): {len(missing)}")
    if not names_only:
        for k in missing:
            print(f"    {rn[k]}")
    print(f"DECORATION MISMATCH (wrong @N or underscore): {len(deco)}")
    if not names_only:
        for k in deco:
            print(f"    reference={rn[k]:44} ours={on[k]}")
    print(f"EXTRA (in ours, not in reference): {len(extra)}")

    return len(missing) + len(deco)


if __name__ == "__main__":
    sys.exit(main())

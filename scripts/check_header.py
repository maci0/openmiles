#!/usr/bin/env python3
"""Check src/mss.h against the export table src/main.zig actually builds.

main.zig is the single source of truth for the mss32 export table: it lists
every symbol with the stdcall stack size (4 bytes per argument on x86) and the
MSS version range the symbol appears in. mss.h is the C declaration of a subset
of that table, so nothing stops the two from drifting apart -- a renamed return
type, a wrong argument count, or a declaration for a symbol a given
-Dmss-version build never exports all produce a header that compiles and then
corrupts the stack or fails to link.

This resolves the header's version guards once per supported version and, for
each resulting declaration, reports:

  UNDECLARED  the header exports a symbol no build provides
  RETURN      the declared return type disagrees with the implementation
  ARITY       the declared argument count does not match the export's stack size
  CONVENTION  the header's calling convention disagrees with the export's
  RANGE       the symbol is declared for a version range that does not export it
  NOTEXPORTED the symbol is never emitted, or is dropped from 8.0 on
  UNDEFINED   a macro is used in the header but never defined

Symbols the header does not declare are listed at the end as a coverage count.
The header is a documented core subset, so that part is informational.

Usage:
    scripts/check_header.py [--verbose]

Exit code 0 when the header and the export table agree for every version.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAIN_ZIG = ROOT / "src" / "main.zig"
MSS_H = ROOT / "src" / "mss.h"

# Every value -Dmss-version accepts, encoded as major*10+minor.
SUPPORTED_VERSIONS = [30, 40, 50, 60, 61, 65, 66, 70, 80, 90]

# The encoding of 8.0: the first release that drops the symbols in
# REMOVED_AT_80 and switches MSS_RIB_CALL to __cdecl.
V8_0 = 80

# One entry per open #if in resolve_header: PENDING until a branch matches,
# TAKEN while that branch is live, DONE once a branch has matched so the rest
# of the chain is skipped.
PENDING, TAKEN, DONE = 0, 1, 2

TARGET_RE = re.compile(
    r'\.name = "([A-Za-z0-9_]+)"'
    r"(?:.*?\.stack_size = (\d+))?"
    r"(?:.*?\.ver = (\d+))?"
    r"(?:.*?\.ver_max = (\d+))?"
    r"(?:.*?\.cdecl = true)?"
)

# Symbols the export loop in main.zig never emits, and name substrings it
# drops wholesale from 8.0 on. A declaration for either is a link error.
REMOVED_AT_80 = [
    "redbook",
    "quick",
    "sequence",
    "DLS",
    "midiOut",
    "XMIDI",
    "midi_driver",
    "register_beat",
    "register_trigger",
    "register_sequence",
    "register_timbre",
    "register_prefix",
    "register_ICA",
    "channel_notes",
    "lock_channel",
    "release_channel",
    "send_channel_voice",
    "send_sysex",
    "controller_value",
    "branch_index",
    "wave_synthesizer",
    "map_sequence",
    "true_sequence",
]

DECL_RE = re.compile(
    r"^\s*(\S+)\s+(MSS_CALLBACK|MSS_RIB_CALL|MSS_CDECL)\s+"
    r"([A-Za-z0-9_]+)\((.*)\);\s*$"
)


def parse_exports(text):
    """Return {name: [(arity, ver, ver_max, cdecl), ...]} from main.zig.

    A name can appear more than once (AIL_init_sample changes arity across
    versions, RIB_* changes calling convention at 8.0), so every entry is kept
    and matching is done against the range the version falls into. `symbol` is
    the implementing function when the export aliases another one.
    """
    exports = {}
    for line in text.splitlines():
        if ".name =" not in line:
            continue
        m = re.search(r'\.name = "([A-Za-z0-9_]+)"', line)
        if not m:
            continue
        name = m.group(1)
        stack = re.search(r"\.stack_size = (\d+)", line)
        if not stack:
            continue
        ver = re.search(r"\.ver = (\d+)", line)
        ver_max = re.search(r"\.ver_max = (\d+)", line)
        symbol = re.search(r'\.symbol = "([A-Za-z0-9_]+)"', line)
        exports.setdefault(name, []).append(
            (
                int(stack.group(1)) // 4,
                int(ver.group(1)) if ver else 30,
                int(ver_max.group(1)) if ver_max else 999,
                ".cdecl = true" in line,
                symbol.group(1) if symbol else name,
            )
        )
    return exports


def eval_guard(expr, version):
    """Evaluate one MSS_AT_LEAST/MSS_BEFORE guard for `version`."""
    expr = expr.strip()
    m = re.fullmatch(r"MSS_AT_LEAST\((\d+)\)", expr)
    if m:
        return version >= int(m.group(1))
    m = re.fullmatch(r"MSS_BEFORE\((\d+)\)", expr)
    if m:
        return version < int(m.group(1))
    m = re.fullmatch(r"MSS_AT_LEAST\((\d+)\)\s*&&\s*MSS_BEFORE\((\d+)\)", expr)
    if m:
        return int(m.group(1)) <= version < int(m.group(2))
    # Any other conditional is not one of the version guards (e.g. _WIN32);
    # include the guarded declarations so their declarations are still checked.
    return True


# One branch per preprocessor directive, mirroring what cpp does; splitting it
# would put the #if/#elif/#else/#endif chain apart from the parse it guards.
def resolve_header(text, version):  # noqa: PLR0912
    """Return the declarations mss.h makes when OPENMILES_MSS_VERSION is `version`."""
    decls = []
    stack = []
    for raw in text.splitlines():
        line = raw.strip()
        m = re.match(r"#if\s+(.*)$", line)
        if m:
            outer_live = all(s != DONE for s in stack)
            stack.append(TAKEN if (outer_live and eval_guard(m.group(1), version)) else PENDING)
            continue
        if re.match(r"#elif\s+", line):
            if stack:
                if stack[-1] == PENDING and eval_guard(re.sub(r"^#elif\s+", "", line), version):
                    stack[-1] = TAKEN
                elif stack[-1] == TAKEN:
                    stack[-1] = DONE
            continue
        if line == "#else":
            if stack and stack[-1] == PENDING:
                stack[-1] = TAKEN
            elif stack:
                stack[-1] = DONE
            continue
        if line == "#endif":
            if stack:
                stack.pop()
            continue
        if any(s != TAKEN for s in stack):
            continue
        d = DECL_RE.match(raw)
        if d:
            decls.append((d.group(1), d.group(2), d.group(3), d.group(4)))
    return decls


def arg_count(params):
    params = params.strip()
    if params in ("", "void"):
        return 0
    depth = 0
    n = 1
    for ch in params:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            n += 1
    return n


def parse_never_export(text):
    m = re.search(r"const never_export = \[_\]\[\]const u8\{(.*?)\};", text, re.DOTALL)
    if not m:
        return set()
    return set(re.findall(r'"([A-Za-z0-9_]+)"', m.group(1)))


def emitted(exports, never_export, name, version):
    """True when main.zig's export loop emits `name` for `version`."""
    if name in never_export:
        return False
    if version >= V8_0 and any(tok in name for tok in REMOVED_AT_80):
        return False
    return any(v[1] <= version <= v[2] for v in exports.get(name, ()))


def zig_returns():
    """Return {name: {return-class, ...}} for the winapi exports in src/api.

    The return class is what a C caller can actually observe: a function that
    returns char* but is declared void hands the caller a register it has no
    name for, and one that returns a signed -1 failure but is declared U32
    turns the failure into 4294967295. Pointer-vs-scalar is the split that
    matters; the specific pointer typedef does not.
    """
    rets = {}
    for src in sorted((ROOT / "src" / "api").glob("*.zig")):
        for m in re.finditer(
            r"^pub fn ([A-Za-z0-9_]+)\(.*?callconv\(\.winapi\)\s+(.+?)\s*\{",
            src.read_text(),
            re.MULTILINE,
        ):
            ret = m.group(2).strip()
            if ret == "void":
                cls = "void"
            elif ret == "i32":
                cls = "signed"
            elif ret == "u32":
                cls = "unsigned"
            else:
                cls = "pointer"
            rets.setdefault(m.group(1), set()).add(cls)
    return rets


def c_return_class(ret):
    return {
        "void": "void",
        "S32": "signed",
        "U32": "unsigned",
        "F32": "float",
    }.get(ret, "pointer")


def undefined_macros(text):
    """Macros the header uses in a declaration but never #defines.

    A declaration guarded by, or spelled with, a macro that does not expand
    still parses here, so the only way to catch it is to notice the name never
    got a definition. On the C side it shows up as a syntax error, or worse, as
    a calling convention silently expanding to nothing.
    """
    defined = set(re.findall(r"^#\s*define\s+([A-Za-z_][A-Za-z0-9_]*)", text, re.MULTILINE))
    used = set(re.findall(r"\bMSS_[A-Z][A-Z0-9_]*\b", text))
    return sorted(used - defined)


def decl_problems(version, decl, exports, never_export, rets):
    """Return the problems one mss.h declaration has for `version`.

    `decl` is the (return, convention, name, params) tuple resolve_header
    produces. The checks are reported in the order the docstring lists them and
    the first failure ends the declaration, so a name that no build provides is
    reported once rather than five times.
    """
    ret, conv, name, params = decl
    if name in never_export:
        return [
            (
                f"v{version} NOTEXPORTED {name} is declared but main.zig lists it in "
                "never_export, so no build provides it"
            )
        ]
    if version >= V8_0 and any(tok in name for tok in REMOVED_AT_80):
        return [
            (f"v{version} NOTEXPORTED {name} is declared but main.zig drops '{name}' from 8.0 on")
        ]
    variants = exports.get(name)
    if not variants:
        return [f"v{version} UNDECLARED  {name} is not in the export table"]
    live = [v for v in variants if v[1] <= version <= v[2]]
    if not live:
        return [f"v{version} RANGE       {name} is declared but no v{version} export provides it"]

    problems = []
    arities = {v[0] for v in live}
    if arg_count(params) not in arities:
        problems.append(
            f"v{version} ARITY       {name} takes {arg_count(params)} args in the header, "
            f"export expects {'/'.join(str(a) for a in sorted(arities))}"
        )
    impl = set()
    for v in live:
        impl |= rets.get(v[4], set())
    want = c_return_class(ret)
    if impl and want not in impl:
        problems.append(
            f"v{version} RETURN      {name} is declared '{ret}' but the implementation "
            f"returns {'/'.join(sorted(impl))}"
        )
    want_cdecl = any(v[3] for v in live)
    # MSS_RIB_CALL is itself version-conditional in the header, so resolve it
    # the same way the C preprocessor would.
    has_cdecl = version < V8_0 if conv == "MSS_RIB_CALL" else conv == "MSS_CDECL"
    if want_cdecl and not has_cdecl:
        problems.append(
            f"v{version} CONVENTION  {name} is exported __cdecl but the header declares it stdcall"
        )
    if not want_cdecl and has_cdecl:
        problems.append(
            f"v{version} CONVENTION  {name} is exported __stdcall but the header "
            "declares it __cdecl"
        )
    return problems


def main():
    verbose = "--verbose" in sys.argv[1:]
    main_zig = MAIN_ZIG.read_text()
    exports = parse_exports(main_zig)
    never_export = parse_never_export(main_zig)
    rets = zig_returns()
    header = MSS_H.read_text()

    problems = []
    declared_by_version = {}

    problems += [
        f"UNDEFINED   macro {macro} is used but never #defined in mss.h"
        for macro in undefined_macros(header)
    ]

    for version in SUPPORTED_VERSIONS:
        decls = resolve_header(header, version)
        declared_by_version[version] = {d[2] for d in decls}
        for decl in decls:
            problems += decl_problems(version, decl, exports, never_export, rets)

    for p in problems:
        print(p)

    for version in SUPPORTED_VERSIONS:
        provided = {name for name in exports if emitted(exports, never_export, name, version)}
        covered = len(provided & declared_by_version[version])
        print(
            f"v{version}: {covered}/{len(provided)} exported symbols declared in mss.h"
            + (f" ({len(provided) - covered} undeclared)" if verbose else "")
        )

    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())

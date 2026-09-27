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

  UNDECLARED  the header declares a symbol the export table never provides
  RETURN      the declared return type disagrees with the implementation
  ARITY       the declared argument count does not match the export's stack size
  CONVENTION  the header's calling convention disagrees with the export's
  RANGE       the symbol is declared for a version range that does not export it
  NOTEXPORTED the symbol is never emitted, or is dropped from 8.0 on
  UNDEFINED   a macro is used in the header but never defined
  LAYOUT      a shared struct's field order disagrees with the implementation
  COMPILE     the header, with that version's guards resolved, is not valid C99

Symbols the header does not declare are listed at the end as a coverage count.
The header is a documented core subset, so that part is informational.
"""

import argparse
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAIN_ZIG = ROOT / "src" / "main.zig"
MSS_H = ROOT / "src" / "mss.h"
ROOT_ZIG = ROOT / "src" / "root.zig"

# Every value -Dmss-version accepts, encoded as major*10+minor. The list
# mss.h validates OPENMILES_MSS_VERSION against, so a version added to one and
# not the other is caught by compile_problems rather than by a caller.
SUPPORTED_VERSIONS = [30, 40, 50, 60, 61, 65, 66, 70, 80, 90]

# Values a consumer can plausibly write that name no build: a minor release
# that does not exist, a version past the newest, an uninitialized define
# reading as 0. Each must fail to compile, not resolve a declaration set.
UNSUPPORTED_VERSIONS = [0, 45, 62, 91, 100]

# The encoding of 8.0: the first release that drops the symbols in
# REMOVED_AT_80 and switches MSS_RIB_CALL to __cdecl.
V8_0 = 80

# The encoding of 9.0: the release that renumbered the preference table, so the
# two layouts mss.h spells are the ones either side of it.
V9_CUTOFF = 90

# One entry per open #if in resolve_header: PENDING until a branch matches,
# TAKEN while that branch is live, DONE once a branch has matched so the rest
# of the chain is skipped.
PENDING, TAKEN, DONE = 0, 1, 2

# Name substrings the export loop in main.zig drops wholesale from 8.0 on. A
# declaration for one is a link error. (The names it never emits at all are
# main.zig's `never_export`, read by parse_never_export below.)
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
# PLR0912: one branch per preprocessor directive, because that is the shape
# cpp gives the file. Anything smaller has to reconstruct the #if/#elif/#else
# nesting to stay correct, which is the bug the branch count is protecting.
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


def slot_count(params):
    """Stack slots `params` occupies on the x86 stdcall ABI.

    An export's stack size is measured in four-byte slots, and one argument is
    one slot -- unless it is a 64-bit value, which is passed as two adjacent
    slots. The v8/v9 event API passes queue IDs and instance filters by value
    that way, so counting the parameters alone would demand a declaration that
    splits each U64 into a `lo, hi` pair the DLL never asked for.
    """
    params = params.strip()
    if params in ("", "void"):
        return 0
    return sum(slot_width(arg) // 4 for arg in split_args(params))


def slot_width(arg):
    """Bytes one top-level parameter occupies: 8 for a U64, 4 otherwise."""
    declared_type = arg.strip().split(" ")[0].strip().rstrip("[]").lstrip("*")
    return 8 if declared_type == "U64" else 4


def split_args(params):
    """The top-level parameters of a declaration, commas inside ()/[]/{} ignored."""
    args = []
    depth = 0
    current = ""
    for ch in params:
        if ch in "([":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            args.append(current)
            current = ""
        else:
            current += ch
    args.append(current)
    return args


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
            src.read_text(encoding="utf-8"),
            re.MULTILINE,
        ):
            ret = m.group(2).strip()
            if ret == "void":
                cls = "void"
            elif ret == "i32":
                cls = "signed"
            elif ret == "u32":
                cls = "unsigned"
            elif ret == "f32":
                # A float return is its own class: the level, cutoff and
                # distance getters hand back an F32, and without this every one
                # of them fell into "pointer" and made a correct F32
                # declaration look like a mismatch.
                cls = "float"
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
    if slot_count(params) not in arities:
        problems.append(
            f"v{version} ARITY       {name} takes {slot_count(params)} stack slots in the header, "
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


def zig_struct_fields(text, name):
    """Return {cutoff: [field, ...]} for the version-branched Zig extern struct `name`.

    root.zig spells the two MSS layouts as
    `pub const X = if (mss_version >= 80) extern struct { ... } else extern struct { ... };`
    so the branch condition and the fields of each side are both recoverable,
    and the field order is what the ABI is made of. The key is the version from
    which that branch applies, so a caller can pick the layout a build uses.
    """
    branch = r" = if \(mss_version >= (\d+)\) extern struct \{(.*?)\}"
    pattern = r"pub const " + re.escape(name) + branch + r"\s*else extern struct \{(.*?)\};"
    m = re.search(pattern, text, re.DOTALL)
    if not m:
        return None
    cutoff, modern, legacy = int(m.group(1)), m.group(2), m.group(3)
    return {
        cutoff: re.findall(r"^\s*(\w+):", modern, re.MULTILINE),
        cutoff - 1: re.findall(r"^\s*(\w+):", legacy, re.MULTILINE),
    }


def c_struct_fields(text, tag):
    """Return the field names of the C struct typedef'd on `_tag`."""
    m = re.search(r"typedef struct " + re.escape(tag) + r" \{(.*?)\}", text, re.DOTALL)
    if not m:
        return None
    # Handles `S32 format;` and `void const* data_ptr;` alike: the qualifier and
    # the pointer star sit between the type and the name.
    return re.findall(
        r"^\s*[A-Za-z_][A-Za-z0-9_]*(?:\s+const)?\s*\*?\s*\*?([A-Za-z_]\w*)\s*;",
        m.group(1),
        re.MULTILINE,
    )


def live_header_lines(text, version):
    """The header's lines with every MSS_AT_LEAST/MSS_BEFORE guard resolved.

    Same #if/#elif/#else/#endif walk resolve_header does, but keeping the lines
    instead of only the declarations, so a struct typedef can be located in the
    branch that is actually compiled for `version`.
    """
    lines = []
    stack = []
    for raw in text.splitlines():
        line = raw.strip()
        directive = re.match(r"#(if|elif)\s+(.*)$", line)
        if directive:
            outer_live = all(s != DONE for s in stack)
            live = outer_live and eval_guard(directive.group(2), version)
            stack.append(TAKEN if live else PENDING)
            continue
        if re.match(r"#elif\s+", line):
            if stack:
                if stack[-1] == PENDING and eval_guard(re.sub(r"^#elif\s+", "", line), version):
                    stack[-1] = TAKEN
                elif stack[-1] == TAKEN:
                    stack[-1] = DONE
            continue
        if line == "#else":
            if stack:
                stack[-1] = PENDING if stack[-1] == TAKEN else TAKEN
            continue
        if line == "#endif":
            if stack:
                stack.pop()
            continue
        if all(s == TAKEN for s in stack):
            lines.append(raw)
    return lines


def layout_problems(header):
    """Field-order agreement between AILSOUNDINFO in root.zig and in mss.h.

    AILSOUNDINFO crosses the boundary by pointer (AIL_set_sample_info,
    AIL_compress_ADPCM, AIL_decompress_ADPCM), so the DLL reads the caller's
    struct by offset. A field the header omits or places differently is a
    misread at runtime with no link-time or compile-time signal anywhere else,
    and the v8/v9 layout really does differ from the v3-v7 one.
    """
    zig = zig_struct_fields(ROOT_ZIG.read_text(encoding="utf-8"), "AILSOUNDINFO")
    if zig is None:
        return ["LAYOUT    the version-branched AILSOUNDINFO struct was not found in src/root.zig"]
    cutoff = max(k for k in zig)

    problems = []
    for version in SUPPORTED_VERSIONS:
        branches = c_struct_fields("\n".join(live_header_lines(header, version)), "_AILSOUNDINFO")
        if not branches:
            problems.append(f"v{version} LAYOUT     the _AILSOUNDINFO typedef is not declared")
            continue
        want = zig[cutoff] if version >= cutoff else zig[cutoff - 1]
        if want != branches:
            problems.append(
                f"v{version} LAYOUT     AILSOUNDINFO fields {branches} do not match "
                f"the implementation's {want}"
            )
    return problems


def zig_preference_slots(text):
    """The preference slot numbers root.zig names, {name: number}.

    Two eras, two spellings: the 3.x..8.x table is the `Pref` enum, and the 9.x
    one is seeded inline (`p[3] = 64; // DIG_MIXER_CHANNELS`), because 9.0
    renumbered the table and the seeds are what the disassembly pinned. A name
    the table does not carry has no number, which is the same state the header
    is checked against.
    """
    enum = re.search(r"pub const Pref = enum\(u32\) \{(.*?)\};", text, re.DOTALL)
    if enum is None:
        return None
    slots = {
        name: int(num)
        for name, num in re.findall(r"^\s*(\w+) = (\d+),", enum.group(1), re.MULTILINE)
    }
    seeded = re.findall(r"^\s*p\[(\d+)\] = -?\d+;\s*//\s*(\w+)", text, re.MULTILINE)
    if not slots or not seeded:
        return None
    return slots, V9_CUTOFF, {name: int(num) for num, name in seeded}


def c_preference_slots(lines):
    """The preference names a preprocessed header defines, {name: number}.

    Read from between the header's preference-slot markers rather than from the
    whole header: every other #define in it (SMP_*, SEEK_*, DIG_F_*) is a
    different constant space and would read as a slot this build does not name.
    """
    block = "\n".join(lines)
    m = re.search(
        r"/\* BEGIN preference slots.*?\*/(.*?)/\* END preference slots",
        block,
        re.DOTALL,
    )
    if not m:
        return {}
    defines = re.findall(r"^#define\s+([A-Z][A-Z0-9_]+)\s+(\d+)\s*$", m.group(1), re.MULTILINE)
    return {name: int(value) for name, value in defines}


def preference_problems(header, root_zig_text):
    """Agreement between mss.h's preference numbers and the table root.zig reads.

    AIL_get_preference / AIL_set_preference take a bare number, so the names the
    header spells are the only way a caller reaches a slot, and MSS 9.0 gave
    every name a different number than 8.0 did. A name whose number drifts from
    the engine's is a setting applied to a neighbour of the one asked for, and
    the call still returns a plausible value.
    """
    parsed = zig_preference_slots(root_zig_text)
    if parsed is None:
        return ["PREF       the preference table in src/root.zig was not found"]
    legacy, v9_cutoff, modern = parsed

    problems = []
    for version in SUPPORTED_VERSIONS:
        want = modern if version >= v9_cutoff else legacy
        declared = c_preference_slots(live_header_lines(header, version))
        if not declared:
            problems.append(f"v{version} PREF       no preference names are declared in mss.h")
            continue
        for name, number in sorted(declared.items()):
            if name not in want:
                problems.append(
                    f"v{version} PREF       {name} is not a preference slot in src/root.zig"
                )
            elif want[name] != number:
                problems.append(
                    f"v{version} PREF       {name} is {number} in mss.h "
                    f"and {want[name]} in src/root.zig"
                )
        problems.extend(
            f"v{version} PREF       {name} is a slot in src/root.zig and unnamed in mss.h"
            for name in sorted(set(want) - set(declared))
        )
    return problems


def compile_problems():
    """Compile mss.h once per version, the way a consumer's compiler does.

    Everything else in this script reads the header as text, so a declaration
    that parses but does not compile -- a macro that expands to nothing, a
    typedef used before it is declared, a stray comma -- passes every check
    above and fails only in the build of the game that includes the header.
    The version guards are ten different preprocessed headers, so all ten are
    compiled: `zig cc` is already the toolchain this project requires, and
    compiling to an object file needs no DLL to link against.

    The same compile runs the other way for values no -Dmss-version build
    produces. Every guard in the header compares the version with >= or <, so
    an unsupported one selects a declaration set belonging to no release and
    reaches the caller as a link error (or, worse, a struct layout the header
    misdescribes). mss.h rejects those with #error, and SUPPORTED_VERSIONS is
    the list it names, so a version added to one and not the other fails here.
    """
    problems = []
    # `make check-toolchain` owns the version; this only needs the binary, and
    # naming it when it is missing beats a FileNotFoundError once per version.
    zig = shutil.which("zig")
    if zig is None:
        print(
            "error: zig not found on PATH; `make check-toolchain` names the version",
            file=sys.stderr,
        )
        # 1, not 2: the invocation was fine, the check could not run. Every
        # gate reserves 2 for a bad argument.
        sys.exit(1)
    for version in SUPPORTED_VERSIONS:
        with tempfile.TemporaryDirectory() as tmp:
            tu = Path(tmp) / "header_check.c"
            tu.write_text(
                f"#define OPENMILES_MSS_VERSION {version}\n"
                f'#include "{MSS_H}"\n'
                "int main(void) { return 0; }\n",
                encoding="utf-8",
            )
            proc = compile_header(zig, tu, tmp)
        if proc.returncode != 0:
            problems.append(
                f"v{version} COMPILE    mss.h does not compile as C99: "
                + " ".join(proc.stderr.split())[:400]
            )
    for version in UNSUPPORTED_VERSIONS:
        with tempfile.TemporaryDirectory() as tmp:
            tu = Path(tmp) / "header_check.c"
            tu.write_text(
                f"#define OPENMILES_MSS_VERSION {version}\n"
                f'#include "{MSS_H}"\n'
                "int main(void) { return 0; }\n",
                encoding="utf-8",
            )
            proc = compile_header(zig, tu, tmp)
        if proc.returncode == 0:
            problems.append(
                f"v{version} COMPILE    mss.h accepts OPENMILES_MSS_VERSION="
                f"{version}, which names no -Dmss-version build; the guards "
                "pick a declaration set belonging to no release instead of "
                "rejecting it"
            )
    return problems


# S603: a fixed argv list with no shell, built here rather than from input,
# running the zig resolved by the caller. The only path handed to it is the
# temp file compile_problems just wrote; nothing from the repository reaches
# argv.
#
# The warning set is the one c_flags carries in build.zig, so a construct the
# build would reject fails here too. A copy, not a source of truth: build.zig
# owns the list, and scripts/check_toolchain_pins.py asserts the two agree.
def compile_header(zig, tu, out_dir):
    return subprocess.run(  # noqa: S603
        [
            zig,
            "cc",
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
            str(tu),
            "-o",
            str(Path(out_dir) / "header_check.o"),
        ],
        capture_output=True,
        # The compiler's output is UTF-8 whatever the console code page is; a
        # Windows run on a legacy code page would otherwise fail to decode it.
        encoding="utf-8",
        errors="replace",
        check=False,
    )


def main():
    parser = argparse.ArgumentParser(
        prog="check_header.py",
        # The docstring is laid out as prose and a column-aligned list of the
        # finding kinds; the default formatter reflows both into one
        # paragraph, losing the list.
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__,
        epilog="Exit status: 0 header and export table agree, 1 they disagree, 2 bad invocation.",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="report the undeclared-symbol count per version too",
    )
    args = parser.parse_args()
    verbose = args.verbose

    main_zig = MAIN_ZIG.read_text(encoding="utf-8")
    exports = parse_exports(main_zig)
    never_export = parse_never_export(main_zig)
    rets = zig_returns()
    header = MSS_H.read_text(encoding="utf-8")

    problems = []
    declared_by_version = {}

    problems += layout_problems(header)

    problems += preference_problems(header, ROOT_ZIG.read_text(encoding="utf-8"))

    problems += [
        f"UNDEFINED   macro {macro} is used but never #defined in mss.h"
        for macro in undefined_macros(header)
    ]

    for version in SUPPORTED_VERSIONS:
        decls = resolve_header(header, version)
        declared_by_version[version] = {d[2] for d in decls}
        for decl in decls:
            problems += decl_problems(version, decl, exports, never_export, rets)

    problems += compile_problems()

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

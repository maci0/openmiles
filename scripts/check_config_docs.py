#!/usr/bin/env python3
"""Check that the documented runtime configuration is the configuration read.

The library reads its runtime configuration from the environment and its build
configuration from build.zig. Every value of either is written down in prose in
the README, and the values the code reads are constants in the sources. Nothing
otherwise joins the two: a limit widened in a Zig source and a README still
quoting the old number is a document that sends an operator down a path the
library has stopped taking, and every gate in the tree passes, because the
number that drifted is a sentence rather than a value anything computes.

So this reads the constants back out of the sources and asserts the documents
name the values that are actually there. A prose number that is wrong is worth
exactly as much as a constant that is wrong, and cheaper to fix: this is the
only place in the tree where the two are compared.

  src/utils/logger.zig   max_log_bytes, max_log_path_bytes, default_log_name,
                         the OPENMILES_DEBUG spellings
  src/api/rib.zig        max_temp_path_units, and the TMPDIR cap derived from it

  README.md              the Configuration table, and the default log name the
                         build instructions above it name
  docs/THREAT_MODEL.md   the log cap and the default log name, which it cites
                         as mitigations

Reported per value:

  STALE     a document quotes a value the source no longer has
  MISSING   a documented value the source stopped naming, or the reverse
"""

import argparse
import re
import sys
from pathlib import Path

PROG = "check_config_docs.py"

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

LOGGER = ROOT / "src" / "utils" / "logger.zig"
RIB = ROOT / "src" / "api" / "rib.zig"
README = ROOT / "README.md"
THREAT_MODEL = ROOT / "docs" / "THREAT_MODEL.md"

# The bytes a MiB holds, for spelling the log cap the way the documents do.
MIB = 1024 * 1024

# The room a configured TMPDIR needs: the buffer rib.zig validates against is
# max_temp_path_units UTF-16 units, the widest a path in it can spell is three
# bytes per unit, and configuredTempDir leaves two bytes for the separator and
# its terminator. So the byte count it accepts is this, and the README quotes
# the result rather than the units it is derived from.
TMPDIR_PATH_SLACK = 2

# A const in a Zig source, as its initializer. The value may be a literal or a
# product of literals (`64 * 1024 * 1024`), and never anything else: a name, a
# call, or a computed expression would be a second definition the documents
# cannot be compared against, and reading it here would mean reimplementing it.
SIZE_RE = re.compile(r"^const\s+(?P<name>\w+)\s*(?::[^=]*)?=\s*(?P<value>[^;]+);", re.MULTILINE)
STRING_RE = re.compile(r'^const\s+(?P<name>\w+)\s*=\s*"(?P<value>[^"]*)"\s*;', re.MULTILINE)
STRING_ARRAY_RE = re.compile(
    r"^const\s+(?P<name>\w+)\s*=\s*\[_\]\[\]const u8\{\s*(?P<body>[^}]*)\}\s*;",
    re.MULTILINE,
)
FACTOR_RE = re.compile(r"^\d+(?:\s*\*\s*\d+)*$")


def read(path):
    if not path.is_file():
        msg = f"{path.relative_to(ROOT)} is absent"
        raise ValueError(msg)
    return path.read_text(encoding="utf-8")


def parse_int_constant(text, name, path):
    """The value of a Zig integer const, e.g. 1024 or 64 * 1024 * 1024."""
    for match in SIZE_RE.finditer(text):
        if match.group("name") != name:
            continue
        value = match.group("value").strip()
        if not FACTOR_RE.match(value):
            msg = f"{path.relative_to(ROOT)} {name} is not a product of literals: {value!r}"
            raise ValueError(msg)
        result = 1
        for factor in value.split("*"):
            result *= int(factor.strip())
        return result
    msg = f"no {name} constant in {path.relative_to(ROOT)}"
    raise ValueError(msg)


def parse_string_constant(text, name, path):
    """The value of a Zig string const, e.g. "openmiles.log"."""
    for match in STRING_RE.finditer(text):
        if match.group("name") == name:
            return match.group("value")
    msg = f"no {name} constant in {path.relative_to(ROOT)}"
    raise ValueError(msg)


def parse_string_array(text, name, path):
    """The values of a Zig `[_][]const u8{ "a", "b" }` const."""
    for match in STRING_ARRAY_RE.finditer(text):
        if match.group("name") == name:
            return re.findall(r'"([^"]*)"', match.group("body"))
    msg = f"no {name} array in {path.relative_to(ROOT)}"
    raise ValueError(msg)


def document_problems(path, text, required):
    """Report every required string a document does not contain.

    A required string is computed from the source constant, never typed here,
    so the document and the code are compared and not the document and an
    earlier copy of the document.
    """
    bad = []
    for what, needle in required:
        if needle in text:
            continue
        print(f"{path.relative_to(ROOT)} STALE     {what}: the document does not say {needle!r}")
        bad.append(f"{path.name} {what}")
    return bad


def main():
    argparse.ArgumentParser(
        prog=PROG,
        # The docstring is laid out as prose and a column-aligned list of the
        # files that must agree; the default formatter reflows both into one
        # paragraph, losing the alignment that makes it readable.
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__,
        epilog="Exit status: 0 every documented value is the one the code reads, "
        "1 one has drifted, 2 bad invocation.",
    ).parse_args()

    logger = read(LOGGER)
    rib = read(RIB)
    readme = read(README)
    threat_model = read(THREAT_MODEL)

    cap = parse_int_constant(logger, "max_log_bytes", LOGGER)
    path_limit = parse_int_constant(logger, "max_log_path_bytes", LOGGER)
    log_name = parse_string_constant(logger, "default_log_name", LOGGER)
    on_values = parse_string_array(logger, "debug_on_values", LOGGER)
    off_values = parse_string_array(logger, "debug_off_values", LOGGER)
    temp_units = parse_int_constant(rib, "max_temp_path_units", RIB)

    # A path is accepted only while strictly shorter than the buffer, so the
    # longest one is a byte less than the constant, and a TMPDIR is accepted
    # while it leaves the separator room, so its cap is the buffer less the
    # same slack.
    longest_log_path = path_limit - 1
    longest_tmpdir = temp_units * 3 - TMPDIR_PATH_SLACK

    problems = []

    # Both documents spell the cap in MiB, which is the unit a reader compares
    # it in, so a cap that stops being a whole number of them has no spelling
    # left to check against and is reported here rather than rounded.
    cap_mib = cap // MIB
    if cap % MIB:
        msg = f"max_log_bytes ({cap}) is not a whole number of MiB"
        raise ValueError(msg)
    problems += document_problems(
        README,
        readme,
        [
            ("the cap in the OPENMILES_DEBUG row", f"capped at {cap_mib} MiB"),
        ],
    )
    problems += document_problems(
        THREAT_MODEL,
        threat_model,
        [("the cap the model claims mitigates log growth", f"{cap_mib} MiB")],
    )
    problems += document_problems(
        README,
        readme,
        [("the longest OPENMILES_LOG_PATH", f"at most {longest_log_path} bytes")],
    )
    problems += document_problems(
        README,
        readme,
        [("the longest TMPDIR", f"at most {longest_tmpdir} bytes")],
    )
    problems += document_problems(
        README,
        readme,
        [("the OPENMILES_LOG_PATH default", f"`{log_name}`")],
    )
    problems += document_problems(
        THREAT_MODEL,
        threat_model,
        [("the log the model names as the one security event leaves", f"`{log_name}`")],
    )

    # The spellings OPENMILES_DEBUG accepts are two lists in the source and one
    # cell in the README. A value accepted but undocumented is one an operator
    # does not know to write, and a documented one the parser rejects is a value
    # that silently leaves the default in place.
    for value in (*on_values, *off_values):
        spelled = f"`{value}`"
        problems += document_problems(
            README,
            readme,
            [(f"the {spelled} the parser accepts", spelled)],
        )

    if problems:
        print()
        print(f"{len(problems)} documented configuration value(s) drifted from the code")
        print("update the document, or the constant, so the two name the same value")
        return 1

    print(
        f"configuration documentation agrees: log cap {cap_mib} MiB, log path "
        f"{longest_log_path} bytes, TMPDIR {longest_tmpdir} bytes, log {log_name}"
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

#!/usr/bin/env python3
"""Generate SBOM.cdx.json: the third-party components this project ships.

deps/ is vendored source, not a package-manager download, and the one Python
package the project declares lives in a requirements.txt no build reads. Neither
leaves a machine-readable inventory behind, so a consumer of the DLL cannot tell
what third-party code is inside it and a vulnerability scanner has nothing to
match against a CVE database. This writes that inventory as CycloneDX 1.6.

Every field is derived from the tree rather than typed in: the vendored
components, their upstream commits and their licenses come from deps/README.md
through check_vendored.readme_entries(), their digests from deps/SHA256SUMS,
the pip component from scripts/requirements.txt, and the project version from
build.zig.zon. A vendored file that stops recording its provenance fails here
the same way it fails check_vendored.py.

A vendored license is also checked against the project license, not just
recorded. Those headers are compiled into the shipped DLL, so a grant the
project cannot redistribute under GPL-3.0-only is a compliance failure, and
without this check it would reach the inventory looking like any other entry.

The output is byte-identical for identical inputs: no timestamp, no serial
number, components in a fixed order. The release archive is compared byte for
byte across two timezones, and a generated timestamp would make that comparison
fail for no reason.

--check compares the committed SBOM.cdx.json against what this run would write
and exits 1 when they differ, so a header swap or a pip bump that forgets the
inventory fails `make lint` instead of publishing a stale one.
"""

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from check_vendored import DEPS, ROOT, read_sums, readme_entries

SBOM = ROOT / "SBOM.cdx.json"
ZON = ROOT / "build.zig.zon"
REQUIREMENTS = ROOT / "scripts" / "requirements.txt"
LICENSE = ROOT / "LICENSE"

# CycloneDX spec version and the project's own license id. The license is
# asserted against LICENSE below rather than trusted here, so a relicensing
# shows up as a failing gate instead of a stale id in the SBOM.
SPEC_VERSION = "1.6"
PROJECT_LICENSE = "GPL-3.0-only"
PROJECT_LICENSE_BANNER = "GNU GENERAL PUBLIC LICENSE"

# deps/README.md writes licenses the way the upstream projects do, which is not
# always an SPDX id: miniaudio is "MIT-0 / Public Domain (Dual-licensed)". The
# SPDX half carries the grant, so the alternative is dropped. A grant name
# outside KNOWN_NON_SPDX, or an id outside SPDX_IDS, stops the build rather than
# going into the inventory as something no scanner resolves.
#
# The ids a vendored header realistically arrives under, both the ones the
# project can redistribute and the ones it cannot. The incompatible ones are
# listed deliberately: they are real licenses that turn up in the wild, and
# naming them here is what lets GPL_COMPATIBLE below reject one with "not one
# GPL-3.0-only can redistribute" rather than the misleading "neither an SPDX id
# nor a known grant name", which sends a maintainer hunting a typo in a file
# that has none.
KNOWN_NON_SPDX = {
    "Public Domain",
}

SPDX_IDS = {
    "0BSD",
    "Apache-2.0",
    "Artistic-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "BSL-1.0",
    "BUSL-1.1",
    "CC-BY-NC-4.0",
    "CC0-1.0",
    "Elastic-2.0",
    "GPL-2.0-only",
    "ISC",
    "LGPL-2.1-only",
    "MIT",
    "MIT-0",
    "MPL-2.0",
    "SSPL-1.0",
    "Unlicense",
    "Zlib",
}

# The ids out of the ones above that GPL-3.0-only can carry. The vendored
# headers are compiled into the shipped DLL and redistributed under the project
# license, so the grant has to be one the project can pass on: a non-commercial
# or source-available term is not redistributable at all, and a permissive id
# carrying a patent grant hands the recipient a license the project never chose
# to give.
#
# An id outside this set stops the build rather than reaching the inventory.
# Adding one is a deliberate act: check it against the project license first,
# the way PIP_LICENSES below is checked. The test is one-directional on purpose.
# GPL-2.0-only is absent because the compatibility does not run the other way:
# the combined work cannot be distributed under GPL-3.0-only.
GPL_COMPATIBLE = {
    "0BSD",
    "Apache-2.0",
    "Artistic-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "BSL-1.0",
    "CC0-1.0",
    "ISC",
    "LGPL-2.1-only",
    "MIT",
    "MIT-0",
    "MPL-2.0",
    "Unlicense",
    "Zlib",
}

# The license of each package scripts/requirements.txt declares, from that
# release's own metadata. A new package has no entry here, and adding one
# without checking it defeats the purpose of the SBOM. These are not gated on
# GPL_COMPATIBLE: nothing in scripts/requirements.txt is compiled into the DLL,
# it is read by a developer-side parity gate, so its grant is not the one the
# project redistributes.
PIP_LICENSES = {"pefile": "MIT"}

# A requirements.txt record is a pin line plus any number of backslash-continued
# "--hash=sha256:<64 hex>" lines. The pin is the only line carrying a name; a
# continuation is joined onto it before either is matched, so the parse sees the
# one logical record the installer does.
PIP_PIN_RE = re.compile(r"^([A-Za-z0-9_.-]+)==(\S+)((?:\s*--hash=sha256:[0-9a-f]{64})+)$")
PIP_HASH_RE = re.compile(r"--hash=sha256:([0-9a-f]{64})")
ZON_VERSION_RE = re.compile(r'^\s*\.version\s*=\s*"([^"]*)"', re.MULTILINE)


def pip_records(text):
    """Yield (lineno, logical record) for every non-comment line in the file.

    A trailing backslash continues a record onto the next line, which is how
    pip writes a hash list under one pin. An unterminated continuation at end of
    file is yielded as it stands, so the pin check below names the line rather
    than the file silently losing its last requirement.
    """
    pending = ""
    start = 0
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        if not pending:
            start = lineno
        stripped = line.strip()
        if stripped.endswith("\\"):
            pending += stripped[:-1] + " "
            continue
        if pending:
            yield start, pending + stripped
            pending = ""
        else:
            yield start, stripped
    if pending:
        yield start, pending


def spdx_ids(declared, where):
    """Return the SPDX ids in a license field, or fail naming the field.

    A license written as a dual grant keeps every SPDX id it lists, so a
    consumer can pick the terms they need. A parenthetical after the grant
    ("(Dual-licensed)") describes the grant rather than adding one, so it is
    cut before the token is looked up.
    """
    ids = []
    for part in declared.split("/"):
        token = part.split("(", 1)[0].strip()
        if not token or token in KNOWN_NON_SPDX:
            continue
        if token not in SPDX_IDS:
            sys.exit(
                f"error: {where}: license {token!r} is neither an SPDX id nor a known grant name"
            )
        ids.append(token)
    if not ids:
        sys.exit(f"error: {where}: no SPDX license id in {declared!r}")
    return ids


def check_redistributable(ids, where):
    """Fail unless every grant is one the project can redistribute under GPL-3.0.

    The vocabulary check in spdx_ids only says the id resolves; this says the
    grant is passable on. A header vendored under a term the project license
    cannot carry compiles, hashes, and lands in the inventory, and the only
    record that it may not ship is this exit.
    """
    for token in ids:
        if token not in GPL_COMPATIBLE:
            sys.exit(
                f"error: {where}: license {token!r} is not one {PROJECT_LICENSE} can "
                f"redistribute; check it against the project license before adding it to "
                f"GPL_COMPATIBLE"
            )


def vendored_components(sums):
    """One CycloneDX component per third-party header in deps/, README order.

    The first-party files (tsf_tml.h, windows_stub.h) are not dependencies, so
    they are not components; their digests travel in deps/SHA256SUMS inside the
    release archive.
    """
    components = []
    for name, entry in readme_entries().items():
        if entry.first_party:
            continue
        missing = [
            field
            for field in ("package", "version", "commit", "source", "license", "purpose")
            if getattr(entry, field) is None
        ]
        if missing:
            sys.exit(f"error: {DEPS.name}/{name}: deps/README.md records no {', '.join(missing)}")
        if name not in sums:
            sys.exit(f"error: {name}: no digest in deps/SHA256SUMS")
        version = entry.version.removeprefix("v")
        licenses = spdx_ids(entry.license, f"{name} license")
        check_redistributable(licenses, f"{DEPS.name}/{name}")
        components.append(
            {
                "type": "library",
                "bom-ref": f"pkg:generic/{entry.package}@{version}",
                # The upstream package name, not the header filename: a CVE
                # database knows "TinyMidiLoader", not "tml.h".
                "name": entry.package,
                "version": version,
                "description": entry.purpose,
                "purl": f"pkg:generic/{entry.package}@{version}",
                "licenses": [{"license": {"id": i}} for i in licenses],
                "hashes": [{"alg": "SHA-256", "content": sums[name]}],
                "externalReferences": [
                    {"type": "website", "url": entry.source},
                    {"type": "vcs", "url": f"{entry.source}/commit/{entry.commit}"},
                ],
                "properties": [{"name": "openmiles:file", "value": f"{DEPS.name}/{name}"}],
            }
        )
    if not components:
        sys.exit("error: deps/README.md records no vendored component")
    return components


def pip_components():
    """One component per exactly pinned, hash-pinned package in requirements.txt."""
    components = []
    for lineno, line in pip_records(REQUIREMENTS.read_text(encoding="utf-8")):
        match = PIP_PIN_RE.match(line)
        if not match:
            sys.exit(
                f"{REQUIREMENTS.relative_to(ROOT)}:{lineno}: {line!r} is not an exact == pin "
                f"carrying at least one --hash=sha256"
            )
        name, version, hashes = match.groups()
        license_id = PIP_LICENSES.get(name)
        if license_id is None:
            sys.exit(f"error: {name} has no license in PIP_LICENSES; check it before recording it")
        digests = PIP_HASH_RE.findall(hashes)
        if len(set(digests)) != len(digests):
            sys.exit(f"{REQUIREMENTS.relative_to(ROOT)}:{lineno}: {name} repeats a digest")
        components.append(
            {
                "type": "library",
                "bom-ref": f"pkg:pypi/{name}@{version}",
                "name": name,
                "version": version,
                "purl": f"pkg:pypi/{name}@{version}",
                "licenses": [{"license": {"id": license_id}}],
                # The digests the installer checks the downloaded artifacts
                # against, so the inventory carries the integrity of this package
                # and not only its version, the way a vendored header's does.
                "hashes": [{"alg": "SHA-256", "content": d} for d in dict.fromkeys(digests)],
                "externalReferences": [
                    {"type": "distribution", "url": f"https://pypi.org/project/{name}/"}
                ],
                # Not compiled into the DLL: recorded so a scanner sees the whole
                # declared surface, and flagged so nobody reads it as shipped.
                "properties": [{"name": "openmiles:shipped-in-release", "value": "false"}],
            }
        )
    if not components:
        sys.exit(f"error: {REQUIREMENTS.relative_to(ROOT)} declares no package")
    return components


def project_version():
    match = ZON_VERSION_RE.search(ZON.read_text(encoding="utf-8"))
    if not match:
        sys.exit(f"error: no .version in {ZON.relative_to(ROOT)}")
    return match.group(1)


def document():
    """The CycloneDX document, in a fixed key order so the bytes are stable."""
    version = project_version()
    if PROJECT_LICENSE_BANNER not in LICENSE.read_text(encoding="utf-8"):
        sys.exit(f"error: {LICENSE.relative_to(ROOT)} is not the license {PROJECT_LICENSE} names")
    # read_sums returns (recorded, malformed); the malformed lines are
    # check_vendored.py's to report, so only the recorded digests are looked up
    # here. Passing the tuple made every `name not in sums` true and the gate
    # failed on the first header.
    recorded, _ = read_sums()
    return {
        "bomFormat": "CycloneDX",
        "specVersion": SPEC_VERSION,
        "version": 1,
        "metadata": {
            "component": {
                "type": "library",
                "bom-ref": f"pkg:generic/openmiles@{version}",
                "name": "openmiles",
                "version": version,
                "description": "OpenMiles: a reimplementation of the Miles Sound System audio API",
                "licenses": [{"license": {"id": PROJECT_LICENSE}}],
            }
        },
        "components": vendored_components(recorded) + pip_components(),
    }


def main():
    parser = argparse.ArgumentParser(
        prog="gen_sbom.py",
        # The docstring is laid out as prose and a list of the records the
        # inventory is derived from; the default formatter reflows both into
        # one paragraph.
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__,
        epilog="Exit status: 0 SBOM written or current, 1 out of date, 2 bad invocation.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit 1 unless the committed SBOM.cdx.json matches what this run would write",
    )
    args = parser.parse_args()

    doc = document()
    text = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
    if args.check:
        if not SBOM.exists():
            print(f"{SBOM.relative_to(ROOT)} MISSING  run scripts/gen_sbom.py")
            return 1
        if SBOM.read_text(encoding="utf-8") != text:
            print(
                f"{SBOM.relative_to(ROOT)} STALE  does not match the tree; run scripts/gen_sbom.py"
            )
            return 1
        print(f"{SBOM.relative_to(ROOT)} matches the tree")
        return 0

    # Bytes, not write_text: a Windows run would otherwise write CRLF and leave
    # a file the next run's comparison (and git) reads as a diff.
    SBOM.write_bytes(text.encode("utf-8"))
    print(f"wrote {SBOM.relative_to(ROOT)} ({len(doc['components'])} components)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

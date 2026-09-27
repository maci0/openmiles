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

The output is byte-identical for identical inputs: no timestamp, no serial
number, components in a fixed order. The release archive is compared byte for
byte across two timezones, and a generated timestamp would make that comparison
fail for no reason.

--check compares the committed SBOM.cdx.json against what this run would write
and exits 1 when they differ, so a header swap or a pip bump that forgets the
inventory fails `make lint` instead of publishing a stale one.

Exit code 0 written or current, 1 out of date, 2 bad invocation.
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
KNOWN_NON_SPDX = {
    "Public Domain",
}

SPDX_IDS = {
    "0BSD",
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "ISC",
    "MIT",
    "MIT-0",
    "MPL-2.0",
    "Unlicense",
    "Zlib",
}

# The license of each package scripts/requirements.txt declares, from that
# release's own metadata. A new package has no entry here, and adding one
# without checking it defeats the purpose of the SBOM.
PIP_LICENSES = {"pefile": "MIT"}

# "pefile==2024.8.26" with an exact pin, or a range the file does not use.
PIP_PIN_RE = re.compile(r"^([A-Za-z0-9_.-]+)==(\S+)$")
ZON_VERSION_RE = re.compile(r'^\s*\.version\s*=\s*"([^"]*)"', re.MULTILINE)


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


def vendored_components(sums):
    """One CycloneDX component per third-party header in deps/, README order.

    The first-party files (tsf_tml.h, windows_stub.h) are not dependencies, so
    they are not components; their digests travel in DEPS-SHA256SUMS inside the
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
                "licenses": [
                    {"license": {"id": i}} for i in spdx_ids(entry.license, f"{name} license")
                ],
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
    """One component per exactly pinned package in scripts/requirements.txt."""
    components = []
    for lineno, raw in enumerate(REQUIREMENTS.read_text().splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        match = PIP_PIN_RE.match(line)
        if not match:
            sys.exit(f"{REQUIREMENTS.relative_to(ROOT)}:{lineno}: {line!r} is not an exact == pin")
        name, version = match.groups()
        license_id = PIP_LICENSES.get(name)
        if license_id is None:
            sys.exit(f"error: {name} has no license in PIP_LICENSES; check it before recording it")
        components.append(
            {
                "type": "library",
                "bom-ref": f"pkg:pypi/{name}@{version}",
                "name": name,
                "version": version,
                "purl": f"pkg:pypi/{name}@{version}",
                "licenses": [{"license": {"id": license_id}}],
                "externalReferences": [
                    {"type": "distribution", "url": f"https://pypi.org/project/{name}/"}
                ],
                # Not compiled into the DLL: recorded so a scanner sees the whole
                # declared surface, and flagged so nobody reads it as shipped.
                "properties": [{"name": "openmiles:shipped-in-release", "value": "false"}],
            }
        )
    return components


def project_version():
    match = ZON_VERSION_RE.search(ZON.read_text())
    if not match:
        sys.exit(f"error: no .version in {ZON.relative_to(ROOT)}")
    return match.group(1)


def document():
    """The CycloneDX document, in a fixed key order so the bytes are stable."""
    version = project_version()
    if PROJECT_LICENSE_BANNER not in LICENSE.read_text():
        sys.exit(f"error: {LICENSE.relative_to(ROOT)} is not the license {PROJECT_LICENSE} names")
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
        "components": vendored_components(read_sums()) + pip_components(),
    }


def render():
    return json.dumps(document(), indent=2, ensure_ascii=False) + "\n"


def main():
    parser = argparse.ArgumentParser(
        prog="gen_sbom.py",
        description=__doc__,
        epilog="Exit status: 0 SBOM written or current, 1 out of date, 2 bad invocation.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="exit 1 unless the committed SBOM.cdx.json matches what this run would write",
    )
    args = parser.parse_args()

    text = render()
    if args.check:
        if not SBOM.exists():
            print(f"{SBOM.relative_to(ROOT)} MISSING  run scripts/gen_sbom.py")
            return 1
        if SBOM.read_text() != text:
            print(
                f"{SBOM.relative_to(ROOT)} STALE  does not match the tree; run scripts/gen_sbom.py"
            )
            return 1
        print(f"{SBOM.relative_to(ROOT)} matches the tree")
        return 0

    SBOM.write_text(text)
    print(f"wrote {SBOM.relative_to(ROOT)} ({len(document()['components'])} components)")
    return 0


if __name__ == "__main__":
    sys.exit(main())

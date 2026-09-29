# OpenMiles Dependencies

OpenMiles minimizes its dependency footprint by utilizing single-file, header-only C libraries.

## miniaudio.h
- **Package:** miniaudio
- **Version:** v0.11.25
- **Source:** https://github.com/mackron/miniaudio
- **Commit:** `9634bedb5b5a2ca38c1ee7108a9358a4e233f14d` (tag `0.11.25`)
- **Purpose:** Cross-platform audio playback, mixing, and 3D spatialization.
- **License:** MIT-0 / Public Domain (Dual-licensed)

## tsf.h (TinySoundFont)
- **Package:** TinySoundFont
- **Version:** v0.9
- **Source:** https://github.com/schellingb/TinySoundFont
- **Commit:** `790a219810cb0fca5defa8cdbd88e2487e5efc7a`
- **Purpose:** SoundFont (SF2) software synthesis.
- **License:** MIT

## tml.h (TinyMidiLoader)
- **Package:** TinyMidiLoader
- **Version:** v0.7
- **Source:** https://github.com/schellingb/TinySoundFont
- **Commit:** `472abcff8be97ff23f8196412041624fc3e34ce4`
- **Purpose:** MIDI file parsing.
- **License:** Zlib

## tsf_tml.h, windows_stub.h
Both are first-party, not vendored: `tsf_tml.h` is the translation unit
`build.zig` runs `addTranslateC` on, `windows_stub.h` lets the C tests compile
on Linux. They are listed in SHA256SUMS so a stray edit to either is caught
along with the rest of the directory.

## Updating
To update a dependency, follow the checklist at the end of this file. Nothing
here is resolved by a package manager, so a swap is only reviewable if the
upstream commit it came from is recorded with the version.

Each vendored entry names the upstream **Package** as well as the file, because
a CVE database and a license scanner know `TinyMidiLoader`, not `tml.h`.

## SBOM
`scripts/gen_sbom.py` reads the entries above, `SHA256SUMS`, and the pins and
digests in `scripts/requirements.txt`, and writes `SBOM.cdx.json`: the
third-party surface of a release, in the format vulnerability scanners and
compliance audits read.
`make check-sbom` (part of `make lint`) regenerates it in memory and fails when
the committed file no longer matches the tree, so a header swap that skips
step 6 of the checklist below cannot ship a stale inventory. The file is
deterministic: no timestamp, no serial number, because the release archive is
compared byte for byte across timezones.

## Vendored file checksums
`SHA256SUMS` holds the SHA-256 of every file in this directory, and
`scripts/check_vendored.py` verifies them. `make lint` runs it, so CI rejects a
header swapped in without a matching digest, or a digest edited to match a
header that arrived from somewhere unexpected. The same script requires every
vendored entry above to name a 40-character upstream commit, since a digest
alone says which bytes shipped but not which release they came from, and it
requires the **Source** URL to be an `https` URL on an approved host (`SOURCE_HOSTS`
in the script). A commit id names a revision, not a repository, so a lookalike
host carrying the right bytes and a plausible commit string would otherwise pass
every other check here; both entries resolve to `github.com`, and moving an
upstream is a deliberate edit to that set.

`deps/` holds files, not a tree: `SHA256SUMS` records the files in this
directory, and the script fails on a subdirectory as well as on an unlisted
file. `build.zig` puts `deps/` on the include path for the translate-C step, so
a header below it would compile into the DLL with no digest, no upstream commit
and no SBOM entry. `--update` refuses one too, so the digests cannot be
rewritten into agreeing with a tree they do not describe.

It also reads the version out of each header's own bytes and compares it to the
**Version** field above. That field is what `gen_sbom.py` writes into
`SBOM.cdx.json`, and a vulnerability scanner matches advisories against it, so a
header upgraded with the entry left behind would put the superseded version in
the inventory and hide every advisory for the release that actually shipped.

The two TinySoundFont headers carry no version macro: their `v0.9` and `v0.7`
entries are the version banner on line 1 of each file, and the commits above are
the last upstream commits to touch them, each verified byte-for-byte against
the copy in this directory.

Update checklist:
1. Fetch by commit id, never by branch or tag, and record that id in the entry
   above next to the version. A branch name resolves to different bytes every
   week, so a header fetched from `master` cannot be traced back to what was
   reviewed.
2. Download only from the upstream URLs listed above; the script fails an entry
   whose **Source** is not one of the hosts in `SOURCE_HOSTS`.
3. Confirm the version against the header's own bytes, which
   `scripts/check_vendored.py` then compares to the **Version** field above:
   miniaudio carries `MA_VERSION_MAJOR/MINOR/REVISION`, but tsf.h and tml.h
   have no version macro at all, so theirs is the banner on line 1 and the
   commit id recorded in step 1.
4. Diff against the current vendored copy to spot unexpected changes.
5. Check the **License** field against the project license before anything
   else, because every other step passes on a header the project is not
   allowed to ship. The vendored headers are compiled into the DLL, so their
   grant travels inside a distribution made under GPL-3.0-only.
   `scripts/gen_sbom.py` holds the ids that license can carry in
   `GPL_COMPATIBLE` and rejects anything else, so a header arriving under a
   non-commercial or source-available term fails the gate with the license
   named. Adding an id to that set is a deliberate act, not a way to make a
   failing gate green.
6. Run `scripts/check_vendored.py --update` in the same commit as the header
   swap, and read the diff: a changed digest is a reviewed change, not a
   formality.
7. Run `scripts/gen_sbom.py` in that same commit, and read its diff too: the
   inventory a consumer reads has to change when the bytes behind it do.
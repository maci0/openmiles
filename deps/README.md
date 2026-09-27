# OpenMiles Dependencies

OpenMiles minimizes its dependency footprint by utilizing single-file, header-only C libraries.

## miniaudio.h
- **Version:** v0.11.25
- **Source:** https://github.com/mackron/miniaudio
- **Purpose:** Cross-platform audio playback, mixing, and 3D spatialization.
- **License:** MIT-0 / Public Domain (Dual-licensed)

## tsf.h (TinySoundFont)
- **Version:** v0.9
- **Source:** https://github.com/schellingb/TinySoundFont
- **Purpose:** SoundFont (SF2) software synthesis.
- **License:** MIT

## tml.h (TinyMidiLoader)
- **Version:** v0.7
- **Source:** https://github.com/schellingb/TinySoundFont
- **Purpose:** MIDI file parsing.
- **License:** Zlib

## tsf_tml.h, windows_stub.h
Both are first-party, not vendored: `tsf_tml.h` is the translation unit
`build.zig` runs `addTranslateC` on, `windows_stub.h` lets the C tests compile
on Linux. They are listed in SHA256SUMS so a stray edit to either is caught
along with the rest of the directory.

## Updating
To update these dependencies, download the latest raw `.h` files from their
upstream repositories and replace the files in this directory.

## Vendored file checksums
`SHA256SUMS` holds the SHA-256 of every file in this directory, and
`scripts/check_vendored.py` verifies them. `make lint` runs it, so CI rejects a
header swapped in without a matching digest, or a digest edited to match a
header that arrived from somewhere unexpected.

Update checklist:
1. Fetch by commit id, never by branch or tag, and record that id under the
   dependency above. A branch name resolves to different bytes every week, so
   a header fetched from `master` cannot be traced back to what was reviewed.
2. Download only from the upstream URLs listed above (miniaudio: the commit of
   the release; tsf.h/tml.h: master, which is ahead of their old version tags).
3. Confirm the version banner / `MA_VERSION_*`, `TSF_*`, `TML_*` macros.
4. Diff against the current vendored copy to spot unexpected changes.
5. Run `scripts/check_vendored.py --update` in the same commit as the header
   swap, and read the diff: a changed digest is a reviewed change, not a
   formality.
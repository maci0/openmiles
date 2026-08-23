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

## Updating
To update these dependencies, simply download the latest raw `.h` files from their respective upstream repositories and replace the files in this directory.

## Vendored file checksums
SHA-256 of the exact vendored copies. Re-check after every update; a mismatch
against what you downloaded means the file changed in transit or in place.

| File          | SHA-256                                                          |
| ------------- | ---------------------------------------------------------------- |
| miniaudio.h   | `ac7af4de748b7e26b777f37e01cee313a308a7296a3eb080e2906b320cc55c89` |
| tsf.h         | `70d55963c98f60ebb81518eaa1f25d46888d5180eb5f5289fd6b74ffc177d197` |
| tml.h         | `93257db259e0efb2ea2037d7157841bec8cb4a2d7986286e43c8090705326546` |

Update checklist:
1. Download only from the upstream URLs listed above (miniaudio: the release
   tag; tsf.h/tml.h: master, which is ahead of their old version tags).
2. Confirm the version banner / `MA_VERSION_*`, `TSF_*`, `TML_*` macros.
3. Diff against the current vendored copy to spot unexpected changes.
4. Refresh the checksums in this table in the same commit as the header swap.
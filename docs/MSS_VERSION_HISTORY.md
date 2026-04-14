# Miles Sound System (MSS) API Evolution & Version History

This document provides a comprehensive overview of the different versions of the Miles Sound System API, highlighting key additions and architectural changes.

## Version Overview Table

| Version | Era | Key Architectural Changes | Target Platforms |
|---------|-----|---------------------------|------------------|
| **1.x** | Early 90s | First "Audio Interface Library" (AIL). | DOS (Real Mode) |
| **2.x** | ~1992 | Protected Mode AIL. Introduced `DIG_` and `MDI_` prefixes. | DOS (Protected Mode) |
| **3.x** | Mid 90s | Transition from DOS to Windows. Split headers (`AIL.H`, `DIG.H`). First "Miles Sound System". | DOS, Win 3.1, Win 95 |
| **4.x** | Late 90s | Unified into `MSS.H`. Introduction of RIB (RAD Interface Broker). | Win 95/98 |
| **5.x** | ~1999 | DirectSound refinement. EAX support expanded. | Win 98/2000 |
| **6.x** | ~2002 | **Mainstream Standard.** Digital Filter system, ASI (Audio Stream Interface). | Win XP, PS2, Xbox |
| **7.x** | ~2006 | Console optimization. Header cleanup (removed system includes). | Xbox 360, PS3, Wii |
| **8.x** | ~2010 | **Modern Miles.** Event System, Soundbanks, Ogg Vorbis, Win64. | Win 7, iOS, Android |
| **9.x** | ~2013 | Miles Studio integration. High-level authoring focus. | PS4, Xbox One |

---

## 0. The AIL Era (v1.x - v2.x)
Before the "Miles Sound System" name, the library was known as the **Audio Interface Library (AIL)**. It was the industry standard for DOS games (e.g., *Doom*, *Warcraft*, *Dune II*).

- **Naming Convention:** Used `DIG_` for digital audio and `MDI_` for MIDI.
- **Drivers:** Used external `.DIG` and `.MDI` driver files for specific sound cards (Sound Blaster, Gravis Ultrasound, etc.).
- **Compatibility:** OpenMiles does not currently export `DIG_` or `MDI_` aliases. These could be added as PE export aliases if needed for older titles.

## 1. Legacy Era (v3.x - v5.x)
Focus was on low-level hardware abstraction (Sound Blaster, AdLib) and early Windows drivers (MME, DirectSound).

- **Core API:** `AIL_open_digital_driver`, `AIL_open_XMIDI_driver`.
- **Memory:** Strict use of `AIL_mem_alloc_lock` due to 16-bit segmented memory legacy.
- **Features:** 
  - Basic 2D sample playback.
  - XMIDI sequence management.
  - Red Book (CD-Audio) control.

## 2. Mainstream Era (v6.x) - *Current Project Target*
This version is the most common target for legacy game mods and wrappers (e.g., GTA III, Vice City, early CoD).

- **Filter System:** Introduced `AIL_open_filter` and `AIL_filter_attribute`. Allowed real-time DSP effects.
- **ASI (Audio Stream Interface):** A plugin system for compressed formats. `AIL_open_stream` started supporting MP3 and early Bink Audio via ASI providers.
- **RIB (RAD Interface Broker):** The backend for loading providers (`.flt`, `.asi`, `.m3d`).
- **3D Audio:** `AIL_set_3D_position` and early EAX support.

## 3. Console Transition Era (v7.x)
Improved performance for multi-core systems and handled console-specific audio hardware.

- **Header Cleanup:** `mss.h` stopped including `windows.h`. All Miles types became independent (e.g., `U32` instead of `DWORD`).
- **Memory Management:** Added `AIL_set_mem_callbacks` for better control over heap allocation on consoles.
- **Ogg Vorbis:** Native support for Ogg streams began appearing in this era.

## 4. Modern Era (v8.x - v9.x)
Shifted from a "Programmer's API" to an "Artist's API" with data-driven event systems.

- **Event System:** Functions like `AIL_enqueue_event` allow playing sounds by name rather than handle. Logic (randomization, pitch shifting) is moved to data files.
- **Soundbanks:** `AIL_open_soundbank` and `AIL_add_soundbank`. Unified asset management.
- **Speaker Config:** Explicit support for 5.1 and 7.1 surround sound via `AIL_set_speaker_configuration`.
- **Bink Audio:** Deep integration with Bink Video's audio tracks.

---

## API Comparison: 6.6 vs 8.0

| Feature | MSS 6.6 | MSS 8.0 | Notes |
|---------|---------|---------|-------|
| **Event System** | 🔴 No | 🟢 Yes | 8.0 introduced the High-Level API. |
| **Soundbanks** | 🔴 No | 🟢 Yes | 8.0 added `.msb` file support. |
| **Ogg Vorbis** | 🟡 Partial | 🟢 Full | 6.6 required external ASI provider. |
| **Win64** | 🔴 No | 🟢 Yes | 8.0 was the first stable 64-bit release. |
| **DSP Filters** | 🟢 Yes | 🟢 Yes | 6.6 introduced the current filter API. |
| **XMIDI** | 🟢 Yes | 🟢 Yes | Maintained for backward compatibility. |

---

## Implementation Guidance for OpenMiles
When implementing a specific game's `mss32.dll`, check the **Version String** in the original DLL's metadata. 
- If it's **v6.x**, prioritize `AIL_open_filter` and sample management.
- If it's **v8.x**, you will need to implement the Event System (`AIL_enqueue_event`) to be compatible.

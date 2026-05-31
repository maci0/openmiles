# Miles Sound System (MSS) API Support Matrix

This matrix tracks the availability of major API groups across different historical versions of MSS and the current implementation status in **OpenMiles**.

> **Export ABI:** every `-Dmss-version` build (v3–v9) reproduces its reference
> `mss32.dll`'s decorated export table with **zero missing exports**. The "OpenMiles"
> column below tracks *behaviour*, not symbol presence — every symbol is present.

## Support Legend
- 🟢 **Full:** Functionally implemented and verified.
- 🟡 **Partial:** Implemented as a functional prototype or stub with basic logic.
- 🔴 **None:** Not implemented or relevant.
- ⚪ **Stub:** Symbol exists for binary compatibility but performs no logic.

---

## 1. Core System APIs
| Function Group | Intro | AIL v2 | MSS v3 | MSS 6.6 | OpenMiles | Notes |
|:---|:---:|:---:|:---:|:---:|:---:|:---|
| Basic Init (`startup`, `shutdown`) | v3 | 🔴 | 🟢 | 🟢 | 🟢 Full | rebranded in v3. |
| Legacy Driver Init (`install_driver`) | v2 | 🟢 | 🟢 | ⚪ | ⚪ Stub | Used in AIL era. |
| Error Handling (`last_error`) | v3 | 🔴 | 🟢 | 🟢 | 🟢 Full | |
| Preference Management | v4 | 🔴 | 🔴 | 🟢 | 🟢 Full | |
| Redist Handling (`redist_dir`) | v6 | 🔴 | 🔴 | 🟢 | 🟢 Full | Stores path and scans for .asi/.m3d/.flt plugins |
| Timer API | v3 | 🔴 | 🟢 | 🟢 | 🟢 Full | Background timer threads |
| Quick API | v4 | 🔴 | 🔴 | 🟢 | 🟢 Full | High-level sound engine helpers |
| Memory API | v4 | 🔴 | 🔴 | 🟢 | 🟢 Full | Basic memory allocators and locking |

## 2. Digital Audio (Samples & Streams)
| Function Group | Intro | AIL v2 | MSS v3 | MSS 6.6 | OpenMiles | Notes |
|:---|:---:|:---:|:---:|:---:|:---:|:---|
| `DIG_` Prefix Functions | v2 | 🟢 | 🟢 | ⚪ | 🔴 None | Aliases not yet exported |
| `AIL_` Prefix Functions | v3 | 🔴 | 🟢 | 🟢 | 🟢 Full | |
| Sample Allocation/Release | v2 | 🟢 | 🟢 | 🟢 | 🟢 Full | |
| Volume / Panning Control | v2 | 🟢 | 🟢 | 🟢 | 🟢 Full | |
| Memory Image Loading | v3 | 🔴 | 🟢 | 🟢 | 🟢 Full | |
| Streaming (File-based) | v4 | 🔴 | 🔴 | 🟢 | 🟢 Full | |
| Input API | v4 | 🔴 | 🔴 | 🟢 | 🟢 Full | Recording via miniaudio capture device |
| Compression API | v4 | 🔴 | 🔴 | 🟢 | 🟡 Partial | Decompression implemented |
| Filter API | v6 | 🔴 | 🔴 | 🟢 | 🟢 Full | Low-pass filter via miniaudio ma_lpf_node; real-time cutoff/order control |

## 3. 3D Positional Audio
| Function Group | Intro | AIL v2 | MSS v3 | MSS 6.6 | OpenMiles | Notes |
|:---|:---:|:---:|:---:|:---:|:---:|:---|
| 3D Sample Handle Mgmt | v6 | 🔴 | 🔴 | 🟢 | 🟢 Full | Allocates Sample3D; file loading via miniaudio |
| Object Position/Velocity | v6 | 🔴 | 🔴 | 🟢 | 🟢 Full | Sample3D and listener position/velocity/orientation via miniaudio |
| 3D Providers (EAX, A3D) | v5 | 🔴 | 🔴 | 🟢 | 🟢 Full | Returns built-in OpenMiles Software 3D provider |

## 4. MIDI & XMIDI
| Function Group | Intro | AIL v2 | MSS v3 | MSS 6.6 | OpenMiles | Notes |
|:---|:---:|:---:|:---:|:---:|:---:|:---|
| `MDI_` Prefix Functions | v2 | 🟢 | 🟢 | ⚪ | 🔴 None | Aliases not yet exported |
| XMIDI Branching | v2 | 🟢 | 🟢 | 🟢 | 🟢 Full | Tempo fade, position seek with channel state replay |
| DLS / SF2 Loading | v4 | 🔴 | 🔴 | 🟢 | 🟢 Full | |

## 5. RIB (RAD Interface Broker)
| Function Group | Intro | AIL v2 | MSS v3 | MSS 6.6 | OpenMiles | Notes |
|:---|:---:|:---:|:---:|:---:|:---:|:---|
| Provider Infrastructure | v4 | 🔴 | 🔴 | 🟢 | 🟢 Full | |
| Provider Enumeration | v6 | 🔴 | 🔴 | 🟢 | 🟢 Full | Real provider enumeration with interface matching |

---

## 6. CD Audio
| Function Group | Intro | AIL v2 | MSS v3 | MSS 6.6 | OpenMiles | Notes |
|:---|:---:|:---:|:---:|:---:|:---:|:---|
| Redbook Audio | v3 | 🔴 | 🟢 | 🟢 | 🟡 Partial | Emulated handle tracks play/pause state; no actual CD audio (games fall back gracefully) |

## 7. Event System & SoundBanks (v8/v9)
| Function Group | Intro | MSS v6.6 | MSS v8 | MSS v9 | OpenMiles | Notes |
|:---|:---:|:---:|:---:|:---:|:---:|:---|
| Event text constructor/decoder | v8 | 🔴 | 🟢 | 🟢 | 🟢 Full | Byte-faithful encode + decode for every step type; `EVENT_STEP_INFO` layout matches the SDK |
| Event variables (`MilesGet/SetVar`) | v9 | 🔴 | 🔴 | 🟢 | 🟢 Full | Per-system variable store |
| SoundBank load + asset query | v8 | 🔴 | 🟢 | 🟢 | 🟢 Full | `BANK` loader; asset enumeration + event-bytecode lookup |
| Event execution VM (enqueue → play) | v8 | 🔴 | 🟢 | 🟢 | ⚪ Stub | Symbols present/ABI-correct; runtime that schedules queued sounds not yet wired |

## Technical Summary
OpenMiles reproduces the export ABI of every MSS release from **v3 through v9**
(zero missing decorated exports per version, including per-version arity quirks).
Behaviourally, the digital/MIDI/3D/RIB/filter/timer/quick subsystems and the v8/v9
event-text and soundbank-query layers are functional; the event *execution* VM is
the main remaining gap. Legacy `DIG_` and `MDI_` prefix aliases are not currently exported but could be added as PE export aliases if needed for older titles.

**Legacy Compatibility Features:**
- `AIL_waveOutOpen`, `AIL_midiOutOpen` for games that use older waveOut-style initialization.
- `AIL_open_XMIDI_driver` / `AIL_close_XMIDI_driver` as aliases for the MIDI driver functions.
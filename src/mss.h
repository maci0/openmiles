#ifndef OPENMILES_MSS_H
#define OPENMILES_MSS_H

/* NULL, which callers use to test every handle this header declares. */
#include <stddef.h>

/*
 * C declarations for the OpenMiles mss32 export table.
 *
 * The DLL is built for one historical Miles release at a time
 * (`-Dmss-version=3..9`, default 9) and each build exports only that
 * release's symbols. Define OPENMILES_MSS_VERSION to the matching encoded
 * version before including this header -- 30, 40, 50, 60, 61, 65, 66, 70, 80,
 * 90 -- so the declarations below match the DLL you link against. The default
 * is 90, the build `zig build` produces with no options.
 *
 * This header covers the core surface a title needs for playback, streaming,
 * MIDI, 3D, RIB, filters, timers, the Quick API, file I/O, and (from 8.0 on)
 * the Miles* event-system and SoundBank API. Nothing else is declared: the
 * v7 DSP-stage surface, the AIL_add_*_event_step event-text builders, the
 * per-bus v9 mixer calls, and the legacy midiOut/DLS spellings are exported by
 * the DLL but absent here. For the full per-function list see
 * docs/API_STATUS.md, and the export table itself in src/main.zig.
 */

#ifndef OPENMILES_MSS_VERSION
#define OPENMILES_MSS_VERSION 90
#endif

/* The version is the one build-time value a consumer supplies, and every guard
 * below compares it with >= and <, so an unsupported value is not a build this
 * project produces: it silently selects a declaration set that belongs to no
 * release (45 reads as "between 4 and 5", 95 as "at least 9") and the caller
 * only finds out at link time, or worse, links against a DLL whose
 * AILSOUNDINFO layout the header just misdescribed. Reject it here instead,
 * where the value came from and where the fix is. Keep this list and
 * SUPPORTED_VERSIONS in scripts/check_header.py in step; that script compiles
 * the header once per supported version and once per unsupported value, so a
 * version dropped from one and not the other is caught. */
#if OPENMILES_MSS_VERSION != 30 && \
    OPENMILES_MSS_VERSION != 40 && \
    OPENMILES_MSS_VERSION != 50 && \
    OPENMILES_MSS_VERSION != 60 && \
    OPENMILES_MSS_VERSION != 61 && \
    OPENMILES_MSS_VERSION != 65 && \
    OPENMILES_MSS_VERSION != 66 && \
    OPENMILES_MSS_VERSION != 70 && \
    OPENMILES_MSS_VERSION != 80 && \
    OPENMILES_MSS_VERSION != 90
#error "OPENMILES_MSS_VERSION must be one of 30, 40, 50, 60, 61, 65, 66, 70, 80, 90 (major*10+minor); it selects a -Dmss-version build, default 9 (90)"
#endif

#define MSS_AT_LEAST(v) (OPENMILES_MSS_VERSION >= (v))
#define MSS_BEFORE(v) (OPENMILES_MSS_VERSION < (v))

/* x86 AILSOUNDINFO layout this DLL build reads, asserted against the typedef
 * below. Kept next to the version macros because that is the only place the
 * version is known. */
#if MSS_AT_LEAST(80)
#define MSS_AILSOUNDINFO_SIZE 40
#define MSS_AILSOUNDINFO_CHANNEL_MASK_OFFSET 24
#define MSS_AILSOUNDINFO_SAMPLES_OFFSET 28
#define MSS_AILSOUNDINFO_BLOCK_SIZE_OFFSET 32
#else
#define MSS_AILSOUNDINFO_SIZE 36
#define MSS_AILSOUNDINFO_SAMPLES_OFFSET 24
#define MSS_AILSOUNDINFO_BLOCK_SIZE_OFFSET 28
#endif

#ifdef _WIN32
#define MSS_CALLBACK __stdcall
#define MSS_CDECL __cdecl
#else
#define MSS_CALLBACK
#define MSS_CDECL
#endif

/* RIB provider management switched from __cdecl to __stdcall in MSS 8.0, so a
 * caller built for a pre-8 DLL must push its arguments the other way. */
#if MSS_AT_LEAST(80)
#define MSS_RIB_CALL MSS_CALLBACK
#else
#define MSS_RIB_CALL MSS_CDECL
#endif

typedef int S32;
typedef unsigned int U32;
typedef float F32;
/* For the 64-bit-by-value fields the v8/v9 event API passes (queue IDs, label
 * filters, instance IDs). Only the layout of `unsigned long long` is assumed,
 * which every compiler agrees on for these eight bytes. */
typedef unsigned long long U64;

typedef void* HSAMPLE;
typedef void* HSTREAM;
typedef void* HDIGDRIVER;
typedef void* H3DSAMPLE;
typedef void* H3DPOBJECT;
typedef void* HPROVIDER;
typedef void* HFILTER;
typedef void* HMSSENUM;
typedef void* HTIMER;
typedef void* HREDBOOK;

#define SMP_FREE                 1
#define SMP_DONE                 2
#define SMP_PLAYING              4
#define SMP_STOPPED              8

#define SEQ_FREE                 1
#define SEQ_DONE                 2
#define SEQ_PLAYING              4
#define SEQ_STOPPED              8

#define DIG_F_MONO_8             0
#define DIG_F_MONO_16            1
#define DIG_F_STEREO_8           2
#define DIG_F_STEREO_16          3

#define REDBOOK_STOPPED          0
#define REDBOOK_PLAYING          1
#define REDBOOK_PAUSED           2
#define REDBOOK_ERROR            3

/* Event-system constants (8.0 and later). A sound instance carries a
 * MILESEVENTSOUNDSTATUS mask; an instance that is in none of these states has
 * left the system. */
#define MILESEVENTSOUNDSTATUS_PENDING   0x1
#define MILESEVENTSOUNDSTATUS_PLAYING   0x2
#define MILESEVENTSOUNDSTATUS_COMPLETE  0x4

/* The event text handed to MilesEnqueueEvent is freed once the event has been
 * consumed rather than recycled into the command buffer. */
#define MILESEVENT_ENQUEUE_FREE_EVENT   0x2

/* Seeds an enumerator walk: write this into the enumeration cursor before the
 * first MilesEnumerate* call, and pass back what each call wrote. */
#define MSS_FIRST              ((HMSSENUM)-1)

/* MSS 8.0 inserted `channel_mask` (U32) between `channels` and `samples` for
 * multichannel WAVE_FORMAT_EXTENSIBLE data, taking the struct from 9 fields /
 * 36 bytes to 10 fields / 40 bytes. The v8 and v9 builds read channel_mask at
 * +0x18 and block_size at +0x20; declaring the pre-8 layout for a v8+ build
 * makes the caller write block_size where the DLL reads channel_mask, and the
 * DLL then reads 4 bytes past the caller's struct. Verified by disassembling
 * AIL_API_set_sample_info in the reference DLLs (see src/root.zig). */
#if MSS_AT_LEAST(80)
typedef struct _AILSOUNDINFO {
    S32 format;
    void const* data_ptr;
    U32 data_len;
    U32 rate;
    S32 bits;
    S32 channels;
    U32 channel_mask;
    U32 samples;
    U32 block_size;
    void const* initial_ptr;
} AILSOUNDINFO;
#else
typedef struct _AILSOUNDINFO {
    S32 format;
    void const* data_ptr;
    U32 data_len;
    U32 rate;
    S32 bits;
    S32 channels;
    U32 samples;
    U32 block_size;
    void const* initial_ptr;
} AILSOUNDINFO;
#endif

/* The offsets are ABI, not documentation: AIL_set_sample_info, AIL_compress_ADPCM
 * and AIL_decompress_ADPCM all take an AILSOUNDINFO* the DLL reads by offset.
 * Pin the x86 layout here so a drift in this header is a compile error in the
 * consumer's build instead of a misread at runtime. Pointer width is part of
 * it, which is why the check is conditioned on the 32-bit target this DLL is. */
#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
#if defined(_WIN32) && !defined(_WIN64)
_Static_assert(sizeof(AILSOUNDINFO) == MSS_AILSOUNDINFO_SIZE, "AILSOUNDINFO size does not match this MSS version");
_Static_assert(offsetof(AILSOUNDINFO, samples) == MSS_AILSOUNDINFO_SAMPLES_OFFSET, "AILSOUNDINFO.samples offset does not match this MSS version");
_Static_assert(offsetof(AILSOUNDINFO, block_size) == MSS_AILSOUNDINFO_BLOCK_SIZE_OFFSET, "AILSOUNDINFO.block_size offset does not match this MSS version");
#if MSS_AT_LEAST(80)
_Static_assert(offsetof(AILSOUNDINFO, channel_mask) == MSS_AILSOUNDINFO_CHANNEL_MASK_OFFSET, "AILSOUNDINFO.channel_mask offset does not match this MSS version");
#endif
#endif
#endif

/* MILESEVENTSTATE: the counters MilesGetEventSystemState fills in. */
typedef struct _MILESEVENTSTATE {
    S32 CommandBufferSize;
    S32 HeapSize;
    S32 HeapRemaining;
    S32 LoadedSoundCount;
    S32 PlayingSoundCount;
    S32 LoadedBankCount;
    S32 PersistCount;
    S32 SoundBankManagementMemory;
    S32 SoundDataMemory;
} MILESEVENTSTATE;

/* MILESEVENTSOUNDINFO: one live sound instance, as
 * MilesEnumerateSoundInstances reports it. The three leading U64s are
 * byte-aligned identically under either alignment rule, so a consumer
 * compiling this for the 32-bit x86 target reads the same offsets the DLL
 * writes. */
typedef struct _MILESEVENTSOUNDINFO {
    U64 QueuedID;
    U64 InstanceID;
    U64 EventID;
    void* Sample;
    void* Stream;
    void* UserBuffer;
    S32 UserBufferLen;
    S32 Status;
    U32 Flags;
    S32 UsedDelay;
    F32 UsedVolume;
    F32 UsedPitch;
    char const* UsedSound;
    S32 HasCompletionEvent;
} MILESEVENTSOUNDINFO;

typedef struct _AILREDBOOKTEXT {
    U32 count;
    struct {
        U32 type;
        char* text;
    } entries[1];
} AILREDBOOKTEXT;

typedef void (MSS_CALLBACK *AILTIMERCB)(U32 user);
/* End-of-sample and end-of-stream callbacks share one shape: the handle that
 * finished. HSAMPLE and HSTREAM are both void*, so one typedef covers both. */
typedef void (MSS_CALLBACK *AILSTREAMCB)(void* handle);
typedef S32  (MSS_CALLBACK *AILLENGTHYCB)(U32 done, U32 total);

/* VFS callbacks for AIL_set_file_callbacks. AIL_FILE_OPEN returns the file
 * length and writes the handle it opened to *FileHandle; a 0 length is
 * ambiguous (closed, or open-but-sizeless), so the DLL falls back to a
 * SEEK_END seek before giving up. AIL_FILE_READ returns the byte count, and
 * the DLL treats a short read as a failure. */
#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2
typedef U32  (MSS_CALLBACK *AIL_FILE_OPEN)(char const* filename, U32* file_handle);
typedef void (MSS_CALLBACK *AIL_FILE_CLOSE)(U32 file_handle);
typedef S32  (MSS_CALLBACK *AIL_FILE_SEEK)(U32 file_handle, S32 offset, U32 type);
typedef U32  (MSS_CALLBACK *AIL_FILE_READ)(U32 file_handle, void* buffer, U32 bytes_to_read);

typedef void* HSEQUENCE;
typedef void* HDLSDRIVER;
typedef void* HDLSBANK;

#ifdef __cplusplus
extern "C" {
#endif

// Core System
S32        MSS_CALLBACK AIL_startup(void);
void       MSS_CALLBACK AIL_shutdown(void);
char*      MSS_CALLBACK AIL_last_error(void);
#if MSS_AT_LEAST(60)
char*      MSS_CALLBACK AIL_set_redist_directory(char const* dir);
#endif
S32        MSS_CALLBACK AIL_get_preference(U32 number);
S32        MSS_CALLBACK AIL_set_preference(U32 number, S32 value);

// Digital Audio Driver
#if MSS_AT_LEAST(61)
HDIGDRIVER MSS_CALLBACK AIL_open_digital_driver(U32 frequency, S32 bits, S32 channels, U32 flags);
void       MSS_CALLBACK AIL_close_digital_driver(HDIGDRIVER dig);
#endif
void       MSS_CALLBACK AIL_serve(void);
#if MSS_BEFORE(62)
void       MSS_CALLBACK AIL_set_digital_master_volume(HDIGDRIVER dig, S32 master_volume);
S32        MSS_CALLBACK AIL_digital_master_volume(HDIGDRIVER dig);
#endif
#if MSS_BEFORE(67)
U32        MSS_CALLBACK AIL_waveOutOpen(HDIGDRIVER* drvr_ptr, U32* lphwo, S32 device_id, void* format);
#endif
S32        MSS_CALLBACK AIL_digital_handle_release(HDIGDRIVER dig);
S32        MSS_CALLBACK AIL_digital_handle_reacquire(HDIGDRIVER dig);

// Sample Management
HSAMPLE    MSS_CALLBACK AIL_allocate_sample_handle(HDIGDRIVER dig);
void       MSS_CALLBACK AIL_release_sample_handle(HSAMPLE S);
#if MSS_AT_LEAST(80)
/* v7 takes two extra S32 arguments; v8+ takes an output format and reports
 * success, v3-v6.6 takes none. The arity is part of the stdcall decoration,
 * so each range needs its own declaration. */
S32        MSS_CALLBACK AIL_init_sample(HSAMPLE S, S32 format);
#elif MSS_AT_LEAST(70)
void       MSS_CALLBACK AIL_init_sample(HSAMPLE S, S32 cb_type, S32 cb_param);
#else
void       MSS_CALLBACK AIL_init_sample(HSAMPLE S);
#endif
S32        MSS_CALLBACK AIL_set_sample_file(HSAMPLE S, void const* file_image, S32 block);
#if MSS_AT_LEAST(50)
S32        MSS_CALLBACK AIL_set_named_sample_file(HSAMPLE S, char const* file_type, void const* file_image, S32 size, U32 flags);
#endif
void       MSS_CALLBACK AIL_set_sample_address(HSAMPLE S, void const* start, U32 len);
#if MSS_BEFORE(67)
void       MSS_CALLBACK AIL_set_sample_type(HSAMPLE S, S32 format, U32 flags);
#endif
void       MSS_CALLBACK AIL_start_sample(HSAMPLE S);
void       MSS_CALLBACK AIL_stop_sample(HSAMPLE S);
void       MSS_CALLBACK AIL_resume_sample(HSAMPLE S);
void       MSS_CALLBACK AIL_end_sample(HSAMPLE S);
/* No AIL_pause_sample: no Miles release ever exported that name, so the DLL
 * does not provide it and a call to it would not link. */
U32        MSS_CALLBACK AIL_sample_status(HSAMPLE S);
#if MSS_BEFORE(62)
S32        MSS_CALLBACK AIL_sample_volume(HSAMPLE S);
S32        MSS_CALLBACK AIL_sample_pan(HSAMPLE S);
void       MSS_CALLBACK AIL_set_sample_volume(HSAMPLE S, S32 volume);
void       MSS_CALLBACK AIL_set_sample_pan(HSAMPLE S, S32 pan);
#endif
S32        MSS_CALLBACK AIL_sample_playback_rate(HSAMPLE S);
#if MSS_AT_LEAST(65)
void       MSS_CALLBACK AIL_set_sample_volume_pan(HSAMPLE S, S32 volume, S32 pan);
#endif
void       MSS_CALLBACK AIL_set_sample_playback_rate(HSAMPLE S, S32 rate);
void       MSS_CALLBACK AIL_set_sample_loop_count(HSAMPLE S, S32 count);
S32        MSS_CALLBACK AIL_sample_loop_count(HSAMPLE S);
#if MSS_AT_LEAST(50)
void       MSS_CALLBACK AIL_sample_ms_position(HSAMPLE S, S32* total_ms, S32* current_ms);
void       MSS_CALLBACK AIL_set_sample_ms_position(HSAMPLE S, S32 ms);
#endif
U32        MSS_CALLBACK AIL_sample_position(HSAMPLE S);
void       MSS_CALLBACK AIL_set_sample_position(HSAMPLE S, U32 pos);
U32        MSS_CALLBACK AIL_active_sample_count(HDIGDRIVER dig);
void*      MSS_CALLBACK AIL_register_EOS_callback(HSAMPLE S, AILSTREAMCB callback);

// Streaming Audio
HSTREAM    MSS_CALLBACK AIL_open_stream(HDIGDRIVER dig, char const* filename, S32 stream_mem);
void       MSS_CALLBACK AIL_close_stream(HSTREAM stream);
void       MSS_CALLBACK AIL_start_stream(HSTREAM stream);
void       MSS_CALLBACK AIL_pause_stream(HSTREAM stream, S32 onoff);
#if MSS_BEFORE(62)
void       MSS_CALLBACK AIL_set_stream_volume(HSTREAM stream, S32 volume);
void       MSS_CALLBACK AIL_set_stream_pan(HSTREAM stream, S32 pan);
S32        MSS_CALLBACK AIL_stream_volume(HSTREAM stream);
S32        MSS_CALLBACK AIL_stream_pan(HSTREAM stream);
#endif
#if MSS_BEFORE(67)
void       MSS_CALLBACK AIL_set_stream_playback_rate(HSTREAM stream, S32 rate);
S32        MSS_CALLBACK AIL_stream_playback_rate(HSTREAM stream);
#endif
void       MSS_CALLBACK AIL_set_stream_loop_count(HSTREAM stream, S32 count);
S32        MSS_CALLBACK AIL_stream_loop_count(HSTREAM stream);
#if MSS_AT_LEAST(50)
void       MSS_CALLBACK AIL_set_stream_ms_position(HSTREAM stream, S32 ms);
void       MSS_CALLBACK AIL_stream_ms_position(HSTREAM stream, S32* total_ms, S32* current_ms);
#endif
/* Signed: a null or errored stream reports -1, so a U32 return would read that
 * back as 4294967295 instead of a distinguishable failure. */
S32        MSS_CALLBACK AIL_stream_status(HSTREAM stream);
void*      MSS_CALLBACK AIL_register_stream_callback(HSTREAM stream, AILSTREAMCB callback);
void       MSS_CALLBACK AIL_auto_service_stream(HSTREAM stream, S32 onoff);

// MIDI API
/* The build exports the XMIDI-spelled driver pair, not AIL_open_midi_driver /
 * AIL_close_midi_driver: no Miles release exported those two names either. The
 * MIDI surface is therefore available on 6.1-7.0 builds only; from 8.0 on, use
 * the v8/v9 event and SoundBank APIs (docs/API_STATUS.md). */
#if MSS_AT_LEAST(61) && MSS_BEFORE(71)
HDLSDRIVER  MSS_CALLBACK AIL_open_XMIDI_driver(U32 flags);
void        MSS_CALLBACK AIL_close_XMIDI_driver(HDLSDRIVER driver);
#endif
#if MSS_BEFORE(71)
HSEQUENCE   MSS_CALLBACK AIL_allocate_sequence_handle(HDLSDRIVER driver);
void        MSS_CALLBACK AIL_release_sequence_handle(HSEQUENCE S);
S32         MSS_CALLBACK AIL_init_sequence(HSEQUENCE S, void const* start, S32 sequence_num);
void        MSS_CALLBACK AIL_start_sequence(HSEQUENCE S);
void        MSS_CALLBACK AIL_stop_sequence(HSEQUENCE S);
void        MSS_CALLBACK AIL_resume_sequence(HSEQUENCE S);
U32         MSS_CALLBACK AIL_sequence_status(HSEQUENCE S);
void        MSS_CALLBACK AIL_set_sequence_volume(HSEQUENCE S, S32 volume, S32 ms);
void        MSS_CALLBACK AIL_set_sequence_loop_count(HSEQUENCE S, S32 loop_count);
void        MSS_CALLBACK AIL_branch_index(HSEQUENCE S, U32 marker_number);
#endif

#if MSS_AT_LEAST(50) && MSS_BEFORE(71)
HDLSBANK    MSS_CALLBACK AIL_DLS_load_file(HDLSDRIVER driver, char const* filename, U32 flags);
#endif

// RIB functions
#if MSS_AT_LEAST(40)
// S32, not long: the exported symbol takes a 4-byte stack slot on every
// version and target (the SDK spells it long, which is 32-bit under LLP64 but
// 64-bit under LP64, so a long prototype miscompiles a 64-bit caller).
HPROVIDER   MSS_RIB_CALL RIB_alloc_provider_handle(S32 module);
void        MSS_RIB_CALL RIB_free_provider_handle(HPROVIDER provider);
void        MSS_RIB_CALL RIB_register_interface(HPROVIDER provider, char const* name, S32 count, void const* entries);
void        MSS_RIB_CALL RIB_unregister_interface(HPROVIDER provider, char const* name, S32 count, void const* entries);
S32         MSS_RIB_CALL RIB_request_interface(HPROVIDER provider, char const* name, S32 count, void* entries);
#endif
#if MSS_AT_LEAST(50)
#if MSS_BEFORE(62)
HPROVIDER   MSS_CALLBACK RIB_provider_library_handle(void);
#endif
S32         MSS_CALLBACK RIB_load_application_providers(char const* dir);
S32         MSS_CALLBACK RIB_enumerate_providers(char const* name, HMSSENUM* next, HPROVIDER* handle);
#endif
#if MSS_AT_LEAST(60)
HPROVIDER   MSS_CALLBACK RIB_find_files_provider(char const* name, char const* property, char const* filename, char const* search_dir, char const* file_ext);
#endif

// Filter API
/* Filtering is driven through the DSP-property names (AIL_*_property), not the
 * AIL_set_sample_filter / AIL_set_filter_attribute spellings, which no Miles
 * release exported. */
#if MSS_AT_LEAST(60)
HFILTER     MSS_CALLBACK AIL_open_filter(HPROVIDER lib, HDIGDRIVER dig);
void        MSS_CALLBACK AIL_close_filter(HFILTER filter);
#if MSS_BEFORE(67)
void        MSS_CALLBACK AIL_filter_attribute(HFILTER filter, char const* name, void* val);
#endif
S32         MSS_CALLBACK AIL_enumerate_filters(HMSSENUM* next, HPROVIDER* dest, char** name);
#endif

// 3D Audio API
#if MSS_AT_LEAST(50) && MSS_BEFORE(67)
H3DSAMPLE   MSS_CALLBACK AIL_allocate_3D_sample_handle(HDIGDRIVER dig);
void        MSS_CALLBACK AIL_release_3D_sample_handle(H3DSAMPLE S);
S32         MSS_CALLBACK AIL_set_3D_sample_file(H3DSAMPLE S, void const* file_image);
void        MSS_CALLBACK AIL_set_3D_position(H3DPOBJECT obj, F32 x, F32 y, F32 z);
void        MSS_CALLBACK AIL_set_3D_velocity(H3DPOBJECT obj, F32 x, F32 y, F32 z, F32 factor);
void        MSS_CALLBACK AIL_set_3D_orientation(H3DPOBJECT obj, F32 front_x, F32 front_y, F32 front_z, F32 up_x, F32 up_y, F32 up_z);
S32         MSS_CALLBACK AIL_enumerate_3D_providers(HMSSENUM* next, HPROVIDER* dest, char** name);
/* v4/v5 grew two extra F32 arguments; the arity is part of the stdcall
 * decoration, so each range needs its own declaration. */
#if MSS_BEFORE(60)
void        MSS_CALLBACK AIL_set_3D_sample_distances(H3DSAMPLE S, F32 max_dist, F32 min_dist, F32 cone_inner, F32 cone_outer);
#else
void        MSS_CALLBACK AIL_set_3D_sample_distances(H3DSAMPLE S, F32 max_dist, F32 min_dist);
#endif
#endif

#if MSS_AT_LEAST(70)
void        MSS_CALLBACK AIL_set_listener_3D_position(HDIGDRIVER dig, F32 x, F32 y, F32 z);
void        MSS_CALLBACK AIL_set_listener_3D_velocity(HDIGDRIVER dig, F32 x, F32 y, F32 z, F32 factor);
void        MSS_CALLBACK AIL_set_listener_3D_orientation(HDIGDRIVER dig, F32 front_x, F32 front_y, F32 front_z, F32 up_x, F32 up_y, F32 up_z);
#endif

// Unified audio API (v7 and later)
#if MSS_AT_LEAST(65)
/* v6.5 introduced the level/pan getters and the master level and reverb
 * calls on the ordinary HSAMPLE/HDIGDRIVER handles; v7 moved 3D onto the
 * same HSAMPLE and dropped the H3DSAMPLE family. A NULL handle is what the
 * first parameter checks, so a NULL HSAMPLE is the documented way to say
 * "the current sample". The low-pass cutoff widened at 8.0 to take a channel,
 * and the master reverb and room-type calls widened at 9.0 to take a bus
 * index, so each arity needs its own declaration: the count is part of the
 * stdcall decoration. */
void        MSS_CALLBACK AIL_set_sample_volume_levels(HSAMPLE S, F32 left_level, F32 right_level);
void        MSS_CALLBACK AIL_sample_volume_levels(HSAMPLE S, F32* left_level, F32* right_level);
/* The unified getter, not the pre-8 AIL_set_sample_volume_pan(HSAMPLE, S32,
 * S32): this one reports volume and pan in the 0-127 MSS scale through the
 * pointers, and a null pointer leaves that half untouched. */
void        MSS_CALLBACK AIL_sample_volume_pan(HSAMPLE S, F32* volume, F32* pan);
void        MSS_CALLBACK AIL_set_sample_reverb_levels(HSAMPLE S, F32 dry_level, F32 wet_level);
void        MSS_CALLBACK AIL_sample_reverb_levels(HSAMPLE S, F32* dry_level, F32* wet_level);
#if MSS_AT_LEAST(80)
void        MSS_CALLBACK AIL_set_sample_low_pass_cut_off(HSAMPLE S, S32 channel, F32 cut_off);
F32         MSS_CALLBACK AIL_sample_low_pass_cut_off(HSAMPLE S, S32 channel);
#else
void        MSS_CALLBACK AIL_set_sample_low_pass_cut_off(HSAMPLE S, F32 cut_off);
F32         MSS_CALLBACK AIL_sample_low_pass_cut_off(HSAMPLE S);
#endif
F32         MSS_CALLBACK AIL_digital_master_volume_level(HDIGDRIVER dig);
void        MSS_CALLBACK AIL_set_digital_master_volume_level(HDIGDRIVER dig, F32 master_volume);
#endif

#if MSS_AT_LEAST(65) && MSS_BEFORE(90)
void        MSS_CALLBACK AIL_set_digital_master_reverb(HDIGDRIVER dig, F32 reverb_decay_time, F32 reverb_predelay, F32 reverb_damping);
void        MSS_CALLBACK AIL_digital_master_reverb(HDIGDRIVER dig, F32* reverb_time, F32* reverb_predelay, F32* reverb_damping);
void        MSS_CALLBACK AIL_set_digital_master_reverb_levels(HDIGDRIVER dig, F32 dry_level, F32 wet_level);
void        MSS_CALLBACK AIL_digital_master_reverb_levels(HDIGDRIVER dig, F32* dry_level, F32* wet_level);
#elif MSS_AT_LEAST(90)
/* v9.0 put every master effect on a named bus, so each of these grew a bus
 * index as its first argument after the driver. */
void        MSS_CALLBACK AIL_set_digital_master_reverb(HDIGDRIVER dig, S32 bus_index, F32 reverb_decay_time, F32 reverb_predelay, F32 reverb_damping);
void        MSS_CALLBACK AIL_digital_master_reverb(HDIGDRIVER dig, S32 bus_index, F32* reverb_time, F32* reverb_predelay, F32* reverb_damping);
void        MSS_CALLBACK AIL_set_digital_master_reverb_levels(HDIGDRIVER dig, S32 bus_index, F32 dry_level, F32 wet_level);
void        MSS_CALLBACK AIL_digital_master_reverb_levels(HDIGDRIVER dig, S32 bus_index, F32* dry_level, F32* wet_level);
#endif

#if MSS_AT_LEAST(70) && MSS_BEFORE(90)
/* AIL_set_room_type returns void here, matching what the DLL actually
 * implements; the S32 the original SDK header spells is a return value it
 * never filled in. AIL_room_type is the one that reports the current setting. */
void        MSS_CALLBACK AIL_set_room_type(HDIGDRIVER dig, S32 room_type);
S32         MSS_CALLBACK AIL_room_type(HDIGDRIVER dig);
#elif MSS_AT_LEAST(90)
void        MSS_CALLBACK AIL_set_room_type(HDIGDRIVER dig, S32 bus_index, S32 room_type);
S32         MSS_CALLBACK AIL_room_type(HDIGDRIVER dig, S32 bus_index);
#endif

#if MSS_AT_LEAST(70)
/* 3D on the ordinary HSAMPLE: the H3DSAMPLE spellings above stop at 6.6, and
 * these are what a v7 or later build exports. The AIL_set_* forms take the
 * values, the AIL_sample_* forms read them back, and a null pointer on a
 * getter leaves that component unchanged. */
void        MSS_CALLBACK AIL_set_sample_3D_position(HSAMPLE S, F32 x, F32 y, F32 z);
S32         MSS_CALLBACK AIL_sample_3D_position(HSAMPLE S, F32* x, F32* y, F32* z);
void        MSS_CALLBACK AIL_set_sample_3D_velocity(HSAMPLE S, F32 dx, F32 dy, F32 dz, F32 magnitude);
void        MSS_CALLBACK AIL_set_sample_3D_velocity_vector(HSAMPLE S, F32 dx, F32 dy, F32 dz);
void        MSS_CALLBACK AIL_sample_3D_velocity(HSAMPLE S, F32* dx, F32* dy, F32* dz);
void        MSS_CALLBACK AIL_set_sample_3D_orientation(HSAMPLE S, F32 front_x, F32 front_y, F32 front_z, F32 up_x, F32 up_y, F32 up_z);
void        MSS_CALLBACK AIL_sample_3D_orientation(HSAMPLE S, F32* front_x, F32* front_y, F32* front_z, F32* up_x, F32* up_y, F32* up_z);
/* Angles are in degrees, and the outer level is the 0-127 volume played
 * outside the cone. */
void        MSS_CALLBACK AIL_set_sample_3D_cone(HSAMPLE S, F32 inner_angle, F32 outer_angle, F32 outer_volume_level);
void        MSS_CALLBACK AIL_sample_3D_cone(HSAMPLE S, F32* inner_angle, F32* outer_angle, F32* outer_volume_level);
/* Distances are in world units, and auto_3D_wet_atten is non-zero to route
 * the 3D wet signal through the same attenuation curve. */
void        MSS_CALLBACK AIL_set_sample_3D_distances(HSAMPLE S, F32 max_dist, F32 min_dist, S32 auto_3D_wet_atten);
void        MSS_CALLBACK AIL_sample_3D_distances(HSAMPLE S, F32* max_dist, F32* min_dist, S32* auto_3D_wet_atten);
/* Advance a moving source and a moving listener by one frame. The engine
 * also advances them from its own mix callback; call these only for sources
 * the application moves by hand. */
void        MSS_CALLBACK AIL_update_sample_3D_position(HSAMPLE S, F32 dt_ms);
void        MSS_CALLBACK AIL_set_sample_obstruction(HSAMPLE S, F32 obstruction);
F32         MSS_CALLBACK AIL_sample_obstruction(HSAMPLE S);
void        MSS_CALLBACK AIL_set_sample_occlusion(HSAMPLE S, F32 occlusion);
F32         MSS_CALLBACK AIL_sample_occlusion(HSAMPLE S);
void        MSS_CALLBACK AIL_set_sample_exclusion(HSAMPLE S, F32 exclusion);
F32         MSS_CALLBACK AIL_sample_exclusion(HSAMPLE S);
S32         MSS_CALLBACK AIL_set_sample_info(HSAMPLE S, AILSOUNDINFO const* info);
#endif

#if MSS_AT_LEAST(70)
void        MSS_CALLBACK AIL_listener_3D_position(HDIGDRIVER dig, F32* x, F32* y, F32* z);
void        MSS_CALLBACK AIL_listener_3D_velocity(HDIGDRIVER dig, F32* dx, F32* dy, F32* dz);
void        MSS_CALLBACK AIL_set_listener_3D_velocity_vector(HDIGDRIVER dig, F32 dx, F32 dy, F32 dz);
void        MSS_CALLBACK AIL_listener_3D_orientation(HDIGDRIVER dig, F32* front_x, F32* front_y, F32* front_z, F32* up_x, F32* up_y, F32* up_z);
void        MSS_CALLBACK AIL_update_listener_3D_position(HDIGDRIVER dig, F32 dt_ms);
#endif

#if MSS_AT_LEAST(65) && MSS_BEFORE(67)
/* 6.5-6.6 only: the per-stream half of the level/pan/reverb/low-pass family,
 * dropped again in 7.x when the stream handle lost its own controls. */
void        MSS_CALLBACK AIL_set_stream_volume_levels(HSTREAM stream, F32 left_level, F32 right_level);
void        MSS_CALLBACK AIL_stream_volume_levels(HSTREAM stream, F32* left_level, F32* right_level);
void        MSS_CALLBACK AIL_stream_volume_pan(HSTREAM stream, F32* volume, F32* pan);
void        MSS_CALLBACK AIL_set_stream_reverb_levels(HSTREAM stream, F32 dry_level, F32 wet_level);
void        MSS_CALLBACK AIL_stream_reverb_levels(HSTREAM stream, F32* dry_level, F32* wet_level);
void        MSS_CALLBACK AIL_set_stream_low_pass_cut_off(HSTREAM stream, F32 cut_off);
F32         MSS_CALLBACK AIL_stream_low_pass_cut_off(HSTREAM stream);
#endif

// Event system / SoundBank API (8.0 and later)
// The `Miles*` names are what the 8.0 and 9.x DLLs export; the 9.x SDK only
// aliases AIL_* spellings onto them, so calling Miles* directly is correct on
// both. Handles are opaque and are never freed by the DLL: a system from
// MilesStartupEventSystem lives until MilesShutdownEventSystem, a bank from
// MilesAddSoundBank until MilesReleaseSoundBank.
// Several calls take the 64-bit fields (queue IDs, label filters, instance IDs)
// by value, which on the 32-bit stdcall ABI occupies two stack slots. A 32-bit
// declaration there would corrupt the caller's stack, so U64 is the type.
#if MSS_AT_LEAST(80)

/* Start an event system over `driver` (an HDIGDRIVER, or NULL for a standalone
 * one) with a command buffer of `command_buf_len` bytes. `memory_buf` and
 * `memory_len` are accepted and ignored: persistent presets are heap-allocated
 * per name. Returns the system handle, or NULL with the reason in
 * AIL_last_error(). */
void*       MSS_CALLBACK MilesStartupEventSystem(void* driver, S32 command_buf_len, void* memory_buf, S32 memory_len);
void        MSS_CALLBACK MilesShutdownEventSystem(void);
#if MSS_AT_LEAST(90)
/* Attach a second system to an existing one; returns the new handle. */
void*       MSS_CALLBACK MilesAddEventSystem(void* driver);
#endif

/* Heap and instance counters for the system. `state` is left untouched when it
 * is NULL. A v9 build takes the system to read; a v8 build has one global
 * system and takes only the output. */
#if MSS_AT_LEAST(90)
void        MSS_CALLBACK MilesGetEventSystemState(void* system, MILESEVENTSTATE* state);
#else
void        MSS_CALLBACK MilesGetEventSystemState(MILESEVENTSTATE* state);
#endif

#if MSS_AT_LEAST(90)
/* Variables: the name is resolved against the bank's and the application's
 * variable blocks, and an unknown name is a no-op rather than an error. The
 * Get forms report whether the name resolved and write through `value` when it
 * did. `system` is a handle, not a pointer into the heap. A v8 build has one
 * global system and does not export these four at all. */
void        MSS_CALLBACK MilesSetVarI(U32 system, char const* name, S32 value);
void        MSS_CALLBACK MilesSetVarF(U32 system, char const* name, F32 value);
S32         MSS_CALLBACK MilesGetVarI(U32 system, char const* name, S32* value);
S32         MSS_CALLBACK MilesGetVarF(U32 system, char const* name, F32* value);
#endif

/* Queue a compiled event for playback. `event` points at event text as
 * AIL_create_event or AIL_get_event_contents produced it; `user_buffer` and
 * `user_buffer_len` attach caller data to the resulting instance, which the
 * instance reports back through MilesEnumerateSoundInstances. `flags` takes
 * the MILESEVENT_ENQUEUE_* values. The return is the queue ID that
 * MilesEnumerateSoundInstances matches on, or 0 if the event was rejected. */
U64         MSS_CALLBACK MilesEnqueueEvent(void const* event, void* user_buffer, S32 user_buffer_len, S32 flags, U64 event_filter);
#if MSS_AT_LEAST(90)
/* The same, against one named event system instead of the current one, and
 * against an event named rather than supplied as text. */
U64         MSS_CALLBACK MilesEnqueueEventContext(void* system, void const* event, void* user_buffer, S32 user_buffer_len, S32 flags, U64 event_filter);
U64         MSS_CALLBACK MilesEnqueueEventByName(char const* event_name);
#endif

/* Begin/Complete bracket the frames a game enqueues, so a batch of events all
 * resolve their variables against one consistent view. Both report whether the
 * queue was in the matching state. */
S32         MSS_CALLBACK MilesBeginEventQueueProcessing(void);
S32         MSS_CALLBACK MilesCompleteEventQueueProcessing(void);
void        MSS_CALLBACK MilesClearEventQueue(void);

/* Start one sound out of a bank. `sound_name` and `labels` are bank-relative
 * names; a NULL `sound_name` starts nothing and returns 0, and NULL labels
 * start every instance carrying the sound. Returns the instance ID. */
U64         MSS_CALLBACK MilesStartSoundInstance(void* bank, char const* sound_name, U32 loop_count, S32 stream, char const* labels, void* user_buffer, S32 user_buffer_len, S32 user_buffer_flags);
/* Stop, pause, or resume every live instance carrying `labels`, or every
 * instance when `labels` is NULL. `filter` is a mask of MILESEVENTSOUNDSTATUS_*
 * states; 0 matches every state. Returns the number of instances affected. */
U64         MSS_CALLBACK MilesStopSoundInstances(char const* labels, U64 filter);
U64         MSS_CALLBACK MilesPauseSoundInstances(char const* labels, U64 filter);
U64         MSS_CALLBACK MilesResumeSoundInstances(char const* labels, U64 filter);

/* Enumerate live instances. Seed `*io_next` with MSS_FIRST for the first call
 * and pass back what the previous call wrote; 0 ends the walk. `status` is a
 * mask of MILESEVENTSOUNDSTATUS_* and 0 means every status. `labels` filters,
 * `search_for_id` restricts to one instance, and `out_info` receives the
 * MILESEVENTSOUNDINFO for the instance that was found (NULL to skip it). The
 * v8 build narrows the instance filter to 32 bits, which is its only search
 * granularity. */
#if MSS_AT_LEAST(90)
S32         MSS_CALLBACK MilesEnumerateSoundInstances(void* system, void** io_next, S32 status, char const* labels, U64 search_for_id, void* out_info);
#else
S32         MSS_CALLBACK MilesEnumerateSoundInstances(void* system, void** io_next, S32 status, char const* labels, U32 search_for_id, void* out_info);
#endif

/* Enumerate the names held as persistent presets, with the same MSS_FIRST
 * seeding as the instance walk. `*out_name` receives a string that stays valid
 * until the bank is released. */
#if MSS_AT_LEAST(90)
S32         MSS_CALLBACK MilesEnumeratePresetPersists(void* system, void** io_next, char** out_name);
#else
S32         MSS_CALLBACK MilesEnumeratePresetPersists(void** io_next, char** out_name);
#endif

#if MSS_AT_LEAST(90)
/* Seek a playing instance. `offset` is in samples or in milliseconds, decided
 * by `is_ms`; an offset before the start clamps to the start. */
void        MSS_CALLBACK MilesSetSoundStartOffset(U32 instance, S32 offset, S32 is_ms);
#endif

/* Cap how many instances may carry a label at once, as a colon-separated list
 * of `label count` pairs (`"footstep 4:door 2"`); matching is
 * case-insensitive and a count of 0 evicts every instance carrying the label
 * when the next one starts. A v8 build has one global system and takes only
 * the limits string. */
#if MSS_AT_LEAST(90)
S32         MSS_CALLBACK MilesSetSoundLabelLimits(void* system, char const* sound_limits);
#else
S32         MSS_CALLBACK MilesSetSoundLabelLimits(char const* sound_limits);
#endif

/* Load a bank. `name` is the name the bank's assets resolve under, or NULL for
 * the name the file carries; a `name` that does not match the bank's own is
 * rejected with a NULL return. Returns the bank handle. A v8 build loads the
 * bank under its own name and takes only the filename. */
#if MSS_AT_LEAST(90)
void*       MSS_CALLBACK MilesAddSoundBank(char const* filename, char const* name);
#else
void*       MSS_CALLBACK MilesAddSoundBank(char const* filename);
#endif
S32         MSS_CALLBACK MilesReleaseSoundBank(void* bank);
/* Resolve a named event to its compiled text, or NULL if the bank has no such
 * event. The bytes stay valid until the bank is released. */
void const* MSS_CALLBACK MilesFindEvent(void* bank, char const* event_name);
#if MSS_AT_LEAST(90)
/* Duration in milliseconds of a named event across the loaded banks, or 0 if
 * no bank carries it or its first start sound has no resolvable duration. */
S32         MSS_CALLBACK MilesGetEventLength(char const* event_name);
#endif
/* A multi-line dump of the loaded banks and their assets, in a buffer the
 * caller frees with free() (or AIL_mem_free_lock). */
char const* MSS_CALLBACK MilesTextDumpEventSystem(void);

/* Install a 32-bit xorshift routine the event VM draws random choices from, and
 * the callback that receives an event the VM could not execute. A NULL resets
 * either to the built-in. */
void        MSS_CALLBACK MilesRegisterRand(void* rand);
void        MSS_CALLBACK MilesSetEventErrorCallback(void* callback);
void        MSS_CALLBACK MilesSetBankFunctions(void const* functions);
#if MSS_AT_LEAST(90)
/* Function table the SDK's audition loader would install; it takes an opaque
 * table and is accepted and ignored. */
void        MSS_CDECL    MilesEventSetAuditionFunctions(void const* functions);
/* The bank loader's function table, which this build has no table to hand
 * back and answers with NULL. */
void const* MSS_CALLBACK MilesGetBankFunctions(void);
/* Opt into telemetry and the lightweight timer; both take the owning context
 * or NULL and are accepted and ignored. */
void        MSS_CALLBACK MilesUseTelemetry(void* context);
void        MSS_CALLBACK MilesUseTmLite(void* context);

/* Background file reads. Start one with MilesAsyncFileRead, poll it with
 * MilesAsyncFileStatus until it reports a completion code, and drop it with
 * MilesAsyncFileCancel; MilesAsyncStartup and MilesAsyncShutdown bracket the
 * whole set. MilesAsyncSetPaused stops delivery without cancelling. */
S32         MSS_CALLBACK MilesAsyncStartup(void);
S32         MSS_CALLBACK MilesAsyncShutdown(void);
S32         MSS_CALLBACK MilesAsyncFileRead(void* request);
S32         MSS_CALLBACK MilesAsyncFileCancel(void* request);
S32         MSS_CALLBACK MilesAsyncFileStatus(void* request, U32 ms);
void        MSS_CALLBACK MilesAsyncSetPaused(S32 is_paused);
void        MSS_CALLBACK MilesRequeueAsyncs(void);
#endif

#endif

// Timer API
HTIMER      MSS_CALLBACK AIL_register_timer(AILTIMERCB callback);
void        MSS_CALLBACK AIL_set_timer_frequency(HTIMER timer, U32 hertz);
void        MSS_CALLBACK AIL_set_timer_period(HTIMER timer, U32 microseconds);
void        MSS_CALLBACK AIL_start_timer(HTIMER timer);
void        MSS_CALLBACK AIL_stop_timer(HTIMER timer);
void        MSS_CALLBACK AIL_release_timer_handle(HTIMER timer);
void        MSS_CALLBACK AIL_start_all_timers(void);
void        MSS_CALLBACK AIL_stop_all_timers(void);

// Quick API
#if MSS_BEFORE(71)
void        MSS_CALLBACK AIL_quick_startup(S32 use_digital, S32 use_MIDI, U32 output_rate, S32 output_bits, S32 output_channels);
void        MSS_CALLBACK AIL_quick_shutdown(void);
HSAMPLE     MSS_CALLBACK AIL_quick_load(char const* filename);
#if MSS_AT_LEAST(50)
HSAMPLE     MSS_CALLBACK AIL_quick_load_mem(void const* buffer, U32 size);
#endif
HSAMPLE     MSS_CALLBACK AIL_quick_copy(HSAMPLE S);
void        MSS_CALLBACK AIL_quick_unload(HSAMPLE S);
S32         MSS_CALLBACK AIL_quick_play(HSAMPLE S, S32 loop_count);
S32         MSS_CALLBACK AIL_quick_status(HSAMPLE S);
/* No AIL_quick_stop: the Quick API's stop entry point is exported under
 * AIL_quick_halt. */
void        MSS_CALLBACK AIL_quick_set_volume(HSAMPLE S, S32 volume, S32 extravol);
void        MSS_CALLBACK AIL_quick_set_speed(HSAMPLE S, S32 rate);
#if MSS_AT_LEAST(50)
S32         MSS_CALLBACK AIL_quick_ms_length(HSAMPLE S);
S32         MSS_CALLBACK AIL_quick_ms_position(HSAMPLE S);
void        MSS_CALLBACK AIL_quick_set_ms_position(HSAMPLE S, S32 ms);
#endif
#endif

// Redbook (CD) API
#if MSS_BEFORE(71)
HREDBOOK    MSS_CALLBACK AIL_redbook_open(U32 drive);
void        MSS_CALLBACK AIL_redbook_close(HREDBOOK hb);
U32         MSS_CALLBACK AIL_redbook_play(HREDBOOK hb, U32 start_ms, U32 end_ms);
U32         MSS_CALLBACK AIL_redbook_stop(HREDBOOK hb);
U32         MSS_CALLBACK AIL_redbook_pause(HREDBOOK hb);
U32         MSS_CALLBACK AIL_redbook_resume(HREDBOOK hb);
U32         MSS_CALLBACK AIL_redbook_status(HREDBOOK hb);
U32         MSS_CALLBACK AIL_redbook_tracks(HREDBOOK hb);
#endif

// ASI API
/* No AIL_open_ASI_provider / AIL_close_ASI_provider / AIL_ASI_provider_attribute:
 * those names are in no Miles export table, so the DLL does not provide them.
 * Load external .asi codecs through RIB_load_application_providers instead. */

// Compression API
#if MSS_AT_LEAST(50)
#if MSS_BEFORE(71)
S32         MSS_CALLBACK AIL_compress_ASI(AILSOUNDINFO const* info, char const* filename_ext, void** outdata, U32* outsize, AILLENGTHYCB callback);
#endif
S32         MSS_CALLBACK AIL_decompress_ASI(void const* indata, U32 insize, char const* filename_ext, void** wav, U32* wavsize, AILLENGTHYCB callback);
#endif

// Memory
#if MSS_AT_LEAST(30)
void*      MSS_CALLBACK AIL_mem_alloc_lock(U32 size);
void       MSS_CALLBACK AIL_mem_free_lock(void* ptr);
#endif

// File I/O
/* AIL_file_* reads and classifies files through the application's own VFS when
 * AIL_set_file_callbacks has installed one, and from disk otherwise. Every
 * failure sets the string AIL_file_error returns, which is the only
 * programmatic signal these calls give: they report absence with 0/null.
 * The buffer is stable until the next AIL_file_* call. */
char*      MSS_CALLBACK AIL_file_error(void);
void*      MSS_CALLBACK AIL_file_read(char const* filename, void* dest);
U32        MSS_CALLBACK AIL_file_size(char const* filename);
S32        MSS_CALLBACK AIL_file_write(char const* filename, void const* data, U32 len);
#if MSS_AT_LEAST(50)
/* Returns an AILFILETYPE_* code, or AILFILETYPE_UNKNOWN for a buffer shorter
 * than 8 bytes and for an unrecognised one. */
S32        MSS_CALLBACK AIL_file_type(void const* data, U32 size);
#endif
#if MSS_AT_LEAST(70)
/* AIL_file_type with the filename's extension consulted first, for the
 * Voxware/Speex voice suffixes that carry no distinguishing magic. */
S32        MSS_CALLBACK AIL_file_type_named(void const* data, char const* filename, U32 size);
#endif

#if MSS_AT_LEAST(61)
/* Routes every later file access through the game's own VFS. The four
 * arguments are the AIL_FILE_* callback pointers below, or 0 to go back to
 * reading from disk. The order is (open, close, seek, read).
 * AIL_set_file_async_callbacks takes the same four plus a completion callback
 * the DLL ignores: the async path is served synchronously, so a callback
 * posted from a worker thread would never be the caller's own. */
void       MSS_CALLBACK AIL_set_file_callbacks(void* open_fn, void* close_fn, void* seek_fn, void* read_fn);
#if MSS_BEFORE(81)
void       MSS_CALLBACK AIL_set_file_async_callbacks(void* open_fn, void* close_fn, void* seek_fn, void* read_fn, void* callback_fn);
#endif
#endif

#ifdef __cplusplus
}
#endif

#endif // OPENMILES_MSS_H

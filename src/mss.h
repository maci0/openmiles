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
 * MIDI, 3D, RIB, filters, timers, and the Quick API. Nothing else is declared:
 * the v7 DSP-stage and v8/v9 event/SoundBank surfaces, and the legacy
 * midiOut/DLS spellings, are exported by the DLL but absent here. For the full
 * per-function list see docs/API_STATUS.md, and the export table itself in
 * src/main.zig.
 */

#ifndef OPENMILES_MSS_VERSION
#define OPENMILES_MSS_VERSION 90
#endif

#define MSS_AT_LEAST(v) (OPENMILES_MSS_VERSION >= (v))
#define MSS_BEFORE(v) (OPENMILES_MSS_VERSION < (v))

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

#ifdef __cplusplus
}
#endif

#endif // OPENMILES_MSS_H

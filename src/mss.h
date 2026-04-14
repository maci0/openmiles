#ifndef OPENMILES_MSS_H
#define OPENMILES_MSS_H

#ifdef _WIN32
#define MSS_CALLBACK __stdcall
#else
#define MSS_CALLBACK
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
typedef void (MSS_CALLBACK *AILSTREAMCB)(HSTREAM stream);

typedef void* HSEQUENCE;
typedef void* HDLSDRIVER;
typedef void* HDLSBANK;

#ifdef __cplusplus
extern "C" {
#endif

// Core System
void       MSS_CALLBACK AIL_startup(void);
void       MSS_CALLBACK AIL_shutdown(void);
char*      MSS_CALLBACK AIL_last_error(void);
void       MSS_CALLBACK AIL_set_redist_directory(char const* dir);
S32        MSS_CALLBACK AIL_get_preference(U32 number);
S32        MSS_CALLBACK AIL_set_preference(U32 number, S32 value);

// Digital Audio Driver
HDIGDRIVER MSS_CALLBACK AIL_open_digital_driver(U32 frequency, S32 bits, S32 channels, U32 flags);
void       MSS_CALLBACK AIL_close_digital_driver(HDIGDRIVER dig);
void       MSS_CALLBACK AIL_serve(void);
void       MSS_CALLBACK AIL_set_digital_master_volume(HDIGDRIVER dig, S32 master_volume);
S32        MSS_CALLBACK AIL_digital_master_volume(HDIGDRIVER dig);
U32        MSS_CALLBACK AIL_waveOutOpen(HDIGDRIVER* drvr_ptr, U32* lphwo, S32 device_id, void* format);
S32        MSS_CALLBACK AIL_digital_handle_release(HDIGDRIVER dig);
S32        MSS_CALLBACK AIL_digital_handle_reacquire(HDIGDRIVER dig);

// Sample Management
HSAMPLE    MSS_CALLBACK AIL_allocate_sample_handle(HDIGDRIVER dig);
void       MSS_CALLBACK AIL_release_sample_handle(HSAMPLE S);
void       MSS_CALLBACK AIL_init_sample(HSAMPLE S);
S32        MSS_CALLBACK AIL_set_sample_file(HSAMPLE S, void const* file_image, S32 block);
S32        MSS_CALLBACK AIL_set_named_sample_file(HSAMPLE S, char const* file_type, void const* file_image, S32 size, U32 flags);
void       MSS_CALLBACK AIL_set_sample_address(HSAMPLE S, void const* start, U32 len);
void       MSS_CALLBACK AIL_set_sample_type(HSAMPLE S, S32 format, U32 flags);
void       MSS_CALLBACK AIL_start_sample(HSAMPLE S);
void       MSS_CALLBACK AIL_stop_sample(HSAMPLE S);
void       MSS_CALLBACK AIL_pause_sample(HSAMPLE S);
void       MSS_CALLBACK AIL_resume_sample(HSAMPLE S);
void       MSS_CALLBACK AIL_end_sample(HSAMPLE S);
U32        MSS_CALLBACK AIL_sample_status(HSAMPLE S);
S32        MSS_CALLBACK AIL_sample_volume(HSAMPLE S);
S32        MSS_CALLBACK AIL_sample_pan(HSAMPLE S);
S32        MSS_CALLBACK AIL_sample_playback_rate(HSAMPLE S);
void       MSS_CALLBACK AIL_set_sample_volume(HSAMPLE S, S32 volume);
void       MSS_CALLBACK AIL_set_sample_pan(HSAMPLE S, S32 pan);
void       MSS_CALLBACK AIL_set_sample_volume_pan(HSAMPLE S, S32 volume, S32 pan);
void       MSS_CALLBACK AIL_set_sample_playback_rate(HSAMPLE S, S32 rate);
void       MSS_CALLBACK AIL_set_sample_loop_count(HSAMPLE S, S32 count);
S32        MSS_CALLBACK AIL_sample_loop_count(HSAMPLE S);
void       MSS_CALLBACK AIL_sample_ms_position(HSAMPLE S, S32* total_ms, S32* current_ms);
void       MSS_CALLBACK AIL_set_sample_ms_position(HSAMPLE S, S32 ms);
U32        MSS_CALLBACK AIL_sample_position(HSAMPLE S);
void       MSS_CALLBACK AIL_set_sample_position(HSAMPLE S, U32 pos);
U32        MSS_CALLBACK AIL_active_sample_count(HDIGDRIVER dig);
void*      MSS_CALLBACK AIL_register_EOS_callback(HSAMPLE S, void* callback);

// Streaming Audio
HSTREAM    MSS_CALLBACK AIL_open_stream(HDIGDRIVER dig, char const* filename, S32 stream_mem);
void       MSS_CALLBACK AIL_close_stream(HSTREAM stream);
void       MSS_CALLBACK AIL_start_stream(HSTREAM stream);
void       MSS_CALLBACK AIL_pause_stream(HSTREAM stream, S32 onoff);
void       MSS_CALLBACK AIL_set_stream_volume(HSTREAM stream, S32 volume);
void       MSS_CALLBACK AIL_set_stream_pan(HSTREAM stream, S32 pan);
void       MSS_CALLBACK AIL_set_stream_playback_rate(HSTREAM stream, S32 rate);
void       MSS_CALLBACK AIL_set_stream_loop_count(HSTREAM stream, S32 count);
void       MSS_CALLBACK AIL_set_stream_ms_position(HSTREAM stream, S32 ms);
U32        MSS_CALLBACK AIL_stream_status(HSTREAM stream);
S32        MSS_CALLBACK AIL_stream_volume(HSTREAM stream);
S32        MSS_CALLBACK AIL_stream_pan(HSTREAM stream);
S32        MSS_CALLBACK AIL_stream_playback_rate(HSTREAM stream);
S32        MSS_CALLBACK AIL_stream_loop_count(HSTREAM stream);
void       MSS_CALLBACK AIL_stream_ms_position(HSTREAM stream, S32* total_ms, S32* current_ms);
void*      MSS_CALLBACK AIL_register_stream_callback(HSTREAM stream, void* callback);
void       MSS_CALLBACK AIL_auto_service_stream(HSTREAM stream, S32 onoff);

// MIDI API
HDLSDRIVER  MSS_CALLBACK AIL_open_midi_driver(U32 flags);
void        MSS_CALLBACK AIL_close_midi_driver(HDLSDRIVER driver);
HDLSDRIVER  MSS_CALLBACK AIL_open_XMIDI_driver(U32 flags);
void        MSS_CALLBACK AIL_close_XMIDI_driver(HDLSDRIVER driver);
HSEQUENCE   MSS_CALLBACK AIL_allocate_sequence_handle(HDLSDRIVER driver);
void        MSS_CALLBACK AIL_release_sequence_handle(HSEQUENCE S);
S32         MSS_CALLBACK AIL_init_sequence(HSEQUENCE S, void const* start, S32 sequence_num);
void        MSS_CALLBACK AIL_start_sequence(HSEQUENCE S);
void        MSS_CALLBACK AIL_stop_sequence(HSEQUENCE S);
void        MSS_CALLBACK AIL_pause_sequence(HSEQUENCE S);
void        MSS_CALLBACK AIL_resume_sequence(HSEQUENCE S);
U32         MSS_CALLBACK AIL_sequence_status(HSEQUENCE S);
void        MSS_CALLBACK AIL_set_sequence_volume(HSEQUENCE S, S32 volume, S32 ms);
void        MSS_CALLBACK AIL_set_sequence_loop_count(HSEQUENCE S, S32 loop_count);
void        MSS_CALLBACK AIL_branch_index(HSEQUENCE S, U32 marker_number);

HDLSBANK    MSS_CALLBACK AIL_DLS_load_file(HDLSDRIVER driver, char const* filename, U32 flags);
void        MSS_CALLBACK AIL_DLS_unload_file(HDLSDRIVER driver, HDLSBANK bank);

// RIB functions
HPROVIDER   MSS_CALLBACK RIB_alloc_provider_handle(long module);
void        MSS_CALLBACK RIB_free_provider_handle(HPROVIDER provider);
void        MSS_CALLBACK RIB_register_interface(HPROVIDER provider, char const* name, S32 count, void const* entries);
void        MSS_CALLBACK RIB_unregister_interface(HPROVIDER provider, char const* name, S32 count, void const* entries);
HPROVIDER   MSS_CALLBACK RIB_provider_library_handle(void);
S32         MSS_CALLBACK RIB_load_application_providers(char const* dir);
S32         MSS_CALLBACK RIB_enumerate_providers(char const* name, HMSSENUM* next, HPROVIDER* handle);
S32         MSS_CALLBACK RIB_request_interface(HPROVIDER provider, char const* name, S32 count, void* entries);
HPROVIDER   MSS_CALLBACK RIB_find_files_provider(char const* name, char const* property, char const* filename, char const* search_dir, char const* file_ext);

// Filter API
HFILTER     MSS_CALLBACK AIL_open_filter(HPROVIDER lib, HDIGDRIVER dig);
void        MSS_CALLBACK AIL_close_filter(HFILTER filter);
void        MSS_CALLBACK AIL_set_sample_filter(HSAMPLE S, HFILTER filter, S32 priority);
void        MSS_CALLBACK AIL_filter_attribute(HFILTER filter, char const* name, void* val);
void        MSS_CALLBACK AIL_set_filter_attribute(HFILTER filter, char const* name, void const* val);
S32         MSS_CALLBACK AIL_enumerate_filters(HPROVIDER provider, HMSSENUM* next, char** name);
S32         MSS_CALLBACK AIL_enumerate_3D_providers(HMSSENUM* next, HPROVIDER* dest, char** name);

// 3D Audio API
H3DSAMPLE   MSS_CALLBACK AIL_allocate_3D_sample_handle(HDIGDRIVER dig);
void        MSS_CALLBACK AIL_release_3D_sample_handle(H3DSAMPLE S);
S32         MSS_CALLBACK AIL_set_3D_sample_file(H3DSAMPLE S, void const* file_image);
void        MSS_CALLBACK AIL_set_3D_position(H3DPOBJECT obj, F32 x, F32 y, F32 z);
void        MSS_CALLBACK AIL_set_3D_velocity(H3DPOBJECT obj, F32 x, F32 y, F32 z, F32 factor);
void        MSS_CALLBACK AIL_set_3D_orientation(H3DPOBJECT obj, F32 front_x, F32 front_y, F32 front_z, F32 up_x, F32 up_y, F32 up_z);
void        MSS_CALLBACK AIL_set_3D_sample_distances(H3DSAMPLE S, F32 max_dist, F32 min_dist);

void        MSS_CALLBACK AIL_set_listener_3D_position(HDIGDRIVER dig, F32 x, F32 y, F32 z);
void        MSS_CALLBACK AIL_set_listener_3D_velocity(HDIGDRIVER dig, F32 x, F32 y, F32 z, F32 factor);
void        MSS_CALLBACK AIL_set_listener_3D_orientation(HDIGDRIVER dig, F32 front_x, F32 front_y, F32 front_z, F32 up_x, F32 up_y, F32 up_z);

// Timer API
HTIMER      MSS_CALLBACK AIL_register_timer(AILTIMERCB callback);
void        MSS_CALLBACK AIL_set_timer_frequency(HTIMER timer, U32 hertz);
void        MSS_CALLBACK AIL_set_timer_period(HTIMER timer, U32 microseconds);
void        MSS_CALLBACK AIL_set_timer_user_data(HTIMER timer, U32 user);
void        MSS_CALLBACK AIL_start_timer(HTIMER timer);
void        MSS_CALLBACK AIL_stop_timer(HTIMER timer);
void        MSS_CALLBACK AIL_release_timer_handle(HTIMER timer);
void        MSS_CALLBACK AIL_start_all_timers(void);
void        MSS_CALLBACK AIL_stop_all_timers(void);

// Quick API
void        MSS_CALLBACK AIL_quick_startup(S32 use_digital, S32 use_MIDI, U32 output_rate, S32 output_bits, S32 output_channels);
void        MSS_CALLBACK AIL_quick_shutdown(void);
HSAMPLE     MSS_CALLBACK AIL_quick_load(char const* filename);
HSAMPLE     MSS_CALLBACK AIL_quick_load_mem(void const* buffer, U32 size);
HSAMPLE     MSS_CALLBACK AIL_quick_copy(HSAMPLE S);
void        MSS_CALLBACK AIL_quick_unload(HSAMPLE S);
void        MSS_CALLBACK AIL_quick_play(HSAMPLE S, S32 loop_count);
void        MSS_CALLBACK AIL_quick_stop(HSAMPLE S);
S32         MSS_CALLBACK AIL_quick_status(HSAMPLE S);
void        MSS_CALLBACK AIL_quick_set_volume(HSAMPLE S, S32 volume);
void        MSS_CALLBACK AIL_quick_set_speed(HSAMPLE S, S32 rate);
S32         MSS_CALLBACK AIL_quick_ms_length(HSAMPLE S);
S32         MSS_CALLBACK AIL_quick_ms_position(HSAMPLE S);
void        MSS_CALLBACK AIL_quick_set_ms_position(HSAMPLE S, S32 ms);

// Redbook (CD) API
HREDBOOK    MSS_CALLBACK AIL_redbook_open(U32 drive);
void        MSS_CALLBACK AIL_redbook_close(HREDBOOK hb);
U32         MSS_CALLBACK AIL_redbook_play(HREDBOOK hb, U32 start_ms, U32 end_ms);
U32         MSS_CALLBACK AIL_redbook_stop(HREDBOOK hb);
U32         MSS_CALLBACK AIL_redbook_pause(HREDBOOK hb);
U32         MSS_CALLBACK AIL_redbook_resume(HREDBOOK hb);
U32         MSS_CALLBACK AIL_redbook_status(HREDBOOK hb);
U32         MSS_CALLBACK AIL_redbook_tracks(HREDBOOK hb);

// ASI API
HPROVIDER   MSS_CALLBACK AIL_open_ASI_provider(void const* buffer, U32 size);
void        MSS_CALLBACK AIL_close_ASI_provider(HPROVIDER provider);
void*       MSS_CALLBACK AIL_ASI_provider_attribute(HPROVIDER provider, char const* name);

// Compression API
S32         MSS_CALLBACK AIL_compress_ASI(HPROVIDER provider, char const* filename, char const* out_filename, U32 flags);
S32         MSS_CALLBACK AIL_decompress_ASI(HPROVIDER provider, char const* filename, char const* out_filename, U32 flags);

// Memory
void*      MSS_CALLBACK AIL_mem_alloc_lock(U32 size);
void       MSS_CALLBACK AIL_mem_free_lock(void* ptr);

#ifdef __cplusplus
}
#endif

#endif // OPENMILES_MSS_H

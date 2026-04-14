#ifndef TEST_UTILS_H
#define TEST_UTILS_H

#include "../deps/windows_stub.h"
#include <stdio.h>

#ifdef _WIN32
#define MSS_DECORATE(name, bytes) #name "@" #bytes
#else
#define MSS_DECORATE(name, bytes) #name
#endif

#define LOAD_FUNC_EX(name, bytes) \
    p_##name = (t_##name)GetProcAddress(mss, #name); \
    if (!p_##name) p_##name = (t_##name)GetProcAddress(mss, MSS_DECORATE(name, bytes)); \
    if (!p_##name) { \
        printf("Failed to load function: %s\n", #name); \
        return 1; \
    }

// Type definitions
typedef void (__stdcall *t_AIL_startup)(void);
typedef void (__stdcall *t_AIL_shutdown)(void);
typedef void (__stdcall *t_AIL_set_redist_directory)(const char*);
typedef char* (__stdcall *t_AIL_last_error)(void);
typedef int (__stdcall *t_AIL_get_preference)(unsigned int);
typedef int (__stdcall *t_AIL_set_preference)(unsigned int, int);

typedef void* (__stdcall *t_AIL_open_digital_driver)(unsigned int, int, int, unsigned int);
typedef void (__stdcall *t_AIL_close_digital_driver)(void*);
typedef void (__stdcall *t_AIL_set_digital_master_volume)(void*, int);

typedef void* (__stdcall *t_AIL_allocate_sample_handle)(void*);
typedef void (__stdcall *t_AIL_release_sample_handle)(void*);
typedef void (__stdcall *t_AIL_init_sample)(void*);
typedef int (__stdcall *t_AIL_set_sample_file)(void*, const void*, int);
typedef void (__stdcall *t_AIL_start_sample)(void*);
typedef void (__stdcall *t_AIL_stop_sample)(void*);
typedef void (__stdcall *t_AIL_set_sample_volume)(void*, int);
typedef void (__stdcall *t_AIL_set_sample_pan)(void*, int);
typedef void (__stdcall *t_AIL_set_sample_loop_count)(void*, int);
typedef unsigned int (__stdcall *t_AIL_sample_status)(void*);

typedef void* (__stdcall *t_AIL_open_stream)(void*, const char*, int);
typedef void (__stdcall *t_AIL_close_stream)(void*);
typedef void (__stdcall *t_AIL_start_stream)(void*);
typedef void (__stdcall *t_AIL_pause_stream)(void*, int);

typedef void* (__stdcall *t_AIL_open_midi_driver)(unsigned int);
typedef void (__stdcall *t_AIL_close_midi_driver)(void*);
typedef void* (__stdcall *t_AIL_allocate_sequence_handle)(void*);
typedef void (__stdcall *t_AIL_release_sequence_handle)(void*);
typedef void (__stdcall *t_AIL_init_sequence)(void*, const void*, int);
typedef void (__stdcall *t_AIL_start_sequence)(void*);
typedef void (__stdcall *t_AIL_stop_sequence)(void*);
typedef void* (__stdcall *t_AIL_DLS_load_file)(void*, const char*, unsigned int);

typedef void* (__stdcall *t_AIL_allocate_3D_sample_handle)(void*);
typedef void (__stdcall *t_AIL_release_3D_sample_handle)(void*);
typedef void (__stdcall *t_AIL_set_3D_position)(void*, float, float, float);
typedef void (__stdcall *t_AIL_set_3D_sample_distances)(void*, float, float);
typedef void (__stdcall *t_AIL_set_listener_3D_position)(void*, float, float, float);

typedef void (__stdcall *t_AILTIMERCB)(unsigned int user);
typedef void* (__stdcall *t_AIL_register_timer)(t_AILTIMERCB callback);
typedef void (__stdcall *t_AIL_set_timer_frequency)(void*, unsigned int);
typedef void (__stdcall *t_AIL_start_timer)(void*);
typedef void (__stdcall *t_AIL_stop_timer)(void*);
typedef void (__stdcall *t_AIL_release_timer_handle)(void*);

typedef void (__stdcall *t_AIL_quick_startup)(int, int, unsigned int, int, int);
typedef void (__stdcall *t_AIL_quick_shutdown)(void);
typedef void* (__stdcall *t_AIL_quick_load)(const char*);
typedef void (__stdcall *t_AIL_quick_play)(void*, unsigned int);
typedef void (__stdcall *t_AIL_quick_unload)(void*);

#endif

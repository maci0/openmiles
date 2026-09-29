#ifndef TEST_UTILS_H
#define TEST_UTILS_H

#include "../deps/windows_stub.h"
#include <stdio.h>
#include <string.h>

#ifdef _WIN32
/* MSVC stdcall decoration: a leading underscore plus the @<argbytes> suffix,
 * e.g. _AIL_startup@0 — matches the real mss32.dll export names. */
#define MSS_DECORATE(name, bytes) "_" #name "@" #bytes
#else
#define MSS_DECORATE(name, bytes) #name
#endif

/* Every harness in this directory answers its command line the same way, so
 * the four do not each invent a spelling: -h and --help print the usage on
 * stdout and exit 0, a mistyped flag or a surplus positional prints it on
 * stderr and exits 2, and the run's own results go to stdout while the
 * diagnostics that stop the run go to stderr. The split matters to anyone
 * piping the output: a report read from stdout is never interleaved with the
 * reason a run could not finish.
 *
 * `notes` may be NULL for a harness with nothing to say past its synopsis. */
static void test_usage(FILE* out, const char* prog, const char* synopsis,
                       const char* notes) {
    /* A harness that takes no arguments has an empty synopsis, and the
     * separator with it, so the usage line does not end in a stray space. */
    if (*synopsis) {
        fprintf(out, "Usage: %s %s\n", prog, synopsis);
    } else {
        fprintf(out, "Usage: %s\n", prog);
    }
    if (notes && *notes) fprintf(out, "\n%s\n", notes);
    fprintf(out, "\nOptions:\n  -h, --help  show this help\n");
    fprintf(out,
            "\nExit status: 0 the run completed, 1 a check failed, 2 bad invocation.\n");
}

/* Splits the command line into at most `cap` positionals, in order. Returns the
 * number it found, or -1 when the harness must stop instead: the reason has
 * already been reported and the code to exit with is in *exit_code, 0 for help
 * and 2 for a bad invocation.
 *
 * A lone "-" is a positional, not a flag, so a file named "-" still reaches the
 * harness. */
static int test_parse_args(int argc, char** argv, char** pos, int cap,
                           const char* synopsis, const char* notes,
                           int* exit_code) {
    int count = 0;
    for (int i = 1; i < argc; i++) {
        char* arg = argv[i];
        if (arg[0] != '-' || arg[1] == '\0') {
            if (count == cap) {
                fprintf(stderr, "error: unexpected argument: %s\n", arg);
                test_usage(stderr, argv[0], synopsis, notes);
                *exit_code = 2;
                return -1;
            }
            pos[count++] = arg;
            continue;
        }
        if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            test_usage(stdout, argv[0], synopsis, notes);
            *exit_code = 0;
            return -1;
        }
        fprintf(stderr, "error: unknown option: %s\n", arg);
        test_usage(stderr, argv[0], synopsis, notes);
        *exit_code = 2;
        return -1;
    }
    return count;
}

#define LOAD_FUNC_EX(name, bytes) \
    p_##name = (t_##name)GetProcAddress(mss, #name); \
    if (!p_##name) p_##name = (t_##name)GetProcAddress(mss, MSS_DECORATE(name, bytes)); \
    if (!p_##name) { \
        fprintf(stderr, "Failed to load function: %s\n", #name); \
        return 1; \
    }

/* A name this build may not export. Some of the surface a harness names is
 * gone from a given export table: the sequence and XMIDI driver entry points
 * are v6.1-v7.0 only, and AIL_ASI_provider_attribute and
 * AIL_set_timer_user_data are in no Miles export table at all, so the DLL never
 * provides them (src/main.zig lists them as never_export, and src/mss.h says
 * so). Loading one of those as required fails the whole run over a function the
 * build never claimed, so it loads optionally and the caller skips or narrows
 * what needs it. */
#define LOAD_FUNC_OPT(name, bytes) \
    p_##name = (t_##name)GetProcAddress(mss, #name); \
    if (!p_##name) p_##name = (t_##name)GetProcAddress(mss, MSS_DECORATE(name, bytes)); \
    if (!p_##name) printf("Not exported by this build, skipping what needs it: %s\n", #name);

/* These mirror the declarations in src/mss.h, which is what a consumer
 * compiles against; a divergence here hides a header defect from the harness
 * that is supposed to exercise it. */
typedef int (__stdcall *t_AIL_startup)(void);
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
/* v8+ export: the entry is _AIL_init_sample@8, emitted from the internal
 * symbol AIL_init_sample_v8, S32 AIL_init_sample(HSAMPLE, S32 format) */
typedef int (__stdcall *t_AIL_init_sample)(void*, int);
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

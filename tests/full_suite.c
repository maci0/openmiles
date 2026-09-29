#include "../deps/windows_stub.h"
#include <stdio.h>
#include <stdint.h>
#include <malloc.h>
#include "test_utils.h"

#define SMP_PLAYING 4

/* The result of a check, so it belongs on stdout with the rest of the report:
 * this harness prints PASSED and FAILED alike and a caller reading a piped run
 * sees every check, not only the ones that broke. */
#define TEST_ASSERT(cond, msg) \
    if (!(cond)) { \
        printf("FAILED: %s\n", msg); \
        return 1; \
    } else { \
        printf("PASSED: %s\n", msg); \
    }

static void __stdcall timer_cb(unsigned int user) {
    if (user) {
        *((volatile int*)(uintptr_t)user) = 1; /* NOLINT: user stores a truncated pointer via AIL_set_timer_user_data */
    }
}

typedef void (__stdcall *t_AIL_set_timer_user_data)(void*, unsigned int);
typedef unsigned int (__stdcall *t_AIL_set_timer_user)(void*, unsigned int);

int play_test_main(int argc, char** argv) {
    static const char* const SYNOPSIS = "[<wav> [<mid> [<sf2>]]]";
    static const char* const NOTES =
        "Drives the whole API surface in six sections. The three media\n"
        "arguments are positional and all optional: each defaults to the\n"
        "fixture under test_media/ next to the executable, which the build\n"
        "installs only when that directory is present in the tree.\n"
        "A section whose entry points this build does not export reports\n"
        "SKIPPED and the run continues.";

    char* pos[3];
    int code = 0;
    if (test_parse_args(argc, argv, pos, 3, SYNOPSIS, NOTES, &code) < 0) {
        return code;
    }
    /* Every positional is optional here, so the count is not read; what matters
     * is that a fourth argument was rejected above. */

    printf("--- OpenMiles Full API Suite ---\n");

    const char* wav_file = pos[0] ? pos[0] : "test_media/test.wav";
    const char* mid_file = pos[1] ? pos[1] : "test_media/test.mid";
    const char* sf2_file = pos[2] ? pos[2] : "test_media/test.sf2";

    HMODULE mss = LoadLibrary("mss32.dll");
    if (!mss) {
        fprintf(stderr, "Failed to load mss32.dll (Error %d)\n", (int)GetLastError());
        return 1;
    }

    t_AIL_startup p_AIL_startup;
    t_AIL_shutdown p_AIL_shutdown;
    t_AIL_set_redist_directory p_AIL_set_redist_directory;
    t_AIL_last_error p_AIL_last_error;
    t_AIL_get_preference p_AIL_get_preference;
    t_AIL_set_preference p_AIL_set_preference;
    t_AIL_open_digital_driver p_AIL_open_digital_driver;
    t_AIL_close_digital_driver p_AIL_close_digital_driver;
    t_AIL_set_digital_master_volume p_AIL_set_digital_master_volume;
    t_AIL_allocate_sample_handle p_AIL_allocate_sample_handle;
    t_AIL_release_sample_handle p_AIL_release_sample_handle;
    t_AIL_init_sample p_AIL_init_sample;
    t_AIL_set_sample_file p_AIL_set_sample_file;
    t_AIL_start_sample p_AIL_start_sample;
    t_AIL_stop_sample p_AIL_stop_sample;
    t_AIL_set_sample_volume p_AIL_set_sample_volume;
    t_AIL_sample_status p_AIL_sample_status;
    t_AIL_open_midi_driver p_AIL_open_midi_driver;
    t_AIL_close_midi_driver p_AIL_close_midi_driver;
    t_AIL_allocate_sequence_handle p_AIL_allocate_sequence_handle;
    t_AIL_release_sequence_handle p_AIL_release_sequence_handle;
    t_AIL_init_sequence p_AIL_init_sequence;
    t_AIL_start_sequence p_AIL_start_sequence;
    t_AIL_release_timer_handle p_AIL_release_timer_handle;
    t_AIL_DLS_load_file p_AIL_DLS_load_file;
    t_AIL_allocate_3D_sample_handle p_AIL_allocate_3D_sample_handle;
    t_AIL_release_3D_sample_handle p_AIL_release_3D_sample_handle;
    t_AIL_set_3D_position p_AIL_set_3D_position;
    t_AIL_set_listener_3D_position p_AIL_set_listener_3D_position;
    t_AIL_register_timer p_AIL_register_timer;
    t_AIL_set_timer_frequency p_AIL_set_timer_frequency;
    t_AIL_set_timer_user_data p_AIL_set_timer_user_data;
    t_AIL_set_timer_user p_AIL_set_timer_user;
    t_AIL_start_timer p_AIL_start_timer;
    t_AIL_stop_timer p_AIL_stop_timer;
    t_AIL_quick_startup p_AIL_quick_startup;
    t_AIL_quick_shutdown p_AIL_quick_shutdown;

    LOAD_FUNC_EX(AIL_startup, 0);
    LOAD_FUNC_EX(AIL_shutdown, 0);
    LOAD_FUNC_EX(AIL_set_redist_directory, 4);
    LOAD_FUNC_EX(AIL_last_error, 0);
    LOAD_FUNC_EX(AIL_get_preference, 4);
    LOAD_FUNC_EX(AIL_set_preference, 8);
    LOAD_FUNC_EX(AIL_open_digital_driver, 16);
    LOAD_FUNC_EX(AIL_close_digital_driver, 4);
    LOAD_FUNC_OPT(AIL_set_digital_master_volume, 8);
    LOAD_FUNC_EX(AIL_allocate_sample_handle, 4);
    LOAD_FUNC_EX(AIL_release_sample_handle, 4);
    /* The v8+ table keeps the export name; AIL_init_sample_v8 is the internal
     * Zig symbol the @8 entry is emitted from, and is never a PE export. */
    LOAD_FUNC_EX(AIL_init_sample, 8);
    LOAD_FUNC_EX(AIL_set_sample_file, 12);
    LOAD_FUNC_EX(AIL_start_sample, 4);
    LOAD_FUNC_EX(AIL_stop_sample, 4);
    LOAD_FUNC_OPT(AIL_set_sample_volume, 8);
    LOAD_FUNC_EX(AIL_sample_status, 4);
    /* The sequence surface is v6.1-v7.0 and AIL_open_midi_driver /
     * AIL_close_midi_driver are in no Miles export table, so section 4 runs
     * only against a build that has it. */
    LOAD_FUNC_OPT(AIL_open_midi_driver, 4);
    LOAD_FUNC_OPT(AIL_close_midi_driver, 4);
    LOAD_FUNC_OPT(AIL_allocate_sequence_handle, 4);
    LOAD_FUNC_OPT(AIL_release_sequence_handle, 4);
    LOAD_FUNC_OPT(AIL_init_sequence, 12);
    LOAD_FUNC_OPT(AIL_start_sequence, 4);
    LOAD_FUNC_OPT(AIL_DLS_load_file, 12);
    /* The 3D sample handle surface stops at 6.6, and the quick API at 7.0, so
     * sections 3 and 6 run only against a build that has them. */
    LOAD_FUNC_OPT(AIL_allocate_3D_sample_handle, 4);
    LOAD_FUNC_OPT(AIL_release_3D_sample_handle, 4);
    LOAD_FUNC_OPT(AIL_set_3D_position, 16);
    LOAD_FUNC_EX(AIL_set_listener_3D_position, 16);
    LOAD_FUNC_EX(AIL_register_timer, 4);
    LOAD_FUNC_EX(AIL_set_timer_frequency, 8);
    /* AIL_set_timer_user is the exported spelling and AIL_set_timer_user_data
     * is in no Miles export table, so the user word the callback reads is set
     * through the first where it exists and the second otherwise. */
    LOAD_FUNC_OPT(AIL_set_timer_user_data, 8);
    LOAD_FUNC_EX(AIL_set_timer_user, 8);
    LOAD_FUNC_EX(AIL_start_timer, 4);
    LOAD_FUNC_EX(AIL_stop_timer, 4);
    LOAD_FUNC_EX(AIL_release_timer_handle, 4);
    LOAD_FUNC_OPT(AIL_quick_startup, 20);
    LOAD_FUNC_OPT(AIL_quick_shutdown, 0);

    printf("1. Core System Test\n");
    TEST_ASSERT(p_AIL_startup() != 0, "Startup");
    p_AIL_set_preference(1, 123);
    TEST_ASSERT(p_AIL_get_preference(1) == 123, "Preference set/get");

    printf("2. Digital Audio Test\n");
    void* dig = p_AIL_open_digital_driver(44100, 16, 2, 0);
    TEST_ASSERT(dig != NULL, "Open Digital Driver");
    if (p_AIL_set_digital_master_volume) p_AIL_set_digital_master_volume(dig, 100);

    void* S = p_AIL_allocate_sample_handle(dig);
    TEST_ASSERT(S != NULL, "Allocate Sample Handle");
    
    FILE* fwav = fopen(wav_file, "rb");
    TEST_ASSERT(fwav != NULL, "WAV file found");
    fseek(fwav, 0, SEEK_END);
    long sz = ftell(fwav);
    fseek(fwav, 0, SEEK_SET);
    void* wdata = malloc(sz);
    fread(wdata, 1, sz, fwav);
    fclose(fwav);
    TEST_ASSERT(p_AIL_init_sample(S, 0) == 1, "Init Sample");
    p_AIL_set_sample_file(S, wdata, (int)sz);
    p_AIL_start_sample(S);
    TEST_ASSERT(p_AIL_sample_status(S) == SMP_PLAYING, "Sample playing status");
    p_AIL_stop_sample(S);
    free(wdata);
    p_AIL_release_sample_handle(S);

    printf("3. 3D Audio Test\n");
    if (!p_AIL_allocate_3D_sample_handle || !p_AIL_release_3D_sample_handle ||
        !p_AIL_set_3D_position) {
        printf("SKIPPED: this build exports no 3D sample handle surface; test a -Dmss-version=50 to 66 build\n");
    } else {
        void* S3D = p_AIL_allocate_3D_sample_handle(dig);
        TEST_ASSERT(S3D != NULL, "Allocate 3D Sample Handle");
        p_AIL_set_3D_position(S3D, 10.0f, 0.0f, 5.0f);
        p_AIL_set_listener_3D_position(dig, 0.0f, 0.0f, 0.0f);
        p_AIL_release_3D_sample_handle(S3D);
    }

    printf("4. MIDI Test\n");
    void* midi = p_AIL_open_midi_driver ? p_AIL_open_midi_driver(0) : NULL;
    if (!midi || !p_AIL_allocate_sequence_handle || !p_AIL_init_sequence ||
        !p_AIL_start_sequence || !p_AIL_release_sequence_handle ||
        !p_AIL_DLS_load_file || !p_AIL_close_midi_driver) {
        printf("SKIPPED: this build exports no sequence surface; test a -Dmss-version=61 or 70 build\n");
    } else {
        TEST_ASSERT(midi != NULL, "Open MIDI Driver");
        TEST_ASSERT(p_AIL_DLS_load_file(midi, sf2_file, 0) != 0, "Load SoundFont");
        FILE* fm = fopen(mid_file, "rb");
        TEST_ASSERT(fm != NULL, "MIDI file found");
        fseek(fm, 0, SEEK_END);
        long msz = ftell(fm);
        fseek(fm, 0, SEEK_SET);
        void* mdata = malloc(msz);
        fread(mdata, 1, msz, fm);
        fclose(fm);
        void* seq = p_AIL_allocate_sequence_handle(midi);
        TEST_ASSERT(seq != NULL, "Allocate Sequence Handle");
        p_AIL_init_sequence(seq, mdata, (int)msz);
        p_AIL_start_sequence(seq);
        p_AIL_release_sequence_handle(seq);
        free(mdata);
        p_AIL_close_midi_driver(midi);
    }

    printf("5. Timer Test\n");
    volatile int timer_called = 0;
    void* T = p_AIL_register_timer(timer_cb);
    TEST_ASSERT(T != NULL, "Register Timer");
    p_AIL_set_timer_user(T, (unsigned int)(uintptr_t)&timer_called);
    p_AIL_set_timer_frequency(T, 100);
    p_AIL_start_timer(T);
    int timeout = 500; // 5 seconds max
    while (timer_called == 0 && timeout > 0) { Sleep(10); timeout--; }
    TEST_ASSERT(timer_called == 1, "Timer callback execution");
    p_AIL_release_timer_handle(T);

    printf("6. Quick API Test\n");
    if (!p_AIL_quick_startup || !p_AIL_quick_shutdown) {
        printf("SKIPPED: this build exports no quick API; test a -Dmss-version=30 to 70 build\n");
    } else {
        p_AIL_quick_startup(1, 0, 44100, 16, 2);
        TEST_ASSERT(p_AIL_get_preference(1) == 123, "Preference survives Quick API cycle");
        p_AIL_quick_shutdown();
    }

    p_AIL_close_digital_driver(dig);
    p_AIL_shutdown();
    FreeLibrary(mss);
    
    printf("\n--- ALL TESTS COMPLETED ---\n");
    return 0;
}

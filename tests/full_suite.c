#include "../deps/windows_stub.h"
#include <stdio.h>
#include <stdint.h>
#include <malloc.h>
#include "test_utils.h"

#define SMP_PLAYING 4

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

int play_test_main(int argc, char** argv) {
    printf("--- OpenMiles Full API Suite ---\n");
    
    const char* wav_file = (argc > 1) ? argv[1] : "test_media/test.wav";
    const char* mid_file = (argc > 2) ? argv[2] : "test_media/test.mid";
    const char* sf2_file = (argc > 3) ? argv[3] : "test_media/test.sf2";

    HMODULE mss = LoadLibrary("mss32.dll");
    if (!mss) {
        printf("Failed to load mss32.dll (Error %d)\n", (int)GetLastError());
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
    t_AIL_start_timer p_AIL_start_timer;
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
    LOAD_FUNC_EX(AIL_set_digital_master_volume, 8);
    LOAD_FUNC_EX(AIL_allocate_sample_handle, 4);
    LOAD_FUNC_EX(AIL_release_sample_handle, 4);
    LOAD_FUNC_EX(AIL_init_sample, 4);
    LOAD_FUNC_EX(AIL_set_sample_file, 12);
    LOAD_FUNC_EX(AIL_start_sample, 4);
    LOAD_FUNC_EX(AIL_stop_sample, 4);
    LOAD_FUNC_EX(AIL_set_sample_volume, 8);
    LOAD_FUNC_EX(AIL_sample_status, 4);
    LOAD_FUNC_EX(AIL_open_midi_driver, 4);
    LOAD_FUNC_EX(AIL_close_midi_driver, 4);
    LOAD_FUNC_EX(AIL_allocate_sequence_handle, 4);
    LOAD_FUNC_EX(AIL_release_sequence_handle, 4);
    LOAD_FUNC_EX(AIL_init_sequence, 12);
    LOAD_FUNC_EX(AIL_start_sequence, 4);
    LOAD_FUNC_EX(AIL_DLS_load_file, 12);
    LOAD_FUNC_EX(AIL_allocate_3D_sample_handle, 4);
    LOAD_FUNC_EX(AIL_release_3D_sample_handle, 4);
    LOAD_FUNC_EX(AIL_set_3D_position, 16);
    LOAD_FUNC_EX(AIL_set_listener_3D_position, 16);
    LOAD_FUNC_EX(AIL_register_timer, 4);
    LOAD_FUNC_EX(AIL_set_timer_frequency, 8);
    LOAD_FUNC_EX(AIL_set_timer_user_data, 8);
    LOAD_FUNC_EX(AIL_start_timer, 4);
    LOAD_FUNC_EX(AIL_release_timer_handle, 4);
    LOAD_FUNC_EX(AIL_quick_startup, 20);
    LOAD_FUNC_EX(AIL_quick_shutdown, 0);

    printf("1. Core System Test\n");
    p_AIL_startup();
    p_AIL_set_preference(1, 123);
    TEST_ASSERT(p_AIL_get_preference(1) == 123, "Preference set/get");

    printf("2. Digital Audio Test\n");
    void* dig = p_AIL_open_digital_driver(44100, 16, 2, 0);
    TEST_ASSERT(dig != NULL, "Open Digital Driver");
    p_AIL_set_digital_master_volume(dig, 100);

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
    p_AIL_set_sample_file(S, wdata, (int)sz);
    p_AIL_start_sample(S);
    TEST_ASSERT(p_AIL_sample_status(S) == SMP_PLAYING, "Sample playing status");
    p_AIL_stop_sample(S);
    free(wdata);
    p_AIL_release_sample_handle(S);

    printf("3. 3D Audio Test\n");
    void* S3D = p_AIL_allocate_3D_sample_handle(dig);
    TEST_ASSERT(S3D != NULL, "Allocate 3D Sample Handle");
    p_AIL_set_3D_position(S3D, 10.0f, 0.0f, 5.0f);
    p_AIL_set_listener_3D_position(dig, 0.0f, 0.0f, 0.0f);
    p_AIL_release_3D_sample_handle(S3D);

    printf("4. MIDI Test\n");
    void* midi = p_AIL_open_midi_driver(0);
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

    printf("5. Timer Test\n");
    volatile int timer_called = 0;
    void* T = p_AIL_register_timer(timer_cb);
    TEST_ASSERT(T != NULL, "Register Timer");
    p_AIL_set_timer_user_data(T, (unsigned int)(uintptr_t)&timer_called);
    p_AIL_set_timer_frequency(T, 100);
    p_AIL_start_timer(T);
    int timeout = 500; // 5 seconds max
    while (timer_called == 0 && timeout > 0) { Sleep(10); timeout--; }
    TEST_ASSERT(timer_called == 1, "Timer callback execution");
    p_AIL_release_timer_handle(T);

    printf("6. Quick API Test\n");
    p_AIL_quick_startup(1, 0, 44100, 16, 2);
    TEST_ASSERT(p_AIL_get_preference(1) == 123, "Preference survives Quick API cycle");
    p_AIL_quick_shutdown();

    p_AIL_close_digital_driver(dig);
    p_AIL_shutdown();
    FreeLibrary(mss);
    
    printf("\n--- ALL TESTS COMPLETED ---\n");
    return 0;
}

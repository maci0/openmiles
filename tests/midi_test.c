#include "../deps/windows_stub.h"
#include <stdio.h>
#include <malloc.h>
#include "test_utils.h"

int play_test_main(int argc, char** argv) {
    printf("OpenMiles MIDI Dynamic Test\n");
    
    if (argc < 3) {
        printf("Usage: %s <midi_file.mid> <soundfont.sf2>\n", argv[0]);
        return 1;
    }

    HMODULE mss = LoadLibrary("mss32.dll");
    if (!mss) {
        printf("Failed to load mss32.dll (Error %d)\n", (int)GetLastError());
        return 1;
    }

    t_AIL_startup p_AIL_startup;
    t_AIL_shutdown p_AIL_shutdown;
    t_AIL_open_digital_driver p_AIL_open_digital_driver;
    t_AIL_close_digital_driver p_AIL_close_digital_driver;
    t_AIL_open_midi_driver p_AIL_open_midi_driver;
    t_AIL_close_midi_driver p_AIL_close_midi_driver;
    t_AIL_allocate_sequence_handle p_AIL_allocate_sequence_handle;
    t_AIL_release_sequence_handle p_AIL_release_sequence_handle;
    t_AIL_init_sequence p_AIL_init_sequence;
    t_AIL_start_sequence p_AIL_start_sequence;
    t_AIL_stop_sequence p_AIL_stop_sequence;
    t_AIL_DLS_load_file p_AIL_DLS_load_file;

    LOAD_FUNC_EX(AIL_startup, 0);
    LOAD_FUNC_EX(AIL_shutdown, 0);
    LOAD_FUNC_EX(AIL_open_digital_driver, 16);
    LOAD_FUNC_EX(AIL_close_digital_driver, 4);
    LOAD_FUNC_EX(AIL_open_midi_driver, 4);
    LOAD_FUNC_EX(AIL_close_midi_driver, 4);
    LOAD_FUNC_EX(AIL_allocate_sequence_handle, 4);
    LOAD_FUNC_EX(AIL_release_sequence_handle, 4);
    LOAD_FUNC_EX(AIL_init_sequence, 12);
    LOAD_FUNC_EX(AIL_start_sequence, 4);
    LOAD_FUNC_EX(AIL_stop_sequence, 4);
    LOAD_FUNC_EX(AIL_DLS_load_file, 12);

    p_AIL_startup();
    
    void* dig = p_AIL_open_digital_driver(44100, 16, 2, 0);
    void* midi = p_AIL_open_midi_driver(0);
    if (!midi) {
        printf("Failed to open MIDI driver.\n");
        return 1;
    }

    printf("Loading SoundFont: %s\n", argv[2]);
    if (!p_AIL_DLS_load_file(midi, argv[2], 0)) {
        printf("Failed to load SoundFont.\n");
        return 1;
    }

    FILE* f = fopen(argv[1], "rb");
    if (!f) {
        printf("Failed to open MIDI file.\n");
        return 1;
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    void* data = malloc(size);
    fread(data, 1, size, f);
    fclose(f);

    void* seq = p_AIL_allocate_sequence_handle(midi);
    if (!seq) {
        printf("FAILED: Allocate Sequence Handle returned NULL\n");
        free(data);
        p_AIL_close_midi_driver(midi);
        p_AIL_close_digital_driver(dig);
        p_AIL_shutdown();
        FreeLibrary(mss);
        return 1;
    }
    p_AIL_init_sequence(seq, data, (int)size);
    printf("Sequence initialized.\n");

    printf("Starting MIDI playback...\n");
    p_AIL_start_sequence(seq);

    p_AIL_stop_sequence(seq);
    p_AIL_release_sequence_handle(seq);
    p_AIL_close_midi_driver(midi);
    p_AIL_close_digital_driver(dig);
    p_AIL_shutdown();
    FreeLibrary(mss);
    
    free(data);
    printf("Test finished.\n");

    return 0;
}

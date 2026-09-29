#include "../deps/windows_stub.h"
#include <stdio.h>
#include <malloc.h>
#include "test_utils.h"

int play_test_main(int argc, char** argv) {
    static const char* const SYNOPSIS = "<midi_file.mid> <soundfont.sf2>";
    static const char* const NOTES =
        "Loads the SoundFont into the MIDI driver and runs the MIDI file\n"
        "through the sequence API. The sequence surface is v6.1-v7.0 only, so\n"
        "a build outside that range reports SKIPPED and exits 0 rather than\n"
        "failing. The harness loads mss32.dll from the directory it is in, so\n"
        "run it from zig-out/bin next to the DLL.";

    char* pos[2];
    int code = 0;
    int n = test_parse_args(argc, argv, pos, 2, SYNOPSIS, NOTES, &code);
    if (n < 0) {
        return code;
    }
    if (n < 2) {
        fprintf(stderr, "error: <midi_file.mid> and <soundfont.sf2> are both required\n");
        test_usage(stderr, argv[0], SYNOPSIS, NOTES);
        return 2;
    }

    printf("OpenMiles MIDI Dynamic Test\n");

    HMODULE mss = LoadLibrary("mss32.dll");
    if (!mss) {
        fprintf(stderr, "Failed to load mss32.dll (Error %d)\n", (int)GetLastError());
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
    /* The whole sequence surface this test drives is v6.1-v7.0: an 8.0 or 9.0
     * build exports none of it, and AIL_open_midi_driver / AIL_close_midi_driver
     * are in no Miles export table under any version (the XMIDI-spelled pair is
     * the exported one, and only to 7.0). So this is a skip on a later build,
     * not a failure. */
    LOAD_FUNC_OPT(AIL_open_midi_driver, 4);
    LOAD_FUNC_OPT(AIL_close_midi_driver, 4);
    LOAD_FUNC_OPT(AIL_allocate_sequence_handle, 4);
    LOAD_FUNC_OPT(AIL_release_sequence_handle, 4);
    LOAD_FUNC_OPT(AIL_init_sequence, 12);
    LOAD_FUNC_OPT(AIL_start_sequence, 4);
    LOAD_FUNC_OPT(AIL_stop_sequence, 4);
    LOAD_FUNC_OPT(AIL_DLS_load_file, 12);

    if (!p_AIL_open_midi_driver || !p_AIL_allocate_sequence_handle ||
        !p_AIL_init_sequence || !p_AIL_start_sequence || !p_AIL_stop_sequence ||
        !p_AIL_release_sequence_handle || !p_AIL_DLS_load_file ||
        !p_AIL_close_midi_driver) {
        printf("SKIPPED: this build exports no sequence surface; test a -Dmss-version=61 or 70 build\n");
        FreeLibrary(mss);
        return 0;
    }

    p_AIL_startup();
    
    void* dig = p_AIL_open_digital_driver(44100, 16, 2, 0);
    void* midi = p_AIL_open_midi_driver(0);
    if (!midi) {
        fprintf(stderr, "Failed to open MIDI driver.\n");
        p_AIL_close_digital_driver(dig);
        p_AIL_shutdown();
        FreeLibrary(mss);
        return 1;
    }

    printf("Loading SoundFont: %s\n", pos[1]);
    if (!p_AIL_DLS_load_file(midi, pos[1], 0)) {
        fprintf(stderr, "Failed to open SoundFont: %s\n", pos[1]);
        p_AIL_close_midi_driver(midi);
        p_AIL_close_digital_driver(dig);
        p_AIL_shutdown();
        FreeLibrary(mss);
        return 1;
    }

    FILE* f = fopen(pos[0], "rb");
    if (!f) {
        fprintf(stderr, "Failed to open MIDI file: %s\n", pos[0]);
        p_AIL_close_midi_driver(midi);
        p_AIL_close_digital_driver(dig);
        p_AIL_shutdown();
        FreeLibrary(mss);
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
        fprintf(stderr, "FAILED: Allocate Sequence Handle returned NULL\n");
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

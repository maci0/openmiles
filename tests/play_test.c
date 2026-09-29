#include "../deps/windows_stub.h"
#include <stdio.h>
#include "test_utils.h"

int play_test_main(int argc, char** argv) {
    static const char* const SYNOPSIS = "<audio_file.wav>";
    static const char* const NOTES =
        "Opens the given audio file through the stream API and plays it. The\n"
        "harness loads mss32.dll from the directory it is in, so run it from\n"
        "zig-out/bin next to the DLL and the ./plugins directory.";

    char* pos[1];
    int code = 0;
    int n = test_parse_args(argc, argv, pos, 1, SYNOPSIS, NOTES, &code);
    if (n < 0) {
        return code;
    }
    if (n < 1) {
        fprintf(stderr, "error: missing <audio_file.wav>\n");
        test_usage(stderr, argv[0], SYNOPSIS, NOTES);
        return 2;
    }

    printf("OpenMiles Dynamic Play Test\n");

    HMODULE mss = LoadLibrary("mss32.dll");
    if (!mss) {
        fprintf(stderr, "Failed to load mss32.dll (Error %d)\n", (int)GetLastError());
        return 1;
    }

    t_AIL_startup p_AIL_startup;
    t_AIL_shutdown p_AIL_shutdown;
    t_AIL_set_redist_directory p_AIL_set_redist_directory;
    t_AIL_last_error p_AIL_last_error;
    t_AIL_open_digital_driver p_AIL_open_digital_driver;
    t_AIL_close_digital_driver p_AIL_close_digital_driver;
    t_AIL_open_stream p_AIL_open_stream;
    t_AIL_close_stream p_AIL_close_stream;
    t_AIL_start_stream p_AIL_start_stream;

    LOAD_FUNC_EX(AIL_startup, 0);
    LOAD_FUNC_EX(AIL_shutdown, 0);
    LOAD_FUNC_EX(AIL_set_redist_directory, 4);
    LOAD_FUNC_EX(AIL_last_error, 0);
    LOAD_FUNC_EX(AIL_open_digital_driver, 16);
    LOAD_FUNC_EX(AIL_close_digital_driver, 4);
    LOAD_FUNC_EX(AIL_open_stream, 12);
    LOAD_FUNC_EX(AIL_close_stream, 4);
    LOAD_FUNC_EX(AIL_start_stream, 4);

    p_AIL_startup();
    printf("AIL started up.\n");

    void* dig = p_AIL_open_digital_driver(44100, 16, 2, 0);
    if (!dig) {
        fprintf(stderr, "Failed to open digital driver: %s\n", p_AIL_last_error());
        return 1;
    }
    printf("Digital driver opened.\n");

    p_AIL_set_redist_directory("./plugins");

    void* stream = p_AIL_open_stream(dig, pos[0], 0);
    if (!stream) {
        fprintf(stderr, "Failed to open stream: %s\n", p_AIL_last_error());
        p_AIL_close_digital_driver(dig);
        p_AIL_shutdown();
        return 1;
    }

    printf("Starting playback...\n");
    p_AIL_start_stream(stream);

    p_AIL_close_stream(stream);
    p_AIL_close_digital_driver(dig);
    p_AIL_shutdown();
    FreeLibrary(mss);
    printf("Test finished.\n");

    return 0;
}

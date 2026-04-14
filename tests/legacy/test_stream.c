#include <windows.h>
#include <stdio.h>

typedef void* HDIGDRIVER;
typedef void* HSTREAM;

typedef HDIGDRIVER (__stdcall *AIL_waveOutOpen_t)(HDIGDRIVER*, int*, int, void*);
typedef HSTREAM (__stdcall *AIL_open_stream_t)(HDIGDRIVER, const char*, int);
typedef void (__stdcall *AIL_start_stream_t)(HSTREAM);
typedef int (__stdcall *AIL_stream_status_t)(HSTREAM);
typedef void (__stdcall *AIL_close_stream_t)(HSTREAM);
typedef void (__stdcall *AIL_shutdown_t)(void);
typedef void (__stdcall *AIL_startup_t)(void);

int main() {
    HMODULE mss = LoadLibraryA("Guild/mss32.dll");
    if (!mss) { printf("Failed to load mss32.dll\n"); return 1; }

    AIL_startup_t AIL_startup = (AIL_startup_t)GetProcAddress(mss, "_AIL_startup@0");
    AIL_waveOutOpen_t AIL_waveOutOpen = (AIL_waveOutOpen_t)GetProcAddress(mss, "_AIL_waveOutOpen@16");
    AIL_open_stream_t AIL_open_stream = (AIL_open_stream_t)GetProcAddress(mss, "_AIL_open_stream@12");
    AIL_start_stream_t AIL_start_stream = (AIL_start_stream_t)GetProcAddress(mss, "_AIL_start_stream@4");
    AIL_stream_status_t AIL_stream_status = (AIL_stream_status_t)GetProcAddress(mss, "_AIL_stream_status@4");
    AIL_close_stream_t AIL_close_stream = (AIL_close_stream_t)GetProcAddress(mss, "_AIL_close_stream@4");
    AIL_shutdown_t AIL_shutdown = (AIL_shutdown_t)GetProcAddress(mss, "_AIL_shutdown@0");

    AIL_startup();
    HDIGDRIVER driver = NULL;
    AIL_waveOutOpen(&driver, NULL, 0, NULL);
    
    HSTREAM stream = AIL_open_stream(driver, "Guild/msx/CD1/AufDemBall.mp3", 0);
    if (!stream) { printf("Failed to open stream\n"); return 1; }
    
    printf("Stream opened! Starting...\n");
    AIL_start_stream(stream);
    
    for (int i=0; i<10; i++) {
        printf("Status: %d\n", AIL_stream_status(stream));
        Sleep(100);
    }
    
    AIL_close_stream(stream);
    AIL_shutdown();
    printf("Done\n");
    return 0;
}

#include <windows.h>
#include <stdio.h>

typedef void* HDIGDRIVER;
typedef int (__stdcall *AIL_waveOutOpen_t)(HDIGDRIVER*, HWAVEOUT*, int, WAVEFORMATEX*);
typedef void (__stdcall *AIL_startup_t)(void);

int main() {
    HMODULE mss = LoadLibraryA("Guild/mss_backup/mss32.dll");
    if (!mss) return 1;

    AIL_startup_t AIL_startup = (AIL_startup_t)GetProcAddress(mss, "_AIL_startup@0");
    AIL_waveOutOpen_t AIL_waveOutOpen = (AIL_waveOutOpen_t)GetProcAddress(mss, "_AIL_waveOutOpen@16");
    
    AIL_startup();

    HDIGDRIVER driver = NULL;
    WAVEFORMATEX fmt = {0};
    AIL_waveOutOpen(&driver, NULL, 0, &fmt);
    
    printf("Format: channels=%d, rate=%d, bits=%d, tag=%d\n", fmt.nChannels, fmt.nSamplesPerSec, fmt.wBitsPerSample, fmt.wFormatTag);
    return 0;
}

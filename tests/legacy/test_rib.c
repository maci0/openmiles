#include <windows.h>
#include <stdio.h>

typedef void* HPROVIDER;
typedef void (__stdcall *AIL_startup_t)(void);
typedef int (__stdcall *RIB_enumerate_providers_t)(const char*, void**, HPROVIDER*);

int main() {
    HMODULE mss = LoadLibraryA("Guild/mss_backup/mss32.dll");
    if (!mss) { printf("Failed to load mss32.dll\n"); return 1; }

    AIL_startup_t AIL_startup = (AIL_startup_t)GetProcAddress(mss, "_AIL_startup@0");
    RIB_enumerate_providers_t RIB_enum = (RIB_enumerate_providers_t)GetProcAddress(mss, "_RIB_enumerate_providers@12");
    
    AIL_startup();

    void* next = NULL;
    HPROVIDER prov = NULL;
    while (RIB_enum("ASI codec", &next, &prov)) {
        printf("Found ASI provider: %p\n", prov);
    }
    
    return 0;
}

#include "../deps/windows_stub.h"
#include <stdio.h>
#include "test_utils.h"

typedef int (__stdcall *t_AIL_enumerate_filters)(void** next, void** dest, char** name);
typedef void* (__stdcall *t_AIL_ASI_provider_attribute)(void* provider, const char* name);

int play_test_main(int argc, char** argv) {
    printf("--- OpenMiles RIB/ASI Test ---\n");
    
    HMODULE mss = LoadLibrary("mss32.dll");
    if (!mss) {
        printf("Failed to load mss32.dll\n");
        return 1;
    }

    t_AIL_startup p_AIL_startup;
    t_AIL_shutdown p_AIL_shutdown;
    t_AIL_set_redist_directory p_AIL_set_redist_directory;
    t_AIL_enumerate_filters p_AIL_enumerate_filters;
    t_AIL_ASI_provider_attribute p_AIL_ASI_provider_attribute;

    LOAD_FUNC_EX(AIL_startup, 0);
    LOAD_FUNC_EX(AIL_shutdown, 0);
    LOAD_FUNC_EX(AIL_set_redist_directory, 4);
    LOAD_FUNC_EX(AIL_enumerate_filters, 12);
    LOAD_FUNC_EX(AIL_ASI_provider_attribute, 8);

    p_AIL_startup();

    printf("Scanning './plugins' for ASI providers...\n");
    p_AIL_set_redist_directory("./plugins");

    void* next = NULL;
    void* dest = NULL;
    char* name = NULL;

    int count = 0;
    while (p_AIL_enumerate_filters(&next, &dest, &name)) {
        if (!name) {
            printf("FAILED: Provider returned NULL name\n");
            p_AIL_shutdown();
            FreeLibrary(mss);
            return 1;
        }
        printf("Found Filter/ASI Provider: %s\n", name);

        // Try to get an attribute
        void* attr = p_AIL_ASI_provider_attribute(dest, "Input data type");
        if (attr) {
            printf("  'Input data type' token: %p\n", attr);
        }
        count++;
    }

    printf("Total providers found: %d\n", count);
    if (count == 0) {
        printf("FAILED: No ASI providers found (expected at least 1 in ./plugins)\n");
        p_AIL_shutdown();
        FreeLibrary(mss);
        return 1;
    }

    printf("PASSED: Found %d ASI provider(s)\n", count);
    p_AIL_shutdown();
    FreeLibrary(mss);
    return 0;
}

#include "../../deps/windows_stub.h"

typedef int S32;
typedef unsigned int U32;

typedef void* HPROVIDER;
typedef void* (*RIB_alloc_provider_handle_ptr)(S32 module);
typedef size_t (*RIB_register_interface_ptr)(HPROVIDER provider, const char* name, S32 count, void* entries);
typedef void (*RIB_unregister_interface_ptr)(size_t handle);

typedef struct {
    U32 entry_type;
    const char* name;
    size_t token;
    U32 subtype;
} RIB_INTERFACE_ENTRY;

static RIB_INTERFACE_ENTRY ASI_entries[] = {
    { 1, "Input data type", 0x1234, 0 }
};

// What reg() handed back, kept so the shutdown path can unregister it: a real
// Miles plugin does the same, and it is the only way the host's unregister
// callback is reached at all.
static size_t ASI_handle = 0;

__declspec(dllexport) S32 __stdcall RIB_Main(HPROVIDER provider, U32 up_down, RIB_alloc_provider_handle_ptr alloc, RIB_register_interface_ptr reg, RIB_unregister_interface_ptr unreg) {
    (void)alloc;
    if (up_down) {
        ASI_handle = reg(provider, "ASI digital audio engine", 1, ASI_entries);
    } else if (ASI_handle) {
        unreg(ASI_handle);
        ASI_handle = 0;
    }
    return 1;
}

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved) {
    (void)hinstDLL;
    (void)fdwReason;
    (void)lpvReserved;
    return TRUE;
}

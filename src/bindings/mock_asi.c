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

__declspec(dllexport) S32 __stdcall RIB_Main(HPROVIDER provider, U32 up_down, RIB_alloc_provider_handle_ptr alloc, RIB_register_interface_ptr reg, RIB_unregister_interface_ptr unreg) {
    if (up_down) {
        reg(provider, "ASI digital audio engine", 1, ASI_entries);
    }
    return 1;
}

BOOL WINAPI DllMain(HINSTANCE hinstDLL, DWORD fdwReason, LPVOID lpvReserved) {
    return TRUE;
}

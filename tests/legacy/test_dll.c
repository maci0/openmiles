#include <windows.h>
#include <stdio.h>

int main() {
    HMODULE mss = LoadLibrary("Guild/mss32.dll");
    if (!mss) {
        printf("Failed to load mss32.dll\n");
        return 1;
    }
    
    void (*startup)() = (void (*)(void))GetProcAddress(mss, "_AIL_startup@0");
    if (!startup) {
        printf("Failed to find _AIL_startup@0\n");
        return 1;
    }
    
    printf("Calling _AIL_startup@0\n");
    startup();
    printf("Returned from _AIL_startup@0\n");

    return 0;
}

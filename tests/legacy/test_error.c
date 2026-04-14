#include <windows.h>
#include <stdio.h>

typedef const char* (__stdcall *AIL_last_error_t)(void);

int main() {
    HMODULE mss = LoadLibraryA("Guild/mss_backup/mss32.dll");
    if (!mss) { printf("Failed to load mss32.dll\n"); return 1; }

    AIL_last_error_t AIL_last_error = (AIL_last_error_t)GetProcAddress(mss, "_AIL_last_error@0");
    if (!AIL_last_error) { printf("Failed to get AIL_last_error\n"); return 1; }

    const char* err = AIL_last_error();
    if (err) {
        printf("AIL_last_error: '%s'\n", err);
    } else {
        printf("AIL_last_error: NULL\n");
    }

    return 0;
}

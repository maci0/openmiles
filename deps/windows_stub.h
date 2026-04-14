#ifndef WINDOWS_STUB_H
#define WINDOWS_STUB_H

// Minimal stub to allow C tests to compile on Linux via zig cc without requiring full mingw windows.h
#ifdef _WIN32
#include <windows.h>
#else

#include <stddef.h>

#define __stdcall
#define WINAPI
#define __declspec(x)

typedef void* HMODULE;
typedef void* HINSTANCE;
typedef void* LPVOID;
typedef unsigned int DWORD;
typedef int BOOL;

#ifndef TRUE
#define TRUE 1
#endif
#ifndef FALSE
#define FALSE 0
#endif

#define LoadLibrary(x) ((void*)1)
#define GetProcAddress(x, y) ((void*)0)
#define GetLastError() 0
#define FreeLibrary(x)
#define Sleep(x)

#endif

#endif
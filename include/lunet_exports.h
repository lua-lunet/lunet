/*
 * lunet_exports.h - shared-library export helpers
 *
 * We only need explicit dllexport for Windows so that LuaJIT can locate
 * luaopen_lunet via GetProcAddress when loading lunet.dll.
 */
#ifndef LUNET_EXPORTS_H
#define LUNET_EXPORTS_H

#if defined(_WIN32) || defined(__CYGWIN__)
  #if defined(LUNET_BUILDING_DLL)
    #define LUNET_API __declspec(dllexport)
  #else
    #define LUNET_API
  #endif
#else
  #define LUNET_API
#endif

#endif /* LUNET_EXPORTS_H */

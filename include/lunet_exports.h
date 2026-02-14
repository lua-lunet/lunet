/*
 * lunet_exports.h - shared-library export helpers
 *
 * We only need explicit dllexport for Windows so that LuaJIT can locate
 * luaopen_lunet via GetProcAddress when loading lunet.dll.
 */
#ifndef LUNET_EXPORTS_H
#define LUNET_EXPORTS_H

#if defined(_WIN32) || defined(__CYGWIN__)
  /* Core shared library exports (liblunet). */
  #if defined(LUNET_BUILDING_CORE)
    #define LUNET_API __declspec(dllexport)
  #else
    #define LUNET_API
  #endif

  /* Lua C module exports (lunet/sqlite3.dll, lunet/mysql.dll, ...). */
  #if defined(LUNET_BUILDING_MODULE)
    #define LUNET_MODULE_API __declspec(dllexport)
  #else
    #define LUNET_MODULE_API
  #endif
#else
  #define LUNET_API
  #define LUNET_MODULE_API
#endif

#endif /* LUNET_EXPORTS_H */

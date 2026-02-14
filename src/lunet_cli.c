#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if !defined(_WIN32) && !defined(__CYGWIN__)
#include <pthread.h>
#endif
#include <uv.h>

#include "lunet_lua.h"
#include "lunet_exports.h"
#include "co.h"
#include "fs.h"
#include "lunet_signal.h"
#include "rt.h"
#include "socket.h"
#include "timer.h"
#include "udp.h"
#include "trace.h"
#include "runtime.h"
#include "lunet_mem.h"
#ifdef LUNET_PAXE
#include "paxe.h"
#endif

static char *lunet_resolve_executable_path(const char *argv0) {
#if defined(_WIN32)
  return _fullpath(NULL, argv0, 0);
#else
  return realpath(argv0, NULL);
#endif
}

/* Provided by the core lunet shared library. */
LUNET_API int luaopen_lunet(lua_State *L);

static void lunet_trace_shutdown(void) {
#if defined(LUNET_TRACE) || defined(LUNET_EASY_MEMORY)
    lunet_mem_summary();
#endif
#ifdef LUNET_TRACE
    lunet_socket_trace_summary();
    lunet_udp_trace_summary();
    lunet_timer_trace_summary();
    lunet_signal_trace_summary();
    lunet_fs_trace_summary();
    lunet_trace_dump();
    lunet_trace_assert_balanced("shutdown");
#endif
#if defined(LUNET_TRACE) || defined(LUNET_EASY_MEMORY)
    lunet_mem_assert_balanced("shutdown");
#endif
}

#ifndef LUNET_NO_MAIN
int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "Usage: %s [OPTIONS] <lua_file>\n", argv[0]);
    fprintf(stderr, "\nOptions:\n");
    fprintf(stderr, "  --dangerously-skip-loopback-restriction\n");
    fprintf(stderr, "      Allow binding to any network interface. By default, binding is restricted\n");
    fprintf(stderr, "      to loopback (127.0.0.1, ::1) or Unix sockets.\n");
    fprintf(stderr, "  --verbose-trace\n");
    fprintf(stderr, "      Enable verbose per-event tracing (debug builds only)\n");
    return 1;
  }

  int script_index = 0;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--dangerously-skip-loopback-restriction") == 0) {
      g_lunet_config.dangerously_skip_loopback_restriction = 1;
      fprintf(stderr, "WARNING: Loopback restriction disabled. Binding to public interfaces allowed.\n");
    } else if (strcmp(argv[i], "--verbose-trace") == 0) {
      // Handled at compile time currently via LUNET_TRACE_VERBOSE
      // Could be runtime flag in future
    } else if (argv[i][0] == '-') {
      fprintf(stderr, "Unknown option: %s\n", argv[i]);
      return 1;
    } else {
      script_index = i;
      break;
    }
  }

  if (script_index == 0) {
    fprintf(stderr, "Error: No script file specified.\n");
    return 1;
  }

  lua_State *L = luaL_newstate();
  luaL_openlibs(L);

  /* Load core module and register lunet.* submodules into package.preload. */
  luaopen_lunet(L);              /* stack: lunet */
  lua_pushvalue(L, -1);          /* stack: lunet lunet */
  lua_setglobal(L, "lunet");    /* stack: lunet */
  lua_getglobal(L, "package");  /* stack: lunet package */
  lua_getfield(L, -1, "loaded");/* stack: lunet package loaded */
  lua_pushvalue(L, -3);          /* stack: lunet package loaded lunet */
  lua_setfield(L, -2, "lunet"); /* package.loaded["lunet"] = lunet */
  lua_pop(L, 3);                 /* pop loaded, package, lunet */

  // Add binary's directory to cpath for finding driver .so files
  // Drivers are in same dir as binary, named like sqlite3.so, mysql.so
  // They're loaded as lunet.sqlite3, so we need lunet/?.so pattern
  // Create symlink-style lookup: binarydir/lunet/?.so -> binarydir/?.so
  {
    char *exe_path = lunet_resolve_executable_path(argv[0]);
    if (!exe_path) {
      goto cpath_done;
    }

    char *last_slash = strrchr(exe_path, '/');
    char *last_backslash = strrchr(exe_path, '\\');
    char *last_sep = last_slash;
    if (!last_sep || (last_backslash && last_backslash > last_sep)) {
      last_sep = last_backslash;
    }
    if (!last_sep) {
      free(exe_path);
      goto cpath_done;
    }

    *last_sep = '\0';

    lua_getglobal(L, "package");
    lua_getfield(L, -1, "cpath");
    const char *old_cpath = lua_tostring(L, -1);
    lua_pop(L, 1);

    char new_cpath[4096];
#if defined(_WIN32)
    snprintf(new_cpath, sizeof(new_cpath), "%s\\lunet\\?.dll;%s\\?.dll;%s",
             exe_path, exe_path, old_cpath ? old_cpath : "");
#else
    snprintf(new_cpath, sizeof(new_cpath), "%s/lunet/?.so;%s/?.so;%s",
             exe_path, exe_path, old_cpath ? old_cpath : "");
#endif
    lua_pushstring(L, new_cpath);
    lua_setfield(L, -2, "cpath");
    lua_pop(L, 1);

    free(exe_path);
  cpath_done:;
  }

  // run lua file
  if (luaL_dofile(L, argv[script_index]) != LUA_OK) {
    const char *error = lua_tostring(L, -1);
    fprintf(stderr, "Error: %s\n", error);
    lua_pop(L, 1);
    lua_close(L);
    return 1;
  }

  int ret = uv_run(uv_default_loop(), UV_RUN_DEFAULT);

  /* Optional: allow Lua script to control process exit status.
   * Used by stress tests so we can exit without os.exit() (which skips trace shutdown).
   */
  int lua_exit_code = -1;
  lua_getglobal(L, "__lunet_exit_code");
  if (lua_isnumber(L, -1)) {
    lua_exit_code = (int)lua_tointeger(L, -1);
  }
  lua_pop(L, 1);
  
  /* Dump trace statistics and assert balance */
  lunet_trace_shutdown();
  
  lua_close(L);

  {
    int loop_close_status = uv_loop_close(uv_default_loop());
    if (loop_close_status != 0) {
      fprintf(stderr, "[LUNET] uv_loop_close failed at shutdown: %s\n",
              uv_strerror(loop_close_status));
    }
#if UV_VERSION_HEX >= ((1 << 16) | (38 << 8) | 0)
    if (loop_close_status == 0) {
      uv_library_shutdown();
    }
#endif
  }
#if defined(LUNET_TRACE) || defined(LUNET_EASY_MEMORY)
  lunet_mem_shutdown();
#endif
  if (lua_exit_code >= 0) {
    return lua_exit_code;
  }
  return ret;
}
#endif

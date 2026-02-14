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
#include "embed_scripts.h"
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

lunet_runtime_config_t g_lunet_config = {0};

// register core module
int lunet_open_core(lua_State *L) {
  luaL_Reg funcs[] = {{"spawn", lunet_spawn}, {"sleep", lunet_sleep}, {NULL, NULL}};
  luaL_newlib(L, funcs);
  return 1;
}

int lunet_open_socket(lua_State *L) {
  luaL_Reg funcs[] = {{"listen", lunet_socket_listen},
                      {"accept", lunet_socket_accept},
                      {"getpeername", lunet_socket_getpeername},
                      {"close", lunet_socket_close},
                      {"read", lunet_socket_read},
                      {"write", lunet_socket_write},
                      {"connect", lunet_socket_connect},
                      {"set_read_buffer_size", lunet_socket_set_read_buffer_size},
                      {NULL, NULL}};
  luaL_newlib(L, funcs);
  return 1;
}

int lunet_open_udp(lua_State *L) {
  luaL_Reg funcs[] = {{"bind", lunet_udp_bind},
                      {"send", lunet_udp_send},
                      {"recv", lunet_udp_recv},
                      {"close", lunet_udp_close},
                      {NULL, NULL}};
  luaL_newlib(L, funcs);
  return 1;
}

int lunet_open_signal(lua_State *L) {
  luaL_Reg funcs[] = {{"wait", lunet_signal_wait}, {NULL, NULL}};
  luaL_newlib(L, funcs);
  return 1;
}

int lunet_open_fs(lua_State *L) {
  luaL_Reg funcs[] = {{"open", lunet_fs_open},
                      {"close", lunet_fs_close},
                      {"read", lunet_fs_read},
                      {"write", lunet_fs_write},
                      {"stat", lunet_fs_stat},
                      {"scandir", lunet_fs_scandir},
                      {NULL, NULL}};
  luaL_newlib(L, funcs);
  return 1;
}

// =============================================================================
// Database Driver Support
// =============================================================================
// Each driver defines LUNET_DB_DRIVER to its name (sqlite3, mysql, postgres).
// The driver module registers as lunet.<driver> and exports luaopen_lunet_<driver>.

#ifdef LUNET_HAS_DB
int lunet_db_open(lua_State* L);
int lunet_db_close(lua_State* L);
int lunet_db_query(lua_State* L);
int lunet_db_exec(lua_State* L);
int lunet_db_escape(lua_State* L);
int lunet_db_query_params(lua_State* L);
int lunet_db_exec_params(lua_State* L);

static int lunet_open_db(lua_State *L) {
  luaL_Reg funcs[] = {{"open", lunet_db_open},
                      {"close", lunet_db_close},
                      {"query", lunet_db_query},
                      {"exec", lunet_db_exec},
                      {"escape", lunet_db_escape},
                      {"query_params", lunet_db_query_params},
                      {"exec_params", lunet_db_exec_params},
                      {NULL, NULL}};
  luaL_newlib(L, funcs);
  return 1;
}
#endif

/*
 * Unified tracing initialization
 * Replaces the redundant calls scattered across functions
 */
static void lunet_init_once(void) {
    static int initialized = 0;
    if (initialized) return;
    initialized = 1;
    
    lunet_mem_init();
    lunet_trace_init();
}

// Driver-specific module entry points
#if defined(LUNET_DB_SQLITE3)
LUNET_API int luaopen_lunet_sqlite3(lua_State *L) {
  lunet_init_once();
  set_default_luaL(L);
  return lunet_open_db(L);
}
#endif

#if defined(LUNET_DB_MYSQL)
LUNET_API int luaopen_lunet_mysql(lua_State *L) {
  lunet_init_once();
  set_default_luaL(L);
  return lunet_open_db(L);
}
#endif

#if defined(LUNET_DB_POSTGRES)
LUNET_API int luaopen_lunet_postgres(lua_State *L) {
  lunet_init_once();
  set_default_luaL(L);
  return lunet_open_db(L);
}
#endif

#if defined(LUNET_PAXE)
LUNET_API int luaopen_lunet_paxe(lua_State *L) {
  lunet_init_once();
  set_default_luaL(L);
  lua_newtable(L);
  return lunet_open_paxe(L);
}
#endif

// register modules
void lunet_open(lua_State *L) {
  // register core module
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, lunet_open_core);
  lua_setfield(L, -2, "lunet");
  lua_pop(L, 2);
  // register socket module
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, lunet_open_socket);
  lua_setfield(L, -2, "lunet.socket");
  lua_pop(L, 2);
  // register udp module
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, lunet_open_udp);
  lua_setfield(L, -2, "lunet.udp");
  lua_pop(L, 2);
  // register signal module
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, lunet_open_signal);
  lua_setfield(L, -2, "lunet.signal");
  lua_pop(L, 2);
  // register fs module
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, lunet_open_fs);
  lua_setfield(L, -2, "lunet.fs");
  lua_pop(L, 2);

  // Database drivers register themselves via luaopen_lunet_<driver>
  // No generic lunet.db registration here - each driver is a separate module
}

/**
 * Module entry point for require("lunet")
 * 
 * This function is called when lunet is loaded as a C module via LuaRocks.
 * It initializes the runtime, registers all submodules in package.preload,
 * and returns the core module table.
 * 
 * Usage from Lua:
 *   local lunet = require("lunet")
 *   lunet.spawn(function() ... end)
 */
LUNET_API int luaopen_lunet(lua_State *L) {
  lunet_init_once();
  set_default_luaL(L);
  lunet_open(L);  // Register submodules in package.preload
  return lunet_open_core(L);  // Return core module table
}

static void lunet_trace_shutdown(void) {
#ifdef LUNET_TRACE
    lunet_mem_summary();
    lunet_socket_trace_summary();
    lunet_udp_trace_summary();
    lunet_timer_trace_summary();
    lunet_signal_trace_summary();
    lunet_fs_trace_summary();
    lunet_trace_dump();
    lunet_trace_assert_balanced("shutdown");
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

#ifdef LUNET_EMBED_SCRIPTS
  char embedded_root[LUNET_EMBED_PATH_MAX] = {0};
  char embedded_script[LUNET_EMBED_PATH_MAX] = {0};
  char embed_error[512] = {0};
#endif

  /* Initialize tracing */
  lunet_init_once();

  lua_State *L = luaL_newstate();
  luaL_openlibs(L);
  set_default_luaL(L);
  lunet_open(L);

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

  const char *script_to_run = argv[script_index];
#ifdef LUNET_EMBED_SCRIPTS
  if (lunet_embed_scripts_prepare(L,
                                  embedded_root,
                                  sizeof(embedded_root),
                                  embed_error,
                                  sizeof(embed_error)) != 0) {
    fprintf(stderr, "Error: failed to prepare embedded scripts: %s\n", embed_error);
    lua_close(L);
    return 1;
  }

  {
    int resolved = lunet_embed_scripts_resolve_script(embedded_root,
                                                      script_to_run,
                                                      embedded_script,
                                                      sizeof(embedded_script),
                                                      embed_error,
                                                      sizeof(embed_error));
    if (resolved < 0) {
      fprintf(stderr, "Error: failed to resolve embedded script path: %s\n", embed_error);
      lua_close(L);
      return 1;
    }
    if (resolved > 0) {
      script_to_run = embedded_script;
    }
  }
#endif

  // run lua file
  if (luaL_dofile(L, script_to_run) != LUA_OK) {
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
  if (lua_exit_code >= 0) {
    return lua_exit_code;
  }
  return ret;
}
#endif

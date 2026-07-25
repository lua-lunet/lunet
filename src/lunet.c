#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

#include "lunet.h"
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

#ifdef LUNET_HTTPC
#include "httpc.h"
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
int lunet_db_query_params(lua_State* L);
int lunet_db_exec_params(lua_State* L);

static int lunet_open_db(lua_State *L) {
  luaL_Reg funcs[] = {{"open", lunet_db_open},
                      {"close", lunet_db_close},
                      {"query", lunet_db_query},
                      {"exec", lunet_db_exec},
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

#if defined(LUNET_HTTPC)
LUNET_API int luaopen_lunet_httpc(lua_State *L) {
  lunet_init_once();
  set_default_luaL(L);
  return lunet_open_httpc(L);
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

struct lunet_runtime {
  lua_State *L;
  int has_run;
  char embedded_root[LUNET_EMBED_PATH_MAX];
};

static lunet_runtime_t *g_active_runtime = NULL;
static int g_runtime_consumed = 0;

static void lunet_runtime_set_error(char *error, size_t error_len, const char *fmt, ...) {
  va_list ap;
  if (!error || error_len == 0 || !fmt) {
    return;
  }
  va_start(ap, fmt);
  vsnprintf(error, error_len, fmt, ap);
  va_end(ap);
}

static void lunet_runtime_configure_cpath(lua_State *L, const char *executable_path) {
  char *resolved_path;
  char *last_slash;
  char *last_backslash;
  char *last_sep;
  const char *old_cpath;
  char new_cpath[4096];
  int written;

  if (!L || !executable_path || executable_path[0] == '\0') {
    return;
  }
  resolved_path = lunet_resolve_executable_path(executable_path);
  if (!resolved_path) {
    return;
  }
  last_slash = strrchr(resolved_path, '/');
  last_backslash = strrchr(resolved_path, '\\');
  last_sep = last_slash;
  if (!last_sep || (last_backslash && last_backslash > last_sep)) {
    last_sep = last_backslash;
  }
  if (!last_sep) {
    free(resolved_path);
    return;
  }
  *last_sep = '\0';
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "cpath");
  old_cpath = lua_tostring(L, -1);
  lua_pop(L, 1);
#if defined(_WIN32)
  written = snprintf(new_cpath, sizeof(new_cpath), "%s\\lunet\\?.dll;%s\\?.dll;%s",
                     resolved_path, resolved_path, old_cpath ? old_cpath : "");
#else
  written = snprintf(new_cpath, sizeof(new_cpath), "%s/lunet/?.so;%s/?.so;%s",
                     resolved_path, resolved_path, old_cpath ? old_cpath : "");
#endif
  if (written < 0 || (size_t)written >= sizeof(new_cpath)) {
    /* A truncated cpath would silently break module loading; keep the default. */
    fprintf(stderr, "[LUNET] warning: executable path too long, package.cpath unchanged\n");
    lua_pop(L, 1);
    free(resolved_path);
    return;
  }
  lua_pushstring(L, new_cpath);
  lua_setfield(L, -2, "cpath");
  lua_pop(L, 1);
  free(resolved_path);
}

static int lunet_runtime_run_path(lunet_runtime_t *runtime,
                                  const char *script_path,
                                  int *exit_code,
                                  char *error,
                                  size_t error_len) {
  int loop_result;
  int lua_exit_code = -1;
  const char *lua_error;

  if (!runtime || runtime != g_active_runtime || !runtime->L || !script_path ||
      script_path[0] == '\0' || !exit_code) {
    lunet_runtime_set_error(error, error_len, "invalid runtime or script path");
    return -1;
  }
  if (runtime->has_run) {
    lunet_runtime_set_error(error, error_len, "a Lunet runtime can run only one application");
    return -1;
  }
  runtime->has_run = 1;
  if (luaL_dofile(runtime->L, script_path) != LUA_OK) {
    lua_error = lua_tostring(runtime->L, -1);
    lunet_runtime_set_error(error, error_len, "%s", lua_error ? lua_error : "Lua execution failed");
    lua_pop(runtime->L, 1);
    return -1;
  }
  loop_result = uv_run(uv_default_loop(), UV_RUN_DEFAULT);
  lua_getglobal(runtime->L, "__lunet_exit_code");
  if (lua_isnumber(runtime->L, -1)) {
    lua_exit_code = (int)lua_tointeger(runtime->L, -1);
  }
  lua_pop(runtime->L, 1);
  *exit_code = lua_exit_code >= 0 ? lua_exit_code : loop_result;
  return 0;
}

int lunet_runtime_init(lunet_runtime_t **out_runtime,
                       const lunet_runtime_options_t *options,
                       char *error,
                       size_t error_len) {
  lunet_runtime_t *runtime;

  if (!out_runtime) {
    lunet_runtime_set_error(error, error_len, "out_runtime is required");
    return -1;
  }
  *out_runtime = NULL;
  if (g_active_runtime || g_runtime_consumed) {
    lunet_runtime_set_error(error, error_len, "only one Lunet runtime is supported per process");
    return -1;
  }
  runtime = (lunet_runtime_t *)calloc(1, sizeof(*runtime));
  if (!runtime) {
    lunet_runtime_set_error(error, error_len, "out of memory");
    return -1;
  }
  lunet_init_once();
  runtime->L = luaL_newstate();
  if (!runtime->L) {
    free(runtime);
    lunet_runtime_set_error(error, error_len, "failed to create Lua state");
    return -1;
  }
  g_lunet_config.dangerously_skip_loopback_restriction =
      options && options->dangerously_skip_loopback_restriction ? 1 : 0;
  luaL_openlibs(runtime->L);
  set_default_luaL(runtime->L);
  lunet_open(runtime->L);
  lunet_runtime_configure_cpath(runtime->L, options ? options->executable_path : NULL);
  g_active_runtime = runtime;
  g_runtime_consumed = 1;
  *out_runtime = runtime;
  return 0;
}

int lunet_runtime_run_file(lunet_runtime_t *runtime,
                           const char *script_path,
                           int *exit_code,
                           char *error,
                           size_t error_len) {
  return lunet_runtime_run_path(runtime, script_path, exit_code, error, error_len);
}

int lunet_runtime_run_embedded(lunet_runtime_t *runtime,
                               const unsigned char *blob,
                               size_t blob_len,
                               const char *entry_script,
                               int *exit_code,
                               char *error,
                               size_t error_len) {
  char embedded_root[LUNET_EMBED_PATH_MAX] = {0};
  char embedded_script[LUNET_EMBED_PATH_MAX] = {0};
  int resolved;

  if (!runtime || runtime != g_active_runtime || !blob || blob_len == 0 ||
      !entry_script || entry_script[0] == '\0') {
    lunet_runtime_set_error(error, error_len, "invalid runtime, embedded blob, or entry script");
    return -1;
  }
  if (lunet_embed_scripts_validate_relative_path(entry_script, error, error_len) != 0) {
    return -1;
  }
  if (runtime->has_run) {
    lunet_runtime_set_error(error, error_len, "a Lunet runtime can run only one application");
    return -1;
  }
  if (lunet_embed_scripts_prepare(runtime->L, blob, blob_len, embedded_root,
                                  sizeof(embedded_root), error, error_len) != 0) {
    return -1;
  }
  resolved = lunet_embed_scripts_resolve_script(embedded_root, entry_script,
                                                embedded_script, sizeof(embedded_script),
                                                error, error_len);
  if (resolved < 0) {
    lunet_embed_scripts_cleanup(embedded_root);
    return -1;
  }
  if (resolved == 0) {
    lunet_runtime_set_error(error, error_len, "embedded entry script not found: %s", entry_script);
    lunet_embed_scripts_cleanup(embedded_root);
    return -1;
  }
  snprintf(runtime->embedded_root, sizeof(runtime->embedded_root), "%s", embedded_root);
  return lunet_runtime_run_path(runtime, embedded_script, exit_code, error, error_len);
}

void lunet_runtime_shutdown(lunet_runtime_t *runtime) {
  int loop_close_status;
  if (!runtime || runtime != g_active_runtime) {
    return;
  }
  lunet_trace_shutdown();
  lua_close(runtime->L);
  lunet_embed_scripts_cleanup(runtime->embedded_root);
  set_default_luaL(NULL);
  loop_close_status = uv_loop_close(uv_default_loop());
  if (loop_close_status != 0) {
    fprintf(stderr, "[LUNET] uv_loop_close failed at shutdown: %s\n", uv_strerror(loop_close_status));
  }
#if UV_VERSION_HEX >= ((1 << 16) | (38 << 8) | 0)
  if (loop_close_status == 0) {
    uv_library_shutdown();
  }
#endif
#if defined(LUNET_TRACE) || defined(LUNET_EASY_MEMORY)
  lunet_mem_shutdown();
#endif
  g_active_runtime = NULL;
  free(runtime);
}

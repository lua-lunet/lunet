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
#include "trace.h"
#include "runtime.h"

#ifdef LUNET_HAS_UDP
#include "lunet_udp.h"
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

#ifdef LUNET_HAS_UDP
static int lunet_open_udp(lua_State *L) {
  luaL_Reg funcs[] = {{"bind", lunet_udp_bind},
                      {"send", lunet_udp_send},
                      {"recv", lunet_udp_recv},
                      {"close", lunet_udp_close},
                      {NULL, NULL}};
  luaL_newlib(L, funcs);
  return 1;
}
#endif

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

#if defined(LUNET_DB_SQLITE3)
LUNET_API int luaopen_lunet_sqlite3(lua_State *L) {
  lunet_trace_init();
  set_default_luaL(L);
  return lunet_open_db(L);
}
#endif

#if defined(LUNET_DB_MYSQL)
LUNET_API int luaopen_lunet_mysql(lua_State *L) {
  lunet_trace_init();
  set_default_luaL(L);
  return lunet_open_db(L);
}
#endif

#if defined(LUNET_DB_POSTGRES)
LUNET_API int luaopen_lunet_postgres(lua_State *L) {
  lunet_trace_init();
  set_default_luaL(L);
  return lunet_open_db(L);
}
#endif

#if defined(LUNET_HAS_UDP)
LUNET_API int luaopen_lunet_udp(lua_State *L) {
  lunet_trace_init();
  set_default_luaL(L);
  return lunet_open_udp(L);
}
#endif

void lunet_open(lua_State *L) {
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, lunet_open_core);
  lua_setfield(L, -2, "lunet");
  lua_pop(L, 2);

  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, lunet_open_socket);
  lua_setfield(L, -2, "lunet.socket");
  lua_pop(L, 2);

  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, lunet_open_signal);
  lua_setfield(L, -2, "lunet.signal");
  lua_pop(L, 2);

  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, lunet_open_fs);
  lua_setfield(L, -2, "lunet.fs");
  lua_pop(L, 2);
}

LUNET_API int luaopen_lunet(lua_State *L) {
  lunet_trace_init();
  set_default_luaL(L);
  lunet_open(L);  // Register submodules in package.preload
  return lunet_open_core(L);  // Return core module table
}

#ifndef LUNET_NO_MAIN
int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "Usage: %s [OPTIONS] <lua_file>\n", argv[0]);
    fprintf(stderr, "\nOptions:\n");
    fprintf(stderr, "  --dangerously-skip-loopback-restriction\n");
    fprintf(stderr, "      Allow binding to any network interface. By default, binding is restricted\n");
    fprintf(stderr, "      to loopback (127.0.0.1, ::1) or Unix sockets.\n");
    return 1;
  }

  int script_index = 0;
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--dangerously-skip-loopback-restriction") == 0) {
      g_lunet_config.dangerously_skip_loopback_restriction = 1;
      fprintf(stderr, "WARNING: Loopback restriction disabled. Binding to public interfaces allowed.\n");
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

  /* Initialize tracing (no-op in release builds) */
  lunet_trace_init();

  lua_State *L = luaL_newstate();
  luaL_openlibs(L);
  set_default_luaL(L);
  lunet_open(L);

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
  
  /* Dump trace statistics and assert balance (no-op in release builds) */
  lunet_trace_dump();
  lunet_trace_assert_balanced("shutdown");
  
  lua_close(L);
  if (lua_exit_code >= 0) {
    return lua_exit_code;
  }
  return ret;
}
#endif

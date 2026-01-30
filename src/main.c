#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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

#ifdef LUNET_HAS_DB
int lunet_db_open(lua_State* L);
int lunet_db_close(lua_State* L);
int lunet_db_query(lua_State* L);
int lunet_db_exec(lua_State* L);
int lunet_db_escape(lua_State* L);
int lunet_db_query_params(lua_State* L);
int lunet_db_exec_params(lua_State* L);

int lunet_open_db(lua_State *L) {
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

#ifdef LUNET_HAS_DB
  // register unified db module
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, lunet_open_db);
  lua_setfield(L, -2, "lunet.db");
  lua_pop(L, 2);
#endif
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
#ifdef LUNET_TRACE
  lunet_udp_trace_summary();
#endif
  lunet_trace_dump();
  lunet_trace_assert_balanced("shutdown");
  
  lua_close(L);
  if (lua_exit_code >= 0) {
    return lua_exit_code;
  }
  return ret;
}
#endif

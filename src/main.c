#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <stdio.h>
#include <uv.h>

#include "co.h"
#include "fs.h"
#include "mysql.h"
#include "rt.h"
#include "socket.h"
#include "timer.h"

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

int lunet_open_mysql(lua_State *L) {
  luaL_Reg funcs[] = {{"open", lunet_mysql_open},
                      {"close", lunet_mysql_close},
                      {"query", lunet_mysql_query},
                      {"exec", lunet_mysql_exec},
                      {NULL, NULL}};
  luaL_newlib(L, funcs);
  return 1;
}

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
  // register mysql module
  lua_getglobal(L, "package");
  lua_getfield(L, -1, "preload");
  lua_pushcfunction(L, lunet_open_mysql);
  lua_setfield(L, -2, "lunet.mysql");
  lua_pop(L, 2);
}

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "Usage: %s <lua_file>\n", argv[0]);
    return 1;
  }

  lua_State *L = luaL_newstate();
  luaL_openlibs(L);
  set_default_luaL(L);
  lunet_open(L);

  // run lua file
  if (luaL_dofile(L, argv[1]) != LUA_OK) {
    const char *error = lua_tostring(L, -1);
    fprintf(stderr, "Error: %s\n", error);
    lua_pop(L, 1);
    lua_close(L);
    return 1;
  }

  int ret = uv_run(uv_default_loop(), UV_RUN_DEFAULT);
  lua_close(L);
  return ret;
}

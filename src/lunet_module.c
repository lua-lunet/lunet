#include "lunet_lua.h"
#include "lunet_exports.h"

#include "co.h"
#include "fs.h"
#include "lunet_signal.h"
#include "rt.h"
#include "socket.h"
#include "timer.h"
#include "udp.h"

static int lunet_open_core(lua_State *L) {
  luaL_Reg funcs[] = {{"spawn", lunet_spawn}, {"sleep", lunet_sleep}, {NULL, NULL}};
  luaL_newlib(L, funcs);
  return 1;
}

static int lunet_open_socket(lua_State *L) {
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

static int lunet_open_udp(lua_State *L) {
  luaL_Reg funcs[] = {{"bind", lunet_udp_bind},
                      {"send", lunet_udp_send},
                      {"recv", lunet_udp_recv},
                      {"close", lunet_udp_close},
                      {NULL, NULL}};
  luaL_newlib(L, funcs);
  return 1;
}

static int lunet_open_signal(lua_State *L) {
  luaL_Reg funcs[] = {{"wait", lunet_signal_wait}, {NULL, NULL}};
  luaL_newlib(L, funcs);
  return 1;
}

static int lunet_open_fs(lua_State *L) {
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

static void lunet_open(lua_State *L) {
  /* Register submodules into package.preload. */
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
  lua_pushcfunction(L, lunet_open_udp);
  lua_setfield(L, -2, "lunet.udp");
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
  lunet_init_core(L);
  lunet_open(L);
  return lunet_open_core(L);
}

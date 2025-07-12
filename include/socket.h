#ifndef SOCKET_H
#define SOCKET_H

#include <lua.h>
int lunet_socket_listen(lua_State *L);
int lunet_socket_accept(lua_State *L);
int lunet_socket_getpeername(lua_State *L);
int lunet_socket_close(lua_State *L);
int lunet_socket_read(lua_State *L);
int lunet_socket_write(lua_State *L);
int lunet_socket_connect(lua_State *L);
int lunet_socket_set_read_buffer_size(lua_State *L);
#endif  // SOCKET_H
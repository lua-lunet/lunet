#ifndef LUNET_SOCKET_H
#define LUNET_SOCKET_H

#include "lunet_lua.h"

int lunet_socket_listen(lua_State* L);
int lunet_socket_accept(lua_State* L);
int lunet_socket_getpeername(lua_State* L);
int lunet_socket_close(lua_State* L);
int lunet_socket_read(lua_State* L);
int lunet_socket_write(lua_State* L);
int lunet_socket_connect(lua_State* L);
int lunet_socket_set_read_buffer_size(lua_State* L);

#ifdef LUNET_TRACE
void lunet_socket_trace_summary(void);
#else
static inline void lunet_socket_trace_summary(void) {}
#endif

#endif

#ifndef LUNET_SOCKET_H
#define LUNET_SOCKET_H

#include "lunet_lua.h"

struct uv_handle_s;

/*
 * Close one socket context during the drain-point teardown. Dispatched by
 * lunet.c's uv_walk over every handle that is still open after the event
 * loop has stopped. Does nothing when the handle is already closing or has
 * no client/server context attached.
 */
void lunet_socket_teardown_close(struct uv_handle_s *handle);

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

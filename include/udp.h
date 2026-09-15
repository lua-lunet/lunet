#ifndef UDP_H
#define UDP_H

#include "lunet_lua.h"

struct uv_handle_s;

/*
 * Close one UDP context during the drain-point teardown (see socket.h).
 * No-op when the handle is already closing or has no bound context.
 */
void lunet_udp_teardown_close(struct uv_handle_s *handle);

int lunet_udp_bind(lua_State *L);
int lunet_udp_send(lua_State *L);
int lunet_udp_recv(lua_State *L);
int lunet_udp_close(lua_State *L);
int lunet_udp_getsockname(lua_State *L);

#ifdef LUNET_TRACE
void lunet_udp_trace_summary(void);
#else
static inline void lunet_udp_trace_summary(void) {}
#endif

#endif  // UDP_H

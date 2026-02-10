#ifndef UDP_H
#define UDP_H

#include "lunet_lua.h"

int lunet_udp_bind(lua_State *L);
int lunet_udp_send(lua_State *L);
int lunet_udp_recv(lua_State *L);
int lunet_udp_close(lua_State *L);

#ifdef LUNET_TRACE
void lunet_udp_trace_summary(void);
#else
static inline void lunet_udp_trace_summary(void) {}
#endif

#endif  // UDP_H

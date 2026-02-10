#ifndef LUNET_SIGNAL_H
#define LUNET_SIGNAL_H

#include "lunet_lua.h"

int lunet_signal_wait(lua_State *L);

#ifdef LUNET_TRACE
void lunet_signal_trace_summary(void);
#else
static inline void lunet_signal_trace_summary(void) {}
#endif

#endif

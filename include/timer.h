#ifndef TIMER_H
#define TIMER_H

#include "lunet_lua.h"
int lunet_sleep(lua_State *L);

#ifdef LUNET_TRACE
void lunet_timer_trace_summary(void);
#else
static inline void lunet_timer_trace_summary(void) {}
#endif

#endif // TIMER_H

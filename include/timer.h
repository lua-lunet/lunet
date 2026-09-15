#ifndef TIMER_H
#define TIMER_H

#include "lunet_lua.h"
int lunet_sleep(lua_State *L);

struct uv_handle_s;

/*
 * Close one pending sleep timer during the drain-point teardown (see
 * socket.h). Work already accepted runs to completion: the parked coroutine
 * is resumed as if the sleep had fired, then the timer handle is closed.
 */
void lunet_timer_teardown_close(struct uv_handle_s *handle);

#ifdef LUNET_TRACE
void lunet_timer_trace_summary(void);
#else
static inline void lunet_timer_trace_summary(void) {}
#endif

#endif // TIMER_H

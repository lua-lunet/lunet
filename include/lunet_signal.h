#ifndef LUNET_SIGNAL_H
#define LUNET_SIGNAL_H

#include "lunet_lua.h"

struct uv_handle_s;

/*
 * Close one signal-wait context during the drain-point teardown (see
 * socket.h). The parked coroutine is woken with an error, then the handle
 * is closed. No-op when nothing is waiting on the handle.
 */
void lunet_signal_teardown_close(struct uv_handle_s *handle);

int lunet_signal_wait(lua_State *L);

#ifdef LUNET_TRACE
void lunet_signal_trace_summary(void);
#else
static inline void lunet_signal_trace_summary(void) {}
#endif

#endif

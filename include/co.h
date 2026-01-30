#ifndef CO_H
#define CO_H

#include "lunet_lua.h"

int lunet_spawn(lua_State *L);

/*
 * Internal: Do not call directly - use lunet_ensure_coroutine() instead.
 * 
 * This is the raw implementation that checks if we're in a yieldable coroutine.
 * The safe wrapper lunet_ensure_coroutine() (defined in trace.h) adds stack
 * integrity checking in debug builds.
 */
int _lunet_ensure_coroutine(lua_State *L, const char *func_name);

#endif  /* CO_H */

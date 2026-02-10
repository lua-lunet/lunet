#ifndef CO_H
#define CO_H

#include "lunet_lua.h"

int lunet_spawn(lua_State *L);

/*
 * Unanchor a coroutine from the alive-set, allowing GC to collect it.
 * Call this after lua_resume returns LUA_OK or an error (coroutine is done).
 */
void lunet_co_unanchor(lua_State *co);

/*
 * Resume a coroutine and automatically unanchor it if it finishes.
 * Returns the status from lua_resume (LUA_OK, LUA_YIELD, or error).
 * If the coroutine finishes (anything other than LUA_YIELD), it is
 * unanchored so GC can collect it.
 */
int lunet_co_resume(lua_State *co, int nargs);

/*
 * Internal: Do not call directly - use lunet_ensure_coroutine() instead.
 * 
 * This is the raw implementation that checks if we're in a yieldable coroutine.
 * The safe wrapper lunet_ensure_coroutine() (defined in trace.h) adds stack
 * integrity checking in debug builds.
 */
int _lunet_ensure_coroutine(lua_State *L, const char *func_name);

#endif  /* CO_H */

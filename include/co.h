#ifndef CO_H
#define CO_H

#include "lunet_lua.h"

int lunet_spawn(lua_State *L);

/*
 * lunet.stop(): request deliberate termination from Lua. The event loop
 * stops taking new work; run_file / run_embedded return after the drain
 * point (on_stop hook fired, all remaining handles closed). Repeat calls
 * are safe no-ops. Violates nothing if the loop is not running.
 */
int lunet_stop(lua_State *L);

/*
 * lunet.on_stop(fn): register the post-drain hook. The hook runs exactly
 * once at the drain point (after uv_run returns, before any handle is
 * closed) and must use synchronous I/O only -- the event loop is not
 * driving anything at that point, so registering new async operations
 * cannot progress. Calling it with a non-callable value raises an error.
 */
int lunet_on_stop(lua_State *L);

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

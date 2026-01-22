#ifndef TRACE_H
#define TRACE_H

#include <lua.h>
#include <lauxlib.h>
#include "co.h"  /* For _lunet_ensure_coroutine */

/*
 * Coroutine Reference Tracing System
 * ==================================
 * 
 * This module provides safe wrappers around low-level Lua-C operations that
 * are prone to stack corruption bugs. In debug builds (LUNET_TRACE defined),
 * these wrappers verify stack integrity and track coroutine reference lifetimes.
 * In release builds, they compile to the minimal required code with zero overhead.
 * 
 * SAFE API (use these):
 * ---------------------
 *   lunet_ensure_coroutine(L, "func_name")  - Check we're in a yieldable coroutine
 *   lunet_coref_create(L, &ref)             - Create a coroutine reference
 *   lunet_coref_release(L, ref)             - Release a coroutine reference
 * 
 * INTERNAL API (do not use directly):
 * -----------------------------------
 *   _lunet_ensure_coroutine()  - Raw implementation without stack checking
 * 
 * LIFECYCLE:
 * ----------
 *   lunet_trace_init()            - Call once at startup
 *   lunet_trace_dump()            - Print statistics
 *   lunet_trace_assert_balanced() - Assert all refs released (call at shutdown)
 */

#ifdef LUNET_TRACE

#include <stdio.h>
#include <assert.h>

/* Maximum tracked locations for debugging leaks */
#define LUNET_TRACE_MAX_LOCATIONS 64

typedef struct {
  const char *file;
  int line;
  int count;  /* Positive = outstanding refs from this location */
} lunet_trace_location_t;

typedef struct {
  /* Coroutine reference tracking */
  int coref_balance;           /* +1 on create, -1 on release, must be 0 at end */
  int coref_total_created;     /* Lifetime count of refs created */
  int coref_total_released;    /* Lifetime count of refs released */
  int coref_peak;              /* High water mark */
  
  /* Location tracking for debugging */
  lunet_trace_location_t locations[LUNET_TRACE_MAX_LOCATIONS];
  int location_count;
  
  /* Stack tracking */
  int stack_checks_passed;
  int stack_checks_failed;
} lunet_trace_state_t;

/* Global trace state - only exists when LUNET_TRACE defined */
extern lunet_trace_state_t lunet_trace_state;

/* Initialize tracing (call once at startup) */
void lunet_trace_init(void);

/* Dump current trace statistics */
void lunet_trace_dump(void);

/* Assert all refs are balanced (call at shutdown or checkpoints) */
void lunet_trace_assert_balanced(const char *context);

/* Internal tracking functions - called by macros */
void lunet_trace_coref_add(const char *file, int line);
void lunet_trace_coref_remove(const char *file, int line);
void lunet_trace_stack_check(lua_State *L, int expected_base, int expected_delta,
                              const char *file, int line);

/*
 * Stack depth checking - use at function entry/exit
 */
#define LUNET_STACK_ENTER(L) int _lunet_stack_base_##__LINE__ = lua_gettop(L)
#define LUNET_STACK_EXIT(L, delta) \
    lunet_trace_stack_check(L, _lunet_stack_base_##__LINE__, delta, __FILE__, __LINE__)

/*
 * lunet_ensure_coroutine - SAFE wrapper for _lunet_ensure_coroutine
 * 
 * Verifies we're in a yieldable coroutine AND checks stack integrity.
 * On error, calls lua_error() and does not return.
 * On success, returns normally (returns 0 but callers can ignore).
 * 
 * In trace builds: validates stack is not corrupted
 * In release builds: just calls the underlying implementation
 * 
 * Usage (as a statement, no need to check return):
 *   lunet_ensure_coroutine(L, "func_name");
 *   // ... rest of function (only reached if in coroutine)
 */
#define lunet_ensure_coroutine(L, func_name) \
    _lunet_ensure_coroutine_checked(L, func_name, __FILE__, __LINE__)

static inline int _lunet_ensure_coroutine_checked(lua_State *L, const char *func_name,
                                                   const char *file, int line) {
    int stack_before = lua_gettop(L);
    if (_lunet_ensure_coroutine(L, func_name) != 0) {
        lua_error(L);  /* Does not return */
    }
    int stack_after = lua_gettop(L);
    if (stack_after != stack_before) {
        fprintf(stderr, "[TRACE] STACK BUG in %s at %s:%d: "
                "_lunet_ensure_coroutine changed stack from %d to %d (delta=%d)\n",
                func_name, file, line, stack_before, stack_after,
                stack_after - stack_before);
        lunet_trace_state.stack_checks_failed++;
        assert(0 && "_lunet_ensure_coroutine corrupted stack");
    }
    return 0;
}

/*
 * lunet_coref_create - SAFE coroutine reference creation
 * 
 * Creates a reference to the current coroutine in the Lua registry.
 * Tracks creation for leak detection in trace builds.
 * 
 * Usage: lunet_coref_create(L, ctx->co_ref);
 */
#define lunet_coref_create(L, ref_var) do { \
    lua_pushthread(L); \
    (ref_var) = luaL_ref(L, LUA_REGISTRYINDEX); \
    lunet_trace_coref_add(__FILE__, __LINE__); \
} while(0)

/*
 * lunet_coref_release - SAFE coroutine reference release
 * 
 * Releases a coroutine reference from the Lua registry.
 * Tracks release for leak detection in trace builds.
 */
#define lunet_coref_release(L, ref) do { \
    luaL_unref(L, LUA_REGISTRYINDEX, ref); \
    lunet_trace_coref_remove(__FILE__, __LINE__); \
} while(0)

#else /* !LUNET_TRACE */

/*
 * Zero-cost stubs - compiler eliminates these completely
 */

static inline void lunet_trace_init(void) {}
static inline void lunet_trace_dump(void) {}
static inline void lunet_trace_assert_balanced(const char *context) { (void)context; }

/*
 * lunet_ensure_coroutine - Direct call to implementation (no checking in release)
 * On error, calls lua_error() and does not return.
 */
static inline int lunet_ensure_coroutine(lua_State *L, const char *func_name) {
    if (_lunet_ensure_coroutine(L, func_name) != 0) {
        lua_error(L);  /* Does not return */
    }
    return 0;
}

/*
 * lunet_coref_create - Just the essential operations, no tracking
 */
#define lunet_coref_create(L, ref_var) do { \
    lua_pushthread(L); \
    (ref_var) = luaL_ref(L, LUA_REGISTRYINDEX); \
} while(0)

/*
 * lunet_coref_release - Just the unref, no tracking
 */
#define lunet_coref_release(L, ref) do { \
    luaL_unref(L, LUA_REGISTRYINDEX, ref); \
} while(0)

/*
 * Stack checking - evaluates to nothing in release
 */
#define LUNET_STACK_ENTER(L) ((void)0)
#define LUNET_STACK_EXIT(L, delta) ((void)0)

#endif /* LUNET_TRACE */

#endif /* TRACE_H */

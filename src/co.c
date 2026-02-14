#include "co.h"
#include "lunet_exports.h"

#include <stdio.h>
#include <assert.h>

/*
 * Coroutine Anchor Table
 * ======================
 * Every spawned coroutine that yields is anchored in a registry table to prevent
 * GC from collecting it between async operations. The table maps thread -> true.
 *
 * Without this anchor, a coroutine that yields has no strong references after the
 * temporary coref (used to wake it from a callback) is released. Under load, GC
 * collects the thread and the next callback segfaults on lua_resume.
 *
 * The anchor is released when:
 *   - lua_resume returns LUA_OK (coroutine finished normally)
 *   - lua_resume returns an error (coroutine died)
 *   - The coroutine never yields (synchronous completion in spawn)
 *
 * See: lunet_co_anchor(), lunet_co_resume()
 */

/* Registry key for the anchor table (address used as light userdata key) */
static char lunet_co_anchor_key;

#ifdef LUNET_TRACE
static int co_trace_resume_seq = 0;
static int co_trace_resume_yield = 0;
static int co_trace_resume_ok = 0;
static int co_trace_resume_err = 0;
#endif

/* Ensure the anchor table exists in the registry, push it onto the stack */
static void lunet_co_get_anchor_table(lua_State *L) {
  lua_pushlightuserdata(L, &lunet_co_anchor_key);
  lua_rawget(L, LUA_REGISTRYINDEX);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
    lua_pushlightuserdata(L, &lunet_co_anchor_key);
    lua_pushvalue(L, -2);
    lua_rawset(L, LUA_REGISTRYINDEX);
  }
}

/* Anchor a coroutine thread (prevent GC). Thread must be on top of L's stack. */
static void lunet_co_anchor(lua_State *L) {
  lunet_co_get_anchor_table(L);     /* stack: ... thread anchortbl */
  lua_pushvalue(L, -2);             /* stack: ... thread anchortbl thread */
  lua_pushboolean(L, 1);            /* stack: ... thread anchortbl thread true */
  lua_rawset(L, -3);                /* anchortbl[thread] = true */
  lua_pop(L, 1);                    /* pop anchortbl */
}

/* Release a coroutine anchor. co is the coroutine's lua_State. */
LUNET_API void lunet_co_unanchor(lua_State *co) {
  lunet_co_get_anchor_table(co);    /* stack: anchortbl */
  lua_pushthread(co);               /* stack: anchortbl thread */
  lua_pushnil(co);                  /* stack: anchortbl thread nil */
  lua_rawset(co, -3);               /* anchortbl[thread] = nil */
  lua_pop(co, 1);                   /* pop anchortbl */
}

LUNET_API int lunet_spawn(lua_State *L) {
  luaL_checktype(L, 1, LUA_TFUNCTION);
  // create new coroutine
  lua_State *co = lua_newthread(L);

  // copy function to new coroutine
  lua_pushvalue(L, 1);
  lua_xmove(L, co, 1);

  // start coroutine
  int status = lua_resume(co, 0);
  if (status == LUA_YIELD) {
    /* Coroutine yielded — anchor it to prevent GC.
     * Thread is still on top of L's stack from lua_newthread. */
    lunet_co_anchor(L);
  } else if (status != LUA_OK) {
    fprintf(stderr, "Coroutine error: %s\n", lua_tostring(co, -1));
  }
  /* else: LUA_OK means coroutine finished synchronously, no anchor needed */

  // pop the coroutine thread from parent's stack
  lua_pop(L, 1);

  return 0;
}

LUNET_API int lunet_co_resume(lua_State *co, int nargs) {
#ifdef LUNET_TRACE
  co_trace_resume_seq++;
#endif
#ifdef LUNET_TRACE_VERBOSE
  fprintf(stderr, "[CO_TRACE] RESUME #%d co=%p nargs=%d top=%d\n",
          co_trace_resume_seq, (void *)co, nargs, lua_gettop(co));
#endif
  int status = lua_resume(co, nargs);
#ifdef LUNET_TRACE
  if (status == LUA_YIELD) {
    co_trace_resume_yield++;
  } else if (status == LUA_OK) {
    co_trace_resume_ok++;
  } else {
    co_trace_resume_err++;
  }
  if (!(status == LUA_YIELD || status == LUA_OK || status > LUA_YIELD)) {
    fprintf(stderr, "[CO_TRACE] INVALID_STATUS seq=%d status=%d co=%p\n",
            co_trace_resume_seq, status, (void *)co);
    assert(status == LUA_YIELD || status == LUA_OK || status > LUA_YIELD);
  }
#endif
#ifdef LUNET_TRACE_VERBOSE
  fprintf(stderr, "[CO_TRACE] RESUMED #%d co=%p status=%d top=%d (yield=%d ok=%d err=%d)\n",
          co_trace_resume_seq, (void *)co, status, lua_gettop(co),
          co_trace_resume_yield, co_trace_resume_ok, co_trace_resume_err);
#endif
  if (status != LUA_YIELD) {
    /* Coroutine finished (LUA_OK) or errored — unanchor so GC can collect it */
    lunet_co_unanchor(co);
    if (status != LUA_OK) {
      const char *err = lua_tostring(co, -1);
      if (err) {
        fprintf(stderr, "[lunet] coroutine error: %s\n", err);
      }
    }
  }
  return status;
}

LUNET_API int _lunet_ensure_coroutine(lua_State *L, const char *func_name) {
  if (lua_pushthread(L)) {
    lua_pop(L, 1);
    lua_pushfstring(L, "%s must be called from coroutine", func_name);
    return lua_error(L);
  }
  lua_pop(L, 1);  // Pop the thread pushed by lua_pushthread
  if (!lua_isyieldable(L)) {
    lua_pushfstring(L, "%s called in non-yieldable context", func_name);
    return lua_error(L);
  }
  return 0;
}

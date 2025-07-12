#include "timer.h"

#include <lauxlib.h>
#include <stdlib.h>
#include <uv.h>

#include "co.h"
#include "rt.h"

typedef struct {
  uv_timer_t timer;
  lua_State *L;
  int co_ref;
} sleep_ctx_t;

static void lunet_sleep_cb(uv_timer_t *timer) {
  sleep_ctx_t *ctx = (sleep_ctx_t *)timer->data;
  lua_State *L = ctx->L;

  // get coroutine reference from registry
  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);

  if (lua_isthread(L, -1) == 0) {
    lua_pop(L, 1);  // pop invalid coroutine
    fprintf(stderr, "[lunet] Invalid coroutine reference in sleep_cb\n");
    return;
  }
  // resume coroutine
  lua_State *co = lua_tothread(L, -1);
  lua_pop(L, 1);

  int status = lua_resume(co, 0);
  if (status != LUA_OK && status != LUA_YIELD) {
    const char *err = lua_tostring(co, -1);
    if (err) {
      fprintf(stderr, "[lunet] resume error in sleep_cb: %s\n", err);
    }
    lua_pop(co, 1);  // pop error message
  }
}
// sleep for ms milliseconds
int lunet_sleep(lua_State *co) {
  if (lunet_ensure_coroutine(co, "lunet.sleep") != 0) {
    return lua_error(co);
  }

  int ms = luaL_checkinteger(co, 1);
  if (ms < 0) {
    lua_pushstring(co, "lunet.sleep duration must be >= 0");
    return lua_error(co);
  }

  sleep_ctx_t *ctx = malloc(sizeof(sleep_ctx_t));
  if (!ctx) {
    lua_pushstring(co, "lunet.sleep: out of memory");
    return lua_error(co);
  }
  // save coroutine reference to main lua state
  ctx->L = default_luaL();
  lua_pushthread(co);
  lua_xmove(co, ctx->L, 1);
  ctx->co_ref = luaL_ref(ctx->L, LUA_REGISTRYINDEX);

  // init timer
  uv_timer_init(uv_default_loop(), &ctx->timer);
  ctx->timer.data = ctx;
  uv_timer_start(&ctx->timer, lunet_sleep_cb, ms, 0);

  return lua_yield(co, 0);
}
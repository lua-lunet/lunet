#include "signal.h"

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <stdlib.h>
#include <uv.h>

#include "co.h"
#include "trace.h"

typedef struct {
  uv_signal_t handle;
  lua_State *L;
  int co_ref;
} signal_ctx_t;

static void lunet_signal_cb(uv_signal_t *handle, int signo) {
  signal_ctx_t *ctx = (signal_ctx_t *)handle->data;
  lua_State *co = ctx->L;

  lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->co_ref);
  // convert signal number to string
  if (signo == SIGINT)
    lua_pushstring(co, "INT");
  else if (signo == SIGTERM)
    lua_pushstring(co, "TERM");
  else if (signo == SIGHUP)
    lua_pushstring(co, "HUP");
  else if (signo == SIGQUIT)
    lua_pushstring(co, "QUIT");
  else
    lua_pushfstring(co, "SIGNAL_%d", signo);
  lua_pushnil(co);

  int status = lua_resume(co, 2);
  if (status != LUA_OK && status != LUA_YIELD) {
    const char *err = lua_tostring(co, -1);
    if (err) {
      fprintf(stderr, "signal_cb resume error: %s\n", err);
    }
  }

  // cleanup
  lunet_coref_release(co, ctx->co_ref);
  uv_signal_stop(&ctx->handle);
  uv_close((uv_handle_t *)&ctx->handle, (uv_close_cb)free);
}

int lunet_signal_wait(lua_State *L) {
  lunet_ensure_coroutine(L, "signal.wait");
  const char *sig_name = luaL_checkstring(L, 1);

  // covert string to signal number
  int signo = SIGINT;
  if (strcmp(sig_name, "INT") == 0)
    signo = SIGINT;
  else if (strcmp(sig_name, "TERM") == 0)
    signo = SIGTERM;
  else if (strcmp(sig_name, "HUP") == 0)
    signo = SIGHUP;
  else if (strcmp(sig_name, "QUIT") == 0)
    signo = SIGQUIT;
  else {
    lua_pushnil(L);
    lua_pushstring(L, "unsupported signal name");
    return 2;
  }

  signal_ctx_t *ctx = (signal_ctx_t *)malloc(sizeof(signal_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "no memory");
    return 2;
  }

  ctx->L = L;
  lunet_coref_create(L, ctx->co_ref);

  uv_signal_init(uv_default_loop(), &ctx->handle);
  ctx->handle.data = ctx;
  uv_signal_start(&ctx->handle, lunet_signal_cb, signo);

  return lua_yield(L, 0);
}
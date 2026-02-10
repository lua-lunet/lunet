#include "lunet_signal.h"

#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

#include "co.h"
#include "trace.h"
#include "lunet_mem.h"

/*
 * Signal domain tracing
 */
#ifdef LUNET_TRACE
static int signal_trace_wait_count = 0;
static int signal_trace_fire_count = 0;

#ifdef LUNET_TRACE_VERBOSE
#define SIGNAL_TRACE_WAIT(signo) \
    do { signal_trace_wait_count++; \
         fprintf(stderr, "[SIGNAL_TRACE] WAIT #%d signo=%d\n", \
                 signal_trace_wait_count, (signo)); \
    } while(0)
#define SIGNAL_TRACE_FIRE(signo) \
    do { signal_trace_fire_count++; \
         fprintf(stderr, "[SIGNAL_TRACE] FIRE #%d signo=%d\n", \
                 signal_trace_fire_count, (signo)); \
    } while(0)
#else
#define SIGNAL_TRACE_WAIT(signo) do { signal_trace_wait_count++; } while(0)
#define SIGNAL_TRACE_FIRE(signo) do { signal_trace_fire_count++; } while(0)
#endif

void lunet_signal_trace_summary(void) {
    fprintf(stderr, "[SIGNAL_TRACE] SUMMARY: wait=%d fire=%d\n",
            signal_trace_wait_count, signal_trace_fire_count);
}

#else /* !LUNET_TRACE */
#define SIGNAL_TRACE_WAIT(signo) ((void)0)
#define SIGNAL_TRACE_FIRE(signo) ((void)0)
void lunet_signal_trace_summary(void) {}
#endif

typedef struct {
  uv_signal_t handle;
  lua_State *L;
  int co_ref;
} signal_ctx_t;

static void signal_close_cb(uv_handle_t *handle) {
  lunet_free_nonnull(handle->data);
}

static void lunet_signal_cb(uv_signal_t *handle, int signo) {
  signal_ctx_t *ctx = (signal_ctx_t *)handle->data;
  lua_State *L = ctx->L;

  SIGNAL_TRACE_FIRE(signo);

  /* Extract coroutine from registry without polluting the stack. */
  int base = LUNET_STACK_BASE(L);
  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lua_State *waiting_co = NULL;
  if (lua_isthread(L, -1)) {
    waiting_co = lua_tothread(L, -1);
  }
  lua_pop(L, 1);

  /* cleanup the reference (even if waiting_co is missing) */
  lunet_coref_release(L, ctx->co_ref);
  ctx->co_ref = LUA_NOREF;

  if (waiting_co) {
    /* convert signal number to string */
    if (signo == SIGINT)
      lua_pushstring(waiting_co, "INT");
    else if (signo == SIGTERM)
      lua_pushstring(waiting_co, "TERM");
    else if (signo == SIGHUP)
      lua_pushstring(waiting_co, "HUP");
    else if (signo == SIGQUIT)
      lua_pushstring(waiting_co, "QUIT");
    else
      lua_pushfstring(waiting_co, "SIGNAL_%d", signo);
    lua_pushnil(waiting_co);

    lunet_co_resume(waiting_co, 2);
  }

  LUNET_STACK_CHECK(L, base, 0);

  uv_signal_stop(&ctx->handle);
  uv_close((uv_handle_t *)&ctx->handle, signal_close_cb);
}

int lunet_signal_wait(lua_State *L) {
  if (lunet_ensure_coroutine(L, "signal.wait") != 0) {
    return lua_error(L);
  }

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

  signal_ctx_t *ctx = (signal_ctx_t *)lunet_alloc(sizeof(signal_ctx_t));
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

  SIGNAL_TRACE_WAIT(signo);

  return lua_yield(L, 0);
}

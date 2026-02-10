#include "timer.h"

#include <stdlib.h>
#include <uv.h>

#include "co.h"
#include "rt.h"
#include "trace.h"
#include "lunet_mem.h"

/*
 * Timer domain tracing
 */
#ifdef LUNET_TRACE
static int timer_trace_sleep_count = 0;
static int timer_trace_wake_count = 0;

#ifdef LUNET_TRACE_VERBOSE
#define TIMER_TRACE_SLEEP(ctx, ms) \
    do { timer_trace_sleep_count++; \
         fprintf(stderr, "[TIMER_TRACE] SLEEP #%d ctx=%p ms=%d\n", \
                 timer_trace_sleep_count, (void*)(ctx), (ms)); \
    } while(0)
#define TIMER_TRACE_WAKE(ctx) \
    do { timer_trace_wake_count++; \
         fprintf(stderr, "[TIMER_TRACE] WAKE #%d ctx=%p\n", \
                 timer_trace_wake_count, (void*)(ctx)); \
    } while(0)
#else
#define TIMER_TRACE_SLEEP(ctx, ms) do { timer_trace_sleep_count++; } while(0)
#define TIMER_TRACE_WAKE(ctx) do { timer_trace_wake_count++; } while(0)
#endif

void lunet_timer_trace_summary(void) {
    fprintf(stderr, "[TIMER_TRACE] SUMMARY: sleep=%d wake=%d\n",
            timer_trace_sleep_count, timer_trace_wake_count);
}

#else /* !LUNET_TRACE */
#define TIMER_TRACE_SLEEP(ctx, ms) ((void)0)
#define TIMER_TRACE_WAKE(ctx) ((void)0)
void lunet_timer_trace_summary(void) {}
#endif

typedef struct {
  uv_timer_t timer;
  lua_State *L;
  int co_ref;
} sleep_ctx_t;

static void lunet_sleep_close_cb(uv_handle_t *handle) {
  /* handle->data is sleep_ctx_t* */
  lunet_free_nonnull(handle->data);
}

static void lunet_sleep_cb(uv_timer_t *timer) {
  sleep_ctx_t *ctx = (sleep_ctx_t *)timer->data;
  lua_State *L = ctx->L;

  TIMER_TRACE_WAKE(ctx);

  // get coroutine reference from registry
  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);

  if (lua_isthread(L, -1) == 0) {
    lua_pop(L, 1);  // pop invalid coroutine
    fprintf(stderr, "[lunet] Invalid coroutine reference in sleep_cb\n");
    return;
  }
  // resume coroutine
  lua_State *co = lua_tothread(L, -1);
  lua_pop(L, 1);

  lunet_co_resume(co, 0);

  /* Stop + close the timer handle, free ctx in close cb. */
  uv_timer_stop(&ctx->timer);
  uv_close((uv_handle_t *)&ctx->timer, lunet_sleep_close_cb);
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

  sleep_ctx_t *ctx = lunet_alloc(sizeof(sleep_ctx_t));
  if (!ctx) {
    lua_pushstring(co, "lunet.sleep: out of memory");
    return lua_error(co);
  }
  // save coroutine reference to main lua state
  ctx->L = default_luaL();
  lua_pushthread(co);
  lua_xmove(co, ctx->L, 1);
  // Thread already on stack from xmove, use raw variant
  lunet_coref_create_raw(ctx->L, ctx->co_ref);

  // init timer
  uv_timer_init(uv_default_loop(), &ctx->timer);
  ctx->timer.data = ctx;
  uv_timer_start(&ctx->timer, lunet_sleep_cb, ms, 0);

  TIMER_TRACE_SLEEP(ctx, ms);

  return lua_yield(co, 0);
}

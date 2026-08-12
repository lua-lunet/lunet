#include "socket.h"

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h> // for unlink
#endif

#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include <uv.h>

#include "co.h"
#include "rt.h"
#include "stl.h"
#include "trace.h"
#include "lunet_mem.h"
#include "runtime.h"

static size_t read_buffer_size = 4096;

static int is_loopback_address(const char *host) {
  return strcmp(host, "127.0.0.1") == 0 ||
         strcmp(host, "::1") == 0 ||
         strcmp(host, "localhost") == 0;
}

typedef enum {
  SOCKET_DOMAIN_TCP,
  SOCKET_DOMAIN_UNIX
} socket_domain_t;

typedef enum {
  SOCKET_SERVER,
  SOCKET_CLIENT,
} socket_type_t;

typedef struct socket_handle_s socket_handle_t;

/* Canary value for socket contexts - ASCII "SOCK" */
#define SOCKET_CTX_CANARY 0x534F434BU
/* Tail canary to detect writes past libuv handle memory - ASCII "UVTL" */
#define SOCKET_UV_TAIL_CANARY 0x5556544CU

typedef struct {
  socket_domain_t domain;
  /* Owning main Lua state (default_luaL()) for registry ops; this handle
   * outlives any creating coroutine. Never store a calling coroutine here. */
  lua_State *owner_L;
  socket_type_t type;
  int closing;
  int ref_count;
  socket_handle_t *handles;

#ifdef LUNET_TRACE
  uint32_t canary;
  int pending_writes;
  int bk_read_wait_seq;
  int bk_read_resume_seq;
  int bk_write_wait_seq;
  int bk_write_resume_seq;
  int bk_accept_wait_seq;
  int bk_accept_resume_seq;
  int bk_read_inflight;
  int bk_write_inflight;
  int bk_accept_inflight;
  int bk_event_seq;
#endif
  union {
    struct {
      int accept_ref;
      queue_t *pending_accepts;
    } server;
    struct {
      int read_ref;
      int write_ref;
    } client;
  };

  /*
   * IMPORTANT: Keep libuv handle memory at the end of the struct.
   * Some teardown paths may still touch handle fields after uv_close().
   * If anything writes past the handle, it must NOT corrupt metadata like ctx->owner_L.
   */
  union {
    uv_tcp_t tcp;
    uv_pipe_t pipe;
    uv_handle_t handle;
    uv_stream_t stream;
  } u;

#ifdef LUNET_TRACE
  uint32_t uv_tail_canary;
#endif

} socket_ctx_t;

// write request structure
typedef struct {
  uv_write_t req;
  socket_ctx_t *ctx;
  char *data;
} write_req_t;

struct socket_handle_s {
  socket_ctx_t *ctx;
  socket_handle_t *next;
};

static const char *LUNET_SOCKET_HANDLE_MT = "lunet.socket.handle";

static int lunet_socket_handle_gc(lua_State *L);

static void socket_handle_push_metatable(lua_State *L) {
  if (luaL_newmetatable(L, LUNET_SOCKET_HANDLE_MT)) {
    lua_pushcfunction(L, lunet_socket_handle_gc);
    lua_setfield(L, -2, "__gc");
  }
}

static socket_handle_t *socket_handle_new(lua_State *L, socket_ctx_t *ctx) {
  socket_handle_t *handle =
      (socket_handle_t *)lua_newuserdata(L, sizeof(socket_handle_t));
  socket_handle_push_metatable(L);
  lua_setmetatable(L, -2);
  /* Link into ctx->handles only after all fallible setup has succeeded. */
  handle->ctx = ctx;
  handle->next = ctx ? ctx->handles : NULL;
  if (ctx) {
    ctx->handles = handle;
  }
  return handle;
}

typedef struct {
  socket_ctx_t *ctx;
  int ref;
} socket_handle_new_payload_t;

static int socket_handle_new_trampoline(lua_State *L) {
  socket_handle_new_payload_t *payload =
      (socket_handle_new_payload_t *)lua_touserdata(L, 1);
  socket_handle_new(L, payload->ctx);
  lunet_valref_create_raw(L, payload->ref);
  return 0;
}

/*
 * listen_cb/connect_cb are unprotected libuv callbacks: they do not run
 * under lua_pcall, so a raised Lua error would longjmp through libuv's C
 * stack frames (undefined behavior). socket_handle_new() calls
 * lua_newuserdata(), which can raise LUA_ERRMEM on allocation failure.
 * Route the allocation through lua_cpcall, which takes a C function
 * pointer directly, so no closure needs to be pushed before the
 * protection boundary is established; an OOM inside surfaces as a normal
 * error return instead of an unprotected longjmp. lua_cpcall discards
 * any pushed results on success, so the new handle userdata is
 * re-fetched through the registry ref (the lua_rawgeti()/
 * lunet_valref_release() dance below) rather than taken off the stack.
 */
static int socket_handle_new_protected(lua_State *L, socket_ctx_t *ctx) {
  socket_handle_new_payload_t payload = {ctx, LUA_NOREF};
  int status = lua_cpcall(L, socket_handle_new_trampoline, &payload);
  if (status != 0) {
    return status;
  }

  lua_rawgeti(L, LUA_REGISTRYINDEX, payload.ref);
  lunet_valref_release(L, payload.ref);
  return 0;
}

static socket_handle_t *socket_handle_check(lua_State *L, int index) {
  socket_handle_t *handle =
      (socket_handle_t *)luaL_testudata(L, index, LUNET_SOCKET_HANDLE_MT);
  if (!handle) {
    return NULL;
  }
  return handle;
}

static socket_ctx_t *socket_handle_get(socket_handle_t *handle) {
  if (!handle) {
    return NULL;
  }
  return handle->ctx;
}

/*
 * NOTE: This __gc metamethod deliberately does NOT close the underlying
 * socket/fd. It only unlinks the handle from its owning ctx's handle list
 * so the ctx doesn't retain a dangling pointer to freed userdata. Callers
 * MUST call socket.close() explicitly to release the fd; relying on GC to
 * close sockets will leak file descriptors.
 */
static int lunet_socket_handle_gc(lua_State *L) {
  socket_handle_t *handle = socket_handle_check(L, 1);
  if (!handle || !handle->ctx) {
    return 0;
  }

  socket_ctx_t *ctx = handle->ctx;
  socket_handle_t **slot = &ctx->handles;
  while (*slot) {
    if (*slot == handle) {
      *slot = handle->next;
      break;
    }
    slot = &(*slot)->next;
  }

  handle->ctx = NULL;
  handle->next = NULL;
  return 0;
}

static void socket_handle_invalidate(socket_ctx_t *ctx) {
  if (!ctx) {
    return;
  }

  socket_handle_t *handle = ctx->handles;
  while (handle) {
    socket_handle_t *next = handle->next;
    handle->ctx = NULL;
    handle->next = NULL;
    handle = next;
  }
  ctx->handles = NULL;
}

/* Fault-injection test harness: gated entirely behind LUNET_TEST_FAULTS so
 * neither the LUNET_TEST_SOCKET_LISTEN_FAULT env var string nor the getenv()
 * check reach release binaries. Only defined for debug/trace build profiles;
 * see xmake.lua. */
#ifdef LUNET_TEST_FAULTS

/* getenv() + parse happens once (lazy-static) rather than on every accepted
 * connection. */
static const char *lunet_socket_test_fault_env(void) {
  static const char *fault = NULL;
  static int initialized = 0;

  if (!initialized) {
    fault = getenv("LUNET_TEST_SOCKET_LISTEN_FAULT");
    initialized = 1;
  }

  return fault;
}

static int lunet_socket_test_fault_active(const char *name) {
  const char *fault = lunet_socket_test_fault_env();
  size_t name_len;
  const char *p;

  if (!fault || !name) {
    return 0;
  }

  name_len = strlen(name);
  p = fault;
  while (*p) {
    const char *end = p;
    while (*end && *end != ',' && *end != '+') {
      end++;
    }
    if ((size_t)(end - p) == name_len && strncmp(p, name, name_len) == 0) {
      return 1;
    }
    p = *end ? end + 1 : end;
  }

  return 0;
}

static int lunet_socket_test_fault_take(const char *name) {
  static unsigned int taken_bits = 0;
  unsigned int bit = 0;

  if (strcmp(name, "queue_fail") == 0) {
    bit = 1u << 0;
  } else if (strcmp(name, "drop_fail") == 0) {
    bit = 1u << 1;
  } else if (strcmp(name, "alloc_fail") == 0) {
    bit = 1u << 2;
  } else if (strcmp(name, "nonthread_waiter") == 0) {
    bit = 1u << 3;
  }

  if (!bit || !lunet_socket_test_fault_active(name) || (taken_bits & bit)) {
    return 0;
  }

  taken_bits |= bit;
  return 1;
}

#else /* !LUNET_TEST_FAULTS */

static int lunet_socket_test_fault_take(const char *name) {
  (void)name;
  return 0;
}

#endif /* LUNET_TEST_FAULTS */

static int lunet_pending_accept_enqueue(socket_ctx_t *ctx,
                                        socket_ctx_t *client_ctx) {
  if (lunet_socket_test_fault_take("queue_fail")) {
    return -1;
  }

  return queue_enqueue(ctx->server.pending_accepts, client_ctx);
}

/*
 * Socket domain tracing
 * Tier 1 (LUNET_TRACE): counters + canary checks
 * Tier 2 (LUNET_TRACE_VERBOSE): per-event stderr logging
 */
#ifdef LUNET_TRACE

static int socket_trace_listen_count = 0;
static int socket_trace_accept_count = 0;
static int socket_trace_connect_count = 0;
static int socket_trace_read_count = 0;
static int socket_trace_write_count = 0;
static int socket_trace_close_count = 0;

static void socket_ctx_init_canary(socket_ctx_t *ctx) {
    ctx->canary = SOCKET_CTX_CANARY;
    ctx->pending_writes = 0;
    ctx->bk_read_wait_seq = 0;
    ctx->bk_read_resume_seq = 0;
    ctx->bk_write_wait_seq = 0;
    ctx->bk_write_resume_seq = 0;
    ctx->bk_accept_wait_seq = 0;
    ctx->bk_accept_resume_seq = 0;
    ctx->bk_read_inflight = 0;
    ctx->bk_write_inflight = 0;
    ctx->bk_accept_inflight = 0;
    ctx->bk_event_seq = 0;
    ctx->uv_tail_canary = SOCKET_UV_TAIL_CANARY;
}

/* Returns 0 if canary is valid, -1 if corrupted (use-after-free detected) */
static int socket_ctx_check_canary(socket_ctx_t *ctx, const char *where) {
    if (!ctx) return -1;
    if (ctx->canary != SOCKET_CTX_CANARY) {
        fprintf(stderr, "[SOCKET_TRACE] CANARY_FAIL ctx=%p in %s "
                "(expected 0x%08X got 0x%08X) -- USE-AFTER-FREE DETECTED\n",
                (void *)ctx, where, SOCKET_CTX_CANARY, ctx->canary);
        return -1;
    }
    if (ctx->uv_tail_canary != SOCKET_UV_TAIL_CANARY) {
        fprintf(stderr, "[SOCKET_TRACE] UV_TAIL_CANARY_FAIL ctx=%p in %s "
                "(expected 0x%08X got 0x%08X) -- HANDLE OVERFLOW / ABI MISMATCH?\n",
                (void *)ctx, where, SOCKET_UV_TAIL_CANARY, ctx->uv_tail_canary);
        return -1;
    }
    lua_State *expected = default_luaL();
    if (expected && ctx->owner_L != expected) {
        fprintf(stderr,
                "[SOCKET_TRACE] BAD_LUA_STATE ctx=%p in %s (ctx->owner_L=%p expected=%p)\n",
                (void *)ctx, where, (void *)ctx->owner_L, (void *)expected);
        return -1;
    }
    return 0;
}

static void socket_bk_wait(socket_ctx_t *ctx, const char *op) {
    ctx->bk_event_seq++;
    if (strcmp(op, "read") == 0) {
        if (ctx->bk_read_inflight) {
            fprintf(stderr, "[SOCKET_TRACE] BK_FAIL duplicate read wait ctx=%p event=%d\n",
                    (void *)ctx, ctx->bk_event_seq);
            assert(!ctx->bk_read_inflight);
        }
        ctx->bk_read_inflight = 1;
        ctx->bk_read_wait_seq++;
    } else if (strcmp(op, "write") == 0) {
        if (ctx->bk_write_inflight) {
            fprintf(stderr, "[SOCKET_TRACE] BK_FAIL duplicate write wait ctx=%p event=%d\n",
                    (void *)ctx, ctx->bk_event_seq);
            assert(!ctx->bk_write_inflight);
        }
        ctx->bk_write_inflight = 1;
        ctx->bk_write_wait_seq++;
    } else if (strcmp(op, "accept") == 0) {
        if (ctx->bk_accept_inflight) {
            fprintf(stderr, "[SOCKET_TRACE] BK_FAIL duplicate accept wait ctx=%p event=%d\n",
                    (void *)ctx, ctx->bk_event_seq);
            assert(!ctx->bk_accept_inflight);
        }
        ctx->bk_accept_inflight = 1;
        ctx->bk_accept_wait_seq++;
    }
}

static void socket_bk_resume(socket_ctx_t *ctx, const char *op) {
    ctx->bk_event_seq++;
    if (strcmp(op, "read") == 0) {
        if (!ctx->bk_read_inflight) {
            fprintf(stderr, "[SOCKET_TRACE] BK_FAIL read resume without wait ctx=%p event=%d\n",
                    (void *)ctx, ctx->bk_event_seq);
            assert(ctx->bk_read_inflight);
        }
        ctx->bk_read_inflight = 0;
        ctx->bk_read_resume_seq++;
        if (ctx->bk_read_resume_seq > ctx->bk_read_wait_seq) {
            fprintf(stderr, "[SOCKET_TRACE] BK_FAIL read resume_seq=%d > wait_seq=%d ctx=%p\n",
                    ctx->bk_read_resume_seq, ctx->bk_read_wait_seq, (void *)ctx);
            assert(ctx->bk_read_resume_seq <= ctx->bk_read_wait_seq);
        }
    } else if (strcmp(op, "write") == 0) {
        if (!ctx->bk_write_inflight) {
            fprintf(stderr, "[SOCKET_TRACE] BK_FAIL write resume without wait ctx=%p event=%d\n",
                    (void *)ctx, ctx->bk_event_seq);
            assert(ctx->bk_write_inflight);
        }
        ctx->bk_write_inflight = 0;
        ctx->bk_write_resume_seq++;
        if (ctx->bk_write_resume_seq > ctx->bk_write_wait_seq) {
            fprintf(stderr, "[SOCKET_TRACE] BK_FAIL write resume_seq=%d > wait_seq=%d ctx=%p\n",
                    ctx->bk_write_resume_seq, ctx->bk_write_wait_seq, (void *)ctx);
            assert(ctx->bk_write_resume_seq <= ctx->bk_write_wait_seq);
        }
    } else if (strcmp(op, "accept") == 0) {
        if (!ctx->bk_accept_inflight) {
            fprintf(stderr, "[SOCKET_TRACE] BK_FAIL accept resume without wait ctx=%p event=%d\n",
                    (void *)ctx, ctx->bk_event_seq);
            assert(ctx->bk_accept_inflight);
        }
        ctx->bk_accept_inflight = 0;
        ctx->bk_accept_resume_seq++;
        if (ctx->bk_accept_resume_seq > ctx->bk_accept_wait_seq) {
            fprintf(stderr, "[SOCKET_TRACE] BK_FAIL accept resume_seq=%d > wait_seq=%d ctx=%p\n",
                    ctx->bk_accept_resume_seq, ctx->bk_accept_wait_seq, (void *)ctx);
            assert(ctx->bk_accept_resume_seq <= ctx->bk_accept_wait_seq);
        }
    }
}

static void socket_bk_cancel(socket_ctx_t *ctx, const char *op) {
    ctx->bk_event_seq++;
    if (strcmp(op, "read") == 0) {
        ctx->bk_read_inflight = 0;
    } else if (strcmp(op, "write") == 0) {
        ctx->bk_write_inflight = 0;
    } else if (strcmp(op, "accept") == 0) {
        ctx->bk_accept_inflight = 0;
    }
}

#ifdef LUNET_TRACE_VERBOSE
#define SOCKET_TRACE_LISTEN(ctx, domain, host, port) \
    do { socket_trace_listen_count++; \
         fprintf(stderr, "[SOCKET_TRACE] LISTEN #%d ctx=%p domain=%s %s:%d\n", \
                 socket_trace_listen_count, (void*)(ctx), \
                 (domain) == SOCKET_DOMAIN_TCP ? "tcp" : "unix", (host), (port)); \
    } while(0)

#define SOCKET_TRACE_ACCEPT(ctx) \
    do { socket_trace_accept_count++; \
         fprintf(stderr, "[SOCKET_TRACE] ACCEPT #%d ctx=%p\n", \
                 socket_trace_accept_count, (void*)(ctx)); \
    } while(0)

#define SOCKET_TRACE_CONNECT(ctx, host, port) \
    do { socket_trace_connect_count++; \
         fprintf(stderr, "[SOCKET_TRACE] CONNECT #%d ctx=%p -> %s:%d\n", \
                 socket_trace_connect_count, (void*)(ctx), (host), (port)); \
    } while(0)

#define SOCKET_TRACE_READ(ctx, nread) \
    do { socket_trace_read_count++; \
         fprintf(stderr, "[SOCKET_TRACE] READ #%d ctx=%p bytes=%zd\n", \
                 socket_trace_read_count, (void*)(ctx), (ssize_t)(nread)); \
    } while(0)

#define SOCKET_TRACE_WRITE_START(ctx, len) \
    do { socket_trace_write_count++; (ctx)->pending_writes++; \
         fprintf(stderr, "[SOCKET_TRACE] WRITE_START #%d ctx=%p bytes=%zu pending=%d\n", \
                 socket_trace_write_count, (void*)(ctx), (size_t)(len), (ctx)->pending_writes); \
    } while(0)

#define SOCKET_TRACE_WRITE_CB(ctx, status) \
    do { \
         fprintf(stderr, "[SOCKET_TRACE] WRITE_CB ctx=%p status=%d pending=%d\n", \
                 (void*)(ctx), (status), (ctx)->pending_writes); \
         (ctx)->pending_writes--; \
    } while(0)

#define SOCKET_TRACE_CLOSE(ctx) \
    do { socket_trace_close_count++; \
         fprintf(stderr, "[SOCKET_TRACE] CLOSE #%d ctx=%p type=%s pending_writes=%d\n", \
                 socket_trace_close_count, (void*)(ctx), \
                 (ctx)->type == SOCKET_SERVER ? "server" : "client", \
                 (ctx)->pending_writes); \
    } while(0)

#define SOCKET_TRACE_FREE(ctx) \
    fprintf(stderr, "[SOCKET_TRACE] FREE ctx=%p\n", (void*)(ctx))

#define SOCKET_TRACE_REF(ctx, op) ((void)0)
#define SOCKET_BK_WAIT(ctx, op) socket_bk_wait((ctx), (op))
#define SOCKET_BK_RESUME(ctx, op) socket_bk_resume((ctx), (op))
#define SOCKET_BK_CANCEL(ctx, op) socket_bk_cancel((ctx), (op))

#else /* LUNET_TRACE but not VERBOSE */

#define SOCKET_TRACE_LISTEN(ctx, domain, host, port) \
    do { socket_trace_listen_count++; } while(0)

#define SOCKET_TRACE_ACCEPT(ctx) \
    do { socket_trace_accept_count++; } while(0)

#define SOCKET_TRACE_CONNECT(ctx, host, port) \
    do { socket_trace_connect_count++; } while(0)

#define SOCKET_TRACE_READ(ctx, nread) \
    do { socket_trace_read_count++; } while(0)

#define SOCKET_TRACE_WRITE_START(ctx, len) \
    do { socket_trace_write_count++; (ctx)->pending_writes++; } while(0)

#define SOCKET_TRACE_WRITE_CB(ctx, status) \
    do { (ctx)->pending_writes--; } while(0)

#define SOCKET_TRACE_CLOSE(ctx) \
    do { socket_trace_close_count++; } while(0)

#define SOCKET_TRACE_FREE(ctx) ((void)0)
#define SOCKET_TRACE_REF(ctx, op) ((void)0)
#define SOCKET_BK_WAIT(ctx, op) socket_bk_wait((ctx), (op))
#define SOCKET_BK_RESUME(ctx, op) socket_bk_resume((ctx), (op))
#define SOCKET_BK_CANCEL(ctx, op) socket_bk_cancel((ctx), (op))

#endif /* LUNET_TRACE_VERBOSE */

void lunet_socket_trace_summary(void) {
    fprintf(stderr, "[SOCKET_TRACE] SUMMARY: listen=%d accept=%d connect=%d "
            "read=%d write=%d close=%d\n",
            socket_trace_listen_count, socket_trace_accept_count,
            socket_trace_connect_count, socket_trace_read_count,
            socket_trace_write_count, socket_trace_close_count);
}

#else /* !LUNET_TRACE */

#define socket_ctx_init_canary(ctx) ((void)0)
#define socket_ctx_check_canary(ctx, where) (0)
#define SOCKET_TRACE_LISTEN(ctx, domain, host, port) ((void)0)
#define SOCKET_TRACE_ACCEPT(ctx) ((void)0)
#define SOCKET_TRACE_CONNECT(ctx, host, port) ((void)0)
#define SOCKET_TRACE_READ(ctx, nread) ((void)0)
#define SOCKET_TRACE_WRITE_START(ctx, len) ((void)0)
#define SOCKET_TRACE_WRITE_CB(ctx, status) ((void)0)
#define SOCKET_TRACE_CLOSE(ctx) ((void)0)
#define SOCKET_TRACE_FREE(ctx) ((void)0)
#define SOCKET_TRACE_REF(ctx, op) ((void)0)
#define SOCKET_BK_WAIT(ctx, op) ((void)0)
#define SOCKET_BK_RESUME(ctx, op) ((void)0)
#define SOCKET_BK_CANCEL(ctx, op) ((void)0)

/* lunet_socket_trace_summary provided by socket.h as static inline */

#endif /* LUNET_TRACE */

static void socket_ctx_retain(socket_ctx_t *ctx) {
  if (!ctx) return;
  ctx->ref_count++;
}

static void socket_ctx_release(socket_ctx_t *ctx) {
  if (!ctx) return;
  ctx->ref_count--;
  if (ctx->ref_count == 0) {
    SOCKET_TRACE_FREE(ctx);
    if (ctx->type == SOCKET_SERVER) {
      queue_destroy(ctx->server.pending_accepts);
    }
    lunet_free(ctx);
  }
}

static void lunet_close_cb(uv_handle_t *handle) {
  socket_ctx_t *ctx = (socket_ctx_t *)handle->data;
  /* Null out handle->data FIRST so any straggler callback sees NULL */
  handle->data = NULL;
  if (ctx) {
    socket_handle_invalidate(ctx);
    /* Release the handle's reference. Pending ops (read/write) keep ctx alive. */
    socket_ctx_release(ctx);
  }
}

/* Wake the coroutine parked in socket.accept (if any) with (nil, errmsg).
 * Clears accept_ref; a no-op when nobody is waiting. Used by listen_cb
 * error paths, socket.close, and the catastrophic accept-failure path. */
static void lunet_accept_wake(socket_ctx_t *ctx, const char *errmsg) {
  if (ctx->server.accept_ref == LUA_NOREF) {
    return;
  }
  lua_State *co = ctx->owner_L;
  lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->server.accept_ref);
  lunet_coref_release(co, ctx->server.accept_ref);
  ctx->server.accept_ref = LUA_NOREF;
  SOCKET_BK_RESUME(ctx, "accept");

  if (lua_isthread(co, -1)) {
    lua_State *waiting_co = lua_tothread(co, -1);
    lua_pop(co, 1);

    lua_pushnil(waiting_co);
    lua_pushstring(waiting_co, errmsg);

    int resume_status = lunet_co_resume(waiting_co, 2);
    if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
      const char *err = lua_tostring(waiting_co, -1);
      if (err) {
        fprintf(stderr, "[lunet] resume error in accept wakeup: %s\n", err);
      }
    }
  } else {
    lua_pop(co, 1);
    fprintf(stderr,
            "[lunet] accept waiter's registry slot was not a coroutine\n");
  }
}

/* Wake the coroutine parked in socket.write (if any) with errmsg.
 * Clears write_ref; a no-op when nobody is waiting. Used by socket.close
 * and write_cb's close path so write waiters are never stranded. */
static void lunet_write_wake(socket_ctx_t *ctx, const char *errmsg) {
  if (ctx->client.write_ref == LUA_NOREF) {
    return;
  }

  lua_State *co = ctx->owner_L;
  lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->client.write_ref);
  lunet_coref_release(co, ctx->client.write_ref);
  ctx->client.write_ref = LUA_NOREF;
  SOCKET_BK_RESUME(ctx, "write");

  if (lua_isthread(co, -1)) {
    lua_State *waiting_co = lua_tothread(co, -1);
    lua_pop(co, 1);

    lua_pushstring(waiting_co, errmsg);

    int resume_status = lunet_co_resume(waiting_co, 1);
    if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
      const char *err = lua_tostring(waiting_co, -1);
      if (err) {
        fprintf(stderr, "[lunet] resume error in write wakeup: %s\n", err);
      }
    }
  } else {
    lua_pop(co, 1);
    fprintf(stderr,
            "[lunet] write waiter's registry slot was not a coroutine\n");
  }
}

static void lunet_drop_conn_cb(uv_handle_t *handle) {
  free(handle);
}

/* Close every connection that was accepted but never delivered to Lua.
 * queue_destroy (called later from socket_ctx_release) does NOT free
 * payloads, so each ctx is closed here and freed by its own close_cb. */
static void lunet_server_drain_pending(socket_ctx_t *ctx) {
  socket_ctx_t *pending;
  while ((pending = (socket_ctx_t *)queue_dequeue(ctx->server.pending_accepts)) != NULL) {
    pending->closing = 1;
    uv_close(&pending->u.handle, lunet_close_cb);
  }
}

/* libuv has already accept(2)-ed a pending connection into the server and
 * stops polling the listener until uv_accept() consumes it. When the real
 * client ctx cannot be built (OOM / handle init failure), accept onto a
 * throwaway handle and close it immediately so the listener is not wedged.
 * Returns 0 once the temporary handle is initialized and scheduled for close;
 * allocation/init failure returns -1. */
static int lunet_listen_drop_conn(uv_stream_t *server, socket_domain_t domain) {
  uv_handle_t *tmp = NULL;
  int ret;

  if (lunet_socket_test_fault_take("drop_fail")) {
    return -1;
  }

  if (domain == SOCKET_DOMAIN_TCP) {
    /* Emergency recovery path: avoid lunet_alloc here because this helper is
     * entered after the real client ctx allocation already failed. */
    tmp = (uv_handle_t *)malloc(sizeof(uv_tcp_t));
    if (!tmp) {
      return -1;
    }
    ret = uv_tcp_init(uv_default_loop(), (uv_tcp_t *)tmp);
  } else {
    tmp = (uv_handle_t *)malloc(sizeof(uv_pipe_t));
    if (!tmp) {
      return -1;
    }
    ret = uv_pipe_init(uv_default_loop(), (uv_pipe_t *)tmp, 0);
  }

  if (ret < 0) {
    free(tmp);
    return -1;
  }

  tmp->data = NULL;
  (void)uv_accept(server, (uv_stream_t *)tmp);
  uv_close(tmp, lunet_drop_conn_cb);
  return 0;
}

// write complete callback
static void lunet_write_cb(uv_write_t *req, int status) {
  write_req_t *write_req = (write_req_t *)req;
  socket_ctx_t *ctx = write_req->ctx;

#ifdef LUNET_TRACE_VERBOSE
  fprintf(stderr, "[SOCKET_TRACE] WRITE_CB_ENTER req=%p ctx=%p status=%d\n",
          (void *)write_req, (void *)ctx, status);
#endif

  /* ---- UAF guard ----
   * If close_cb already ran and socket_ctx_release freed ctx, write_req->ctx
   * may be stale. With refcount, ctx stays alive until we release. But if
   * something went very wrong, guard against NULL. */
  if (!ctx) {
    if (write_req->data) {
      lunet_free_nonnull(write_req->data);
    }
    lunet_free_nonnull(write_req);
    return;
  }

#ifdef LUNET_TRACE
  if (socket_ctx_check_canary(ctx, "lunet_write_cb") != 0) {
    if (write_req->data) {
      lunet_free(write_req->data);
    }
    lunet_free_nonnull(write_req);
    return;
  }
  SOCKET_TRACE_WRITE_CB(ctx, status);
#endif

  /* Handle is closing — wake the waiter with the close error and release. */
  if (ctx->closing) {
    lunet_write_wake(ctx, "socket closed");
    if (write_req->data) {
      lunet_free(write_req->data);
    }
    lunet_free_nonnull(write_req);
    socket_ctx_release(ctx);
    return;
  }

  if (ctx->client.write_ref != LUA_NOREF) {
    lua_State *co = ctx->owner_L;
    int write_ref = ctx->client.write_ref;
    ctx->client.write_ref = LUA_NOREF;

    lua_rawgeti(co, LUA_REGISTRYINDEX, write_ref);
    lunet_coref_release(co, write_ref);
    SOCKET_BK_RESUME(ctx, "write");

    if (lua_isthread(co, -1)) {
      lua_State *waiting_co = lua_tothread(co, -1);
      lua_pop(co, 1);

      if (status == 0) {
        lua_pushnil(waiting_co);
      } else {
        lua_pushstring(waiting_co, uv_strerror(status));
      }

      int resume_status = lunet_co_resume(waiting_co, 1);
      if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
        const char *err = lua_tostring(waiting_co, -1);
        if (err) {
          fprintf(stderr, "[lunet] resume error in lunet_write_cb: %s\n", err);
        }
      }
    } else {
      lua_pop(co, 1);  /* pop the non-thread value */
    }
  }

  // release write request and data
  if (write_req->data) {
    lunet_free(write_req->data);
  }
  lunet_free_nonnull(write_req);

  /* Release the write operation's reference */
  socket_ctx_release(ctx);
}

static void alloc_buffer(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf) {
  /* If handle is closing or ctx was already freed, return empty buffer.
   * libuv will then call read_cb with nread=UV_ENOBUFS which we handle. */
  if (!handle->data || uv_is_closing(handle)) {
    buf->base = NULL;
    buf->len = 0;
    return;
  }
  buf->base = lunet_alloc(read_buffer_size);
  buf->len = read_buffer_size;
}

static void lunet_read_cb(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf) {
  socket_ctx_t *ctx = (socket_ctx_t *)stream->data;

  uv_read_stop(stream);

  /* ---- UAF guard ----
   * If close_cb already ran, handle->data is NULL. Free the buffer and bail.
   * No socket_ctx_release here because the ctx is already gone. */
  if (!ctx) {
    if (buf && buf->base) {
      lunet_free_nonnull(buf->base);  /* must match lunet_alloc backend (libc or EasyMem) */
    }
    return;
  }

#ifdef LUNET_TRACE
  if (socket_ctx_check_canary(ctx, "lunet_read_cb") != 0) {
    if (buf && buf->base) {
      lunet_free_nonnull(buf->base);
    }
    /* Canary failed — ctx is garbage. Don't touch it further. */
    return;
  }
#endif

  /* Handle is closing — free buffer, release our retain, skip Lua resume */
  if (ctx->closing || uv_is_closing((uv_handle_t *)stream)) {
    if (buf && buf->base) {
      lunet_free_nonnull(buf->base);
    }
    /* Release the read_ref if still held, so the coref count balances */
    if (ctx->type == SOCKET_CLIENT && ctx->client.read_ref != LUA_NOREF) {
      lunet_coref_release(ctx->owner_L, ctx->client.read_ref);
      ctx->client.read_ref = LUA_NOREF;
      SOCKET_BK_CANCEL(ctx, "read");
    }
    socket_ctx_release(ctx);
    return;
  }

  SOCKET_TRACE_READ(ctx, nread);

  if (ctx->client.read_ref != LUA_NOREF) {
    lua_State *co = ctx->owner_L;
    int read_ref = ctx->client.read_ref;
    ctx->client.read_ref = LUA_NOREF;

#ifdef LUNET_TRACE_VERBOSE
    fprintf(stderr, "[SOCKET_TRACE] READ_CB_RESOLVE ctx=%p co=%p read_ref=%d\n",
            (void *)ctx, (void *)co, read_ref);
#endif

    lua_rawgeti(co, LUA_REGISTRYINDEX, read_ref);
    lunet_coref_release(co, read_ref);
    SOCKET_BK_RESUME(ctx, "read");

#ifdef LUNET_TRACE_VERBOSE
    fprintf(stderr, "[SOCKET_TRACE] READ_CB_GOT_REF type=%s\n",
            lua_typename(co, lua_type(co, -1)));
#endif

    if (lua_isthread(co, -1)) {
      lua_State *waiting_co = lua_tothread(co, -1);
      lua_pop(co, 1);

#ifdef LUNET_TRACE_VERBOSE
      fprintf(stderr, "[SOCKET_TRACE] READ_CB_PUSHING waiting_co=%p nread=%zd\n",
              (void *)waiting_co, (ssize_t)nread);
#endif

      if (nread > 0) {
        lua_pushlstring(waiting_co, buf->base, nread);
        lua_pushnil(waiting_co);
      } else if (nread == UV_EOF) {
        lua_pushnil(waiting_co);
        lua_pushnil(waiting_co);
      } else {
        lua_pushnil(waiting_co);
        lua_pushstring(waiting_co, uv_strerror(nread));
      }

#ifdef LUNET_TRACE_VERBOSE
      fprintf(stderr, "[SOCKET_TRACE] READ_CB_RESUMING waiting_co=%p\n",
              (void *)waiting_co);
#endif

      int resume_status = lunet_co_resume(waiting_co, 2);
      if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
        const char *err = lua_tostring(waiting_co, -1);
        if (err) {
          fprintf(stderr, "[lunet] resume error in on_read: %s\n", err);
        }
      }
    } else {
      lua_pop(co, 1);  /* pop the non-thread value */
    }
  }

  if (buf && buf->base) {
    lunet_free_nonnull(buf->base);
  }

  /* Release the read operation's reference */
  socket_ctx_release(ctx);
}

static void lunet_listen_cb(uv_stream_t *server, int status) {
  socket_ctx_t *ctx = (socket_ctx_t *)server->data;
  socket_ctx_t *client_ctx = NULL;

  if (status < 0) {
    lunet_accept_wake(ctx, uv_strerror(status));
    return;
  }

  // create new client connection
  if (!lunet_socket_test_fault_take("alloc_fail")) {
    client_ctx = lunet_alloc(sizeof(socket_ctx_t));
  }
  if (!client_ctx) {
    /* libuv has already accepted a pending connection: consume it or the
     * listener stops polling. If even that fails, close the listener and
     * wake any parked acceptor instead of wedging silently. */
    if (lunet_listen_drop_conn(server, ctx->domain) != 0) {
      ctx->closing = 1;
      lunet_accept_wake(ctx, "out of memory");
      lunet_server_drain_pending(ctx);
      uv_close(&ctx->u.handle, lunet_close_cb);
    }
    return;
  }

  client_ctx->owner_L = ctx->owner_L;
  client_ctx->type = SOCKET_CLIENT;
  client_ctx->domain = ctx->domain;
  client_ctx->closing = 0;
  client_ctx->ref_count = 1;
  client_ctx->handles = NULL;
  client_ctx->client.read_ref = LUA_NOREF;
  client_ctx->client.write_ref = LUA_NOREF;
  socket_ctx_init_canary(client_ctx);

  SOCKET_TRACE_ACCEPT(client_ctx);

  int ret = 0;
  if (ctx->domain == SOCKET_DOMAIN_TCP) {
      ret = uv_tcp_init(uv_default_loop(), &client_ctx->u.tcp);
  } else {
      ret = uv_pipe_init(uv_default_loop(), &client_ctx->u.pipe, 0);
  }

  if (ret < 0) {
    lunet_free(client_ctx);
    /* Same contract as the alloc-failure path above: the pending connection
     * must be consumed, and if it cannot be, fail loudly instead of
     * wedging the listener. */
    if (lunet_listen_drop_conn(server, ctx->domain) != 0) {
      ctx->closing = 1;
      lunet_accept_wake(ctx, uv_strerror(ret));
      lunet_server_drain_pending(ctx);
      uv_close(&ctx->u.handle, lunet_close_cb);
    }
    return;
  }

  client_ctx->u.handle.data = client_ctx;

  if (uv_accept(server, &client_ctx->u.stream) < 0) {
    uv_close(&client_ctx->u.handle, lunet_close_cb);
    return;
  }

  if (ctx->server.accept_ref != LUA_NOREF) {
    // there is a coroutine waiting for accept, wake it up
    lua_State *co = ctx->owner_L;
    lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->server.accept_ref);
    if (lunet_socket_test_fault_take("nonthread_waiter")) {
      lua_pop(co, 1);
      lua_pushboolean(co, 0);
    }
    lunet_coref_release(co, ctx->server.accept_ref);
    ctx->server.accept_ref = LUA_NOREF;
    SOCKET_BK_RESUME(ctx, "accept");

    if (lua_isthread(co, -1)) {
      lua_State *waiting_co = lua_tothread(co, -1);
      lua_pop(co, 1);

      if (socket_handle_new_protected(waiting_co, client_ctx) != 0) {
        /* OOM creating the handle userdata: the connection was already
         * accepted by libuv, but we cannot hand it to the waiter. Discard
         * the cpcall error message and close the orphaned connection rather
         * than leaving it (or the coroutine) stuck. */
        lua_pop(waiting_co, 1);
        fprintf(stderr, "[lunet] listen_cb: out of memory creating socket handle\n");
        client_ctx->closing = 1;
        uv_close(&client_ctx->u.handle, lunet_close_cb);
        lua_pushnil(waiting_co);
        lua_pushstring(waiting_co, "out of memory");
        int resume_status = lunet_co_resume(waiting_co, 2);
        if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
          const char *err = lua_tostring(waiting_co, -1);
          if (err) {
            fprintf(stderr, "[lunet] resume error in listen_cb (OOM path): %s\n", err);
          }
        }
        return;
      }
      lua_pushnil(waiting_co);

      int resume_status = lunet_co_resume(waiting_co, 2);
      if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
        const char *err = lua_tostring(waiting_co, -1);
        if (err) {
          fprintf(stderr, "[lunet] resume error in listen_cb: %s\n", err);
        }
      }
    } else {
      /* accept_ref was cleared above but the registry slot does not hold the
       * waiting coroutine (ref aliasing, or a waiter that died without
       * clearing accept_ref). The connection is fully accepted and must not
       * be lost: park it on the pending queue so a later socket.accept
       * delivers it, pop the non-thread value, and make the corruption
       * visible instead of hanging silently. */
      lua_pop(co, 1);
      fprintf(stderr,
              "[lunet] listen_cb: accept waiter's registry slot was not a "
              "coroutine; connection queued for a later accept\n");
      if (lunet_pending_accept_enqueue(ctx, client_ctx) != 0) {
        client_ctx->closing = 1;
        uv_close(&client_ctx->u.handle, lunet_close_cb);
      }
    }
  } else {
    // there is no coroutine waiting for accept, put the connection into the queue
    if (lunet_pending_accept_enqueue(ctx, client_ctx) != 0) {
      // queue is full or error, close the connection
      client_ctx->closing = 1;
      uv_close(&client_ctx->u.handle, lunet_close_cb);
    }
  }
}

int lunet_socket_listen(lua_State *co) {
  if (lunet_ensure_coroutine(co, "socket.listen") != 0) {
    return lua_error(co);
  }
  const char *protocol = luaL_checkstring(co, 1);
  const char *host = luaL_checkstring(co, 2);
  int port = luaL_checkinteger(co, 3);

  socket_domain_t domain;
  if (strcmp(protocol, "tcp") == 0) {
      domain = SOCKET_DOMAIN_TCP;
      // Check for secure binding configuration
      if (!g_lunet_config.dangerously_skip_loopback_restriction && !is_loopback_address(host)) {
        lua_pushnil(co);
        lua_pushstring(co, "binding to non-loopback addresses requires --dangerously-skip-loopback-restriction flag");
        return 2;
      }
      if (port < 1 || port > 65535) {
        lua_pushnil(co);
        lua_pushstring(co, "port must be between 1 and 65535");
        return 2;
      }
  } else if (strcmp(protocol, "unix") == 0) {
      domain = SOCKET_DOMAIN_UNIX;
  } else {
      lua_pushnil(co);
      lua_pushstring(co, "only tcp and unix are supported");
      return 2;
  }

  socket_ctx_t *ctx = lunet_alloc(sizeof(socket_ctx_t));
  if (!ctx) {
    lua_pushnil(co);
    lua_pushstring(co, "out of memory");
    return 2;
  }
  /* Use the main Lua state for registry operations; the calling coroutine may
   * finish synchronously and be GC'ed while sockets are still alive. */
  lua_State *mainL = default_luaL();
  ctx->owner_L = mainL ? mainL : co;
  ctx->type = SOCKET_SERVER;
  ctx->domain = domain;
  ctx->closing = 0;
  ctx->ref_count = 1;
  ctx->handles = NULL;
  ctx->server.accept_ref = LUA_NOREF;
  ctx->server.pending_accepts = queue_init();
  socket_ctx_init_canary(ctx);
  if (!ctx->server.pending_accepts) {
    lunet_free(ctx);
    lua_pushnil(co);
    lua_pushstring(co, "out of memory");
    return 2;
  }

  int ret = 0;
  if (domain == SOCKET_DOMAIN_TCP) {
      if ((ret = uv_tcp_init(uv_default_loop(), &ctx->u.tcp)) < 0) {
        queue_destroy(ctx->server.pending_accepts);
        lunet_free(ctx);
        lua_pushnil(co);
        lua_pushfstring(co, "failed to initialize TCP: %s", uv_strerror(ret));
        return 2;
      }
  } else {
      if ((ret = uv_pipe_init(uv_default_loop(), &ctx->u.pipe, 0)) < 0) {
        queue_destroy(ctx->server.pending_accepts);
        lunet_free(ctx);
        lua_pushnil(co);
        lua_pushfstring(co, "failed to initialize Pipe: %s", uv_strerror(ret));
        return 2;
      }
  }

  ctx->u.handle.data = ctx;

  if (domain == SOCKET_DOMAIN_TCP) {
      struct sockaddr_in addr;
      if (uv_ip4_addr(host, port, &addr) < 0) {
        uv_close(&ctx->u.handle, lunet_close_cb);
        lua_pushnil(co);
        lua_pushstring(co, "invalid host or port");
        return 2;
      }
      if ((ret = uv_tcp_bind(&ctx->u.tcp, (const struct sockaddr *)&addr, 0)) < 0) {
        uv_close(&ctx->u.handle, lunet_close_cb);
        lua_pushnil(co);
        lua_pushfstring(co, "failed to bind: %s", uv_strerror(ret));
        return 2;
      }
  } else {
      // Unix socket: remove file if exists
      #ifndef _WIN32
      unlink(host);
      #endif
      if ((ret = uv_pipe_bind(&ctx->u.pipe, host)) < 0) {
        uv_close(&ctx->u.handle, lunet_close_cb);
        lua_pushnil(co);
        lua_pushfstring(co, "failed to bind unix socket: %s", uv_strerror(ret));
        return 2;
      }
  }

  if ((ret = uv_listen(&ctx->u.stream, 128, lunet_listen_cb)) < 0) {
    uv_close(&ctx->u.handle, lunet_close_cb);
    lua_pushnil(co);
    lua_pushfstring(co, "failed to listen: %s", uv_strerror(ret));
    return 2;
  }

  SOCKET_TRACE_LISTEN(ctx, domain, host, port);
  
  socket_handle_new(co, ctx);
  lua_pushnil(co);
  return 2;
}

int lunet_socket_accept(lua_State *co) {
  if (lunet_ensure_coroutine(co, "socket.accept") != 0) {
    return lua_error(co);
  }

  socket_handle_t *listener_handle = socket_handle_check(co, 1);
  if (!listener_handle) {
    lua_pushnil(co);
    lua_pushstring(co, "invalid listener handle");
    return 2;
  }

  socket_ctx_t *listener_ctx = socket_handle_get(listener_handle);
  if (!listener_ctx || listener_ctx->type != SOCKET_SERVER) {
    lua_pushnil(co);
    lua_pushstring(co, listener_ctx ? "not a listening socket" : "listener closed");
    return 2;
  }

  /* Refuse to park on a closing listener: no listen_cb can ever fire, so
   * yielding here would hang the coroutine forever. */
  if (listener_ctx->closing) {
    lua_pushnil(co);
    lua_pushstring(co, "listener closed");
    return 2;
  }

  // there is a coroutine waiting for accept
  if (listener_ctx->server.accept_ref != LUA_NOREF) {
    lua_pushnil(co);
    lua_pushstring(co, "another accept already in progress");
    return 2;
  }

  // there is a connection in the queue
  if (!queue_is_empty(listener_ctx->server.pending_accepts)) {
    socket_ctx_t *client_ctx = (socket_ctx_t *)queue_dequeue(listener_ctx->server.pending_accepts);
    if (client_ctx) {
      socket_handle_new(co, client_ctx);
      lua_pushnil(co);
      return 2;
    }
  }

  // there is no connection in the queue, wait for new connection
  // save the current coroutine reference
  lunet_coref_create(co, listener_ctx->server.accept_ref);
  SOCKET_BK_WAIT(listener_ctx, "accept");

  // yield to wait for new connection
  return lua_yield(co, 0);
}

int lunet_socket_getpeername(lua_State *L) {
  if (lunet_ensure_coroutine(L, "socket.getpeername") != 0) {
    return lua_error(L);
  }

  socket_handle_t *handle = socket_handle_check(L, 1);
  if (!handle) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid socket handle");
    return 2;
  }

  socket_ctx_t *ctx = socket_handle_get(handle);
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "socket closed");
    return 2;
  }

  if (ctx->domain == SOCKET_DOMAIN_TCP) {
      struct sockaddr_in addr;
      int addr_len = sizeof(addr);
      int ret = uv_tcp_getpeername(&ctx->u.tcp, (struct sockaddr *)&addr, &addr_len);
      if (ret < 0) {
        lua_pushnil(L);
        lua_pushfstring(L, "failed to get peer name: %s", uv_strerror(ret));
        return 2;
      }

      char buf[INET_ADDRSTRLEN];
      if (uv_ip4_name(&addr, buf, sizeof(buf)) < 0) {
        lua_pushnil(L);
        lua_pushstring(L, "failed to get peer name");
        return 2;
      }

      lua_pushfstring(L, "%s:%d", buf, ntohs(addr.sin_port));
  } else {
      // Unix socket: return empty string or path if available?
      // uv_pipe_getpeername
      // For now, return "unix"
      lua_pushstring(L, "unix");
  }
  
  lua_pushnil(L);
  return 2;
}

int lunet_socket_close(lua_State *L) {
  socket_handle_t *handle = socket_handle_check(L, 1);
  if (!handle) {
    lua_pushstring(L, "invalid socket handle");
    return 1;
  }

  socket_ctx_t *ctx = socket_handle_get(handle);
  if (!ctx) {
    lua_pushnil(L);
    return 1;
  }

  SOCKET_TRACE_CLOSE(ctx);

  if (!ctx->closing) {
      ctx->closing = 1;

      if (ctx->type == SOCKET_SERVER) {
        /* Wake a coroutine parked in socket.accept: no listen_cb can fire
         * after close, so without this it would hang forever with its coref
         * leaked. */
        lunet_accept_wake(ctx, "listener closed");

        /* Drain connections that were accepted but never delivered to Lua. */
        lunet_server_drain_pending(ctx);
      } else {
        /* Stop reading immediately so libuv won't fire read_cb after close */
        uv_read_stop(&ctx->u.stream);

        /* Coroutines parked in socket.read/write can never make forward
         * progress after close; resume them with an error now. */
        if (ctx->client.read_ref != LUA_NOREF) {
          lua_State *co = ctx->owner_L;
          lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->client.read_ref);
          lunet_coref_release(co, ctx->client.read_ref);
          ctx->client.read_ref = LUA_NOREF;
          SOCKET_BK_CANCEL(ctx, "read");

          if (lua_isthread(co, -1)) {
            lua_State *waiting_co = lua_tothread(co, -1);
            lua_pop(co, 1);

            lua_pushnil(waiting_co);
            lua_pushstring(waiting_co, "socket closed");

            int resume_status = lunet_co_resume(waiting_co, 2);
            if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
              const char *err = lua_tostring(waiting_co, -1);
              if (err) {
                fprintf(stderr, "[lunet] resume error in socket_close: %s\n", err);
              }
            }
          } else {
            lua_pop(co, 1);
            fprintf(stderr,
                    "[lunet] socket_close: read waiter's registry slot was "
                    "not a coroutine\n");
          }

          socket_ctx_release(ctx);
        }

        lunet_write_wake(ctx, "socket closed");
      }

      uv_close(&ctx->u.handle, lunet_close_cb);
  }

  lua_pushnil(L);
  return 1;
}

int lunet_socket_read(lua_State *co) {
  if (lunet_ensure_coroutine(co, "socket.read") != 0) {
    return lua_error(co);
  }

  socket_handle_t *handle = socket_handle_check(co, 1);
  if (!handle) {
    lua_pushnil(co);
    lua_pushstring(co, "invalid socket handle");
    return 2;
  }

  socket_ctx_t *ctx = socket_handle_get(handle);
  if (!ctx || ctx->type != SOCKET_CLIENT) {
    lua_pushnil(co);
    lua_pushstring(co, ctx ? "invalid client socket handle" : "socket closed");
    return 2;
  }

  /* Refuse to park on a closing socket: read_cb is stopped at close, so
   * yielding here would hang the coroutine forever. */
  if (ctx->closing) {
    lua_pushnil(co);
    lua_pushstring(co, "socket closed");
    return 2;
  }

  // there is a read already in progress
  if (ctx->client.read_ref != LUA_NOREF) {
    lua_pushnil(co);
    lua_pushstring(co, "another read already in progress");
    return 2;
  }

  // save the coroutine reference
  lunet_coref_create(co, ctx->client.read_ref);
  SOCKET_BK_WAIT(ctx, "read");

  // start reading
  socket_ctx_retain(ctx);
  int ret = uv_read_start(&ctx->u.stream, alloc_buffer, lunet_read_cb);
  if (ret < 0) {
    socket_ctx_release(ctx);
    // failed to start reading, clean up the reference
    lunet_coref_release(co, ctx->client.read_ref);
    ctx->client.read_ref = LUA_NOREF;
    SOCKET_BK_CANCEL(ctx, "read");

    lua_pushnil(co);
    lua_pushfstring(co, "failed to start reading: %s", uv_strerror(ret));
    return 2;
  }

  return lua_yield(co, 0);
}

int lunet_socket_write(lua_State *co) {
  if (lunet_ensure_coroutine(co, "socket.write") != 0) {
    return lua_error(co);
  }

  socket_handle_t *handle = socket_handle_check(co, 1);
  if (!handle) {
    lua_pushstring(co, "invalid socket handle");
    return 1;
  }

  if (!lua_isstring(co, 2)) {
    lua_pushstring(co, "data must be a string");
    return 1;
  }

  socket_ctx_t *ctx = socket_handle_get(handle);
  if (!ctx || ctx->type != SOCKET_CLIENT) {
    lua_pushstring(co, ctx ? "invalid client socket handle" : "socket closed");
    return 1;
  }

  if (ctx->closing) {
    lua_pushstring(co, "socket closed");
    return 1;
  }

  // check if there is a write already in progress
  if (ctx->client.write_ref != LUA_NOREF) {
    lua_pushstring(co, "another write already in progress");
    return 1;
  }

  // get the data
  size_t data_len;
  const char *data = lua_tolstring(co, 2, &data_len);

  // allocate write request
  write_req_t *write_req = lunet_alloc(sizeof(write_req_t));
  if (!write_req) {
    lua_pushstring(co, "out of memory");
    return 1;
  }

  // copy data to heap memory
  write_req->data = lunet_alloc(data_len);
  if (!write_req->data) {
    lunet_free(write_req);
    lua_pushstring(co, "out of memory");
    return 1;
  }
  memcpy(write_req->data, data, data_len);

  write_req->ctx = ctx;

  // set the buffer
  uv_buf_t buf = uv_buf_init(write_req->data, data_len);

  // save the coroutine reference
  lunet_coref_create(co, ctx->client.write_ref);
  SOCKET_BK_WAIT(ctx, "write");

  SOCKET_TRACE_WRITE_START(ctx, data_len);

  /* Hold ctx alive until write callback fires */
  socket_ctx_retain(ctx);

  // start writing
  int ret = uv_write(&write_req->req, &ctx->u.stream, &buf, 1, lunet_write_cb);
  if (ret < 0) {
    socket_ctx_release(ctx);
    // failed to start writing, clean up the resource
    lunet_coref_release(co, ctx->client.write_ref);
    ctx->client.write_ref = LUA_NOREF;
    SOCKET_BK_CANCEL(ctx, "write");
    lunet_free(write_req->data);
    lunet_free(write_req);

    lua_pushfstring(co, "failed to start writing: %s", uv_strerror(ret));
    return 1;
  }

  // yield to wait for write to complete
  return lua_yield(co, 0);
}

typedef struct {
  uv_connect_t req;
  socket_ctx_t *ctx;
  /* Calling coroutine state, valid for the op's lifetime via co_ref. */
  lua_State *waiter_L;
  int co_ref;
  char err[256];
} connect_ctx_t;

static void lunet_connect_cb(uv_connect_t *req, int status) {
  connect_ctx_t *ctx = (connect_ctx_t *)req->data;
  lua_State *co = ctx->waiter_L;

  // resume coroutine
  lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(co, ctx->co_ref);
  ctx->co_ref = LUA_NOREF;
  /* rawgeti pushed the waiter thread itself; drop it so it does not sit
   * below the resume arguments, matching the other async callbacks. */
  lua_pop(co, 1);

  if (status == 0) {
    if (socket_handle_new_protected(co, ctx->ctx) != 0) {
      /* OOM creating the handle userdata: discard the cpcall error message
       * and close the connected socket rather than leaving it unreachable. */
      lua_pop(co, 1);
      fprintf(stderr, "[lunet] connect_cb: out of memory creating socket handle\n");
      ctx->ctx->closing = 1;
      uv_close(&ctx->ctx->u.handle, lunet_close_cb);
      lua_pushnil(co);
      lua_pushstring(co, "out of memory");
    } else {
      lua_pushnil(co);
    }
  } else {
    lua_pushnil(co);
    lua_pushstring(co, uv_strerror(status));
  }

  int resume_status = lunet_co_resume(co, 2);
  if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
    const char *err = lua_tostring(co, -1);
    if (err) {
      fprintf(stderr, "[lunet] resume error in connect_cb: %s\n", err);
    }
  }

  lunet_free_nonnull(ctx);
}

int lunet_socket_connect(lua_State *L) {
  if (lunet_ensure_coroutine(L, "socket.connect") != 0) {
    return lua_error(L);
  }

  const char *host = luaL_checkstring(L, 1);
  int port = luaL_checkinteger(L, 2);

  socket_domain_t domain = SOCKET_DOMAIN_TCP;
  if (strchr(host, '/') != NULL) {
      domain = SOCKET_DOMAIN_UNIX;
  } else {
      if (port < 1 || port > 65535) {
        lua_pushnil(L);
        lua_pushstring(L, "port must be between 1 and 65535");
        return 2;
      }
  }

  socket_ctx_t *ctx = lunet_alloc(sizeof(socket_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  /* Use the main Lua state for registry operations; the connect coroutine is
   * tracked via connect_ctx->co_ref and resumed via connect_ctx->waiter_L. */
  lua_State *mainL = default_luaL();
  ctx->owner_L = mainL ? mainL : L;
  ctx->type = SOCKET_CLIENT;
  ctx->domain = domain;
  ctx->closing = 0;
  ctx->ref_count = 1;
  ctx->handles = NULL;
  ctx->client.read_ref = LUA_NOREF;
  ctx->client.write_ref = LUA_NOREF;
  socket_ctx_init_canary(ctx);

  int ret = 0;
  if (domain == SOCKET_DOMAIN_TCP) {
      ret = uv_tcp_init(uv_default_loop(), &ctx->u.tcp);
  } else {
      ret = uv_pipe_init(uv_default_loop(), &ctx->u.pipe, 0);
  }

  if (ret < 0) {
    lunet_free(ctx);
    lua_pushnil(L);
    lua_pushfstring(L, "failed to initialize socket: %s", uv_strerror(ret));
    return 2;
  }

  ctx->u.handle.data = ctx;

  connect_ctx_t *connect_ctx = lunet_alloc(sizeof(connect_ctx_t));
  if (!connect_ctx) {
    uv_close(&ctx->u.handle, lunet_close_cb);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  connect_ctx->ctx = ctx;
  connect_ctx->waiter_L = L;
  connect_ctx->co_ref = LUA_NOREF;
  connect_ctx->req.data = connect_ctx;

  // save coroutine reference, for resume in connect_cb
  lunet_coref_create(L, connect_ctx->co_ref);

  SOCKET_TRACE_CONNECT(ctx, host, port);

  if (domain == SOCKET_DOMAIN_TCP) {
      struct sockaddr_in dest;
      ret = uv_ip4_addr(host, port, &dest);
      if (ret < 0) {
        lunet_coref_release(L, connect_ctx->co_ref);
        connect_ctx->co_ref = LUA_NOREF;
        lunet_free(connect_ctx);
        uv_close(&ctx->u.handle, lunet_close_cb);
        lua_pushnil(L);
        lua_pushstring(L, "invalid host or port");
        return 2;
      }
      ret = uv_tcp_connect(&connect_ctx->req, &ctx->u.tcp, (const struct sockaddr *)&dest, lunet_connect_cb);
  } else {
      uv_pipe_connect(&connect_ctx->req, &ctx->u.pipe, host, lunet_connect_cb);
      ret = 0;
  }
  
  if (ret < 0) {
    lunet_coref_release(L, connect_ctx->co_ref);
    connect_ctx->co_ref = LUA_NOREF;
    lunet_free(connect_ctx);
    uv_close(&ctx->u.handle, lunet_close_cb);
    lua_pushnil(L);
    lua_pushfstring(L, "failed to start connect: %s", uv_strerror(ret));
    return 2;
  }

  // yield to wait for connection to complete
  return lua_yield(L, 0);
}

int lunet_socket_set_read_buffer_size(lua_State *L) {
  if (lua_isnumber(L, 1)) {
    read_buffer_size = lua_tointeger(L, 1);
  }
  lua_pushnil(L);
  return 1;
}

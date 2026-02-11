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
#include <uv.h>

#include "co.h"
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

/* Canary value for socket contexts - ASCII "SOCK" */
#define SOCKET_CTX_CANARY 0x534F434BU

typedef struct {
  union {
    uv_tcp_t tcp;
    uv_pipe_t pipe;
    uv_handle_t handle;
    uv_stream_t stream;
  } u;
  socket_domain_t domain;

  lua_State *co;
  socket_type_t type;
  int closing;
  int ref_count;

#ifdef LUNET_TRACE
  uint32_t canary;
  int pending_writes;
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

} socket_ctx_t;

// write request structure
typedef struct {
  uv_write_t req;
  socket_ctx_t *ctx;
  char *data;
} write_req_t;

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
    return 0;
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
    /* Release the handle's reference. Pending ops (read/write) keep ctx alive. */
    socket_ctx_release(ctx);
  }
}

// write complete callback
static void lunet_write_cb(uv_write_t *req, int status) {
  write_req_t *write_req = (write_req_t *)req;
  socket_ctx_t *ctx = write_req->ctx;

#ifdef LUNET_TRACE_VERBOSE
  fprintf(stderr, "[SOCKET_TRACE] WRITE_CB_ENTER req=%p ctx=%p status=%d\n",
          (void *)write_req, (void *)ctx, status);
#endif

  /* ---- UAF guard (Issue #50) ----
   * If close_cb already ran and socket_ctx_release freed ctx, write_req->ctx
   * may be stale. With refcount, ctx stays alive until we release. But if
   * something went very wrong, guard against NULL. */
  if (!ctx) {
    if (write_req->data) {
      free(write_req->data);
    }
    free(write_req);
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

  /* Handle is closing — free resources, release coref, release retain, skip Lua resume */
  if (ctx->closing) {
    if (ctx->client.write_ref != LUA_NOREF) {
      lunet_coref_release(ctx->co, ctx->client.write_ref);
      ctx->client.write_ref = LUA_NOREF;
    }
    if (write_req->data) {
      lunet_free(write_req->data);
    }
    lunet_free_nonnull(write_req);
    socket_ctx_release(ctx);
    return;
  }

  if (ctx->client.write_ref != LUA_NOREF) {
    lua_State *co = ctx->co;
    int write_ref = ctx->client.write_ref;
    ctx->client.write_ref = LUA_NOREF;

    lua_rawgeti(co, LUA_REGISTRYINDEX, write_ref);
    lunet_coref_release(co, write_ref);

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

  /* ---- UAF guard (Issue #50) ----
   * If close_cb already ran, handle->data is NULL. Free the buffer and bail.
   * No socket_ctx_release here because the ctx is already gone. */
  if (!ctx) {
    if (buf && buf->base) {
      free(buf->base);  /* raw free: ctx/lunet_mem may already be torn down */
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
      lunet_coref_release(ctx->co, ctx->client.read_ref);
      ctx->client.read_ref = LUA_NOREF;
    }
    socket_ctx_release(ctx);
    return;
  }

  SOCKET_TRACE_READ(ctx, nread);

  if (ctx->client.read_ref != LUA_NOREF) {
    lua_State *co = ctx->co;
    int read_ref = ctx->client.read_ref;
    ctx->client.read_ref = LUA_NOREF;

    lua_rawgeti(co, LUA_REGISTRYINDEX, read_ref);
    lunet_coref_release(co, read_ref);

    if (lua_isthread(co, -1)) {
      lua_State *waiting_co = lua_tothread(co, -1);
      lua_pop(co, 1);

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

  if (status < 0) {
    // there is a coroutine waiting for accept
    if (ctx->server.accept_ref != LUA_NOREF) {
      lua_State *co = ctx->co;
      lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->server.accept_ref);
      lunet_coref_release(co, ctx->server.accept_ref);
      ctx->server.accept_ref = LUA_NOREF;

      if (lua_isthread(co, -1)) {
        lua_State *waiting_co = lua_tothread(co, -1);
        lua_pop(co, 1);

        lua_pushnil(waiting_co);
        lua_pushstring(waiting_co, uv_strerror(status));

        int resume_status = lunet_co_resume(waiting_co, 2);
        if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
          const char *err = lua_tostring(waiting_co, -1);
          if (err) {
            fprintf(stderr, "[lunet] resume error in listen_cb: %s\n", err);
          }
        }
      }
    }
    return;
  }

  // create new client connection
  socket_ctx_t *client_ctx = lunet_alloc(sizeof(socket_ctx_t));
  if (!client_ctx) {
    return;  // ignore this connection
  }

  client_ctx->co = ctx->co;
  client_ctx->type = SOCKET_CLIENT;
  client_ctx->domain = ctx->domain;
  client_ctx->closing = 0;
  client_ctx->ref_count = 1;
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
    return;
  }

  client_ctx->u.handle.data = client_ctx;

  if (uv_accept(server, &client_ctx->u.stream) < 0) {
    uv_close(&client_ctx->u.handle, lunet_close_cb);
    return;
  }

  if (ctx->server.accept_ref != LUA_NOREF) {
    // there is a coroutine waiting for accept, wake it up
    lua_State *co = ctx->co;
    lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->server.accept_ref);
    lunet_coref_release(co, ctx->server.accept_ref);
    ctx->server.accept_ref = LUA_NOREF;

    if (lua_isthread(co, -1)) {
      lua_State *waiting_co = lua_tothread(co, -1);
      lua_pop(co, 1);

      lua_pushlightuserdata(waiting_co, client_ctx);
      lua_pushnil(waiting_co);

      int resume_status = lunet_co_resume(waiting_co, 2);
      if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
        const char *err = lua_tostring(waiting_co, -1);
        if (err) {
          fprintf(stderr, "[lunet] resume error in listen_cb: %s\n", err);
        }
      }
    }
  } else {
    // there is no coroutine waiting for accept, put the connection into the queue
    if (queue_enqueue(ctx->server.pending_accepts, client_ctx) != 0) {
      // queue is full or error, close the connection
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
  ctx->co = co;
  ctx->type = SOCKET_SERVER;
  ctx->domain = domain;
  ctx->closing = 0;
  ctx->ref_count = 1;
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
  
  lua_pushlightuserdata(co, ctx);
  lua_pushnil(co);
  return 2;
}

int lunet_socket_accept(lua_State *co) {
  if (lunet_ensure_coroutine(co, "socket.accept") != 0) {
    return lua_error(co);
  }

  if (!lua_islightuserdata(co, 1)) {
    lua_pushnil(co);
    lua_pushstring(co, "invalid listener handle");
    return 2;
  }

  socket_ctx_t *listener_ctx = (socket_ctx_t *)lua_touserdata(co, 1);
  if (!listener_ctx) {
    lua_pushnil(co);
    lua_pushstring(co, "invalid listener handle");
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
      lua_pushlightuserdata(co, client_ctx);
      lua_pushnil(co);
      return 2;
    }
  }

  // there is no connection in the queue, wait for new connection
  // save the current coroutine reference
  lunet_coref_create(co, listener_ctx->server.accept_ref);

  // yield to wait for new connection
  return lua_yield(co, 0);
}

int lunet_socket_getpeername(lua_State *L) {
  if (lunet_ensure_coroutine(L, "socket.getpeername") != 0) {
    return lua_error(L);
  }

  if (!lua_islightuserdata(L, 1)) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid socket handle");
    return 2;
  }

  socket_ctx_t *ctx = (socket_ctx_t *)lua_touserdata(L, 1);
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid socket handle");
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
  if (!lua_islightuserdata(L, 1)) {
    lua_pushstring(L, "invalid socket handle");
    return 1;
  }

  socket_ctx_t *ctx = (socket_ctx_t *)lua_touserdata(L, 1);
  if (!ctx) {
    lua_pushstring(L, "invalid socket handle");
    return 1;
  }

  SOCKET_TRACE_CLOSE(ctx);

  if (!ctx->closing) {
      ctx->closing = 1;

      /* Stop reading immediately so libuv won't fire read_cb after close */
      if (ctx->type == SOCKET_CLIENT) {
        uv_read_stop(&ctx->u.stream);
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

  if (!lua_islightuserdata(co, 1)) {
    lua_pushnil(co);
    lua_pushstring(co, "invalid socket handle");
    return 2;
  }

  socket_ctx_t *ctx = (socket_ctx_t *)lua_touserdata(co, 1);
  if (!ctx || ctx->type != SOCKET_CLIENT) {
    lua_pushnil(co);
    lua_pushstring(co, "invalid client socket handle");
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

  // start reading
  socket_ctx_retain(ctx);
  int ret = uv_read_start(&ctx->u.stream, alloc_buffer, lunet_read_cb);
  if (ret < 0) {
    socket_ctx_release(ctx);
    // failed to start reading, clean up the reference
    lunet_coref_release(co, ctx->client.read_ref);
    ctx->client.read_ref = LUA_NOREF;

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

  if (!lua_islightuserdata(co, 1)) {
    lua_pushstring(co, "invalid socket handle");
    return 1;
  }

  if (!lua_isstring(co, 2)) {
    lua_pushstring(co, "data must be a string");
    return 1;
  }

  socket_ctx_t *ctx = (socket_ctx_t *)lua_touserdata(co, 1);
  if (!ctx || ctx->type != SOCKET_CLIENT) {
    lua_pushstring(co, "invalid client socket handle");
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
  lua_State *co;
  int co_ref;
  char err[256];
} connect_ctx_t;

static void lunet_connect_cb(uv_connect_t *req, int status) {
  connect_ctx_t *ctx = (connect_ctx_t *)req->data;
  lua_State *co = ctx->co;

  // resume coroutine
  lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(co, ctx->co_ref);
  ctx->co_ref = LUA_NOREF;

  if (status == 0) {
    lua_pushlightuserdata(co, ctx->ctx);
    lua_pushnil(co);
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

  ctx->co = L;
  ctx->type = SOCKET_CLIENT;
  ctx->domain = domain;
  ctx->closing = 0;
  ctx->ref_count = 1;
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
  connect_ctx->co = L;
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

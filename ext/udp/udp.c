#include "lunet_udp.h"

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#endif

#include <stdlib.h>
#include <string.h>
#include <uv.h>

#include "co.h"
#include "stl.h"
#include "trace.h"

typedef struct {
  uv_udp_t handle;
  queue_t *pending;
  lua_State *co;
  int recv_ref;
#ifdef LUNET_TRACE
  int trace_tx;
  int trace_rx;
#endif
} udp_ctx_t;

#ifdef LUNET_TRACE

static int udp_trace_tx_count = 0;
static int udp_trace_rx_count = 0;
static int udp_trace_bind_count = 0;

static void udp_trace_bind_actual(uv_udp_t *handle) {
    struct sockaddr_storage addr;
    int namelen = sizeof(addr);
    char host[INET6_ADDRSTRLEN];
    int port = 0;
    
    if (uv_udp_getsockname(handle, (struct sockaddr *)&addr, &namelen) == 0) {
        if (addr.ss_family == AF_INET) {
            struct sockaddr_in *a4 = (struct sockaddr_in *)&addr;
            uv_ip4_name(a4, host, sizeof(host));
            port = ntohs(a4->sin_port);
        } else if (addr.ss_family == AF_INET6) {
            struct sockaddr_in6 *a6 = (struct sockaddr_in6 *)&addr;
            uv_ip6_name(a6, host, sizeof(host));
            port = ntohs(a6->sin6_port);
        } else {
            snprintf(host, sizeof(host), "unknown");
        }
    } else {
        snprintf(host, sizeof(host), "?");
    }
    
    udp_trace_bind_count++;
    fprintf(stderr, "[UDP_TRACE] BIND #%d %s:%d\n", udp_trace_bind_count, host, port);
}

#define UDP_TRACE_BIND(handle) udp_trace_bind_actual(handle)

#define UDP_TRACE_TX(ctx, dest_host, dest_port, len) \
    do { \
        udp_trace_tx_count++; \
        (ctx)->trace_tx++; \
        fprintf(stderr, "[UDP_TRACE] TX #%d -> %s:%d (%zu bytes)\n", \
                udp_trace_tx_count, (dest_host), (dest_port), (size_t)(len)); \
    } while(0)

#define UDP_TRACE_RX(ctx, src_host, src_port, len) \
    do { \
        udp_trace_rx_count++; \
        (ctx)->trace_rx++; \
        fprintf(stderr, "[UDP_TRACE] RX #%d <- %s:%d (%zu bytes)\n", \
                udp_trace_rx_count, (src_host), (src_port), (size_t)(len)); \
    } while(0)

#define UDP_TRACE_RECV_WAIT() \
    fprintf(stderr, "[UDP_TRACE] RECV_WAIT (coroutine yielding)\n")

#define UDP_TRACE_RECV_RESUME(host, port, len) \
    fprintf(stderr, "[UDP_TRACE] RECV_RESUME <- %s:%d (%zu bytes)\n", \
            (host), (port), (size_t)(len))

#define UDP_TRACE_RECV_DELIVER(host, port, len) \
    fprintf(stderr, "[UDP_TRACE] RECV_DELIVER (immediate) <- %s:%d (%zu bytes)\n", \
            (host), (port), (size_t)(len))

#define UDP_TRACE_CLOSE(ctx) \
    fprintf(stderr, "[UDP_TRACE] CLOSE (local: tx=%d rx=%d) (global: tx=%d rx=%d)\n", \
            (ctx)->trace_tx, (ctx)->trace_rx, udp_trace_tx_count, udp_trace_rx_count)

void lunet_udp_trace_summary(void) {
    fprintf(stderr, "[UDP_TRACE] SUMMARY: binds=%d tx=%d rx=%d\n", \
            udp_trace_bind_count, udp_trace_tx_count, udp_trace_rx_count);
}

#else /* !LUNET_TRACE */

#define UDP_TRACE_BIND(handle) ((void)0)
#define UDP_TRACE_TX(ctx, dest_host, dest_port, len) ((void)0)
#define UDP_TRACE_RX(ctx, src_host, src_port, len) ((void)0)
#define UDP_TRACE_RECV_WAIT() ((void)0)
#define UDP_TRACE_RECV_RESUME(host, port, len) ((void)0)
#define UDP_TRACE_RECV_DELIVER(host, port, len) ((void)0)
#define UDP_TRACE_CLOSE(ctx) ((void)0)
void lunet_udp_trace_summary(void) {}

#endif /* LUNET_TRACE */

typedef struct {
  uv_udp_send_t req;
  uv_buf_t buf;
  char *data;
} udp_send_ctx_t;

typedef struct {
  char *data;
  size_t len;
  char host[INET6_ADDRSTRLEN];
  int port;
} udp_msg_t;

static void udp_on_close(uv_handle_t *handle) { free(handle->data); }

static void udp_alloc_cb(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf) {
  (void)handle;
  char *data = (char *)malloc(suggested_size);
  buf->base = data;
  buf->len = suggested_size;
}

static void udp_recv_cb(uv_udp_t *handle, ssize_t nread, const uv_buf_t *buf,
                        const struct sockaddr *addr, unsigned flags) {
  (void)flags;
  udp_ctx_t *ctx = (udp_ctx_t *)handle->data;

  if (nread <= 0 || addr == NULL) {
    free(buf->base);
    return;
  }

  udp_msg_t *msg = (udp_msg_t *)malloc(sizeof(udp_msg_t));
  if (msg == NULL) {
    free(buf->base);
    return;
  }

  msg->data = buf->base;
  msg->len = (size_t)nread;
  msg->port = 0;
  msg->host[0] = '\0';

  if (addr->sa_family == AF_INET) {
    const struct sockaddr_in *a4 = (const struct sockaddr_in *)addr;
    uv_ip4_name(a4, msg->host, sizeof(msg->host));
    msg->port = ntohs(a4->sin_port);
  } else if (addr->sa_family == AF_INET6) {
    const struct sockaddr_in6 *a6 = (const struct sockaddr_in6 *)addr;
    uv_ip6_name(a6, msg->host, sizeof(msg->host));
    msg->port = ntohs(a6->sin6_port);
  }

  UDP_TRACE_RX(ctx, msg->host, msg->port, msg->len);

  if (queue_enqueue(ctx->pending, msg) != 0) {
    free(msg->data);
    free(msg);
    return;
  }

  if (ctx->recv_ref != LUA_NOREF) {
    lua_rawgeti(ctx->co, LUA_REGISTRYINDEX, ctx->recv_ref);
    lunet_coref_release(ctx->co, ctx->recv_ref);
    ctx->recv_ref = LUA_NOREF;

    if (!lua_isthread(ctx->co, -1)) {
      lua_pop(ctx->co, 1);
      return;
    }

    lua_State *waiting_co = lua_tothread(ctx->co, -1);
    lua_pop(ctx->co, 1);
    udp_msg_t *to_deliver = (udp_msg_t *)queue_dequeue(ctx->pending);
    if (to_deliver != NULL) {
      UDP_TRACE_RECV_RESUME(to_deliver->host, to_deliver->port, to_deliver->len);
      lua_pushlstring(waiting_co, to_deliver->data, to_deliver->len);
      lua_pushstring(waiting_co, to_deliver->host);
      lua_pushinteger(waiting_co, to_deliver->port);
      free(to_deliver->data);
      free(to_deliver);
      int resume_status = lua_resume(waiting_co, 3);
      if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
        fprintf(stderr, "udp recv resume error: %s\n", lua_tostring(waiting_co, -1));
      }
    } else {
      int resume_status = lua_resume(waiting_co, 0);
      if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
        fprintf(stderr, "udp recv resume error: %s\n", lua_tostring(waiting_co, -1));
      }
    }
  }
}

static void udp_send_cb(uv_udp_send_t *req, int status) {
  (void)status;
  udp_send_ctx_t *send_ctx = (udp_send_ctx_t *)req->data;
  free(send_ctx->data);
  free(send_ctx);
}

int lunet_udp_bind(lua_State *co) {
  if (lunet_ensure_coroutine(co, "udp.bind") != 0) return 2;

  const char *host = luaL_checkstring(co, 1);
  int port = (int)luaL_checkinteger(co, 2);

  udp_ctx_t *ctx = (udp_ctx_t *)calloc(1, sizeof(udp_ctx_t));
  if (ctx == NULL) {
    lua_pushnil(co);
    lua_pushstring(co, "out of memory");
    return 2;
  }
  ctx->pending = queue_init();
  if (ctx->pending == NULL) {
    free(ctx);
    lua_pushnil(co);
    lua_pushstring(co, "out of memory");
    return 2;
  }

  uv_loop_t *loop = uv_default_loop();
  int ret = uv_udp_init(loop, &ctx->handle);
  if (ret < 0) {
    queue_destroy(ctx->pending);
    free(ctx);
    lua_pushnil(co);
    lua_pushfstring(co, "failed to init udp: %s", uv_strerror(ret));
    return 2;
  }
  ctx->handle.data = ctx;
  ctx->co = co;
  ctx->recv_ref = LUA_NOREF;

  struct sockaddr_storage addr;
  memset(&addr, 0, sizeof(addr));
  if (strchr(host, ':') != NULL) {
    struct sockaddr_in6 a6;
    ret = uv_ip6_addr(host, port, &a6);
    if (ret < 0) {
      uv_close((uv_handle_t *)&ctx->handle, udp_on_close);
      lua_pushnil(co);
      lua_pushstring(co, "invalid host or port");
      return 2;
    }
    memcpy(&addr, &a6, sizeof(a6));
  } else {
    struct sockaddr_in a4;
    ret = uv_ip4_addr(host, port, &a4);
    if (ret < 0) {
      uv_close((uv_handle_t *)&ctx->handle, udp_on_close);
      lua_pushnil(co);
      lua_pushstring(co, "invalid host or port");
      return 2;
    }
    memcpy(&addr, &a4, sizeof(a4));
  }

  ret = uv_udp_bind(&ctx->handle, (const struct sockaddr *)&addr, 0);
  if (ret < 0) {
    uv_close((uv_handle_t *)&ctx->handle, udp_on_close);
    lua_pushnil(co);
    lua_pushfstring(co, "failed to bind: %s", uv_strerror(ret));
    return 2;
  }

  ret = uv_udp_recv_start(&ctx->handle, udp_alloc_cb, udp_recv_cb);
  if (ret < 0) {
    uv_close((uv_handle_t *)&ctx->handle, udp_on_close);
    lua_pushnil(co);
    lua_pushfstring(co, "failed to start recv: %s", uv_strerror(ret));
    return 2;
  }

  UDP_TRACE_BIND(&ctx->handle);

  lua_pushlightuserdata(co, ctx);
  lua_pushnil(co);
  return 2;
}

int lunet_udp_send(lua_State *co) {
  if (lunet_ensure_coroutine(co, "udp.send") != 0) return 2;

  udp_ctx_t *ctx = (udp_ctx_t *)lua_touserdata(co, 1);
  if (ctx == NULL) {
    lua_pushnil(co);
    lua_pushstring(co, "invalid udp handle");
    return 2;
  }

  const char *host = luaL_checkstring(co, 2);
  int port = (int)luaL_checkinteger(co, 3);

  size_t len = 0;
  const char *data = luaL_checklstring(co, 4, &len);

  struct sockaddr_storage addr;
  memset(&addr, 0, sizeof(addr));
  int ret = 0;
  if (strchr(host, ':') != NULL) {
    struct sockaddr_in6 a6;
    ret = uv_ip6_addr(host, port, &a6);
    if (ret < 0) {
      lua_pushnil(co);
      lua_pushstring(co, "invalid host or port");
      return 2;
    }
    memcpy(&addr, &a6, sizeof(a6));
  } else {
    struct sockaddr_in a4;
    ret = uv_ip4_addr(host, port, &a4);
    if (ret < 0) {
      lua_pushnil(co);
      lua_pushstring(co, "invalid host or port");
      return 2;
    }
    memcpy(&addr, &a4, sizeof(a4));
  }

  udp_send_ctx_t *send_ctx = (udp_send_ctx_t *)malloc(sizeof(udp_send_ctx_t));
  if (send_ctx == NULL) {
    lua_pushnil(co);
    lua_pushstring(co, "out of memory");
    return 2;
  }
  memset(send_ctx, 0, sizeof(*send_ctx));

  send_ctx->data = (char *)malloc(len);
  if (send_ctx->data == NULL) {
    free(send_ctx);
    lua_pushnil(co);
    lua_pushstring(co, "out of memory");
    return 2;
  }
  memcpy(send_ctx->data, data, len);
  send_ctx->buf = uv_buf_init(send_ctx->data, (unsigned int)len);
  send_ctx->req.data = send_ctx;

  ret = uv_udp_send(&send_ctx->req, &ctx->handle, &send_ctx->buf, 1,
                    (const struct sockaddr *)&addr, udp_send_cb);
  if (ret < 0) {
    free(send_ctx->data);
    free(send_ctx);
    lua_pushnil(co);
    lua_pushfstring(co, "failed to send: %s", uv_strerror(ret));
    return 2;
  }

  UDP_TRACE_TX(ctx, host, port, len);

  lua_pushboolean(co, 1);
  lua_pushnil(co);
  return 2;
}

int lunet_udp_recv(lua_State *co) {
  if (lunet_ensure_coroutine(co, "udp.recv") != 0) return 3;

  udp_ctx_t *ctx = (udp_ctx_t *)lua_touserdata(co, 1);
  if (ctx == NULL) {
    lua_pushnil(co);
    lua_pushnil(co);
    lua_pushstring(co, "invalid udp handle");
    return 3;
  }

  if (queue_is_empty(ctx->pending)) {
    if (ctx->recv_ref != LUA_NOREF) {
      lua_pushnil(co);
      lua_pushnil(co);
      lua_pushstring(co, "recv already pending");
      return 3;
    }

    ctx->co = co;
    lunet_coref_create(co, ctx->recv_ref);
    UDP_TRACE_RECV_WAIT();
    return lua_yield(co, 0);
  }

  udp_msg_t *msg = (udp_msg_t *)queue_dequeue(ctx->pending);
  if (msg == NULL) {
    lua_pushnil(co);
    lua_pushnil(co);
    lua_pushnil(co);
    return 3;
  }

  UDP_TRACE_RECV_DELIVER(msg->host, msg->port, msg->len);

  lua_pushlstring(co, msg->data, msg->len);
  lua_pushstring(co, msg->host);
  lua_pushinteger(co, msg->port);
  free(msg->data);
  free(msg);
  return 3;
}

int lunet_udp_close(lua_State *L) {
  if (lunet_ensure_coroutine(L, "udp.close") != 0) return 2;

  udp_ctx_t *ctx = (udp_ctx_t *)lua_touserdata(L, 1);
  if (ctx == NULL) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid udp handle");
    return 2;
  }

  uv_udp_recv_stop(&ctx->handle);

  while (!queue_is_empty(ctx->pending)) {
    udp_msg_t *msg = (udp_msg_t *)queue_dequeue(ctx->pending);
    if (msg) {
      free(msg->data);
      free(msg);
    }
  }
  queue_destroy(ctx->pending);
  ctx->pending = NULL;

  if (ctx->recv_ref != LUA_NOREF) {
    lua_rawgeti(ctx->co, LUA_REGISTRYINDEX, ctx->recv_ref);
    lunet_coref_release(ctx->co, ctx->recv_ref);
    ctx->recv_ref = LUA_NOREF;
    if (lua_isthread(ctx->co, -1)) {
      lua_State *waiting_co = lua_tothread(ctx->co, -1);
      lua_pop(ctx->co, 1);
      lua_pushnil(waiting_co);
      lua_pushnil(waiting_co);
      lua_pushstring(waiting_co, "udp closed");
      lua_resume(waiting_co, 3);
    } else {
      lua_pop(ctx->co, 1);
    }
  }

  UDP_TRACE_CLOSE(ctx);

  uv_close((uv_handle_t *)&ctx->handle, udp_on_close);
  lua_pushboolean(L, 1);
  lua_pushnil(L);
  return 2;
}

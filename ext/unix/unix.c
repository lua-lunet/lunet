/**
 * unix.c - Unix domain socket extension for lunet
 *
 * Provides Unix domain socket (IPC) support using libuv's uv_pipe_t.
 * This is a standalone extension module, loadable via require("lunet.unix").
 */

#include "lunet_unix.h"

#ifndef _WIN32
#include <errno.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#endif

#include <stdlib.h>
#include <string.h>
#include <uv.h>

#include "co.h"
#include "stl.h"
#include "trace.h"

/* Default read buffer size */
static size_t unix_read_buffer_size = 4096;

/* Socket types */
typedef enum {
  UNIX_SOCKET_SERVER,
  UNIX_SOCKET_CLIENT,
} unix_socket_type_t;

/* Socket context structure */
typedef struct {
  uv_pipe_t pipe;
  uv_handle_t handle;  /* alias for close operations */
  uv_stream_t stream;  /* alias for read/write/accept */
} unix_handle_t;

typedef struct {
  union {
    uv_pipe_t pipe;
    uv_handle_t handle;
    uv_stream_t stream;
  } u;

  lua_State *co;
  unix_socket_type_t type;
  char *socket_path;  /* For servers, to unlink on close */

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
} unix_ctx_t;

/* Write request structure */
typedef struct {
  uv_write_t req;
  unix_ctx_t *ctx;
  char *data;
} unix_write_req_t;

/* Connect context structure */
typedef struct {
  uv_connect_t req;
  unix_ctx_t *ctx;
  lua_State *co;
  int co_ref;
} unix_connect_ctx_t;

/* ============================================================================
 * Internal callbacks
 * ============================================================================ */

static void unix_close_cb(uv_handle_t *handle) {
  unix_ctx_t *ctx = (unix_ctx_t *)handle->data;
  if (ctx) {
    if (ctx->type == UNIX_SOCKET_SERVER) {
      /* Remove socket file on close */
      if (ctx->socket_path) {
#ifndef _WIN32
        unlink(ctx->socket_path);
#endif
        free(ctx->socket_path);
        ctx->socket_path = NULL;
      }
      if (ctx->server.pending_accepts) {
        queue_destroy(ctx->server.pending_accepts);
        ctx->server.pending_accepts = NULL;
      }
    }
    free(ctx);
  }
}

static void unix_write_cb(uv_write_t *req, int status) {
  unix_write_req_t *write_req = (unix_write_req_t *)req;
  unix_ctx_t *ctx = write_req->ctx;

  if (ctx->client.write_ref != LUA_NOREF) {
    lua_State *co = ctx->co;
    lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->client.write_ref);
    lunet_coref_release(co, ctx->client.write_ref);
    ctx->client.write_ref = LUA_NOREF;

    if (lua_isthread(co, -1)) {
      lua_State *waiting_co = lua_tothread(co, -1);
      lua_pop(co, 1);

      if (status == 0) {
        lua_pushnil(waiting_co);
      } else {
        lua_pushstring(waiting_co, uv_strerror(status));
      }

      int resume_status = lua_resume(waiting_co, 1);
      if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
        const char *err = lua_tostring(waiting_co, -1);
        if (err) {
          fprintf(stderr, "[lunet.unix] resume error in write_cb: %s\n", err);
        }
      }
    }
  }

  if (write_req->data) {
    free(write_req->data);
  }
  free(write_req);
}

static void unix_alloc_buffer(uv_handle_t *handle, size_t suggested_size,
                              uv_buf_t *buf) {
  (void)handle;
  (void)suggested_size;
  buf->base = malloc(unix_read_buffer_size);
  buf->len = unix_read_buffer_size;
}

static void unix_read_cb(uv_stream_t *stream, ssize_t nread,
                         const uv_buf_t *buf) {
  unix_ctx_t *ctx = (unix_ctx_t *)stream->data;

  uv_read_stop(stream);

  if (ctx->client.read_ref != LUA_NOREF) {
    lua_State *co = ctx->co;
    lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->client.read_ref);
    lunet_coref_release(co, ctx->client.read_ref);
    ctx->client.read_ref = LUA_NOREF;

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

      int resume_status = lua_resume(waiting_co, 2);
      if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
        const char *err = lua_tostring(waiting_co, -1);
        if (err) {
          fprintf(stderr, "[lunet.unix] resume error in read_cb: %s\n", err);
        }
      }
    }
  }

  if (buf->base) {
    free(buf->base);
  }
}

static void unix_listen_cb(uv_stream_t *server, int status) {
  unix_ctx_t *ctx = (unix_ctx_t *)server->data;

  if (status < 0) {
    /* Error during connection attempt */
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

        int resume_status = lua_resume(waiting_co, 2);
        if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
          const char *err = lua_tostring(waiting_co, -1);
          if (err) {
            fprintf(stderr, "[lunet.unix] resume error in listen_cb: %s\n",
                    err);
          }
        }
      }
    }
    return;
  }

  /* Create new client connection context */
  unix_ctx_t *client_ctx = malloc(sizeof(unix_ctx_t));
  if (!client_ctx) {
    return; /* Ignore this connection */
  }

  client_ctx->co = ctx->co;
  client_ctx->type = UNIX_SOCKET_CLIENT;
  client_ctx->socket_path = NULL;
  client_ctx->client.read_ref = LUA_NOREF;
  client_ctx->client.write_ref = LUA_NOREF;

  int ret = uv_pipe_init(uv_default_loop(), &client_ctx->u.pipe, 0);
  if (ret < 0) {
    free(client_ctx);
    return;
  }

  client_ctx->u.handle.data = client_ctx;

  if (uv_accept(server, &client_ctx->u.stream) < 0) {
    uv_close(&client_ctx->u.handle, unix_close_cb);
    return;
  }

  if (ctx->server.accept_ref != LUA_NOREF) {
    /* Coroutine waiting for accept - wake it up */
    lua_State *co = ctx->co;
    lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->server.accept_ref);
    lunet_coref_release(co, ctx->server.accept_ref);
    ctx->server.accept_ref = LUA_NOREF;

    if (lua_isthread(co, -1)) {
      lua_State *waiting_co = lua_tothread(co, -1);
      lua_pop(co, 1);

      lua_pushlightuserdata(waiting_co, client_ctx);
      lua_pushnil(waiting_co);

      int resume_status = lua_resume(waiting_co, 2);
      if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
        const char *err = lua_tostring(waiting_co, -1);
        if (err) {
          fprintf(stderr, "[lunet.unix] resume error in listen_cb: %s\n", err);
        }
      }
    }
  } else {
    /* No coroutine waiting - queue the connection */
    if (queue_enqueue(ctx->server.pending_accepts, client_ctx) != 0) {
      /* Queue full or error - close the connection */
      uv_close(&client_ctx->u.handle, unix_close_cb);
    }
  }
}

static void unix_connect_cb(uv_connect_t *req, int status) {
  unix_connect_ctx_t *ctx = (unix_connect_ctx_t *)req->data;
  lua_State *co = ctx->co;

  lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(co, ctx->co_ref);
  ctx->co_ref = LUA_NOREF;

  if (status == 0) {
    lua_pushlightuserdata(co, ctx->ctx);
    lua_pushnil(co);
  } else {
    /* Clean up socket context on error */
    uv_close(&ctx->ctx->u.handle, unix_close_cb);
    lua_pushnil(co);
    lua_pushstring(co, uv_strerror(status));
  }

  int resume_status = lua_resume(co, 2);
  if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
    const char *err = lua_tostring(co, -1);
    if (err) {
      fprintf(stderr, "[lunet.unix] resume error in connect_cb: %s\n", err);
    }
  }

  free(ctx);
}

/* ============================================================================
 * Public API functions
 * ============================================================================ */

int lunet_unix_listen(lua_State *L) {
  if (lunet_ensure_coroutine(L, "unix.listen") != 0) {
    return lua_error(L);
  }

  const char *path = luaL_checkstring(L, 1);

  /* Validate path */
  if (!path || strlen(path) == 0) {
    lua_pushnil(L);
    lua_pushstring(L, "unix.listen requires a valid socket path");
    return 2;
  }

#ifndef _WIN32
  /* Check path length limit */
  struct sockaddr_un sun_addr;
  if (strlen(path) >= sizeof(sun_addr.sun_path)) {
    lua_pushnil(L);
    lua_pushstring(L, "socket path too long");
    return 2;
  }
#endif

  unix_ctx_t *ctx = malloc(sizeof(unix_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  ctx->co = L;
  ctx->type = UNIX_SOCKET_SERVER;
  ctx->socket_path = strdup(path);
  ctx->server.accept_ref = LUA_NOREF;
  ctx->server.pending_accepts = queue_init();

  if (!ctx->server.pending_accepts || !ctx->socket_path) {
    if (ctx->socket_path) free(ctx->socket_path);
    if (ctx->server.pending_accepts) queue_destroy(ctx->server.pending_accepts);
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  int ret = uv_pipe_init(uv_default_loop(), &ctx->u.pipe, 0);
  if (ret < 0) {
    free(ctx->socket_path);
    queue_destroy(ctx->server.pending_accepts);
    free(ctx);
    lua_pushnil(L);
    lua_pushfstring(L, "failed to initialize pipe: %s", uv_strerror(ret));
    return 2;
  }

  ctx->u.handle.data = ctx;

  /* Remove existing socket file if present */
#ifndef _WIN32
  unlink(path);
#endif

  ret = uv_pipe_bind(&ctx->u.pipe, path);
  if (ret < 0) {
    uv_close(&ctx->u.handle, unix_close_cb);
    lua_pushnil(L);
    lua_pushfstring(L, "failed to bind unix socket: %s", uv_strerror(ret));
    return 2;
  }

  ret = uv_listen(&ctx->u.stream, 128, unix_listen_cb);
  if (ret < 0) {
    uv_close(&ctx->u.handle, unix_close_cb);
    lua_pushnil(L);
    lua_pushfstring(L, "failed to listen: %s", uv_strerror(ret));
    return 2;
  }

  lua_pushlightuserdata(L, ctx);
  lua_pushnil(L);
  return 2;
}

int lunet_unix_accept(lua_State *L) {
  if (lunet_ensure_coroutine(L, "unix.accept") != 0) {
    return lua_error(L);
  }

  if (!lua_islightuserdata(L, 1)) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid listener handle");
    return 2;
  }

  unix_ctx_t *listener_ctx = (unix_ctx_t *)lua_touserdata(L, 1);
  if (!listener_ctx || listener_ctx->type != UNIX_SOCKET_SERVER) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid listener handle");
    return 2;
  }

  /* Check if another accept is already in progress */
  if (listener_ctx->server.accept_ref != LUA_NOREF) {
    lua_pushnil(L);
    lua_pushstring(L, "another accept already in progress");
    return 2;
  }

  /* Check if there's a pending connection in the queue */
  if (!queue_is_empty(listener_ctx->server.pending_accepts)) {
    unix_ctx_t *client_ctx =
        (unix_ctx_t *)queue_dequeue(listener_ctx->server.pending_accepts);
    if (client_ctx) {
      lua_pushlightuserdata(L, client_ctx);
      lua_pushnil(L);
      return 2;
    }
  }

  /* No pending connection - wait for one */
  lunet_coref_create(L, listener_ctx->server.accept_ref);

  return lua_yield(L, 0);
}

int lunet_unix_connect(lua_State *L) {
  if (lunet_ensure_coroutine(L, "unix.connect") != 0) {
    return lua_error(L);
  }

  const char *path = luaL_checkstring(L, 1);

  if (!path || strlen(path) == 0) {
    lua_pushnil(L);
    lua_pushstring(L, "unix.connect requires a valid socket path");
    return 2;
  }

#ifndef _WIN32
  /* Check path length limit */
  struct sockaddr_un sun_addr;
  if (strlen(path) >= sizeof(sun_addr.sun_path)) {
    lua_pushnil(L);
    lua_pushstring(L, "socket path too long");
    return 2;
  }
#endif

  unix_ctx_t *ctx = malloc(sizeof(unix_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  ctx->co = L;
  ctx->type = UNIX_SOCKET_CLIENT;
  ctx->socket_path = NULL;
  ctx->client.read_ref = LUA_NOREF;
  ctx->client.write_ref = LUA_NOREF;

  int ret = uv_pipe_init(uv_default_loop(), &ctx->u.pipe, 0);
  if (ret < 0) {
    free(ctx);
    lua_pushnil(L);
    lua_pushfstring(L, "failed to initialize pipe: %s", uv_strerror(ret));
    return 2;
  }

  ctx->u.handle.data = ctx;

  unix_connect_ctx_t *connect_ctx = malloc(sizeof(unix_connect_ctx_t));
  if (!connect_ctx) {
    uv_close(&ctx->u.handle, unix_close_cb);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  connect_ctx->ctx = ctx;
  connect_ctx->co = L;
  connect_ctx->co_ref = LUA_NOREF;
  connect_ctx->req.data = connect_ctx;

  lunet_coref_create(L, connect_ctx->co_ref);

  /* uv_pipe_connect is void - no error return */
  uv_pipe_connect(&connect_ctx->req, &ctx->u.pipe, path, unix_connect_cb);

  return lua_yield(L, 0);
}

int lunet_unix_read(lua_State *L) {
  if (lunet_ensure_coroutine(L, "unix.read") != 0) {
    return lua_error(L);
  }

  if (!lua_islightuserdata(L, 1)) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid socket handle");
    return 2;
  }

  unix_ctx_t *ctx = (unix_ctx_t *)lua_touserdata(L, 1);
  if (!ctx || ctx->type != UNIX_SOCKET_CLIENT) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid client socket handle");
    return 2;
  }

  /* Check if another read is already in progress */
  if (ctx->client.read_ref != LUA_NOREF) {
    lua_pushnil(L);
    lua_pushstring(L, "another read already in progress");
    return 2;
  }

  lunet_coref_create(L, ctx->client.read_ref);

  int ret = uv_read_start(&ctx->u.stream, unix_alloc_buffer, unix_read_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->client.read_ref);
    ctx->client.read_ref = LUA_NOREF;

    lua_pushnil(L);
    lua_pushfstring(L, "failed to start reading: %s", uv_strerror(ret));
    return 2;
  }

  return lua_yield(L, 0);
}

int lunet_unix_write(lua_State *L) {
  if (lunet_ensure_coroutine(L, "unix.write") != 0) {
    return lua_error(L);
  }

  if (!lua_islightuserdata(L, 1)) {
    lua_pushstring(L, "invalid socket handle");
    return 1;
  }

  if (!lua_isstring(L, 2)) {
    lua_pushstring(L, "data must be a string");
    return 1;
  }

  unix_ctx_t *ctx = (unix_ctx_t *)lua_touserdata(L, 1);
  if (!ctx || ctx->type != UNIX_SOCKET_CLIENT) {
    lua_pushstring(L, "invalid client socket handle");
    return 1;
  }

  /* Check if another write is already in progress */
  if (ctx->client.write_ref != LUA_NOREF) {
    lua_pushstring(L, "another write already in progress");
    return 1;
  }

  size_t data_len;
  const char *data = lua_tolstring(L, 2, &data_len);

  unix_write_req_t *write_req = malloc(sizeof(unix_write_req_t));
  if (!write_req) {
    lua_pushstring(L, "out of memory");
    return 1;
  }

  write_req->data = malloc(data_len);
  if (!write_req->data) {
    free(write_req);
    lua_pushstring(L, "out of memory");
    return 1;
  }
  memcpy(write_req->data, data, data_len);

  write_req->ctx = ctx;

  uv_buf_t buf = uv_buf_init(write_req->data, data_len);

  lunet_coref_create(L, ctx->client.write_ref);

  int ret = uv_write(&write_req->req, &ctx->u.stream, &buf, 1, unix_write_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->client.write_ref);
    ctx->client.write_ref = LUA_NOREF;
    free(write_req->data);
    free(write_req);

    lua_pushfstring(L, "failed to start writing: %s", uv_strerror(ret));
    return 1;
  }

  return lua_yield(L, 0);
}

int lunet_unix_close(lua_State *L) {
  if (!lua_islightuserdata(L, 1)) {
    lua_pushstring(L, "invalid socket handle");
    return 1;
  }

  unix_ctx_t *ctx = (unix_ctx_t *)lua_touserdata(L, 1);
  if (!ctx) {
    lua_pushstring(L, "invalid socket handle");
    return 1;
  }

  uv_close(&ctx->u.handle, unix_close_cb);

  lua_pushnil(L);
  return 1;
}

int lunet_unix_getpeername(lua_State *L) {
  if (lunet_ensure_coroutine(L, "unix.getpeername") != 0) {
    return lua_error(L);
  }

  if (!lua_islightuserdata(L, 1)) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid socket handle");
    return 2;
  }

  unix_ctx_t *ctx = (unix_ctx_t *)lua_touserdata(L, 1);
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid socket handle");
    return 2;
  }

  /* Get peer name for Unix socket */
  char buf[256];
  size_t len = sizeof(buf);
  int ret = uv_pipe_getpeername(&ctx->u.pipe, buf, &len);
  if (ret < 0) {
    /* Unix sockets often don't have a peer name - return "unix" */
    lua_pushstring(L, "unix");
    lua_pushnil(L);
    return 2;
  }

  lua_pushlstring(L, buf, len);
  lua_pushnil(L);
  return 2;
}

int lunet_unix_unlink(lua_State *L) {
  const char *path = luaL_checkstring(L, 1);

#ifndef _WIN32
  if (unlink(path) != 0 && errno != ENOENT) {
    lua_pushstring(L, strerror(errno));
    return 1;
  }
#else
  (void)path;
#endif

  lua_pushnil(L);
  return 1;
}

int lunet_unix_set_read_buffer_size(lua_State *L) {
  if (lua_isnumber(L, 1)) {
    unix_read_buffer_size = lua_tointeger(L, 1);
  }
  lua_pushnil(L);
  return 1;
}

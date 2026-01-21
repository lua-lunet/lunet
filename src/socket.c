#include "socket.h"

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#endif

#include <lauxlib.h>
#include <lua.h>
#include <lualib.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

#include "co.h"
#include "stl.h"

static size_t read_buffer_size = 4096;

typedef enum {
  TCP_SERVER,
  TCP_CLIENT,
} tcp_type_t;

typedef struct {
  uv_tcp_t handle;
  lua_State *co;
  tcp_type_t type;
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

} tcp_ctx_t;

// write request structure
typedef struct {
  uv_write_t req;
  tcp_ctx_t *ctx;
  char *data;
} write_req_t;

static void lunet_close_cb(uv_handle_t *handle) {
  tcp_ctx_t *ctx = (tcp_ctx_t *)handle->data;
  if (ctx) {
    if (ctx->type == TCP_SERVER) {
      queue_destroy(ctx->server.pending_accepts);
    }
    free(ctx);
  }
}
// write complete callback
static void lunet_write_cb(uv_write_t *req, int status) {
  write_req_t *write_req = (write_req_t *)req;
  tcp_ctx_t *ctx = write_req->ctx;

  if (ctx->client.write_ref != LUA_NOREF) {
    lua_State *co = ctx->co;
    lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->client.write_ref);
    luaL_unref(co, LUA_REGISTRYINDEX, ctx->client.write_ref);
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
          fprintf(stderr, "[lunet] resume error in lunet_write_cb: %s\n", err);
        }
      }
    }
  }

  // release write request and data
  if (write_req->data) {
    free(write_req->data);
  }
  free(write_req);
}

static void alloc_buffer(uv_handle_t *handle, size_t suggested_size, uv_buf_t *buf) {
  buf->base = malloc(read_buffer_size);
  buf->len = read_buffer_size;
}

static void lunet_read_cb(uv_stream_t *stream, ssize_t nread, const uv_buf_t *buf) {
  tcp_ctx_t *ctx = (tcp_ctx_t *)stream->data;

  uv_read_stop(stream);

  if (ctx->client.read_ref != LUA_NOREF) {
    lua_State *co = ctx->co;
    lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->client.read_ref);
    luaL_unref(co, LUA_REGISTRYINDEX, ctx->client.read_ref);
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
          fprintf(stderr, "[lunet] resume error in on_read: %s\n", err);
        }
      }
    }
  }

  if (buf->base) {
    free(buf->base);
  }
}

static void lunet_listen_cb(uv_stream_t *server, int status) {
  tcp_ctx_t *ctx = (tcp_ctx_t *)server->data;

  if (status < 0) {
    // there is a coroutine waiting for accept
    if (ctx->server.accept_ref != LUA_NOREF) {
      lua_State *co = ctx->co;
      lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->server.accept_ref);
      luaL_unref(co, LUA_REGISTRYINDEX, ctx->server.accept_ref);
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
            fprintf(stderr, "[lunet] resume error in listen_cb: %s\n", err);
          }
        }
      }
    }
    return;
  }

  // create new client connection
  tcp_ctx_t *client_ctx = malloc(sizeof(tcp_ctx_t));
  if (!client_ctx) {
    return;  // ignore this connection
  }

  client_ctx->co = ctx->co;
  client_ctx->type = TCP_CLIENT;
  client_ctx->client.read_ref = LUA_NOREF;
  client_ctx->client.write_ref = LUA_NOREF;

  if (uv_tcp_init(uv_default_loop(), &client_ctx->handle) < 0) {
    free(client_ctx);
    return;
  }

  client_ctx->handle.data = client_ctx;

  if (uv_accept(server, (uv_stream_t *)&client_ctx->handle) < 0) {
    uv_close((uv_handle_t *)&client_ctx->handle, lunet_close_cb);
    return;
  }

  if (ctx->server.accept_ref != LUA_NOREF) {
    // there is a coroutine waiting for accept, wake it up
    lua_State *co = ctx->co;
    lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->server.accept_ref);
    luaL_unref(co, LUA_REGISTRYINDEX, ctx->server.accept_ref);
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
          fprintf(stderr, "[lunet] resume error in listen_cb: %s\n", err);
        }
      }
    }
  } else {
    // there is no coroutine waiting for accept, put the connection into the queue
    if (queue_enqueue(ctx->server.pending_accepts, client_ctx) != 0) {
      // queue is full or error, close the connection
      uv_close((uv_handle_t *)&client_ctx->handle, lunet_close_cb);
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
  if (port < 1 || port > 65535) {
    lua_pushnil(co);
    lua_pushstring(co, "port must be between 1 and 65535");
    return 2;
  }
  if (strcmp(protocol, "tcp") != 0) {
    lua_pushnil(co);
    lua_pushstring(co, "only tcp is supported");
    return 2;
  }
  tcp_ctx_t *ctx = malloc(sizeof(tcp_ctx_t));
  if (!ctx) {
    lua_pushnil(co);
    lua_pushstring(co, "out of memory");
    return 2;
  }
  ctx->co = co;
  ctx->type = TCP_SERVER;
  ctx->server.accept_ref = LUA_NOREF;
  ctx->server.pending_accepts = queue_init();
  if (!ctx->server.pending_accepts) {
    free(ctx);
    lua_pushnil(co);
    lua_pushstring(co, "out of memory");
    return 2;
  }

  int ret = 0;
  if ((ret = uv_tcp_init(uv_default_loop(), &ctx->handle)) < 0) {
    queue_destroy(ctx->server.pending_accepts);
    free(ctx);
    lua_pushnil(co);
    lua_pushfstring(co, "failed to initialize TCP: %s", uv_strerror(ret));
    return 2;
  }

  ctx->handle.data = ctx;

  struct sockaddr_in addr;
  if (uv_ip4_addr(host, port, &addr) < 0) {
    queue_destroy(ctx->server.pending_accepts);
    free(ctx);
    lua_pushnil(co);
    lua_pushstring(co, "invalid host or port");
    return 2;
  }
  if ((ret = uv_tcp_bind(&ctx->handle, (const struct sockaddr *)&addr, 0)) < 0) {
    queue_destroy(ctx->server.pending_accepts);
    free(ctx);
    lua_pushnil(co);
    lua_pushfstring(co, "failed to bind: %s", uv_strerror(ret));
    return 2;
  }
  if ((ret = uv_listen((uv_stream_t *)&ctx->handle, 128, lunet_listen_cb)) < 0) {
    queue_destroy(ctx->server.pending_accepts);
    free(ctx);
    lua_pushnil(co);
    lua_pushfstring(co, "failed to listen: %s", uv_strerror(ret));
    return 2;
  }
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

  tcp_ctx_t *listener_ctx = (tcp_ctx_t *)lua_touserdata(co, 1);
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
    tcp_ctx_t *client_ctx = (tcp_ctx_t *)queue_dequeue(listener_ctx->server.pending_accepts);
    if (client_ctx) {
      lua_pushlightuserdata(co, client_ctx);
      lua_pushnil(co);
      return 2;
    }
  }

  // there is no connection in the queue, wait for new connection
  // save the current coroutine reference
  lua_pushthread(co);
  listener_ctx->server.accept_ref = luaL_ref(co, LUA_REGISTRYINDEX);

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

  tcp_ctx_t *ctx = (tcp_ctx_t *)lua_touserdata(L, 1);
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid socket handle");
    return 2;
  }

  struct sockaddr_in addr;
  int addr_len = sizeof(addr);
  int ret = uv_tcp_getpeername(&ctx->handle, (struct sockaddr *)&addr, &addr_len);
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
  lua_pushnil(L);
  return 2;
}

int lunet_socket_close(lua_State *L) {
  if (!lua_islightuserdata(L, 1)) {
    lua_pushstring(L, "invalid socket handle");
    return 1;
  }

  tcp_ctx_t *ctx = (tcp_ctx_t *)lua_touserdata(L, 1);
  if (!ctx) {
    lua_pushstring(L, "invalid socket handle");
    return 1;
  }

  uv_close((uv_handle_t *)&ctx->handle, lunet_close_cb);

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

  tcp_ctx_t *ctx = (tcp_ctx_t *)lua_touserdata(co, 1);
  if (!ctx || ctx->type != TCP_CLIENT) {
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
  lua_pushthread(co);
  ctx->client.read_ref = luaL_ref(co, LUA_REGISTRYINDEX);

  // start reading
  int ret = uv_read_start((uv_stream_t *)&ctx->handle, alloc_buffer, lunet_read_cb);
  if (ret < 0) {
    // failed to start reading, clean up the reference
    luaL_unref(co, LUA_REGISTRYINDEX, ctx->client.read_ref);
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

  tcp_ctx_t *ctx = (tcp_ctx_t *)lua_touserdata(co, 1);
  if (!ctx || ctx->type != TCP_CLIENT) {
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
  write_req_t *write_req = malloc(sizeof(write_req_t));
  if (!write_req) {
    lua_pushstring(co, "out of memory");
    return 1;
  }

  // copy data to heap memory
  write_req->data = malloc(data_len);
  if (!write_req->data) {
    free(write_req);
    lua_pushstring(co, "out of memory");
    return 1;
  }
  memcpy(write_req->data, data, data_len);

  write_req->ctx = ctx;

  // set the buffer
  uv_buf_t buf = uv_buf_init(write_req->data, data_len);

  // save the coroutine reference
  lua_pushthread(co);
  ctx->client.write_ref = luaL_ref(co, LUA_REGISTRYINDEX);

  // start writing
  int ret = uv_write(&write_req->req, (uv_stream_t *)&ctx->handle, &buf, 1, lunet_write_cb);
  if (ret < 0) {
    // failed to start writing, clean up the resource
    luaL_unref(co, LUA_REGISTRYINDEX, ctx->client.write_ref);
    ctx->client.write_ref = LUA_NOREF;
    free(write_req->data);
    free(write_req);

    lua_pushfstring(co, "failed to start writing: %s", uv_strerror(ret));
    return 1;
  }

  // yield to wait for write to complete
  return lua_yield(co, 0);
}

typedef struct {
  uv_connect_t req;
  tcp_ctx_t *ctx;
  lua_State *co;
  int co_ref;
  char err[256];
} connect_ctx_t;

static void lunet_connect_cb(uv_connect_t *req, int status) {
  connect_ctx_t *ctx = (connect_ctx_t *)req->data;
  lua_State *co = ctx->co;

  // resume coroutine
  lua_rawgeti(co, LUA_REGISTRYINDEX, ctx->co_ref);
  luaL_unref(co, LUA_REGISTRYINDEX, ctx->co_ref);
  ctx->co_ref = LUA_NOREF;

  if (status == 0) {
    lua_pushlightuserdata(co, ctx->ctx);
    lua_pushnil(co);
  } else {
    lua_pushnil(co);
    lua_pushstring(co, uv_strerror(status));
  }

  int resume_status = lua_resume(co, 2);
  if (resume_status != LUA_OK && resume_status != LUA_YIELD) {
    const char *err = lua_tostring(co, -1);
    if (err) {
      fprintf(stderr, "[lunet] resume error in connect_cb: %s\n", err);
    }
  }

  free(ctx);
}

int lunet_socket_connect(lua_State *L) {
  if (lunet_ensure_coroutine(L, "socket.connect") != 0) {
    return lua_error(L);
  }

  const char *host = luaL_checkstring(L, 1);
  int port = luaL_checkinteger(L, 2);

  if (port < 1 || port > 65535) {
    lua_pushnil(L);
    lua_pushstring(L, "port must be between 1 and 65535");
    return 2;
  }

  tcp_ctx_t *ctx = malloc(sizeof(tcp_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  ctx->co = L;
  ctx->type = TCP_CLIENT;
  ctx->client.read_ref = LUA_NOREF;
  ctx->client.write_ref = LUA_NOREF;

  int ret = uv_tcp_init(uv_default_loop(), &ctx->handle);
  if (ret < 0) {
    free(ctx);
    lua_pushnil(L);
    lua_pushfstring(L, "failed to initialize TCP: %s", uv_strerror(ret));
    return 2;
  }

  ctx->handle.data = ctx;

  struct sockaddr_in dest;
  ret = uv_ip4_addr(host, port, &dest);
  if (ret < 0) {
    uv_close((uv_handle_t *)&ctx->handle, lunet_close_cb);
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "invalid host or port");
    return 2;
  }

  connect_ctx_t *connect_ctx = malloc(sizeof(connect_ctx_t));
  if (!connect_ctx) {
    uv_close((uv_handle_t *)&ctx->handle, lunet_close_cb);
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  connect_ctx->ctx = ctx;
  connect_ctx->co = L;
  connect_ctx->co_ref = LUA_NOREF;
  connect_ctx->req.data = connect_ctx;

  // save coroutine reference, for resume in connect_cb
  lua_pushthread(L);
  connect_ctx->co_ref = luaL_ref(L, LUA_REGISTRYINDEX);

  ret = uv_tcp_connect(&connect_ctx->req, &ctx->handle, (const struct sockaddr *)&dest, lunet_connect_cb);
  if (ret < 0) {
    luaL_unref(L, LUA_REGISTRYINDEX, connect_ctx->co_ref);
    connect_ctx->co_ref = LUA_NOREF;
    free(connect_ctx);
    uv_close((uv_handle_t *)&ctx->handle, lunet_close_cb);
    free(ctx);
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

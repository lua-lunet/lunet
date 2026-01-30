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

static void lunet_close_cb(uv_handle_t *handle) {
  socket_ctx_t *ctx = (socket_ctx_t *)handle->data;
  if (ctx) {
    if (ctx->type == SOCKET_SERVER) {
      queue_destroy(ctx->server.pending_accepts);
    }
    free(ctx);
  }
}

// write complete callback
static void lunet_write_cb(uv_write_t *req, int status) {
  write_req_t *write_req = (write_req_t *)req;
  socket_ctx_t *ctx = write_req->ctx;

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
  socket_ctx_t *ctx = (socket_ctx_t *)stream->data;

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
  socket_ctx_t *client_ctx = malloc(sizeof(socket_ctx_t));
  if (!client_ctx) {
    return;  // ignore this connection
  }

  client_ctx->co = ctx->co;
  client_ctx->type = SOCKET_CLIENT;
  client_ctx->domain = ctx->domain;
  client_ctx->client.read_ref = LUA_NOREF;
  client_ctx->client.write_ref = LUA_NOREF;

  int ret = 0;
  if (ctx->domain == SOCKET_DOMAIN_TCP) {
      ret = uv_tcp_init(uv_default_loop(), &client_ctx->u.tcp);
  } else {
      ret = uv_pipe_init(uv_default_loop(), &client_ctx->u.pipe, 0);
  }

  if (ret < 0) {
    free(client_ctx);
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

  socket_ctx_t *ctx = malloc(sizeof(socket_ctx_t));
  if (!ctx) {
    lua_pushnil(co);
    lua_pushstring(co, "out of memory");
    return 2;
  }
  ctx->co = co;
  ctx->type = SOCKET_SERVER;
  ctx->domain = domain;
  ctx->server.accept_ref = LUA_NOREF;
  ctx->server.pending_accepts = queue_init();
  if (!ctx->server.pending_accepts) {
    free(ctx);
    lua_pushnil(co);
    lua_pushstring(co, "out of memory");
    return 2;
  }

  int ret = 0;
  if (domain == SOCKET_DOMAIN_TCP) {
      if ((ret = uv_tcp_init(uv_default_loop(), &ctx->u.tcp)) < 0) {
        queue_destroy(ctx->server.pending_accepts);
        free(ctx);
        lua_pushnil(co);
        lua_pushfstring(co, "failed to initialize TCP: %s", uv_strerror(ret));
        return 2;
      }
  } else {
      if ((ret = uv_pipe_init(uv_default_loop(), &ctx->u.pipe, 0)) < 0) {
        queue_destroy(ctx->server.pending_accepts);
        free(ctx);
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

  uv_close(&ctx->u.handle, lunet_close_cb);

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
  int ret = uv_read_start(&ctx->u.stream, alloc_buffer, lunet_read_cb);
  if (ret < 0) {
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
  lunet_coref_create(co, ctx->client.write_ref);

  // start writing
  int ret = uv_write(&write_req->req, &ctx->u.stream, &buf, 1, lunet_write_cb);
  if (ret < 0) {
    // failed to start writing, clean up the resource
    lunet_coref_release(co, ctx->client.write_ref);
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

  socket_ctx_t *ctx = malloc(sizeof(socket_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  ctx->co = L;
  ctx->type = SOCKET_CLIENT;
  ctx->domain = domain;
  ctx->client.read_ref = LUA_NOREF;
  ctx->client.write_ref = LUA_NOREF;

  int ret = 0;
  if (domain == SOCKET_DOMAIN_TCP) {
      ret = uv_tcp_init(uv_default_loop(), &ctx->u.tcp);
  } else {
      ret = uv_pipe_init(uv_default_loop(), &ctx->u.pipe, 0);
  }

  if (ret < 0) {
    free(ctx);
    lua_pushnil(L);
    lua_pushfstring(L, "failed to initialize socket: %s", uv_strerror(ret));
    return 2;
  }

  ctx->u.handle.data = ctx;

  connect_ctx_t *connect_ctx = malloc(sizeof(connect_ctx_t));
  if (!connect_ctx) {
    uv_close(&ctx->u.handle, lunet_close_cb);
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
  lunet_coref_create(L, connect_ctx->co_ref);

  if (domain == SOCKET_DOMAIN_TCP) {
      struct sockaddr_in dest;
      ret = uv_ip4_addr(host, port, &dest);
      if (ret < 0) {
        lunet_coref_release(L, connect_ctx->co_ref);
        connect_ctx->co_ref = LUA_NOREF;
        free(connect_ctx);
        uv_close(&ctx->u.handle, lunet_close_cb);
        free(ctx);
        lua_pushnil(L);
        lua_pushstring(L, "invalid host or port");
        return 2;
      }
      ret = uv_tcp_connect(&connect_ctx->req, &ctx->u.tcp, (const struct sockaddr *)&dest, lunet_connect_cb);
  } else {
      uv_pipe_connect(&connect_ctx->req, &ctx->u.pipe, host, lunet_connect_cb);
      ret = 0; // uv_pipe_connect is void? No, checks say void in some versions?
      // libuv docs says void uv_pipe_connect(...)
      // So we assume success? Or check synchronous errors?
      // Wait, uv_pipe_connect is void in older versions but might be checked?
      // Checking header...
      // Usually it's void.
  }
  
  // NOTE: uv_pipe_connect is void. We assume it initiated.
  // But wait, if ret is not set?
  // Let's verify libuv version.
  
  if (ret < 0) {
    lunet_coref_release(L, connect_ctx->co_ref);
    connect_ctx->co_ref = LUA_NOREF;
    free(connect_ctx);
    uv_close(&ctx->u.handle, lunet_close_cb);
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

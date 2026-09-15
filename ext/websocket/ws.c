#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <wslay/wslay.h>

#include "lunet_lua.h"
#include "lunet_mem.h"

#include "ws.h"

typedef struct ws_msg_node_s {
  struct ws_msg_node_s *next;
  uint8_t *msg;
  size_t msg_len;
  uint8_t opcode;
} ws_msg_node_t;

typedef struct {
  wslay_event_context_ptr wslay;
  uint8_t *in_buf;
  size_t in_len;
  size_t in_off;
  size_t in_cap;

  uint8_t *out_buf;
  size_t out_len;
  size_t out_cap;

  ws_msg_node_t *msg_head;
  ws_msg_node_t *msg_tail;
  size_t msg_count;
  int closed;
} ws_conn_t;

static int ws_size_add(size_t a, size_t b, size_t *out) {
  if (!out) {
    return -1;
  }
  if (a > ((size_t)-1) - b) {
    return -1;
  }
  *out = a + b;
  return 0;
}

static int ws_reserve(uint8_t **buf, size_t *cap, size_t need, size_t preserve_len) {
  if (*cap >= need) {
    return 0;
  }
  size_t next = (*cap == 0) ? 256 : *cap;
  while (next < need) {
    size_t grown = next * 2;
    if (grown < next) {
      return -1;
    }
    next = grown;
  }
  uint8_t *p = (uint8_t *)lunet_alloc(next);
  if (!p) {
    return -1;
  }
  if (*buf && preserve_len > 0) {
    memcpy(p, *buf, preserve_len);
  }
  if (*buf) {
    lunet_free_nonnull(*buf);
  }
  *buf = p;
  *cap = next;
  return 0;
}

static ssize_t ws_recv_callback(wslay_event_context_ptr ctx,
                                uint8_t *buf,
                                size_t len,
                                int flags,
                                void *user_data) {
  (void)flags;
  ws_conn_t *conn = (ws_conn_t *)user_data;
  if (!conn) {
    wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
    return -1;
  }
  if (conn->in_off >= conn->in_len || !conn->in_buf) {
    wslay_event_set_error(ctx, WSLAY_ERR_WOULDBLOCK);
    return -1;
  }
  size_t avail = conn->in_len - conn->in_off;
  size_t n = (avail < len) ? avail : len;
  memcpy(buf, conn->in_buf + conn->in_off, n);
  conn->in_off += n;
  return (ssize_t)n;
}

static ssize_t ws_send_callback(wslay_event_context_ptr ctx,
                                const uint8_t *data,
                                size_t len,
                                int flags,
                                void *user_data) {
  (void)flags;
  ws_conn_t *conn = (ws_conn_t *)user_data;
  if (!conn) {
    wslay_event_set_error(ctx, WSLAY_ERR_CALLBACK_FAILURE);
    return -1;
  }
  if (len == 0) {
    return 0;
  }
  size_t need = 0;
  if (ws_size_add(conn->out_len, len, &need) != 0) {
    wslay_event_set_error(ctx, WSLAY_ERR_NOMEM);
    return -1;
  }
  if (ws_reserve(&conn->out_buf, &conn->out_cap, need, conn->out_len) != 0) {
    wslay_event_set_error(ctx, WSLAY_ERR_NOMEM);
    return -1;
  }
  memcpy(conn->out_buf + conn->out_len, data, len);
  conn->out_len += len;
  return (ssize_t)len;
}

static void ws_on_msg_recv_callback(wslay_event_context_ptr ctx,
                                    const struct wslay_event_on_msg_recv_arg *arg,
                                    void *user_data) {
  ws_conn_t *conn = (ws_conn_t *)user_data;
  if (!conn || !arg) {
    return;
  }

  if (arg->opcode == WSLAY_CONNECTION_CLOSE) {
    conn->closed = 1;
    return;
  }

  if (arg->opcode != WSLAY_TEXT_FRAME && arg->opcode != WSLAY_BINARY_FRAME) {
    return;
  }

  ws_msg_node_t *node = (ws_msg_node_t *)lunet_alloc(sizeof(ws_msg_node_t));
  if (!node) {
    conn->closed = 1;
    wslay_event_set_error(ctx, WSLAY_ERR_NOMEM);
    return;
  }
  memset(node, 0, sizeof(*node));
  node->opcode = arg->opcode;
  node->msg_len = arg->msg_length;

  if (arg->msg_length > 0 && arg->msg) {
    node->msg = (uint8_t *)lunet_alloc(arg->msg_length);
    if (!node->msg) {
      lunet_free(node);
      conn->closed = 1;
      wslay_event_set_error(ctx, WSLAY_ERR_NOMEM);
      return;
    }
    memcpy(node->msg, arg->msg, arg->msg_length);
  }

  if (conn->msg_tail) {
    conn->msg_tail->next = node;
  } else {
    conn->msg_head = node;
  }
  conn->msg_tail = node;
  conn->msg_count += 1;
}

static int ws_drain_out(ws_conn_t *conn) {
  while (wslay_event_want_write(conn->wslay)) {
    /*
     * In this module, ws_send_callback only appends encoded frames to an
     * in-memory buffer and never does socket I/O, so it never sets
     * WSLAY_ERR_WOULDBLOCK. Per wslay API, any non-zero return here is fatal.
     */
    int rc = wslay_event_send(conn->wslay);
    if (rc != 0) {
      return -1;
    }
  }
  return 0;
}

static int ws_new(lua_State *L) {
  lua_Integer max_recv_msg = luaL_optinteger(L, 1, 8 * 1024 * 1024);
  if (max_recv_msg <= 0) {
    lua_pushnil(L);
    lua_pushstring(L, "max_message_size must be > 0");
    return 2;
  }

  ws_conn_t *conn = (ws_conn_t *)lunet_alloc(sizeof(ws_conn_t));
  if (!conn) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  memset(conn, 0, sizeof(*conn));

  struct wslay_event_callbacks callbacks;
  memset(&callbacks, 0, sizeof(callbacks));
  callbacks.recv_callback = ws_recv_callback;
  callbacks.send_callback = ws_send_callback;
  callbacks.on_msg_recv_callback = ws_on_msg_recv_callback;

  if (wslay_event_context_server_init(&conn->wslay, &callbacks, conn) != 0) {
    lunet_free(conn);
    lua_pushnil(L);
    lua_pushstring(L, "failed to initialize websocket context");
    return 2;
  }
  wslay_event_config_set_max_recv_msg_length(conn->wslay, (uint64_t)max_recv_msg);

  lua_pushlightuserdata(L, conn);
  lua_pushnil(L);
  return 2;
}

static int ws_feed(lua_State *L) {
  ws_conn_t *conn = (ws_conn_t *)lua_touserdata(L, 1);
  size_t n = 0;
  const char *chunk = luaL_checklstring(L, 2, &n);

  if (!conn || !conn->wslay) {
    lua_pushnil(L);
    lua_pushnil(L);
    lua_pushnil(L);
    lua_pushboolean(L, 1);
    lua_pushstring(L, "invalid websocket handle");
    return 5;
  }

  conn->out_len = 0;
  if (n > 0) {
    size_t need = 0;
    if (ws_size_add(conn->in_len, n, &need) != 0) {
      lua_pushnil(L);
      lua_pushnil(L);
      lua_pushnil(L);
      lua_pushboolean(L, conn->closed ? 1 : 0);
      lua_pushstring(L, "input buffer too large");
      return 5;
    }
    if (ws_reserve(&conn->in_buf, &conn->in_cap, need, conn->in_len) != 0) {
      lua_pushnil(L);
      lua_pushnil(L);
      lua_pushnil(L);
      lua_pushboolean(L, conn->closed ? 1 : 0);
      lua_pushstring(L, "out of memory");
      return 5;
    }
    memcpy(conn->in_buf + conn->in_len, chunk, n);
    conn->in_len += n;
  }

  while (conn->in_off < conn->in_len && conn->msg_head == NULL && !conn->closed) {
    int rc = wslay_event_recv(conn->wslay);
    if (rc != 0) {
      /*
       * wslay_event_recv() does not surface WSLAY_ERR_WOULDBLOCK as return
       * value. WOULDBLOCK from recv_callback is absorbed internally and recv()
       * returns 0, so any non-zero rc here is treated as fatal.
       */
      conn->in_len = 0;
      conn->in_off = 0;
      lua_pushnil(L);
      lua_pushnil(L);
      lua_pushnil(L);
      lua_pushboolean(L, conn->closed ? 1 : 0);
      lua_pushstring(L, "websocket frame decode failed");
      return 5;
    }
  }

  if (conn->in_off > 0) {
    if (conn->in_off < conn->in_len) {
      memmove(conn->in_buf, conn->in_buf + conn->in_off, conn->in_len - conn->in_off);
      conn->in_len -= conn->in_off;
      conn->in_off = 0;
    } else {
      conn->in_len = 0;
      conn->in_off = 0;
    }
  }

  if (ws_drain_out(conn) != 0) {
    lua_pushnil(L);
    lua_pushnil(L);
    lua_pushnil(L);
    lua_pushboolean(L, conn->closed ? 1 : 0);
    lua_pushstring(L, "websocket frame encode failed");
    return 5;
  }

  if (conn->msg_head) {
    ws_msg_node_t *node = conn->msg_head;
    conn->msg_head = node->next;
    if (!conn->msg_head) {
      conn->msg_tail = NULL;
    }
    if (conn->msg_count > 0) {
      conn->msg_count -= 1;
    }
    if (node->msg_len > 0 && node->msg) {
      lua_pushlstring(L, (const char *)node->msg, node->msg_len);
    } else {
      lua_pushliteral(L, "");
    }
    lua_pushinteger(L, node->opcode);
    if (node->msg) {
      lunet_free_nonnull(node->msg);
    }
    lunet_free_nonnull(node);
  } else {
    lua_pushnil(L);
    lua_pushnil(L);
  }

  if (conn->out_len > 0) {
    lua_pushlstring(L, (const char *)conn->out_buf, conn->out_len);
  } else {
    lua_pushnil(L);
  }
  lua_pushboolean(L, (conn->closed && conn->msg_head == NULL) ? 1 : 0);
  lua_pushnil(L);
  return 5;
}

static int ws_queue_msg_internal(lua_State *L, uint8_t opcode) {
  ws_conn_t *conn = (ws_conn_t *)lua_touserdata(L, 1);
  size_t len = 0;
  const char *data = luaL_checklstring(L, 2, &len);
  if (!conn || !conn->wslay) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid websocket handle");
    return 2;
  }

  conn->out_len = 0;

  struct wslay_event_msg msg;
  msg.opcode = opcode;
  msg.msg = (const uint8_t *)data;
  msg.msg_length = len;
  if (wslay_event_queue_msg(conn->wslay, &msg) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, "failed to queue websocket message");
    return 2;
  }
  if (ws_drain_out(conn) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, "websocket frame encode failed");
    return 2;
  }

  if (conn->out_len > 0) {
    lua_pushlstring(L, (const char *)conn->out_buf, conn->out_len);
  } else {
    lua_pushnil(L);
  }
  lua_pushnil(L);
  return 2;
}

static int ws_queue_msg(lua_State *L) {
  ws_conn_t *conn = (ws_conn_t *)lua_touserdata(L, 1);
  int opcode = (int)luaL_optinteger(L, 3, WSLAY_TEXT_FRAME);
  if (!conn || !conn->wslay) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid websocket handle");
    return 2;
  }
  if (opcode != WSLAY_TEXT_FRAME && opcode != WSLAY_BINARY_FRAME) {
    lua_pushnil(L);
    lua_pushstring(L, "opcode must be TEXT(1) or BINARY(2)");
    return 2;
  }
  return ws_queue_msg_internal(L, (uint8_t)opcode);
}

static int ws_queue_ping(lua_State *L) {
  return ws_queue_msg_internal(L, WSLAY_PING);
}

static int ws_queue_close(lua_State *L) {
  ws_conn_t *conn = (ws_conn_t *)lua_touserdata(L, 1);
  int code = (int)luaL_optinteger(L, 2, 1000);
  size_t len = 0;
  const char *reason = luaL_optlstring(L, 3, "", &len);
  if (!conn || !conn->wslay) {
    lua_pushnil(L);
    lua_pushnil(L);
    return 2;
  }
  if (len > 123) {
    len = 123;
  }

  conn->out_len = 0;
  if (wslay_event_queue_close(conn->wslay,
                              (uint16_t)code,
                              (const uint8_t *)reason,
                              len) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, "failed to queue close frame");
    return 2;
  }
  if (ws_drain_out(conn) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, "websocket close encode failed");
    return 2;
  }
  conn->closed = 1;
  if (conn->out_len > 0) {
    lua_pushlstring(L, (const char *)conn->out_buf, conn->out_len);
  } else {
    lua_pushnil(L);
  }
  lua_pushnil(L);
  return 2;
}

static int ws_free(lua_State *L) {
  ws_conn_t *conn = (ws_conn_t *)lua_touserdata(L, 1);
  if (!conn) {
    lua_pushboolean(L, 1);
    return 1;
  }

  if (conn->wslay) {
    wslay_event_context_free(conn->wslay);
    conn->wslay = NULL;
  }
  if (conn->out_buf) {
    lunet_free_nonnull(conn->out_buf);
    conn->out_buf = NULL;
  }
  if (conn->in_buf) {
    lunet_free_nonnull(conn->in_buf);
    conn->in_buf = NULL;
  }
  while (conn->msg_head) {
    ws_msg_node_t *node = conn->msg_head;
    conn->msg_head = node->next;
    if (node->msg) {
      lunet_free_nonnull(node->msg);
    }
    lunet_free_nonnull(node);
  }
  conn->msg_tail = NULL;
  conn->msg_count = 0;
  lunet_free(conn);

  lua_pushboolean(L, 1);
  return 1;
}

int lunet_open_websocket(lua_State *L) {
  luaL_Reg funcs[] = {
      {"_new", ws_new},
      {"_feed", ws_feed},
      {"_queue_msg", ws_queue_msg},
      {"_queue_ping", ws_queue_ping},
      {"_queue_close", ws_queue_close},
      {"_free", ws_free},
      {NULL, NULL}};
  luaL_newlib(L, funcs);
  lua_pushinteger(L, WSLAY_TEXT_FRAME);
  lua_setfield(L, -2, "TEXT");
  lua_pushinteger(L, WSLAY_BINARY_FRAME);
  lua_setfield(L, -2, "BINARY");
  lua_pushinteger(L, WSLAY_CONNECTION_CLOSE);
  lua_setfield(L, -2, "CLOSE");
  lua_pushinteger(L, WSLAY_PING);
  lua_setfield(L, -2, "PING");
  lua_pushinteger(L, WSLAY_PONG);
  lua_setfield(L, -2, "PONG");
  return 1;
}
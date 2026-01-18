#include "mysql.h"

#include <lauxlib.h>
#include <lua.h>
#include <mysql/mysql.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "co.h"
#include "uv.h"

typedef struct {
  uv_work_t req;
  lua_State* L;
  int co_ref;

  MYSQL* conn;
  char err[256];

  char host[256];
  int port;
  char user[256];
  char password[256];
  char database[256];
  char charset[256];
} mysql_open_ctx_t;

static void mysql_open_work_cb(uv_work_t* req) {
  mysql_open_ctx_t* ctx = (mysql_open_ctx_t*)req->data;
  ctx->conn = mysql_init(NULL);
  if (!ctx->conn) {
    snprintf(ctx->err, sizeof(ctx->err), "mysql_init failed");
    return;
  }

  mysql_options(ctx->conn, MYSQL_SET_CHARSET_NAME, ctx->charset);

  if (!mysql_real_connect(ctx->conn, ctx->host, ctx->user, ctx->password, ctx->database, ctx->port, NULL, 0)) {
    strncpy(ctx->err, mysql_error(ctx->conn), sizeof(ctx->err));
    mysql_close(ctx->conn);
    ctx->conn = NULL;
    return;
  }
}

static void mysql_open_after_cb(uv_work_t* req, int status) {
  mysql_open_ctx_t* ctx = (mysql_open_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in mysql.open\n");
    mysql_close(ctx->conn);
    ctx->conn = NULL;
    free(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->conn) {
    lua_pushlightuserdata(co, ctx->conn);
    lua_pushnil(co);
  } else {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
  }
  lua_resume(co, 2);
  free(ctx);
}

int lunet_mysql_open(lua_State* L) {
  if (lunet_ensure_coroutine(L, "mysql.open")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 1 || !lua_istable(L, 1)) {
    lua_pushstring(L, "mysql.open requires params table");
    return lua_error(L);
  }

  mysql_open_ctx_t* ctx = malloc(sizeof(mysql_open_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "mysql.open: out of memory");
    return lua_error(L);
  }
  memset(ctx->err, 0, sizeof(ctx->err));
  ctx->L = L;
  ctx->req.data = ctx;

  // read params from table
  lua_getfield(L, 1, "host");
  strncpy(ctx->host, luaL_checkstring(L, -1), sizeof(ctx->host));
  lua_getfield(L, 1, "port");
  ctx->port = luaL_checkinteger(L, -1);
  lua_getfield(L, 1, "user");
  strncpy(ctx->user, luaL_checkstring(L, -1), sizeof(ctx->user));
  lua_getfield(L, 1, "password");
  strncpy(ctx->password, luaL_checkstring(L, -1), sizeof(ctx->password));
  lua_getfield(L, 1, "database");
  strncpy(ctx->database, luaL_checkstring(L, -1), sizeof(ctx->database));
  lua_getfield(L, 1, "charset");
  strncpy(ctx->charset, luaL_checkstring(L, -1), sizeof(ctx->charset));
  // save coroutine reference to main lua state
  lua_pop(L, 6);

  lua_pushthread(L);
  ctx->co_ref = luaL_ref(L, LUA_REGISTRYINDEX);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, mysql_open_work_cb, mysql_open_after_cb);
  if (ret < 0) {
    luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
    free(ctx);
    lua_pushnil(L);
    lua_pushfstring(L, "mysql.open: uv_queue_work failed: %s", uv_strerror(ret));
    return lua_error(L);
  }

  return lua_yield(L, 0);
}

int lunet_mysql_close(lua_State* L) {
  if (lunet_ensure_coroutine(L, "mysql.close")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 1) {
    lua_pushstring(L, "mysql.close requires a connection");
    return 1;
  }
  if (!lua_isuserdata(L, 1) && !lua_islightuserdata(L, 1)) {
    lua_pushstring(L, "mysql.close requires a connection");
    return 1;
  }

  MYSQL* conn = (MYSQL*)lua_touserdata(L, 1);
  if (!conn) {
    lua_pushstring(L, "invalid connection");
    return 1;
  }

  mysql_close(conn);
  lua_pushnil(L);
  return 1;
}

typedef struct {
  uv_work_t req;
  lua_State* L;
  int co_ref;

  MYSQL* conn;
  const char* query;

  MYSQL_RES* result;
  char err[256];
} mysql_query_ctx_t;

static void mysql_query_work_cb(uv_work_t* req) {
  mysql_query_ctx_t* ctx = (mysql_query_ctx_t*)req->data;

  if (mysql_query(ctx->conn, ctx->query)) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", mysql_error(ctx->conn));
    ctx->result = NULL;
    return;
  }

  ctx->result = mysql_store_result(ctx->conn);
  if (!ctx->result && mysql_field_count(ctx->conn) != 0) {
    snprintf(ctx->err, sizeof(ctx->err), "mysql_store_result failed: %s", mysql_error(ctx->conn));
  }
}

static void mysql_query_after_cb(uv_work_t* req, int status) {
  mysql_query_ctx_t* ctx = (mysql_query_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in mysql.query\n");
    if (ctx->result) mysql_free_result(ctx->result);
    free((void*)ctx->query);
    free(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->result) {
    lua_newtable(co);
    int row_idx = 1;

    MYSQL_ROW row;
    unsigned int num_fields = mysql_num_fields(ctx->result);
    MYSQL_FIELD* fields = mysql_fetch_fields(ctx->result);

    while ((row = mysql_fetch_row(ctx->result))) {
      lua_newtable(co);
      unsigned long* lengths = mysql_fetch_lengths(ctx->result);
      for (unsigned int i = 0; i < num_fields; ++i) {
        lua_pushstring(co, fields[i].name);

        if (row[i] == NULL) {
          lua_pushnil(co);
        } else {
          switch (fields[i].type) {
            case MYSQL_TYPE_TINY:
            case MYSQL_TYPE_SHORT:
            case MYSQL_TYPE_LONG:
            case MYSQL_TYPE_INT24:
            case MYSQL_TYPE_LONGLONG:
              lua_pushinteger(co, strtoll(row[i], NULL, 10));
              break;

            case MYSQL_TYPE_FLOAT:
            case MYSQL_TYPE_DOUBLE:
            case MYSQL_TYPE_DECIMAL:
              lua_pushnumber(co, strtod(row[i], NULL));
              break;

            case MYSQL_TYPE_NULL:
              lua_pushnil(co);
              break;

            default:
              lua_pushlstring(co, row[i], lengths[i]);
              break;
          }
        }

        lua_settable(co, -3);
      }
      lua_rawseti(co, -2, row_idx++);
    }

    mysql_free_result(ctx->result);
    ctx->result = NULL;

    lua_pushnil(co);
    lua_resume(co, 2);
  } else {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
    lua_resume(co, 2);
  }

  free(ctx);
}

int lunet_mysql_query(lua_State* L) {
  if (lunet_ensure_coroutine(L, "mysql.query")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "mysql.query requires connection and sql string");
    return 2;
  }

  if (!lua_isuserdata(L, 1) && !lua_islightuserdata(L, 1)) {
    lua_pushnil(L);
    lua_pushstring(L, "mysql.query requires a connection");
    return 2;
  }

  MYSQL* conn = (MYSQL*)lua_touserdata(L, 1);
  if (!conn) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid connection");
    return 2;
  }

  const char* query = luaL_checkstring(L, 2);

  mysql_query_ctx_t* ctx = malloc(sizeof(mysql_query_ctx_t));
  if (!ctx) {
    lua_pushstring(L, "out of memory");
    return lua_error(L);
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->L = L;
  ctx->req.data = ctx;
  ctx->conn = conn;
  ctx->query = strdup(query);
  if (!ctx->query) {
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  lua_pushthread(L);
  ctx->co_ref = luaL_ref(L, LUA_REGISTRYINDEX);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, mysql_query_work_cb, mysql_query_after_cb);
  if (ret < 0) {
    luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
    free((void*)ctx->query);
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(ret));
    return 2;
  }

  return lua_yield(L, 0);
}

typedef struct {
  uv_work_t req;
  lua_State* L;
  int co_ref;

  MYSQL* conn;
  const char* query;

  int affected_rows;
  unsigned long long insert_id;
  char err[256];
} mysql_exec_ctx_t;

static void mysql_exec_work_cb(uv_work_t* req) {
  mysql_exec_ctx_t* ctx = (mysql_exec_ctx_t*)req->data;

  if (mysql_query(ctx->conn, ctx->query)) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", mysql_error(ctx->conn));
    return;
  }

  ctx->affected_rows = mysql_affected_rows(ctx->conn);
  ctx->insert_id = mysql_insert_id(ctx->conn);
}

static void mysql_exec_after_cb(uv_work_t* req, int status) {
  mysql_exec_ctx_t* ctx = (mysql_exec_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in mysql.exec\n");
    free((void*)ctx->query);
    free(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->err[0] != '\0') {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
    lua_resume(co, 2);
  } else {
    lua_newtable(co);
    lua_pushstring(co, "affected_rows");
    lua_pushinteger(co, ctx->affected_rows);
    lua_settable(co, -3);
    lua_pushstring(co, "last_insert_id");
    lua_pushinteger(co, ctx->insert_id);
    lua_settable(co, -3);
    lua_pushnil(co);
    lua_resume(co, 2);
  }

  free((void*)ctx->query);
  free(ctx);
}

int lunet_mysql_exec(lua_State* L) {
  if (lunet_ensure_coroutine(L, "mysql.exec")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "mysql.exec requires connection and sql string");
    return 2;
  }
  if (!lua_isuserdata(L, 1) && !lua_islightuserdata(L, 1)) {
    lua_pushnil(L);
    lua_pushstring(L, "mysql.exec requires a connection");
    return 2;
  }

  MYSQL* conn = (MYSQL*)lua_touserdata(L, 1);
  if (!conn) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid connection");
    return 2;
  }

  const char* query = luaL_checkstring(L, 2);

  mysql_exec_ctx_t* ctx = malloc(sizeof(mysql_exec_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->L = L;
  ctx->req.data = ctx;
  ctx->conn = conn;
  ctx->query = strdup(query);
  if (!ctx->query) {
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  lua_pushthread(L);
  ctx->co_ref = luaL_ref(L, LUA_REGISTRYINDEX);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, mysql_exec_work_cb, mysql_exec_after_cb);
  if (ret < 0) {
    luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
    free((void*)ctx->query);
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(ret));
    return 2;
  }

  return lua_yield(L, 0);
}
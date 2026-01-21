#include "mysql.h"

#include <lauxlib.h>
#include <lua.h>
#include <mysql/mysql.h>
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
} db_open_ctx_t;

static void db_open_work_cb(uv_work_t* req) {
  db_open_ctx_t* ctx = (db_open_ctx_t*)req->data;
  mysql_thread_init();
  ctx->conn = mysql_init(NULL);
  if (!ctx->conn) {
    snprintf(ctx->err, sizeof(ctx->err), "mysql_init failed");
    mysql_thread_end();
    return;
  }

  mysql_options(ctx->conn, MYSQL_SET_CHARSET_NAME, ctx->charset);

  if (!mysql_real_connect(ctx->conn, ctx->host, ctx->user, ctx->password, ctx->database, ctx->port, NULL, 0)) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", mysql_error(ctx->conn));
    mysql_close(ctx->conn);
    ctx->conn = NULL;
    mysql_thread_end();
    return;
  }
  mysql_thread_end();
}

static void db_open_after_cb(uv_work_t* req, int status) {
  db_open_ctx_t* ctx = (db_open_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.open\n");
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
  int rc = lua_resume(co, 2);
  if (rc != 0 && rc != LUA_YIELD) {
    const char* err = lua_tostring(co, -1);
    if (err) fprintf(stderr, "lua_resume error in db.open: %s\n", err);
    lua_pop(co, 1);
  }
  free(ctx);
}

int lunet_db_open(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.open")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 1 || !lua_istable(L, 1)) {
    lua_pushstring(L, "db.open requires params table");
    return lua_error(L);
  }

  db_open_ctx_t* ctx = malloc(sizeof(db_open_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "db.open: out of memory");
    return lua_error(L);
  }
  memset(ctx->err, 0, sizeof(ctx->err));
  ctx->L = L;
  ctx->req.data = ctx;

  lua_getfield(L, 1, "host");
  snprintf(ctx->host, sizeof(ctx->host), "%s", luaL_optstring(L, -1, "localhost"));
  lua_getfield(L, 1, "port");
  ctx->port = (int)luaL_optinteger(L, -1, 3306);
  if (ctx->port < 1 || ctx->port > 65535) ctx->port = 3306;
  lua_getfield(L, 1, "user");
  snprintf(ctx->user, sizeof(ctx->user), "%s", luaL_optstring(L, -1, "root"));
  lua_getfield(L, 1, "password");
  snprintf(ctx->password, sizeof(ctx->password), "%s", luaL_optstring(L, -1, ""));
  lua_getfield(L, 1, "database");
  snprintf(ctx->database, sizeof(ctx->database), "%s", luaL_optstring(L, -1, ""));
  lua_getfield(L, 1, "charset");
  snprintf(ctx->charset, sizeof(ctx->charset), "%s", luaL_optstring(L, -1, "utf8mb4"));
  lua_pop(L, 6);

  lua_pushthread(L);
  ctx->co_ref = luaL_ref(L, LUA_REGISTRYINDEX);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_open_work_cb, db_open_after_cb);
  if (ret < 0) {
    luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
    free(ctx);
    lua_pushnil(L);
    lua_pushfstring(L, "db.open: uv_queue_work failed: %s", uv_strerror(ret));
    return lua_error(L);
  }

  return lua_yield(L, 0);
}

int lunet_db_close(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.close")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 1) {
    lua_pushstring(L, "db.close requires a connection");
    return 1;
  }
  if (!lua_isuserdata(L, 1) && !lua_islightuserdata(L, 1)) {
    lua_pushstring(L, "db.close requires a connection");
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
  char* query;

  MYSQL_RES* result;
  char err[256];
} db_query_ctx_t;

static void db_query_work_cb(uv_work_t* req) {
  db_query_ctx_t* ctx = (db_query_ctx_t*)req->data;

  mysql_thread_init();
  if (mysql_query(ctx->conn, ctx->query)) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", mysql_error(ctx->conn));
    ctx->result = NULL;
    mysql_thread_end();
    return;
  }

  ctx->result = mysql_store_result(ctx->conn);
  if (!ctx->result && mysql_field_count(ctx->conn) != 0) {
    snprintf(ctx->err, sizeof(ctx->err), "mysql_store_result failed: %s", mysql_error(ctx->conn));
  }
  mysql_thread_end();
}

static void db_query_after_cb(uv_work_t* req, int status) {
  db_query_ctx_t* ctx = (db_query_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.query\n");
    if (ctx->result) mysql_free_result(ctx->result);
    free(ctx->query);
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
    int rc = lua_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) fprintf(stderr, "lua_resume error in db.query: %s\n", err);
      lua_pop(co, 1);
    }
  } else {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
    int rc = lua_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) fprintf(stderr, "lua_resume error in db.query: %s\n", err);
      lua_pop(co, 1);
    }
  }

  free(ctx->query);
  free(ctx);
}

int lunet_db_query(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.query")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "db.query requires connection and sql string");
    return 2;
  }

  if (!lua_isuserdata(L, 1) && !lua_islightuserdata(L, 1)) {
    lua_pushnil(L);
    lua_pushstring(L, "db.query requires a connection");
    return 2;
  }

  MYSQL* conn = (MYSQL*)lua_touserdata(L, 1);
  if (!conn) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid connection");
    return 2;
  }

  const char* query = luaL_checkstring(L, 2);

  db_query_ctx_t* ctx = malloc(sizeof(db_query_ctx_t));
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

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_query_work_cb, db_query_after_cb);
  if (ret < 0) {
    luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
    free(ctx->query);
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
  char* query;

  int affected_rows;
  unsigned long long insert_id;
  char err[256];
} db_exec_ctx_t;

static void db_exec_work_cb(uv_work_t* req) {
  db_exec_ctx_t* ctx = (db_exec_ctx_t*)req->data;

  mysql_thread_init();
  if (mysql_query(ctx->conn, ctx->query)) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", mysql_error(ctx->conn));
    mysql_thread_end();
    return;
  }

  ctx->affected_rows = mysql_affected_rows(ctx->conn);
  ctx->insert_id = mysql_insert_id(ctx->conn);
  mysql_thread_end();
}

static void db_exec_after_cb(uv_work_t* req, int status) {
  db_exec_ctx_t* ctx = (db_exec_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.exec\n");
    free(ctx->query);
    free(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->err[0] != '\0') {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
    int rc = lua_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) fprintf(stderr, "lua_resume error in db.exec: %s\n", err);
      lua_pop(co, 1);
    }
  } else {
    lua_newtable(co);
    lua_pushstring(co, "affected_rows");
    lua_pushinteger(co, ctx->affected_rows);
    lua_settable(co, -3);
    lua_pushstring(co, "last_insert_id");
    lua_pushinteger(co, ctx->insert_id);
    lua_settable(co, -3);
    lua_pushnil(co);
    int rc = lua_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) fprintf(stderr, "lua_resume error in db.exec: %s\n", err);
      lua_pop(co, 1);
    }
  }

  free(ctx->query);
  free(ctx);
}

int lunet_db_exec(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.exec")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "db.exec requires connection and sql string");
    return 2;
  }
  if (!lua_isuserdata(L, 1) && !lua_islightuserdata(L, 1)) {
    lua_pushnil(L);
    lua_pushstring(L, "db.exec requires a connection");
    return 2;
  }

  MYSQL* conn = (MYSQL*)lua_touserdata(L, 1);
  if (!conn) {
    lua_pushnil(L);
    lua_pushstring(L, "invalid connection");
    return 2;
  }

  const char* query = luaL_checkstring(L, 2);

  db_exec_ctx_t* ctx = malloc(sizeof(db_exec_ctx_t));
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

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_exec_work_cb, db_exec_after_cb);
  if (ret < 0) {
    luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
    free(ctx->query);
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(ret));
    return 2;
  }

  return lua_yield(L, 0);
}

int lunet_db_escape(lua_State* L) {
  luaL_checkstring(L, 1);
  lua_getglobal(L, "string");
  lua_getfield(L, -1, "gsub");
  lua_remove(L, -2); /* remove string table */

  if (!lua_isfunction(L, -1)) {
    return luaL_error(L, "string.gsub is not available");
  }

  lua_pushvalue(L, 1);
  lua_pushstring(L, "(['\\\\])");
  lua_pushstring(L, "\\%1");

  if (lua_pcall(L, 3, 1, 0) != LUA_OK) {
    return lua_error(L);
  }
  return 1;
}
#include "sqlite3.h"

#include <lauxlib.h>
#include <lua.h>
#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>

#include "co.h"
#include "uv.h"

typedef struct {
  uv_work_t req;
  lua_State* L;
  int co_ref;

  sqlite3* conn;
  char err[256];

  char path[1024];
} db_open_ctx_t;

static void db_open_work_cb(uv_work_t* req) {
  db_open_ctx_t* ctx = (db_open_ctx_t*)req->data;

  int rc = sqlite3_open(ctx->path, &ctx->conn);
  if (rc != SQLITE_OK) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", sqlite3_errmsg(ctx->conn));
    sqlite3_close(ctx->conn);
    ctx->conn = NULL;
    return;
  }
}

static void db_open_after_cb(uv_work_t* req, int status) {
  db_open_ctx_t* ctx = (db_open_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.open\n");
    if (ctx->conn) sqlite3_close(ctx->conn);
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

  lua_getfield(L, 1, "path");
  const char* path = luaL_optstring(L, -1, ":memory:");
  snprintf(ctx->path, sizeof(ctx->path), "%s", path);
  lua_pop(L, 1);

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

  sqlite3* conn = (sqlite3*)lua_touserdata(L, 1);
  if (!conn) {
    lua_pushstring(L, "invalid connection");
    return 1;
  }

  sqlite3_close(conn);
  lua_pushnil(L);
  return 1;
}

typedef struct {
  uv_work_t req;
  lua_State* L;
  int co_ref;

  sqlite3* conn;
  char* query;

  char** col_names;
  int* col_types;
  char*** rows;
  int nrows;
  int ncols;
  char err[256];
} db_query_ctx_t;

static void db_query_work_cb(uv_work_t* req) {
  db_query_ctx_t* ctx = (db_query_ctx_t*)req->data;
  sqlite3_stmt* stmt = NULL;

  int rc = sqlite3_prepare_v2(ctx->conn, ctx->query, -1, &stmt, NULL);
  if (rc != SQLITE_OK) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", sqlite3_errmsg(ctx->conn));
    return;
  }

  ctx->ncols = sqlite3_column_count(stmt);
  ctx->col_names = malloc(sizeof(char*) * ctx->ncols);
  ctx->col_types = malloc(sizeof(int) * ctx->ncols);
  for (int i = 0; i < ctx->ncols; i++) {
    const char* name = sqlite3_column_name(stmt, i);
    ctx->col_names[i] = strdup(name ? name : "");
  }

  int capacity = 16;
  ctx->rows = malloc(sizeof(char**) * capacity);
  ctx->nrows = 0;

  while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
    if (ctx->nrows >= capacity) {
      capacity *= 2;
      ctx->rows = realloc(ctx->rows, sizeof(char**) * capacity);
    }

    char** row = malloc(sizeof(char*) * ctx->ncols);
    for (int i = 0; i < ctx->ncols; i++) {
      int t = sqlite3_column_type(stmt, i);
      if (ctx->nrows == 0 && ctx->col_types) ctx->col_types[i] = t;
      if (t == SQLITE_NULL) {
        row[i] = NULL;
      } else {
        const char* val = (const char*)sqlite3_column_text(stmt, i);
        row[i] = val ? strdup(val) : NULL;
      }
    }
    ctx->rows[ctx->nrows] = row;
    ctx->nrows++;
  }

  if (rc != SQLITE_DONE) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", sqlite3_errmsg(ctx->conn));
  }

  sqlite3_finalize(stmt);
}

static void db_query_after_cb(uv_work_t* req, int status) {
  db_query_ctx_t* ctx = (db_query_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.query\n");
    goto cleanup;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->err[0] != '\0') {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
    int rc = lua_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) fprintf(stderr, "lua_resume error in db.query: %s\n", err);
      lua_pop(co, 1);
    }
    goto cleanup;
  }

  lua_newtable(co);
  int* types = ctx->col_types;

  for (int i = 0; i < ctx->nrows; i++) {
    lua_newtable(co);
    for (int j = 0; j < ctx->ncols; j++) {
      lua_pushstring(co, ctx->col_names[j]);
      if (ctx->rows[i][j] == NULL) {
        lua_pushnil(co);
      } else {
        int coltype = types ? types[j] : SQLITE_TEXT;
        switch (coltype) {
          case SQLITE_INTEGER:
            lua_pushinteger(co, strtoll(ctx->rows[i][j], NULL, 10));
            break;
          case SQLITE_FLOAT:
            lua_pushnumber(co, strtod(ctx->rows[i][j], NULL));
            break;
          default:
            lua_pushstring(co, ctx->rows[i][j]);
            break;
        }
      }
      lua_settable(co, -3);
    }
    lua_rawseti(co, -2, i + 1);
  }

  lua_pushnil(co);
  {
    int rc = lua_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) fprintf(stderr, "lua_resume error in db.query: %s\n", err);
      lua_pop(co, 1);
    }
  }

cleanup:
  for (int i = 0; i < ctx->nrows; i++) {
    for (int j = 0; j < ctx->ncols; j++) {
      free(ctx->rows[i][j]);
    }
    free(ctx->rows[i]);
  }
  free(ctx->rows);
  for (int i = 0; i < ctx->ncols; i++) {
    free(ctx->col_names[i]);
  }
  free(ctx->col_names);
  free(ctx->col_types);
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

  sqlite3* conn = (sqlite3*)lua_touserdata(L, 1);
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

  sqlite3* conn;
  char* query;

  long long affected_rows;
  long long insert_id;
  char err[256];
} db_exec_ctx_t;

static void db_exec_work_cb(uv_work_t* req) {
  db_exec_ctx_t* ctx = (db_exec_ctx_t*)req->data;

  char* errmsg = NULL;
  int rc = sqlite3_exec(ctx->conn, ctx->query, NULL, NULL, &errmsg);
  if (rc != SQLITE_OK) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", errmsg ? errmsg : sqlite3_errmsg(ctx->conn));
    if (errmsg) sqlite3_free(errmsg);
    return;
  }

  ctx->affected_rows = sqlite3_changes(ctx->conn);
  ctx->insert_id = sqlite3_last_insert_rowid(ctx->conn);
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

  sqlite3* conn = (sqlite3*)lua_touserdata(L, 1);
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
  lua_pushstring(L, "'");
  lua_pushstring(L, "''");

  if (lua_pcall(L, 3, 1, 0) != LUA_OK) {
    return lua_error(L);
  }
  return 1;
}

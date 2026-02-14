#include "lunet_sqlite3.h"

#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>

#include "co.h"
#include "trace.h"
#include "lunet_mem.h"
#include "uv.h"

#define LUNET_SQLITE_CONN_MT "lunet.sqlite.conn"

static char* lunet_strdup_local(const char* s) {
  if (!s) return NULL;
  size_t len = strlen(s);
  char* out = lunet_alloc(len + 1);
  if (!out) return NULL;
  memcpy(out, s, len + 1);
  return out;
}

typedef struct {
  sqlite3* conn;
  uv_mutex_t mutex;
  int closed;
} lunet_sqlite_conn_t;

// Close the SQLite connection but don't destroy the mutex (caller may still hold it)
static void lunet_sqlite_conn_close(lunet_sqlite_conn_t* wrapper) {
  if (!wrapper || wrapper->closed) return;
  wrapper->closed = 1;
  if (wrapper->conn) {
    sqlite3_close(wrapper->conn);
    wrapper->conn = NULL;
  }
}

// Full cleanup including mutex - only call when mutex is NOT held (e.g., from GC)
static void lunet_sqlite_conn_destroy(lunet_sqlite_conn_t* wrapper) {
  lunet_sqlite_conn_close(wrapper);
  if (wrapper) {
    uv_mutex_destroy(&wrapper->mutex);
  }
}

static int conn_gc(lua_State* L) {
  lunet_sqlite_conn_t* wrapper = (lunet_sqlite_conn_t*)luaL_checkudata(L, 1, LUNET_SQLITE_CONN_MT);
  lunet_sqlite_conn_destroy(wrapper);
  return 0;
}

static void register_conn_metatable(lua_State* L) {
  if (luaL_newmetatable(L, LUNET_SQLITE_CONN_MT)) {
    lua_pushcfunction(L, conn_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_pop(L, 1);
}

typedef enum {
    PARAM_TYPE_NIL,
    PARAM_TYPE_INT,
    PARAM_TYPE_DOUBLE,
    PARAM_TYPE_TEXT
} param_type_t;

typedef struct {
    param_type_t type;
    union {
        long long i;
        double d;
        struct {
            char* data;
            size_t len;
        } s;
    } value;
} param_t;

static void free_params(param_t* params, int nparams) {
    if (!params) return;
    for (int i = 0; i < nparams; i++) {
        if (params[i].type == PARAM_TYPE_TEXT) {
            lunet_free_nonnull(params[i].value.s.data);
        }
    }
    lunet_free_nonnull(params);
}

static param_t* collect_params(lua_State* L, int start, int* nparams) {
    int top = lua_gettop(L);
    *nparams = top - start + 1;
    if (*nparams <= 0) {
        *nparams = 0;
        return NULL;
    }
    param_t* params = lunet_alloc(sizeof(param_t) * (*nparams));
    if (!params) {
        *nparams = -1;
        return NULL;
    }
    for (int i = 0; i < *nparams; i++) {
        int idx = start + i;
        int type = lua_type(L, idx);
        switch (type) {
            case LUA_TNIL:
                params[i].type = PARAM_TYPE_NIL;
                break;
            case LUA_TNUMBER: {
                lua_Number n = lua_tonumber(L, idx);
                long long val = (long long)n;
                if ((lua_Number)val == n) {
                    params[i].type = PARAM_TYPE_INT;
                    params[i].value.i = val;
                } else {
                    params[i].type = PARAM_TYPE_DOUBLE;
                    params[i].value.d = n;
                }
                break;
            }
            case LUA_TBOOLEAN:
                params[i].type = PARAM_TYPE_INT;
                params[i].value.i = lua_toboolean(L, idx);
                break;
            case LUA_TSTRING: {
                size_t len;
                const char* s = lua_tolstring(L, idx, &len);
                params[i].type = PARAM_TYPE_TEXT;
                params[i].value.s.data = lunet_alloc(len + 1);
                if (!params[i].value.s.data) {
                    free_params(params, i);
                    *nparams = -1;
                    return NULL;
                }
                memcpy(params[i].value.s.data, s, len);
                params[i].value.s.data[len] = '\0';
                params[i].value.s.len = len;
                break;
            }
            default: {
                const char* s = lua_tostring(L, idx);
                if (s) {
                    size_t len = strlen(s);
                    params[i].type = PARAM_TYPE_TEXT;
                    params[i].value.s.data = lunet_strdup_local(s);
                    if (!params[i].value.s.data) {
                        free_params(params, i);
                        *nparams = -1;
                        return NULL;
                    }
                    params[i].value.s.len = len;
                } else {
                    params[i].type = PARAM_TYPE_NIL;
                }
                break;
            }
        }
    }
    return params;
}

static int bind_params(sqlite3_stmt* stmt, param_t* params, int nparams, char* err, size_t errsize) {
    int expected = sqlite3_bind_parameter_count(stmt);
    if (nparams > 0 && !params) {
        snprintf(err, errsize, "parameter collection failed");
        return SQLITE_ERROR;
    }
    if (nparams != expected) {
        snprintf(err, errsize, "parameter count mismatch: got %d, expected %d", nparams, expected);
        return SQLITE_ERROR;
    }
    for (int i = 0; i < nparams; i++) {
        int rc;
        int idx = i + 1;
        switch (params[i].type) {
            case PARAM_TYPE_NIL:
                rc = sqlite3_bind_null(stmt, idx);
                break;
            case PARAM_TYPE_INT:
                rc = sqlite3_bind_int64(stmt, idx, params[i].value.i);
                break;
            case PARAM_TYPE_DOUBLE:
                rc = sqlite3_bind_double(stmt, idx, params[i].value.d);
                break;
            case PARAM_TYPE_TEXT:
                rc = sqlite3_bind_text(stmt, idx, params[i].value.s.data, params[i].value.s.len, SQLITE_TRANSIENT);
                break;
            default:
                rc = SQLITE_ERROR;
                break;
        }
        if (rc != SQLITE_OK) return rc;
    }
    return SQLITE_OK;
}

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
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.open\n");
    if (ctx->conn) sqlite3_close(ctx->conn);
    ctx->conn = NULL;
    lunet_free_nonnull(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->conn) {
    lunet_sqlite_conn_t* wrapper = (lunet_sqlite_conn_t*)lua_newuserdata(co, sizeof(lunet_sqlite_conn_t));
    wrapper->conn = ctx->conn;
    wrapper->closed = 0;
    uv_mutex_init(&wrapper->mutex);
    luaL_getmetatable(co, LUNET_SQLITE_CONN_MT);
    lua_setmetatable(co, -2);
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
  lunet_free_nonnull(ctx);
}

int lunet_db_open(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.open")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 1 || !lua_istable(L, 1)) {
    lua_pushstring(L, "db.open requires params table");
    return lua_error(L);
  }

  register_conn_metatable(L);

  db_open_ctx_t* ctx = lunet_alloc(sizeof(db_open_ctx_t));
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

  lunet_coref_create(L, ctx->co_ref);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_open_work_cb, db_open_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lunet_free_nonnull(ctx);
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
  lunet_sqlite_conn_t* wrapper = (lunet_sqlite_conn_t*)luaL_testudata(L, 1, LUNET_SQLITE_CONN_MT);
  if (!wrapper) {
    lua_pushstring(L, "db.close requires a valid connection");
    return 1;
  }

  uv_mutex_lock(&wrapper->mutex);
  lunet_sqlite_conn_close(wrapper);  // Close connection but don't destroy mutex
  uv_mutex_unlock(&wrapper->mutex);
  // Mutex will be destroyed by GC via lunet_sqlite_conn_destroy

  lua_pushnil(L);
  return 1;
}

typedef struct {
  uv_work_t req;
  lua_State* L;
  int co_ref;

  lunet_sqlite_conn_t* wrapper;
  char* query;
  
  param_t* params;
  int nparams;

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

  uv_mutex_lock(&ctx->wrapper->mutex);
  if (ctx->wrapper->closed || !ctx->wrapper->conn) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  int rc = sqlite3_prepare_v2(ctx->wrapper->conn, ctx->query, -1, &stmt, NULL);
  if (rc != SQLITE_OK) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", sqlite3_errmsg(ctx->wrapper->conn));
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }
  
  if (ctx->nparams > 0) {
      rc = bind_params(stmt, ctx->params, ctx->nparams, ctx->err, sizeof(ctx->err));
      if (rc != SQLITE_OK) {
          if (ctx->err[0] == '\0') {
              snprintf(ctx->err, sizeof(ctx->err), "bind failed: %s", sqlite3_errmsg(ctx->wrapper->conn));
          }
          sqlite3_finalize(stmt);
          uv_mutex_unlock(&ctx->wrapper->mutex);
          return;
      }
  }

  ctx->ncols = sqlite3_column_count(stmt);
  if (ctx->ncols > 0) {
    ctx->col_names = lunet_alloc(sizeof(char*) * ctx->ncols);
    ctx->col_types = lunet_alloc(sizeof(int) * ctx->ncols);
    if (!ctx->col_names || !ctx->col_types) {
      snprintf(ctx->err, sizeof(ctx->err), "out of memory");
      lunet_free_nonnull(ctx->col_names);
      lunet_free_nonnull(ctx->col_types);
      ctx->col_names = NULL;
      ctx->col_types = NULL;
      ctx->ncols = 0;
      sqlite3_finalize(stmt);
      uv_mutex_unlock(&ctx->wrapper->mutex);
      return;
    }
    memset(ctx->col_names, 0, sizeof(char*) * ctx->ncols);
    for (int i = 0; i < ctx->ncols; i++) {
      const char* name = sqlite3_column_name(stmt, i);
      ctx->col_names[i] = lunet_strdup_local(name ? name : "");
      if (!ctx->col_names[i]) {
        snprintf(ctx->err, sizeof(ctx->err), "out of memory");
        for (int j = 0; j < i; j++) lunet_free_nonnull(ctx->col_names[j]);
        lunet_free_nonnull(ctx->col_names);
        lunet_free_nonnull(ctx->col_types);
        ctx->col_names = NULL;
        ctx->col_types = NULL;
        ctx->ncols = 0;
        sqlite3_finalize(stmt);
        uv_mutex_unlock(&ctx->wrapper->mutex);
        return;
      }
    }
  } else {
    ctx->col_names = NULL;
    ctx->col_types = NULL;
  }

  int capacity = 16;
  ctx->rows = lunet_alloc(sizeof(char**) * capacity);
  if (!ctx->rows) {
    snprintf(ctx->err, sizeof(ctx->err), "out of memory");
    for (int i = 0; i < ctx->ncols; i++) lunet_free_nonnull(ctx->col_names[i]);
    lunet_free_nonnull(ctx->col_names);
    lunet_free_nonnull(ctx->col_types);
    ctx->col_names = NULL;
    ctx->col_types = NULL;
    ctx->ncols = 0;
    sqlite3_finalize(stmt);
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }
  ctx->nrows = 0;

  while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
    if (ctx->nrows >= capacity) {
      capacity *= 2;
      char*** new_rows = lunet_realloc(ctx->rows, sizeof(char**) * capacity);
      if (!new_rows) {
        snprintf(ctx->err, sizeof(ctx->err), "out of memory");
        break;
      }
      ctx->rows = new_rows;
    }

    char** row = lunet_alloc(sizeof(char*) * ctx->ncols);
    if (!row) {
      snprintf(ctx->err, sizeof(ctx->err), "out of memory");
      break;
    }
    memset(row, 0, sizeof(char*) * ctx->ncols);
    int alloc_failed = 0;
    for (int i = 0; i < ctx->ncols; i++) {
      int t = sqlite3_column_type(stmt, i);
      if (ctx->nrows == 0 && ctx->col_types) ctx->col_types[i] = t;
      if (t == SQLITE_NULL) {
        row[i] = NULL;
      } else {
        const char* val = (const char*)sqlite3_column_text(stmt, i);
        if (val) {
          row[i] = lunet_strdup_local(val);
          if (!row[i]) {
            alloc_failed = 1;
            break;
          }
        } else {
          row[i] = NULL;
        }
      }
    }
    if (alloc_failed) {
      snprintf(ctx->err, sizeof(ctx->err), "out of memory");
      for (int i = 0; i < ctx->ncols; i++) lunet_free_nonnull(row[i]);
      lunet_free_nonnull(row);
      break;
    }
    ctx->rows[ctx->nrows] = row;
    ctx->nrows++;
  }

  if (rc != SQLITE_DONE) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", sqlite3_errmsg(ctx->wrapper->conn));
  }

  sqlite3_finalize(stmt);
  uv_mutex_unlock(&ctx->wrapper->mutex);
}

static void db_query_after_cb(uv_work_t* req, int status) {
  db_query_ctx_t* ctx = (db_query_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
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
      lunet_free_nonnull(ctx->rows[i][j]);
    }
    lunet_free_nonnull(ctx->rows[i]);
  }
  lunet_free_nonnull(ctx->rows);
  for (int i = 0; i < ctx->ncols; i++) {
    lunet_free_nonnull(ctx->col_names[i]);
  }
  lunet_free_nonnull(ctx->col_names);
  lunet_free_nonnull(ctx->col_types);
  lunet_free_nonnull(ctx->query);
  free_params(ctx->params, ctx->nparams);
  lunet_free_nonnull(ctx);
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

  lunet_sqlite_conn_t* wrapper = (lunet_sqlite_conn_t*)luaL_testudata(L, 1, LUNET_SQLITE_CONN_MT);
  if (!wrapper) {
    lua_pushnil(L);
    lua_pushstring(L, "db.query requires a valid connection");
    return 2;
  }

  if (wrapper->closed || !wrapper->conn) {
    lua_pushnil(L);
    lua_pushstring(L, "connection is closed");
    return 2;
  }

  const char* query = luaL_checkstring(L, 2);

  db_query_ctx_t* ctx = lunet_alloc(sizeof(db_query_ctx_t));
  if (!ctx) {
    lua_pushstring(L, "out of memory");
    return lua_error(L);
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->L = L;
  ctx->req.data = ctx;
  ctx->wrapper = wrapper;
  ctx->query = lunet_strdup_local(query);
  if (!ctx->query) {
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  lunet_coref_create(L, ctx->co_ref);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_query_work_cb, db_query_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lunet_free_nonnull(ctx->query);
    lunet_free_nonnull(ctx);
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

  lunet_sqlite_conn_t* wrapper;
  char* query;
  
  param_t* params;
  int nparams;

  long long affected_rows;
  long long insert_id;
  char err[256];
} db_exec_ctx_t;

static void db_exec_work_cb(uv_work_t* req) {
  db_exec_ctx_t* ctx = (db_exec_ctx_t*)req->data;

  uv_mutex_lock(&ctx->wrapper->mutex);
  if (ctx->wrapper->closed || !ctx->wrapper->conn) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  if (ctx->nparams > 0) {
      sqlite3_stmt* stmt = NULL;
      int rc = sqlite3_prepare_v2(ctx->wrapper->conn, ctx->query, -1, &stmt, NULL);
      if (rc != SQLITE_OK) {
          snprintf(ctx->err, sizeof(ctx->err), "%s", sqlite3_errmsg(ctx->wrapper->conn));
          uv_mutex_unlock(&ctx->wrapper->mutex);
          return;
      }
      rc = bind_params(stmt, ctx->params, ctx->nparams, ctx->err, sizeof(ctx->err));
      if (rc != SQLITE_OK) {
          if (ctx->err[0] == '\0') {
              snprintf(ctx->err, sizeof(ctx->err), "bind failed: %s", sqlite3_errmsg(ctx->wrapper->conn));
          }
          sqlite3_finalize(stmt);
          uv_mutex_unlock(&ctx->wrapper->mutex);
          return;
      }
      rc = sqlite3_step(stmt);
      if (rc != SQLITE_DONE && rc != SQLITE_ROW) {
          snprintf(ctx->err, sizeof(ctx->err), "%s", sqlite3_errmsg(ctx->wrapper->conn));
      }
      sqlite3_finalize(stmt);
  } else {
      char* errmsg = NULL;
      int rc = sqlite3_exec(ctx->wrapper->conn, ctx->query, NULL, NULL, &errmsg);
      if (rc != SQLITE_OK) {
        snprintf(ctx->err, sizeof(ctx->err), "%s", errmsg ? errmsg : sqlite3_errmsg(ctx->wrapper->conn));
        if (errmsg) sqlite3_free(errmsg);
        uv_mutex_unlock(&ctx->wrapper->mutex);
        return;
      }
  }

  ctx->affected_rows = sqlite3_changes(ctx->wrapper->conn);
  ctx->insert_id = sqlite3_last_insert_rowid(ctx->wrapper->conn);
  uv_mutex_unlock(&ctx->wrapper->mutex);
}

static void db_exec_after_cb(uv_work_t* req, int status) {
  db_exec_ctx_t* ctx = (db_exec_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.exec\n");
    lunet_free_nonnull(ctx->query);
    free_params(ctx->params, ctx->nparams);
    lunet_free_nonnull(ctx);
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

  lunet_free_nonnull(ctx->query);
  free_params(ctx->params, ctx->nparams);
  lunet_free_nonnull(ctx);
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

  lunet_sqlite_conn_t* wrapper = (lunet_sqlite_conn_t*)luaL_testudata(L, 1, LUNET_SQLITE_CONN_MT);
  if (!wrapper) {
    lua_pushnil(L);
    lua_pushstring(L, "db.exec requires a valid connection");
    return 2;
  }

  if (wrapper->closed || !wrapper->conn) {
    lua_pushnil(L);
    lua_pushstring(L, "connection is closed");
    return 2;
  }

  const char* query = luaL_checkstring(L, 2);

  db_exec_ctx_t* ctx = lunet_alloc(sizeof(db_exec_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->L = L;
  ctx->req.data = ctx;
  ctx->wrapper = wrapper;
  ctx->query = lunet_strdup_local(query);
  if (!ctx->query) {
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  lunet_coref_create(L, ctx->co_ref);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_exec_work_cb, db_exec_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lunet_free_nonnull(ctx->query);
    lunet_free_nonnull(ctx);
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

int lunet_db_query_params(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.query_params")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "db.query_params requires connection and sql string");
    return 2;
  }

  lunet_sqlite_conn_t* wrapper = (lunet_sqlite_conn_t*)luaL_testudata(L, 1, LUNET_SQLITE_CONN_MT);
  if (!wrapper) {
    lua_pushnil(L);
    lua_pushstring(L, "db.query_params requires a valid connection");
    return 2;
  }

  if (wrapper->closed || !wrapper->conn) {
    lua_pushnil(L);
    lua_pushstring(L, "connection is closed");
    return 2;
  }

  const char* query = luaL_checkstring(L, 2);

  db_query_ctx_t* ctx = lunet_alloc(sizeof(db_query_ctx_t));
  if (!ctx) {
    lua_pushstring(L, "out of memory");
    return lua_error(L);
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->L = L;
  ctx->req.data = ctx;
  ctx->wrapper = wrapper;
  ctx->query = lunet_strdup_local(query);
  if (!ctx->query) {
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  ctx->params = collect_params(L, 3, &ctx->nparams);
  if (ctx->nparams < 0) {
    lunet_free_nonnull(ctx->query);
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  lunet_coref_create(L, ctx->co_ref);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_query_work_cb, db_query_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lunet_free_nonnull(ctx->query);
    free_params(ctx->params, ctx->nparams);
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(ret));
    return 2;
  }

  return lua_yield(L, 0);
}

int lunet_db_exec_params(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.exec_params")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "db.exec_params requires connection and sql string");
    return 2;
  }

  lunet_sqlite_conn_t* wrapper = (lunet_sqlite_conn_t*)luaL_testudata(L, 1, LUNET_SQLITE_CONN_MT);
  if (!wrapper) {
    lua_pushnil(L);
    lua_pushstring(L, "db.exec_params requires a valid connection");
    return 2;
  }

  if (wrapper->closed || !wrapper->conn) {
    lua_pushnil(L);
    lua_pushstring(L, "connection is closed");
    return 2;
  }

  const char* query = luaL_checkstring(L, 2);

  db_exec_ctx_t* ctx = lunet_alloc(sizeof(db_exec_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->L = L;
  ctx->req.data = ctx;
  ctx->wrapper = wrapper;
  ctx->query = lunet_strdup_local(query);
  if (!ctx->query) {
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  ctx->params = collect_params(L, 3, &ctx->nparams);
  if (ctx->nparams < 0) {
    lunet_free_nonnull(ctx->query);
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  lunet_coref_create(L, ctx->co_ref);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_exec_work_cb, db_exec_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lunet_free_nonnull(ctx->query);
    free_params(ctx->params, ctx->nparams);
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(ret));
    return 2;
  }

  return lua_yield(L, 0);
}

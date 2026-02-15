#include "lunet_db_postgres.h"

#include <libpq-fe.h>
#include <stdlib.h>
#include <string.h>

#include "co.h"
#include "trace.h"
#include "lunet_mem.h"
#include "uv.h"

#define LUNET_PG_CONN_MT "lunet.pg.conn"

static char* lunet_strdup_local(const char* s) {
  if (!s) return NULL;
  size_t len = strlen(s);
  char* out = lunet_alloc(len + 1);
  if (!out) return NULL;
  memcpy(out, s, len + 1);
  return out;
}

typedef struct {
  PGconn* conn;
  uv_mutex_t mutex;
  int closed;
} lunet_pg_conn_t;

// Close the PG connection but don't destroy the mutex (caller may still hold it)
static void lunet_pg_conn_close(lunet_pg_conn_t* wrapper) {
  if (!wrapper || wrapper->closed) return;
  wrapper->closed = 1;
  if (wrapper->conn) {
    PQfinish(wrapper->conn);
    wrapper->conn = NULL;
  }
}

// Full cleanup including mutex - only call when mutex is NOT held (e.g., from GC)
static void lunet_pg_conn_destroy(lunet_pg_conn_t* wrapper) {
  lunet_pg_conn_close(wrapper);
  if (wrapper) {
    uv_mutex_destroy(&wrapper->mutex);
  }
}

static int conn_gc(lua_State* L) {
  lunet_pg_conn_t* wrapper = (lunet_pg_conn_t*)luaL_checkudata(L, 1, LUNET_PG_CONN_MT);
  lunet_pg_conn_destroy(wrapper);
  return 0;
}

static void register_conn_metatable(lua_State* L) {
  if (luaL_newmetatable(L, LUNET_PG_CONN_MT)) {
    lua_pushcfunction(L, conn_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_pop(L, 1);
}

// Parameter handling
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

typedef struct {
  uv_work_t req;
  lua_State* L;
  int co_ref;

  PGconn* conn;
  char err[256];

  char conninfo[1024];
} db_open_ctx_t;

static void db_open_work_cb(uv_work_t* req) {
  db_open_ctx_t* ctx = (db_open_ctx_t*)req->data;

  ctx->conn = PQconnectdb(ctx->conninfo);
  if (PQstatus(ctx->conn) != CONNECTION_OK) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", PQerrorMessage(ctx->conn));
    PQfinish(ctx->conn);
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
    if (ctx->conn) PQfinish(ctx->conn);
    ctx->conn = NULL;
    lunet_free_nonnull(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->conn) {
    lunet_pg_conn_t* wrapper = (lunet_pg_conn_t*)lua_newuserdata(co, sizeof(lunet_pg_conn_t));
    wrapper->conn = ctx->conn;
    wrapper->closed = 0;
    uv_mutex_init(&wrapper->mutex);
    luaL_getmetatable(co, LUNET_PG_CONN_MT);
    lua_setmetatable(co, -2);
    lua_pushnil(co);
  } else {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
  }
  int rc = lunet_co_resume(co, 2);
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

  char host[256] = "localhost";
  int port = 5432;
  char user[256] = "";
  char password[256] = "";
  char database[256] = "";

  lua_getfield(L, 1, "host");
  if (lua_isstring(L, -1)) snprintf(host, sizeof(host), "%s", lua_tostring(L, -1));
  lua_getfield(L, 1, "port");
  if (lua_isnumber(L, -1)) port = lua_tointeger(L, -1);
  lua_getfield(L, 1, "user");
  if (lua_isstring(L, -1)) snprintf(user, sizeof(user), "%s", lua_tostring(L, -1));
  lua_getfield(L, 1, "password");
  if (lua_isstring(L, -1)) snprintf(password, sizeof(password), "%s", lua_tostring(L, -1));
  lua_getfield(L, 1, "database");
  if (lua_isstring(L, -1)) snprintf(database, sizeof(database), "%s", lua_tostring(L, -1));
  lua_pop(L, 5);

  snprintf(ctx->conninfo, sizeof(ctx->conninfo),
           "host='%s' port='%d' user='%s' password='%s' dbname='%s'",
           host, port, user, password, database);
  
  /* printf("DEBUG: conninfo='%s'\n", ctx->conninfo); */

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
  lunet_pg_conn_t* wrapper = (lunet_pg_conn_t*)luaL_testudata(L, 1, LUNET_PG_CONN_MT);
  if (!wrapper) {
    lua_pushstring(L, "db.close requires a valid connection");
    return 1;
  }

  uv_mutex_lock(&wrapper->mutex);
  lunet_pg_conn_close(wrapper);
  uv_mutex_unlock(&wrapper->mutex);

  lua_pushnil(L);
  return 1;
}

typedef struct {
  uv_work_t req;
  lua_State* L;
  int co_ref;

  lunet_pg_conn_t* wrapper;
  char* query;
  
  param_t* params;
  int nparams;

  PGresult* result;
  char err[256];
} db_query_ctx_t;

static void db_query_work_cb(uv_work_t* req) {
  db_query_ctx_t* ctx = (db_query_ctx_t*)req->data;

  uv_mutex_lock(&ctx->wrapper->mutex);
  if (ctx->wrapper->closed || !ctx->wrapper->conn) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    ctx->result = NULL;
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  if (ctx->nparams > 0) {
      const char **paramValues = lunet_calloc(ctx->nparams, sizeof(char*));
      int *should_free = lunet_calloc(ctx->nparams, sizeof(int));
      if (!paramValues || !should_free) {
           snprintf(ctx->err, sizeof(ctx->err), "out of memory");
           lunet_free_nonnull(paramValues);
           lunet_free_nonnull(should_free);
           uv_mutex_unlock(&ctx->wrapper->mutex);
           return;
      }
      
      for (int i=0; i<ctx->nparams; i++) {
          if (ctx->params[i].type == PARAM_TYPE_INT) {
              char buf[64];
              snprintf(buf, sizeof(buf), "%lld", ctx->params[i].value.i);
              paramValues[i] = lunet_strdup_local(buf);
              should_free[i] = 1;
          } else if (ctx->params[i].type == PARAM_TYPE_DOUBLE) {
              char buf[64];
              snprintf(buf, sizeof(buf), "%g", ctx->params[i].value.d);
              paramValues[i] = lunet_strdup_local(buf);
              should_free[i] = 1;
          } else if (ctx->params[i].type == PARAM_TYPE_TEXT) {
              paramValues[i] = ctx->params[i].value.s.data;
              should_free[i] = 0;
          } else {
              paramValues[i] = NULL;
              should_free[i] = 0;
          }
      }

      ctx->result = PQexecParams(ctx->wrapper->conn, ctx->query, ctx->nparams, NULL, (const char * const *)paramValues, NULL, NULL, 0);

      for(int i=0; i<ctx->nparams; i++) if(should_free[i]) lunet_free_nonnull((void*)paramValues[i]);
      lunet_free_nonnull(paramValues);
      lunet_free_nonnull(should_free);
  } else {
      ctx->result = PQexec(ctx->wrapper->conn, ctx->query);
  }

  ExecStatusType status = PQresultStatus(ctx->result);

  if (status != PGRES_TUPLES_OK && status != PGRES_COMMAND_OK) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", PQerrorMessage(ctx->wrapper->conn));
    PQclear(ctx->result);
    ctx->result = NULL;
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }
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
    if (ctx->result) PQclear(ctx->result);
    lunet_free_nonnull(ctx->query);
    free_params(ctx->params, ctx->nparams);
    lunet_free_nonnull(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->result) {
    lua_newtable(co);
    int nrows = PQntuples(ctx->result);
    int ncols = PQnfields(ctx->result);

    for (int i = 0; i < nrows; i++) {
      lua_newtable(co);
      for (int j = 0; j < ncols; j++) {
        const char* fname = PQfname(ctx->result, j);
        lua_pushstring(co, fname);

        if (PQgetisnull(ctx->result, i, j)) {
          lua_pushnil(co);
        } else {
          const char* val = PQgetvalue(ctx->result, i, j);
          Oid ftype = PQftype(ctx->result, j);

          switch (ftype) {
            case 21:   // INT2OID
            case 23:   // INT4OID
            case 20:   // INT8OID
              lua_pushinteger(co, strtoll(val, NULL, 10));
              break;
            case 700:  // FLOAT4OID
            case 701:  // FLOAT8OID
            case 1700: // NUMERICOID
              lua_pushnumber(co, strtod(val, NULL));
              break;
            case 16:   // BOOLOID
              lua_pushboolean(co, val[0] == 't' || val[0] == 'T');
              break;
            default:
              lua_pushstring(co, val);
              break;
          }
        }
        lua_settable(co, -3);
      }
      lua_rawseti(co, -2, i + 1);
    }

    PQclear(ctx->result);
    ctx->result = NULL;

    lua_pushnil(co);
    int rc = lunet_co_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) fprintf(stderr, "lua_resume error in db.query: %s\n", err);
      lua_pop(co, 1);
    }
  } else {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
    int rc = lunet_co_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) fprintf(stderr, "lua_resume error in db.query: %s\n", err);
      lua_pop(co, 1);
    }
  }

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

  lunet_pg_conn_t* wrapper = (lunet_pg_conn_t*)luaL_testudata(L, 1, LUNET_PG_CONN_MT);
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

typedef struct {
  uv_work_t req;
  lua_State* L;
  int co_ref;

  lunet_pg_conn_t* wrapper;
  char* query;
  
  param_t* params;
  int nparams;

  long long affected_rows;
  unsigned long long insert_id;
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

  PGresult* result;
  if (ctx->nparams > 0) {
      const char **paramValues = lunet_calloc(ctx->nparams, sizeof(char*));
      int *should_free = lunet_calloc(ctx->nparams, sizeof(int));
      if (!paramValues || !should_free) {
           snprintf(ctx->err, sizeof(ctx->err), "out of memory");
           lunet_free_nonnull(paramValues);
           lunet_free_nonnull(should_free);
           uv_mutex_unlock(&ctx->wrapper->mutex);
           return;
      }
      
      for (int i=0; i<ctx->nparams; i++) {
          if (ctx->params[i].type == PARAM_TYPE_INT) {
              char buf[64];
              snprintf(buf, sizeof(buf), "%lld", ctx->params[i].value.i);
              paramValues[i] = lunet_strdup_local(buf);
              should_free[i] = 1;
          } else if (ctx->params[i].type == PARAM_TYPE_DOUBLE) {
              char buf[64];
              snprintf(buf, sizeof(buf), "%g", ctx->params[i].value.d);
              paramValues[i] = lunet_strdup_local(buf);
              should_free[i] = 1;
          } else if (ctx->params[i].type == PARAM_TYPE_TEXT) {
              paramValues[i] = ctx->params[i].value.s.data;
              should_free[i] = 0;
          } else {
              paramValues[i] = NULL;
              should_free[i] = 0;
          }
      }

      result = PQexecParams(ctx->wrapper->conn, ctx->query, ctx->nparams, NULL, (const char * const *)paramValues, NULL, NULL, 0);

      for(int i=0; i<ctx->nparams; i++) if(should_free[i]) lunet_free_nonnull((void*)paramValues[i]);
      lunet_free_nonnull(paramValues);
      lunet_free_nonnull(should_free);
  } else {
      result = PQexec(ctx->wrapper->conn, ctx->query);
  }

  ExecStatusType status = PQresultStatus(result);

  if (status != PGRES_COMMAND_OK && status != PGRES_TUPLES_OK) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", PQerrorMessage(ctx->wrapper->conn));
    PQclear(result);
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  const char* affected = PQcmdTuples(result);
  ctx->affected_rows = affected[0] ? strtoll(affected, NULL, 10) : 0;
  ctx->insert_id = (unsigned long long)PQoidValue(result);

  PQclear(result);
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
    int rc = lunet_co_resume(co, 2);
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
    int rc = lunet_co_resume(co, 2);
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
  lunet_pg_conn_t* wrapper = (lunet_pg_conn_t*)luaL_testudata(L, 1, LUNET_PG_CONN_MT);
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

int lunet_db_escape(lua_State* L) {
  luaL_checkstring(L, 1);
  lua_getglobal(L, "string");
  lua_getfield(L, -1, "gsub");
  lua_remove(L, -2); /* remove string table */

  if (!lua_isfunction(L, -1)) {
    return luaL_error(L, "string.gsub is not available");
  }

  lua_pushvalue(L, 1); /* subject */
  lua_pushstring(L, "(['\\\\])"); /* pattern */
  
  lua_newtable(L); /* replacement table */
  lua_pushstring(L, "'");
  lua_pushstring(L, "''");
  lua_settable(L, -3);
  lua_pushstring(L, "\\");
  lua_pushstring(L, "\\\\");
  lua_settable(L, -3);

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

  lunet_pg_conn_t* wrapper = (lunet_pg_conn_t*)luaL_testudata(L, 1, LUNET_PG_CONN_MT);
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

  lunet_pg_conn_t* wrapper = (lunet_pg_conn_t*)luaL_testudata(L, 1, LUNET_PG_CONN_MT);
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

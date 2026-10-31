#include "lunet_db_postgres.h"

#include <libpq-fe.h>
#if !defined(PG_VERSION_NUM)
#  include <pg_config.h>
#endif
#if !defined(PG_VERSION_NUM)
#  error "lunet postgres driver requires libpq client library >= 17 (PG_VERSION_NUM unavailable)"
#endif
#if PG_VERSION_NUM < 170000
#  error "lunet postgres driver requires libpq client library >= 17"
#endif
#include <stdlib.h>
#include <string.h>

#include "co.h"
#include "trace.h"
#include "lunet_mem.h"
#include "uv.h"

#define LUNET_PG_CONN_MT "lunet.pg.conn"
#define LUNET_PG_POOL_MT "lunet.pg.pool"
#define LUNET_PG_STMT_MT "lunet.pg.stmt"
#define LUNET_PG_POOL_MAX 64

static char* lunet_strdup_local(const char* s) {
  if (!s) return NULL;
  size_t len = strlen(s);
  char* out = lunet_alloc(len + 1);
  if (!out) return NULL;
  memcpy(out, s, len + 1);
  return out;
}

typedef struct lunet_pg_stmt_s lunet_pg_stmt_t;

typedef struct {
  PGconn* conn;
  uv_mutex_t mutex;
  int closed;
  /* Open prepared statements bound to this connection (intrusive list,
   * loop-thread-only links). Closing the connection marks every still-open
   * statement closed and severs it: the server-side prepared statement dies
   * with the session, so a surviving statement userdata must never send
   * commands on the dead connection again. */
  lunet_pg_stmt_t* stmts;
} lunet_pg_conn_t;

/* A prepared statement: one connection, one server-side name. The busy
 * flag guards re-entrant use (a second call while one is in flight fails
 * loudly instead of interleaving on the connection). */
struct lunet_pg_stmt_s {
  lunet_pg_conn_t* member;
  char name[64]; /* server-side prepared-statement name, per session */
  int busy;
  int closed;
  lunet_pg_stmt_t* next;
  lunet_pg_stmt_t* prev;
};

/* Link a statement into the connection's open-statement list (loop thread). */
static void conn_track_stmt(lunet_pg_conn_t* conn, lunet_pg_stmt_t* s) {
  s->prev = NULL;
  s->next = conn->stmts;
  if (conn->stmts) conn->stmts->prev = s;
  conn->stmts = s;
}

/* Unlink a statement from the connection's open-statement list (loop thread). */
static void conn_untrack_stmt(lunet_pg_conn_t* conn, lunet_pg_stmt_t* s) {
  if (s->prev) s->prev->next = s->next;
  else if (conn->stmts == s) conn->stmts = s->next;
  if (s->next) s->next->prev = s->prev;
  s->next = NULL;
  s->prev = NULL;
}

/* The handle open() returns: a pool of pool_size connections, one statement
 * -> one member, picked round-robin at dispatch. Default pool_size is 1 —
 * exactly one connection, as before. The server genuinely serves concurrent
 * client connections, so a wider pool parallelises real work. */
typedef struct {
  lunet_pg_conn_t** members;
  int n;
  int next; /* round-robin cursor; picked on the loop thread only */
  int closed;
} lunet_pg_pool_t;

/* Close the PG connection but don't destroy the mutex (caller may still hold it). */
static void lunet_pg_conn_close(lunet_pg_conn_t* wrapper) {
  if (!wrapper || wrapper->closed) return;
  wrapper->closed = 1;
  /* Sever every still-open prepared statement first: the server-side
   * prepared statements die with the session, so each one is marked closed
   * and severed — later use or GC is a loud error or a safe no-op, never a
   * command on a dead connection. */
  lunet_pg_stmt_t* s = wrapper->stmts;
  while (s) {
    lunet_pg_stmt_t* next = s->next;
    s->closed = 1;
    s->member = NULL;
    s->next = NULL;
    s->prev = NULL;
    s = next;
  }
  wrapper->stmts = NULL;
  if (wrapper->conn) {
    PQfinish(wrapper->conn);
    wrapper->conn = NULL;
  }
}

/* Full cleanup including mutex; only call when mutex is not held (for example, from GC). */
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

/* Full pool teardown: close every member, destroy its mutex, free the array. */
static int pool_gc(lua_State* L) {
  lunet_pg_pool_t* pool = (lunet_pg_pool_t*)luaL_checkudata(L, 1, LUNET_PG_POOL_MT);
  if (pool->members) {
    for (int i = 0; i < pool->n; i++) {
      if (pool->members[i]) {
        lunet_pg_conn_close(pool->members[i]);
        uv_mutex_destroy(&pool->members[i]->mutex);
        lunet_free_nonnull(pool->members[i]);
        pool->members[i] = NULL;
      }
    }
    lunet_free_nonnull(pool->members);
    pool->members = NULL;
  }
  pool->closed = 1;
  return 0;
}

static void register_conn_metatable(lua_State* L) {
  if (luaL_newmetatable(L, LUNET_PG_CONN_MT)) {
    lua_pushcfunction(L, conn_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_pop(L, 1);
  if (luaL_newmetatable(L, LUNET_PG_POOL_MT)) {
    lua_pushcfunction(L, pool_gc);
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
  lua_State* waiter_L;
  int co_ref;

  PGconn** conns; /* pool_n connections; handed to the pool on success */
  int pool_n;
  char err[256];

  char conninfo[1024];
} db_open_ctx_t;

static void db_open_work_cb(uv_work_t* req) {
  db_open_ctx_t* ctx = (db_open_ctx_t*)req->data;

  /* pool_n is owned by after_cb; work_cb NEVER zeroes it. conns == NULL is
   * the failure signal. */
  ctx->conns = lunet_alloc(sizeof(PGconn*) * (size_t)ctx->pool_n);
  if (!ctx->conns) {
    snprintf(ctx->err, sizeof(ctx->err), "out of memory");
    return;
  }
  memset(ctx->conns, 0, sizeof(PGconn*) * (size_t)ctx->pool_n);

  for (int i = 0; i < ctx->pool_n; i++) {
    ctx->conns[i] = PQconnectdb(ctx->conninfo);
    if (PQstatus(ctx->conns[i]) != CONNECTION_OK) {
      snprintf(ctx->err, sizeof(ctx->err), "%s", PQerrorMessage(ctx->conns[i]));
      PQfinish(ctx->conns[i]);
      ctx->conns[i] = NULL;
      for (int j = 0; j < i; j++) {
        PQfinish(ctx->conns[j]);
        ctx->conns[j] = NULL;
      }
      lunet_free_nonnull(ctx->conns);
      ctx->conns = NULL;
      return;
    }
  }
}

static void db_open_after_cb(uv_work_t* req, int status) {
  db_open_ctx_t* ctx = (db_open_ctx_t*)req->data;
  lua_State* L = ctx->waiter_L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.open\n");
    if (ctx->conns) {
      for (int i = 0; i < ctx->pool_n; i++) {
        if (ctx->conns[i]) PQfinish(ctx->conns[i]);
        ctx->conns[i] = NULL;
      }
      lunet_free_nonnull(ctx->conns);
      ctx->conns = NULL;
    }
    lunet_free_nonnull(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->conns) {
    /* Success shape: (pool handle, nil). Build the pool wrapper and hand
     * the raw connections over to it. */
    lunet_pg_pool_t* pool =
        (lunet_pg_pool_t*)lua_newuserdata(co, sizeof(lunet_pg_pool_t));
    pool->members = lunet_alloc(sizeof(lunet_pg_conn_t*) * (size_t)ctx->pool_n);
    if (!pool->members) {
      pool->n = 0;
      pool->closed = 1;
      for (int i = 0; i < ctx->pool_n; i++) {
        if (ctx->conns[i]) PQfinish(ctx->conns[i]);
        ctx->conns[i] = NULL;
      }
      lunet_free_nonnull(ctx->conns);
      ctx->conns = NULL;
      ctx->pool_n = 0;
      lua_pushnil(co);
      lua_pushstring(co, "out of memory");
    } else {
      pool->n = ctx->pool_n;
      pool->next = 0;
      pool->closed = 0;
      for (int i = 0; i < pool->n; i++) {
        lunet_pg_conn_t* member = lunet_alloc(sizeof(lunet_pg_conn_t));
        memset(member, 0, sizeof(*member));
        member->conn = ctx->conns[i];
        uv_mutex_init(&member->mutex);
        pool->members[i] = member;
        ctx->conns[i] = NULL;
      }
      lunet_free_nonnull(ctx->conns);
      ctx->conns = NULL;
      ctx->pool_n = 0;
      luaL_getmetatable(co, LUNET_PG_POOL_MT);
      lua_setmetatable(co, -2);
      lua_pushnil(co);
    }
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
  ctx->waiter_L = L;
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

  /* connect_timeout: seconds libpq waits before the connect attempt fails.
   * Unset leaves the libpq default untouched. */
  int connect_timeout = -1;
  lua_getfield(L, 1, "connect_timeout");
  if (!lua_isnil(L, -1)) {
    if (!lua_isnumber(L, -1)) {
      lua_pop(L, 1);
      lunet_free_nonnull(ctx);
      lua_pushstring(L, "db.open: connect_timeout must be a number (seconds)");
      return lua_error(L);
    }
    connect_timeout = (int)lua_tointeger(L, -1);
    if (connect_timeout < 1) {
      lua_pop(L, 1);
      lunet_free_nonnull(ctx);
      lua_pushstring(L, "db.open: connect_timeout must be a positive integer (seconds)");
      return lua_error(L);
    }
  }
  lua_pop(L, 1);

  /* sslmode: passed through to libpq verbatim once whitelisted against the
   * values libpq accepts. Unset leaves the libpq default untouched. */
  char sslmode[32] = "";
  lua_getfield(L, 1, "sslmode");
  if (!lua_isnil(L, -1)) {
    if (!lua_isstring(L, -1)) {
      lua_pop(L, 1);
      lunet_free_nonnull(ctx);
      lua_pushstring(L, "db.open: sslmode must be a string");
      return lua_error(L);
    }
    snprintf(sslmode, sizeof(sslmode), "%s", lua_tostring(L, -1));
    static const char* const sslmodes[] = {
        "disable", "allow", "prefer", "require", "verify-ca", "verify-full", NULL};
    int known = 0;
    for (int i = 0; sslmodes[i]; i++) {
      if (strcmp(sslmode, sslmodes[i]) == 0) {
        known = 1;
        break;
      }
    }
    if (!known) {
      lua_pop(L, 1);
      lunet_free_nonnull(ctx);
      lua_pushfstring(L,
                      "db.open: sslmode must be \"disable\", \"allow\", \"prefer\", "
                      "\"require\", \"verify-ca\" or \"verify-full\" (got '%s')",
                      sslmode);
      return lua_error(L);
    }
  }
  lua_pop(L, 1);

  int off = snprintf(ctx->conninfo, sizeof(ctx->conninfo),
                     "host='%s' port='%d' user='%s' password='%s' dbname='%s'",
                     host, port, user, password, database);
  if (connect_timeout > 0 && off > 0 && (size_t)off < sizeof(ctx->conninfo)) {
    int n = snprintf(ctx->conninfo + off, sizeof(ctx->conninfo) - (size_t)off,
                     " connect_timeout='%d'", connect_timeout);
    if (n > 0) off += n;
  }
  if (sslmode[0] && off > 0 && (size_t)off < sizeof(ctx->conninfo)) {
    snprintf(ctx->conninfo + off, sizeof(ctx->conninfo) - (size_t)off,
             " sslmode='%s'", sslmode);
  }

  /* pool_size: how many connections sit behind the returned handle
   * (round-robin pick at dispatch). Default 1 — exactly one connection,
   * as before. */
  ctx->pool_n = 1;
  lua_getfield(L, 1, "pool_size");
  if (!lua_isnil(L, -1)) {
    if (!lua_isnumber(L, -1)) {
      lua_pop(L, 1);
      lunet_free_nonnull(ctx);
      lua_pushstring(L, "db.open: pool_size must be a number");
      return lua_error(L);
    }
    ctx->pool_n = (int)lua_tointeger(L, -1);
    if (ctx->pool_n < 1 || ctx->pool_n > LUNET_PG_POOL_MAX) {
      lua_pop(L, 1);
      lunet_free_nonnull(ctx);
      lua_pushstring(L, "db.open: pool_size must be between 1 and 64");
      return lua_error(L);
    }
  }
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
  lunet_pg_pool_t* pool = (lunet_pg_pool_t*)luaL_testudata(L, 1, LUNET_PG_POOL_MT);
  if (pool) {
    for (int i = 0; i < pool->n; i++) {
      if (pool->members[i]) lunet_pg_conn_close(pool->members[i]);
    }
    pool->closed = 1;
    lua_pushnil(L);
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

/* Resolve the statement target: a pool handle round-robins to its next
 * member; a bare connection handle is itself. Returns NULL for anything
 * else. The cursor is touched only on the loop thread, where every entry
 * point runs. */
static lunet_pg_conn_t* pick_statement_target(lua_State* L, int idx) {
  lunet_pg_pool_t* pool = (lunet_pg_pool_t*)luaL_testudata(L, idx, LUNET_PG_POOL_MT);
  if (pool) {
    if (!pool->members || pool->n < 1) return NULL;
    lunet_pg_conn_t* member = pool->members[pool->next];
    pool->next = (pool->next + 1) % pool->n;
    return member; /* closed pools surface "connection is closed" downstream */
  }
  return (lunet_pg_conn_t*)luaL_testudata(L, idx, LUNET_PG_CONN_MT);
}

/* Convert collected Lua params to libpq's text-paramValues form.
 * Returns 0 on success (caller frees via pg_free_param_values), -1 on
 * out-of-memory. */
static int pg_build_param_values(param_t* params, int nparams,
                                 const char*** out_values, int** out_should_free) {
  *out_values = NULL;
  *out_should_free = NULL;
  if (nparams <= 0) return 0;
  const char** paramValues = lunet_calloc(nparams, sizeof(char*));
  int* should_free = lunet_calloc(nparams, sizeof(int));
  if (!paramValues || !should_free) {
    lunet_free_nonnull(paramValues);
    lunet_free_nonnull(should_free);
    return -1;
  }
  for (int i = 0; i < nparams; i++) {
    if (params[i].type == PARAM_TYPE_INT) {
      char buf[64];
      snprintf(buf, sizeof(buf), "%lld", params[i].value.i);
      paramValues[i] = lunet_strdup_local(buf);
      should_free[i] = 1;
    } else if (params[i].type == PARAM_TYPE_DOUBLE) {
      char buf[64];
      snprintf(buf, sizeof(buf), "%g", params[i].value.d);
      paramValues[i] = lunet_strdup_local(buf);
      should_free[i] = 1;
    } else if (params[i].type == PARAM_TYPE_TEXT) {
      paramValues[i] = params[i].value.s.data;
      should_free[i] = 0;
    } else {
      paramValues[i] = NULL;
      should_free[i] = 0;
    }
  }
  *out_values = paramValues;
  *out_should_free = should_free;
  return 0;
}

static void pg_free_param_values(const char** paramValues, int* should_free, int nparams) {
  if (!paramValues) return;
  for (int i = 0; i < nparams; i++) {
    if (should_free && should_free[i]) lunet_free_nonnull((void*)paramValues[i]);
  }
  lunet_free_nonnull(paramValues);
  lunet_free_nonnull(should_free);
}

typedef struct {
  uv_work_t req;
  lua_State* waiter_L;
  int co_ref;

  lunet_pg_conn_t* wrapper;
  char* query;

  /* When set, execute this server-side prepared statement name via
   * PQexecPrepared instead of one-shot PQexec/PQexecParams. The valref
   * pins the statement userdata while the worker op is in flight. */
  char prepared_name[64];
  lunet_pg_stmt_t* pstmt;
  int stmt_valref;

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

  if (ctx->prepared_name[0]) {
    const char** paramValues = NULL;
    int* should_free = NULL;
    if (pg_build_param_values(ctx->params, ctx->nparams, &paramValues, &should_free) != 0) {
      snprintf(ctx->err, sizeof(ctx->err), "out of memory");
      ctx->result = NULL;
      uv_mutex_unlock(&ctx->wrapper->mutex);
      return;
    }
    ctx->result = PQexecPrepared(ctx->wrapper->conn, ctx->prepared_name,
                                 ctx->nparams, (const char* const*)paramValues,
                                 NULL, NULL, 0);
    pg_free_param_values(paramValues, should_free, ctx->nparams);
  } else if (ctx->nparams > 0) {
      const char **paramValues = NULL;
      int *should_free = NULL;
      if (pg_build_param_values(ctx->params, ctx->nparams, &paramValues, &should_free) != 0) {
           snprintf(ctx->err, sizeof(ctx->err), "out of memory");
           uv_mutex_unlock(&ctx->wrapper->mutex);
           return;
      }

      ctx->result = PQexecParams(ctx->wrapper->conn, ctx->query, ctx->nparams, NULL, (const char * const *)paramValues, NULL, NULL, 0);

      pg_free_param_values(paramValues, should_free, ctx->nparams);
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
  lua_State* L = ctx->waiter_L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.query\n");
    if (ctx->pstmt) ctx->pstmt->busy = 0;
    if (ctx->stmt_valref) lunet_valref_release(L, ctx->stmt_valref);
    if (ctx->result) PQclear(ctx->result);
    lunet_free_nonnull(ctx->query);
    free_params(ctx->params, ctx->nparams);
    lunet_free_nonnull(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->pstmt) ctx->pstmt->busy = 0;
  if (ctx->stmt_valref) lunet_valref_release(L, ctx->stmt_valref);

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

  lunet_pg_conn_t* wrapper = pick_statement_target(L, 1);
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
  ctx->waiter_L = L;
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
  lua_State* waiter_L;
  int co_ref;

  lunet_pg_conn_t* wrapper;
  char* query;

  char prepared_name[64];
  lunet_pg_stmt_t* pstmt;
  int stmt_valref;

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
  if (ctx->prepared_name[0]) {
    const char** paramValues = NULL;
    int* should_free = NULL;
    if (pg_build_param_values(ctx->params, ctx->nparams, &paramValues, &should_free) != 0) {
      snprintf(ctx->err, sizeof(ctx->err), "out of memory");
      uv_mutex_unlock(&ctx->wrapper->mutex);
      return;
    }
    result = PQexecPrepared(ctx->wrapper->conn, ctx->prepared_name,
                            ctx->nparams, (const char* const*)paramValues,
                            NULL, NULL, 0);
    pg_free_param_values(paramValues, should_free, ctx->nparams);
  } else if (ctx->nparams > 0) {
      const char **paramValues = NULL;
      int *should_free = NULL;
      if (pg_build_param_values(ctx->params, ctx->nparams, &paramValues, &should_free) != 0) {
           snprintf(ctx->err, sizeof(ctx->err), "out of memory");
           uv_mutex_unlock(&ctx->wrapper->mutex);
           return;
      }

      result = PQexecParams(ctx->wrapper->conn, ctx->query, ctx->nparams, NULL, (const char * const *)paramValues, NULL, NULL, 0);

      pg_free_param_values(paramValues, should_free, ctx->nparams);
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
  lua_State* L = ctx->waiter_L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.exec\n");
    if (ctx->pstmt) ctx->pstmt->busy = 0;
    if (ctx->stmt_valref) lunet_valref_release(L, ctx->stmt_valref);
    lunet_free_nonnull(ctx->query);
    free_params(ctx->params, ctx->nparams);
    lunet_free_nonnull(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->pstmt) ctx->pstmt->busy = 0;
  if (ctx->stmt_valref) lunet_valref_release(L, ctx->stmt_valref);

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
  lunet_pg_conn_t* wrapper = pick_statement_target(L, 1);
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
  ctx->waiter_L = L;
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

int lunet_db_query_params(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.query_params")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "db.query_params requires connection and sql string");
    return 2;
  }

  lunet_pg_conn_t* wrapper = pick_statement_target(L, 1);
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
  ctx->waiter_L = L;
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

  lunet_pg_conn_t* wrapper = pick_statement_target(L, 1);
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
  ctx->waiter_L = L;
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

/* ==========================================================================
 * Prepared statements
 *
 * db.prepare(handle, sql) hands back a reusable statement handle: the SQL
 * is PQprepare'd once under a unique session-scoped name, each stmt:query /
 * stmt:exec call executes it via PQexecPrepared with fresh parameters, and
 * stmt:close() releases the server-side definition with PQclosePrepared.
 * One statement is bound to one connection — prepare on a pooled handle
 * therefore requires pool_size = 1. If the connection dies, the statement
 * dies with the session: use fails loudly. A second call while one is in
 * flight fails loudly ("statement is busy").
 * ========================================================================== */

/* Session-scoped unique name generator: every entry point that mints one
 * runs on the loop thread, so no lock is needed. */
static unsigned long long g_pg_stmt_counter = 0;

static void pg_stmt_name(char* buf, size_t buflen) {
  snprintf(buf, buflen, "lunet_s%llu",
           (unsigned long long)(++g_pg_stmt_counter));
}

static int stmt_gc(lua_State* L) {
  lunet_pg_stmt_t* s = (lunet_pg_stmt_t*)luaL_checkudata(L, 1, LUNET_PG_STMT_MT);
  if (s->closed || !s->member) return 0;
  /* Best-effort, no network: a statement dropped without stmt:close()
   * leaves its server-side definition allocated until the session ends.
   * Running PQclosePrepared here would be a blocking round trip on the
   * loop thread — the deliberate trade is the documented leak-until-close
   * for statements that are GC'd without an explicit close. */
  s->closed = 1;
  conn_untrack_stmt(s->member, s);
  return 0;
}

/* Worker hop for stmt:close: PQclosePrepared is a network round trip, so
 * it never runs on the loop thread. */
typedef struct {
  uv_work_t req;
  lua_State* waiter_L;
  int co_ref;
  lunet_pg_conn_t* member;
  char name[64];

  char err[256];
} stmt_close_ctx_t;

static void stmt_close_work_cb(uv_work_t* req) {
  stmt_close_ctx_t* ctx = (stmt_close_ctx_t*)req->data;

  uv_mutex_lock(&ctx->member->mutex);
  if (ctx->member->closed || !ctx->member->conn) {
    /* The session is gone: the server-side statement died with it. */
    uv_mutex_unlock(&ctx->member->mutex);
    return;
  }
  PGresult* r = PQclosePrepared(ctx->member->conn, ctx->name);
  ExecStatusType status = r ? PQresultStatus(r) : PGRES_FATAL_ERROR;
  if (r) PQclear(r);
  if (status != PGRES_COMMAND_OK && status != PGRES_TUPLES_OK) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", PQerrorMessage(ctx->member->conn));
  }
  uv_mutex_unlock(&ctx->member->mutex);
}

static void stmt_close_after_cb(uv_work_t* req, int status) {
  stmt_close_ctx_t* ctx = (stmt_close_ctx_t*)req->data;
  lua_State* L = ctx->waiter_L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in stmt:close\n");
    lunet_free_nonnull(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->err[0] != '\0') {
    lua_pushstring(co, ctx->err);
  } else {
    lua_pushnil(co);
  }
  /* Shape: err = stmt:close() — one return value. */
  int rc = lunet_co_resume(co, 1);
  if (rc != 0 && rc != LUA_YIELD) {
    const char* err = lua_tostring(co, -1);
    if (err) fprintf(stderr, "lua_resume error in stmt:close: %s\n", err);
    lua_pop(co, 1);
  }
  lunet_free_nonnull(ctx);
}

static int stmt_close(lua_State* L) {
  if (lunet_ensure_coroutine(L, "stmt:close")) {
    return lua_error(L);
  }
  lunet_pg_stmt_t* s = (lunet_pg_stmt_t*)luaL_testudata(L, 1, LUNET_PG_STMT_MT);
  if (!s) {
    lua_pushstring(L, "stmt:close requires a prepared statement");
    return 1;
  }
  if (s->closed || !s->member) {
    lua_pushnil(L);
    return 1;
  }
  if (s->busy) {
    lua_pushstring(L, "statement is busy");
    return 1;
  }

  /* Mark closed and detach immediately: every later use fails loudly even
   * while the release round trip is still in flight. */
  stmt_close_ctx_t* ctx = lunet_alloc(sizeof(stmt_close_ctx_t));
  if (!ctx) {
    lua_pushstring(L, "out of memory");
    return lua_error(L);
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->waiter_L = L;
  ctx->req.data = ctx;
  ctx->member = s->member;
  snprintf(ctx->name, sizeof(ctx->name), "%s", s->name);

  s->closed = 1;
  conn_untrack_stmt(s->member, s);

  lunet_coref_create(L, ctx->co_ref);
  int ret = uv_queue_work(uv_default_loop(), &ctx->req, stmt_close_work_cb,
                          stmt_close_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lunet_free_nonnull(ctx);
    lua_pushfstring(L, "stmt:close: uv_queue_work failed: %s", uv_strerror(ret));
    return lua_error(L);
  }
  return lua_yield(L, 0);
}

/* Shared body of stmt:query / stmt:exec: validate the handle, bind the
 * varargs (same binding semantics as the one-shot calls), pin the
 * userdata, and queue the PQexecPrepared worker op. */
static int stmt_dispatch(lua_State* L, int is_exec) {
  lunet_pg_stmt_t* s = (lunet_pg_stmt_t*)luaL_testudata(L, 1, LUNET_PG_STMT_MT);
  if (!s) {
    lua_pushnil(L);
    lua_pushstring(L, "stmt requires a prepared statement");
    return 2;
  }
  if (s->closed || !s->member) {
    lua_pushnil(L);
    lua_pushstring(L, "statement is closed");
    return 2;
  }
  if (s->busy) {
    lua_pushnil(L);
    lua_pushstring(L, "statement is busy");
    return 2;
  }
  if (s->member->closed) {
    lua_pushnil(L);
    lua_pushstring(L, "connection is closed");
    return 2;
  }

  /* Pin the statement userdata for the flight; the after callback releases
   * the pin and clears the busy flag. */
  lua_pushvalue(L, 1);
  int valref;
  lunet_valref_create_raw(L, valref);
  s->busy = 1;

  if (is_exec) {
    db_exec_ctx_t* ctx = lunet_alloc(sizeof(db_exec_ctx_t));
    if (!ctx) {
      s->busy = 0;
      lunet_valref_release(L, valref);
      lua_pushstring(L, "out of memory");
      return lua_error(L);
    }
    memset(ctx, 0, sizeof(*ctx));
    ctx->waiter_L = L;
    ctx->req.data = ctx;
    ctx->wrapper = s->member;
    ctx->pstmt = s;
    ctx->stmt_valref = valref;
    snprintf(ctx->prepared_name, sizeof(ctx->prepared_name), "%s", s->name);
    ctx->params = collect_params(L, 2, &ctx->nparams);
    if (ctx->nparams < 0) {
      s->busy = 0;
      lunet_valref_release(L, valref);
      lunet_free_nonnull(ctx);
      lua_pushnil(L);
      lua_pushstring(L, "out of memory");
      return 2;
    }

    lunet_coref_create(L, ctx->co_ref);
    int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_exec_work_cb, db_exec_after_cb);
    if (ret < 0) {
      lunet_coref_release(L, ctx->co_ref);
      s->busy = 0;
      lunet_valref_release(L, valref);
      lunet_free_nonnull(ctx->query);
      free_params(ctx->params, ctx->nparams);
      lunet_free_nonnull(ctx);
      lua_pushnil(L);
      lua_pushstring(L, uv_strerror(ret));
      return 2;
    }
    return lua_yield(L, 0);
  }

  db_query_ctx_t* ctx = lunet_alloc(sizeof(db_query_ctx_t));
  if (!ctx) {
    s->busy = 0;
    lunet_valref_release(L, valref);
    lua_pushstring(L, "out of memory");
    return lua_error(L);
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->waiter_L = L;
  ctx->req.data = ctx;
  ctx->wrapper = s->member;
  ctx->pstmt = s;
  ctx->stmt_valref = valref;
  snprintf(ctx->prepared_name, sizeof(ctx->prepared_name), "%s", s->name);
  ctx->params = collect_params(L, 2, &ctx->nparams);
  if (ctx->nparams < 0) {
    s->busy = 0;
    lunet_valref_release(L, valref);
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  lunet_coref_create(L, ctx->co_ref);
  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_query_work_cb, db_query_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    s->busy = 0;
    lunet_valref_release(L, valref);
    lunet_free_nonnull(ctx->query);
    free_params(ctx->params, ctx->nparams);
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(ret));
    return 2;
  }
  return lua_yield(L, 0);
}

static int stmt_query(lua_State* L) {
  if (lunet_ensure_coroutine(L, "stmt:query")) {
    return lua_error(L);
  }
  return stmt_dispatch(L, 0);
}

static int stmt_exec(lua_State* L) {
  if (lunet_ensure_coroutine(L, "stmt:exec")) {
    return lua_error(L);
  }
  return stmt_dispatch(L, 1);
}

static void register_stmt_metatable(lua_State* L) {
  if (luaL_newmetatable(L, LUNET_PG_STMT_MT)) {
    lua_newtable(L);
    lua_pushcfunction(L, stmt_query);
    lua_setfield(L, -2, "query");
    lua_pushcfunction(L, stmt_exec);
    lua_setfield(L, -2, "exec");
    lua_pushcfunction(L, stmt_close);
    lua_setfield(L, -2, "close");
    lua_setfield(L, -2, "__index");
    lua_pushcfunction(L, stmt_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_pop(L, 1);
}

typedef struct {
  uv_work_t req;
  lua_State* waiter_L;
  int co_ref;
  int ud_ref; /* pins the statement userdata across the worker hop */
  lunet_pg_stmt_t* target;
  char* sql;

  char err[256];
} db_prepare_ctx_t;

static void db_prepare_work_cb(uv_work_t* req) {
  db_prepare_ctx_t* ctx = (db_prepare_ctx_t*)req->data;
  lunet_pg_stmt_t* s = ctx->target;

  uv_mutex_lock(&s->member->mutex);
  if (s->member->closed || !s->member->conn) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    uv_mutex_unlock(&s->member->mutex);
    return;
  }
  PGresult* r = PQprepare(s->member->conn, s->name, ctx->sql, 0, NULL);
  ExecStatusType status = r ? PQresultStatus(r) : PGRES_FATAL_ERROR;
  if (r) PQclear(r);
  if (status != PGRES_COMMAND_OK) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", PQerrorMessage(s->member->conn));
  }
  uv_mutex_unlock(&s->member->mutex);
}

/* Mark a not-yet-usable statement closed and take it off the connection's
 * open list. */
static void prepare_discard(lunet_pg_stmt_t* s) {
  s->closed = 1;
  if (s->member) conn_untrack_stmt(s->member, s);
}

static void db_prepare_after_cb(uv_work_t* req, int status) {
  db_prepare_ctx_t* ctx = (db_prepare_ctx_t*)req->data;
  lua_State* L = ctx->waiter_L;
  lunet_pg_stmt_t* s = ctx->target;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.prepare\n");
    lunet_valref_release(L, ctx->ud_ref);
    prepare_discard(s);
    lunet_free_nonnull(ctx->sql);
    lunet_free_nonnull(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  /* The pinned statement userdata moves to the coroutine's stack as the
   * first return value. */
  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->ud_ref);
  lunet_valref_release(L, ctx->ud_ref);

  if (ctx->err[0] != '\0') {
    prepare_discard(s);
    lua_pop(L, 1);
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
  } else {
    lua_xmove(L, co, 1);
    lua_pushnil(co);
  }
  int rc = lunet_co_resume(co, 2);
  if (rc != 0 && rc != LUA_YIELD) {
    const char* err = lua_tostring(co, -1);
    if (err) fprintf(stderr, "lua_resume error in db.prepare: %s\n", err);
    lua_pop(co, 1);
  }
  lunet_free_nonnull(ctx->sql);
  lunet_free_nonnull(ctx);
}

int lunet_db_prepare(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.prepare")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 2 || lua_type(L, 2) != LUA_TSTRING ||
      lua_strlen(L, 2) == 0) {
    lua_pushstring(L, "db.prepare requires a non-empty SQL string");
    return lua_error(L);
  }

  /* Statement-to-connection affinity: one statement lives on exactly one
   * pool member, so prepare is only defined for the default pool. */
  lunet_pg_pool_t* pool = (lunet_pg_pool_t*)luaL_testudata(L, 1, LUNET_PG_POOL_MT);
  if (pool && pool->n > 1) {
    lua_pushnil(L);
    lua_pushstring(L, "db.prepare requires pool_size = 1 (a statement is bound to one connection)");
    return 2;
  }

  lunet_pg_conn_t* wrapper = pick_statement_target(L, 1);
  if (!wrapper) {
    lua_pushnil(L);
    lua_pushstring(L, "db.prepare requires a valid connection");
    return 2;
  }
  if (wrapper->closed || !wrapper->conn) {
    lua_pushnil(L);
    lua_pushstring(L, "connection is closed");
    return 2;
  }
  const char* sql = lua_tostring(L, 2);

  register_stmt_metatable(L);

  lunet_pg_stmt_t* s =
      (lunet_pg_stmt_t*)lua_newuserdata(L, sizeof(lunet_pg_stmt_t));
  memset(s, 0, sizeof(*s));
  s->member = wrapper;
  pg_stmt_name(s->name, sizeof(s->name));
  luaL_getmetatable(L, LUNET_PG_STMT_MT);
  lua_setmetatable(L, -2);
  conn_track_stmt(wrapper, s);

  db_prepare_ctx_t* ctx = lunet_alloc(sizeof(db_prepare_ctx_t));
  if (!ctx) {
    s->closed = 1;
    conn_untrack_stmt(wrapper, s);
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->waiter_L = L;
  ctx->req.data = ctx;
  ctx->target = s;
  ctx->sql = lunet_strdup_local(sql);
  if (!ctx->sql) {
    s->closed = 1;
    conn_untrack_stmt(wrapper, s);
    lunet_free_nonnull(ctx);
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  lua_pushvalue(L, 3); /* the statement userdata */
  lunet_valref_create_raw(L, ctx->ud_ref);

  lunet_coref_create(L, ctx->co_ref);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_prepare_work_cb,
                          db_prepare_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lunet_valref_release(L, ctx->ud_ref);
    s->closed = 1;
    conn_untrack_stmt(wrapper, s);
    lunet_free_nonnull(ctx->sql);
    lunet_free_nonnull(ctx);
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushfstring(L, "db.prepare: uv_queue_work failed: %s", uv_strerror(ret));
    return 2;
  }

  return lua_yield(L, 0);
}

#include "lunet_sqlite3.h"

#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>

#include "co.h"
#include "trace.h"
#include "lunet_mem.h"
#include "uv.h"

#define LUNET_SQLITE_CONN_MT "lunet.sqlite.conn"
#define LUNET_SQLITE_STMT_MT "lunet.sqlite.stmt"

static char* lunet_strdup_local(const char* s) {
  if (!s) return NULL;
  size_t len = strlen(s);
  char* out = lunet_alloc(len + 1);
  if (!out) return NULL;
  memcpy(out, s, len + 1);
  return out;
}

typedef struct lunet_sqlite_stmt_s lunet_sqlite_stmt_t;

typedef struct {
  sqlite3* conn;
  int closed;
  /* Set on the read-only handle returned as open()'s second connection.
   * Queries and execs on it run inline on the loop thread (no worker hop,
   * no yield); writes fail loudly at step with SQLITE_READONLY. */
  int readonly;
  /* Open prepared statements bound to this connection (intrusive list).
   * Closing the connection finalizes every statement still open on it and
   * marks it closed, so a surviving statement userdata can never point at
   * a dead connection. List links are touched on the loop thread only. */
  lunet_sqlite_stmt_t* stmts;
} lunet_sqlite_conn_t;

/* A prepared statement: one connection, one vendor statement. */
struct lunet_sqlite_stmt_s {
  lunet_sqlite_conn_t* conn;
  sqlite3_stmt* stmt;
  lunet_sqlite_stmt_t* next;
  lunet_sqlite_stmt_t* prev;
  int closed;
};

/* Link a statement into the connection's open-statement list (loop thread). */
static void conn_track_stmt(lunet_sqlite_conn_t* conn, lunet_sqlite_stmt_t* s) {
  s->prev = NULL;
  s->next = conn->stmts;
  if (conn->stmts) conn->stmts->prev = s;
  conn->stmts = s;
}

/* Unlink a statement from the connection's open-statement list (loop thread). */
static void conn_untrack_stmt(lunet_sqlite_conn_t* conn, lunet_sqlite_stmt_t* s) {
  if (s->prev) s->prev->next = s->next;
  else if (conn->stmts == s) conn->stmts = s->next;
  if (s->next) s->next->prev = s->prev;
  s->next = NULL;
  s->prev = NULL;
}

/* Close the SQLite connection but don't destroy the mutex (caller may still hold it). */
static void lunet_sqlite_conn_close(lunet_sqlite_conn_t* wrapper) {
  if (!wrapper || wrapper->closed) return;
  wrapper->closed = 1;
  /* Finalize every still-open statement before sqlite3_close: the close
   * would fail with SQLITE_BUSY otherwise. Each statement is marked closed
   * and severed from the connection so later use or GC is a safe no-op. */
  lunet_sqlite_stmt_t* s = wrapper->stmts;
  while (s) {
    lunet_sqlite_stmt_t* next = s->next;
    if (s->stmt) {
      sqlite3_finalize(s->stmt);
      s->stmt = NULL;
    }
    s->closed = 1;
    s->conn = NULL;
    s->next = NULL;
    s->prev = NULL;
    s = next;
  }
  wrapper->stmts = NULL;
  if (wrapper->conn) {
    sqlite3_close(wrapper->conn);
    wrapper->conn = NULL;
  }
}

/* Full cleanup including mutex; only call when mutex is not held (for example, from GC). */
static void lunet_sqlite_conn_destroy(lunet_sqlite_conn_t* wrapper) {
  lunet_sqlite_conn_close(wrapper);
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
  lua_State* waiter_L;
  int co_ref;

  sqlite3* conn;    /* the read-write connection */
  sqlite3* ro_conn; /* the read-only connection (NULL for :memory:) */
  char err[256];

  char path[1024];
  int create;        /* open READWRITE|CREATE instead of READWRITE */
  int set_wal;       /* issue PRAGMA journal_mode=WAL and check the result */
  int is_memory;     /* path is ":memory:" — one connection, both handles */
  int busy_timeout;  /* ms; -1 = leave at the SQLite default (no wait) */
  int foreign_keys;  /* -1 = vendor default, 0 = off, 1 = on */
  int synchronous;   /* -1 = vendor default, 0 = off, 1 = normal, 2 = full */
} db_open_ctx_t;

/* Apply the caller's passthrough settings to one connection. Pragmas are
 * per-connection and last-write-wins: after open the caller can override
 * any of them on either handle with db.exec(handle, "PRAGMA ..."). */
static int apply_open_settings(db_open_ctx_t* ctx, sqlite3* conn) {
  if (ctx->busy_timeout >= 0) {
    sqlite3_busy_timeout(conn, ctx->busy_timeout);
  }
  if (ctx->foreign_keys >= 0) {
    const char* sql = ctx->foreign_keys ? "PRAGMA foreign_keys=ON"
                                        : "PRAGMA foreign_keys=OFF";
    char* errmsg = NULL;
    if (sqlite3_exec(conn, sql, NULL, NULL, &errmsg) != SQLITE_OK) {
      snprintf(ctx->err, sizeof(ctx->err), "PRAGMA foreign_keys failed: %s",
               errmsg ? errmsg : sqlite3_errmsg(conn));
      if (errmsg) sqlite3_free(errmsg);
      return -1;
    }
  }
  if (ctx->synchronous >= 0) {
    static const char* modes[] = { "OFF", "NORMAL", "FULL" };
    char sql[64];
    snprintf(sql, sizeof(sql), "PRAGMA synchronous=%s", modes[ctx->synchronous]);
    char* errmsg = NULL;
    if (sqlite3_exec(conn, sql, NULL, NULL, &errmsg) != SQLITE_OK) {
      snprintf(ctx->err, sizeof(ctx->err), "PRAGMA synchronous failed: %s",
               errmsg ? errmsg : sqlite3_errmsg(conn));
      if (errmsg) sqlite3_free(errmsg);
      return -1;
    }
  }
  return 0;
}

static void db_open_work_cb(uv_work_t* req) {
  db_open_ctx_t* ctx = (db_open_ctx_t*)req->data;

  if (ctx->is_memory) {
    /* :memory: is one private database: a single connection serves both
     * handles (the Lua loader documents that ro does not enforce read-only
     * there — it exists so unit tests can swap the path and keep the same
     * (rw, ro) code shape). create= and WAL are meaningless for it. */
    int rc = sqlite3_open_v2(ctx->path, &ctx->conn,
                             SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
    if (rc != SQLITE_OK) {
      snprintf(ctx->err, sizeof(ctx->err), "%s",
               ctx->conn ? sqlite3_errmsg(ctx->conn) : "cannot open database");
      if (ctx->conn) sqlite3_close(ctx->conn);
      ctx->conn = NULL;
      return;
    }
    if (apply_open_settings(ctx, ctx->conn) != 0) {
      sqlite3_close(ctx->conn);
      ctx->conn = NULL;
    }
    return;
  }

  /* File path. Without create= the file must already exist: provisioning
   * (creating the database, setting WAL) is a deployment act, and the
   * driver never makes a sticky change to a file on its own. */
  int rc = sqlite3_open_v2(ctx->path, &ctx->conn,
                           ctx->create
                               ? (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
                               : SQLITE_OPEN_READWRITE,
                           NULL);
  if (rc != SQLITE_OK) {
    snprintf(ctx->err, sizeof(ctx->err), "%s",
             ctx->conn ? sqlite3_errmsg(ctx->conn) : "cannot open database");
    if (ctx->conn) sqlite3_close(ctx->conn);
    ctx->conn = NULL;
    return;
  }

  if (ctx->set_wal) {
    /* journal_mode returns the PRIOR mode string when the conversion does
     * not take (it does not error), so the result is checked. There is no
     * cleanup on failure: a filesystem that cannot host WAL is between the
     * caller and SQLite — the loud open error is the whole story. */
    sqlite3_stmt* stmt = NULL;
    rc = sqlite3_prepare_v2(ctx->conn, "PRAGMA journal_mode=WAL", -1, &stmt, NULL);
    if (rc == SQLITE_OK) rc = sqlite3_step(stmt);
    const char* mode =
        (rc == SQLITE_ROW) ? (const char*)sqlite3_column_text(stmt, 0) : NULL;
    int wal_ok = mode && strcmp(mode, "wal") == 0;
    sqlite3_finalize(stmt);
    if (!wal_ok) {
      snprintf(ctx->err, sizeof(ctx->err),
               "journal_mode=WAL unavailable (journal mode is %s)",
               mode ? mode : "unknown");
      sqlite3_close(ctx->conn);
      ctx->conn = NULL;
      return;
    }
  }

  rc = sqlite3_open_v2(ctx->path, &ctx->ro_conn, SQLITE_OPEN_READONLY, NULL);
  if (rc != SQLITE_OK) {
    snprintf(ctx->err, sizeof(ctx->err), "%s",
             ctx->ro_conn ? sqlite3_errmsg(ctx->ro_conn)
                          : "cannot open read-only connection");
    if (ctx->ro_conn) sqlite3_close(ctx->ro_conn);
    ctx->ro_conn = NULL;
    sqlite3_close(ctx->conn);
    ctx->conn = NULL;
    return;
  }

  if (apply_open_settings(ctx, ctx->conn) != 0 ||
      apply_open_settings(ctx, ctx->ro_conn) != 0) {
    if (ctx->ro_conn) {
      sqlite3_close(ctx->ro_conn);
      ctx->ro_conn = NULL;
    }
    sqlite3_close(ctx->conn);
    ctx->conn = NULL;
  }
}

/* Wrap a raw sqlite3 handle in the connection userdata. */
static void push_conn_wrapper(lua_State* co, sqlite3* conn, int readonly) {
  lunet_sqlite_conn_t* wrapper =
      (lunet_sqlite_conn_t*)lua_newuserdata(co, sizeof(lunet_sqlite_conn_t));
  memset(wrapper, 0, sizeof(*wrapper));
  wrapper->conn = conn;
  wrapper->readonly = readonly;
  luaL_getmetatable(co, LUNET_SQLITE_CONN_MT);
  lua_setmetatable(co, -2);
}

static void db_open_after_cb(uv_work_t* req, int status) {
  db_open_ctx_t* ctx = (db_open_ctx_t*)req->data;
  lua_State* L = ctx->waiter_L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.open\n");
    if (ctx->conn) sqlite3_close(ctx->conn);
    ctx->conn = NULL;
    if (ctx->ro_conn) sqlite3_close(ctx->ro_conn);
    ctx->ro_conn = NULL;
    lunet_free_nonnull(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->is_memory && ctx->conn) {
    /* One connection, both handles: the same userdata pushed twice keeps
     * one mutex and one close guard, so close/destroy cannot double-free
     * and the engine never sees two wrappers over one connection. */
    push_conn_wrapper(co, ctx->conn, 0);
    lua_pushvalue(co, -1);
    lua_pushnil(co);
    ctx->conn = NULL;
  } else if (ctx->conn && ctx->ro_conn) {
    /* Success shape: (rw, ro, nil). The third push is load-bearing:
     * lua_resume(co, 3) takes the top three values of the coroutine's
     * stack as the yield's return values — without the nil, stack junk
     * becomes the first return and every handle shifts. */
    push_conn_wrapper(co, ctx->conn, 0);
    push_conn_wrapper(co, ctx->ro_conn, 1);
    lua_pushnil(co);
    ctx->conn = NULL;
    ctx->ro_conn = NULL;
  } else {
    /* Failure shape: (nil, nil, err) — both handles nil, error third. */
    lua_pushnil(co);
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
  }
  int rc = lunet_co_resume(co, 3);
  if (rc != 0 && rc != LUA_YIELD) {
    const char* err = lua_tostring(co, -1);
    if (err) fprintf(stderr, "lua_resume error in db.open: %s\n", err);
    lua_pop(co, 1);
  }
  lunet_free_nonnull(ctx);
}

/* The raw open: always opens a fresh (rw, ro) pair in one worker hop. The
 * path-keyed convenience cache lives in the Lua loader (sqlite3.lua), not
 * here — C owns the async I/O, Lua owns the policy. */
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

  lua_getfield(L, 1, "path");
  const char* path = luaL_optstring(L, -1, ":memory:");
  snprintf(ctx->path, sizeof(ctx->path), "%s", path);
  lua_pop(L, 1);
  ctx->is_memory = strcmp(ctx->path, ":memory:") == 0;

  ctx->create = 0;
  ctx->set_wal = 0;
  ctx->busy_timeout = -1;
  ctx->foreign_keys = -1;
  ctx->synchronous = -1;

  lua_getfield(L, 1, "create");
  if (!lua_isnil(L, -1)) {
    const char* create = luaL_checkstring(L, -1);
    if (strcmp(create, "WAL") == 0) {
      ctx->create = 1;
      ctx->set_wal = 1;
    } else if (strcmp(create, "NORMAL") == 0) {
      ctx->create = 1;
    } else {
      lunet_free_nonnull(ctx);
      lua_pushfstring(L, "db.open: create must be \"WAL\" or \"NORMAL\" (got '%s')",
                      create);
      return lua_error(L);
    }
  }
  lua_pop(L, 1);

  lua_getfield(L, 1, "busy_timeout");
  if (!lua_isnil(L, -1)) {
    lua_Integer ms = luaL_checkinteger(L, -1);
    if (ms < 0) {
      lunet_free_nonnull(ctx);
      lua_pushstring(L, "db.open: busy_timeout must be >= 0");
      return lua_error(L);
    }
    ctx->busy_timeout = (int)ms;
  }
  lua_pop(L, 1);

  lua_getfield(L, 1, "foreign_keys");
  if (!lua_isnil(L, -1)) {
    luaL_checktype(L, -1, LUA_TBOOLEAN);
    ctx->foreign_keys = lua_toboolean(L, -1) ? 1 : 0;
  }
  lua_pop(L, 1);

  lua_getfield(L, 1, "synchronous");
  if (!lua_isnil(L, -1)) {
    const char* sync = luaL_checkstring(L, -1);
    if (strcmp(sync, "OFF") == 0) {
      ctx->synchronous = 0;
    } else if (strcmp(sync, "NORMAL") == 0) {
      ctx->synchronous = 1;
    } else if (strcmp(sync, "FULL") == 0) {
      ctx->synchronous = 2;
    } else {
      lunet_free_nonnull(ctx);
      lua_pushfstring(L,
                      "db.open: synchronous must be \"OFF\", \"NORMAL\" or \"FULL\" (got '%s')",
                      sync);
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
  lunet_sqlite_conn_t* wrapper = (lunet_sqlite_conn_t*)luaL_testudata(L, 1, LUNET_SQLITE_CONN_MT);
  if (!wrapper) {
    lua_pushstring(L, "db.close requires a valid connection");
    return 1;
  }

  lunet_sqlite_conn_close(wrapper);

  lua_pushnil(L);
  return 1;
}

typedef struct {
  uv_work_t req;
  lua_State* waiter_L;
  int co_ref;

  lunet_sqlite_conn_t* wrapper;
  char* query;

  /* When set, run against this already-prepared statement (reset +
   * clear-bindings + bind + step, no finalize) instead of preparing the
   * SQL text per call. The valref pins the statement userdata so it
   * cannot be collected while a worker op on it is in flight. */
  lunet_sqlite_stmt_t* pstmt;
  int stmt_valref;

  param_t* params;
  int nparams;

  char** col_names;
  int* col_types;
  char*** rows;
  int nrows;
  int ncols;
  char err[256];
} db_query_ctx_t;

/* Bind the statement's column metadata and step it to completion, staging
 * every row into the ctx. Never finalizes the statement: the caller decides
 * (finalize for the per-call prepare path, reset for the prepared handle). */
static void collect_query_rows(db_query_ctx_t* ctx, sqlite3_stmt* stmt) {
  sqlite3* conn = ctx->wrapper->conn;

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
    return;
  }
  ctx->nrows = 0;

  int rc;
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
    snprintf(ctx->err, sizeof(ctx->err), "%s", sqlite3_errmsg(conn));
  }
}

static void db_query_work_cb(uv_work_t* req) {
  db_query_ctx_t* ctx = (db_query_ctx_t*)req->data;
  sqlite3_stmt* stmt = NULL;

  if (ctx->wrapper->closed || !ctx->wrapper->conn) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    return;
  }

  if (ctx->pstmt) {
    /* Prepared handle: reset + clear bindings + bind + step. The vendor
     * statement is never finalized here — it survives for the next call. */
    stmt = ctx->pstmt->stmt;
    if (!stmt) {
      snprintf(ctx->err, sizeof(ctx->err), "statement is closed");
      return;
    }
    sqlite3_reset(stmt);
    sqlite3_clear_bindings(stmt);
    int rc = bind_params(stmt, ctx->params, ctx->nparams, ctx->err, sizeof(ctx->err));
    if (rc != SQLITE_OK) {
      if (ctx->err[0] == '\0') {
        snprintf(ctx->err, sizeof(ctx->err), "bind failed: %s", sqlite3_errmsg(ctx->wrapper->conn));
      }
      sqlite3_reset(stmt);
      return;
    }
    collect_query_rows(ctx, stmt);
    sqlite3_reset(stmt); /* leave the statement ready for the next call */
    return;
  }

  int rc = sqlite3_prepare_v2(ctx->wrapper->conn, ctx->query, -1, &stmt, NULL);
  if (rc != SQLITE_OK) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", sqlite3_errmsg(ctx->wrapper->conn));
    return;
  }

  if (ctx->nparams > 0) {
      rc = bind_params(stmt, ctx->params, ctx->nparams, ctx->err, sizeof(ctx->err));
      if (rc != SQLITE_OK) {
          if (ctx->err[0] == '\0') {
              snprintf(ctx->err, sizeof(ctx->err), "bind failed: %s", sqlite3_errmsg(ctx->wrapper->conn));
          }
          sqlite3_finalize(stmt);
          return;
      }
  }

  collect_query_rows(ctx, stmt);

  sqlite3_finalize(stmt);
}

/* Push the query outcome as two Lua values: (rows, nil) on success or
 * (nil, err) on failure. Shared by the worker-pool after-callback and the
 * read-only handle's inline path. */
static void db_query_push_values(lua_State* co, db_query_ctx_t* ctx) {
  if (ctx->err[0] != '\0') {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
    return;
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
}

static void db_query_ctx_free(db_query_ctx_t* ctx) {
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

static void db_query_after_cb(uv_work_t* req, int status) {
  db_query_ctx_t* ctx = (db_query_ctx_t*)req->data;
  lua_State* L = ctx->waiter_L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.query\n");
    if (ctx->stmt_valref) lunet_valref_release(L, ctx->stmt_valref);
    db_query_ctx_free(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->stmt_valref) lunet_valref_release(L, ctx->stmt_valref);

  db_query_push_values(co, ctx);
  {
    int rc = lunet_co_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) fprintf(stderr, "lua_resume error in db.query: %s\n", err);
      lua_pop(co, 1);
    }
  }

  db_query_ctx_free(ctx);
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

  /* Bind trailing arguments as parameters, same as db.query_params. Without
   * this, db.query(conn, sql, ...) silently discarded its parameters and left
   * every '?' unbound (i.e. NULL), which the sqlite3 API reports as success. */
  ctx->params = collect_params(L, 3, &ctx->nparams);
  if (ctx->nparams < 0) {
    lunet_free_nonnull(ctx->query);
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  /* Read-only handle: run inline on the loop thread — no worker hop, no
   * yield. A mis-routed write fails loudly at step with SQLITE_READONLY. */
  if (wrapper->readonly) {
    db_query_work_cb(&ctx->req);
    db_query_push_values(L, ctx);
    db_query_ctx_free(ctx);
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

  lunet_sqlite_conn_t* wrapper;
  char* query;

  lunet_sqlite_stmt_t* pstmt;
  int stmt_valref;

  param_t* params;
  int nparams;

  long long affected_rows;
  long long insert_id;
  char err[256];
} db_exec_ctx_t;

static void db_exec_work_cb(uv_work_t* req) {
  db_exec_ctx_t* ctx = (db_exec_ctx_t*)req->data;

  if (ctx->wrapper->closed || !ctx->wrapper->conn) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    return;
  }

  if (ctx->pstmt) {
    /* Prepared handle: reset + clear bindings + bind + step. */
    sqlite3_stmt* stmt = ctx->pstmt->stmt;
    if (!stmt) {
      snprintf(ctx->err, sizeof(ctx->err), "statement is closed");
      return;
    }
    sqlite3_reset(stmt);
    sqlite3_clear_bindings(stmt);
    int rc = bind_params(stmt, ctx->params, ctx->nparams, ctx->err, sizeof(ctx->err));
    if (rc != SQLITE_OK) {
      if (ctx->err[0] == '\0') {
        snprintf(ctx->err, sizeof(ctx->err), "bind failed: %s", sqlite3_errmsg(ctx->wrapper->conn));
      }
      sqlite3_reset(stmt);
      return;
    }
    rc = sqlite3_step(stmt);
    if (rc != SQLITE_DONE && rc != SQLITE_ROW) {
      snprintf(ctx->err, sizeof(ctx->err), "%s", sqlite3_errmsg(ctx->wrapper->conn));
    }
    sqlite3_reset(stmt); /* leave the statement ready for the next call */
  } else if (ctx->nparams > 0) {
      sqlite3_stmt* stmt = NULL;
      int rc = sqlite3_prepare_v2(ctx->wrapper->conn, ctx->query, -1, &stmt, NULL);
      if (rc != SQLITE_OK) {
          snprintf(ctx->err, sizeof(ctx->err), "%s", sqlite3_errmsg(ctx->wrapper->conn));
          return;
      }
      rc = bind_params(stmt, ctx->params, ctx->nparams, ctx->err, sizeof(ctx->err));
      if (rc != SQLITE_OK) {
          if (ctx->err[0] == '\0') {
              snprintf(ctx->err, sizeof(ctx->err), "bind failed: %s", sqlite3_errmsg(ctx->wrapper->conn));
          }
          sqlite3_finalize(stmt);
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
        return;
      }
  }

  ctx->affected_rows = sqlite3_changes(ctx->wrapper->conn);
  ctx->insert_id = sqlite3_last_insert_rowid(ctx->wrapper->conn);
}

/* Push the exec outcome as two Lua values: (result, nil) on success or
 * (nil, err) on failure. Shared by the worker-pool after-callback and the
 * read-only handle's inline path. */
static void db_exec_push_values(lua_State* co, db_exec_ctx_t* ctx) {
  if (ctx->err[0] != '\0') {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
  } else {
    lua_newtable(co);
    lua_pushstring(co, "affected_rows");
    lua_pushinteger(co, ctx->affected_rows);
    lua_settable(co, -3);
    lua_pushstring(co, "last_insert_id");
    lua_pushinteger(co, ctx->insert_id);
    lua_settable(co, -3);
    lua_pushnil(co);
  }
}

static void db_exec_ctx_free(db_exec_ctx_t* ctx) {
  lunet_free_nonnull(ctx->query);
  free_params(ctx->params, ctx->nparams);
  lunet_free_nonnull(ctx);
}

static void db_exec_after_cb(uv_work_t* req, int status) {
  db_exec_ctx_t* ctx = (db_exec_ctx_t*)req->data;
  lua_State* L = ctx->waiter_L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.exec\n");
    if (ctx->stmt_valref) lunet_valref_release(L, ctx->stmt_valref);
    db_exec_ctx_free(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->stmt_valref) lunet_valref_release(L, ctx->stmt_valref);

  db_exec_push_values(co, ctx);
  {
    int rc = lunet_co_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) fprintf(stderr, "lua_resume error in db.exec: %s\n", err);
      lua_pop(co, 1);
    }
  }

  db_exec_ctx_free(ctx);
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

  /* Bind trailing arguments as parameters, same as db.exec_params. Without
   * this, db.exec(conn, sql, ...) silently discarded its parameters and left
   * every '?' unbound (i.e. NULL), which the sqlite3 API reports as success. */
  ctx->params = collect_params(L, 3, &ctx->nparams);
  if (ctx->nparams < 0) {
    lunet_free_nonnull(ctx->query);
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  /* Read-only handle: run inline on the loop thread — no worker hop, no
   * yield. A mis-routed write fails loudly at step with SQLITE_READONLY. */
  if (wrapper->readonly) {
    db_exec_work_cb(&ctx->req);
    db_exec_push_values(L, ctx);
    db_exec_ctx_free(ctx);
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

  /* Read-only handle: run inline on the loop thread — no worker hop, no
   * yield. A mis-routed write fails loudly at step with SQLITE_READONLY. */
  if (wrapper->readonly) {
    db_query_work_cb(&ctx->req);
    db_query_push_values(L, ctx);
    db_query_ctx_free(ctx);
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

  /* Read-only handle: run inline on the loop thread — no worker hop, no
   * yield. A mis-routed write fails loudly at step with SQLITE_READONLY. */
  if (wrapper->readonly) {
    db_exec_work_cb(&ctx->req);
    db_exec_push_values(L, ctx);
    db_exec_ctx_free(ctx);
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
 * db.prepare(conn, sql) hands back a reusable statement handle: prepare
 * once, then stmt:query(...) / stmt:exec(...) per call with the vendor
 * reset + rebind discipline, and stmt:close() to finalize. One statement
 * is bound to one connection.
 * ========================================================================== */

static int stmt_gc(lua_State* L) {
  lunet_sqlite_stmt_t* s = (lunet_sqlite_stmt_t*)luaL_checkudata(L, 1, LUNET_SQLITE_STMT_MT);
  if (s->closed || !s->stmt || !s->conn) return 0;
  if (!s->closed && s->stmt) {
    sqlite3_finalize(s->stmt);
    s->stmt = NULL;
    s->closed = 1;
    conn_untrack_stmt(s->conn, s);
  }
  return 0;
}

static int stmt_close(lua_State* L) {
  if (lunet_ensure_coroutine(L, "stmt:close")) {
    return lua_error(L);
  }
  lunet_sqlite_stmt_t* s = (lunet_sqlite_stmt_t*)luaL_testudata(L, 1, LUNET_SQLITE_STMT_MT);
  if (!s) {
    lua_pushstring(L, "stmt:close requires a prepared statement");
    return 1;
  }
  if (s->closed || !s->conn) {
    lua_pushnil(L);
    return 1;
  }
  if (!s->closed && s->stmt) {
    sqlite3_finalize(s->stmt);
    s->stmt = NULL;
    s->closed = 1;
    conn_untrack_stmt(s->conn, s);
  } else {
    s->closed = 1;
  }
  lua_pushnil(L);
  return 1;
}

/* Shared body of stmt:query / stmt:exec: validate the handle, bind the
 * varargs, and either run inline (read-only connection) or queue the
 * worker op. `exec` selects the exec context and callbacks. */
static int stmt_dispatch(lua_State* L, int is_exec) {
  lunet_sqlite_stmt_t* s = (lunet_sqlite_stmt_t*)luaL_testudata(L, 1, LUNET_SQLITE_STMT_MT);
  if (!s) {
    lua_pushnil(L);
    lua_pushstring(L, "stmt requires a prepared statement");
    return 2;
  }
  if (s->closed || !s->conn) {
    lua_pushnil(L);
    lua_pushstring(L, "statement is closed");
    return 2;
  }
  if (s->conn->closed) {
    lua_pushnil(L);
    lua_pushstring(L, "connection is closed");
    return 2;
  }

  /* A statement created on the read-write handle rides the worker pool;
   * one created on the read-only handle runs inline, matching that
   * handle's inline semantics. */
  if (s->conn->readonly) {
    if (is_exec) {
      db_exec_ctx_t* ctx = lunet_alloc(sizeof(db_exec_ctx_t));
      if (!ctx) {
        lua_pushstring(L, "out of memory");
        return lua_error(L);
      }
      memset(ctx, 0, sizeof(*ctx));
      ctx->waiter_L = L;
      ctx->req.data = ctx;
      ctx->wrapper = s->conn;
      ctx->pstmt = s;
      ctx->params = collect_params(L, 2, &ctx->nparams);
      if (ctx->nparams < 0) {
        lunet_free_nonnull(ctx);
        lua_pushnil(L);
        lua_pushstring(L, "out of memory");
        return 2;
      }
      db_exec_work_cb(&ctx->req);
      db_exec_push_values(L, ctx);
      db_exec_ctx_free(ctx);
      return 2;
    }
    db_query_ctx_t* ctx = lunet_alloc(sizeof(db_query_ctx_t));
    if (!ctx) {
      lua_pushstring(L, "out of memory");
      return lua_error(L);
    }
    memset(ctx, 0, sizeof(*ctx));
    ctx->waiter_L = L;
    ctx->req.data = ctx;
    ctx->wrapper = s->conn;
    ctx->pstmt = s;
    ctx->params = collect_params(L, 2, &ctx->nparams);
    if (ctx->nparams < 0) {
      lunet_free_nonnull(ctx);
      lua_pushnil(L);
      lua_pushstring(L, "out of memory");
      return 2;
    }
    db_query_work_cb(&ctx->req);
    db_query_push_values(L, ctx);
    db_query_ctx_free(ctx);
    return 2;
  }

  if (is_exec) {
    db_exec_ctx_t* ctx = lunet_alloc(sizeof(db_exec_ctx_t));
    if (!ctx) {
      lua_pushstring(L, "out of memory");
      return lua_error(L);
    }
    memset(ctx, 0, sizeof(*ctx));
    ctx->waiter_L = L;
    ctx->req.data = ctx;
    ctx->wrapper = s->conn;
    ctx->pstmt = s;
    ctx->params = collect_params(L, 2, &ctx->nparams);
    if (ctx->nparams < 0) {
      lunet_free_nonnull(ctx);
      lua_pushnil(L);
      lua_pushstring(L, "out of memory");
      return 2;
    }
    /* Pin the statement userdata for the flight: the worker touches only
     * the raw struct, so GC must not collect the userdata out from under
     * it. The ref is released in the after callback, which also clears
     * the busy flag. */
    lua_pushvalue(L, 1);
    lunet_valref_create_raw(L, ctx->stmt_valref);

    lunet_coref_create(L, ctx->co_ref);
    int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_exec_work_cb, db_exec_after_cb);
    if (ret < 0) {
      lunet_coref_release(L, ctx->co_ref);
      lunet_valref_release(L, ctx->stmt_valref);
      lunet_free_nonnull(ctx);
      lua_pushnil(L);
      lua_pushstring(L, uv_strerror(ret));
      return 2;
    }
    return lua_yield(L, 0);
  }

  db_query_ctx_t* ctx = lunet_alloc(sizeof(db_query_ctx_t));
  if (!ctx) {
    lua_pushstring(L, "out of memory");
    return lua_error(L);
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->waiter_L = L;
  ctx->req.data = ctx;
  ctx->wrapper = s->conn;
  ctx->pstmt = s;
  ctx->params = collect_params(L, 2, &ctx->nparams);
  if (ctx->nparams < 0) {
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  lua_pushvalue(L, 1);
  lunet_valref_create_raw(L, ctx->stmt_valref);

  lunet_coref_create(L, ctx->co_ref);
  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_query_work_cb, db_query_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lunet_valref_release(L, ctx->stmt_valref);
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
  if (luaL_newmetatable(L, LUNET_SQLITE_STMT_MT)) {
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

/* Extract the trailing varargs bound on every stmt:query / stmt:exec call.
 * Shared shape with query_params/exec_params: same binding semantics. */

typedef struct {
  uv_work_t req;
  lua_State* waiter_L;
  int co_ref;
  int ud_ref; /* pins the statement userdata across the worker hop */
  lunet_sqlite_stmt_t* target;
  char* sql;

  char err[256];
} db_prepare_ctx_t;

static void db_prepare_work_cb(uv_work_t* req) {
  db_prepare_ctx_t* ctx = (db_prepare_ctx_t*)req->data;
  lunet_sqlite_stmt_t* s = ctx->target;

  if (s->conn->closed || !s->conn->conn) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    return;
  }
  int rc = sqlite3_prepare_v2(s->conn->conn, ctx->sql, -1, &s->stmt, NULL);
  if (rc != SQLITE_OK) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", sqlite3_errmsg(s->conn->conn));
    s->stmt = NULL;
  }
}

/* Finalize a not-yet-handed-over statement and take it off the connection's
 * open list (loop thread; lock held by the caller). */
static void prepare_discard(lunet_sqlite_stmt_t* s) {
  if (s->stmt) {
    sqlite3_finalize(s->stmt);
    s->stmt = NULL;
  }
  s->closed = 1;
  if (s->conn) conn_untrack_stmt(s->conn, s);
}

static void db_prepare_after_cb(uv_work_t* req, int status) {
  db_prepare_ctx_t* ctx = (db_prepare_ctx_t*)req->data;
  lua_State* L = ctx->waiter_L;
  lunet_sqlite_stmt_t* s = ctx->target;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.prepare\n");
    lunet_valref_release(L, ctx->ud_ref);
    if (ctx->err[0] != '\0' || !s->stmt) {
      prepare_discard(s);
    } else {
      /* Prepared but nowhere to hand it: finalize so nothing leaks. */
      prepare_discard(s);
    }
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
  lunet_sqlite_conn_t* wrapper = (lunet_sqlite_conn_t*)luaL_testudata(L, 1, LUNET_SQLITE_CONN_MT);
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

  /* Create and register the statement userdata up front: the worker fills
   * the vendor statement in, and the connection's open-statement list is
   * touched only here, in the after callback and at GC — all on the loop
   * thread. */
  lunet_sqlite_stmt_t* s =
      (lunet_sqlite_stmt_t*)lua_newuserdata(L, sizeof(lunet_sqlite_stmt_t));
  memset(s, 0, sizeof(*s));
  s->conn = wrapper;
  luaL_getmetatable(L, LUNET_SQLITE_STMT_MT);
  lua_setmetatable(L, -2);
  conn_track_stmt(wrapper, s);

  if (wrapper->readonly) {
    /* Inline prepare on the read-only handle, matching that handle's
     * inline statement semantics — and giving write SQL a loud rejection
     * at prepare time instead of a step-time failure on first execution. */
    char err[256] = "";
    int rc = sqlite3_prepare_v2(wrapper->conn, sql, -1, &s->stmt, NULL);
    if (rc != SQLITE_OK) {
      snprintf(err, sizeof(err), "%s", sqlite3_errmsg(wrapper->conn));
      s->stmt = NULL;
    } else if (!sqlite3_stmt_readonly(s->stmt)) {
      sqlite3_finalize(s->stmt);
      s->stmt = NULL;
      snprintf(err, sizeof(err),
               "write statement rejected on the read-only connection");
    }
    if (err[0] != '\0') {
      s->closed = 1;
      conn_untrack_stmt(wrapper, s);
      lua_pop(L, 1); /* the statement userdata */
      lua_pushnil(L);
      lua_pushstring(L, err);
      return 2;
    }
    lua_pushnil(L); /* success shape: (stmt, nil) */
    return 2;
  }

  /* Read-write handle: prepare in one worker hop, like every other
   * statement on this handle. */
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

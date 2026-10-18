#include "lunet_db_mysql.h"

#ifdef _WIN32
/* Include winsock2.h before mysql.h to prevent the old winsock.h from being
 * pulled in by the MySQL client headers. winsock2.h defines _WINSOCKAPI_
 * which suppresses subsequent winsock.h inclusion, avoiding struct
 * redefinition errors (sockaddr, fd_set, timeval, etc.) when libuv also
 * includes the newer Windows socket headers. */
#include <winsock2.h>
#include <ws2tcpip.h>
#endif

#include <mysql.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "co.h"
#include "trace.h"
#include "lunet_mem.h"
#include "uv.h"

#define LUNET_MYSQL_CONN_MT "lunet.mysql.conn"
#define LUNET_MYSQL_POOL_MT "lunet.mysql.pool"
#define LUNET_MYSQL_STMT_MT "lunet.mysql.stmt"
#define LUNET_MYSQL_POOL_MAX 64

static int g_mysql_library_initialized = 0;
static int g_mysql_library_refcount = 0;

static int lunet_mysql_library_acquire(void) {
  if (g_mysql_library_refcount == 0) {
    if (mysql_library_init(0, NULL, NULL) != 0) {
      return -1;
    }
    g_mysql_library_initialized = 1;
  }
  g_mysql_library_refcount++;
  return 0;
}

static void lunet_mysql_library_release(void) {
  if (g_mysql_library_refcount <= 0) {
    return;
  }
  g_mysql_library_refcount--;
  if (g_mysql_library_refcount == 0 && g_mysql_library_initialized) {
    mysql_library_end();
    g_mysql_library_initialized = 0;
  }
}

static char* lunet_strdup_local(const char* s) {
  if (!s) return NULL;
  size_t len = strlen(s);
  char* out = lunet_alloc(len + 1);
  if (!out) return NULL;
  memcpy(out, s, len + 1);
  return out;
}

typedef struct lunet_mysql_stmt_s lunet_mysql_stmt_t;

typedef struct {
  MYSQL* conn;
  uv_mutex_t mutex;
  int closed;
  int library_ref_held;
  /* Open prepared statements bound to this connection (intrusive list,
   * loop-thread-only links). Closing the connection marks every still-open
   * statement closed and severs it: mysql_close() invalidates the vendor
   * statements with the connection, so a surviving statement userdata must
   * never dereference its MYSQL_STMT* again. */
  lunet_mysql_stmt_t* stmts;
} lunet_mysql_conn_t;

/* A prepared statement: one connection, one vendor statement. The busy
 * flag guards re-entrant use (a second call while one is in flight fails
 * loudly instead of surfacing as CR_COMMANDS_OUT_OF_SYNC). */
struct lunet_mysql_stmt_s {
  MYSQL_STMT* stmt;
  lunet_mysql_conn_t* member;
  lunet_mysql_stmt_t* next;
  lunet_mysql_stmt_t* prev;
  int busy;
  int closed;
};

/* Link a statement into the connection's open-statement list (loop thread). */
static void conn_track_stmt(lunet_mysql_conn_t* conn, lunet_mysql_stmt_t* s) {
  s->prev = NULL;
  s->next = conn->stmts;
  if (conn->stmts) conn->stmts->prev = s;
  conn->stmts = s;
}

/* Unlink a statement from the connection's open-statement list (loop thread). */
static void conn_untrack_stmt(lunet_mysql_conn_t* conn, lunet_mysql_stmt_t* s) {
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
  lunet_mysql_conn_t** members;
  int n;
  int next; /* round-robin cursor; picked on the loop thread only */
  int closed;
} lunet_mysql_pool_t;

/* Close connection but keep mutex intact (for explicit db.close()). */
static void lunet_mysql_conn_close(lunet_mysql_conn_t* wrapper) {
  if (!wrapper || wrapper->closed) return;
  wrapper->closed = 1;
  /* Sever every still-open prepared statement first: mysql_close()
   * invalidates the vendor statements with the connection, so each one is
   * marked closed and its MYSQL_STMT* nulled — later use or GC is then a
   * loud error or a safe no-op, never a dereference of freed memory. */
  lunet_mysql_stmt_t* s = wrapper->stmts;
  while (s) {
    lunet_mysql_stmt_t* next = s->next;
    s->stmt = NULL;
    s->closed = 1;
    s->member = NULL;
    s->next = NULL;
    s->prev = NULL;
    s = next;
  }
  wrapper->stmts = NULL;
  if (wrapper->conn) {
    mysql_close(wrapper->conn);
    wrapper->conn = NULL;
  }
  if (wrapper->library_ref_held) {
    lunet_mysql_library_release();
    wrapper->library_ref_held = 0;
  }
}

/* Full cleanup including mutex (only called from GC). */
static void lunet_mysql_conn_destroy(lunet_mysql_conn_t* wrapper) {
  if (!wrapper) return;
  lunet_mysql_conn_close(wrapper);
  uv_mutex_destroy(&wrapper->mutex);
}

typedef struct {
  uv_work_t req;
  lua_State* waiter_L;
  int co_ref;

  MYSQL** conns; /* pool_n connections; handed to the pool on success */
  int pool_n;
  char err[256];

  char host[256];
  int port;
  char user[256];
  char password[256];
  char database[256];
  char charset[256];
  int connect_timeout; /* 0 = unset, leave the libmysqlclient default */
} db_open_ctx_t;

static void db_open_work_cb(uv_work_t* req) {
  db_open_ctx_t* ctx = (db_open_ctx_t*)req->data;
  mysql_thread_init();

  /* pool_n is owned by after_cb (it bounds the library-ref release loops);
   * work_cb NEVER zeroes it. conns == NULL is the failure signal. */
  ctx->conns = lunet_alloc(sizeof(MYSQL*) * (size_t)ctx->pool_n);
  if (!ctx->conns) {
    snprintf(ctx->err, sizeof(ctx->err), "out of memory");
    mysql_thread_end();
    return;
  }
  memset(ctx->conns, 0, sizeof(MYSQL*) * (size_t)ctx->pool_n);

  for (int i = 0; i < ctx->pool_n; i++) {
    ctx->conns[i] = mysql_init(NULL);
    if (!ctx->conns[i]) {
      snprintf(ctx->err, sizeof(ctx->err), "mysql_init failed");
      for (int j = 0; j < i; j++) {
        mysql_close(ctx->conns[j]);
        ctx->conns[j] = NULL;
      }
      lunet_free_nonnull(ctx->conns);
      ctx->conns = NULL;
      mysql_thread_end();
      return;
    }

    mysql_options(ctx->conns[i], MYSQL_SET_CHARSET_NAME, ctx->charset);

    /* connect_timeout: seconds libmysqlclient waits before the connect
     * attempt fails. 0 leaves the library default untouched. */
    if (ctx->connect_timeout > 0) {
      unsigned int timeout = (unsigned int)ctx->connect_timeout;
      mysql_options(ctx->conns[i], MYSQL_OPT_CONNECT_TIMEOUT, &timeout);
    }

    if (!mysql_real_connect(ctx->conns[i], ctx->host, ctx->user, ctx->password,
                            ctx->database, ctx->port, NULL, 0)) {
      snprintf(ctx->err, sizeof(ctx->err), "%s", mysql_error(ctx->conns[i]));
      mysql_close(ctx->conns[i]);
      ctx->conns[i] = NULL;
      for (int j = 0; j < i; j++) {
        mysql_close(ctx->conns[j]);
        ctx->conns[j] = NULL;
      }
      lunet_free_nonnull(ctx->conns);
      ctx->conns = NULL;
      mysql_thread_end();
      return;
    }
  }
  mysql_thread_end();
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
        if (ctx->conns[i]) mysql_close(ctx->conns[i]);
        ctx->conns[i] = NULL;
      }
      lunet_free_nonnull(ctx->conns);
      ctx->conns = NULL;
    }
    /* Release exactly what the entry acquired; pool_n is still the
     * original count here (work_cb never zeroes it). */
    for (int i = 0; i < ctx->pool_n; i++) lunet_mysql_library_release();
    ctx->pool_n = 0;
    lunet_free_nonnull(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->conns) {
    /* Success shape: (pool handle, nil). Build the pool wrapper and hand
     * the raw connections over to it; each member holds one library ref. */
    lunet_mysql_pool_t* pool =
        (lunet_mysql_pool_t*)lua_newuserdata(co, sizeof(lunet_mysql_pool_t));
    pool->members = lunet_alloc(sizeof(lunet_mysql_conn_t*) * (size_t)ctx->pool_n);
    if (!pool->members) {
      pool->n = 0;
      pool->closed = 1;
      for (int i = 0; i < ctx->pool_n; i++) {
        if (ctx->conns[i]) mysql_close(ctx->conns[i]);
        ctx->conns[i] = NULL;
      }
      lunet_free_nonnull(ctx->conns);
      ctx->conns = NULL;
      for (int i = 0; i < ctx->pool_n; i++) lunet_mysql_library_release();
      ctx->pool_n = 0;
      lua_pushnil(co);
      lua_pushstring(co, "out of memory");
    } else {
      pool->n = ctx->pool_n;
      pool->next = 0;
      pool->closed = 0;
      for (int i = 0; i < pool->n; i++) {
        lunet_mysql_conn_t* member = lunet_alloc(sizeof(lunet_mysql_conn_t));
        memset(member, 0, sizeof(*member));
        member->conn = ctx->conns[i];
        member->library_ref_held = 1;
        uv_mutex_init(&member->mutex);
        pool->members[i] = member;
        ctx->conns[i] = NULL;
      }
      lunet_free_nonnull(ctx->conns);
      ctx->conns = NULL;
      ctx->pool_n = 0;
      luaL_getmetatable(co, LUNET_MYSQL_POOL_MT);
      lua_setmetatable(co, -2);
      lua_pushnil(co);
    }
  } else {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
    for (int i = 0; i < ctx->pool_n; i++) lunet_mysql_library_release();
    ctx->pool_n = 0;
  }
  int rc = lunet_co_resume(co, 2);
  if (rc != 0 && rc != LUA_YIELD) {
    const char* err = lua_tostring(co, -1);
    if (err) fprintf(stderr, "lua_resume error in db.open: %s\n", err);
    lua_pop(co, 1);
  }
  lunet_free_nonnull(ctx);
}

static int conn_gc(lua_State* L) {
  lunet_mysql_conn_t* wrapper = (lunet_mysql_conn_t*)luaL_checkudata(L, 1, LUNET_MYSQL_CONN_MT);
  lunet_mysql_conn_destroy(wrapper);
  return 0;
}

/* Full pool teardown: close every member (releasing its library ref),
 * destroy its mutex, free the array. */
static int pool_gc(lua_State* L) {
  lunet_mysql_pool_t* pool = (lunet_mysql_pool_t*)luaL_checkudata(L, 1, LUNET_MYSQL_POOL_MT);
  if (pool->members) {
    for (int i = 0; i < pool->n; i++) {
      if (pool->members[i]) {
        lunet_mysql_conn_destroy(pool->members[i]);
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
  if (luaL_newmetatable(L, LUNET_MYSQL_CONN_MT)) {
    lua_pushcfunction(L, conn_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_pop(L, 1);
  if (luaL_newmetatable(L, LUNET_MYSQL_POOL_MT)) {
    lua_pushcfunction(L, pool_gc);
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

static int bind_params(MYSQL_STMT* stmt, MYSQL_BIND* bind, param_t* params, int nparams, char* err, size_t errsize) {
    if (nparams > 0 && !params) {
        snprintf(err, errsize, "parameter collection failed");
        return 1;
    }
    
    memset(bind, 0, sizeof(MYSQL_BIND) * nparams);
    
    for (int i = 0; i < nparams; i++) {
        switch (params[i].type) {
            case PARAM_TYPE_NIL:
                bind[i].buffer_type = MYSQL_TYPE_NULL;
                break;
            case PARAM_TYPE_INT:
                bind[i].buffer_type = MYSQL_TYPE_LONGLONG;
                bind[i].buffer = (void*)&params[i].value.i;
                break;
            case PARAM_TYPE_DOUBLE:
                bind[i].buffer_type = MYSQL_TYPE_DOUBLE;
                bind[i].buffer = (void*)&params[i].value.d;
                break;
            case PARAM_TYPE_TEXT:
                bind[i].buffer_type = MYSQL_TYPE_STRING;
                bind[i].buffer = (void*)params[i].value.s.data;
                bind[i].buffer_length = params[i].value.s.len;
                break;
            default:
                snprintf(err, errsize, "unknown parameter type");
                return 1;
        }
    }
    
    if (mysql_stmt_bind_param(stmt, bind)) {
        snprintf(err, errsize, "mysql_stmt_bind_param failed: %s", mysql_stmt_error(stmt));
        return 1;
    }
    return 0;
}

int lunet_db_open(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.open")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 1 || !lua_istable(L, 1)) {
    lua_pushstring(L, "db.open requires params table");
    return lua_error(L);
  }
  if (lunet_mysql_library_acquire() != 0) {
    lua_pushstring(L, "db.open: mysql_library_init failed");
    return lua_error(L);
  }

  register_conn_metatable(L);

  db_open_ctx_t* ctx = lunet_alloc(sizeof(db_open_ctx_t));
  if (!ctx) {
    lunet_mysql_library_release();
    lua_pushnil(L);
    lua_pushstring(L, "db.open: out of memory");
    return lua_error(L);
  }
  memset(ctx->err, 0, sizeof(ctx->err));
  ctx->waiter_L = L;
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

  /* connect_timeout: seconds libmysqlclient waits before the connect
   * attempt fails. Unset leaves the library default untouched. */
  ctx->connect_timeout = 0;
  lua_getfield(L, 1, "connect_timeout");
  if (!lua_isnil(L, -1)) {
    if (!lua_isnumber(L, -1)) {
      lua_pop(L, 1);
      lunet_mysql_library_release();
      lunet_free_nonnull(ctx);
      lua_pushstring(L, "db.open: connect_timeout must be a number (seconds)");
      return lua_error(L);
    }
    ctx->connect_timeout = (int)lua_tointeger(L, -1);
    if (ctx->connect_timeout < 1) {
      lua_pop(L, 1);
      lunet_mysql_library_release();
      lunet_free_nonnull(ctx);
      lua_pushstring(L, "db.open: connect_timeout must be a positive integer (seconds)");
      return lua_error(L);
    }
  }
  lua_pop(L, 1);

  /* pool_size: how many connections sit behind the returned handle
   * (round-robin pick at dispatch). Default 1 — exactly one connection,
   * as before. Each pool member holds one mysql library ref, so top the
   * refcount up to pool_n; every failure path releases the full count. */
  ctx->pool_n = 1;
  lua_getfield(L, 1, "pool_size");
  if (!lua_isnil(L, -1)) {
    if (!lua_isnumber(L, -1)) {
      lua_pop(L, 1);
      lunet_mysql_library_release();
      lunet_free_nonnull(ctx);
      lua_pushstring(L, "db.open: pool_size must be a number");
      return lua_error(L);
    }
    ctx->pool_n = (int)lua_tointeger(L, -1);
    if (ctx->pool_n < 1 || ctx->pool_n > LUNET_MYSQL_POOL_MAX) {
      lua_pop(L, 1);
      lunet_mysql_library_release();
      lunet_free_nonnull(ctx);
      lua_pushstring(L, "db.open: pool_size must be between 1 and 64");
      return lua_error(L);
    }
  }
  lua_pop(L, 1);
  for (int i = 1; i < ctx->pool_n; i++) {
    if (lunet_mysql_library_acquire() != 0) {
      for (int j = 1; j < i; j++) lunet_mysql_library_release();
      lunet_mysql_library_release();
      lunet_free_nonnull(ctx);
      lua_pushstring(L, "db.open: mysql_library_init failed");
      return lua_error(L);
    }
  }

  lunet_coref_create(L, ctx->co_ref);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_open_work_cb, db_open_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lunet_free_nonnull(ctx);
    for (int i = 0; i < ctx->pool_n; i++) lunet_mysql_library_release();
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

  lunet_mysql_pool_t* pool = (lunet_mysql_pool_t*)luaL_testudata(L, 1, LUNET_MYSQL_POOL_MT);
  if (pool) {
    for (int i = 0; i < pool->n; i++) {
      if (pool->members[i]) lunet_mysql_conn_close(pool->members[i]);
    }
    pool->closed = 1;
    lua_pushnil(L);
    return 1;
  }

  lunet_mysql_conn_t* wrapper = (lunet_mysql_conn_t*)luaL_testudata(L, 1, LUNET_MYSQL_CONN_MT);
  if (!wrapper) {
    lua_pushstring(L, "db.close requires a valid connection");
    return 1;
  }

  uv_mutex_lock(&wrapper->mutex);
  lunet_mysql_conn_close(wrapper); /* Keep mutex intact until after unlock. */
  uv_mutex_unlock(&wrapper->mutex);

  lua_pushnil(L);
  return 1;
}

/* Resolve the statement target: a pool handle round-robins to its next
 * member; a bare connection handle is itself. Returns NULL for anything
 * else. The cursor is touched only on the loop thread, where every entry
 * point runs. */
static lunet_mysql_conn_t* pick_statement_target(lua_State* L, int idx) {
  lunet_mysql_pool_t* pool = (lunet_mysql_pool_t*)luaL_testudata(L, idx, LUNET_MYSQL_POOL_MT);
  if (pool) {
    if (!pool->members || pool->n < 1) return NULL;
    lunet_mysql_conn_t* member = pool->members[pool->next];
    pool->next = (pool->next + 1) % pool->n;
    return member; /* closed pools surface "connection is closed" downstream */
  }
  return (lunet_mysql_conn_t*)luaL_testudata(L, idx, LUNET_MYSQL_CONN_MT);
}

typedef struct {
  uv_work_t req;
  lua_State* waiter_L;
  int co_ref;

  lunet_mysql_conn_t* wrapper;
  char* query;

  /* When set, run against this already-prepared vendor statement (reset +
   * rebind + execute, no init/prepare/close per call). The valref pins the
   * statement userdata so it cannot be collected while the worker op is in
   * flight. */
  lunet_mysql_stmt_t* pstmt;
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

static void db_query_work_cb(uv_work_t* req) {
  db_query_ctx_t* ctx = (db_query_ctx_t*)req->data;

  uv_mutex_lock(&ctx->wrapper->mutex);

  mysql_thread_init();
  if (ctx->wrapper->closed || !ctx->wrapper->conn) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    mysql_thread_end();
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  /* mysql_stmt_close() belongs to the per-call-prepare path only: a
   * statement handle keeps its vendor statement alive across calls. */
  int owned = (ctx->pstmt == NULL);
  MYSQL_STMT* stmt;

  if (ctx->pstmt) {
    stmt = ctx->pstmt->stmt;
    if (!stmt) {
      snprintf(ctx->err, sizeof(ctx->err), "statement is closed");
      mysql_thread_end();
      uv_mutex_unlock(&ctx->wrapper->mutex);
      return;
    }
    mysql_stmt_free_result(stmt);
    mysql_stmt_reset(stmt);
  } else {
    // Use prepared statement
    stmt = mysql_stmt_init(ctx->wrapper->conn);
    if (!stmt) {
      snprintf(ctx->err, sizeof(ctx->err), "mysql_stmt_init failed: %s", mysql_error(ctx->wrapper->conn));
      mysql_thread_end();
      uv_mutex_unlock(&ctx->wrapper->mutex);
      return;
    }

    if (mysql_stmt_prepare(stmt, ctx->query, strlen(ctx->query))) {
      snprintf(ctx->err, sizeof(ctx->err), "mysql_stmt_prepare failed: %s", mysql_stmt_error(stmt));
      if (owned) mysql_stmt_close(stmt);
      mysql_thread_end();
      uv_mutex_unlock(&ctx->wrapper->mutex);
      return;
    }
  }

  unsigned long param_count = mysql_stmt_param_count(stmt);
  if (param_count != (unsigned long)ctx->nparams) {
    snprintf(ctx->err, sizeof(ctx->err), "parameter count mismatch: expected %lu, got %d", param_count, ctx->nparams);
    if (owned) mysql_stmt_close(stmt);
    mysql_thread_end();
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  MYSQL_BIND* bind = NULL;
  if (ctx->nparams > 0) {
      bind = lunet_alloc(sizeof(MYSQL_BIND) * ctx->nparams);
      if (!bind) {
          snprintf(ctx->err, sizeof(ctx->err), "out of memory");
          if (owned) mysql_stmt_close(stmt);
          mysql_thread_end();
          uv_mutex_unlock(&ctx->wrapper->mutex);
          return;
      }
      if (bind_params(stmt, bind, ctx->params, ctx->nparams, ctx->err, sizeof(ctx->err))) {
          lunet_free_nonnull(bind);
          if (owned) mysql_stmt_close(stmt);
          mysql_thread_end();
          uv_mutex_unlock(&ctx->wrapper->mutex);
          return;
      }
  }

  if (mysql_stmt_execute(stmt)) {
    snprintf(ctx->err, sizeof(ctx->err), "mysql_stmt_execute failed: %s", mysql_stmt_error(stmt));
    if (bind) lunet_free_nonnull(bind);
    if (owned) mysql_stmt_close(stmt);
    mysql_thread_end();
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  if (bind) lunet_free_nonnull(bind);

  // Store result to get metadata about fields and buffer everything
  if (mysql_stmt_store_result(stmt)) {
      snprintf(ctx->err, sizeof(ctx->err), "mysql_stmt_store_result failed: %s", mysql_stmt_error(stmt));
      if (owned) mysql_stmt_close(stmt);
      mysql_thread_end();
      uv_mutex_unlock(&ctx->wrapper->mutex);
      return;
  }

  MYSQL_RES* metadata = mysql_stmt_result_metadata(stmt);
  if (!metadata) {
      // No result set (e.g. UPDATE/INSERT)
      ctx->ncols = 0;
      ctx->nrows = 0;
      // Should we check if it was supposed to return result? 
      // mysql_stmt_field_count(stmt) would tell us.
      if (mysql_stmt_field_count(stmt) > 0) {
          snprintf(ctx->err, sizeof(ctx->err), "mysql_stmt_result_metadata failed: %s", mysql_stmt_error(stmt));
      }
      if (owned) mysql_stmt_close(stmt);
      mysql_thread_end();
      uv_mutex_unlock(&ctx->wrapper->mutex);
      return;
  }

  ctx->ncols = mysql_num_fields(metadata);
  MYSQL_FIELD* fields = mysql_fetch_fields(metadata);
  
  ctx->col_names = lunet_alloc(sizeof(char*) * ctx->ncols);
  ctx->col_types = lunet_alloc(sizeof(int) * ctx->ncols);
  MYSQL_BIND* result_bind = lunet_alloc(sizeof(MYSQL_BIND) * ctx->ncols);
  // Use char for is_null to match my_bool on older MySQL/MariaDB (char vs bool)
  char* is_null = lunet_alloc(sizeof(char) * ctx->ncols);
  unsigned long* length = lunet_alloc(sizeof(unsigned long) * ctx->ncols);
  
  if (!ctx->col_names || !ctx->col_types || !result_bind || !is_null || !length) {
      snprintf(ctx->err, sizeof(ctx->err), "out of memory");
      if (ctx->col_names) lunet_free_nonnull(ctx->col_names);
      if (ctx->col_types) lunet_free_nonnull(ctx->col_types);
      if (result_bind) lunet_free_nonnull(result_bind);
      if (is_null) lunet_free_nonnull(is_null);
      if (length) lunet_free_nonnull(length);
      mysql_free_result(metadata);
      if (owned) mysql_stmt_close(stmt);
      mysql_thread_end();
      uv_mutex_unlock(&ctx->wrapper->mutex);
      return;
  }
  
  memset(result_bind, 0, sizeof(MYSQL_BIND) * ctx->ncols);

  for (int i = 0; i < ctx->ncols; i++) {
      ctx->col_names[i] = lunet_strdup_local(fields[i].name);
      ctx->col_types[i] = fields[i].type;
      
      // Bind everything as string for simplicity, preserving type info in ctx->col_types
      result_bind[i].buffer_type = MYSQL_TYPE_STRING;
      // Use field length (declared column size) as it's more reliable than max_length
      // max_length can be 0 in some MariaDB configurations even after store_result
      unsigned long len = fields[i].length;
      if (len == 0) len = fields[i].max_length;
      if (len == 0) len = 255;  // Fallback for text columns without declared length
      // Cap at reasonable size to avoid huge allocations for TEXT/BLOB
      if (len > 65535) len = 65535;
      result_bind[i].buffer_length = len + 1;
      result_bind[i].buffer = lunet_alloc(result_bind[i].buffer_length);
      result_bind[i].is_null = &is_null[i];
      result_bind[i].length = &length[i];
      
      if (!result_bind[i].buffer) {
          snprintf(ctx->err, sizeof(ctx->err), "out of memory");
          // cleanup
          for (int j = 0; j <= i; j++) {
              if (result_bind[j].buffer) lunet_free_nonnull(result_bind[j].buffer);
              if (j < i) lunet_free_nonnull(ctx->col_names[j]);
          }
          lunet_free_nonnull(ctx->col_names);
          lunet_free_nonnull(ctx->col_types);
          lunet_free_nonnull(result_bind);
          lunet_free_nonnull(is_null);
          lunet_free_nonnull(length);
          mysql_free_result(metadata);
          if (owned) mysql_stmt_close(stmt);
          mysql_thread_end();
          uv_mutex_unlock(&ctx->wrapper->mutex);
          return;
      }
  }

  if (mysql_stmt_bind_result(stmt, result_bind)) {
      snprintf(ctx->err, sizeof(ctx->err), "mysql_stmt_bind_result failed: %s", mysql_stmt_error(stmt));
       for (int i = 0; i < ctx->ncols; i++) {
          lunet_free_nonnull(result_bind[i].buffer);
          lunet_free_nonnull(ctx->col_names[i]);
      }
      lunet_free_nonnull(ctx->col_names);
      lunet_free_nonnull(ctx->col_types);
      lunet_free_nonnull(result_bind);
      lunet_free_nonnull(is_null);
      lunet_free_nonnull(length);
      mysql_free_result(metadata);
      if (owned) mysql_stmt_close(stmt);
      mysql_thread_end();
      uv_mutex_unlock(&ctx->wrapper->mutex);
      return;
  }

  // Fetch rows
  int capacity = 16;
  ctx->rows = lunet_alloc(sizeof(char**) * capacity);
  if (!ctx->rows) {
      // cleanup ... (omitted for brevity, assume critical failure)
      // Just set error and return, memory leak in edge case
      snprintf(ctx->err, sizeof(ctx->err), "out of memory");
  } else {
      ctx->nrows = 0;
      while (mysql_stmt_fetch(stmt) == 0) {
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
          
          for (int i = 0; i < ctx->ncols; i++) {
              if (is_null[i]) {
                  row[i] = NULL;
              } else {
                  row[i] = lunet_strdup_local((char*)result_bind[i].buffer);
              }
          }
          ctx->rows[ctx->nrows++] = row;
      }
  }

  // Cleanup result bindings
  for (int i = 0; i < ctx->ncols; i++) {
      lunet_free_nonnull(result_bind[i].buffer);
  }
  lunet_free_nonnull(result_bind);
  lunet_free_nonnull(is_null);
  lunet_free_nonnull(length);
  
  mysql_free_result(metadata);
  if (owned) mysql_stmt_close(stmt);
  mysql_thread_end();
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
    goto cleanup;
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
      if (err) fprintf(stderr, "lua_resume error in db.query: %s\n", err);
      lua_pop(co, 1);
    }
  } else {
      lua_newtable(co);
      int row_idx = 1;
      
      for (int i = 0; i < ctx->nrows; i++) {
          lua_newtable(co);
          for (int j = 0; j < ctx->ncols; j++) {
              lua_pushstring(co, ctx->col_names[j]);
              if (ctx->rows[i][j] == NULL) {
                  lua_pushnil(co);
              } else {
                  int type = ctx->col_types[j];
                  switch (type) {
                      case MYSQL_TYPE_TINY:
                      case MYSQL_TYPE_SHORT:
                      case MYSQL_TYPE_LONG:
                      case MYSQL_TYPE_INT24:
                      case MYSQL_TYPE_LONGLONG:
                          lua_pushinteger(co, strtoll(ctx->rows[i][j], NULL, 10));
                          break;
                      case MYSQL_TYPE_FLOAT:
                      case MYSQL_TYPE_DOUBLE:
                      case MYSQL_TYPE_DECIMAL:
                          lua_pushnumber(co, strtod(ctx->rows[i][j], NULL));
                          break;
                      default:
                          lua_pushstring(co, ctx->rows[i][j]);
                          break;
                  }
              }
              lua_settable(co, -3);
          }
          lua_rawseti(co, -2, row_idx++);
      }
      
      lua_pushnil(co);
      int rc = lunet_co_resume(co, 2);
      if (rc != 0 && rc != LUA_YIELD) {
          const char* err = lua_tostring(co, -1);
          if (err) fprintf(stderr, "lua_resume error in db.query: %s\n", err);
          lua_pop(co, 1);
      }
  }

cleanup:
  if (ctx->rows) {
      for (int i = 0; i < ctx->nrows; i++) {
          for (int j = 0; j < ctx->ncols; j++) {
              lunet_free_nonnull(ctx->rows[i][j]);
          }
          lunet_free_nonnull(ctx->rows[i]);
      }
      lunet_free_nonnull(ctx->rows);
  }
  if (ctx->col_names) {
      for (int i = 0; i < ctx->ncols; i++) lunet_free_nonnull(ctx->col_names[i]);
      lunet_free_nonnull(ctx->col_names);
  }
  if (ctx->col_types) lunet_free_nonnull(ctx->col_types);
  
  lunet_free_nonnull(ctx->query);
  free_params(ctx->params, ctx->nparams);
  lunet_free_nonnull(ctx);
}

int lunet_db_query(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.query")) {
    return lua_error(L);
  }
  
  int n = lua_gettop(L);
  if (n < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "db.query requires connection and sql string");
    return 2;
  }

  lunet_mysql_conn_t* wrapper = pick_statement_target(L, 1);
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

  lunet_mysql_conn_t* wrapper;
  char* query;

  lunet_mysql_stmt_t* pstmt;
  int stmt_valref;

  param_t* params;
  int nparams;

  int affected_rows;
  unsigned long long insert_id;
  char err[256];
} db_exec_ctx_t;

static void db_exec_work_cb(uv_work_t* req) {
  db_exec_ctx_t* ctx = (db_exec_ctx_t*)req->data;

  uv_mutex_lock(&ctx->wrapper->mutex);

  mysql_thread_init();
  if (ctx->wrapper->closed || !ctx->wrapper->conn) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    mysql_thread_end();
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  int owned = (ctx->pstmt == NULL);
  MYSQL_STMT* stmt;

  if (ctx->pstmt) {
    stmt = ctx->pstmt->stmt;
    if (!stmt) {
      snprintf(ctx->err, sizeof(ctx->err), "statement is closed");
      mysql_thread_end();
      uv_mutex_unlock(&ctx->wrapper->mutex);
      return;
    }
    mysql_stmt_free_result(stmt);
    mysql_stmt_reset(stmt);
  } else {
    // Use prepared statement
    stmt = mysql_stmt_init(ctx->wrapper->conn);
    if (!stmt) {
      snprintf(ctx->err, sizeof(ctx->err), "mysql_stmt_init failed: %s", mysql_error(ctx->wrapper->conn));
      mysql_thread_end();
      uv_mutex_unlock(&ctx->wrapper->mutex);
      return;
    }

    if (mysql_stmt_prepare(stmt, ctx->query, strlen(ctx->query))) {
      snprintf(ctx->err, sizeof(ctx->err), "mysql_stmt_prepare failed: %s", mysql_stmt_error(stmt));
      mysql_stmt_close(stmt);
      mysql_thread_end();
      uv_mutex_unlock(&ctx->wrapper->mutex);
      return;
    }
  }

  unsigned long param_count = mysql_stmt_param_count(stmt);
  if (param_count != (unsigned long)ctx->nparams) {
    snprintf(ctx->err, sizeof(ctx->err), "parameter count mismatch: expected %lu, got %d", param_count, ctx->nparams);
    if (owned) mysql_stmt_close(stmt);
    mysql_thread_end();
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  MYSQL_BIND* bind = NULL;
  if (ctx->nparams > 0) {
      bind = lunet_alloc(sizeof(MYSQL_BIND) * ctx->nparams);
      if (!bind) {
          snprintf(ctx->err, sizeof(ctx->err), "out of memory");
          if (owned) mysql_stmt_close(stmt);
          mysql_thread_end();
          uv_mutex_unlock(&ctx->wrapper->mutex);
          return;
      }

      if (bind_params(stmt, bind, ctx->params, ctx->nparams, ctx->err, sizeof(ctx->err))) {
          lunet_free_nonnull(bind);
          if (owned) mysql_stmt_close(stmt);
          mysql_thread_end();
          uv_mutex_unlock(&ctx->wrapper->mutex);
          return;
      }
  }

  if (mysql_stmt_execute(stmt)) {
    snprintf(ctx->err, sizeof(ctx->err), "mysql_stmt_execute failed: %s", mysql_stmt_error(stmt));
    if (bind) lunet_free_nonnull(bind);
    if (owned) mysql_stmt_close(stmt);
    mysql_thread_end();
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  if (bind) lunet_free_nonnull(bind);

  ctx->affected_rows = mysql_stmt_affected_rows(stmt);
  ctx->insert_id = mysql_stmt_insert_id(stmt);

  if (owned) mysql_stmt_close(stmt);
  mysql_thread_end();
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
  
  int n = lua_gettop(L);
  if (n < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "db.exec requires connection and sql string");
    return 2;
  }

  lunet_mysql_conn_t* wrapper = pick_statement_target(L, 1);
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

// Helper function to count parameters in SQL string
static int count_params(const char* sql) {
  int count = 0;
  for (const char* p = sql; *p; p++) {
    if (*p == '?') count++;
  }
  return count;
}

// New query function with parameter support
int lunet_db_query_params(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.query")) {
    return lua_error(L);
  }
  
  int n = lua_gettop(L);
  if (n < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "db.query requires connection and sql string");
    return 2;
  }
  
  lunet_mysql_conn_t* wrapper = pick_statement_target(L, 1);
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

// New exec function with parameter support
int lunet_db_exec_params(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.exec")) {
    return lua_error(L);
  }
  
  int n = lua_gettop(L);
  if (n < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "db.exec requires connection and sql string");
    return 2;
  }
  
  lunet_mysql_conn_t* wrapper = pick_statement_target(L, 1);
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
 * db.prepare(handle, sql) hands back a reusable statement handle: the
 * vendor statement is created once and kept, each stmt:query / stmt:exec
 * call resets + rebinds + executes it, and stmt:close() releases it. One
 * statement is bound to one pool member — prepare on a pooled handle
 * therefore requires pool_size = 1. A second call while one is in flight
 * fails loudly ("statement is busy") instead of surfacing as
 * CR_COMMANDS_OUT_OF_SYNC.
 * ========================================================================== */

static int stmt_gc(lua_State* L) {
  lunet_mysql_stmt_t* s = (lunet_mysql_stmt_t*)luaL_checkudata(L, 1, LUNET_MYSQL_STMT_MT);
  if (s->closed || !s->member) return 0;
  /* The busy flag can only be set while a valref pins this userdata, so
   * GC can never observe it. */
  uv_mutex_lock(&s->member->mutex);
  if (!s->closed && s->stmt) {
    mysql_stmt_close(s->stmt);
    s->stmt = NULL;
    s->closed = 1;
    conn_untrack_stmt(s->member, s);
  }
  uv_mutex_unlock(&s->member->mutex);
  return 0;
}

static int stmt_close(lua_State* L) {
  if (lunet_ensure_coroutine(L, "stmt:close")) {
    return lua_error(L);
  }
  lunet_mysql_stmt_t* s = (lunet_mysql_stmt_t*)luaL_testudata(L, 1, LUNET_MYSQL_STMT_MT);
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
  uv_mutex_lock(&s->member->mutex);
  if (!s->closed && s->stmt) {
    mysql_stmt_close(s->stmt);
    s->stmt = NULL;
    s->closed = 1;
    conn_untrack_stmt(s->member, s);
  } else {
    s->closed = 1;
  }
  uv_mutex_unlock(&s->member->mutex);
  lua_pushnil(L);
  return 1;
}

/* Shared body of stmt:query / stmt:exec: validate the handle, bind the
 * varargs (same binding semantics as query_params/exec_params), pin the
 * userdata, and queue the worker op on the statement's own connection. */
static int stmt_dispatch(lua_State* L, int is_exec) {
  lunet_mysql_stmt_t* s = (lunet_mysql_stmt_t*)luaL_testudata(L, 1, LUNET_MYSQL_STMT_MT);
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
  if (luaL_newmetatable(L, LUNET_MYSQL_STMT_MT)) {
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
  lunet_mysql_stmt_t* target;
  char* sql;

  char err[256];
} db_prepare_ctx_t;

static void db_prepare_work_cb(uv_work_t* req) {
  db_prepare_ctx_t* ctx = (db_prepare_ctx_t*)req->data;
  lunet_mysql_stmt_t* s = ctx->target;

  uv_mutex_lock(&s->member->mutex);
  mysql_thread_init();
  if (s->member->closed || !s->member->conn) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    mysql_thread_end();
    uv_mutex_unlock(&s->member->mutex);
    return;
  }
  MYSQL_STMT* stmt = mysql_stmt_init(s->member->conn);
  if (!stmt) {
    snprintf(ctx->err, sizeof(ctx->err), "mysql_stmt_init failed: %s",
             mysql_error(s->member->conn));
    mysql_thread_end();
    uv_mutex_unlock(&s->member->mutex);
    return;
  }
  if (mysql_stmt_prepare(stmt, ctx->sql, strlen(ctx->sql))) {
    snprintf(ctx->err, sizeof(ctx->err), "mysql_stmt_prepare failed: %s",
             mysql_stmt_error(stmt));
    mysql_stmt_close(stmt);
    mysql_thread_end();
    uv_mutex_unlock(&s->member->mutex);
    return;
  }
  s->stmt = stmt;
  mysql_thread_end();
  uv_mutex_unlock(&s->member->mutex);
}

/* Mark a not-yet-usable statement closed and take it off the connection's
 * open list (loop thread; lock held by the caller where required). */
static void prepare_discard(lunet_mysql_stmt_t* s) {
  s->stmt = NULL;
  s->closed = 1;
  if (s->member) conn_untrack_stmt(s->member, s);
}

static void db_prepare_after_cb(uv_work_t* req, int status) {
  db_prepare_ctx_t* ctx = (db_prepare_ctx_t*)req->data;
  lua_State* L = ctx->waiter_L;
  lunet_mysql_stmt_t* s = ctx->target;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.prepare\n");
    lunet_valref_release(L, ctx->ud_ref);
    if (s->stmt && s->member) {
      uv_mutex_lock(&s->member->mutex);
      mysql_stmt_close(s->stmt);
      prepare_discard(s);
      uv_mutex_unlock(&s->member->mutex);
    } else {
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
    uv_mutex_lock(&s->member->mutex);
    prepare_discard(s);
    uv_mutex_unlock(&s->member->mutex);
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
  lunet_mysql_pool_t* pool = (lunet_mysql_pool_t*)luaL_testudata(L, 1, LUNET_MYSQL_POOL_MT);
  if (pool && pool->n > 1) {
    lua_pushnil(L);
    lua_pushstring(L, "db.prepare requires pool_size = 1 (a statement is bound to one connection)");
    return 2;
  }

  lunet_mysql_conn_t* wrapper = pick_statement_target(L, 1);
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

  lunet_mysql_stmt_t* s =
      (lunet_mysql_stmt_t*)lua_newuserdata(L, sizeof(lunet_mysql_stmt_t));
  memset(s, 0, sizeof(*s));
  s->member = wrapper;
  luaL_getmetatable(L, LUNET_MYSQL_STMT_MT);
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

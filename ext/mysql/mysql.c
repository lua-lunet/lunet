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
#if !defined(MYSQL_VERSION_ID)
#  error "lunet mysql driver requires a client library that reports MYSQL_VERSION_ID (mysqlclient >= 8.0 or libmariadb >= 3.4)"
#endif
/* The two client libraries share the MAJOR*10000+MINOR*100+PATCH id scheme
 * but not a version history: mysqlclient 8.0 = 80000, libmariadb 3.4 =
 * 30400. libmariadb additionally defines MARIADB_VERSION_ID, which is
 * how the floor is picked. The floor prunes legacy option surface
 * (MYSQL_OPT_SSL_VERIFY_SERVER_CERT and MYSQL_OPT_SSL_ENFORCE were both
 * removed in 8.0) without cutting off older servers: libmysqlclient keeps
 * cipher support for prior server versions and Connector/C is compatible
 * with all MariaDB and MySQL servers. */
#if defined(MARIADB_VERSION_ID)
/* libmariadb reports two different version schemes: MYSQL_VERSION_ID is the
 * server version (e.g. 101114 for MariaDB 10.11) while MARIADB_PACKAGE_
 * VERSION_ID is the Connector/C package version (e.g. 30317 for 3.3.17).
 * The floor is on the package (client library) version, so check that. */
#  if !defined(MARIADB_PACKAGE_VERSION_ID) || MARIADB_PACKAGE_VERSION_ID < 30400
#    error "lunet mysql driver requires libmariadb >= 3.4 (MARIADB_PACKAGE_VERSION_ID < 30400)"
#  endif
#else
#  if MYSQL_VERSION_ID < 80000
#    error "lunet mysql driver requires mysqlclient >= 8.0"
#  endif
#endif
/* MYSQL_BIND.is_null is `my_bool*` (my_bool = char) in libmariadb and
 * `bool*` in Oracle libmysqlclient 8.0+. Use a family-aware alias so the
 * allocation matches the field type exactly on both, avoiding the
 * incompatible-pointer-types warning on the Oracle side. */
#ifdef MARIADB_VERSION_ID
typedef my_bool lunet_mysql_bool;
#else
typedef bool lunet_mysql_bool;
#endif
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
struct lunet_mysql_pool_s;

typedef struct lunet_mysql_conn_s {
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
  /* Exclusive-checkout support: a userdata created by checkout() is a
   * VIEW over one member of a pool — it never owns the member, never
   * closes it, and never destroys its mutex; release (or GC) just clears
   * the member's checked_out flag. A plain member has is_view == 0. */
  int is_view;
  int checked_out; /* meaningful on a member: 1 while checked out */
  struct lunet_mysql_conn_s* member; /* meaningful on a view: the member it is bound to */
  struct lunet_mysql_pool_s* owner; /* the pool a view belongs to (NULL for members) */
  int pool_ref; /* strong registry ref pinning the pool userdata while a view lives */
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
typedef struct lunet_mysql_pool_s {
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

  /* TLS passthrough (open-time keys, mirroring the postgres sslmode
   * design): an empty string means unset and leaves the vendor default
   * untouched. ssl_mode / ssl_verify_server_cert are -1 when unset and are
   * family-gated — setting either on the family that lacks the option is a
   * loud open-time error (see lunet_db_open). */
  char ssl_ca[512];
  char ssl_capath[512];
  char ssl_cert[512];
  char ssl_key[512];
  char ssl_cipher[512];
  char ssl_crl[512];
  char ssl_crlpath[512];
  char tls_version[64];
  int ssl_mode;
  int ssl_verify_server_cert;
} db_open_ctx_t;

/* Loud-error path shared by every TLS key: pop the field, release the
 * library ref, free the open context, raise. The connect_timeout and
 * pool_size guards in lunet_db_open spell this out inline; here it is one
 * helper because there are ten keys and every failure is fatal before any
 * connection exists. */
static int db_open_tls_fail(lua_State* L, db_open_ctx_t* ctx, const char* msg) {
  lunet_mysql_library_release();
  lunet_free_nonnull(ctx);
  lua_pushstring(L, msg);
  return lua_error(L);
}

/* tls_version whitelist: exactly the TLSv1.2 / TLSv1.3 atoms, optionally
 * comma-separated ("TLSv1.2,TLSv1.3"). Each atom is matched exactly — no
 * whitespace trimming — so "TLSv1.2, TLSv1.3" fails loudly. */
static int tls_version_atom_valid(const char* atom, size_t len) {
  return len == 7 &&
         (strncmp(atom, "TLSv1.2", len) == 0 || strncmp(atom, "TLSv1.3", len) == 0);
}

static int tls_version_valid(const char* s) {
  const char* p = s;
  for (;;) {
    const char* comma = strchr(p, ',');
    size_t len = comma ? (size_t)(comma - p) : strlen(p);
    if (!tls_version_atom_valid(p, len)) return 0;
    if (!comma) return 1;
    p = comma + 1;
  }
}

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

    /* TLS passthrough, applied before mysql_real_connect so every option
     * governs the handshake itself (same doctrine as connect_timeout).
     * Order: tls_version, then the family-gated mode/verify flag, then the
     * path/cipher options. Empty keys were left unset at open and stay
     * untouched here. */
    if (ctx->tls_version[0] != '\0') {
#ifdef MARIADB_VERSION_ID
      mysql_options(ctx->conns[i], MARIADB_OPT_TLS_VERSION, ctx->tls_version);
#else
      mysql_options(ctx->conns[i], MYSQL_OPT_TLS_VERSION, ctx->tls_version);
#endif
    }

#ifdef MARIADB_VERSION_ID
    if (ctx->ssl_verify_server_cert >= 0) {
      my_bool verify = (my_bool)ctx->ssl_verify_server_cert;
      mysql_options(ctx->conns[i], MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &verify);
    }
#else
    if (ctx->ssl_mode >= 0) {
      unsigned int mode = (unsigned int)ctx->ssl_mode;
      mysql_options(ctx->conns[i], MYSQL_OPT_SSL_MODE, &mode);
    }
#endif

    if (ctx->ssl_ca[0] != '\0')
      mysql_options(ctx->conns[i], MYSQL_OPT_SSL_CA, ctx->ssl_ca);
    if (ctx->ssl_capath[0] != '\0')
      mysql_options(ctx->conns[i], MYSQL_OPT_SSL_CAPATH, ctx->ssl_capath);
    if (ctx->ssl_cert[0] != '\0')
      mysql_options(ctx->conns[i], MYSQL_OPT_SSL_CERT, ctx->ssl_cert);
    if (ctx->ssl_key[0] != '\0')
      mysql_options(ctx->conns[i], MYSQL_OPT_SSL_KEY, ctx->ssl_key);
    if (ctx->ssl_cipher[0] != '\0')
      mysql_options(ctx->conns[i], MYSQL_OPT_SSL_CIPHER, ctx->ssl_cipher);
    if (ctx->ssl_crl[0] != '\0')
      mysql_options(ctx->conns[i], MYSQL_OPT_SSL_CRL, ctx->ssl_crl);
    if (ctx->ssl_crlpath[0] != '\0')
      mysql_options(ctx->conns[i], MYSQL_OPT_SSL_CRLPATH, ctx->ssl_crlpath);

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
        member->is_view = 0;
        member->checked_out = 0;
        member->owner = NULL;
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
  if (wrapper->is_view) {
    /* Release the member back into the rotation if it is still checked
     * out; the pool owns the member and closes it at pool close. Never
     * close/free here. Already-released (closed) views are a no-op. */
    if (!wrapper->closed && wrapper->owner && !wrapper->owner->closed &&
        wrapper->member && wrapper->member->checked_out) {
      wrapper->member->checked_out = 0;
    }
    if (wrapper->pool_ref) {
      lunet_valref_release(L, wrapper->pool_ref);
      wrapper->pool_ref = 0;
    }
    wrapper->member = NULL;
    wrapper->owner = NULL;
    wrapper->closed = 1;
    return 0;
  }
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

  /* TLS passthrough, read + validated BEFORE pool_size and before any
   * connection exists: wrong types and non-whitelisted values fail loudly
   * here, never silently. Empty/absent keys leave the vendor default
   * untouched (connect_timeout doctrine). */
  ctx->ssl_mode = -1;
  ctx->ssl_verify_server_cert = -1;

  /* String path/cipher keys — present only when a string, copied only when
   * it fits. */
  const struct {
    const char* key;
    char* dest;
    size_t dest_size;
  } tls_path_keys[] = {
      {"ssl_ca", ctx->ssl_ca, sizeof(ctx->ssl_ca)},
      {"ssl_capath", ctx->ssl_capath, sizeof(ctx->ssl_capath)},
      {"ssl_cert", ctx->ssl_cert, sizeof(ctx->ssl_cert)},
      {"ssl_key", ctx->ssl_key, sizeof(ctx->ssl_key)},
      {"ssl_cipher", ctx->ssl_cipher, sizeof(ctx->ssl_cipher)},
      {"ssl_crl", ctx->ssl_crl, sizeof(ctx->ssl_crl)},
      {"ssl_crlpath", ctx->ssl_crlpath, sizeof(ctx->ssl_crlpath)},
  };
  for (size_t k = 0; k < sizeof(tls_path_keys) / sizeof(tls_path_keys[0]); k++) {
    lua_getfield(L, 1, tls_path_keys[k].key);
    int t = lua_type(L, -1);
    if (t == LUA_TNIL) {
      /* unset: leave the vendor default untouched */
    } else if (t == LUA_TSTRING) {
      size_t len;
      const char* s = lua_tolstring(L, -1, &len);
      if (len >= tls_path_keys[k].dest_size) {
        lua_pop(L, 1);
        char msg[128];
        snprintf(msg, sizeof(msg), "db.open: %s is too long (max %d bytes)",
                 tls_path_keys[k].key, (int)tls_path_keys[k].dest_size - 1);
        return db_open_tls_fail(L, ctx, msg);
      }
      snprintf(tls_path_keys[k].dest, tls_path_keys[k].dest_size, "%s", s);
    } else {
      lua_pop(L, 1);
      char msg[128];
      snprintf(msg, sizeof(msg), "db.open: %s must be a string",
               tls_path_keys[k].key);
      return db_open_tls_fail(L, ctx, msg);
    }
    lua_pop(L, 1);
  }

  /* tls_version: whitelist exactly TLSv1.2 / TLSv1.3, comma-separated
   * combinations of those atoms allowed ("TLSv1.2,TLSv1.3"). Applied to
   * the vendor option named by the compile-time family below. */
  lua_getfield(L, 1, "tls_version");
  if (!lua_isnil(L, -1)) {
    if (lua_type(L, -1) != LUA_TSTRING) {
      lua_pop(L, 1);
      return db_open_tls_fail(L, ctx, "db.open: tls_version must be a string");
    }
    const char* s = lua_tostring(L, -1);
    if (strlen(s) >= sizeof(ctx->tls_version)) {
      lua_pop(L, 1);
      return db_open_tls_fail(L, ctx,
                              "db.open: tls_version is too long (max 63 bytes)");
    }
    if (!tls_version_valid(s)) {
      lua_pop(L, 1);
      return db_open_tls_fail(
          L, ctx,
          "db.open: tls_version must be TLSv1.2 and/or TLSv1.3 (comma-separated, no spaces)");
    }
    snprintf(ctx->tls_version, sizeof(ctx->tls_version), "%s", s);
  }
  lua_pop(L, 1);

  /* ssl_mode: an Oracle libmysqlclient 8.0 option
   * (MYSQL_OPT_SSL_MODE / SSL_MODE_DISABLED..SSL_MODE_VERIFY_IDENTITY).
   * It does not exist in MariaDB Connector/C — if set there, fail loudly
   * naming the fact instead of silently dropping it. */
  lua_getfield(L, 1, "ssl_mode");
  if (!lua_isnil(L, -1)) {
    if (lua_type(L, -1) != LUA_TSTRING) {
      lua_pop(L, 1);
      return db_open_tls_fail(L, ctx,
                              "db.open: ssl_mode must be a string");
    }
#ifdef MARIADB_VERSION_ID
    lua_pop(L, 1);
    return db_open_tls_fail(
        L, ctx,
        "db.open: ssl_mode is not a MariaDB Connector/C option (Oracle libmysqlclient only); use ssl_verify_server_cert instead");
#else
    static const struct {
      const char* name;
      int value;
    } ssl_modes[] = {
        {"disabled", SSL_MODE_DISABLED},
        {"prefer", SSL_MODE_PREFERRED},
        {"require", SSL_MODE_REQUIRED},
        {"verify_ca", SSL_MODE_VERIFY_CA},
        {"verify_identity", SSL_MODE_VERIFY_IDENTITY},
    };
    const char* s = lua_tostring(L, -1);
    int matched = -1;
    for (size_t k = 0; k < sizeof(ssl_modes) / sizeof(ssl_modes[0]); k++) {
      if (strcmp(s, ssl_modes[k].name) == 0) {
        matched = ssl_modes[k].value;
        break;
      }
    }
    if (matched < 0) {
      lua_pop(L, 1);
      return db_open_tls_fail(
          L, ctx,
          "db.open: ssl_mode must be one of disabled, prefer, require, verify_ca, verify_identity");
    }
    ctx->ssl_mode = matched;
#endif
  }
  lua_pop(L, 1);

  /* ssl_verify_server_cert: the MariaDB counterpart (my_bool via
   * MYSQL_OPT_SSL_VERIFY_SERVER_CERT; Connector/C 3.4 verifies by default —
   * the key is how to turn it OFF). Removed from Oracle libmysqlclient 8.0,
   * so if set there, fail loudly naming the fact. */
  lua_getfield(L, 1, "ssl_verify_server_cert");
  if (!lua_isnil(L, -1)) {
    if (lua_type(L, -1) != LUA_TBOOLEAN) {
      lua_pop(L, 1);
      return db_open_tls_fail(L, ctx,
                              "db.open: ssl_verify_server_cert must be a boolean");
    }
#ifndef MARIADB_VERSION_ID
    lua_pop(L, 1);
    return db_open_tls_fail(
        L, ctx,
        "db.open: ssl_verify_server_cert is not an Oracle libmysqlclient 8.0 option (removed at the 8.0 floor); use ssl_mode instead");
#else
    ctx->ssl_verify_server_cert = lua_toboolean(L, -1) ? 1 : 0;
#endif
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
  if (wrapper->is_view) {
    /* A checked-out member is released, not closed: the pool owns the
     * member and closes it at pool close. */
    lunet_mysql_pool_t* owner = (lunet_mysql_pool_t*)wrapper->owner;
    if (owner && !owner->closed && wrapper->member &&
        wrapper->member->checked_out) {
      wrapper->member->checked_out = 0;
    }
    if (wrapper->pool_ref) {
      lunet_valref_release(L, wrapper->pool_ref);
      wrapper->pool_ref = 0;
    }
    wrapper->member = NULL;
    wrapper->owner = NULL;
    wrapper->closed = 1;
    lua_pushnil(L);
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
    /* Round-robin, skipping members that are currently checked out. */
    int start = pool->next;
    do {
      lunet_mysql_conn_t* member = pool->members[pool->next];
      pool->next = (pool->next + 1) % pool->n;
      if (member && !member->checked_out) {
        return member;
      }
    } while (pool->next != start);
    /* Every member is checked out: exhaustion, surfaced by the caller. */
    return NULL;
  }
  lunet_mysql_conn_t* conn = (lunet_mysql_conn_t*)luaL_testudata(L, idx, LUNET_MYSQL_CONN_MT);
  if (conn && conn->is_view && conn->member) {
    return conn->member;
  }
  return conn;
}

/* Exclusive checkout: take one member out of the round-robin rotation
 * for as long as the caller holds the returned conn handle. The member is
 * never closed by the conn handle (the pool owns it). */
int lunet_db_checkout(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.checkout")) {
    return lua_error(L);
  }
  lunet_mysql_pool_t* pool = (lunet_mysql_pool_t*)luaL_testudata(L, 1, LUNET_MYSQL_POOL_MT);
  if (!pool) {
    lua_pushstring(L, "db.checkout requires a connection pool");
    return lua_error(L);
  }
  if (pool->closed || !pool->members || pool->n < 1) {
    lua_pushnil(L);
    lua_pushstring(L, "connection is closed");
    return 2;
  }
  /* Find a member that is not checked out. */
  lunet_mysql_conn_t* member = NULL;
  for (int i = 0; i < pool->n; i++) {
    if (pool->members[i] && !pool->members[i]->checked_out) {
      member = pool->members[i];
      break;
    }
  }
  if (!member) {
    lua_pushnil(L);
    lua_pushstring(L, "pool exhausted: all members are checked out");
    return 2;
  }
  member->checked_out = 1;

  /* Create a conn userdata that is a VIEW over this member. */
  lunet_mysql_conn_t* view =
      (lunet_mysql_conn_t*)lua_newuserdata(L, sizeof(lunet_mysql_conn_t));
  memset(view, 0, sizeof(*view));
  /* Views carry NO connection/mutex of their own: dispatch resolves them
   * to their member. Copying the mutex by value is a landmine and copying
   * the MYSQL* dangles after pool close. */
  view->closed = 0;
  view->stmts = NULL;
  view->is_view = 1;
  view->checked_out = 0;
  view->member = member;
  view->owner = pool;
  view->pool_ref = 0;
  luaL_getmetatable(L, LUNET_MYSQL_CONN_MT);
  lua_setmetatable(L, -2);
  /* Pin the pool userdata so a view can never outlive its pool: the
   * pool's members (and its Lua userdata) stay alive as long as any
   * view is alive. Released in release()/conn_gc()/db.close(). */
  lua_pushvalue(L, 1);
  lunet_valref_create_raw(L, view->pool_ref);

  lua_pushnil(L);
  return 2;
}

/* Liveness probe: one worker hop, mysql_ping under the member mutex. The
 * driver never sets MYSQL_OPT_RECONNECT, so a dead session reports dead —
 * mysql_ping does not silently resurrect it. */
typedef struct {
  uv_work_t req;
  lua_State* waiter_L;
  int co_ref;
  lunet_mysql_conn_t* wrapper;
  char err[256];
} db_ping_ctx_t;

static void db_ping_work_cb(uv_work_t* req) {
  db_ping_ctx_t* ctx = (db_ping_ctx_t*)req->data;

  uv_mutex_lock(&ctx->wrapper->mutex);
  mysql_thread_init();
  if (ctx->wrapper->closed || !ctx->wrapper->conn) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    mysql_thread_end();
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }
  if (mysql_ping(ctx->wrapper->conn) != 0) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", mysql_error(ctx->wrapper->conn));
  }
  mysql_thread_end();
  uv_mutex_unlock(&ctx->wrapper->mutex);
}

static void db_ping_after_cb(uv_work_t* req, int status) {
  db_ping_ctx_t* ctx = (db_ping_ctx_t*)req->data;
  lua_State* L = ctx->waiter_L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.ping\n");
    lunet_free_nonnull(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->err[0] != '\0') {
    lua_pushboolean(co, 0);
    lua_pushstring(co, ctx->err);
  } else {
    lua_pushboolean(co, 1);
    lua_pushnil(co);
  }
  int rc = lunet_co_resume(co, 2);
  if (rc != 0 && rc != LUA_YIELD) {
    const char* err = lua_tostring(co, -1);
    if (err) fprintf(stderr, "lua_resume error in db.ping: %s\n", err);
    lua_pop(co, 1);
  }
  lunet_free_nonnull(ctx);
}

int lunet_db_ping(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.ping")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 1) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "db.ping requires a connection");
    return 2;
  }
  lunet_mysql_conn_t* wrapper =
      (lunet_mysql_conn_t*)luaL_testudata(L, 1, LUNET_MYSQL_CONN_MT);
  if (wrapper && wrapper->is_view && wrapper->member) {
    wrapper = wrapper->member;
  }
  if (!wrapper) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "db.ping requires a valid connection");
    return 2;
  }
  if (wrapper->closed || !wrapper->conn) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "connection is closed");
    return 2;
  }

  db_ping_ctx_t* ctx = lunet_alloc(sizeof(db_ping_ctx_t));
  if (!ctx) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->waiter_L = L;
  ctx->req.data = ctx;
  ctx->wrapper = wrapper;

  lunet_coref_create(L, ctx->co_ref);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_ping_work_cb,
                          db_ping_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lunet_free_nonnull(ctx);
    lua_pushboolean(L, 0);
    lua_pushstring(L, uv_strerror(ret));
    return 2;
  }

  return lua_yield(L, 0);
}

int lunet_db_release(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.release")) {
    return lua_error(L);
  }
  lunet_mysql_conn_t* wrapper = (lunet_mysql_conn_t*)luaL_testudata(L, 1, LUNET_MYSQL_CONN_MT);
  if (!wrapper || !wrapper->is_view) {
    lua_pushnil(L);
    lua_pushstring(L, "db.release requires a checked-out connection");
    return 2;
  }
  if (wrapper->closed) {
    lua_pushnil(L);
    lua_pushstring(L, "db.release: connection was not checked out");
    return 2;
  }
  lunet_mysql_pool_t* owner = (lunet_mysql_pool_t*)wrapper->owner;
  if (!owner || owner->closed) {
    /* Pool is gone: releasing is a no-op. */
    if (wrapper->pool_ref) {
      lunet_valref_release(L, wrapper->pool_ref);
      wrapper->pool_ref = 0;
    }
    wrapper->member = NULL;
    wrapper->owner = NULL;
    wrapper->closed = 1;
    lua_pushnil(L);
    return 1;
  }
  if (!wrapper->member || !wrapper->member->checked_out) {
    lua_pushnil(L);
    lua_pushstring(L, "db.release: connection was not checked out");
    return 2;
  }
  wrapper->member->checked_out = 0;
  if (wrapper->pool_ref) {
    lunet_valref_release(L, wrapper->pool_ref);
    wrapper->pool_ref = 0;
  }
  wrapper->member = NULL;
  wrapper->owner = NULL;
  wrapper->closed = 1;
  lua_pushnil(L);
  return 1;
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
  // Family-aware bool to match MYSQL_BIND.is_null (my_bool on MariaDB, bool on Oracle)
  lunet_mysql_bool* is_null = lunet_alloc(sizeof(lunet_mysql_bool) * ctx->ncols);
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
    lunet_mysql_pool_t* _pool = (lunet_mysql_pool_t*)luaL_testudata(L, 1, LUNET_MYSQL_POOL_MT);
    if (_pool && _pool->members && _pool->n > 0) {
      int _ex = 1;
      for (int _i = 0; _i < _pool->n; _i++) {
        if (_pool->members[_i] && !_pool->members[_i]->checked_out) { _ex = 0; break; }
      }
      if (_ex) {
        lua_pushnil(L);
        lua_pushstring(L, "pool exhausted: all members are checked out");
        return 2;
      }
    }
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
    lunet_mysql_pool_t* _pool = (lunet_mysql_pool_t*)luaL_testudata(L, 1, LUNET_MYSQL_POOL_MT);
    if (_pool && _pool->members && _pool->n > 0) {
      int _ex = 1;
      for (int _i = 0; _i < _pool->n; _i++) {
        if (_pool->members[_i] && !_pool->members[_i]->checked_out) { _ex = 0; break; }
      }
      if (_ex) {
        lua_pushnil(L);
        lua_pushstring(L, "pool exhausted: all members are checked out");
        return 2;
      }
    }
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
    lunet_mysql_pool_t* _pool = (lunet_mysql_pool_t*)luaL_testudata(L, 1, LUNET_MYSQL_POOL_MT);
    if (_pool && _pool->members && _pool->n > 0) {
      int _ex = 1;
      for (int _i = 0; _i < _pool->n; _i++) {
        if (_pool->members[_i] && !_pool->members[_i]->checked_out) { _ex = 0; break; }
      }
      if (_ex) {
        lua_pushnil(L);
        lua_pushstring(L, "pool exhausted: all members are checked out");
        return 2;
      }
    }
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
    lunet_mysql_pool_t* _pool = (lunet_mysql_pool_t*)luaL_testudata(L, 1, LUNET_MYSQL_POOL_MT);
    if (_pool && _pool->members && _pool->n > 0) {
      int _ex = 1;
      for (int _i = 0; _i < _pool->n; _i++) {
        if (_pool->members[_i] && !_pool->members[_i]->checked_out) { _ex = 0; break; }
      }
      if (_ex) {
        lua_pushnil(L);
        lua_pushstring(L, "pool exhausted: all members are checked out");
        return 2;
      }
    }
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
    lunet_mysql_pool_t* _pool = (lunet_mysql_pool_t*)luaL_testudata(L, 1, LUNET_MYSQL_POOL_MT);
    if (_pool && _pool->members && _pool->n > 0) {
      int _ex = 1;
      for (int _i = 0; _i < _pool->n; _i++) {
        if (_pool->members[_i] && !_pool->members[_i]->checked_out) { _ex = 0; break; }
      }
      if (_ex) {
        lua_pushnil(L);
        lua_pushstring(L, "pool exhausted: all members are checked out");
        return 2;
      }
    }
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

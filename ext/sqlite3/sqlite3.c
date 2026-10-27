/* lunet sqlite3 driver — the settled ownership machine.
 *
 * Two logical paths, each with one owner:
 *   ro: the event-loop thread. query_ro runs inline, synchronously, no
 *       yield; every call is a transient statement (prepare, bind, step,
 *       collect, finalize). Nothing is cached on this path.
 *   rw: one dedicated background worker thread per connection pair. Every
 *       rw call enqueues an op node and yields; the worker executes the
 *       queue strictly in FIFO order, and a loop-side uv_async delivers
 *       each finished op by resuming the calling coroutine with its own
 *       values. The close op is just the last node: accepted work drains
 *       by ordering, and the close finalizes every named statement and the
 *       physical connection on the owner thread.
 *
 * Errors are Lua tables: message, SQLite primary/extended codes when
 * SQLite produced them, and the operation context. A failed op is a
 * result for the caller; the connection and the queue stay usable.
 */

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

/* ------------------------------------------------------------------ */
/* Parameter snapshots: values are deep-copied off the Lua stack before */
/* any dispatch, so the worker only ever sees plain memory.             */
/* ------------------------------------------------------------------ */

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

/* Parse one Lua value into a param slot. Returns 0 on success, -1 on OOM. */
static int param_parse_one(lua_State* L, int idx, param_t* p) {
    int type = lua_type(L, idx);
    switch (type) {
        case LUA_TNIL:
            p->type = PARAM_TYPE_NIL;
            return 0;
        case LUA_TNUMBER: {
            lua_Number n = lua_tonumber(L, idx);
            long long val = (long long)n;
            if ((lua_Number)val == n) {
                p->type = PARAM_TYPE_INT;
                p->value.i = val;
            } else {
                p->type = PARAM_TYPE_DOUBLE;
                p->value.d = n;
            }
            return 0;
        }
        case LUA_TBOOLEAN:
            p->type = PARAM_TYPE_INT;
            p->value.i = lua_toboolean(L, idx) ? 1 : 0;
            return 0;
        case LUA_TSTRING: {
            size_t len;
            const char* s = lua_tolstring(L, idx, &len);
            p->type = PARAM_TYPE_TEXT;
            p->value.s.data = lunet_alloc(len + 1);
            if (!p->value.s.data) return -1;
            memcpy(p->value.s.data, s, len);
            p->value.s.data[len] = '\0';
            p->value.s.len = len;
            return 0;
        }
        default: {
            p->type = PARAM_TYPE_NIL;
            return 0;
        }
    }
}

/* Snapshot the trailing arguments (from stack index start to the top). */
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
        if (param_parse_one(L, start + i, &params[i]) != 0) {
            free_params(params, i);
            *nparams = -1;
            return NULL;
        }
    }
    return params;
}

/* Snapshot an explicit array-style binding table (order and arity are the
 * caller's contract; holes read as NULL). */
static param_t* collect_params_table(lua_State* L, int idx, int* nparams) {
    if (!lua_istable(L, idx)) {
        *nparams = -2;
        return NULL;
    }
    int n = (int)lua_objlen(L, idx);
    *nparams = n;
    if (n == 0) return NULL;
    param_t* params = lunet_alloc(sizeof(param_t) * n);
    if (!params) {
        *nparams = -1;
        return NULL;
    }
    for (int i = 0; i < n; i++) {
        lua_rawgeti(L, idx, i + 1);
        int bad = param_parse_one(L, -1, &params[i]);
        lua_pop(L, 1);
        if (bad != 0) {
            free_params(params, i);
            *nparams = -1;
            return NULL;
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
                rc = sqlite3_bind_text(stmt, idx, params[i].value.s.data, (int)params[i].value.s.len, SQLITE_TRANSIENT);
                break;
            default:
                rc = SQLITE_ERROR;
                break;
        }
        if (rc != SQLITE_OK) {
            if (err[0] == '\0') {
                snprintf(err, errsize, "bind failed: %s", sqlite3_errmsg(sqlite3_db_handle(stmt)));
            }
            return rc;
        }
    }
    return SQLITE_OK;
}

/* ------------------------------------------------------------------ */
/* Typed result staging: every cell keeps the SQLite type SQLite        */
/* produced, per row, so NULL/INTEGER/REAL/TEXT/BLOB all round-trip.     */
/* ------------------------------------------------------------------ */

typedef struct {
    int type;
    union {
        long long i;
        double d;
        struct {
            char* data;
            int len;
        } bin;
    } v;
} sqlite_cell_t;

typedef struct {
    char** col_names;
    int ncols;
    sqlite_cell_t** rows;
    int nrows;
    int cap_rows;
} sqlite_result_t;

static void free_result(sqlite_result_t* r) {
    for (int i = 0; i < r->nrows; i++) {
        for (int j = 0; j < r->ncols; j++) {
            sqlite_cell_t* c = &r->rows[i][j];
            if (c->type == SQLITE_TEXT || c->type == SQLITE_BLOB) {
                lunet_free_nonnull(c->v.bin.data);
            }
        }
        lunet_free_nonnull(r->rows[i]);
    }
    lunet_free_nonnull(r->rows);
    if (r->col_names) {
        for (int j = 0; j < r->ncols; j++) lunet_free_nonnull(r->col_names[j]);
        lunet_free_nonnull(r->col_names);
    }
    memset(r, 0, sizeof(*r));
}

static void push_result(lua_State* co, sqlite_result_t* r) {
    lua_newtable(co);
    for (int i = 0; i < r->nrows; i++) {
        lua_newtable(co);
        for (int j = 0; j < r->ncols; j++) {
            lua_pushstring(co, r->col_names[j]);
            sqlite_cell_t* c = &r->rows[i][j];
            switch (c->type) {
                case SQLITE_INTEGER:
                    lua_pushinteger(co, c->v.i);
                    break;
                case SQLITE_FLOAT:
                    lua_pushnumber(co, c->v.d);
                    break;
                case SQLITE_NULL:
                    lua_pushnil(co);
                    break;
                case SQLITE_BLOB:
                case SQLITE_TEXT:
                    lua_pushlstring(co, c->v.bin.data, (size_t)c->v.bin.len);
                    break;
                default:
                    lua_pushnil(co);
                    break;
            }
            lua_settable(co, -3);
        }
        lua_rawseti(co, -2, i + 1);
    }
}

/* Step the statement to completion, staging every row with its SQLite
 * types. Never finalizes. Returns SQLITE_DONE on a complete read, or the
 * step failure's rc (with err filled from the connection). */
static int stage_rows(sqlite3_stmt* stmt, sqlite3* conn, sqlite_result_t* r,
                      char* err, size_t errsz) {
    r->ncols = sqlite3_column_count(stmt);
    if (r->ncols > 0) {
        r->col_names = lunet_alloc(sizeof(char*) * r->ncols);
        if (!r->col_names) {
            snprintf(err, errsz, "out of memory");
            return SQLITE_NOMEM;
        }
        memset(r->col_names, 0, sizeof(char*) * r->ncols);
        for (int i = 0; i < r->ncols; i++) {
            const char* name = sqlite3_column_name(stmt, i);
            r->col_names[i] = lunet_strdup_local(name ? name : "");
            if (!r->col_names[i]) {
                snprintf(err, errsz, "out of memory");
                free_result(r);
                return SQLITE_NOMEM;
            }
        }
    }

    int rc = SQLITE_OK;
    while ((rc = sqlite3_step(stmt)) == SQLITE_ROW) {
        if (r->nrows >= r->cap_rows) {
            int cap = r->cap_rows ? r->cap_rows * 2 : 16;
            sqlite_cell_t** grown = lunet_realloc(r->rows, sizeof(sqlite_cell_t*) * cap);
            if (!grown) {
                snprintf(err, errsz, "out of memory");
                return SQLITE_NOMEM;
            }
            r->rows = grown;
            r->cap_rows = cap;
        }
        sqlite_cell_t* row = lunet_alloc(sizeof(sqlite_cell_t) * r->ncols);
        if (!row) {
            snprintf(err, errsz, "out of memory");
            return SQLITE_NOMEM;
        }
        memset(row, 0, sizeof(sqlite_cell_t) * r->ncols);
        int oom = 0;
        for (int j = 0; j < r->ncols; j++) {
            int t = sqlite3_column_type(stmt, j);
            row[j].type = t;
            if (t == SQLITE_INTEGER) {
                row[j].v.i = sqlite3_column_int64(stmt, j);
            } else if (t == SQLITE_FLOAT) {
                row[j].v.d = sqlite3_column_double(stmt, j);
            } else if (t == SQLITE_TEXT || t == SQLITE_BLOB) {
                const void* bytes = (t == SQLITE_TEXT) ? (const void*)sqlite3_column_text(stmt, j)
                                                       : sqlite3_column_blob(stmt, j);
                int len = sqlite3_column_bytes(stmt, j);
                if (bytes && len > 0) {
                    row[j].v.bin.data = lunet_alloc((size_t)len);
                    if (!row[j].v.bin.data) {
                        oom = 1;
                        break;
                    }
                    memcpy(row[j].v.bin.data, bytes, (size_t)len);
                    row[j].v.bin.len = len;
                }
            }
        }
        if (oom) {
            snprintf(err, errsz, "out of memory");
            lunet_free_nonnull(row);
            return SQLITE_NOMEM;
        }
        r->rows[r->nrows] = row;
        r->nrows++;
    }

    if (rc != SQLITE_DONE) {
        snprintf(err, errsz, "%s", sqlite3_errmsg(conn));
    }
    return rc;
}

/* ------------------------------------------------------------------ */
/* The mutable handles: a connection wrapper (with its owned worker on   */
/* the rw side) and a named statement bound to it.                       */
/* ------------------------------------------------------------------ */

typedef struct lunet_rw_worker_s lunet_rw_worker_t;
typedef struct rw_node_s rw_node_t;

typedef struct lunet_sqlite_conn_s {
  sqlite3* conn;
  int closed;
  int readonly;
  /* Named statements bound to this connection (intrusive list, loop
   * thread only). conn close finalizes every one still open on it. */
  struct lunet_sqlite_stmt_s* stmts;
  /* rw side: the dedicated worker that owns this connection. NULL on the
   * read-only handle. */
  lunet_rw_worker_t* worker;
} lunet_sqlite_conn_t;

struct lunet_sqlite_stmt_s {
  lunet_sqlite_conn_t* conn;
  sqlite3_stmt* stmt;
  struct lunet_sqlite_stmt_s* next;
  struct lunet_sqlite_stmt_s* prev;
  int closed;
  /* Registry ref of the owning connection userdata: one value pinning
   * the wrapper alive for the statement's lifetime (released at GC). */
  int conn_ref;
};

static void conn_track_stmt(lunet_sqlite_conn_t* conn, struct lunet_sqlite_stmt_s* s) {
  s->prev = NULL;
  s->next = conn->stmts;
  if (conn->stmts) conn->stmts->prev = s;
  conn->stmts = s;
}

static void conn_untrack_stmt(lunet_sqlite_conn_t* conn, struct lunet_sqlite_stmt_s* s) {
  if (s->prev) s->prev->next = s->next;
  else if (conn->stmts == s) conn->stmts = s->next;
  if (s->next) s->next->prev = s->prev;
  s->next = NULL;
  s->prev = NULL;
}

/* ------------------------------------------------------------------ */
/* The rw worker: one thread per connection pair. Nodes move through a   */
/* FIFO queue onto the thread, come back through a results queue, and    */
/* the loop-side uv_async drains them by resuming the callers.           */
/* ------------------------------------------------------------------ */

typedef enum {
  RW_OP_QUERY,        /* transient prepare + rows            */
  RW_OP_QUERY_RO,     /* same, but called through query_ro   */
  RW_OP_EXEC,         /* transient prepare + write metadata  */
  RW_OP_STMT_QUERY,   /* named statement + rows              */
  RW_OP_STMT_EXEC,    /* named statement + write metadata    */
  RW_OP_PREPARE,      /* prepare one named statement         */
  RW_OP_STMT_CLOSE,   /* finalize one named statement        */
  RW_OP_CLOSE,        /* drain + teardown the connection     */
  RW_OP_SHUTDOWN      /* GC teardown (no waiter)             */
} rw_op_kind_t;

struct rw_node_s {
  rw_node_t* next;
  rw_op_kind_t kind;
  char op[16];
  lua_State* waiter_L;
  int co_ref;
  /* Registry refs released at delivery (loop thread): the pinned
   * connection / statement userdatas for this flight. */
  int refs[2];
  int nrefs;

  sqlite3* conn;
  lunet_sqlite_conn_t* owner;
  struct lunet_sqlite_stmt_s* stmt;
  char* sql;
  param_t* params;
  int nparams;

  sqlite_result_t res;
  long long affected_rows;
  long long insert_id;
  char message[512];
  int code;
  int ext_code;
  int code_valid;
};

struct lunet_rw_worker_s {
  uv_thread_t thread;
  int thread_started;
  uv_mutex_t mu;
  uv_cond_t cv;
  rw_node_t* q_head;   /* FIFO of accepted work */
  rw_node_t** q_tail;
  rw_node_t* r_head;   /* finished, awaiting delivery */
  rw_node_t** r_tail;
  int running;
  int finished;
  int inflight;
  uv_async_t async;
};

/* Error capture at the failing SQLite call: message text, primary code
 * from the rc, and the extended code from the connection. */
static void node_sqlite_err(rw_node_t* n, sqlite3* conn, int rc, const char* fallback) {
  if (n->message[0] == '\0') {
    const char* msg = conn ? sqlite3_errmsg(conn) : NULL;
    snprintf(n->message, sizeof(n->message), "%s", (msg && fallback == NULL) ? msg : fallback);
  }
  n->code = rc;
  n->ext_code = conn ? sqlite3_extended_errcode(conn) : rc;
  n->code_valid = 1;
}

static void node_message_err(rw_node_t* n, const char* msg) {
  snprintf(n->message, sizeof(n->message), "%s", msg);
}

/* Finalize every statement still linked on the connection and close the
 * physical connection once. Runs on the worker thread (close op) or on
 * the loop thread at GC — never while any op is in flight, because every
 * op pins the wrapper until delivery. */
static void lunet_sqlite_conn_teardown(lunet_sqlite_conn_t* wrapper) {
  if (!wrapper) return;
  struct lunet_sqlite_stmt_s* s = wrapper->stmts;
  while (s) {
    struct lunet_sqlite_stmt_s* next = s->next;
    if (s->stmt) {
      sqlite3_finalize(s->stmt);
      s->stmt = NULL;
    }
    s->closed = 1;
    s->next = NULL;
    s->prev = NULL;
    s = next;
  }
  wrapper->stmts = NULL;
  if (wrapper->conn) {
    sqlite3_close(wrapper->conn);
    wrapper->conn = NULL;
  }
  wrapper->closed = 1;
}

static void worker_free_cb(uv_handle_t* handle) {
  lunet_rw_worker_t* w = (lunet_rw_worker_t*)handle->data;
  if (w) {
    uv_mutex_destroy(&w->mu);
    uv_cond_destroy(&w->cv);
    lunet_free_nonnull(w);
  }
}

static void node_free(lua_State* L, rw_node_t* n) {
  free_params(n->params, n->nparams);
  free_result(&n->res);
  lunet_free_nonnull(n->sql);
  if (L) {
    for (int i = 0; i < n->nrefs; i++) {
      lunet_valref_release(L, n->refs[i]);
    }
    if (n->co_ref) {
      lunet_coref_release(L, n->co_ref);
      n->co_ref = 0;
    }
  }
  lunet_free_nonnull(n);
}

static void node_deliver(rw_node_t* node);

/* The loop-side drain: deliver everything finished, then let the async
 * handle fall asleep when nothing is outstanding. */
static void worker_async_cb(uv_async_t* handle) {
  lunet_rw_worker_t* w = (lunet_rw_worker_t*)handle->data;
  if (!w) return;

  uv_mutex_lock(&w->mu);
  rw_node_t* list = w->r_head;
  w->r_head = NULL;
  w->r_tail = &w->r_head;
  uv_mutex_unlock(&w->mu);

  rw_node_t* n = list;
  while (n) {
    rw_node_t* next = n->next;
    n->next = NULL;
    node_deliver(n);
    n = next;
  }

  uv_mutex_lock(&w->mu);
  int pending = (w->q_head != NULL) || (w->r_head != NULL) || w->inflight || (w->finished && 0);
  if (!pending) {
    uv_unref((uv_handle_t*)&w->async);
  }
  uv_mutex_unlock(&w->mu);
}

static void rw_execute(rw_node_t* node) {
  sqlite3* conn = node->conn;

  if (node->kind == RW_OP_CLOSE || node->kind == RW_OP_SHUTDOWN) {
    node->message[0] = '\0';
    lunet_sqlite_conn_teardown(node->owner);
    return;
  }

  if (node->kind == RW_OP_STMT_CLOSE) {
    struct lunet_sqlite_stmt_s* s = node->stmt;
    if (s->stmt) {
      sqlite3_finalize(s->stmt);
      s->stmt = NULL;
    }
    s->closed = 1;
    return;
  }

  if (node->kind == RW_OP_PREPARE) {
    if (!node->owner || node->owner->closed || !node->owner->conn) {
      node_message_err(node, "connection is closed");
      return;
    }
    sqlite3_stmt* st = NULL;
    int rc = sqlite3_prepare_v2(conn, node->sql, -1, &st, NULL);
    if (rc != SQLITE_OK) {
      node_sqlite_err(node, conn, rc, NULL);
      return;
    }
    node->stmt->stmt = st;
    node->message[0] = '\0';
    return;
  }

  if (node->owner && node->owner->closed) {
    node_message_err(node, "connection is closed");
    return;
  }

  sqlite3_stmt* st = NULL;
  int transient = 0;

  if (node->stmt) {
    st = node->stmt->stmt;
    if (!st) {
      node_message_err(node, "statement is closed");
      return;
    }
    sqlite3_reset(st);
    sqlite3_clear_bindings(st);
  } else {
    int rc = sqlite3_prepare_v2(conn, node->sql, -1, &st, NULL);
    if (rc != SQLITE_OK) {
      node_sqlite_err(node, conn, rc, NULL);
      return;
    }
    transient = 1;
  }

  int rc = bind_params(st, node->params, node->nparams, node->message, sizeof(node->message));
  if (rc != SQLITE_OK) {
    node->code = rc;
    node->ext_code = sqlite3_extended_errcode(conn);
    node->code_valid = 1;
    sqlite3_reset(st);
    if (transient) sqlite3_finalize(st);
    return;
  }

  if (node->kind == RW_OP_QUERY || node->kind == RW_OP_QUERY_RO ||
      node->kind == RW_OP_STMT_QUERY) {
    rc = stage_rows(st, conn, &node->res, node->message, sizeof(node->message));
    if (rc != SQLITE_DONE) {
      node_sqlite_err(node, conn, rc, NULL);
      sqlite3_reset(st);
      if (transient) sqlite3_finalize(st);
      return;
    }
  } else {
    rc = sqlite3_step(st);
    if (rc != SQLITE_DONE && rc != SQLITE_ROW) {
      node_sqlite_err(node, conn, rc, NULL);
      sqlite3_reset(st);
      if (transient) sqlite3_finalize(st);
      return;
    }
    node->affected_rows = sqlite3_changes(conn);
    node->insert_id = sqlite3_last_insert_rowid(conn);
  }

  node->message[0] = '\0';
  sqlite3_reset(st);
  if (transient) sqlite3_finalize(st);
}

static void worker_proc(void* arg) {
  lunet_rw_worker_t* w = (lunet_rw_worker_t*)arg;
  for (;;) {
    uv_mutex_lock(&w->mu);
    while (w->running && w->q_head == NULL) {
      uv_cond_wait(&w->cv, &w->mu);
    }
    rw_node_t* node = w->q_head;
    if (node == NULL) {
      uv_mutex_unlock(&w->mu);
      break;
    }
    w->q_head = node->next;
    if (w->q_head == NULL) w->q_tail = &w->q_head;
    w->inflight = 1;
    uv_mutex_unlock(&w->mu);

    rw_execute(node);
    node->next = NULL;

    uv_mutex_lock(&w->mu);
    *w->r_tail = node;
    w->r_tail = &node->next;
    w->inflight = 0;
    int stop_after = (node->kind == RW_OP_SHUTDOWN);
    uv_mutex_unlock(&w->mu);
    uv_async_send(&w->async);
    if (stop_after) break;
  }
  uv_mutex_lock(&w->mu);
  w->finished = 1;
  uv_mutex_unlock(&w->mu);
  /* No exit-notify send: a send that lands after the loop's last poll
   * leaves libuv's async busy flag set, and uv_loop_close would spin on
   * it forever. Nothing consumes "finished" here — the GC join path is
   * the shutdown protocol. */
}

/* Start owns the thread lifecycle: called once, from the loop thread,
 * before any handle is handed back. Returns NULL on failure. */
static lunet_rw_worker_t* rw_worker_start(void) {
  lunet_rw_worker_t* w = lunet_alloc(sizeof(lunet_rw_worker_t));
  if (!w) return NULL;
  memset(w, 0, sizeof(*w));
  if (uv_mutex_init(&w->mu) != 0) {
    lunet_free_nonnull(w);
    return NULL;
  }
  if (uv_cond_init(&w->cv) != 0) {
    uv_mutex_destroy(&w->mu);
    lunet_free_nonnull(w);
    return NULL;
  }
  w->q_tail = &w->q_head;
  w->r_tail = &w->r_head;
  w->running = 1;
  w->async.data = w;
  if (uv_async_init(uv_default_loop(), &w->async, worker_async_cb) != 0) {
    uv_cond_destroy(&w->cv);
    uv_mutex_destroy(&w->mu);
    lunet_free_nonnull(w);
    return NULL;
  }
  /* Not outstanding yet: never hold the loop on an idle driver. */
  uv_unref((uv_handle_t*)&w->async);
  if (uv_thread_create(&w->thread, worker_proc, w) != 0) {
    uv_close((uv_handle_t*)&w->async, worker_free_cb);
    return NULL;
  }
  w->thread_started = 1;
  return w;
}

/* Stop the worker and free its machinery. Called from the loop thread at
 * GC time; by then no op references the wrapper (every op pins it), so
 * the queue is empty and the join is quick. */
static void rw_worker_stop(lunet_rw_worker_t* w) {
  if (!w) return;
  int alive = 0;
  uv_mutex_lock(&w->mu);
  w->running = 0;
  alive = (w->finished == 0);
  uv_cond_signal(&w->cv);
  uv_mutex_unlock(&w->mu);
  if (alive && w->thread_started) {
    uv_thread_join(&w->thread);
  }
  /* Un-delivered leftovers (a coroutine that died mid-flight) drop their
   * registry references here, then the async close frees the struct. */
  uv_mutex_lock(&w->mu);
  rw_node_t* list = w->r_head;
  w->r_head = NULL;
  w->r_tail = &w->r_head;
  rw_node_t* queued = w->q_head;
  w->q_head = NULL;
  w->q_tail = &w->q_head;
  uv_mutex_unlock(&w->mu);
  while (list) {
    rw_node_t* next = list->next;
    node_free(NULL, list);
    list = next;
  }
  while (queued) {
    rw_node_t* next = queued->next;
    node_free(NULL, queued);
    queued = next;
  }
  /* The runtime's teardown sweep may have closed this async first (with
   * a NULL callback). Closing a closing handle twice corrupts libuv's
   * close bookkeeping; skip and let the process exit reclaim. */
  if (!uv_is_closing((uv_handle_t*)&w->async)) {
    uv_close((uv_handle_t*)&w->async, worker_free_cb);
  }
}

static int rw_enqueue(lunet_rw_worker_t* w, rw_node_t* node) {
  node->next = NULL;
  int was_idle = 0;
  uv_mutex_lock(&w->mu);
  if (!w->running) {
    uv_mutex_unlock(&w->mu);
    return -1;
  }
  was_idle = (w->q_head == NULL && w->r_head == NULL && w->inflight == 0);
  *w->q_tail = node;
  w->q_tail = &node->next;
  uv_cond_signal(&w->cv);
  uv_mutex_unlock(&w->mu);
  if (was_idle) {
    uv_ref((uv_handle_t*)&w->async);
  }
  return 0;
}

/* ------------------------------------------------------------------ */
/* Delivery: on the loop thread, resolve the waiter coroutine, push its  */
/* result shape, release the flight pins, free the node.                 */
/* ------------------------------------------------------------------ */

static void push_err_table(lua_State* co, rw_node_t* n) {
  lua_newtable(co);
  lua_pushstring(co, "message");
  lua_pushstring(co, n->message);
  lua_settable(co, -3);
  lua_pushstring(co, "op");
  lua_pushstring(co, n->op);
  lua_settable(co, -3);
  if (n->code_valid) {
    lua_pushstring(co, "code");
    lua_pushinteger(co, n->code);
    lua_settable(co, -3);
    lua_pushstring(co, "extended_code");
    lua_pushinteger(co, n->ext_code);
    lua_settable(co, -3);
  }
}

static void node_deliver(rw_node_t* node) {
  lua_State* L = node->waiter_L;
  lua_rawgeti(L, LUA_REGISTRYINDEX, node->co_ref);
  lunet_coref_release(L, node->co_ref);
  node->co_ref = 0;
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    node_free(L, node);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  int nargs = 0;
  int err = (node->message[0] != '\0');

  switch (node->kind) {
    case RW_OP_PREPARE: {
      struct lunet_sqlite_stmt_s* s = node->stmt;
      if (err || s->closed || s->stmt == NULL) {
        /* Startup-inventory failure: no usable statement is handed back. */
        s->stmt = NULL;
        s->closed = 1;
        conn_untrack_stmt(s->conn, s);
        lua_pushnil(co);
        push_err_table(co, node);
        nargs = 2;
      } else {
        /* The pinned statement userdata lands as the first return. */
        lua_rawgeti(L, LUA_REGISTRYINDEX, node->refs[0]);
        lunet_valref_release(L, node->refs[0]);
        node->refs[0] = 0;
        node->refs[1] = 0;
        node->nrefs = 0;
        lua_xmove(L, co, 1);
        lua_pushnil(co);
        nargs = 2;
      }
      break;
    }
    case RW_OP_QUERY:
    case RW_OP_QUERY_RO:
    case RW_OP_STMT_QUERY:
      if (err) {
        lua_pushnil(co);
        push_err_table(co, node);
      } else {
        push_result(co, &node->res);
        lua_pushnil(co);
      }
      nargs = 2;
      break;
    case RW_OP_EXEC:
    case RW_OP_STMT_EXEC:
      if (err) {
        lua_pushnil(co);
        push_err_table(co, node);
      } else {
        lua_newtable(co);
        lua_pushstring(co, "affected_rows");
        lua_pushinteger(co, node->affected_rows);
        lua_settable(co, -3);
        lua_pushstring(co, "last_insert_id");
        lua_pushinteger(co, node->insert_id);
        lua_settable(co, -3);
        lua_pushnil(co);
      }
      nargs = 2;
      break;
    case RW_OP_STMT_CLOSE:
    case RW_OP_CLOSE:
      lua_pushnil(co);
      nargs = 1;
      break;
    default:
      break;
  }

  lunet_co_resume(co, nargs);
  node_free(L, node);
}

/* ------------------------------------------------------------------ */
/* Handle GC lifetimes.                                                  */
/* ------------------------------------------------------------------ */

static int conn_gc(lua_State* L) {
  lunet_sqlite_conn_t* wrapper = (lunet_sqlite_conn_t*)luaL_checkudata(L, 1, LUNET_SQLITE_CONN_MT);
  if (wrapper->worker) {
    rw_worker_stop(wrapper->worker);
    wrapper->worker = NULL;
  }
  lunet_sqlite_conn_teardown(wrapper);
  return 0;
}

static void register_conn_metatable(lua_State* L) {
  if (luaL_newmetatable(L, LUNET_SQLITE_CONN_MT)) {
    lua_pushcfunction(L, conn_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_pop(L, 1);
}

static int stmt_gc(lua_State* L) {
  struct lunet_sqlite_stmt_s* s = (struct lunet_sqlite_stmt_s*)luaL_checkudata(L, 1, LUNET_SQLITE_STMT_MT);
  if (s->stmt && s->conn && s->conn->conn) {
    sqlite3_finalize(s->stmt);
    conn_untrack_stmt(s->conn, s);
  }
  s->stmt = NULL;
  s->closed = 1;
  if (s->conn_ref) {
    lunet_valref_release(L, s->conn_ref);
    s->conn_ref = 0;
  }
  return 0;
}

static int stmt_dispatch(lua_State* L, rw_op_kind_t kind);

/* The named-statement methods: index 1 is the statement userdata. */
static int stmt_query(lua_State* L) {
  if (lunet_ensure_coroutine(L, "stmt:query")) {
    return lua_error(L);
  }
  return stmt_dispatch(L, RW_OP_STMT_QUERY);
}

static int stmt_exec(lua_State* L) {
  if (lunet_ensure_coroutine(L, "stmt:exec")) {
    return lua_error(L);
  }
  return stmt_dispatch(L, RW_OP_STMT_EXEC);
}

static int stmt_close(lua_State* L) {
  if (lunet_ensure_coroutine(L, "stmt:close")) {
    return lua_error(L);
  }
  struct lunet_sqlite_stmt_s* s = (struct lunet_sqlite_stmt_s*)luaL_testudata(L, 1, LUNET_SQLITE_STMT_MT);
  if (!s) {
    lua_pushstring(L, "stmt:close requires a prepared statement");
    return lua_error(L);
  }
  if (s->closed || s->stmt == NULL || !s->conn || !s->conn->worker) {
    lua_pushnil(L);
    return 1;
  }
  /* Closing happens on the owner, FIFO-ordered after the calls already
   * accepted on this statement. Accepting it marks the statement closed
   * immediately: later calls fail loudly, earlier ones keep their turns. */
  s->closed = 1;
  conn_untrack_stmt(s->conn, s);

  rw_node_t* node = lunet_alloc(sizeof(rw_node_t));
  if (!node) {
    lua_pushstring(L, "out of memory");
    return lua_error(L);
  }
  memset(node, 0, sizeof(*node));
  node->kind = RW_OP_STMT_CLOSE;
  snprintf(node->op, sizeof(node->op), "stmt_close");
  node->waiter_L = L;
  node->conn = s->conn->conn;
  node->owner = s->conn;
  node->stmt = s;
  lua_pushvalue(L, 1);
  lunet_valref_create_raw(L, node->refs[0]);
  node->nrefs = 1;
  lunet_coref_create(L, node->co_ref);

  if (rw_enqueue(s->conn->worker, node) != 0) {
    node_free(L, node);
    lua_pushnil(L);
    return 1;
  }
  return lua_yield(L, 0);
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

/* ------------------------------------------------------------------ */
/* Open: the option contract (create / passthroughs / mutex / loud       */
/* unknowns), one worker hop, and the dedicated worker started before    */
/* any handle is handed over.                                            */
/* ------------------------------------------------------------------ */

typedef struct {
  uv_work_t req;
  lua_State* waiter_L;
  int co_ref;

  sqlite3* conn;
  sqlite3* ro_conn;
  char err[256];
  int err_code;
  int err_ext;
  int err_code_valid;

  char path[1024];
  int create;
  int set_wal;
  int is_memory;
  int busy_timeout;
  int foreign_keys;
  int synchronous;
  unsigned int mutex_flags;
} db_open_ctx_t;

static void db_open_ctx_fail_sqlite(db_open_ctx_t* ctx, sqlite3* conn, int rc, const char* fallback) {
  if (ctx->err[0] == '\0') {
    const char* msg = conn ? sqlite3_errmsg(conn) : NULL;
    snprintf(ctx->err, sizeof(ctx->err), "%s", (msg && fallback == NULL) ? msg : fallback);
  }
  ctx->err_code = rc;
  ctx->err_ext = conn ? sqlite3_extended_errcode(conn) : rc;
  ctx->err_code_valid = 1;
}

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
      ctx->err_code = SQLITE_ERROR;
      ctx->err_ext = sqlite3_extended_errcode(conn);
      ctx->err_code_valid = 1;
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
      ctx->err_code = SQLITE_ERROR;
      ctx->err_ext = sqlite3_extended_errcode(conn);
      ctx->err_code_valid = 1;
      return -1;
    }
  }
  return 0;
}

static void db_open_work_cb(uv_work_t* req) {
  db_open_ctx_t* ctx = (db_open_ctx_t*)req->data;

  if (ctx->is_memory) {
    /* One private database: a single connection serves both logical
     * paths; access serializes through its owner worker. Read-only is
     * not enforced on this alias. */
    unsigned int flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | ctx->mutex_flags;
    int rc = sqlite3_open_v2(ctx->path, &ctx->conn, (int)flags, NULL);
    if (rc != SQLITE_OK) {
      db_open_ctx_fail_sqlite(ctx, ctx->conn, rc, "cannot open database");
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

  /* Without create= the file must already exist and its journal mode is
   * left untouched. create=NORMAL permits creation; create=WAL permits
   * creation, requests WAL, and verifies SQLite actually returned wal. */
  unsigned int flags = (ctx->create
      ? (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
      : SQLITE_OPEN_READWRITE) | ctx->mutex_flags;
  int rc = sqlite3_open_v2(ctx->path, &ctx->conn, (int)flags, NULL);
  if (rc != SQLITE_OK) {
    db_open_ctx_fail_sqlite(ctx, ctx->conn, rc, "cannot open database");
    if (ctx->conn) sqlite3_close(ctx->conn);
    ctx->conn = NULL;
    return;
  }

  if (ctx->set_wal) {
    /* journal_mode returns the PRIOR mode string when the conversion
     * does not take (it does not error), so the result is checked. */
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
      ctx->err_code = SQLITE_ERROR;
      ctx->err_ext = sqlite3_extended_errcode(ctx->conn);
      ctx->err_code_valid = 1;
      sqlite3_close(ctx->conn);
      ctx->conn = NULL;
      return;
    }
  }

  unsigned int ro_flags = SQLITE_OPEN_READONLY | ctx->mutex_flags;
  rc = sqlite3_open_v2(ctx->path, &ctx->ro_conn, (int)ro_flags, NULL);
  if (rc != SQLITE_OK) {
    db_open_ctx_fail_sqlite(ctx, ctx->ro_conn, rc, "cannot open read-only connection");
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

static void push_conn_wrapper(lua_State* co, sqlite3* conn, int readonly,
                              lunet_rw_worker_t* worker) {
  lunet_sqlite_conn_t* wrapper =
      (lunet_sqlite_conn_t*)lua_newuserdata(co, sizeof(lunet_sqlite_conn_t));
  memset(wrapper, 0, sizeof(*wrapper));
  wrapper->conn = conn;
  wrapper->readonly = readonly;
  wrapper->worker = worker;
  luaL_getmetatable(co, LUNET_SQLITE_CONN_MT);
  lua_setmetatable(co, -2);
}

static void db_open_after_cb(uv_work_t* req, int status) {
  (void)status;
  db_open_ctx_t* ctx = (db_open_ctx_t*)req->data;
  lua_State* L = ctx->waiter_L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    if (ctx->conn) sqlite3_close(ctx->conn);
    if (ctx->ro_conn) sqlite3_close(ctx->ro_conn);
    lunet_free_nonnull(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (!ctx->conn || !(ctx->ro_conn || ctx->is_memory)) {
    /* Failure shape: (nil, nil, err). Nothing partial survives. */
    lua_pushnil(co);
    lua_pushnil(co);
    lua_newtable(co);
    lua_pushstring(co, "message");
    lua_pushstring(co, ctx->err);
    lua_settable(co, -3);
    lua_pushstring(co, "op");
    lua_pushstring(co, "open");
    lua_settable(co, -3);
    if (ctx->err_code_valid) {
      lua_pushstring(co, "code");
      lua_pushinteger(co, ctx->err_code);
      lua_settable(co, -3);
      lua_pushstring(co, "extended_code");
      lua_pushinteger(co, ctx->err_ext);
      lua_settable(co, -3);
    }
    int rc = lunet_co_resume(co, 3);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) fprintf(stderr, "lua_resume error in db.open: %s\n", err);
      lua_pop(co, 1);
    }
    lunet_free_nonnull(ctx);
    return;
  }

  /* Success path: the dedicated worker starts before any handle is
   * handed over. */
  lunet_rw_worker_t* worker = rw_worker_start();
  if (!worker) {
    snprintf(ctx->err, sizeof(ctx->err), "cannot start the rw worker");
    ctx->err_code = 0;
    ctx->err_ext = 0;
    ctx->err_code_valid = 0;
    sqlite3_close(ctx->conn);
    ctx->conn = NULL;
    if (ctx->ro_conn) {
      sqlite3_close(ctx->ro_conn);
      ctx->ro_conn = NULL;
    }
    lua_pushnil(co);
    lua_pushnil(co);
    lua_newtable(co);
    lua_pushstring(co, "message");
    lua_pushstring(co, ctx->err);
    lua_settable(co, -3);
    lua_pushstring(co, "op");
    lua_pushstring(co, "open");
    lua_settable(co, -3);
    int rc = lunet_co_resume(co, 3);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) fprintf(stderr, "lua_resume error in db.open: %s\n", err);
      lua_pop(co, 1);
    }
    lunet_free_nonnull(ctx);
    return;
  }

  if (ctx->is_memory) {
    /* One wrapper userdata pushed twice: one owner, closing once. */
    push_conn_wrapper(co, ctx->conn, 0, worker);
    lua_pushvalue(co, -1);
    lua_pushnil(co);
    ctx->conn = NULL;
  } else {
    push_conn_wrapper(co, ctx->conn, 0, worker);
    push_conn_wrapper(co, ctx->ro_conn, 1, NULL);
    lua_pushnil(co);
    ctx->conn = NULL;
    ctx->ro_conn = NULL;
  }
  int rc = lunet_co_resume(co, 3);
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
    lua_pushstring(L, "db.open: out of memory");
    return lua_error(L);
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->waiter_L = L;
  ctx->req.data = ctx;
  ctx->busy_timeout = -1;
  ctx->foreign_keys = -1;
  ctx->synchronous = -1;

  /* One pass over the caller's table. Every key is known or loud. */
  lua_pushnil(L);
  while (lua_next(L, 1) != 0) {
    if (lua_type(L, -2) != LUA_TSTRING) {
      const char* kt = lua_typename(L, lua_type(L, -2));
      lunet_free_nonnull(ctx);
      lua_pushfstring(L, "db.open: option names must be strings (got %s)", kt);
      return lua_error(L);
    }
    const char* key = lua_tostring(L, -2);
    if (strcmp(key, "path") == 0) {
      const char* path = lua_tostring(L, -1);
      if (!path) {
        lunet_free_nonnull(ctx);
        lua_pushstring(L, "db.open: path must be a string");
        return lua_error(L);
      }
      snprintf(ctx->path, sizeof(ctx->path), "%s", path);
    } else if (strcmp(key, "create") == 0) {
      const char* create = luaL_checkstring(L, -1);
      if (strcmp(create, "WAL") == 0) {
        ctx->create = 1;
        ctx->set_wal = 1;
      } else if (strcmp(create, "NORMAL") == 0) {
        ctx->create = 1;
      } else {
        lunet_free_nonnull(ctx);
        lua_pushfstring(L, "db.open: create must be \"WAL\" or \"NORMAL\" (got '%s')", create);
        return lua_error(L);
      }
    } else if (strcmp(key, "busy_timeout") == 0) {
      lua_Integer ms = luaL_checkinteger(L, -1);
      if (ms < 0) {
        lunet_free_nonnull(ctx);
        lua_pushstring(L, "db.open: busy_timeout must be >= 0");
        return lua_error(L);
      }
      ctx->busy_timeout = (int)ms;
    } else if (strcmp(key, "foreign_keys") == 0) {
      luaL_checktype(L, -1, LUA_TBOOLEAN);
      ctx->foreign_keys = lua_toboolean(L, -1) ? 1 : 0;
    } else if (strcmp(key, "synchronous") == 0) {
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
    } else if (strcmp(key, "mutex") == 0) {
      const char* mutex = luaL_checkstring(L, -1);
      if (strcmp(mutex, "nomutex") == 0) {
        ctx->mutex_flags = (unsigned int)SQLITE_OPEN_NOMUTEX;
      } else if (strcmp(mutex, "fullmutex") == 0) {
        ctx->mutex_flags = (unsigned int)SQLITE_OPEN_FULLMUTEX;
      } else {
        lunet_free_nonnull(ctx);
        lua_pushfstring(L,
                        "db.open: mutex must be \"nomutex\" or \"fullmutex\" (got '%s')",
                        mutex);
        return lua_error(L);
      }
    } else {
      lunet_free_nonnull(ctx);
      lua_pushfstring(L, "db.open: unknown option '%s'", key);
      return lua_error(L);
    }
    lua_pop(L, 1);
  }
  if (ctx->path[0] == '\0') {
    snprintf(ctx->path, sizeof(ctx->path), ":memory:");
  }
  ctx->is_memory = strcmp(ctx->path, ":memory:") == 0;

  lunet_coref_create(L, ctx->co_ref);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_open_work_cb, db_open_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lunet_free_nonnull(ctx);
    lua_pushfstring(L, "db.open: uv_queue_work failed: %s", uv_strerror(ret));
    return lua_error(L);
  }

  return lua_yield(L, 0);
}

/* ------------------------------------------------------------------ */
/* Shared rw dispatch: one entry shapes an op node for the four generic  */
/* calls and yields; the worker delivers the result table.               */
/* ------------------------------------------------------------------ */

static int queue_rw_op(lua_State* L, lunet_sqlite_conn_t* wrapper,
                       rw_op_kind_t kind, const char* opname,
                       struct lunet_sqlite_stmt_s* stmt, const char* sql);
static void node_free_stmt_hazard(lua_State* L, struct lunet_sqlite_stmt_s* s);

/* Route enforcement: the rw-only calls return a loud route error when
 * handed the read-only handle. Routing is by call, never by SQL; every
 * route violation carries the same op so the caller pattern-matches it. */
static void push_route_err(lua_State* L, const char* callname) {
  lua_pushnil(L);
  lua_newtable(L);
  lua_pushstring(L, "message");
  lua_pushfstring(L,
                  "routing: %s belongs to the rw handle; use query_ro on the read-only handle",
                  callname);
  lua_settable(L, -3);
  lua_pushstring(L, "op");
  lua_pushstring(L, "route");
  lua_settable(L, -3);
}

int lunet_db_close(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.close")) {
    return lua_error(L);
  }
  lunet_sqlite_conn_t* wrapper =
      (lunet_sqlite_conn_t*)luaL_testudata(L, 1, LUNET_SQLITE_CONN_MT);
  if (!wrapper) {
    lua_pushstring(L, "db.close requires a connection");
    return lua_error(L);
  }
  if (wrapper->closed || !wrapper->conn) {
    lua_pushnil(L);
    return 1;
  }
  if (!wrapper->worker) {
    /* ro handle: close inline, no worker. */
    lunet_sqlite_conn_teardown(wrapper);
    lua_pushnil(L);
    return 1;
  }
  /* rw handle: the close is the last node of this FIFO. Accepted work
   * drains first, the inventory finalizes on the owner, and the caller
   * resumes with nil once the physical connection is closed. */
  rw_node_t* node = lunet_alloc(sizeof(rw_node_t));
  if (!node) {
    lua_pushstring(L, "out of memory");
    return lua_error(L);
  }
  memset(node, 0, sizeof(*node));
  node->kind = RW_OP_CLOSE;
  snprintf(node->op, sizeof(node->op), "close");
  node->waiter_L = L;
  node->conn = wrapper->conn;
  node->owner = wrapper;
  lua_pushvalue(L, 1);
  lunet_valref_create_raw(L, node->refs[0]);
  node->nrefs = 1;
  lunet_coref_create(L, node->co_ref);

  if (rw_enqueue(wrapper->worker, node) != 0) {
    node_free(L, node);
    lua_pushnil(L);
    return 1;
  }
  return lua_yield(L, 0);
}

/* query_ro: the ro handle's inline point read. On a readonly=0 wrapper
 * (the :memory: alias, or a deliberate rw route) the call is dispatched
 * to the owner so the one physical connection stays single-owner. */
static int query_ro_inline(lua_State* L, lunet_sqlite_conn_t* wrapper,
                           const char* sql) {
  sqlite3* conn = wrapper->conn;
  sqlite3_stmt* st = NULL;
  int rc = sqlite3_prepare_v2(conn, sql, -1, &st, NULL);
  if (rc != SQLITE_OK) {
    char msg[256];
    snprintf(msg, sizeof(msg), "%s", sqlite3_errmsg(conn));
    int ext = sqlite3_extended_errcode(conn);
    sqlite3_finalize(st);
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message"); lua_pushstring(L, msg); lua_settable(L, -3);
    lua_pushstring(L, "code"); lua_pushinteger(L, rc); lua_settable(L, -3);
    lua_pushstring(L, "extended_code"); lua_pushinteger(L, ext); lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, "query_ro"); lua_settable(L, -3);
    return 2;
  }

  int nparams = 0;
  param_t* params = collect_params(L, 3, &nparams);
  if (nparams < 0) {
    sqlite3_finalize(st);
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message"); lua_pushstring(L, "out of memory"); lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, "query_ro"); lua_settable(L, -3);
    return 2;
  }

  char bind_err[128] = "";
  rc = bind_params(st, params, nparams, bind_err, sizeof(bind_err));
  if (rc != SQLITE_OK) {
    char msg[256];
    snprintf(msg, sizeof(msg), "%s", bind_err[0] ? bind_err : sqlite3_errmsg(conn));
    int ext = sqlite3_extended_errcode(conn);
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message"); lua_pushstring(L, msg); lua_settable(L, -3);
    lua_pushstring(L, "code"); lua_pushinteger(L, rc); lua_settable(L, -3);
    lua_pushstring(L, "extended_code"); lua_pushinteger(L, ext); lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, "query_ro"); lua_settable(L, -3);
    sqlite3_finalize(st);
    free_params(params, nparams);
    return 2;
  }

  sqlite_result_t res;
  memset(&res, 0, sizeof(res));
  char step_err[256] = "";
  rc = stage_rows(st, conn, &res, step_err, sizeof(step_err));
  sqlite3_finalize(st);
  free_params(params, nparams);
  if (rc != SQLITE_DONE) {
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message"); lua_pushstring(L, step_err); lua_settable(L, -3);
    lua_pushstring(L, "code"); lua_pushinteger(L, rc); lua_settable(L, -3);
    lua_pushstring(L, "extended_code"); lua_pushinteger(L, sqlite3_extended_errcode(conn)); lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, "query_ro"); lua_settable(L, -3);
    free_result(&res);
    return 2;
  }
  push_result(L, &res);
  lua_pushnil(L);
  free_result(&res);
  return 2;
}

int lunet_db_query_ro(lua_State* L) {
  if (lunet_ensure_coroutine(L, "query_ro")) {
    return lua_error(L);
  }
  lunet_sqlite_conn_t* wrapper =
      (lunet_sqlite_conn_t*)luaL_testudata(L, 1, LUNET_SQLITE_CONN_MT);
  if (!wrapper) {
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message"); lua_pushstring(L, "query_ro requires a connection"); lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, "query_ro"); lua_settable(L, -3);
    return 2;
  }
  if (wrapper->closed || !wrapper->conn) {
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message"); lua_pushstring(L, "connection is closed"); lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, "query_ro"); lua_settable(L, -3);
    return 2;
  }
  if (lua_gettop(L) < 2 || lua_type(L, 2) != LUA_TSTRING ||
      lua_strlen(L, 2) == 0) {
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message"); lua_pushstring(L, "query_ro requires a SQL string"); lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, "query_ro"); lua_settable(L, -3);
    return 2;
  }

  /* File-backed ro: inline, synchronous, no yield. The :memory: alias
   * (readonly=0) routes through the owner worker so the shared physical
   * connection never has two owners at once. */
  if (wrapper->readonly) {
    return query_ro_inline(L, wrapper, lua_tostring(L, 2));
  }
  return queue_rw_op(L, wrapper, RW_OP_QUERY_RO, "query_ro", NULL, lua_tostring(L, 2));
}

/* The four generic rw calls. One node shape, four op names. */
static int queue_rw_op(lua_State* L, lunet_sqlite_conn_t* wrapper,
                       rw_op_kind_t kind, const char* opname,
                       struct lunet_sqlite_stmt_s* stmt, const char* sql) {
  rw_node_t* node = lunet_alloc(sizeof(rw_node_t));
  if (!node) {
    lua_pushstring(L, "out of memory");
    return lua_error(L);
  }
  memset(node, 0, sizeof(*node));
  node->kind = kind;
  snprintf(node->op, sizeof(node->op), "%s", opname);
  node->waiter_L = L;
  node->conn = wrapper->conn;
  node->owner = wrapper;
  node->stmt = stmt;

  if (stmt) {
    /* Varargs bind per call, snapshotted before dispatch: concurrent
     * callers of the same statement keep their own parameters. */
    node->params = collect_params(L, 2, &node->nparams);
  } else if (strcmp(opname, "query_params") == 0 ||
             strcmp(opname, "exec_params") == 0) {
    /* An explicit array-style binding table. */
    node->params = collect_params_table(L, 3, &node->nparams);
    if (node->nparams == -2) {
      lunet_free_nonnull(node);
      lua_pushnil(L);
      lua_newtable(L);
      lua_pushstring(L, "message");
      lua_pushfstring(L, "%s requires a params table", opname);
      lua_settable(L, -3);
      lua_pushstring(L, "op");
      lua_pushstring(L, opname);
      lua_settable(L, -3);
      return 2;
    }
  } else {
    node->sql = lunet_strdup_local(sql);
    if (!node->sql) { /* fall through to OOM handling below */
      lunet_free_nonnull(node);
      lua_pushstring(L, "out of memory");
      return lua_error(L);
    }
    node->params = collect_params(L, 3, &node->nparams);
  }
  if (node->nparams < 0) {
    lunet_free_nonnull(node->sql);
    lunet_free_nonnull(node);
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message"); lua_pushstring(L, "out of memory"); lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, opname); lua_settable(L, -3);
    return 2;
  }

  /* For SQL-carrying kinds the node needs the text itself. */
  if (!stmt && !node->sql) {
    node->sql = lunet_strdup_local(sql ? sql : "");
    if (!node->sql) {
      free_params(node->params, node->nparams);
      lunet_free_nonnull(node);
      lua_pushstring(L, "out of memory");
      return lua_error(L);
    }
  }

  /* Pin the flight: statement and connection userdatas must outlive the
   * worker's touch, so GC cannot collect them mid-operation. */
  if (stmt) {
    lua_pushvalue(L, 1);
    lunet_valref_create_raw(L, node->refs[0]);
    lua_rawgeti(L, LUA_REGISTRYINDEX, stmt->conn_ref);
    lunet_valref_create_raw(L, node->refs[1]);
    node->nrefs = 2;
  } else {
    lua_pushvalue(L, 1);
    lunet_valref_create_raw(L, node->refs[0]);
    node->nrefs = 1;
  }

  lunet_coref_create(L, node->co_ref);

  if (rw_enqueue(wrapper->worker, node) != 0) {
    node_free(L, node);
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message"); lua_pushstring(L, "connection is closed"); lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, opname); lua_settable(L, -3);
    return 2;
  }
  return lua_yield(L, 0);
}

static int rw_dispatch_with_sql(lua_State* L, rw_op_kind_t kind,
                                const char* opname, int use_param_table) {
  if (lunet_ensure_coroutine(L, opname)) {
    return lua_error(L);
  }
  lunet_sqlite_conn_t* wrapper =
      (lunet_sqlite_conn_t*)luaL_testudata(L, 1, LUNET_SQLITE_CONN_MT);
  if (!wrapper) {
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message");
    lua_pushfstring(L, "%s requires a valid connection", opname);
    lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, opname); lua_settable(L, -3);
    return 2;
  }
  if (lua_gettop(L) < 2 || lua_type(L, 2) != LUA_TSTRING ||
      lua_strlen(L, 2) == 0) {
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message");
    lua_pushfstring(L, "%s requires a SQL string", opname);
    lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, opname); lua_settable(L, -3);
    return 2;
  }
  if (wrapper->readonly) {
    push_route_err(L, opname);
    return 2;
  }
  if (wrapper->closed || !wrapper->conn) {
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message"); lua_pushstring(L, "connection is closed"); lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, opname); lua_settable(L, -3);
    return 2;
  }
  const char* sql = lua_tostring(L, 2);
  (void)use_param_table;
  return queue_rw_op(L, wrapper, kind, opname, NULL, sql);
}

int lunet_db_query(lua_State* L) {
  return rw_dispatch_with_sql(L, RW_OP_QUERY, "query", 0);
}

int lunet_db_exec(lua_State* L) {
  return rw_dispatch_with_sql(L, RW_OP_EXEC, "exec", 0);
}

int lunet_db_query_params(lua_State* L) {
  return rw_dispatch_with_sql(L, RW_OP_QUERY, "query_params", 1);
}

int lunet_db_exec_params(lua_State* L) {
  return rw_dispatch_with_sql(L, RW_OP_EXEC, "exec_params", 1);
}

/* ------------------------------------------------------------------ */
/* Prepare: the named-statement inventory lives on the rw worker too.    */
/* ------------------------------------------------------------------ */

int lunet_db_prepare(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.prepare")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 2 || lua_type(L, 2) != LUA_TSTRING ||
      lua_strlen(L, 2) == 0) {
    lua_pushstring(L, "db.prepare requires a non-empty SQL string");
    return lua_error(L);
  }
  lunet_sqlite_conn_t* wrapper =
      (lunet_sqlite_conn_t*)luaL_testudata(L, 1, LUNET_SQLITE_CONN_MT);
  if (!wrapper) {
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message"); lua_pushstring(L, "db.prepare requires a valid connection"); lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, "prepare"); lua_settable(L, -3);
    return 2;
  }
  if (wrapper->readonly) {
    push_route_err(L, "prepare");
    return 2;
  }
  if (wrapper->closed || !wrapper->conn) {
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message"); lua_pushstring(L, "connection is closed"); lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, "prepare"); lua_settable(L, -3);
    return 2;
  }

  register_stmt_metatable(L);

  /* The statement userdata exists before the worker compiles it: the
   * connection's open-statement list is touched only on the loop thread,
   * the vendor statement is filled in by the owner. */
  struct lunet_sqlite_stmt_s* s =
      (struct lunet_sqlite_stmt_s*)lua_newuserdata(L, sizeof(struct lunet_sqlite_stmt_s));
  memset(s, 0, sizeof(*s));
  s->conn = wrapper;
  luaL_getmetatable(L, LUNET_SQLITE_STMT_MT);
  lua_setmetatable(L, -2);
  conn_track_stmt(wrapper, s);
  lua_pushvalue(L, 1);
  lunet_valref_create_raw(L, s->conn_ref);

  const char* sql = lua_tostring(L, 2);
  rw_node_t* node = lunet_alloc(sizeof(rw_node_t));
  if (!node) {
    node_free_stmt_hazard(L, s);
    lua_pushstring(L, "out of memory");
    return lua_error(L);
  }
  memset(node, 0, sizeof(*node));
  node->kind = RW_OP_PREPARE;
  snprintf(node->op, sizeof(node->op), "prepare");
  node->waiter_L = L;
  node->conn = wrapper->conn;
  node->owner = wrapper;
  node->stmt = s;
  node->sql = lunet_strdup_local(sql);
  if (!node->sql) {
    node_free_stmt_hazard(L, s);
    lunet_free_nonnull(node);
    lua_pushstring(L, "out of memory");
    return lua_error(L);
  }

  /* Pin the statement userdata: it cannot be handed over if collected. */
  lua_pushvalue(L, 3);
  lunet_valref_create_raw(L, node->refs[0]);
  node->nrefs = 1;
  lunet_coref_create(L, node->co_ref);

  if (rw_enqueue(wrapper->worker, node) != 0) {
    node_free(L, node);
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message"); lua_pushstring(L, "connection is closed"); lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, "prepare"); lua_settable(L, -3);
    return 2;
  }
  return lua_yield(L, 0);
}

/* A prepare that never reaches the queue: drop the registered statement
 * and hand back no usable handle. */
static void node_free_stmt_hazard(lua_State* L, struct lunet_sqlite_stmt_s* s) {
  (void)L;
  s->closed = 1;
  if (s->stmt) {
    sqlite3_finalize(s->stmt);
    s->stmt = NULL;
  }
  if (s->conn) conn_untrack_stmt(s->conn, s);
}

/* stmt:query / stmt:exec shared body: validate the handle, snapshot the
 * varargs, queue the call. index 1 is the statement userdata. */
static int stmt_dispatch(lua_State* L, rw_op_kind_t kind) {
  struct lunet_sqlite_stmt_s* s =
      (struct lunet_sqlite_stmt_s*)luaL_testudata(L, 1, LUNET_SQLITE_STMT_MT);
  const char* opname = (kind == RW_OP_STMT_EXEC) ? "stmt_exec" : "stmt_query";

  if (!s) {
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message"); lua_pushstring(L, "stmt requires a prepared statement"); lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, opname); lua_settable(L, -3);
    return 2;
  }
  if (s->closed || s->stmt == NULL || !s->conn) {
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message"); lua_pushstring(L, "statement is closed"); lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, opname); lua_settable(L, -3);
    return 2;
  }
  lunet_sqlite_conn_t* wrapper = s->conn;
  if (wrapper->closed || !wrapper->conn) {
    lua_pushnil(L);
    lua_newtable(L);
    lua_pushstring(L, "message"); lua_pushstring(L, "connection is closed"); lua_settable(L, -3);
    lua_pushstring(L, "op"); lua_pushstring(L, opname); lua_settable(L, -3);
    return 2;
  }
  return queue_rw_op(L, wrapper, kind, opname, s, NULL);
}

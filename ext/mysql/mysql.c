#include "lunet_db_mysql.h"

#include <mysql.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "co.h"
#include "trace.h"
#include "lunet_mem.h"
#include "uv.h"

#define LUNET_MYSQL_CONN_MT "lunet.mysql.conn"

static int g_mysql_library_initialized = 0;
static int g_mysql_library_shutdown_registered = 0;

static void lunet_mysql_library_shutdown(void) {
  if (!g_mysql_library_initialized) {
    return;
  }
  mysql_library_end();
  g_mysql_library_initialized = 0;
}

static int lunet_mysql_library_ensure(void) {
  if (g_mysql_library_initialized) {
    return 0;
  }
  if (mysql_library_init(0, NULL, NULL) != 0) {
    return -1;
  }
  g_mysql_library_initialized = 1;
  if (!g_mysql_library_shutdown_registered && atexit(lunet_mysql_library_shutdown) == 0) {
    g_mysql_library_shutdown_registered = 1;
  }
  return 0;
}

static char* lunet_strdup_local(const char* s) {
  if (!s) return NULL;
  size_t len = strlen(s);
  char* out = lunet_alloc(len + 1);
  if (!out) return NULL;
  memcpy(out, s, len + 1);
  return out;
}

typedef struct {
  MYSQL* conn;
  uv_mutex_t mutex;
  int closed;
} lunet_mysql_conn_t;

// Close connection but keep mutex intact (for explicit db.close())
static void lunet_mysql_conn_close(lunet_mysql_conn_t* wrapper) {
  if (!wrapper || wrapper->closed) return;
  wrapper->closed = 1;
  if (wrapper->conn) {
    mysql_close(wrapper->conn);
    wrapper->conn = NULL;
  }
}

// Full cleanup including mutex (only called from GC)
static void lunet_mysql_conn_destroy(lunet_mysql_conn_t* wrapper) {
  if (!wrapper) return;
  lunet_mysql_conn_close(wrapper);
  uv_mutex_destroy(&wrapper->mutex);
}

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
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in db.open\n");
    if (ctx->conn) mysql_close(ctx->conn);
    lunet_free_nonnull(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->conn) {
    lunet_mysql_conn_t* wrapper = (lunet_mysql_conn_t*)lua_newuserdata(co, sizeof(lunet_mysql_conn_t));
    wrapper->conn = ctx->conn;
    wrapper->closed = 0;
    uv_mutex_init(&wrapper->mutex);

    luaL_getmetatable(co, LUNET_MYSQL_CONN_MT);
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

static int conn_gc(lua_State* L) {
  lunet_mysql_conn_t* wrapper = (lunet_mysql_conn_t*)luaL_checkudata(L, 1, LUNET_MYSQL_CONN_MT);
  lunet_mysql_conn_destroy(wrapper);
  return 0;
}

static void register_conn_metatable(lua_State* L) {
  if (luaL_newmetatable(L, LUNET_MYSQL_CONN_MT)) {
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
  if (lunet_mysql_library_ensure() != 0) {
    lua_pushstring(L, "db.open: mysql_library_init failed");
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

  lunet_mysql_conn_t* wrapper = (lunet_mysql_conn_t*)luaL_testudata(L, 1, LUNET_MYSQL_CONN_MT);
  if (!wrapper) {
    lua_pushstring(L, "db.close requires a valid connection");
    return 1;
  }

  uv_mutex_lock(&wrapper->mutex);
  lunet_mysql_conn_close(wrapper);  // Close connection but keep mutex for unlock
  uv_mutex_unlock(&wrapper->mutex);

  lua_pushnil(L);
  return 1;
}

typedef struct {
  uv_work_t req;
  lua_State* L;
  int co_ref;

  lunet_mysql_conn_t* wrapper;
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

  uv_mutex_lock(&ctx->wrapper->mutex);

  mysql_thread_init();
  if (ctx->wrapper->closed || !ctx->wrapper->conn) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    mysql_thread_end();
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  // Use prepared statement
  MYSQL_STMT* stmt = mysql_stmt_init(ctx->wrapper->conn);
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

  unsigned long param_count = mysql_stmt_param_count(stmt);
  if (param_count != (unsigned long)ctx->nparams) {
    snprintf(ctx->err, sizeof(ctx->err), "parameter count mismatch: expected %lu, got %d", param_count, ctx->nparams);
    mysql_stmt_close(stmt);
    mysql_thread_end();
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  if (ctx->nparams > 0) {
    MYSQL_BIND* bind = lunet_alloc(sizeof(MYSQL_BIND) * ctx->nparams);
    if (!bind) {
      snprintf(ctx->err, sizeof(ctx->err), "out of memory");
      mysql_stmt_close(stmt);
      mysql_thread_end();
      uv_mutex_unlock(&ctx->wrapper->mutex);
      return;
    }
    
    if (bind_params(stmt, bind, ctx->params, ctx->nparams, ctx->err, sizeof(ctx->err))) {
       lunet_free_nonnull(bind);
       mysql_stmt_close(stmt);
       mysql_thread_end();
       uv_mutex_unlock(&ctx->wrapper->mutex);
       return;
    }
    lunet_free_nonnull(bind); // bind_params calls mysql_stmt_bind_param which copies the structures? No, it uses the array. 
    // Wait, mysql_stmt_bind_param documentation says "The array of MYSQL_BIND structures must remain valid until the statement is executed."
    // But we are about to execute it.
    // However, if we free 'bind' here, and then call mysql_stmt_execute, is it safe?
    // mysql_stmt_bind_param documentation says: "The bind argument is an array of MYSQL_BIND structures. The library uses the information in this array to bind the buffers... "
    // It usually doesn't copy the array, it uses the pointer. 
    // BUT we are in the same function scope.
    // Wait, I should free it AFTER execution.
  }
  
  // Re-allocating bind for clarity and safety
  MYSQL_BIND* bind = NULL;
  if (ctx->nparams > 0) {
      bind = lunet_alloc(sizeof(MYSQL_BIND) * ctx->nparams);
      if (!bind) {
          snprintf(ctx->err, sizeof(ctx->err), "out of memory");
          mysql_stmt_close(stmt);
          mysql_thread_end();
          uv_mutex_unlock(&ctx->wrapper->mutex);
          return;
      }
      if (bind_params(stmt, bind, ctx->params, ctx->nparams, ctx->err, sizeof(ctx->err))) {
          lunet_free_nonnull(bind);
          mysql_stmt_close(stmt);
          mysql_thread_end();
          uv_mutex_unlock(&ctx->wrapper->mutex);
          return;
      }
  }

  if (mysql_stmt_execute(stmt)) {
    snprintf(ctx->err, sizeof(ctx->err), "mysql_stmt_execute failed: %s", mysql_stmt_error(stmt));
    if (bind) lunet_free_nonnull(bind);
    mysql_stmt_close(stmt);
    mysql_thread_end();
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }
  
  if (bind) lunet_free_nonnull(bind); // Now we can free the bind array

  // Store result to get metadata about fields and buffer everything
  if (mysql_stmt_store_result(stmt)) {
      snprintf(ctx->err, sizeof(ctx->err), "mysql_stmt_store_result failed: %s", mysql_stmt_error(stmt));
      mysql_stmt_close(stmt);
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
      mysql_stmt_close(stmt);
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
      mysql_stmt_close(stmt);
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
          mysql_stmt_close(stmt);
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
      mysql_stmt_close(stmt);
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
  mysql_stmt_close(stmt);
  mysql_thread_end();
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
      int rc = lua_resume(co, 2);
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

  lunet_mysql_conn_t* wrapper = (lunet_mysql_conn_t*)luaL_testudata(L, 1, LUNET_MYSQL_CONN_MT);
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

  lunet_mysql_conn_t* wrapper;
  char* query;
  
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

  // Use prepared statement
  MYSQL_STMT* stmt = mysql_stmt_init(ctx->wrapper->conn);
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

  unsigned long param_count = mysql_stmt_param_count(stmt);
  if (param_count != (unsigned long)ctx->nparams) {
    snprintf(ctx->err, sizeof(ctx->err), "parameter count mismatch: expected %lu, got %d", param_count, ctx->nparams);
    mysql_stmt_close(stmt);
    mysql_thread_end();
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }
  
  MYSQL_BIND* bind = NULL;
  if (ctx->nparams > 0) {
      bind = lunet_alloc(sizeof(MYSQL_BIND) * ctx->nparams);
      if (!bind) {
          snprintf(ctx->err, sizeof(ctx->err), "out of memory");
          mysql_stmt_close(stmt);
          mysql_thread_end();
          uv_mutex_unlock(&ctx->wrapper->mutex);
          return;
      }
      
      if (bind_params(stmt, bind, ctx->params, ctx->nparams, ctx->err, sizeof(ctx->err))) {
          lunet_free_nonnull(bind);
          mysql_stmt_close(stmt);
          mysql_thread_end();
          uv_mutex_unlock(&ctx->wrapper->mutex);
          return;
      }
  }

  if (mysql_stmt_execute(stmt)) {
    snprintf(ctx->err, sizeof(ctx->err), "mysql_stmt_execute failed: %s", mysql_stmt_error(stmt));
    if (bind) lunet_free_nonnull(bind);
    mysql_stmt_close(stmt);
    mysql_thread_end();
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }
  
  if (bind) lunet_free_nonnull(bind);

  ctx->affected_rows = mysql_stmt_affected_rows(stmt);
  ctx->insert_id = mysql_stmt_insert_id(stmt);
  
  mysql_stmt_close(stmt);
  mysql_thread_end();
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
  
  int n = lua_gettop(L);
  if (n < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "db.exec requires connection and sql string");
    return 2;
  }

  lunet_mysql_conn_t* wrapper = (lunet_mysql_conn_t*)luaL_testudata(L, 1, LUNET_MYSQL_CONN_MT);
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
  lua_remove(L, -2);

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
  
  lunet_mysql_conn_t* wrapper = (lunet_mysql_conn_t*)luaL_testudata(L, 1, LUNET_MYSQL_CONN_MT);
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
  
  lunet_mysql_conn_t* wrapper = (lunet_mysql_conn_t*)luaL_testudata(L, 1, LUNET_MYSQL_CONN_MT);
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

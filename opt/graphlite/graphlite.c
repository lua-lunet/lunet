#include "lunet_graphlite.h"

#include <stdlib.h>
#include <string.h>

#include "co.h"
#include "trace.h"
#include "lunet_mem.h"
#include "uv.h"

#if defined(_WIN32) || defined(__CYGWIN__)
#include <windows.h>
typedef HMODULE gl_lib_t;
#define GL_DLOPEN(p) LoadLibraryA(p)
#define GL_DLSYM(h, s) ((void*)GetProcAddress((h), (s)))
#define GL_DLCLOSE(h) FreeLibrary(h)
static const char* gl_dlerror(void) {
  static char buf[256];
  FormatMessageA(FORMAT_MESSAGE_FROM_SYSTEM, NULL, GetLastError(),
                 0, buf, sizeof(buf), NULL);
  return buf;
}
#else
#include <dlfcn.h>
typedef void* gl_lib_t;
#define GL_DLOPEN(p) dlopen((p), RTLD_NOW | RTLD_LOCAL)
#define GL_DLSYM(h, s) dlsym((h), (s))
#define GL_DLCLOSE(h) dlclose(h)
static const char* gl_dlerror(void) { return dlerror(); }
#endif

typedef enum {
  GL_SUCCESS = 0,
  GL_NULL_POINTER = 1,
  GL_INVALID_UTF8 = 2,
  GL_DB_OPEN_ERROR = 3,
  GL_SESSION_ERROR = 4,
  GL_QUERY_ERROR = 5,
  GL_PANIC_ERROR = 6,
  GL_JSON_ERROR = 7
} gl_error_code_t;

typedef struct gl_db gl_db_t;

typedef gl_db_t* (*fn_graphlite_open)(const char* path, gl_error_code_t* err);
typedef char* (*fn_graphlite_create_session)(gl_db_t* db, const char* user,
                                             gl_error_code_t* err);
typedef char* (*fn_graphlite_query)(gl_db_t* db, const char* session,
                                    const char* query, gl_error_code_t* err);
typedef gl_error_code_t (*fn_graphlite_close_session)(gl_db_t* db,
                                                       const char* session,
                                                       gl_error_code_t* err);
typedef void (*fn_graphlite_free_string)(char* s);
typedef void (*fn_graphlite_close)(gl_db_t* db);
typedef const char* (*fn_graphlite_version)(void);

typedef struct {
  gl_lib_t handle;
  fn_graphlite_open open;
  fn_graphlite_create_session create_session;
  fn_graphlite_query query;
  fn_graphlite_close_session close_session;
  fn_graphlite_free_string free_string;
  fn_graphlite_close close;
  fn_graphlite_version version;
} gl_vtable_t;

static gl_vtable_t g_gl = {0};

static const char* gl_error_string(gl_error_code_t code) {
  switch (code) {
    case GL_SUCCESS:        return "success";
    case GL_NULL_POINTER:   return "null pointer";
    case GL_INVALID_UTF8:   return "invalid UTF-8";
    case GL_DB_OPEN_ERROR:  return "database open failed";
    case GL_SESSION_ERROR:  return "session error";
    case GL_QUERY_ERROR:    return "query error";
    case GL_PANIC_ERROR:    return "internal panic";
    case GL_JSON_ERROR:     return "JSON serialization error";
  }
  return "unknown error";
}

static int gl_load_library(const char* lib_path, char* err, size_t errsize) {
  if (g_gl.handle) return 0;

  g_gl.handle = GL_DLOPEN(lib_path);
  if (!g_gl.handle) {
    const char* dle = gl_dlerror();
    snprintf(err, errsize, "dlopen: %.200s", dle ? dle : "unknown error");
    return -1;
  }

#define GL_RESOLVE(name)                                                    \
  g_gl.name = (fn_graphlite_##name)GL_DLSYM(g_gl.handle,                   \
                                              "graphlite_" #name);          \
  if (!g_gl.name) {                                                         \
    snprintf(err, errsize, "missing symbol: graphlite_" #name);             \
    GL_DLCLOSE(g_gl.handle);                                                \
    memset(&g_gl, 0, sizeof(g_gl));                                         \
    return -1;                                                              \
  }

  GL_RESOLVE(open)
  GL_RESOLVE(create_session)
  GL_RESOLVE(query)
  GL_RESOLVE(close_session)
  GL_RESOLVE(free_string)
  GL_RESOLVE(close)
  GL_RESOLVE(version)

#undef GL_RESOLVE
  return 0;
}

#define LUNET_GRAPHLITE_CONN_MT "lunet.graphlite.conn"

static char* lunet_strdup_local(const char* s) {
  if (!s) return NULL;
  size_t len = strlen(s);
  char* out = lunet_alloc(len + 1);
  if (!out) return NULL;
  memcpy(out, s, len + 1);
  return out;
}

typedef struct {
  gl_db_t* db;
  uv_mutex_t mutex;
  int closed;
} lunet_gl_conn_t;

static void lunet_gl_conn_close(lunet_gl_conn_t* w) {
  if (!w || w->closed) return;
  w->closed = 1;
  if (w->db && g_gl.close) {
    g_gl.close(w->db);
    w->db = NULL;
  }
}

static void lunet_gl_conn_destroy(lunet_gl_conn_t* w) {
  lunet_gl_conn_close(w);
  if (w) {
    uv_mutex_destroy(&w->mutex);
  }
}

static int conn_gc(lua_State* L) {
  lunet_gl_conn_t* w =
      (lunet_gl_conn_t*)luaL_checkudata(L, 1, LUNET_GRAPHLITE_CONN_MT);
  lunet_gl_conn_destroy(w);
  return 0;
}

static void register_conn_metatable(lua_State* L) {
  if (luaL_newmetatable(L, LUNET_GRAPHLITE_CONN_MT)) {
    lua_pushcfunction(L, conn_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_pop(L, 1);
}

typedef struct {
  uv_work_t req;
  lua_State* L;
  int co_ref;
  gl_db_t* db;
  char err[256];
  char path[1024];
  char lib_path[1024];
} gl_open_ctx_t;

static void gl_open_work_cb(uv_work_t* req) {
  gl_open_ctx_t* ctx = (gl_open_ctx_t*)req->data;

  if (!g_gl.handle) {
    if (gl_load_library(ctx->lib_path, ctx->err, sizeof(ctx->err)) != 0) {
      return;
    }
  }

  gl_error_code_t ec = GL_SUCCESS;
  ctx->db = g_gl.open(ctx->path, &ec);
  if (!ctx->db) {
    snprintf(ctx->err, sizeof(ctx->err), "graphlite_open: %s",
             gl_error_string(ec));
  }
}

static void gl_open_after_cb(uv_work_t* req, int status) {
  gl_open_ctx_t* ctx = (gl_open_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in graphlite.open\n");
    if (ctx->db && g_gl.close) g_gl.close(ctx->db);
    lunet_free_nonnull(ctx);
    return;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->db) {
    lunet_gl_conn_t* w =
        (lunet_gl_conn_t*)lua_newuserdata(co, sizeof(lunet_gl_conn_t));
    w->db = ctx->db;
    w->closed = 0;
    uv_mutex_init(&w->mutex);
    luaL_getmetatable(co, LUNET_GRAPHLITE_CONN_MT);
    lua_setmetatable(co, -2);
    lua_pushnil(co);
  } else {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
  }
  int rc = lunet_co_resume(co, 2);
  if (rc != 0 && rc != LUA_YIELD) {
    const char* e = lua_tostring(co, -1);
    if (e) fprintf(stderr, "lua_resume error in graphlite.open: %s\n", e);
    lua_pop(co, 1);
  }
  lunet_free_nonnull(ctx);
}

int lunet_graphlite_open(lua_State* L) {
  if (lunet_ensure_coroutine(L, "graphlite.open")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 1 || !lua_istable(L, 1)) {
    lua_pushstring(L, "graphlite.open requires params table");
    return lua_error(L);
  }

  register_conn_metatable(L);

  gl_open_ctx_t* ctx = lunet_alloc(sizeof(gl_open_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "graphlite.open: out of memory");
    return lua_error(L);
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->L = L;
  ctx->req.data = ctx;

  lua_getfield(L, 1, "path");
  const char* dbpath = luaL_checkstring(L, -1);
  snprintf(ctx->path, sizeof(ctx->path), "%s", dbpath);
  lua_pop(L, 1);

  lua_getfield(L, 1, "lib");
  const char* libpath = luaL_optstring(L, -1, NULL);
  if (libpath) {
    snprintf(ctx->lib_path, sizeof(ctx->lib_path), "%s", libpath);
  } else {
#if defined(_WIN32)
    snprintf(ctx->lib_path, sizeof(ctx->lib_path), "graphlite_ffi.dll");
#elif defined(__APPLE__)
    snprintf(ctx->lib_path, sizeof(ctx->lib_path), "libgraphlite_ffi.dylib");
#else
    snprintf(ctx->lib_path, sizeof(ctx->lib_path), "libgraphlite_ffi.so");
#endif
  }
  lua_pop(L, 1);

  lunet_coref_create(L, ctx->co_ref);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, gl_open_work_cb,
                           gl_open_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushfstring(L, "graphlite.open: uv_queue_work failed: %s",
                    uv_strerror(ret));
    return lua_error(L);
  }

  return lua_yield(L, 0);
}

int lunet_graphlite_close(lua_State* L) {
  if (lunet_ensure_coroutine(L, "graphlite.close")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 1) {
    lua_pushstring(L, "graphlite.close requires a connection");
    return 1;
  }
  lunet_gl_conn_t* w =
      (lunet_gl_conn_t*)luaL_testudata(L, 1, LUNET_GRAPHLITE_CONN_MT);
  if (!w) {
    lua_pushstring(L, "graphlite.close requires a valid connection");
    return 1;
  }

  uv_mutex_lock(&w->mutex);
  lunet_gl_conn_close(w);
  uv_mutex_unlock(&w->mutex);

  lua_pushnil(L);
  return 1;
}

typedef struct {
  uv_work_t req;
  lua_State* L;
  int co_ref;
  lunet_gl_conn_t* wrapper;
  char* username;
  char* session_id;
  char err[256];
} gl_session_ctx_t;

static void gl_create_session_work_cb(uv_work_t* req) {
  gl_session_ctx_t* ctx = (gl_session_ctx_t*)req->data;

  uv_mutex_lock(&ctx->wrapper->mutex);
  if (ctx->wrapper->closed || !ctx->wrapper->db) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  gl_error_code_t ec = GL_SUCCESS;
  char* sid = g_gl.create_session(ctx->wrapper->db, ctx->username, &ec);
  if (!sid) {
    snprintf(ctx->err, sizeof(ctx->err), "graphlite_create_session: %s",
             gl_error_string(ec));
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }
  ctx->session_id = lunet_strdup_local(sid);
  g_gl.free_string(sid);
  uv_mutex_unlock(&ctx->wrapper->mutex);
}

static void gl_create_session_after_cb(uv_work_t* req, int status) {
  gl_session_ctx_t* ctx = (gl_session_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in graphlite.create_session\n");
    goto cleanup;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->err[0] != '\0') {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
  } else {
    lua_pushstring(co, ctx->session_id);
    lua_pushnil(co);
  }
  {
    int rc = lunet_co_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* e = lua_tostring(co, -1);
      if (e) fprintf(stderr, "lua_resume error in graphlite.create_session: %s\n", e);
      lua_pop(co, 1);
    }
  }

cleanup:
  lunet_free_nonnull(ctx->username);
  lunet_free_nonnull(ctx->session_id);
  lunet_free_nonnull(ctx);
}

int lunet_graphlite_create_session(lua_State* L) {
  if (lunet_ensure_coroutine(L, "graphlite.create_session")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "graphlite.create_session requires connection and username");
    return 2;
  }

  lunet_gl_conn_t* w =
      (lunet_gl_conn_t*)luaL_testudata(L, 1, LUNET_GRAPHLITE_CONN_MT);
  if (!w) {
    lua_pushnil(L);
    lua_pushstring(L, "graphlite.create_session requires a valid connection");
    return 2;
  }
  if (w->closed || !w->db) {
    lua_pushnil(L);
    lua_pushstring(L, "connection is closed");
    return 2;
  }

  const char* username = luaL_checkstring(L, 2);

  gl_session_ctx_t* ctx = lunet_alloc(sizeof(gl_session_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->L = L;
  ctx->req.data = ctx;
  ctx->wrapper = w;
  ctx->username = lunet_strdup_local(username);
  if (!ctx->username) {
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  lunet_coref_create(L, ctx->co_ref);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req,
                           gl_create_session_work_cb,
                           gl_create_session_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lunet_free_nonnull(ctx->username);
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
  lunet_gl_conn_t* wrapper;
  char* session_id;
  char err[256];
} gl_close_session_ctx_t;

static void gl_close_session_work_cb(uv_work_t* req) {
  gl_close_session_ctx_t* ctx = (gl_close_session_ctx_t*)req->data;

  uv_mutex_lock(&ctx->wrapper->mutex);
  if (ctx->wrapper->closed || !ctx->wrapper->db) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  gl_error_code_t ec = GL_SUCCESS;
  g_gl.close_session(ctx->wrapper->db, ctx->session_id, &ec);
  if (ec != GL_SUCCESS) {
    snprintf(ctx->err, sizeof(ctx->err), "graphlite_close_session: %s",
             gl_error_string(ec));
  }
  uv_mutex_unlock(&ctx->wrapper->mutex);
}

static void gl_close_session_after_cb(uv_work_t* req, int status) {
  gl_close_session_ctx_t* ctx = (gl_close_session_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in graphlite.close_session\n");
    goto cleanup;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->err[0] != '\0') {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
  } else {
    lua_pushboolean(co, 1);
    lua_pushnil(co);
  }
  {
    int rc = lunet_co_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* e = lua_tostring(co, -1);
      if (e) fprintf(stderr, "lua_resume error in graphlite.close_session: %s\n", e);
      lua_pop(co, 1);
    }
  }

cleanup:
  lunet_free_nonnull(ctx->session_id);
  lunet_free_nonnull(ctx);
}

int lunet_graphlite_close_session(lua_State* L) {
  if (lunet_ensure_coroutine(L, "graphlite.close_session")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "graphlite.close_session requires connection and session_id");
    return 2;
  }

  lunet_gl_conn_t* w =
      (lunet_gl_conn_t*)luaL_testudata(L, 1, LUNET_GRAPHLITE_CONN_MT);
  if (!w) {
    lua_pushnil(L);
    lua_pushstring(L, "graphlite.close_session requires a valid connection");
    return 2;
  }

  const char* session_id = luaL_checkstring(L, 2);

  gl_close_session_ctx_t* ctx = lunet_alloc(sizeof(gl_close_session_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->L = L;
  ctx->req.data = ctx;
  ctx->wrapper = w;
  ctx->session_id = lunet_strdup_local(session_id);
  if (!ctx->session_id) {
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  lunet_coref_create(L, ctx->co_ref);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req,
                           gl_close_session_work_cb,
                           gl_close_session_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lunet_free_nonnull(ctx->session_id);
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
  lunet_gl_conn_t* wrapper;
  char* session_id;
  char* gql;
  char* result_json;
  char err[256];
} gl_query_ctx_t;

static void gl_query_work_cb(uv_work_t* req) {
  gl_query_ctx_t* ctx = (gl_query_ctx_t*)req->data;

  uv_mutex_lock(&ctx->wrapper->mutex);
  if (ctx->wrapper->closed || !ctx->wrapper->db) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  gl_error_code_t ec = GL_SUCCESS;
  char* json = g_gl.query(ctx->wrapper->db, ctx->session_id, ctx->gql, &ec);
  if (!json) {
    snprintf(ctx->err, sizeof(ctx->err), "graphlite_query: %s",
             gl_error_string(ec));
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }
  ctx->result_json = lunet_strdup_local(json);
  g_gl.free_string(json);
  uv_mutex_unlock(&ctx->wrapper->mutex);
}

static void gl_query_after_cb(uv_work_t* req, int status) {
  gl_query_ctx_t* ctx = (gl_query_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in graphlite.query\n");
    goto cleanup;
  }
  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->err[0] != '\0') {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
  } else {
    lua_pushstring(co, ctx->result_json ? ctx->result_json : "{}");
    lua_pushnil(co);
  }
  {
    int rc = lunet_co_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* e = lua_tostring(co, -1);
      if (e) fprintf(stderr, "lua_resume error in graphlite.query: %s\n", e);
      lua_pop(co, 1);
    }
  }

cleanup:
  lunet_free_nonnull(ctx->session_id);
  lunet_free_nonnull(ctx->gql);
  lunet_free_nonnull(ctx->result_json);
  lunet_free_nonnull(ctx);
}

int lunet_graphlite_query(lua_State* L) {
  if (lunet_ensure_coroutine(L, "graphlite.query")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 3) {
    lua_pushnil(L);
    lua_pushstring(L,
        "graphlite.query requires connection, session_id, and GQL string");
    return 2;
  }

  lunet_gl_conn_t* w =
      (lunet_gl_conn_t*)luaL_testudata(L, 1, LUNET_GRAPHLITE_CONN_MT);
  if (!w) {
    lua_pushnil(L);
    lua_pushstring(L, "graphlite.query requires a valid connection");
    return 2;
  }
  if (w->closed || !w->db) {
    lua_pushnil(L);
    lua_pushstring(L, "connection is closed");
    return 2;
  }

  const char* session_id = luaL_checkstring(L, 2);
  const char* gql = luaL_checkstring(L, 3);

  gl_query_ctx_t* ctx = lunet_alloc(sizeof(gl_query_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->L = L;
  ctx->req.data = ctx;
  ctx->wrapper = w;
  ctx->session_id = lunet_strdup_local(session_id);
  ctx->gql = lunet_strdup_local(gql);
  if (!ctx->session_id || !ctx->gql) {
    lunet_free_nonnull(ctx->session_id);
    lunet_free_nonnull(ctx->gql);
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  lunet_coref_create(L, ctx->co_ref);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, gl_query_work_cb,
                           gl_query_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lunet_free_nonnull(ctx->session_id);
    lunet_free_nonnull(ctx->gql);
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(ret));
    return 2;
  }

  return lua_yield(L, 0);
}

int lunet_graphlite_version(lua_State* L) {
  if (!g_gl.version) {
    lua_pushstring(L, "graphlite library not loaded");
    return 1;
  }
  const char* v = g_gl.version();
  lua_pushstring(L, v ? v : "unknown");
  return 1;
}

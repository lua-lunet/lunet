#include "lunet_db_graphlite.h"

#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "co.h"
#include "lunet_mem.h"
#include "trace.h"
#include "uv.h"

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#ifndef lua_absindex
#define lua_absindex(L, i) ((i) > 0 || (i) <= LUA_REGISTRYINDEX ? (i) : lua_gettop(L) + (i) + 1)
#endif
#ifndef lua_rawlen
#define lua_rawlen(L, i) lua_objlen((L), (i))
#endif

#define LUNET_GRAPHLITE_CONN_MT "lunet.graphlite.conn"

typedef int graphlite_error_code_t;

typedef void* (*graphlite_open_fn)(const char* path, graphlite_error_code_t* error_out);
typedef char* (*graphlite_create_session_fn)(void* db, const char* username, graphlite_error_code_t* error_out);
typedef char* (*graphlite_query_fn)(void* db,
                                    const char* session_id,
                                    const char* query,
                                    graphlite_error_code_t* error_out);
typedef graphlite_error_code_t (*graphlite_close_session_fn)(void* db,
                                                             const char* session_id,
                                                             graphlite_error_code_t* error_out);
typedef void (*graphlite_free_string_fn)(char* s);
typedef void (*graphlite_close_fn)(void* db);
typedef const char* (*graphlite_version_fn)(void);

typedef struct {
  int initialized;
  char loaded_from[1024];
#if defined(_WIN32)
  HMODULE handle;
#else
  void* handle;
#endif
  graphlite_open_fn graphlite_open;
  graphlite_create_session_fn graphlite_create_session;
  graphlite_query_fn graphlite_query;
  graphlite_close_session_fn graphlite_close_session;
  graphlite_free_string_fn graphlite_free_string;
  graphlite_close_fn graphlite_close;
  graphlite_version_fn graphlite_version;
} graphlite_api_t;

static graphlite_api_t g_graphlite_api;
static uv_once_t g_graphlite_api_once = UV_ONCE_INIT;
static uv_mutex_t g_graphlite_api_mutex;

typedef struct {
  void* db;
  char* session_id;
  uv_mutex_t mutex;
  int closed;
} lunet_graphlite_conn_t;

typedef struct {
  uv_work_t req;
  lua_State* L;
  int co_ref;

  void* db;
  char* session_id;
  char db_path[1024];
  char username[128];
  char library_path[2048];
  char err[256];
} db_open_ctx_t;

typedef struct {
  uv_work_t req;
  lua_State* L;
  int co_ref;

  lunet_graphlite_conn_t* wrapper;
  char* query;
  char* json_result;
  char err[256];
} db_query_ctx_t;

typedef struct {
  uv_work_t req;
  lua_State* L;
  int co_ref;

  lunet_graphlite_conn_t* wrapper;
  char* query;
  char* json_result;
  char err[256];
} db_exec_ctx_t;

typedef struct {
  const char* cur;
  const char* end;
  char err[256];
} graphlite_json_parser_t;

static char* lunet_strdup_local(const char* s) {
  if (!s) {
    return NULL;
  }
  size_t len = strlen(s);
  char* out = lunet_alloc(len + 1);
  if (!out) {
    return NULL;
  }
  memcpy(out, s, len + 1);
  return out;
}

static const char* graphlite_error_name(graphlite_error_code_t code) {
  switch (code) {
    case 0:
      return "Success";
    case 1:
      return "NullPointer";
    case 2:
      return "InvalidUtf8";
    case 3:
      return "DatabaseOpenError";
    case 4:
      return "SessionError";
    case 5:
      return "QueryError";
    case 6:
      return "PanicError";
    case 7:
      return "JsonError";
    default:
      return "UnknownError";
  }
}

static const char* graphlite_default_library_name(void) {
#if defined(_WIN32)
  return "graphlite_ffi.dll";
#elif defined(__APPLE__)
  return "libgraphlite_ffi.dylib";
#else
  return "libgraphlite_ffi.so";
#endif
}

static void graphlite_api_init_once(void) {
  memset(&g_graphlite_api, 0, sizeof(g_graphlite_api));
  uv_mutex_init(&g_graphlite_api_mutex);
}

#if defined(_WIN32)
static void graphlite_windows_error(DWORD code, char* err, size_t errsize) {
  if (!err || errsize == 0) {
    return;
  }
  LPSTR msg = NULL;
  DWORD flags = FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS;
  DWORD len = FormatMessageA(flags,
                             NULL,
                             code,
                             MAKELANGID(LANG_NEUTRAL, SUBLANG_DEFAULT),
                             (LPSTR)&msg,
                             0,
                             NULL);
  if (len > 0 && msg) {
    snprintf(err, errsize, "%s", msg);
    LocalFree(msg);
    return;
  }
  snprintf(err, errsize, "Windows error code %lu", (unsigned long)code);
}
#endif

static void* graphlite_load_library(const char* path, char* err, size_t errsize) {
#if defined(_WIN32)
  HMODULE module = LoadLibraryA(path);
  if (!module) {
    graphlite_windows_error(GetLastError(), err, errsize);
    return NULL;
  }
  return (void*)module;
#else
  void* handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!handle) {
    const char* dlerr = dlerror();
    snprintf(err, errsize, "%s", dlerr ? dlerr : "dlopen failed");
    return NULL;
  }
  return handle;
#endif
}

static void graphlite_close_library(void* handle) {
  if (!handle) {
    return;
  }
#if defined(_WIN32)
  FreeLibrary((HMODULE)handle);
#else
  dlclose(handle);
#endif
}

static void* graphlite_lookup_symbol(void* handle, const char* symbol, char* err, size_t errsize) {
#if defined(_WIN32)
  FARPROC proc = GetProcAddress((HMODULE)handle, symbol);
  if (!proc) {
    char win_err[128] = {0};
    graphlite_windows_error(GetLastError(), win_err, sizeof(win_err));
    snprintf(err, errsize, "missing symbol %s: %s", symbol, win_err);
    return NULL;
  }
  return (void*)proc;
#else
  dlerror();
  void* proc = dlsym(handle, symbol);
  const char* dlerr = dlerror();
  if (dlerr != NULL) {
    snprintf(err, errsize, "missing symbol %s: %s", symbol, dlerr);
    return NULL;
  }
  return proc;
#endif
}

static int graphlite_api_load(const char* library_path, char* err, size_t errsize) {
  uv_once(&g_graphlite_api_once, graphlite_api_init_once);

  uv_mutex_lock(&g_graphlite_api_mutex);
  if (g_graphlite_api.initialized) {
    uv_mutex_unlock(&g_graphlite_api_mutex);
    return 0;
  }

  const char* env_lib = getenv("LUNET_GRAPHLITE_LIB");
  const char* candidates[4];
  int candidate_count = 0;
  if (library_path && library_path[0] != '\0') {
    candidates[candidate_count++] = library_path;
  }
  if (env_lib && env_lib[0] != '\0') {
    if (!(library_path && library_path[0] != '\0' && strcmp(library_path, env_lib) == 0)) {
      candidates[candidate_count++] = env_lib;
    }
  }
  candidates[candidate_count++] = graphlite_default_library_name();

  void* handle = NULL;
  char last_err[256] = {0};
  const char* loaded_from = NULL;
  for (int i = 0; i < candidate_count; i++) {
    char load_err[256] = {0};
    handle = graphlite_load_library(candidates[i], load_err, sizeof(load_err));
    if (handle) {
      loaded_from = candidates[i];
      break;
    }
    snprintf(last_err, sizeof(last_err), "%s", load_err);
  }

  if (!handle) {
    snprintf(err,
             errsize,
             "failed to load GraphLite shared library. last error: %s",
             last_err[0] ? last_err : "unknown loader error");
    uv_mutex_unlock(&g_graphlite_api_mutex);
    return -1;
  }

  g_graphlite_api.graphlite_open =
      (graphlite_open_fn)graphlite_lookup_symbol(handle, "graphlite_open", err, errsize);
  if (!g_graphlite_api.graphlite_open) {
    graphlite_close_library(handle);
    uv_mutex_unlock(&g_graphlite_api_mutex);
    return -1;
  }
  g_graphlite_api.graphlite_create_session =
      (graphlite_create_session_fn)graphlite_lookup_symbol(handle, "graphlite_create_session", err, errsize);
  if (!g_graphlite_api.graphlite_create_session) {
    graphlite_close_library(handle);
    uv_mutex_unlock(&g_graphlite_api_mutex);
    return -1;
  }
  g_graphlite_api.graphlite_query =
      (graphlite_query_fn)graphlite_lookup_symbol(handle, "graphlite_query", err, errsize);
  if (!g_graphlite_api.graphlite_query) {
    graphlite_close_library(handle);
    uv_mutex_unlock(&g_graphlite_api_mutex);
    return -1;
  }
  g_graphlite_api.graphlite_close_session =
      (graphlite_close_session_fn)graphlite_lookup_symbol(handle, "graphlite_close_session", err, errsize);
  if (!g_graphlite_api.graphlite_close_session) {
    graphlite_close_library(handle);
    uv_mutex_unlock(&g_graphlite_api_mutex);
    return -1;
  }
  g_graphlite_api.graphlite_free_string =
      (graphlite_free_string_fn)graphlite_lookup_symbol(handle, "graphlite_free_string", err, errsize);
  if (!g_graphlite_api.graphlite_free_string) {
    graphlite_close_library(handle);
    uv_mutex_unlock(&g_graphlite_api_mutex);
    return -1;
  }
  g_graphlite_api.graphlite_close =
      (graphlite_close_fn)graphlite_lookup_symbol(handle, "graphlite_close", err, errsize);
  if (!g_graphlite_api.graphlite_close) {
    graphlite_close_library(handle);
    uv_mutex_unlock(&g_graphlite_api_mutex);
    return -1;
  }
  g_graphlite_api.graphlite_version =
      (graphlite_version_fn)graphlite_lookup_symbol(handle, "graphlite_version", err, errsize);
  if (!g_graphlite_api.graphlite_version) {
    graphlite_close_library(handle);
    uv_mutex_unlock(&g_graphlite_api_mutex);
    return -1;
  }

  g_graphlite_api.initialized = 1;
#if defined(_WIN32)
  g_graphlite_api.handle = (HMODULE)handle;
#else
  g_graphlite_api.handle = handle;
#endif
  snprintf(g_graphlite_api.loaded_from,
           sizeof(g_graphlite_api.loaded_from),
           "%s",
           loaded_from ? loaded_from : graphlite_default_library_name());

  uv_mutex_unlock(&g_graphlite_api_mutex);
  return 0;
}

static void lunet_graphlite_conn_close(lunet_graphlite_conn_t* wrapper) {
  if (!wrapper || wrapper->closed) {
    return;
  }

  wrapper->closed = 1;
  if (wrapper->db && g_graphlite_api.initialized) {
    if (wrapper->session_id && g_graphlite_api.graphlite_close_session) {
      graphlite_error_code_t code = 0;
      (void)g_graphlite_api.graphlite_close_session(wrapper->db, wrapper->session_id, &code);
    }
    g_graphlite_api.graphlite_close(wrapper->db);
    wrapper->db = NULL;
  }
  lunet_free_nonnull(wrapper->session_id);
  wrapper->session_id = NULL;
}

static void lunet_graphlite_conn_destroy(lunet_graphlite_conn_t* wrapper) {
  if (!wrapper) {
    return;
  }
  lunet_graphlite_conn_close(wrapper);
  uv_mutex_destroy(&wrapper->mutex);
}

static int conn_gc(lua_State* L) {
  lunet_graphlite_conn_t* wrapper = (lunet_graphlite_conn_t*)luaL_checkudata(L, 1, LUNET_GRAPHLITE_CONN_MT);
  lunet_graphlite_conn_destroy(wrapper);
  return 0;
}

static void register_conn_metatable(lua_State* L) {
  if (luaL_newmetatable(L, LUNET_GRAPHLITE_CONN_MT)) {
    lua_pushcfunction(L, conn_gc);
    lua_setfield(L, -2, "__gc");
  }
  lua_pop(L, 1);
}

static void db_open_work_cb(uv_work_t* req) {
  db_open_ctx_t* ctx = (db_open_ctx_t*)req->data;
  graphlite_error_code_t code = 0;

  if (graphlite_api_load(ctx->library_path, ctx->err, sizeof(ctx->err)) != 0) {
    return;
  }

  ctx->db = g_graphlite_api.graphlite_open(ctx->db_path, &code);
  if (!ctx->db) {
    snprintf(ctx->err,
             sizeof(ctx->err),
             "graphlite_open failed (%s) path=%s",
             graphlite_error_name(code),
             ctx->db_path);
    return;
  }

  char* session_ptr = g_graphlite_api.graphlite_create_session(ctx->db, ctx->username, &code);
  if (!session_ptr) {
    snprintf(ctx->err,
             sizeof(ctx->err),
             "graphlite_create_session failed (%s) username=%s",
             graphlite_error_name(code),
             ctx->username);
    g_graphlite_api.graphlite_close(ctx->db);
    ctx->db = NULL;
    return;
  }

  ctx->session_id = lunet_strdup_local(session_ptr);
  g_graphlite_api.graphlite_free_string(session_ptr);
  if (!ctx->session_id) {
    snprintf(ctx->err, sizeof(ctx->err), "out of memory");
    g_graphlite_api.graphlite_close(ctx->db);
    ctx->db = NULL;
  }
}

static void db_open_after_cb(uv_work_t* req, int status) {
  (void)status;

  db_open_ctx_t* ctx = (db_open_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in graphlite db.open\n");
    if (ctx->db && g_graphlite_api.initialized) {
      g_graphlite_api.graphlite_close(ctx->db);
      ctx->db = NULL;
    }
    lunet_free_nonnull(ctx->session_id);
    lunet_free_nonnull(ctx);
    return;
  }

  lua_State* co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->db && ctx->err[0] == '\0') {
    lunet_graphlite_conn_t* wrapper =
        (lunet_graphlite_conn_t*)lua_newuserdata(co, sizeof(lunet_graphlite_conn_t));
    wrapper->db = ctx->db;
    wrapper->session_id = ctx->session_id;
    wrapper->closed = 0;
    uv_mutex_init(&wrapper->mutex);

    ctx->db = NULL;
    ctx->session_id = NULL;

    luaL_getmetatable(co, LUNET_GRAPHLITE_CONN_MT);
    lua_setmetatable(co, -2);
    lua_pushnil(co);
  } else {
    if (ctx->db && g_graphlite_api.initialized) {
      g_graphlite_api.graphlite_close(ctx->db);
      ctx->db = NULL;
    }
    lunet_free_nonnull(ctx->session_id);
    ctx->session_id = NULL;

    lua_pushnil(co);
    lua_pushstring(co, ctx->err[0] ? ctx->err : "graphlite open failed");
  }

  {
    int rc = lunet_co_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) {
        fprintf(stderr, "lua_resume error in graphlite db.open: %s\n", err);
      }
      lua_pop(co, 1);
    }
  }
  lunet_free_nonnull(ctx);
}

static void db_query_ctx_cleanup(db_query_ctx_t* ctx) {
  if (!ctx) {
    return;
  }
  lunet_free_nonnull(ctx->query);
  lunet_free_nonnull(ctx->json_result);
  lunet_free_nonnull(ctx);
}

static void db_exec_ctx_cleanup(db_exec_ctx_t* ctx) {
  if (!ctx) {
    return;
  }
  lunet_free_nonnull(ctx->query);
  lunet_free_nonnull(ctx->json_result);
  lunet_free_nonnull(ctx);
}

static void db_query_work_cb(uv_work_t* req) {
  db_query_ctx_t* ctx = (db_query_ctx_t*)req->data;
  graphlite_error_code_t code = 0;

  uv_mutex_lock(&ctx->wrapper->mutex);
  if (ctx->wrapper->closed || !ctx->wrapper->db || !ctx->wrapper->session_id) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  char* json = g_graphlite_api.graphlite_query(ctx->wrapper->db, ctx->wrapper->session_id, ctx->query, &code);
  if (!json) {
    snprintf(ctx->err, sizeof(ctx->err), "graphlite_query failed (%s)", graphlite_error_name(code));
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  ctx->json_result = lunet_strdup_local(json);
  g_graphlite_api.graphlite_free_string(json);
  if (!ctx->json_result) {
    snprintf(ctx->err, sizeof(ctx->err), "out of memory");
  }

  uv_mutex_unlock(&ctx->wrapper->mutex);
}

static void db_exec_work_cb(uv_work_t* req) {
  db_exec_ctx_t* ctx = (db_exec_ctx_t*)req->data;
  graphlite_error_code_t code = 0;

  uv_mutex_lock(&ctx->wrapper->mutex);
  if (ctx->wrapper->closed || !ctx->wrapper->db || !ctx->wrapper->session_id) {
    snprintf(ctx->err, sizeof(ctx->err), "connection is closed");
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  char* json = g_graphlite_api.graphlite_query(ctx->wrapper->db, ctx->wrapper->session_id, ctx->query, &code);
  if (!json) {
    snprintf(ctx->err, sizeof(ctx->err), "graphlite_query failed (%s)", graphlite_error_name(code));
    uv_mutex_unlock(&ctx->wrapper->mutex);
    return;
  }

  ctx->json_result = lunet_strdup_local(json);
  g_graphlite_api.graphlite_free_string(json);
  if (!ctx->json_result) {
    snprintf(ctx->err, sizeof(ctx->err), "out of memory");
  }

  uv_mutex_unlock(&ctx->wrapper->mutex);
}

static int graphlite_json_fail(graphlite_json_parser_t* p, const char* msg) {
  if (p->err[0] == '\0') {
    snprintf(p->err, sizeof(p->err), "%s", msg);
  }
  return -1;
}

static void graphlite_json_skip_ws(graphlite_json_parser_t* p) {
  while (p->cur < p->end) {
    unsigned char c = (unsigned char)*p->cur;
    if (c == ' ' || c == '\t' || c == '\r' || c == '\n') {
      p->cur++;
      continue;
    }
    break;
  }
}

static int graphlite_json_hex(char c) {
  if (c >= '0' && c <= '9') {
    return c - '0';
  }
  if (c >= 'a' && c <= 'f') {
    return c - 'a' + 10;
  }
  if (c >= 'A' && c <= 'F') {
    return c - 'A' + 10;
  }
  return -1;
}

static void graphlite_json_add_utf8(luaL_Buffer* b, unsigned int cp) {
  if (cp <= 0x7F) {
    luaL_addchar(b, (char)cp);
    return;
  }
  if (cp <= 0x7FF) {
    luaL_addchar(b, (char)(0xC0 | (cp >> 6)));
    luaL_addchar(b, (char)(0x80 | (cp & 0x3F)));
    return;
  }
  if (cp <= 0xFFFF) {
    luaL_addchar(b, (char)(0xE0 | (cp >> 12)));
    luaL_addchar(b, (char)(0x80 | ((cp >> 6) & 0x3F)));
    luaL_addchar(b, (char)(0x80 | (cp & 0x3F)));
    return;
  }
  luaL_addchar(b, '?');
}

static int graphlite_json_parse_value(lua_State* L, graphlite_json_parser_t* p);

static int graphlite_json_parse_string(lua_State* L, graphlite_json_parser_t* p) {
  if (p->cur >= p->end || *p->cur != '"') {
    return graphlite_json_fail(p, "expected string");
  }

  p->cur++;
  luaL_Buffer b;
  luaL_buffinit(L, &b);

  while (p->cur < p->end) {
    char c = *p->cur++;
    if (c == '"') {
      luaL_pushresult(&b);
      return 0;
    }

    if (c == '\\') {
      if (p->cur >= p->end) {
        return graphlite_json_fail(p, "unterminated escape sequence");
      }
      char esc = *p->cur++;
      switch (esc) {
        case '"':
        case '\\':
        case '/':
          luaL_addchar(&b, esc);
          break;
        case 'b':
          luaL_addchar(&b, '\b');
          break;
        case 'f':
          luaL_addchar(&b, '\f');
          break;
        case 'n':
          luaL_addchar(&b, '\n');
          break;
        case 'r':
          luaL_addchar(&b, '\r');
          break;
        case 't':
          luaL_addchar(&b, '\t');
          break;
        case 'u': {
          if (p->end - p->cur < 4) {
            return graphlite_json_fail(p, "invalid unicode escape");
          }
          int h1 = graphlite_json_hex(p->cur[0]);
          int h2 = graphlite_json_hex(p->cur[1]);
          int h3 = graphlite_json_hex(p->cur[2]);
          int h4 = graphlite_json_hex(p->cur[3]);
          if (h1 < 0 || h2 < 0 || h3 < 0 || h4 < 0) {
            return graphlite_json_fail(p, "invalid unicode escape");
          }
          unsigned int codepoint = (unsigned int)((h1 << 12) | (h2 << 8) | (h3 << 4) | h4);
          p->cur += 4;
          graphlite_json_add_utf8(&b, codepoint);
          break;
        }
        default:
          return graphlite_json_fail(p, "unsupported escape sequence");
      }
      continue;
    }

    if ((unsigned char)c < 0x20) {
      return graphlite_json_fail(p, "invalid control character in string");
    }
    luaL_addchar(&b, c);
  }

  return graphlite_json_fail(p, "unterminated string");
}

static int graphlite_json_parse_number(lua_State* L, graphlite_json_parser_t* p) {
  const char* start = p->cur;
  char* endptr = NULL;
  double value = strtod(start, &endptr);
  if (endptr == start) {
    return graphlite_json_fail(p, "invalid number");
  }
  p->cur = endptr;
  lua_pushnumber(L, value);
  return 0;
}

static int graphlite_json_parse_literal(lua_State* L, graphlite_json_parser_t* p, const char* literal) {
  size_t len = strlen(literal);
  if ((size_t)(p->end - p->cur) < len || strncmp(p->cur, literal, len) != 0) {
    return graphlite_json_fail(p, "invalid literal");
  }
  p->cur += len;
  if (strcmp(literal, "true") == 0) {
    lua_pushboolean(L, 1);
  } else if (strcmp(literal, "false") == 0) {
    lua_pushboolean(L, 0);
  } else {
    lua_pushnil(L);
  }
  return 0;
}

static int graphlite_json_parse_array(lua_State* L, graphlite_json_parser_t* p) {
  if (p->cur >= p->end || *p->cur != '[') {
    return graphlite_json_fail(p, "expected array");
  }
  p->cur++;

  lua_newtable(L);
  lua_Integer idx = 1;
  graphlite_json_skip_ws(p);

  if (p->cur < p->end && *p->cur == ']') {
    p->cur++;
    return 0;
  }

  while (p->cur < p->end) {
    if (graphlite_json_parse_value(L, p) != 0) {
      lua_pop(L, 1);
      return -1;
    }
    lua_rawseti(L, -2, idx++);

    graphlite_json_skip_ws(p);
    if (p->cur >= p->end) {
      lua_pop(L, 1);
      return graphlite_json_fail(p, "unterminated array");
    }
    if (*p->cur == ',') {
      p->cur++;
      graphlite_json_skip_ws(p);
      continue;
    }
    if (*p->cur == ']') {
      p->cur++;
      return 0;
    }
    lua_pop(L, 1);
    return graphlite_json_fail(p, "expected ',' or ']' in array");
  }

  lua_pop(L, 1);
  return graphlite_json_fail(p, "unterminated array");
}

static int graphlite_json_parse_object(lua_State* L, graphlite_json_parser_t* p) {
  if (p->cur >= p->end || *p->cur != '{') {
    return graphlite_json_fail(p, "expected object");
  }
  p->cur++;

  lua_newtable(L);
  graphlite_json_skip_ws(p);
  if (p->cur < p->end && *p->cur == '}') {
    p->cur++;
    return 0;
  }

  while (p->cur < p->end) {
    if (graphlite_json_parse_string(L, p) != 0) {
      lua_pop(L, 1);
      return -1;
    }
    graphlite_json_skip_ws(p);
    if (p->cur >= p->end || *p->cur != ':') {
      lua_pop(L, 2);
      return graphlite_json_fail(p, "expected ':' in object");
    }
    p->cur++;
    graphlite_json_skip_ws(p);

    if (graphlite_json_parse_value(L, p) != 0) {
      lua_pop(L, 2);
      return -1;
    }
    lua_settable(L, -3);

    graphlite_json_skip_ws(p);
    if (p->cur >= p->end) {
      lua_pop(L, 1);
      return graphlite_json_fail(p, "unterminated object");
    }
    if (*p->cur == ',') {
      p->cur++;
      graphlite_json_skip_ws(p);
      continue;
    }
    if (*p->cur == '}') {
      p->cur++;
      return 0;
    }
    lua_pop(L, 1);
    return graphlite_json_fail(p, "expected ',' or '}' in object");
  }

  lua_pop(L, 1);
  return graphlite_json_fail(p, "unterminated object");
}

static int graphlite_json_parse_value(lua_State* L, graphlite_json_parser_t* p) {
  graphlite_json_skip_ws(p);
  if (p->cur >= p->end) {
    return graphlite_json_fail(p, "unexpected end of input");
  }

  char c = *p->cur;
  if (c == '"') {
    return graphlite_json_parse_string(L, p);
  }
  if (c == '{') {
    return graphlite_json_parse_object(L, p);
  }
  if (c == '[') {
    return graphlite_json_parse_array(L, p);
  }
  if (c == 't') {
    return graphlite_json_parse_literal(L, p, "true");
  }
  if (c == 'f') {
    return graphlite_json_parse_literal(L, p, "false");
  }
  if (c == 'n') {
    return graphlite_json_parse_literal(L, p, "null");
  }
  if (c == '-' || isdigit((unsigned char)c)) {
    return graphlite_json_parse_number(L, p);
  }
  return graphlite_json_fail(p, "unexpected token");
}

static int graphlite_json_decode(lua_State* L, const char* json, char* err, size_t errsize) {
  graphlite_json_parser_t parser;
  parser.cur = json;
  parser.end = json + strlen(json);
  parser.err[0] = '\0';

  if (graphlite_json_parse_value(L, &parser) != 0) {
    snprintf(err, errsize, "json parse error: %s", parser.err[0] ? parser.err : "invalid json");
    return -1;
  }
  graphlite_json_skip_ws(&parser);
  if (parser.cur != parser.end) {
    lua_pop(L, 1);
    snprintf(err, errsize, "json parse error: trailing content");
    return -1;
  }
  return 0;
}

static void graphlite_push_unwrapped_value(lua_State* L, int idx) {
  idx = lua_absindex(L, idx);
  if (!lua_istable(L, idx)) {
    lua_pushvalue(L, idx);
    return;
  }

  lua_getfield(L, idx, "String");
  if (!lua_isnil(L, -1)) {
    return;
  }
  lua_pop(L, 1);

  lua_getfield(L, idx, "Number");
  if (!lua_isnil(L, -1)) {
    return;
  }
  lua_pop(L, 1);

  lua_getfield(L, idx, "Boolean");
  if (!lua_isnil(L, -1)) {
    return;
  }
  lua_pop(L, 1);

  lua_getfield(L, idx, "Null");
  if (!lua_isnil(L, -1)) {
    lua_pop(L, 1);
    lua_pushnil(L);
    return;
  }
  lua_pop(L, 1);

  lua_getfield(L, idx, "List");
  if (lua_istable(L, -1)) {
    int list_idx = lua_absindex(L, lua_gettop(L));
    lua_newtable(L);
    int out_idx = lua_absindex(L, lua_gettop(L));
    size_t n = lua_rawlen(L, list_idx);
    for (size_t i = 1; i <= n; i++) {
      lua_rawgeti(L, list_idx, (lua_Integer)i);
      graphlite_push_unwrapped_value(L, -1);
      lua_rawseti(L, out_idx, (lua_Integer)i);
      lua_pop(L, 1);
    }
    lua_remove(L, list_idx);
    return;
  }
  lua_pop(L, 1);

  lua_getfield(L, idx, "Map");
  if (lua_istable(L, -1)) {
    int map_idx = lua_absindex(L, lua_gettop(L));
    lua_newtable(L);
    int out_idx = lua_absindex(L, lua_gettop(L));
    lua_pushnil(L);
    while (lua_next(L, map_idx) != 0) {
      lua_pushvalue(L, -2);
      graphlite_push_unwrapped_value(L, -2);
      lua_settable(L, out_idx);
      lua_pop(L, 1);
    }
    lua_remove(L, map_idx);
    return;
  }
  lua_pop(L, 1);

  lua_getfield(L, idx, "Node");
  if (!lua_isnil(L, -1)) {
    graphlite_push_unwrapped_value(L, -1);
    lua_remove(L, -2);
    return;
  }
  lua_pop(L, 1);

  lua_getfield(L, idx, "Edge");
  if (!lua_isnil(L, -1)) {
    graphlite_push_unwrapped_value(L, -1);
    lua_remove(L, -2);
    return;
  }
  lua_pop(L, 1);

  lua_getfield(L, idx, "Path");
  if (!lua_isnil(L, -1)) {
    graphlite_push_unwrapped_value(L, -1);
    lua_remove(L, -2);
    return;
  }
  lua_pop(L, 1);

  lua_pushvalue(L, idx);
}

static void graphlite_flatten_row_table(lua_State* L, int row_idx, int out_row_idx) {
  row_idx = lua_absindex(L, row_idx);
  out_row_idx = lua_absindex(L, out_row_idx);

  int used_values = 0;
  lua_getfield(L, row_idx, "values");
  if (lua_istable(L, -1)) {
    int values_idx = lua_absindex(L, lua_gettop(L));
    used_values = 1;
    lua_pushnil(L);
    while (lua_next(L, values_idx) != 0) {
      lua_pushvalue(L, -2);
      graphlite_push_unwrapped_value(L, -2);
      lua_settable(L, out_row_idx);
      lua_pop(L, 1);
    }
  }
  lua_pop(L, 1);

  if (!used_values && lua_istable(L, row_idx)) {
    lua_pushnil(L);
    while (lua_next(L, row_idx) != 0) {
      lua_pushvalue(L, -2);
      graphlite_push_unwrapped_value(L, -2);
      lua_settable(L, out_row_idx);
      lua_pop(L, 1);
    }
  }
}

static int graphlite_result_push_rows(lua_State* L, int result_idx) {
  result_idx = lua_absindex(L, result_idx);

  lua_getfield(L, result_idx, "rows");
  if (!lua_istable(L, -1)) {
    lua_pop(L, 1);
    lua_newtable(L);
    return 0;
  }

  int rows_idx = lua_absindex(L, lua_gettop(L));
  lua_newtable(L);
  int out_idx = lua_absindex(L, lua_gettop(L));

  size_t nrows = lua_rawlen(L, rows_idx);
  for (size_t i = 1; i <= nrows; i++) {
    lua_rawgeti(L, rows_idx, (lua_Integer)i);
    int row_idx = lua_absindex(L, lua_gettop(L));

    lua_newtable(L);
    int out_row_idx = lua_absindex(L, lua_gettop(L));
    if (lua_istable(L, row_idx)) {
      graphlite_flatten_row_table(L, row_idx, out_row_idx);
    }
    lua_rawseti(L, out_idx, (lua_Integer)i);
    lua_pop(L, 1);
  }

  lua_remove(L, rows_idx);
  return 0;
}

static long long graphlite_result_row_count(lua_State* L, int result_idx) {
  result_idx = lua_absindex(L, result_idx);
  long long row_count = 0;

  lua_getfield(L, result_idx, "row_count");
  if (lua_isnumber(L, -1)) {
    row_count = (long long)lua_tointeger(L, -1);
  } else if (lua_isstring(L, -1)) {
    row_count = strtoll(lua_tostring(L, -1), NULL, 10);
  }
  lua_pop(L, 1);
  return row_count;
}

static void db_query_after_cb(uv_work_t* req, int status) {
  (void)status;

  db_query_ctx_t* ctx = (db_query_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in graphlite db.query\n");
    db_query_ctx_cleanup(ctx);
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
      if (err) {
        fprintf(stderr, "lua_resume error in graphlite db.query: %s\n", err);
      }
      lua_pop(co, 1);
    }
    db_query_ctx_cleanup(ctx);
    return;
  }

  if (graphlite_json_decode(co, ctx->json_result, ctx->err, sizeof(ctx->err)) != 0) {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
    int rc = lunet_co_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) {
        fprintf(stderr, "lua_resume error in graphlite db.query: %s\n", err);
      }
      lua_pop(co, 1);
    }
    db_query_ctx_cleanup(ctx);
    return;
  }

  {
    int result_idx = lua_absindex(co, lua_gettop(co));
    graphlite_result_push_rows(co, result_idx);
    lua_remove(co, result_idx);
  }

  lua_pushnil(co);
  {
    int rc = lunet_co_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) {
        fprintf(stderr, "lua_resume error in graphlite db.query: %s\n", err);
      }
      lua_pop(co, 1);
    }
  }

  db_query_ctx_cleanup(ctx);
}

static void db_exec_after_cb(uv_work_t* req, int status) {
  (void)status;

  db_exec_ctx_t* ctx = (db_exec_ctx_t*)req->data;
  lua_State* L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in graphlite db.exec\n");
    db_exec_ctx_cleanup(ctx);
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
      if (err) {
        fprintf(stderr, "lua_resume error in graphlite db.exec: %s\n", err);
      }
      lua_pop(co, 1);
    }
    db_exec_ctx_cleanup(ctx);
    return;
  }

  long long row_count = 0;
  if (graphlite_json_decode(co, ctx->json_result, ctx->err, sizeof(ctx->err)) == 0) {
    row_count = graphlite_result_row_count(co, lua_gettop(co));
    lua_pop(co, 1);
  } else {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
    int rc = lunet_co_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) {
        fprintf(stderr, "lua_resume error in graphlite db.exec: %s\n", err);
      }
      lua_pop(co, 1);
    }
    db_exec_ctx_cleanup(ctx);
    return;
  }

  lua_newtable(co);
  lua_pushstring(co, "affected_rows");
  lua_pushinteger(co, row_count);
  lua_settable(co, -3);
  lua_pushstring(co, "last_insert_id");
  lua_pushinteger(co, 0);
  lua_settable(co, -3);
  lua_pushstring(co, "row_count");
  lua_pushinteger(co, row_count);
  lua_settable(co, -3);
  lua_pushnil(co);

  {
    int rc = lunet_co_resume(co, 2);
    if (rc != 0 && rc != LUA_YIELD) {
      const char* err = lua_tostring(co, -1);
      if (err) {
        fprintf(stderr, "lua_resume error in graphlite db.exec: %s\n", err);
      }
      lua_pop(co, 1);
    }
  }

  db_exec_ctx_cleanup(ctx);
}

int lunet_db_open(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.open")) {
    return lua_error(L);
  }

  const char* db_path = ".tmp/graphlite-db";
  const char* username = "lunet";
  const char* library_path = "";

  if (lua_gettop(L) >= 1 && lua_istable(L, 1)) {
    lua_getfield(L, 1, "path");
    db_path = luaL_optstring(L, -1, db_path);
    lua_pop(L, 1);

    lua_getfield(L, 1, "username");
    username = luaL_optstring(L, -1, username);
    lua_pop(L, 1);

    lua_getfield(L, 1, "library_path");
    if (lua_isstring(L, -1)) {
      library_path = lua_tostring(L, -1);
    }
    lua_pop(L, 1);

    if (!library_path || library_path[0] == '\0') {
      lua_getfield(L, 1, "lib_path");
      if (lua_isstring(L, -1)) {
        library_path = lua_tostring(L, -1);
      }
      lua_pop(L, 1);
    }
  } else if (lua_gettop(L) >= 1 && lua_isstring(L, 1)) {
    db_path = lua_tostring(L, 1);
  } else if (lua_gettop(L) >= 1) {
    lua_pushnil(L);
    lua_pushstring(L, "db.open expects a config table or path string");
    return 2;
  }

  register_conn_metatable(L);

  db_open_ctx_t* ctx = lunet_alloc(sizeof(db_open_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "db.open: out of memory");
    return 2;
  }
  memset(ctx, 0, sizeof(*ctx));
  ctx->L = L;
  ctx->req.data = ctx;
  snprintf(ctx->db_path, sizeof(ctx->db_path), "%s", db_path ? db_path : ".tmp/graphlite-db");
  snprintf(ctx->username, sizeof(ctx->username), "%s", username ? username : "lunet");
  snprintf(ctx->library_path, sizeof(ctx->library_path), "%s", library_path ? library_path : "");

  lunet_coref_create(L, ctx->co_ref);

  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_open_work_cb, db_open_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushfstring(L, "db.open: uv_queue_work failed: %s", uv_strerror(ret));
    return 2;
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

  lunet_graphlite_conn_t* wrapper =
      (lunet_graphlite_conn_t*)luaL_testudata(L, 1, LUNET_GRAPHLITE_CONN_MT);
  if (!wrapper) {
    lua_pushstring(L, "db.close requires a valid connection");
    return 1;
  }

  uv_mutex_lock(&wrapper->mutex);
  lunet_graphlite_conn_close(wrapper);
  uv_mutex_unlock(&wrapper->mutex);

  lua_pushnil(L);
  return 1;
}

int lunet_db_query(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.query")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "db.query requires connection and gql string");
    return 2;
  }

  lunet_graphlite_conn_t* wrapper =
      (lunet_graphlite_conn_t*)luaL_testudata(L, 1, LUNET_GRAPHLITE_CONN_MT);
  if (!wrapper) {
    lua_pushnil(L);
    lua_pushstring(L, "db.query requires a valid connection");
    return 2;
  }
  if (wrapper->closed || !wrapper->db || !wrapper->session_id) {
    lua_pushnil(L);
    lua_pushstring(L, "connection is closed");
    return 2;
  }

  const char* query = luaL_checkstring(L, 2);
  db_query_ctx_t* ctx = lunet_alloc(sizeof(db_query_ctx_t));
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
    db_query_ctx_cleanup(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  lunet_coref_create(L, ctx->co_ref);
  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_query_work_cb, db_query_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    db_query_ctx_cleanup(ctx);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(ret));
    return 2;
  }

  return lua_yield(L, 0);
}

int lunet_db_exec(lua_State* L) {
  if (lunet_ensure_coroutine(L, "db.exec")) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "db.exec requires connection and gql string");
    return 2;
  }

  lunet_graphlite_conn_t* wrapper =
      (lunet_graphlite_conn_t*)luaL_testudata(L, 1, LUNET_GRAPHLITE_CONN_MT);
  if (!wrapper) {
    lua_pushnil(L);
    lua_pushstring(L, "db.exec requires a valid connection");
    return 2;
  }
  if (wrapper->closed || !wrapper->db || !wrapper->session_id) {
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
    db_exec_ctx_cleanup(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  lunet_coref_create(L, ctx->co_ref);
  int ret = uv_queue_work(uv_default_loop(), &ctx->req, db_exec_work_cb, db_exec_after_cb);
  if (ret < 0) {
    lunet_coref_release(L, ctx->co_ref);
    db_exec_ctx_cleanup(ctx);
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

int lunet_db_query_params(lua_State* L) {
  if (lua_gettop(L) > 2) {
    lua_pushnil(L);
    lua_pushstring(L, "graphlite driver does not support positional parameters yet");
    return 2;
  }
  return lunet_db_query(L);
}

int lunet_db_exec_params(lua_State* L) {
  if (lua_gettop(L) > 2) {
    lua_pushnil(L);
    lua_pushstring(L, "graphlite driver does not support positional parameters yet");
    return 2;
  }
  return lunet_db_exec(L);
}

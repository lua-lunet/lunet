#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <uv.h>

#include "lunet_lua.h"
#include "co.h"
#include "trace.h"

#include "httpc.h"

#ifndef lua_rawlen
#define lua_rawlen lua_objlen
#endif

#include <curl/curl.h>

static char *lunet_strdup_local(const char *s) {
  if (!s) return NULL;
  size_t n = strlen(s);
  char *p = (char *)malloc(n + 1);
  if (!p) return NULL;
  memcpy(p, s, n + 1);
  return p;
}

typedef struct {
  char **items;
  size_t len;
  size_t cap;
} httpc_strlist_t;

static int httpc_strlist_push(httpc_strlist_t *l, const char *s, size_t n) {
  if (n == 0) return 0;
  if (l->len + 1 > l->cap) {
    size_t next = l->cap ? (l->cap * 2) : 8;
    char **p = (char **)realloc(l->items, next * sizeof(char *));
    if (!p) return -1;
    l->items = p;
    l->cap = next;
  }
  char *copy = (char *)malloc(n + 1);
  if (!copy) return -1;
  memcpy(copy, s, n);
  copy[n] = '\0';
  l->items[l->len++] = copy;
  return 0;
}

static void httpc_strlist_free(httpc_strlist_t *l) {
  if (!l) return;
  for (size_t i = 0; i < l->len; i++) free(l->items[i]);
  free(l->items);
  l->items = NULL;
  l->len = 0;
  l->cap = 0;
}

typedef struct {
  uv_work_t req;
  lua_State *L;
  int co_ref;

  char *url;
  char *method;
  char *body;
  size_t body_len;
  long timeout_ms;
  size_t max_body_bytes;
  int insecure;

  struct curl_slist *req_headers;

  long status;
  char *resp_body;
  size_t resp_len;
  size_t resp_cap;
  httpc_strlist_t resp_headers;
  char *effective_url;

  char err[256];
  int too_large;
} httpc_req_t;

static int httpc_env_truthy(const char *name) {
  const char *v = getenv(name);
  if (!v) return 0;
  if (strcmp(v, "1") == 0) return 1;
  if (strcmp(v, "true") == 0) return 1;
  if (strcmp(v, "TRUE") == 0) return 1;
  if (strcmp(v, "yes") == 0) return 1;
  if (strcmp(v, "YES") == 0) return 1;
  if (strcmp(v, "on") == 0) return 1;
  if (strcmp(v, "ON") == 0) return 1;
  return 0;
}

static size_t httpc_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
  httpc_req_t *ctx = (httpc_req_t *)userdata;
  size_t n = size * nmemb;
  if (n == 0) return 0;

  if (ctx->resp_len + n > ctx->max_body_bytes) {
    ctx->too_large = 1;
    return 0; // abort
  }

  if (ctx->resp_len + n + 1 > ctx->resp_cap) {
    size_t next = ctx->resp_cap ? (ctx->resp_cap * 2) : 8192;
    while (next < ctx->resp_len + n + 1) next *= 2;
    char *p = (char *)realloc(ctx->resp_body, next);
    if (!p) {
      snprintf(ctx->err, sizeof(ctx->err), "out of memory");
      return 0;
    }
    ctx->resp_body = p;
    ctx->resp_cap = next;
  }

  memcpy(ctx->resp_body + ctx->resp_len, ptr, n);
  ctx->resp_len += n;
  ctx->resp_body[ctx->resp_len] = '\0';
  return n;
}

static size_t httpc_header_cb(char *buffer, size_t size, size_t nitems, void *userdata) {
  httpc_req_t *ctx = (httpc_req_t *)userdata;
  size_t n = size * nitems;
  if (n == 0) return 0;

  // Trim trailing CRLF
  while (n > 0 && (buffer[n - 1] == '\n' || buffer[n - 1] == '\r')) n--;
  if (n == 0) return size * nitems;

  // Ignore status line and continuation lines
  if (n >= 5 && memcmp(buffer, "HTTP/", 5) == 0) return size * nitems;
  if (buffer[0] == ' ' || buffer[0] == '\t') return size * nitems;

  // Only store lines containing ':'
  const char *colon = (const char *)memchr(buffer, ':', n);
  if (!colon) return size * nitems;

  if (httpc_strlist_push(&ctx->resp_headers, buffer, n) != 0) {
    snprintf(ctx->err, sizeof(ctx->err), "out of memory");
    return 0;
  }

  return size * nitems;
}

static void httpc_work_cb(uv_work_t *req) {
  httpc_req_t *ctx = (httpc_req_t *)req->data;
  ctx->err[0] = '\0';
  ctx->too_large = 0;

  CURL *curl = curl_easy_init();
  if (!curl) {
    snprintf(ctx->err, sizeof(ctx->err), "curl init failed");
    return;
  }

  curl_easy_setopt(curl, CURLOPT_URL, ctx->url);
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, ctx->timeout_ms);
  curl_easy_setopt(curl, CURLOPT_ACCEPT_ENCODING, "");
  curl_easy_setopt(curl, CURLOPT_USERAGENT, "lunet-httpc/0.1");

  if (ctx->insecure) {
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);
  }

  if (ctx->method && strcmp(ctx->method, "GET") == 0 && ctx->body == NULL) {
    curl_easy_setopt(curl, CURLOPT_HTTPGET, 1L);
  } else {
    curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, ctx->method ? ctx->method : "GET");
  }

  if (ctx->body) {
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS, ctx->body);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)ctx->body_len);
  }

  if (ctx->req_headers) {
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, ctx->req_headers);
  }

  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, httpc_write_cb);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, ctx);
  curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, httpc_header_cb);
  curl_easy_setopt(curl, CURLOPT_HEADERDATA, ctx);

  CURLcode rc = curl_easy_perform(curl);

  if (ctx->too_large) {
    snprintf(ctx->err, sizeof(ctx->err), "response too large");
  } else if (ctx->err[0] != '\0') {
    // keep existing message (e.g. OOM)
  } else if (rc != CURLE_OK) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", curl_easy_strerror(rc));
  } else {
    long status = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    ctx->status = status;

    char *eff = NULL;
    if (curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &eff) == CURLE_OK && eff) {
      size_t n = strlen(eff);
      ctx->effective_url = (char *)malloc(n + 1);
      if (ctx->effective_url) {
        memcpy(ctx->effective_url, eff, n + 1);
      }
    }
  }

  curl_easy_cleanup(curl);
}

static void httpc_after_cb(uv_work_t *req, int status) {
  (void)status;
  httpc_req_t *ctx = (httpc_req_t *)req->data;
  lua_State *L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in httpc.request\n");
    goto cleanup;
  }
  lua_State *co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->err[0] != '\0') {
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
    lunet_co_resume(co, 2);
    goto cleanup;
  }

  lua_newtable(co);

  lua_pushinteger(co, (lua_Integer)ctx->status);
  lua_setfield(co, -2, "status");

  lua_pushlstring(co, ctx->resp_body ? ctx->resp_body : "", ctx->resp_len);
  lua_setfield(co, -2, "body");

  lua_newtable(co);
  lua_Integer out_i = 0;
  for (size_t i = 0; i < ctx->resp_headers.len; i++) {
    const char *line = ctx->resp_headers.items[i];
    const char *colon = strchr(line, ':');
    if (!colon) continue;
    const char *name = line;
    const char *val = colon + 1;
    while (*val == ' ' || *val == '\t') val++;
    lua_newtable(co);
    lua_pushlstring(co, name, (size_t)(colon - name));
    lua_setfield(co, -2, "name");
    lua_pushstring(co, val);
    lua_setfield(co, -2, "value");
    out_i++;
    lua_rawseti(co, -2, out_i);
  }
  lua_setfield(co, -2, "headers");

  if (ctx->effective_url) {
    lua_pushstring(co, ctx->effective_url);
    lua_setfield(co, -2, "effective_url");
  }

  lua_pushnil(co);
  lunet_co_resume(co, 2);

cleanup:
  free(ctx->url);
  free(ctx->method);
  free(ctx->body);
  if (ctx->req_headers) curl_slist_free_all(ctx->req_headers);
  free(ctx->resp_body);
  httpc_strlist_free(&ctx->resp_headers);
  free(ctx->effective_url);
  free(ctx);
}

static int httpc_parse_headers(lua_State *L, int idx, struct curl_slist **out, char *err, size_t errsz) {
  if (lua_isnil(L, idx)) return 0;
  if (!lua_istable(L, idx)) {
    snprintf(err, errsz, "headers must be a table");
    return -1;
  }

  // Heuristic: if rawgeti(1) is table -> array form, else map form
  lua_rawgeti(L, idx, 1);
  int is_array = lua_istable(L, -1);
  lua_pop(L, 1);

  if (is_array) {
    lua_Integer n = (lua_Integer)lua_rawlen(L, idx);
    for (lua_Integer i = 1; i <= n; i++) {
      lua_rawgeti(L, idx, i);
      if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        snprintf(err, errsz, "headers[%lld] must be {name, value}", (long long)i);
        return -1;
      }
      lua_rawgeti(L, -1, 1);
      lua_rawgeti(L, -2, 2);
      const char *k = lua_tostring(L, -2);
      const char *v = lua_tostring(L, -1);
      lua_pop(L, 2);
      lua_pop(L, 1);
      if (!k || !v) {
        snprintf(err, errsz, "headers[%lld] must be {string, string}", (long long)i);
        return -1;
      }
      size_t kn = strlen(k);
      size_t vn = strlen(v);
      char *line = (char *)malloc(kn + 2 + vn + 1);
      if (!line) {
        snprintf(err, errsz, "out of memory");
        return -1;
      }
      memcpy(line, k, kn);
      line[kn] = ':';
      line[kn + 1] = ' ';
      memcpy(line + kn + 2, v, vn);
      line[kn + 2 + vn] = '\0';
      *out = curl_slist_append(*out, line);
      free(line);
      if (!*out) {
        snprintf(err, errsz, "out of memory");
        return -1;
      }
    }
    return 0;
  }

  lua_pushnil(L);
  while (lua_next(L, idx) != 0) {
    if (lua_type(L, -2) != LUA_TSTRING || lua_type(L, -1) != LUA_TSTRING) {
      lua_pop(L, 1);
      snprintf(err, errsz, "headers keys/values must be strings");
      return -1;
    }
    const char *k = lua_tostring(L, -2);
    const char *v = lua_tostring(L, -1);
    size_t kn = strlen(k);
    size_t vn = strlen(v);
    char *line = (char *)malloc(kn + 2 + vn + 1);
    if (!line) {
      lua_pop(L, 1);
      snprintf(err, errsz, "out of memory");
      return -1;
    }
    memcpy(line, k, kn);
    line[kn] = ':';
    line[kn + 1] = ' ';
    memcpy(line + kn + 2, v, vn);
    line[kn + 2 + vn] = '\0';
    *out = curl_slist_append(*out, line);
    free(line);
    if (!*out) {
      lua_pop(L, 1);
      snprintf(err, errsz, "out of memory");
      return -1;
    }
    lua_pop(L, 1);
  }

  return 0;
}

static int httpc_request(lua_State *L) {
  if (lunet_ensure_coroutine(L, "httpc.request")) {
    return lua_error(L);
  }

  if (lua_gettop(L) < 1 || !lua_istable(L, 1)) {
    lua_pushnil(L);
    lua_pushstring(L, "httpc.request requires options table");
    return 2;
  }

  lua_getfield(L, 1, "url");
  const char *url = lua_tostring(L, -1);
  lua_pop(L, 1);
  if (!url) {
    lua_pushnil(L);
    lua_pushstring(L, "url is required");
    return 2;
  }

  const char *method = NULL;
  lua_getfield(L, 1, "method");
  if (!lua_isnil(L, -1)) method = lua_tostring(L, -1);
  lua_pop(L, 1);
  if (!method) method = "GET";

  const char *body = NULL;
  size_t body_len = 0;
  lua_getfield(L, 1, "body");
  if (!lua_isnil(L, -1)) body = lua_tolstring(L, -1, &body_len);
  lua_pop(L, 1);

  long timeout_ms = 30000;
  lua_getfield(L, 1, "timeout_ms");
  if (lua_isnumber(L, -1)) timeout_ms = (long)lua_tointeger(L, -1);
  lua_pop(L, 1);
  if (timeout_ms <= 0) timeout_ms = 30000;

  size_t max_body_bytes = 10 * 1024 * 1024;
  lua_getfield(L, 1, "max_body_bytes");
  if (lua_isnumber(L, -1)) {
    lua_Integer v = lua_tointeger(L, -1);
    if (v > 0) max_body_bytes = (size_t)v;
  }
  lua_pop(L, 1);

  int insecure = 0;
  lua_getfield(L, 1, "insecure");
  if (lua_isboolean(L, -1)) {
    insecure = lua_toboolean(L, -1) ? 1 : 0;
  } else {
    insecure = httpc_env_truthy("LUNET_HTTPC_INSECURE") ? 1 : 0;
  }
  lua_pop(L, 1);

  httpc_req_t *ctx = (httpc_req_t *)malloc(sizeof(httpc_req_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  memset(ctx, 0, sizeof(*ctx));

  ctx->L = L;
  ctx->req.data = ctx;
  ctx->timeout_ms = timeout_ms;
  ctx->max_body_bytes = max_body_bytes;
  ctx->insecure = insecure;

  ctx->url = lunet_strdup_local(url);
  ctx->method = lunet_strdup_local(method);
  if (!ctx->url || !ctx->method) {
    free(ctx->url);
    free(ctx->method);
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  if (body) {
    ctx->body = (char *)malloc(body_len + 1);
    if (!ctx->body) {
      free(ctx->url);
      free(ctx->method);
      free(ctx);
      lua_pushnil(L);
      lua_pushstring(L, "out of memory");
      return 2;
    }
    memcpy(ctx->body, body, body_len);
    ctx->body[body_len] = '\0';
    ctx->body_len = body_len;
  }

  ctx->req_headers = NULL;
  lua_getfield(L, 1, "headers");
  if (!lua_isnil(L, -1)) {
    if (httpc_parse_headers(L, lua_gettop(L), &ctx->req_headers, ctx->err, sizeof(ctx->err)) != 0) {
      lua_pop(L, 1);
      lua_pushnil(L);
      lua_pushstring(L, ctx->err[0] ? ctx->err : "invalid headers");
      free(ctx->url);
      free(ctx->method);
      free(ctx->body);
      if (ctx->req_headers) curl_slist_free_all(ctx->req_headers);
      free(ctx);
      return 2;
    }
  }
  lua_pop(L, 1);

  lunet_coref_create(L, ctx->co_ref);

  int rc = uv_queue_work(uv_default_loop(), &ctx->req, httpc_work_cb, httpc_after_cb);
  if (rc < 0) {
    lunet_coref_release(L, ctx->co_ref);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(rc));
    free(ctx->url);
    free(ctx->method);
    free(ctx->body);
    if (ctx->req_headers) curl_slist_free_all(ctx->req_headers);
    free(ctx);
    return 2;
  }

  return lua_yield(L, 0);
}

int lunet_open_httpc(lua_State *L) {
  static int curl_inited = 0;
  if (!curl_inited) {
    CURLcode rc = curl_global_init(CURL_GLOBAL_DEFAULT);
    if (rc != CURLE_OK) {
      return luaL_error(L, "curl_global_init failed: %s", curl_easy_strerror(rc));
    }
    curl_inited = 1;
  }
  luaL_Reg funcs[] = {{"request", httpc_request}, {NULL, NULL}};
  luaL_newlib(L, funcs);
  return 1;
}

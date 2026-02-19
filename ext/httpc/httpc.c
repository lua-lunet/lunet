#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <ctype.h>
#include <stdint.h>

#include <uv.h>

#include "lunet_lua.h"
#include "co.h"
#include "trace.h"
#include "lunet_mem.h"

#include "httpc.h"

#ifndef lua_rawlen
#define lua_rawlen lua_objlen
#endif

#include <curl/curl.h>

#ifdef LUNET_HTTPC_WORKER_EM
#ifndef LUNET_EASY_MEMORY
#error "LUNET_HTTPC_WORKER_EM requires LUNET_EASY_MEMORY"
#endif
#include <easy_memory.h>
#ifndef LUNET_HTTPC_WORKER_EM_ARENA_BYTES
#define LUNET_HTTPC_WORKER_EM_ARENA_BYTES (1024ULL * 1024ULL)
#endif
#ifndef LUNET_HTTPC_WORKER_EM_BUMP_BYTES
#define LUNET_HTTPC_WORKER_EM_BUMP_BYTES (768ULL * 1024ULL)
#endif
#ifndef LUNET_HTTPC_WORKER_EM_META_BYTES
#define LUNET_HTTPC_WORKER_EM_META_BYTES (64ULL * 1024ULL)
#endif
#endif

#define HTTPC_DEFAULT_TIMEOUT_MS 30000L
#define HTTPC_DEFAULT_MAX_BODY_BYTES ((size_t)(10U * 1024U * 1024U))
#define HTTPC_DEFAULT_MAX_HEADER_BYTES ((size_t)(64U * 1024U))
#define HTTPC_DEFAULT_MAX_HEADER_LINES ((size_t)256U)
#define HTTPC_DEFAULT_MAX_REDIRECTS 8L

typedef struct {
  char **items;
  size_t len;
  size_t cap;
} httpc_strlist_t;
typedef struct httpc_req_s {
  uv_work_t req;
  lua_State *L;
  int co_ref;

#ifdef LUNET_HTTPC_WORKER_EM
  EM *req_em;
  Bump *req_bump;
#endif

  char *url;
  char *method;
  char *body;
  size_t body_len;
  long timeout_ms;
  long connect_timeout_ms;
  long low_speed_limit_bps;
  long low_speed_time_sec;
  long max_redirects;
  size_t max_body_bytes;
  size_t max_header_bytes;
  size_t max_header_lines;
  size_t header_bytes;
  int follow_redirects;
  int allow_file_protocol;
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
#ifdef LUNET_HTTPC_WORKER_EM
  size_t req_em_required_bytes;
#endif
} httpc_req_t;

static uv_once_t httpc_curl_global_once = UV_ONCE_INIT;
static CURLcode httpc_curl_global_rc = CURLE_OK;
static uv_once_t httpc_summary_once = UV_ONCE_INIT;
static uint64_t httpc_completed_count = 0;
static uint64_t httpc_valid_count = 0;
static uint64_t httpc_invalid_count = 0;

static void httpc_curl_global_init_once(void) {
  httpc_curl_global_rc = curl_global_init(CURL_GLOBAL_DEFAULT);
}

static void httpc_shutdown_summary(void) {
  fprintf(stderr,
      "[HTTPC] SUMMARY: completed=%llu valid=%llu invalid=%llu\n",
      (unsigned long long)httpc_completed_count,
      (unsigned long long)httpc_valid_count,
      (unsigned long long)httpc_invalid_count);
}

static void httpc_register_shutdown_summary_once(void) {
  if (atexit(httpc_shutdown_summary) != 0) {
    fprintf(stderr, "[HTTPC] WARNING: failed to register shutdown summary\n");
  }
}

static int httpc_size_add(size_t a, size_t b, size_t *out) {
  if (a > (size_t)-1 - b) {
    return -1;
  }
  *out = a + b;
  return 0;
}

static int httpc_size_mul(size_t a, size_t b, size_t *out) {
  if (a != 0 && b > (size_t)-1 / a) {
    return -1;
  }
  *out = a * b;
  return 0;
}

#ifdef LUNET_HTTPC_WORKER_EM
static int httpc_worker_em_required_bytes(
    const char *url,
    const char *method,
    size_t body_len,
    size_t max_body_bytes,
    size_t max_header_bytes,
    size_t max_header_lines,
    size_t *out,
    char *err,
    size_t errsz) {
  size_t total = 0;
  size_t tmp = 0;

  if (httpc_size_add(total, max_body_bytes, &total) != 0) goto overflow;
  if (httpc_size_add(total, 1, &total) != 0) goto overflow;
  if (httpc_size_add(total, max_header_bytes, &total) != 0) goto overflow;
  if (httpc_size_add(total, max_header_lines, &total) != 0) goto overflow;
  if (httpc_size_mul(max_header_lines, sizeof(char *), &tmp) != 0) goto overflow;
  if (httpc_size_add(total, tmp, &total) != 0) goto overflow;

  if (httpc_size_add(total, strlen(url), &total) != 0) goto overflow;
  if (httpc_size_add(total, 1, &total) != 0) goto overflow;
  if (httpc_size_add(total, strlen(method), &total) != 0) goto overflow;
  if (httpc_size_add(total, 1, &total) != 0) goto overflow;
  if (httpc_size_add(total, body_len, &total) != 0) goto overflow;
  if (httpc_size_add(total, 1, &total) != 0) goto overflow;
  if (httpc_size_add(total, (size_t)LUNET_HTTPC_WORKER_EM_META_BYTES, &total) != 0) goto overflow;

  *out = total;
  return 0;

overflow:
  snprintf(err, errsz, "httpc limits overflow allocator sizing");
  return -1;
}
#endif

static int httpc_req_allocator_init(httpc_req_t *ctx, char *err, size_t errsz) {
#ifdef LUNET_HTTPC_WORKER_EM
  size_t arena_bytes = (size_t)LUNET_HTTPC_WORKER_EM_ARENA_BYTES;
  size_t bump_bytes = (size_t)LUNET_HTTPC_WORKER_EM_BUMP_BYTES;
  if (ctx->req_em_required_bytes == 0) {
    snprintf(err, errsz, "invalid EasyMem required size");
    return -1;
  }
  if (arena_bytes < ctx->req_em_required_bytes) {
    snprintf(err, errsz,
        "httpc worker EasyMem arena too small: need %zu bytes, have %zu bytes",
        ctx->req_em_required_bytes, arena_bytes);
    return -1;
  }
  if (bump_bytes < ctx->req_em_required_bytes) {
    snprintf(err, errsz,
        "httpc worker EasyMem bump too small: need %zu bytes, have %zu bytes",
        ctx->req_em_required_bytes, bump_bytes);
    return -1;
  }
  ctx->req_em = em_create(arena_bytes);
  if (!ctx->req_em) {
    snprintf(err, errsz, "httpc worker EasyMem em_create failed");
    return -1;
  }
  ctx->req_bump = em_bump_create(ctx->req_em, bump_bytes);
  if (!ctx->req_bump) {
    em_destroy(ctx->req_em);
    ctx->req_em = NULL;
    snprintf(err, errsz, "httpc worker EasyMem em_bump_create failed");
    return -1;
  }
#else
  (void)ctx;
  (void)err;
  (void)errsz;
#endif
  return 0;
}

static void httpc_req_allocator_shutdown(httpc_req_t *ctx) {
#ifdef LUNET_HTTPC_WORKER_EM
  if (ctx->req_bump) {
    em_bump_destroy(ctx->req_bump);
    ctx->req_bump = NULL;
  }
  if (ctx->req_em) {
    em_destroy(ctx->req_em);
    ctx->req_em = NULL;
  }
#else
  (void)ctx;
#endif
}

static void *httpc_req_alloc(httpc_req_t *ctx, size_t size) {
  size_t want = size > 0 ? size : 1;
#ifdef LUNET_HTTPC_WORKER_EM
  if (ctx && ctx->req_bump) {
    return em_bump_alloc(ctx->req_bump, want);
  }
#endif
  return lunet_alloc(want);
}

static void *httpc_req_realloc(httpc_req_t *ctx, void *ptr, size_t old_size, size_t new_size) {
  size_t want = new_size > 0 ? new_size : 1;
#ifdef LUNET_HTTPC_WORKER_EM
  if (ctx && ctx->req_bump) {
    void *next = em_bump_alloc(ctx->req_bump, want);
    if (!next) {
      return NULL;
    }
    if (ptr && old_size > 0) {
      size_t copy_size = old_size < want ? old_size : want;
      memcpy(next, ptr, copy_size);
    }
    return next;
  }
#endif
  return lunet_realloc(ptr, want);
}

static void httpc_req_free(httpc_req_t *ctx, void *ptr) {
#ifdef LUNET_HTTPC_WORKER_EM
  if (ctx && ctx->req_bump) {
    (void)ptr;
    return;
  }
#endif
  lunet_free_nonnull(ptr);
}

static char *lunet_strdup_ctx(httpc_req_t *ctx, const char *s) {
  if (!s) return NULL;
  size_t n = strlen(s);
  size_t alloc_bytes = 0;
  if (httpc_size_add(n, 1, &alloc_bytes) != 0) return NULL;
  char *p = (char *)httpc_req_alloc(ctx, alloc_bytes);
  if (!p) return NULL;
  memcpy(p, s, n + 1);
  return p;
}

static int httpc_strlist_push(httpc_req_t *ctx, httpc_strlist_t *l, const char *s, size_t n) {
  if (n == 0) return 0;
  if (ctx && l->len >= ctx->max_header_lines) return -2;
  if (l->len + 1 > l->cap) {
    size_t next = l->cap ? (l->cap * 2) : 8;
    size_t min_cap = l->len + 1;
    size_t old_bytes = 0;
    size_t next_bytes = 0;
    if (next < min_cap) next = min_cap;
    if (ctx && next > ctx->max_header_lines) next = ctx->max_header_lines;
    if (next < min_cap) return -1;
    if (httpc_size_mul(l->cap, sizeof(char *), &old_bytes) != 0) return -1;
    if (httpc_size_mul(next, sizeof(char *), &next_bytes) != 0) return -1;
    char **p = (char **)httpc_req_realloc(ctx, l->items, old_bytes, next_bytes);
    if (!p) return -1;
    l->items = p;
    l->cap = next;
  }
  char *copy = (char *)httpc_req_alloc(ctx, n + 1);
  if (!copy) return -1;
  memcpy(copy, s, n);
  copy[n] = '\0';
  l->items[l->len++] = copy;
  return 0;
}

static void httpc_strlist_free(httpc_req_t *ctx, httpc_strlist_t *l) {
  if (!l) return;
  for (size_t i = 0; i < l->len; i++) httpc_req_free(ctx, l->items[i]);
  httpc_req_free(ctx, l->items);
  l->items = NULL;
  l->len = 0;
  l->cap = 0;
}

static int httpc_env_truthy(const char *name) {
  const char *v = getenv(name);
  size_t i = 0;
  char buf[16];
  if (!v || v[0] == '\0') return 0;
  if (strcmp(v, "1") == 0) return 1;
  while (v[i] != '\0' && i + 1 < sizeof(buf)) {
    buf[i] = (char)tolower((unsigned char)v[i]);
    i++;
  }
  buf[i] = '\0';
  if (strcmp(buf, "true") == 0) return 1;
  if (strcmp(buf, "yes") == 0) return 1;
  if (strcmp(buf, "on") == 0) return 1;
  return 0;
}

static int httpc_opt_long(lua_State *L, int idx, const char *name, long def, long min, long max, long *out, char *err, size_t errsz) {
  lua_getfield(L, idx, name);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    *out = def;
    return 0;
  }
  if (!lua_isnumber(L, -1)) {
    lua_pop(L, 1);
    snprintf(err, errsz, "%s must be an integer", name);
    return -1;
  }
  lua_Integer v = lua_tointeger(L, -1);
  lua_pop(L, 1);
  if (v < (lua_Integer)min || v > (lua_Integer)max) {
    snprintf(err, errsz, "%s must be in range [%ld, %ld]", name, min, max);
    return -1;
  }
  *out = (long)v;
  return 0;
}

static int httpc_opt_size(lua_State *L, int idx, const char *name, size_t def, size_t min, size_t max, size_t *out, char *err, size_t errsz) {
  lua_getfield(L, idx, name);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    *out = def;
    return 0;
  }
  if (!lua_isnumber(L, -1)) {
    lua_pop(L, 1);
    snprintf(err, errsz, "%s must be an integer", name);
    return -1;
  }
  lua_Integer v = lua_tointeger(L, -1);
  lua_pop(L, 1);
  if (v <= 0) {
    snprintf(err, errsz, "%s must be > 0", name);
    return -1;
  }
  if ((unsigned long long)v < (unsigned long long)min || (unsigned long long)v > (unsigned long long)max) {
    snprintf(err, errsz, "%s must be in range [%zu, %zu]", name, min, max);
    return -1;
  }
  *out = (size_t)v;
  return 0;
}

static int httpc_opt_bool(lua_State *L, int idx, const char *name, int def, int *out, char *err, size_t errsz) {
  lua_getfield(L, idx, name);
  if (lua_isnil(L, -1)) {
    lua_pop(L, 1);
    *out = def;
    return 0;
  }
  if (!lua_isboolean(L, -1)) {
    lua_pop(L, 1);
    snprintf(err, errsz, "%s must be boolean", name);
    return -1;
  }
  *out = lua_toboolean(L, -1) ? 1 : 0;
  lua_pop(L, 1);
  return 0;
}

static int httpc_ascii_ieq_n(const char *s, size_t n, const char *lit) {
  size_t i = 0;
  for (; i < n; i++) {
    char a = s[i];
    char b = lit[i];
    if (b == '\0') return 0;
    if ((char)tolower((unsigned char)a) != (char)tolower((unsigned char)b)) return 0;
  }
  return lit[i] == '\0';
}

static int httpc_url_scheme_allowed(const char *url, int allow_file_protocol) {
  const char *sep = strstr(url, "://");
  if (!sep) return 0;
  size_t n = (size_t)(sep - url);
  if (httpc_ascii_ieq_n(url, n, "http")) return 1;
  if (httpc_ascii_ieq_n(url, n, "https")) return 1;
  if (allow_file_protocol && httpc_ascii_ieq_n(url, n, "file")) return 1;
  return 0;
}

static size_t httpc_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata) {
  httpc_req_t *ctx = (httpc_req_t *)userdata;
  size_t n = 0;
  size_t need = 0;
  if (httpc_size_mul(size, nmemb, &n) != 0) {
    snprintf(ctx->err, sizeof(ctx->err), "response chunk size overflow");
    return 0;
  }
  if (n == 0) return 0;

  if (ctx->resp_len > ctx->max_body_bytes || n > ctx->max_body_bytes - ctx->resp_len) {
    ctx->too_large = 1;
    if (ctx->err[0] == '\0') {
      snprintf(ctx->err, sizeof(ctx->err),
          "response body exceeds max_body_bytes (%zu)", ctx->max_body_bytes);
    }
    return 0;
  }
  if (httpc_size_add(ctx->resp_len, n, &need) != 0 || httpc_size_add(need, 1, &need) != 0) {
    snprintf(ctx->err, sizeof(ctx->err), "response size overflow");
    return 0;
  }

  if (need > ctx->resp_cap) {
    size_t next = ctx->resp_cap ? (ctx->resp_cap * 2) : 8192;
    while (next < need) {
      if (next > (size_t)-1 / 2) {
        next = need;
        break;
      }
      next *= 2;
    }
    if (next < need) next = need;
    char *p = (char *)httpc_req_realloc(ctx, ctx->resp_body, ctx->resp_cap, next);
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
  size_t n = 0;
  size_t raw_n = 0;
  if (httpc_size_mul(size, nitems, &n) != 0) {
    snprintf(ctx->err, sizeof(ctx->err), "header chunk size overflow");
    return 0;
  }
  raw_n = n;
  if (n == 0) return 0;

  if (ctx->header_bytes > ctx->max_header_bytes || n > ctx->max_header_bytes - ctx->header_bytes) {
    ctx->too_large = 1;
    if (ctx->err[0] == '\0') {
      snprintf(ctx->err, sizeof(ctx->err),
          "response headers exceed max_header_bytes (%zu)", ctx->max_header_bytes);
    }
    return 0;
  }
  ctx->header_bytes += n;

  // Trim trailing CRLF
  while (n > 0 && (buffer[n - 1] == '\n' || buffer[n - 1] == '\r')) n--;
  if (n == 0) return raw_n;

  // Ignore status line and continuation lines
  if (n >= 5 && memcmp(buffer, "HTTP/", 5) == 0) return raw_n;
  if (buffer[0] == ' ' || buffer[0] == '\t') return raw_n;

  // Only store lines containing ':'
  const char *colon = (const char *)memchr(buffer, ':', n);
  if (!colon) return raw_n;

  int push_rc = httpc_strlist_push(ctx, &ctx->resp_headers, buffer, n);
  if (push_rc != 0) {
    if (push_rc == -2) {
      ctx->too_large = 1;
      if (ctx->err[0] == '\0') {
        snprintf(ctx->err, sizeof(ctx->err),
            "response headers exceed max_header_lines (%zu)", ctx->max_header_lines);
      }
    } else {
      snprintf(ctx->err, sizeof(ctx->err), "out of memory");
    }
    return 0;
  }

  return raw_n;
}

#ifdef CURLOPT_XFERINFOFUNCTION
static int httpc_xferinfo_cb(void *clientp, curl_off_t dltotal, curl_off_t dlnow, curl_off_t ultotal, curl_off_t ulnow) {
  (void)dltotal;
  (void)ultotal;
  (void)ulnow;
  httpc_req_t *ctx = (httpc_req_t *)clientp;
  if (dlnow < 0) return 0;
  if ((unsigned long long)dlnow > (unsigned long long)ctx->max_body_bytes) {
    ctx->too_large = 1;
    if (ctx->err[0] == '\0') {
      snprintf(ctx->err, sizeof(ctx->err),
          "response body exceeds max_body_bytes (%zu)", ctx->max_body_bytes);
    }
    return 1;
  }
  return 0;
}
#endif

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
  curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
  curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, ctx->follow_redirects ? 1L : 0L);
  curl_easy_setopt(curl, CURLOPT_MAXREDIRS, ctx->max_redirects);
  curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, ctx->timeout_ms);
  curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, ctx->connect_timeout_ms);
  if (ctx->low_speed_limit_bps > 0 && ctx->low_speed_time_sec > 0) {
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_LIMIT, ctx->low_speed_limit_bps);
    curl_easy_setopt(curl, CURLOPT_LOW_SPEED_TIME, ctx->low_speed_time_sec);
  }
#ifdef CURLOPT_MAXFILESIZE_LARGE
  curl_easy_setopt(curl, CURLOPT_MAXFILESIZE_LARGE, (curl_off_t)ctx->max_body_bytes);
#endif
#if defined(CURLOPT_PROTOCOLS_STR)
  curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, ctx->allow_file_protocol ? "http,https,file" : "http,https");
#elif defined(CURLOPT_PROTOCOLS)
  {
    long protocols = CURLPROTO_HTTP | CURLPROTO_HTTPS;
    if (ctx->allow_file_protocol) protocols |= CURLPROTO_FILE;
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS, protocols);
  }
#endif
#if defined(CURLOPT_REDIR_PROTOCOLS_STR)
  curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS_STR, "http,https");
#elif defined(CURLOPT_REDIR_PROTOCOLS)
  curl_easy_setopt(curl, CURLOPT_REDIR_PROTOCOLS, CURLPROTO_HTTP | CURLPROTO_HTTPS);
#endif
#ifdef CURLOPT_XFERINFOFUNCTION
  curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, httpc_xferinfo_cb);
  curl_easy_setopt(curl, CURLOPT_XFERINFODATA, ctx);
  curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
#endif
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
#ifdef CURLOPT_POSTFIELDSIZE_LARGE
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)ctx->body_len);
#else
    if (ctx->body_len > (size_t)LONG_MAX) {
      snprintf(ctx->err, sizeof(ctx->err), "request body too large");
      curl_easy_cleanup(curl);
      return;
    }
    curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE, (long)ctx->body_len);
#endif
  }

  if (ctx->req_headers) {
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, ctx->req_headers);
  }

  curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, httpc_write_cb);
  curl_easy_setopt(curl, CURLOPT_WRITEDATA, ctx);
  curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, httpc_header_cb);
  curl_easy_setopt(curl, CURLOPT_HEADERDATA, ctx);

  CURLcode rc = curl_easy_perform(curl);

  if (ctx->err[0] != '\0') {
    // keep existing message (e.g. OOM)
  } else if (ctx->too_large) {
    snprintf(ctx->err, sizeof(ctx->err), "response exceeds configured limits");
  } else if (rc != CURLE_OK) {
    snprintf(ctx->err, sizeof(ctx->err), "%s", curl_easy_strerror(rc));
  } else {
    long status = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
    ctx->status = status;

    char *eff = NULL;
    if (curl_easy_getinfo(curl, CURLINFO_EFFECTIVE_URL, &eff) == CURLE_OK && eff) {
      size_t n = strlen(eff);
      ctx->effective_url = (char *)httpc_req_alloc(ctx, n + 1);
      if (ctx->effective_url) {
        memcpy(ctx->effective_url, eff, n + 1);
      }
    }
  }

  curl_easy_cleanup(curl);
}

static void httpc_after_cb(uv_work_t *req, int status) {
  httpc_req_t *ctx = (httpc_req_t *)req->data;
  lua_State *L = ctx->L;
  httpc_completed_count++;

  if (status == UV_ECANCELED && ctx->err[0] == '\0') {
    snprintf(ctx->err, sizeof(ctx->err), "httpc request canceled");
  }

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);
  if (!lua_isthread(L, -1)) {
    httpc_invalid_count++;
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in httpc.request\n");
    goto cleanup;
  }
  lua_State *co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (ctx->err[0] != '\0') {
    httpc_invalid_count++;
    lua_pushnil(co);
    lua_pushstring(co, ctx->err);
    lunet_co_resume(co, 2);
    goto cleanup;
  }
  httpc_valid_count++;

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
  httpc_req_free(ctx, ctx->url);
  httpc_req_free(ctx, ctx->method);
  httpc_req_free(ctx, ctx->body);
  if (ctx->req_headers) curl_slist_free_all(ctx->req_headers);
  httpc_req_free(ctx, ctx->resp_body);
  httpc_strlist_free(ctx, &ctx->resp_headers);
  httpc_req_free(ctx, ctx->effective_url);
  httpc_req_allocator_shutdown(ctx);
  lunet_free_nonnull(ctx);
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
      size_t line_bytes = 0;
      if (httpc_size_add(kn, vn, &line_bytes) != 0 || httpc_size_add(line_bytes, 3, &line_bytes) != 0) {
        snprintf(err, errsz, "header line too large");
        return -1;
      }
      char *line = (char *)lunet_alloc(line_bytes);
      if (!line) {
        snprintf(err, errsz, "out of memory");
        return -1;
      }
      memcpy(line, k, kn);
      line[kn] = ':';
      line[kn + 1] = ' ';
      memcpy(line + kn + 2, v, vn);
      line[kn + 2 + vn] = '\0';
      struct curl_slist *prev = *out;
      *out = curl_slist_append(*out, line);
      lunet_free_nonnull(line);
      if (!*out) {
        *out = prev;
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
    size_t line_bytes = 0;
    if (httpc_size_add(kn, vn, &line_bytes) != 0 || httpc_size_add(line_bytes, 3, &line_bytes) != 0) {
      lua_pop(L, 1);
      snprintf(err, errsz, "header line too large");
      return -1;
    }
    char *line = (char *)lunet_alloc(line_bytes);
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
    struct curl_slist *prev = *out;
    *out = curl_slist_append(*out, line);
    lunet_free_nonnull(line);
    if (!*out) {
      *out = prev;
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

  char opt_err[256];
  long timeout_ms = HTTPC_DEFAULT_TIMEOUT_MS;
  if (httpc_opt_long(L, 1, "timeout_ms", HTTPC_DEFAULT_TIMEOUT_MS, 1, LONG_MAX, &timeout_ms, opt_err, sizeof(opt_err)) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, opt_err);
    return 2;
  }

  long connect_timeout_ms = timeout_ms;
  if (httpc_opt_long(L, 1, "connect_timeout_ms", timeout_ms, 1, LONG_MAX, &connect_timeout_ms, opt_err, sizeof(opt_err)) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, opt_err);
    return 2;
  }
  if (connect_timeout_ms > timeout_ms) {
    lua_pushnil(L);
    lua_pushstring(L, "connect_timeout_ms must be <= timeout_ms");
    return 2;
  }

  size_t max_body_bytes = HTTPC_DEFAULT_MAX_BODY_BYTES;
  if (httpc_opt_size(L, 1, "max_body_bytes", HTTPC_DEFAULT_MAX_BODY_BYTES, 1, (size_t)LONG_MAX, &max_body_bytes, opt_err, sizeof(opt_err)) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, opt_err);
    return 2;
  }

  size_t max_header_bytes = HTTPC_DEFAULT_MAX_HEADER_BYTES;
  if (httpc_opt_size(L, 1, "max_header_bytes", HTTPC_DEFAULT_MAX_HEADER_BYTES, 1, (size_t)LONG_MAX, &max_header_bytes, opt_err, sizeof(opt_err)) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, opt_err);
    return 2;
  }

  size_t max_header_lines = HTTPC_DEFAULT_MAX_HEADER_LINES;
  if (httpc_opt_size(L, 1, "max_header_lines", HTTPC_DEFAULT_MAX_HEADER_LINES, 1, (size_t)LONG_MAX, &max_header_lines, opt_err, sizeof(opt_err)) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, opt_err);
    return 2;
  }

  int follow_redirects = 1;
  if (httpc_opt_bool(L, 1, "follow_redirects", 1, &follow_redirects, opt_err, sizeof(opt_err)) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, opt_err);
    return 2;
  }

  long max_redirects = HTTPC_DEFAULT_MAX_REDIRECTS;
  if (httpc_opt_long(L, 1, "max_redirects", HTTPC_DEFAULT_MAX_REDIRECTS, 0, LONG_MAX, &max_redirects, opt_err, sizeof(opt_err)) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, opt_err);
    return 2;
  }

  long low_speed_limit_bps = 0;
  if (httpc_opt_long(L, 1, "low_speed_limit_bps", 0, 0, LONG_MAX, &low_speed_limit_bps, opt_err, sizeof(opt_err)) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, opt_err);
    return 2;
  }

  long low_speed_time_sec = 0;
  if (httpc_opt_long(L, 1, "low_speed_time_sec", 0, 0, LONG_MAX, &low_speed_time_sec, opt_err, sizeof(opt_err)) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, opt_err);
    return 2;
  }
  if ((low_speed_limit_bps == 0) != (low_speed_time_sec == 0)) {
    lua_pushnil(L);
    lua_pushstring(L, "low_speed_limit_bps and low_speed_time_sec must both be set (or both 0)");
    return 2;
  }

  int allow_file_protocol = 0;
  if (httpc_opt_bool(L, 1, "allow_file_protocol", 0, &allow_file_protocol, opt_err, sizeof(opt_err)) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, opt_err);
    return 2;
  }
  if (!httpc_url_scheme_allowed(url, allow_file_protocol)) {
    lua_pushnil(L);
    lua_pushstring(L, allow_file_protocol
        ? "url scheme not allowed (allowed: http, https, file)"
        : "url scheme not allowed (allowed: http, https)");
    return 2;
  }

  int insecure = 0;
  lua_getfield(L, 1, "insecure");
  if (lua_isnil(L, -1)) {
    insecure = httpc_env_truthy("LUNET_HTTPC_INSECURE") ? 1 : 0;
  } else if (lua_isboolean(L, -1)) {
    insecure = lua_toboolean(L, -1) ? 1 : 0;
  } else {
    lua_pop(L, 1);
    lua_pushnil(L);
    lua_pushstring(L, "insecure must be boolean");
    return 2;
  }
  lua_pop(L, 1);

  httpc_req_t *ctx = (httpc_req_t *)lunet_alloc(sizeof(httpc_req_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  memset(ctx, 0, sizeof(*ctx));

  ctx->L = L;
  ctx->req.data = ctx;
  ctx->timeout_ms = timeout_ms;
  ctx->connect_timeout_ms = connect_timeout_ms;
  ctx->low_speed_limit_bps = low_speed_limit_bps;
  ctx->low_speed_time_sec = low_speed_time_sec;
  ctx->follow_redirects = follow_redirects;
  ctx->max_redirects = max_redirects;
  ctx->max_body_bytes = max_body_bytes;
  ctx->max_header_bytes = max_header_bytes;
  ctx->max_header_lines = max_header_lines;
  ctx->allow_file_protocol = allow_file_protocol;
  ctx->insecure = insecure;

#ifdef LUNET_HTTPC_WORKER_EM
  if (httpc_worker_em_required_bytes(
          url,
          method,
          body_len,
          max_body_bytes,
          max_header_bytes,
          max_header_lines,
          &ctx->req_em_required_bytes,
          ctx->err,
          sizeof(ctx->err)) != 0) {
    lua_pushnil(L);
    lua_pushstring(L, ctx->err);
    lunet_free_nonnull(ctx);
    return 2;
  }
#endif

  if (httpc_req_allocator_init(ctx, ctx->err, sizeof(ctx->err)) != 0) {
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, ctx->err[0] ? ctx->err : "out of memory");
    return 2;
  }

  ctx->url = lunet_strdup_ctx(ctx, url);
  ctx->method = lunet_strdup_ctx(ctx, method);
  if (!ctx->url || !ctx->method) {
    httpc_req_free(ctx, ctx->url);
    httpc_req_free(ctx, ctx->method);
    httpc_req_allocator_shutdown(ctx);
    lunet_free_nonnull(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  if (body) {
    size_t body_alloc_bytes = 0;
    if (httpc_size_add(body_len, 1, &body_alloc_bytes) != 0) {
      httpc_req_free(ctx, ctx->url);
      httpc_req_free(ctx, ctx->method);
      httpc_req_allocator_shutdown(ctx);
      lunet_free_nonnull(ctx);
      lua_pushnil(L);
      lua_pushstring(L, "request body too large");
      return 2;
    }
    ctx->body = (char *)httpc_req_alloc(ctx, body_alloc_bytes);
    if (!ctx->body) {
      httpc_req_free(ctx, ctx->url);
      httpc_req_free(ctx, ctx->method);
      httpc_req_allocator_shutdown(ctx);
      lunet_free_nonnull(ctx);
      lua_pushnil(L);
      lua_pushstring(L, "out of memory");
      return 2;
    }
    memcpy(ctx->body, body, body_len);
    ctx->body[body_len] = '\0';
    ctx->body_len = body_len;
  }

#ifdef LUNET_HTTPC_WORKER_EM
  {
    size_t resp_cap = 0;
    if (httpc_size_add(ctx->max_body_bytes, 1, &resp_cap) != 0) {
      httpc_req_free(ctx, ctx->url);
      httpc_req_free(ctx, ctx->method);
      httpc_req_free(ctx, ctx->body);
      httpc_req_allocator_shutdown(ctx);
      lunet_free_nonnull(ctx);
      lua_pushnil(L);
      lua_pushstring(L, "max_body_bytes too large");
      return 2;
    }
    ctx->resp_body = (char *)httpc_req_alloc(ctx, resp_cap);
    if (!ctx->resp_body) {
      httpc_req_free(ctx, ctx->url);
      httpc_req_free(ctx, ctx->method);
      httpc_req_free(ctx, ctx->body);
      httpc_req_allocator_shutdown(ctx);
      lunet_free_nonnull(ctx);
      lua_pushnil(L);
      lua_pushstring(L, "out of memory");
      return 2;
    }
    ctx->resp_cap = resp_cap;
    ctx->resp_body[0] = '\0';
  }
#endif

  ctx->req_headers = NULL;
  lua_getfield(L, 1, "headers");
  if (!lua_isnil(L, -1)) {
    if (httpc_parse_headers(L, lua_gettop(L), &ctx->req_headers, ctx->err, sizeof(ctx->err)) != 0) {
      lua_pop(L, 1);
      lua_pushnil(L);
      lua_pushstring(L, ctx->err[0] ? ctx->err : "invalid headers");
      httpc_req_free(ctx, ctx->url);
      httpc_req_free(ctx, ctx->method);
      httpc_req_free(ctx, ctx->body);
      if (ctx->req_headers) curl_slist_free_all(ctx->req_headers);
      httpc_req_allocator_shutdown(ctx);
      lunet_free_nonnull(ctx);
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
    httpc_req_free(ctx, ctx->url);
    httpc_req_free(ctx, ctx->method);
    httpc_req_free(ctx, ctx->body);
    if (ctx->req_headers) curl_slist_free_all(ctx->req_headers);
    httpc_req_allocator_shutdown(ctx);
    lunet_free_nonnull(ctx);
    return 2;
  }

  return lua_yield(L, 0);
}

int lunet_open_httpc(lua_State *L) {
  uv_once(&httpc_curl_global_once, httpc_curl_global_init_once);
  if (httpc_curl_global_rc != CURLE_OK) {
    return luaL_error(L, "curl_global_init failed: %s", curl_easy_strerror(httpc_curl_global_rc));
  }
  uv_once(&httpc_summary_once, httpc_register_shutdown_summary_once);
  luaL_Reg funcs[] = {{"request", httpc_request}, {NULL, NULL}};
  luaL_newlib(L, funcs);
  return 1;
}

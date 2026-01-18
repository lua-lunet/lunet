#include "su.h"

#include <errno.h>
#include <fcntl.h>
#include <lauxlib.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>
#include <uv.h>

#include "co.h"

#define SU_BLOCK_SIZE 4096
#define SU_BITMAP_MAGIC "SUBM"
#define SU_BITMAP_VERSION 1
#define SU_BITMAP_HEADER_SIZE 16  // 4 magic + 4 ver + 8 max

typedef struct su_write_ctx_s su_write_ctx_t;

typedef struct bm_entry_s {
  size_t byte_idx;
  uint32_t gen;
  int inflight;
  su_write_ctx_t *waiters_head;
  su_write_ctx_t *waiters_tail;
  struct bm_entry_s *next;
} bm_entry_t;

typedef struct {
  uv_file data_fd;
  uv_file bm_fd;
  uint64_t max_addresses;
  size_t bm_len;
  uint8_t *bm_bytes;       // committed bits (in memory)
  uint8_t *pending_bytes;  // in-flight writes (in memory only)

  size_t bm_bucket_count;
  bm_entry_t **bm_buckets;  // hash table for active bitmap bytes
} su_t;

typedef struct {
  su_t *su;
} su_ud_t;

typedef enum {
  SU_WSTEP_DATA_WRITE = 1,
  SU_WSTEP_DATA_FSYNC,
  SU_WSTEP_BM_WRITE,
  SU_WSTEP_BM_FSYNC,
} su_write_step_t;

struct su_write_ctx_s {
  uv_fs_t req;
  lua_State *L;
  int co_ref;
  su_t *su;

  uint64_t address;
  size_t byte_idx;
  uint8_t bit_mask;

  uint32_t target_gen;  // bitmap generation that must be durable

  su_write_step_t step;
  char *data;
  size_t data_len;

  // linked-list node for bitmap byte waiters
  su_write_ctx_t *next_waiter;
};

typedef struct {
  uv_fs_t req;
  su_t *su;
  bm_entry_t *entry;
  uint32_t flush_gen;
  size_t byte_idx;
  uint8_t byte_value;
  int do_fsync;
} bm_flush_ctx_t;

typedef struct {
  uv_fs_t req;
  lua_State *L;
  int co_ref;
  su_t *su;
  uint64_t address;
  char *buf;
} su_read_ctx_t;

static uint32_t read_u32_le(const uint8_t *p) {
  return ((uint32_t)p[0]) | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static uint64_t read_u64_le(const uint8_t *p) {
  return ((uint64_t)p[0]) | ((uint64_t)p[1] << 8) | ((uint64_t)p[2] << 16) | ((uint64_t)p[3] << 24) |
         ((uint64_t)p[4] << 32) | ((uint64_t)p[5] << 40) | ((uint64_t)p[6] << 48) | ((uint64_t)p[7] << 56);
}

static void write_u32_le(uint8_t *p, uint32_t v) {
  p[0] = (uint8_t)(v & 0xff);
  p[1] = (uint8_t)((v >> 8) & 0xff);
  p[2] = (uint8_t)((v >> 16) & 0xff);
  p[3] = (uint8_t)((v >> 24) & 0xff);
}

static void write_u64_le(uint8_t *p, uint64_t v) {
  p[0] = (uint8_t)(v & 0xff);
  p[1] = (uint8_t)((v >> 8) & 0xff);
  p[2] = (uint8_t)((v >> 16) & 0xff);
  p[3] = (uint8_t)((v >> 24) & 0xff);
  p[4] = (uint8_t)((v >> 32) & 0xff);
  p[5] = (uint8_t)((v >> 40) & 0xff);
  p[6] = (uint8_t)((v >> 48) & 0xff);
  p[7] = (uint8_t)((v >> 56) & 0xff);
}

static int mkdir_p(const char *path) {
  // best-effort: create only the leaf directory
  if (mkdir(path, 0755) == 0) return 0;
  if (errno == EEXIST) return 0;
  return -1;
}

static void bm_entry_append_waiter(bm_entry_t *e, su_write_ctx_t *w) {
  w->next_waiter = NULL;
  if (!e->waiters_head) {
    e->waiters_head = e->waiters_tail = w;
  } else {
    e->waiters_tail->next_waiter = w;
    e->waiters_tail = w;
  }
}

static size_t bm_hash_idx(const su_t *su, size_t byte_idx) {
  // simple mix; bm_bucket_count is power-of-two
  size_t x = byte_idx;
  x ^= x >> 33;
  x *= 0xff51afd7ed558ccdULL;
  x ^= x >> 33;
  return x & (su->bm_bucket_count - 1);
}

static bm_entry_t *bm_get_or_create_entry(su_t *su, size_t byte_idx) {
  size_t b = bm_hash_idx(su, byte_idx);
  bm_entry_t *cur = su->bm_buckets[b];
  while (cur) {
    if (cur->byte_idx == byte_idx) return cur;
    cur = cur->next;
  }
  bm_entry_t *e = (bm_entry_t *)calloc(1, sizeof(bm_entry_t));
  if (!e) return NULL;
  e->byte_idx = byte_idx;
  e->gen = 0;
  e->inflight = 0;
  e->waiters_head = NULL;
  e->waiters_tail = NULL;
  e->next = su->bm_buckets[b];
  su->bm_buckets[b] = e;
  return e;
}

static void bm_remove_entry_if_idle(su_t *su, bm_entry_t *e) {
  if (!e || e->inflight || e->waiters_head) return;
  size_t b = bm_hash_idx(su, e->byte_idx);
  bm_entry_t **pp = &su->bm_buckets[b];
  while (*pp) {
    if (*pp == e) {
      *pp = e->next;
      free(e);
      return;
    }
    pp = &(*pp)->next;
  }
}

static void su_resume_write_waiter_ok(su_write_ctx_t *w) {
  lua_State *L = w->L;
  lua_rawgeti(L, LUA_REGISTRYINDEX, w->co_ref);
  luaL_unref(L, LUA_REGISTRYINDEX, w->co_ref);
  w->co_ref = LUA_NOREF;

  if (lua_isthread(L, -1)) {
    lua_State *co = lua_tothread(L, -1);
    lua_pop(L, 1);
    // clear pending bit
    size_t pbyte = w->byte_idx;
    w->su->pending_bytes[pbyte] &= (uint8_t)~w->bit_mask;

    lua_pushboolean(co, 1);
    lua_pushnil(co);
    int st = lua_resume(co, 2);
    if (st != LUA_OK && st != LUA_YIELD) {
      const char *err = lua_tostring(co, -1);
      if (err) fprintf(stderr, "[lunet.su] resume error (write ok): %s\n", err);
    }
  } else {
    lua_pop(L, 1);
  }

  uv_fs_req_cleanup(&w->req);
  if (w->data) free(w->data);
  free(w);
}

static void su_resume_write_waiter_err(su_write_ctx_t *w, const char *err) {
  lua_State *L = w->L;
  lua_rawgeti(L, LUA_REGISTRYINDEX, w->co_ref);
  luaL_unref(L, LUA_REGISTRYINDEX, w->co_ref);
  w->co_ref = LUA_NOREF;

  if (lua_isthread(L, -1)) {
    lua_State *co = lua_tothread(L, -1);
    lua_pop(L, 1);
    // clear pending bit
    size_t pbyte = w->byte_idx;
    w->su->pending_bytes[pbyte] &= (uint8_t)~w->bit_mask;

    lua_pushnil(co);
    lua_pushstring(co, err ? err : "unknown error");
    int st = lua_resume(co, 2);
    if (st != LUA_OK && st != LUA_YIELD) {
      const char *e = lua_tostring(co, -1);
      if (e) fprintf(stderr, "[lunet.su] resume error (write err): %s\n", e);
    }
  } else {
    lua_pop(L, 1);
  }

  uv_fs_req_cleanup(&w->req);
  if (w->data) free(w->data);
  free(w);
}

static void bm_flush_cb(uv_fs_t *req);
static void bm_fsync_cb(uv_fs_t *req);

static int bm_start_flush(su_t *su, bm_entry_t *e) {
  if (!su || !e) return -1;
  if (e->inflight) return 0;

  bm_flush_ctx_t *ctx = (bm_flush_ctx_t *)calloc(1, sizeof(bm_flush_ctx_t));
  if (!ctx) return -1;

  e->inflight = 1;

  ctx->su = su;
  ctx->entry = e;
  ctx->flush_gen = e->gen;
  ctx->byte_idx = e->byte_idx;
  ctx->byte_value = su->bm_bytes[e->byte_idx];
  ctx->do_fsync = 1;
  ctx->req.data = ctx;

  uv_buf_t buf = uv_buf_init((char *)&ctx->byte_value, 1);
  int rc = uv_fs_write(uv_default_loop(), &ctx->req, su->bm_fd, &buf, 1,
                       (int64_t)(SU_BITMAP_HEADER_SIZE + (int64_t)ctx->byte_idx), bm_flush_cb);
  if (rc < 0) {
    e->inflight = 0;
    free(ctx);
    return rc;
  }
  return 0;
}

static void bm_flush_cb(uv_fs_t *req) {
  bm_flush_ctx_t *ctx = (bm_flush_ctx_t *)req->data;
  su_t *su = ctx->su;
  bm_entry_t *e = ctx->entry;

  if (req->result < 0) {
    // Fail all waiters that were waiting for <= flush_gen.
    su_write_ctx_t *prev = NULL;
    su_write_ctx_t *cur = e->waiters_head;
    while (cur) {
      su_write_ctx_t *next = cur->next_waiter;
      if (cur->target_gen <= ctx->flush_gen) {
        if (prev) {
          prev->next_waiter = next;
        } else {
          e->waiters_head = next;
        }
        if (e->waiters_tail == cur) e->waiters_tail = prev;
        su_resume_write_waiter_err(cur, uv_strerror((int)req->result));
      } else {
        prev = cur;
      }
      cur = next;
    }

    e->inflight = 0;
    uv_fs_req_cleanup(req);
    free(ctx);
    bm_remove_entry_if_idle(su, e);
    return;
  }

  // fsync bitmap fd to make commit durable
  ctx->req.data = ctx;
  int rc = uv_fs_fsync(uv_default_loop(), &ctx->req, su->bm_fd, bm_fsync_cb);
  if (rc < 0) {
    // treat as error
    su_write_ctx_t *prev = NULL;
    su_write_ctx_t *cur = e->waiters_head;
    while (cur) {
      su_write_ctx_t *next = cur->next_waiter;
      if (cur->target_gen <= ctx->flush_gen) {
        if (prev) {
          prev->next_waiter = next;
        } else {
          e->waiters_head = next;
        }
        if (e->waiters_tail == cur) e->waiters_tail = prev;
        su_resume_write_waiter_err(cur, uv_strerror(rc));
      } else {
        prev = cur;
      }
      cur = next;
    }
    e->inflight = 0;
    uv_fs_req_cleanup(req);
    free(ctx);
    bm_remove_entry_if_idle(su, e);
    return;
  }
}

static void bm_fsync_cb(uv_fs_t *req) {
  bm_flush_ctx_t *ctx = (bm_flush_ctx_t *)req->data;
  su_t *su = ctx->su;
  bm_entry_t *e = ctx->entry;

  if (req->result < 0) {
    // Fail all waiters that were waiting for <= flush_gen.
    su_write_ctx_t *prev = NULL;
    su_write_ctx_t *cur = e->waiters_head;
    while (cur) {
      su_write_ctx_t *next = cur->next_waiter;
      if (cur->target_gen <= ctx->flush_gen) {
        if (prev) {
          prev->next_waiter = next;
        } else {
          e->waiters_head = next;
        }
        if (e->waiters_tail == cur) e->waiters_tail = prev;
        su_resume_write_waiter_err(cur, uv_strerror((int)req->result));
      } else {
        prev = cur;
      }
      cur = next;
    }
  } else {
    // Resume all waiters satisfied by this flush.
    su_write_ctx_t *prev = NULL;
    su_write_ctx_t *cur = e->waiters_head;
    while (cur) {
      su_write_ctx_t *next = cur->next_waiter;
      if (cur->target_gen <= ctx->flush_gen) {
        if (prev) {
          prev->next_waiter = next;
        } else {
          e->waiters_head = next;
        }
        if (e->waiters_tail == cur) e->waiters_tail = prev;
        su_resume_write_waiter_ok(cur);
      } else {
        prev = cur;
      }
      cur = next;
    }
  }

  // This flush is done.
  e->inflight = 0;

  // If more bits were set since flush started, flush again.
  if (e->waiters_head && e->gen > ctx->flush_gen) {
    // start next flush with latest value/gen
    (void)bm_start_flush(su, e);
  } else if (!e->waiters_head) {
    bm_remove_entry_if_idle(su, e);
  }

  uv_fs_req_cleanup(req);
  free(ctx);
}

static int su_get_bit(const uint8_t *bm, size_t byte_idx, uint8_t bit_mask) {
  return (bm[byte_idx] & bit_mask) != 0;
}

static su_ud_t *su_check(lua_State *L, int idx) {
  return (su_ud_t *)luaL_checkudata(L, idx, "lunet.su");
}

static int su_close(lua_State *L) {
  su_ud_t *ud = su_check(L, 1);
  if (!ud || !ud->su) {
    lua_pushnil(L);
    return 1;
  }
  su_t *su = ud->su;
  ud->su = NULL;

  if (su->data_fd >= 0) close(su->data_fd);
  if (su->bm_fd >= 0) close(su->bm_fd);
  if (su->bm_bytes) free(su->bm_bytes);
  if (su->pending_bytes) free(su->pending_bytes);

  if (su->bm_buckets) {
    for (size_t i = 0; i < su->bm_bucket_count; i++) {
      bm_entry_t *e = su->bm_buckets[i];
      while (e) {
        bm_entry_t *n = e->next;
        // any waiters remaining get failed (close)
        su_write_ctx_t *w = e->waiters_head;
        while (w) {
          su_write_ctx_t *wn = w->next_waiter;
          su_resume_write_waiter_err(w, "storage unit closed");
          w = wn;
        }
        free(e);
        e = n;
      }
    }
    free(su->bm_buckets);
  }

  free(su);
  lua_pushnil(L);
  return 1;
}

static int su_is_written(lua_State *L) {
  su_ud_t *ud = su_check(L, 1);
  su_t *su = ud->su;
  uint64_t address = (uint64_t)luaL_checknumber(L, 2);
  if (!su || address >= su->max_addresses) {
    lua_pushboolean(L, 0);
    return 1;
  }
  size_t byte_idx = (size_t)(address >> 3);
  uint8_t bit_mask = (uint8_t)(1u << (address & 7u));
  lua_pushboolean(L, su_get_bit(su->bm_bytes, byte_idx, bit_mask));
  return 1;
}

static void su_write_step_cb(uv_fs_t *req);

static int su_write_once(lua_State *L) {
  if (lunet_ensure_coroutine(L, "su.write_once") != 0) {
    return lua_error(L);
  }

  su_ud_t *ud = su_check(L, 1);
  su_t *su = ud->su;
  if (!su) {
    lua_pushnil(L);
    lua_pushstring(L, "storage unit closed");
    return 2;
  }

  uint64_t address = (uint64_t)luaL_checknumber(L, 2);
  size_t data_len = 0;
  const char *data = luaL_checklstring(L, 3, &data_len);
  if (data_len != SU_BLOCK_SIZE) {
    lua_pushnil(L);
    lua_pushstring(L, "data must be exactly 4096 bytes");
    return 2;
  }
  if (address >= su->max_addresses) {
    lua_pushnil(L);
    lua_pushstring(L, "address out of range");
    return 2;
  }

  size_t byte_idx = (size_t)(address >> 3);
  uint8_t bit_mask = (uint8_t)(1u << (address & 7u));

  if (su_get_bit(su->bm_bytes, byte_idx, bit_mask)) {
    lua_pushnil(L);
    lua_pushstring(L, "ALREADY_WRITTEN");
    return 2;
  }
  if (su_get_bit(su->pending_bytes, byte_idx, bit_mask)) {
    lua_pushnil(L);
    lua_pushstring(L, "BUSY");
    return 2;
  }

  // mark pending
  su->pending_bytes[byte_idx] |= bit_mask;

  su_write_ctx_t *ctx = (su_write_ctx_t *)calloc(1, sizeof(su_write_ctx_t));
  if (!ctx) {
    su->pending_bytes[byte_idx] &= (uint8_t)~bit_mask;
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  ctx->L = L;
  ctx->co_ref = LUA_NOREF;
  ctx->su = su;
  ctx->address = address;
  ctx->byte_idx = byte_idx;
  ctx->bit_mask = bit_mask;
  ctx->step = SU_WSTEP_DATA_WRITE;
  ctx->data_len = data_len;
  ctx->data = (char *)malloc(data_len);
  if (!ctx->data) {
    free(ctx);
    su->pending_bytes[byte_idx] &= (uint8_t)~bit_mask;
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  memcpy(ctx->data, data, data_len);
  ctx->req.data = ctx;

  // save coroutine reference
  lua_pushthread(L);
  ctx->co_ref = luaL_ref(L, LUA_REGISTRYINDEX);

  uv_buf_t buf = uv_buf_init(ctx->data, (unsigned int)ctx->data_len);
  int rc = uv_fs_write(uv_default_loop(), &ctx->req, su->data_fd, &buf, 1,
                       (int64_t)(address * (uint64_t)SU_BLOCK_SIZE), su_write_step_cb);
  if (rc < 0) {
    luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
    ctx->co_ref = LUA_NOREF;
    su->pending_bytes[byte_idx] &= (uint8_t)~bit_mask;
    free(ctx->data);
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(rc));
    return 2;
  }

  return lua_yield(L, 0);
}

static void su_write_step_cb(uv_fs_t *req) {
  su_write_ctx_t *ctx = (su_write_ctx_t *)req->data;
  su_t *su = ctx->su;

  if (ctx->step == SU_WSTEP_DATA_WRITE) {
    if (req->result != (ssize_t)SU_BLOCK_SIZE) {
      const char *err = (req->result < 0) ? uv_strerror((int)req->result) : "SHORT_WRITE";
      su_resume_write_waiter_err(ctx, err);
      return;
    }
    ctx->step = SU_WSTEP_DATA_FSYNC;
    // free the data buffer early; data is already in kernel buffers
    free(ctx->data);
    ctx->data = NULL;

    int rc = uv_fs_fsync(uv_default_loop(), &ctx->req, su->data_fd, su_write_step_cb);
    if (rc < 0) {
      su_resume_write_waiter_err(ctx, uv_strerror(rc));
      return;
    }
    return;
  }

  if (ctx->step == SU_WSTEP_DATA_FSYNC) {
    if (req->result < 0) {
      su_resume_write_waiter_err(ctx, uv_strerror((int)req->result));
      return;
    }

    // Mark committed in memory, then enqueue waiter for durable bitmap flush.
    bm_entry_t *e = bm_get_or_create_entry(su, ctx->byte_idx);
    if (!e) {
      su_resume_write_waiter_err(ctx, "out of memory");
      return;
    }

    // bump generation and set committed bit
    e->gen++;
    su->bm_bytes[ctx->byte_idx] |= ctx->bit_mask;
    ctx->target_gen = e->gen;

    bm_entry_append_waiter(e, ctx);

    // start / continue flushing this bitmap byte
    int rc = bm_start_flush(su, e);
    if (rc < 0) {
      // fail this one; keep others
      // remove ctx from waiters list head/tail (it should be at tail)
      su_write_ctx_t *prev = NULL;
      su_write_ctx_t *cur = e->waiters_head;
      while (cur) {
        if (cur == ctx) {
          su_write_ctx_t *next = cur->next_waiter;
          if (prev) {
            prev->next_waiter = next;
          } else {
            e->waiters_head = next;
          }
          if (e->waiters_tail == cur) e->waiters_tail = prev;
          break;
        }
        prev = cur;
        cur = cur->next_waiter;
      }
      su_resume_write_waiter_err(ctx, uv_strerror(rc));
    }
    return;
  }
}

static void su_read_cb(uv_fs_t *req) {
  su_read_ctx_t *ctx = (su_read_ctx_t *)req->data;
  lua_State *L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
  ctx->co_ref = LUA_NOREF;

  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    uv_fs_req_cleanup(req);
    free(ctx->buf);
    free(ctx);
    return;
  }

  lua_State *co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (req->result == (ssize_t)SU_BLOCK_SIZE) {
    lua_pushlstring(co, ctx->buf, SU_BLOCK_SIZE);
    lua_pushnil(co);
  } else if (req->result < 0) {
    lua_pushnil(co);
    lua_pushstring(co, uv_strerror((int)req->result));
  } else {
    lua_pushnil(co);
    lua_pushstring(co, "SHORT_READ");
  }

  int st = lua_resume(co, 2);
  if (st != LUA_OK && st != LUA_YIELD) {
    const char *e = lua_tostring(co, -1);
    if (e) fprintf(stderr, "[lunet.su] resume error (read): %s\n", e);
  }

  uv_fs_req_cleanup(req);
  free(ctx->buf);
  free(ctx);
}

static int su_read(lua_State *L) {
  if (lunet_ensure_coroutine(L, "su.read") != 0) {
    return lua_error(L);
  }

  su_ud_t *ud = su_check(L, 1);
  su_t *su = ud->su;
  if (!su) {
    lua_pushnil(L);
    lua_pushstring(L, "storage unit closed");
    return 2;
  }

  uint64_t address = (uint64_t)luaL_checknumber(L, 2);
  if (address >= su->max_addresses) {
    lua_pushnil(L);
    lua_pushstring(L, "address out of range");
    return 2;
  }

  size_t byte_idx = (size_t)(address >> 3);
  uint8_t bit_mask = (uint8_t)(1u << (address & 7u));
  if (!su_get_bit(su->bm_bytes, byte_idx, bit_mask)) {
    lua_pushnil(L);
    lua_pushstring(L, "NOT_WRITTEN");
    return 2;
  }

  su_read_ctx_t *ctx = (su_read_ctx_t *)calloc(1, sizeof(su_read_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  ctx->L = L;
  ctx->co_ref = LUA_NOREF;
  ctx->su = su;
  ctx->address = address;
  ctx->buf = (char *)malloc(SU_BLOCK_SIZE);
  if (!ctx->buf) {
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }
  ctx->req.data = ctx;

  lua_pushthread(L);
  ctx->co_ref = luaL_ref(L, LUA_REGISTRYINDEX);

  uv_buf_t buf = uv_buf_init(ctx->buf, SU_BLOCK_SIZE);
  int rc = uv_fs_read(uv_default_loop(), &ctx->req, su->data_fd, &buf, 1,
                      (int64_t)(address * (uint64_t)SU_BLOCK_SIZE), su_read_cb);
  if (rc < 0) {
    luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
    free(ctx->buf);
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(rc));
    return 2;
  }

  return lua_yield(L, 0);
}

static int su_gc(lua_State *L) { return su_close(L); }

static int su_make_metatable(lua_State *L) {
  if (luaL_newmetatable(L, "lunet.su") == 0) {
    lua_pop(L, 1);
    return 0;
  }

  lua_pushcfunction(L, su_gc);
  lua_setfield(L, -2, "__gc");

  lua_newtable(L);
  lua_pushcfunction(L, su_close);
  lua_setfield(L, -2, "close");
  lua_pushcfunction(L, su_write_once);
  lua_setfield(L, -2, "write_once");
  lua_pushcfunction(L, su_read);
  lua_setfield(L, -2, "read");
  lua_pushcfunction(L, su_is_written);
  lua_setfield(L, -2, "is_written");
  lua_setfield(L, -2, "__index");

  lua_pop(L, 1);
  return 0;
}

static int su_open_impl(lua_State *L, const char *dir, uint64_t max_addresses) {
  if (max_addresses == 0) {
    lua_pushnil(L);
    lua_pushstring(L, "max_addresses must be > 0");
    return 2;
  }

  // Ensure directory exists (best effort).
  (void)mkdir_p(dir);

  char data_path[1024];
  char bm_path[1024];
  snprintf(data_path, sizeof(data_path), "%s/%s", dir, "data.bin");
  snprintf(bm_path, sizeof(bm_path), "%s/%s", dir, "bitmap.bin");

  int data_fd = open(data_path, O_RDWR | O_CREAT, 0644);
  if (data_fd < 0) {
    lua_pushnil(L);
    lua_pushfstring(L, "failed to open data file: %s", strerror(errno));
    return 2;
  }

  int bm_fd = open(bm_path, O_RDWR | O_CREAT, 0644);
  if (bm_fd < 0) {
    close(data_fd);
    lua_pushnil(L);
    lua_pushfstring(L, "failed to open bitmap file: %s", strerror(errno));
    return 2;
  }

  size_t bm_len = (size_t)((max_addresses + 7) / 8);
  uint8_t *bm_bytes = (uint8_t *)calloc(1, bm_len);
  uint8_t *pending_bytes = (uint8_t *)calloc(1, bm_len);
  if (!bm_bytes || !pending_bytes) {
    close(data_fd);
    close(bm_fd);
    if (bm_bytes) free(bm_bytes);
    if (pending_bytes) free(pending_bytes);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  // Initialize or load bitmap file.
  struct stat st;
  if (fstat(bm_fd, &st) != 0) {
    close(data_fd);
    close(bm_fd);
    free(bm_bytes);
    free(pending_bytes);
    lua_pushnil(L);
    lua_pushfstring(L, "failed to stat bitmap file: %s", strerror(errno));
    return 2;
  }

  if (st.st_size == 0) {
    // create header + zero bitset
    uint8_t hdr[SU_BITMAP_HEADER_SIZE];
    memcpy(hdr, SU_BITMAP_MAGIC, 4);
    write_u32_le(hdr + 4, SU_BITMAP_VERSION);
    write_u64_le(hdr + 8, max_addresses);
    if (pwrite(bm_fd, hdr, SU_BITMAP_HEADER_SIZE, 0) != SU_BITMAP_HEADER_SIZE) {
      close(data_fd);
      close(bm_fd);
      free(bm_bytes);
      free(pending_bytes);
      lua_pushnil(L);
      lua_pushfstring(L, "failed to write bitmap header: %s", strerror(errno));
      return 2;
    }
    // extend file to required size (sparse ok)
    off_t want = (off_t)(SU_BITMAP_HEADER_SIZE + bm_len);
    if (ftruncate(bm_fd, want) != 0) {
      close(data_fd);
      close(bm_fd);
      free(bm_bytes);
      free(pending_bytes);
      lua_pushnil(L);
      lua_pushfstring(L, "failed to size bitmap file: %s", strerror(errno));
      return 2;
    }
    (void)fsync(bm_fd);
  } else {
    uint8_t hdr[SU_BITMAP_HEADER_SIZE];
    ssize_t n = pread(bm_fd, hdr, SU_BITMAP_HEADER_SIZE, 0);
    if (n != SU_BITMAP_HEADER_SIZE) {
      close(data_fd);
      close(bm_fd);
      free(bm_bytes);
      free(pending_bytes);
      lua_pushnil(L);
      lua_pushstring(L, "failed to read bitmap header");
      return 2;
    }
    if (memcmp(hdr, SU_BITMAP_MAGIC, 4) != 0) {
      close(data_fd);
      close(bm_fd);
      free(bm_bytes);
      free(pending_bytes);
      lua_pushnil(L);
      lua_pushstring(L, "invalid bitmap magic");
      return 2;
    }
    uint32_t ver = read_u32_le(hdr + 4);
    uint64_t max_on_disk = read_u64_le(hdr + 8);
    if (ver != SU_BITMAP_VERSION) {
      close(data_fd);
      close(bm_fd);
      free(bm_bytes);
      free(pending_bytes);
      lua_pushnil(L);
      lua_pushstring(L, "unsupported bitmap version");
      return 2;
    }
    if (max_on_disk != max_addresses) {
      close(data_fd);
      close(bm_fd);
      free(bm_bytes);
      free(pending_bytes);
      lua_pushnil(L);
      lua_pushstring(L, "max_addresses mismatch with existing bitmap");
      return 2;
    }
    // read bitset
    ssize_t r = pread(bm_fd, bm_bytes, (size_t)bm_len, (off_t)SU_BITMAP_HEADER_SIZE);
    if (r != (ssize_t)bm_len) {
      close(data_fd);
      close(bm_fd);
      free(bm_bytes);
      free(pending_bytes);
      lua_pushnil(L);
      lua_pushstring(L, "failed to read bitmap body");
      return 2;
    }
  }

  su_t *su = (su_t *)calloc(1, sizeof(su_t));
  if (!su) {
    close(data_fd);
    close(bm_fd);
    free(bm_bytes);
    free(pending_bytes);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  su->data_fd = data_fd;
  su->bm_fd = bm_fd;
  su->max_addresses = max_addresses;
  su->bm_len = bm_len;
  su->bm_bytes = bm_bytes;
  su->pending_bytes = pending_bytes;

  // Hash table sized as power-of-two, at least 1024 buckets.
  size_t buckets = 1024;
  while (buckets < (bm_len / 4)) buckets <<= 1;
  if (buckets > (1u << 20)) buckets = (1u << 20);  // cap to keep overhead bounded
  su->bm_bucket_count = buckets;
  su->bm_buckets = (bm_entry_t **)calloc(su->bm_bucket_count, sizeof(bm_entry_t *));
  if (!su->bm_buckets) {
    close(data_fd);
    close(bm_fd);
    free(bm_bytes);
    free(pending_bytes);
    free(su);
    lua_pushnil(L);
    lua_pushstring(L, "out of memory");
    return 2;
  }

  su_make_metatable(L);
  su_ud_t *ud = (su_ud_t *)lua_newuserdata(L, sizeof(su_ud_t));
  ud->su = su;
  luaL_getmetatable(L, "lunet.su");
  lua_setmetatable(L, -2);

  lua_pushnil(L);
  return 2;
}

int lunet_su_open(lua_State *L) {
  const char *dir = luaL_checkstring(L, 1);
  uint64_t max_addresses = (uint64_t)luaL_checknumber(L, 2);
  return su_open_impl(L, dir, max_addresses);
}


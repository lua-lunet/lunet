#include "fs.h"

#include <lauxlib.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <uv.h>

#include "co.h"
#include "trace.h"

typedef struct {
  uv_fs_t req;
  lua_State *L;
  int co_ref;
} fs_ctx_t;

static void lunet_fs_open_cb(uv_fs_t *req) {
  fs_ctx_t *ctx = (fs_ctx_t *)req->data;
  lua_State *L = ctx->L;

  // resume coroutine
  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);

  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in fs.open\n");
    goto cleanup;
  }

  lua_State *co = lua_tothread(L, -1);
  lua_pop(L, 1);  // pop coroutine

  if (req->result >= 0) {
    lua_pushinteger(co, req->result);
    lua_pushnil(co);
  } else {
    lua_pushnil(co);
    lua_pushstring(co, uv_strerror((int)req->result));
  }

  lua_resume(co, 2);

cleanup:
  uv_fs_req_cleanup(req);
  free(ctx);
}

// mode to uv_fs_open flags
static int fs_mode_to_flags(const char *mode, size_t mode_len) {
  if (mode_len == 0) return -1;

  int flags = 0;
  bool has_plus = false;
  bool has_x = false;

  // Check for '+' and 'x' modifiers first
  for (size_t i = 0; i < mode_len; i++) {
    if (mode[i] == '+') has_plus = true;
    if (mode[i] == 'x') has_x = true;
  }

  // Handle primary mode
  switch (mode[0]) {
    case 'r':
      if (has_plus) {
        flags = O_RDWR;  // r+ - read/write, file must exist
      } else {
        flags = O_RDONLY;  // r - read only
      }
      break;

    case 'w':
      if (has_plus) {
        flags = O_RDWR | O_CREAT | O_TRUNC;  // w+ - read/write, create/truncate
      } else {
        flags = O_WRONLY | O_CREAT | O_TRUNC;  // w - write only, create/truncate
      }
      break;

    case 'a':
      if (has_plus) {
        flags = O_RDWR | O_CREAT | O_APPEND;  // a+ - read/write, create/append
      } else {
        flags = O_WRONLY | O_CREAT | O_APPEND;  // a - write only, create/append
      }
      break;

    case 'x':
      if (has_plus) {
        flags = O_RDWR | O_CREAT | O_EXCL;  // x+ - read/write, create new, fail if exists
      } else {
        flags = O_WRONLY | O_CREAT | O_EXCL;  // x - write only, create new, fail if exists
      }
      break;

    default:
      return -1;  // Invalid mode
  }

  return flags;
}

int lunet_fs_open(lua_State *L) {
  if (lunet_ensure_coroutine(L, "fs.open") != 0) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 2) {
    lua_pushnil(L);
    lua_pushstring(L, "fs.open requires path and mode");
    return 2;
  }

  const char *path = luaL_checkstring(L, 1);
  const char *mode = luaL_checkstring(L, 2);

  int flags = fs_mode_to_flags(mode, strlen(mode));
  if (flags == -1) {
    lua_pushnil(L);
    lua_pushstring(L, "fs.open invalid mode");
    return 2;
  }

  fs_ctx_t *ctx = malloc(sizeof(fs_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "fs.open: out of memory");
    return 2;
  }

  ctx->L = L;
  lunet_coref_create(L, ctx->co_ref);
  ctx->req.data = ctx;

  int rc = uv_fs_open(uv_default_loop(), &ctx->req, path, flags, 0644, lunet_fs_open_cb);
  if (rc < 0) {
    lunet_coref_release(L, ctx->co_ref);
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(rc));
    return 2;
  }

  return lua_yield(L, 0);
}

typedef struct {
  uv_fs_t req;
  lua_State *L;
  int co_ref;
} fs_close_ctx_t;

static void lunet_fs_close_cb(uv_fs_t *req) {
  fs_close_ctx_t *ctx = (fs_close_ctx_t *)req->data;
  lua_State *L = ctx->L;

  // resume coroutine
  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);

  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in fs.close\n");
    goto cleanup;
  }

  lua_State *co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (req->result == 0) {
    lua_pushnil(co);
  } else {
    lua_pushstring(co, uv_strerror((int)req->result));
  }

  lua_resume(co, 1);

cleanup:
  uv_fs_req_cleanup(req);
  free(ctx);
}

int lunet_fs_close(lua_State *L) {
  if (lunet_ensure_coroutine(L, "fs.close") != 0) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 1 || !lua_isnumber(L, 1)) {
    lua_pushstring(L, "fs.close requires 1 integer fd");
    return 1;
  }

  uv_file fd = (uv_file)lua_tointeger(L, 1);

  fs_close_ctx_t *ctx = malloc(sizeof(fs_close_ctx_t));
  if (!ctx) {
    lua_pushstring(L, "fs.close: out of memory");
    return 1;
  }

  ctx->L = L;
  lunet_coref_create(L, ctx->co_ref);
  ctx->req.data = ctx;

  int rc = uv_fs_close(uv_default_loop(), &ctx->req, fd, lunet_fs_close_cb);
  if (rc < 0) {
    lunet_coref_release(L, ctx->co_ref);
    free(ctx);
    lua_pushstring(L, uv_strerror(rc));
    return 1;
  }

  return lua_yield(L, 0);
}

typedef struct {
  uv_fs_t req;
  lua_State *L;
  int co_ref;
} fs_stat_ctx_t;

static void lunet_fs_stat_cb(uv_fs_t *req) {
  fs_stat_ctx_t *ctx = (fs_stat_ctx_t *)req->data;
  lua_State *L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);

  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in fs.fstat\n");
    goto cleanup;
  }

  lua_State *co = lua_tothread(L, -1);
  lua_pop(L, 1);  // pop thread

  if (req->result == 0) {
    uv_stat_t *s = &req->statbuf;
    // lua_pushinteger(co, (lua_Integer)s->st_size);
    // uint64_t st_dev;
    // uint64_t st_mode;
    // uint64_t st_nlink;
    // uint64_t st_uid;
    // uint64_t st_gid;
    // uint64_t st_rdev;
    // uint64_t st_ino;
    // uint64_t st_size;
    // uint64_t st_blksize;
    // uint64_t st_blocks;
    // uint64_t st_flags;
    // uint64_t st_gen;
    // uv_timespec_t st_atim;
    // uv_timespec_t st_mtim;
    // uv_timespec_t st_ctim;
    // uv_timespec_t st_birthtim;、
    lua_newtable(co);
    lua_pushinteger(co, (lua_Integer)s->st_dev);
    lua_setfield(co, -2, "dev");
    lua_pushinteger(co, (lua_Integer)s->st_mode);
    lua_setfield(co, -2, "mode");
    lua_pushinteger(co, (lua_Integer)s->st_nlink);
    lua_setfield(co, -2, "nlink");
    lua_pushinteger(co, (lua_Integer)s->st_uid);
    lua_setfield(co, -2, "uid");
    lua_pushinteger(co, (lua_Integer)s->st_gid);
    lua_setfield(co, -2, "gid");
    lua_pushinteger(co, (lua_Integer)s->st_rdev);
    lua_setfield(co, -2, "rdev");
    lua_pushinteger(co, (lua_Integer)s->st_ino);
    lua_setfield(co, -2, "ino");
    lua_pushinteger(co, (lua_Integer)s->st_size);
    lua_setfield(co, -2, "size");
    lua_pushinteger(co, (lua_Integer)s->st_blksize);
    lua_setfield(co, -2, "blksize");
    lua_pushinteger(co, (lua_Integer)s->st_blocks);
    lua_setfield(co, -2, "blocks");
    lua_pushinteger(co, (lua_Integer)s->st_flags);
    lua_setfield(co, -2, "flags");
    lua_pushinteger(co, (lua_Integer)s->st_gen);
    lua_setfield(co, -2, "gen");
    lua_pushnumber(co, (lua_Number)s->st_atim.tv_sec);
    lua_setfield(co, -2, "atim");
    lua_pushnumber(co, (lua_Number)s->st_mtim.tv_sec);
    lua_setfield(co, -2, "mtim");
    lua_pushnumber(co, (lua_Number)s->st_ctim.tv_sec);
    lua_setfield(co, -2, "ctim");
    lua_pushnumber(co, (lua_Number)s->st_birthtim.tv_sec);
    lua_setfield(co, -2, "birthtim");
    lua_pushnil(co);
  } else {
    lua_pushnil(co);
    lua_pushstring(co, uv_strerror((int)req->result));
  }

  lua_resume(co, 2);

cleanup:
  uv_fs_req_cleanup(req);
  free(ctx);
}

int lunet_fs_stat(lua_State *L) {
  if (lunet_ensure_coroutine(L, "fs.fstat") != 0) {
    return lua_error(L);
  }

  if (!lua_isstring(L, 1)) {
    lua_pushnil(L);
    lua_pushstring(L, "fs.fstat requires path");
    return 2;
  }

  const char *path = luaL_checkstring(L, 1);

  fs_stat_ctx_t *ctx = malloc(sizeof(fs_stat_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "fs.fstat out of memory");
    return 2;
  }

  ctx->L = L;
  lunet_coref_create(L, ctx->co_ref);
  ctx->req.data = ctx;

  int rc = uv_fs_stat(uv_default_loop(), &ctx->req, path, lunet_fs_stat_cb);
  if (rc < 0) {
    lunet_coref_release(L, ctx->co_ref);
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(rc));
    return 2;
  }

  return lua_yield(L, 0);
}

typedef struct {
  uv_fs_t req;
  lua_State *L;
  int co_ref;
  size_t len;
  char *buf;
} fs_read_ctx_t;

static void lunet_fs_read_cb(uv_fs_t *req) {
  fs_read_ctx_t *ctx = (fs_read_ctx_t *)req->data;
  lua_State *L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);

  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in fs.read\n");
    goto cleanup;
  }

  lua_State *co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (req->result >= 0) {
    lua_pushlstring(co, ctx->buf, req->result);
    lua_pushnil(co);
  } else {
    lua_pushnil(co);
    lua_pushstring(co, uv_strerror((int)req->result));
  }

  lua_resume(co, 2);

cleanup:
  uv_fs_req_cleanup(req);
  free(ctx->buf);
  free(ctx);
}
int lunet_fs_read(lua_State *L) {
  if (lunet_ensure_coroutine(L, "fs.read") != 0) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 2 || !lua_isnumber(L, 1) || !lua_isnumber(L, 2)) {
    lua_pushnil(L);
    lua_pushstring(L, "fs.read requires fd and length");
    return 2;
  }

  uv_file fd = (uv_file)lua_tointeger(L, 1);
  size_t len = (size_t)lua_tointeger(L, 2);

  fs_read_ctx_t *ctx = malloc(sizeof(fs_read_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "fs.read out of memory");
    return 2;
  }

  ctx->L = L;
  lunet_coref_create(L, ctx->co_ref);
  ctx->len = len;
  ctx->buf = malloc(len);
  if (!ctx->buf) {
    lunet_coref_release(L, ctx->co_ref);
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "fs.read out of memory");
    return 2;
  }
  ctx->req.data = ctx;

  uv_buf_t buf = uv_buf_init(ctx->buf, len);
  int rc = uv_fs_read(uv_default_loop(), &ctx->req, fd, &buf, 1, 0, lunet_fs_read_cb);
  if (rc < 0) {
    lunet_coref_release(L, ctx->co_ref);
    free(ctx->buf);
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(rc));
    return 2;
  }

  return lua_yield(L, 0);
}

typedef struct {
  uv_fs_t req;
  lua_State *L;
  int co_ref;

  size_t len;
  char *buf;
} fs_write_ctx_t;

static void lunet_fs_write_cb(uv_fs_t *req) {
  fs_write_ctx_t *ctx = (fs_write_ctx_t *)req->data;
  lua_State *L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);

  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in fs.write\n");
    goto cleanup;
  }

  lua_State *co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (req->result >= 0) {
    lua_pushinteger(co, req->result);
    lua_pushnil(co);
  } else {
    lua_pushnil(co);
    lua_pushstring(co, uv_strerror((int)req->result));
  }

  lua_resume(co, 2);

cleanup:
  uv_fs_req_cleanup(req);
  free(ctx->buf);
  free(ctx);
}

int lunet_fs_write(lua_State *L) {
  if (lunet_ensure_coroutine(L, "fs.write") != 0) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 2 || !lua_isnumber(L, 1) || !lua_isstring(L, 2)) {
    lua_pushnil(L);
    lua_pushstring(L, "fs.write requires fd and data");
    return 2;
  }
  uv_file fd = (uv_file)lua_tointeger(L, 1);
  const char *data = luaL_checkstring(L, 2);
  size_t len = strlen(data);

  fs_write_ctx_t *ctx = malloc(sizeof(fs_write_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "fs.write out of memory");
    return 2;
  }

  ctx->L = L;
  lunet_coref_create(L, ctx->co_ref);
  ctx->len = len;
  ctx->buf = malloc(len);
  if (!ctx->buf) {
    lunet_coref_release(L, ctx->co_ref);
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, "fs.write out of memory");
    return 2;
  }

  memcpy(ctx->buf, data, len);
  ctx->req.data = ctx;

  uv_buf_t buf = uv_buf_init(ctx->buf, len);
  int rc = uv_fs_write(uv_default_loop(), &ctx->req, fd, &buf, 1, 0, lunet_fs_write_cb);
  if (rc < 0) {
    lunet_coref_release(L, ctx->co_ref);
    free(ctx->buf);
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(rc));
    return 2;
  }

  return lua_yield(L, 0);
}

typedef struct {
  uv_fs_t req;
  lua_State *L;
  int co_ref;
} fs_scandir_ctx_t;

const char *dirent_type_to_string(uv_dirent_type_t type) {
  switch (type) {
    case UV_DIRENT_FILE:
      return "file";
    case UV_DIRENT_DIR:
      return "dir";
    case UV_DIRENT_LINK:
      return "link";
    case UV_DIRENT_FIFO:
      return "fifo";
    case UV_DIRENT_SOCKET:
      return "socket";
    case UV_DIRENT_CHAR:
      return "char";
    case UV_DIRENT_BLOCK:
      return "block";
    default:
      return "unknown";
  }
}

static void lunet_fs_scandir_cb(uv_fs_t *req) {
  fs_scandir_ctx_t *ctx = (fs_scandir_ctx_t *)req->data;
  lua_State *L = ctx->L;

  lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
  lunet_coref_release(L, ctx->co_ref);

  if (!lua_isthread(L, -1)) {
    lua_pop(L, 1);
    fprintf(stderr, "invalid coroutine in fs.scandir\n");
    goto cleanup;
  }

  lua_State *co = lua_tothread(L, -1);
  lua_pop(L, 1);

  if (req->result < 0) {
    lua_pushnil(co);
    lua_pushstring(co, uv_strerror((int)req->result));
  } else {
    lua_newtable(co);
    int i = 1;
    uv_dirent_t ent;

    while (uv_fs_scandir_next(req, &ent) != UV_EOF) {
      lua_newtable(co);
      lua_pushstring(co, ent.name);
      lua_setfield(co, -2, "name");
      lua_pushstring(co, dirent_type_to_string(ent.type));
      lua_setfield(co, -2, "type");
      lua_rawseti(co, -2, i++);
    }

    lua_pushnil(co);
  }

  lua_resume(co, 2);

cleanup:
  uv_fs_req_cleanup(req);
  free(ctx);
}

int lunet_fs_scandir(lua_State *L) {
  if (lunet_ensure_coroutine(L, "fs.scandir") != 0) {
    return lua_error(L);
  }
  if (lua_gettop(L) < 1 || !lua_isstring(L, 1)) {
    lua_pushnil(L);
    lua_pushstring(L, "fs.scandir requires path");
    return 2;
  }

  const char *path = luaL_checkstring(L, 1);

  fs_scandir_ctx_t *ctx = malloc(sizeof(fs_scandir_ctx_t));
  if (!ctx) {
    lua_pushnil(L);
    lua_pushstring(L, "fs.scandir out of memory");
    return 2;
  }

  ctx->L = L;
  lunet_coref_create(L, ctx->co_ref);
  ctx->req.data = ctx;

  int rc = uv_fs_scandir(uv_default_loop(), &ctx->req, path, 0, lunet_fs_scandir_cb);
  if (rc < 0) {
    lunet_coref_release(L, ctx->co_ref);
    free(ctx);
    lua_pushnil(L);
    lua_pushstring(L, uv_strerror(rc));
    return 2;
  }

  return lua_yield(L, 0);
}
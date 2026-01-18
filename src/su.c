#include "su.h"
#include "co.h"

#include <lauxlib.h>
#include <uv.h>
#include <stdlib.h>
#include <string.h>
#include <stdbool.h>
#include <fcntl.h>
#include <errno.h>

#define DEFAULT_MAX_BLOCKS (1024 * 1024)
#define BLOCK_SIZE 4096

typedef struct su_write_ctx_s su_write_ctx_t;

struct su_write_ctx_s {
    uv_fs_t req;
    lua_State *L;
    int co_ref;
    uint64_t addr;
    char *buf;      // 4096 bytes data
    char bitmap_byte; // Buffer for bitmap write
    su_write_ctx_t *next;
};

typedef struct {
    uv_file data_fd;
    uv_file bitmap_fd;
    uint8_t *bitmap;
    uint8_t *inflight; // Bitset for inflight writes? Or just bytes for simplicity? 
                       // 1M blocks -> 125KB bitset. Bytes is 1MB. Bytes is easier/faster.
    uint8_t *byte_locks; // Lock for each bitmap byte (to serialize updates)
    su_write_ctx_t **wait_queues; // Array of pointers to head of wait queues
    
    size_t max_blocks;
    bool initialized;
} su_state_t;

static su_state_t su_ctx = {0};

// Helper: Check if address is valid
static int check_addr(lua_State *L, uint64_t addr) {
    if (!su_ctx.initialized) {
        lua_pushnil(L);
        lua_pushstring(L, "su not initialized");
        return 0;
    }
    if (addr >= su_ctx.max_blocks) {
        lua_pushnil(L);
        lua_pushstring(L, "address out of bounds");
        return 0;
    }
    return 1;
}

// Helper: Sync read all
static int sync_read_all(uv_file fd, void *buf, size_t len, int64_t offset) {
    uv_fs_t req;
    uv_buf_t iov = uv_buf_init((char *)buf, len);
    int rc = uv_fs_read(uv_default_loop(), &req, fd, &iov, 1, offset, NULL);
    uv_fs_req_cleanup(&req);
    return rc;
}

// Helper: Sync write all
static int sync_write_all(uv_file fd, void *buf, size_t len, int64_t offset) {
    uv_fs_t req;
    uv_buf_t iov = uv_buf_init((char *)buf, len);
    int rc = uv_fs_write(uv_default_loop(), &req, fd, &iov, 1, offset, NULL);
    uv_fs_req_cleanup(&req);
    return rc;
}

int lunet_su_init(lua_State *L) {
    const char *data_path = luaL_checkstring(L, 1);
    const char *bitmap_path = luaL_checkstring(L, 2);
    size_t max_blocks = luaL_optinteger(L, 3, DEFAULT_MAX_BLOCKS);

    if (su_ctx.initialized) {
        lua_pushnil(L);
        lua_pushstring(L, "already initialized");
        return 2;
    }

    su_ctx.max_blocks = max_blocks;
    size_t bitmap_size = (max_blocks + 7) / 8;

    // Open Data File
    uv_fs_t req;
    int flags = O_RDWR | O_CREAT;
    int mode = 0644;
    int rc = uv_fs_open(uv_default_loop(), &req, data_path, flags, mode, NULL);
    if (rc < 0) {
        lua_pushnil(L);
        lua_pushstring(L, uv_strerror(rc));
        uv_fs_req_cleanup(&req);
        return 2;
    }
    su_ctx.data_fd = rc;
    uv_fs_req_cleanup(&req);

    // Open Bitmap File
    rc = uv_fs_open(uv_default_loop(), &req, bitmap_path, flags, mode, NULL);
    if (rc < 0) {
        lua_pushnil(L);
        lua_pushstring(L, uv_strerror(rc));
        uv_fs_req_cleanup(&req);
        // Close data_fd
        uv_fs_close(uv_default_loop(), &req, su_ctx.data_fd, NULL);
        uv_fs_req_cleanup(&req);
        return 2;
    }
    su_ctx.bitmap_fd = rc;
    uv_fs_req_cleanup(&req);

    // Resize bitmap file if needed (to ensure it can hold all bits)
    // Actually, we can just let it grow, but reading it all requires knowing size.
    // For simplicity, let's assume we pre-allocate or just read what's there.
    // Let's alloc memory first.
    su_ctx.bitmap = calloc(1, bitmap_size);
    su_ctx.inflight = calloc(1, max_blocks); // 1 byte per block for simplicity
    su_ctx.byte_locks = calloc(1, bitmap_size); // 1 byte per bitmap byte
    su_ctx.wait_queues = calloc(bitmap_size, sizeof(su_write_ctx_t*));

    if (!su_ctx.bitmap || !su_ctx.inflight || !su_ctx.byte_locks || !su_ctx.wait_queues) {
        lua_pushnil(L);
        lua_pushstring(L, "out of memory");
        return 2;
    }

    // Read existing bitmap
    // We try to read bitmap_size bytes. If file is smaller, we get partial read.
    // That's fine, the rest is 0 (unwritten).
    rc = sync_read_all(su_ctx.bitmap_fd, su_ctx.bitmap, bitmap_size, 0);
    if (rc < 0) {
        lua_pushnil(L);
        lua_pushstring(L, uv_strerror(rc));
        return 2;
    }

    su_ctx.initialized = true;
    lua_pushboolean(L, 1);
    return 1;
}

// --- Write Logic ---

static void continue_bitmap_write(su_write_ctx_t *ctx);

static void on_bitmap_write_done(uv_fs_t *req) {
    su_write_ctx_t *ctx = (su_write_ctx_t *)req->data;
    lua_State *L = ctx->L;
    
    // Update memory bitmap if success
    if (req->result >= 0) {
        size_t byte_idx = ctx->addr / 8;
        int bit_idx = ctx->addr % 8;
        su_ctx.bitmap[byte_idx] |= (1 << bit_idx);
    }
    
    // Resume Lua
    lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
    luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
    lua_State *co = lua_tothread(L, -1);
    lua_pop(L, 1);

    if (req->result >= 0) {
        lua_pushboolean(co, 1); // Success
        lua_pushnil(co);
    } else {
        lua_pushnil(co);
        lua_pushstring(co, uv_strerror((int)req->result));
    }
    
    // Clear inflight
    su_ctx.inflight[ctx->addr] = 0;
    
    // Handle queue
    size_t byte_idx = ctx->addr / 8;
    su_write_ctx_t *next = su_ctx.wait_queues[byte_idx];
    if (next) {
        su_ctx.wait_queues[byte_idx] = next->next;
        next->next = NULL;
        continue_bitmap_write(next);
    } else {
        su_ctx.byte_locks[byte_idx] = 0;
    }

    uv_fs_req_cleanup(req);
    free(ctx->buf);
    free(ctx);
    
    lua_resume(co, 2);
}

static void continue_bitmap_write(su_write_ctx_t *ctx) {
    size_t byte_idx = ctx->addr / 8;
    int bit_idx = ctx->addr % 8;
    
    // Prepare the byte value
    // Note: We use the CURRENT memory bitmap state, which should be up to date
    // because previous writes in queue have updated it in their callback.
    uint8_t current_byte = su_ctx.bitmap[byte_idx];
    ctx->bitmap_byte = current_byte | (1 << bit_idx);
    
    // Lock is already held by us or the previous writer who woke us up
    su_ctx.byte_locks[byte_idx] = 1;
    
    uv_buf_t iov = uv_buf_init(&ctx->bitmap_byte, 1);
    // Reuse req
    uv_fs_req_cleanup(&ctx->req);
    int rc = uv_fs_write(uv_default_loop(), &ctx->req, su_ctx.bitmap_fd, &iov, 1, byte_idx, on_bitmap_write_done);
    
    if (rc < 0) {
        // Failed to start write? Extremely rare.
        // We should probably fail the request and process next in queue.
        // For simplicity, assume uv_fs_write doesn't fail synchronously often.
        // If it does, we are in trouble regarding the queue.
        // Let's handle it by calling the callback manually with error.
        ctx->req.result = rc;
        on_bitmap_write_done(&ctx->req);
    }
}

static void on_data_write_done(uv_fs_t *req) {
    su_write_ctx_t *ctx = (su_write_ctx_t *)req->data;
    
    if (req->result < 0) {
        // Data write failed
        lua_State *L = ctx->L;
        lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
        luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
        lua_State *co = lua_tothread(L, -1);
        lua_pop(L, 1);
        
        lua_pushnil(co);
        lua_pushstring(co, uv_strerror((int)req->result));
        
        su_ctx.inflight[ctx->addr] = 0;
        
        uv_fs_req_cleanup(req);
        free(ctx->buf);
        free(ctx);
        
        lua_resume(co, 2);
        return;
    }
    
    // Data written. Now update bitmap.
    size_t byte_idx = ctx->addr / 8;
    
    if (su_ctx.byte_locks[byte_idx]) {
        // Queued
        ctx->next = su_ctx.wait_queues[byte_idx];
        su_ctx.wait_queues[byte_idx] = ctx;
    } else {
        // Start write
        continue_bitmap_write(ctx);
    }
}

int lunet_su_write(lua_State *L) {
    if (lunet_ensure_coroutine(L, "su.write") != 0) return lua_error(L);
    
    uint64_t addr = (uint64_t)luaL_checkinteger(L, 1);
    size_t len;
    const char *data = luaL_checklstring(L, 2, &len);
    
    if (!check_addr(L, addr)) return 2;
    
    if (len != BLOCK_SIZE) {
        lua_pushnil(L);
        lua_pushstring(L, "data must be 4096 bytes");
        return 2;
    }
    
    // Check write-once
    size_t byte_idx = addr / 8;
    int bit_idx = addr % 8;
    if (su_ctx.bitmap[byte_idx] & (1 << bit_idx)) {
        lua_pushnil(L);
        lua_pushstring(L, "already written");
        return 2;
    }
    
    // Check inflight
    if (su_ctx.inflight[addr]) {
        lua_pushnil(L);
        lua_pushstring(L, "concurrent write detected");
        return 2;
    }
    
    su_ctx.inflight[addr] = 1;
    
    su_write_ctx_t *ctx = malloc(sizeof(su_write_ctx_t));
    ctx->L = L;
    ctx->addr = addr;
    ctx->next = NULL;
    ctx->buf = malloc(BLOCK_SIZE);
    memcpy(ctx->buf, data, BLOCK_SIZE);
    
    lua_pushthread(L);
    ctx->co_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    ctx->req.data = ctx;
    
    uv_buf_t iov = uv_buf_init(ctx->buf, BLOCK_SIZE);
    int rc = uv_fs_write(uv_default_loop(), &ctx->req, su_ctx.data_fd, &iov, 1, addr * BLOCK_SIZE, on_data_write_done);
    
    if (rc < 0) {
        su_ctx.inflight[addr] = 0;
        luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
        free(ctx->buf);
        free(ctx);
        lua_pushnil(L);
        lua_pushstring(L, uv_strerror(rc));
        return 2;
    }
    
    return lua_yield(L, 0);
}

// --- Read Logic ---

typedef struct {
    uv_fs_t req;
    lua_State *L;
    int co_ref;
    char *buf;
} su_read_ctx_t;

static void on_read_done(uv_fs_t *req) {
    su_read_ctx_t *ctx = (su_read_ctx_t *)req->data;
    lua_State *L = ctx->L;
    
    lua_rawgeti(L, LUA_REGISTRYINDEX, ctx->co_ref);
    luaL_unref(L, LUA_REGISTRYINDEX, ctx->co_ref);
    lua_State *co = lua_tothread(L, -1);
    lua_pop(L, 1);
    
    if (req->result >= 0) {
        lua_pushlstring(co, ctx->buf, req->result);
        lua_pushnil(co);
    } else {
        lua_pushnil(co);
        lua_pushstring(co, uv_strerror((int)req->result));
    }
    
    uv_fs_req_cleanup(req);
    free(ctx->buf);
    free(ctx);
    
    lua_resume(co, 2);
}

int lunet_su_read(lua_State *L) {
    if (lunet_ensure_coroutine(L, "su.read") != 0) return lua_error(L);
    
    uint64_t addr = (uint64_t)luaL_checkinteger(L, 1);
    
    if (!check_addr(L, addr)) return 2;
    
    // Check bitmap
    size_t byte_idx = addr / 8;
    int bit_idx = addr % 8;
    if (!(su_ctx.bitmap[byte_idx] & (1 << bit_idx))) {
        lua_pushnil(L); // Not written
        return 1;
    }
    
    su_read_ctx_t *ctx = malloc(sizeof(su_read_ctx_t));
    ctx->L = L;
    ctx->buf = malloc(BLOCK_SIZE);
    
    lua_pushthread(L);
    ctx->co_ref = luaL_ref(L, LUA_REGISTRYINDEX);
    ctx->req.data = ctx;
    
    uv_buf_t iov = uv_buf_init(ctx->buf, BLOCK_SIZE);
    int rc = uv_fs_read(uv_default_loop(), &ctx->req, su_ctx.data_fd, &iov, 1, addr * BLOCK_SIZE, on_read_done);
    
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

#ifndef LUNET_EASY_MEMORY_H
#define LUNET_EASY_MEMORY_H

/*
 * EasyMem/easy_memory Integration for Lunet
 * ==========================================
 *
 * When LUNET_EASY_MEMORY is defined at build time (via xmake --easy_memory=y),
 * this header provides:
 *
 *   1. A global EM arena that replaces the system heap for lunet internal
 *      allocations (via lunet_alloc/lunet_free in lunet_mem.h).
 *
 *   2. Per-worker arena helpers for DB driver thread-pool callbacks.
 *      Each uv_work_t callback can create a scoped nested arena that is
 *      destroyed (O(1)) when the work function returns.
 *
 *   3. Diagnostic hooks that produce profiling data when built with
 *      LUNET_TRACE (counters, peak usage, fragmentation).
 *
 * In release builds without LUNET_EASY_MEMORY this header compiles to nothing.
 *
 * See: https://github.com/EasyMem/easy_memory
 */

#ifdef LUNET_EASY_MEMORY

#include "easy_memory.h"
#include <stdio.h>
#include <stdint.h>

/* =========================================================================
 * Global Arena
 * ========================================================================= */

/* Default global arena size: 16 MB (tunable via LUNET_EM_ARENA_SIZE) */
#ifndef LUNET_EM_ARENA_SIZE
#define LUNET_EM_ARENA_SIZE (16 * 1024 * 1024)
#endif

/* Opaque state – defined in lunet_easy_memory.c (or inlined below) */
typedef struct {
    EM *global_arena;          /* Main arena backing lunet_alloc/lunet_free      */
    int64_t alloc_count;       /* Running allocation counter                     */
    int64_t free_count;        /* Running free counter                           */
    int64_t alloc_bytes;       /* Total bytes allocated (cumulative)             */
    int64_t free_bytes;        /* Total bytes freed (cumulative)                 */
    int64_t current_bytes;     /* Bytes currently in use                         */
    int64_t peak_bytes;        /* High-water mark                                */
    int64_t arena_created;     /* Number of worker arenas created                */
    int64_t arena_destroyed;   /* Number of worker arenas destroyed              */
} lunet_em_state_t;

extern lunet_em_state_t lunet_em_state;

/* =========================================================================
 * Lifecycle
 * ========================================================================= */

/* Initialize the global EasyMem arena. Call once at startup. */
void lunet_em_init(void);

/* Destroy the global arena and print diagnostics. Call at shutdown. */
void lunet_em_shutdown(void);

/* Print a profiling summary to stderr. */
void lunet_em_summary(void);

/* Assert that all arena allocations have been freed. */
void lunet_em_assert_balanced(const char *context);

/* =========================================================================
 * Allocation API (used by lunet_mem.h when LUNET_EASY_MEMORY is active)
 * ========================================================================= */

void *lunet_em_alloc(size_t size, const char *file, int line);
void *lunet_em_calloc(size_t count, size_t size, const char *file, int line);
void *lunet_em_realloc(void *ptr, size_t new_size, const char *file, int line);
void  lunet_em_free(void *ptr, const char *file, int line);

/* =========================================================================
 * Worker Arena API (scoped arenas for DB thread-pool work)
 * ========================================================================= */

/*
 * Create a nested arena for a thread-pool work callback.
 * The arena is carved from the global EM arena.
 * Typical usage:
 *
 *   void db_work_cb(uv_work_t *req) {
 *       EM *arena = lunet_em_worker_arena_begin(64 * 1024);
 *       // ... allocate temporary buffers from arena ...
 *       lunet_em_worker_arena_end(arena);
 *   }
 */
EM *lunet_em_worker_arena_begin(size_t size);
void lunet_em_worker_arena_end(EM *arena);

#else /* !LUNET_EASY_MEMORY */

/* Compile to nothing when easy_memory is not enabled */
static inline void lunet_em_init(void) {}
static inline void lunet_em_shutdown(void) {}
static inline void lunet_em_summary(void) {}
static inline void lunet_em_assert_balanced(const char *ctx) { (void)ctx; }

#endif /* LUNET_EASY_MEMORY */

#endif /* LUNET_EASY_MEMORY_H */

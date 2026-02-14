/*
 * EasyMem/easy_memory integration implementation for Lunet
 *
 * This is the REAL allocation routing layer.  When LUNET_EASY_MEMORY is
 * defined, lunet_alloc / lunet_free / lunet_calloc (in lunet_mem.h) are
 * macros that expand to the lunet_em_* functions below.  Every allocation
 * goes through the EasyMem global arena.
 *
 * We prepend a small size_t header to each allocation so that:
 *   - lunet_em_free can track how many bytes were freed
 *   - lunet_em_realloc can copy the right amount of data
 *
 * Only compiled when LUNET_EASY_MEMORY is defined.
 */

#ifdef LUNET_EASY_MEMORY

#include "lunet_easy_memory.h"
#include <string.h>

/* =========================================================================
 * Size header: we store the requested size before the returned pointer.
 * Layout: [ size_t size ][ user data ... ]
 *                         ^ returned to caller
 * ========================================================================= */

/* Align the header to at least the natural alignment so user data stays aligned */
#define EM_HDR_SIZE  (sizeof(size_t) < 16 ? 16 : sizeof(size_t))

static inline void *em_hdr_to_user(void *raw) {
    return (char *)raw + EM_HDR_SIZE;
}

static inline void *em_user_to_hdr(void *user) {
    return (char *)user - EM_HDR_SIZE;
}

static inline size_t em_get_size(void *user) {
    size_t sz;
    memcpy(&sz, em_user_to_hdr(user), sizeof(sz));
    return sz;
}

static inline void em_set_size(void *raw, size_t sz) {
    memcpy(raw, &sz, sizeof(sz));
}

/* =========================================================================
 * Global State
 * ========================================================================= */

lunet_em_state_t lunet_em_state;

/* =========================================================================
 * Lifecycle
 * ========================================================================= */

void lunet_em_init(void) {
    memset(&lunet_em_state, 0, sizeof(lunet_em_state));

    lunet_em_state.global_arena = em_create(LUNET_EM_ARENA_SIZE);
    if (!lunet_em_state.global_arena) {
        fprintf(stderr, "[EASY_MEMORY] FATAL: failed to create global arena (%zu bytes)\n",
                (size_t)LUNET_EM_ARENA_SIZE);
        return;
    }

#ifdef LUNET_TRACE
    fprintf(stderr, "[EASY_MEMORY] Global arena initialized (%zu bytes)\n",
            (size_t)LUNET_EM_ARENA_SIZE);
#endif
}

void lunet_em_shutdown(void) {
    lunet_em_summary();

    if (lunet_em_state.global_arena) {
        em_destroy(lunet_em_state.global_arena);
        lunet_em_state.global_arena = NULL;
    }

#ifdef LUNET_TRACE
    fprintf(stderr, "[EASY_MEMORY] Global arena destroyed\n");
#endif
}

void lunet_em_summary(void) {
    fprintf(stderr, "\n");
    fprintf(stderr, "========================================\n");
    fprintf(stderr, "       EASY_MEMORY PROFILING SUMMARY\n");
    fprintf(stderr, "========================================\n");
    fprintf(stderr, "Allocations:\n");
    fprintf(stderr, "  Total allocs:   %lld\n", (long long)lunet_em_state.alloc_count);
    fprintf(stderr, "  Total frees:    %lld\n", (long long)lunet_em_state.free_count);
    fprintf(stderr, "  Alloc bytes:    %lld\n", (long long)lunet_em_state.alloc_bytes);
    fprintf(stderr, "  Free bytes:     %lld\n", (long long)lunet_em_state.free_bytes);
    fprintf(stderr, "  Current bytes:  %lld\n", (long long)lunet_em_state.current_bytes);
    fprintf(stderr, "  Peak bytes:     %lld\n", (long long)lunet_em_state.peak_bytes);
    fprintf(stderr, "\n");
    fprintf(stderr, "Worker Arenas:\n");
    fprintf(stderr, "  Created:        %lld\n", (long long)lunet_em_state.arena_created);
    fprintf(stderr, "  Destroyed:      %lld\n", (long long)lunet_em_state.arena_destroyed);
    if (lunet_em_state.arena_created != lunet_em_state.arena_destroyed) {
        fprintf(stderr, "  WARNING: arena leak! delta=%lld\n",
                (long long)(lunet_em_state.arena_created - lunet_em_state.arena_destroyed));
    }
    fprintf(stderr, "\n");
    fprintf(stderr, "Arena Config:\n");
    fprintf(stderr, "  Arena size:     %zu bytes\n", (size_t)LUNET_EM_ARENA_SIZE);
#ifdef EM_POISONING
    fprintf(stderr, "  Poisoning:      ENABLED\n");
#else
    fprintf(stderr, "  Poisoning:      disabled\n");
#endif
#ifdef EM_ASSERT_STAYS
    fprintf(stderr, "  Assertions:     ALWAYS ON (EM_ASSERT_STAYS)\n");
#elif defined(EM_ASSERT_PANIC)
    fprintf(stderr, "  Assertions:     PANIC mode\n");
#elif defined(DEBUG)
    fprintf(stderr, "  Assertions:     DEBUG mode\n");
#else
    fprintf(stderr, "  Assertions:     release (compiled out)\n");
#endif
    fprintf(stderr, "========================================\n\n");
}

void lunet_em_assert_balanced(const char *context) {
    if (lunet_em_state.alloc_count != lunet_em_state.free_count) {
        fprintf(stderr, "[EASY_MEMORY] LEAK at %s: allocs=%lld frees=%lld delta=%lld\n",
                context,
                (long long)lunet_em_state.alloc_count,
                (long long)lunet_em_state.free_count,
                (long long)(lunet_em_state.alloc_count - lunet_em_state.free_count));
    }
    if (lunet_em_state.current_bytes != 0) {
        fprintf(stderr, "[EASY_MEMORY] LEAK at %s: %lld bytes still allocated\n",
                context, (long long)lunet_em_state.current_bytes);
    }
    if (lunet_em_state.arena_created != lunet_em_state.arena_destroyed) {
        fprintf(stderr, "[EASY_MEMORY] ARENA LEAK at %s: created=%lld destroyed=%lld\n",
                context,
                (long long)lunet_em_state.arena_created,
                (long long)lunet_em_state.arena_destroyed);
    }
}

/* =========================================================================
 * Allocation API
 *
 * Every allocation stores a size_t header so we can track bytes on free
 * and support realloc (alloc+copy+free).
 * ========================================================================= */

void *lunet_em_alloc(size_t size, const char *file, int line) {
    if (!lunet_em_state.global_arena) return NULL;
    if (size == 0) size = 1;  /* EasyMem may reject 0-size */

    void *raw = em_alloc(lunet_em_state.global_arena, EM_HDR_SIZE + size);
    if (!raw) return NULL;

    em_set_size(raw, size);
    void *user = em_hdr_to_user(raw);

    lunet_em_state.alloc_count++;
    lunet_em_state.alloc_bytes += (int64_t)size;
    lunet_em_state.current_bytes += (int64_t)size;
    if (lunet_em_state.current_bytes > lunet_em_state.peak_bytes) {
        lunet_em_state.peak_bytes = lunet_em_state.current_bytes;
    }

#ifdef LUNET_TRACE_VERBOSE
    fprintf(stderr, "[EASY_MEMORY] ALLOC ptr=%p size=%zu at %s:%d\n",
            user, size, file, line);
#else
    (void)file; (void)line;
#endif

    return user;
}

void *lunet_em_calloc(size_t count, size_t size, const char *file, int line) {
    size_t total = count * size;
    void *ptr = lunet_em_alloc(total, file, line);
    if (ptr) {
        memset(ptr, 0, total);
    }
    return ptr;
}

void *lunet_em_realloc(void *ptr, size_t new_size, const char *file, int line) {
    /* realloc(NULL, size) == malloc(size) */
    if (!ptr) return lunet_em_alloc(new_size, file, line);

    /* realloc(ptr, 0) == free(ptr) */
    if (new_size == 0) {
        lunet_em_free(ptr, file, line);
        return NULL;
    }

    size_t old_size = em_get_size(ptr);
    void *new_ptr = lunet_em_alloc(new_size, file, line);
    if (!new_ptr) return NULL;

    size_t copy_size = old_size < new_size ? old_size : new_size;
    memcpy(new_ptr, ptr, copy_size);

    lunet_em_free(ptr, file, line);
    return new_ptr;
}

void lunet_em_free(void *ptr, const char *file, int line) {
    if (!ptr) return;
    if (!lunet_em_state.global_arena) return;

    size_t size = em_get_size(ptr);
    void *raw = em_user_to_hdr(ptr);

    lunet_em_state.free_count++;
    lunet_em_state.free_bytes += (int64_t)size;
    lunet_em_state.current_bytes -= (int64_t)size;

#ifdef LUNET_TRACE_VERBOSE
    fprintf(stderr, "[EASY_MEMORY] FREE ptr=%p size=%zu at %s:%d\n",
            ptr, size, file, line);
#else
    (void)file; (void)line;
#endif

    em_free(raw);
}

/* =========================================================================
 * Worker Arena API
 * ========================================================================= */

EM *lunet_em_worker_arena_begin(size_t size) {
    if (!lunet_em_state.global_arena) return NULL;

    EM *arena = em_create_nested(lunet_em_state.global_arena, size);
    if (arena) {
        lunet_em_state.arena_created++;
#ifdef LUNET_TRACE_VERBOSE
        fprintf(stderr, "[EASY_MEMORY] WORKER_ARENA_BEGIN size=%zu (total=%lld)\n",
                size, (long long)lunet_em_state.arena_created);
#endif
    }
    return arena;
}

void lunet_em_worker_arena_end(EM *arena) {
    if (!arena) return;

    em_destroy(arena);
    lunet_em_state.arena_destroyed++;

#ifdef LUNET_TRACE_VERBOSE
    fprintf(stderr, "[EASY_MEMORY] WORKER_ARENA_END (total_destroyed=%lld)\n",
            (long long)lunet_em_state.arena_destroyed);
#endif
}

#endif /* LUNET_EASY_MEMORY */

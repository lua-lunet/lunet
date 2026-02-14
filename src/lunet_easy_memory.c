/*
 * EasyMem/easy_memory integration implementation for Lunet
 *
 * Provides:
 *   - Global arena lifecycle (init / shutdown / summary)
 *   - Allocation wrappers that track statistics
 *   - Worker arena helpers for DB driver thread-pool callbacks
 *
 * Only compiled when LUNET_EASY_MEMORY is defined.
 */

#ifdef LUNET_EASY_MEMORY

#include "lunet_easy_memory.h"
#include <string.h>

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
 * ========================================================================= */

void *lunet_em_alloc(size_t size, const char *file, int line) {
    if (!lunet_em_state.global_arena) return NULL;

    void *ptr = em_alloc(lunet_em_state.global_arena, size);
    if (ptr) {
        lunet_em_state.alloc_count++;
        lunet_em_state.alloc_bytes += (int64_t)size;
        lunet_em_state.current_bytes += (int64_t)size;
        if (lunet_em_state.current_bytes > lunet_em_state.peak_bytes) {
            lunet_em_state.peak_bytes = lunet_em_state.current_bytes;
        }
    }

#ifdef LUNET_TRACE_VERBOSE
    fprintf(stderr, "[EASY_MEMORY] ALLOC ptr=%p size=%zu at %s:%d\n",
            ptr, size, file, line);
#else
    (void)file; (void)line;
#endif

    return ptr;
}

void *lunet_em_calloc(size_t count, size_t size, const char *file, int line) {
    size_t total = count * size;
    void *ptr = lunet_em_alloc(total, file, line);
    if (ptr) {
        memset(ptr, 0, total);
    }
    return ptr;
}

void lunet_em_free(void *ptr, const char *file, int line) {
    if (!ptr) return;
    if (!lunet_em_state.global_arena) return;

    /*
     * NOTE: easy_memory does not expose the size of a previously allocated
     * block via its public API, so we cannot track exact freed byte counts
     * the way our canary-based allocator does. We track the count only.
     * The arena's internal integrity checks (XOR-magic headers, poisoning)
     * provide the safety guarantees instead.
     */
    lunet_em_state.free_count++;

#ifdef LUNET_TRACE_VERBOSE
    fprintf(stderr, "[EASY_MEMORY] FREE ptr=%p at %s:%d\n", ptr, file, line);
#else
    (void)file; (void)line;
#endif

    em_free(ptr);
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

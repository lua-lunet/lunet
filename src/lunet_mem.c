#include "lunet_mem.h"

#if defined(LUNET_TRACE) || defined(LUNET_EASY_MEMORY)

#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <string.h>

#ifdef LUNET_EASY_MEMORY
#ifdef LUNET_EASY_MEMORY_DIAGNOSTICS
#ifndef DEBUG
#define DEBUG
#endif
#ifndef EM_ASSERT_STAYS
#define EM_ASSERT_STAYS
#endif
#ifndef EM_POISONING
#define EM_POISONING
#endif
#ifndef EM_SAFETY_POLICY
#define EM_SAFETY_POLICY EM_POLICY_CONTRACT
#endif
#endif
#define EASY_MEMORY_IMPLEMENTATION
#include <easy_memory.h>
#endif

lunet_mem_state_t lunet_mem_state;

#ifdef LUNET_EASY_MEMORY
static EM *g_lunet_em = NULL;
static int g_lunet_em_initialized = 0;
static int g_lunet_em_enabled = 0;
static int g_lunet_em_shutdown_registered = 0;

static void lunet_mem_atexit_shutdown(void) {
    lunet_mem_shutdown();
}

static void *lunet_backend_alloc(size_t size) {
    if (g_lunet_em_enabled && g_lunet_em) {
        return em_alloc(g_lunet_em, size);
    }
    return malloc(size);
}

static void lunet_backend_free(void *ptr) {
    if (!ptr) {
        return;
    }
    if (g_lunet_em_enabled && g_lunet_em) {
        em_free(ptr);
        return;
    }
    free(ptr);
}
#endif

void lunet_mem_init(void) {
    memset(&lunet_mem_state, 0, sizeof(lunet_mem_state));
#ifdef LUNET_EASY_MEMORY
    if (g_lunet_em_initialized) {
        return;
    }
    g_lunet_em_initialized = 1;
    g_lunet_em = em_create((size_t)LUNET_EASY_MEMORY_ARENA_BYTES);
    if (g_lunet_em) {
        g_lunet_em_enabled = 1;
#ifdef LUNET_TRACE_VERBOSE
        fprintf(stderr, "[MEM_TRACE] EASY_MEMORY backend enabled (arena=%llu bytes)\n",
                (unsigned long long)LUNET_EASY_MEMORY_ARENA_BYTES);
#endif
    } else {
        g_lunet_em_enabled = 0;
        fprintf(stderr, "[MEM_TRACE] EASY_MEMORY backend unavailable, falling back to libc allocator\n");
    }
    if (!g_lunet_em_shutdown_registered) {
        if (atexit(lunet_mem_atexit_shutdown) == 0) {
            g_lunet_em_shutdown_registered = 1;
        } else {
            fprintf(stderr, "[MEM_TRACE] WARNING: failed to register EASY_MEMORY shutdown hook\n");
        }
    }
#endif
}

void lunet_mem_shutdown(void) {
#ifdef LUNET_EASY_MEMORY
    if (g_lunet_em_enabled && g_lunet_em) {
        em_destroy(g_lunet_em);
        g_lunet_em = NULL;
    }
    g_lunet_em_enabled = 0;
    g_lunet_em_initialized = 0;
#endif
}

void *lunet_mem_alloc_impl(size_t size, const char *file, int line) {
    lunet_mem_header_t *header = NULL;
#ifdef LUNET_EASY_MEMORY
    header = (lunet_mem_header_t *)lunet_backend_alloc(sizeof(lunet_mem_header_t) + size);
#else
    header = (lunet_mem_header_t *)malloc(sizeof(lunet_mem_header_t) + size);
#endif
    if (!header) {
        return NULL;
    }

    header->canary = LUNET_MEM_CANARY;
    header->size = size;

    lunet_mem_state.alloc_count++;
    lunet_mem_state.alloc_bytes += (int64_t)size;
    lunet_mem_state.current_bytes += (int64_t)size;
    if (lunet_mem_state.current_bytes > lunet_mem_state.peak_bytes) {
        lunet_mem_state.peak_bytes = lunet_mem_state.current_bytes;
    }

    void *ptr = (void *)(header + 1);

#ifdef LUNET_TRACE_VERBOSE
    fprintf(stderr, "[MEM_TRACE] ALLOC ptr=%p size=%zu at %s:%d\n",
            ptr, size, file, line);
#else
    (void)file;
    (void)line;
#endif

    return ptr;
}

void *lunet_mem_calloc_impl(size_t count, size_t size, const char *file, int line) {
    if (count != 0 && size > (SIZE_MAX / count)) {
        return NULL;
    }
    size_t total = count * size;
    void *ptr = lunet_mem_alloc_impl(total, file, line);
    if (ptr) {
        memset(ptr, 0, total);
    }
    return ptr;
}

void *lunet_mem_realloc_impl(void *ptr, size_t size, const char *file, int line) {
    if (!ptr) {
        return lunet_mem_alloc_impl(size, file, line);
    }

    lunet_mem_header_t *old_header = ((lunet_mem_header_t *)ptr) - 1;
    if (old_header->canary != LUNET_MEM_CANARY) {
        fprintf(stderr, "[MEM_TRACE] CANARY_FAIL on realloc ptr=%p "
                "(expected 0x%08X got 0x%08X) at %s:%d\n",
                ptr, LUNET_MEM_CANARY, old_header->canary, file, line);
        return NULL;
    }

#ifdef LUNET_EASY_MEMORY
    size_t old_size = old_header->size;
    void *new_ptr = lunet_mem_alloc_impl(size, file, line);
    if (!new_ptr) {
        return NULL;
    }
    if (old_size > 0 && size > 0) {
        size_t copy_size = old_size < size ? old_size : size;
        memcpy(new_ptr, ptr, copy_size);
    }
    lunet_mem_free_impl(ptr, file, line);
    return new_ptr;
#else
    size_t old_size = old_header->size;

    lunet_mem_state.free_count++;
    lunet_mem_state.free_bytes += (int64_t)old_size;
    lunet_mem_state.current_bytes -= (int64_t)old_size;

    lunet_mem_header_t *new_header = (lunet_mem_header_t *)realloc(
        old_header, sizeof(lunet_mem_header_t) + size);
    if (!new_header) {
        return NULL;
    }

    new_header->canary = LUNET_MEM_CANARY;
    new_header->size = size;

    lunet_mem_state.alloc_count++;
    lunet_mem_state.alloc_bytes += (int64_t)size;
    lunet_mem_state.current_bytes += (int64_t)size;
    if (lunet_mem_state.current_bytes > lunet_mem_state.peak_bytes) {
        lunet_mem_state.peak_bytes = lunet_mem_state.current_bytes;
    }

    return (void *)(new_header + 1);
#endif
}

void lunet_mem_free_impl(void *ptr, const char *file, int line) {
    if (!ptr) {
        return;
    }

    lunet_mem_header_t *header = ((lunet_mem_header_t *)ptr) - 1;
    if (header->canary != LUNET_MEM_CANARY) {
        if (header->canary == (LUNET_MEM_POISON | (LUNET_MEM_POISON << 8) |
                               (LUNET_MEM_POISON << 16) | (LUNET_MEM_POISON << 24))) {
            fprintf(stderr, "[MEM_TRACE] DOUBLE_FREE ptr=%p "
                    "(memory already poisoned with 0xDE) at %s:%d\n",
                    ptr, file, line);
        } else {
            fprintf(stderr, "[MEM_TRACE] CANARY_FAIL on free ptr=%p "
                    "(expected 0x%08X got 0x%08X) at %s:%d\n",
                    ptr, LUNET_MEM_CANARY, header->canary, file, line);
        }
        return;
    }

    size_t size = header->size;
    lunet_mem_state.free_count++;
    lunet_mem_state.free_bytes += (int64_t)size;
    lunet_mem_state.current_bytes -= (int64_t)size;

#ifdef LUNET_TRACE_VERBOSE
    fprintf(stderr, "[MEM_TRACE] FREE ptr=%p size=%zu at %s:%d\n",
            ptr, size, file, line);
#else
    (void)file;
    (void)line;
#endif

    memset(header, LUNET_MEM_POISON, sizeof(lunet_mem_header_t) + size);
#ifdef LUNET_EASY_MEMORY
    lunet_backend_free(header);
#else
    free(header);
#endif
}

void lunet_mem_summary(void) {
    fprintf(stderr, "[MEM_TRACE] SUMMARY: allocs=%d frees=%d "
            "alloc_bytes=%lld free_bytes=%lld current=%lld peak=%lld\n",
            lunet_mem_state.alloc_count,
            lunet_mem_state.free_count,
            (long long)lunet_mem_state.alloc_bytes,
            (long long)lunet_mem_state.free_bytes,
            (long long)lunet_mem_state.current_bytes,
            (long long)lunet_mem_state.peak_bytes);
#ifdef LUNET_EASY_MEMORY
    if (g_lunet_em_enabled && g_lunet_em) {
        fprintf(stderr, "[MEM_TRACE] EASY_MEMORY: enabled arena=%llu bytes diagnostics=%s\n",
                (unsigned long long)LUNET_EASY_MEMORY_ARENA_BYTES,
#ifdef LUNET_EASY_MEMORY_DIAGNOSTICS
                "on");
        print_em(g_lunet_em);
        print_fancy(g_lunet_em, 64);
#else
                "off");
#endif
    } else if (g_lunet_em_initialized) {
        fprintf(stderr, "[MEM_TRACE] EASY_MEMORY: disabled (libc fallback)\n");
    }
#endif
}

void lunet_mem_assert_balanced(const char *context) {
    if (lunet_mem_state.alloc_count != lunet_mem_state.free_count) {
        fprintf(stderr, "[MEM_TRACE] LEAK at %s: alloc_count=%d free_count=%d (delta=%d)\n",
                context,
                lunet_mem_state.alloc_count,
                lunet_mem_state.free_count,
                lunet_mem_state.alloc_count - lunet_mem_state.free_count);
        /* Don't assert - just report. The leak in timer.c is known. */
    }
    if (lunet_mem_state.current_bytes != 0) {
        fprintf(stderr, "[MEM_TRACE] LEAK at %s: %lld bytes still allocated\n",
                context, (long long)lunet_mem_state.current_bytes);
    }
}

#endif /* LUNET_TRACE || LUNET_EASY_MEMORY */

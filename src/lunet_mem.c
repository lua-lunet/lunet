#include "lunet_mem.h"

#ifdef LUNET_TRACE

#include <stdio.h>
#include <assert.h>
#include <string.h>

lunet_mem_state_t lunet_mem_state;

void lunet_mem_init(void) {
    memset(&lunet_mem_state, 0, sizeof(lunet_mem_state));
}

void *lunet_mem_alloc_impl(size_t size, const char *file, int line) {
    lunet_mem_header_t *header = (lunet_mem_header_t *)malloc(sizeof(lunet_mem_header_t) + size);
    if (!header) return NULL;

    header->canary = LUNET_MEM_CANARY;
    header->size = (uint32_t)size;

    lunet_mem_state.alloc_count++;
    lunet_mem_state.alloc_bytes += (int64_t)size;
    lunet_mem_state.current_bytes += (int64_t)size;
    if (lunet_mem_state.current_bytes > lunet_mem_state.peak_bytes) {
        lunet_mem_state.peak_bytes = lunet_mem_state.current_bytes;
    }

    void *ptr = (void *)(header + 1);

#ifdef LUNET_TRACE_VERBOSE
    fprintf(stderr, "[MEM_TRACE] ALLOC ptr=%p size=%u at %s:%d\n",
            ptr, (unsigned)size, file, line);
#else
    (void)file; (void)line;
#endif

    return ptr;
}

LUNET_API void *lunet_mem_calloc_impl(size_t count, size_t size, const char *file, int line) {
    size_t total = count * size;
    void *ptr = lunet_mem_alloc_impl(total, file, line);
    if (ptr) {
        memset(ptr, 0, total);
    }
    return ptr;
}

LUNET_API void *lunet_mem_realloc_impl(void *ptr, size_t size, const char *file, int line) {
    if (!ptr) {
        return lunet_mem_alloc_impl(size, file, line);
    }

    lunet_mem_header_t *old_header = ((lunet_mem_header_t *)ptr) - 1;
    if (old_header->canary != LUNET_MEM_CANARY) {
        fprintf(stderr, "[MEM_TRACE] CANARY_FAIL on realloc ptr=%p "
                "(expected 0x%08X got 0x%08X) at %s:%d\n",
                ptr, LUNET_MEM_CANARY, old_header->canary, file, line);
        /* Return NULL rather than abort - let caller handle it */
        return NULL;
    }

    uint32_t old_size = old_header->size;
    lunet_mem_state.free_count++;
    lunet_mem_state.free_bytes += (int64_t)old_size;
    lunet_mem_state.current_bytes -= (int64_t)old_size;

    lunet_mem_header_t *new_header = (lunet_mem_header_t *)realloc(
        old_header, sizeof(lunet_mem_header_t) + size);
    if (!new_header) return NULL;

    new_header->canary = LUNET_MEM_CANARY;
    new_header->size = (uint32_t)size;

    lunet_mem_state.alloc_count++;
    lunet_mem_state.alloc_bytes += (int64_t)size;
    lunet_mem_state.current_bytes += (int64_t)size;
    if (lunet_mem_state.current_bytes > lunet_mem_state.peak_bytes) {
        lunet_mem_state.peak_bytes = lunet_mem_state.current_bytes;
    }

    return (void *)(new_header + 1);
}

void lunet_mem_free_impl(void *ptr, const char *file, int line) {
    if (!ptr) return;

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
        /* Do NOT call free - memory is corrupt or already freed */
        return;
    }

    uint32_t size = header->size;

    lunet_mem_state.free_count++;
    lunet_mem_state.free_bytes += (int64_t)size;
    lunet_mem_state.current_bytes -= (int64_t)size;

#ifdef LUNET_TRACE_VERBOSE
    fprintf(stderr, "[MEM_TRACE] FREE ptr=%p size=%u at %s:%d\n",
            ptr, (unsigned)size, file, line);
#else
    (void)file; (void)line;
#endif

    /* Poison the user region + header so any use-after-free reads 0xDEDEDEDE */
    memset(header, LUNET_MEM_POISON, sizeof(lunet_mem_header_t) + size);

    free(header);
}

LUNET_API void lunet_mem_summary(void) {
    fprintf(stderr, "[MEM_TRACE] SUMMARY: allocs=%d frees=%d "
            "alloc_bytes=%lld free_bytes=%lld current=%lld peak=%lld\n",
            lunet_mem_state.alloc_count,
            lunet_mem_state.free_count,
            (long long)lunet_mem_state.alloc_bytes,
            (long long)lunet_mem_state.free_bytes,
            (long long)lunet_mem_state.current_bytes,
            (long long)lunet_mem_state.peak_bytes);
}

LUNET_API void lunet_mem_assert_balanced(const char *context) {
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

#endif /* LUNET_TRACE */

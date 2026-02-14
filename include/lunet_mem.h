#ifndef LUNET_MEM_H
#define LUNET_MEM_H

/*
 * Centralized memory management with optional EasyMem backend.
 *
 * Default release builds:
 *   lunet_alloc/lunet_free/lunet_calloc/lunet_realloc map directly to libc.
 *
 * Trace/EasyMem builds:
 *   - Hidden allocation header with canary
 *   - Allocation/free counters and byte totals
 *   - Poison-on-free and leak reporting
 *   - Optional EasyMem arena backend with integrity diagnostics
 */

#include <stdlib.h>
#include <string.h>

#ifndef LUNET_EASY_MEMORY_ARENA_BYTES
#define LUNET_EASY_MEMORY_ARENA_BYTES (128ULL * 1024ULL * 1024ULL)
#endif

#if defined(LUNET_TRACE) || defined(LUNET_EASY_MEMORY)

#include <stdio.h>
#include <assert.h>
#include <stdint.h>

/* Magic canary value: ASCII "LUNE" = 0x4C554E45 */
#define LUNET_MEM_CANARY 0x4C554E45U

/* Poison byte written over freed memory */
#define LUNET_MEM_POISON 0xDE

/* Hidden header prepended to every allocation */
typedef struct {
    uint32_t canary;
    uint32_t size;
} lunet_mem_header_t;

/* Global memory statistics */
typedef struct {
    int alloc_count;
    int free_count;
    int64_t alloc_bytes;
    int64_t free_bytes;
    int64_t current_bytes;
    int64_t peak_bytes;
} lunet_mem_state_t;

extern lunet_mem_state_t lunet_mem_state;

void lunet_mem_init(void);
void lunet_mem_shutdown(void);
void lunet_mem_summary(void);
void lunet_mem_assert_balanced(const char *context);

/* Core allocation functions - called via macros with file/line */
void *lunet_mem_alloc_impl(size_t size, const char *file, int line);
void *lunet_mem_calloc_impl(size_t count, size_t size, const char *file, int line);
void *lunet_mem_realloc_impl(void *ptr, size_t size, const char *file, int line);
void  lunet_mem_free_impl(void *ptr, const char *file, int line);

#define lunet_alloc(size)          lunet_mem_alloc_impl((size), __FILE__, __LINE__)
#define lunet_calloc(count, size)  lunet_mem_calloc_impl((count), (size), __FILE__, __LINE__)
#define lunet_realloc(ptr, size)   lunet_mem_realloc_impl((ptr), (size), __FILE__, __LINE__)
#define lunet_free(ptr)            do { lunet_mem_free_impl((ptr), __FILE__, __LINE__); (ptr) = NULL; } while(0)

/* Free without NULLing - for cases where ptr is a local about to go out of scope */
#define lunet_free_nonnull(ptr)    lunet_mem_free_impl((ptr), __FILE__, __LINE__)

#else /* !LUNET_TRACE && !LUNET_EASY_MEMORY */

/* Zero-cost: direct to system allocator */
#define lunet_alloc(size)          malloc(size)
#define lunet_calloc(count, size)  calloc((count), (size))
#define lunet_realloc(ptr, size)   realloc((ptr), (size))
#define lunet_free(ptr)            free(ptr)
#define lunet_free_nonnull(ptr)    free(ptr)

static inline void lunet_mem_init(void) {}
static inline void lunet_mem_shutdown(void) {}
static inline void lunet_mem_summary(void) {}
static inline void lunet_mem_assert_balanced(const char *context) { (void)context; }

#endif /* LUNET_TRACE || LUNET_EASY_MEMORY */

#endif /* LUNET_MEM_H */

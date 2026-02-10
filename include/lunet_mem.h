#ifndef LUNET_MEM_H
#define LUNET_MEM_H

/*
 * Centralized Memory Management with Two-Tier Diagnostics
 * ========================================================
 *
 * Release builds (default):
 *   lunet_alloc/lunet_free/lunet_calloc/lunet_realloc are thin #defines
 *   to malloc/free/calloc/realloc. Zero overhead.
 *
 * Tier 1 - LUNET_TRACE (counters + canary + poison):
 *   Every allocation gets a hidden header with a magic canary (0x4C554E45 = "LUNE").
 *   Global counters track alloc/free counts and byte totals.
 *   On free: canary is validated, memory is poisoned with 0xDE, pointer is NULLed.
 *   On shutdown: lunet_mem_summary() prints stats, lunet_mem_assert_balanced() aborts
 *   if alloc_count != free_count.
 *
 * Tier 2 - LUNET_TRACE_VERBOSE (per-event stderr logging):
 *   Every alloc/free prints [MEM_TRACE] with pointer, size, and caller file:line.
 *   Only enable when actively debugging. Compile-time flag.
 */

#include <stdlib.h>
#include <string.h>

#ifdef LUNET_TRACE

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

#else /* !LUNET_TRACE */

/* Zero-cost: direct to system allocator */
#define lunet_alloc(size)          malloc(size)
#define lunet_calloc(count, size)  calloc((count), (size))
#define lunet_realloc(ptr, size)   realloc((ptr), (size))
#define lunet_free(ptr)            free(ptr)
#define lunet_free_nonnull(ptr)    free(ptr)

static inline void lunet_mem_init(void) {}
static inline void lunet_mem_summary(void) {}
static inline void lunet_mem_assert_balanced(const char *context) { (void)context; }

#endif /* LUNET_TRACE */

#endif /* LUNET_MEM_H */

# Memory Safety Strategies for C99: A Report for Lunet

## Executive Summary

This report explores state-of-the-art memory safety techniques for C99 that can provide Rust-like safety guarantees at critical checkpoints, while maintaining the performance characteristics required for a high-performance async I/O runtime like Lunet.

**Key Insight**: Lunet's architecture (libuv thread pool + coroutine yields) creates natural "memory neutrality checkpoints" where we can assert that all operation-scoped allocations have been freed. This is an ideal fit for arena allocators and checkpoint-based leak detection.

---

## 1. Current State: What We Have

### 1.1 Zero-Cost Coroutine Tracing (Implemented in PR #21)

- `lunet_coref_create()` / `lunet_coref_release()` tracking
- Stack integrity verification
- Reference balance assertions at shutdown
- Zero overhead in release builds

### 1.2 What's Missing

- **Memory allocation tracking**: We track coroutine refs, but not `malloc`/`free`
- **Per-operation memory isolation**: No guarantee that a DB query cleans up after itself
- **Leak detection**: No automatic detection of memory leaks
- **Thread-local arenas**: All threads share the global heap

---

## 2. Arena Allocators: The Right Tool for Lunet

### 2.1 Why Arenas Fit Our Model

Lunet's execution model creates natural allocation scopes:

```
┌─────────────────────────────────────────────────────────┐
│ Main Thread (Event Loop)                                │
│   ┌───────────────────────────────────────────────────┐ │
│   │ Coroutine A: HTTP Request                         │ │
│   │   - Parse request (allocate)                      │ │
│   │   - yield to DB query                             │ │
│   │   - Resume with result                            │ │
│   │   - Format response (allocate)                    │ │
│   │   - RETURN → all allocations should be freed      │ │
│   └───────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│ Thread Pool Worker                                      │
│   ┌───────────────────────────────────────────────────┐ │
│   │ DB Query Work Function                            │ │
│   │   - Allocate result buffers                       │ │
│   │   - Execute query                                 │ │
│   │   - Copy results                                  │ │
│   │   - RETURN → all worker allocations freed         │ │
│   └───────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────┘
```

**Key Property**: At the end of each operation, memory should be "neutral" - everything allocated during the operation should be freed.

### 2.2 Arena Allocator Design

An arena is simply:

```c
typedef struct {
    char *base;      // Start of memory block
    size_t offset;   // Current position
    size_t capacity; // Total size
} arena_t;

// Allocate from arena (bump pointer - extremely fast)
void *arena_alloc(arena_t *a, size_t size) {
    size = (size + 7) & ~7;  // Align to 8 bytes
    if (a->offset + size > a->capacity) return NULL;
    void *ptr = a->base + a->offset;
    a->offset += size;
    return ptr;
}

// Reset arena (free everything at once - O(1))
void arena_reset(arena_t *a) {
    a->offset = 0;  // That's it!
}
```

**Benefits**:
- **Allocation**: O(1) - just bump a pointer
- **Deallocation**: O(1) - reset the offset
- **No fragmentation**: Linear allocation
- **Cache-friendly**: Allocations are contiguous
- **No individual frees needed**: Reset handles everything

### 2.3 Proposed Arena Strategy for Lunet

```c
// Thread-local arena for worker threads
__thread arena_t *tl_arena = NULL;

// Per-operation arena (created per coroutine/request)
typedef struct {
    arena_t arena;
    struct lunet_op_arena *parent;  // For nested operations
} lunet_op_arena_t;

// Macros for scoped allocation
#define LUNET_OP_BEGIN(size) \
    lunet_op_arena_t _op_arena; \
    lunet_op_arena_init(&_op_arena, size)

#define LUNET_OP_ALLOC(size) \
    arena_alloc(&_op_arena.arena, size)

#define LUNET_OP_END() \
    lunet_op_arena_destroy(&_op_arena)
```

---

## 3. Memory Tracking Approaches

### 3.1 Debug-Only Tracking (Zero-Cost in Release)

Similar to our coroutine tracing, add allocation tracking:

```c
#ifdef LUNET_TRACE

typedef struct {
    size_t alloc_count;
    size_t free_count;
    size_t bytes_allocated;
    size_t bytes_freed;
    size_t peak_usage;
} lunet_mem_stats_t;

extern __thread lunet_mem_stats_t lunet_mem_stats;

#define lunet_malloc(size) _lunet_malloc_tracked(size, __FILE__, __LINE__)
#define lunet_free(ptr) _lunet_free_tracked(ptr, __FILE__, __LINE__)

// Assert memory neutrality at checkpoint
#define lunet_mem_assert_neutral(ctx) do { \
    if (lunet_mem_stats.alloc_count != lunet_mem_stats.free_count) { \
        fprintf(stderr, "[TRACE] MEMORY LEAK at %s: allocs=%zu, frees=%zu\n", \
                ctx, lunet_mem_stats.alloc_count, lunet_mem_stats.free_count); \
        assert(0 && "Memory leak detected"); \
    } \
} while(0)

#else

#define lunet_malloc(size) malloc(size)
#define lunet_free(ptr) free(ptr)
#define lunet_mem_assert_neutral(ctx) ((void)0)

#endif
```

### 3.2 Thread-Local Heap Isolation

For worker threads that should be memory-neutral after each task:

```c
// Worker thread gets its own arena
void db_work_cb(uv_work_t *req) {
    // Create thread-local arena for this work unit
    arena_t work_arena;
    arena_init(&work_arena, 64 * 1024);  // 64KB per work unit
    
    // All allocations during work use this arena
    db_ctx_t *ctx = req->data;
    ctx->result = arena_alloc(&work_arena, result_size);
    
    // ... do work ...
    
    // Copy result to main thread's memory before returning
    // Arena is automatically cleaned up
    arena_destroy(&work_arena);
}
```

---

## 4. Compiler & Runtime Tools

### 4.1 AddressSanitizer (ASan)

**What**: Compiler instrumentation for memory error detection
**Overhead**: ~2x slowdown, ~2x memory
**Use Case**: Development and CI testing

```bash
# Build with ASan
cmake -DCMAKE_C_FLAGS="-fsanitize=address -g" ..

# Run tests
ASAN_OPTIONS=detect_leaks=1 ./build/lunet test/stress_test.lua
```

**Detects**:
- Buffer overflows (heap, stack, global)
- Use-after-free
- Double-free
- Memory leaks (with LeakSanitizer)

### 4.2 LeakSanitizer (LSan)

**What**: Memory leak detector, can run standalone or with ASan
**Overhead**: Minimal until shutdown (then scans heap)
**Use Case**: CI testing for leak detection

```bash
# Standalone LSan
cmake -DCMAKE_C_FLAGS="-fsanitize=leak -g" ..

# With ASan (recommended)
cmake -DCMAKE_C_FLAGS="-fsanitize=address -g" ..
ASAN_OPTIONS=detect_leaks=1 ./build/lunet app/main.lua
```

### 4.3 Valgrind

**What**: Runtime memory analysis tool
**Overhead**: 10-50x slowdown
**Use Case**: Deep investigation of memory issues

```bash
valgrind --leak-check=full --track-origins=yes ./build/lunet test/stress_test.lua
```

---

## 5. Modern Allocator Options

### 5.1 mimalloc (Microsoft)

**Best for**: General replacement with excellent performance

- Free list sharding reduces contention
- ~7% faster than jemalloc in benchmarks
- Drop-in replacement via LD_PRELOAD or linking
- Good for reference-counting languages (Swift, Python)

```bash
# Link with mimalloc
cmake -DCMAKE_C_FLAGS="-I/path/to/mimalloc/include" \
      -DCMAKE_EXE_LINKER_FLAGS="-L/path/to/mimalloc/lib -lmimalloc" ..
```

### 5.2 jemalloc (Facebook)

**Best for**: Multi-threaded applications with many allocations

- Thread-local caches reduce lock contention
- Excellent fragmentation handling
- Used by Firefox, Facebook, Redis

### 5.3 tcmalloc (Google)

**Best for**: Large-scale applications

- Per-thread caches
- Central free list for cross-thread deallocation
- Good profiling support

### 5.4 rpmalloc

**Best for**: Lock-free requirements

- Completely lock-free thread caching
- 16-byte aligned allocations
- Very low overhead

---

## 6. Recommended Implementation Plan

### Phase 1: Sanitizer Integration (Low effort, High value)

Add `make sanitize` target for ASan+LSan testing:

```makefile
sanitize: ## Build with AddressSanitizer for memory error detection
	@echo "=== Building with AddressSanitizer ==="
	mkdir -p build
	cd build && cmake -DLUNET_DB=$(LUNET_DB) \
		-DCMAKE_C_FLAGS="-fsanitize=address -fno-omit-frame-pointer -g" \
		-DCMAKE_EXE_LINKER_FLAGS="-fsanitize=address" .. && make
	@echo "Run with: ASAN_OPTIONS=detect_leaks=1 ./build/lunet <script>"
```

### Phase 2: Memory Tracking Macros (Medium effort, High value)

Extend `trace.h` with allocation tracking:

```c
#ifdef LUNET_TRACE
  #define lunet_malloc(size) _lunet_malloc_tracked(size, __FILE__, __LINE__)
  #define lunet_free(ptr) _lunet_free_tracked(ptr, __FILE__, __LINE__)
  #define lunet_mem_checkpoint() _lunet_mem_checkpoint(__FILE__, __LINE__)
  #define lunet_mem_assert_since_checkpoint() _lunet_mem_assert_checkpoint(__FILE__, __LINE__)
#else
  #define lunet_malloc(size) malloc(size)
  #define lunet_free(ptr) free(ptr)
  #define lunet_mem_checkpoint() ((void)0)
  #define lunet_mem_assert_since_checkpoint() ((void)0)
#endif
```

### Phase 3: Thread-Local Arenas for Workers (Medium effort, High value)

Add arena allocator for `uv_queue_work` callbacks:

```c
// In work callback
void db_query_work(uv_work_t *req) {
    lunet_worker_arena_begin(64 * 1024);  // 64KB arena
    
    // All allocations use arena...
    
    lunet_worker_arena_end();  // Assert empty, then free
}
```

### Phase 4: Per-Request Arenas (Higher effort, Highest value)

Integrate arenas into coroutine lifecycle:

```c
// When coroutine starts handling request
lunet_request_arena_t *arena = lunet_request_arena_create(request_id);

// All allocations during request handling use this arena
void *data = lunet_request_alloc(arena, size);

// When request completes
lunet_request_arena_destroy(arena);  // Frees everything at once
```

---

## 7. Comparison: Our Approach vs. Rust

| Aspect | Rust | Lunet (Proposed) |
|--------|------|------------------|
| Memory safety | Compile-time ownership | Runtime checkpoint assertions |
| Overhead (release) | Zero | Zero (macros compile away) |
| Overhead (debug) | Zero | ~5% (tracking) |
| Leak detection | Compile-time | Runtime assertions at checkpoints |
| Thread safety | Compile-time Send/Sync | Arena isolation + assertions |
| Learning curve | Steep | Minimal (just use macros) |
| Flexibility | Constrained by borrow checker | Full C flexibility |

**Key Insight**: We can't match Rust's compile-time guarantees, but we can:
1. Catch 99% of bugs in debug/test builds
2. Have zero overhead in release
3. Leverage our natural "memory neutrality checkpoints"

---

## 8. TODO Items

### Immediate (PR #22)
- [ ] Add `make sanitize` target with ASan+LSan
- [ ] Update stress test to run under sanitizer
- [ ] Document sanitizer usage in AGENTS.md

### Short-term
- [ ] Implement `lunet_malloc`/`lunet_free` tracking macros
- [ ] Add `lunet_mem_assert_neutral()` to stress test
- [ ] Track per-file allocation stats

### Medium-term
- [ ] Implement simple arena allocator in `include/arena.h`
- [ ] Add thread-local arena for worker threads
- [ ] Add `lunet_worker_arena_begin()`/`_end()` wrappers

### Long-term
- [ ] Per-request arena integration
- [ ] Consider mimalloc as default allocator
- [ ] Memory profiling tools integration

---

## References

1. [Ryan Fleury - Untangling Lifetimes: The Arena Allocator](https://www.rfleury.com/p/untangling-lifetimes-the-arena-allocator)
2. [Chris Wellons - Arena allocator tips and tricks](https://nullprogram.com/blog/2023/09/27/)
3. [mimalloc Technical Report (Microsoft)](https://www.microsoft.com/en-us/research/wp-content/uploads/2019/06/mimalloc-tr-v1.pdf)
4. [AddressSanitizer - Clang Documentation](https://clang.llvm.org/docs/AddressSanitizer.html)
5. [LeakSanitizer - Clang Documentation](https://clang.llvm.org/docs/LeakSanitizer.html)
6. [libuv Thread Pool Documentation](https://docs.libuv.org/en/v1.x/threadpool.html)
7. [John Lakos - Local Memory Allocators (CppCon 2017)](https://www.youtube.com/watch?v=nZNd5FjSquk)

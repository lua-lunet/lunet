# EasyMem Integration and Profiling Report

## Scope

This report replaces the older memory safety strategy write-up and documents the current EasyMem integration in Lunet:

- optional EasyMem add-in support in `xmake.lua`
- automatic EasyMem enablement in trace and ASAN builds
- experimental release mode with EasyMem diagnostics
- profiling output from example/demo runs

## Build/Profile Modes Added

Lunet now supports these EasyMem paths:

1. **Automatic in trace builds**
   - `xmake f -c -m debug --lunet_trace=y --lunet_verbose_trace=n -y`
2. **Automatic in ASAN builds**
   - `xmake f -c -m debug --lunet_trace=y --asan=y -y`
   - On Windows, ASAN compiler flags are skipped (expected behavior).
3. **Experimental release with EasyMem**
   - `xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n --easy_memory_experimental=y --easy_memory_arena_mb=128 -y`
4. **Manual opt-in**
   - `xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n --easy_memory=y -y`

## Validation Runs

Logs are archived at:

- `.tmp/logs/20260214_054129/`

### Build validation

| Profile | Result | Notes |
|---|---|---|
| Debug + trace | PASS | EasyMem downloaded and enabled |
| Debug + ASAN | PASS | `-fsanitize=address` + `LUNET_EASY_MEMORY_DIAGNOSTICS` confirmed |
| Experimental release | PASS | `lunet-run`, `lunet`, `lunet-sqlite3`, `lunet-paxe` built |

### Example/demo validation

| Script | Result | Key observations |
|---|---|---|
| `examples/03_db_sqlite3.lua` | PASS | Functional DB flow passed; EasyMem summary + ASCII visualization printed |
| `examples/06_paxe_encryption.lua` | PASS | PAXE encryption/decryption flow passed; EasyMem summary + visualization printed |
| `examples/07_paxe_stress.lua` (`ITERATIONS=200`) | PASS | Throughput output stable; script ends via `os.exit`, so Lunet shutdown summary is skipped |
| `test/stress_test.lua` (`10x20`) in experimental release | PASS | `[MEM_TRACE] allocs=203 frees=203 peak=7032` |
| `test/stress_test.lua` (`5x10`) in debug+ASAN | PASS | `[MEM_TRACE] allocs=53 frees=53 peak=3456`, trace summary balanced, no ASAN errors |

## Profiling Findings

1. **EasyMem diagnostics are active**
   - `print_em()` and `print_fancy()` output is present at shutdown in diagnostics-enabled profiles.
   - ASCII memory visualization ("chart") is emitted as expected.

2. **Allocator accounting is accurate for Lunet core allocations**
   - Stress runs show balanced alloc/free counts and stable low peaks.

3. **DB and PAXE examples show zero Lunet allocator counts**
   - `examples/03_db_sqlite3.lua` and `examples/06_paxe_encryption.lua` report `allocs=0 frees=0` in Lunet memory summary.
   - This indicates those paths currently rely mostly on raw `malloc/free` in extension modules (`ext/*`, `src/paxe.c`) instead of `lunet_alloc/lunet_free`.

4. **ASAN + EasyMem dual coverage works**
   - ASAN instrumentation and EasyMem diagnostics are active together in debug builds.
   - No sanitizer failures were observed in the executed stress path.

## Recommendations to Apply More EasyMem Features

To fully exploit EasyMem (especially around DB worker/mutex paths), apply these next:

1. **Migrate extension allocations to Lunet allocator wrappers**
   - Replace direct `malloc/calloc/realloc/free` in `ext/sqlite3/sqlite3.c`, `ext/mysql/mysql.c`, `ext/postgres/postgres.c`, and `src/paxe.c` with Lunet allocator APIs.
   - This makes those modules visible in EasyMem profiling and integrity checks.

2. **Per-operation arenas for DB worker tasks**
   - For each `uv_queue_work` DB operation, create a nested/scratch EasyMem scope.
   - Free the scope at completion boundaries (`after_work` callback), preserving memory neutrality across uv mutex-protected operations.

3. **Driver-local arena policy**
   - Keep long-lived connection structs in a stable root arena.
   - Place query/result temporary buffers in nested/scratch arenas to minimize fragmentation and simplify cleanup on early-error paths.

4. **CI diagnostics artifacts**
   - Capture EasyMem summaries/visualizations from trace+ASAN CI runs as artifacts.
   - Add regression thresholds (e.g., peak usage drift per stress scenario).

## Conclusion

EasyMem is now integrated as an opt-in allocator backend with automatic activation in trace/ASAN modes and an explicit experimental release option. The profiling pipeline is operational, but extension modules must be migrated to Lunet allocator wrappers to realize full allocator diagnostics coverage across database and crypto paths.

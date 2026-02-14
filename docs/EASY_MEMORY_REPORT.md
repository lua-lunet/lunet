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
   - Windows uses `/fsanitize=address` when supported by the toolchain.
3. **Experimental release with EasyMem**
   - `xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n --easy_memory_experimental=y --easy_memory_arena_mb=128 -y`
4. **Manual opt-in**
   - `xmake f -c -m release --lunet_trace=n --lunet_verbose_trace=n --easy_memory=y -y`

## Validation Runs

Logs are archived at:

- `.tmp/logs/20260214_054129/`
- `.tmp/logs/20260214_061022/` (zero-overhead audit)
- `.tmp/logs/20260214_061820/` (post-migration extension allocator build/run validation)

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

3. **Source migration completed for extension allocations**
   - Direct `malloc/calloc/realloc/free/strdup` usage was replaced with Lunet allocator wrappers in:
     - `ext/sqlite3/sqlite3.c`
     - `ext/mysql/mysql.c`
     - `ext/postgres/postgres.c`
     - `src/paxe.c`
   - Build validation passed for all related targets: `lunet-sqlite3`, `lunet-mysql`, `lunet-postgres`, `lunet-paxe`.
   - Note: top-level `lunet-run` memory summary for module-driven examples can still show `allocs=0` because driver modules currently compile their own copy of core allocator state; this requires a shared-core linkage follow-up to aggregate stats in one global state.

4. **ASAN + EasyMem dual coverage works**
   - ASAN instrumentation and EasyMem diagnostics are active together in debug builds.
   - No sanitizer failures were observed in the executed stress path.

## Recommendations to Apply More EasyMem Features

To fully exploit EasyMem (especially around DB worker/mutex paths), apply these next:

1. **Unify allocator state across module boundaries**
   - Current driver modules embed core sources, so allocator counters are per-module.
   - For fully unified profiling/integrity reporting, refactor to share one allocator state (e.g., link driver modules against a shared core allocator/runtime object instead of duplicating `src/lunet_mem.c` in each module target).

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

EasyMem is now integrated as an opt-in allocator backend with automatic activation in trace/ASAN modes and an explicit experimental release option. Extension allocation calls have been migrated to Lunet allocator wrappers in the DB/PAXE code paths. Remaining work is to unify allocator state across shared-module boundaries so all module allocations appear in one consolidated runtime summary.

## Zero-Overhead Verification (Release, EasyMem Disabled)

Audit log set: `.tmp/logs/20260214_061022/`

### Method used

Compared release artifacts across four configurations:

1. default release (`--lunet_trace=n --lunet_verbose_trace=n`)
2. explicit EasyMem-off release (`--easy_memory=n --easy_memory_experimental=n --asan=n`)
3. EasyMem release (`--easy_memory=y`)
4. EasyMem experimental release (`--easy_memory_experimental=y`)

For each, captured:
- `sha256sum` of `lunet-run` and `lunet.so`
- file byte size (`wc -c`)
- section sizes (`size`, text/data/bss)
- dynamic symbol counts (`nm -D --defined-only`)
- dynamic dependencies (`readelf -d` NEEDED entries)

### Result

Default release and explicit EasyMem-off release are **byte-for-byte identical**:
- `lunet-run` hash: `7d7c248d32dfa132a84e850dadafca030c1d75814ba325298c45641f3a7a930b`
- `lunet.so` hash: `ad16fe0cccad4eb41ef7bbc50f21234f6c7b0d9ba44f6d50c7f5d959362125e7`
- same sizes/sections/dependencies
- no EasyMem strings/symbol signatures detected

This confirms **zero accidental release overhead** when EasyMem is disabled.

## Top-Level Artifact Stats When Tracing/Diagnostics Are Enabled

Baseline (release, EasyMem disabled):
- `lunet-run`: 47,248 bytes
- `lunet.so`: 47,968 bytes

EasyMem release (`--easy_memory=y`):
- `lunet-run`: 59,536 bytes (**+12,288**, +26.01%)
- `lunet.so`: 60,384 bytes (**+12,416**, +25.88%)
- Added exported allocator symbol family (`em_*`)

EasyMem experimental diagnostics (`--easy_memory_experimental=y`):
- `lunet-run`: 67,728 bytes (**+20,480**, +43.35%)
- `lunet.so`: 68,608 bytes (**+20,640**, +43.03%)
- Adds diagnostics symbols/output paths including `print_em` and `print_fancy`

No extra shared-library dependencies were introduced in any variant (still `libluajit-5.1`, `libuv`, `libc` on Linux in this audit).

# item19c findings — MySQL parameterised paths under the memory tooling

Date: 2026-07-29. Logs: `.tmp/logs/20260729_223005/item19c/` (ephemeral,
gitignored). Legs were run separately so failures localise; pass criteria were
read from logs (test pass lines, `[MEM_TRACE] SUMMARY` balance, absence of
`ERROR: AddressSanitizer` / `CANARY_FAIL` / `DOUBLE_FREE` / LSAN reports),
never from exit codes alone. All four parameterised-path tests
(`smoke_mysql`, `smoke_mysql_mismatch`, `smoke_mysql_null`,
`smoke_mysql_concurrency`) ran against a live MySQL 8.4.10 server
(`mysql:8.4` container, `--tmpfs /var/lib/mysql`, published on
127.0.0.1:3306; `LUNET_DB_REQUIRED=1` so a connect failure is a hard error).

## Leg results

| Leg | Platform / build | Result | Log-based criteria |
|---|---|---|---|
| 4 parameterised tests | macOS 26.5.2 arm64, debug `LUNET_TRACE=ON` + EasyMem (lunet_mem canary + poison-on-free active) | all pass | per test: `=== All ... passed ===`, `All coroutine references properly balanced.`, `[MEM_TRACE] SUMMARY` allocs==frees, no `CANARY_FAIL`/`DOUBLE_FREE`/`LEAK at`, EasyMem arena `EM occupied data size: 0` at shutdown |
| 4 tests × LSAN raw (no suppressions) | Debian trixie arm64 container, debug + ASan + EasyMem + trace | all pass, **exit 0 — zero leaked allocations** | no `SUMMARY: AddressSanitizer`, no `leaked in` line (LSAN prints a report and exits 23 when it sees anything; it saw nothing) |
| 4 tests × LSAN with `test/lsan_suppressions.txt` | same | all pass, exit 0 | same; suppressions had nothing to suppress |
| `ci_easy_memory_db_stress` (preflight step 06 recipe, `detect_leaks=0`, 20 ops) | same | pass | `[EASYMEM_CI] lunet.mysql probe completed (20 ops)`, `completed successfully`, no ASan output |
| `ci_easy_memory_lsan_regression` (CI recipe, `exitcode=23`, 10 iterations, **live server**) | same | pass, exit 0 | `[EASYMEM_LSAN] mysql probe completed (10 iterations)`, `probe completed successfully`, no LSAN report — see baseline below |
| LSAN positive control | same build | **fires** | deliberate `ffi.C.malloc(4096)` → exit 23, `Direct leak of 4096 byte(s) in 1 object(s)` — the detector is live in this exact binary |
| Defective-driver negative control (pre-item19d `mysql.c` relinked into `lunet/mysql.so`) | same build | **zero memory-tooling signal** | see finding F2 |
| ASan | macOS | not run — the documented dyld-hang environmental issue (AGENTS.md); ASan legs verified on Linux per the spec | — |

Note on per-module counters: the driver `.so` links its own private copies of
the `lunet_mem` / trace state on both platforms, so the runner-printed
`[MEM_TRACE] SUMMARY` counts runner-side allocations only (0–2, balanced).
Driver-side accounting is part of finding F2.

## Empirical leak baseline and the "exactly 4 allocations" figure

**Measured baseline on this platform: 0 leaked allocations, raw and
suppressed alike, across all four parameterised tests and the CI LSAN
regression script — including the 300-iteration deliberate-mismatch error
loop and the 6-coroutine contended batch.**

Provenance: Debian GNU/Linux 13 (trixie) arm64 container (colima VM, kernel
6.8.0-100-generic), gcc 14.2.0, libasan8 14.2.0-19, **libmariadb-dev
1:11.8.6-0+deb13u1** (Debian `default-libmysqlclient-dev` 1.1.1 — the same
package family CI installs on ubuntu-latest), LuaJIT
2.1.0+openresty20250117-2, libuv 1.50.0-2, xmake 3.0.8, MySQL server 8.4.10.
macOS leg provenance (correctness + trace/EasyMem only): macOS 26.5.2
(25F84) arm64, Xcode 26.1 clang 17.0.0, Homebrew **mysql-client 9.7.1**
(Oracle client, libmysqlclient.24.dylib), libuv 1.52.1, LuaJIT
2.1.1785005726.

**Does "exactly 4 allocations" still hold?** It is not contradicted, but it
is not what this platform measures. The workflow's LSAN step asserts `rc==23
→ allocs==4`; here every run (including the CI recipe with a live server,
which CI normally lacks — its mysql probe only exercises failed connects)
exits 0 with no LSAN report at all. Two things follow:

1. The new parameterised-path coverage adds **nothing** to the leak count:
   the figure did not grow from the known client-runtime overhead — it is 0
   here, and would still be bounded by the `==4` ceiling on the platforms
   where that overhead appears. The allowance absorbs no new leak from
   items 17–19b.
2. On trixie + libmariadb 11.8.6 the client runtime leaves **no**
   LSAN-visible residue (the driver's last `db.close` runs
   `mysql_library_end`, which releases the one-time allocations), so the
   exact-4 assertion's `rc==23` branch simply never triggers. Any future
   non-zero count on this platform is therefore pure signal, not noise.

**Suppressions added: none.** The existing named suppressions in
`test/lsan_suppressions.txt` (`leak:libstdc++`, `leak:libmysqlclient`,
`leak:libmariadb`) already name the only legitimate excuse (client C++
runtime one-time allocations); with the measured baseline at 0 they
currently suppress nothing, and no new allowance is warranted. Leak
detection stays fully enabled everywhere; no blanket `detect_leaks=0` was
used for any of the four parameterised tests.

## Findings (reported, not fixed)

- **F1 — nested-checkout build trap (operational, critical).** This repo is
  a git worktree at `/Users/Shared/lua-lunet/lunet/paxe` inside another
  lunet checkout. Plain `xmake build`/`xmake f` from this directory resolves
  `os.projectdir()` to the **parent** (`/Users/Shared/lua-lunet/lunet`)
  while keeping this repo's build directory, silently compiling the
  *parent's* `ext/mysql/mysql.c` (pre-item19d) and parent core sources into
  `paxe/build/`. Verified via object DWARF (compile CWD = parent) and a
  missing `_lunet_memdup_local` symbol in the freshly built `mysql.so`.
  `xmake -P . …` resolves the project correctly (verified). Consequences:
  the first set of legs run here was invalid and initially surfaced as a
  phantom "fresh builds truncate binary reads at NUL" bug — that failure was
  the *parent's* pre-item19d driver, not this branch. The polluted build
  tree was soft-deleted to `.tmp/build.parent-polluted.20260729_223005/`
  and every leg was rebuilt with `-P` and re-verified (symbol check +
  depfile paths) before use. Any automation driving xmake in this checkout
  must use `-P .`; task invocations such as `xmake lint` execute with the
  caller's working directory and lint the correct tree either way.
- **F2 — the instrumented profile cannot see driver-side leaks (the item's
  core finding).** Three compounding facts, each verified:
  (a) `lunet-mysql.so` statically links `core_sources`, so it carries
  private copies of `lunet_mem_state` / the trace counters; the shutdown
  reporters (`lunet_mem_summary`, `lunet_mem_assert_balanced`,
  `lunet_trace_assert_balanced`) run only inside the runner binary — the
  module's alloc/free and coref balances are never summarised or asserted
  (observed: module prints `COREF_ADD … total_created=4`, runner summary
  reports `Total created: 0`).
  (b) With any instrumented profile (`--lunet_trace=y` or `--asan=y` or
  `--easy_memory=y` all force `LUNET_EASY_MEMORY` on), `lunet_alloc` in the
  driver resolves into the module-private EasyMem **arena**; LSAN/ASan track
  malloc, not arena sub-allocations, so a leaked driver block is invisible
  to them — and `em_destroy()` performs no live-block audit (reads the
  arena wholesale; verified in `easy_memory.h` 2026.02.14).
  (c) Negative control: the pre-item19d `mysql.c` (the bind-lifetime defect
  this item's spec describes: bind array freed while installed in the
  statement handle across the rebind window) was relinked into
  `lunet/mysql.so` and run under the full ASan+EasyMem+trace+LSAN profile —
  `smoke_mysql` and `smoke_mysql_mismatch` (300 error-path iterations)
  produced **no ASan report, no LSAN report, no canary/double-free, no
  balance assertion**; the only signal anywhere was item19d's *correctness*
  assertion (embedded-NUL round-trip) failing, because the old driver also
  truncates binary reads. The LSAN positive control in the same binary
  fires correctly (deliberate 4096-byte malloc → exit 23), so this silence
  is not a dead detector.
  What does cover the driver today: per-allocation canary + double-free
  checks and poison-on-free (in-module, active in every trace/EasyMem
  build), and test-level invariants (unique per-coroutine answers,
  connection-usable-after-error-paths, server-side statement-handle
  pressure from the 300-iteration loop). Closing the residue — e.g.
  module-side shutdown reporting or shared mem/trace state via interposed
  symbols, an arena-free profile that makes driver allocations
  LSAN-visible, or an `em_destroy` occupancy audit — is follow-up work
  beyond this verification item.
- **F3 — environmental: VM disk exhaustion masquerading as test failures.**
  The colima VM hit 100 % disk during the container build; subsequent
  InnoDB `CREATE TABLE` calls failed with `disk is full`, which the tests
  correctly reported as FAILs (the failure mode looked like a product
  regression until `mysql_stmt_error` was read). Only dangling docker
  layers were pruned (386 MB); the MySQL container was recreated with
  `--tmpfs /var/lib/mysql` (memory-backed, disposable test data) and all
  legs re-run green. No user/agent data was touched.
- macOS ASan dyld hang: not re-tested beyond the documented behaviour; the
  ASan legs were verified on Linux as the spec directs.

## Repro index (logs under `.tmp/logs/20260729_223005/item19c/`)

- `macos2_trace_easymem_smoke_mysql*.log` — 4 tests, macOS trace+EasyMem.
- `linux_05_asan_lsan_legs.log` — provenance + 4 tests × {raw, suppressed}
  LSAN + db stress + LSAN regression ×2.
- `linux_06_negative_controls.log` — LSAN positive control + defective-driver
  control. Probe/verification harness: `.tmp/item19c/` (Dockerfile, runner,
  probe sources; ephemeral).
- `macos2_04_lint.log` — `lua bin/lint_c_safety.lua` and `xmake lint`, both
  pass; the `lunet.c_safety_lint` build rule also passed inside every
  `-P`-anchored build used above.

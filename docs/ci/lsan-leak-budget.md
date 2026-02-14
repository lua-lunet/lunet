## LeakSanitizer (LSAN) budget in EasyMem QA

### Why this exists

In GitHub Actions **EasyMem QA** runs, we build with AddressSanitizer enabled and run a small regression probe (`test/ci_easy_memory_lsan_regression.lua`).

On some CI images, simply loading the MySQL client library (via `require("lunet.mysql")`) can trigger a small number of **one-time allocations in the C++ runtime / client library initialization path**. LeakSanitizer may report these allocations at process exit even when lunet shuts down cleanly and calls `mysql_library_end()`.

These allocations:
- are **not made by lunet** (the CI backtraces land in `libstdc++` / `libmysqlclient`)
- are **environment-dependent** (may reproduce in CI but not locally)
- are typically **stable in count**

### What we enforce

We do **not** blanket-disable LeakSanitizer.

Instead, we:
- run the LSAN regression with `LSAN_OPTIONS=exitcode=0` so the process output is available even if LSAN reports leaks
- parse the log and enforce a strict budget via `test/ci_lsan_leak_budget.lua`

Default policy:
- **Pass** if leak allocations are \(0\)
- **Pass** if leak allocations are exactly **4**
- **Fail** otherwise

The budget is configurable with:
- `LSAN_LEAK_BUDGET_ALLOCS` (default: `4`)

### Where it runs

- `.github/workflows/build.yml` (EasyMem QA)
- `.github/workflows/examples-test.yml` (Examples Test)
- `xmake preflight-easy-memory` (local developer repro)

### Notes on suppressions

There is a `test/lsan_suppressions.txt` file in the repo as a last-resort tool for narrowing down noisy third-party allocations, but the CI gate is implemented as a **budget check** so we don’t accidentally hide real lunet leaks.


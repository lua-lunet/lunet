# item15 findings — PAXE under LUNET_TRACE and the memory tooling

Date: 2026-07-29. Logs: `.tmp/logs/20260729_102204/` (ephemeral, gitignored).
Legs were run separately so failures localise; pass criteria were read from
logs, not exit codes. Because lunet's `os.exit` is the stock C `exit()` and
bypasses `lunet_runtime_shutdown()` (where the trace summary is printed),
the smoke/e2e trace legs ran via `.tmp/item15/wrap_*.lua` shims that
neutralise `os.exit` (logging the intended code) so the loop drains and the
instrumented shutdown path runs. The pristine release e2e ran via
`test/run_paxe_udp_e2e.sh` unmodified.

## Leg results

| Leg | Platform / build | Result | Log-based criteria |
|---|---|---|---|
| cargo test | macOS debug + release, Linux debug + release | 86/86 pass ×4 | `test result: ok. 86 passed; 0 failed` |
| busted spec/paxe_spec.lua | macOS (Homebrew LuaJIT 2.1.1785005726) | 43 successes, 0 failures | busted summary |
| busted spec/paxe_spec.lua | Linux (Debian LuaJIT 2.1.1737090214) | **parse error, 0 checks run** — finding F1 | `')' expected near '~'` at line 487 |
| smoke | macOS release | 67/67 checks | `=== All paxe smoke checks passed (67 checks) ===` |
| smoke | macOS trace (LUNET_TRACE=ON) | 67/67 + clean shutdown | coref balance 0, `All coroutine references properly balanced.`, allocs==frees==0, no `[TRACE] WARNING`, no assertion, exactly 2 `[PAXE] drop:` stderr lines (same as release — policy-output prefix assertions do not invert between build modes) |
| smoke | Linux ASan+EasyMem+trace | **parse error before any check** — finding F1 | `test/smoke_paxe.lua:166: ')' expected near '~'`; the C runtime still shut down clean (coref 0/0) |
| UDP e2e | macOS release (pristine driver) | receiver 83/83, sender 33/33 | verdict file `PASS`, no FAIL lines |
| UDP e2e | macOS trace | receiver 83/83, sender 33/33 | receiver coref 16/16 balance 0, allocs==frees==136; sender coref 18/18 balance 0, allocs==frees==76; no warnings/assertions/LEAK lines; UDP summary receiver binds=6 tx=6 rx=27, sender binds=6 tx=23 |
| UDP e2e | Linux ASan+EasyMem+trace | receiver 86/86, sender 33/33 | receiver allocs==frees==138, sender 76/76, coref balance 0 both, no AddressSanitizer output. 86 vs 83 receiver checks vs macOS is the *documented* macOS loopback EMSGSIZE platform-skip of the 65507-byte wire leg, not a divergence |
| EasyMem | macOS + Linux (active in every trace build: `lunet_easy_memory_enabled()` includes `lunet_trace`) | arena enabled, diagnostics on, zero imbalance | `[MEM_TRACE] EASY_MEMORY: enabled arena=134217728 bytes diagnostics=on` |
| ASan | Linux (libasan8, Debian trixie arm64) | all above Linux legs clean | no `ERROR: AddressSanitizer` anywhere; LSAN positive control fired (below) |
| ASan | macOS 26.5.2 | **dyld hang, reconfirmed** — documented environmental issue, not a failure | `timeout 30` → exit 124, zero output, hello-world script; binary verified instrumented (`libclang_rt.asan_osx_dynamic.dylib` linked) |

## libsodium / guarded-allocation leak baseline

**Baseline: 0 residual allocations, 0 bytes. No suppression added to
`test/lsan_suppressions.txt`; detection stays fully enabled.**

Evidence (Debian trixie arm64 container, lunet debug+ASan+EasyMem+trace,
symbolized and stripped cdylib variants both linked against the static
source-built libsodium):

- LSAN proven active: a deliberate `ffi.C.malloc(4096)` leak is caught —
  exit 23, `Direct leak of 4096 byte(s) in 1 object(s)`.
- `paxe load + init + shutdown` under LSAN (`exitcode=23`): exit 0, no report.
- Keystore lifecycle (32 epochs installed/retired/cleared twice over) under
  LSAN: exit 0, no report. `sodium_malloc` is page-granular `mmap` + guard
  pages, so guarded allocations are outside the malloc interceptor by
  design; libsodium 1.0.22 init leaves no LSAN-visible residue.
- Provenance: macOS 26.5.2 (25F84) arm64, Homebrew libsodium 1.0.22,
  libuv 1.52.1, LuaJIT 2.1.1785005726, clang Xcode 26.1 SDK, cargo 1.96.0.
  Linux: Debian GNU/Linux 13 (trixie) arm64 container (colima VM, kernel
  6.8.0-100-generic), libsodium 1.0.22 built from source
  (sha256 adbdd8f1…be3349; `--disable-shared --enable-static`), gcc 14.2.0,
  LuaJIT 2.1.1737090214, cargo 1.85.0, libasan8. The *distro* trixie
  libsodium is 1.0.18 and reports `crypto_aead_aes256gcm_is_available()=0`
  (the documented skip case); the source build reports 1, so the Linux
  crypto legs genuinely executed.

## Trace vs release diff

No divergence. Every suite that passes in one build mode passes in the
other with identical check counts (smoke 67/67 both; e2e 83+33 macOS both;
cargo 86/86 both profiles; busted is build-mode independent). The only
cross-platform count difference (e2e receiver 83 macOS vs 86 Linux) is the
pre-existing documented macOS loopback max-datagram platform-skip.

## panic=abort erasure question — concrete answer

Construction tested: exactly the `keystore.rs` one — key bytes in a
`sodium_malloc` guarded allocation with explicit `sodium_mlock`, then
`abort()` with no destructors run (`panic = "abort"`). Cores/memory
inspected for a 32-byte key pattern plus a normal-heap control pattern.

- **Linux: key material is NOT recoverable from the core.**
  `/proc/self/smaps` for the guarded VMA shows `VmFlags: rd wr mr mw me lo
  ac dd` — both `lo` (mlocked) and `dd` (`MADV_DONTDUMP`, set by libsodium's
  `sodium_mlock`). Kernel core after abort (real ELF core via
  `core_pattern`): control pattern found (1 occurrence — detection works),
  guarded key pattern found **0 times**. Through the real crate FFI path
  (`keystore_set`, drop the Lua ref, 2× GC, abort): exactly **1**
  occurrence — the transient LuaJIT-heap remnant of the interned key
  string, not the keystore copy. Conclusion: on Linux the erasure guarantee
  under abort rests on `sodium_mlock`→`MADV_DONTDUMP` and it holds.
- **macOS: key material IS recoverable. Defect — finding F2.**
  At the SIGABRT stop (lldb, mechanism probe): control pattern present,
  **guarded key pattern fully present and readable** in the mlocked pages
  (both adjacent guard pages verified unreadable — a genuine libsodium
  guarded region). FFI path: 2 occurrences — the keystore copy
  (end-of-page placement in a 16 KB region, classic `sodium_malloc` layout)
  plus the LuaJIT remnant. Darwin has no `MADV_DONTDUMP` equivalent and
  `mlock` does not exclude pages from core dumps, so the keystore.rs claim
  "locked pages are excluded from core dumps and never reach swap" holds
  only for Linux. On macOS the abort-time guarantee reduces to "swap
  avoidance", not "core-dump exclusion".

## Findings (reported, not fixed)

- **F1 — test-file portability defect (blocked Linux busted + smoke
  legs).** `spec/paxe_spec.lua` (lines 487, 516, 542, 560) and
  `test/smoke_paxe.lua` (line 166) use the Lua 5.3 `~` operator. Homebrew
  LuaJIT 2.1.1785005726 parses it; Debian trixie LuaJIT 2.1.1737090214
  rejects it at parse time (`loadstring("return 1 ~ 1")` → nil,
  `'<eof>' expected near '~'`). The legs fail identically in every build
  mode (parse-time, pre-runtime), so this is not a trace/release
  divergence — but `xmake test` runs `busted spec/` and the trixie gate
  (`docker/gate.sh`) runs it on the older LuaJIT, so the spec currently
  cannot pass in that environment.
- **F2 — macOS core-dump erasure defect (above).** After an abort with no
  destructors, keystore key material is present in dumpable memory on
  macOS; `sodium_mlock` does not prevent it there (no `MADV_DONTDUMP` on
  Darwin). The Linux guarantee is intact. Candidate for a suffixed item
  (e.g. item15a): either document the platform limit in keystore.rs's
  load-bearing comment or add a Darwin mitigation.
- **F3 — operational gotcha (build tool, not product).** Switching only
  `--asan` within the same mode directory did not trigger recompilation
  (`xmake build` reported success in 0.17 s reusing non-ASan objects; the
  flags were in the config but objects were considered fresh). `xmake
  build -r` forced it. Verify instrumentation with `otool -L` /
  `nm | grep -i asan` after any asan toggle.
- macOS ASan dyld hang reconfirmed on 26.5.2 (exit 124, zero output) —
  the documented environmental issue; the ASan legs were verified on Linux
  instead, as specified.

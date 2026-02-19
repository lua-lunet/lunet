# EASYMEM_HTTP_C

## Scope
This document is a lossless reconstruction of:
- what was asked
- what sources you pointed to
- what those sources said
- what Context7/Tavily returned
- what plan/design was formed
- what was implemented in `httpc.c`
- how errors and limits are handled
- build settings/macros/`.so` wiring
- additional germane concerns
- open questions and future lines of investigation

Date context: 2026-02-18.

## 1) What You Asked
You asked for an explicit, measurable, non-guessy design around `lunet.httpc` + EasyMem, with focus on:
- prove behavior with benchmarks and concrete counters/cost
- remove shim path and use pure Lunet macro allocation path
- test EasyMem as baseline and then worker-oriented strategy
- handle hostile/unbounded libcurl responses safely
- make limits explicit (`max_body_bytes`, headers caps, etc.) and enforced in callbacks, not only in libcurl hints
- align limits with application-level API limits (specifically Fastmail/JMAP)
- document architecture/design clearly with diagrams

You also requested:
- component diagram
- sequence diagram
- explicit error handling map
- build options/macros/flags and `.so` target behavior
- which structures/functions/junctions changed
- appendix for open questions/future directions

## 2) User-Provided Sources To Use
Sources explicitly called out by you:
- `docs/XMAKE_INTEGRATION.md`
- `docs/SECURITY_ARCHITECTURE.md`
- EasyMem maintainer guidance (the long quoted comment)
- EasyMem repo positioning:
  - lock-free/single-threaded philosophy
  - TLS pattern: one EM instance per thread
  - source-agnostic API for static/dynamic/nested
  - optional visual debugging (`print_fancy`)
- Lunet-related demo repos for scenario testing:
  - `lunet`
  - `lunet-mcp-sse`
  - `lunet-realworld-example-app`
  - `lunet-backproxy`

### 2.1 What Those Sources Said (as provided by you)
From your EasyMem maintainer quote and notes:
- Three concurrency models were proposed:
  - hierarchical nested from global arena
  - hybrid with parent mutex around nested create/destroy
  - pragmatic recommended: worker-local independent `em_create(size)`; allocate freely; `em_destroy` at end
- Incremental usage levels:
  - Level 1: normal `em_alloc`/`em_free`
  - Level 2: fast-quit (`em_destroy` instead of per-object free)
  - Level 3: bump allocator for short-lived O(1) pointer-advance allocations
  - Level 4/5: scratch/split-heap advanced strategies
- OS demand paging note: large virtual reservations do not fully commit RAM until pages are touched.

From your Lunet architecture framing:
- system commonly links LuaJIT/libuv as distro-shipped `.so`/`.dll` (not rebuilt with EasyMem by default)
- main EasyMem opportunity is Lunet-owned C modules (db/httpc/etc), especially uv worker callbacks with clear lifecycle boundaries
- httpc/libcurl path is high-risk for unbounded network payload behavior, so hard caps are mandatory

## 3) External Findings (Context7 + Tavily)

## 3.1 libuv (Context7 + docs)
Key confirmed points:
- `uv_queue_work(loop, req, work_cb, after_work_cb)`:
  - `work_cb` runs on libuv threadpool
  - `after_work_cb` runs back on loop thread
- libuv exposes TLS key API (`uv_key_create`) for thread-local association patterns.
- Threadpool is global/shared; default size is 4; configurable via `UV_THREADPOOL_SIZE` (max 1024 in modern libuv).

References:
- https://github.com/libuv/libuv/blob/v1.x/docs/src/threadpool.rst
- https://github.com/libuv/libuv/blob/v1.x/docs/src/threading.rst
- https://docs.libuv.org/en/v1.x/threadpool.html

## 3.2 libcurl response-size control (Tavily: curl docs)
Key confirmed points:
- `CURLOPT_MAXFILESIZE_LARGE` is helpful but not sufficient as sole defense when size is unknown at start.
- Application must enforce byte limits in write/progress callbacks and abort on threshold.
- write callback abort semantics are explicit: returning short/`CURL_WRITEFUNC_ERROR` aborts transfer.

References:
- https://curl.se/libcurl/c/CURLOPT_MAXFILESIZE_LARGE.html
- https://curl.se/libcurl/c/CURLOPT_WRITEFUNCTION.html
- https://everything.curl.dev/transfers/callbacks/write.html

## 3.3 JMAP/Fastmail size-limit relevance (Tavily)
Key findings:
- JMAP Session advertises capability limits such as `maxSizeRequest`, `maxSizeUpload`, `maxCallsInRequest`.
- Fastmail docs also describe account/file transfer limits.
- design implication: `httpc` transport caps should be configured to be >= expected JMAP response/request envelopes, but still bounded.

References:
- https://www.fastmail.com/blog/how-and-why-we-built-masked-email-with-jmap-an-open-api-standard/
- https://jmap.io/
- https://www.fastmail.help/hc/en-us/articles/1500000277382-Account-limits

## 4) Plan That Was Formed
1. Remove shim path and keep pure Lunet allocator path.
2. Add strict explicit transport limits in `httpc`:
   - body bytes cap
   - header bytes cap
   - header lines cap
   - redirect/protocol/timeouts/low-speed controls
3. Enforce limits both:
   - libcurl option layer
   - callback-time hard checks
4. Add worker-local EasyMem mode in `httpc` (optional):
   - per-request EM + bump
   - free becomes no-op within request allocator scope
   - one destroy at request teardown
5. Benchmark matrix across baseline/EasyMem/experimental/worker variants.
6. Add smoke tests for limit behavior.
7. Document architecture and decisions.

## 5) Candidate Design (Current)

### 5.1 Memory model in `lunet.httpc`
- Default path:
  - `httpc` allocations route via Lunet wrappers (`lunet_alloc/lunet_realloc/lunet_free_nonnull`).
- Optional worker-local mode (`LUNET_HTTPC_WORKER_EM`):
  - request gets `EM *req_em` + `Bump *req_bump`
  - allocations done via bump allocator
  - per-object free becomes no-op
  - teardown destroys bump/EM once

### 5.2 Limit model in `lunet.httpc`
Explicit options parsed and validated:
- `timeout_ms`
- `connect_timeout_ms`
- `max_body_bytes`
- `max_header_bytes`
- `max_header_lines`
- `follow_redirects`
- `max_redirects`
- `low_speed_limit_bps`
- `low_speed_time_sec`
- `allow_file_protocol`
- `insecure`

Enforcement points:
- URL scheme gate before libcurl (`http/https`, optional `file`)
- header callback:
  - hard cap total header bytes
  - hard cap number of header lines
- body write callback:
  - hard cap cumulative bytes
- progress callback (`CURLOPT_XFERINFOFUNCTION` when available):
  - stop if `dlnow` exceeds `max_body_bytes`

## 6) Component Diagram
```mermaid
flowchart LR
    LUA[Lua Coroutine\nlunet.spawn] --> API[require('lunet.httpc')\nhttpc.request(opts)]
    API --> PARSE[Option Validation\nscheme/limits/types]
    PARSE --> QW[uv_queue_work]
    QW --> WCB[httpc_work_cb\nlibuv worker thread]
    WCB --> CURL[libcurl easy handle]
    CURL --> NET[Remote API\n(JMAP/HTTPS/etc)]
    CURL --> HCB[Header Callback\nmax_header_bytes/max_header_lines]
    CURL --> BCB[Write Callback\nmax_body_bytes]
    CURL --> PCB[Progress Callback\n(optional)]
    WCB --> ACB[httpc_after_cb\nloop thread]
    ACB --> LUA

    subgraph ALLOC[Allocator backend for httpc request]
      A1[Lunet alloc wrappers]
      A2[Optional request-local EasyMem\nEM + Bump]
    end

    PARSE --> A1
    PARSE --> A2
    HCB --> A1
    HCB --> A2
    BCB --> A1
    BCB --> A2
```

## 7) Sequence Diagram
```mermaid
sequenceDiagram
    participant Co as Lua Coroutine
    participant H as lunet.httpc C API
    participant Loop as libuv Loop Thread
    participant WP as libuv Worker Thread
    participant C as libcurl
    participant S as Remote Server

    Co->>H: httpc.request(opts)
    H->>H: validate opts + scheme + limits
    alt invalid opts/scheme
        H-->>Co: nil, err
    else valid
        H->>Loop: uv_queue_work(req)
        Loop->>WP: work_cb(req)
        WP->>C: curl_easy_perform()
        C->>S: HTTP request
        S-->>C: headers/body chunks
        C->>WP: header callback(s)
        WP->>WP: enforce header caps
        C->>WP: write callback(s)
        WP->>WP: enforce body cap
        alt any cap exceeded / callback error
            WP->>WP: set ctx->err, abort transfer
        end
        WP-->>Loop: after_work_cb(req)
        Loop->>H: build Lua response or error
        H-->>Co: resp,nil OR nil,err
        H->>H: teardown allocations (single destroy in worker-EM mode)
    end
```

## 8) Error Handling Design

| Stage | Condition | Behavior | Returned to Lua |
|---|---|---|---|
| Option parse | wrong type/range | immediate reject | `nil, "<field> ..."` |
| URL gate | scheme not allowed | immediate reject | `nil, "url scheme not allowed ..."` |
| Allocator init | OOM / insufficient sizing | immediate reject | `nil, "out of memory"` or explicit allocator message |
| Header callback | bytes exceed cap | abort transfer | `nil, "response headers exceed max_header_bytes (...)"` |
| Header callback | lines exceed cap | abort transfer | `nil, "response headers exceed max_header_lines (...)"` |
| Write callback | body exceeds cap | abort transfer | `nil, "response body exceeds max_body_bytes (...)"` |
| Progress callback | download exceeds cap | abort transfer | same `max_body_bytes` message |
| libcurl | network/protocol error | report curl error string | `nil, curl_easy_strerror(rc)` |
| uv queue | `uv_queue_work` fail | immediate reject | `nil, uv_strerror(rc)` |
| Success | all checks pass | build response table | `resp, nil` |

## 9) Build Settings, Macros, `.so`, Flags

### 9.1 xmake options
Relevant options in `xmake.lua`:
- `--easy_memory=[y|n]`
- `--easy_memory_experimental=[y|n]`
- `--easy_memory_arena_mb=<n>`
- `--httpc_worker_easy_memory=[y|n]`
- `--httpc_worker_easy_memory_arena_kb=<n>`
- `--httpc_worker_easy_memory_bump_kb=<n>`

### 9.2 Core defines
From `lunet_apply_easy_memory()`:
- `LUNET_EASY_MEMORY`
- `LUNET_EASY_MEMORY_ARENA_BYTES=<...>`
- `LUNET_EASY_MEMORY_DIAGNOSTICS` (when diagnostics mode on)

For `httpc` worker-local mode (intended):
- `LUNET_HTTPC_WORKER_EM`
- `LUNET_HTTPC_WORKER_EM_ARENA_BYTES=<...>`
- `LUNET_HTTPC_WORKER_EM_BUMP_BYTES=<...>`

In `ext/httpc/httpc.c` defaults:
- `LUNET_HTTPC_WORKER_EM_ARENA_BYTES` default 1 MiB
- `LUNET_HTTPC_WORKER_EM_BUMP_BYTES` default 768 KiB
- `LUNET_HTTPC_WORKER_EM_META_BYTES` default 64 KiB

### 9.3 `.so` artifact
Target:
- `target("lunet-httpc")`

Output:
- `build/<platform>/<arch>/<mode>/lunet/httpc.so` (`.dll` on Windows)

### 9.4 Observed compile/link flags (release sample)
Observed in logged compile lines:
- `-O3 -std=c99 -fPIC`
- `-DLUNET_NO_MAIN -DLUNET_HTTPC`
- EasyMem flags when enabled:
  - `-DLUNET_EASY_MEMORY`
  - `-DLUNET_EASY_MEMORY_ARENA_BYTES=...`
- linked with `-lcurl`, plus luajit/libuv/system libs

## 10) Data Structures / Functions / Junctions Added or Amended

### 10.1 `httpc_req_t` additions
Added fields:
- transport controls:
  - `connect_timeout_ms`
  - `low_speed_limit_bps`
  - `low_speed_time_sec`
  - `max_redirects`
  - `max_header_bytes`
  - `max_header_lines`
  - `header_bytes`
  - `follow_redirects`
  - `allow_file_protocol`
- worker EasyMem fields (guarded):
  - `EM *req_em`
  - `Bump *req_bump`
  - `size_t req_em_required_bytes`

### 10.2 New/changed helper functions
Added:
- `httpc_size_add`, `httpc_size_mul` (overflow-safe arithmetic)
- `httpc_worker_em_required_bytes` (required budget computation)
- `httpc_opt_long`, `httpc_opt_size`, `httpc_opt_bool` (strict option parsing)
- `httpc_ascii_ieq_n`, `httpc_url_scheme_allowed` (scheme gate)
- `httpc_xferinfo_cb` (progress cap)

Changed:
- `httpc_req_allocator_init` now receives error buffer and checks explicit sizing
- callbacks now enforce hard caps with explicit error strings
- `httpc_parse_headers` now uses temporary `lunet_alloc` for header-line assembly before `curl_slist_append`

### 10.3 Junctions amended
Request entrypoint (`httpc_request`):
- stricter opts validation and defaults
- scheme allow-list check
- optional worker-EM required-size calculation before allocator init

Worker callback (`httpc_work_cb`):
- added curl hardening options:
  - `CURLOPT_NOSIGNAL`
  - `CURLOPT_FOLLOWLOCATION`
  - `CURLOPT_MAXREDIRS`
  - `CURLOPT_TIMEOUT_MS`
  - `CURLOPT_CONNECTTIMEOUT_MS`
  - `CURLOPT_LOW_SPEED_LIMIT/TIME`
  - `CURLOPT_MAXFILESIZE_LARGE` (if available)
  - `CURLOPT_PROTOCOLS_STR`/`CURLOPT_PROTOCOLS` (if available)
  - `CURLOPT_REDIR_PROTOCOLS_STR`/`CURLOPT_REDIR_PROTOCOLS` (if available)
  - `CURLOPT_XFERINFOFUNCTION`/`CURLOPT_XFERINFODATA` (if available)

Header/body callbacks:
- enforce limit breaches and abort

## 11) Bench + Validation Results

Benchmark matrix log:
- `.tmp/logs/20260218_214733/httpc_alloc_matrix`

Results (`requests=400`, body `256 KiB`):
- baseline: `elapsed_wall_s=0.034389`
- easy_memory: `0.043024` (`+25.11%` vs baseline)
- easy_memory_experimental: `0.053133` (`+54.51%`)
- easy_memory_worker: `0.040033` (`+16.41%`)
- easy_memory_experimental_worker: `0.050923` (`+48.08%`)

All profiles completed with:
- `ok=400 fail=0`

Limit smoke:
- initial run showed `file://` still accepted in one path
- after explicit scheme gate, rerun passed:
  - `.tmp/logs/20260218_214545/httpc_limits/07_httpc_limit_smoke_rerun.log`

## 12) Additional Germane Points You Had Not Explicitly Asked But Matter
- JMAP session-driven caps:
  - at startup, fetch JMAP Session and derive safe transport defaults from `maxSizeRequest` and related capability fields.
- Compression risk:
  - `CURLOPT_ACCEPT_ENCODING=""` enables compressed transfer; cap enforcement is on delivered bytes, but policy should be explicit for compressed-vs-uncompressed expectations.
- Redirect policy:
  - for API clients, defaulting to low `max_redirects` and optionally disabling redirects can reduce abuse surface.
- Threadpool contention:
  - `uv_queue_work` shares global pool with fs/dns; heavy `httpc` load can starve unrelated pool tasks.
- Memory budgeting:
  - separate budgets for:
    - transport body/header
    - JSON parse structures in Lua
    - app-level object graphs
  - transport cap alone is necessary but not sufficient for full memory safety.
- API-specific envelopes:
  - Fastmail/JMAP limits should be reflected at both:
    - application semantic layer (request batching, object limits)
    - transport layer (`httpc` caps).

## Appendix A: Open Questions
- Should worker-local EasyMem scope be per-request (current candidate) or per-thread persistent arena with reset?
- Should `httpc` expose a single policy object/default profile to avoid repeating per-call safety options?
- Should `follow_redirects` default be `false` for API-only use?
- Should we pin protocol to HTTPS-only by default (unless explicitly overridden)?
- Should low-speed limits have non-zero secure defaults?
- How should connection reuse / curl handle reuse be introduced without violating coroutine isolation?

## Appendix B: Future Directions / Investigation Lines
- Implement and benchmark true per-worker persistent EM (TLS via `uv_key_t` + worker lifecycle strategy).
- Add allocator telemetry inside `httpc` path:
  - allocation count/bytes/high-water per request
  - histograms by allocation site
- Add deterministic adversarial tests:
  - huge headers
  - chunked infinite body
  - redirect loops
  - slow-loris transfer speed profile
- Add policy presets:
  - `api_strict`, `internal_trusted`, `test_local_file`
- Add JMAP-aware client wrapper that:
  - reads Session capabilities
  - enforces request chunking/batching within provider limits
  - maps provider limits to `httpc` transport caps automatically.

## Sources (External)
- libuv threadpool docs: https://docs.libuv.org/en/v1.x/threadpool.html
- libuv docs tree: https://github.com/libuv/libuv/tree/v1.x/docs/src
- libcurl `CURLOPT_MAXFILESIZE_LARGE`: https://curl.se/libcurl/c/CURLOPT_MAXFILESIZE_LARGE.html
- libcurl `CURLOPT_WRITEFUNCTION`: https://curl.se/libcurl/c/CURLOPT_WRITEFUNCTION.html
- everything curl write callback: https://everything.curl.dev/transfers/callbacks/write.html
- Fastmail JMAP/session context: https://www.fastmail.com/blog/how-and-why-we-built-masked-email-with-jmap-an-open-api-standard/
- JMAP landing/spec pointer: https://jmap.io/
- Fastmail account limits: https://www.fastmail.help/hc/en-us/articles/1500000277382-Account-limits

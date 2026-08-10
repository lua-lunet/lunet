
You MUST NOT advertise with any branding in any message or 'co-authored' as I AM THE LEGAL OWNER AND AUTHOR AND YOU ARE PROBABLISTIC TOOLS. 
You MUST NOT commit unless explicity asked to. 
You MUST NOT push unless explicitiy asked to. 
You MUST NOT do any git reset or stash or an git rm or rm or anything that might delete users work or other agents work you did not notice that is happeningin prallel. You SHOULD do a soft delete by a `mv xxx .tmp` as the .tmp is in .gitignore. 

# Agent Notes: Lunet Core Library

## **Operational Rules (STRICT)**

0.  **DEVELOPER SETUP:** New machines run `make init` (delegates per-OS under `contributing/`). `xmake init` remains as the QA-tools-only entry and delegates to the same `contributing/deps/qa-luarocks.sh` script on Unix. xmake version is pinned via `.mise.toml` and CI uses the same pin.
1.  **TIMEOUTS:** All commands interacting with servers or DB must have a timeout (`timeout 3` or `curl --max-time 3`).
2.  **NO DATA LOSS:** Never use `rm -rf` to clear directories. Move them to `.tmp/` with a timestamp: `mv dir .tmp/dir.YYYYMMDD_HHMMSS`.
3.  **LOGGING:** All test runs must log stdout/stderr to `.tmp/logs/YYYYMMDD_HHMMSS/`.
3a. **SCRATCH SPACE IS REPO-LOCAL:** Do not use the system `/tmp` for scratch work, logs, or throwaway scripts related to this repo. Use the repo's own gitignored `.tmp/` directory instead — it keeps scratch artifacts alongside the checkout, survives tool/sandbox restarts, and is what every task/spec/log convention in this file and `xmake.lua` already assumes.
3b. **NO ISSUE NUMBERS IN CODE OR DOCS:** Do not leave issue numbers, PR numbers, or session-local item numbers in code comments, docs, tests, or workflow comments. Exception: already-published historical release notes under `docs/release-notes/` may retain their original issue references as an immutable record of what shipped; no new issue-number references may be added anywhere else.
4.  **SECURE BINDING:** Never bind to `0.0.0.0` or public interfaces. Use Unix sockets (preferred) or `127.0.0.1` (development). Only bypass this rule if the user explicitly requests it via CLI flag `--dangerously-skip-loopback-restriction`.
5.  **MANDATORY LOCAL CI PARITY BEFORE PUSH:** Before any push, agents MUST run locally all steps from `.github/workflows/build.yml` for their current OS matrix entry (Linux/macOS/Windows), including configure, build, and packaging commands. If any required step cannot be run locally or fails, do not push until fixed or explicitly approved by the user.
    - Minimum local gate for this repo: `xmake lint`, `xmake check`, `xmake check-types`, `xmake build-paxe` (the PAXE Rust crate in `ext/paxe` — `spec/paxe_spec.lua` goes pending without it, and pending fails the suite), `xmake test` (or CI-equivalent Lua test step), `xmake preflight-easy-memory`, and `xmake build-release` (which also builds the `lunet-static` and `sdk-api-test` SDK targets).
    - Note: `xmake test` runs `xmake check-types` first and fails the run on any pending busted test; `LUNET_ALLOW_PENDING=1` is a local-iteration escape hatch only, never CI.
    - PAXE is a Rust extension, not a C target: the protocol core (the private `paxe-core` repository) is vendored byte-exact from the pinned upstream tag at `ext/paxe/paxe-core` (manifest: `ext/paxe/paxe-core.version`; re-pin with `xmake vendor-paxe`, which needs upstream read access). Builds are fully offline — no cargo git fetch anywhere. There is no `xmake build lunet-paxe` anymore — use `xmake build-paxe` / `xmake test-paxe`.
    - CI installs deps via `contributing/deps/*` for dev/CI parity. The same scripts `make init` uses on developer machines drive the `build`, `embed-scripts`, `easy-memory`, and `lua-qa` jobs.
    - If the change affects examples, packaging, or specialized jobs, run the corresponding local equivalents for the current OS as well.
    - macOS local notes: Homebrew's `zlib`, `curl`, `libpq`, and `mysql-client` are keg-only — export `PKG_CONFIG_PATH` with each `$(brew --prefix <pkg>)/lib/pkgconfig` before building drivers or running preflight (same as CI). As of 2026-07-25, ASan-instrumented debug binaries hang in `__malloc_init` at dyld time on macOS 26 (observed on 26.5.2, even for hello-world scripts; release and non-ASan debug/trace builds are unaffected). This blocks the ASan legs of `xmake preflight-easy-memory` locally — environmental, CI is unaffected.

6.  **LUAJIT / LUA 5.1 ABI ONLY FOR TOOLING:** The runtime is LuaJIT (ABI-compatible with Lua 5.1). Homebrew's default `lua` is now 5.5 and is NOT supported for any build/QA tooling. Rocks installed without a version pin land in the 5.5 tree and crash under LuaJIT (e.g. `luacheck` 1.2.0 on Lua 5.5 dies with `attempt to assign to const variable 'field_name'`). Always install rocks against the 5.1 tree: `luarocks --lua-version=5.1 --lua-dir=$(brew --prefix luajit) install <rock>` (the `contributing/deps/*` scripts already do this). Do not attempt to port or debug tooling under Lua 5.5; coerce 5.1 instead.
7.  **WORKTREES ARE OFF-LIMITS:** `paxe/` at the repo root is a separate git worktree (owner's checkout — the intended path was `.worktrees/paxe`). The `.worktrees/` directory likewise holds other worktrees. Do not read, search, list, or modify anything under them unless the user explicitly directs it. They are not part of this checkout's working state.

## Internationalisation Parity (STRICT)

All user-facing documentation MUST be kept in sync between English and Chinese (简体中文).  When you create or modify any of the files below, you MUST create or update its counterpart:

| English | Chinese |
|---------|---------|
| `README.md` | `README-CN.md` |
| `docs/PAXE.md` | `docs/PAXE-CN.md` |
| `docs/*.md` | `docs/*-CN.md` (same basename with `-CN` suffix) |

This includes badges, links, examples, and section structure.  A missing or stale translation is a build-quality defect.

## Type Annotation Parity (STRICT)

Any change to a `types/*.lua` requires a matching change to the corresponding
`types/*.d.tl`. The two are kept in step by inspection. Automated Teal checking
is deliberately deferred.

## Release Quality Gate (STRICT)

Before creating or announcing a release:

1. **Tag-triggered CI only:** Release tags (`v*`) must go through GitHub Actions builds (Linux/macOS/Windows). Do not handcraft a release from local output.
2. **Assets required:** The release must include all eight archives:
   - `lunet-linux-amd64.tar.gz`
   - `lunet-linux-arm64.tar.gz`
   - `lunet-macos.tar.gz`
   - `lunet-windows-amd64.zip`
   - `lunet-linux-amd64-sdk.tar.gz`
   - `lunet-linux-arm64-sdk.tar.gz`
   - `lunet-macos-sdk.tar.gz`
   - `lunet-windows-amd64-sdk.zip`
   - plus `lunet_fetch_release_<tag>.lua`, rendered by the publish workflow from
     `bin/lunet_fetch_release.lua` (the `@RELEASE_TAG@` placeholder becomes the
     release tag). The fetcher installs the runtime into a project-local
     `.lunet/<tag>/` with SHA-256 verification against the release metadata.
3. **Readable release notes:** Notes must include at minimum:
   - `## Highlights`
   - `## Binaries`
   - `## Quick Start`
4. **Verify before sign-off:** Check the published release page and confirm notes formatting plus all assets are present.
5. **If anything is missing:** Fix workflow/release and republish before telling downstream users to consume the tag.
6. **Ignore the AppVeyor checks.** `continuous-integration/appveyor/pr` and
   `.../branch` are orphaned webhooks: the AppVeyor account was deleted before
   its jobs were removed, so they report failure without building anything and
   there is no account left to disable them. They are excluded from the
   required status checks on `main`, and clearing them needs a repo deepclean
   deferred until closer to 1.0.0. GitHub Actions is the only build signal.

**Branch protection:** `main` requires the GitHub Actions build, embed-scripts,
easy-memory and lua-qa checks across Linux/macOS/Windows, with `strict` set so a
branch must be up to date before it merges. `Publish release` is deliberately
*not* required, because it is skipped on non-tag pushes and a skipped required
check would deadlock every merge. Without these, a PR with auto-merge enabled
merges instantly and its CI jobs die at checkout with
`couldn't find remote ref refs/pull/<n>/merge`, which is how a merge can land
with no CI signal at all.

## Example Application

The RealWorld Conduit demo app lives in a separate repository:
[https://github.com/lua-lunet/lunet-realworld-example-app](https://github.com/lua-lunet/lunet-realworld-example-app)

For application-level testing and load testing, clone and use that repo.

## Security & Network Testing

When modifying networking code (sockets, binding, listeners):

1.  **Verify Loopback Restriction:**
    - Try binding to `0.0.0.0` -> MUST FAIL (without flag)
    - Try binding to `127.0.0.1` -> MUST SUCCEED
    - Try binding to Unix socket -> MUST SUCCEED

2.  **Verify Unix Socket Support:**
    - Ensure `socket.listen("unix", "/path")` works
    - Verify permissions on the socket file (should be user-only by default, or as configured)
    - Verify cleanup (socket file removed on close/exit)

## Scripting Guidelines

**AVOID SHELL SCRIPTS FOR NON-TRIVIAL WORK.**

This is a **Lua** project. If a task requires logic, loops, parsing, or file manipulation beyond simple command chaining, **write it in Lua**.

*   **Allowed in Shell:** Simple wrappers (e.g., `xmake` targets), environment setup, `curl` tests.
*   **Must be Lua:** Linting logic, complex build steps, benchmarks, data processing.
*   **Rationale:** Shell scripts (sh/bash) are fragile, platform-dependent, and hard to debug. Lua is robust, portable, and native to this environment.

## Engineering Internals

C code naming conventions, safe-wrapper usage, Lua-C stack debugging notes,
the memory-corruption/segfault debugging methodology (tracing levels, ASan,
lldb, repro harness, known pitfalls), the strict testing protocol, and UDP
module tracing macros have moved to
[`docs/CONTRIBUTING-INTERNALS.md`](docs/CONTRIBUTING-INTERNALS.md)
(Chinese: [`docs/CONTRIBUTING-INTERNALS-CN.md`](docs/CONTRIBUTING-INTERNALS-CN.md)).
That content applies to any contributor, not just agents; read it before
touching C sources under `src/` or `ext/`.

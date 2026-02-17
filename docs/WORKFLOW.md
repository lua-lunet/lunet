# Developer Workflow

[中文文档](WORKFLOW-CN.md)

This document describes the canonical developer workflow for Lunet and lists every available xmake task.

## Canonical Build System: xmake

**xmake is the sole, canonical build system for Lunet.** There is no Makefile.

This decision was made after PR #62 (linting pipeline improvements) established xmake lint tasks and CI gates. All developer workflows, CI pipelines, and documentation use xmake commands exclusively.

### Why xmake?

- **Cross-platform**: Linux, macOS, and Windows from one build definition
- **Dependency detection**: Automatic pkg-config / vcpkg package resolution
- **Task system**: Custom developer tasks (`xmake lint`, `xmake ci`, etc.) live alongside build targets in `xmake.lua`
- **CI parity**: The same commands run locally and in GitHub Actions

## Task Catalog

Every task below is defined in `xmake.lua` and can be run with `xmake <task>`.

### Setup

| Task | Description |
|------|-------------|
| `xmake init` | Install local Lua QA dependencies (luafilesystem, busted, luacheck) via luarocks |

### Quality Gates

| Task | Description |
|------|-------------|
| `xmake lint` | Run C safety lint checks (`bin/lint_c_safety.lua`) |
| `xmake check` | Run luacheck static analysis on `test/` and `spec/` using a staged baseline filter |
| `xmake test` | Run Lua unit tests with busted (`spec/`) |

### Build Profiles

| Task | Description |
|------|-------------|
| `xmake build-release` | Configure and build optimized release profile |
| `xmake build-debug` | Configure and build debug profile with `LUNET_TRACE` |
| `xmake build-easy-memory-experimental` | Configure and build EasyMem experimental release profile |

### Functional Tests

| Task | Description |
|------|-------------|
| `xmake examples-compile` | Run examples compile/syntax check (`test/ci_examples_compile.lua`) |
| `xmake sqlite3-smoke` | Build and run SQLite3 example smoke test (`examples/03_db_sqlite3.lua`) |
| `xmake smoke` | Run all database smoke tests (SQLite3 + MySQL + Postgres if available) |
| `xmake stress` | Run concurrent stress test with debug trace profile |
| `xmake socket-gc` | Run socket listener GC regression test |

### CI / Release

| Task | Description |
|------|-------------|
| `xmake ci` | Run full local CI parity sequence: lint, check, build-release, test, build lunet-sqlite3, examples compile check, SQLite3 smoke |
| `xmake preflight-easy-memory` | Run EasyMem + ASan preflight smoke with logged output (`.tmp/logs/`) |
| `xmake release` | Full release gate: lint + test + stress + EasyMem preflight + build-release |

### Advanced / Platform-Specific

| Task | Description |
|------|-------------|
| `xmake luajit-asan` | Build macOS LuaJIT with ASan into `.tmp` (macOS only) |
| `xmake build-debug-asan-luajit` | Build lunet-bin with ASan + custom LuaJIT ASan (macOS only) |
| `xmake repro-50-asan-luajit` | Run issue #50 repro with LuaJIT + Lunet ASan (macOS only) |

## Recommended Workflows

### Day-to-day development

```bash
xmake build-debug     # Build with tracing
xmake lint            # Check C naming conventions
xmake test            # Run unit tests
```

### Before pushing

```bash
xmake ci              # Full local CI parity check
```

Or the minimum gate specified in `AGENTS.md`:

```bash
xmake lint
xmake test
xmake preflight-easy-memory
xmake build-release
```

### Preparing a release

```bash
xmake release         # lint + test + stress + preflight + build-release
```

## CI Pipeline

The GitHub Actions workflow (`.github/workflows/build.yml`) runs on every push to `main` and every pull request. It first enforces a dedicated Ubuntu lint gate (`xmake lint`, `xmake check`, `xmake test`), then runs cross-platform build jobs on Linux, macOS, and Windows with examples compile checks and SQLite3 smoke tests.

The `xmake ci` task mirrors this pipeline locally so you can catch failures before pushing.

## Migration Notes

- **No Makefile**: Lunet has never shipped a Makefile. All workflows use xmake.
- **Pre-commit hook**: The repo includes `.githooks/pre-commit` (runs `xmake lint` and `xmake check` when `luacheck` is available). Install it via `bin/install-hooks.sh` (recommended) or `git config core.hooksPath .githooks`.
- **Deprecation policy**: If a future build system migration is needed, xmake tasks will be preserved as compatibility shims during the transition period.

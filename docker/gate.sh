#!/usr/bin/env bash
# Local CI-parity gate sequence (Linux/trixie). Mirrors CI + AGENTS.md gates.
set -euo pipefail

step() { printf '\n===== GATE: %s =====\n' "$*"; }

step "cargo test (lnt_shared, release)"
cargo test --release --manifest-path ext/lnt_shared/Cargo.toml

step "xmake build-lnt-shared"
xmake build-lnt-shared

step "xmake ci (lint + build-release + sqlite3 + examples compile + sqlite3 smoke)"
xmake ci

step "optional extensions (lunet-httpc, release)"
xmake build lunet-httpc

# PAXE is fully exercised here: the crate is vendored (no network, no
# credentials) and the image carries a source-built libsodium with the ARM
# CE AES-256-GCM path (see Dockerfile), so the FFI suite, the Lua spec
# (inside xmake test below), the smoke and the two-process e2e all run.
step "paxe crate tests (xmake test-paxe)"
xmake test-paxe

step "paxe build (xmake build-paxe)"
xmake build-paxe

step "xmake test (busted under luajit; httpc + paxe specs live)"
xmake test

step "paxe functional smoke + protected-UDP e2e (release runner)"
RUNNER="$(find build -type f -name 'lunet-run' -path '*release*' | head -1)"
timeout 60 "$RUNNER" test/smoke_paxe.lua
timeout 90 bash test/run_paxe_udp_e2e.sh

step "lnt_shared smoke (release runner)"
RUNNER="$(find build -type f -name 'lunet-run' -path '*release*' | head -1)"
timeout 60 "$RUNNER" test/smoke_lnt_shared.lua

step "xmake preflight-easy-memory (ASAN + EasyMem + DB stress + LSAN)"
xmake preflight-easy-memory

step "ALL GATES PASSED"

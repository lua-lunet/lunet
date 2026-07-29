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

step "xmake test (busted under luajit; httpc spec live)"
xmake test

step "lnt_shared smoke (release runner)"
RUNNER="$(find build -type f -name 'lunet-run' -path '*release*' | head -1)"
timeout 60 "$RUNNER" test/smoke_lnt_shared.lua

step "xmake preflight-easy-memory (ASAN + EasyMem + DB stress + LSAN)"
xmake preflight-easy-memory

step "ALL GATES PASSED"

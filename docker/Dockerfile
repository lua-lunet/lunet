# Local CI-parity gate for lunet — Debian trixie (arm64) + LuaJIT.
# Mirrors .github/workflows/build.yml (Linux entries) plus the repo's
# mandatory local gates from AGENTS.md:
#   xmake lint | xmake test | xmake preflight-easy-memory | xmake build-release
# …and this branch's lnt_shared Rust extension (cargo test + smoke).
#
# Build:  docker build -f docker/Dockerfile -t lunet-gate:trixie .
# Run:    docker run --rm lunet-gate:trixie
# (classic builder only — no BuildKit, no mounts)

FROM --platform=linux/arm64 debian:trixie

ENV DEBIAN_FRONTEND=noninteractive

# CI dependency sets:
#  - build job:       pkg-config libuv1-dev luajit libluajit-5.1-dev libsqlite3-dev
#  - easy-memory job: + libpq-dev default-libmysqlclient-dev
#  - embed job:       + zlib1g-dev
#  - local gates:     + busted (xmake test), libasan8 (ASAN), rustc/cargo (ext)
# (No libsodium: PAXE's Rust crate links a source-built static libsodium via
# paxe-core's build.rs, and paxe is not exercised in this container at all —
# see docker/gate.sh.)
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential pkg-config \
      luajit libluajit-5.1-dev \
      libuv1-dev libsqlite3-dev zlib1g-dev \
      libpq-dev default-libmysqlclient-dev \
      libcurl4-openssl-dev \
      libasan8 \
      rustc cargo \
      luarocks lua5.1 \
      curl ca-certificates git \
    && rm -rf /var/lib/apt/lists/*

# xmake pinned to the same version used in local dev (auto-detect in the
# upstream installer script fails in minimal containers).
ARG XMAKE_VERSION=3.0.8
RUN curl -fsSL -o /tmp/xmake.run "https://github.com/xmake-io/xmake/releases/download/v${XMAKE_VERSION}/xmake-v${XMAKE_VERSION}.gz.run" \
    && bash /tmp/xmake.run \
    && rm /tmp/xmake.run
ENV PATH="/root/.local/bin:${PATH}"
# Containers run as root; xmake requires explicit opt-in for that.
ENV XMAKE_ROOT=y

# lua-language-server for type checking (xmake check-types).
# The --metapath flag in xmake.lua ensures the meta cache is written to a
# writable location (logdir), so the root-owned install dir is not a problem.
ARG LUALS_VERSION=3.15.0
RUN ARCH=$(dpkg --print-architecture | sed 's/amd64/x64/') && \
    LUALS_TARBALL="lua-language-server-${LUALS_VERSION}-linux-${ARCH}.tar.gz" && \
    LUALS_URL="https://github.com/LuaLS/lua-language-server/releases/download/${LUALS_VERSION}/${LUALS_TARBALL}" && \
    mkdir -p /usr/local/lib/lua-language-server && \
    curl -fsSL "$LUALS_URL" | tar -xzf - -C /usr/local/lib/lua-language-server && \
    ln -sf /usr/local/lib/lua-language-server/bin/lua-language-server /usr/local/bin/lua-language-server && \
    lua-language-server --version

# busted for `xmake test`, forced to run under LuaJIT so the ABI matches the
# lunet modules (PUC-Lua would crash loading luajit-linked .so files).
RUN luarocks --lua-version=5.1 install busted \
    && BUSTED_BIN="$(find /usr/local/lib/luarocks -type f -path '*/busted/*/bin/busted' | head -1)" \
    && printf '#!/bin/sh\nexec luajit "%s" "$@"\n' "$BUSTED_BIN" > /usr/local/bin/busted \
    && chmod +x /usr/local/bin/busted \
    && busted --version

WORKDIR /src
COPY . /src

RUN chmod +x docker/gate.sh
CMD ["bash", "docker/gate.sh"]

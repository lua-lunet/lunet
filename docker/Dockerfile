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
# (No distro libsodium: the vendored PAXE crate links a static libsodium, and
# the trixie arm64 distro package lacks the ARM CE AES-256-GCM runtime path.
# A source-built one is installed after COPY, below.)
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

# Static libsodium 1.0.22 with the ARM CE AES-256-GCM path for the vendored
# PAXE crate (paxe-core's build.rs resolves PAXE_SODIUM_LIB_DIR first).
RUN bash contributing/deps/sodium-src.sh
ENV PAXE_SODIUM_LIB_DIR=/tmp/libsodium/lib

RUN chmod +x docker/gate.sh
CMD ["bash", "docker/gate.sh"]

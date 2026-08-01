#!/usr/bin/env bash
set -euo pipefail

VERSION="1.0.21"
SHA256="9e4285c7a419e82dedb0be63a72eea357d6943bc3e28e6735bf600dd4883feaf"
TARBALL="libsodium-${VERSION}.tar.gz"
URL="https://download.libsodium.org/libsodium/releases/${TARBALL}"
PREFIX="${SODIUM_PREFIX:-/tmp/libsodium}"
WORKDIR="/tmp/libsodium-build"
JOBS="${NPROC:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

echo "=== Building libsodium ${VERSION} from source: ${PREFIX} ==="

mkdir -p "${WORKDIR}"
cd "${WORKDIR}"

if [[ ! -f "${TARBALL}.downloaded" ]]; then
    echo "  Downloading ${URL}"
    curl --max-time 120 -fsSL -o "${TARBALL}" "${URL}"
    echo "${SHA256}  ${TARBALL}" | sha256sum -c -
    touch "${TARBALL}.downloaded"
else
    echo "  Already downloaded, skipping"
fi

if [[ ! -d "libsodium-${VERSION}" ]]; then
    echo "  Extracting"
    tar xzf "${TARBALL}"
fi

cd "libsodium-${VERSION}"

echo "  Configuring"
./configure \
    --enable-static \
    --disable-shared \
    --prefix="${PREFIX}" \
    > /dev/null

echo "  Building (${JOBS} jobs)"
make -j"${JOBS}" > /dev/null

echo "  Installing"
make install > /dev/null

echo ""
echo "  libsodium ${VERSION} installed to ${PREFIX}"
echo "  Static archive: ${PREFIX}/lib/libsodium.a"
echo "  pkg-config:     ${PREFIX}/lib/pkgconfig/libsodium.pc"
echo "  SODIUM_PREFIX=${PREFIX}"

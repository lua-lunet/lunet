#!/usr/bin/env bash
set -euo pipefail

# 1.0.22, not 1.0.21: 1.0.21's crypto_ipcrypt/ipcrypt_armcrypto.c does not
# compile on aarch64 with GCC. BYTESHL128 feeds a vextq_s8() result to
# vreinterpretq_u64_u8(), and pfx_shift_left() assigns uint8x16_t values to
# uint64x2_t locals. Clang accepts both (lax NEON vector conversions), GCC
# rejects them, so the arm64 CI leg died in "Install Dependencies (Linux)".
# Upstream fixed both in 1.0.22 (u8 intrinsics throughout).
VERSION="1.0.22"
SHA256="adbdd8f16149e81ac6078a03aca6fc03b592b89ef7b5ed83841c086191be3349"
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

#!/usr/bin/env bash
# Build the fully static musl binary in an Alpine container: scripts/docker-build.sh
# The result is static, so test it on the host: SKIP_BUILD=1 BUILD_DIR=build-musl ./test.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${LMSSH_ALPINE_IMAGE:-alpine:3.22}"
docker run --rm -v "$HERE:/w" -w /w -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" "$IMAGE" sh -c '
  trap "chown -R $HOST_UID:$HOST_GID /w/build-musl /w/third_party 2>/dev/null || true" EXIT
  apk add -q build-base autoconf automake openssl-dev openssl-libs-static zlib-dev zlib-static linux-headers bash git cmake ninja python3 &&
  git config --global --add safe.directory "*" &&
  cmake -S . -B build-musl -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build build-musl'

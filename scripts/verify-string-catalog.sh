#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
expected=
while IFS='=' read -r key value; do [[ $key != sha256 ]] || expected=$value; done < string-catalog.lock
if command -v sha256sum >/dev/null; then actual=$(sha256sum cpp/stdlib/string.hpp); else actual=$(shasum -a 256 cpp/stdlib/string.hpp); fi
[[ ${actual%% *} == "$expected" ]] || { echo 'stdlib/string.hpp differs from string-catalog.lock' >&2; exit 1; }

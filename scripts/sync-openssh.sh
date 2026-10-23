#!/usr/bin/env bash
# Fetch openssh-portable into third_party/openssh-portable (git-ignored) at the commit pinned in openssh.lock.
set -eu
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$HERE/openssh.lock"
DIR="$HERE/third_party/openssh-portable"
[ -f "$LOCK" ] || { echo "openssh.lock missing" >&2; exit 1; }
repo="$(sed -n 's/^repo=//p' "$LOCK")"
commit="$(sed -n 's/^commit=//p' "$LOCK")"
if [ "${1:-}" = "--verify" ]; then
  [ -d "$DIR/.git" ] || { echo "third_party/openssh-portable missing: run scripts/sync-openssh.sh" >&2; exit 1; }
  have="$(git -C "$DIR" rev-parse HEAD)"
  [ "$have" = "$commit" ] || { echo "third_party/openssh-portable at $have, openssh.lock pins $commit: run scripts/sync-openssh.sh" >&2; exit 1; }
  echo "third_party/openssh-portable matches openssh.lock ($commit)"
  exit 0
fi
if [ ! -d "$DIR/.git" ]; then
  mkdir -p "$DIR"
  git -C "$DIR" init -q
  git -C "$DIR" remote add origin "$repo"
fi
git -C "$DIR" fetch -q --depth 1 origin "$commit"
git -C "$DIR" checkout -q FETCH_HEAD
echo "synced third_party/openssh-portable at $commit"

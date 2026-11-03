#!/usr/bin/env bash
# Build (unless SKIP_BUILD=1) and test lmssh. Needs: cmake, a C/C++ toolchain, autoconf/automake, static libcrypto/libz,
# python3, an lmscript v6 compiler (scripts/select-compiler.sh) and, for the end-to-end checks, an sshd binary
# (LMSSH_REQUIRE_SSHD=1 makes a missing or unusable sshd a failure instead of a skip).
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
BUILD_DIR="${BUILD_DIR:-build}"
HOST="$HERE/$BUILD_DIR/lmssh"
TIMEOUT_CMD=timeout
command -v timeout >/dev/null 2>&1 || TIMEOUT_CMD=gtimeout
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lmsshtest.XXXXXX")"
SSHD_PID=""
cleanup() {
  [ -n "$SSHD_PID" ] && kill "$SSHD_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT
pass=0
ok(){ pass=$((pass+1)); echo "ok $pass - $1"; }
fail(){ echo "FAIL: $*" >&2; exit 1; }
contains(){ case "$1" in *"$2"*) return 0;; *) return 1;; esac; }
expect_contains(){ contains "$1" "$2" || fail "$3: expected '$2' in: $1"; }

scripts/sync-sdk.sh --verify >/dev/null || fail "SDK header pin mismatch"
ok "VM and catalog headers match sdk.lock"
python3 scripts/merge-std.py schema/lmssh.host.json "$WORK/lmssh.merged-schema.json"
python3 scripts/verify-lmcode-fixtures.py tests/fixtures/lmcode/manifest.json || fail "lmcode fixture pins differ"
mkdir -p "$BUILD_DIR"
"${CXX:-c++}" -std=c++17 -O0 -Icpp tests/prompt-command.cpp -o "$BUILD_DIR/prompt-command"
LMSSH_PROMPT_DRIVER="$HERE/$BUILD_DIR/prompt-command" python3 scripts/test-set-prompt.py
ok "managed Bash prompt recipe preserves startup data and verifies rendered aliases"
if [ -z "${SKIP_BUILD:-}" ]; then
  scripts/sync-openssh.sh --verify >/dev/null 2>&1 || scripts/sync-openssh.sh >/dev/null
fi
scripts/sync-openssh.sh --verify >/dev/null || fail "openssh pin mismatch"
ok "third_party/openssh-portable matches openssh.lock"

if [ -z "${SKIP_BUILD:-}" ]; then
  CMAKE_ARGS=(-DCMAKE_BUILD_TYPE=Release)
  [ -n "${OPENSSL_DIR:-}" ] && CMAKE_ARGS+=(-DOPENSSL_DIR="$OPENSSL_DIR")
  [ "${LMSSH_FULL_STATIC:-}" = OFF ] && CMAKE_ARGS+=(-DLMSSH_FULL_STATIC=OFF)
  GEN=(); command -v ninja >/dev/null 2>&1 && GEN=(-G Ninja)
  cmake -S . -B "$BUILD_DIR" ${GEN[@]+"${GEN[@]}"} "${CMAKE_ARGS[@]}" >"$WORK/build.log" 2>&1 || { tail -40 "$WORK/build.log" >&2; fail "cmake configure"; }
  cmake --build "$BUILD_DIR" >>"$WORK/build.log" 2>&1 || { tail -60 "$WORK/build.log" >&2; for l in "$BUILD_DIR"/openssh/*.log; do [ -f "$l" ] && { echo "== $l" >&2; tail -30 "$l" >&2; }; done; fail "build"; }
fi
[ -x "$HOST" ] || fail "no executable at $HOST"
ok "lmssh built"
python3 tests/check-host-flags.py schema/lmssh.dsl.json "$HOST" || fail "hard host flag cutover"

LMSCRIPT="$(scripts/select-compiler.sh)"
ok "lmcode v6 compiler found: $LMSCRIPT"
cat > "$WORK/new-language-features.lms" <<EOF
let options=args_parse([],{});
program = _lmcode_ schema="$HERE/schema/lmssh.dsl.json";
let n=1;
let text=f"count={n}";
end _lmcode_
EOF
NEW_FEATURES=1
if ! "$LMSCRIPT" --check "$WORK/new-language-features.lms" >"$WORK/features.out" 2>"$WORK/features.err"; then
  if grep -Eq "undefined function 'args_parse'|undefined name 'f'" "$WORK/features.err"; then
    NEW_FEATURES=0
    echo "SKIP args_parse/inner f-string checks: selected published compiler predates mono-main language commits"
  else
    cat "$WORK/features.err" >&2; fail "new lmcode/lmscript feature probe"
  fi
fi
for source in examples/*.lms tests/fixtures/lmcode/*.lms scripts/lib/prompt-program.lms; do
  if [ "$NEW_FEATURES" = 0 ] && { [ "$source" = "examples/deploy-file.lms" ] || [ "$source" = "tests/fixtures/lmcode/session.lms" ]; }; then
    continue
  fi
  "$LMSCRIPT" --check "$source" >"$WORK/check.out" 2>"$WORK/check.err" || { cat "$WORK/check.err" >&2; fail "lmcode source $source does not check"; }
done
if [ "$NEW_FEATURES" = 1 ]; then
  LMCTL_BIN="${LMCTL_BIN:-$(dirname "$LMSCRIPT")/lmctl}" python3 scripts/test-args-parser.py || fail "args_parse parity tests"
  "$LMSCRIPT" --check scripts/lib/args.lms
  "$LMSCRIPT" --check scripts/lib/prompt.lms
  "$LMSCRIPT" --check recipes/set-prompt.lms
else
  echo "SKIP args_parse source checks: selected published compiler predates mono-main args_parse"
fi

LMSCRIPT_BIN="$LMSCRIPT" NEW_LANGUAGE_FEATURES="$NEW_FEATURES" python3 scripts/test-body-expansion.py || fail "fixture body expansion"
ok "fixture body expansion without outer effects"

# ---- identity, schema, static linking ----
want_version="$(sed -n 's/^project(lmssh VERSION \([0-9.]*\).*/\1/p' CMakeLists.txt)"
[ "$("$HOST" --version)" = "lmssh $want_version" ] || fail "--version"
ok "--version is lmssh $want_version"
"$HOST" --lmcode-schema --json | cmp - schema/lmssh.dsl.json || fail "embedded schema differs from schema/lmssh.dsl.json"
ok "--lmcode-schema --json is byte-identical to schema/lmssh.dsl.json"
"$HOST" --lmcode-signatures > "$WORK/host.sig"
"$LMSCRIPT" --lmcode-signatures schema/lmssh.dsl.json > "$WORK/compiler.sig"
diff "$WORK/host.sig" "$WORK/compiler.sig" >/dev/null || fail "registry signatures differ from the compiler's reading of the schema"
ok "registry signatures match the compiler ($(wc -l < "$WORK/host.sig" | tr -d ' ') signatures)"
cmp schema/lmssh.host.json schema/lmssh.dsl.json || fail "generated schema differs from host-only input"
python3 scripts/merge-std.py --host-only schema/lmssh.dsl.json "$WORK/host-only-schema.json"
cmp schema/lmssh.dsl.json "$WORK/host-only-schema.json" || fail "embedded schema still declares standard members"
"$HOST" --lmcode-signatures >"$WORK/registry-signatures.txt"
"$LMSCRIPT" --lmcode-signatures cpp/std/lmcode-std.schema.json >"$WORK/standard-signatures.txt"
python3 - "$WORK" <<'PYHOST'
from pathlib import Path
import sys
work=Path(sys.argv[1])
registry=set((work/'registry-signatures.txt').read_text().splitlines())
standard=set((work/'standard-signatures.txt').read_text().splitlines())
assert len(standard)==206, len(standard)
(work/'host-signatures.txt').write_bytes(''.join(line+'\n' for line in sorted(registry-standard)).encode('utf-8'))
PYHOST
diff -u <("$LMSCRIPT" --lmcode-signatures schema/lmssh.dsl.json --without-std) "$WORK/host-signatures.txt" || fail "host-only registry/compiler signatures differ"
ok "host-only schema bytes and --without-std parity retain domain and testing declarations"
python3 scripts/gen-schema.py "$HOST" | cmp - schema/lmssh.host.json || fail "schema/lmssh.host.json is stale: scripts/gen-schema.py"
ok "schema/lmssh.dsl.json regenerates identically from the registry"
case "$(uname -s)" in
  Linux)
    # ldd exits non-zero on a static executable, which pipefail would turn into a failure
    lddout="$(ldd "$HOST" 2>&1 || true)"
    if [ "${LMSSH_FULL_STATIC:-}" = OFF ]; then ok "static check skipped (LMSSH_FULL_STATIC=OFF)";
    elif contains "$lddout" "not a dynamic executable" || contains "$lddout" "statically linked"; then ok "fully static executable (ldd)";
    else fail "executable is not static: $lddout"; fi ;;
  Darwin)
    others="$(otool -L "$HOST" | tail -n +2 | awk '{print $1}' | grep -vE '^/usr/lib/|^/System/Library/' || true)"
    [ -z "$others" ] || fail "non-system dynamic libraries: $others"
    ok "only system libraries linked (otool -L)" ;;
esac

# ---- the original OpenSSH clients, unchanged ----
v="$("$HOST" ssh -V 2>&1)"; expect_contains "$v" "OpenSSH_10" "ssh -V"; ok "lmssh ssh -V: $v"
expect_contains "$("$HOST" sftp -h 2>&1 || true)" "usage: sftp" "sftp usage"
expect_contains "$("$HOST" scp 2>&1 || true)" "usage: scp" "scp usage"
ok "lmssh sftp / scp print the original usage"
"$HOST" ssh-keygen -q -t ed25519 -N '' -C orig@test -f "$WORK/orig" || fail "ssh-keygen"
fp="$("$HOST" ssh-keygen -l -f "$WORK/orig.pub")"; expect_contains "$fp" "orig@test (ED25519)" "ssh-keygen -l"
ok "lmssh ssh-keygen generates and prints a fingerprint: $fp"
mkdir "$WORK/links"; for t in ssh sftp scp ssh-keygen; do ln -s "$HOST" "$WORK/links/$t"; done
expect_contains "$("$WORK/links/ssh" -V 2>&1)" "OpenSSH_10" "argv[0]=ssh dispatch"
expect_contains "$("$WORK/links/ssh-keygen" -l -f "$WORK/orig.pub")" "orig@test" "argv[0]=ssh-keygen dispatch"
ok "invoked as ssh / ssh-keygen (symlink) it behaves as that program"
rc=0; "$HOST" >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "usage exit code $rc"
rc=0; "$HOST" --lmcode >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "--lmcode without file: $rc"
rc=0; "$HOST" --lmcode --oops x.dslb >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "--lmcode with option-like file: $rc"
ok "usage errors exit 2"

# ---- pinned lmcode fixture runner ----
lmcode() { # lmcode NAME [SCRIPT_ARGS ...] -> sets RC, OUT, ERR
  local name="$1"; shift
  RC=0; "$HOST" --lmcode "$HERE/tests/fixtures/lmcode/$name.dslb" -- "$@" >"$WORK/out.txt" 2>"$WORK/err.txt" || RC=$?
  OUT="$(cat "$WORK/out.txt")"; ERR="$(cat "$WORK/err.txt")"
}
lmcode_dry() { # lmcode_dry NAME [SCRIPT_ARGS ...]
  local name="$1"; shift
  RC=0; "$HOST" --dry-run --lmcode "$HERE/tests/fixtures/lmcode/$name.dslb" -- "$@" >"$WORK/out.txt" 2>"$WORK/err.txt" || RC=$?
  OUT="$(cat "$WORK/out.txt")"; ERR="$(cat "$WORK/err.txt")"
}

# ---- no-network lmcode: keys, io, strings, report ----
lmcode keys
[ "$RC" = 3 ] || fail "overwriting a key must be a run error (rc=$RC out=$OUT)"
expect_contains "$OUT" "ed25519|kc@test|256" "key facts"
expect_contains "$OUT" "ssh-ed25519 " "public key"
expect_contains "$OUT" "truefalse" "io.exists"
expect_contains "$OUT" "4ca+b++c" "str_split keeps empty fields"
expect_contains "$OUT" "X42" "string catalog"
expect_contains "$OUT" 'kind file:3: line1\nline2' "report text escapes"
expect_contains "$OUT" '"count":1' "report json"
expect_contains "$OUT" "refusing to overwrite" "no clobber"
expect_contains "$OUT" '"ok": false' "error result line"
ok "keys / io / strings / report work; an existing key is never overwritten"

lmcode sigs A1
[ "$RC" = 4 ] || fail "io.fail must exit 4 (rc=$RC)"; expect_contains "$OUT" "custom verdict A1" "io.fail message"
ok "io.fail exits 4 with the script's own message"

rc=0; "$HOST" --lmcode "$WORK/missing.dslb" >/dev/null 2>&1 || rc=$?; [ "$rc" = 3 ] || fail "missing bytecode rc=$rc"
rc=0; "$HOST" --lmcode "$HERE/tests/fixtures/lmcode/other-schema.dslb" >"$WORK/o.txt" 2>&1 || rc=$?; [ "$rc" = 3 ] || fail "schema mismatch rc=$rc"
ok "missing bytecode and schema-hash mismatch are load errors (exit 3)"

# ---- end to end against a throw-away sshd on 127.0.0.1 ----
SSHD="$(command -v sshd 2>/dev/null || true)"; [ -n "$SSHD" ] || { [ -x /usr/sbin/sshd ] && SSHD=/usr/sbin/sshd; } || true
E2E=0
if [ -n "$SSHD" ]; then
  PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1])')"
  ssh-keygen -q -t ed25519 -N '' -f "$WORK/host_key" 2>/dev/null || "$HOST" ssh-keygen -q -t ed25519 -N '' -f "$WORK/host_key"
  "$HOST" ssh-keygen -q -t ed25519 -N '' -C client -f "$WORK/id_client"
  "$HOST" ssh-keygen -q -t ed25519 -N 'sekret' -C enc -f "$WORK/id_enc"
  cat "$WORK/id_client.pub" "$WORK/id_enc.pub" > "$WORK/authorized_keys"; chmod 600 "$WORK/authorized_keys"
  cat > "$WORK/sshd_config" <<E2
Port $PORT
ListenAddress 127.0.0.1
HostKey $WORK/host_key
PidFile $WORK/sshd.pid
AuthorizedKeysFile $WORK/authorized_keys
StrictModes no
UsePAM no
PasswordAuthentication no
PermitRootLogin yes
Subsystem sftp internal-sftp
LogLevel ERROR
E2
  mkdir -p /run/sshd 2>/dev/null || true
  "$SSHD" -f "$WORK/sshd_config" -D -e >"$WORK/sshd.log" 2>&1 &
  SSHD_PID=$!
  SSHD_OWNED=0
  for _ in $(seq 1 50); do
    if ps -p "$SSHD_PID" -o args= | grep -F -- "$WORK/sshd_config" >/dev/null; then SSHD_OWNED=1; fi
    if [ "$SSHD_OWNED" = 1 ] && (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then E2E=1; break; fi
    sleep 0.1
  done
  [ "$SSHD_OWNED" = 1 ] || fail "started sshd pid identity did not match the owned config"
  [ "$E2E" = 1 ] || { echo "sshd did not start: $(cat "$WORK/sshd.log")" >&2; [ -z "${LMSSH_REQUIRE_SSHD:-}" ] || fail "sshd unusable"; }
elif [ -n "${LMSSH_REQUIRE_SSHD:-}" ]; then fail "no sshd binary"; fi

if [ "$E2E" = 1 ]; then
  ME="$(id -un)"
  cat > "$WORK/ssh_config" <<E2
Host testhost
  HostName 127.0.0.1
  Port $PORT
  User $ME
  IdentityFile $WORK/id_client
  IdentitiesOnly yes
  UserKnownHostsFile $WORK/known_hosts
  StrictHostKeyChecking accept-new
Host *
  UserKnownHostsFile $WORK/known_hosts
  StrictHostKeyChecking accept-new
  IdentityFile $WORK/id_client
E2
  R="$WORK/remote"; mkdir -p "$R"
  # The interactive clients really talk to the server too (original options).
  expect_contains "$("$HOST" ssh -F "$WORK/ssh_config" testhost 'echo interactive-ok')" interactive-ok "lmssh ssh -F ... testhost"
  echo "ls $R" | "$HOST" sftp -F "$WORK/ssh_config" -b - testhost >/dev/null || fail "lmssh sftp"
  echo cli-scp > "$WORK/cli.txt"; "$HOST" scp -q -F "$WORK/ssh_config" "$WORK/cli.txt" testhost:"$R/cli.txt"; [ "$(cat "$R/cli.txt")" = cli-scp ] || fail "lmssh scp"
  ok "original ssh / sftp / scp options work against the test server (scp and sftp use this image as their ssh)"

  lmcode session "$WORK/ssh_config" "$WORK" "$R"
  [ "$RC" = 3 ] || fail "require() on a failing command must be a run error (rc=$RC err=$ERR out=$OUT)"
  expect_contains "$OUT" "st=3 ok=false out=out err=err" "exec result"
  expect_contains "$OUT" "who=$ME" "output"
  expect_contains "$OUT" "stdin=from-stdin" "exec with input"
  expect_contains "$OUT" "cat=payload" "put + cat"
  expect_contains "$OUT" "exists=truefalse" "exists"
  expect_contains "$OUT" "ls=w2.txt" "mkdir/rename/ls"
  expect_contains "$OUT" "gone=false" "rm/rmdir"
  expect_contains "$OUT" "back=B" "put_dir/get_dir"
  expect_contains "$OUT" "sftp=Remote working directory:" "sftp batch"
  expect_contains "$OUT" "ok?=truefalse" "ok()"
  expect_contains "$OUT" "exited 9" "require() message"
  [ "$(cat "$R/up.txt")" = payload ] || fail "remote file content"
  ok "Session exec/output/put/get/cat/write/ls/exists/mkdir/rename/rm/put_dir/get_dir/sftp over a real sshd"

  lmcode fleet "$WORK/ssh_config"
  [ "$RC" = 3 ] || fail "require_all must fail (rc=$RC)"
  expect_contains "$OUT" "n=3 failed=0" "each() results"
  secs="$(printf '%s' "$OUT" | sed -n 's/.*secs=\([0-9][0-9]*\).*/\1/p')"
  [ -n "$secs" ] && [ "$secs" -le 2 ] || fail "three 1s commands should overlap (sequential would take 3s+): $OUT"
  expect_contains "$OUT" "bad failed=1" "failed()"
  ok "Ssh.each runs commands in parallel and reports failures"

  lmcode options "$WORK/known_hosts2" "$PORT" "$ME" "$WORK/id_client" "$WORK/ssh_config" "$WORK/id_enc" "$WORK/empty_hosts"
  [ "$RC" = 0 ] || fail "options script failed rc=$RC out=$OUT err=$ERR"
  expect_contains "$OUT" "direct=d" "port/identity/user/known_hosts options"
  expect_contains "$OUT" "jump=j" "ProxyJump through this image"
  expect_contains "$OUT" "reuse=m1m2" "ControlMaster reuse"
  expect_contains "$OUT" "timeout=truefalse124" "timeout kills the command"
  expect_contains "$OUT" "askpass=with-passphrase" "key passphrase through SSH_ASKPASS"
  expect_contains "$OUT" "wrong=false" "wrong passphrase fails"
  expect_contains "$OUT" "unknown host key refused=true" "unknown host keys are never auto-accepted"
  # Session work directories use exactly six mkdtemp characters. Unrelated
  # lmssh-*.log files are not leaked session directories.
  for dir in /tmp/lmssh-??????; do
    [ ! -d "$dir" ] || fail "work directory leaked: $dir"
  done
  ok "port/identity/jump/reuse/timeout/passphrase options work; the private work directory is removed"

  rm -f "$R/dry.txt"
  lmcode_dry dry "$WORK/ssh_config" "$R" "$WORK"
  [ "$RC" = 0 ] || fail "dry-run rc=$RC err=$ERR"
  expect_contains "$ERR" "[dry-run] ssh " "dry-run lists the ssh command"
  [ ! -e "$R/dry.txt" ] && [ ! -e "$WORK/dry-local.txt" ] || fail "dry-run changed something"
  ok "--dry-run prints the commands and changes nothing"

  # ---- security regressions: control-char injection, glob neutralization, odd legal names ----
  echo "keep" > "$R/victim.txt"
  lmcode inject-nl "$WORK/ssh_config" "$R"
  [ "$RC" = 3 ] || fail "newline injection must fail with rc=3 (got $RC: $OUT $ERR)"
  expect_contains "$OUT" "contains a control character" "newline injection error"
  [ -f "$R/victim.txt" ] || fail "newline injection removed victim.txt"

  lmcode inject-cr "$WORK/ssh_config" "$R"
  [ "$RC" = 3 ] || fail "CR injection must fail with rc=3 (got $RC: $OUT $ERR)"
  expect_contains "$OUT" "contains a control character" "CR injection error"

  lmcode inject-put "$WORK/ssh_config" "$R"
  [ "$RC" = 3 ] || fail "write newline path must fail with rc=3 (got $RC: $OUT $ERR)"
  expect_contains "$OUT" "contains a control character" "write newline error"

  lmcode inject-user
  [ "$RC" = 3 ] || fail "option-like user must fail with rc=3 (got $RC: $OUT $ERR)"
  ok "control-character and option-injection attempts are rejected before invoking OpenSSH"

  mkdir -p "$R/glob_dir"
  printf 'victim-data' > "$R/glob_dir/victim.txt"
  printf 'brace-a' > "$R/glob_dir/brace_a.txt"
  printf 'brace-b' > "$R/glob_dir/brace_b.txt"
  lmcode glob-check "$WORK/ssh_config" "$R" "$WORK"
  [ "$RC" = 0 ] || fail "glob_check failed rc=$RC out=$OUT err=$ERR"
  expect_contains "$OUT" "wild=falsefalsefalsefalse" "globs and braces do not expand on exists/ls"
  expect_contains "$OUT" "lit=lit-star|lit-qmark|lit-brack|lit-brace" "literal glob/brace filenames round-trip via write/cat"
  expect_contains "$OUT" "got=lit-brack" "literal bracket filename round-trips via get"
  expect_contains "$OUT" "survivors=victim-data|brace-a|brace-b" "rm on literal glob/brace filenames leaves matching siblings untouched"
  ok "glob (* ? [) and brace ({a,b}) characters are neutralized across sftp and scp operations"

  lmcode odd-names "$WORK/ssh_config" "$R" "$WORK"
  [ "$RC" = 0 ] || fail "odd_names failed rc=$RC out=$OUT err=$ERR"
  expect_contains "$OUT" "f1=odd-1 ex=true" "spaces/quotes/backslash write+cat+exists"
  expect_contains "$OUT" "ls=renamed \"2\" 'b'.txt" "rename+ls on odd directory and file"
  expect_contains "$OUT" "d_gone=false" "rm+rmdir on odd directory"
  expect_contains "$OUT" "dash=dash-val ls_dash=-r" "leading-dash paths are not parsed as sftp flags"
  expect_contains "$OUT" "colon=colon-val" "colon in filenames is not parsed as host:path"
  ok "odd but legal names (spaces, quotes, backslashes, #hash, leading '-', ':') work across put/get/write/cat/ls/mkdir/rename/rm/rmdir"
fi

# ---- compile-only examples ----
for f in examples/*.lms scripts/lib/prompt-program.lms tests/fixtures/lmcode/*.lms; do
  if [ "$NEW_FEATURES" = 0 ] && { [ "$f" = "examples/deploy-file.lms" ] || [ "$f" = "tests/fixtures/lmcode/session.lms" ]; }; then continue; fi
  "$LMSCRIPT" --check "$f" >"$WORK/compile.out" 2>&1 || { cat "$WORK/compile.out" >&2; fail "lmcode source $f does not check"; }
done
ok "compile-only lmcode sources check against the merged schema; compiled bytes are pinned"
run_ex() { local n="$1"; shift; RC=0; LMSSH_SSH_CONFIG="$WORK/ssh_config" "$HOST" --lmcode "$HERE/examples/compiled/$n.dslb" -- "$@" >"$WORK/out.txt" 2>"$WORK/err.txt" || RC=$?; OUT="$(cat "$WORK/out.txt")"; ERR="$(cat "$WORK/err.txt")"; }
run_ex sign-verify; [ "$RC" = 0 ] || fail "sign-verify rc=$RC $OUT $ERR"
expect_contains "$OUT" "original verifies: true" "sign-verify"; expect_contains "$OUT" "tampered verifies: false" "sign-verify"
run_ex issue-cert "$WORK/ca-out"; [ "$RC" = 0 ] || fail "issue-cert rc=$RC $OUT $ERR"
[ -s "$WORK/ca-out/user-cert.pub" ] || fail "certificate not written"
"$HOST" ssh-keygen -L -f "$WORK/ca-out/user-cert.pub" | grep -q "deploy" || fail "certificate principals"
ok "examples sign-verify and issue-cert (offline) produce verified signatures and a certificate with principals"
run_ex known-hosts "$WORK/nohosts" example.org; contains "$OUT" "unknown" || fail "known-hosts: $OUT"
if [ "$E2E" = 1 ]; then
  run_ex run-command testhost 'echo example-run'; [ "$RC" = 0 ] && contains "$OUT" "example-run" || fail "run-command rc=$RC $OUT $ERR"
  run_ex run-command testhost 'echo oops >&2; exit 7'; [ "$RC" = 4 ] && contains "$OUT" "exit 7: oops" || fail "run-command failure rc=$RC $OUT"
  printf '# fleet\ntesthost\n\ntesthost\n' > "$WORK/hosts.txt"
  run_ex fleet-check "$WORK/hosts.txt" 'echo up' "$WORK/fleet.report"; [ "$RC" = 0 ] && contains "$OUT" "2 ok, 0 failed" || fail "fleet-check rc=$RC $OUT $ERR"
  run_ex fleet-check "$WORK/hosts.txt" 'exit 2' "$WORK/fleet.report"; [ "$RC" = 4 ] && grep -q "failed testhost:2" "$WORK/fleet.report" || fail "fleet-check failure rc=$RC $OUT $(cat "$WORK/fleet.report" 2>/dev/null)"
  echo "release-bits" > "$WORK/artifact.bin"
  run_ex deploy-file testhost "$WORK/artifact.bin" "$R/artifact.bin"; [ "$RC" = 0 ] || fail "deploy-file rc=$RC $OUT $ERR"
  [ "$(cat "$R/artifact.bin")" = release-bits ] && [ ! -e "$R/artifact.bin.lmssh-new" ] || fail "deploy-file result"
  echo "log-line" > "$R/app.log"
  run_ex fetch-files "$WORK/hosts.txt" "$R/app.log" "$WORK/fetched"; [ "$RC" = 0 ] && [ "$(cat "$WORK/fetched/testhost/app.log")" = log-line ] || fail "fetch-files rc=$RC $OUT $ERR"
  run_ex fetch-files "$WORK/hosts.txt" "$R/missing.log" "$WORK/fetched2"; [ "$RC" = 4 ] || fail "fetch-files missing rc=$RC"
  mkdir -p "$R/m"; echo 1 > "$R/m/one"; echo 2 > "$R/m/two"
  run_ex mirror-dir testhost "$R/m" "$WORK/mirror"; [ "$RC" = 0 ] && contains "$OUT" "fetched 2 of 2" && [ "$(cat "$WORK/mirror/two")" = 2 ] || fail "mirror-dir rc=$RC $OUT $ERR"
  run_ex mirror-dir testhost "$R/m" "$WORK/mirror"; contains "$OUT" "fetched 0 of 2" || fail "mirror-dir is not idempotent: $OUT"
  cp "$WORK/id_client" "$WORK/id_old"; cp "$WORK/id_client.pub" "$WORK/id_old.pub"
  run_ex rotate-key testhost "$WORK/id_old" "$WORK/id_new" "$WORK/authorized_keys"; [ "$RC" = 0 ] || fail "rotate-key rc=$RC $OUT $ERR"
  ! grep -qF "$(cut -d' ' -f2 "$WORK/id_old.pub")" "$WORK/authorized_keys" && grep -qF "$(cut -d' ' -f2 "$WORK/id_new.pub")" "$WORK/authorized_keys" || fail "rotate-key left authorized_keys wrong"
  ok "examples run-command, fleet-check, deploy-file, fetch-files, mirror-dir, rotate-key work against the test server"
else
  echo "skip: end-to-end checks need an sshd (none usable here)"
fi
echo "PASS: $pass checks"

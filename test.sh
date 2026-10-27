#!/usr/bin/env bash
# Build (unless SKIP_BUILD=1) and test lmssh. Needs: cmake, a C/C++ toolchain, autoconf/automake, static libcrypto/libz,
# python3, an lmscript v5 compiler (scripts/select-compiler.sh) and, for the end-to-end checks, an sshd binary
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

LMSCRIPT="$(scripts/select-compiler.sh)"
ok "DSL v5 compiler found: $LMSCRIPT"

# ---- identity, schema, static linking ----
want_version="$(sed -n 's/^project(lmssh VERSION \([0-9.]*\).*/\1/p' CMakeLists.txt)"
[ "$("$HOST" --version)" = "lmssh $want_version" ] || fail "--version"
ok "--version is lmssh $want_version"
"$HOST" --dsl-schema --json | cmp - schema/lmssh.dsl.json || fail "embedded schema differs from schema/lmssh.dsl.json"
ok "--dsl-schema --json is byte-identical to schema/lmssh.dsl.json"
"$HOST" --dsl-signatures > "$WORK/host.sig"
"$LMSCRIPT" --dsl-signatures schema/lmssh.dsl.json > "$WORK/compiler.sig"
diff "$WORK/host.sig" "$WORK/compiler.sig" >/dev/null || fail "registry signatures differ from the compiler's reading of the schema"
ok "registry signatures match the compiler ($(wc -l < "$WORK/host.sig" | tr -d ' ') signatures)"
cmp schema/lmssh.host.json schema/lmssh.dsl.json || fail "generated schema differs from host-only input"
python3 scripts/merge-std.py --host-only schema/lmssh.dsl.json "$WORK/host-only-schema.json"
cmp schema/lmssh.dsl.json "$WORK/host-only-schema.json" || fail "embedded schema still declares standard members"
"$HOST" --dsl-signatures >"$WORK/registry-signatures.txt"
"$LMSCRIPT" --dsl-signatures cpp/std/lmcode-std.schema.json >"$WORK/standard-signatures.txt"
python3 - "$WORK" <<'PYHOST'
from pathlib import Path
import sys
work=Path(sys.argv[1])
registry=set((work/'registry-signatures.txt').read_text().splitlines())
standard=set((work/'standard-signatures.txt').read_text().splitlines())
assert len(standard)==72, len(standard)
(work/'host-signatures.txt').write_bytes(''.join(line+'\n' for line in sorted(registry-standard)).encode('utf-8'))
PYHOST
diff -u <("$LMSCRIPT" --dsl-signatures schema/lmssh.dsl.json --without-std) "$WORK/host-signatures.txt" || fail "host-only registry/compiler signatures differ"
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
rc=0; "$HOST" --dsl >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "--dsl without file: $rc"
rc=0; "$HOST" --dsl --oops x.dslb >/dev/null 2>&1 || rc=$?; [ "$rc" = 2 ] || fail "--dsl with option-like file: $rc"
ok "usage errors exit 2"

# ---- DSL helpers ----
SCHEMA="$HERE/schema/lmssh.dsl.json"
dsl() { # dsl NAME [host args...] < body  -> compiles and runs; sets RC, OUT, ERR
  local name="$1"; shift
  { printf 'p = _dsl_ schema="%s";\n' "$SCHEMA"; cat; printf 'end _dsl_\nsavedsl(p, "%s");\n' "$WORK/$name.dslb"; } > "$WORK/$name.lms"
  "$LMSCRIPT" "$WORK/$name.lms" >"$WORK/compile.out" 2>&1 || { cat "$WORK/compile.out" >&2; fail "compile $name"; }
  RC=0; "$HOST" "$@" --dsl "$WORK/$name.dslb" >"$WORK/out.txt" 2>"$WORK/err.txt" || RC=$?
  OUT="$(cat "$WORK/out.txt")"; ERR="$(cat "$WORK/err.txt")"
}
dsl_args() { # dsl_args NAME -- ARGS < body
  local name="$1"; shift; shift
  { printf 'p = _dsl_ schema="%s";\n' "$SCHEMA"; cat; printf 'end _dsl_\nsavedsl(p, "%s");\n' "$WORK/$name.dslb"; } > "$WORK/$name.lms"
  "$LMSCRIPT" "$WORK/$name.lms" >"$WORK/compile.out" 2>&1 || { cat "$WORK/compile.out" >&2; fail "compile $name"; }
  RC=0; "$HOST" --dsl "$WORK/$name.dslb" -- "$@" >"$WORK/out.txt" 2>"$WORK/err.txt" || RC=$?
  OUT="$(cat "$WORK/out.txt")"; ERR="$(cat "$WORK/err.txt")"
}

# ---- no-network DSL: keys, io, strings, report ----
dsl keys <<E2
let dir = io.temp_dir();
let k = keys.generate(dir + "/k", "ed25519", "kc@test", "pw1");
io.print(k.type() + "|" + k.comment() + "|" + str(k.bits()));
keys.change_passphrase(dir + "/k", "pw1", "pw2");
io.print(k.public_with("pw2"));
io.print(str(io.exists(dir + "/k.pub")) + str(io.exists(dir + "/none")));
let l = str_split("a,b,,c", ",");
io.print(str(l.len()) + l.at(2) + l.at(3) + l.join("+"));
io.print(str_upper("x") + str(str_to_int("41") + 1) + io.sha256(dir + "/k.pub"));
report.add("kind", "file", 3, "line1\nline2");
report.write_text(dir + "/r.txt"); report.write_json(dir + "/r.json");
io.print(io.read(dir + "/r.txt") + io.read(dir + "/r.json"));
let again = keys.generate(dir + "/k", "ed25519");
E2
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

dsl_args sigs -- A1 <<E2
io.fail("custom verdict " + io.args().at(0));
E2
[ "$RC" = 4 ] || fail "io.fail must exit 4 (rc=$RC)"; expect_contains "$OUT" "custom verdict A1" "io.fail message"
ok "io.fail exits 4 with the script's own message"

rc=0; "$HOST" --dsl "$WORK/missing.dslb" >/dev/null 2>&1 || rc=$?; [ "$rc" = 3 ] || fail "missing bytecode rc=$rc"
printf '{"dsl.schema":2,"name":"other","types":{},"functions":{},"context":{}}' > "$WORK/other.schema.json"
printf 'p = _dsl_ schema="%s";\nwhile (false) {}\nend _dsl_\nsavedsl(p, "%s");\n' "$WORK/other.schema.json" "$WORK/other.dslb" > "$WORK/other.lms"
"$LMSCRIPT" "$WORK/other.lms" >/dev/null 2>&1
rc=0; "$HOST" --dsl "$WORK/other.dslb" >"$WORK/o.txt" 2>&1 || rc=$?; [ "$rc" = 3 ] || fail "schema mismatch rc=$rc"
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
  for _ in $(seq 1 50); do (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null && { E2E=1; break; }; sleep 0.1; done
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

  dsl session <<E2
ssh.config("$WORK/ssh_config");
let s = ssh.connect("testhost");
let r = s.exec("echo out; echo err >&2; exit 3");
io.print("st=" + str(r.status()) + " ok=" + str(r.ok()) + " out=" + str_trim(r.stdout()) + " err=" + str_trim(r.stderr()));
io.print("who=" + s.output("id -un"));
io.print("stdin=" + str_trim(s.exec("cat", "from-stdin").stdout()));
io.write("$WORK/up.txt", "payload");
s.put("$WORK/up.txt", "$R/up.txt");
io.print("cat=" + s.cat("$R/up.txt"));
s.write("$R/w.txt", "written");
io.print("exists=" + str(s.exists("$R/w.txt")) + str(s.exists("$R/none")));
s.mkdir("$R/d"); s.rename("$R/w.txt", "$R/d/w2.txt");
io.print("ls=" + s.ls("$R/d").join(","));
s.rm("$R/d/w2.txt"); s.rmdir("$R/d");
io.print("gone=" + str(s.exists("$R/d")));
io.mkdir("$WORK/tree/sub"); io.write("$WORK/tree/a.txt", "A"); io.write("$WORK/tree/sub/b.txt", "B");
s.put_dir("$WORK/tree", "$R/tree");
s.get_dir("$R/tree", "$WORK/back");
io.print("back=" + io.read("$WORK/back/sub/b.txt"));
io.print("sftp=" + str_trim(s.sftp("pwd").stdout()));
io.print("ok?=" + str(s.ok("true")) + str(s.ok("false")));
s.exec("exit 9").require();
E2
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

  dsl fleet <<E2
ssh.config("$WORK/ssh_config");
let hosts = str_list().add("testhost").add("testhost").add("testhost");
ssh.parallel(3);
let t0 = io.now();
let rs = ssh.each(hosts, "sleep 1; echo \$\$");
io.print("n=" + str(rs.len()) + " failed=" + str(rs.failed()) + " secs=" + str(io.now() - t0));
let bad = ssh.each(str_list().add("testhost"), "exit 5");
io.print("bad failed=" + str(bad.failed()));
bad.require_all();
E2
  [ "$RC" = 3 ] || fail "require_all must fail (rc=$RC)"
  expect_contains "$OUT" "n=3 failed=0" "each() results"
  secs="$(printf '%s' "$OUT" | sed -n 's/.*secs=\([0-9][0-9]*\).*/\1/p')"
  [ -n "$secs" ] && [ "$secs" -le 2 ] || fail "three 1s commands should overlap (sequential would take 3s+): $OUT"
  expect_contains "$OUT" "bad failed=1" "failed()"
  ok "Ssh.each runs commands in parallel and reports failures"

  dsl options <<E2
ssh.known_hosts("$WORK/known_hosts2").strict_host_key("accept-new").connect_timeout(10).port($PORT).user("$ME");
let a = ssh.connect("127.0.0.1").identity("$WORK/id_client");
io.print("direct=" + str_trim(a.output("echo d")));
let j = ssh.connect("127.0.0.1").config("$WORK/ssh_config").jump("localhost:$PORT");
io.print("jump=" + str_trim(j.output("echo j")));
let m = ssh.connect("127.0.0.1").identity("$WORK/id_client").reuse(true);
io.print("reuse=" + str_trim(m.output("echo m1")) + str_trim(m.output("echo m2")));
m.close();
let t = ssh.connect("127.0.0.1").identity("$WORK/id_client").timeout(2);
let r = t.exec("sleep 20");
io.print("timeout=" + str(r.timed_out()) + str(r.ok()) + str(r.status()));
let e = ssh.connect("127.0.0.1").identity("$WORK/id_enc").password("sekret");
io.print("askpass=" + str_trim(e.output("echo with-passphrase")));
let w = ssh.connect("127.0.0.1").identity("$WORK/id_enc").password("wrong");
io.print("wrong=" + str(w.exec("true").ok()));
let n = ssh.connect("127.0.0.1").strict_host_key("yes").known_hosts("$WORK/empty_hosts");
io.print("unknown host key refused=" + str(!n.exec("true").ok()));
E2
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
  dsl dry --dry-run <<E2
ssh.config("$WORK/ssh_config");
let s = ssh.connect("testhost");
s.exec("touch $R/dry.txt");
s.write("$R/dry.txt", "x");
io.write("$WORK/dry-local.txt", "x");
io.print("kept going");
E2
  [ "$RC" = 0 ] || fail "dry-run rc=$RC err=$ERR"
  expect_contains "$ERR" "[dry-run] ssh " "dry-run lists the ssh command"
  [ ! -e "$R/dry.txt" ] && [ ! -e "$WORK/dry-local.txt" ] || fail "dry-run changed something"
  ok "--dry-run prints the commands and changes nothing"

  # ---- security regressions: control-char injection, glob neutralization, odd legal names ----
  echo "keep" > "$R/victim.txt"
  dsl inject_nl <<E2
ssh.config("$WORK/ssh_config");
let s = ssh.connect("testhost");
s.exists("$R/ok\"\nrm \"$R/victim.txt");
E2
  [ "$RC" = 3 ] || fail "newline injection must fail with rc=3 (got $RC: $OUT $ERR)"
  expect_contains "$OUT" "contains a control character" "newline injection error"
  [ -f "$R/victim.txt" ] || fail "newline injection removed victim.txt"

  dsl inject_cr <<E2
ssh.config("$WORK/ssh_config");
let s = ssh.connect("testhost");
s.rm("$R/ok\rrm $R/victim.txt");
E2
  [ "$RC" = 3 ] || fail "CR injection must fail with rc=3 (got $RC: $OUT $ERR)"
  expect_contains "$OUT" "contains a control character" "CR injection error"

  dsl inject_put <<E2
ssh.config("$WORK/ssh_config");
let s = ssh.connect("testhost");
s.write("$R/ok\nbad.txt", "x");
E2
  [ "$RC" = 3 ] || fail "write newline path must fail with rc=3 (got $RC: $OUT $ERR)"
  expect_contains "$OUT" "contains a control character" "write newline error"

  dsl inject_user <<E2
ssh.user("-oProxyCommand=evil");
E2
  [ "$RC" = 3 ] || fail "option-like user must fail with rc=3 (got $RC: $OUT $ERR)"
  ok "control-character and option-injection attempts are rejected before invoking OpenSSH"

  mkdir -p "$R/glob_dir"
  printf 'victim-data' > "$R/glob_dir/victim.txt"
  printf 'brace-a' > "$R/glob_dir/brace_a.txt"
  printf 'brace-b' > "$R/glob_dir/brace_b.txt"
  dsl glob_check <<E2
ssh.config("$WORK/ssh_config");
let s = ssh.connect("testhost");
io.print("wild=" + str(s.exists("$R/glob_dir/*.txt")) + str(s.exists("$R/glob_dir/victim?.txt")) + str(s.exists("$R/glob_dir/victim[a-z].txt")) + str(s.exists("$R/glob_dir/brace_{a,b}.txt")));
s.write("$R/glob_dir/star*.txt", "lit-star");
s.write("$R/glob_dir/qmark?.txt", "lit-qmark");
s.write("$R/glob_dir/brack[a-z].txt", "lit-brack");
s.write("$R/glob_dir/brace{a,b}.txt", "lit-brace");
io.print("lit=" + s.cat("$R/glob_dir/star*.txt") + "|" + s.cat("$R/glob_dir/qmark?.txt") + "|" + s.cat("$R/glob_dir/brack[a-z].txt") + "|" + s.cat("$R/glob_dir/brace{a,b}.txt"));
s.get("$R/glob_dir/brack[a-z].txt", "$WORK/got_brack.txt");
io.print("got=" + io.read("$WORK/got_brack.txt"));
s.rm("$R/glob_dir/star*.txt");
s.rm("$R/glob_dir/qmark?.txt");
s.rm("$R/glob_dir/brack[a-z].txt");
s.rm("$R/glob_dir/brace{a,b}.txt");
io.print("survivors=" + s.cat("$R/glob_dir/victim.txt") + "|" + s.cat("$R/glob_dir/brace_a.txt") + "|" + s.cat("$R/glob_dir/brace_b.txt"));
E2
  [ "$RC" = 0 ] || fail "glob_check failed rc=$RC out=$OUT err=$ERR"
  expect_contains "$OUT" "wild=falsefalsefalsefalse" "globs and braces do not expand on exists/ls"
  expect_contains "$OUT" "lit=lit-star|lit-qmark|lit-brack|lit-brace" "literal glob/brace filenames round-trip via write/cat"
  expect_contains "$OUT" "got=lit-brack" "literal bracket filename round-trips via get"
  expect_contains "$OUT" "survivors=victim-data|brace-a|brace-b" "rm on literal glob/brace filenames leaves matching siblings untouched"
  ok "glob (* ? [) and brace ({a,b}) characters are neutralized across sftp and scp operations"

  dsl odd_names <<E2
ssh.config("$WORK/ssh_config");
let s = ssh.connect("testhost");
let d = "$R/odd dir \"quote\" 'single' #hash";
s.mkdir(d);
let f1 = d + "/space \"quote\" 'tick' \\\\back.txt";
s.write(f1, "odd-1");
io.print("f1=" + s.cat(f1) + " ex=" + str(s.exists(f1)));
let f2 = d + "/renamed \"2\" 'b'.txt";
s.rename(f1, f2);
io.print("ls=" + s.ls(d).join("|"));
s.rm(f2);
s.rmdir(d);
io.print("d_gone=" + str(s.exists(d)));
s.mkdir("$R/-l");
s.write("$R/-l/-r", "dash-val");
io.print("dash=" + s.cat("$R/-l/-r") + " ls_dash=" + s.ls("$R/-l").join(","));
s.rm("$R/-l/-r");
s.rmdir("$R/-l");
io.write("$WORK/local:colon.txt", "colon-val");
s.put("$WORK/local:colon.txt", "$R/remote:colon.txt");
s.get("$R/remote:colon.txt", "$WORK/back:colon.txt");
io.print("colon=" + io.read("$WORK/back:colon.txt"));
s.rm("$R/remote:colon.txt");
E2
  [ "$RC" = 0 ] || fail "odd_names failed rc=$RC out=$OUT err=$ERR"
  expect_contains "$OUT" "f1=odd-1 ex=true" "spaces/quotes/backslash write+cat+exists"
  expect_contains "$OUT" "ls=renamed \"2\" 'b'.txt" "rename+ls on odd directory and file"
  expect_contains "$OUT" "d_gone=false" "rm+rmdir on odd directory"
  expect_contains "$OUT" "dash=dash-val ls_dash=-r" "leading-dash paths are not parsed as sftp flags"
  expect_contains "$OUT" "colon=colon-val" "colon in filenames is not parsed as host:path"
  ok "odd but legal names (spaces, quotes, backslashes, #hash, leading '-', ':') work across put/get/write/cat/ls/mkdir/rename/rm/rmdir"
fi

# ---- examples ----
EXOUT="$WORK/examples"; mkdir -p "$EXOUT"
for f in examples/*.lms; do
  n="$(basename "$f" .lms)"
  (cd examples && "$LMSCRIPT" "$n.lms" "$EXOUT/$n.dslb" >"$WORK/compile.out" 2>&1) || { cat "$WORK/compile.out" >&2; fail "example $n does not compile"; }
done
ok "every example compiles against the schema"
run_ex() { local n="$1"; shift; RC=0; LMSSH_SSH_CONFIG="$WORK/ssh_config" "$HOST" --dsl "$EXOUT/$n.dslb" -- "$@" >"$WORK/out.txt" 2>"$WORK/err.txt" || RC=$?; OUT="$(cat "$WORK/out.txt")"; ERR="$(cat "$WORK/err.txt")"; }
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

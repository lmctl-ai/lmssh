#!/usr/bin/env bash
# Build the OpenSSH client pieces lmssh links in: libssh.a, libopenbsd-compat.a and one archive of the
# ssh / sftp / scp / ssh-keygen objects whose main() is renamed (lmssh_<tool>_main). The pinned source is
# copied first, so third_party/ stays pristine. Usage: build-openssh.sh OUTDIR
# Env: OPENSSL_DIR (prefix holding include/openssl and lib/libcrypto.a, default /usr), CC, JOBS.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
SRC="$HERE/third_party/openssh-portable"
OPENSSL_DIR="${OPENSSL_DIR:-/usr}"
JOBS="${JOBS:-$( (nproc || sysctl -n hw.ncpu) 2>/dev/null || echo 2)}"
[ -f "$SRC/configure.ac" ] || { echo "run scripts/sync-openssh.sh first" >&2; exit 1; }
[ -f "$OUT/.stamp" ] && [ "$(cat "$OUT/.stamp")" = "$(cat "$HERE/openssh.lock" "$HERE/scripts/build-openssh.sh" | cksum)" ] && exit 0
rm -rf "$OUT/src" "$OUT/lib"
mkdir -p "$OUT/src" "$OUT/lib"
(cd "$SRC" && tar --exclude=.git -cf - .) | (cd "$OUT/src" && tar xf -)
cd "$OUT/src"

# Both scp.c and sftp.c define these two globals, which sftp-client.c shares; one definition serves the image.
# cleanup_exit() is defined by scp.c and clientloop.c: both are renamed here and dispatched by cpp/tools.c.
sed -i.bak -e 's/^int showprogress = 1;/extern int showprogress;/' \
           -e 's/^volatile sig_atomic_t interrupted = 0;/extern volatile sig_atomic_t interrupted;/' scp.c
grep -q '^extern int showprogress;' scp.c && grep -q '^extern volatile sig_atomic_t interrupted;' scp.c \
  || { echo "scp.c layout changed: update the global-sharing edit in build-openssh.sh" >&2; exit 1; }
rm -f scp.c.bak

autoreconf -i >/dev/null 2>&1
CONFIG_FLAGS=(--without-pam --without-selinux --without-kerberos5 --without-libedit --without-ldns
  --disable-pkcs11 --disable-security-key --without-hardening --disable-strip
  --with-ssl-dir="$OPENSSL_DIR" --with-zlib="${ZLIB_DIR:-$OPENSSL_DIR}" --with-privsep-path=/var/empty --prefix=/nonexistent)
CFLAGS="${CFLAGS:--O2}" LDFLAGS="${LDFLAGS:-}" ./configure "${CONFIG_FLAGS[@]}" >"$OUT/configure.log" 2>&1 \
  || { tail -30 "$OUT/configure.log" >&2; exit 1; }

TOOL_OBJS=(ssh.o readconf.o clientloop.o sshtty.o sshconnect.o sshconnect2.o mux.o ssh-pkcs11.o ssh-sk-client.o
  sftp.o sftp-client.o sftp-common.o sftp-glob.o sftp-usergroup.o progressmeter.o scp.o ssh-keygen.o sshsig.o)
BASE_CFLAGS="$(sed -n 's/^CFLAGS=//p' Makefile)"
run_make() { make "$@" >>"$OUT/make.log" 2>&1 || { tail -30 "$OUT/make.log" >&2; exit 1; }; }
run_make -j"$JOBS" libssh.a openbsd-compat/libopenbsd-compat.a
# Per-object defines: main() becomes an ordinary function; cleanup_exit() is split per tool.
build_obj() { local obj="$1"; shift; rm -f "$obj"; run_make "$obj" CFLAGS="$BASE_CFLAGS $*"; }
build_obj ssh.o -Dmain=lmssh_ssh_main
build_obj sftp.o -Dmain=lmssh_sftp_main
build_obj scp.o -Dmain=lmssh_scp_main -Dcleanup_exit=lmssh_scp_cleanup_exit
build_obj ssh-keygen.o -Dmain=lmssh_ssh_keygen_main
build_obj clientloop.o -Dcleanup_exit=lmssh_ssh_cleanup_exit
run_make -j"$JOBS" "${TOOL_OBJS[@]}"

cp libssh.a openbsd-compat/libopenbsd-compat.a "$OUT/lib/"
rm -f "$OUT/lib/libsshtools.a"
ar rcs "$OUT/lib/libsshtools.a" "${TOOL_OBJS[@]}"
cp config.h "$OUT/lib/config.h"
grep -o 'OpenSSH_[0-9.]*' version.h | head -1 > "$OUT/lib/openssh-version.txt"
cat "$HERE/openssh.lock" "$HERE/scripts/build-openssh.sh" | cksum > "$OUT/.stamp"
echo "openssh client objects built in $OUT/lib"

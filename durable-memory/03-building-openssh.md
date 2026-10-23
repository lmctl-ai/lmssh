# Building OpenSSH into the image

## Pin

`openssh.lock` records repo, tag (`V_10_6_P1`) and commit (`a8c72b84…`). `scripts/sync-openssh.sh` fetches exactly that commit shallowly into git-ignored `third_party/openssh-portable`; `--verify` is a `test.sh` check. To move to a newer release: edit the lock (tag and commit), run the sync, rebuild, run `./test.sh`. The three source edits below are asserted by the build (it fails loudly if upstream changed the lines), and a changed set of colliding symbols shows up as a link error.

## `scripts/build-openssh.sh OUTDIR`

1. Copies the pinned tree to `OUTDIR/src` (the pristine tree is never touched) and applies the `scp.c` global-sharing edit (see 02).
2. `autoreconf -i`, then `configure` with: `--without-pam --without-selinux --without-kerberos5 --without-libedit --without-ldns --disable-pkcs11 --disable-security-key --without-hardening --disable-strip --with-ssl-dir=$OPENSSL_DIR --with-zlib=… --with-privsep-path=/var/empty --prefix=/nonexistent`. Nothing is installed; the prefix only has to be inert.
3. `make libssh.a openbsd-compat/libopenbsd-compat.a`.
4. Recompiles `ssh.o`, `sftp.o`, `scp.o`, `ssh-keygen.o`, `clientloop.o` with the `-D` renames, using the `CFLAGS` configure chose (so `-fno-strict-aliasing`, `-fno-builtin-memset` etc. are kept), then builds the other client objects (`readconf`, `sshconnect*`, `mux`, `sftp-client`, `progressmeter`, `sshsig`, the pkcs11/sk stubs, …).
5. Archives the client objects as `lib/libsshtools.a`; copies `libssh.a` and `libopenbsd-compat.a` next to it. A stamp (cksum of `openssh.lock` + the script) makes re-runs no-ops.

`ssherr-nolibcrypto.o` (which upstream's sftp/scp link) is deliberately left out: `libssh.a` already has `ssherr.o`, a superset.

CMake runs the script from an `add_custom_command` and links `libsshtools.a libssh.a libopenbsd-compat.a` (twice, for archive order), then OpenSSL's `libcrypto.a` and `libz.a`, found by `find_library(NAMES libcrypto.a …)` under `OPENSSL_DIR`.

## Static linking per platform

- **Linux, musl (releases)**: `scripts/docker-build.sh` builds inside `alpine:3.22` (`openssl-libs-static`, `zlib-static`). Result: `ldd` says "not a dynamic executable", and — unlike glibc — user, group and host lookups work without any shared NSS libraries on the target. This is what "no dependency" means in practice, including minimal containers.
- **Linux, glibc**: builds and runs (`cmake -S . -B build`), but `getpwnam`/`getaddrinfo` in a static glibc binary load NSS modules at run time (the linker warns). Fine for development on the same machine; use the musl build to ship.
- **macOS**: no fully static executables exist. The binary links `libSystem`, `libc++` and `libz` from the OS, and OpenSSL's `libcrypto.a` from Homebrew (`OPENSSL_DIR=$(brew --prefix openssl@3)`); the test asserts via `otool -L` that nothing else is linked.
- **Windows**: not supported (openssh-portable is a POSIX codebase; the Windows port is a separate project).

Binary size: about 7 MB stripped on Linux (most of it is OpenSSL's libcrypto). `-s` is passed on non-Apple platforms.

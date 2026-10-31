# Testing

`./test.sh` (builds first unless `SKIP_BUILD=1`; `BUILD_DIR=build-musl` points it at another build) runs 29 checks:

1. **Pins** — `sdk.lock` (sha256 of `cpp/dslvm.hpp`), `string-catalog.lock`, `openssh.lock` (commit of `third_party/openssh-portable`).
2. **Build and identity** — `--version` equals the CMake `project(VERSION)`; the embedded schema is byte-identical to `schema/lmssh.dsl.json`; the registry's signatures equal the compiler's reading of the schema (`lmscript --lmcode-signatures`); the schema regenerates identically from the registry; the binary is fully static (`ldd`) on Linux or links only system libraries (`otool -L`) on macOS.
3. **Original programs** — `lmssh ssh -V`, `sftp`/`scp` usage text (so `__progname` is right), `ssh-keygen` generate + fingerprint, symlink dispatch by `argv[0]`, usage errors exit 2.
4. **DSL without network** — keys, io, strings, report; refusing to overwrite a key; `io.fail` exit 4; missing bytecode and schema-hash mismatch exit 3.
5. **Against a real `sshd`** — started by the test on `127.0.0.1:<free port>` as the current user (`UsePAM no`, `StrictModes no`, key auth only, a host key and two client keys made by the test, one with a passphrase). Covers the interactive `ssh -F`, `sftp -b`, `scp` through this image; every `Session` operation; parallel `Ssh.each` timing; port/identity/user/known_hosts options; ProxyJump through this image; connection reuse and cleanup; timeout kill; passphrase through askpass (right and wrong); an unknown host key refused under `strict_host_key("yes")`; `--dry-run` changing nothing; no leftover `/tmp/lmssh-*`.
6. **Examples** — every `examples/*.lms` compiles; each runs against the test server (or offline) and its effect is checked on disk.

`LMSSH_REQUIRE_SSHD=1` turns a missing/unusable sshd into a failure (CI sets it); without it the end-to-end part is skipped with a message. Needs `python3` (free port) and an lmscript compiler that emits bytecode v5 (`scripts/select-compiler.sh` probes by compiling a chunk; `LMSCRIPT_BIN` overrides).

## Pitfalls worth remembering

- `ldd` exits non-zero on a static binary; with `pipefail` that fails the check unless it is wrapped (`|| true`).
- `cmd | grep -q` under `pipefail` fails when `grep` exits early and `cmd` gets SIGPIPE — capture into a variable instead.
- The test's own scratch directory must not match `/tmp/lmssh-*`, or the leak check finds itself.
- Defaults set with `ssh.identity()` apply to every later session: a "wrong passphrase" check passed because the unencrypted default key logged in. Give identities per session in tests.
- `report.write_text("/dev/stdout")` truncates a redirected stdout file; use `report.print()`.
- Examples that edit `~/.ssh/authorized_keys` (rotate-key) must be pointed at the test server's file with the optional fourth argument — the first version of the test edited the developer's real file (one appended line, removed by hand). Never let a test target the invoking user's real dotfiles.

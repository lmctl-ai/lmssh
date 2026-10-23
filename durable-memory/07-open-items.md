# Open items and known limits

- **No Windows.** openssh-portable does not build there; a Windows variant would mean wrapping Microsoft's Win32-OpenSSH or a different SSH library.
- **sftp without line editing.** libedit is off (static linking, extra dependency). Interactive `lmssh sftp` works but has no history/completion; batch use is unaffected.
- **No agent, no `ssh-keyscan`, no FIDO/PKCS#11, no GSSAPI.** Agent forwarding to a running system `ssh-agent` still works through `SSH_AUTH_SOCK` (the linked ssh is the client). `ssh-keyscan` would be a fifth renamed `main()` if automation needs host-key bootstrapping; today use `strict_host_key("accept-new")`.
- **Output is buffered in memory** without a cap, and `Session.cat` goes through a temp file. Very large transfers should use `get`/`put`.
- **askpass answers every non-host-key prompt with the same secret**; a server that asks several different questions (keyboard-interactive with OTP) is not supported. `NumberOfPasswordPrompts=1` avoids lockouts from repeated wrong passwords.
- **Host key policy is the caller's.** There is no `ssh-keyscan`-style trust-on-first-use helper; `accept-new` is the intended unattended mode.
- **ProxyJump only inherits `-F` config** (OpenSSH behaviour); documented in 04.
- **Fork per step** costs a few milliseconds and a full copy-on-write image; for thousands of short steps prefer `Ssh.each` or `reuse(true)`.
- **glibc static builds** (non-release) still need NSS shared objects at run time for user and host lookups; release builds use musl.
- **Possible later**: stream callbacks (line-by-line output), `Session.forward` for port forwarding, a `Result.json()` helper, an in-process tool mode (would need each OpenSSH `main()` to return rather than `exit()`).

# Architecture

```
                lmscript (.lms)  ──compile against schema/lmssh.dsl.json──▶  .dslb bytecode
                                                                                  │
 lmssh --lmcode x.dslb ─▶ cpp/main.cpp ─▶ dslvm::Program::load/run ─▶ cpp/host.cpp (registry)
                                                                                  │ argv + env + stdin
                                                                         cpp/runner.cpp  fork()
                                                                                  │
                                              child: cpp/tools.c ─▶ lmssh_{ssh,sftp,scp,ssh_keygen}_main()
                                                                    (OpenSSH code, libssh.a, libcrypto)
```

## One image, four `main()`s

`scripts/build-openssh.sh` compiles `ssh.c`, `sftp.c`, `scp.c` and `ssh-keygen.c` with `-Dmain=lmssh_<tool>_main`. `cpp/tools.c` calls them through `lmssh_run_tool(tool, argc, argv)`, which sets `__progname` (OpenSSH prints and logs under it) and fixes `argv[0]`.

Linking the four tools together produced exactly three symbol collisions (checked by linking; nothing else clashes):

| Symbol | Where | Resolution |
| --- | --- | --- |
| `showprogress`, `interrupted` | defined in both `scp.c` and `sftp.c`; `sftp-client.c` references them | `scp.c`'s definitions become `extern` declarations (a checked `sed` on the private source copy), so one definition serves both tools |
| `cleanup_exit` | defined in `scp.c` and `clientloop.c`; called from libssh's `fatal()` | both renamed (`lmssh_scp_cleanup_exit`, `lmssh_ssh_cleanup_exit`); `cpp/tools.c` defines `cleanup_exit` and dispatches on the running tool; sftp and ssh-keygen use `_exit` as upstream's `cleanup.o` does |

## Why a forked child per step

The OpenSSH programs are written as processes: they call `exit()`, keep state in globals, install signal handlers, and `ssh` may fork a ControlPersist master. Embedding them as functions would leak all of that into the host. `cpp/runner.cpp` therefore does `fork()`, and in the child: `setsid()` (no controlling terminal, so nothing can prompt on `/dev/tty`, and the whole process group can be killed on timeout), redirects stdin/stdout/stderr to pipes, closes other descriptors, sets the step's environment, and calls the tool. The parent multiplexes pipes with `poll()`, enforces timeouts with `kill(-pgid, SIGKILL)` (reported as status 124), and reaps. `run_all(specs, parallel)` drives several children at once for `Ssh.each`. The parent must never run the child's `exit()` path through its own destructors: `Host::shutdown()` checks `is_owner()` (pid) first. No threads exist anywhere, so `fork()` is safe.

## The executable re-enters itself

`sftp` and `scp` do not speak SSH themselves: they `execvp` an `ssh` program (`-S`, default `ssh` from `PATH`). `ssh -J` / `ProxyJump` builds a ProxyCommand that runs `argv[0]` again with `-W host:port`. A single-file product has no `ssh` on disk, so `lmssh_run_tool` passes `-S <this executable>` to `sftp` and `scp`, and `argv[0] = <this executable>` to `ssh`. `cpp/main.cpp` dispatches the re-entry:

1. `argv[0]` basename is `ssh`/`sftp`/`scp`/`ssh-keygen` → that program (symlink use, also makes `-S ssh`-style calls work).
2. `argv[1]` starts with a single `-` → the ssh client (every transport/ProxyJump invocation begins with an option; lmssh's own options start with `--`).
3. `argv[1]` is `ssh|sftp|scp|ssh-keygen|keygen` → that program with the remaining arguments, original options, original exit code. This is the interactive path and never forks.
4. `LMSSH_ASKPASS_SECRET` set and exactly one non-option argument → askpass mode (below).
5. Otherwise lmssh's own options: `--version`, `--lmcode-schema [--json]`, `--lmcode-signatures`, `[--dry-run] --lmcode FILE... [-- ARG...]`.

The executable's own path comes from `/proc/self/exe` (Linux) or `_NSGetExecutablePath` (macOS), falling back to `argv[0]` / `PATH`.

## Secrets: SSH_ASKPASS

A session with `password(secret)` (a login password or a key passphrase — OpenSSH asks the same way) runs the step with `SSH_ASKPASS=<this executable>`, `SSH_ASKPASS_REQUIRE=force`, `LMSSH_ASKPASS_SECRET=<secret>` and `BatchMode=no`; every other session runs with `BatchMode=yes` so an unattended script can never hang on a prompt. In askpass mode the executable prints the secret, except for host-key questions (`(yes/no`), which it answers `no` so unattended runs never trust an unknown key by accident. The secret lives only in the child's environment, never on a command line (error messages print command lines).

## Connection reuse

`reuse(true)` adds `ControlMaster=auto`, `ControlPath=<work>/c-%C`, `ControlPersist=120`. The work directory is a private `mkdtemp("/tmp/lmssh-XXXXXX")` (always `/tmp`: Unix socket paths are limited to ~104 bytes and macOS `$TMPDIR` is long). `Session.close()` sends `ssh -O exit`; `Host::shutdown()` (end of the run, success or error) exits every remaining master, then removes the directory. `test.sh` asserts nothing is left behind.

## State and limits

Objects handed to scripts live in deques owned by `Host` (stable addresses) and are freed at exit; each kind is capped at 65 536 as in lmhtml. Captured output is held in memory without a cap.

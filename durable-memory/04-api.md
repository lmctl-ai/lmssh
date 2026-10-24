# DSL API reference

The schema is `schema/lmssh.dsl.json`, generated from the registry by `scripts/gen-schema.py` (the registry in `cpp/host.cpp` is the source of truth; `test.sh` regenerates it and diffs, and diffs `lmssh --dsl-signatures` against the compiler). `lmssh --dsl-schema` prints every signature; `--dsl-schema --json` prints the schema bytes the VM binds bytecode to.

Contexts (global variables in a `_dsl_` block): `ssh: Ssh`, `keys: Keys`, `io: Io`, `report: Report`. The catalog `str_*` functions from lmcode-cpp (`str_trim`, `str_find`, `str_replace`, `str_starts_with`, `str_to_int`, …) are registered, plus `str_list()` and `str_split(s, sep)`.

## Errors and exit codes

A failing step throws a run error: the result line is `{"ok": false, "phase": "run", "code": "RUN_HOST", "message": …, "line": N}` and the exit status is **3**. `io.fail(msg)` (and `report.fail_if_any()`) end the run with code `APP_FAIL`, exit **4**. Load problems (missing/corrupt bytecode, schema hash mismatch, unbound import) are exit **3** before anything runs; usage errors are **2**. Success prints `{"ok": true, "result": null}` as the last line of stdout (`io.print` output comes before it). Failing *commands* are not errors until you ask: `exec` returns a `Result` whatever the remote exit status; `output`, `put`, `get`, `ls`, `mkdir`, … throw when the underlying program fails, with the program's first stderr line in the message.

## Ssh (context `ssh`) and Session

`ssh` holds **defaults**; `ssh.connect(dest)` returns a `Session` that starts as a copy (set defaults first). Setters return the receiver and exist on both:

| Setter | OpenSSH equivalent |
| --- | --- |
| `port(int)` | `-p` / `-P` |
| `user(string)` | `user@` prefix when `dest` has none |
| `identity(string)` | `-i` (repeatable; also adds `IdentitiesOnly=yes`) |
| `config(string)` | `-F` |
| `jump(string)` | `-J` |
| `known_hosts(string)` | `-o UserKnownHostsFile=` |
| `strict_host_key(string)` | `-o StrictHostKeyChecking=` (`yes`, `accept-new`, `no`, …) |
| `option(string)` | `-o Key=Value` (repeatable) |
| `connect_timeout(int)` | `-o ConnectTimeout=` (default 30 s) |
| `timeout(int)` | per-step wall clock limit in seconds, 0 = none; the step's process group is killed, `Result.timed_out()` is true, status 124 |
| `password(string)` | login password or key passphrase, via askpass (see 02) |
| `reuse(bool)` | ControlMaster/ControlPersist for this session |
| `parallel(int)` | fan-out of `Ssh.each` (1–256, default 8) |

`dest` is `[user@]host` or an `ssh_config` alias; IPv6 literals are bracketed automatically for scp. Options not set explicitly come from the usual places (`~/.ssh/config`, defaults).

Without `password(...)` every step runs with `BatchMode=yes`.

`Session` steps:

| Method | Via | Result |
| --- | --- | --- |
| `exec(cmd)`, `exec(cmd, stdin)` | ssh | `Result` (never throws on remote failure) |
| `output(cmd)` | ssh | stdout; throws unless exit status 0 |
| `ok(cmd)` | ssh | `bool`, exit status 0 |
| `put(local, remote)`, `get(remote, local)` | scp | throws on failure |
| `put_dir(local, remote)`, `get_dir(remote, local)` | scp -r | |
| `cat(remote)`, `write(remote, content)` | scp + a private temp file | string / void |
| `ls(dir)` → `StrList` (names), `exists(path)`, `mkdir`, `rm`, `rmdir`, `rename(a, b)` | sftp batch | |
| `sftp(batch)` | `sftp -b -` | `Result`; the batch text is on stdin, the `sftp> …` echo lines are removed from stdout |
| `close()` | `ssh -O exit` | stops this session's reuse master |
| `dest()` | | the destination string |

`Ssh.each(StrList dests, string cmd)` runs `cmd` on every destination with the defaults, `parallel` at a time, and returns a `ResultList` in input order: `len()`, `at(i)`, `failed()` (count), `require_all()` (throws listing every failure). `Ssh.shutdown()` closes masters and removes the work directory early.

`Result`: `ok()` (exit 0 and not timed out), `status()`, `stdout()`, `stderr()`, `dest()`, `timed_out()`, `require()` (throws with command, status and first stderr line, returns the Result).

## Keys (context `keys`) and Key

All through `ssh-keygen`; secrets are passed as arguments to an in-process child, never through a shell.

| Method | ssh-keygen |
| --- | --- |
| `bits(int)` | `-b` for later `generate` calls |
| `generate(path, type)`, `generate(path, type, comment, passphrase)` → `Key` | `-t -f -N -C`; refuses to overwrite an existing key |
| `load(path)` → `Key` | |
| `fingerprint(path)` | `-l` (the `SHA256:…` string) |
| `change_passphrase(path, old, new)` | `-p` |
| `set_comment(path, comment, passphrase)` | `-c` |
| `known_hosts_find(host, file)` → string (empty if absent) | `-F` |
| `known_hosts_remove(host, file)`, `known_hosts_hash(file)` | `-R`, `-H` |
| `certify(ca_key, pub, identity, principals, validity)` → path of `*-cert.pub` | `-s -I -n -V` |
| `sign(key, namespace, file)` → path of `file.sig` | `-Y sign` |
| `verify(allowed_signers, identity, namespace, sigfile, datafile)` → bool | `-Y verify` |

`Key`: `path()`, `public()` (reads `path.pub`, else derives it), `public_with(passphrase)`, `fingerprint()`, `type()` (`ed25519`, `rsa`, …), `comment()`, `bits()`.

## Io (context `io`)

`print`, `eprint`, `read`, `lines` (→ `StrList`), `write`, `append`, `exists`, `mkdir` (recursive), `remove` (recursive), `env(name)`, `args()` (script arguments after `--`), `temp_dir()` (private, removed at exit), `sha256(path)` (hex), `sleep_ms`, `now()` (epoch seconds), `fail(msg)` (exit 4).

## Report (context `report`)

Findings `(kind, file, line, message)` as in lmhtml: `add`, `count`, `text`, `print`, `write_text(path)` (`kind file:line: message` lines, control characters escaped), `write_json(path)`, `fail_if_any()` (exit 4 with "N finding(s)").

## `--dry-run`

No `ssh`/`sftp`/`scp`/`ssh-keygen` process starts; each would-be command line is printed to stderr as `[dry-run] …` and succeeds with empty output. Local mutations by `io.write/append/mkdir/remove` and `Session.write` temp files are skipped (reads still happen). Report files are still written — they are the run's output. Scripts that branch on remote output see empty strings, so a dry run shows the commands up to the first such branch.

## Patterns

- Fleet: build a `StrList` with `str_list().add(...)` or `io.lines(file)`, then one `ssh.each`.
- Verify before replace: `put` to `path.new`, check `sha256sum` against `io.sha256`, then `rename` (see `examples/deploy-file.lms`).
- Many steps on one host: `reuse(true)` makes later steps skip the handshake.
- Jump hosts only see `-F` config, not per-session `-i`/`-o` settings (this is how OpenSSH's ProxyJump works, with or without lmssh): put the bastion's identity and known-hosts policy in an `ssh_config` and pass it with `config()`.

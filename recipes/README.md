# Direct LMScript recipes

These recipes run through `lmctl` and use lmssh's published scripting API.
The older `examples/` files retain their compile-then-run bytecode workflow.

## Set an interactive Bash prompt

```bash
# Read-only preview; this connects and checks the target, without changing files.
lmctl recipes/set-prompt.lms web1 web1 expected-kernel-hostname
# Apply and verify:
lmctl recipes/set-prompt.lms web1 web1 expected-kernel-hostname --apply
```

The third argument is an optional kernel hostname check, separate from the
short display label. Use it in fleet scripts to catch a misrouted SSH alias.
SSH configuration, jump hosts, identities and known-host aliases are inherited;
strict host-key checking is enabled, without accepting unknown keys.

Fleet scripts can import `scripts/lib/prompt.lms` and call its function:

```text
set_host_prompt("web1", "web1", "internal-hostname-1", apply);
set_host_prompt("web2", "web2", "internal-hostname-2", apply);
```

Each function call executes a Python payload through `Session.exec(command,
stdin)`. The payload updates only one managed block at the end of the user's
`.bashrc`, with `PS1='label:\w\$ '`. Bash keeps the working directory dynamic,
abbreviates the home directory, and uses `#` for a root shell. This does not
change the operating system hostname, SSH configuration, keys, or other users'
startup files. No services or existing sessions are restarted or sent input.

Before changing a file it validates the destination hostname, label,
ownership, existing managed markers and candidate Bash syntax. Original bytes
are backed up under `~/.local/state/lmssh/prompt-backups/` (directory mode 0700,
file mode 0600). A staged file is atomically replaced, retaining its previous
mode and any `.bashrc` symlink. Interactive verification failure restores the
old bytes if no concurrent edit has replaced the candidate. Unchanged runs
make no backup and do not rewrite the file. An interrupted fleet run can be
rerun: hosts already configured will report `unchanged`.

The recipe prints only structured status/prompt information, never startup
file contents. Remote requirements are Python 3 and Bash 4.4+ (for verified
prompt expansion). Existing shells need `source ~/.bashrc`, or reconnect.
The prompt can be reverted by restoring the reported backup to the original
file, or removing the marked block after reviewing any later edits.

Run `python3 scripts/test-set-prompt.py` for isolated checks of preview,
rendering, unrelated secret preservation, backup privacy, idempotence,
destination validation, symlinks and rollback. These tests use temporary homes
and do not contact SSH hosts. The fleet is additionally checked using the
published lmssh binary; no changes to its C++ transport are required.

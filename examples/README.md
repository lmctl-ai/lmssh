# Examples

Each example is an lmscript file. Compile it with `lmscript NAME.lms NAME.dslb` from this directory (the schema path is relative), then run `lmssh --lmcode NAME.dslb -- ARGS...`. Set `LMSSH_SSH_CONFIG=/path/to/ssh_config` to use a specific `ssh_config(5)` file instead of `~/.ssh/config`. `lmssh --dry-run --lmcode ...` prints the commands without running them.

| Script | Does | Arguments |
| --- | --- | --- |
| `run-command.lms` | Run one command on one host; exit 4 if it fails | `DEST COMMAND` |
| `fleet-check.lms` | Run a command on every host of a file in parallel; failed hosts become findings | `HOSTS_FILE COMMAND [REPORT_FILE]` |
| `deploy-file.lms` | Upload a file, verify its sha256 on the remote side, rename it into place | `DEST LOCAL_FILE REMOTE_PATH` |
| `fetch-files.lms` | Copy one remote file from every host into `OUT_DIR/<host>/` | `HOSTS_FILE REMOTE_PATH OUT_DIR` |
| `mirror-dir.lms` | Download files of a remote directory that are not yet local (sftp listing, scp copy) | `DEST REMOTE_DIR LOCAL_DIR` |
| `rotate-key.lms` | Create a new key, install it, prove it logs in, then drop the old one from `authorized_keys` | `DEST OLD_KEY NEW_KEY [AUTHORIZED_KEYS_PATH]` |
| `known-hosts.lms` | Report which hosts have a key on file; `LMSSH_FORGET=1` removes them | `KNOWN_HOSTS HOST...` |
| `sign-verify.lms` | Sign a file with `ssh-keygen -Y sign`, verify it, show that a tampered copy fails (offline) | none |
| `issue-cert.lms` | Create a CA and a user key and issue a user certificate (offline) | `OUT_DIR` |

`./test.sh` compiles every example and runs them against a throw-away `sshd` on `127.0.0.1`, so the scripts stay working.

# Purpose and place

lmssh is a single, statically linked executable for **automating SSH**. It contains OpenSSH's client programs — `ssh`, `sftp`, `scp`, `ssh-keygen` — and a bytecode VM ([lmcode-cpp](https://github.com/lmctl-ai/lmcode-cpp) `dslvm.hpp`) that runs lmscript `_dsl_` programs against a schema describing what the host offers. It follows the same pattern as the sibling hosts `../lmhtml` (HTML, lexbor) and `../lmcad`: the host owns the process and the objects, the script only calls what the registry offers.

## What it is for

Scripts that run commands across machines, move and verify files, rotate or issue keys, sign artifacts, audit `known_hosts`. Anything where the result matters more than the terminal: exit codes, captured output, findings, a `--dry-run` that prints the commands.

## What it is not

- **Not a replacement for OpenSSH.** There is no server (`sshd`), no `ssh-agent`/`ssh-add`, no `ssh-keyscan`. For interactive use, `lmssh ssh|sftp|scp|ssh-keygen ARGS` runs the original program with its original options, and nothing about those options was re-invented.
- **Not a reimplementation.** The protocol work is OpenSSH's own code (tag `V_10_6_P1`), including `ssh_config` parsing, `known_hosts` handling, `ProxyJump`, multiplexing, certificates and the sftp client. The DSL builds argument vectors for those programs and reads their results.
- **Not an API mirror of the command-line options.** The task was explicit: no need to expose the original option set to scripts. Anything not covered by a setter can be passed with `option("Key=Value")` (ssh `-o`), `config(path)` (`-F`), or a raw `sftp` batch.

## Scope boundary: host vs script

Host (C++): process management, argument assembly, captured stdio, timeouts, parallel fan-out, askpass, temp files, hashing, report files. Script (lmscript): which hosts, which commands, what counts as a failure, what to do next. The VM does no type checks at call time; the host validates every argument kind (`check_args` in `cpp/host.cpp`) because bytecode is trusted like host code but mistakes should read well.

## Licensing

The project code is MIT, matching the siblings. OpenSSH's licence file is a collection of BSD/ISC/MIT-style and public-domain terms (no GPL), which MIT-licensed code may link with; the one unusual clause (Tatu Ylönen's: derived versions must be marked as such and not be called "ssh" or "Secure Shell") is the reason the product is named lmssh and says so in the README and `THIRD_PARTY_NOTICES`. OpenSSL 3 is Apache-2.0, zlib is zlib, musl is MIT; GCC's runtime library exception covers libstdc++/libgcc. `THIRD_PARTY_NOTICES` reproduces what binary redistribution requires and ships next to every release binary.

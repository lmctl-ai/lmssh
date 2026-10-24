# lmssh durable memory

Design, build and operating notes for the lmssh host (OpenSSH client programs + lmcode-cpp, scripted by lmscript `_dsl_` bytecode). Read in numeric order.

- `01-purpose-and-place.md` — what lmssh is and is not; relation to OpenSSH, lmcode-cpp, lmscript, lmhtml/lmcad; scope boundary.
- `02-architecture.md` — one image, four programs: renamed `main()`s, symbol collisions, the fork runner, argv dispatch, why sftp/scp/ProxyJump re-enter the same executable.
- `03-building-openssh.md` — the pinned source, `scripts/build-openssh.sh` step by step, configure flags, static linking (musl vs glibc vs macOS), how to bump the OpenSSH pin.
- `04-api.md` — the DSL surface: contexts, types, every method, error and exit-code behaviour, option inheritance, worked patterns.
- `05-testing.md` — `test.sh` layout, the throw-away sshd, what each check protects, pitfalls hit while writing it.
- `06-ci-release.md` — GitHub Actions matrix, artifacts, release flow, versioning rule.
- `07-open-items.md` — known limits and ideas not done (Windows, libedit, agent, FIDO, in-process mode, ...).

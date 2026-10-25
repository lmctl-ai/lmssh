# lmssh durable memory

`lmssh` is a static, dependency-free lmscript `_dsl_` host embedding OpenSSH client programs (ssh, scp, sftp) and `lmcode-cpp` for programmatic remote automation, secure copy, and multiplexed sessions.
Repository: https://github.com/lmctl-ai/lmssh.

## 60-second takeover

```sh
scripts/sync-deps.sh                  # Download and prepare OpenSSH source tree
scripts/build-openssh.sh              # Build static OpenSSH client libraries
cmake -S . -B build                   # Configure CMake build
cmake --build build --parallel 4      # Build binary at build/lmssh
./test.sh                             # Run full test suite with throw-away sshd
```

## Document map

| File | Contents |
| --- | --- |
| [01-purpose-and-place.md](01-purpose-and-place.md) | Scope, OpenSSH client integration, and script execution boundary |
| [02-architecture.md](02-architecture.md) | Single binary image containing ssh, scp, and sftp dispatch |
| [03-building-openssh.md](03-building-openssh.md) | Building OpenSSH static archives, musl vs glibc, build flags |
| [04-api.md](04-api.md) | DSL surface, session context, commands, and error handling |
| [05-testing.md](05-testing.md) | Integration test suite, throw-away sshd daemon, and security tests |
| [06-ci-release.md](06-ci-release.md) | GitHub Actions matrix, platform targets, and release procedure |
| [07-open-items.md](07-open-items.md) | Backlog, Windows port ideas, agent forwarding, FIDO support |
| [07-sdk-catalog.md](07-sdk-catalog.md) | Shared SDK catalogs, collection arena, and std schema merge rules |

## SDK pin and sync

The vendored SDK headers and standard catalogs are pinned in `sdk.lock` pointing to `https://github.com/lmctl-ai/lmcode-cpp`:
```sh
scripts/sync-sdk.sh                   # Refetches pinned headers and verifies sha256
```

## Adding an example or function

### Adding an example
1. Create `examples/<name>.lms` using `_dsl_ cli="lmssh" install="github:lmctl-ai/lmssh@latest"`.
2. Run script: `build/lmssh run examples/<name>.lms` or via `lmscript`.
3. Add the example to `./test.sh` test run list.
4. Add terminal output image to `docs/images/<name>.png` and update `README.md` demo table with `lmctl autorun` command.

### Adding a host function
1. Declare function/method in `schema/lmssh.host.json`.
2. Reconfigure CMake to copy the exact host-only bytes into `schema/lmssh.dsl.json`; lmscript >=0.2.420 resolves std implicitly.
3. Register and implement the function in C++ source under `src/` using `dslvm::Registry`.
4. Rebuild and verify schema synchronization with `cmake --build build` and `./test.sh`.

## Releases

Releases are triggered automatically on push across Linux and macOS platforms. Platform binaries are published with `SHA256SUMS`, `LICENSE`, and `THIRD_PARTY_NOTICES`.

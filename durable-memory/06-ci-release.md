# CI and releases

`.github/workflows/ci.yml`:

| Job | Runner | How it builds |
| --- | --- | --- |
| linux-x64 | `ubuntu-24.04` | `scripts/docker-build.sh` (Alpine, musl, fully static), then `test.sh` on the runner against the static result with the runner's `sshd` |
| linux-arm64 | `ubuntu-24.04-arm` | same |
| macos-arm64 | `macos-15` | Homebrew `openssl@3 autoconf automake ninja`; `OPENSSL_DIR=$(brew --prefix openssl@3)` |
| macos-x64 | `macos-15-intel` | same |

All jobs install the lmscript compiler from npm (`@lmctl-ai/lmctl`, pinned version in the workflow; needs Node ≥ 24) because the tests compile scripts. Actions are pinned by commit SHA, build jobs have `contents: read` and `persist-credentials: false`; only the tag-gated release job has `contents: write`. Docs-only pushes (`durable-memory/**`, `**.md`) skip the matrix.

Each build job uploads `lmssh-<platform>` (+ `LICENSE`, `THIRD_PARTY_NOTICES`). On a `v*` tag the release job downloads them, checks that `lmssh --version` of the linux-x64 asset equals `lmssh <tag without v>`, and creates (or updates, idempotently) a GitHub release with every file attached.

**Versioning rule:** the version lives in `CMakeLists.txt` `project(lmssh VERSION x.y.z)`. Bump it, commit, then tag `vx.y.z`; the release job fails if they differ.

## Releasing

```sh
# edit CMakeLists.txt VERSION, then
git commit -am "Release 0.1.1" && git tag v0.1.1 && git push origin main v0.1.1
```

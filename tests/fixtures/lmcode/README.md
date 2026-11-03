# lmcode test fixtures

The `.lms` files are compile-only lmcode bodies used by the native host tests.
`test.sh` runs the pinned `.dslb` copies so the public CI job needs no private
compiler source. To regenerate a bytecode pin, build the compiler-library API
from mono main and run:

```sh
LMCODE_COMPILER_MODULE=/absolute/mono/lmscript/dist/dsl.js \
  node scripts/compile-lmcode-fixture.mjs tests/fixtures/lmcode/keys.lms /tmp/keys.dslb
```

Update `manifest.json` with source/schema/output hashes after review. Keep bytecode
generation in this low-level test tooling; do not add an output-file header to
lmcode programs.

For the prompt program, regenerate with the canonical output path:

```sh
LMCODE_COMPILER_MODULE=/absolute/mono/lmscript/dist/dsl.js \
  node scripts/compile-lmcode-fixture.mjs scripts/lib/prompt-program.lms scripts/fixtures/prompt.dslb
```

That also emits the caller-relative `scripts/lib/prompt-bytecode.lms` data module.
The wrapper decodes it into its own temporary file and removes that file after the
native invocation, so imports work from foreign working directories without a
runtime compiler-library dependency. The options transport is one JSON argument.
The test uses the actual wrapper and VM command builder with an isolated SSH
boundary, then executes Python/Bash against a private home. The single-backslash
Bash prompt encoding is intentionally pinned, correcting the old double-escaped
spelling while preserving the intended rendered prompt.

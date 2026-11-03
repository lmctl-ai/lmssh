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

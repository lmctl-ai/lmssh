# Shared SDK catalogs

`scripts/sync-sdk.sh` vendors `cpp/dslvm.hpp` and every `stdlib/*.hpp` from the same committed lmcode-cpp revision. `sdk.lock` records the source commit and a `sha256.<path>` entry for every file. `--verify` checks both the lock entries and every vendored header; it does not need a sibling SDK checkout. The separate string catalog lock and verifier are superseded by this pin.

The host registers the SDK string and collections catalogs. `lmssh::StrList` aliases `dslvm::stdlib::StrList`; native list results from `Session.ls`, `Io.args` and `Io.lines` are allocated through `Host::collections.make_str_list`. `Ssh.each` consumes the same type. Existing list methods, byte splitting, empty fields, errors and chaining are preserved. The schema includes the SDK's superset (`set`, `index_of`, `clear`, numeric lists and insertion-ordered maps), generated from the registry like the domain API.

The collection arena owns stable-address objects for a chunk run and is reset before each chunk. The shared limit is 65,536 live collection objects across all four SDK collection types. Domain objects such as sessions and ResultList retain their separate host-owned storage and lifecycle.

## Built-in std transition

Registry construction installs the complete standard by default. The host has no std registration calls or collection arena member. Native SSH/io list producers allocate through the registry-owned run arena, which Program::run resets on entry and exit. Domain ResultList/session ownership remains separate.

Only `schema/lmssh.host.json` is the checked-in declaration source; CMake copies its exact bytes into the ignored embedded schema, published lmscript >=0.2.420 supplies std implicitly, and effective/`--without-std` parity retains SSH/ResultList APIs and explicit testing declarations.

The built-in standard excludes testing helpers. The host schema explicitly declares `print` and `assert_close`, and host registration explicitly binds the optional SDK testing catalog, preserving the previous public signatures.

The pinned standard also supplies `file_read`, `file_write`, `file_append`, `file_exists`, and `file_lines` on raw bytes and native process-cwd paths. `file_lines` splits LF while retaining CR and trailing empty fields. SDK synchronization now pins nine artifacts, including `stdlib/file.hpp`.

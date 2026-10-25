#!/usr/bin/env bash
set -euo pipefail
MIN_VERSION="0.2.420"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lmcode-compiler-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) WORK="$(cd "$WORK" && pwd -W | tr '\\' '/')" ;;
esac
candidate="${LMSCRIPT_BIN:-}"
if [[ -z "$candidate" ]]; then candidate="$(command -v lmscript || true)"; fi
if [[ -z "$candidate" ]]; then echo "error: no lmscript compiler found; install @lmctl-ai/lmctl >= $MIN_VERSION or set LMSCRIPT_BIN" >&2; exit 2; fi
version="$("$candidate" --version 2>/dev/null || true)"
python3 - "$version" "$MIN_VERSION" <<'PY'
import re, sys
def parse(value):
    match = re.search(r'^lmscript\s+(\d+)\.(\d+)\.(\d+)(?:\+[A-Za-z0-9.-]+)?\s*$', value)
    return tuple(map(int, match.groups())) if match else None
got, minimum = parse(sys.argv[1]), parse('lmscript ' + sys.argv[2])
if got is None or got < minimum:
    print(f"error: lmscript must be >= {sys.argv[2]} (got {sys.argv[1] or 'unknown'})", file=sys.stderr)
    raise SystemExit(2)
PY
SCHEMA="$WORK/implicit-std.schema.json"
PROBE="$WORK/probe.lms"
cat > "$SCHEMA" <<'JSON'
{"dsl.schema":2,"name":"implicit_std_probe","types":{},"functions":{},"context":{}}
JSON
python3 - "$SCHEMA" "$PROBE" "$WORK" <<'PY'
import json, pathlib, sys
schema, probe, work = sys.argv[1:]
def source(marker):
    return (f'p = {marker} schema={json.dumps(schema)};\n'
            'let value = <<~STD_PROBE;\n'
            '  raw ${not_an_outer_field} "quotes"\n'
            '  STD_PROBE\n'
            'let n = str_len(value);\n'
            f'end {marker}\n'
            f'savedsl(p, {json.dumps(str(pathlib.Path(work) / (marker[1:-1] + ".dslb")))});\n')
pathlib.Path(probe).write_text(source('_dsl_'))
pathlib.Path(work, 'probe-lmcode.lms').write_text(source('_lmcode_'))
PY
for source in "$PROBE" "$WORK/probe-lmcode.lms"; do
  out="$WORK/$(basename "$source" .lms | sed 's/^probe$/dsl/; s/^probe-lmcode$/lmcode/')".dslb
  "$candidate" "$source" "$out" >"$WORK/compiler.out" 2>"$WORK/compiler.err" || { cat "$WORK/compiler.err" >&2; exit 2; }
  python3 - "$out" "$SCHEMA" <<'PY'
import hashlib, pathlib, sys
bytecode = pathlib.Path(sys.argv[1]).read_bytes()
schema = pathlib.Path(sys.argv[2]).read_bytes()
if bytecode[:6] != b'DSLB\x00\x05': raise SystemExit('error: compiler did not emit DSL bytecode v5')
if bytecode[6:38] != hashlib.sha256(schema).digest(): raise SystemExit('error: bytecode schema hash does not match raw host schema bytes')
PY
done
"$candidate" --dsl-signatures "$SCHEMA" | grep -Fq 'fn str_len(string) -> int' || { echo "error: compiler inspection surface lacks implicit std fn str_len(string) -> int" >&2; exit 2; }
printf '%s\n' "$candidate"

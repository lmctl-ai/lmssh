#!/usr/bin/env bash
set -euo pipefail
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lmcode-compiler-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) WORK="$(cd "$WORK" && pwd -W | tr '\\' '/')" ;;
esac
candidate="${LMSCRIPT_BIN:-}"
if [[ -z "$candidate" ]]; then candidate="$(command -v lmscript || true)"; fi
if [[ -z "$candidate" ]]; then echo "error: no lmscript compiler found; install @lmctl-ai/lmctl or set LMSCRIPT_BIN" >&2; exit 2; fi
SCHEMA="$WORK/lmssh-probe.schema.json"
PROBE="$WORK/lmssh-probe.lms"
cat > "$SCHEMA" <<'JSON'
{"dsl.schema":2,"name":"lmssh_probe","types":{},"functions":{},"context":{}}
JSON
cat > "$PROBE" <<EOF
program = _lmcode_ schema="$SCHEMA";
let sample = <<~PROBE_TEXT;
  byte-oriented lmcode
PROBE_TEXT
let length = str_len(sample);
end _lmcode_
EOF
"$candidate" --check "$PROBE" >"$WORK/check.out" 2>"$WORK/check.err" || { cat "$WORK/check.err" >&2; exit 2; }
"$candidate" --lmcode-signatures "$SCHEMA" | grep -Fq 'fn str_len(string) -> int' || { echo "error: compiler inspection surface lacks standard lmcode signatures" >&2; exit 2; }
printf '%s\n' "$candidate"

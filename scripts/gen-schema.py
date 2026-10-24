#!/usr/bin/env python3
"""Generate schema/lmssh.dsl.json from `lmssh --dsl-signatures` (the registry is the source of truth).

usage: gen-schema.py LMSSH_BINARY > schema/lmssh.dsl.json
The checked-in schema is verified against the compiler's own signature listing by test.sh.
"""
import json, re, subprocess, sys, importlib.util
from pathlib import Path

lines = subprocess.run([sys.argv[1], "--dsl-signatures"], check=True, capture_output=True, text=True).stdout.splitlines()
types, functions, context = {}, {}, {}
sig = re.compile(r"^(?:fn (\w+)|method (\w+)\.(\w+))\((.*?)\) -> (\w+)$")
for line in lines:
    if line.startswith("context "):
        name, typ = line[len("context "):].split(": ")
        context[name] = typ
        continue
    m = sig.match(line)
    if not m:
        sys.exit("unparsable signature: " + line)
    fn, typ, meth, params, ret = m.groups()
    entry = {"params": [p for p in params.split(", ") if p], "returns": ret}
    if fn:
        functions.setdefault(fn, []).append(entry)
    else:
        types.setdefault(typ, {"methods": {}})["methods"].setdefault(meth, []).append(entry)

def dump(value, indent=2, level=0):
    pad = " " * (indent * (level + 1))
    end = " " * (indent * level)
    if isinstance(value, dict):
        if all(isinstance(v, list) for v in value.values()) and level >= 2:
            items = [pad + json.dumps(k) + ": " + json.dumps(v, separators=(", ", ": ")) for k, v in value.items()]
        else:
            items = [pad + json.dumps(k) + ": " + dump(v, indent, level + 1) for k, v in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + end + "}"
    return json.dumps(value, separators=(", ", ": "))

schema = {"dsl.schema": 2, "name": "lmssh", "types": dict(sorted(types.items())),
          "functions": dict(sorted(functions.items())), "context": dict(sorted(context.items()))}
root = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("std_merge", root / "scripts/merge-std.py")
sys.dont_write_bytecode = True
bridge = importlib.util.module_from_spec(spec); spec.loader.exec_module(bridge)
standard = json.loads((root / "cpp/std/lmcode-std.schema.json").read_text())
sys.stdout.buffer.write((json.dumps(bridge.remove_standard(schema, standard), indent=2) + "\n").encode("utf-8"))

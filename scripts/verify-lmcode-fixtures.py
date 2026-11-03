#!/usr/bin/env python3
"""Verify the source/schema/bytecode pins used by offline lmssh host tests."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
manifest = json.loads((ROOT / "tests/fixtures/lmcode/manifest.json").read_text())
for relative, expected in manifest["sha256"].items():
    actual = hashlib.sha256((ROOT / relative).read_bytes()).hexdigest()
    if actual != expected:
        raise SystemExit(f"fixture pin differs: {relative}; regenerate with scripts/compile-lmcode-fixture.mjs")
print(f"verified {len(manifest['sha256'])} lmcode fixture pins from compiler main {manifest['compiler_main']}")

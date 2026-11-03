#!/usr/bin/env python3
"""Behavior parity for the pure prompt recipe argument parser."""
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
LMCTL = os.environ.get("LMCTL_BIN", "lmctl")
SOURCE = 'import "./scripts/lib/args.lms"; let parsed=parse_prompt_args(ARGV); println(json_stringify(parsed));'


def run(args, success=True):
    result = subprocess.run([LMCTL, "script", "-e", SOURCE, *args], cwd=ROOT,
                            text=True, capture_output=True, env=os.environ.copy())
    assert (result.returncode == 0) == success, result.stdout + result.stderr
    if success:
        return json.loads(result.stdout)
    return result.stdout + result.stderr


assert run(["web1", "web1"]) == {
    "destination": "web1", "label": "web1", "expected_hostname": "", "apply": False, "preview": False
}
assert run(["--apply", "web1", "prompt", "host.example"]) == {
    "destination": "web1", "label": "prompt", "expected_hostname": "host.example", "apply": True, "preview": False
}
assert run(["web1", "prompt", "--preview"]) == {
    "destination": "web1", "label": "prompt", "expected_hostname": "", "apply": False, "preview": True
}
assert run(["--dry-run", "web1", "prompt", "--dry-run"]) == {
    "destination": "web1", "label": "prompt", "expected_hostname": "", "apply": False, "preview": True
}
assert run(["-host", "prompt"]) == {
    "destination": "-host", "label": "prompt", "expected_hostname": "", "apply": False, "preview": False
}
assert "unknown flag: --unknown" in run(["web1", "prompt", "--unknown"], success=False)
assert "usage: DEST LABEL" in run(["web1"], success=False)
assert "choose preview or apply" in run(["web1", "prompt", "--apply", "--preview"], success=False)
print("PASS prompt args defaults, positional order, duplicate flags, legacy preview alias, errors")

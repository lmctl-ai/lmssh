#!/usr/bin/env python3
"""Prompt recipe behavior with isolated startup files; no SSH or real home edits."""
import json
import os
from pathlib import Path
import re
import socket
import stat
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "scripts/lib/prompt.lms").read_text()
match = re.search(r'let prompt_python=join\((\[.*?\]),"\\n"\);', source, re.S)
assert match
payload = "\n".join(json.loads(match.group(1)))
compile(payload, "prompt payload", "exec")


def main():
    version = subprocess.check_output(["bash", "-c", 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"'], text=True)
    if tuple(map(int, version.split("."))) < (4, 4):
        print("SKIP prompt recipe test: Bash 4.4+ required for prompt rendering verification")
        return
    with tempfile.TemporaryDirectory(prefix="lmssh-prompt-") as td:
        home = Path(td)
        (home / "repos").mkdir()
        canary = "DO_NOT_PRINT_THIS_TEST_SECRET"
        original = f"# existing startup\nexport PRIVATE_TEST_KEY='{canary}'\nPS1='old>'\n".encode()
        rc = home / ".bashrc"
        rc.write_bytes(original)
        rc.chmod(0o640)

        def run(apply=False, label="t4g2", expected=None, ok=True, extra_env=None):
            options = dict(label=label, expected_hostname=socket.gethostname() if expected is None else expected, apply=apply)
            env = dict(os.environ, HOME=str(home))
            env.update(extra_env or {})
            result = subprocess.run(["python3", "-", json.dumps(options)], input=payload,
                                    env=env, text=True, capture_output=True, timeout=45)
            assert (result.returncode == 0) == ok, result.stdout + result.stderr
            assert canary not in result.stdout + result.stderr
            return json.loads(result.stdout) if ok else result

        preview = run()
        assert preview["status"] == "preview" and rc.read_bytes() == original
        assert not (home / ".local/state/lmssh/prompt-backups").exists()
        changed = run(apply=True)
        assert changed["status"] == "updated"
        assert changed["rendered_prompt"] == "t4g2:~/repos" + ("# " if os.geteuid() == 0 else "$ ")
        assert b"PRIVATE_TEST_KEY" in rc.read_bytes()
        assert rc.read_bytes().startswith(original.rstrip(b"\n"))
        backup = Path(changed["backup"])
        assert backup.read_bytes() == original
        assert stat.S_IMODE(backup.stat().st_mode) == 0o600
        assert stat.S_IMODE(backup.parent.stat().st_mode) == 0o700
        assert stat.S_IMODE(rc.stat().st_mode) == 0o640
        saved = rc.read_bytes()
        assert run(apply=True)["status"] == "unchanged"
        assert rc.read_bytes() == saved
        assert len(list(backup.parent.iterdir())) == 1
        run(apply=True, label="t3wsl")
        assert rc.read_text().count("# >>> lmssh host prompt >>>") == 1
        assert "PS1='t3wsl:" in rc.read_text()
        stable = rc.read_bytes()
        run(apply=True, expected="wrong-host", ok=False)
        run(apply=True, label="$(touch /tmp/no)", ok=False)
        assert rc.read_bytes() == stable
        rc.write_bytes(stable + b"\n# >>> lmssh host prompt >>>\n")
        broken = rc.read_bytes()
        run(apply=True, ok=False)
        assert rc.read_bytes() == broken
        # Preserve symlinked dotfile layouts.
        rc.unlink()
        target = home / "real-bashrc"
        target.write_bytes(original)
        rc.symlink_to(target)
        run(apply=True)
        assert rc.is_symlink() and "PS1='t4g2:" in target.read_text()
        # An interactive verification failure restores the exact previous bytes.
        target.write_bytes(original)
        fakebin = home / "bin"
        fakebin.mkdir()
        bash = fakebin / "bash"
        bash.write_text('#!/bin/sh\nif [ "$1" = "-n" ]; then exec /bin/bash "$@"; fi\nexit 42\n')
        bash.chmod(0o755)
        run(apply=True, ok=False, extra_env={"PATH": str(fakebin) + os.pathsep + os.environ["PATH"]})
        assert target.read_bytes() == original
    print("PASS prompt preview/apply, rendered alias/path, secret preservation, private backup, idempotence, hostname guard, symlink and rollback checks")


if __name__ == "__main__":
    main()

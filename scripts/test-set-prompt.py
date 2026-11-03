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
DRIVER = Path(os.environ.get("LMSSH_PROMPT_DRIVER", ROOT / "build/prompt-command"))
BYTECODE = ROOT / "scripts/fixtures/prompt.dslb"
SCHEMA = ROOT / "schema/lmssh.host.json"



def main():
    version = subprocess.check_output(["bash", "-c", 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"'], text=True)
    if tuple(map(int, version.split("."))) < (4, 4):
        print("SKIP prompt recipe test: Bash 4.4+ required for prompt rendering verification")
        return
    with tempfile.TemporaryDirectory(prefix="lmssh-prompt-") as td:
        home = Path(td).resolve()
        (home / "repos").mkdir()
        canary = "DO_NOT_PRINT_THIS_TEST_SECRET"
        original = f"# existing startup\nexport PRIVATE_TEST_KEY='{canary}'\nPS1='old>'\n".encode()
        rc = home / ".bashrc"
        rc.write_bytes(original)
        rc.chmod(0o640)

        transport = home / "transport-bin"
        transport.mkdir()
        fake = transport / "lmssh"
        fake.write_text("#!/usr/bin/env python3\n" + r'''
import os,sys,subprocess,tempfile,shlex
from pathlib import Path
assert sys.argv[1] == "--lmcode" and sys.argv[3] == "--"
code=Path(sys.argv[2]); assert code.is_absolute() and code.is_file(), "bytecode must be absolute and present"
assert code.read_bytes()==Path(os.environ["LMSSH_TEST_BYTECODE"]).read_bytes(), "runtime bytes differ from pin"
with tempfile.TemporaryDirectory(dir=os.environ["HOME"]) as work:
 command,payload=Path(work)/"command",Path(work)/"payload"
 r=subprocess.run([os.environ["LMSSH_PROMPT_DRIVER"],str(code),os.environ["LMSSH_TEST_SCHEMA"],str(command),str(payload),*sys.argv[4:]],capture_output=True,text=True)
 if r.returncode:sys.stderr.write(r.stderr);sys.exit(r.returncode)
 r=subprocess.run(shlex.split(command.read_text()),input=payload.read_text(),capture_output=True,text=True)
 sys.stdout.write(r.stdout);sys.stdout.write(__import__("json").dumps({"ok":r.returncode==0,"result":None})+"\n");sys.stderr.write(r.stderr);sys.exit(r.returncode)
''')
        fake.chmod(0o755)
        compiler=os.environ.get("LMSCRIPT_BIN", "lmscript")
        foreign=home/"foreign";foreign.mkdir()
        def run(apply=False, label="t4g2", expected=None, ok=True, extra_env=None):
            expected=socket.gethostname() if expected is None else expected
            source='import '+json.dumps(str(ROOT/"scripts/lib/prompt.lms"))+'; set_host_prompt("fixture-destination",'+json.dumps(label)+','+json.dumps(expected)+','+str(apply).lower()+');'
            env=dict(os.environ,HOME=str(home),LMSSH_PROMPT_DRIVER=str(DRIVER),LMSSH_TEST_BYTECODE=str(BYTECODE),LMSSH_TEST_SCHEMA=str(SCHEMA))
            env.update(extra_env or {})
            env["PATH"]=str(transport)+os.pathsep+env["PATH"]
            result=subprocess.run([compiler,"-e",source],cwd=foreign,env=env,text=True,capture_output=True)
            assert (result.returncode==0)==ok,result.stdout+result.stderr
            assert canary not in result.stdout+result.stderr
            if not ok:return result
            lines=[json.loads(line) for line in result.stdout.splitlines() if line.strip()]
            assert len(lines)==2 and lines[-1]=={"ok":True,"result":None},lines
            return lines[0]

        # Original decoded transport used double backslashes. Keep the corrected
        # Bash encoding explicit rather than accidentally changing it while moving source.
        legacy_ps1 = r"t4g2:\\w\\$ "
        canonical_ps1 = r"t4g2:\w\$ "
        assert canonical_ps1 == legacy_ps1.replace("\\\\", "\\")
        preview = run()
        assert preview["desired_ps1"] == canonical_ps1
        assert preview["status"] == "preview" and rc.read_bytes() == original
        assert not (home / ".local/state/lmssh/prompt-backups").exists()
        changed = run(apply=True)
        assert changed["status"] == "updated"
        assert changed["rendered_prompt"] == "t4g2:~/repos" + ("# " if os.geteuid() == 0 else "$ "), changed["rendered_prompt"]
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

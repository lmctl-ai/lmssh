#!/usr/bin/env python3
"""Fixture exports use the outer compilation layer without executing outer statements."""
import os,subprocess,tempfile,json,shutil
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
compiler=Path(os.environ.get('LMSCRIPT_BIN')or shutil.which('lmscript')or'').resolve()
module=os.environ.get('LMCODE_COMPILER_MODULE')or str(compiler.parent.parent/'dist/dsl.js')
env=dict(os.environ,LMCODE_COMPILER_MODULE=module)
with tempfile.TemporaryDirectory(prefix='lmssh-body-')as directory:
 work=Path(directory);schema=work/'s.json';schema.write_text('{"dsl.schema":2,"name":"fixture_body"}')
 source=work/'safe.lms';marker=work/'outer-effect';out=work/'safe.dslb'
 source.write_text('write_file('+json.dumps(str(marker))+',"unexpected");\np=_lmcode_ schema="s.json";\nlet text="safe";\nend _lmcode_\n')
 r=subprocess.run(['node',str(ROOT/'scripts/compile-lmcode-fixture.mjs'),str(source),str(out)],cwd=ROOT,env=env,capture_output=True);assert r.returncode==0,r.stderr.decode();assert out.is_file();assert not marker.exists(),'fixture tool executed unrelated outer statements'
 if os.environ.get('NEW_LANGUAGE_FEATURES')=='1':
  for source,pinned in [('tests/fixtures/lmcode/session.lms','tests/fixtures/lmcode/session.dslb'),('examples/deploy-file.lms','examples/compiled/deploy-file.dslb')]:
   r=subprocess.run(['node',str(ROOT/'scripts/compile-lmcode-fixture.mjs'),source,str(out)],cwd=ROOT,env=env,capture_output=True);assert r.returncode==0,r.stderr.decode();assert out.read_bytes()==(ROOT/pinned).read_bytes(),source+' bytecode changed'
  print('PASS both formatted bodies retain exact pinned bytecode')
 print('PASS fixture compiler uses the lmscript layer without outer effects')

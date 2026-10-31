"""POSIX per-process write-limit fault test; does not fill the disk or change ACLs."""
import json
import os
import pathlib
import signal
import subprocess
import sys
import tempfile

if os.name != 'posix':
    print('POSIX write-limit test not applicable; Windows recovery cases use test-recovery.cjs')
    raise SystemExit(0)
import resource
root = pathlib.Path(__file__).resolve().parents[1]
native = '--native' in sys.argv
native_binary = next((p for p in [root / '_build/native/release/build/cmd/main/main', root / '_build/native/release/build/cmd/main/main.exe'] if p.is_file()), None)
command = [str(native_binary)] if native else ['node', str(root / '_build/js/release/build/cmd/main/main.js')]

def limit_writes():
    resource.setrlimit(resource.RLIMIT_FSIZE, (64, 64))
    signal.signal(signal.SIGXFSZ, signal.SIG_IGN)

with tempfile.TemporaryDirectory(prefix='moonvalve-write-failure-') as temp:
    folder = pathlib.Path(temp)
    for mode in ['temporary', 'backup']:
        source = folder / f'{mode}.vdf'
        before = b'root { keep yes }' if mode == 'temporary' else ('root { keep yes padding "' + 'x' * 2048 + '" }').encode()
        source.write_bytes(before)
        plan = folder / f'{mode}.json'
        change = {'op':'replace','value':'y'*2048,'path':[{'key':'root','occurrence':0},{'key':'keep','occurrence':0}]} if mode == 'temporary' else {'op':'remove','path':[{'key':'root','occurrence':0},{'key':'padding','occurrence':0}]}
        plan.write_text(json.dumps([change]), encoding='utf-8')
        result = subprocess.run(command + ['edit',str(source),str(plan),'--in-place'], capture_output=True, timeout=20, preexec_fn=limit_writes)
        assert result.returncode == 2, (mode, result.returncode, result.stderr)
        assert source.read_bytes() == before
        assert not pathlib.Path(str(source)+'.bak').exists(), 'Incomplete owned backup must be removed'
        assert not list(folder.glob('*.moonvalve-*')), 'Incomplete temporary output must be removed'
print('Temporary-output and backup-write failures preserve originals and leave no incomplete owned files ('+('native' if native else 'js')+')')

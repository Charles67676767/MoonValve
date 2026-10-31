"""Verify CI-built release archives without executing a foreign-platform binary."""
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
folder = pathlib.Path(sys.argv[1])
version = re.search(r'^version\s*=\s*"([^"]+)"', (root / 'moon.mod').read_text(encoding='utf-8'), re.M).group(1)
commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
archives = sorted(folder.glob('*.zip'))
assert len(archives) == 2, 'Expected Windows x64 and Linux x64 archives'
platforms = set()
for archive in archives:
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == pathlib.Path(str(archive) + '.sha256').read_text().split()[0]
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        names = z.namelist()
        prefix = names[0].split('/')[0] + '/'
        for name in names:
            p = pathlib.PurePosixPath(name)
            assert name.startswith(prefix) and not p.is_absolute() and '..' not in p.parts
        build = json.loads(z.read(prefix + 'BUILD.json'))
        assert build['version'] == version and build['commit'] == commit
        assert build['arch'] == 'x64' and build['toolchain'] == '0.10.18+6c83a7f62'
        platforms.add(build['platform'])
        checks = z.read(prefix + 'SHA256SUMS').decode().splitlines()
        for line in checks:
            digest, name = line.split('  ', 1)
            assert hashlib.sha256(z.read(prefix + name)).hexdigest() == digest, name
        assert {prefix + line.split('  ', 1)[1] for line in checks} == {n for n in names if not n.endswith('/') and n != prefix + 'SHA256SUMS'}
assert platforms == {'linux', 'win32'}
print('Both release archives match the verified commit, version and per-file checksums')

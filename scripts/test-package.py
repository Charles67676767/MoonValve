"""Verify the distributed ZIP and run the executable from an isolated extraction."""
import hashlib
import json
import pathlib
import subprocess
import tempfile
import zipfile
import argparse
import re

root = pathlib.Path(__file__).resolve().parents[1]
options = argparse.ArgumentParser()
options.add_argument('archive', nargs='?', help='Explicit ZIP when several builds are present')
args = options.parse_args()
module_version = re.search(r'^version\s*=\s*"([^"]+)"', (root / 'moon.mod').read_text(encoding='utf-8'), re.M).group(1)
archives = [pathlib.Path(args.archive).resolve()] if args.archive else list((root / '_build/packages').glob(f'moonvalve-{module_version}-*.zip'))
assert len(archives) == 1, 'Expected one current-version package; select an explicit ZIP if needed'
archive = archives[0]
assert hashlib.sha256(archive.read_bytes()).hexdigest() == pathlib.Path(str(archive) + '.sha256').read_text().split()[0]
with tempfile.TemporaryDirectory(prefix='moonvalve-package-') as temporary:
    target = pathlib.Path(temporary)
    with zipfile.ZipFile(archive) as bundle:
        assert bundle.testzip() is None
        for entry in bundle.infolist():
            path = pathlib.PurePosixPath(entry.filename)
            assert not path.is_absolute() and '..' not in path.parts
        bundle.extractall(target)
        for entry in bundle.infolist():
            (target / entry.filename).chmod((entry.external_attr >> 16) & 0o777)
    folder = next(target.iterdir())
    for line in (folder / 'SHA256SUMS').read_text().splitlines():
        digest, filename = line.split('  ', 1)
        assert hashlib.sha256((folder / filename).read_bytes()).hexdigest() == digest, filename
    binary = folder / ('moonvalve.exe' if (folder / 'moonvalve.exe').exists() else 'moonvalve')
    version = subprocess.run([str(binary), '--version'], check=True, capture_output=True, encoding='utf-8')
    assert json.loads(version.stdout)['version'] == json.loads((folder / 'BUILD.json').read_text())['version']
    assert json.loads(version.stdout)['version'] == module_version
    result = subprocess.run([str(binary), 'parse', '-'], input='root { key "中文😀" key two }', encoding='utf-8', check=True, capture_output=True)
    assert [row['value'] for row in json.loads(result.stdout)[0]['value']] == ['中文😀', 'two']
    assert (folder / 'web/editor/moonvalve.mjs').is_file()
    for asset in ['tools.mjs', 'samples.mjs', 'worker.mjs']:
        assert (folder / 'web/editor' / asset).is_file()
    streamed = subprocess.run([str(binary), 'stream-query', '-', 'root', 'key'], input='root { key "中文😀" key two }', encoding='utf-8', check=True, capture_output=True)
    assert [json.loads(line)['value'] for line in streamed.stdout.splitlines()] == ['中文😀', 'two']
    project = subprocess.run([str(binary), 'project', 'main.vdf', '--root', str(folder / 'fixtures/project'), '--condition', 'WIN32'], encoding='utf-8', check=True, capture_output=True)
    assert any(row['location']['source'] == 'config/defaults.vdf' for row in json.loads(project.stdout)['origins'])
    assert (folder / 'licenses/Apache-2.0.txt').is_file()
print('Package checksums, ZIP integrity, isolated native execution and bundled editor passed')

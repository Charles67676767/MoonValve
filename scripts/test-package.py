"""Verify the distributed ZIP and run the executable from an isolated extraction."""
import hashlib
import json
import pathlib
import subprocess
import tempfile
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
archives = list((root / '_build/packages').glob('*.zip'))
assert len(archives) == 1, 'Expected one freshly generated package'
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
    result = subprocess.run([str(binary), 'parse', '-'], input='root { key "中文😀" key two }', encoding='utf-8', check=True, capture_output=True)
    assert [row['value'] for row in json.loads(result.stdout)[0]['value']] == ['中文😀', 'two']
    assert (folder / 'web/editor/moonvalve.mjs').is_file()
    assert (folder / 'licenses/Apache-2.0.txt').is_file()
print('Package checksums, ZIP integrity, isolated native execution and bundled editor passed')

"""Verify the distributed ZIP and run the executable from an isolated extraction."""
import hashlib
import json
import pathlib
import subprocess
import tempfile
import zipfile
import argparse
import re
import io

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
    build = json.loads((folder / 'BUILD.json').read_text())
    contract = json.loads((root / 'docs/api-contract.json').read_text())
    assert build['toolchain'] == contract['toolchain']
    assert build['minimum_moonc'] == json.loads(version.stdout)['minimum_moonc']
    assert tuple(map(int, build['minimum_moonc'].split('.'))) >= (0, 10, 16)
    assert json.loads(version.stdout)['version'] == json.loads((folder / 'BUILD.json').read_text())['version']
    assert json.loads(version.stdout)['version'] == module_version
    result = subprocess.run([str(binary), 'parse', '-'], input='root { key "中文😀" key two }', encoding='utf-8', check=True, capture_output=True)
    assert [row['value'] for row in json.loads(result.stdout)[0]['value']] == ['中文😀', 'two']
    assert (folder / 'web/editor/moonvalve.mjs').is_file()
    for asset in ['tools.mjs', 'samples.mjs', 'worker.mjs', 'editing.mjs', 'kv3-tools.mjs', 'kv3-tree.mjs']:
        assert (folder / 'web/editor' / asset).is_file()
    streamed = subprocess.run([str(binary), 'stream-query', '-', 'root', 'key'], input='root { key "中文😀" key two }', encoding='utf-8', check=True, capture_output=True)
    assert [json.loads(line)['value'] for line in streamed.stdout.splitlines()] == ['中文😀', 'two']
    project = subprocess.run([str(binary), 'project', 'main.vdf', '--root', str(folder / 'fixtures/project'), '--condition', 'WIN32'], encoding='utf-8', check=True, capture_output=True)
    assert any(row['location']['source'] == 'config/defaults.vdf' for row in json.loads(project.stdout)['origins'])
    assert (folder / 'licenses/Apache-2.0.txt').is_file()
    selected = subprocess.run([str(binary), 'select', '-', '/**/tag'], input='r {tag one tag two}', encoding='utf-8', check=True, capture_output=True)
    assert len(json.loads(selected.stdout)) == 2
    typed = subprocess.run([str(binary), 'kv3-parse', str(folder / 'fixtures/sample.kv3')], encoding='utf-8', check=True, capture_output=True)
    assert '18446744073709551615' in typed.stdout
    snapshot_file = folder / 'fixtures/workspace-fields.json'
    snapshot = json.loads(snapshot_file.read_text(encoding='utf-8'))
    exported = subprocess.run([str(binary), 'workspace-zip', str(snapshot_file)], check=True, capture_output=True)
    with zipfile.ZipFile(io.BytesIO(exported.stdout)) as project_zip:
        assert project_zip.testzip() is None
        assert set(project_zip.namelist()) == set(snapshot['files'])
        for name, text in snapshot['files'].items():
            assert project_zip.read(name) == text.encode('utf-8')
    project_copy = target / 'exported-project'
    subprocess.run([str(binary), 'workspace-export', str(snapshot_file), str(project_copy)], check=True, capture_output=True)
    for name, text in snapshot['files'].items():
        assert (project_copy / name).read_bytes() == text.encode('utf-8')
    query = subprocess.run([str(binary), 'kv3-select', str(folder / 'fixtures/sample.kv3'), '/**?type=integer&>9007199254740993'], check=True, capture_output=True, encoding='utf-8')
    assert json.loads(query.stdout)[0]['value']['value'] == '18446744073709551615'
    mixed = subprocess.run([str(binary), 'workspace-kv3-query', str(folder / 'fixtures/workspace-mixed.json'), '/**?flag=resource'], check=True, capture_output=True, encoding='utf-8')
    assert len(json.loads(mixed.stdout)) == 2
    preserving = subprocess.run([str(binary), 'kv3-format-preserving', '-', '--headerless'], input='//keep\n{n=18446744073709551615 arr=[1,2]}', check=True, capture_output=True, encoding='utf-8')
    assert '//keep' in preserving.stdout and '18446744073709551615' in preserving.stdout
    refs = subprocess.run([str(binary), 'kv3-resources', str(folder / 'fixtures/sample.kv3'), str(folder / 'fixtures/resource-roots.json')], check=True, capture_output=True, encoding='utf-8')
    assert json.loads(refs.stdout)[0]['target'] == 'content/materials/moon.vmat'
    extension = folder / 'extensions' / f'moonvalve-{module_version}.vsix'
    with zipfile.ZipFile(extension) as bundle:
        assert bundle.testzip() is None
        assert 'extension/client.cjs' in bundle.namelist()
        assert not any('/node_modules/' in name for name in bundle.namelist())
print('Package checksums, ZIP integrity, isolated native execution and bundled editor passed')

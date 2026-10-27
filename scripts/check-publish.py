"""Inspect the exact Mooncakes source archive; never inspect authentication tokens."""
import json
import pathlib
import re
import zipfile

root = pathlib.Path(__file__).resolve().parents[1]
manifest = (root / 'moon.mod').read_text(encoding='utf-8')
version = re.search(r'^version\s*=\s*"([^"]+)"', manifest, re.M).group(1)
archive = root / '_build/publish' / f'Charles67676767-moonvalve-{version}.zip'
forbidden = {'.git', '.codex', '.agents', '.local', 'private', 'submissions', 'research', 'node_modules', '_build'}
with zipfile.ZipFile(archive) as bundle:
    names = set(bundle.namelist())
    assert {'moon.mod', 'moon.pkg', 'LICENSE', 'NOTICE.md', 'pkg.generated.mbti'} <= names
    assert 'fixtures/upstream/proton/LICENSE.proton' in names
    assert bundle.read('moon.mod').decode('utf-8').replace('\r\n', '\n') == manifest.replace('\r\n', '\n')
    for info in bundle.infolist():
        path = pathlib.PurePosixPath(info.filename.replace('\\', '/'))
        assert not path.is_absolute() and '..' not in path.parts
        assert not forbidden.intersection(path.parts), info.filename
        assert not re.search(r'credential|\.env(?:\.|$)', path.name, re.I), info.filename
        if info.is_dir():
            continue
        data = bundle.read(info)
        try:
            text = data.decode('utf-8')
        except UnicodeDecodeError:
            continue
        assert not re.search(r'(?i)C:[/\\]Users[/\\]|D:[/\\]codex|[A-Z0-9._%+-]+@qq\.com', text), info.filename
print(json.dumps({'module': 'Charles67676767/moonvalve', 'version': version, 'source_archive_checked': True, 'files': len(names)}))

"""Independent test-only adapters: srctools 2.7.0 and polib 1.2.0."""
import base64
import io
import json
import pathlib
import sys
import tempfile
import polib
from srctools import dmx, vmt, vpk
from srctools.filesys import VirtualFileSystem

def b64(data):
    return base64.b64encode(data).decode('ascii')

def execute(request):
    operation = request['operation']
    if operation == 'dmx':
        element, name, version = dmx.Element.parse(io.BytesIO(base64.b64decode(request['base64'])), unicode=True)
        text, binary = io.BytesIO(), io.BytesIO()
        element.export_kv2(text, fmt_name=name, fmt_ver=version, flat=True, unicode='silent')
        element.export_binary(binary, version=request.get('version', 5), fmt_name=name, fmt_ver=version, unicode='silent')
        return {'text': text.getvalue().decode('utf8'), 'binary': b64(binary.getvalue())}
    if operation == 'vmt':
        material = vmt.Material.parse(request['files'][request['source']])
        material = material.apply_patches(VirtualFileSystem(request['files']))
        return {'shader': material.shader, 'parameters': {key.lower(): material[key] for key in material}, 'proxies': len(material.proxies)}
    if operation == 'po':
        catalog = polib.pofile(request['text'])
        return {'text': str(catalog), 'metadata': catalog.metadata, 'entries': [{'context': e.msgctxt, 'id': e.msgid, 'plural': e.msgid_plural, 'translation': e.msgstr, 'plurals': e.msgstr_plural, 'flags': e.flags, 'obsolete': bool(e.obsolete)} for e in catalog]}
    if operation.startswith('vpk'):
        with tempfile.TemporaryDirectory(prefix='moonvalve-reference-') as temp:
            path = pathlib.Path(temp) / 'pak01_dir.vpk'
            if operation == 'vpk-read':
                path.write_bytes(base64.b64decode(request['base64']))
                archive = vpk.VPK(path)
                return {'files': {entry.filename: b64(entry.read()) for entry in archive}}
            archive = vpk.VPK(path, mode='w', dir_data_limit=3)
            for name, value in request['files'].items():
                archive.add_file(name, base64.b64decode(value), arch_index=request.get('archive', 0))
            archive.write_dirfile()
            return {'directory': b64(path.read_bytes()), 'archives': {str(int(p.stem.rsplit('_', 1)[1])): b64(p.read_bytes()) for p in pathlib.Path(temp).glob('pak01_[0-9]*.vpk')}}
    raise ValueError('Unknown operation')

for line in sys.stdin:
    try:
        print(json.dumps({'ok': True, 'result': execute(json.loads(line))}, ensure_ascii=False))
    except Exception as error:
        print(json.dumps({'ok': False, 'error': type(error).__name__ + ': ' + str(error)}))

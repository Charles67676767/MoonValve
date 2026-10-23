const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const native = process.argv.includes('--native');
const executable = (native ? ['_build/native/release/build/cmd/main/main.exe', '_build/native/release/build/cmd/main/main'] : ['_build/js/release/build/cmd/main/main.js'])
  .map(name => path.join(root, name)).find(name => fs.existsSync(name));
if (!executable) throw new Error(`Run moon build --target ${native ? 'native' : 'js'} --release first`);
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'moonvalve-test-'));
let cases = 0;
function run(args, input) {
  const result = spawnSync(native ? executable : process.execPath, native ? args : [executable, ...args], {
    cwd: root, encoding: 'utf8', input, maxBuffer: 4 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  return result;
}
function runRaw(args, input) {
  const result = spawnSync(native ? executable : process.execPath, native ? args : [executable, ...args], {
    cwd: root, input, maxBuffer: 8 * 1024 * 1024,
  });
  if (result.error) throw result.error;
  return result;
}
function test(name, body) { body(); cases++; console.log(`ok ${cases} - ${name}`); }

try {
  test('help describes available commands', () => {
    const r = run(['--help']); assert.equal(r.status, 0); assert.match(r.stdout, /inventory/);
  });
  test('app manifest keeps exact numeric strings', () => {
    const r = run(['app', 'fixtures/appmanifest_480.acf']);
    assert.equal(r.status, 0); const app = JSON.parse(r.stdout);
    assert.equal(app.app_id, '480'); assert.equal(app.size_on_disk, '1048576');
  });
  test('parse retains repeated keys', () => {
    const r = run(['parse', 'fixtures/duplicates.vdf']); assert.equal(r.status, 0);
    assert.deepEqual(JSON.parse(r.stdout)[0].value.slice(0, 2).map(e => e.value), ['singleplayer', 'controller']);
  });
  test('format output can be parsed again from stdin', () => {
    const r = run(['format', 'fixtures/duplicates.vdf']); assert.equal(r.status, 0);
    const parsed = run(['parse', '-'], r.stdout); assert.equal(parsed.status, 0);
    assert.equal(JSON.parse(parsed.stdout)[0].key, 'root');
  });
  test('query accepts one argument per key', () => {
    const r = run(['query', 'fixtures/appmanifest_480.acf', 'AppState', 'name']);
    assert.equal(r.status, 0); assert.equal(JSON.parse(r.stdout), 'Moon Harbor');
  });
  test('missing query path returns a failing exit status', () => {
    const r = run(['query', 'fixtures/duplicates.vdf', 'missing']); assert.equal(r.status, 2);
    assert.equal(r.stdout, ''); assert.match(r.stderr, /Path not found/);
  });
  test('invalid input is rejected with a located diagnostic', () => {
    const r = run(['parse', '-'], 'root { key }'); assert.equal(r.status, 2);
    assert.match(r.stderr, /missing_value at 1:/); assert.equal(r.stdout, '');
  });
  test('invalid UTF-8 does not silently replace bytes', () => {
    const r = run(['parse', '-'], Buffer.from([0xff, 0xfe, 0xff])); assert.equal(r.status, 2);
  });
  test('missing files and invalid commands fail', () => {
    assert.equal(run(['parse', path.join(temporary, 'missing.vdf')]).status, 2);
    assert.equal(run(['unknown']).status, 2);
    assert.equal(run(['query', 'fixtures/duplicates.vdf']).status, 2);
  });
  test('current and legacy library entries both work', () => {
    const r = run(['libraries', 'fixtures/libraryfolders.vdf']); assert.equal(r.status, 0);
    const libs = JSON.parse(r.stdout); assert.equal(libs.length, 2); assert.deepEqual(libs[0].app_ids, ['480']);
  });
  test('inventory reads real files and reports individual bad manifests', () => {
    const library = path.join(temporary, 'library');
    fs.mkdirSync(path.join(library, 'steamapps'), { recursive: true });
    fs.copyFileSync(path.join(root, 'fixtures/appmanifest_480.acf'), path.join(library, 'steamapps/appmanifest_480.acf'));
    const folders = path.join(temporary, 'libraryfolders.vdf');
    fs.writeFileSync(folders, `libraryfolders { 0 { path ${JSON.stringify(library)} } }`);
    const good = run(['inventory', folders]); assert.equal(good.status, 0);
    assert.equal(JSON.parse(good.stdout).games[0].app.name, 'Moon Harbor');
    fs.writeFileSync(path.join(library, 'steamapps/appmanifest_999.acf'), 'AppState {}');
    const mixed = run(['inventory', folders]); assert.equal(mixed.status, 1);
    const report = JSON.parse(mixed.stdout); assert.equal(report.games.length, 1); assert.equal(report.errors.length, 1);
  });
  test('inventory cannot silently use stdin as a file base', () => {
    const r = run(['inventory', '-'], 'libraryfolders {}'); assert.equal(r.status, 2);
  });
  test('ordered JSON can be imported and invalid schemas fail', () => {
    const rows = [{key: 'k', value: 'a'}, {key: 'k', value: [{key: '中文', value: '😀'}]}];
    const imported = run(['from-json', '-'], JSON.stringify(rows)); assert.equal(imported.status, 0);
    assert.deepEqual(JSON.parse(run(['parse', '-'], imported.stdout).stdout), rows);
    assert.equal(run(['from-json', '-'], '{"k":1}').status, 2);
  });
  test('inventory sorts filters totals and exports CSV with anomaly diagnostics', () => {
    const library = path.join(temporary, 'inventory-rich');
    fs.mkdirSync(path.join(library, 'steamapps'), {recursive: true});
    fs.writeFileSync(path.join(library, 'steamapps/appmanifest_2.acf'), 'AppState { appid 2 name "Alpha, Test" installdir game SizeOnDisk 9007199254740993 }');
    fs.writeFileSync(path.join(library, 'steamapps/appmanifest_10.acf'), 'AppState { appid 10 name Zoo installdir game }');
    const folders = path.join(temporary, 'rich.vdf');
    fs.writeFileSync(folders, `libraryfolders { 0 { path ${JSON.stringify(library)} apps { 2 0 99 0 } } 1 ${JSON.stringify(library)} }`);
    const r = run(['inventory', folders, '--filter', 'ALPHA', '--sort', 'size']); assert.equal(r.status, 1);
    const report = JSON.parse(r.stdout); assert.equal(report.games.length, 1);
    assert.equal(report.summary.known_size_bytes, '9007199254740993');
    assert.equal(report.summary.scanned_count, 2);
    assert.deepEqual(report.errors.map(e => e.code).sort(), ['duplicate_library', 'missing_manifest']);
    const csv = run(['inventory', folders, '--csv', '--sort', 'name']);
    assert.equal(csv.status, 1); assert.match(csv.stdout, /"Alpha, Test"/); assert.match(csv.stderr, /missing_manifest/);
    assert.equal(run(['inventory', folders, '--sort', 'random']).status, 2);
    assert.equal(run(['inventory', folders, '--filter']).status, 2);
  });
  test('text commands expose duplicate queries conditions literal paths and JSON errors', () => {
    const all=run(['query-all','-','r','k'],'r { k 1 k 2 } r { k 3 }');
    assert.equal(all.status,0);assert.deepEqual(JSON.parse(all.stdout),['1','2','3']);
    const conditional=run(['parse','-','--condition','WIN32'],'platform win [$WIN32] platform linux [$LINUX]');
    assert.equal(conditional.status,0);assert.deepEqual(JSON.parse(conditional.stdout),[{key:'platform',value:'win'}]);
    const literal=run(['parse','-','--literal'],'path "C:\\games"');
    assert.equal(JSON.parse(literal.stdout)[0].value,'C:\\games');
    const error=run(['--json-errors','parse','-'],'root { key }');
    assert.equal(error.status,2);assert.equal(error.stdout,'');
    assert.equal(JSON.parse(error.stderr).code,'missing_value');assert.equal(JSON.parse(error.stderr).line,1);
  });
  test('reference loading is constrained to a selected root including canonical paths', () => {
    const dir=path.join(temporary,'references');fs.mkdirSync(path.join(dir,'cfg'),{recursive:true});
    fs.writeFileSync(path.join(dir,'cfg/main.vdf'),'root { a local } #base ../base.vdf');
    fs.writeFileSync(path.join(dir,'base.vdf'),'root { b default }');
    const resolved=run(['resolve','cfg/main.vdf','--root',dir]);assert.equal(resolved.status,0,resolved.stderr);
    assert.match(resolved.stdout,/"b" "default"/);
    assert.equal(run(['resolve','cfg/main.vdf']).status,2);
    assert.equal(run(['resolve','../outside','--root',dir]).status,2);
    const outside=path.join(temporary,'outside');fs.mkdirSync(outside);fs.writeFileSync(path.join(outside,'private.vdf'),'secret data');
    fs.symlinkSync(outside,path.join(dir,'linked'),process.platform==='win32'?'junction':'dir');
    fs.writeFileSync(path.join(dir,'escape.vdf'),'#include linked/private.vdf');
    assert.equal(run(['resolve','escape.vdf','--root',dir]).status,2);
  });
  test('transaction preview and atomic save preserve BOM CRLF and an exclusive backup', () => {
    const file=path.join(temporary,'edit-中文.vdf'),plan=path.join(temporary,'edit.json');
    const before='\ufeff// keep\r\nroot { k one [$WIN32] k two }\r\n';
    fs.writeFileSync(file,before);if(process.platform!=='win32')fs.chmodSync(file,0o640);
    fs.writeFileSync(plan,JSON.stringify([{path:[{key:'root',occurrence:0},{key:'k',occurrence:1}],op:'replace',value:'three'}]));
    const preview=run(['edit',file,plan,'--dry-run']);assert.equal(preview.status,0,preview.stderr);
    const report=JSON.parse(preview.stdout);assert.equal(report.before,before);assert.equal(report.after,before.replace('two','three'));assert.match(report.diff,/--- before/);
    assert.equal(fs.readFileSync(file,'utf8'),before);assert.equal(fs.existsSync(file+'.bak'),false);
    const saved=run(['edit',file,plan,'--in-place']);assert.equal(saved.status,0,saved.stderr);
    assert.equal(fs.readFileSync(file+'.bak','utf8'),before);assert.equal(fs.readFileSync(file,'utf8'),report.after);
    if(process.platform!=='win32')assert.equal(fs.statSync(file).mode&0o777,0o640);
    fs.writeFileSync(plan,JSON.stringify([{path:[{key:'root',occurrence:0},{key:'k',occurrence:1}],op:'replace',value:'four'}]));
    assert.equal(run(['edit',file,plan,'--in-place']).status,2);assert.equal(fs.readFileSync(file,'utf8'),report.after);
    assert.equal(fs.readdirSync(temporary).some(n=>n.includes('.moonvalve-')),false);
  });
  test('a failed batch never modifies its input or creates a backup', () => {
    const file=path.join(temporary,'unchanged.vdf'),plan=path.join(temporary,'bad-plan.json');
    fs.writeFileSync(file,'a one');
    fs.writeFileSync(plan,JSON.stringify([{path:[{key:'a',occurrence:0}],op:'replace',value:'two'},{path:[{key:'missing',occurrence:0}],op:'remove'}]));
    assert.equal(run(['edit',file,plan,'--in-place']).status,2);assert.equal(fs.readFileSync(file,'utf8'),'a one');assert.equal(fs.existsSync(file+'.bak'),false);
  });
  test('typed binary CLI roundtrips exact numeric bits and malformed bytes fail', () => {
    const rows=[{key:'n',type:'uint64',value:'18446744073709551615'},{key:'float',type:'float32bits',value:'2143289345'},{key:'unicode',type:'wstring',value:'中文😀'}];
    const encoded=runRaw(['binary-encode','-'],JSON.stringify(rows));assert.equal(encoded.status,0,encoded.stderr.toString());
    const decoded=run(['binary-decode','-'],encoded.stdout);assert.equal(decoded.status,0,decoded.stderr);assert.deepEqual(JSON.parse(decoded.stdout),rows);
    assert.equal(run(['binary-decode','-'],encoded.stdout.subarray(0,-1)).status,2);
  });
  test('shortcut commands add set remove and preserve unknown binary fields', () => {
    const file=path.join(temporary,'shortcuts.vdf'),definition=path.join(temporary,'shortcut.json');
    const rows=[{key:'metadata',type:'string',value:'keep'},{key:'shortcuts',type:'object',value:[]}];
    const encoded=runRaw(['binary-encode','-'],JSON.stringify(rows));assert.equal(encoded.status,0);fs.writeFileSync(file,encoded.stdout);
    fs.writeFileSync(definition,JSON.stringify({name:'Game',exe:'"D:\\Games\\game.exe"',tags:['Games','中文']}));
    const added=run(['shortcut-add',file,definition,'--in-place']);assert.equal(added.status,0,added.stderr);
    const list=JSON.parse(run(['shortcuts',file]).stdout);assert.equal(list[0].name,'Game');assert.match(list[0].url,/steam:\/\/rungameid\/[0-9]+/);
    fs.writeFileSync(definition,JSON.stringify({launch_options:'--fullscreen'}));
    const changed=runRaw(['shortcut-set',file,'0',definition]);assert.equal(changed.status,0,changed.stderr.toString());
    const data=JSON.parse(run(['binary-decode','-'],changed.stdout).stdout);assert.equal(data[0].value,'keep');
    const updated=path.join(temporary,'updated-shortcuts.vdf');fs.writeFileSync(updated,changed.stdout);
    assert.equal(JSON.parse(run(['shortcuts',updated]).stdout)[0].app_id,list[0].app_id);
    const removed=runRaw(['shortcut-remove',updated,'0']);assert.equal(removed.status,0);
    assert.deepEqual(JSON.parse(run(['binary-decode','-'],removed.stdout).stdout)[1].value,[]);
  });
  test('Steam cache CLI indexes and extracts independently framed appinfo records', () => {
    const payload=runRaw(['binary-encode','-'],JSON.stringify([{key:'name',type:'string',value:'Synthetic'}])).stdout;
    const header=Buffer.alloc(8);header.writeUInt32LE(0x07564427,0);header.writeUInt32LE(1,4);
    const record=Buffer.alloc(48);record.writeUInt32LE(480,0);record.writeUInt32LE(40+payload.length,4);record.writeUInt32LE(7,44);
    const file=path.join(temporary,'appinfo.vdf');fs.writeFileSync(file,Buffer.concat([header,record,payload,Buffer.alloc(4)]));
    const index=run(['cache',file]);assert.equal(index.status,0,index.stderr);assert.equal(JSON.parse(index.stdout).records[0].id,'480');
    const extracted=run(['cache',file,'480']);assert.equal(extracted.status,0,extracted.stderr);assert.equal(JSON.parse(extracted.stdout)[0].value,'Synthetic');
    assert.equal(run(['cache',file,'999']).status,2);
  });
  test('streamed events retain raw conditions and scalar query addresses every duplicate', () => {
    const source='r { k one k "中文😀" [$WIN32] nested { k no } }';
    const events=run(['stream-json','-'],source);assert.equal(events.status,0,events.stderr);
    const rows=events.stdout.trim().split('\n').map(JSON.parse);assert.equal(rows[2].path[1].index,1);assert.equal(rows[3].event,'condition');
    const query=run(['stream-query','-','r','k'],source);assert.equal(query.status,0,query.stderr);
    assert.deepEqual(query.stdout.trim().split('\n').map(line=>JSON.parse(line).value),['one','中文😀']);
    const csv=run(['stream-csv','-'],'r { k "a,\\\"b" }');assert.equal(csv.status,0,csv.stderr);assert.match(csv.stdout,/path,value/);assert.match(csv.stdout,/a,""b/);
  });
  test('stream formatting roundtrips and rejects conditional or referenced output', () => {
    const source='r { k "中文😀" k two nested { x y } }';const formatted=run(['stream-format','-'],source);assert.equal(formatted.status,0,formatted.stderr);
    assert.deepEqual(JSON.parse(run(['parse','-'],formatted.stdout).stdout),JSON.parse(run(['parse','-'],source).stdout));
    for(const text of ['r {k yes [$WIN32]}','#base missing','r {k yes'])assert.equal(run(['stream-format','-'],text).status,2);
    assert.equal(run(['stream-json','-','--max-bytes','2'],'key value').status,2);
    assert.equal(run(['stream-json','-'],Buffer.from([0xf0,0x9f])).status,2);
    assert.equal(run(['stream-json',path.join(temporary,'missing-stream')]).status,2);
  });
  test('project CLI reports inherited scalar origins and reference locations', () => {
    const folder=path.join(temporary,'project');fs.mkdirSync(folder);
    fs.writeFileSync(path.join(folder,'main.vdf'),'#base defaults.vdf\nr { local yes }');fs.writeFileSync(path.join(folder,'defaults.vdf'),'r { local no inherited yes }');
    const result=run(['project','main.vdf','--root',folder]);assert.equal(result.status,0,result.stderr);
    const project=JSON.parse(result.stdout),origin=project.origins.find(o=>o.path.at(-1).key==='inherited');assert.equal(origin.location.source,'defaults.vdf');assert.equal(origin.location.column,14);assert.equal(project.references[0].kind,'base');
  });
  test('streaming crosses chunk UTF8 boundaries and reads files larger than ordinary IO limits', () => {
    const file=path.join(temporary,'large.vdf'),fd=fs.openSync(file,'w');
    fs.writeSync(fd,'r {\n');const row='padding "'+ 'x'.repeat(90)+'"\n';for(let i=0;i<200;i++)fs.writeSync(fd,row.repeat(1000));fs.writeSync(fd,'needle "中文😀"\n}');fs.closeSync(fd);
    assert.ok(fs.statSync(file).size>16*1024*1024);
    const result=run(['stream-query',file,'r','needle']);assert.equal(result.status,0,result.stderr);assert.equal(JSON.parse(result.stdout).value,'中文😀');
    const boundary=path.join(temporary,'boundary.vdf');fs.writeFileSync(boundary,' '.repeat(65535)+'r {k "😀"}');assert.equal(run(['stream-format',boundary]).status,0);
  });
  console.log(`${cases} CLI checks passed`);
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}

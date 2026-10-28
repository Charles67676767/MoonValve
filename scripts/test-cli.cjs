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
  test('query expressions and snapshot edits retain duplicate identity and reject overlaps',()=>{
    const file=path.join(temporary,'query.vdf'),plan=path.join(temporary,'query.json');fs.writeFileSync(file,'// keep\nr {tag one tag two nested {tag three}}');
    let r=run(['select',file,'/**/tag']);assert.equal(r.status,0,r.stderr);assert.equal(JSON.parse(r.stdout).length,3);
    fs.writeFileSync(plan,JSON.stringify({op:'replace',value:'Moon'}));r=run(['query-edit',file,'/**/tag',plan]);assert.equal(r.status,0,r.stderr);assert.equal((r.stdout.match(/Moon/g)||[]).length,3);assert.match(r.stdout,/^\/\/ keep/);assert.match(fs.readFileSync(file,'utf8'),/one/);
    fs.writeFileSync(plan,JSON.stringify([{op:'remove',path:[{key:'r',occurrence:0},{key:'tag',occurrence:0}]},{op:'remove',path:[{key:'r',occurrence:0},{key:'tag',occurrence:1}]}]));r=run(['edit-snapshot',file,plan]);assert.equal(r.status,0,r.stderr);assert.doesNotMatch(r.stdout,/one|two/);assert.match(r.stdout,/three/);
  });
  test('structure transfers preserve source comments and reject moving into descendants',()=>{
    const file=path.join(temporary,'transfer.vdf'),plan=path.join(temporary,'transfer.json');fs.writeFileSync(file,'r {\n // follows\n k one\n child {}\n}');
    const from=[{key:'r',occurrence:0},{key:'k',occurrence:0}],to=[{key:'r',occurrence:0},{key:'child',occurrence:0}];fs.writeFileSync(plan,JSON.stringify({from,to,index:0,copy:true}));let r=run(['transfer',file,plan]);assert.equal(r.status,0,r.stderr);assert.equal((r.stdout.match(/follows/g)||[]).length,2);
    fs.writeFileSync(plan,JSON.stringify({from:[{key:'r',occurrence:0}],to,index:0}));assert.equal(run(['transfer',file,plan]).status,2);
  });
  test('typed KV3 text roundtrips exact integers and rejects binary and invalid types',()=>{
    const r=run(['kv3-parse','-','--headerless'],'{n=18446744073709551615 flag=resource:"moon" data=#[00 ff]}');assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/18446744073709551615/);
    const text=run(['kv3-from-json','-'],r.stdout);assert.equal(text.status,0,text.stderr);assert.equal(run(['kv3-parse','-','--headerless'],text.stdout).status,0);
    assert.equal(run(['kv3-parse','-'],'{a=1}').status,2);assert.equal(run(['kv3-parse','-','--headerless'],'{a=1 a=2}').status,2);
  });
  test('workspace snapshot rename rewrites incoming and outgoing references atomically',()=>{
    const file=path.join(temporary,'workspace.json'),plan=path.join(temporary,'workspace-plan.json'),before={format:'moonvalve-project-v1',source:'main.vdf',files:{'main.vdf':'#base config/base.vdf\nr {}','config/base.vdf':'#include ../extra.vdf\nr {k v}','extra.vdf':'extra yes'}};fs.writeFileSync(file,JSON.stringify(before));fs.writeFileSync(plan,JSON.stringify([{op:'rename',from:'config/base.vdf',to:'moved.vdf'}]));let r=run(['workspace-edit',file,plan]);assert.equal(r.status,0,r.stderr);const result=JSON.parse(r.stdout);assert.match(result.files['main.vdf'],/moved.vdf/);assert.match(result.files['moved.vdf'],/extra.vdf/);assert.doesNotMatch(result.files['moved.vdf'],/\.\.\//);assert.deepEqual(JSON.parse(fs.readFileSync(file)),before);
    fs.writeFileSync(plan,JSON.stringify([{op:'remove',name:'config/base.vdf'}]));assert.equal(run(['workspace-edit',file,plan,'--in-place']).status,2);assert.ok(!fs.existsSync(file+'.bak'));
  });
  test('preserving KV3 edits back up originals and reject entire invalid transactions',()=>{
    const file=path.join(temporary,'local.kv3'),plan=path.join(temporary,'kv3-plan.json'),before='// keep\r\n{n=18446744073709551615 arr=[1, /*keep*/ 2,]}';fs.writeFileSync(file,before);
    fs.writeFileSync(plan,JSON.stringify([{op:'replace',path:['n'],value:{type:'integer',value:'42'}},{op:'insert-element',path:['arr'],index:1,value:{type:'bool',value:true}}]));
    let r=run(['kv3-edit',file,plan,'--headerless','--dry-run']);assert.equal(r.status,0,r.stderr);assert.equal(fs.readFileSync(file,'utf8'),before);assert.ok(!fs.existsSync(file+'.bak'));
    r=run(['kv3-edit',file,plan,'--headerless','--in-place']);assert.equal(r.status,0,r.stderr);assert.equal(fs.readFileSync(file+'.bak','utf8'),before);assert.match(fs.readFileSync(file,'utf8'),/\/\*keep\*\//);
    const changed=fs.readFileSync(file,'utf8');fs.writeFileSync(plan,JSON.stringify([{op:'remove',path:['arr','0']},{op:'remove',path:['absent']}]));assert.equal(run(['kv3-edit',file,plan,'--headerless','--in-place']).status,2);assert.equal(fs.readFileSync(file,'utf8'),changed);
  });
  test('workspace field query selects files and batch failure writes nothing',()=>{
    const file=path.join(temporary,'fields.json'),plan=path.join(temporary,'fields-plan.json'),selection=path.join(temporary,'fields-selection.json');
    const before={format:'moonvalve-project-v1',source:'a.vdf',files:{'a.vdf':'// keep\nr {path old/a}','b.vdf':'r {path old/b}','c.vdf':'r {path other}'}};fs.writeFileSync(file,JSON.stringify(before));fs.writeFileSync(selection,JSON.stringify(['b.vdf']));
    let r=run(['workspace-query',file,'/r/path',selection]);assert.equal(r.status,0,r.stderr);assert.deepEqual(JSON.parse(r.stdout).map(row=>row.file),['b.vdf']);
    fs.writeFileSync(plan,JSON.stringify([{op:'query',expression:'/r/path?^="old/"',operation:{op:'replace-prefix',from:'old/',to:'new/'},files:[]}]))
    r=run(['workspace-edit',file,plan]);assert.equal(r.status,0,r.stderr);assert.match(JSON.parse(r.stdout).files['a.vdf'],/new\/a/);assert.equal(JSON.parse(r.stdout).files['c.vdf'],before.files['c.vdf']);assert.deepEqual(JSON.parse(fs.readFileSync(file)),before);
    fs.writeFileSync(plan,JSON.stringify([{op:'query',expression:'/r/path',operation:{op:'replace-prefix',from:'old/',to:'new/'},files:[]}]))
    assert.equal(run(['workspace-edit',file,plan,'--in-place']).status,2);assert.deepEqual(JSON.parse(fs.readFileSync(file)),before);assert.ok(!fs.existsSync(file+'.bak'));
  });
  test('project directory and ZIP export retain paths and reject every existing target',()=>{
    const file=path.join(temporary,'export.json'),out=path.join(temporary,'new-project'),files={'main.vdf':'//keep\r\n#base 配置/base.vdf\nr {}','配置/base.vdf':'r {k yes}'},snapshot={format:'moonvalve-project-v1',source:'main.vdf',files};fs.writeFileSync(file,JSON.stringify(snapshot));
    let r=run(['workspace-export',file,out]);assert.equal(r.status,0,r.stderr);for(const [name,text]of Object.entries(files))assert.equal(fs.readFileSync(path.join(out,name),'utf8'),text);
    fs.writeFileSync(path.join(out,'sentinel'),'untouched');r=run(['workspace-export',file,out]);assert.equal(r.status,2);assert.equal(fs.readFileSync(path.join(out,'sentinel'),'utf8'),'untouched');
    const targetFile=path.join(temporary,'existing-file');fs.writeFileSync(targetFile,'untouched');assert.equal(run(['workspace-export',file,targetFile]).status,2);assert.equal(fs.readFileSync(targetFile,'utf8'),'untouched');
    const invalid=path.join(temporary,'invalid-project');fs.writeFileSync(file,JSON.stringify({...snapshot,files:{...files,'../outside.vdf':'r {}'}}));assert.equal(run(['workspace-export',file,invalid]).status,2);assert.ok(!fs.existsSync(invalid));
    fs.writeFileSync(file,JSON.stringify(snapshot));const zipName=path.join(temporary,'export.zip');assert.equal(run(['workspace-zip',file,zipName]).status,0);const savedZip=fs.readFileSync(zipName);assert.equal(run(['workspace-zip',file,zipName]).status,2);assert.deepEqual(fs.readFileSync(zipName),savedZip);const zip=runRaw(['workspace-zip',file]);assert.equal(zip.status,0,zip.stderr?.toString());assert.equal(zip.stdout.subarray(0,4).toString('hex'),'504b0304');
    try{const link=path.join(temporary,'project-link');fs.symlinkSync(out,link,process.platform==='win32'?'junction':'dir');assert.equal(run(['workspace-export',file,link]).status,2);assert.equal(fs.readFileSync(path.join(out,'sentinel'),'utf8'),'untouched');}catch(e){if(!['EPERM','EACCES'].includes(e.code))throw e;}
  });
  test('typed KV3 queries retain uint64 precision and batch source edits preserve resource flags',()=>{
    const file=path.join(temporary,'query-typed.kv3'),plan=path.join(temporary,'query-typed.json'),text='//keep\r\n{assets=[resource:"old/a",resource:"old/b"] note="old/a" n=18446744073709551615}';fs.writeFileSync(file,text);
    let r=run(['kv3-select',file,'/**?type=integer&>9007199254740993','--headerless']);assert.equal(r.status,0,r.stderr);assert.equal(JSON.parse(r.stdout)[0].value.value,'18446744073709551615');
    fs.writeFileSync(plan,JSON.stringify({op:'replace-prefix',from:'old/',to:'new/'}));r=run(['kv3-query-edit',file,'/**?flag=resource',plan,'--headerless']);assert.equal(r.status,0,r.stderr);assert.equal(r.stdout,text.replaceAll('resource:"old/','resource:"new/'));assert.equal(fs.readFileSync(file,'utf8'),text);
    fs.writeFileSync(plan,JSON.stringify({op:'remove'}));assert.equal(run(['kv3-query-edit',file,'/**',plan,'--headerless','--in-place']).status,2);assert.equal(fs.readFileSync(file,'utf8'),text);assert.ok(!fs.existsSync(file+'.bak'));
  });
  test('preserving format keeps conditions comments lexical values and supports safe saving',()=>{
    const file=path.join(temporary,'whitespace.vdf'),text='//keep\r\n#base base.vdf\r\nr {k one [$WIN32] k two [$LINUX]}';fs.writeFileSync(file,text);
    let r=run(['format-preserving',file]);assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/k one \[\$WIN32\]/);assert.match(r.stdout,/^\/\/keep/);assert.match(r.stdout,/#base base.vdf/);assert.equal(fs.readFileSync(file,'utf8'),text);
    assert.equal(run(['format-preserving','-'],r.stdout).stdout,r.stdout);
    r=run(['format-preserving',file,'--in-place']);assert.equal(r.status,0,r.stderr);assert.equal(fs.readFileSync(file+'.bak','utf8'),text);
    const kv3='//keep\n{n=18446744073709551615 arr=[1,/*x*/2,]}';r=run(['kv3-format-preserving','-','--headerless'],kv3);assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/\/\*x\*\//);assert.match(r.stdout,/18446744073709551615/);assert.equal(run(['kv3-format-preserving','-','--headerless'],r.stdout).stdout,r.stdout);
  });
  test('mixed workspace typed query edits only KV3 and exports both formats',()=>{
    const h=fs.readFileSync(path.join(root,'fixtures/sample.kv3'),'utf8').split(/\r?\n/)[0]+'\n',file=path.join(temporary,'mixed.json'),plan=path.join(temporary,'mixed-plan.json');
    const files={'main.vdf':'r {path old/kv1}','a.kv3':h+'//keep\n{path=resource:"old/a" n=18446744073709551615}','b.kv3':h+'{path=resource:"old/b"}'};fs.writeFileSync(file,JSON.stringify({format:'moonvalve-project-v1',source:'main.vdf',files}));
    let r=run(['workspace-kv3-query',file,'/**?flag=resource']);assert.equal(r.status,0,r.stderr);assert.equal(JSON.parse(r.stdout).length,2);
    fs.writeFileSync(plan,JSON.stringify([{op:'kv3-query',expression:'/**?flag=resource',files:[],operation:{op:'replace-prefix',from:'old/',to:'new/'}}]));r=run(['workspace-edit',file,plan]);assert.equal(r.status,0,r.stderr);const result=JSON.parse(r.stdout);assert.equal(result.files['main.vdf'],files['main.vdf']);assert.match(result.files['a.kv3'],/resource:"new\/a"/);fs.writeFileSync(file,r.stdout);
    const out=path.join(temporary,'mixed-out');r=run(['workspace-export',file,out]);assert.equal(r.status,0,r.stderr);assert.equal(fs.readFileSync(path.join(out,'a.kv3'),'utf8'),result.files['a.kv3']);
  });
  test('resource report and migration use explicit roots and preserve symbolic names',()=>{
    const file=path.join(temporary,'resource.kv3'),roots=path.join(temporary,'roots.json'),moves=path.join(temporary,'moves.json'),text='//keep\n{a=resource:"materials/a.vmat" b=resource_name:"materials/a.vmat"}';fs.writeFileSync(file,text);fs.writeFileSync(roots,JSON.stringify([{prefix:'',directory:'content'}]));fs.writeFileSync(moves,JSON.stringify({'content/materials':'content/new'}));
    let r=run(['kv3-resources',file,roots,'--headerless']);assert.equal(r.status,0,r.stderr);const rows=JSON.parse(r.stdout);assert.equal(rows.length,1);assert.equal(rows[0].target,'content/materials/a.vmat');
    r=run(['kv3-resource-edit',file,roots,moves,'--headerless']);assert.equal(r.status,0,r.stderr);assert.match(r.stdout,/resource:"new\/a.vmat"/);assert.match(r.stdout,/resource_name:"materials\/a.vmat"/);assert.equal(fs.readFileSync(file,'utf8'),text);
    fs.writeFileSync(moves,JSON.stringify({'content/materials':'outside'}));assert.equal(run(['kv3-resource-edit',file,roots,moves,'--headerless','--in-place']).status,2);assert.equal(fs.readFileSync(file,'utf8'),text);assert.ok(!fs.existsSync(file+'.bak'));
  });
  console.log(`${cases} CLI checks passed`);
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}

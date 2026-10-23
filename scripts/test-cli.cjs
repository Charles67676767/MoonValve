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
  console.log(`${cases} CLI checks passed`);
} finally {
  fs.rmSync(temporary, { recursive: true, force: true });
}

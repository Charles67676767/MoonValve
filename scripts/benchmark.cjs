// Reproducible process-level parsing benchmark, including startup and JSON output.
const {spawnSync} = require('node:child_process');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const native = process.argv.includes('--native');
const executable = path.join(root, native ? '_build/native/release/build/cmd/main/main' + (process.platform === 'win32' ? '.exe' : '') : '_build/js/release/build/cmd/main/main.js');
console.log(JSON.stringify({node: process.version, platform: process.platform, architecture: process.arch, target: native ? 'native' : 'js', metric: 'wall time including process startup, UTF-8 parsing and ordered JSON output'}));
for (const entries of [1000, 10000, 50000]) {
  const input = 'root {\n' + Array.from({length: entries}, (_, i) => `"key${i % 97}" "value ${i} 中文"\n`).join('') + '}\n';
  const elapsed = [];
  for (let iteration = 0; iteration < 4; iteration++) {
    const start = performance.now();
    const result = spawnSync(native ? executable : process.execPath, native ? ['parse', '-'] : [executable, 'parse', '-'], {cwd: root, input, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024, timeout: 30000});
    if (result.error) throw result.error;
    assert.equal(result.status, 0, result.stderr);
    const duration = performance.now() - start;
    assert.equal(JSON.parse(result.stdout)[0].value.length, entries);
    if (iteration) elapsed.push(duration); // first execution is warmup
  }
  elapsed.sort((a,b) => a-b);
  console.log(JSON.stringify({entries, input_bytes: Buffer.byteLength(input), median_ms: +elapsed[1].toFixed(2), measured_runs: elapsed.length}));
}

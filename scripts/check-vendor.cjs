// Verify the attributed third-party sources independently of checkout line endings.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../internal/vendor');
const manifest=JSON.parse(fs.readFileSync(path.join(root,'provenance.json'),'utf8'));
for(const file of manifest.files){
  const target=path.resolve(root,file.path);
  assert.ok(target.startsWith(root+path.sep));
  const source=fs.readFileSync(target,'utf8').replace(/\r\n/g,'\n');
  assert.equal(crypto.createHash('sha256').update(source).digest('hex'),file.vendored_lf_sha256,file.path);
}
console.log(`Verified ${manifest.files.length} attributed compression source and test files`);

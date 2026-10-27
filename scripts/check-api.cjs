const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),contract=JSON.parse(fs.readFileSync(path.join(root,'docs/api-contract.json'),'utf8'));
const manifest=fs.readFileSync(path.join(root,'moon.mod'),'utf8'),version=/^version\s*=\s*"([^"]+)"/m.exec(manifest)[1];
assert.equal(version.split('.').slice(0,2).join('.'),contract.series,'Review the API contract before starting a new series');
const source=fs.readFileSync(path.join(root,contract.interface),'utf8').replace(/\r\n/g,'\n');
assert.equal(crypto.createHash('sha256').update(source).digest('hex'),contract.sha256,'Public signatures changed: keep 0.4.x compatible or explicitly review a new minor series');
console.log('Public MoonBit API matches the 0.4.x compatibility baseline');

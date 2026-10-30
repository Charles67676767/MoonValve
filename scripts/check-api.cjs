const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..'),contract=JSON.parse(fs.readFileSync(path.join(root,'docs/api-contract.json'),'utf8'));
const read=name=>fs.readFileSync(path.join(root,name),'utf8').replace(/\r\n/g,'\n');
const hash=source=>crypto.createHash('sha256').update(source).digest('hex');
// MoonBit 0.10.18 prints the existing 32-bit Int/UInt aliases with explicit names.
const canonical=source=>source.replace(/\bInt\b/g,'Int32').replace(/\bUInt\b/g,'UInt32');
const version=/^version\s*=\s*"([^"]+)"/m.exec(read('moon.mod'))[1];
assert.equal(version.split('.').slice(0,2).join('.'),contract.series,'Review the API contract before starting a new series');
const source=read(contract.interface);
assert.equal(hash(source),contract.sha256,'Public signatures changed: review a new minor series rather than changing a published patch contract');
function declarations(text){
  const result=[];let current='',depth=0;
  for(const line of text.split('\n')){
    if(!current&&!/^(?:pub(?:\([^)]*\))? (?:fn|struct|enum|suberror|type)|type )/.test(line))continue;
    current+=(current?'\n':'')+line;depth+=(line.match(/\{/g)||[]).length-(line.match(/\}/g)||[]).length;
    if(depth===0){result.push(current);current='';}
  }
  assert.equal(current,'');return result;
}
for(const previous of (Array.isArray(contract.previous)?contract.previous:contract.previous?[contract.previous]:[])){
  const baseline=read(previous.interface);assert.equal(hash(baseline),previous.sha256,'Previous compatibility baseline changed');
  const current=new Set(declarations(canonical(source)));for(const declaration of declarations(canonical(baseline)))assert.ok(current.has(declaration),'Previous API declaration removed or changed: '+declaration);
}
console.log('Public MoonBit API matches '+contract.series+'.x baseline and retains previous public declarations');

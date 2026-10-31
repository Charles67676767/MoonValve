const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'..');
function walk(dir){return fs.readdirSync(dir,{withFileTypes:true}).flatMap(e=>e.isDirectory()?walk(path.join(dir,e.name)):e.name.endsWith('.md')?[path.join(dir,e.name)]:[]);}
let checked=0;
for(const file of [path.join(root,'README.md'),...walk(path.join(root,'docs'))]){
  const text=fs.readFileSync(file,'utf8');
  for(const m of text.matchAll(/\]\(([^)]+)\)/g)){const link=m[1].split(/\s+"/)[0].replace(/^<|>$/g,'');if(/^(https?:|mailto:|#)/.test(link))continue;const target=decodeURIComponent(link.split('#')[0]);if(!target)continue;assert.ok(fs.existsSync(path.resolve(path.dirname(file),target)),path.relative(root,file)+': '+link);checked++;}
}
console.log(`${checked} local documentation links verified`);

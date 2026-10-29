const assert=require('node:assert/strict'),fs=require('node:fs'),os=require('node:os'),path=require('node:path'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),native=process.argv.includes('--native'),executable=(native?['_build/native/release/build/cmd/main/main.exe','_build/native/release/build/cmd/main/main']:['_build/js/release/build/cmd/main/main.js']).map(n=>path.join(root,n)).find(fs.existsSync);
if(!executable)throw new Error('Build release CLI first');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'moonvalve-assets-'));let count=0;
const write=(name,data)=>{const p=path.join(temp,name);fs.mkdirSync(path.dirname(p),{recursive:true});fs.writeFileSync(p,data);return p;};
function run(args,input){const p=spawnSync(native?executable:process.execPath,native?args:[executable,...args],{input,maxBuffer:32*1024*1024,timeout:30000});if(p.error)throw p.error;return p;}
function ok(args,input){const r=run(args,input);assert.equal(r.status,0,r.stderr.toString());return r.stdout;}
function test(name,fn){fn();count++;console.log('ok '+count+' - '+name);}
try{
  test('binary KV3 codecs query edit and DATA resource preserve model',()=>{
    const text=write('data.kv3','<!-- kv3 encoding:text:version{e21c7f3c-8a33-41c5-9977-a76d3a32aa0d} format:generic:version{7412167c-06e9-4698-aff2-e63eb59037e7} -->\n{name="Moon" n=18446744073709551615}');
    for(const version of [4,5])for(const codec of ['raw','lz4','zstd']){
      const file=write('data.bin',ok(['kv3-text-to-binary',text,String(version),codec])),model=ok(['kv3-binary-decode',file]);
      assert.equal(JSON.parse(ok(['kv3-binary-select',file,'/name']))[0].value.root.value,'Moon');
      const op=write('op.json',JSON.stringify({op:'replace',value:{type:'string',value:'Sun'}})),output=path.join(temp,'changed-'+version+'-'+codec+'.bin');
      ok(['kv3-binary-edit',file,'/name',op,output]);assert.ok(ok(['kv3-binary-to-text',output]).toString().includes('Sun'));assert.equal(run(['kv3-binary-edit',file,'/name',op,output]).status,2);
      const resource=write('resource.bin',ok(['kv3-resource-encode',write('model.json',model),String(version),codec]));assert.equal(JSON.parse(ok(['resource-inspect',resource])).blocks[0].kind,'DATA');assert.deepEqual(JSON.parse(ok(['resource-data',resource])).root,JSON.parse(model).root);
    }
  });
  test('VPK embedded and numbered archives CRC lazy ranges extraction and no overwrite',()=>{
    const files={'materials/moon.vmt':Buffer.from('UnlitGeneric {$basetexture moon/base}').toString('base64'),'materials/moon/base.vtf':Buffer.from([0,255,1]).toString('base64')};
    const file=write('own_dir.vpk',ok(['vpk-create',write('bundle.json',JSON.stringify(files))]));assert.equal(JSON.parse(ok(['vpk-check',file])).checked,2);
    assert.deepEqual(ok(['vpk-extract',file,'materials/moon/base.vtf']),Buffer.from([0,255,1]));
    const out=path.join(temp,'unpacked');ok(['vpk-extract-all',file,out]);assert.deepEqual(fs.readFileSync(path.join(out,'materials/moon/base.vtf')),Buffer.from([0,255,1]));assert.equal(run(['vpk-extract-all',file,out]).status,2);
    const meta=Buffer.alloc(18);meta.writeUInt32LE(0x3610a686);meta.writeUInt16LE(2,4);meta.writeUInt16LE(12,6);meta.writeUInt32LE(7,8);meta.writeUInt32LE(3,12);meta.writeUInt16LE(65535,16);
    const tree=Buffer.concat([Buffer.from('txt\0 \0moon\0'),meta,Buffer.from('he\0\0\0')]),header=Buffer.alloc(12);header.writeUInt32LE(0x55aa1234);header.writeUInt32LE(1,4);header.writeUInt32LE(tree.length,8);
    const index=write('external_dir.vpk',Buffer.concat([header,tree]));write('external_012.vpk',Buffer.from('paddingllo'));assert.equal(ok(['vpk-extract',index,'moon.txt']).toString(),'hello');
    write('external_012.vpk',Buffer.from('paddingBAD'));assert.equal(run(['vpk-check',index]).status,2);
  });
  test('dependency manifest mounts VPK base content and exports strict directory ZIP VPK',()=>{
    const rootDir=path.join(temp,'mod');write('mod/materials/moon.vmt','Patch {include materials/base.vmt replace {$basetexture moon/custom}}');write('mod/materials/moon/custom.vtf','custom');
    const baseFiles={'materials/base.vmt':Buffer.from('UnlitGeneric {$basetexture moon/base}').toString('base64'),'materials/moon/base.vtf':Buffer.from('base').toString('base64')};
    const archive=write('base_dir.vpk',ok(['vpk-create',write('base-bundle.json',JSON.stringify(baseFiles))]));
    const manifest=write('deps.json',JSON.stringify({roots:['materials/moon.vmt'],mounts:[{id:'mod',root:rootDir,base_game:false},{id:'base',vpk:archive,base_game:true}]}));
    const graph=JSON.parse(ok(['dependencies',manifest]));assert.equal(graph.files.length,4);assert.ok(graph.edges.some(e=>e.status==='base-game'));
    assert.deepEqual(JSON.parse(ok(['dependencies',manifest,'materials/moon/base.vtf'])),['materials/base.vmt','materials/moon.vmt']);
    for(const format of ['zip','vpk','directory']){const out=path.join(temp,'closure.'+format);ok(['dependencies-export',manifest,out,format]);assert.equal(run(['dependencies-export',manifest,out,format]).status,2);}
    assert.equal(JSON.parse(ok(['vpk-index',path.join(temp,'closure.vpk')])).entries.length,2);
  });
  test('VMT explicit-root expansion and parameter edit',()=>{
    const file=write('vmt/materials/patch.vmt','Patch {include materials/base.vmt insert {$detail moon/detail}}');write('vmt/materials/base.vmt','UnlitGeneric {$basetexture moon/base}');
    const expanded=ok(['vmt-expand','materials/patch.vmt',path.join(temp,'vmt')]);assert.ok(expanded.toString().includes('moon/detail'));
    assert.equal(JSON.parse(ok(['vmt-parse',write('expanded.vmt',expanded)])).textures.length,2);assert.ok(ok(['vmt-set',file,'include','materials/new.vmt']).toString().includes('materials/new.vmt'));
    assert.equal(run(['vmt-expand','../outside.vmt',path.join(temp,'vmt')]).status,2);
  });
  test('localization encodings PO roundtrip placeholder failure and stale source',()=>{
    const model={language:'English',encoding:'utf8',tokens:[{name:'Moon_Hello',text:'Hello %s1'}]},translation={...model,language:'schinese',tokens:[{name:'Moon_Hello',text:'你好 %s1'}]};
    const source=write('english.txt',ok(['localization-write',write('loc.json',JSON.stringify(model)),'utf16be'])),target=write('schinese.txt',ok(['localization-write',write('translated.json',JSON.stringify(translation)),'utf8-bom']));
    const po=write('translated.po',ok(['localization-po',source,target]));assert.equal(JSON.parse(ok(['localization-read',write('translated-import.txt',ok(['localization-import',source,po,'schinese','valve','utf8']))])).tokens[0].text,'你好 %s1');
    const bad=write('bad.po',fs.readFileSync(po,'utf8').replace('你好 %s1','你好 %d1'));assert.equal(run(['localization-import',source,bad,'schinese']).status,2);
    const template=write('new.pot',ok(['localization-pot',write('new.txt',ok(['localization-write',write('new.json',JSON.stringify({...model,tokens:[{name:'Moon_Hello',text:'Hi %s1'}]}))]))]));assert.ok(ok(['po-update',template,po]).toString().includes('fuzzy'));
  });
  test('DMX text binary JSON roundtrip typed identities and malformed versions',()=>{
    const text='<!-- dmx encoding keyvalues2 1 format model 22 -->\n"DmeRoot" {"id" "elementid" "11111111-2222-4333-8444-555555555555" "name" "string" "Moon" "child" "DmeChild" {"name" "string" "Mesh" "position" "vector3" "1 2 3"}}';
    const file=write('model.dmx',text),expected=JSON.parse(ok(['dmx-decode',file]));
    for(const version of [4,5]){const binary=write('model'+version+'.dmx',ok(['dmx-binary',file,String(version)]));assert.deepEqual(JSON.parse(ok(['dmx-decode',binary])),expected);const json=write('dmx.json',ok(['dmx-decode',binary]));const out=write('flat.dmx',ok(['dmx-from-json',json]));assert.deepEqual(JSON.parse(ok(['dmx-decode',out])),expected);}
    assert.equal(run(['dmx-binary',file,'9']).status,2);
  });
  console.log(count+' asset CLI integration groups passed ('+(native?'native':'js')+')');
}finally{fs.rmSync(temp,{recursive:true,force:true});}

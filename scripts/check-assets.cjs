const path=require('node:path'),assert=require('node:assert/strict'),{pathToFileURL}=require('node:url'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),python=process.env.MOONVALVE_PYTHON||'python';
(async()=>{
  const {dispatch}=await import(pathToFileURL(path.join(root,'web/editor/moonvalve.mjs')));
  const run=q=>{const r=JSON.parse(dispatch(JSON.stringify(q)));assert.equal(r.ok,true,JSON.stringify(r.error));return r.result;};
  const b64=s=>Buffer.from(s).toString('base64');
  function reference(request){const p=spawnSync(python,[path.join(root,'scripts/reference-assets.py')],{input:JSON.stringify(request)+'\n',encoding:'utf8',maxBuffer:32*1024*1024,timeout:30000,env:{...process.env,PYTHONUTF8:'1'}});if(p.error)throw p.error;assert.equal(p.status,0,p.stderr);const r=JSON.parse(p.stdout);assert.equal(r.ok,true,r.error);return r.result;}
  let count=0;
  const files={'materials/moon.vmt':b64('UnlitGeneric {$basetexture moon/base}'),'materials/moon/base.vtf':b64('texture'.repeat(200)),'root':b64('hello'),'empty.txt':b64('')};
  for(const preload of [0,3,65535]){
    const own=run({action:'vpk-create',files,preload});assert.deepEqual(reference({operation:'vpk-read',base64:own.base64}).files,files);count++;
  }
  // srctools' writer supports numbered data archives. Embedded payloads are
  // covered above by reading MoonValve-created archives with srctools.
  for(const archive of [0,12]){
    const result=reference({operation:'vpk-create',files,archive});
    const index=run({action:'vpk-index',base64:result.directory});assert.equal(index.entries.length,Object.keys(files).length);
    const directory=Buffer.from(result.directory,'base64'),ranges={};
    for(const e of index.entries){const offset=e.offset+(e.archive===32767?index.data_offset:0),source=e.archive===32767?directory:Buffer.from(result.archives[String(e.archive)],'base64');ranges[`${e.archive}:${offset}:${e.length}`]=source.subarray(offset,offset+e.length).toString('base64');}
    for(const name of Object.keys(files))assert.equal(run({action:'vpk-extract',base64:result.directory,path:name,ranges}).base64,files[name]);count++;
  }
  const materials={'materials/base.vmt':'VertexLitGeneric {$basetexture moon/base $alpha 1 $bumpmap moon/normal Proxies {Sine {sineperiod 1}}}','materials/patch.vmt':'Patch {include materials/base.vmt insert {$basetexture moon/new $detail moon/detail Proxies {TextureScroll {rate 1}}} replace {$alpha 0.5 $missing ignored $bumpmap ""}}'};
  const own=run({action:'vmt-expand',source:'materials/patch.vmt',files:materials}),mature=reference({operation:'vmt',source:'materials/patch.vmt',files:materials});
  assert.equal(own.model.shader,mature.shader);assert.deepEqual(Object.fromEntries(own.model.parameters.filter(e=>typeof e.value==='string').map(e=>[e.key.toLowerCase(),e.value])),mature.parameters);assert.equal(own.model.parameters.find(e=>e.key==='Proxies').value.length,mature.proxies);count++;
  const source={language:'English',encoding:'utf8',tokens:[{name:'Moon_Hello',text:'Hello %s1'},{name:'Moon_SameA',text:'Same'},{name:'Moon_SameB',text:'Same'}]};
  const localization=run({action:'localization-write',model:source,encoding:'utf16be'}),po=run({action:'localization-po',base64:localization.base64}).text;
  const gettext=reference({operation:'po',text:po});assert.equal(gettext.entries.length,3);assert.equal(gettext.entries[0].context,'Moon_Hello');const roundtrip=reference({operation:'po',text:run({action:'po-format',text:gettext.text}).text});assert.deepEqual(roundtrip.entries,gettext.entries);assert.deepEqual(roundtrip.metadata,gettext.metadata);count++;
  const id='11111111-2222-4333-8444-555555555555',child='66666666-7777-4888-8999-aaaaaaaaaaaa';
  const value=(type,value)=>({type,value});
  const model={format_name:'model',format_version:22,root:id,elements:[{id,name:'root',type:'DmeRoot',attributes:[{name:'int',value:value('int',-2147483648)},{name:'float',value:value('float','1067450368')},{name:'strings',value:value('string_array',[value('string','hello'),value('string','line\nnext')])},{name:'blob',value:value('binary','00ff12')},{name:'time',value:value('time',12345)},{name:'color',value:value('color','4279383126')},{name:'vector',value:value('vector3',['1065353216','1073741824','1077936128'])},{name:'link',value:value('element',child)},{name:'shared',value:value('element_array',[value('element',child),value('element',null)])}]},{id:child,name:'child',type:'DmeChild',attributes:[{name:'back',value:value('element',id)}]}]};
  function normalized(d){return {...d,elements:d.elements.slice().sort((a,b)=>a.id.localeCompare(b.id)).map(e=>({...e,attributes:e.attributes.slice().sort((a,b)=>a.name.localeCompare(b.name))}))};}
  for(const encoding of ['text','binary'])for(const version of [4,5]){
    const encoded=run({action:'dmx-write',model,encoding,version}),result=reference({operation:'dmx',base64:encoded.base64,version});
    assert.deepEqual(normalized(run({action:'dmx-read',base64:result.binary}).model),normalized(model));
    assert.deepEqual(normalized(run({action:'dmx-read',base64:b64(result.text)}).model),normalized(model));count++;
  }
  console.log(count+' independent asset interop groups passed: srctools VPK/VMT/DMX and polib PO');
})().catch(e=>{console.error(e);process.exitCode=1;});

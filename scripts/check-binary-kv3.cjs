const path=require('node:path'),assert=require('node:assert/strict'),{pathToFileURL}=require('node:url'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),dotnet=process.env.MOONVALVE_DOTNET||'dotnet';
(async()=>{
  const {dispatch}=await import(pathToFileURL(path.join(root,'web/editor/moonvalve.mjs')));
  const run=request=>{const r=JSON.parse(dispatch(JSON.stringify(request)));assert.equal(r.ok,true,JSON.stringify(r.error));return r.result;};
  const header='<!-- kv3 encoding:text:version{e21c7f3c-8a33-41c5-9977-a76d3a32aa0d} format:generic:version{7412167c-06e9-4698-aff2-e63eb59037e7} -->\n';
  const sources=['{}','{a=1 b=-2 c=1.25 d=true e=false n=null s="中文😀" empty="" flag=resource:"materials/moon.vmat" arr=[1,2,3]}','[true,false,null,{x="y"},[],{}]','{blob=#[00 ff 12] empty=#[]}','{blob=#['+Array.from({length:70000},(_,i)=>(i%251).toString(16).padStart(2,'0')).join(' ')+'] next=#[01]}','{i=18446744073709551615 n=-9223372036854775808 f=nan g=inf h=-inf z=-0.0}'].map(s=>header+s);
  function normalize(n){if(n.type==='integer')return {...n,value:BigInt(n.value).toString()};if(n.type==='float'){const s=n.value.toLowerCase(),v=Number(s);return {...n,value:s.includes('nan')?'nan':s.includes('inf')?(s.startsWith('-')?'-inf':'inf'):String(v)};}if(n.type==='array')return {...n,value:n.value.map(normalize)};if(n.type==='object')return {...n,value:n.value.map(e=>({key:e.key,value:normalize(e.value)}))};if(n.type==='flag')return {...n,value:normalize(n.value)};return n;}
  const cases=[];
  for(const text of sources)for(const version of [4,5])for(const compression of [0,1,2]){
    const expected=normalize(run({action:'kv3-parse',text}).model.root);
    const own=run({action:'kv3-to-binary',text,version,compression}).base64;
    cases.push({request:{binary:own,version,compression},expected,direction:'MoonValve to reference'});
    cases.push({request:{text,version,compression},expected,direction:'reference to MoonValve'});
  }
  const u32=n=>{const b=Buffer.alloc(4);b.writeUInt32LE(n>>>0);return b;};
  const legacyPayload=Buffer.concat([u32(3),Buffer.from('n\0path\0materials/moon.vmat\0'),Buffer.from([9]),u32(2),u32(0),Buffer.from([3]),Buffer.from('0000000000000080','hex'),u32(1),Buffer.from([134,1]),u32(2),u32(0xffffffff)]);
  const legacyExpected=normalize(run({action:'kv3-parse',text:header+'{n=-9223372036854775808 path=resource:"materials/moon.vmat"}'}).model.root);
  const legacyGuid=Buffer.from('7c161274e9069846aff2e63eb59037e7','hex');
  function legacy(encoding,payload){return Buffer.concat([Buffer.from('564b5603','hex'),Buffer.from(encoding,'hex'),legacyGuid,payload]).toString('base64');}
  const masks=[];for(let i=0;i<legacyPayload.length;i+=16)masks.push(Buffer.from([0,0]),legacyPayload.subarray(i,i+16));
  const literal=Buffer.concat([Buffer.from([0xf0,legacyPayload.length-15]),legacyPayload]);
  const legacyCases=[legacy('0005861bd8f7c140ad8275a48267e714',legacyPayload),legacy('8a344768a1635c4fa19753806fd9b119',Buffer.concat([u32(legacyPayload.length),literal])),legacy('461a7995bc956c4fa70b05bca1b7dfd2',Buffer.concat([u32(legacyPayload.length),...masks])),legacy('461a7995bc956c4fa70b05bca1b7dfd2',Buffer.concat([u32(0x80000000+legacyPayload.length),legacyPayload]))];
  for(const binary of legacyCases){const original=run({action:'kv3-binary-decode',base64:binary});assert.deepEqual(normalize(original.semantic.root),legacyExpected);cases.push({request:{binary},expected:legacyExpected,direction:'legacy VKV3 fixture through reference'});}
  const reference=spawnSync(dotnet,[path.join(root,'tools/reference-resources/bin/Release/net10.0/Reference.dll')],{input:cases.map(c=>JSON.stringify(c.request)).join('\n')+'\n',encoding:'utf8',maxBuffer:64*1024*1024,timeout:60000});
  if(reference.error)throw reference.error;assert.equal(reference.status,0,reference.stderr);
  const responses=reference.stdout.trim().split(/\r?\n/).map(JSON.parse);assert.equal(responses.length,cases.length);
  for(let i=0;i<cases.length;i++){
    const c=cases[i],r=responses[i];assert.equal(r.ok,true,`${i} ${c.direction}: ${r.error}`);
    let result;try{result=run({action:'kv3-binary-decode',base64:r.binary});}catch(e){require('node:fs').writeFileSync(path.join(root,'_build/binary-reference-failure.bin'),Buffer.from(r.binary,'base64'));throw new Error(`${i} ${c.direction} version ${c.request.version} codec ${c.request.compression}: ${e.message}`);}
    assert.deepEqual(normalize(result.semantic.root),c.expected,`${i} ${c.direction}`);
    assert.deepEqual(normalize(run({action:'kv3-parse',text:r.text}).model.root),c.expected,`${i} reference text`);
    const packed=run({action:'kv3-binary-encode',model:result.model});
    assert.deepEqual(run({action:'kv3-binary-decode',base64:packed.base64}).model,result.model,`${i} exact storage model`);
  }
  console.log(cases.length+' binary KV3 interop cases passed (legacy/raw/block/LZ4 and versions 4/5 raw/LZ4/Zstandard)');
})().catch(e=>{console.error(e);process.exitCode=1;});

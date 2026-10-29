// Optional local fixtures remain outside the repository. Obtain original files
// from ValveResourceFormat commit 2a45474046bdb5eb62c5685cbfad9e085fd2d293.
const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{pathToFileURL}=require('node:url'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),folder=process.env.MOONVALVE_RESOURCE_FIXTURES,dotnet=process.env.MOONVALVE_DOTNET||'dotnet';
if(!folder)throw new Error('Set MOONVALVE_RESOURCE_FIXTURES to a directory of original resource files');
(async()=>{
  const {dispatch}=await import(pathToFileURL(path.join(root,'web/editor/moonvalve.mjs')));
  const run=q=>{const r=JSON.parse(dispatch(JSON.stringify(q)));assert.equal(r.ok,true,JSON.stringify(r.error));return r.result;};
  const names=fs.readdirSync(folder).filter(s=>s.endsWith('_c')),requests=names.map(name=>({resource:fs.readFileSync(path.join(folder,name)).toString('base64')}));
  const reference=spawnSync(dotnet,[path.join(root,'tools/reference-resources/bin/Release/net10.0/Reference.dll')],{input:requests.map(JSON.stringify).join('\n')+'\n',encoding:'utf8',maxBuffer:64*1024*1024,timeout:120000});
  if(reference.error)throw reference.error;assert.equal(reference.status,0,reference.stderr);
  const responses=reference.stdout.trim().split(/\r?\n/).map(JSON.parse);
  function normalize(n){if(n.type==='integer')return {...n,value:BigInt(n.value).toString()};if(n.type==='float'){const s=n.value.toLowerCase();return {...n,value:s.includes('nan')?'nan':s.includes('inf')?(s.startsWith('-')?'-inf':'inf'):String(Number(n.value))};}if(n.type==='array')return {...n,value:n.value.map(normalize)};if(n.type==='object')return {...n,value:n.value.map(e=>({key:e.key,value:normalize(e.value)}))};if(n.type==='flag')return {...n,value:normalize(n.value)};return n;}
  for(let i=0;i<names.length;i++){
    const name=names[i];let inspected;try{inspected=run({action:'resource-inspect',base64:requests[i].resource});}catch(e){throw new Error(name+': '+e.message);}
    assert.ok(inspected.model,name+' DATA binary KV3');
    assert.equal(responses[i].ok,true,name+': '+responses[i].error);
    const own=run({action:'kv3-binary-encode',model:{...inspected.model,version:5,compression:2}}),decoded=run({action:'kv3-binary-decode',base64:own.base64});
    // The reference text writer rounds single precision values for display.
    // Compare its serialized binary, which retains the stored numeric payload.
    const mature=run({action:'kv3-binary-decode',base64:responses[i].binary});
    assert.deepEqual(normalize(decoded.semantic.root),normalize(mature.semantic.root),name);
    assert.deepEqual(decoded.model.root,inspected.model.root,name+' exact storage');
    console.log(name+': binary KV3 '+inspected.model.version+', codec '+inspected.model.compression+', '+inspected.references.length+' RERL references passed');
  }
})().catch(e=>{console.error(e);process.exitCode=1;});

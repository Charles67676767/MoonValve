const path=require('node:path'),assert=require('node:assert/strict'),{pathToFileURL}=require('node:url'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),dotnet=process.env.MOONVALVE_DOTNET||'dotnet';
(async()=>{
  const {dispatch}=await import(pathToFileURL(path.join(root,'web/editor/moonvalve.mjs')));
  const run=request=>{const result=JSON.parse(dispatch(JSON.stringify(request)));assert.equal(result.ok,true,JSON.stringify(result.error));return result.result;};
  const header='<!-- kv3 encoding:text:version{e21c7f3c-8a33-41c5-9977-a76d3a32aa0d} format:generic:version{7412167c-06e9-4698-aff2-e63eb59037e7} -->\n';
  let seed=20261024;const random=n=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed%n;};
  const literals=['null','true','false','18446744073709551615','-9223372036854775808','1.25','-3.5e2','nan','inf','-inf','"中文😀"','"line\\nbreak"','"a\\\\b"','#[00 ff 12]','resource:"models/moon.vmdl"'];
  function value(depth){const pick=random(depth?5:3);if(pick===3)return '['+Array.from({length:random(5)},()=>value(depth-1)).join(',')+']';if(pick===4)return '{'+Array.from({length:random(5)},(_,i)=>'key'+i+' = '+value(depth-1)).join('\n')+'}';return literals[random(literals.length)];}
  const sources=Array.from({length:60},()=>header+value(3));
  for(const literal of literals)sources.push(header+literal);
  sources.push(header+'{text="""\nline one\n中文\n"""\nempty=[] object={} flag=panorama:[true,false]}');
  const original=header+'// stable\r\n{ name="Moon😀" id=18446744073709551615 arr=[1, /* keep comma , */ 2,3,] nested=resource:{title="old"} }';
  const plans=[
    [{op:'replace',path:['name'],value:{type:'string',value:'Sun'}}],
    [{op:'rename',path:['name'],key:'display name'}],
    [{op:'remove',path:['id']}],
    [{op:'replace',path:['nested','title'],value:{type:'string',value:'new'}}],
    ...Array.from({length:4},(_,index)=>[{op:'insert-element',path:['arr'],index,value:{type:'bool',value:false}}]),
    ...Array.from({length:3},(_,index)=>[{op:'remove',path:['arr',String(index)]}]),
    [{op:'insert-field',path:[],index:2,key:'added',value:{type:'array',value:[{type:'null',value:null}]}}]
  ];
  for(const plan of plans){const result=run({action:'kv3-edit',text:original,plan});assert.ok(result.text.includes('// stable\r\n'));assert.ok(result.text.includes('/* keep comma , */'));sources.push(result.text);}
  const models=sources.map(text=>run({action:'kv3-parse',text}));
  const requests=sources.flatMap((text,i)=>[{kv3:true,text},{kv3:true,text:models[i].text}]);
  const reference=spawnSync(dotnet,[path.join(root,'tools/reference-dotnet/bin/Release/net10.0/Reference.dll')],{input:requests.map(r=>JSON.stringify(r)).join('\n')+'\n',encoding:'utf8',maxBuffer:16*1024*1024,timeout:60000});
  if(reference.error)throw reference.error;assert.equal(reference.status,0,reference.stderr);
  const responses=reference.stdout.trim().split(/\r?\n/).map(JSON.parse);assert.equal(responses.length,requests.length);
  function normalize(node){
    if(node.type==='integer')return {...node,value:BigInt(node.value).toString()};
    if(node.type==='float'){const n=Number(node.value),raw=node.value.toLowerCase();return {...node,value:raw.includes('nan')?'nan':raw.includes('inf')?(raw.startsWith('-')?'-inf':'inf'):Object.is(n,-0)?'-0':String(n)};}
    if(node.type==='array')return {...node,value:node.value.map(normalize)};
    if(node.type==='object')return {...node,value:node.value.map(e=>({key:e.key,value:normalize(e.value)}))};
    if(node.type==='flag')return {...node,value:normalize(node.value)};
    return node;
  }
  for(let i=0;i<responses.length;i++){
    const result=responses[i];assert.equal(result.ok,true,'reference case '+i+': '+result.error+'\n'+requests[i].text);
    const text=Buffer.from(result.roundtrip,'base64').toString('utf8'),actual=run({action:'kv3-parse',text});
    assert.deepEqual(normalize(actual.model.root),normalize(models[Math.floor(i/2)].model.root),'KV3 reference case '+i+'\n'+text);
  }
  console.log(sources.length+' KV3 documents verified through reference parsing and writing in both source/canonical directions');
})().catch(error=>{console.error(error);process.exitCode=1;});

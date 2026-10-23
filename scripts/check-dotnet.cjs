const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),{pathToFileURL}=require('node:url'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),dotnet=process.env.MOONVALVE_DOTNET||'dotnet';
(async()=>{
  const {dispatch}=await import(pathToFileURL(path.join(root,'web/editor/moonvalve.mjs')));
  const moon=request=>{const r=JSON.parse(dispatch(JSON.stringify(request)));assert.equal(r.ok,true,JSON.stringify(r.error));return r.result;};
  const cases=[];let state=20261023;
  const random=n=>{state=(Math.imul(state,1664525)+1013904223)>>>0;return state%n;};
  function generate(depth){const result=[];for(let i=0,n=1+random(6);i<n;i++)result.push({key:['duplicate','duplicate','space key','中文',''][random(5)],value:depth&&random(4)===0?generate(depth-1):['','value','中文😀','a"quote','a\\path','line\nbreak'][random(6)]});return result;}
  function text(entries,depth=0){return entries.map(e=>'  '.repeat(depth)+JSON.stringify(e.key)+(Array.isArray(e.value)?'\n'+'  '.repeat(depth)+'{\n'+text(e.value,depth+1)+'  '.repeat(depth)+'}\n':' '+JSON.stringify(e.value)+'\n')).join('');}
  for(let i=0;i<100;i++){const tree=[{key:'root',value:generate(3)}];cases.push({name:'generated '+i,request:{text:text(tree)},expected:tree});}
  for(const source of ['root { x one [$WIN32] x two [$LINUX] }','root { x one x = [$WIN32] two }','root { x [$LINUX] one [$WIN32] }','root { x yes [($WIN32 || $OSX) && !$MOBILE] }'])cases.push({name:'condition '+source,request:{text:source,symbols:['WIN32']},expected:moon({action:'evaluate',text:source,symbols:['WIN32']}).tree,knownError:source.includes(' = [')?'InObjectBetweenKeyAndValue':null,knownTree:source.includes('[$LINUX] one')?[{key:'root',value:[]}]:null});
  for(const source of ['#base base.vdf root { a own nested { a own } }','root { a own } #include extra.vdf']){
    const files={'base.vdf':'root { a default b value nested { a default b value } }','extra.vdf':'tail { key value }'};
    cases.push({name:'reference '+source,request:{text:source,files},expected:moon({action:'resolve',source:'main',files:{...files,main:source}}).tree,knownError:source.includes('#include')?'Inclusions are only valid at the beginning':null});
  }
  const tree=[{key:'root',type:'object',value:[{key:'n',type:'int32',value:'-2147483648'},{key:'n',type:'uint64',value:'18446744073709551615'},{key:'s',type:'string',value:'中文😀'}]}];
  const binary=moon({action:'binary-encode',tree}).base64;
  cases.push({name:'typed binary',request:{binary},expected:[{key:'root',value:[{key:'n',value:'-2147483648'},{key:'n',value:'18446744073709551615'},{key:'s',value:'中文😀'}]}]});
  const result=spawnSync(dotnet,[path.join(root,'tools/reference-dotnet/bin/Release/net10.0/Reference.dll')],{input:cases.map(c=>JSON.stringify(c.request)).join('\n')+'\n',encoding:'utf8',maxBuffer:16*1024*1024,timeout:60000,env:{...process.env,DOTNET_CLI_TELEMETRY_OPTOUT:'1'}});
  if(result.error)throw result.error;assert.equal(result.status,0,result.stderr);
  const responses=result.stdout.trim().split(/\r?\n/).map(line=>JSON.parse(line));assert.equal(responses.length,cases.length);
  let matched=0,differences=0;
  for(let i=0;i<cases.length;i++){const actual=responses[i],expected=cases[i];if(expected.knownError){assert.equal(actual.ok,false,expected.name);assert.ok(actual.error.includes(expected.knownError),actual.error);differences++;continue;}assert.equal(actual.ok,true,expected.name+': '+actual.error);if(expected.knownTree){assert.deepEqual(actual.tree,expected.knownTree,expected.name);assert.notDeepEqual(actual.tree,expected.expected);differences++;continue;}assert.deepEqual(actual.tree,expected.expected,expected.name);if(!expected.request.binary){const written=Buffer.from(actual.roundtrip,'base64').toString('utf8');assert.deepEqual(moon({action:'parse',text:written}).tree,expected.expected,'Reference serialization '+expected.name);}matched++;}
  console.log(`${matched} ValveKeyValue 0.70.0.499 cases matched; ${differences} known released-version difference explicitly asserted`);
})().catch(error=>{console.error(error);process.exitCode=1;});

const assert=require('node:assert/strict'),path=require('node:path'),{pathToFileURL}=require('node:url');
(async()=>{
  const {dispatch}=await import(pathToFileURL(path.resolve(__dirname,'../web/editor/moonvalve.mjs')));
  let cases=0;
  function run(request){return JSON.parse(dispatch(JSON.stringify(request)));}
  function ok(request){const result=run(request);assert.equal(result.ok,true,JSON.stringify(result.error));return result.result;}
  function test(name,body){body();console.log(`ok ${++cases} - ${name}`);}
  test('browser parse retains duplicate keys and root references',()=>{
    const result=ok({action:'parse',text:'#base defaults root { tag one tag two [$WIN32] }'});
    assert.equal(result.tree[0].key,'#base');assert.equal(result.tree[1].value.length,2);
  });
  test('browser edit preserves comments and targets precisely one occurrence',()=>{
    const text='// keep\r\nr { k one k two [$WIN32] }';
    const result=ok({action:'apply',text,changes:[{path:[{key:'r',occurrence:0},{key:'k',occurrence:1}],op:'replace',value:'three'}]});
    assert.equal(result.text,text.replace('two','three'));
    assert.equal(run({action:'apply',text,changes:[{path:[{key:'missing',occurrence:0}],op:'remove'}]}).ok,false);
  });
  test('virtual references and conditions use only explicitly provided files',()=>{
    const request={action:'evaluate',source:'main',text:'#base base root { os win [$WIN32] os linux [$LINUX] }',files:{main:'#base base root { os win [$WIN32] os linux [$LINUX] }',base:'root { extra yes }'},symbols:['WIN32']};
    const result=ok(request);assert.deepEqual(result.tree[0].value,[{key:'os',value:'win'},{key:'extra',value:'yes'}]);
    assert.equal(run({...request,files:{main:request.text}}).ok,false);
  });
  test('binary bridge retains maximum integers NaN bits and UTF16 strings',()=>{
    const tree=[{key:'u',type:'uint64',value:'18446744073709551615'},{key:'f',type:'float32bits',value:'2143289345'},{key:'s',type:'wstring',value:'中文😀'}];
    const encoded=ok({action:'binary-encode',tree});assert.deepEqual(ok({action:'binary-decode',base64:encoded.base64}).tree,tree);
    assert.equal(run({action:'binary-decode',base64:'CQ=='}).ok,false);
  });
  test('stream bridge preserves chunk-independent event order',()=>{
    const result=ok({action:'stream',chunks:[...'r { k "中文😀" }']});assert.deepEqual(result.events,[['begin','r'],['pair','k','中文😀'],['end']]);
  });
  test('browser diagnostics expose exact source location and safe failure envelopes',()=>{
    const result=run({action:'parse',text:'r {\n key }'});assert.equal(result.ok,false);assert.equal(result.error.code,'missing_value');assert.equal(result.error.line,2);
    assert.equal(JSON.parse(dispatch('{')).ok,false);
  });
  console.log(`${cases} editor core checks passed`);
})().catch(error=>{console.error(error);process.exitCode=1;});

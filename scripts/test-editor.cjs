const assert=require('node:assert/strict'),path=require('node:path'),{pathToFileURL}=require('node:url');
(async()=>{
  const {dispatch,openCache}=await import(pathToFileURL(path.resolve(__dirname,'../web/editor/moonvalve.mjs')));
  const {cacheSample}=await import(pathToFileURL(path.resolve(__dirname,'../web/editor/samples.mjs')));
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
  test('shortcut forms apply atomic bulk changes and retain unknown fields and IDs',()=>{
    const source=[{key:'unknown-root',type:'string',value:'keep'},...ok({action:'shortcuts-new'}).tree];
    const added=ok({action:'shortcuts-edit',tree:source,changes:[{op:'add',fields:{name:'One',exe:'game1'}},{op:'add',fields:{name:'Two',exe:'game2'}}]});
    added.tree[1].value[0].value.push({key:'unknown-field',type:'uint64',value:'18446744073709551615'});
    const changed=ok({action:'shortcuts-edit',tree:added.tree,changes:added.items.map(s=>({op:'set',index:s.index,fields:{launch_options:'--fullscreen',tags:['中文']}}))});
    assert.deepEqual(changed.items.map(s=>s.app_id),added.items.map(s=>s.app_id));assert.equal(changed.tree[0].value,'keep');assert.ok(changed.tree[1].value[0].value.some(e=>e.key==='unknown-field'));
    assert.deepEqual(changed.items.map(s=>s.tags),[['中文'],['中文']]);
    assert.equal(run({action:'shortcuts-edit',tree:added.tree,changes:[{op:'remove',index:'0'},{op:'set',index:'missing',fields:{name:'Bad'}}]}).ok,false);
    assert.equal(ok({action:'shortcuts-list',tree:added.tree}).items.length,2);
    assert.equal(ok({action:'shortcuts-edit',tree:changed.tree,changes:[{op:'remove',index:'0'}]}).items.length,1);
  });
  test('cache session pages metadata searches IDs and decodes one record',()=>{
    const opened=JSON.parse(openCache(cacheSample()));assert.equal(opened.ok,true,JSON.stringify(opened.error));assert.equal(opened.result.total,230);assert.equal(opened.result.records.length,100);
    const next=ok({action:'cache-page',offset:200});assert.equal(next.records.length,30);assert.equal(next.records[0].id,'680');
    const filtered=ok({action:'cache-page',query:'480'});assert.equal(filtered.total,1);
    const record=ok({action:'cache-read',id:'480'});assert.equal(record.tree[0].value[0].value,'Synthetic Game 1');
    assert.equal(run({action:'cache-read',id:'999999'}).ok,false);assert.equal(run({action:'cache-page',offset:-1}).ok,false);
    assert.equal(JSON.parse(openCache(new Uint8Array([0,1]))).ok,false);assert.equal(run({action:'cache-page'}).ok,false);
    assert.equal(JSON.parse(openCache(cacheSample(1))).ok,true);ok({action:'cache-close'});assert.equal(run({action:'cache-read',id:'480'}).ok,false);
  });
  test('project provenance survives conditions and points inherited duplicate keys to original files',()=>{
    const files={'main':'#base defaults\nroot { k own }','defaults':'root { k base k inherited }'};
    const result=ok({action:'project',source:'main',files,symbols:['WIN32']});assert.equal(result.tree[0].value[1].value,'inherited');
    const inherited=result.origins.find(o=>o.path.at(-1).occurrence===1);assert.equal(inherited.location.source,'defaults');assert.equal(inherited.location.column,15);
    assert.equal(result.references[0].location.line,1);
    const raw=ok({action:'parse',source:'main',text:'😀 yes\r\nr {k one k two}'});assert.equal(raw.origins.at(-1).path.at(-1).occurrence,1);assert.equal(raw.origins.at(-1).line,2);
    assert.equal(run({action:'project',source:'main',files:{main:'#include main'},symbols:[]}).ok,false);
  });
  test('query batch and structure transfer share the MoonBit source editor',()=>{
    const text='// keep\nr {tag one tag two child {}}';assert.equal(ok({action:'query',text,expression:'/**/tag'}).matches.length,2);
    const r=ok({action:'query-edit',text,expression:'/**/tag',operation:{op:'replace',value:'Moon'}});assert.match(r.text,/^\/\/ keep/);assert.equal(r.tree[0].value[1].value,'Moon');
    const moved=ok({action:'transfer',text,plan:{from:[{key:'r',occurrence:0},{key:'tag',occurrence:1}],to:[{key:'r',occurrence:0},{key:'child',occurrence:0}],index:0}});assert.equal(moved.tree[0].value[1].value[0].value,'two');
  });
  test('KV3 typed models and workspace refactors reject invalid requests',()=>{
    const r=ok({action:'kv3-parse',headerless:true,text:'{n=18446744073709551615 arr=[true,null]}'});assert.equal(ok({action:'kv3-from-json',model:r.model}).model.root.value[0].value.value,'18446744073709551615');
    assert.equal(run({action:'kv3-parse',headerless:true,text:'{n=1 n=2}'}).ok,false);
    const snapshot={format:'moonvalve-project-v1',source:'main',files:{main:'#base base\nr {}',base:'r {k v}'}};const result=ok({action:'workspace-edit',snapshot,plan:[{op:'rename',from:'base',to:'new/base'}]});assert.match(result.files.main,/new\/base/);assert.equal(run({action:'workspace-edit',snapshot,plan:[{op:'remove',name:'base'}]}).ok,false);
  });
  test('KV3 local edits preserve unaffected source and reject invalid later steps',()=>{
    const text='// keep\r\n{ name="Moon" n=18446744073709551615 arr=[1,/*tail*/] }';
    const r=ok({action:'kv3-edit',text,headerless:true,plan:[{op:'replace',path:['name'],value:{type:'string',value:'Sun'}},{op:'insert-element',path:['arr'],index:1,value:{type:'null',value:null}}]});
    assert.match(r.text,/^\/\/ keep\r\n/);assert.match(r.text,/18446744073709551615/);assert.match(r.text,/\/\*tail\*\//);assert.equal(r.model.root.value[2].value.value.length,2);
    assert.equal(run({action:'kv3-edit',text,headerless:true,plan:[{op:'remove',path:['name']},{op:'remove',path:['absent']}]}).ok,false);
  });
  test('workspace queries and batch edits share snapshot semantics with CLI',()=>{
    const snapshot={format:'moonvalve-project-v1',source:'a',files:{a:'//keep\nr {path old/a}',b:'r {path other}'}};
    const rows=ok({action:'workspace-query',snapshot,expression:'/r/path'});assert.deepEqual(rows.map(row=>row.file),['a','b']);
    const r=ok({action:'workspace-edit',snapshot,plan:[{op:'query',expression:'/r/path',files:['a'],operation:{op:'replace-prefix',from:'old/',to:'new/'}}]});assert.equal(r.files.a,'//keep\nr {path new/a}');assert.equal(r.files.b,snapshot.files.b);
    assert.equal(run({action:'workspace-edit',snapshot,plan:[{op:'query',expression:'/r/path',files:[],operation:{op:'replace-prefix',from:'old/',to:'new/'}}]}).ok,false);
  });
  test('project ZIP and typed KV3 worker actions expose exactly the same core behavior',()=>{
    const snapshot={format:'moonvalve-project-v1',source:'main.vdf',files:{'main.vdf':'r {}','cfg/base.vdf':'r {k yes}'}};const exported=ok({action:'workspace-zip',snapshot}),bytes=Buffer.from(exported.base64,'base64');assert.equal(bytes.length,exported.size);assert.equal(bytes.readUInt32LE(0),0x04034b50);
    const text='//😀\r\n{arr=[resource:"old/a",resource:"old/b"] n=18446744073709551615}';const q=ok({action:'kv3-query',text,headerless:true,expression:'/arr/*?flag=resource'});assert.equal(q.matches.length,2);
    const range=ok({action:'kv3-locate',text,headerless:true,path:['n']});assert.equal(Array.from(text).slice(range.selection_start,range.selection_end).join(''),'n');
    const edited=ok({action:'kv3-query-edit',text,headerless:true,expression:'/arr/*?flag=resource',operation:{op:'replace-prefix',from:'old/',to:'new/'}});assert.equal(edited.text,text.replaceAll('old/','new/'));assert.match(edited.text,/18446744073709551615/);
    assert.equal(run({action:'kv3-query-edit',text,headerless:true,expression:'/**',operation:{op:'remove'}}).ok,false);
  });
  console.log(`${cases} editor core checks passed`);
})().catch(error=>{console.error(error);process.exitCode=1;});

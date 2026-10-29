// Seeded malformed-input checks for the binary codecs exposed by the workbench.
const assert=require('node:assert/strict'),path=require('node:path'),{pathToFileURL}=require('node:url');
(async()=>{
  const {dispatch}=await import(pathToFileURL(path.resolve(__dirname,'../web/editor/moonvalve.mjs')));
  const call=q=>JSON.parse(dispatch(JSON.stringify(q))),run=q=>{const r=call(q);assert.equal(r.ok,true,JSON.stringify(r.error));return r.result;};
  let seed=20261030;const random=n=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed%n;};
  const cases=Number(process.env.MOONVALVE_ASSET_FUZZ_CASES||1000);assert.ok(Number.isInteger(cases)&&cases>0&&cases<=100000);
  const binary=run({action:'kv3-to-binary',text:'{name="Moon" items=[1,2,resource:"materials/moon.vmat"] blob=#[00 ff 12] nested={x=true}}',headerless:true,version:5,compression:2});
  const model=run({action:'kv3-binary-decode',base64:binary.base64}).model;
  const dmx=run({action:'dmx-read',base64:Buffer.from('<!-- dmx encoding keyvalues2 1 format model 22 -->\n"DmeRoot" {"id" "elementid" "11111111-2222-4333-8444-555555555555" "name" "string" "Moon" "arr" "float_array" ["1","2","3"]}').toString('base64')});
  const inputs=[['kv3-binary-decode',binary],['kv3-binary-decode',run({action:'kv3-to-binary',text:'[true,false,#[00 ff 12],{a=1}]',headerless:true,version:4,compression:1})],['resource-inspect',run({action:'kv3-resource-encode',model,compression:2})],['vpk-index',run({action:'vpk-create',files:{'materials/moon.vmt':Buffer.from('UnlitGeneric {}').toString('base64'),'readme.txt':Buffer.from('hello').toString('base64')},preload:3})],['dmx-read',run({action:'dmx-write',model:dmx.model,version:5})]];
  let accepted=0,rejected=0;
  for(const [action,input]of inputs){
    const original=Buffer.from(input.base64,'base64');
    for(let i=0;i<cases;i++){
      let bytes=Buffer.from(original);const kind=i%4;
      if(kind===0)bytes=bytes.subarray(0,random(bytes.length));
      else if(kind===1){const offset=random(bytes.length);bytes[offset]^=1<<random(8);}
      else if(kind===2){const offset=random(Math.max(1,bytes.length-3));bytes.fill(255,offset,Math.min(offset+4,bytes.length));}
      else bytes=Buffer.concat([bytes,Buffer.from([random(256)])]);
      const r=call({action,base64:bytes.toString('base64')});assert.equal(typeof r.ok,'boolean');
      if(!r.ok){assert.equal(typeof r.error.message,'string');rejected++;continue;}accepted++;
      if(action==='kv3-binary-decode'){
        const encoded=run({action:'kv3-binary-encode',model:{...r.result.model,version:5,compression:0}});
        assert.deepEqual(run({action,base64:encoded.base64}).model.root,r.result.model.root);
      }else if(action==='dmx-read'){
        const encoded=run({action:'dmx-write',model:r.result.model});
        assert.deepEqual(run({action,base64:encoded.base64}).model,r.result.model);
      }
    }
  }
  console.log(JSON.stringify({seed:20261030,cases:cases*inputs.length,accepted,rejected,uncaught_failures:0}));
})().catch(e=>{console.error(e);process.exitCode=1;});

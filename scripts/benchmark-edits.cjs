// Compare identical edits through one bridge request; includes parsing and JSON.
const assert=require('node:assert/strict'),path=require('node:path'),{pathToFileURL}=require('node:url');
(async()=>{
  const {dispatch}=await import(pathToFileURL(path.resolve(__dirname,'../web/editor/moonvalve.mjs')));
  const run=request=>{const r=JSON.parse(dispatch(JSON.stringify(request)));assert.equal(r.ok,true,JSON.stringify(r.error));return r.result;};
  console.log(JSON.stringify({node:process.version,platform:process.platform,architecture:process.arch,metric:'bridge wall time including parsing, validated source edits and JSON output; one warmup, three measured runs'}));
  for(const [entries,count] of [[1000,50],[5000,200]]){
    const text='root {\n'+Array.from({length:entries},(_,i)=>'key'+i+' "value '+i+' 中文"\n').join('')+'}\n';
    const changes=Array.from({length:count},(_,i)=>({path:[{key:'root',occurrence:0},{key:'key'+i,occurrence:0}],op:'replace',value:'changed '+i}));
    let expected;const times={};
    for(const sequential of [true,false]){const elapsed=[];for(let i=0;i<4;i++){const start=performance.now(),r=run({action:'apply',text,changes,sequential});const duration=performance.now()-start;if(expected)assert.equal(r.text,expected);else expected=r.text;if(i)elapsed.push(duration);}elapsed.sort((a,b)=>a-b);times[sequential?'sequential_ms':'batch_ms']=+elapsed[1].toFixed(2);}
    console.log(JSON.stringify({entries,changes:count,input_bytes:Buffer.byteLength(text),...times}));
  }
})().catch(e=>{console.error(e);process.exitCode=1;});

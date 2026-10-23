// Deterministic mutation testing with automatic reduction of reproducible failures.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),{pathToFileURL}=require('node:url');
(async()=>{
  const root=path.resolve(__dirname,'..'),{dispatch}=await import(pathToFileURL(path.join(root,'web/editor/moonvalve.mjs')));
  const count=Number(process.env.MOONVALVE_FUZZ_CASES||3000);if(!Number.isInteger(count)||count<1||count>100000)throw new Error('Invalid fuzz count');
  let state=Number(process.env.MOONVALVE_FUZZ_SEED||20261023)>>>0,accepted=0,rejected=0;
  const seed=state,random=n=>{state=(Math.imul(state,1664525)+1013904223)>>>0;return state%n;};
  const binarySeeds=JSON.parse(fs.readFileSync(path.join(root,'fixtures/reference-binary.json'),'utf8')).map(v=>Buffer.from(v.hex,'hex'));
  const run=request=>JSON.parse(dispatch(JSON.stringify(request)));
  function verify(source){const parsed=run({action:'parse',text:source});if(!parsed.ok)return false;const formatted=run({action:'format',text:source});if(!formatted.ok)throw new Error('Accepted source cannot be serialized');assert.deepEqual(run({action:'parse',text:formatted.result.text}).result.tree,parsed.result.tree,'Canonical roundtrip');const chunks=[];for(let i=0;i<source.length;){let end=Math.min(source.length,i+1+random(7));if(end<source.length&&source.charCodeAt(end-1)>=0xd800&&source.charCodeAt(end-1)<=0xdbff)end++;chunks.push(source.slice(i,end));i=end;}const streamed=run({action:'stream',chunks});assert.equal(streamed.ok,true,JSON.stringify(streamed.error));const tree=[],stack=[tree];for(const [tag,key,value]of streamed.result.events){if(tag==='pair')stack.at(-1).push({key,value});else if(tag==='begin'){const children=[];stack.at(-1).push({key,value:children});stack.push(children);}else if(tag==='end')stack.pop();}assert.deepEqual(tree,parsed.result.tree,'Stream/document agreement');return true;}
  function reduce(source){let result=source;for(let width=Math.max(1,Math.floor(result.length/2));width>=1;width=Math.floor(width/2)){let attempts=0;for(let i=0;i+width<=result.length&&attempts++<128;){const candidate=result.slice(0,i)+result.slice(i+width);try{verify(candidate);i+=width;}catch{result=candidate;}}}return result;}
  const valid=['root { key "中文😀" key two nested { a b } }','// comment\r\nr { path "a\\\\b" empty "" }','a one a two','root { k = value }'];
  const alphabet='{}[]=\"/\\ \r\n\t$!&|abc012中文';
  for(let i=0;i<count;i++){
    let source=valid[random(valid.length)];
    if(i%4!==0){const edits=1+random(6);for(let j=0;j<edits;j++){const index=random(source.length+1);if(random(2)&&index<source.length)source=source.slice(0,index)+source.slice(index+1);else source=source.slice(0,index)+alphabet[random(alphabet.length)]+source.slice(index);}}
    try{verify(source)?accepted++:rejected++;}
    catch(error){const minimized=reduce(source);fs.mkdirSync(path.join(root,'_build'),{recursive:true});fs.writeFileSync(path.join(root,'_build/fuzz-failure.json'),JSON.stringify({seed,case:i,source,minimized,error:error.message},null,2));throw new Error(`Fuzz case ${i} failed; reduced reproducer saved in _build/fuzz-failure.json`);}
    let bytes;
    if(i%2===0){bytes=Buffer.from(binarySeeds[random(binarySeeds.length)]);const mutation=random(3);if(mutation===0)bytes=bytes.subarray(0,random(bytes.length));else if(mutation===1)bytes[random(bytes.length)]^=1<<random(8);else bytes=Buffer.concat([bytes,Buffer.from([random(256)])]);}
    else bytes=Buffer.from(Array.from({length:random(64)},()=>random(256)));
    const binary=run({action:'binary-decode',base64:bytes.toString('base64')});
    if(binary.ok){const encoded=run({action:'binary-encode',tree:binary.result.tree});assert.equal(encoded.ok,true);assert.deepEqual(Buffer.from(encoded.result.base64,'base64'),bytes,'Exact binary roundtrip');}
  }
  console.log(`seed=${seed}, ${count} text mutations (${accepted} accepted/${rejected} rejected) and ${count} binary mutations passed`);
})().catch(error=>{console.error(error);process.exitCode=1;});

const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto'),assert=require('node:assert/strict'),{pathToFileURL}=require('node:url');
(async()=>{
  const root=path.resolve(__dirname,'..'),folder=path.join(root,'fixtures/upstream/proton');
  const provenance=JSON.parse(fs.readFileSync(path.join(folder,'provenance.json'),'utf8'));
  assert.equal(provenance.license,'BSD-3-Clause');assert.match(fs.readFileSync(path.join(folder,provenance.license_file),'utf8'),/Valve Corporation/);
  const {dispatch}=await import(pathToFileURL(path.join(root,'web/editor/moonvalve.mjs')));
  const run=request=>{const r=JSON.parse(dispatch(JSON.stringify(request)));assert.equal(r.ok,true,JSON.stringify(r.error));return r.result;};
  for(const file of provenance.files){
    const bytes=fs.readFileSync(path.join(folder,file.path));assert.equal(crypto.createHash('sha256').update(bytes).digest('hex'),file.sha256,file.path);
    const text=new TextDecoder('utf-8',{fatal:true}).decode(bytes),tree=run({action:'parse',text}).tree;
    assert.equal(tree.length,1);assert.ok(Array.isArray(tree[0].value));
    const formatted=run({action:'format',text}).text;assert.deepEqual(run({action:'parse',text:formatted}).tree,tree);
    const preserved=run({action:'format-preserving',text}).text;assert.deepEqual(run({action:'parse',text:preserved}).tree,tree);assert.equal(run({action:'format-preserving',text:preserved}).text,preserved);
    for(const comment of text.match(/\/\/[^\r\n]*/g)||[])assert.ok(preserved.includes(comment),'Preserve production comment text');
    if(file.path==='compatibilitytool.vdf.template'){
      assert.equal(tree[0].key,'compatibilitytools');
      const r=run({action:'query-edit',text,expression:'/**/display_name',operation:{op:'replace',value:'MoonValve compatibility check'}});
      assert.ok(r.text.includes('// Can register this tool with Steam in two ways:'));
      assert.equal(run({action:'query',text:r.text,expression:'/**/display_name?=="MoonValve compatibility check"'}).matches.length,1);
      assert.equal(run({action:'query',text,expression:'/**/file'}).matches.length,0);
    }else{
      assert.equal(tree[0].key,'manifest');const fields=new Map(tree[0].value.map(row=>[row.key,row.value]));
      assert.equal(fields.get('version'),'2');assert.equal(fields.get('commandline'),'/proton %verb%');assert.equal(fields.get('compatmanager_layer_name'),'proton');
      assert.equal(fields.get('require_tool_appid'),file.path.includes('arm64')?'4185400':'4183110');
    }
  }
  console.log(provenance.files.length+' pinned production Proton VDF manifests/templates: hashes, semantic checks, roundtrip and preserving edits passed');
})().catch(e=>{console.error(e);process.exitCode=1;});

// A paused consumer must apply backpressure without losing output or buffering
// the entire input in the CLI. Both producers and consumers use bounded chunks.
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),crypto=require('node:crypto'),assert=require('node:assert/strict'),{spawn}=require('node:child_process');
const root=path.resolve(__dirname,'..'),native=process.argv.includes('--native');
const binary=native?['_build/native/release/build/cmd/main/main.exe','_build/native/release/build/cmd/main/main'].map(p=>path.join(root,p)).find(fs.existsSync):path.join(root,'_build/js/release/build/cmd/main/main.js');
const temporary=fs.mkdtempSync(path.join(os.tmpdir(),'moonvalve-stream-'));
(async()=>{
  try{
    const file=path.join(temporary,'input.vdf'),fd=fs.openSync(file,'w'),line='  "key" "'+ 'x'.repeat(100)+'"\n';
    const expected=crypto.createHash('sha256');function write(text){fs.writeSync(fd,text);expected.update(text);}
    write('"root"\n{\n');for(let i=0;i<200;i++)write(line.repeat(1000));write('}\n');fs.closeSync(fd);
    const child=spawn(native?binary:process.execPath,native?['stream-format',file]:['--max-old-space-size=48',binary,'stream-format',file],{cwd:root,stdio:['ignore','pipe','pipe']});
    let bytes=0,errors='';const hash=crypto.createHash('sha256');
    child.stdout.on('data',chunk=>{bytes+=chunk.length;hash.update(chunk);child.stdout.pause();setTimeout(()=>child.stdout.resume(),2);});
    child.stderr.on('data',chunk=>{if(errors.length<4096)errors+=chunk;});
    const timeout=setTimeout(()=>child.kill(),60000);
    const code=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('close',resolve);});clearTimeout(timeout);
    assert.equal(code,0,errors);assert.equal(hash.digest('hex'),expected.digest('hex'));assert.equal(bytes,fs.statSync(file).size);
    console.log(`${native?'Native':'JavaScript'} streaming pipe verified: ${bytes} bytes; paused consumer; exact SHA-256${native?'':'; 48 MiB JS heap limit'}`);
  }finally{fs.rmSync(temporary,{recursive:true,force:true});}
})().catch(error=>{console.error(error);process.exitCode=1;});

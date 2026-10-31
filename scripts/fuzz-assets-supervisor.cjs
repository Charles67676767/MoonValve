// Bound decoder CPU/heap and retain a replayable last input on any failure.
const {fork}=require('node:child_process'),fs=require('node:fs'),path=require('node:path');
const root=path.resolve(__dirname,'..'),failure=path.join(root,'_build/fuzz-assets-failure.json');
const replay=process.argv.indexOf('--replay'),env={...process.env};
if(replay>=0){if(!process.argv[replay+1])throw new Error('--replay requires a saved failure file');env.MOONVALVE_ASSET_REPLAY=path.resolve(process.argv[replay+1]);}
const child=fork(path.join(__dirname,'fuzz-assets-worker.cjs'),[],{cwd:root,env,execArgv:['--max-old-space-size=192'],stdio:['ignore','inherit','inherit','ipc']});
let last=null,reason='',finished=false,timer;
const save=()=>{fs.mkdirSync(path.dirname(failure),{recursive:true});fs.writeFileSync(failure,JSON.stringify({seed:env.MOONVALVE_ASSET_FUZZ_SEED||20261030,reason,request:last},null,2));};
function stop(message){if(finished)return;reason=message;save();child.kill();}
function deadline(){clearTimeout(timer);timer=setTimeout(()=>stop('No decoder progress for 10 seconds'),10000);}
child.on('message',m=>{if(m.request){last=m.request;deadline();}});
child.on('error',e=>stop(e.message));
child.on('exit',(code,signal)=>{finished=true;clearTimeout(timer);clearTimeout(total);if(code!==0||signal){reason=reason||`Worker exit ${code}, signal ${signal}`;save();console.error(reason+'; replay with node scripts/fuzz-assets.cjs --replay _build/fuzz-assets-failure.json');process.exitCode=1;}});
deadline();const total=setTimeout(()=>stop('Total decoder budget exceeded 120 seconds'),120000);

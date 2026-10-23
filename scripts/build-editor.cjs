const fs=require('node:fs'),path=require('node:path'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..');
const built=spawnSync('moon',['build','web/bridge','--target','js','--release','--deny-warn'],{cwd:root,stdio:'inherit',shell:false});
if(built.error)throw built.error;if(built.status)process.exit(built.status);
fs.copyFileSync(path.join(root,'_build/js/release/build/web/bridge/bridge.js'),path.join(root,'web/editor/moonvalve.mjs'));
console.log('Local editor built. Run node scripts/serve-editor.cjs');

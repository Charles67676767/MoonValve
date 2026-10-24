const fs=require('node:fs'),path=require('node:path'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),folder=path.join(root,'extensions/vscode');
const version=JSON.parse(fs.readFileSync(path.join(folder,'package.json'),'utf8')).version;
fs.mkdirSync(path.join(root,'_build'),{recursive:true});
const tool=path.join(folder,'node_modules/@vscode/vsce/vsce');
if(!fs.existsSync(tool))throw new Error('Run npm ci --ignore-scripts in extensions/vscode first');
const result=spawnSync(process.execPath,[tool,'package','--no-dependencies','--out',path.join(root,'_build/moonvalve-'+version+'.vsix')],{cwd:folder,stdio:'inherit'});
if(result.error)throw result.error;process.exitCode=result.status;

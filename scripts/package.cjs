const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),crypto=require('node:crypto'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),manifest=fs.readFileSync(path.join(root,'moon.mod'),'utf8');
const version=/^version\s*=\s*"([^"]+)"/m.exec(manifest)[1],name=`moonvalve-${version}-${process.platform}-${process.arch}`;
const destination=path.join(root,'_build/packages',name);
if(fs.existsSync(destination))throw new Error('Package directory exists; choose a clean build directory');
const candidates=['_build/native/release/build/cmd/main/main.exe','_build/native/release/build/cmd/main/main'];
const binary=candidates.map(p=>path.join(root,p)).find(p=>fs.existsSync(p));
if(!binary)throw new Error('Build the native release CLI first');
const result=spawnSync(binary,['version'],{encoding:'utf8'});if(result.error)throw result.error;
if(result.status||JSON.parse(result.stdout).version!==version)throw new Error('CLI and module versions differ');
const hash=data=>crypto.createHash('sha256').update(data).digest('hex');
function copy(source,target){fs.mkdirSync(path.dirname(target),{recursive:true});fs.copyFileSync(source,target);}
function copyTree(source,target){for(const item of fs.readdirSync(source,{withFileTypes:true})){if(item.isDirectory())copyTree(path.join(source,item.name),path.join(target,item.name));else if(item.isFile())copy(path.join(source,item.name),path.join(target,item.name));}}
fs.mkdirSync(destination,{recursive:true});
copy(binary,path.join(destination,process.platform==='win32'?'moonvalve.exe':'moonvalve'));
copy(path.join(root,'_build/js/release/build/cmd/main/main.js'),path.join(destination,'moonvalve.cjs'));
for(const file of ['LICENSE','NOTICE.md','pkg.generated.mbti'])copy(path.join(root,file),path.join(destination,file));
copyTree(path.join(root,'docs'),path.join(destination,'docs'));
copyTree(path.join(root,'fixtures'),path.join(destination,'fixtures'));
copyTree(path.join(root,'web/editor'),path.join(destination,'web/editor'));
for(const file of ['package.json','extension.cjs','client.cjs','language-configuration.json','kv3-language-configuration.json','README.md','LICENSE'])copy(path.join(root,'extensions/vscode',file),path.join(destination,'extensions/vscode',file));
copy(path.join(root,'_build',`moonvalve-${version}.vsix`),path.join(destination,'extensions',`moonvalve-${version}.vsix`));
copy(path.join(root,'scripts/serve-editor.cjs'),path.join(destination,'scripts/serve-editor.cjs'));
const moonHome=process.env.MOON_HOME||path.join(os.homedir(),'.moon');
copy(path.join(moonHome,'lib/core/LICENSE'),path.join(destination,'licenses/Apache-2.0.txt'));
copy(path.join(moonHome,'lib/core/NOTICE'),path.join(destination,'licenses/MoonBit-core-NOTICE.txt'));
fs.writeFileSync(path.join(destination,'licenses/MoonBit-runtime-NOTICE.txt'),'MoonBit native runtime\nCopyright 2026 International Digital Economy Academy\nLicensed under the Apache License, Version 2.0 (Apache-2.0.txt).\nSource: https://github.com/moonbitlang/moonbit-native-runtime\n');
fs.writeFileSync(path.join(destination,'README.txt'),`MoonValve ${version}\n\nNative CLI: ${process.platform==='win32'?'moonvalve.exe': './moonvalve'} help\nJavaScript CLI (Node 22+): node moonvalve.cjs help\nLocal workbench: node scripts/serve-editor.cjs\nThen open http://127.0.0.1:8765\n\nNo Node runtime is required by the native CLI.\nSee docs/commands.md, docs/editor.md and docs/api.md.\nFiles are read-only unless --in-place is explicitly requested; saves create FILE.bak.\n`);
const commit=spawnSync('git',['rev-parse','HEAD'],{cwd:root,encoding:'utf8'}).stdout.trim();
fs.writeFileSync(path.join(destination,'BUILD.json'),JSON.stringify({name:'MoonValve',version,commit,platform:process.platform,arch:process.arch,minimum_moonc:'0.10.14',toolchain:'0.10.14+7d59c7ec9'},null,2)+'\n');
function files(directory,prefix=''){return fs.readdirSync(directory,{withFileTypes:true}).flatMap(item=>item.isDirectory()?files(path.join(directory,item.name),prefix+item.name+'/'):[prefix+item.name]).sort();}
const contents=files(destination);
fs.writeFileSync(path.join(destination,'SHA256SUMS'),contents.map(file=>hash(fs.readFileSync(path.join(destination,file)))+'  '+file).join('\n')+'\n');
// Store-only ZIP with stable dates, UTF-8 filenames and executable Unix modes.
function crc32(data){let value=0xffffffff;for(const byte of data){value^=byte;for(let i=0;i<8;i++)value=(value>>>1)^((value&1)?0xedb88320:0);}return (value^0xffffffff)>>>0;}
const local=[],central=[];let offset=0;
for(const file of files(destination)){
  const filename=Buffer.from(name+'/'+file),data=fs.readFileSync(path.join(destination,file)),crc=crc32(data);
  const header=Buffer.alloc(30);header.writeUInt32LE(0x04034b50,0);header.writeUInt16LE(20,4);header.writeUInt16LE(0x800,6);header.writeUInt16LE(0x2821,12);header.writeUInt32LE(crc,14);header.writeUInt32LE(data.length,18);header.writeUInt32LE(data.length,22);header.writeUInt16LE(filename.length,26);
  local.push(header,filename,data);
  const record=Buffer.alloc(46);record.writeUInt32LE(0x02014b50,0);record.writeUInt16LE(0x314,4);record.writeUInt16LE(20,6);record.writeUInt16LE(0x800,8);record.writeUInt16LE(0x2821,14);record.writeUInt32LE(crc,16);record.writeUInt32LE(data.length,20);record.writeUInt32LE(data.length,24);record.writeUInt16LE(filename.length,28);record.writeUInt32LE(((file==='moonvalve'?0o100755:0o100644)<<16)>>>0,38);record.writeUInt32LE(offset,42);central.push(record,filename);offset+=header.length+filename.length+data.length;
}
const directory=Buffer.concat(central),end=Buffer.alloc(22);end.writeUInt32LE(0x06054b50,0);end.writeUInt16LE(central.length/2,8);end.writeUInt16LE(central.length/2,10);end.writeUInt32LE(directory.length,12);end.writeUInt32LE(offset,16);
const archive=path.join(path.dirname(destination),name+'.zip');fs.writeFileSync(archive,Buffer.concat([...local,directory,end]));
fs.writeFileSync(archive+'.sha256',hash(fs.readFileSync(archive))+'  '+path.basename(archive)+'\n');
console.log('Package created: '+path.relative(root,archive));

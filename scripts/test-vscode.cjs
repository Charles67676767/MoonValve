const fs=require('node:fs'),path=require('node:path'),assert=require('node:assert/strict'),{spawnSync}=require('node:child_process');
const root=path.resolve(__dirname,'..'),test=require('../extensions/vscode/node_modules/@vscode/test-electron');
(async()=>{
  const version=JSON.parse(fs.readFileSync(path.join(root,'extensions/vscode/package.json'),'utf8')).version;
  const build=path.join(root,'_build/vscode-e2e'),workspace=path.join(build,'workspace'),extensions=path.join(build,'extensions'),user=path.join(build,'user');
  fs.mkdirSync(path.join(workspace,'.vscode'),{recursive:true});fs.mkdirSync(path.join(user,'User'),{recursive:true});
  const native=['_build/native/release/build/cmd/main/main.exe','_build/native/release/build/cmd/main/main'].map(p=>path.join(root,p)).find(fs.existsSync);assert.ok(native,'Build native release CLI first');
  fs.writeFileSync(path.join(user,'User/settings.json'),JSON.stringify({'moonvalve.serverPath':native,'moonvalve.serverArgs':['lsp'],'telemetry.telemetryLevel':'off','workbench.startupEditor':'none','extensions.autoUpdate':false}));
  fs.writeFileSync(path.join(workspace,'main.vdf'),'#base base.vdf\nroot\n{\n tag one\n tag two\n}\n');fs.writeFileSync(path.join(workspace,'base.vdf'),'root { inherited yes }');fs.writeFileSync(path.join(workspace,'plain.vdf'),'root {key "😀"}');
  fs.copyFileSync(path.join(root,'fixtures/sample.kv3'),path.join(workspace,'resource.kv3'));
  let executable=process.env.MOONVALVE_VSCODE_EXECUTABLE;
  if(!executable&&process.platform==='win32'){const local=path.join(process.env.LOCALAPPDATA,'Programs/Microsoft VS Code/Code.exe');if(fs.existsSync(local))executable=local;}
  executable=executable||await test.downloadAndUnzipVSCode({version:'1.143.1',cachePath:path.join(root,'_build/vscode-download')});
  const shared=['--user-data-dir',user,'--extensions-dir',extensions],vsix=path.join(root,'_build',`moonvalve-${version}.vsix`);assert.ok(fs.existsSync(vsix),'Package extension first');
  // The regular Windows launcher may be versioned; its batch wrapper locates the right CLI.
  let install;
  if(process.platform==='win32'){
    const cli=path.join(path.dirname(executable),'bin/code.cmd');
    const wrapper=fs.readFileSync(cli,'utf8'),match=wrapper.match(/"%~dp0\.\.\\([^"]+cli\.js)"/);assert.ok(match,'VS Code launcher CLI path');
    const entry=path.join(path.dirname(executable),match[1]);assert.ok(fs.existsSync(entry));
    install=spawnSync(executable,[entry,...shared,'--install-extension',vsix,'--force'],{env:{...process.env,ELECTRON_RUN_AS_NODE:'1',VSCODE_DEV:''},encoding:'utf8',timeout:120000,windowsHide:true});
  }else{
    const [cli,...args]=test.resolveCliArgsFromVSCodeExecutablePath(executable,{reuseMachineInstall:true});
    install=spawnSync(cli,[...args,...shared,'--install-extension',vsix,'--force'],{encoding:'utf8',timeout:120000});
  }
  if(install.error)throw install.error;assert.equal(install.status,0,install.stderr+'\n'+install.stdout);console.log(install.stdout.trim());
  const env={...process.env};delete env.ELECTRON_RUN_AS_NODE;
  const args=[workspace,...shared,'--extensionDevelopmentPath='+path.join(root,'integration/vscode-host'),'--extensionTestsPath='+path.join(root,'integration/vscode-host/suite.cjs'),'--disable-workspace-trust','--skip-welcome','--skip-release-notes','--disable-updates','--disable-gpu'];
  const child=require('node:child_process').spawn(executable,args,{env:{...env,MOONVALVE_E2E_WORKSPACE:workspace,MOONVALVE_E2E_EXTENSIONS:extensions,MOONVALVE_E2E_REPORT:path.join(build,'results.json')},windowsHide:true});
  const log=fs.createWriteStream(path.join(build,'host.log'));child.stdout.pipe(log);child.stderr.pipe(log);
  const code=await new Promise((resolve,reject)=>{const timer=setTimeout(()=>{child.kill();reject(new Error('VS Code test timed out'));},120000);child.on('error',e=>{clearTimeout(timer);reject(e);});child.on('exit',code=>{clearTimeout(timer);resolve(code);});});
  if(code!==0){if(fs.existsSync(path.join(build,'results.json')))console.error(fs.readFileSync(path.join(build,'results.json'),'utf8'));throw new Error('VS Code test failed; see _build/vscode-e2e/host.log');}
  const result=JSON.parse(fs.readFileSync(path.join(build,'results.json'),'utf8'));assert.equal(result.success,true);assert.equal(result.extension_version,version);console.log('Real VS Code '+result.host+': installed VSIX '+version+', '+result.checks.length+' checks passed');
})().catch(error=>{console.error(error);process.exitCode=1;});

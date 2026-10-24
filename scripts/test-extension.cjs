// Exercise the extension adapter against the real server with a small VS Code API host.
const assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),{createRequire}=require('node:module');
const root=path.resolve(__dirname,'..'),entry=path.join(root,'extensions/vscode/extension.cjs'),localRequire=createRequire(entry);
const providers={},events={},messages=[],disposed=()=>({dispose(){}}),on=name=>fn=>{events[name]=fn;return disposed();};
class Range{constructor(a,b,c,d){this.start={line:a,character:b};this.end={line:c,character:d};}}
class DocumentSymbol{constructor(name,detail,kind,range,selectionRange){Object.assign(this,{name,detail,kind,range,selectionRange});}}
class TextEdit{constructor(range,newText){Object.assign(this,{range,newText});}}
const document={uri:{toString:()=> 'file:///project/main.vdf'},languageId:'moonvalve-kv1',version:1,text:'r { k "😀" }',getText(){return this.text;}};
const languages={createDiagnosticCollection:()=>({set(){},dispose(){}})};
for(const type of ['DocumentSymbol','Definition','DocumentLink','FoldingRange','CompletionItem','Hover','DocumentFormattingEdit'])languages['register'+type+'Provider']=(_selector,provider)=>{providers[type]=provider;return disposed();};
const vscode={Range,DocumentSymbol,TextEdit,languages,Uri:{parse:s=>({toString:()=>s})},window:{createOutputChannel:()=>({append(){},appendLine(){},dispose(){}}),showErrorMessage:s=>messages.push(s)},workspace:{isTrusted:true,workspaceFolders:[],textDocuments:[document],getConfiguration:()=>({get:(key,fallback)=>key==='serverPath'?process.execPath:key==='serverArgs'?[path.join(root,'_build/js/release/build/cmd/main/main.js'),'lsp']:fallback}),onDidOpenTextDocument:on('open'),onDidChangeTextDocument:on('change'),onDidCloseTextDocument:on('close'),onDidSaveTextDocument:on('save'),findFiles:async()=>[],createFileSystemWatcher:()=>({onDidChange:on('fileChange'),onDidCreate:on('fileCreate'),onDidDelete:on('fileDelete'),dispose(){}})}};
const moduleHost={exports:{}};
vm.runInNewContext(fs.readFileSync(entry,'utf8'),{require:name=>name==='vscode'?vscode:localRequire(name),module:moduleHost,process,TextDecoder,setTimeout,clearTimeout,console},{filename:entry});
(async()=>{const extension=moduleHost.exports;try{
  const context={subscriptions:[]};await extension.activate(context);assert.deepEqual(messages,[]);assert.equal(Object.keys(providers).length,7);
  let symbols=await providers.DocumentSymbol.provideDocumentSymbols(document);assert.equal(symbols[0].children[0].name,'k');assert.equal(symbols[0].range.start.line,0);
  document.version=2;document.text='r { k Moon }';events.change({document,contentChanges:[{range:{start:{line:0,character:7},end:{line:0,character:9}},rangeLength:2,text:'Moon'}]});
  const edits=await providers.DocumentFormattingEdit.provideDocumentFormattingEdits(document);assert.match(edits[0].newText,/Moon/);
  events.close(document);assert.deepEqual(await providers.DocumentSymbol.provideDocumentSymbols(document),[]);
  events.open(document);symbols=await providers.DocumentSymbol.provideDocumentSymbols(document);assert.equal(symbols[0].children.length,1);
  console.log('VS Code adapter activation, seven providers, UTF16 change, close and reopen passed (API host + real MoonBit server)');
}finally{await extension.deactivate();}})().catch(e=>{console.error(e);process.exitCode=1;});

const vscode=require('vscode'),{spawn}=require('node:child_process'),{RpcClient}=require('./client.cjs');
let client,child,channel;
const supported=document=>['moonvalve-kv1','moonvalve-kv3'].includes(document.languageId);
function notify(method,params){try{client?.notify(method,params);}catch(error){channel?.appendLine(error.message);}}
const docParam=document=>({textDocument:{uri:document.uri.toString()}});
const position=p=>({line:p.line,character:p.character});
const range=r=>({start:position(r.start),end:position(r.end)});
const toRange=r=>new vscode.Range(r.start.line,r.start.character,r.end.line,r.end.character);
async function activate(context) {
  if(!vscode.workspace.isTrusted)return;
  channel=vscode.window.createOutputChannel('MoonValve');context.subscriptions.push(channel);
  const config=vscode.workspace.getConfiguration('moonvalve');
  child=spawn(config.get('serverPath','moonvalve'),config.get('serverArgs',['lsp']),{stdio:['pipe','pipe','pipe'],windowsHide:true,shell:false});
  child.stderr.on('data',bytes=>channel.append(bytes.toString()));
  client=new RpcClient(child);
  const diagnostics=vscode.languages.createDiagnosticCollection('MoonValve');context.subscriptions.push(diagnostics);
  client.on('notification',message=>{
    if(message.method==='textDocument/publishDiagnostics') {
      const params=message.params,open=vscode.workspace.textDocuments.find(doc=>doc.uri.toString()===params.uri);
      if(open&&params.version!==undefined&&open.version!==params.version)return;
      diagnostics.set(vscode.Uri.parse(params.uri),params.diagnostics.map(row=>{
        const item=new vscode.Diagnostic(toRange(row.range),row.message,Math.max(0,(row.severity||1)-1));item.source='MoonValve';item.code=row.code;return item;
      }));
    }else if(message.method==='window/logMessage')channel.appendLine(message.params.message);
  });
  try {
    await client.request('initialize',{processId:process.pid,rootUri:vscode.workspace.workspaceFolders?.[0]?.uri.toString()||null,capabilities:{general:{positionEncodings:['utf-16']},textDocument:{documentSymbol:{hierarchicalDocumentSymbolSupport:true},publishDiagnostics:{versionSupport:true}}},initializationOptions:{literalPaths:config.get('literalPaths',false)}});
    notify('initialized');
  }catch(error){client.dispose();vscode.window.showErrorMessage('MoonValve 无法启动：'+error.message+'。请配置 moonvalve.serverPath / serverArgs。');return;}
  const selector=[{language:'moonvalve-kv1'},{language:'moonvalve-kv3'}];
  const safe=fn=>async(...args)=>{try{return await fn(...args);}catch(error){channel.appendLine(error.message);return undefined;}};
  const ask=(method,document,extra={})=>client.request(method,{...docParam(document),...extra});
  function open(document){if(supported(document))notify('textDocument/didOpen',{textDocument:{uri:document.uri.toString(),languageId:document.languageId,version:document.version,text:document.getText()}});}
  for(const document of vscode.workspace.textDocuments)open(document);
  context.subscriptions.push(vscode.workspace.onDidOpenTextDocument(open));
  context.subscriptions.push(vscode.workspace.onDidChangeTextDocument(event=>{
    if(supported(event.document)&&event.contentChanges.length)notify('textDocument/didChange',{textDocument:{uri:event.document.uri.toString(),version:event.document.version},contentChanges:event.contentChanges.map(change=>({range:range(change.range),rangeLength:change.rangeLength,text:change.text}))});
  }));
  context.subscriptions.push(vscode.workspace.onDidCloseTextDocument(document=>{if(supported(document))notify('textDocument/didClose',docParam(document));}));
  let cached=new Map();
  async function cache(uri) {
    if(!vscode.workspace.getWorkspaceFolder(uri))return;
    try {
      const bytes=await vscode.workspace.fs.readFile(uri),key=uri.toString();
      if(bytes.length>8*1024*1024)return;
      const total=[...cached].reduce((n,[name,size])=>n+(name===key?0:size),bytes.length);
      if(total>16*1024*1024||(!cached.has(key)&&cached.size>=64))return;
      const text=new TextDecoder('utf-8',{fatal:true}).decode(bytes);
      notify('moonvalve/setFile',{uri:key,text});cached.set(key,bytes.length);
    }catch(error){channel.appendLine('Workspace cache: '+error.message);}
  }
  context.subscriptions.push(vscode.workspace.onDidSaveTextDocument(document=>cache(document.uri)));
  const glob='**/*.{vdf,acf,res,kv,kv3,txt}',watcher=vscode.workspace.createFileSystemWatcher(glob);context.subscriptions.push(watcher);
  watcher.onDidChange(uri=>cache(uri),null,context.subscriptions);watcher.onDidCreate(uri=>cache(uri),null,context.subscriptions);
  watcher.onDidDelete(uri=>{cached.delete(uri.toString());notify('moonvalve/removeFile',{uri:uri.toString()});},null,context.subscriptions);
  function symbols(rows){return rows.map(row=>{const symbol=new vscode.DocumentSymbol(row.name,row.detail||'',row.kind-1,toRange(row.range),toRange(row.selectionRange));symbol.children=symbols(row.children||[]);return symbol;});}
  context.subscriptions.push(vscode.languages.registerDocumentSymbolProvider(selector,{provideDocumentSymbols:safe(async doc=>symbols(await ask('textDocument/documentSymbol',doc)))}));
  context.subscriptions.push(vscode.languages.registerDefinitionProvider(selector,{provideDefinition:safe(async(doc,p)=>(await ask('textDocument/definition',doc,{position:position(p)})).map(row=>new vscode.Location(vscode.Uri.parse(row.uri),toRange(row.range))))}));
  context.subscriptions.push(vscode.languages.registerDocumentLinkProvider(selector,{provideDocumentLinks:safe(async doc=>(await ask('textDocument/documentLink',doc)).map(row=>new vscode.DocumentLink(toRange(row.range),vscode.Uri.parse(row.target))))}));
  context.subscriptions.push(vscode.languages.registerFoldingRangeProvider(selector,{provideFoldingRanges:safe(async doc=>(await ask('textDocument/foldingRange',doc)).map(row=>new vscode.FoldingRange(row.startLine,row.endLine,vscode.FoldingRangeKind.Region)))}));
  context.subscriptions.push(vscode.languages.registerCompletionItemProvider(selector,{provideCompletionItems:safe(async(doc,p)=>(await ask('textDocument/completion',doc,{position:position(p)})).map(row=>{const item=new vscode.CompletionItem(row.label,(row.kind||1)-1);item.insertText=row.insertText;if(row.textEdit)item.textEdit=new vscode.TextEdit(toRange(row.textEdit.range),row.textEdit.newText);return item;}))},'"','/'));
  context.subscriptions.push(vscode.languages.registerHoverProvider(selector,{provideHover:safe(async(doc,p)=>{const result=await ask('textDocument/hover',doc,{position:position(p)});if(!result)return;const content=new vscode.MarkdownString();content.appendText(result.contents.value);return new vscode.Hover(content,result.range?toRange(result.range):undefined);})}));
  context.subscriptions.push(vscode.languages.registerDocumentFormattingEditProvider(selector,{provideDocumentFormattingEdits:safe(async doc=>(await ask('textDocument/formatting',doc)).map(row=>new vscode.TextEdit(toRange(row.range),row.newText)))}));
  const files=await vscode.workspace.findFiles(glob,'**/{node_modules,.git,_build,target,bin,obj}/**',64);
  for(const uri of files)await cache(uri);
}
async function deactivate() {
  if(!client)return;
  try{await Promise.race([client.request('shutdown'),new Promise((_,reject)=>setTimeout(()=>reject(new Error('shutdown timeout')),1500))]);notify('exit');}catch{}
  setTimeout(()=>client?.dispose(),500).unref();
}
module.exports={activate,deactivate};

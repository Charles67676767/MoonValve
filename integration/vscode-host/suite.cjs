const vscode=require('vscode'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path');
exports.run=async()=>{
  const checks=[],folder=process.env.MOONVALVE_E2E_WORKSPACE,report=process.env.MOONVALVE_E2E_REPORT;
  const uri=name=>vscode.Uri.file(path.join(folder,name));
  const result={host:vscode.version,installed_from_vsix:true,checks};
  const command=(name,...args)=>vscode.commands.executeCommand('vscode.'+name,...args);
  function formattedText(document,edits){let text=document.getText();const changes=edits.map(edit=>({start:document.offsetAt(edit.range.start),end:document.offsetAt(edit.range.end),text:edit.newText})).sort((a,b)=>b.start-a.start);for(const edit of changes)text=text.slice(0,edit.start)+edit.text+text.slice(edit.end);return text;}
  async function waitFor(read,label){const deadline=Date.now()+10000;while(Date.now()<deadline){const value=await read();if(value)return value;await new Promise(resolve=>setTimeout(resolve,50));}throw new Error('Timed out: '+label);}
  try{
    const extension=vscode.extensions.getExtension('Charles67676767.moonvalve');assert.ok(extension,'Installed VSIX is discoverable');
    assert.ok(extension.extensionPath.startsWith(process.env.MOONVALVE_E2E_EXTENSIONS+path.sep),'Must load installed VSIX, not checkout');
    result.extension_version=extension.packageJSON.version;await extension.activate();checks.push('installed VSIX activation');
    const main=await vscode.workspace.openTextDocument(uri('main.vdf'));await vscode.window.showTextDocument(main);assert.equal(main.languageId,'moonvalve-kv1');
    const symbols=await waitFor(async()=>{const rows=await command('executeDocumentSymbolProvider',main.uri);return rows?.length?rows:null;},'symbols');assert.ok(symbols.some(row=>row.name==='root'));checks.push('language recognition and symbols');
    const definitions=await command('executeDefinitionProvider',main.uri,new vscode.Position(0,9));assert.equal(definitions[0].uri.toString(),uri('base.vdf').toString());checks.push('workspace reference definition');
    const links=await command('executeLinkProvider',main.uri);assert.equal(links[0].target.toString(),uri('base.vdf').toString());checks.push('document links');
    const completions=await command('executeCompletionItemProvider',main.uri,new vscode.Position(0,9));assert.ok(completions.items.some(row=>row.label==='base.vdf'));checks.push('reference completion');
    const keyPosition=main.positionAt(main.getText().indexOf('tag'));
    const hovers=await command('executeHoverProvider',main.uri,keyPosition);assert.ok(hovers.length);checks.push('hover');
    const folding=await command('executeFoldingRangeProvider',main.uri);assert.ok(folding.length);checks.push('folding');
    const plain=await vscode.workspace.openTextDocument(uri('plain.vdf'));await vscode.window.showTextDocument(plain);
    const offset=plain.getText().indexOf('😀'),edit=new vscode.WorkspaceEdit();edit.replace(plain.uri,new vscode.Range(plain.positionAt(offset),plain.positionAt(offset+2)),'Moon');assert.equal(await vscode.workspace.applyEdit(edit),true);
    let formatting=await command('executeFormatDocumentProvider',plain.uri,{tabSize:2,insertSpaces:true});assert.match(formattedText(plain,formatting),/Moon/);checks.push('UTF16 incremental edits and formatting');
    const saved=plain.getText(),broken=new vscode.WorkspaceEdit();broken.replace(plain.uri,new vscode.Range(new vscode.Position(0,0),plain.positionAt(saved.length)),'root { key }');await vscode.workspace.applyEdit(broken);
    await waitFor(()=>vscode.languages.getDiagnostics(plain.uri).some(row=>row.severity===vscode.DiagnosticSeverity.Error),'syntax diagnostic');checks.push('published diagnostics');
    const restore=new vscode.WorkspaceEdit();restore.replace(plain.uri,new vscode.Range(new vscode.Position(0,0),plain.positionAt(plain.getText().length)),saved);await vscode.workspace.applyEdit(restore);
    await waitFor(()=>vscode.languages.getDiagnostics(plain.uri).length===0,'clear diagnostics');checks.push('diagnostic recovery');
    const kv3=await vscode.workspace.openTextDocument(uri('resource.kv3'));await vscode.window.showTextDocument(kv3);assert.equal(kv3.languageId,'moonvalve-kv3');
    formatting=await command('executeFormatDocumentProvider',kv3.uri,{tabSize:2,insertSpaces:true});const formatted=formattedText(kv3,formatting);assert.match(formatted,/18446744073709551615/);assert.match(formatted,/resource:/);checks.push('KV3 language and exact typed formatting');
    const rename=new vscode.WorkspaceEdit();rename.renameFile(uri('base.vdf'),uri('renamed.vdf'));assert.equal(await vscode.workspace.applyEdit(rename),true);
    await waitFor(()=>main.getText().includes('renamed.vdf'),'automatic reference rename');checks.push('file rename updates incoming reference');
    await main.save();const renamed=await vscode.workspace.openTextDocument(uri('renamed.vdf'));
    const linkEdits=await command('executeLinkProvider',main.uri);assert.equal(linkEdits[0].target.toString(),renamed.uri.toString());checks.push('renamed cache navigation');
    const changeReference=new vscode.WorkspaceEdit();changeReference.replace(main.uri,new vscode.Range(new vscode.Position(0,0),main.positionAt(main.getText().length)),'#base absent.vdf\nroot {}');await vscode.workspace.applyEdit(changeReference);
    await waitFor(()=>vscode.languages.getDiagnostics(main.uri).some(row=>row.code==='missing_reference'),'confirmed missing target');checks.push('filesystem-confirmed missing reference');
    const restoreMain=new vscode.WorkspaceEdit();restoreMain.replace(main.uri,new vscode.Range(new vscode.Position(0,0),main.positionAt(main.getText().length)),'#base renamed.vdf\nroot {}');await vscode.workspace.applyEdit(restoreMain);
    const cycle=new vscode.WorkspaceEdit();cycle.replace(renamed.uri,new vscode.Range(new vscode.Position(0,0),renamed.positionAt(renamed.getText().length)),'#include main.vdf\nroot {}');await vscode.workspace.applyEdit(cycle);
    await waitFor(()=>vscode.languages.getDiagnostics(main.uri).some(row=>row.code==='reference_cycle'&&row.message.includes('main.vdf')),'live reference cycle');checks.push('unsaved cross-file cycle diagnostic');
    const removeCycle=new vscode.WorkspaceEdit();removeCycle.replace(renamed.uri,new vscode.Range(new vscode.Position(0,0),renamed.positionAt(renamed.getText().length)),'root {}');await vscode.workspace.applyEdit(removeCycle);
    await waitFor(()=>vscode.languages.getDiagnostics(main.uri).length===0,'cross-file recovery');checks.push('dependent diagnostic recovery');
    result.success=true;
  }catch(error){result.success=false;result.error=error.message;throw error;}
  finally{fs.writeFileSync(report,JSON.stringify(result,null,2)+'\n');}
};

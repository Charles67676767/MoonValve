import {setupKV3Tree} from './kv3-tree.mjs';
export function setupKV3(api,show) {
  const $=id=>document.getElementById(id),source=$('kv3-source'),model=$('kv3-model');let name='example.kv3',history=[];
  const guard=fn=>async(...args)=>{try{await fn(...args);}catch(e){api.status(e.message||String(e),true);}};
  async function edit(step,title){const before=source.value,h=$('kv3-headerless').checked;const result=await api.core({action:'kv3-edit',text:before,headerless:h,plan:[step]});preview(result,title,before,h);}
  const tree=setupKV3Tree(api,{source,headerless:$('kv3-headerless'),edit,guard});
  function render(result){tree.set(result.model,source.value,$('kv3-headerless').checked);model.value=JSON.stringify(result.model,null,2);$('kv3-tree').textContent='根类型：'+result.model.root.type+' · 点击树节点可定位原文并编辑';}
  async function parse(){const text=source.value,headerless=$('kv3-headerless').checked;const result=await api.core({action:'kv3-parse',text,headerless});if(text!==source.value||headerless!==$('kv3-headerless').checked)throw new Error('内容已变化，请重新解析。');render(result);api.status('KV3 解析成功 · 类型与整数精度已保留');return result;}
  async function loadKV3(text,filename){source.value=text;name=filename;$('kv3-filename').textContent=name;history=[];$('kv3-undo').disabled=true;show('kv3');await parse();}
  function preview(result,title,before,headerless){api.preview(result.text,title,async()=>{if(source.value!==before||headerless!==$('kv3-headerless').checked)throw new Error('KV3 内容或选项已变化，请重新预览。');history.push(before);if(history.length>20)history.shift();source.value=result.text;$('kv3-undo').disabled=false;render(result);},before);}
  $('kv3-parse').onclick=guard(parse);
  $('kv3-format').onclick=guard(async()=>{const before=source.value,h=$('kv3-headerless').checked;preview(await parse(),'KV3 规范化 · 注释将由规范化文本替代',before,h);});
  $('kv3-json-preview').onclick=guard(async()=>{const before=source.value,h=$('kv3-headerless').checked;preview(await api.core({action:'kv3-from-json',model:JSON.parse(model.value)}),'应用类型 JSON 到 KV3 文本',before,h);});
  $('kv3-edit-preview').onclick=guard(async()=>{
    const before=source.value,h=$('kv3-headerless').checked,op=$('kv3-edit-op').value;
    const step={op,path:JSON.parse($('kv3-edit-path').value)};
    if(['replace','insert-field','insert-element'].includes(op))step.value=JSON.parse($('kv3-edit-value').value);
    if(['rename','insert-field'].includes(op))step.key=$('kv3-edit-key').value;
    if(op.startsWith('insert-'))step.index=Number($('kv3-edit-index').value);
    const result=await api.core({action:'kv3-edit',text:before,headerless:h,plan:[step]});
    preview(result,'KV3 局部修改 · 保留其余原文',before,h);
  });
  function queryStamp(){return JSON.stringify([source.value,$('kv3-headerless').checked]);}
  async function query(action){
    const before=source.value,h=$('kv3-headerless').checked,stamp=queryStamp(),expression=$('kv3-query-expression').value;
    const request={action,text:before,headerless:h,expression};
    if(action==='kv3-query-edit'){
      const op=$('kv3-query-operation').value;
      const type=$('kv3-query-type').value;const value={type,value:type==='bool'?$('kv3-query-bool').checked:type==='null'?null:$('kv3-query-value').value};
      request.operation=op==='replace'?{op,value}:op==='replace-prefix'?{op,from:$('kv3-query-from').value,to:$('kv3-query-to').value}:op==='rename'?{op,key:$('kv3-query-key').value}:{op};
    }
    const result=await api.core(request);if(queryStamp()!==stamp)throw new Error('源文件或选项已变化，请重新查询。');
    await parse();
    $('kv3-query-count').textContent=result.matches.length+' 项匹配';$('kv3-query-results').replaceChildren();
    for(const row of result.matches.slice(0,1000)){const button=document.createElement('button');button.textContent=JSON.stringify(row.path)+' · '+(row.value.type==='flag'?row.value.flag+': '+row.value.value.type:row.value.type);button.onclick=guard(async()=>{if(queryStamp()!==stamp)throw new Error('源文件已变化，请重新查询。');await tree.reveal(row.path);});$('kv3-query-results').append(button);}
    if(result.matches.length>1000)$('kv3-query-count').textContent+='（显示前 1000 项）';
    if(action==='kv3-query-edit')preview(result,'KV3 批量修改 · '+result.matches.length+' 项',before,h);
  }
  function queryControls(){const op=$('kv3-query-operation').value,type=$('kv3-query-type').value;for(const key of ['from','to'])$('kv3-query-'+key+'-field').hidden=op!=='replace-prefix';$('kv3-query-type-field').hidden=op!=='replace';$('kv3-query-value-field').hidden=op!=='replace'||['bool','null'].includes(type);$('kv3-query-bool-field').hidden=op!=='replace'||type!=='bool';$('kv3-query-key-field').hidden=op!=='rename';}
  $('kv3-query-operation').onchange=queryControls;$('kv3-query-type').onchange=queryControls;queryControls();
  $('kv3-query-run').onclick=guard(()=>query('kv3-query'));
  $('kv3-query-preview').onclick=guard(()=>query('kv3-query-edit'));
  $('kv3-undo').onclick=guard(async()=>{if(history.length){source.value=history.pop();$('kv3-undo').disabled=!history.length;await parse();}});
  $('kv3-open').onclick=()=>$('kv3-input').click();
  $('kv3-input').onchange=guard(async event=>{const file=event.target.files[0];event.target.value='';if(!file)return;if(file.size>8*1024*1024)throw new Error('KV3 文件超过 8 MiB。');await loadKV3(new TextDecoder('utf-8',{fatal:true}).decode(await file.arrayBuffer()),file.name);});
  $('kv3-demo').onclick=guard(()=>loadKV3('<!-- kv3 encoding:text:version{e21c7f3c-8a33-41c5-9977-a76d3a32aa0d} format:generic:version{7412167c-06e9-4698-aff2-e63eb59037e7} -->\n{\n name = "Moon Harbor"\n enabled = true\n id = 18446744073709551615\n resources = [resource:"materials/moon.vmat", null]\n data = #[00 ff 7a]\n}\n','example.kv3'));
  $('kv3-download').onclick=guard(async()=>{const before=source.value;await parse();api.download(before,name.replace(/(\.[^.]*)?$/,'.edited$1'),'text/plain;charset=utf-8');});
  $('kv3-export').onclick=guard(async()=>{await parse();api.download(model.value,name+'.json','application/json');});
  source.oninput=()=>{tree.invalidate();$('kv3-query-results').replaceChildren();$('kv3-query-count').textContent='源文件已变化，请重新查询。';$('kv3-tree').textContent='内容已变化，请重新解析。';};
  $('kv3-headerless').onchange=()=>tree.invalidate();
  return {loadKV3};
}

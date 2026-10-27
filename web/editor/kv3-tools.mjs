export function setupKV3(api,show) {
  const $=id=>document.getElementById(id),source=$('kv3-source'),model=$('kv3-model');let name='example.kv3',history=[];
  const guard=fn=>async(...args)=>{try{await fn(...args);}catch(e){api.status(e.message||String(e),true);}};
  function render(result){model.value=JSON.stringify(result.model,null,2);$('kv3-tree').textContent='根类型：'+result.model.root.type+' · 使用类型 JSON 查看与修改完整内容';}
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
  $('kv3-undo').onclick=guard(async()=>{if(history.length){source.value=history.pop();$('kv3-undo').disabled=!history.length;await parse();}});
  $('kv3-open').onclick=()=>$('kv3-input').click();
  $('kv3-input').onchange=guard(async event=>{const file=event.target.files[0];event.target.value='';if(!file)return;if(file.size>8*1024*1024)throw new Error('KV3 文件超过 8 MiB。');await loadKV3(new TextDecoder('utf-8',{fatal:true}).decode(await file.arrayBuffer()),file.name);});
  $('kv3-demo').onclick=guard(()=>loadKV3('<!-- kv3 encoding:text:version{e21c7f3c-8a33-41c5-9977-a76d3a32aa0d} format:generic:version{7412167c-06e9-4698-aff2-e63eb59037e7} -->\n{\n name = "Moon Harbor"\n enabled = true\n id = 18446744073709551615\n resources = [resource:"materials/moon.vmat", null]\n data = #[00 ff 7a]\n}\n','example.kv3'));
  $('kv3-download').onclick=guard(async()=>{const before=source.value;await parse();api.download(before,name.replace(/(\.[^.]*)?$/,'.edited$1'),'text/plain;charset=utf-8');});
  $('kv3-export').onclick=guard(async()=>{await parse();api.download(model.value,name+'.json','application/json');});
  source.oninput=()=>{$('kv3-tree').textContent='内容已变化，请重新解析。';};
  return {loadKV3};
}

// Typed rendering and source selection; parsing and edits stay in MoonBit.
export function setupKV3Tree(api,{source,headerless,edit,guard}) {
  const $=id=>document.getElementById(id),root=$('kv3-nodes');
  let model=null,stamp='',mode=false,selected=null,expanded=new Set(['[]']);
  const plain=node=>node.type==='flag'?node.value:node;
  const fresh=()=>{if(!model||source.value!==stamp||headerless.checked!==mode)throw new Error('源文件或选项已变化，请重新解析。');};
  const children=node=>{const n=plain(node);return n.type==='object'?n.value.map(e=>[e.key,e.value]):n.type==='array'?n.value.map((v,i)=>[String(i),v]):[];};
  function at(path){let n=model.root;for(const key of path){const p=plain(n);if(p.type==='object'){const e=p.value.find(e=>e.key===key);if(!e)throw new Error('字段已不存在。');n=e.value;}else if(p.type==='array'){n=p.value[Number(key)];if(!n)throw new Error('数组元素已不存在。');}else throw new Error('路径不是容器。');}return n;}
  function summary(node){const p=plain(node),prefix=node.type==='flag'?node.flag+': ':'';return prefix+p.type+(p.type==='object'||p.type==='array'?' ('+p.value.length+')':p.type==='blob'?' ('+p.value.length/2+' 字节)':p.type==='null'?'':' · '+String(p.value).slice(0,100));}
  function render(){
    root.replaceChildren();let count=0;
    function row(node,path,name,depth){
      if(count++>=5000)return;const descendants=children(node),key=JSON.stringify(path),wrapper=document.createElement('div');wrapper.className='kv3-tree-row';wrapper.style.paddingLeft=depth*16+'px';
      const toggle=document.createElement('button');toggle.className='kv3-toggle';toggle.textContent=descendants.length?(expanded.has(key)?'▾':'▸'):'·';toggle.disabled=!descendants.length;toggle.setAttribute('aria-label','展开 '+key);toggle.onclick=()=>{expanded.has(key)?expanded.delete(key):expanded.add(key);render();};
      const button=document.createElement('button');button.className='kv3-node';button.dataset.path=key;button.textContent=name+' · '+summary(node);button.setAttribute('role','treeitem');button.setAttribute('aria-level',String(depth+1));button.setAttribute('aria-selected',JSON.stringify(selected)===key?'true':'false');if(descendants.length)button.setAttribute('aria-expanded',String(expanded.has(key)));button.onclick=guard(()=>select(path));wrapper.append(toggle,button);root.append(wrapper);
      if(expanded.has(key))for(const [child,value]of descendants){if(count>=5000)break;row(value,[...path,child],plain(node).type==='array'?'['+child+']':child,depth+1);}
    }
    if(model)row(model.root,[],'文档根',0);if(count>=5000){const note=document.createElement('p');note.textContent='当前展示上限为 5000 个节点，请折叠分支或通过查询定位。';root.append(note);}
  }
  function fields(path,node){
    const p=plain(node),scalar=!['object','array'].includes(p.type);$('kv3-node-path').textContent=JSON.stringify(path)+' · '+summary(node);$('kv3-node-value').value=p.type==='null'?'':String(p.value);$('kv3-node-bool').checked=p.value===true;$('kv3-node-bool-label').hidden=p.type!=='bool';$('kv3-node-value-label').hidden=p.type==='bool'||!scalar||p.type==='null';$('kv3-node-set').disabled=!scalar;$('kv3-node-remove').disabled=!path.length;
    const parent=path.length?plain(at(path.slice(0,-1))):null,renamable=parent?.type==='object';$('kv3-node-key').value=renamable?path.at(-1):'';$('kv3-node-rename').disabled=!renamable;$('kv3-edit-path').value=JSON.stringify(path);
  }
  async function select(path){
    fresh();const before=stamp,h=mode,node=at(path),range=await api.core({action:'kv3-locate',text:before,headerless:h,path});fresh();if(stamp!==before)throw new Error('源文件已变化，请重新选择。');selected=[...path];fields(path,node);render();
    const chars=Array.from(source.value),start=chars.slice(0,range.selection_start).join('').length,end=chars.slice(0,range.selection_end).join('').length;source.focus();source.setSelectionRange(start,end);api.status('已定位 KV3 节点 '+JSON.stringify(path));
  }
  function current(){fresh();if(!selected)throw new Error('请先选择树中的字段或元素。');return {path:[...selected],node:at(selected)};}
  $('kv3-node-set').onclick=guard(async()=>{const {path,node}=current(),p=plain(node);let changed;if(p.type==='bool')changed={type:'bool',value:$('kv3-node-bool').checked};else if(p.type==='null')changed={type:'null',value:null};else changed={type:p.type,value:$('kv3-node-value').value};if(node.type==='flag')changed={type:'flag',flag:node.flag,value:changed};await edit({op:'replace',path,value:changed},'修改 KV3 字段值');});
  $('kv3-node-rename').onclick=guard(async()=>{const {path}=current();await edit({op:'rename',path,key:$('kv3-node-key').value},'重命名 KV3 字段');});
  $('kv3-node-remove').onclick=guard(async()=>{const {path}=current();await edit({op:'remove',path},'删除 KV3 字段或元素');});
  return {
    set(next,text,h){model=next;stamp=text;mode=h;selected=null;expanded=new Set(['[]']);$('kv3-node-path').textContent='从树中选择字段或数组元素';$('kv3-node-value').value='';$('kv3-node-key').value='';$('kv3-node-value-label').hidden=true;$('kv3-node-bool-label').hidden=true;for(const id of ['kv3-node-set','kv3-node-remove','kv3-node-rename'])$(id).disabled=true;render();},
    invalidate(){model=null;selected=null;root.replaceChildren();$('kv3-node-path').textContent='源文件已变化，请重新解析';for(const id of ['kv3-node-set','kv3-node-remove','kv3-node-rename'])$(id).disabled=true;},
    async reveal(path){fresh();for(let i=0;i<path.length;i++)expanded.add(JSON.stringify(path.slice(0,i)));await select(path);}
  };
}

// UI state and file selection only. MoonBit owns all format and Steam semantics.
export function setupTools(api) {
  const $ = id => document.getElementById(id);
  const guard = fn => async (...args) => { try { await fn(...args); } catch (e) { api.status(e.message || String(e), true); } };
  const button = (text, click) => { const el = document.createElement('button'); el.textContent = text; el.onclick = guard(click); return el; };
  const lines = text => text.split(/\r?\n/).map(s => s.trim()).filter(Boolean);
  let panel = 'config', shortcuts = [], selectedShortcut = null, cachePage = null, cacheRecord = null, cacheName = '', cacheRevision = 0;
  let project = null, analyzedFiles = null, analyzedOptions = '';

  function show(name) {
    panel = name;
    $('open').hidden = $('download').hidden = name !== 'config';
    $('size').hidden = name === 'cache' || name === 'project';
    for (const tab of document.querySelectorAll('[data-panel]')) tab.classList.toggle('active', tab.dataset.panel === name);
    for (const key of ['config', 'shortcuts', 'cache', 'project']) $('panel-' + key).hidden = name !== key;
  }
  for (const tab of document.querySelectorAll('[data-panel]')) tab.onclick = guard(async () => {
    show(tab.dataset.panel);
    if (panel === 'shortcuts') await refreshShortcuts();
    if (panel === 'project') renderFiles();
  });
  function requireShortcutTree() {
    const current = api.current();
    if (!current.valid || current.kind !== 'binary') throw new Error('请打开快捷方式文件，或选择新建 / 加载示例。');
    return current;
  }
  function resetForm(item = null) {
    selectedShortcut = item?.index ?? null;
    $('sc-heading').textContent = item ? '编辑 · ' + item.name : '新增快捷方式';
    for (const [id, value] of Object.entries({'sc-name': item?.name, 'sc-exe': item?.exe, 'sc-dir': item?.start_dir, 'sc-args': item?.launch_options})) $(id).value = value || '';
    $('sc-tags').value = item?.tags.join('\n') || '';
    $('sc-id').textContent = item ? `AppID ${item.app_id} · ${item.url}` : '新增时由 MoonBit 核心计算 AppID。';
  }
  function renderShortcuts() {
    const query = $('sc-search').value.toLowerCase(), list = $('sc-list'); list.replaceChildren();
    const filtered = shortcuts.filter(s => [s.name, s.exe, ...s.tags].join('\n').toLowerCase().includes(query));
    $('sc-summary').textContent = `${filtered.length} / ${shortcuts.length} 个快捷方式 · ${api.current().name}`;
    for (const item of filtered) {
      const row = document.createElement('div'); row.className = 'shortcut-row';
      const check = document.createElement('input'); check.type = 'checkbox'; check.value = item.index; check.setAttribute('aria-label', '选择 ' + item.name);
      const detail = button(item.name, () => resetForm(item));
      const meta = document.createElement('small'); meta.textContent = `${item.exe} · ${item.tags.join(' / ') || '无标签'}`;
      const body = document.createElement('div'); body.append(detail, meta); row.append(check, body); list.append(row);
    }
    if (!filtered.length) list.textContent = '暂无匹配条目。';
  }
  async function refreshShortcuts() {
    shortcuts = [];
    try { const current = requireShortcutTree(); shortcuts = (await api.core({action: 'shortcuts-list', tree: current.tree})).items; renderShortcuts(); }
    catch (e) { $('sc-list').textContent = e.message; $('sc-summary').textContent = ''; }
  }
  async function previewShortcuts(changes) {
    const current = requireShortcutTree(), before = JSON.stringify(current.tree);
    const result = await api.core({action: 'shortcuts-edit', tree: current.tree, changes});
    api.preview(JSON.stringify(result.items, null, 2), '快捷方式修改预览', async () => {
      if (JSON.stringify(api.current().tree) !== before) throw new Error('文档已变化，请重新预览。');
      await api.apply(JSON.stringify(result.tree, null, 2)); resetForm(); await refreshShortcuts();
    }, JSON.stringify(shortcuts, null, 2));
  }
  $('sc-search').oninput = renderShortcuts;
  $('sc-reset').onclick = () => resetForm();
  $('sc-open').onclick = () => api.open();
  $('sc-download').onclick = guard(async () => { requireShortcutTree(); await api.save(); });
  $('sc-new').onclick = guard(async () => { const result = await api.core({action: 'shortcuts-new'}); await api.load(JSON.stringify(result.tree, null, 2), 'shortcuts.vdf', 'binary'); resetForm(); await refreshShortcuts(); });
  $('sc-demo').onclick = guard(async () => {
    const empty = await api.core({action: 'shortcuts-new'});
    const result = await api.core({action: 'shortcuts-edit', tree: empty.tree, changes: [
      {op: 'add', fields: {name: 'Moon Harbor', exe: '"D:\\Games\\MoonHarbor.exe"', start_dir: 'D:\\Games', tags: ['独立游戏', '手柄']}},
      {op: 'add', fields: {name: 'Lunar Workshop', exe: './lunar-workshop', launch_options: '--windowed', tags: ['创作']}}
    ]});
    await api.load(JSON.stringify(result.tree, null, 2), 'shortcuts.vdf', 'binary'); resetForm(); await refreshShortcuts();
  });
  $('sc-form').onsubmit = guard(async event => {
    event.preventDefault();
    const fields = {name: $('sc-name').value, exe: $('sc-exe').value, start_dir: $('sc-dir').value, launch_options: $('sc-args').value, tags: lines($('sc-tags').value)};
    await previewShortcuts([{op: selectedShortcut === null ? 'add' : 'set', index: selectedShortcut, fields}]);
  });
  function selectedIndices() {
    const indices = [...$('sc-list').querySelectorAll('input:checked')].map(input => input.value);
    if (!indices.length) throw new Error('请先勾选快捷方式。');
    return indices;
  }
  $('sc-delete').onclick = guard(() => previewShortcuts(selectedIndices().map(index => ({op: 'remove', index}))));
  $('sc-bulk').onclick = guard(() => { selectedIndices(); $('sc-bulk-dialog').showModal(); });
  $('sc-bulk-preview').onclick = guard(async () => {
    const fields = {};
    if ($('bulk-dir-on').checked) fields.start_dir = $('bulk-dir').value;
    if ($('bulk-args-on').checked) fields.launch_options = $('bulk-args').value;
    if ($('bulk-tags-on').checked) fields.tags = lines($('bulk-tags').value);
    if (!Object.keys(fields).length) throw new Error('请勾选至少一个需要修改的字段。');
    const changes = selectedIndices().map(index => ({op: 'set', index, fields}));
    $('sc-bulk-dialog').close(); await previewShortcuts(changes);
  });

  function clearRecord() {
    cacheRecord = null; $('cache-detail').textContent = '选择一条记录查看。'; $('cache-detail-tree').replaceChildren();
    $('cache-record-title').textContent = '记录内容'; $('cache-export').disabled = $('cache-edit').disabled = true;
  }
  function renderCache(page) {
    cachePage = page;
    $('cache-summary').textContent = `${cacheName} · ${page.format} v${page.version} · ${page.total} 条匹配记录`;
    $('cache-page').textContent = page.total ? `${page.offset + 1}–${Math.min(page.offset + 100, page.total)} / ${page.total}` : '0 条';
    $('cache-prev').disabled = page.offset === 0; $('cache-next').disabled = page.offset + 100 >= page.total;
    $('cache-list').replaceChildren();
    for (const row of page.records) {
      const item = button(`ID ${row.id} · 变更 ${row.change_number} · ${row.length} 字节`, async () => {
        const revision = cacheRevision;
        const record = await api.core({action: 'cache-read', id: row.id});
        if (revision !== cacheRevision) return;
        cacheRecord = {...record, id: row.id}; $('cache-detail').textContent = JSON.stringify(record.tree, null, 2);
        $('cache-record-title').textContent = 'ID ' + row.id; $('cache-export').disabled = $('cache-edit').disabled = false;
        renderDetailTree(record.tree, $('cache-detail-tree'));
        api.status('已按需解码记录 ' + row.id);
      });
      $('cache-list').append(item);
    }
    if (!page.records.length) $('cache-list').textContent = '暂无匹配记录。';
  }
  function renderDetailTree(entries, target) {
    target.replaceChildren(); let count = 0;
    function add(rows, parent) {
      for (const entry of rows) {
        if (++count > 1000) return;
        if (Array.isArray(entry.value)) {
          const details = document.createElement('details'), summary = document.createElement('summary'); summary.textContent = entry.key + ' · ' + entry.value.length + ' 项'; details.append(summary); add(entry.value, details); parent.append(details);
        } else { const line = document.createElement('div'); line.textContent = `${entry.key} = ${entry.value} (${entry.type})`; parent.append(line); }
      }
    }
    add(entries, target);
    if (count > 1000) { const note = document.createElement('p'); note.textContent = '树形展示前 1000 项，完整内容可导出。'; target.append(note); }
  }
  async function openCache(bytes, name) {
    const revision = ++cacheRevision; clearRecord(); cachePage = null; $('cache-list').textContent = '正在建立索引…';
    cacheName = name;
    try { const page = await api.core({action: 'cache-open', buffer: bytes}); if(revision !== cacheRevision)return; renderCache(page); api.status('缓存索引已建立，选择记录后解码。'); }
    catch (e) { $('cache-list').textContent = '缓存未打开。'; $('cache-summary').textContent = '请选择受支持的缓存文件。'; throw e; }
  }
  async function pageCache(offset) {
    const revision = ++cacheRevision; clearRecord();
    const result = await api.core({action: 'cache-page', query: $('cache-query').value.trim(), offset});
    if (revision === cacheRevision) renderCache(result);
  }
  $('cache-open').onclick = () => $('cache-input').click();
  $('cache-input').onchange = guard(async event => {
    const file = event.target.files[0]; event.target.value = ''; if (!file) return;
    if (file.size > 128 * 1024 * 1024) throw new Error('浏览器缓存上限为 128 MiB；更大的文件可使用命令行。');
    $('cache-query').value = ''; await openCache(await file.arrayBuffer(), file.name);
  });
  $('cache-demo').onclick = guard(async () => { const {cacheSample} = await import('./samples.mjs'); $('cache-query').value = ''; await openCache(cacheSample().buffer, 'synthetic-appinfo.vdf'); });
  $('cache-query').oninput = guard(() => cachePage && pageCache(0));
  $('cache-prev').onclick = guard(() => cachePage && pageCache(Math.max(0, cachePage.offset - 100)));
  $('cache-next').onclick = guard(() => cachePage && pageCache(cachePage.offset + 100));
  $('cache-close').onclick = guard(async () => { ++cacheRevision; await api.core({action: 'cache-close'}); cachePage = null; clearRecord(); $('cache-list').replaceChildren(); $('cache-summary').textContent = '缓存已关闭，内存中的索引已释放。'; $('cache-page').textContent = ''; });
  $('cache-export').onclick = () => { if (cacheRecord) api.download(JSON.stringify(cacheRecord.tree, null, 2), `${cacheName}.${cacheRecord.id}.json`, 'application/json'); };
  $('cache-edit').onclick = guard(async () => { if (cacheRecord) { await api.load(JSON.stringify(cacheRecord.tree, null, 2), `cache-${cacheRecord.id}.vdf`, 'binary'); show('config'); } });

  function renderFiles() {
    const files = api.files(), originals = api.originals(), names = Object.keys(files).sort(), previous = $('project-entry').value;
    $('project-entry').replaceChildren(); $('project-files').replaceChildren();
    for (const name of names) {
      const option = document.createElement('option'); option.value = option.textContent = name; $('project-entry').append(option);
      const item = button(name + (files[name] !== originals[name] ? ' · 已修改' : ''), () => jump(name, 0)); item.className = 'project-file'; item.style.paddingLeft = `${10 + (name.split('/').length - 1) * 14}px`; $('project-files').append(item);
    }
    if (names.includes(previous)) $('project-entry').value = previous;
    if (!names.length) $('project-files').textContent = '打开目录或加载示例工程。';
  }
  async function jump(name, offset) {
    const files = api.files();
    if (!(name in files)) throw new Error('工程中不存在文件：' + name);
    await api.load(files[name], name, 'text'); show('config'); api.highlight(offset); api.status(`已定位 ${name} 的原始位置`);
  }
  function invalidateProject() { project = null; analyzedFiles = null; $('project-graph').replaceChildren(); $('project-origins').replaceChildren(); $('project-state').textContent = '选择入口并分析引用。'; }
  async function setProject(files, source) {
    api.setFiles(files); invalidateProject(); renderFiles(); $('project-entry').value = source;
    await api.load(files[source], source, 'text'); show('project');
  }
  $('project-open').onclick = () => $('project-input').click();
  $('project-import').onclick = () => $('project-snapshot').click();
  $('project-snapshot').onchange = guard(async event => {
    const file = event.target.files[0]; event.target.value = ''; if(!file)return;
    if(file.size>48*1024*1024)throw new Error('快照文件过大。');
    const snapshot = JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(await file.arrayBuffer()));
    if(snapshot.format!=='moonvalve-project-v1'||!snapshot.files||Array.isArray(snapshot.files)||typeof snapshot.files!=='object')throw new Error('无效的 MoonValve 工程快照。');
    const names=Object.keys(snapshot.files);let size=0;
    if(!names.length||names.length>64)throw new Error('快照需包含 1–64 个文件。');
    for(const name of names){if(!name||name.includes('\\')||name.includes(':')||name.includes('\0')||name.startsWith('/')||name.split('/').some(p=>p==='..'||p==='.'||p==='')||typeof snapshot.files[name]!=='string')throw new Error('快照包含无效路径或内容。');size+=new TextEncoder().encode(snapshot.files[name]).length;}
    if(size>16*1024*1024)throw new Error('快照文本合计超过 16 MiB。');
    const source=names.includes(snapshot.source)?snapshot.source:names.sort()[0];await setProject(snapshot.files,source);
  });
  $('project-input').onchange = guard(async event => {
    const files = [...event.target.files].filter(f => /\.(vdf|acf|res|txt)$/i.test(f.name)); event.target.value = '';
    if (!files.length || files.length > 64 || files.reduce((n, f) => n + f.size, 0) > 16 * 1024 * 1024) throw new Error('工程需包含 1–64 个文本文件，合计最多 16 MiB。');
    const virtual = Object.create(null);
    for (const file of files) { const name = file.webkitRelativePath.split('/').slice(1).join('/'); virtual[name] = new TextDecoder('utf-8', {fatal: true, ignoreBOM: true}).decode(await file.arrayBuffer()); }
    await setProject(virtual, Object.keys(virtual).sort()[0]);
  });
  $('project-demo').onclick = guard(() => setProject({
    'main.vdf': '// Moon Harbor · 工程入口\n#base "config/defaults.vdf"\n#include "config/extra.vdf"\nroot\n{\n  name "Moon Harbor"\n  platform windows [$WIN32]\n  platform linux [$LINUX]\n}\n',
    'config/defaults.vdf': '// 默认设置\nroot\n{\n  name "Default Name"\n  quality high\n  resources { path "materials/moon" }\n}\n',
    'config/extra.vdf': '// 附加条目\nextra { tag controller tag singleplayer }\n'
  }, 'main.vdf'));
  function checkOriginsFresh() {
    const files = api.files();
    if (!analyzedFiles || analyzedOptions!==analysisOptions() || Object.keys(files).length !== Object.keys(analyzedFiles).length || Object.keys(files).some(name => files[name] !== analyzedFiles[name])) throw new Error('工程内容或分析选项已变化，请重新分析后再使用来源定位。');
  }
  function analysisOptions(){return JSON.stringify({source:$('project-entry').value,symbols:$('project-symbols').value,literal:api.options().literal});}
  function renderProject() {
    if (!project) return;
    const query = $('project-filter').value.toLowerCase(); $('project-origins').replaceChildren();
    const rows = project.origins.filter(origin => (origin.path.map(p => p.key).join('/') + ' ' + origin.location.source).toLowerCase().includes(query));
    $('project-state').textContent = `${project.origins.length} 个展开字段 · ${project.references.length} 条引用 · ${rows.length} 项匹配`;
    for (const origin of rows.slice(0, 2500)) {
      const location = origin.location;
      const item = button(`${origin.path.map(p => `${p.key}[${p.occurrence}]`).join(' / ')} ← ${location.source}:${location.line}:${location.column}`, async () => { checkOriginsFresh(); await jump(location.source, location.offset); });
      $('project-origins').append(item);
    }
    if (rows.length > 2500) { const note = document.createElement('p'); note.textContent = '当前显示前 2500 项，可搜索缩小范围。'; $('project-origins').append(note); }
  }
  $('project-filter').oninput = renderProject;
  $('project-resolve').onclick = guard(async () => {
    const files = api.files(), source = $('project-entry').value;
    const signature = analysisOptions();
    const symbols = $('project-symbols').value.split(/[\s,]+/).filter(Boolean);
    const result = await api.core({action: 'project', source, files, symbols, ...api.options()});
    project = result; analyzedFiles = files; analyzedOptions=signature; renderProject(); $('project-graph').replaceChildren();
    for (const edge of result.references) {
      const row = document.createElement('div'); row.className = 'reference-edge';
      const arrow = document.createElement('span'); arrow.textContent = ` ─ ${edge.kind} → `;
      row.append(button(edge.source + ':' + edge.location.line, async () => { checkOriginsFresh(); await jump(edge.source, edge.location.offset); }), arrow, button(edge.target, async () => { checkOriginsFresh(); await jump(edge.target, 0); }));
      $('project-graph').append(row);
    }
    if (!result.references.length) $('project-graph').textContent = '此入口没有生效的文件引用。';
    api.status('工程分析完成；点击字段可定位到原文件。');
  });
  $('project-export').onclick = guard(() => {
    const files = api.files(); if (!Object.keys(files).length) throw new Error('请先载入工程。');
    api.download(JSON.stringify({format: 'moonvalve-project-v1', source:$('project-entry').value, files}, null, 2), 'moonvalve-project.json', 'application/json');
    api.status('已导出含当前编辑内容的工程快照。');
  });
  api.subscribe(() => { if (panel === 'shortcuts') guard(refreshShortcuts)(); });
  return {show, renderFiles};
}

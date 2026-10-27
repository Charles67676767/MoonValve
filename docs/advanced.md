# 查询、结构编辑、KV3 与语言服务

## 查询与快照批量编辑

`Document::select` / `compile_query` 返回携带 `Array[Selector]` 的有序结果。路径 `/root/tag` 选择所有同名项，`/root[0]/tag[1]` 指定从 0 开始的出现次序；`*` 匹配一层，`**` 匹配零层或多层，`$` 选择整个根对象。

可追加一个过滤器：`/**/path?^="materials/"` 前缀、`?*="moon"` 包含、`?$=".vmat"` 后缀、`?=="text"` / `?!="text"` 文本相等或不等、`?kind=text` / `?kind=object` 类型，以及 `?>=10` 等有限数字比较。文本参数采用 JSON 字符串。键名中的 `~ / * [ ] ?` 分别转义为 `~0 ~1 ~2 ~3 ~4 ~5`。表达式最多 4096 字符、128 个路径步骤；默认最多 10000 个结果和 100 万次条目访问。查询状态按路径步骤推进，连续递归通配不会重复返回同一位置。

`query_plan` 生成针对原文快照的修改，必须交给 `apply_snapshot`。`edit_query` 完成选择、规划和源文档修改，操作 JSON 为：

```json
{"op":"replace-prefix","from":"materials/","to":"assets/"}
```

另有 `{"op":"replace","value":"new"}`、`{"op":"rename","value":"new-key"}` 和 `{"op":"remove"}`。对象不能进行文本替换。快照计划最多 10000 项，支持 replace/rename/remove，拒绝重复目标、祖先与后代同时修改和根对象修改。相邻重复项同时删除仍按原始次序定位。

原来的 `apply` 保持顺序事务语义：后一步路径基于前一步结果。互不重叠的多项替换自动使用一次树扫描与一次源文档重建；其余操作保持顺序执行。`apply_snapshot` 与 `apply` 的定位含义不同，不能混用删除或重命名计划。

```sh
moon run cmd/main --target native -- select fixtures/duplicates.vdf '/**/tag'
moon run cmd/main --target native -- query-edit fixtures/duplicates.vdf '/**/tag' fixtures/query-edit.json
moon run cmd/main --target native -- edit-snapshot input.vdf changes.json --dry-run
```

选择原文中的条目时保留所有条件分支；需要求值的只读查询可显式使用 `--condition` / `--resolve`，源编辑拒绝这些选项。

## 移动与复制

`Document::transfer` / `SourceDocument::transfer` 支持跨对象移动或复制，`transfer_json` 接受：

```json
{"from":[{"key":"root","occurrence":0},{"key":"tag","occurrence":1}],"to":[{"key":"root","occurrence":0}],"index":0,"copy":true}
```

`to` 为目标对象路径，空数组表示文档根；`index` 是删除前原目标数组的插入边界。禁止把条目转移到自身或后代中，目标必须为对象，索引必须有效。源编辑带走连续前置行注释和同一行尾注，文档开头说明保持原位；只调整字符串外的行缩进，保留多行字符串内容、条件、引用、BOM 与换行风格。结果重解析并核对结构后才返回，失败时原对象不变。

CLI：`moonvalve transfer input.vdf plan.json [--dry-run|--in-place]`。工作台在“查询与批量修改 / 移动复制”中操作，统一预览后应用，支持撤销与副本下载。

## 文本 KV3

`parse_kv3` / `stringify_kv3` 使用独立的 `KV3Document` / `KV3Value`，支持文本头、对象、原生数组、布尔、空值、64 位整数、浮点（含 nan/inf）、Unicode 字符串、多行字符串、行/块注释、十六进制 blob 和资源标记。整数用十进制字符串保留完整精度；允许 Int64 负数与 UInt64 正数范围。格式标记支持 resource、resource_name、panorama、soundevent、subclass、entity_name、localize。默认要求文本编码头，可显式 `allow_headerless=true`。重复对象键被拒绝；不支持二进制 KV3，不将 KV3 默认为 KV1。

规范化写出不保留注释、引号样式或原始排版。KV3 字符串转义遵循 KV3 行为，不等同于 JSON 转义。`kv3_to_json` / `kv3_from_json` 使用显式类型模型，整数及浮点值为字符串，blob 为十六进制，object 为有序键值数组，flag 保留标记和被标记值。解析与写出均有资源限制，默认 8M 字符、10 万节点、128 层、1M token/blob 字节。KV1 的条件求值和字面路径模式不适用于 KV3。

```sh
moonvalve kv3-parse fixtures/sample.kv3
moonvalve kv3-format fixtures/sample.kv3
moonvalve kv3-from-json typed-model.json
```

工作台“KV3 文本”支持打开、解析、类型 JSON 编辑、规范化预览、撤销和下载。转换前可查看完整结果。

### 保留原文的 KV3 局部编辑

`parse_kv3_preserving(text, options?, allow_headerless?)` 返回 `KV3SourceDocument`，提供 `text()` / `document()` / `edit(path, operation)` / `apply_json(plan)`。路径是字符串数组：对象按键、数组按从 0 开始的十进制下标（如 `["resources","0"]`），空数组选择根。标记对路径遍历透明；替换标记值本身也会替换其标记。

操作为 `KV3Replace(value)`、`KV3Rename(key)`、`KV3Remove`、`KV3InsertField(index,key,value)`、`KV3InsertElement(index,value)`。插入路径选择父容器，位置为当前容器的插入边界。不能删除或重命名根，不能给数组元素命名，拒绝不存在的路径、重复字段和越界索引。JSON 事务至多 1000 步，后一步地址基于前一步结果：

```json
[
  {"op":"replace","path":["name"],"value":{"type":"string","value":"Moon Harbor"}},
  {"op":"insert-element","path":["resources"],"index":0,"value":{"type":"string","value":"materials/moon.vmat"}}
]
```

其他 JSON 操作为 `{"op":"remove","path":["name"]}`、`{"op":"rename","path":["name"],"key":"title"}`、`{"op":"insert-field","path":[],"index":0,"key":"enabled","value":{"type":"bool","value":true}}`。类型值沿用上文类型 JSON。

```sh
moonvalve kv3-edit fixtures/sample.kv3 fixtures/kv3-edit.json --dry-run
moonvalve kv3-edit input.kv3 plan.json --in-place
```

只替换选中 token；数组增删单独调整必需的逗号，保留间隙注释。新增文本使用引号和规范值写法；替换整个容器会重写该容器内部。删除字段时保留周围注释，不推断其归属。每步重新解析并核对预期结构，预算继续生效；失败不返回部分事务。CLI 原位保存仍创建独占备份。工作台“KV3 → 保留原文的局部编辑”提供表单、差异预览、撤销和下载；原有规范化与整体 JSON 导入保留原行为。

## 多文件重构

`new_workspace` 接受 1–64 个相对路径文本，合计最多 16M 字符，每份文档另有解析预算。重命名更新所有根级 include/base 引用（含未生效条件），跨目录移动重新计算文件自身的相对引用；复制只重算新副本的向外引用，其他文件仍引用原件。新增拒绝覆盖，删除拒绝仍被任一条件分支引用的文件，工程至少保留一个文件。

`Workspace::apply` 接受最多 1000 项顺序操作，全部成功才返回新工程：

```json
[{"op":"rename","from":"config/base.vdf","to":"defaults.vdf"}]
```

其他操作为 `{"op":"copy","from":"a","to":"b"}`、`{"op":"add","name":"a","text":"root {}"}`、`{"op":"remove","name":"a"}`。`edit_workspace_snapshot` 更新 `moonvalve-project-v1` 快照及入口路径。

CLI `workspace-edit project.json plan.json` 输出快照；`--in-place` 保存单份快照并创建备份。工作台提供预览、应用、工程撤销和快照导出。这里的事务针对内存工程 / 单份快照，不宣称能原子替换整个磁盘目录。

### 工程字段查询和批量修改

`Workspace::select(expression, files?=[])` 返回按文件名、字段原位置排序的 `{file,matches}` 数组；`Workspace::edit_query(expression, operation, files?=[])` 返回全新的工程。空文件列表表示全部文件，显式列表拒绝重复和不存在的文件。查询覆盖未经求值的全部条件分支，仍按重复项 occurrence 定位；它不把继承后的同一字段重复写回多个文件。总匹配数最多 10000。选中任何不适用的值或祖先与后代重叠修改，整次失败。

工程操作 JSON 可与文件操作顺序组合：

```json
[{"op":"query","expression":"/**/path?^=\"old/\"","files":[],"operation":{"op":"replace-prefix","from":"old/","to":"new/"}}]
```

```sh
moonvalve workspace-query fixtures/workspace-fields.json '/**/path'
moonvalve workspace-edit fixtures/workspace-fields.json fixtures/workspace-query.json --dry-run
```

`workspace-query` 的可选第三个参数是选定文件名数组的 JSON 文件。`query_workspace_snapshot` 提供同样的库入口。工作台“工程 → 工程字段查询与批量修改”显示文件、路径、值，点击结果定位原文；预览确认后统一应用，可撤销并导出包含所有文件的新快照。源文件或解析选项变化会使预览失效。磁盘目录不做部分覆盖。

## LSP 与 VS Code

`moonvalve lsp` 通过标准输入输出传输 JSON-RPC Content-Length 帧，可与其他 LSP 客户端连接。实现初始化、关闭、UTF-16 增量修改、版本过期保护、诊断、KV1 文档符号、折叠、文件指令定义跳转、文档链接、补全、纯文本悬浮和格式化。文本 KV3 提供诊断与格式化，其他导航能力当前针对 KV1。包含条件或文件指令的 KV1 拒绝格式化，避免静默丢失语义。

服务只访问客户端提供的文档；引用缓存使用 `moonvalve/setFile {uri,text}` / `moonvalve/removeFile {uri}`，不隐式扫描磁盘。打开后的未保存文档优先于缓存。最多 64 份文档、合计 16M 字符，单文件 8M 字符；帧头最多 4096 字节、帧体最多 16 MiB。符号和折叠结果各最多 5000 项。格式化使用两空格规范输出。

VS Code 扩展与安装说明见 [extensions/vscode](../extensions/vscode/README.md)。扩展为接口适配层，所有格式处理和语言功能来自 MoonBit；运行时不依赖 npm 包。自动化验证使用模拟 VS Code API 主机连接真实语言服务器，另有 JS/原生子进程交互测试；另有 `scripts/test-vscode.cjs` 在真实 VS Code 中将 VSIX 安装到独立配置，验证 16 项语言交互；该测试使用真实编辑器提供器命令，不以模拟 API 代替主机，也不宣称覆盖每个菜单。

### 跨文件诊断与重命名协议

支持标准 `workspace/willRenameFiles`，返回携带打开文档版本的 `documentChanges`，不更改服务器文本；客户端应用编辑并完成移动后发送 `workspace/didRenameFiles`。文件及目录移动均按原位置解析目标、按新位置计算相对路径；同时更新全部条件分支的传入引用与被移动文件的传出引用。拒绝缓存内目标冲突、嵌套重叠或链式重命名批次；批次最多 64 项。文件中存在无法解析的引用指令时拒绝生成可能不完整的引用编辑。服务器仅处理客户端提供的文件；VS Code 工作区超出缓存限制或无法完整载入时会提示引用更新未完成，重命名本身仍由编辑器管理。

`moonvalve/referenceTargets {}` 返回缓存内已解析文件的规范化目标 URI；宿主确认目标确实不存在后发送 `moonvalve/setMissingFiles {uris:[...]}`（至多 10000 项）。服务器不将未缓存文件认定为缺失。VS Code 仅在当前工作区内通过 `workspace.fs.stat` 确认 `FileNotFound`，权限失败不当作不存在，不自动读取目标内容。缺失诊断为警告，循环诊断为错误；均附引用链及关联位置，最多 128 条/文档。引用图至多 10000 条边，单次诊断遍历至多 10000 步；循环检查覆盖所有已载入的条件分支。文件修改、关闭、缓存变动及重命名会刷新打开文档的相关诊断。缓存外文件内容不参与循环分析。

VS Code 使用官方 [文件重命名事件](https://code.visualstudio.com/api/references/vscode-api#workspace.onWillRenameFiles) 交回引用编辑，支持编辑器的应用与撤销。扩展运行时仍无第三方 npm 依赖。

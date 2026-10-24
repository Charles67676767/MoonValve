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

## 多文件重构

`new_workspace` 接受 1–64 个相对路径文本，合计最多 16M 字符，每份文档另有解析预算。重命名更新所有根级 include/base 引用（含未生效条件），跨目录移动重新计算文件自身的相对引用；复制只重算新副本的向外引用，其他文件仍引用原件。新增拒绝覆盖，删除拒绝仍被任一条件分支引用的文件，工程至少保留一个文件。

`Workspace::apply` 接受最多 1000 项顺序操作，全部成功才返回新工程：

```json
[{"op":"rename","from":"config/base.vdf","to":"defaults.vdf"}]
```

其他操作为 `{"op":"copy","from":"a","to":"b"}`、`{"op":"add","name":"a","text":"root {}"}`、`{"op":"remove","name":"a"}`。`edit_workspace_snapshot` 更新 `moonvalve-project-v1` 快照及入口路径。

CLI `workspace-edit project.json plan.json` 输出快照；`--in-place` 保存单份快照并创建备份。工作台提供预览、应用、工程撤销和快照导出。这里的事务针对内存工程 / 单份快照，不宣称能原子替换整个磁盘目录。

## LSP 与 VS Code

`moonvalve lsp` 通过标准输入输出传输 JSON-RPC Content-Length 帧，可与其他 LSP 客户端连接。实现初始化、关闭、UTF-16 增量修改、版本过期保护、诊断、KV1 文档符号、折叠、文件指令定义跳转、文档链接、补全、纯文本悬浮和格式化。文本 KV3 提供诊断与格式化，其他导航能力当前针对 KV1。包含条件或文件指令的 KV1 拒绝格式化，避免静默丢失语义。

服务只访问客户端提供的文档；引用缓存使用 `moonvalve/setFile {uri,text}` / `moonvalve/removeFile {uri}`，不隐式扫描磁盘。打开后的未保存文档优先于缓存。最多 64 份文档、合计 16M 字符，单文件 8M 字符；帧头最多 4096 字节、帧体最多 16 MiB。符号和折叠结果各最多 5000 项。格式化使用两空格规范输出。

VS Code 扩展与安装说明见 [extensions/vscode](../extensions/vscode/README.md)。扩展为接口适配层，所有格式处理和语言功能来自 MoonBit；运行时不依赖 npm 包。自动化验证使用模拟 VS Code API 主机连接真实语言服务器，另有 JS/原生子进程交互测试；尚未以完整 VS Code GUI 自动化覆盖所有菜单操作。

# 混合工程、保留注释格式化与资源导航

0.7.0 将文本 KV3 接入工程编辑，同时提供只调整空白的格式化与显式资源映射。核心仍由 MoonBit 实现，无新增运行依赖。二进制 KV3 不在本版本范围内。

## 在同一工程管理 KV1 与 KV3

`new_workspace` / `workspace_from_json` 接受混合文件。`.kv3` 文件或带文本 KV3 头的内容按 KV3 解析，其余按 KV1 解析；工程中的 KV3 必须包含有效头部。现有 1–64 文件、合计 16M Unicode 字符预算不变。

旧 `Workspace::select` / `edit_query` 和 `workspace-query` 只处理 KV1；新增 `Workspace::select_kv3` / `edit_query_kv3`、`query_workspace_kv3_snapshot` 和 `workspace-kv3-query` 只处理 KV3。空文件列表表示该格式的全部文件；显式指定另一种格式的文件会报错，避免悄悄漏改。跨文件匹配合计不超过 10000 项。

```sh
moonvalve workspace-kv3-query fixtures/workspace-mixed.json '/**?flag=resource'
moonvalve workspace-edit fixtures/workspace-mixed.json fixtures/workspace-kv3-plan.json --dry-run
moonvalve workspace-edit fixtures/workspace-mixed.json fixtures/workspace-kv3-plan.json > edited-project.json
moonvalve workspace-export edited-project.json new-project
```

工程计划的新操作：

```json
[{"op":"kv3-query","expression":"/**?flag=resource","files":[],"operation":{"op":"replace-prefix","from":"old/","to":"new/"}}]
```

KV3 替换使用类型 JSON，重命名使用 `key`；其他规则与单文件类型查询相同。所有文件以修改前快照定位，任一失败不返回部分结果。文件移动、复制、新建、删除可以与查询顺序组合；KV1 的 include/base 重写继续只用于 KV1。KV3 没有被赋予 include/base 语义。工程快照、撤销、目录和 ZIP 导出同时保留两种格式。

工作台“多文件工程”可载入 `.vdf/.acf/.res/.txt/.kv/.kv3`，在查询格式下拉框选择 KV1 或 KV3。KV3 结果跳转到类型树；手工编辑、预览应用和 KV3 撤销均同步到工程草稿。工程撤销或恢复会同步已打开的 KV3 面板。来源展开分析仍为 KV1 专用。

## 格式化时保留注释和原始字面值

```sh
moonvalve format-preserving config.vdf --dry-run
moonvalve format-preserving config.vdf --in-place
moonvalve kv3-format-preserving source.kv3 --in-place
moonvalve kv3-format-preserving headerless.txt --headerless
```

库接口为 `SourceDocument::format_preserving` 与 `KV3SourceDocument::format_preserving`。它们返回新的源文档，重新解析并核对数据结构。

- 只调整语法之间的空格、缩进与换行，使用两空格缩进，沿用 CRLF、CR 或 LF；保留至多一个空白分隔行，并以换行结束非空文档。
- 键名和值的 token、字符串内容、注释正文、BOM、KV3 头部、数字原始写法、资源标记、重复项及其顺序保持不变。
- KV1 的全部条件分支和 include/base 指令保持原样，无需选择条件符号或展开引用。字面反斜杠模式通过 `--literal` 显式选择。
- KV3 多行字符串、blob 和带标记的标量视为完整原文字面值，不修改内部空白。块注释内部也不重排。
- 连续格式化两次结果相同。畸形输入拒绝格式化；原位保存沿用独占备份与单文件保存机制。

原 `format` / `kv3-format` 仍提供原来的规范化写出。工作台新增“保留注释格式化”并沿用预览、撤销；VS Code 的格式化现使用保留注释的实现，可以处理带条件和文件指令的 KV1。

## 显式资源目录映射

只把 `resource:"path"` 识别为文件引用。`resource_name`、`soundevent`、`localize`、`entity_name` 等名称没有被当作磁盘路径。空资源值表示未指定资源，不作缺失警告。路径中的上级跳转、绝对路径、反斜杠和控制字符被拒绝。

命令行根目录配置示例：

```json
[{"prefix":"","directory":"content"},{"prefix":"materials/","directory":"source-materials"}]
```

匹配最长前缀；同前缀不允许配置两次。非空前缀必须为以 `/` 结束的相对目录。目录可为显式的规范化路径，`.` 表示相对根。最多 32 个映射、每文档最多 10000 个资源引用。

```sh
moonvalve kv3-resources fixtures/sample.kv3 fixtures/resource-roots.json
moonvalve kv3-resource-edit fixtures/sample.kv3 fixtures/resource-roots.json fixtures/resource-moves.json --dry-run
```

`kv3-resources` 返回字段路径、原资源字符串、映射目标及 Unicode 标量范围。核心与 CLI 的 `resolved` 仅表示路径已映射，不代表磁盘文件存在；未配置、未匹配、空值与非法路径分别报告为 `unconfigured`、`unmapped`、`empty`、`invalid`。

`KV3SourceDocument::resources` / `resource_references_to_json` 提供同样的库入口；`resource_roots_from_json` 读取配置。`rewrite_resources(roots, moves)` 接受目标路径移动映射，如 `{"content/materials":"content/new-materials"}`，预览文件或目录移动需要的配置修改。它保留资源标记、无关注释及数字精度，不移动资源文件本身。重叠或链式移动计划被拒绝；若实际引用的新目标落在映射目录外，整次失败。无需修改的文档原样返回。

## VS Code 中使用资源导航

在设置中添加：

```json
{"moonvalve.resourceRoots":[{"prefix":"","directory":"content"}]}
```

`directory` 相对于第一个工作区文件夹，只允许该工作区内的相对目录；`.` 表示该文件夹。多根工作区也采用第一个文件夹作为这组配置的基准。设置可实时更新。扩展不搜索 Steam 安装目录，不扫描未配置目录，不自动读取资源文件内容。

扩展根据配置对引用目标调用文件系统状态检查：普通文件为 `present`，确认不存在为 `missing`，权限失败、目录或无法检查为 `unavailable`。未检查为 `unchecked`。只有 `missing` 产生缺失警告，只有 `present` 提供定义跳转和文档链接。悬浮显示映射与检查状态；命令面板的 **MoonValve: Browse Resource References** 列出当前已载入配置的引用位置，可以返回使用处。

在 VS Code 移动资源文件或目录时，标准 `workspace/willRenameFiles` 返回配置编辑，保留打开文档版本，随后由编辑器完成实际移动。支持未保存的 KV3 文档，只修改 `resource:` 文件引用。移动配置过的资源根本身需先更新设置；目标移出映射、存在畸形 KV3 或工程缓存不完整时提示引用更新未完成，不声称全工程已更新。

资源引用范围为已打开或缓存的配置，延续最多 64 文件、合计 16M 字符的 LSP 预算。全部资源报告最多 10000 项，单文件诊断最多 128 项。超限时应缩小工作区；磁盘上未载入的配置不在自动重写范围内。

自定义 LSP 协议：`moonvalve/setResourceRoots {roots:[{prefix,uri}]}`、`moonvalve/resourceTargets {}`、`moonvalve/resourceReferences {}`、`moonvalve/setResourceStates {states:[{uri,status}]}`。根 URI 由宿主明确提供；检查状态由宿主报告，MoonBit 核心本身不访问文件系统。改变根配置和完成文件移动会清空旧检查状态。

# 库 API 导览

完整签名见仓库根目录 `pkg.generated.mbti`。所有核心 API 可用于 wasm、wasm-gc、js、native，不自行读取文件。可运行示例在 examples/，独立模块示例在 integration/consumer/。

## 文本、查询与类型读取

- `parse`、`stringify`：有序文档与规范化文本双向转换。
- `get`、`get_all`、`lookup`：首个顶层项、全部顶层同名项、每层选择首项的路径查询。
- `lookup_at(Array[Selector])`：以键和 occurrence 精确定位，找不到或跨越标量时返回包含完整请求路径的 `AccessError`。
- `lookup_all(Array[String])`：每层遍历全部同名项，保持原始顺序。
- `walk(visitor)`：前序遍历，回调返回 false 跳过对象子树，路径为独立快照；`find(key)` 返回带完整重复项路径的结果。
- `read_text`、`read_int64`、`read_bool`、`read_double`：严格读取。Int64 要求十进制格式并检查溢出；Bool 接受 true/false/1/0；Double 拒绝非有限值。错误携带原请求路径。
- `to_json`、`document_from_json`、`parse_json_document`：使用有序 `{key,value}` 数组，不折叠重复键。

## 编辑与原文模型

`Document::edit` 支持 Replace、Remove、Rename、Insert；`Document::apply(Array[Change])` 按顺序执行事务，最终验证文本与资源限制。它们不修改输入数组；返回的模型仍是普通 MoonBit 数据，调用方自行直接修改共享数组不属于编辑事务。

`parse_preserving` 得到不暴露内部源位置数据的 `SourceDocument`。`document()` 提供**未经条件过滤、未经引用展开**的原文语义视图，全部同名项均保留；`text()` 返回原文。`edit` 和 `apply` 修改后重新解析，保留改动范围之外的字符。

源模型支持转义模式或字面模式，但不接受 conditions=Some；使用 `evaluate(symbols)` 可另得条件求值结果，遇到根级引用时仍需显式加载器。键/标量替换尽量保留原引号方式；插入沿用相邻键的引号、换行与缩进。删除会移除该条目的尾随条件，保留周围注释。替换整个对象会重写对象内部内容。

`changes_from_json` 导入与 CLI 共用的编辑计划，格式见 commands.md。路径选择前一步操作的结果，不是最初文档。单次事务最多 10000 项，选择路径最多 128 层。字面模式无法表示的引号值会明确拒绝。

## 条件与文件引用

`ParseOptions.conditions=None` 默认拒绝条件；Some(symbols) 显式求值。`evaluate_condition` 支持变量、逻辑运算和括号。`load_resolved(source,loader)` 使用用户回调展开 include/base，处理相对路径、循环与累计预算；它不为回调授予磁盘访问权限。扩展说明列出具体语义。

## 二进制与 Steam 数据

- `encode_binary` / `decode_binary`：有序 `BinaryEntry` 模型，支持标准 KV1 类型；可显式提供 `string_table=Some([...])` 读写键索引，表内键须唯一，编码不自动增加表项。
- `binary_to_json` / `binary_from_json`：有序 `{key,type,value}`，数字是字符串，Float32 使用原始位，不丢失 64 位精度或 NaN 载荷。
- `read_app_manifest` / `read_library_folders`：Steam 清单与库目录，`select_inventory` / `inventory_total` / `check_inventory` / `inventory_csv` 提供盘点分析。
- `open_steam_cache`：支持 appinfo 39/40/41、packageinfo 39/40。`records()` 返回元数据；`read(id)` 使用索引定位并解码目标，不存在返回 None；`format/version/universe` 提供头部信息。AppInfo 建索引时检查边界、头部和字符串表，目标数据延迟验证；PackageInfo 为定位记录边界需要解析各树。
- `SteamCache::page(query="", offset=0, limit=100)`：按十进制 ID 子串过滤元数据，返回匹配总数与当前页；每页 1–200 条，偏移非负。不会为搜索解码记录正文。
- `new_shortcut_file` / `read_shortcut_file`：读写快捷方式模型。`shortcuts` 返回建模字段；`add/set/remove` 返回新文件，保留未知字段；`to_binary` 交给二进制编码器。`set` 保留传入 App ID，允许调用方决定是否重新计算；`shortcut_app_id` 与 `SteamShortcut::url` 提供计算辅助。

缓存输入默认上限 512 MiB、最多 1000000 条记录。标准二进制默认上限 16 MiB、100000 条条目、128 层、单字符串 1 MiB；缓存索引使用独立的更大累计条目预算。未知缓存版本拒绝解析。

## 分块事件解析

`new_stream_parser(visitor)` 提供 `feed(String)` 或 `feed_bytes(Bytes)`，最后调用 `finish()`。两种输入方式不能混用。字节方式严格增量解码 UTF-8，跨块最多保留 3 个不完整字节；token、字符、深度和条目预算跨块累计。

事件为 Pair、BeginObject、EndObject、Condition。BeginObject 回调返回 false 可停止交付其后代事件，但语法和预算仍检查，匹配的 EndObject 仍交付。事件是原文视图：条件只验证并交付、不求值；根级指令作为普通 Pair 交付，不进行文件读取。它与需要回看对象尾部条件的文档求值是不同接口。

解析器自身保留当前 token、对象栈与不完整 UTF-8 字节，不构建文档树；调用方可以流式处理或自行累积事件。错误或 finish 后不可继续 feed。`entries_seen/characters_seen` 提供累计计数；百万条目示例见 examples/streaming。

`new_stream_writer(sink)` 返回事件写出器，`write(event)` 逐条交付规范化文本到调用方 sink，`finish()` 检查对象是否闭合。sink 可抛错，失败后不能继续使用写出器。最大对象深度 128；拒绝条件和根级引用，避免把尚未求值的数据误写成普通配置。详细文件命令与部分输出约定见 [流式处理](streaming.md)。

## 工程与来源

`load_project(source, loader, options?, max_files?)` 使用与 `load_resolved` 相同的条件、引用、预算和合并语义，返回 `ResolvedProject`，包含最终 `document`、逐字段 `origins` 和生效的 `references`。来源路径为区分大小写且感知重复项的 `Array[Selector]`；位置包含原虚拟文件名、从 0 开始的 Unicode 标量偏移，以及从 1 开始的行列号，定位原文件中的键开头。原文件编辑后应重新分析。

本地对象保留本地键位置，继承的子字段指向默认文件；include 追加条目保留被引用文件的位置。被过滤条件分支不产生最终来源。`SourceDocument::locations(source)` 则返回未经条件过滤的原文位置。`ResolvedProject::to_json()` 提供有序树、来源与引用边的便携表达。见 [工程说明](projects.md)。

## 安装与版本

`version()` 返回开发版本；CLI 和发行包构建会核对其与 moon.mod 一致。从 Mooncakes 安装使用普通版本依赖；integration/consumer 的 moon.work 方式另供源码开发。核心库无 Python/.NET 运行依赖。

查询、快照批量编辑、移动复制、文本 KV3、多文件重构与 LSP 的用法、JSON 格式和边界见 [进阶功能](advanced.md)。

0.5.x 与前一系列的公开接口兼容规则与自动基线检查见 [API 稳定性](api-stability.md)，已发布版本的独立接入验证见 [发布与安装](publishing.md)。

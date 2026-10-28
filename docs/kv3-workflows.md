# 工程导出与 KV3 类型工作流

## 把工程快照导回可使用的文件

工作台“多文件工程 → 下载工程 ZIP”会导出快照当前包含的全部文件，保留相对路径、原始注释、BOM 与换行。ZIP 使用标准 ZIP32、UTF-8 文件名、CRC32 校验和不压缩条目，可用系统解压工具或 Python `zipfile` 打开。生成工作由 MoonBit 核心完成。

```sh
moonvalve workspace-export fixtures/workspace-fields.json new-project
moonvalve workspace-zip fixtures/workspace-fields.json project.zip
```

输出目录或 ZIP 文件必须不存在，父目录必须存在；已有文件、目录、符号链接或 Windows 目录联接不会被覆盖。省略 ZIP 文件名则输出原始 ZIP 字节到标准输出；Windows 用户优先使用显式输出文件名，以免旧版 shell 的文本重定向转换二进制内容。

库接口为 `project_export_files(snapshot, options?)` 与 `export_project_zip(snapshot, options?)`。先核对入口、全部文本、路径与冲突，再创建输出；KV1 原文支持条件和引用，`.kv3` 或带 KV3 头的文本按 KV3 验证。只导出快照明确包含的文件，不额外扫描、复制游戏资源或整个磁盘目录。

每个快照 1–64 份文件、总 UTF-8 内容最多 64 MiB，单份文档仍遵守解析预算。相对路径最多 64 段、4096 UTF-8 字节，单段最多 255 UTF-8 字节；拒绝上级目录、绝对路径、Windows 设备名、大小写冲突以及文件与目录同名冲突。文件间的引用无需全部解析成功才能导出，但缺失的外部资源不会自动补入 ZIP。

目录导出采用独占新建并在失败时回收本次创建的文件和目录；它不是对已有工程的多文件原子替换。进程中断可能留下不完整的新目录，应检查或重新选择一个新输出路径。

## KV3 类型查询

```sh
moonvalve kv3-select fixtures/sample.kv3 '/**?type=integer&>9007199254740993'
moonvalve kv3-query-edit fixtures/sample.kv3 '/**?flag=resource&^="materials/"' fixtures/kv3-query-prefix.json --dry-run
```

库接口：`compile_kv3_query(expression).select(document)`、`KV3Document::select(expression)`、`KV3SourceDocument::edit_query(expression, operation)`。结果包含字符串数组路径和原生 `KV3Value`；`kv3_located_values_to_json` 输出携带类型的值，不转换整数为 JSON 浮点数。

路径沿用 KV1 查询的转义与 `*` / `**`，数组使用 `/0`、`/1`，不使用 KV1 重复键的 `[occurrence]`。例如 `/resources/0`、`/**/path`，`$` 选择根节点。`/**` 选择根下面的节点，不包含根本身。标记对路径遍历透明，结果仍保留标记。

| 过滤方式 | 示例 |
|---|---|
| 底层类型 | `?type=integer`、`?type=array` |
| 标记 | `?flag=resource`、`?flag=none` |
| 字符串前缀/包含/后缀 | `?^="materials/"`、`?*="moon"`、`?$=".vmat"` |
| 类型严格的标量相等/不等 | `?==true`、`?==null`、`?==18446744073709551615` |
| 有限数值比较 | `?>=9007199254740993`、`?<1.5` |
| 组合条件 | `?type=string&flag=resource&^="materials/"` |

类型支持 null、bool、integer、float、string、blob、object、array。整数对整数作精确十进制比较，浮点对浮点作有限数值比较；不隐式把整数转为浮点，因此 `>=1` 与 `>=1.0` 匹配的数值类型不同。字符串 `"true"` 与布尔 `true` 不相同。字符串过滤只处理字符串值，不扫描注释。`&` 位于双引号字符串内时是普通字符。非有限浮点不参与有序比较。

表达式最多 4096 字符、128 步路径、8 个组合过滤条件；最多 10000 个结果、100 万次访问，输入的节点和深度预算继续生效。它是 MoonValve 的有界结构查询语法，不宣称完整实现 JSONPath。

## KV3 批量修改

`KV3QueryEdit` 包括：

- `KV3SetValue(value)`：替换完整选中值；若原值带标记，新值须显式携带所需标记。
- `KV3ReplacePrefix(from,to)`：修改字符串前缀，同时保留其资源等标记；不匹配前缀或选中非字符串时整次失败。
- `KV3RenameMatches(key)`：重命名对象字段，拒绝键冲突和数组元素命名。
- `KV3RemoveMatches`：删除字段或数组元素，按原快照定位并统一处理数组分隔逗号。

`kv3_query_edit_from_json` 接受 `replace`（类型 JSON `value`）、`replace-prefix`（`from` / `to`）、`rename`（`key`）、`remove` 操作。

所有匹配地址基于修改前的原文，拒绝祖先与后代重叠修改、根删除和根重命名。修改一次重建原文并重新解析、核对结构；失败不返回部分文档。无关注释、数值写法和换行保留。`--in-place` 继续采用原有独占备份与单文件保存机制。

## 树形工作台与编辑器导航

工作台打开 KV3 后可展开对象/数组、点击节点定位原文，并使用布尔控件或文本框修改值。整数与浮点作为字符串交给 MoonBit 验证，不经 JavaScript Number 转换。支持字段重命名、节点删除、批量查询结果定位、修改预览、应用与撤销；类型 JSON 导入保留在高级面板中。

树当前最多展示 5000 个展开节点，折叠分支或使用查询可缩小范围。源文件或头部选项改变后，旧树和旧预览失效，需要重新解析。

VS Code 的文本 KV3 现支持对象/数组大纲、折叠、显示类型与精确数值的悬浮，以及语法字面量/标记补全。大纲与折叠各有 5000 项预算。文件指令跳转与重命名引用维护继续针对 KV1；KV3 不自动推断游戏资源根目录或字段 schema。`KV3SourceDocument::range(path)` 返回 Unicode 标量偏移，可供宿主转换为 UTF-16 编辑器位置。

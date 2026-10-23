# 扩展 API

## 有序编辑

`Document::edit(path, operation)` 返回新文档，不修改原文档数组。路径元素为 `Selector { key, occurrence }`，同名键的 occurrence 从 0 开始。操作包括 `Replace(Value)`、`Remove`、`Rename(String)` 和向对象插入条目的 `Insert(index, Entry)`。

空路径选择文档根对象；根不能删除、重命名或替换成文本。不存在的键、负 occurrence、跨越文本的路径及越界插入均返回 `EditError`。插入按条目位置进行，不覆盖同名项。

## JSON 双向转换

`document_from_json` 和 `parse_json_document` 导入 `to_json` 输出的有序条目数组。值只能是字符串或下一层条目数组；缺失字段、额外字段和数值等不兼容类型会被拒绝。资源限制沿用 `ParseOptions`。JSON 文本本身使用标准 JSON 对象键语义；KV1 重复项通过条目数组表示。

CLI：`moon run cmd/main --target js -- from-json data.json`。输出为可重新解析的 KV1。

## 平台条件

`ParseOptions.conditions = Some(["WIN32"])` 开启显式条件求值；`None` 保持拒绝条件的严格模式。支持 `$NAME`、`!`、`&&`、`||` 和括号，未知变量为假，名称不区分 ASCII 大小写。条件可以出现在键之后、等号之后及值之后；同一条目的最后一个条件决定保留与否。等号后的条件匹配时替换先前同名项。被过滤的分支仍进行语法检查并计入资源预算。表达式最多 4096 字符、64 层。

## 文件引用

`load_resolved(source, loader, options?, max_files?)` 使用显式回调读取文件，核心库不自行访问文件系统。根级 `#include` 在本地条目之后按引用顺序追加；`#base` 递归补充缺失项，本地值优先，重复键按出现次数配对。对象内部同名指令键是普通数据。

引用路径相对当前文件，统一斜杠并折叠点段；不允许绝对引用及越过虚拟根。调用方仍需根据自身宿主限制实际文件访问范围。循环引用、文件数、累计输入字符和累计解析条目均受限；被条件过滤的语法条目也计入预算。

## 标准二进制 KV1

`encode_binary` / `decode_binary` 使用独立的有序 `BinaryEntry` / `BinaryValue` 模型，支持对象、UTF-8 字符串、Int32、Float32、32 位指针数据、UTF-16LE 字符串、RGBA 原始数据、UInt64 和 Int64。浮点以 `Float32Bits(UInt)` 保存全部原始位，包含负零和 NaN 载荷；指针字段仅作为数值处理。

使用小端数字与标准结束标记 8。解码严格检查完整终止、尾随数据及字符串编码；双向遵守深度、条目、字符串字节和总字节限制。可通过显式 string_table 参数读写外部键表；Steam 容器使用独立的 open_steam_cache API。VBKV 仍不支持。

## 保留原文的编辑

`parse_preserving` 返回 `SourceDocument`，通过 `text()` 读取原文、`document()` 读取语义模型。`SourceDocument::edit` 支持同一套 `Selector` 和 `Edit` 操作：精确替换值、重命名、删除与按位置插入。修改范围以外的字符保持原样，包括 BOM、中文、注释、CRLF 和缩进；每次编辑后重新解析并核对语义结果。

源模型保留未求值条件、根级引用与字面路径。插入条目沿用周围缩进、换行与键的引号风格；替换标量保留其引号方式。删除条目移除尾随条件并保留周围注释；替换整个对象会替换内部注释。evaluate 提供独立条件视图，apply 提供顺序事务。详见 [API 导览](api.md)。

## Steam 清单分析

`select_inventory` 按名称或 App ID 过滤，支持 `id`（十进制数值顺序）、`name`（忽略大小写）和 `size`（降序、未知值最后）排序。`inventory_total` 用 Int64 精确统计已知容量并报告未知容量数量，溢出报错。`check_inventory` 识别 App ID 与文件名不符、重复 App ID、重复库路径及声明中缺失的可读清单；路径比较为精确字符串比较。

CLI 示例：`inventory libraryfolders.vdf --filter portal --sort size --csv`。默认输出 JSON，包括筛选后汇总、扫描数量和全量异常；CSV 输出至标准输出、异常写入标准错误。包含异常时退出码为 1，致命错误为 2。CSV 字段按 RFC 4180 转义，原样保留内容，导入电子表格时应使用文本列类型。

## 原生命令行

`moon build --target native --release` 在 `_build/native/release/build/cmd/main/` 生成 `main.exe` 或 `main`，以工具链实际产物为准，运行时无需 Node。可用 `moon run cmd/main --target native --release -- help` 运行。命令和退出码与 JavaScript 版本一致。原生版本通过少量 C 宿主代码提供有界字节读取、标准输出和目录枚举；解析与业务逻辑均为 MoonBit。Windows 路径转换为 UTF-16 调用系统接口，文件内容严格按 UTF-8 解码。

构建需要 MoonBit 原生后端支持的 C 编译器。输入最多 16 MiB；目录枚举最多 100000 个普通文件和 16 MiB 文件名数据，不跟随清单文件符号链接。JavaScript 与原生版本共用同一套 CLI 验收脚本。

# 能力、限制与验证证据

此文件由 capabilities.json 生成；执行 node scripts/generate-capabilities.cjs 更新。

- **structure**：解析成功仅说明已识别结构符合本实现支持的子集。
- **integrity**：仅说明明确列出的校验项目通过，不代表签名或所有块均已验证。
- **interop**：固定参考工具与样本通过，不代表所有游戏版本兼容。
- **runtime**：须在具体目标程序加载验证；当前没有自动游戏运行验证。

## 资源与核心工具

### 二进制 KV3 / Source 2

- 读取：KV3 历史版0；现代1—5；资源容器 header12 的块表、KV3 DATA 与 RERL。
- 写出：独立 KV3 4/5，raw/LZ4/Zstandard；新建仅含 DATA 的资源容器。
- 保留承诺：未修改节点的数值存储位；容器布局与压缩字节会重新生成。
- 明确边界：不完整重写编译资源，不修复其他块或重定位表；不支持外部压缩字典。
- 回归入口：[kv3_binary_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/kv3_binary_test.mbt)、[resource_container_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/resource_container_test.mbt)、[scripts/check-binary-kv3.cjs](https://github.com/Charles67676767/MoonValve/blob/main/scripts/check-binary-kv3.cjs)

### VPK

- 读取：v1/v2 目录、preload、embedded/编号分卷，按条目读取与文件 CRC32。
- 写出：确定性 embedded 单文件 VPK v1。
- 保留承诺：成功提取的每个文件按原始字节保存并核对 CRC32。
- 明确边界：不验证 v2 MD5/数字签名；偏移与条目长度最多2147483647，超出时明确拒绝；浏览器提取合计16MiB，CLI64MiB。
- 回归入口：[vpk_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/vpk_test.mbt)、[scripts/test-assets-cli.cjs](https://github.com/Charles67676767/MoonValve/blob/main/scripts/test-assets-cli.cjs)、[scripts/check-assets.cjs](https://github.com/Charles67676767/MoonValve/blob/main/scripts/check-assets.cjs)

### 静态依赖闭包

- 读取：VMT 纹理/Patch、KV3 标记、RERL、KV1 include/base。
- 写出：目录、ZIP、VPK；默认阻止未解决引用并排除基础游戏文件。
- 保留承诺：导出所选文件的原始字节与相对路径。
- 明确边界：动态路径、未知格式及 BSP/MDL 内部引用不保证完整；导出成功不代表游戏可加载。
- 回归入口：[dependencies_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/dependencies_test.mbt)、[project_export_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/project_export_test.mbt)、[scripts/test-assets-cli.cjs](https://github.com/Charles67676767/MoonValve/blob/main/scripts/test-assets-cli.cjs)

### VMT

- 读取：递归 Patch include/insert/replace、参数来源与已知纹理参数。
- 写出：规范化材质副本和参数修改。
- 保留承诺：有序参数语义；不保留原材质注释与排版。
- 明确边界：不执行材质代理、不模拟渲染、不编译纹理；未知纹理参数由调用方配置。
- 回归入口：[vmt_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/vmt_test.mbt)、[scripts/check-assets.cjs](https://github.com/Charles67676767/MoonValve/blob/main/scripts/check-assets.cjs)

### 本地化 / PO

- 读取：UTF-8/BOM、UTF-16LE/BE BOM；PO 上下文/复数/fuzzy/废弃项。
- 写出：Valve 单数令牌与 PO/POT；问题未清除时不导出语言文件。
- 保留承诺：令牌身份、顺序和选择的编码；非原始字节等价。
- 明确边界：PO 复数不压成单数；printf 动态*宽度/精度需适配；不证明游戏中的字体或排版正确。
- 回归入口：[localization_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/localization_test.mbt)、[scripts/check-assets.cjs](https://github.com/Charles67676767/MoonValve/blob/main/scripts/check-assets.cjs)、[scripts/test-assets-cli.cjs](https://github.com/Charles67676767/MoonValve/blob/main/scripts/test-assets-cli.cjs)

### DMX / KeyValues2

- 读取：KeyValues2 1、binary4/5，支持的标量/同类型数组、UUID 共享/循环/外部引用。
- 写出：KeyValues2 1 和 binary4/5。
- 保留承诺：二进制数值位及 UUID 图身份；文本输出规范化 NaN payload。
- 明确边界：其他版本/扩展类型拒绝；不执行动画、不加载外部元素、不保证任意模型可被引擎使用。
- 回归入口：[dmx_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/dmx_test.mbt)、[scripts/check-assets.cjs](https://github.com/Charles67676767/MoonValve/blob/main/scripts/check-assets.cjs)

### KV1 文本与二进制

- 读取：有序重复键、显式转义模式；标准二进制0—7/10及结束标记8。
- 写出：规范化文本、保留原文局部编辑、标准二进制。
- 保留承诺：SourceDocument保留未改原文片段；普通stringify只保留结构/顺序，二进制模型保存数值位。
- 明确边界：不是VBKV/KV3；普通parse默认拒绝条件与根指令，加载/条件需显式选项或独立入口。
- 回归入口：[parser_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/parser_test.mbt)、[binary_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/binary_test.mbt)、[source_edit_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/source_edit_test.mbt)

### 文本 KV3

- 读取：独立类型树、标记、blob、64位整数；可显式允许无头文本。
- 写出：规范化或保留原文的编辑；混合工程显式选择文件。
- 保留承诺：保留模式维护未改文本；普通写出不保证原始数字写法/注释。
- 明确边界：不自动按文件扩展名猜测所有输入；文本NaN不保证原payload。
- 回归入口：[kv3_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/kv3_test.mbt)、[kv3_source_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/kv3_source_test.mbt)

### Steam 元数据

- 读取：appmanifest/libraryfolders/shortcuts；appinfo39/40/41、packageinfo39/40。
- 写出：已声明的清单/快捷方式编辑与副本输出；缓存索引/按需解码。
- 保留承诺：按相应文本/二进制模型保留；不承诺Steam运行时自动接受所有自定义元数据。
- 明确边界：不管理Steam进程、账号登录或下载；未知缓存版本拒绝，不提供任意缓存重建器。
- 回归入口：[steam_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/steam_test.mbt)、[cache_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/cache_test.mbt)、[shortcuts_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/shortcuts_test.mbt)

### 流式处理

- 读取：增量UTF-8事件与路径查询，跨分块语法验证。
- 写出：JSONL/CSV及支持子集的流式规范化，宿主处理背压。
- 保留承诺：原文事件与规范化输出为不同承诺；不把跳过交付视为跳过验证。
- 明确边界：不保证进程RSS恒定；流式规范化的条件/指令限制见streaming.md。
- 回归入口：[stream_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/stream_test.mbt)、[scripts/test-stream-pipe.cjs](https://github.com/Charles67676767/MoonValve/blob/main/scripts/test-stream-pipe.cjs)

### 编辑器服务

- 读取：已支持文本格式的诊断、导航、来源与UTF-16位置。
- 写出：明确编辑与引用重写，通过编辑器应用/撤销。
- 保留承诺：未保存版本与请求上下文必须匹配，不能用旧位置覆盖新文本。
- 明确边界：不是全功能IDE；不编译游戏资源，不自动猜测缺失挂载或任意动态引用。
- 回归入口：[lsp_test.mbt](https://github.com/Charles67676767/MoonValve/blob/main/lsp_test.mbt)、[scripts/test-lsp.cjs](https://github.com/Charles67676767/MoonValve/blob/main/scripts/test-lsp.cjs)、[scripts/test-vscode.cjs](https://github.com/Charles67676767/MoonValve/blob/main/scripts/test-vscode.cjs)

## KV3 版本与压缩组合

| 版本 | 可读 | 可写 |
|---|---|---|
| 0 (VKV3) | raw / LZ4 / Valve block compression | 不支持 |
| 1 | raw / LZ4 | 不支持 |
| 2/3 | raw / LZ4 / Zstandard | 不支持 |
| 4/5 | raw / LZ4 / Zstandard | raw / LZ4 / Zstandard |

## 资源限制

浏览器文件/目录合计16MiB、目录最多2048文件；CLI资源单项/批量默认64MiB，VPK目录16MiB。VPK偏移/条目长度上限2147483647。文本字符计量、其他库选项及条件语义见[KV1兼容说明](compatibility.md)与[资源指南](assets.md)。

这些上限不是压测结果；支持矩阵不等于每种组合都有真实生产文件回归，真实样本与生成样本应分开报告。

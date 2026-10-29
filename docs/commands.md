# 命令行工具

大文件的 `stream-json`、`stream-query`、`stream-csv`、`stream-format` 用法及部分输出约定见 [流式处理](streaming.md)。`project FILE --root DIR` 的字段来源与引用关系输出见 [多文件工程](projects.md)。

构建：`moon build --target native --release`，或 `moon build --target js --release`。以下用 `moonvalve` 指代生成的程序；源码运行可替换为 `moon run cmd/main --target native --release --`。默认读取文件、向标准输出写结果。

## 文本与引用

```sh
moonvalve query-all fixtures/duplicates.vdf root tag
moonvalve parse configuration.vdf --condition WIN32 --condition DESKTOP
moonvalve parse configuration.vdf --literal
moonvalve resolve cfg/main.vdf --root /path/to/project
moonvalve format cfg/main.vdf --resolve --root /path/to/project --condition WIN32
moonvalve --json-errors parse broken.vdf
```

`--resolve` 模式下输入文件名与引用路径均相对显式 `--root`。读取前解析真实路径，拒绝越过目录边界的符号链接或目录联接。根目录必须已存在。文件引用由核心库进行循环检测和累计预算检查；CLI 再约束实际文件访问范围。

`--condition` 可重复，名称集合由用户显式给出。默认模式拒绝条件，`--literal` 关闭反斜杠转义。`query-all` 遍历每一层的全部同名项，返回有序数组。`--` 后的参数全部作为键或位置参数处理。

`--json-errors` 必须位于命令前，错误输出包含 code、message；文本解析错误另有 offset、line、column。退出码仍为 2。

## 批量编辑

```sh
moonvalve edit fixtures/duplicates.vdf fixtures/edit-plan.json --dry-run
moonvalve edit configuration.vdf plan.json > updated.vdf
moonvalve edit configuration.vdf plan.json --in-place
```

计划是 JSON 数组，每项包含 `path` 与 `op`。路径为 `{key, occurrence}` 数组，occurrence 从 0 开始；后续操作定位前一步的结果。支持 `replace`（value）、`remove`、`rename`（key）、`insert`（index 与 entry）。值采用文本或有序条目数组。

源编辑保留条件和根级引用的原文，不求值；它与 `--resolve`、`--condition` 不组合。支持 `--literal`。插入沿用邻近键的引号风格、缩进与换行；更换对象的内部内容会重写该对象。删除保留周围注释，并一并删除该条目尾随条件。多项操作全部成功后才生成最终结果。

`--dry-run` 输出 before、after、changed 和文本修改预览，不写文件。`--in-place` 保存前核对原内容，先以独占方式创建 `FILE.bak`，再用同目录临时文件替换目标。已有备份时拒绝覆盖；失败的编辑计划不会创建备份。文件读写期间仍应避免其他软件同时修改目标；原子替换并不构成与其他程序之间的编辑事务。

## 二进制、缓存与快捷方式

```sh
moonvalve binary-decode input.vdf > typed.json
moonvalve binary-encode typed.json > output.vdf
moonvalve cache appinfo.vdf
moonvalve cache appinfo.vdf 480
moonvalve shortcuts shortcuts.vdf
moonvalve shortcut-add shortcuts.vdf fixtures/shortcut-definition.json --dry-run
moonvalve shortcut-set shortcuts.vdf 0 changes.json --in-place
moonvalve shortcut-remove shortcuts.vdf 0 --in-place
```

二进制 JSON 为有序 `{key,type,value}` 数组；对象的 value 仍为数组，数值 payload 为十进制字符串，Float32 使用原始位字符串。UTF-8、UTF-16LE、64 位边界与 NaN payload 均可保留。

缓存支持 appinfo 39/40/41 与 packageinfo 39/40；默认只列记录索引，指定 ID 才解码目标。未知版本拒绝解析。缓存命令输入上限 512 MiB，其他文件命令上限 16 MiB。AppInfo 按记录边界建立索引后延迟验证数据；PackageInfo 没有记录长度，索引时需要解析其树。

快捷方式定义包含 name、exe、start_dir、launch_options 和 tags。新增时 name/exe 必填；更新仅替换定义中提供的字段并保留 App ID 及未知数据。库 API 允许调用方另行显式调整 ID。默认向标准输出写新的二进制；预览、备份和原地保存规则与文本编辑一致。运行中的 Steam 可能重新写入快捷方式配置，因此应在 Steam 退出后保存。

查询、快照批量编辑、移动复制、文本 KV3、多文件重构与 LSP 的用法、JSON 格式和边界见 [进阶功能](advanced.md)。

## 0.7 新入口

`workspace-kv3-query`、`format-preserving`、`kv3-format-preserving`、`kv3-resources` 与 `kv3-resource-edit` 的完整示例及输入格式见[工程工作流](project-workflows.md)。原有规范化命令保持原行为。

## 0.8 资源能力

二进制 KV3、Source 2 DATA/RERL、VPK、GameFileSystem、DependencyGraph、VMT、本地化/PO 与 DMX 的接口、命令和预算见[资源指南](assets.md)。可运行示例：`moon run examples/assets --target js`。

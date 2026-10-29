# 资源、材质、本地化与 DMX

这些功能面向游戏模组、资源检查和桌面工具。库中的加载回调由调用方显式提供；命令行与工作台负责文件选择和输出。完整可运行示例：

```sh
moon run examples/assets --target js
```

## 二进制 KV3 与 Source 2 资源

`decode_kv3_binary` 读取 VKV3 历史版与现代 1—5 版，支持其无压缩、Valve block compression、LZ4 和 Zstandard 编码。`encode_kv3_binary` 写出 4/5 版，选择 `compression=0/1/2`。不支持外部压缩字典及未知版本；错误会报告边界或格式问题。

`KV3BinaryValue` 区分整型宽度与符号、float/double、原始 IEEE 位、字符串、blob、数组、对象和标记。容器布局与压缩字节会重新生成，不能用于要求整个文件字节不变的签名场景。`document()` 提供已有 KV3 API 的语义视图。`select()` 返回原始数值类型；`edit_query()` 使用与文本 KV3 相同的过滤和批量操作，保留未修改数值的存储位。重叠修改与重名字段会失败。

```sh
moonvalve kv3-binary-decode input.kv3
moonvalve kv3-binary-select input.kv3 '/**?flag=resource'
moonvalve kv3-binary-edit input.kv3 '/name' operation.json changed.kv3
moonvalve kv3-text-to-binary source.kv3 5 zstd > output.kv3
moonvalve kv3-binary-encode model.json 4 lz4 > output-v4.kv3
moonvalve resource-inspect asset.vmat_c
moonvalve resource-data asset.vmat_c
```

`read_resource_container` 读取 header version 12，检查 block table、范围与重叠，保留未知块及声明大小以外的尾随字节。`data()` 解码二进制 KV3 DATA；`external_references()` 解码 RERL 的资源 ID 和文件名。`encode_kv3_resource` 创建仅含 DATA 的新容器。任意已编译资源的其他块、重定位表和流式尾部不属于通用重写范围。

## VPK 与搜索路径

`read_vpk` 读取 v1/v2 的树索引、preload、内置/编号分卷和 CRC32。只提供头部与目录树也可以建立索引；`read()` 仅向加载器请求指定条目需要的范围。加载器参数为 `(archive_index, absolute_offset, length)`，`0x7fff` 表示目录文件。`create_vpk` 生成确定性的单文件 embedded VPK v1，可设置 preload 大小。v2 页脚的 MD5 与签名不属于当前验证范围；`vpk-check` 明确输出 `file-crc32`。

```sh
moonvalve vpk-index pak01_dir.vpk
moonvalve vpk-check pak01_dir.vpk
moonvalve vpk-extract pak01_dir.vpk materials/moon.vmt extracted.vmt
moonvalve vpk-extract-all pak01_dir.vpk new-directory
moonvalve vpk-create files.json new_dir.vpk
```

`files.json` 为路径到 Base64 内容的 JSON 对象，例如 `{"readme.txt":"SGVsbG8="}`。输出文件/目录必须不存在，失败时回滚新建的输出。命令行解析目录树最多 16 MiB，单条目最多 64 MiB，批量提取合计最多 64 MiB；库可通过 `BinaryOptions` 设置预算。当前索引偏移范围不超过有符号 32 位整数。

`mount_game_filesystem` 接受按搜索顺序排列的 `LooseMount` 与 `VPKMount`。第一个存在的文件胜出，`locate()` 同时列出被遮蔽候选和 `base_game` 来源。`gameinfo_search_paths` 展开显式 `gameinfo_directory`、`engine_directory`、语言与已解析条件下的 SearchPaths，保留重复项/顺序及 `Game+Mod` ID。尾部 `/*` 作为待枚举计划返回，不会扫描磁盘；其他通配符和未知 token 会报错。实际挂载由调用方决定。

## 依赖图与闭包打包

`build_dependency_graph` 从指定入口出发，通过挂载文件系统追踪 VMT Patch/纹理、KV3 resource/resource_name、Source 2 RERL、KV1 include/base。边记录来源文件、字段、引用种类与状态；节点保留 mount、base_game 和原始字节。反向查询使用 `dependents()`；导出目录、二进制安全 ZIP 或 VPK 时，默认排除基础游戏文件，并阻止未解决的引用。

命令行清单示例：

```json
{
  "roots": ["materials/moon.vmt"],
  "mounts": [
    {"id": "mod", "root": "mod", "base_game": false},
    {"id": "base", "vpk": "base/pak01_dir.vpk", "base_game": true}
  ]
}
```

```sh
moonvalve dependencies project.json
moonvalve dependencies project.json materials/moon/base.vtf
moonvalve dependencies-export project.json new-mod.zip zip
moonvalve dependencies-export project.json new-mod_dir.vpk vpk
moonvalve dependencies-export project.json new-mod directory
```

这是已知格式的静态资源闭包。Patch 原始 include 也必须打包，因此其引用的、后来被覆盖的纹理可能被保守地包含。动态构造路径、未知格式及缺失文件保留诊断；没有解析 BSP/MDL 的二进制模型内部结构。`strict=false` 仅供调用方审阅诊断后显式选择。默认图预算 2048 文件、64 MiB、100000 条边。

## VMT

`load_vmt` 支持递归 Patch include、insert、replace、空字符串删除、Proxies 追加、循环与总输入限制。参数匹配不区分大小写；insert 可添加或覆盖，replace 只修改已有参数。已存在的块按相同规则递归合并。`origins` 的整数路径对应展开后的参数树，记录源文件及操作。`textures()` 识别常用纹理参数，并允许传入额外参数名；`env_cubemap` 与 `_rt_*` 标为内建资源，动态值单独标记。`with_parameter()` 返回新材质，重复参数歧义会报错。

```sh
moonvalve vmt-parse materials/moon.vmt
moonvalve vmt-expand materials/patch.vmt mod
moonvalve vmt-set materials/moon.vmt '$basetexture' moon/new
```

展开/写出为规范化材质副本，不保留原材质注释。条件可由库的 ParseOptions 显式求值；没有运行材质代理或模拟渲染器。

## Valve 本地化与 PO/POT

`read_localization` 严格解码 UTF-8、UTF-8 BOM、UTF-16 LE/BE BOM；`write()` 可选择同样四种编码。令牌按名称保持顺序，大小写重复名称被拒绝。`to_po` 以令牌名作为 `msgctxt`，源字符串为 `msgid`，已有译文为 `msgstr`，提供 UTF-8 gettext 头部；没有译文时可导出 POT。

`parse_po`/`stringify` 支持多行字符串、上下文、复数、注释、fuzzy 和废弃条目。PO 转 Valve 仅接受单数令牌；有意保留复数供 PO 往返，不会把不同复数变体压成一条译文。输入使用 UTF-8 文本；非 ASCII 的 C 数字转义请先转换为实际 Unicode 字符。`update_po` 按上下文更新，变更原文的旧译文标为 fuzzy，删除消息标为废弃。

`import_po` 检查上下文、原文新旧、fuzzy、缺译和占位符，返回文档与逐项问题。问题项保留源文；命令行/工作台在问题清除后导出。占位符支持 Valve `%s1`/`%d2`，printf 参数身份与常见静态宽度/精度，或 `{0}`、`{s:name}` 等 brace 名称。保留重复次数并允许有编号参数换序。printf 动态 `*` 宽度/精度需由应用提供适配器。

```sh
moonvalve localization-read game_english.txt
moonvalve localization-pot game_english.txt > game.pot
moonvalve localization-po game_english.txt game_schinese.txt > game.po
moonvalve po-update new.pot old.po > updated.po
moonvalve localization-import game_english.txt reviewed.po schinese valve utf16le > game_schinese.txt
```

## DMX / KeyValues2

`DMXDocument` 独立于 KV1/KV3，是由 UUID 标识的元素图。支持 element/null/external 引用、int32、float32 原始位、bool、string、binary、time tick、RGBA、vector2/3/4、qangle、quaternion、4×4 vmatrix 及其同类型数组。读取/写出 binary 4/5 与 KeyValues2 1；其他二进制版本和扩展类型会明确报错。

KeyValues2 可读取内联元素、共享和向前引用；缺省 UUID 分配确定性且避开已有 ID。规范化输出将元素平铺，通过 UUID 保持环与共享身份。`with_attribute()` 编辑指定元素属性；JSON 以十进制字符串保存浮点位与颜色位。二进制往返保留 NaN payload/负零；转为文本会规范化 NaN payload。

```sh
moonvalve dmx-decode model.dmx
moonvalve dmx-to-text model.dmx
moonvalve dmx-binary model.dmx 5 > model.binary.dmx
moonvalve dmx-from-json model.json > model.text.dmx
```

## 验证

跨格式命令行回归：`node scripts/test-assets-cli.cjs`，原生版加 `--native`。独立兼容性：`node scripts/check-binary-kv3.cjs` 使用锁定的 ValveResourceFormat .NET 工具；`node scripts/check-assets.cjs` 使用仅测试依赖 srctools 2.7.0、polib 1.2.0。这些参考实现不会在产品中运行。`check-resource-fixtures.cjs` 还可验证固定上游提交的真实文件，需通过环境变量提供仓库外原始样本；不随项目重新分发游戏资源。

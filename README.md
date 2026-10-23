# MoonValve

**MoonBit 原生 Valve KeyValues 1 读写库与 Steam 清单工具。**

MoonValve 让 MoonBit 程序可以读取、查询和写出 VDF/ACF 文本，同时保留键的顺序与重复项。核心库没有第三方依赖，也不调用 Python、Valve SDK 或外部解析器。Steam 数据模型和命令行工具建立在同一份解析实现上。

当前版本为开发中的 `0.1.0`，已提供可运行的库、示例、命令行和测试。尚未发布到 Mooncakes。

## 为什么需要它

Steam 和 Source 生态使用 KeyValues 保存配置和资源信息。这种格式有嵌套对象，也允许重复键；把它直接转换成普通字典容易丢失信息。MoonValve 使用有序条目数组表示对象，方便游戏工具、资源处理程序和桌面应用复用。

## 已实现

- KV1 文本解析：嵌套对象、带引号和不带引号的字符串、空值、空对象、`//` 注释、Unicode 和 UTF-8 BOM。
- 有序条目模型，重复键不覆盖；支持首项查询、全部同名项查询和逐层路径查询。
- 规范化写出与结构往返，提供保留重复键的 JSON 导出。
- 可选择的转义模式，以及输入长度、字符串长度、总条目数和嵌套深度限制。
- 包含错误码、行列号和 Unicode 字符偏移的解析诊断。
- Steam `appmanifest_*.acf` 和新旧 `libraryfolders.vdf` 数据模型。
- 文件／标准输入命令行，以及多游戏库清单汇总；单个清单损坏时保留其他成功结果。

完整的格式边界见 [兼容性说明](docs/compatibility.md)。

## 环境与获取代码

- 已验证工具链：`moonc v0.10.14+7d59c7ec9`，配套 `moonbitlang/core` 同版本。
- CLI 需要 Node.js 22 或更高版本；纯 MoonBit 示例不需要 Node.js。

```sh
git clone https://github.com/Charles67676767/MoonValve.git
cd MoonValve
moon version --all
moon check
moon test
moon run examples/demo
```

示例输出以 `480: Moon Harbor (Moon Harbor)` 开头，随后输出规范化的 KV1。示例游戏、路径和清单均为合成数据。

## 库用法

在本仓库中的包配置里导入：

```moonbit
import {
  "Charles67676767/moonvalve" @valve,
}
```

```moonbit
let doc = @valve.parse("root { tag one tag two name \"Moon Harbor\" }")
let name = doc.lookup(["root", "name"])
let normalized = @valve.stringify(doc)
let same = @valve.parse(normalized) == doc
```

`parse` 和 `stringify` 会抛出结构化错误，需要由调用方处理。可直接运行的完整错误处理示例在 [examples/demo](examples/demo/main.mbt)。Mooncakes 发布前，使用上面的源码仓库运行方式。

对象由 `Array[Entry]` 表示，`Value` 为 `Text(String)` 或 `Object(Array[Entry])`。查询默认区分大小写，遇到重复键时返回第一项；`Document::get_all` 返回所有顶层同名项。Steam 数据模型单独采用 ASCII 不区分大小写的字段查询。

## 命令行

以下命令在仓库根目录执行；输入文件保持只读，结果写到标准输出。

```sh
moon run cmd/main --target js -- help
moon run cmd/main --target js -- parse fixtures/duplicates.vdf
moon run cmd/main --target js -- format fixtures/duplicates.vdf
moon run cmd/main --target js -- query fixtures/appmanifest_480.acf AppState name
moon run cmd/main --target js -- app fixtures/appmanifest_480.acf
moon run cmd/main --target js -- libraries fixtures/libraryfolders.vdf
```

`app` 的示例结果：

```json
{"app_id":"480","name":"Moon Harbor","install_dir":"Moon Harbor","size_on_disk":"1048576","build_id":"20261023"}
```

游戏 ID、构建 ID 和输出的字节数使用字符串表示，避免 JSON 消费端的浮点精度问题。

读取本机实际清单时，将命令中的路径换成自己的 `libraryfolders.vdf`：

```sh
moon run cmd/main --target js -- inventory "/path/to/Steam/steamapps/libraryfolders.vdf"
```

`inventory` 扫描该文件列出的库中的 `steamapps/appmanifest_*.acf`，返回 `games` 和 `errors` 数组。相对库路径以输入文件的目录为基准。它读取清单记录，不计算实际文件夹大小，也不验证游戏下载是否完整。库路径和清单名可能出现在本机输出中。

除 `inventory` 外，可以把文件名换成 `-` 从标准输入读取。CLI 严格解码 UTF-8，输入上限为 16 MiB。退出码为 `0`（成功）、`1`（inventory 部分失败）或 `2`（参数、输入或解析错误）。

也可以先构建，再直接使用 Node.js：

```sh
moon build --target js --release
node _build/js/release/build/cmd/main/main.js help
```

## 检查与测试

```sh
moon fmt --check
moon check --target js
moon test --target wasm
moon test --target wasm-gc
moon test --target js
moon build --target js --release
node scripts/test-cli.cjs
moon info
```

核心测试覆盖重复键、Unicode、转义、错误输入、资源边界、结构往返、Steam 字段及精确整数。CLI 测试使用临时目录构造库与清单，检查文件／标准输入、UTF-8、退出码和部分失败结果。持续集成执行格式、检查、构建、测试和示例。

## 目录

```text
model.mbt             有序数据模型与查询
parser.mbt            KV1 文本解析及诊断
writer.mbt            规范化文本写出
steam.mbt             Steam 清单模型
cmd/main/             Node.js 文件 IO 适配与 MoonBit CLI
examples/demo/        跨后端最小使用示例
fixtures/             合成示例数据
scripts/test-cli.cjs   CLI 端到端测试
docs/                 兼容性、设计与路线图
```

## 后续方向

当前重点是稳定文本 KV1 和 Steam 清单能力。后续计划评估显式文件解析器支持的 `#include`／`#base`、平台条件求值、保留注释的编辑模型和二进制 KV1。详见 [路线图](docs/roadmap.md)。

## 许可证与参考

采用 [MIT 许可证](LICENSE)。格式兼容性参考 [ValvePython/vdf](https://github.com/ValvePython/vdf) 和 [ValveKeyValue](https://github.com/ValveResourceFormat/ValveKeyValue)，来源及分发边界见 [NOTICE.md](NOTICE.md)。

MoonValve 是独立项目，与 Valve 或 Steam 没有隶属关系。

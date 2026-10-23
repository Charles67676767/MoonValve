# MoonValve

**MoonBit 原生 Valve KeyValues 1 读写库与 Steam 清单工具。**

MoonValve 让 MoonBit 程序可以读取、查询和写出 VDF/ACF 文本，同时保留键的顺序与重复项。核心库没有第三方依赖，也不调用 Python、Valve SDK 或外部解析器。Steam 数据模型和命令行工具建立在同一份解析实现上。

当前版本为开发中的 `0.1.0`，已提供可运行的库、示例、命令行和测试。尚未发布到 Mooncakes。

## 为什么需要它

Steam 和 Source 生态使用 KeyValues 保存配置和资源信息。这种格式有嵌套对象，也允许重复键；把它直接转换成普通字典容易丢失信息。MoonValve 使用有序条目数组表示对象，方便游戏工具、资源处理程序和桌面应用复用。

## 已实现

- KV1 文本解析：嵌套对象、带引号和不带引号的字符串、空值、空对象、`//` 注释、Unicode 和 UTF-8 BOM。
- 有序条目模型，重复键不覆盖；支持首项查询、全部同名项查询和逐层路径查询。
- 规范化写出与结构往返，提供保留重复键的 JSON 双向转换。
- 按同名键出现次序定位的插入、替换、删除与重命名，以及保留原文注释和排版的局部编辑。
- 显式平台条件求值与调用方提供加载回调的 `#include`／`#base` 解析，含循环检测和全局资源预算。
- 保留类型与浮点原始位的标准二进制 KV1 编解码。
- 可选择的转义模式，以及输入长度、字符串长度、总条目数和嵌套深度限制。
- 包含错误码、行列号和 Unicode 字符偏移的解析诊断。
- Steam `appmanifest_*.acf` 和新旧 `libraryfolders.vdf` 数据模型。
- JavaScript 与原生命令行；Steam 清单筛选、排序、精确容量汇总、重复及缺失检查与 CSV 导出。

完整的格式边界见 [兼容性说明](docs/compatibility.md)，新增 API 见 [扩展说明](docs/extensions.md)。

## 环境与获取代码

- 已验证工具链：`moonc v0.10.14+7d59c7ec9`，配套 `moonbitlang/core` 同版本。
- JavaScript CLI 需要 Node.js 22 或更高版本；原生 CLI 构建需要 C 编译器，运行时无需 Node。

```sh
git clone https://github.com/Charles67676767/MoonValve.git
cd MoonValve
moon version --all
moon check
moon test
moon run examples/demo
moon run examples/advanced
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
moon run cmd/main --target js -- from-json data.json
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
moon run cmd/main --target js -- inventory "/path/to/libraryfolders.vdf" --filter portal --sort size --csv
```

`inventory` 扫描该文件列出的库中的 `steamapps/appmanifest_*.acf`，返回 `games`、`errors` 和筛选结果的 `summary`。相对库路径以输入文件的目录为基准。它读取清单记录，不计算实际文件夹大小，也不验证游戏下载是否完整。库路径和清单名可能出现在本机输出中。

除 `inventory` 外，可以把文件名换成 `-` 从标准输入读取。CLI 严格解码 UTF-8，输入上限为 16 MiB。退出码为 `0`（成功）、`1`（inventory 部分失败）或 `2`（参数、输入或解析错误）。

也可以先构建，再直接使用 Node.js：

```sh
moon build --target js --release
node _build/js/release/build/cmd/main/main.js help
```

原生程序：

```sh
moon build --target native --release
moon run cmd/main --target native --release -- help
```

可直接分发 `_build/native/release/build/cmd/main/` 下生成的 `main.exe` 或 `main`，以工具链实际产物为准；`.exe` 后缀也可能出现在 Linux 产物上。两种 CLI 的命令、输入格式与退出码一致。

## 检查与测试

```sh
moon fmt --check
moon check --target js
moon test --target all --deny-warn
moon build --target js --release
node scripts/test-cli.cjs
moon build --target native --release
node scripts/test-cli.cjs --native
python -m pip install vdf==3.4
python scripts/check-reference.py
node scripts/benchmark.cjs --native
moon info
```

核心测试覆盖文本与二进制、编辑、条件、引用、Steam 分析与资源边界，并包含生成式往返和独立参考向量。CLI 测试使用临时目录构造清单。差分脚本在文本的共同支持范围内与 `vdf==3.4` 双向比对；Python 仅为可选测试依赖。持续集成执行四后端检查、构建、测试、示例，以及 Windows/Linux 命令行验收。复现细节见 [验证说明](docs/validation.md)。

## 目录

```text
model.mbt             有序数据模型与查询
parser.mbt            KV1 文本解析及诊断
writer.mbt            规范化文本写出
steam.mbt             Steam 清单模型
inventory.mbt         筛选、排序、统计、检查与 CSV
edit.mbt              重复键感知的文档编辑
source_edit.mbt       保留原文的局部编辑
json_codec.mbt        有序 JSON 导入
conditions.mbt        平台条件表达式
resolve.mbt           文件引用解析
binary.mbt            标准二进制 KV1
cmd/main/             JS/C 宿主适配与 MoonBit CLI
examples/demo/        跨后端最小使用示例
examples/advanced/    编辑、条件、引用与二进制示例
fixtures/             合成示例数据
scripts/test-cli.cjs   CLI 端到端测试
docs/                 兼容性、设计与路线图
```

## 后续方向

当前重点是稳定已实现 API、扩充实际兼容性样例并准备首个 Mooncakes 发布版本。KV2、KV3 和 appinfo 容器不在当前范围内。详见 [路线图](docs/roadmap.md)。

## 许可证与参考

采用 [MIT 许可证](LICENSE)。格式兼容性参考 [ValvePython/vdf](https://github.com/ValvePython/vdf) 和 [ValveKeyValue](https://github.com/ValveResourceFormat/ValveKeyValue)，来源及分发边界见 [NOTICE.md](NOTICE.md)。

MoonValve 是独立项目，与 Valve 或 Steam 没有隶属关系。

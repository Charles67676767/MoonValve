# MoonValve

**MoonBit 原生 Valve KeyValues 工具库：KV1、文本 KV3、Steam 清单与编辑器服务。**

MoonValve 让 MoonBit 程序可以读取、查询和写出 VDF/ACF 文本，同时保留键的顺序与重复项。核心库没有第三方依赖，也不调用 Python、Valve SDK 或外部解析器。Steam 数据模型和命令行工具建立在同一份解析实现上。

当前版本为 `0.7.0`，提供库、命令行、本地可视化工作台和跨平台下载包。从 0.4.0 起已发布到 Mooncakes；[安装与独立验证](docs/publishing.md)说明版本依赖用法。

新增查询表达式与快照批量修改、跨对象移动复制、批量编辑优化、文本 KV3、多文件引用重构及标准输入输出 LSP。详见 [进阶功能与边界](docs/advanced.md)，[VS Code 扩展](extensions/vscode/README.md) 可通过 VSIX 安装。

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
- 全重复项路径查询、树遍历、严格类型读取与有序编辑事务。
- 保留条件、引用与字面路径的源编辑，插入沿用相邻缩进、换行和键的引号方式。
- `shortcuts.vdf` 增删改、appinfo/packageinfo 多版本索引、二进制外部字符串表。
- 增量 UTF-8 解析与事件回调，可跳过对象交付而继续验证语法，附百万条目示例。
- 命令行编辑预览、带备份的原子保存、受选定目录约束的引用展开和结构化错误。
- 本机可视化工作台，提供文本/二进制树形浏览、编辑预览、撤销和下载副本。
- 分块文件命令，支持 JSON Lines 原文事件、原始标量路径查询、CSV 和无条件文本的流式规范化；输出处理慢速接收端的背压。
- 快捷方式专用表单、批量修改预览；缓存按 ID 搜索、分页和记录按需解码。
- 多文件工程切换、草稿快照、引用关系及展开字段到原文件行列的来源导航。

完整格式边界见 [兼容性说明](docs/compatibility.md)，库接口见 [API 导览](docs/api.md)，工具用法见 [命令行](docs/commands.md)、[本地工作台](docs/editor.md) 和 [发行包](docs/distribution.md)。

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

示例输出以 `480: Moon Harbor (Moon Harbor)` 开头，随后输出规范化的 KV1。演示中的游戏和路径为合成数据；另有固定上游版本的 [Proton 实际配置回归](fixtures/upstream/proton/README.md)。

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

`parse` 和 `stringify` 会抛出结构化错误，需要由调用方处理。可直接运行的完整错误处理示例在 [examples/demo](examples/demo/main.mbt)。Mooncakes 发布前，也可通过 [独立模块示例](integration/consumer/README.md) 的 moon.work 引入源码依赖。

对象由 `Array[Entry]` 表示，`Value` 为 `Text(String)` 或 `Object(Array[Entry])`。查询默认区分大小写，遇到重复键时返回第一项；`Document::get_all` 返回所有顶层同名项。Steam 数据模型单独采用 ASCII 不区分大小写的字段查询。

## 命令行

以下命令在仓库根目录执行，默认向标准输出写结果；只有显式 `--in-place` 才保存到文件并创建备份。

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

除 `inventory`、文件引用展开及原地保存外，可以把文件名换成 `-` 从标准输入读取。文本按 UTF-8 严格解码，普通输入上限 16 MiB，缓存命令上限 512 MiB；流式命令默认 64 MiB，可显式设定预算，见 [流式文件处理](docs/streaming.md)。退出码为 `0`（成功）、`1`（inventory 部分失败）或 `2`（参数、输入或解析错误）。

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

核心测试覆盖文本与二进制、编辑事务、格式保留、条件、引用、流解析、Steam 快捷方式、缓存及资源边界。CLI 使用临时目录验收；Python vdf 与 .NET ValveKeyValue 是独立测试参考，不参与产品运行。另有带失败样本缩减的确定性模糊测试。持续集成执行四后端验证、Windows/Linux 命令行、编辑器核心、独立参考和发行包校验。复现细节见 [验证说明](docs/validation.md)。

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
project.mbt           引用关系与原文来源
stream_writer.mbt     有界事件写出
binary.mbt            标准二进制 KV1
cmd/main/             JS/C 宿主适配与 MoonBit CLI
examples/demo/        跨后端最小使用示例
examples/advanced/    编辑、条件、引用与二进制示例
fixtures/             合成示例与注明来源许可的实际配置
scripts/test-cli.cjs   CLI 端到端测试
docs/                 兼容性、设计与路线图
```

## 后续方向

0.7.x 保留 0.4、0.5 与 0.6 系列公开签名，并遵循[兼容约定](docs/api-stability.md)，并通过接口基线、实际配置回归、真实 VS Code 主机及注册表消费者进行验证。KV2、二进制 KV3、VBKV 和未知版本的 Steam 缓存不在当前范围内。详见 [路线图](docs/roadmap.md)。

## 许可证与参考

采用 [MIT 许可证](LICENSE)。格式兼容性参考 [ValvePython/vdf](https://github.com/ValvePython/vdf) 和 [ValveKeyValue](https://github.com/ValveResourceFormat/ValveKeyValue)，来源及分发边界见 [NOTICE.md](NOTICE.md)。

MoonValve 是独立项目，与 Valve 或 Steam 没有隶属关系。

### 0.5 新增的工程编辑能力

- KV3 原文局部编辑：替换值、重命名字段、增删对象字段与数组元素，保留未修改区域的注释、头部、换行和数字写法。
- 工程字段查询与批量修改：按文件选择，查看全部匹配，统一预览并生成新快照；任一步失败都不返回部分工程。
- VS Code 文件引用维护：文件及目录重命名更新 `#base` / `#include`，跨目录移动重算向外引用；诊断显示文件系统确认的缺失目标及循环引用链。

可运行示例：`moon run examples/advanced --target native`。命令行及工作台用法见[进阶功能](docs/advanced.md)。

### 0.6 工程导出与 KV3 类型工作流

工作台支持按原目录结构下载工程 ZIP；CLI 可将快照导出到全新目录或 ZIP。KV3 支持类型/标记感知查询、精确整数比较、保留原文的批量编辑、树形字段控件，以及 VS Code 大纲、折叠与类型悬浮。完整命令、库接口和资源限制见[工程导出与 KV3 工作流](docs/kv3-workflows.md)。

```sh
moon run cmd/main --target native -- workspace-export fixtures/workspace-fields.json new-project
moon run cmd/main --target native -- workspace-zip fixtures/workspace-fields.json project.zip
moon run cmd/main --target native -- kv3-select fixtures/sample.kv3 '/**?type=integer&>9007199254740993'
```

### 0.7 混合工程与资源维护

KV1 与文本 KV3 可在同一工程内分别查询、批量修改并导出；新增保留注释、条件、引用与数字写法的格式化。VS Code 可按显式资源目录跳转、检查缺失文件，并在移动资源时更新已载入 KV3 的引用。配置示例和限制见[工程与资源工作流](docs/project-workflows.md)。

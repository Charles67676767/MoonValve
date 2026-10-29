# 验证与复现

工具链：`moonc v0.10.14+7d59c7ec9`，同版本 `moonbitlang/core`。Zstandard 使用 `bikallem/compress` 0.3.4（Apache-2.0）；Python/.NET 参考测试不参与产品运行。新增格式验证命令见[资源指南](assets.md)。

## 核心与命令行

```sh
moon fmt --check
moon check --target all --deny-warn
moon build --target all
moon test --target all --deny-warn
moon run examples/demo
moon run examples/advanced
moon build --target js --release
node scripts/test-cli.cjs
moon build --target native --release
node scripts/test-cli.cjs --native
```

核心测试覆盖文本/二进制、重复项、Unicode、资源限制、编辑事务、Steam、流式处理和新增资源格式。四个后端运行同一套核心测试；CLI、LSP、工作台和资源端到端测试由 scripts/ 中的脚本验证，输出实际测试数量。另有大规模默认项合并与百万条目分块示例。

流式端到端检查使用超过 16 MiB 的文件和跨 64 KiB 块的 Unicode 输入。`node scripts/test-stream-pipe.cjs`（或加 `--native`）让接收端反复暂停，核对 22,200,011 字节输出的完整 SHA-256；JS 进程设置 48 MiB 堆限制。此限制只约束 V8 堆，不等同于进程总内存或峰值 RSS。

生成式测试包含 300 份文本模型的文本/JSON往返与源编辑、300 份二进制模型的类型往返与尾随数据拒绝，以及 200 份文本的三种结构破坏。所有生成过程固定种子或确定公式，失败可以复现。

## 独立参考

```sh
python -m pip install vdf==3.4
python scripts/check-reference.py
python scripts/check-reference.py --native
```

脚本以种子 `20261023` 生成 80 份共同子集文本，在参考实现和 MoonValve 之间进行双向转换，比较完整有序树。每个 CLI 调用限制 15 秒。文本子集包含重复键、对象、中文、引号和常见转义。

脚本同时重新生成并核对 24 组二进制参考向量。向量记录在 `fixtures/reference-binary.json`，对应 MoonBit 测试逐字节比对编码结果，再核对解码后的类型模型；覆盖负零、64 位边界、重复项和嵌套对象。宽字符串与畸形输入使用独立测试，因为参考库的相应行为不适合用作严格验证基准。

仅在需要更新合成向量时运行 `python scripts/check-reference.py --refresh --cases 0`，随后执行 `moon fmt` 并检查差异。该选项不会修改上游源码。

## 规模基准

```sh
node scripts/benchmark.cjs
node scripts/benchmark.cjs --native
```

基准生成 1000、10000、50000 条带中文和重复键的记录；先预热一次，再记录三次的中位数。计时包括进程启动、输入解码、解析及 JSON 输出，输出同时记录后端、系统、架构、Node 版本、条目数和输入字节数，**不是纯解析器吞吐率**。不同系统的结果不可直接当作同环境性能比较；CI 运行基准验证规模路径，不设置依赖机器速度的耗时断言。

## 覆盖率

```sh
moon test --target js --enable-coverage
moon coverage report -f summary
```

报告按 MoonBit 插桩点统计；CLI 的进程验收不计入核心单元测试的覆盖数字。原生 C 宿主代码另由两平台的端到端检查覆盖。

## 第二参考、模糊测试与发行包

```sh
node scripts/build-editor.cjs
node scripts/test-editor.cjs
dotnet restore tools/reference-dotnet/Reference.csproj --locked-mode
dotnet build tools/reference-dotnet/Reference.csproj --no-restore -c Release
node scripts/check-dotnet.cjs
node scripts/fuzz.cjs
moon run examples/streaming --target native --release
moon -C integration/consumer run cmd/main --target js
node scripts/package.cjs
python scripts/test-package.py
```

.NET 参考有 104 项共同子集一致、3 项已发布版本差异被明确断言；变异测试默认 3000 份文本与 3000 份二进制输入，并自动缩减文本性质失败样本。细节见 [参考差异](reference-differences.md)。发行包校验 ZIP、逐文件 SHA-256、版本及在隔离目录运行的原生程序，确保下载包可直接使用；说明见 [发行包](distribution.md)。

## 0.4.0 新增验证

`node scripts/test-lsp.cjs` 与 `--native` 各执行 9 项交互式检查，确认无需关闭输入即可响应、UTF-16 增量修改、负版本号、缓存与未保存文档、过期版本、引用跳转、诊断与正常关闭。`node scripts/test-extension.cjs` 在模拟 VS Code API 主机内启动真实服务器，覆盖激活、七类提供器注册、增量修改、关闭和重开；另有安装 VSIX 后的真实主机测试，见下文。

`node scripts/check-kv3.cjs` 使用固定种子 20261024 和 ValveKeyValue 0.70.0.499，对 76 份 KV3 文档的原文和规范化输出分别执行参考解析写出、再由 MoonValve 重读，比较类型模型。数字比较保留 64 位整数精度、负零及非有限浮点；子集包含数组、对象、blob、多行字符串和标记。

`node scripts/benchmark-edits.cjs` 比较逐项编辑与优化批量编辑的完全相同输出，预热一次后取三次中位数，包括解析、源编辑验证与桥接 JSON 输出，不设置机器耗时门槛。2026-10-24 Windows x64 / Node 24.15.0 本地测量：1000 条配置修改 50 项为 96.64 / 6.63 ms；5000 条配置修改 200 项为 2520.46 / 59.37 ms（逐项 / 批量）。数字不能用于跨机器性能承诺。

发行包检查额外验证新工作台模块、KV3 夹具、查询命令及 VSIX 的内容完整性。VSIX 使用锁定的微软 vsce 4.0.0 打包，开发依赖不进入运行包。

## 0.4.1 发布与使用验收

- `moon info` 后运行 `node scripts/check-api.cjs`，验证根包公开签名与 0.4.0 基线一致。
- `node scripts/check-upstream.cjs` 验证 ValveSoftware/Proton 的三份实际清单和模板，原始字节哈希与 BSD-3-Clause 许可随文件保留。
- `node scripts/test-registry.cjs VERSION` 从公开注册表安装指定版本，在仓库外、没有 moon.work 的新模块执行四后端接入；0.4.0 已在 2026-10-27 通过此流程。新版本发布后须再次指定版本验证。
- `node scripts/test-vscode.cjs` 在独立用户和扩展目录安装 VSIX，以真实 VS Code 命令测试语言识别、符号、引用跳转、链接、补全、悬浮、折叠、UTF-16 增量编辑、格式化、诊断和恢复、KV3 精确类型格式化。2026-10-27 在 Windows x64 / VS Code 1.143.1 完成 11 项检查。主机日志与结果只保存在被忽略的 `_build/vscode-e2e`，机器绝对路径不进入仓库。
- `moon package --list` 后运行 `python scripts/check-publish.py` 核对实际发布 ZIP 的版本、关键文件、许可证与内容排除。

## 0.5 增量验收

新增用例覆盖 KV3 每个数组增删边界、尾逗号与延续行注释、CRLF、标记内字段、数字写法、无效事务与冲突字段；工程按文件选择、稳定排序、完整回滚；LSP 仅确认后报告缺失、间接引用链、循环恢复、未保存版本、文件/目录移动与编码 URI。真实 VS Code 1.143.1 的 16 项检查包括文件重命名自动维护引用、移动后跳转、缺失目标、未保存循环及相关文件诊断恢复。

## 0.6 增量验收

- 91 份 KV3 文档经成熟参考实现双向核验；四后端核心测试覆盖 64 种数组删除子集及有无尾逗号、资源标记保留、整数精确筛选、冲突/重叠事务、Unicode 位置、非法/大小写/设备名导出路径。
- 两套 CLI 验证目录副本、拒绝已有目标与目录联接、ZIP 输出和类型查询；Python `zipfile` 独立校验 ZIP 中央目录、CRC32 及每个文件的原始字节。
- 真实 VS Code 1.143.1 从 VSIX 安装后验证 20 项交互，包括 KV3 数组/对象大纲、折叠、精确整数悬浮和字面量补全。
- 工作台实际验证树形布尔/整数编辑、预览撤销、资源类型查询和批改、工程 ZIP 下载与解压校验。截图及本机输出保存在仓库外或忽略目录。
- `node scripts/test-registry.cjs --source` 在发布前检查生成的消费者用例，发布后仍用不含 moon.work 的注册表模式执行四后端独立安装。

## 0.7 增量验收

- 核心新增混合工程的格式隔离、类型查询与整批失败，保留注释格式化的幂等性、CRLF/BOM、重复键、条件/指令、多行字符串和精确数值，以及显式资源映射、符号标记排除和移动冲突。资源目录重写覆盖 2000 个原始目标。
- CLI 两后端各 36 项、LSP 两后端各 19 项、工作台核心 15 项；真实 VS Code 1.143.1 的 28 项检查增加资源目标跳转、链接、移动后更新未保存 KV3、确认缺失及恢复、KV1 指令格式化。
- 182 份 KV3 文档（含保留注释格式化结果）经 ValveKeyValue 参考解析和写出；三份固定 Proton 实际配置增加保留注释格式化与幂等检查。
- 发布前独立源码消费者和发布后真实注册表消费者覆盖新混合工程、格式化、资源映射与重写接口，均检查四后端。

# 验证与复现

工具链：`moonc v0.10.18+6c83a7f62`，同版本 `moonbitlang/core`。Zstandard 使用 `bikallem/compress` 0.3.4 的所需源码（Apache-2.0，来源与原始哈希见 `internal/vendor`）；Python/.NET 参考测试不参与产品运行。新增格式验证命令见[资源指南](assets.md)。

## 核心与命令行

```sh
moon update
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

## 当前验收加固

```sh
node scripts/generate-capabilities.cjs --check
node scripts/run-workflows.cjs all
node scripts/run-workflows.cjs all --native
node scripts/test-recovery.cjs
node scripts/test-recovery.cjs --native
npm ci --ignore-scripts --prefix tools/browser
node tools/browser/node_modules/playwright/cli.js install chromium
node scripts/test-browser.cjs
node scripts/fuzz-assets.cjs
```

Linux干净环境安装浏览器可使用 `install --with-deps chromium`。Playwright仅用于测试，不进入工具运行依赖。浏览器结果保存在忽略的 `_build/browser-e2e.json`。真实资源获取与异常输入重放见[验收路径](acceptance.md)；旧版数量与测量移至[历史记录](validation-history.md)，不作为当前版本覆盖数量。

主验证基线与文档构建统一使用 `moonc v0.10.18+6c83a7f62` 及同版本标准库，包含四后端检查、构建、测试、Windows 验证、参考实现测试和发布后独立安装验证。CI 的 `docs-compat` 作业补充检查文档生成。上游压缩源码的原始哈希、修改说明及当前哈希由 `node scripts/check-vendor.cjs` 核验；其测试与 MoonValve 自有测试分开计数。

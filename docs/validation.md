# 验证与复现

工具链：`moonc v0.10.14+7d59c7ec9`，同版本 `moonbitlang/core`。核心库无第三方包依赖；参考测试使用 `vdf==3.4`（MIT），不参与产品运行。

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

目前 100 项测试覆盖文本/二进制、重复项、Unicode、资源限制、编辑事务、原文条件保留、查询遍历、类型读取、Steam 快捷方式、缓存分页、分块解析与写出、条件过滤后的来源位置和引用合并，四个后端均运行同一套核心测试。两个 CLI 各运行 25 项端到端验收；编辑器另有 9 项共用核心检查。另有大规模默认项合并测试与百万条目分块示例。

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

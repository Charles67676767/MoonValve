# 独立参考与已知差异

Python `vdf==3.4` 和 .NET `ValveKeyValue 0.70.0.499` 仅用于测试，不参与 MoonValve 产品运行。适配器和样例为独立编写的代码与合成数据；参考库由各自包管理器获取。

## .NET 验证

```sh
node scripts/build-editor.cjs
dotnet restore tools/reference-dotnet/Reference.csproj --locked-mode
dotnet build tools/reference-dotnet/Reference.csproj -c Release --no-restore
node scripts/check-dotnet.cjs
```

需要 .NET 10 SDK。可通过 `MOONVALVE_DOTNET` 指定已有 dotnet 可执行文件。脚本对 100 份生成文本，以及简单/复合条件、递归 base 和二进制标量进行交叉验证；对文本还检查参考库写出结果经 MoonValve 重读后的完整有序树。共同子集中共有 104 项一致。

以下三项是固定已发布版本与 MoonValve 所依据的当前格式说明之间的差异，脚本分别断言双方行为，不计入一致案例：

| 输入 | ValveKeyValue 0.70.0.499 | MoonValve |
|---|---|---|
| `root { x one x = [$WIN32] two }` | 抛出键值间状态错误 | 条件匹配时替换先前项 |
| `root { x [$LINUX] one [$WIN32] }`，只启用 WIN32 | 不保留 x | 最后条件决定，保留 x |
| `root { a own } #include extra.vdf` | 拒绝位于根对象后的 include | 允许根对象前后指令，追加引用内容 |

条件与引用的目标行为参考 [ValveKeyValue 当前说明](https://github.com/ValveResourceFormat/ValveKeyValue#conditionals)；参考包版本变化时应重新核对这些差异，不能直接更新预期值掩盖变化。Python 参考的宽字符串、空根二进制及非法编码差异另见兼容性说明。

## 可复现的模糊测试

```sh
node scripts/fuzz.cjs
```

默认种子 20261023，运行 3000 份文本变异和 3000 份二进制变异。文本成功解析后核对规范化往返以及分块事件重建的有序树；二进制覆盖随机字节与对独立参考向量的截断、位翻转、尾随数据变异，成功解码后要求逐字节往返。

发生文本性质失败时自动删除输入片段以缩减复现样本，保存到被忽略的 `_build/fuzz-failure.json`。可通过 `MOONVALVE_FUZZ_SEED` 与 `MOONVALVE_FUZZ_CASES` 复现或扩大运行规模；这属于确定性变异测试，不声称具有覆盖率引导能力或完整格式覆盖。

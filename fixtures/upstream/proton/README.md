# Proton 实际配置样例

这里保留 ValveSoftware/Proton 提交 `bc896217ffcd67f892f952b010f898fe7bd0f0a1` 的三个原始文件：两个架构的实际工具清单，以及构建中用于注册兼容工具的 VDF 模板。它们来自公开产品工程，不是 MoonValve 生成的虚构配置。模板中的占位符按上游原样保留。

各文件来源 URL、提交和原始字节 SHA-256 记录在 `provenance.json`；许可为 BSD-3-Clause，原始版权、条件和免责声明见 `LICENSE.proton`。没有引入 Proton 的实现代码或游戏素材。

`node scripts/check-upstream.cjs` 核对原始字节哈希、真实清单字段、解析与规范化往返，并检查修改显示名称时原文注释仍被保留。该测试验证格式处理与已知字段，不启动 Steam 或 Proton。

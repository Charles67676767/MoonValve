# 第一次使用 MoonValve

先选择入口：使用已有工具下载发行包；在 MoonBit 中开发应用则安装库。二者无需互相安装。

## 使用发行包

1. 从 [GitHub Releases](https://github.com/Charles67676767/MoonValve/releases) 下载匹配平台的 ZIP 和 `.sha256`，不要下载 Source code ZIP 当作可执行程序。
2. 核对 SHA-256 后解压，保持目录完整。Windows x64 使用 `moonvalve.exe`；Linux x64 使用 `./moonvalve`。目前没有验证 macOS、ARM 或旧系统。
3. 在解压目录运行以下命令。Windows PowerShell 将 `./moonvalve` 换成 `./moonvalve.exe`。

```sh
./moonvalve version
./moonvalve capabilities
./moonvalve parse fixtures/duplicates.vdf
```

预期：version 输出版本与最低 moonc 信息；capabilities 输出支持边界的 JSON；parse 输出有序条目数组，同名键保持多项。原生程序运行不需要 MoonBit 或 Node。使用本地工作台另需 Node 22+：

```sh
node scripts/serve-editor.cjs
```

打开终端显示的本机地址。工作台生成下载副本，不写回浏览器选择的原文件。较大资源应先查看[支持范围](support.md)，再选择 CLI。

## 安装库

使用 MoonBit 0.10.18+，当前验证工具链为 0.10.18+6c83a7f62 和同版本标准库。在已有 MoonBit 项目运行 `moon add Charles67676767/moonvalve`，按[安装指南](publishing.md)导入包；完整可运行示例位于 examples/demo。

## 接下来

- 修改配置并恢复：[配置流程](workflows.md)。
- 检查静态依赖和打包：[模组资源流程](workflows.md)。
- 维护 PO 和语言编码：[翻译流程](workflows.md)。
- 操作失败：[错误与恢复](errors.md)。
- 从源码构建及质量验证：[验证指南](validation.md)。

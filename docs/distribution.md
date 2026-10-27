# 版本与发行包

`moonvalve version` 或 `moonvalve --version` 输出产品名、版本和最低 moonc 版本。打包脚本要求命令行版本与 moon.mod 一致，构建清单另记录对应提交与平台。

```sh
moon build --target js --release
moon build --target native --release
node scripts/build-editor.cjs
npm ci --ignore-scripts --prefix extensions/vscode
node scripts/package-extension.cjs
node scripts/package.cjs
python scripts/test-package.py
```

输出位于 `_build/packages/`，包括平台 ZIP、其 SHA-256 校验文件及目录形式的包。打包目录已存在时拒绝覆盖，应从干净构建目录运行。

包包含原生 CLI、Node CLI、已编译的本地工作台、可安装 VSIX 扩展及其适配源码、说明文档、合成夹具、公开接口清单、许可证、构建信息及逐文件校验和。原生 CLI 运行无需 Node；本地工作台的静态服务使用 Node 22 或更高版本。解压后运行 README.txt 中的命令即可使用。

GitHub CI 在 Linux x64 和 Windows x64 完成测试后生成下载制品，Actions 页面可下载对应 artifact。它们属于平台工具构建；Mooncakes 另行发布可复用源码模块，安装验证见 [发布与安装](publishing.md)。运行环境要求以构建平台为准，不声明支持尚未测试的架构或较旧系统。

包内附 MoonBit 标准库的 Apache-2.0 许可证与原始 NOTICE，以及原生运行时说明。Python/.NET 参考库和开发工具不随产品打包。

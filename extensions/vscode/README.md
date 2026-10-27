# MoonValve KeyValues

MoonBit 语言服务器为 KV1 提供诊断、文档符号、折叠、引用跳转、文件链接、补全、悬浮信息与格式化；文本 KV3 提供诊断和格式化。

安装：先取得 MoonValve 原生程序，在 VS Code 中执行 **Extensions: Install from VSIX**，选择 `moonvalve-0.5.0.vsix`。在用户设置中将 `moonvalve.serverPath` 指向程序的绝对路径；默认参数为 `["lsp"]`。也可以将 serverPath 设为 Node.js，serverArgs 设为 `["/path/to/moonvalve.cjs", "lsp"]`。改变配置后重新加载窗口。

打开 `.vdf`、`.acf`、`.res`、`.kv` 或 `.kv3` 文件即可使用。其他扩展名可手动选择 Valve KeyValues 语言。扩展只在可信工作区启动；服务进程使用参数数组启动，不经过 shell。

引用解析只使用客户端提供的本地工作区文件。最多缓存 64 份文件、合计 16 MiB，单文件最多 8 MiB；未提供的引用目标不会自动读取。UTF-16 增量修改保留未保存内容。KV1 含条件或文件指令时拒绝格式化，避免丢失语义；KV3 规范化会替换原有注释和排版，不支持二进制 KV3。

从源码打包：在本目录运行 `npm ci --ignore-scripts`，再运行 `npm exec -- vsce package --no-dependencies --out ../../_build/moonvalve-0.5.0.vsix`。打包工具仅为开发依赖；扩展运行时不依赖 npm 包。打包方法遵循 [VS Code 官方文档](https://code.visualstudio.com/api/working-with-extensions/publishing-extension)。未发布到扩展商店。

真实主机验收：在仓库根运行 `node scripts/test-vscode.cjs`。脚本在 `_build/vscode-e2e` 中安装 VSIX、设置专用服务器路径、打开夹具工作区，并通过真实 VS Code 命令检查 16 项功能；结果为 `results.json`。用户日常的配置和扩展目录不受影响。需要先构建原生 CLI 和 VSIX；可通过 `MOONVALVE_VSCODE_EXECUTABLE` 指定已有 VS Code，否则使用本机标准安装或微软官方固定版本下载。

0.5 支持文件与目录重命名时更新引用、重算相对路径，并报告带引用链的循环和已确认缺失目标。未保存文档参与分析；工作区超过缓存上限或载入失败时提示引用更新不完整。参考文本无法解析时不生成引用修改。未加载目标不会被误报缺失。完整限制见[进阶说明](../../docs/advanced.md)。

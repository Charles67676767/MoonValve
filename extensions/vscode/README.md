# MoonValve KeyValues

MoonBit 语言服务器为 KV1 提供诊断、文档符号、折叠、引用跳转、文件链接、补全、悬浮信息与格式化；文本 KV3 提供诊断和格式化。

安装：先取得 MoonValve 原生程序，在 VS Code 中执行 **Extensions: Install from VSIX**，选择 `moonvalve-0.4.0.vsix`。在设置中将 `moonvalve.serverPath` 指向程序的绝对路径；默认参数为 `["lsp"]`。也可以将 serverPath 设为 Node.js，serverArgs 设为 `["/path/to/moonvalve.cjs", "lsp"]`。改变配置后重新加载窗口。

打开 `.vdf`、`.acf`、`.res`、`.kv` 或 `.kv3` 文件即可使用。其他扩展名可手动选择 Valve KeyValues 语言。扩展只在可信工作区启动；服务进程使用参数数组启动，不经过 shell。

引用解析只使用客户端提供的本地工作区文件。最多缓存 64 份文件、合计 16 MiB，单文件最多 8 MiB；未提供的引用目标不会自动读取。UTF-16 增量修改保留未保存内容。KV1 含条件或文件指令时拒绝格式化，避免丢失语义；KV3 规范化会替换原有注释和排版，不支持二进制 KV3。

从源码打包：在本目录运行 `npm ci --ignore-scripts`，再运行 `npm exec -- vsce package --no-dependencies --out ../../_build/moonvalve-0.4.0.vsix`。打包工具仅为开发依赖；扩展运行时不依赖 npm 包。打包方法遵循 [VS Code 官方文档](https://code.visualstudio.com/api/working-with-extensions/publishing-extension)。未发布到扩展商店。

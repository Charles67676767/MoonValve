# 验收路径与证据范围

本页区分自动检查的事实和需要目标程序验证的事项。测试通过不等于所有格式、所有游戏或所有规模均已覆盖。

| 承诺 | 自动证据入口 | 明确不证明的事项 |
|---|---|---|
| 支持范围一致 | generate-capabilities.cjs --check；test-recovery.cjs 比较真实 CLI 输出 | 每个组合都存在真实生产样本 |
| 旧公开接口兼容 | check-api.cjs；保留0.4—0.8原始基线哈希 | 仅签名检查不能证明全部行为兼容 |
| 输入/输出结果正确 | 四后端 MoonBit 测试；check-binary-kv3.cjs；check-assets.cjs | 未覆盖的版本和未知扩展类型 |
| 真实资源可重读 | fetch-resource-fixtures.cjs；check-resource-fixtures.cjs；固定九份样本 | 任意资源完整重写、引擎加载 |
| 失败不留下部分产物 | test-recovery.cjs；test-cli.cjs；run-workflows.cjs；POSIX test-write-failure.py | 断电、内核故障等环境级灾难恢复 |
| 浏览器输入与输出对应 | test-browser.cjs：坏文件、输入锁定、失效模型、真实下载和 Worker恢复 | 所有浏览器/移动设备支持 |
| 三类任务可复现 | run-workflows.cjs all，JS与原生 | 合成纹理可渲染、模组实际可运行 |
| 异常输入有界且可重放 | fuzz-assets.cjs；10秒无进展/120秒总预算；192MiB V8堆 | 操作系统总内存硬上限或穷尽式安全证明 |
| 发布产物可直接使用 | test-package.py；真实注册表消费者；GitHub Release 校验和 | 未测试平台和架构 |

## 固定原始资源回归

```sh
node scripts/fetch-resource-fixtures.cjs
dotnet restore tools/reference-resources/Reference.csproj --locked-mode
dotnet build tools/reference-resources/Reference.csproj --no-restore -c Release
```

获取脚本依据 fixtures/upstream/resource-manifest.json 中的固定提交、文件路径、长度与 SHA-256 下载到忽略的 `_build/reference-resources`，已有缓存也重新校验。原文件不进入源码包、发行包或上传制品。目录准备好后：

```sh
# POSIX shell
MOONVALVE_RESOURCE_FIXTURES=_build/reference-resources node scripts/check-resource-fixtures.cjs
```

PowerShell 使用 `$env:MOONVALVE_RESOURCE_FIXTURES='_build/reference-resources'` 后执行同一 Node 命令。需要 .NET10；获取原始上游文件需curl与网络（Windows10/11和CI镜像已提供curl，可使用HTTPS_PROXY配置代理），离线时可使用哈希相同的缓存。原始游戏资产不单独声称拥有再分发许可；项目仅保存来源清单。

## 异常输入重放

`node scripts/fuzz-assets.cjs` 使用固定种子生成变异输入。工作进程超时、异常或性质断言失败时，监督进程保存最后输入到 `_build/fuzz-assets-failure.json`。运行 `node scripts/fuzz-assets.cjs --replay _build/fuzz-assets-failure.json` 在同样预算下重放；启动环境本身失败则先处理其错误，可能尚无可重放输入。

## 目标程序验证记录

当前没有自动游戏加载测试。实际采用时，应记录游戏/工具名称及版本、源样本来源与哈希、执行的操作、目标程序加载结果、发现的问题和恢复方式。能被参考解析器重读，只记为 interop；只有实际目标程序验证后才能记为 runtime。不要用合成流程或截图代替运行结果。

# 发布与独立安装

模块：`Charles67676767/moonvalve`。0.4.0 是首个 Mooncakes 发布版本；0.4.1 补充公开 API 兼容约定、实际配置回归和真实编辑器验收工具。0.5.0 增加 KV3 原文局部编辑、工程字段修改和跨文件编辑器维护。包的版本列表可在 [Mooncakes](https://mooncakes.io/docs/Charles67676767/moonvalve/) 查看。

## 安装核心库

在自己的 MoonBit 项目中运行：

```sh
moon add Charles67676767/moonvalve@0.5.0
```

在调用包的 `moon.pkg` 中添加：

```moonbit
import { "Charles67676767/moonvalve" @valve }
```

然后可调用 `@valve.parse`、`@valve.parse_preserving`、`@valve.parse_kv3` 等公开接口。完整可运行用法见 examples/，公开签名见 `pkg.generated.mbti`。

## 独立注册表消费者

```sh
node scripts/test-registry.cjs 0.5.0
```

脚本在系统临时目录建立全新模块，只声明 Mooncakes 版本依赖，不创建 `moon.work`，不指向仓库源码。刷新注册表后核对实际下载模块的版本及来源路径，再在 wasm、wasm-gc、JS、native 四后端运行：精确 Int64、重复项查询、保留原文编辑、移动复制、KV3 类型模型、多文件重构和 LSP 初始化。成功结果写入被忽略的 `_build/registry-check-VERSION.json`。

这与 `integration/consumer` 的源码工作区示例不同：前者验证已发布的可安装包，后者供源码开发和调试使用。原生后端需要 C 编译器。

## 发布核对

发布前运行四后端检查与测试、集成检查、`moon info`、`node scripts/check-api.cjs`、`moon package --list` 以及 `python scripts/check-publish.py`，确认包内容、许可证和版本。使用 `moon whoami` 核对发布账号为 Charles67676767；账号不符时先通过 `moon login` 的 GitHub 流程切换。

`moon publish --dry-run` 只进行服务端预检。当前固定工具链可能把服务端明确返回的 `202 Accepted / Dry run completed successfully` 报为非零退出；这条成功文本不表示已经发布。正式 `moon publish` 应返回成功，再查询公开版本并运行上述独立消费者。不要只根据本地生成 ZIP 或预检文本宣布发布完成。

认证文件及本机配置不属于发布内容。GitHub 与 Mooncakes 使用同一提交的源码，版本发布后保持不可覆盖。

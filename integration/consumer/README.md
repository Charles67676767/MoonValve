# 独立模块接入示例

本目录是独立 MoonBit 模块，通过 `moon.work` 引用仓库根的源码模块，不要求 Mooncakes 已发布。

```sh
moon -C integration/consumer run cmd/main --target js
```

输出为将第二个 tag 修改成 keyboard 的配置；构建 ID 读取为 Int64 并验证精确值。将此模式用于其他项目时，在自己的工作区中列出应用模块与 MoonValve 源码模块，再在应用的 moon.mod 中声明依赖，在包配置中导入库。Mooncakes 发布后可改为普通版本依赖。

# 三条可复现任务流程

样本在 examples/workflows，全部为合成数据。模组中的 `.vtf` 是不透明字节复制样本，不是可渲染纹理。三个流程验证工具链和数据结果，不声称在游戏中加载通过。

## 运行方式

从源码运行时，先在仓库根目录构建：

```sh
moon build --target js --release
moon build --target native --release
node scripts/run-workflows.cjs all
node scripts/run-workflows.cjs all --native
```

在已解压的发行包目录也可以运行上述两条 `node scripts/run-workflows.cjs` 命令：它会选择包中的 JavaScript / 原生 CLI，无需再次构建。执行辅助脚本需 Node 22+。

每次创建独立的 `_build/workflows-*` 目录，保留产物和 `results.json`；不改示例文件。要指定目录，添加 `--output NEW-DIRECTORY`，已有目录会被拒绝。脚本调用的 CLI、输入文件和断言均可在 scripts/run-workflows.cjs 中查看。

## 配置维护

```sh
node scripts/run-workflows.cjs config
```

以 config.vdf 和 edit.json 为输入。流程先执行 edit --dry-run，检查原文未变；再 edit --in-place，检查 `.bak` 与原字节一致，以及新配置可重读。随后用不同修改验证已有备份阻止覆盖，最后从备份恢复并逐字节比较。

实际文件操作前先复制到工作目录。发生已有备份错误时，先确认并另存两份文件，再决定下一次操作；不要为了通过命令而直接删除唯一备份。Windows PowerShell 恢复副本可用 `Copy-Item -LiteralPath FILE.bak -Destination FILE`，恢复后再次 parse。

## 模组资源检查与打包

```sh
node scripts/run-workflows.cjs mod
```

从 Patch 材质追踪基材质和纹理路径，保存依赖报告；严格导出 VPK，执行文件 CRC32 检查，提取到新目录，逐字节核对三个文件。再次提取到已有目录必须被拒绝。删除纹理后再次严格导出应失败，且不得产生目标 ZIP。

真实模组使用时，审查未知格式、动态引用和基础游戏挂载来源。静态闭包不检查 BSP/MDL 内部全部依赖，也不检查引擎能否渲染结果。VPK CRC32 通过不代表 v2 签名或所有归档元数据验证通过。

## 翻译维护

```sh
node scripts/run-workflows.cjs translation
```

读取源语言 → 导出 POT → 填入带相同 `%s1` 的译文 → 导回 UTF-16LE → 检查 BOM、令牌与文本。随后故意把 `%s1` 改成 `%d1`，命令应失败并且不输出语言内容。更新源文后，旧译文应标为 fuzzy，未复核前导入应被拒绝。

实际翻译还需在目标程序确认字体、换行和显示宽度。该环节没有自动化游戏运行证据；检查通过只表明编码、令牌和配置的占位符规则通过。

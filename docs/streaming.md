# 流式文件处理

以下命令适用于原生和 Node CLI：

```sh
moonvalve stream-json large.vdf > events.jsonl
moonvalve stream-query large.vdf root resource_path > paths.jsonl
moonvalve stream-csv large.vdf > values.csv
moonvalve stream-format large.vdf > formatted.vdf
moonvalve stream-query large.vdf root key --max-bytes 268435456 --literal
```

输入可为文件名或 `-`。宿主每次读取至多 65536 字节，直接交给严格 UTF-8 增量解析器；事件处理和文本写出使用 MoonBit，不构建完整文档树。状态规模随块、最长 token 和对象深度变化，不随完整条目列表增长。输出逐条写入，Node 宿主对慢速管道暂时不可写的情况等待重试，不把所有结果积存在输出队列中。

默认字节预算 64 MiB，`--max-bytes` 可设为 1–1,073,741,824；全局字符预算等于字节预算，总条目上限 10,000,000，token 上限 1,048,576 个字符，深度上限 128。普通非流式命令仍维持原来的更小预算。

`stream-json` 输出 JSON Lines：pair、begin、end 带 `path`；每一层含 `key` 与 `index`，index 是该对象中所有条目的从零开始的位置，不是同名项序号。条件事件含原始 `key` 与 `expression`，按原文事件顺序交付，可能先于对应值；它不是规范化后的树结构。

`stream-query` 仅匹配完整的标量键路径，遍历所有同名对象和同名键，每次匹配输出一条带原始路径的 pair 记录；对象值不累积输出，未匹配时成功且不输出。它和 `stream-csv` 都是**未进行条件求值、未展开引用**的原文标量视图，不能用来推断某平台上的最终配置。CSV 包含 path、value 两列，字段按 CSV 引号规则转义；path 为上述路径数组的 JSON 文本。

`stream-format` 输出等价的无条件 KV1 规范文本，保留重复键与顺序，去掉注释和原始排版。条件事件和根级 include/base 会明确报错；需要先通过文档接口求值或展开引用。

流式输出可能在后续语法、UTF-8、预算或写入错误出现前已经产生部分结果。只有退出码 0 才表示完整成功；需要可靠发布输出时，应先写临时目标、检查成功后再替换。命令不提供原地覆盖参数。关闭管道或中断进程会终止处理；已输出的内容不回滚。

复现大文件与慢接收端验证：

```sh
node scripts/test-cli.cjs
node scripts/test-cli.cjs --native
node scripts/test-stream-pipe.cjs
node scripts/test-stream-pipe.cjs --native
```

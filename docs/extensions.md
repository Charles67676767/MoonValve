# 扩展 API

## 有序编辑

`Document::edit(path, operation)` 返回新文档，不修改原文档数组。路径元素为 `Selector { key, occurrence }`，同名键的 occurrence 从 0 开始。操作包括 `Replace(Value)`、`Remove`、`Rename(String)` 和向对象插入条目的 `Insert(index, Entry)`。

空路径选择文档根对象；根不能删除、重命名或替换成文本。不存在的键、负 occurrence、跨越文本的路径及越界插入均返回 `EditError`。插入按条目位置进行，不覆盖同名项。

## JSON 双向转换

`document_from_json` 和 `parse_json_document` 导入 `to_json` 输出的有序条目数组。值只能是字符串或下一层条目数组；缺失字段、额外字段和数值等不兼容类型会被拒绝。资源限制沿用 `ParseOptions`。JSON 文本本身使用标准 JSON 对象键语义；KV1 重复项通过条目数组表示。

CLI：`moon run cmd/main --target js -- from-json data.json`。输出为可重新解析的 KV1。

## 平台条件

`ParseOptions.conditions = Some(["WIN32"])` 开启显式条件求值；`None` 保持拒绝条件的严格模式。支持 `$NAME`、`!`、`&&`、`||` 和括号，未知变量为假，名称不区分 ASCII 大小写。条件可以出现在键之后、等号之后及值之后；同一条目的最后一个条件决定保留与否。等号后的条件匹配时替换先前同名项。被过滤的分支仍进行语法检查并计入资源预算。表达式最多 4096 字符、64 层。

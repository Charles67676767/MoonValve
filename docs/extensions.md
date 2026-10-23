# 扩展 API

## 有序编辑

`Document::edit(path, operation)` 返回新文档，不修改原文档数组。路径元素为 `Selector { key, occurrence }`，同名键的 occurrence 从 0 开始。操作包括 `Replace(Value)`、`Remove`、`Rename(String)` 和向对象插入条目的 `Insert(index, Entry)`。

空路径选择文档根对象；根不能删除、重命名或替换成文本。不存在的键、负 occurrence、跨越文本的路径及越界插入均返回 `EditError`。插入按条目位置进行，不覆盖同名项。

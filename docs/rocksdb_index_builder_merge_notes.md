# index_builder.cc 合并说明（ShortenedIndexBuilder::AddIndexEntry）

> **来源**：原 `rocksdb-sst-ext/INDEX_BUILDER_MERGE_NOTES.md`。  
> **现状**：时空扩展已**直接合入** `D:\Project\rocksdb`；接口以当前源码为准，本文仅作历史合并思路参考。

---

## 1. `index_builder.h` 必须先改的签名（示例）

在 `ShortenedIndexBuilder`（或你实际用于 `kBinarySearch` 的 Builder）里，把 `AddIndexEntry` 扩展为携带 `SpatioTemporalBlockMeta`：

```cpp
#include "table/index_value_codec.h"

// 由 BlockBasedTableBuilder 在每次 data block 封块时传入统计结果。
virtual Status AddIndexEntry(
    std::string* last_key_in_current_block,
    const Slice* first_key_in_next_block,
    const BlockHandle& block_handle,
    const SpatioTemporalBlockMeta& st_meta) override;
```

原先三参数重载可保留为 `= default` 元数据全 0（仅用于过渡），但正式路径应始终传入真实 `st_meta`。

## 2. `index_builder.cc` 中 `AddIndexEntry` 体：替换 value 编码

**原逻辑（概念上）**多为：

```cpp
std::string handle_encoding;
block_handle.EncodeTo(&handle_encoding);
index_block_builder.Add(..., handle_encoding);
```

**改为**：

```cpp
std::string value_encoding;
Status es = EncodeSpatioTemporalIndexValue(&value_encoding, block_handle, st_meta);
if (!es.ok()) {
  return es;
}
// 后续仍用 value_encoding 作为 index block 的 value 写入（separator key 不变）
```

即：**唯一必须改动的数据路径**是「索引 value 从纯 BlockHandle 变为扩展编码」；separator key 的生成逻辑保持 RocksDB 原样。

## 3. `BlockBasedTableBuilder` 调用侧

在 `table/block_based_table_builder.cc` 每次 `FlushDataBlock` / `WriteBlock` 完成并得到 `BlockHandle` 时，你已经知道该块的 `SpatioTemporalBlockMeta`（按你的固定世界外框单遍策略计算），将其传入 `index_builder_->AddIndexEntry(..., st_meta)`。

## 4. 编译

把 `index_value_codec.cc` 加入 `CMakeLists.txt` / `TARGET_OBJECTS`（与 `index_builder.cc` 同一 library 目标）。

## 5. 读路径

`block_based_table_reader` 解析 index value 时，用 `DecodeSpatioTemporalIndexValue` 替代仅 `BlockHandle::DecodeFrom`（另任务）。

# RocksDB 时空索引扩展（实验）— 修改说明

本文档整理在 **`D:\Project\rocksdb`** 上对官方 RocksDB 所做的改造，按**模块**归类，便于查阅与后续合并/升级。

---

## 1. 总览

| 目标 | 说明 |
|------|------|
| 功能 | 在 **BlockBasedTable** 主索引的 **IndexValue** 标准编码之后，可选追加 **固定长度** 的时空摘要（`SpatioTemporalBlockMeta`）。 |
| 开关 | `BlockBasedTableOptions::experimental_spatio_temporal_meta_in_index_value`（默认 `false`，见 `include/rocksdb/table.h`）。 |
| 读写 | **写库与读库必须一致**；旧 SST 无尾巴时，读侧若打开开关可能导致解析异常。 |
| 辅助说明 | 早期补丁笔记见 **`docs/rocksdb_index_builder_merge_notes.md`**；实现已**直接合入** `rocksdb` 树内，以本文与源码为准。 |

---

## 2. 新增文件

| 文件 | 职责 |
|------|------|
| `table/st_meta_index_extension.h` | 定义 `SpatioTemporalBlockMeta` 与 `kSpatioTemporalIndexTailBytes()`，避免 `format.h` 与 `index_value_codec` 循环依赖。 |
| `table/index_value_codec.h` / `table/index_value_codec.cc` | 全量 `BlockHandle+尾巴` 编解码（测试/工具向）；**追加/仅解析尾巴**的 `AppendSpatioTemporalIndexTail`、`DecodeSpatioTemporalIndexTail`。 |

**构建**：`table/index_value_codec.cc` 已加入根目录 **`CMakeLists.txt`** 的 `LIB_SOURCES` 列表（与 `index_builder.cc` 同属 `rocksdb` 目标）。

---

## 3. 公共选项（API 模块）

| 位置 | 修改 |
|------|------|
| `include/rocksdb/table.h` | 在 `BlockBasedTableOptions` 中增加 `bool experimental_spatio_temporal_meta_in_index_value = false;` 及注释。 |

应用侧在 `Options` 上通过 `NewBlockBasedTableFactory(table_options)` 传入该 `table_options` 即可。

---

## 4. 表格式与 IndexValue（`table/format`）

| 文件 | 修改 |
|------|------|
| `table/format.h` | `#include "table/st_meta_index_extension.h"`；`IndexValue` 增加 `has_st_meta`、`st_meta`；`EncodeTo` / `DecodeFrom` 增加可选参数（默认保持旧行为）。 |
| `table/format.cc` | `EncodeTo` 在标准 IndexValue 编码后按需 `AppendSpatioTemporalIndexTail`；`DecodeFrom` 在标准解码后按需 `DecodeSpatioTemporalIndexTail`；`#include "table/index_value_codec.h"`。 |

参数命名注意：`EncodeTo` 最后一参为 `st_meta_arg`，避免与成员 `st_meta` 冲突（MSVC `/WX`）。

---

## 5. 索引构建（`table/block_based/index_builder`）

| 文件 | 修改 |
|------|------|
| `table/block_based/index_builder.h` | `#include "table/st_meta_index_extension.h"`；`ShortenedIndexBuilder` 增加 `attach_st_meta_in_index_value_` 及构造参数；`AddIndexEntryImpl` 中 `IndexValue::EncodeTo(..., append_st, st_ptr)`；`ShortenedPreparedIndexEntry::st_meta`；`PrepareIndexEntry` / `FinishIndexEntry` / `AddIndexEntry` 与 `FinalizeBlockStMetaForDataBlock` 贯通；基类 `AddIndexEntry` 带 `SpatioTemporalBlockMeta` 参数（默认 `{}`）；`HashIndexBuilder` / `PartitionedIndexBuilder` / `UserDefinedIndexBuilderWrapper` 签名转发。 |
| `table/block_based/index_builder.cc` | `CreateIndexBuilder` / `MakeNewSubIndexBuilder` 传入 `table_opt.experimental_spatio_temporal_meta_in_index_value`；`PartitionedIndexBuilder::AddIndexEntry` 转发 `st_meta`；`MergeInternalKeyIntoBlockStMeta`（实验：按 user key 长度统计）与 `FinalizeBlockStMetaForDataBlock`。 |
| `table/block_based/user_defined_index_wrapper.h` | `AddIndexEntry` 增加 `st_meta` 并转发内部 builder。 |
| `table/block_based/partitioned_filter_block_test.cc` | 测试里 `AddIndexEntry(..., {})` 补齐最后一参。 |

---

## 6. 索引块迭代与 Block（`table/block_based/block`）

| 文件 | 修改 |
|------|------|
| `table/block_based/block.h` | `IndexBlockIter::Initialize` 增加 `decode_index_st_meta_tail`；成员 `decode_index_st_meta_tail_`；`value()` 与 delta 路径调用 `DecodeFrom(..., decode_st_meta_tail_)`；`Block::NewIndexIterator` 增加最后一参 `decode_index_st_meta_tail`（默认 `false`）。 |
| `table/block_based/block.cc` | `NewIndexIterator` 将标志传入 `Initialize`；`DecodeCurrentValue` 中 `decoded_value_.DecodeFrom(..., decode_index_st_meta_tail_)`。 |

---

## 7. 表读路径（Index Iterator 创建）

在创建 **数据主索引** 的 `IndexBlockIter` 时，将 `rep->table_options.experimental_spatio_temporal_meta_in_index_value` 传入 `Block::NewIndexIterator`（最后一参）。

| 文件 |
|------|
| `table/block_based/block_based_table_reader.cc`（含 `InitBlockIterator`、部分直接 `NewIndexIterator` 路径） |
| `table/block_based/binary_search_index_reader.cc` |
| `table/block_based/hash_index_reader.cc` |
| `table/block_based/partitioned_index_reader.cc` |

**说明**：**Filter 分区索引**等仍使用默认 `decode_index_st_meta_tail = false`，因其实际 value 格式不是本实验的数据主索引格式。

---

## 8. 写路径（Table Builder）

| 文件 | 修改 |
|------|------|
| `table/block_based/block_based_table_builder.cc` | `EmitBlock` 中 `AddIndexEntry` 使用默认 `st_meta`（`{}`）；具体 meta 在 `ShortenedIndexBuilder` 内由 key 路径计算。 |

---

## 9. Windows 构建环境（与本机相关，非逻辑模块）

以下在 **`D:\Project\rocksdb`** 上为顺利编译所做，**不属于**时空功能本身，但建议记录在案：

| 项 | 说明 |
|----|------|
| 生成器 | 本机为 **Visual Studio 2026**，CMake 使用 `Visual Studio 18 2026` 或 **Ninja + `vcvars64.bat`**。 |
| `Directory.Build.props` | 官方仓库若存在且指向 ccache，而本机无 `ccache.exe`，可改名为 `Directory.Build.props.off` 以免 MSBuild 找不到编译器。 |
| 编码 / 并行 | Ninja + `CMAKE_CXX_FLAGS=/utf-8`；若 VS 生成器遇 C1041，可优先用 Ninja。 |

---

## 10. 历史 `rocksdb-sst-ext` 仓库

原独立目录中的合并笔记与代码片段已迁入 **`docs/rocksdb_index_builder_merge_notes.md`**；**实现以 `rocksdb/table/` 下当前源码为准**（接口可能已演进为 `Prepare/FinishIndexEntry` 等并行路径）。**项目目录总览**见 **`docs/project_layout.md`**。

---

## 11. 实验步骤（摘要）

1. 编译 fork：`D:\Project\rocksdb\build` 下 `cmake` + `ninja rocksdb`。  
2. 示例工程 **`rocks-demo`** 已通过 CMake 直接链接 **`../rocksdb/build/rocksdb.lib`** 与 **`../rocksdb/include`**（见该目录下 `CMakeLists.txt`）。配置前若仍留有旧的 `rocks-demo/build`（曾指向 vcpkg），请删除后重新 CMake 配置。  
3. 打开 `experimental_spatio_temporal_meta_in_index_value = true`，新建或清空路径写库再读。  
4. 在 **内部**使用 `IndexValue::has_st_meta` / `st_meta` 或自写 TableReader 工具验证；`DB::Get` 不直接暴露索引 value。

---

## 12. 后续可扩展方向

- 将 `MergeInternalKeyIntoBlockStMeta` 替换为真实 **user key → 时空字段** 解析。  
- 在 **OPTIONS** / `options_helper` 中注册选项字符串（若需要 `SetOptions` 动态配置）。  
- 评估 **partitioned / hash** 等索引类型是否也要统一尾巴语义与兼容策略。

---

## 13. Git 仓库与推送到 GitHub

本机 `D:\Project` 已初始化为 **单一 Git 仓库**（monorepo），根目录 `.gitignore` **不包含** `data/`（本地数据集与实验产物可能达数 GB，请勿提交）。

在 [GitHub](https://github.com/husky926) 上 **新建空仓库**（示例名：`st-rocksdb-project`），然后在本机执行：

```powershell
cd D:\Project
git remote add origin https://github.com/husky926/<YOUR_REPO_NAME>.git
git branch -M main
git push -u origin main
```

若曾单独克隆过 `rocksdb` 子目录：当前仓库已 **去掉** `rocksdb/`、`rocksdb_vanilla/` 内嵌的 `.git`，以便由根仓库统一追踪；上游 RocksDB 历史请自行从 [facebook/rocksdb](https://github.com/facebook/rocksdb) 对照。

---

*文档生成对应仓库状态：以 `D:\Project\rocksdb` 中已提交/未提交的本地修改为准；若你后续 `git pull` 上游，需按冲突重新合并上述模块。*

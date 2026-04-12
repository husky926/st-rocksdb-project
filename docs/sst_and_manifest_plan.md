# SSTable 组织与后续 Manifest 改造（路线图）

本文配合「时空摘要」实验：**A = 索引尾巴开销**，**B = 块级摘要在读路径上的收益**（见 `tools/st_meta_eval.ps1`）。

---

## 1. 当前 SST 里摘要放在哪

| 层次 | 内容 | 作用 |
|------|------|------|
| **单 SST 文件** | Header、Footer、Meta Index、**数据块**、**索引块**、Filter 等 | 标准 BlockBasedTable |
| **主索引每条 value** | `BlockHandle` + 可选 **32B 时空尾**（`t_min/max`，MBR，`bitmap`） | **块级**时空包络；读路径可在打开数据块前做相交判断 |

要点：**摘要粒度是「数据块」**，不是整条 SST，也不是 LSM 的「文件级」元数据。

---

## 2. 为何还要动 Manifest（动机）

- **块级尾**：只有 **打开该 SST 并读到主索引** 之后才能利用；无法 **在 Version 层直接跳过整文件**。
- **Manifest / Version**：维护 **每个 SST 文件** 的 `FileMetaData`（层号、大小、smallest/largest key、seqno 等），是 **LevelIterator / compaction 选文件** 的入口。
- **改造目标**：在 **不打开文件** 或 **打开前**，用 **文件级** 时空摘要（由块级聚合或单独维护）做 **整文件过滤**，与现有块级尾 **互补**：
  - **粗**：Manifest / 文件级 → 少 `OpenTable`、少读 index/filter。
  - **细**：SST 内索引尾 → 少读 data block。

---

## 3. 建议的 SST「组织」原则（为 Manifest 铺路）

1. **块级尾（已实现）**  
   - 保持 **固定长度**、**与 BlockHandle 拼接** 的编码，便于索引迭代器统一 `DecodeFrom`。  
   - User key 需 **可解析** 出参与聚合的 `t`、`(x,y)`（当前 `0xE5` 前缀方案）。

2. **文件级摘要（进行中）**  
   - 对每个 SST，在 **Flush/Compaction 结束** 时计算：  
     `file_t_min/max`、`file_mbr`、`file_bitmap`（例如块级 bitmap 的 OR，或独立粗网格）。  
   - **当前实验实现**：与块级 IndexValue 尾同构的 **`SpatioTemporalBlockMeta` 全文件并集** → 表属性 **`rocksdb.experimental.st_file_bounds`** → **`FileMetaData::has_st_file_meta` / `st_file_meta`** → MANIFEST **`NewFileCustomTag::kExperimentalStFileBounds` (17)**（旧二进制可忽略）。读路径 **Version 层剪枝** 仍为下一步。  
   - **存放位置候选**：  
     - **A**：写入 `FileMetaData` 新字段，经 **Manifest / VersionEdit** 持久化（与 `CURRENT` 一致演进）。  
     - **B**：写入 SST **属性**（TableProperties）或单独 meta block，Manifest 只存 **偏移或校验**（实现快，跨工具可见性差）。  
   - 推荐长期：**A + Manifest**，与层级裁剪、备份恢复一致。

3. **兼容性**  
   - 旧文件无文件级域 → 读路径 **保守相交**（与块级「无 ST key 用全相交」同理）。  
   - 写路径：新选项打开后才写新 Manifest 字段。

4. **Compaction**  
   - 输出 SST 的文件级摘要 = **输入 SST 摘要的合并**（时间 min/max，MBR 并，bitmap OR），避免全表扫数据块。  
   - **切分策略定稿**见 **§7.6**（合并后时空分裂）：输出 SST 的物理边界与业务时间桶对齐，减轻跨桶索引冗余。

---

## 4. Manifest 侧实现要点（实现顺序建议）

1. 在 `FileMetaData`（或并行结构）增加 **可选** `SpatioTemporalFileMeta`（或与块结构同构的轻量版）。  
2. `VersionEdit` 序列化/反序列化扩展；**版本号**或 **feature bit** 区分新旧 Manifest。  
3. `Version::GetOverlappingInputs` / `LevelIterator` 构造前：若 `ReadOptions` 带时空查询窗，**过滤无交文件**（与 `experimental_st_prune_scan` 语义对齐，但作用在 **文件级**）。  
4. 单测：无域、有域、混合 Version；与块级尾 **组合** 回归。

---

## 5. 评测分工（与 `st_meta_eval.ps1` 对应）

| 部分 | 工具 | 回答的问题 |
|------|------|------------|
| **A** | `st_meta_bench` | 仅多索引尾巴、**不用**块跳过选项时，写 + 随机读的 **相对开销**（OFF vs ON）。 |
| **B** | `st_meta_scan_bench` | ST key + `experimental_st_prune_scan` 下，**选择性前向扫描**相对全表的 **时间与枚举键数**。 |

Manifest 改造完成后，可增加 **C**：同查询窗下 **打开 SST 次数 / TableReader 创建次数** 的对比（需埋点或统计）。

| **C0** | `manifest_bucket_rtree_validate`（`rocks-demo/`，**不链 RocksDB**） | **算法基线**：合成 `FileMetaData`（`t_min/max` + MBR），按 §7.2 **时间桶多挂** + 每桶 **2D R 树**（大桶）或 **线性扫描**（小桶）；与 **暴力（时间∩MBR）** 对比 **集合一致性**；统计 **spatial 候选/去重后**、**brute/indexed** 时间比。高选择性用 **`--query-time-max`**、**`--query-mbr-hw-max`** 缩小查询窗。**读路径合成**：**`--open-ns`** 为每次 `OpenTable` 计费；基线 **opens** = 与查询 **时间相交** 的文件数（假设 Manifest 无文件级 MBR），索引侧 **opens** = **\|结果集\|**（Manifest 上 t+MBR 过滤后）；**`weighted_brute/indexed`**（`>1` 表示计入 Open 后索引更优）。 |

---

## 6. 文档与代码索引

- 块级尾编码：`rocksdb/table/st_meta_index_extension.h`，`table/index_value_codec.*`  
- User key 聚合：`rocksdb/table/st_meta_user_key.*`  
- 读路径块过滤：`ReadOptions::experimental_st_prune_scan`，`block_based_table_iterator.cc`  
- 一键评测：`tools/st_meta_eval.ps1`


## 7. 时间分片与全局索引（设计定稿摘要）

本节把 Manifest 侧方案写成可实现、可写进论文的要点；与 §2–§4 的关系是：**§2–§4 仍是 RocksDB 内改造的通用顺序**，本节补充 **时间桶 + R 树 + 与 Version 一致** 的具体约定。

### 7.1 时间键（Temporal Key）与 `FileMetaData`

- **不采用**系统 Flush 时间；**不**在打开 SST 时实时扫描 user key 抽时间（开销过大）。
- **采用**扩展 `FileMetaData` 的 **`smallest_time` / `largest_time`**（记为 `[T_{min}, T_{max}]`），在 **`TableBuilder::Finish`**（或表元数据定稿时刻）由 **该 SST 内已聚合的轨迹信息** 一次性计算，并经 **Manifest / `VersionEdit`** 持久化。
- **与 user key 中时间字段必须同语义、同编码规则**，且与 **块级 ST summary 的 `t` 定义一致**；否则文件级与块级剪枝会不一致。
- **查询路由**：对候选文件做 ` [T_{qstart}, T_{qend}] \cap [T_{min}, T_{max}] ` 是否非空；再与文件级 MBR（及后续空间索引）组合。

### 7.2 时间桶、跨桶文件与 R 树

- **动机**：Manifest 可重放、版本在内存演进；用 **时间划分多个「小 Manifest」分片（时间桶）** 控制单次加载与索引规模（轨迹数据随时间递增写入）。
- **每桶**维护一棵 **2D R 树**（文件级 MBR）；**时间**以 `FileMetaData` 的 `[T_{min},T_{max}]` 挂在叶子侧元数据上，流程为：**MBR 候选 → 再判时间相交**（与「先空间后时间」的过滤顺序一致）。
- **跨桶**：若某 SST 的 `[T_{min},T_{max}]` 仍跨越多个预设时间桶，全局索引仍允许 **同一 `FileNumber` 在多个桶的 R 树中逻辑多挂载**；**读路径必须按 `FileNumber` 去重**。**主策略**是通过 **§7.6** 的合并后分裂，使输出文件尽量 **单桶内**，从根上减少逻辑副本与索引冗余。

### 7.3 与 `VersionEdit` 一致性与恢复

- **`VersionEdit` 为因果链**：Compaction / Flush 完成产生 `VersionEdit`（删旧文件、增新文件）时，同步触发 **Global Index Observer**，更新各桶 R 树（插入新文件 MBR + 时间元数据，删除旧文件引用）。
- **真理来源（SoT）**：持久化状态以 **Manifest 中的 `FileMetaData`（含扩展时空域）** 为准；**R 树为随版本演进的内存派生视图**。崩溃恢复：**重放 Manifest** → 重建 R 树。
- **原子性的工程含义**：若 R 树另有持久化文件，需规定与 Manifest 的 **fsync 顺序**或 **同一日志混写**；若 R 树 **仅内存、完全由重放重建**，则与「SoT = Manifest」最简一致。

### 7.4 术语：`VersionSubSet`

**非 RocksDB 原生类型**。本文中指 **按时间桶划分的逻辑文件子集**（每桶一棵 R 树、对应一段业务时间轴上的 SST 集合），便于叙述「分片 Manifest ↔ 内存索引」的映射；实现时可用等价结构表达。

### 7.5 边界情况（实现必钉死）

- **空表 / 无有效轨迹段 / 无 ST key 的 SST**：`Finish` 时 `smallest_time`/`largest_time`（及 MBR）取 **sentinel、全范围、或禁止产出** 须明确定义；避免出现 de facto **全时间** 元数据，否则分桶与 R 树剪枝失效。

### 7.6 合并后时空分裂（Post-merge Spatio-temporal Splitting，定稿）

在执行 Compaction 时，**不再**以 RocksDB 原生 **target file size** 作为 **唯一** 输出切分标准，而是采用下述 **三步**，使每个输出 SST 在业务时间与空间包络上保持 **紧凑**，并与 **时间桶** 在逻辑上对齐。

1. **全量重组（Full Reorganization）**  
   Compaction 引擎将选定输入 SST **全量解压**，按 **业务时间（Event Time）** 排序，形成单一的 **轨迹段流**，作为后续切分的有序输入。

2. **动态密度切分（Density-aware Partitioning）**  
   - **时间切断**：当前累积输出的 **时间跨度** 超过预设阈值 $T_{max\_span}$，或 **当前轨迹段** 已进入 **新的预设时间桶**（与全局分桶配置一致）。  
   - **数量 / 空间饱和**：当前正在构建的输出 SST 内 **轨迹段数量** 达到 $N$，或 **文件级 MBR** 的扩张速率 **趋于平缓**（用于抑制「块内空洞」过大、空间包络过松）。

3. **强制对齐切断（Alignment Snap）**  
   当上述任一条件触发时，在 **满足条件的最近一个业务时间戳** 处执行切断：结束当前输出、开始下一个输出，保证切分点落在 **Event Time** 上，而非任意字节偏移。

**输出性质**：每个新产出的 SST 均被约束在 **紧凑** 的 $[T_{min}, T_{max}]$ 与 **空间包络（MBR）** 内；`FileMetaData` 中的 `smallest_time` / `largest_time` 与该边界一致（见 §7.1）。

**收益**：Global Index 中 **R 树叶子与 SSTable** 趋向 **1:1** 的洁净映射，显著减少 **单文件跨多桶** 导致的 **逻辑副本** 与 R 树索引冗余。

### 7.7 实现落点（CompactionJob 输出流）

- 在 **`CompactionJob` 的输出路径**（向 `TableBuilder` / `BuildTable` 写 KV 的流控逻辑）中引入 **Event Time 监测器**：维护当前输出 SST 的 **已接纳 Event Time 区间**、**段计数**、**运行 MBR**（及可选的 MBR 增长斜率指标）。  
- 当 **§7.6** 的切断条件成立时：**立即调用当前 `TableBuilder::Finish()`**（或等价「封表」API），**再开启新的 SST** 继续接收排序后的轨迹段流。  
- **目标**：使 **物理 SST 文件边界** 与 **时间桶边界** 在逻辑上 **对齐**（与仅按字节/`target_file_size` 切分相比，跨桶文件比例应显著下降）。  
- **注意**：该路径与原生 **target_file_size** 可能并存：需定义 **优先级**（例如 Event Time / 桶对齐 **先于** 或 **与** 字节上限 **取先触发者**），并在测试中覆盖「仅时间触发」「仅大小触发」「二者同时」三种情况。

**已实现（验证用最小子集）**：`db/compaction/compaction_outputs.cc` 中 `ShouldStopBeforeEventTime`，由 `ColumnFamilyOptions::experimental_compaction_event_time_*` 控制；在 `ShouldStopBefore` 中 **先于** `output_level == 0` 的提前返回执行，故 **L0 compaction 输出** 也可按 Event Time 切分。键需为 **`0xE5` ST user key**（`TryDecodeSpatioTemporalUserKeyTime`）。对比实验：`rocks-demo/st_meta_compaction_verify`（`--split` 与默认各跑一次；看 **`non_L0` SST 个数**、`per_level` 分布与端点 `t` 跨度；`per_level` 会显示实际落在 L1/L2/… 的分布）。

**Windows**：`st_meta_compaction_verify` 须与 `rocksdb.lib` **同为 Release（/MD）或同为 Debug（/MDd）**，且 **`CMAKE_BUILD_TYPE` 两边要一致**。常见情况一：Debug demo + Release `rocksdb.lib`；情况二：**RocksDB 在仓库内且首次配置未指定类型时，CMake 默认 Debug**，而 rocks-demo 用 Release — 同样是 **`DB::Open` 直接崩**。处理：在 **`rocksdb/build`** 执行 `cmake -G Ninja -DCMAKE_BUILD_TYPE=Release ..`，再 `ninja clean && ninja rocksdb`，然后重编 demo。程序会打印 `rocks-demo CMAKE_BUILD_TYPE=...`；MSVC Debug 构建下另有提示（可用 `ROCKSDB_ALLOW_MSVC_DEBUG_DEMO=1` 跳过，仅当你有意对齐双 Debug 时）。
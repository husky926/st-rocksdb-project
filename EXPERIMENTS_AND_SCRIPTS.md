# 实验与脚本追踪（断链后从这里恢复上下文）

**用途**：上下文丢失或换机器时，不要从零写新文档；以本文件 + `docs/BUILD_AND_EXPERIMENTS.md` 为准，更新时只改这两处并保持互链，避免 HTML/脚本/路径各说各话。

| 文档 | 内容 |
|------|------|
| **本文件**（仓库根目录） | 脚本地图、消融定义与标准、数据目录约定、一致性规则 |
| `docs/BUILD_AND_EXPERIMENTS.md` | Windows 下编译 RocksDB / rocks-demo、建库命令、TSV 字段说明 |
| `docs/VANILLA_ROCKSDB_BASELINE.md` | **官方 RocksDB（Vanilla）基线**：与 fork full / prune 对齐的实验协议与 TSV 约定 |
| `AGENT_HANDOFF.md` | 会话恢复、**查询真值与 bench 差异（§1.0a）**、**Method 级读路径（§8）** |

---

## 0. 实验前标准（开跑前约定）

以下三条为 **正式实验 / 写论文数字前** 的约定；与当前脚本默认值冲突时，**以本节为准** 并回头改脚本或文档。

### 0.1 消融维度与 SST 布局

- **剪枝消融（三个方法项）**——在同一数据集、同一批查询窗、同一 bench 配置下，分别报告三种 **`PruneMode`**（与文档用语对齐）：

| 文档 / 论文 | `PruneMode` | 含义 |
|-------------|-------------|------|
| **Local** | `sst` | SST 内块级 / key 级剪枝为主（文件级可按开关关闭或弱化） |
| **Global** | `manifest` | 文件级（manifest / `st_file_meta`）跳过为主 |
| **Local+Global** | `sst_manifest` | 文件级与 SST 内剪枝组合 |

- **SST 布局（三个规模）— 仅指 Fork 侧**：必须在 **1 个 SST、164 个 SST、按时间分桶的多 SST** 三档 **fork 物理库**上各跑齐上述三种模式，并叠加 **Fork full（F0）** 基线（协议见 `docs/VANILLA_ROCKSDB_BASELINE.md`）。  
  - **与 Vanilla 脱钩**：**Vanilla（V）** 若使用 **原生态 `rocksdb_vanilla`**，则 **不**再为 V **复制**上述三档布局；将 **加工好的轨迹数据** 按 **一种** 灌库流程写入 **单一** 官方 RocksDB 目录，**SST 个数与 compaction 形态交给引擎**。与 fork 各档对比时，**主观测**是 **同一批查询窗上的查询壁钟**（及可选 IO），论文叙事写清 **V = 单一原生态库上的时间**，**不要**暗示「官方也做了 1 / 164 / 多 SST 三档划分」。历史脚本若仍传三个 Vanilla 路径，视为 **过渡**，以 `docs/VANILLA_ROCKSDB_BASELINE.md` **§1.1** 为准。  
  - **第三档的语义（标准）**：按 **事件时间 1 小时**（**3600 秒**）分桶灌库（`st_bucket_ingest_build.exe --bucket-sec 3600`；**一键**：`tools/build_wuxi_segment_third_tier_hourly.ps1`；详 **`docs/BUILD_AND_EXPERIMENTS.md` §4.2**）。成品目录名 **推荐** `verify_wuxi_segment_bucket3600_sst`（语义清晰）。**`*.sst` 个数 `N` 由数据中非空小时桶数决定**，常见 **约七百多**，**不是**固定常数。  
  - **历史目录名** `verify_wuxi_segment_776sst` / `..._736sst` 仅为旧命名；脚本通过 **`tools/wuxi_resolve_third_tier_fork.ps1`** 在缺省时依次尝试 **`bucket3600_sst` → `776sst` → `736sst`**。**论文与表格**写「按 3600s 时间桶的多 SST（`N=` 实测）」，勿把 776/736 当数学结论。

### 0.1a 轨迹查询真值与 bench 谓词（**严格标准，全队统一**）

**业务真值（对外与论文一致）**

- 对象：**轨迹段**由若干**轨迹点**组成；一次查询给定**时空窗** \(W\)。
- **命中（match）** 当且仅当：段内 **至少存在一个采样点** \(p\) 满足 \(p \in W\)（时间 + 空间均在窗内，按你们窗定义实现）。
- **返回**：一旦命中，应返回 **整条轨迹段** 的完整信息（整段一条 KV / 整段 payload），而不是仅窗内点子集。
- **假阳性**：若仅用 **段的 MBR（或 key 内嵌的 t/x/y 包围盒）与 \(W\) 相交** 即算作命中，但 **段内没有任何真实点落在 \(W\) 内**，则视为 **错误**，不得记为正确返回或用于主表结论。

**与当前 `st_meta_read_bench` 的关系（必须知情）**

- 对 **点键 `0xE5`**：`UserKeySpatioTemporalInWindow` 即 **点是否在窗内**，与上述真值一致。
- 对 **段键 `0xE6`**：同一函数在 `rocksdb/table/st_meta_user_key.cc` 中实现为 **段时间区间 ∩ 窗** 且 **段空间 MBR ∩ 查询矩形**（轴对齐相交）。这是 **必要条件不充分**：会产生 **MBR 相交但无点在窗内** 的假阳性。此类键计入的 `full_keys` / `prune_scan keys`、以及 **`-VerifyKVResults`**（比较 full 与 prune 在该谓词下是否一致）**只保证剪枝实现自洽**，**不保证**符合上面的 **点级真值**。
- **Value 形态（工程现状）**：`st_meta_smoke --st-segment-keys` 与 `st_bucket_ingest_build` 在 **`--segment-points-csv`** 下将每段 **全部采样点**（`unix_s, lon, lat`）写入 **V2 value**（见 `rocks-demo/segment_value_codec.hpp`）。**旧库** 可能仍为仅 28 字节的段头；重建段库后 value 才含点列，便于后续 bench 做 **值域 ∃点∈窗** 精判。  
- **正式实验与论文主数字**：在段库上应以 **点级命中** 为金标准；在 bench 尚未升级为 **值域精判（解码 value 中的点列并检验 ∃点∈W）** 或 **点级 KV 金标准** 之前，现有 TSV 中基于 **仅 user key（MBR）** 的列须 **标注为候选/MBR 口径** 或 **不得单独作为主结论**。实现严格指标与 `VerifyKVResults` 扩展为 **点级真值验证** 为后续工程项（见 `AGENT_HANDOFF.md` §1.0a）。

### 0.2 基线（Baseline）：原生 RocksDB — 与 fork 内 full（F0）区分

- **Vanilla（V）**：**上游未改动的 RocksDB**（`rocksdb_vanilla`）+ 与 fork 对齐的 **逻辑数据集**（见 `docs/VANILLA_ROCKSDB_BASELINE.md` **§1.1**）。**不**为 V 做 fork 式的 **1 / 164 / 多 SST** 三库划分；**一次灌入、由引擎决定布局**。测量 **同一 12 窗、同一扫描语义** 下的 **`wall_us`（查询壁钟）** / 可选 IO / 窗内 key 数，作为 **「相对官方」的分母**（对外主结论建议用 `speedup_V_to_prune`）。
- **Fork full（F0）**：当前 `st_meta_read_bench` 的 **full** 路径（`experimental_st_prune_scan` 关闭），用于 **fork 内**「无剪枝 vs 剪枝」：`speedup_F0_to_prune`。**不得**再单独称为「相对官方」。
- **落地顺序**：优先 **从加工数据直接灌单一原生态目录**（`VANILLA` 文档 **§7.1 推荐主路径**）。若需过渡，可对 fork 库做 **Phase 0** 探测或 **Phase 1 副本**；**副本数量与命名不必再跟 fork 三档一一对应**，以 **单一 V 目录 + 同窗查询时间** 为收敛目标。脚本与 TSV 列扩展在协议中分阶段列出；未落地前，现有 sweep 输出仍标注为 fork 内对比。
- **历史说明**：`AGENT_HANDOFF.md` §7「暂缓」曾将 *vanilla 对照* 与 *三模式消融* 分开；现以 **`docs/VANILLA_ROCKSDB_BASELINE.md`** 为统一实验设计入口。

### 0.3 查询窗：固定 12 个，且禁止「空窗」

- **窗个数**：**12** 个时空查询窗（**正式默认**与 `st_validity_experiment_windows_wuxi_stratified12_n4m4w4.csv` 及无锡 HTML 对齐；`random12_cov_s42` 为 legacy）。
- **禁止无轨迹窗**：任一窗若在数据上 **几乎没有落在窗内的 key**（`full_keys` 过小或为 0），剪枝倍率会 **虚高**，**不具客观性**，不得纳入正式对比。  
- **与 §0.1a 一致**：在 **段键库** 上，`full_keys` 若仍来自 **MBR∩窗** 谓词，则「非空窗」只保证 **候选段** 足够多；**严格非空**应以 **点级 ∃∈W** 为准（待 bench/列名升级后统一）。
- **推荐操作**：
  1. 使用 **`tools/st_validity_experiment_windows_wuxi_stratified12_n4m4w4.csv`**（**4 窄 + 4 中 + 4 宽**；在 **1-SST** 上经 `validate_wuxi_windows_csv.py` 校验 **`full_keys ≥ 50`**）。**切换正式窗 CSV 后**须 **重跑** **`tools/cache_wuxi_vanilla_wall_baseline.ps1`**，否则 `wuxi_vanilla_wall_cache.json` 与当前窗几何不一致会导致 Vanilla 列 miss。Legacy：`random12_cov_s42`。  
  2. 汇总时关注 `summarize_wuxi_ablation_three_modes.py` 按 `full_keys` 分档；  
  3. **`-VerifyKVResults`**：保证 **full 与 prune 在同一套 `UserKeySpatioTemporalInWindow` 规则下输出一致**，**不等于** §0.1a 的点级真值已满足；段库上主结论须另有点级验证或升级后的列。  
- **禁止**：使用未验证的 **`random12_s42` 均匀随机窗** 作为正式表的主数字（易出现空窗）；若需对比，须注明「未验证窗」且单独讨论。

### 0.4 本 fork「模型 / 存储与读路径」已做的改进（核对清单）

下列为 **截至当前代码** 在 **RocksDB fork** 中与 ST 时空查询相关的主要改造（论文 Method 可展开；细节见 **`AGENT_HANDOFF.md` §8**）。**对照基线**：原生 **`NewIterator` → MergingIterator → LevelIterator → TableCache → BlockBasedTableIterator`** 的模块与源码文件，见 **`AGENT_HANDOFF.md` §8.0**（便于区分「官方读路径」与「在何处插入 Global/Local」）。

| 层次 | 改进内容 | 代码位置（主要） |
|------|----------|------------------|
| **Manifest / 文件** | SST 级 **`st_file_meta`**（时空包围盒等），`has_st_file_meta`；含 **range deletion** 的文件不参与文件级跳过 | `version_set.cc`、`FileMetaData` 相关 |
| **LevelIterator / 前向扫描** | 文件级 ST 与查询窗不相交则 **不 `OpenTable`**（仅 `SeekToFirst`/`Next` 路径；**Seek/SeekForPrev 不跳过**） | `LevelIterator::NextForwardFileIndexSkippingStPrune` |
| **文件级加速（可选）** | **时间分桶** → 桶内 **x/y 空间 BVH** → **`file_skip_mask_`** → 压缩 **候选 SST 下标表** `st_candidate_files_`，`Next` 用 `lower_bound` 跳转；diag 计数与线性语义对齐 | `EnsureTimeBucketRTreeSkipMask`、`EnsureStCandidateFilesFromSkipMask`（`version_set.cc`） |
| **SST 内** | 块迭代 **`FindKeyForward`**：user key 与查询窗 **时空不相交则跳过**（`UserKeySpatioTemporalDisjointFromPruneScan`）；分区索引迭代器侧对称逻辑 | `block_based_table_iterator.cc`、`partitioned_index_iterator.cc`、`st_meta_user_key.cc` |
| **读选项** | 统一由 **`ReadOptions.experimental_st_prune_scan`** 子开关控制 file/block/key 级及 time-bucket R-tree 等 | `read_options` / bench 传参 |
| **Compaction / 建库（工程侧）** | 事件时间切分、`CompactFiles` 等（避免 trivial move）；与 **段式元数据** 配合的建库工具链 | 见 `AGENT_HANDOFF.md` §1.2、`docs/sst_and_manifest_plan.md` |
| **未做 / 不在此清单** | Get/MultiGet 文件级剪枝；**反向迭代**块内 key 过滤；**整段单 KV** schema | 见 `AGENT_HANDOFF.md` §4 末尾 |

### 0.5 默认查询时空窗（团队标准：无锡，**非** Geolife）

自 **2026-04-12** 起，**本仓库内与 ST 读路径相关的正式测试**（手跑 `st_meta_read_bench`、文档示例命令、未在脚本里显式覆盖 `--prune-*` 的新实验）**一律以无锡轨迹数据上的时空窗为准**，**不再使用 Geolife（北京附近）那组默认 `t/x/y` 作为默认示例或默认未传参行为**。

| 项 | 约定 |
|----|------|
| **权威窗表** | **`tools/st_validity_experiment_windows_wuxi_stratified12_n4m4w4.csv`**（12 窗分层；§0.3）。Legacy：**`random12_cov_s42`**。 |
| **默认单窗（与 `st_meta_read_bench` 内置默认一致）** | **`wx_strat_narrow_01`**：`t=[1596200000,1596203600]`，`x=[120.02,120.34]`，`y=[31.52,31.88]`。 |
| **推荐 DB 示例（多 SST manifest 场景）** | **`D:\Project\data\verify_wuxi_segment_bucket3600_sst`**（或 `verify_wuxi_segment_736sst` / `verify_wuxi_segment_manysst`，与 §2.1 一致）。 |
| **Geolife 点库**（如 `verify_traj_st_full`） | **仅保留**为历史对照、特定 diag（如 `st_diag_align_read_bench`）或 **显式标注 legacy** 的复现；**新写入 `Record.md` 的主结论、新跑次 TSV 默认不得再以 Geolife 窗作为「项目默认查询」**。 |

---

## 1. 名词：什么是「消融」

在本仓库里，**时空（ST）剪枝消融**指：在同一批查询窗口、同一 RocksDB 上，用 `st_meta_read_bench` 对比：

- **Fork full（F0）**：本 fork 内 **不做剪枝的 full scan**（`st_meta_read_bench` 当前 full 路径；与 **§0.2** 的 **Vanilla（V）** 区分）；
- **Prune**：某一种剪枝策略（由 `PruneMode` 决定）。

一次完整「三模式消融」会跑三种剪枝模式，并产出三份 TSV（见下表）。**不要**把「消融」和「只跑一个 PruneMode」混用；口头说「消融」时默认指三模式成套结果。

| 模式名（论文/文档） | `PruneMode` | 含义（简写） |
|---------------------|-------------|----------------|
| Global | `manifest` | 主要依赖 manifest / 文件级跳过 |
| Local | `sst` | SST 内 block/key 级剪枝 |
| Local+Global | `sst_manifest` | 上述组合 |

**核心驱动脚本**：`tools/st_prune_vs_full_baseline_sweep.ps1`（逐窗调用 `st_meta_read_bench.exe`，写一行 TSV）。

---

## 2. 当前「标准」跑法（与 `docs/st_ablation_wuxi_1sst_vs_manysst.html` 对齐）

### 2.1 数据库布局（第三档 = **1 小时 / 3600s 桶**，**`N` 个 SST 以实测为准**）

| 路径（默认在 `D:\Project\data\`） | 典型 SST 数 | 说明 |
|-----------------------------------|------------|------|
| `verify_wuxi_segment_1sst` | 1 | 单 SST 基线 |
| `verify_wuxi_segment_164sst` | 164 | 多小 SST（flush 策略等，见建库脚本） |
| **`verify_wuxi_segment_bucket3600_sst`** | **`N`（依数据；常见 ~700+）** | **第三档标准路径名**：`st_bucket_ingest_build --bucket-sec 3600`，每桶 flush → 多 SST |
| `verify_wuxi_segment_776sst` / `verify_wuxi_segment_736sst` | **`N`** | **仅历史/兼容**；若存在可被 **`wuxi_resolve_third_tier_fork.ps1`** 选为第三路径 |

**主消融 / 缓存默认 CSV** 第三路径为 **`verify_wuxi_segment_bucket3600_sst`**；若该目录不存在，则按解析器尝试 **`776sst` → `736sst`**。`wuxi_ablation_run_meta.json` 含 **`third_tier_resolved_fork_path`**、**`third_tier_live_sst_count`**、**`third_tier_hourly_bucket_sec`: 3600**。**输出目录**默认形如 `wuxi_ablation_1_164_hourly_<时间戳>`（旧名 `..._776_...` 仍可能出现在历史实验里）。

校验 SST 个数：

```text
python tools/verify_wuxi_segment_sst_counts.py
```

### 2.1a 第三档多 SST 在数据里**怎么划分**（核对用）

与目录名 **736 / 776 / `bucket3600`** 无关，**语义**是：用 **`st_bucket_ingest_build`** 按段元数据里的 **`t_start`** 做 **整除分桶**：

- **`bucket_id = t_start / bucket_sec`**（`uint32`；默认示例 **`--bucket-sec 3600`** 即按 **事件时间 1 小时** 一桶）。
- 同一 `bucket_id` 内的段先 **排序再 `Put`**，然后 **`Flush` 一次** → 该桶在成品库里对应 **至少一个 live SST**（实现上「每桶一次 flush」，通常 **一非空桶 ≈ 一 SST**；若曾 compact 过则可能合并，以当前 `GetLiveFilesMetaData` / 目录下 `*.sst` 为准）。
- 输入：`segments_meta.csv` + `segments_points.csv`（与 `docs/BUILD_AND_EXPERIMENTS.md` **§4.2** 一致）。

实现位置：`rocks-demo/st_bucket_ingest_build.cpp`（分桶 `const uint32_t b = t_start / bucket_sec;`，按桶 `Put` + `Flush`）。

**本机验证步骤**：

1. 数 SST：`(Get-ChildItem <db> -Filter *.sst).Count` 或 `python tools/verify_wuxi_segment_sst_counts.py`。  
2. 与元数据一致：对 `segments_meta.csv` 统计 **`floor(t_start / 3600)`** 的不同取值个数（非空桶数），应与「按该流程 freshly build、且未大幅 compact」时的 SST 数 **同阶**；若目录是历史拷贝或做过 `CompactRange`，只保证 **仍是按时间桶 ingest 的产物**，个数不必与公式逐字相等。  
3. 若需从空目录 **复现**：按 **`docs/BUILD_AND_EXPERIMENTS.md` §4.2** 建 `verify_wuxi_segment_bucket3600_sst`（文档示例期望 **736** 个 SST，取决于无锡数据时间跨度）。

**仅 4 个窄窗跑 Global**：`tools/run_wuxi_global_736_narrow4.ps1`（窗表 `tools/st_validity_experiment_windows_wuxi_stratified12_narrow4.csv`，与 stratified12 中 **narrow_01..04** 相同）。

### 2.2 查询窗口 CSV（优先级）

| 文件 | 标准用途 |
|------|----------|
| `tools/st_validity_experiment_windows_wuxi_stratified12_n4m4w4.csv` | **正式默认（首选）**：**4 窄 + 4 中 + 4 宽**；已在 **`verify_wuxi_segment_1sst`** 上 **`validate_wuxi_windows_csv.py --min-keys 50` 全通过**。`run_wuxi_segment_ablation_1_164_776.ps1` / `cache_wuxi_vanilla_wall_baseline.ps1` **未传 `-WindowsCsv` 时优先使用本文件**。 |
| `tools/st_validity_experiment_windows_wuxi_stratified12_narrow4.csv` | 仅 **4 窄**（与上表 narrow_01..04 一致）；配合 **`run_wuxi_global_736_narrow4.ps1`** 做 736/776 档 **Global-only** 快速跑。 |
| `tools/st_validity_experiment_windows_wuxi_random12_cov_s42.csv` | **Legacy**：seed=42 随机 12 窗 + cov 验证；历史跑次与旧 Vanilla 缓存可能仍指向本 CSV。 |
| `tools/st_validity_experiment_windows_wuxi_random12_s42.csv` | 备选：稠密包络内均匀随机，**未**做 per-window 键验证 |
| `tools/st_validity_experiment_windows_wuxi.csv` | 手工 12 场景 |

生成 cov 窗：

```text
python tools/generate_wuxi_random_windows_validated.py ...
```

校验任意窗 CSV（示例：分层 12 窗）：

```text
python tools/validate_wuxi_windows_csv.py --csv tools/st_validity_experiment_windows_wuxi_stratified12_n4m4w4.csv --db D:/Project/data/verify_wuxi_segment_1sst
```

未验证随机窗（易出空窗、倍率失真）：

```text
python tools/generate_random_query_windows_wuxi.py ...
```

### 2.3 Bench 配置约定（与主消融脚本默认一致）

- VirtualMerge + VirtualMergeAuto（VM 风格）
- `TimeBucketCount = 736`（**时间桶个数**，与 SST 个数 736 **不是同一概念**）
- `SstManifestAdaptiveKeyGate` / `SstManifestAdaptiveBlockGate` 默认开启

### 2.4 汇总与严谨性

- **汇总**：`python tools/summarize_wuxi_ablation_three_modes.py`（`--pooled`、`--pooled-by-db` 等）  
- **KV / 剪枝自洽（默认开启）**：`run_wuxi_segment_ablation_1_164_776.ps1` **默认**向 `st_prune_vs_full_baseline_sweep.ps1` 传入 `-VerifyKVResults`，bench 对 **fork** 跑 **`--verify-kv-results`**（full 与 prune 在 **bench 内置谓词** 下窗内 KV 集合一致）。**仅加速迭代**时用 `-SkipVerifyKVResults`。**Vanilla 基线**（`-VanillaAsBaseline`）行上 ratio 仍用 Vanilla wall，KV 对拍由 sweep **额外**对同一 fork 再跑一轮 full+prune+verify 填入 `kv_correct`（见 `st_prune_vs_full_baseline_sweep.ps1` 注释）。  
- **Global「病理」诊断**：多 SST 库各文件 **`st_file_bounds`** 与查询窗的相交比例、xy 相关量等 → `python tools/wuxi_sst_file_mbr_pathology_report.py --db <...> --windows-csv ...`（依赖 `rocksdb/build/tools/st_meta_sst_diag.exe`）。**读数注意**：（1）输出里的 **xy「面积」为 Δx·Δy**，无锡段键一般为 **经纬度（度）** → 数值单位为 **deg²**，**不是 km²**，更不能直接当「占无锡市百分比」；（2）若 **`sst_glob_count` 只有 1**，则目录**并非**多 SST 桶布局（与文件夹名 `736sst` 无关），该单个文件的文件级 MBR 是 **整文件键的外包矩形**，必然极大，Global **无法**在文件间做跳过。脚本 JSON 会带 **`layout_warning`** / **`xy_extent_product_units`**。  
- **点级真值**：主结论应以 **§0.1a** 为准；在实现 **值域精判或点级金标准列** 之前，勿将仅 MBR 口径的指标当作「严格正确」对外表述。

### 2.5 输出目录约定

- 主入口默认输出：`data/experiments/wuxi_ablation_1_164_hourly_<时间戳>`；若第三档路径经解析器替换，默认名可追加 `_third_tier_path_fallback`。
- 每次运行写入 **`wuxi_ablation_run_meta.json`**（含 **`third_tier_*`**、`used_736sst_fallback`（仅当解析到 `..._736sst` 路径）、`rocks_db_paths_csv`、`windows_csv`、`generated_utc`）。
- 历史重复跑次见：`data/experiments/README_wuxi_ablation_layout.txt`、`data/experiments/archive_wuxi_ablation_runs/`。

---

## 3. 脚本地图（`tools/`）

### 3.1 无锡段数据 — 三库三模式（HTML 主报告）

| 脚本 | 作用 |
|------|------|
| `run_wuxi_segment_ablation_1_164_776.ps1` | **主入口**：1sst + 164sst + **第三档**（默认 **`verify_wuxi_segment_bucket3600_sst`**；`wuxi_resolve_third_tier_fork.ps1` 可解析到 legacy `776sst`/`736sst`）× manifest / sst / sst_manifest；写 meta（含 **`third_tier_live_sst_count`** 等）；可选 `-SummarizePooled`。Vanilla 逻辑同前。 |
| `build_wuxi_segment_third_tier_hourly.ps1` | **重建第三档**：`st_bucket_ingest_build --bucket-sec 3600` → `verify_wuxi_segment_bucket3600_sst` |
| `wuxi_resolve_third_tier_fork.ps1` | 被主脚本 **dot-source**：解析 CSV 中第三 fork 路径（bucket3600 → 776 → 736） |
| `run_wuxi_segment_ablation_vanilla.ps1` | **强制 Vanilla 基线**：要求已构建 `st_segment_window_scan_vanilla.exe`，再调用主入口；缺 exe 时直接报错退出。无法访问 GitHub 时可用 **`-DVANILLA_STANDIN_LINK_FORK_LIB=ON`** 仅链接本仓库 fork 的 `rocksdb.lib` 生成同名 exe（**非**官方 V，见 `docs/VANILLA_ROCKSDB_BASELINE.md` §7.1）。 |
| `run_wuxi_segment_ablation_1_164_736.ps1` | 仅转发到上一脚本，保留旧路径/书签 |
| `run_wuxi_global_736_narrow4.ps1` | **仅 Global**：第三档（同主入口解析）× **`st_validity_experiment_windows_wuxi_stratified12_narrow4.csv`**；bench **§2.3**；默认 KV verify + Vanilla |
| `run_wuxi_random12_vm_p50_ablation.ps1` | 固定 random12_cov（或退 random12）+ 调用上一主脚本 |

### 3.2 无锡 — 其它实验入口

| 脚本 | 作用 |
|------|------|
| `run_wuxi_dual_regime_full_ablation.ps1` | 双库/双制度 6 窗（默认 `data/experiments/wuxi_dual_regime_windows.csv`），默认库常为 `verify_wuxi_segment_manysst` |
| `run_wuxi_manysst_ablation_timebucket_rtree.ps1` | 164 SST 库上多 `TimeBucketCount` × 多模式扫描，用于 timebucket/rtree 相关消融 |
| `wuxi_manifest_file_skip_stats.ps1` | 按窗统计 manifest 文件级 disjoint 比例等（依赖 diag 可执行文件） |

### 3.3 通用底层

| 脚本 | 作用 |
|------|------|
| `st_prune_vs_full_baseline_sweep.ps1` | 全扫描 vs 单 PruneMode，产出单张 TSV；可选 **`-VanillaAsBaseline`**（需 Vanilla 缓存或 exe）用 Vanilla 填满 `full_*` 并 **`--no-full-scan`** |
| `st_prune_synergy_ablation.ps1` | 另一套剪枝/协同实验封装（与无锡 HTML 无默认绑定） |
| `st_prune_dual_regime_experiment.ps1` | 双制度实验封装 |

### 3.4 Python 辅助

| 脚本 | 作用 |
|------|------|
| `summarize_wuxi_ablation_three_modes.py` | 读三份 `ablation_*.tsv`，p50 / pooled / 按库汇总 |
| `wuxi_sst_file_mbr_pathology_report.py` | **Global 病理**：`st_meta_sst_diag` 扫库内 `*.sst` 文件级 ST MBR；可选 `--windows-csv` 逐窗统计相交/不相交、与窗的 xy 交集面积和、`时间×xy交集` 代理；`--pairwise-spatial` 两两空间交集面积和（§2.4） |
| `summarize_prune_vs_full_tsv.py` | 通用 TSV 汇总（若被其它流程引用） |
| `verify_wuxi_segment_sst_counts.py` | 打印默认段库 SST 个数 |
| `generate_wuxi_random_windows_validated.py` | 生成 cov 随机窗 CSV |
| `generate_random_query_windows_wuxi.py` | 生成未验证 random12 类 CSV |
| `process_wuxi_trajectory.py` | 轨迹数据处理管线（输入侧，非 bench） |

### 3.5 可执行文件（`rocks-demo/build/`）

| 可执行文件 | 作用 |
|------------|------|
| `st_meta_read_bench.exe` | Full/Prune bench，单行统计供 PowerShell 解析 |
| `st_meta_smoke.exe` | 从 `segments_meta.csv` 建段键库 |
| `st_bucket_ingest_build.exe` | 按时间桶 ingest（如 3600s）控制 SST 划分 |
| `st_meta_compact_existing.exe` | 对已有 DB 做 compact |

---

## 4. 另一套路径命名（文档/旧脚本仍可能出现）

部分脚本默认仍指向 **按构建方式命名** 的目录，与「1sst/164sst/776sst」并存；不要假设全仓库只剩一种命名。

| 路径 | 常见 SST 数 | 常见用途 |
|------|------------|----------|
| `verify_wuxi_segment_manysst` | 164 | `run_wuxi_dual_regime_full_ablation`、`wuxi_manifest_file_skip_stats`、部分 timebucket 实验 |
| `verify_wuxi_segment_bucket3600_sst` | **以 `*.sst` 计数为准**（3600s 桶，常见 ~700+） | 与第三档 **语义相同**，仅目录命名不同；见 `BUILD_AND_EXPERIMENTS.md` 建库示例 |

若论文只报告「1 / 164 / 多 SST」HTML 那一套，以 **第二节** 为准。

---

## 5. 静态报告

| 文件 | 说明 |
|------|------|
| `docs/st_ablation_wuxi_1sst_vs_manysst.html` | 无锡 12 窗 × 三库 **柱状图**（仅 SVG，无正文表格）；更新柱高/标签前对照 `data/experiments/` 下跑次与 `pooled_p50_summary.txt`、`wuxi_ablation_run_meta.json`。图/表第二簇标题为 **164 SST**（文档约定 **164 档**，对应 `verify_wuxi_segment_164sst`），**不是**该目录经 compact 后的 `*.sst` 瞬时个数；第一、三档标题中的数字仍为目录 **live `*.sst` 实测**（由 `tools/refresh_wuxi_ablation_chart_html.py` 生成）。 |

---

## 6. 维护清单（改代码/跑新实验时自检）

1. **§0 实验前标准**：三模式 × 三 SST 档、12 窗无空窗、**Vanilla baseline** 是否已单独跑并记录。  
2. **§0.1a 真值口径**：对外文案、主表、摘要是否区分 **点级命中（权威）** 与 **MBR/段 key 谓词（bench 现状，段库可含假阳性）**；升级 bench/TSV 后是否同步列名与图注。  
3. 默认 DB 列表、窗口 CSV、输出目录命名是否与 **本文件** 一致。  
4. 是否发生 736 回退：必须在 **meta** 或 **目录后缀** 上可读，不能只改 HTML 文案。  
5. cov 窗仅在 1-SST 上验证；跨库结论是否需 `-VerifyKVResults`（并理解 §0.1a 限制）。  
6. 更新 `BUILD_AND_EXPERIMENTS.md` 时：编译与建库命令仍以该文件为权威；**脚本索引以本文件为权威**，在 `BUILD_AND_EXPERIMENTS.md` 顶部保留指向本文件的链接。

---

*最后建议：在 Git 提交信息里写清「更新了哪份实验目录 + 是否回退 736」，便于与 HTML 对照。*

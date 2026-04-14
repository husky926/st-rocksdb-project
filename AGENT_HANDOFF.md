# Project handoff / 会话恢复用（给 AI 与维护者）

> **用途**：网络重连后先读本文 + `Record.md`，可快速对齐目标与进度；**实验脚本、无锡三库路径**以 **`EXPERIMENTS_AND_SCRIPTS.md`** 为准（**默认查询时空窗：无锡**，见该文件 **§0.5**）；**开跑前硬性约定**（三模式 × **Fork 侧**三 SST 档、12 窗禁空窗、**Vanilla vs Fork-full 基线**）见该文件 **§0** 与 **`docs/VANILLA_ROCKSDB_BASELINE.md`**。  
> **Vanilla 基线（原生态）**：**单一**官方 RocksDB 目录，**加工轨迹数据一次灌入**，**不**复制 fork 的 1 / 164 / 多 SST 三档；**主指标 = 同窗查询壁钟**（`vanilla_wall_us`）。**无锡 Vanilla 壁钟 / `-VanillaAsBaseline`**：`st_segment_window_scan_vanilla` 须打开 **真实可迭代的 V 目录**（过渡期为 `*_vanilla_replica` 等；`cache_wuxi_vanilla_wall_baseline.ps1` 的 JSON 键须与打开路径一致）；在 **fork 段库路径**上直接跑 Vanilla 常无有效 `wall_us`，TSV 会出现 **`vanilla_as_baseline_unavailable`**。  
> **查询真值（全队统一）**：轨迹段查询的 **正确命中** = 段内 **至少有一点**落在查询时空窗内；命中后返回 **整段**。**仅 MBR（或段 key 内包围盒）与窗相交、但无点在窗内** = **假阳性，视为错误**，不得作为正式正确结果。**权威定义与 bench 现状差异**见 **`EXPERIMENTS_AND_SCRIPTS.md` §0.1a**。  
> **维护**：重大实验、架构或路径变更后，请追加或修订「当前状态」「下一步」；**读路径 / Method 级改造**同步 **§8**。  
> **论文导向**：终极目标见 **§1.1**；**当前优先**见 **§1.0**（验证设计能否提升 DB 性能）。**统计层面**（多次中位数、严格冷热缓存）可分期；**语义层面**以 **§1.0a / EXPERIMENTS §0.1a** 为硬标准。

### 实验结果 → 必须写入 `Record.md`（给 AI 的约定）

**用户每次在对话里发送实验输出 / 日志时**，助手应 **在 `Record.md` 末尾追加一节**（或更新对应日期条目），**按下面结构记录**（可用表格一行一项，与既有 `Record.md` 风格一致）：

| 项 | 说明 |
|----|------|
| **实验目的** | 跑的命令/工具、要验证什么假设或设计点 |
| **实验结果** | 关键数字、路径、日志/TSV 文件名（可摘要） |
| **是否达到预期** | **是 / 否 / 部分**，一句话 |
| **为什么** | 结合机制（Manifest / 块级 / 块内 key / 缓存等）解释符合或偏离的原因 |
| **下一步**（建议） | 可执行的后续命令或实验方向（可选但推荐） |

与历史条目中的「验证目的 / 验证结果 / 是否符合期望 / 原因」**同义**，统一以用户表述的 **「实验目的—实验结果—是否达到预期—为什么」** 为准。

---

## 1. 目标

### 1.0 当前阶段（优先）

**主线**：验证 **Manifest + SST（及读路径）改造是否真实提升 DB 性能**、**设计是否有效**（机制与 **可观测指标**：`bytes_read`、`wall_us`、`prune_scan keys`、diag 的 INTERSECTS/DISJOINT 等）。**正确性叙事**必须以 **§1.0a** 与 **`EXPERIMENTS_AND_SCRIPTS.md` §0.1a** 的点级真值为准；IO 与剪枝倍率不得与「MBR 假阳性当命中」混谈。

**刻意不做（统计协议，可与语义真值分开）**：多次重复取中位数、严格冷/热缓存协议等 —— 可留待 **论文逼近定稿或审稿要求** 时再加强（部分原规划见 **§7 暂缓**）。**Fork 三 SST 档 × 三模式消融** 与 **单一 Vanilla 基线**仍按 `EXPERIMENTS_AND_SCRIPTS.md` 与 `VANILLA_ROCKSDB_BASELINE.md`（**§1.1**）执行。

### 1.0a 轨迹查询真值 vs 当前 bench（必读）

下列与 **`st_meta_read_bench`**、**`-VerifyKVResults`** 及论文表述对齐：

| 项目 | 约定 |
|------|------|
| **真值** | 段 **S** 命中查询窗 **W** 当且仅当 **∃ 点 p∈S，p∈W**；返回 **整条段**。 |
| **假阳性** | **MBR(S)∩W**（或段 key 中 t/x/y 包围盒与 **W** 相交）但 **S 中无点在 W 内** → **错误**，不记入「正确返回」。 |
| **点键库 `0xE5`** | `UserKeySpatioTemporalInWindow` 即点是否在窗内，与真值一致。 |
| **段键库 `0xE6`** | 同函数当前为 **时间相交 ∧ 空间 MBR 相交**，**宽于**真值；用它计的 `full_keys` 与 **`-VerifyKVResults`（full≈prune 同谓词）** 只证明 **剪枝实现与全表扫描在该谓词上一致**，**不证明**点级真值。 |
| **后续工程** | 段库主结论需 **值域精判**（解码 value 点列并检验 ∃∈W）、或 **点级 KV 金标准**、或等价离线校验；直至落地，TSV/HTML 须 **标注口径**，避免把 MBR 指标当严格正确。 |

**`Record.md` 与论文**：凡涉及「窗内命中数 / 正确性」，应写明采用的是 **点级** 还是 **当前 bench 段谓词（MBR）**，二者不可混称。

### 1.1 终极目标（学术论文）

**要在论文中论证的结论**：**Manifest + SST 改造在真实 / 大规模 workload 里普遍、稳定地带来性能提升**（读放大、延迟或吞吐上的可重复收益，而非仅在单库、单窗、手工构造的 DISJOINT 场景下成立）。

**成果形态**：**学术论文**。达到该目标时，再补齐：**可复现协议**、**贴近真实的查询分布**、**规模外推**、**清晰基线** 等（详见 **§7 暂缓**）。

**成文模板（论文 §1.1 实验与结果结构）**：**`docs/st_paper_1_1_workload_evaluation.md`**（主张、B0/A/B1/B2 基线、W1–W6 workload、协议、**已有 PKDD E5 数字**、待补表格清单）。

**当前仓库状态**：**受控 A/B**（如文件级 DISJOINT 东窗）已能说明 **「能触发时 IO 下降」**；**多样窗 / 多 SST** 仍在 **`Record.md`** 中逐步积累，以支撑从 **有效性** 过渡到 **普遍性** 叙事。

### 1.2 阶段性目标（工程验证）

在 **真实或半真实的 RocksDB**（本仓库 **fork 的 rocksdb** + **rocks-demo** 工具）上验证改进是否有效：

- **ST 元数据**：块级 / 文件级（Manifest tag 17、`st_file_meta` 等，见 `Record.md` 与 `docs/sst_and_manifest_plan.md`）。
- **Compaction**：事件时间切分（`experimental_compaction_event_time_*` + **`CompactFiles`** 避免 trivial move）。
- **读路径**：从 **`open_ns` 合成加权** 演进到 **真实读 IO 测量**（`st_meta_read_bench` 等）。

**数据形态**：仓库中既有 **轨迹点级 KV**（`0xE5`），也有 **段级 KV**（`0xE6`，键内嵌段 MBR）；无锡段实验常用后者。**新建段库**（`st_meta_smoke --st-segment-keys` + `--segment-points-csv`）将 **V2 value** 写入 RocksDB：段头 + **逐点 `(unix_s,lon,lat)`**（`rocks-demo/segment_value_codec.hpp`），供后续 **值域 ∃点∈窗** 验证；旧库可能仍为仅 28 字节段头。**点级库**与 **§1.0a** 真值直接对齐；**段级库**上 bench 在升级前仍可能仅用 user key（MBR）计数，须按 **§1.0a** 理解。加工 CSV：`data/processed/*/segments_meta.csv` + **`segments_points.csv`**。

---

## 2. 目录与产物（常改）

| 路径 | 说明 |
|------|------|
| `d:\Project\EXPERIMENTS_AND_SCRIPTS.md` | **实验脚本地图、消融定义、无锡标准跑法**（与 `docs/BUILD_AND_EXPERIMENTS.md` 互链） |
| `d:\Project\docs\project_layout.md` | **顶层目录与 `data/` 说明**（`rocksdb` / `rocks-demo` / 可再生产物） |
| `d:\Project\Record.md` | **人写实验记录**（目的/结果/下一步），权威流水账 |
| `d:\Project\data\README.txt` | `data/` 下保留什么、脚本关系 |
| `d:\Project\data\processed\` | `segments_points.csv` / `segments_meta.csv`（Geolife 等加工结果） |
| `d:\Project\data\verify_traj_st_full` | **~128 万点** ST user key 库（`st_meta_smoke --csv --st-keys --max-points -1`） |
| `d:\Project\data\experiments\` | `run_st_experiments.ps1` 生成的 `verify_split_on` / `verify_split_off` |
| `d:\Project\rocksdb\` | Fork 源码；`build\rocksdb.lib`、`build\tools\ldb.exe` |
| `d:\Project\rocks-demo\` | 可执行文件在 `build\*.exe` |

---

## 3. 关键工具（rocks-demo/build）

| 可执行文件 | 作用 |
|------------|------|
| `st_meta_smoke.exe` | `--csv` + **`--st-keys`**：真实 CSV → **0xE5 ST user key** + ST 表选项 |
| `st_meta_compaction_verify.exe` | split ON/OFF + CompactFiles vs CompactRange，看 SST 个数 |
| `manifest_bucket_rtree_validate.exe` | **无 RocksDB**：合成 Manifest 桶+R 树 vs 暴力（含 `--open-ns` 加权） |
| `st_meta_scan_bench.exe` | **自建小库**：全表扫 vs `experimental_st_prune_scan`，`block_read_count` |
| **`st_meta_read_bench.exe`** | **打开已有库**：全表扫 vs prune；**PerfContext + IOStatsContext + Statistics**（真实读路径第一步） |
| **`st_meta_compact_existing.exe`** | **已有库副本**：`SetOptions(target_file_size_base)` + **`CompactRange`**，拆小 SST 后再跑 **`st_meta_sst_diag` / read_bench** |
| **`tools\copy_compact_traj_st.ps1`** | **`robocopy`** `verify_traj_st_full` → `verify_traj_st_compact_work`，再 **`st_meta_compact_existing`**，若存在则自动 **`st_meta_sst_diag --window`（宽窗）** 对所有 `*.sst` |
| **`traj_db_audit.exe`** | **`VerifyChecksum` + `GetLiveFilesMetaData`**，汇总 **`num_entries`**（计划第 1 步：健康检查与条目对齐） |
| **`tools\audit_sst_entries.ps1`** | 对每个 `*.sst` 调 **`sst_dump --show_properties`**，解析 **`# entries`** 求和（与 manifest 交叉核对） |
| **`rocksdb\build\tools\st_meta_sst_diag.exe`** | **Fork**：块级 index ST tail 统计 + 文件级 **`st_file_bounds`**；与 `sst_dump` 同目录，**不在** `rocks-demo\build` |
| **`tools\st_diag_align_read_bench.ps1`** | 对 **`verify_traj_st_full`** 两 SST 跑 **`st_meta_sst_diag --window`**：**宽窗**（= `st_meta_read_bench` 默认）+ **尖窗**（= `Record.md` Run1）；参数映射见 `Record.md`「对照流程」 |
| **`tools\st_manifest_disjoint_demo.ps1`** | **文件级 DISJOINT 演示**：`x=[120,122]` 使 **`000011` DISJOINT**；接 **`st_meta_read_bench --no-full-scan`**；建议 **`ExecutionPolicy Bypass`** |
| `tools\run_st_experiments.ps1` | 一键 A1–A3 + B1–B2；日志在 `experiment_logs\run_*.log` |

**常用命令摘要**（路径按本机调整）：

```bat
REM 真实轨迹 ST 键全表（需空目录）
st_meta_smoke.exe --db D:\Project\data\verify_traj_st_full --csv D:\Project\data\processed\segments_points.csv --st-keys --max-points -1

REM Manifest 看键（hex）
D:\Project\rocksdb\build\tools\ldb.exe manifest_dump --db=D:\Project\data\verify_traj_st_keys --verbose --hex

REM 真实读基准（默认剪枝窗 = 无锡 wx_strat_narrow_01，与 §0.5 / stratified12 CSV 首档一致；可省略 --prune-*）
D:\Project\rocks-demo\build\st_meta_read_bench.exe --db D:\Project\data\verify_wuxi_segment_bucket3600_sst

REM 与 bench 同窗的块级/文件级诊断（先编 st_meta_sst_diag）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\st_diag_align_read_bench.ps1

REM 文件级 DISJOINT + bench（见 Record.md）
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\st_manifest_disjoint_demo.ps1
```

---

## 4. 当前状态（截至最近对话）

- **ST-keys 真实灌库**：5000 / 50000 / **1279214** 点 Get 校验通过；`manifest_dump --hex` 见 **`E5`**。
- **全流程脚本**：`run_st_experiments.ps1` 已修复 `$args` / stderr；B1 `total_sst=500`、B2 `total_sst=1`。
- **`data/`** 已精简：保留 `processed/` + 原始 **zip**；实验 RocksDB 目录多可再生。
- **读路径**：已加 **`st_meta_read_bench`**；已对 **`verify_traj_st_full`** **宽窗 + 尖窗** 跑通：**`prune_scan keys` 均为 1279138**（与 full 差 76），**尖窗未改变 IO**——块级剪枝仅跳过排序最前与窗不相交的块；**块内 key 过滤（新）** 见下。
- **块内 ST key 过滤（已测）**：**`FindKeyForward`** 按 **0xE5 user key (t,x,y)** 过滤。**`verify_traj_st_full` 宽窗**：**`prune_scan keys=3803`**（原仅块级 **1279138**），**`key_selectivity≈0.003`**，**`block_read_ratio=1`**、**`bytes_read` 不变**；**Manifest 东窗**（`st_manifest_disjoint_demo.ps1`）：**`keys=1`**（块内过滤后窗内点极少）。见 **`Record.md`「2026-04-06 — 块内 ST key 过滤：实测」**。
- **Version 文件级 ST 剪枝**：`LevelIterator` 在 **`SeekToFirst` / `Next`** 路径上，若 **`experimental_st_prune_scan` 开启** 且 **`FileMetaData::has_st_file_meta`** 与查询窗 **不相交**，则 **不 `OpenTable`** 该 SST（**`Seek` / `SeekForPrev` 不跳过**；含 **range deletion** 的文件不跳过）。**`tools/st_manifest_disjoint_demo.ps1`**：用 **`x=[120,122]`** 等窗演示 **文件级 DISJOINT**（`000011`）+ bench。
- **文件级「时间分桶 + 桶内空间 BVH」+ 前向候选表（新增，论文 Method 见 §8.3）**：当 **`ReadOptions.experimental_st_prune_scan.file_level_time_bucket_rtree_enable`** 开启时，`LevelIterator` 在 `rocksdb/db/version_set.cc` 内对当前 level 建 **`file_skip_mask_`**（被时空查询窗完全排除的 SST 标记为跳过），再派生 **`st_candidate_files_`**（未跳过文件下标的有序表）。**`Next` / `SeekToFirst`** 通过 **`NextForwardFileIndexSkippingStPrune`** 在该表上做 **`lower_bound`**，直接跳到下一候选 SST，并在开启 diag 指针时对掩蔽区间内文件仍递增原有 **considered / disjoint / skipped** 计数，以保持与逐文件线性判定一致的语义。无 R-tree 路径时仍回退为按文件下标线性扫描 + **`StFileDisjointFromExperimentalPruneScanAt`**。
- **未做 / 长期**：Get/MultiGet 文件级剪枝；**反向迭代块内过滤**；**整轨迹段为单 KV** 的 schema。

---

## 5. 构建注意（Windows）

- **rocks-demo** 与 **rocksdb** 须 **同一 CMAKE_BUILD_TYPE（建议 Release）**，否则 `DB::Open` 可能异常。
- **`st_meta_sst_diag` 只在 `rocksdb` 里编**，产出 **`D:\Project\rocksdb\build\tools\st_meta_sst_diag.exe`**。在 **`rocks-demo\build`** 上执行 `--target st_meta_sst_diag` 会 **`ninja: error: unknown target`**——属预期，请改在 **`rocksdb\build`** 上编该 target（或编 **`rocksdb`** 时若已包含 tools，可直接用 `tools\` 下 exe）。
- **常用两条**（Release 示例）：
  ```bat
  cmake --build D:\Project\rocksdb\build --target rocksdb st_meta_sst_diag --config Release
  cmake --build D:\Project\rocks-demo\build --target st_meta_read_bench --config Release
  ```
  若 CMake 版本较老不支持一行多 target，则分两次各编一个 target。
- 若编译器路径异常（如 `D:\Visio\VC\...`），优先在 **x64 Native Tools Command Prompt for VS** 中 `cmake --build`。

---

## 6. 下一步（可勾选）

- [ ] **对齐 §1.0**：多样窗 + 多 SST +（可选）trace（**§7 第 1–3 步**）；结果写入 **`Record.md`**。**重复统计、ablation 基线** 见 **§7 暂缓**。
- [x] 跑通 **`st_meta_read_bench`** 对 `verify_traj_st_full`（宽窗 + 尖窗，见 `Record.md`）。
- [x] **计划第 1 步**：**`VerifyChecksum` OK**；**2×L0 SST**，**`sum_num_entries=1279214`**；**`audit_sst_entries.ps1`** 与 manifest 一致；**`sst_dump` Corruption** 与校验并存（见 `Record.md`）。
- [x] **计划第 2 步（部分）**：块级诊断 **`st_meta_sst_diag`**；**LevelIterator 文件级 ST 剪枝**（与 `experimental_st_prune_scan` 同窗，见 `version_set.cc`）。
- [x] **块内 ST key 过滤**（`FindKeyForward` + `UserKeySpatioTemporalDisjointFromPruneScan`）；**实测已写入 `Record.md`（2026-04-06 节）**。
- [ ] **反向迭代**块内过滤（`FindKeyBackward`）；Manifest 元数据经 **LiveFileMetaData** 对外暴露（可选）；Get 路径文件级剪枝（可选）。
- [ ] 用户每次贴实验结果 → **更新 `Record.md`**（见上文约定）。

---

## 7. 实验路线（当前对齐 §1.0：验证有效性）

**成文设计**：`docs/st_validity_experiment_design.md`（**E1–E4**、预期、成功标准）。  
**自动化**：`tools/st_validity_sweep.ps1` + `tools/st_validity_experiment_windows.csv`（**12 个窗**）。  
**与「无剪枝全表扫」硬对比（Phase A）**：`docs/st_rocksdb_hard_baseline_experiment.md` + **`tools/st_prune_vs_full_baseline_sweep.ps1`**（同一进程内 **`full_scan` vs `prune_scan`** 的 **`bytes_read`/`wall_us` 比值**）；`st_meta_read_bench` 支持 **`--no-prune-scan`** 仅跑基线。

按序做即可；每条把 **命令 + 输出摘要 / TSV** 记入 **`Record.md`**。**不追求** 统计上的过度严谨。

1. **多样查询窗（E1）**  
   `powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\st_validity_sweep.ps1`（可加 `-OutTsv ...`）。

2. **多 SST / 不同布局（E2）**  
   **双库**：从 **`powershell -File ...` 调用时不要用 `@(...)`**（第二个路径会被当成命令）。用 **逗号分隔字符串**：**`-RocksDbPathsCsv "D:\Project\data\verify_traj_st_full,D:\Project\data\verify_traj_st_compact_work"`**；或在**已打开的 PowerShell** 里 **`&` 调用** 时仍可用 **`-RocksDbPaths @('...','...')`**。**勿用 `-Db`**（与 **`-Debug`** 冲突）。**spot-check** 仍用 **`st_diag_align_read_bench.ps1`** / **`st_manifest_disjoint_demo.ps1`**（**E3**，见设计文档）。

3. **真实查询 trace（E4，可选）**  
   自建与 **`st_validity_experiment_windows.csv`** 同列的 CSV，**`-WindowsCsv`** 指向该文件，粗汇总即可。  

4. **随机窗 + Phase A 分布（E5）**  
   **`tools/run_random_prune_vs_full_pkdd.ps1`**（或 **`generate_random_query_windows.py`** + **`st_prune_vs_full_baseline_sweep.ps1`** + **`summarize_prune_vs_full_tsv.py`**），削弱手选窗质疑；见 **`docs/st_validity_experiment_design.md` E5**。

### 暂缓（论文定稿 / 审稿前再考虑）

- **重复跑 + 中位数 / 方差**、**严格冷/热缓存声明**。  
- **Vanilla RocksDB / 完全无 ST 元数据的严格对照 ablation**（与当前仓库内 **`manifest` / `sst` / `sst_manifest` 三模式 ST 剪枝对比**不同；后者见 **`EXPERIMENTS_AND_SCRIPTS.md`** 与 `docs/st_ablation_wuxi_1sst_vs_manysst.html`）。  

以上原对应 **§7 旧版第 3、4 步**，服务于 **§1.1** 的 **「普遍、稳定」** 叙事，与当前 **§1.0** 刻意区分。

---

## 8. Method：本 fork 读路径改造（论文 Method 可据此扩写）

下列与 **RocksDB `ReadOptions.experimental_st_prune_scan`** 及 **ST 文件/块元数据** 相关；实现主要在 **`rocksdb/db/version_set.cc`**（`LevelIterator`）与 **`rocksdb/table/block_based/block_based_table_iterator.cc`** 等。写论文时按小节拆成「数据结构 → 判定条件 → 迭代器挂钩点」即可。

### 8.0 原生 RocksDB：范围扫描读路径（对比基线，未加 ST 剪枝时）

**目的**：说明 **`DB::NewIterator` + `SeekToFirst`/`Seek` + `Next`** 在 **官方语义**下大致经过哪些模块与文件，便于读者把 **§8.1–8.4 的 fork 改造**叠在这条链路上理解（「在哪一层插入了时空判定、省掉了什么 IO」）。

**典型调用链（列族迭代器、前向扫描）**

1. **API 入口**  
   - **`rocksdb/db/db_impl/db_impl.cc`**：`DBImpl::NewIterator`（只读路径下可能经 **`DBImplReadOnly`**，见 **`db_impl_readonly.cc`**）构造 **`ArenaWrappedDBIter`** / 内部 **`DBIter`**，底层持有一个 **合并迭代器**。

2. **跨层合并**  
   - **`rocksdb/table/merging_iterator.cc`**（及 **`db/db_iter.cc`** 对 `DBIter` 的封装）：把 **MemTable**、**immutable memtable**、以及 **L0…Ln 各层** 的 **子迭代器** 按 **内序比较** 合并为单一逻辑视图。用户看到的 `Next()` 在这里被 **分发到某一层的当前子迭代器**。

3. **单层 SST 序列（本 fork 文件级剪枝的挂载点）**  
   - **`rocksdb/db/version_set.cc`**：**`LevelIterator`**（匿名命名空间内类）。  
   - 根据 **当前 key 范围** 在 **`LevelFilesBrief`** 上 **选择下一个 SST**（`FindFile` / 顺序下标），通过 **`TableCache::NewIterator`**（**`db/table_cache.cc`**）打开 **BlockBasedTable** 上的 **`BlockBasedTableIterator`**。  
   - **原生行为**：只要 key 范围仍可能落在该文件内，就会 **打开表**；**没有**「文件级时空外包与查询窗不相交则跳过打开」的逻辑。

4. **单个 SST 内部（本 fork 块级/键级剪枝的挂载点）**  
   - **`rocksdb/table/block_based/block_based_table_reader.{h,cc}`**：表读取器；负责 **footer、meta index、properties** 等。  
   - **索引**：未分区时走 **`rocksdb/table/block_based/block_based_table_iterator.cc`** 的索引迭代；**分区索引**时还有 **`partitioned_index_iterator.cc`**。索引块通常经 **block cache**（`rocksdb/cache/`）或 **文件读** 装入。  
   - **数据块**：`BlockBasedTableIterator` 在索引上定位后 **读 data block**（同样走 **block cache / `RandomAccessFileReader`**）。  
   - **可选**：**filter block**（Bloom 等）在 **`table/block_based/filter_block.cc`** 及相关路径；**compression** 在块解码时涉及 **`table/format.cc`** 等。

5. **I/O 与统计**  
   - 环境抽象：**`rocksdb/env*.cc`**、**`file/random_access_file_reader.cc`**。  
   - 本仓库 bench 读的 **PerfContext / IOStatsContext** 在迭代过程中累计 **block read 次数、字节、read_nanos** 等。

**与 fork 的对应关系（一句话）**  
- **Global（§8.2–8.3）**：改在 **`LevelIterator`** —— 在 **仍使用 `TableCache` 之前** 决定是否 **跳过整个 SST**。  
- **Local（§8.4）**：改在 **`BlockBasedTableIterator`（及分区索引）** —— 在 **已打开表** 的前提下，减少 **数据块读取** 与 **向上合并迭代器暴露的 key 数**。

**注意**：**点查 `Get` / `MultiGet`** 走 **sst 文件选择 + block cache** 的另一条链（`Version::Get`、`table_cache`、`GetContext` 等），**本 fork 当前未做** 文件级 ST 剪枝；**反向 `Prev`** 与部分 **Seek** 路径 **也不套用** 前向文件级跳过逻辑（见 §8.2）。

### 8.1 文件级时空元数据（Manifest / `FileMetaData`）

- 每个 SST 可携带 **`st_file_meta`**（时间 `t` 与空间 `x/y` 包围盒等），由 **`FileMetaData::has_st_file_meta`** 指示是否存在。  
- **含 range deletion 的 SST** 不参与文件级跳过（保守正确性）。  
- 查询窗由 **`experimental_st_prune_scan`** 中的 `t_min/t_max/x_min/x_max/...` 描述。

### 8.2 文件级不相交则跳过 `OpenTable`（基线策略）

- **`LevelIterator::NextForwardFileIndexSkippingStPrune`**（及 `SeekToFirst` 初始化）：在 **前向**扫描上，若当前文件 ST 元数据与查询窗 **时空不相交**，则递增可选的 **`file_level_files_*`** 计数并前进到下一文件，**不打开表**。  
- **`Seek` / `SeekForPrev` 路径不使用**上述跳过逻辑（避免破坏定位语义）。详见代码注释 *Forward scan only*。

### 8.3 时间分桶 + 桶内空间 BVH + 候选 SST 表（近期新增）

**动机**：Level 上 SST 数量大时，逐文件线性判定不相交会产生额外循环开销；在已启用 **文件级 time-bucket R-tree** 模式时，改为先对整层构建 **跳过掩码**，再 **压缩存储仍可能含候选项的文件下标**，使 `Next` 以 **有序表 + `lower_bound`** 跳到下一打开目标。

**步骤（与 `version_set.cc` 中实现一致）**：

1. **`EnsureCompactStMeta`**：缓存本 level 各文件的 **`has_st_file_meta`**、**`st_file_meta`**、是否含 range deletion。  
2. **`EnsureTimeBucketRTreeSkipMask`**：在 **`file_level_time_bucket_rtree_enable`** 为真时，按全局时间跨度将文件划入 **`file_level_time_bucket_count`** 个桶；查询窗只访问**与时间相交的桶**。桶内对 SST 的 **x/y 包围盒** 建 **类 R-tree 的层次包围盒（BVH）**，递归判定与查询窗是否 **空间不相交**，不相交则对该文件在 **`file_skip_mask_`** 中标记跳过。  
3. **`EnsureStCandidateFilesFromSkipMask`**：将 **`file_skip_mask_[i]==0`** 的文件下标 `i` 依次填入有序数组 **`st_candidate_files_`**。  
4. **`NextForwardFileIndexSkippingStPrune`**：若 R-tree 模式开启，对当前下标 `start` 在 **`st_candidate_files_`** 上 **`lower_bound`**，得到下一待打开文件；若 diag 指针（`file_level_files_considered` 等）非空，对 **`[start, next)`** 区间内被掩码跳过的文件仍按原语义递增计数，**与旧版线性扫描可观测统计对齐**。  
5. 若未启用 **`file_level_time_bucket_rtree_enable`**，则仍使用 **8.2** 的逐文件 **`StFileDisjointFromExperimentalPruneScanAt`** 线性前进。

**论文表述提示**：可强调「粗筛（时间桶）→ 细筛（桶内空间 BVH）→ 迭代器仅在压缩后的候选序列上前进」，并说明 **Seek 仍保守**。

### 8.4 块级与 user key 级过滤（SST 内）

- **`BlockBasedTableIterator::FindKeyForward`**（等路径）：对解码得到的 **user key** 调用 **`UserKeySpatioTemporalDisjointFromPruneScan`**（`rocksdb/table/st_meta_user_key.cc`），与同一 **`experimental_st_prune_scan`** 窗比较；不相交则继续在块内前进，减少向上层暴露的 key 与后续 IO。  
- **`PartitionedIndexIterator::FindKeyForward`** 等索引迭代器侧有对称逻辑（见同目录 **`partitioned_index_iterator.cc`**）。  
- 块级跳过另受 **`block_level_enable`** 等子开关控制（与文件级独立组合，对应工具链里的 **Local / Global / L+G** 消融语义，见 **`EXPERIMENTS_AND_SCRIPTS.md`**）。

### 8.5 与基准工具的关系

- **`st_meta_read_bench`**（`rocks-demo`）在 **同一 `ReadOptions`** 下交替跑 **full scan** 与 **prune scan**，输出 **wall / bytes / prune 统计**，用于验证 **8.2–8.4** 及 **8.3** 的 **IO/剪枝行为** 与 **实现自洽**（full 与 prune 在相同 **`UserKeySpatioTemporalInWindow`** 规则下的窗内键集合）。  
- **段键 `0xE6`**：窗判定与 **§1.0a** 所述一致，为 **MBR∩窗**，**不等于**「∃ 点在窗内」的真值；论文与对外结论须以 **§1.0a / `EXPERIMENTS_AND_SCRIPTS.md` §0.1a** 为准。  
- **`-VerifyKVResults`**：只验证 full 与 prune 在上述谓词下 **哈希一致**，**不验证**点级真值。  
- 无锡多 SST 上 **三模式**（`manifest` / `sst` / `sst_manifest`）成套 TSV 由 **`tools/st_prune_vs_full_baseline_sweep.ps1`** 与 **`run_wuxi_segment_ablation_1_164_776.ps1`** 驱动，**不是** vanilla RocksDB 对照。

---

*文件：`d:\Project\AGENT_HANDOFF.md`*

# 复现说明（当前仓库状态）

本文档整合 **`AGENT_HANDOFF.md`**、**`EXPERIMENTS_AND_SCRIPTS.md`**、**`docs/VANILLA_ROCKSDB_BASELINE.md`**、**`docs/BUILD_AND_EXPERIMENTS.md`**、**`Method.md`** 及关键工程改动，用于换机、审稿或 **清空源码后重新部署 RocksDB 改造实验** 时 **按结构 + 参数** 复现。**权威细节仍以各原文为准**；冲突时以根目录 **`EXPERIMENTS_AND_SCRIPTS.md` §0** 为实验约定优先（该文件在「仅保留数据」后需从 Git 再次检出或从备份恢复）。

---

## 0. 仅保留「数据 + 实验记录」、准备重新部署时

下列适用于你 **删除除数据与实验记录以外的仓库内容**、随后 **重新克隆 / 解压工程并改造 RocksDB** 的场景。

### 0.1 建议保留或事先拷贝出去的物（除 `data/` 内已有内容外）

| 类别 | 建议路径 / 内容 | 说明 |
|------|-----------------|------|
| **数据** | `data/` 整树（含 `processed/`、`verify_wuxi_*` RocksDB 目录、`experiments/` 下 TSV/JSON 等） | **改造实验的输入与历史产物**；体积大，勿误删 |
| **实验记录** | `Record.md`、以及你视为权威的 **`data/experiments/**`** 下 `ablation_*.tsv`、`wuxi_ablation_run_meta.json`、`pooled_*.txt` 等 | 与论文数字、跑次一一对应 |
| **复现与方法论** | **本文件 `REPRODUCTION.md`**、`Method.md` | 删空仓库后若未备份，协议与命令只能从 Git 历史或备份找回；**建议复制一份到 `data/experiments/_handoff/`**（或单独 U 盘/私有分支），与数据同迁 |
| **不必保留（可全量重编）** | `rocksdb/build/`、`rocks-demo/build/`、`rocksdb_vanilla/build/` | 构建产物；新环境按 §7 重建即可 |
| **必须随源码恢复** | `rocksdb/`（fork 源码）、`rocks-demo/`、`tools/`、`docs/`、`AGENT_HANDOFF.md`、`EXPERIMENTS_AND_SCRIPTS.md` 等 | 无源码则无法继续 **改造**；需从远程仓库重新 clone 或与备份同步 |

### 0.2 重新部署后的目录与构建顺序（Windows，建议 Release）

1. 将保留的 **`data/`** 放回工程根下（例如 `D:\Project\data\`，与文档中默认路径一致，或全局替换为你的根路径）。  
2. **恢复或克隆** 完整仓库（含 fork **`rocksdb/`**、`rocks-demo/`、`tools/`）。  
3. **工具链**：Visual Studio C++、CMake、Ninja；在 **x64 Native Tools** 或已 `vcvars64` 的环境中编译。  
4. **先编 Fork RocksDB 库**：`rocksdb/build` → `rocksdb.lib`（与 `rocks-demo` **同一 `CMAKE_BUILD_TYPE`**，见 `AGENT_HANDOFF.md` §5）。  
5. **再编 `rocks-demo`**：`st_meta_read_bench`、`st_meta_smoke`、`st_bucket_ingest_build` 等（见 `BUILD_AND_EXPERIMENTS.md`）。  
6. **（可选）上游 Vanilla**：`tools/bootstrap_rocksdb_vanilla.ps1` → `rocksdb_vanilla/build/rocksdb.lib` → `rocks-demo` 中 **`VANILLA_STANDIN_LINK_FORK_LIB=OFF`** 编 `st_segment_window_scan_vanilla`、`st_vanilla_kv_stream_ingest`（见 §5）。  
7. **验证**：对已有 `verify_wuxi_*` 库跑一次 `st_meta_read_bench` 单窗或 `st_prune_vs_full_baseline_sweep.ps1` 单行，确认路径与 **`Record.md` / meta JSON** 一致。

### 0.3 删除代码前自检

- [ ] `data/` 下 RocksDB 目录完整（无半截 MANIFEST/SST）。  
- [ ] 重要 TSV / `wuxi_ablation_run_meta.json` 已归档或随 `data/experiments` 保留。  
- [ ] `REPRODUCTION.md` + `Record.md`（及需要的 `Method.md`）已复制到 **`data/experiments/_handoff/`** 或其它备份。  
- [ ] 知悉：**仅数据无法单独「复现改造」**；必须恢复 **本仓库 fork 的 `rocksdb` 源码** 才能继续改读路径 / 剪枝逻辑。

---

## 1. 文档地图（应先读哪份）

| 文件 | 用途 |
|------|------|
| `EXPERIMENTS_AND_SCRIPTS.md` | **实验标准**：Fork 三 SST 档 × 三 `PruneMode`、12 窗、Vanilla 定义、脚本索引、无锡路径与输出约定 |
| `AGENT_HANDOFF.md` | **会话恢复**：目标（§1.0 / §1.1）、点级真值 vs bench（§1.0a）、读路径 Method（§8）、工具表、构建注意 |
| `docs/VANILLA_ROCKSDB_BASELINE.md` | **V / F0 / F\*** 命名、Vanilla §1.1（单一原生态库、不复制 1/164/736）、Phase 0/1/2、TSV 列、`st_segment_window_scan_vanilla` |
| `docs/BUILD_AND_EXPERIMENTS.md` | Windows 编译、`rocks-demo` 目标、无锡建库命令（`st_meta_smoke` / `st_bucket_ingest_build`）、窗 CSV |
| `Method.md` | **Fork 侧剪枝与 bench 方法**（Phase A–E：全局三态、Contains 短路、VM 候选表、adaptive gate、736 推荐参数） |
| `Record.md` | 人写实验流水（结果路径、结论）；对话里跑出的数字宜同步至此（见 `AGENT_HANDOFF.md` 约定） |

---

## 2. 实验语义与指标（写论文前必须对齐）

### 2.1 消融结构（Fork 侧）

- **三模式（`PruneMode`）**：`sst`（Local）、`manifest`（Global）、`sst_manifest`（Local+Global）。  
- **三 SST 布局（仅 Fork 物理库）**：`verify_wuxi_segment_1sst`、`verify_wuxi_segment_164sst`、第三档为 **按时间分桶的多 SST**（默认目录名 `verify_wuxi_segment_776sst`，缺则回退 `verify_wuxi_segment_736sst`；**数字仅为文件夹名**，论文应写 **实际 `*.sst` 计数 + 建库参数如 3600s 桶**）。  
- **基线**：**Fork full（F0）** = `st_meta_read_bench` 关闭 `experimental_st_prune_scan` 的全表路径；**Vanilla（V）** = 上游 `rocksdb_vanilla`，与 Fork 三档 **脱钩**（单一灌库目录，主指标为 **同窗 `wall_us`**）。见 `VANILLA_ROCKSDB_BASELINE.md` **§1.1**。

### 2.2 查询窗

- **首选**：`tools/st_validity_experiment_windows_wuxi_random12_cov_s42.csv`（12 窗；在 1-SST 上验证过 **bench 口径** `full_keys ≥ 50`）。  
- 列：`Label,TMin,TMax,XMin,XMax,YMin,YMax,Note`（时间为 **uint32 秒** 等约定与 bench 一致）。

### 2.3 点级真值 vs 当前 bench（§0.1a / AGENT §1.0a）

- **权威真值**：段命中当且仅当 **∃ 采样点 ∈ 时空窗**；返回整段。  
- **段键 `0xE6`**：`UserKeySpatioTemporalInWindow` 实为 **时间区间 ∧ 段 MBR ∩ 窗**，**宽于**真值；`full_keys` / `-VerifyKVResults` 只保证 **full 与 prune 在同一 MBR 谓词下一致**，**不**等价于点级正确。  
- **V2 value**：`st_meta_smoke` / `st_bucket_ingest_build` 在 **`--segment-points-csv`** 下写入 **段头 + 点列**（`rocks-demo/segment_value_codec.hpp`），供后续值域精判；旧库可能仅 28 字节段头。

### 2.4 加速比（TSV 叙事）

- `speedup_F0_to_F*`：Fork 内 full / prune。  
- `speedup_V_to_F*`：**Vanilla 壁钟 / prune 壁钟**（相对官方）。  
- `st_prune_vs_full_baseline_sweep.ps1` 在 **`-VanillaAsBaseline`** 时以 Vanilla 填 **`full_*` 列语义**（配合 `VanillaWallDbPathsCsv` / 缓存）；详见 `VANILLA` 文档 §6–§8。

---

## 3. Fork 侧代码与方法改动（摘要）

以下内容对应 **`Method.md`** 与 **`AGENT_HANDOFF.md` §8**，便于论文 Method 对照。

| 主题 | 内容 | 主要位置 |
|------|------|----------|
| Phase A | 文件级三态：`kDisjoint` / `kIntersect` / `kContains`；`file_level_overlap_result` | `ReadOptions`、使用处见 `Method.md` |
| Phase B | `kContains` 时局部剪枝短路；块迭代器快路径 | `block_based_table_iterator.cc` |
| Phase C | VM：**跳过掩码 → 候选 SST 表**；`NextForwardFileIndexSkippingStPrune` 用 `lower_bound` | `version_set.cc`（`EnsureStCandidateFilesFromSkipMask` 等） |
| Phase D | Bench CLI：`--virtual-merge`、`--virtual-merge-auto`、`--vm-time-span-sec-threshold` | `st_meta_read_bench.cpp` |
| Phase E | `sst_manifest` 下 **adaptive key gate**：`--sst-manifest-adaptive-key-gate`、`--adaptive-overlap-threshold` | `st_meta_read_bench`、文档 `docs/BEST_736_CONFIG.md`（若存在） |
| 文件级 ST | 前向扫描：与窗不相交则 **不 `OpenTable`**；range deletion 文件不跳过 | `LevelIterator`（`AGENT` §8.2） |
| 时间桶 + BVH | `file_level_time_bucket_rtree_enable`：桶内 BVH → `file_skip_mask_` → `st_candidate_files_` | `version_set.cc`（`AGENT` §8.3） |
| 块内 | `FindKeyForward` + `UserKeySpatioTemporalDisjointFromPruneScan` | `block_based_table_iterator.cc`、`st_meta_user_key.cc` |

**736 -focused 推荐参数（`Method.md`）**（仅作复现起点，与 `EXPERIMENTS` §2.3 默认可能并存，以脚本实际传参为准）：

- `--prune-mode sst_manifest`  
- `--virtual-merge --virtual-merge-auto --vm-time-span-sec-threshold 21600`  
- `--sst-manifest-key-level 1 --sst-manifest-adaptive-key-gate --adaptive-overlap-threshold 0.5`  
- `--time-bucket-count 736 --rtree-leaf-size 8`  

**复现命令示例**（单库 736 + 手工窗 CSV）：见 `Method.md` 文末 `powershell ... st_prune_vs_full_baseline_sweep.ps1` 块。

---

## 4. 数据、目录与建库参数

### 4.1 常用数据路径（默认 `D:\Project\data\`）

| 路径 | 含义 |
|------|------|
| `processed/wuxi/segments_meta.csv`、`segments_points.csv` | 无锡段元数据 + 点列（V2 ingest） |
| `verify_wuxi_segment_1sst` / `164sst` / `776sst` 或 `736sst` | Fork 段库三档（第三档以实际目录为准） |
| `verify_wuxi_segment_manysst`、`verify_wuxi_segment_bucket3600_sst` | 另一套命名（见 `EXPERIMENTS` §4） |
| `experiments/<name>/` | TSV、`wuxi_ablation_run_meta.json` 等 |

### 4.2 建库（与 `BUILD_AND_EXPERIMENTS.md` §4 一致）

- **164 档示例**：`st_meta_smoke.exe` + `--st-segment-keys` + `--segment-meta-csv` + **`--segment-points-csv`** + `--flush-every 500` + `--disable-auto-compactions` + `--write-buffer-mb 1` 等（见原文）。  
- **3600s 桶**：`st_bucket_ingest_build.exe` + `--bucket-sec 3600` + `--segment-points-csv` + `--reset-target-db` 等。

---

## 5. Vanilla（上游 RocksDB）复现要点

### 5.1 原则（文档层）

- **单一原生态目录**灌入加工数据；**不**为 Vanilla 复制 Fork 的 1/164/736 三档。  
- 主指标：**同窗 `vanilla_wall_us`**（及可选 `block_read` / `bytes_read`）。

### 5.2 构建

1. **`tools/bootstrap_rocksdb_vanilla.ps1`**：上游 **`facebook/rocksdb`**，默认 tag **`v11.0.4`**（可用 `-Tag` 覆盖）；产出 **`rocksdb_vanilla/build/rocksdb.lib`**（生成器可能是 Ninja / VS，见脚本）。  
2. **`rocks-demo`**：CMake 需指向 vanilla 库；**`VANILLA_STANDIN_LINK_FORK_LIB=OFF`** 时，`st_segment_window_scan_vanilla` / `st_vanilla_kv_stream_ingest` **链接上游** `rocksdb.lib`；**`=ON`** 时仅链接 fork，**stderr 打 WARNING**，**不得**当正式「相对官方」结论。  
3. **Fork 与 rocks-demo 的 `CMAKE_BUILD_TYPE` 须一致**（建议 **Release**）。

### 5.3 工程参数（与当前源码一致）

- **`st_vanilla_kv_stream_ingest`**：`Options` 设 **`persist_user_defined_timestamps = false`**（避免 RocksDB 11 默认 UDT 导致内部键与「仅剥 8 字节 footer」的窗解码不一致）。  
- **输入格式**：`st_fork_kv_stream_dump` 产出 **WUXIKV01**（magic 8 字节 + 重复 `u32 key_len, u32 val_len, key, value`）；ingest 对 key/value 分次 `read` 后 **分别** 用 `gcount()` 校验（修复「连续两次 read 只认最后一次 gcount」问题）。  
- **`st_segment_window_scan_vanilla`**：打开 Options 同样 **`persist_user_defined_timestamps = false`**；全表 `SeekToFirst`…`Next`，`UserKeyFromInternalKey` + 与 fork 对齐的 **E5/E6 窗判定**；输出 `vanilla_segment_scan keys=... wall_us=...`。

### 5.4 推荐数据路径（Phase 1 过渡）

- Fork 段库 **不能**被上游稳定迭代时：  
  `st_fork_kv_stream_dump --db <fork_db> --out <dump.kvs>` →  
  `st_vanilla_kv_stream_ingest --db <empty_vanilla_dir> --in <dump.kvs> [--compact]`。  
- 一键三副本（历史）：`tools/build_wuxi_vanilla_replica_dbs.ps1`（默认三 Fork 源 → 三个 `*_vanilla_replica`）；与 **§1.1 单一 V** 叙事冲突时，以 **单次灌入单一目录** 为准。  
- **缓存壁钟**：`cache_wuxi_vanilla_wall_baseline.ps1` 的 **JSON 键必须与** `st_segment_window_scan_vanilla` **打开的 DB 路径一致**，否则 TSV 可能出现 **`vanilla_as_baseline_unavailable`**。

### 5.5 工程现状提示

- `st_segment_window_scan_vanilla.cpp` 中可能仍含 **调试用 `DEBUG` 输出**（如样本 `Get`、前几项 `internal_key.size`）。**重新部署做正式对比前**建议删除或 `#ifdef` 掉，避免 stderr 污染与性能微扰。  
- 无锡主脚本 **`run_wuxi_segment_ablation_1_164_776.ps1`**：默认 **`VanillaAsBaseline`** + 若存在则 **`fork_leaf_vanilla_replica`** 等逻辑；与 **单一 Vanilla 路径** 的长期目标仍可能对齐中（见 `VANILLA` §7 与 `EXPERIMENTS` §3.1）。

---

## 6. 无锡三库三模式主流程（脚本级）

| 项目 | 说明 |
|------|------|
| 主入口 | `tools/run_wuxi_segment_ablation_1_164_776.ps1` |
| 底层 sweep | `tools/st_prune_vs_full_baseline_sweep.ps1`：`-RocksDbPathsCsv`、`-WindowsCsv`、`-PruneMode`、`-FullScanMode window`、`-OutTsv`、可选 `-VerifyKVResults`、**`-VanillaAsBaseline`**、**`-VanillaWallDbPathsCsv`** |
| 默认 bench 风格 | `EXPERIMENTS` §2.3：VirtualMerge、**`TimeBucketCount = 736`**（时间桶个数，**不等于** SST 个数）、adaptive gate 等 |
| 汇总 | `tools/summarize_wuxi_ablation_three_modes.py`（`--pooled` 等） |
| 输出 | 默认 `data/experiments/wuxi_ablation_1_164_776_<timestamp>/`，写 **`wuxi_ablation_run_meta.json`**（含 `used_736sst_fallback`、`rocks_db_paths_csv`、`windows_csv`） |

---

## 7. 最小复现检查清单（按顺序）

**全新部署**时与 **§0.2** 一致；日常增量开发可从第 2 步起。

1. **读** `EXPERIMENTS_AND_SCRIPTS.md` **§0**，确认消融维度、真值口径、Vanilla 定义。  
2. **构建** Fork `rocksdb.lib` 与 **`rocks-demo`**（Release，二者一致）。  
3. **准备** 无锡三档 Fork DB（**通常已由保留的 `data/verify_wuxi_*` 提供**；若丢失则从 `processed/wuxi/*.csv` 按 `BUILD_AND_EXPERIMENTS` 重建）+ **cov 12 窗 CSV**（来自 `tools/`，随仓库恢复）。  
4. **（可选）Vanilla**：`bootstrap_rocksdb_vanilla.ps1` → 配置 **`VANILLA_STANDIN_LINK_FORK_LIB=OFF`** → 编译 **`st_vanilla_kv_stream_ingest`**、**`st_fork_kv_stream_dump`**、**`st_segment_window_scan_vanilla`** → dump/ingest 或缓存壁钟。  
5. **跑** `st_prune_vs_full_baseline_sweep.ps1` 或 `run_wuxi_segment_ablation_1_164_776.ps1`，保留 **TSV + meta JSON**。  
6. **汇总** 并核对 **736 回退**、**Vanilla 路径** 与 **`Record.md`** 记录。  
7. **改造实验循环**：修改 `rocksdb/` 或 `rocks-demo` → **全量或增量重编**受影响 target → 用 **同一 `data/` 库与同一窗 CSV** 再跑 sweep，对比 TSV（与旧 `data/experiments` 或 `Record.md` 对照）。

---

## 8. 变更溯源（本文件未逐行列 diff）

- **协议与脚本**：以 Git 历史为准；文档变更集中在 **`EXPERIMENTS_AND_SCRIPTS.md`**、**`AGENT_HANDOFF.md`**、**`docs/VANILLA_ROCKSDB_BASELINE.md`**。  
- **Fork 读路径 / bench**：`rocksdb/db/version_set.cc`、`table/block_based/block_based_table_iterator.cc`、`rocksdb/table/st_meta_user_key.cc`、`rocks-demo/st_meta_read_bench.cpp`（见 `Method.md`、`AGENT` §8）。  
- **Vanilla 工具链**：`rocks-demo/st_vanilla_kv_stream_ingest.cpp`、`st_fork_kv_stream_dump.cpp`、`st_segment_window_scan_vanilla.cpp`。

---

*若本复现说明与某次本地实验不一致，以当次 **`wuxi_ablation_run_meta.json`**、`OPTIONS-*` 与 **`Record.md`** 为准。*

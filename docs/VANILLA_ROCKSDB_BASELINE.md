# 官方 RocksDB（Vanilla）基线实验协议 — 与 fork 数据对齐

**目的**：以后所有对外「加速比」在叙事上可声明为 **相对官方 RocksDB**；在工程上把 **Vanilla baseline**、**Fork full（关剪枝）**、**Fork prune** 三种测量拆开记录，避免混称 `full_scan`。

**非目标**：本文不替代 `Method.md` 里的实现细节；只规定 **数据形态、二进制边界、指标与阶段**。

---

## 1. 三个名字（以后 TSV / 图表统一用）

| 代号 | 含义 | 二进制 |
|------|------|--------|
| **V** | **Vanilla**：上游 RocksDB（无本 fork ST 剪枝与相关 manifest 扩展逻辑），在同一 **逻辑数据集** 上跑与论文一致的扫描 workload | 仅链接 **官方** `rocksdb` 构建产物 |
| **F0** | **Fork full**：本 fork，`ReadOptions` **不**启用 `experimental_st_prune_scan`（与当前 `st_meta_read_bench` 的 full 路径一致） | `st_meta_read_bench.exe`（fork） |
| **F*** | **Fork prune**：本 fork，`--prune-mode` 取 `manifest` / `sst` / `sst_manifest` 等 | 同上 |

**加速比（建议同时报两条）**

- `speedup_F0_to_F*` = F0 壁钟 / F* 壁钟（**现有**「fork 内 full vs prune」）
- `speedup_V_to_F*` = V 壁钟 / F* 壁钟（**新增**「相对官方」）

### 1.1 Vanilla 数据与 SST 布局（与 Fork 三档 **脱钩**）

**原则（当前共识）**

- **`rocksdb_vanilla` = 原生态 RocksDB**：灌入的是 **已加工好的轨迹数据**（与 fork 实验同一逻辑数据集即可），**不**为 Vanilla **人为复刻** fork 上的 **1-SST / 164-SST / 736-SST（或按桶多 SST）** 三套物理库。
- **SST 个数、分层、何时 compaction** 一律交给 **原生态 RocksDB** 的默认行为与选项；Vanilla 基线 **不**把「SST 档数」当作官方侧的消融维度。
- **我们关心的主指标**：在约定的 **同一批时空查询窗** 上，测 **查询壁钟**（`wall_us`；可选 `block_read` / `bytes_read`）。即：**时间（及 IO）是观测目标**，不是「再扫三套官方布局」。
- **Fork 侧**仍可保留 **1 / 164 / 多 SST** 三档，用于 **剪枝与读路径** 的对比；与 Vanilla 对比时，论文表述应写清：**V 为单一原生态库上的查询时间**，F* 为各 fork 布局上的 prune 时间，避免暗示「官方也做了三档 SST 划分」。

**工程备注**：历史上曾有「按 fork 源库分别导出 → 三个 `*_vanilla_replica`」的做法，便于对齐物理路径；与 **§1.1** 冲突时，**以单一原生态灌库 + 查询时间为准**，旧流程可标为过渡或废弃。

---

## 2. 核心约束：Vanilla **不能**保证直接 `DB::Open` 本仓库现有目录

Fork 产出的 `verify_wuxi_segment_*` 可能包含：

- Manifest / `VersionEdit` 中的 **自定义 tag**（未知 tag 官方版常忽略，但**不保证**所有版本行为一致）
- SST **表属性**中的 ST 尾字段（官方表工厂通常 **忽略未知 property**，读取块布局仍可能成功）
- 若将来引入 **非官方 comparator / merge / 专用 TableFactory`**，则 Vanilla **无法**打开同一目录

因此协议规定 **Phase 0 探测**；失败则走 **Phase 1 副本**（推荐默认路径）。

---

## 3. Phase 0 — 打开性探测（低成本）

**输入（Fork 源库探测时）**：可为 `verify_wuxi_segment_1sst`（及 164 / 736）等 fork 路径。**Vanilla 单一基线库**建好后，Phase 0/2 的 **V** 只对 **该原生态目录** 探测与扫窗（见 **§1.1**）。

**步骤**：

1. 使用与数据 **OPTIONS** 中声明一致的 **官方 RocksDB 大版本**（上游 **GitHub release tag** 以 [facebook/rocksdb releases](https://github.com/facebook/rocksdb/releases) 为准；bootstrap 默认 `v11.0.4`。若 OPTIONS 里是 fork 内部版本号，应对齐 **最接近** 的上游 tag 再构建 `ldb` 或最小 `open_db_probe`）。
2. 只读打开：`DB::OpenForReadOnly` 或 `ldb dump --db=...` 试读 `MANIFEST` + 列出一个 SST 的 properties。
3. **判定**  
   - **PASS**：能打开且能 `NewIterator` 扫全表（或至少迭代 default CF）→ 可进入 **Phase 2** 直接在同一物理目录上跑 **V**（仍建议记录官方 commit id）。  
   - **FAIL**：记录失败原因（manifest / OPTIONS / comparator 等）→ **必须**走 **Phase 1**。

---

## 4. Phase 1 — Vanilla 物理副本（官方 API 写入的 V 目录）

**与 §1.1 对齐**：目标通常是 **一个**（而非与 fork 三档一一对应的三个）**仅由官方 RocksDB API 写入** 的目录；键值与加工后轨迹语义一致即可与 **F0/F\*** 同窗对比。

**历史命名**：下文仍出现 `verify_wuxi_segment_*_vanilla_replica` 时，指 **单次副本产物的一种目录名**；**不**要求为 1sst / 164 / bucket 各建一个 replica。

**目标**：得到 **仅由官方 RocksDB API 写入、OPTIONS 可控** 的目录，其中 **user key / value** 与 fork 侧 **逻辑数据集** 一致（或经明确约定的无损映射），从而 **V 与 F0/F* 在数据上可比**。

**推荐实现（二选一或组合）**

1. **在线拷贝（fork 读 → vanilla 写）**  
   - 使用 **fork** 二进制以只读方式打开源库，`Iterator` 全表扫描，对每条记录调用 **vanilla** `WriteBatch::Put` 写入新库。  
   - Vanilla 侧使用 **默认 `BlockBasedTable` + `BytewiseComparator`**（与当前无锡 OPTIONS 中 `comparator=leveldb.BytewiseComparator` 一致），**关闭** fork 专用 compaction / ST 表选项（若副本工具需写 OPTIONS，则显式不写 ST 扩展字段）。  
   - 灌满后 `CompactRange` 一次，固定最终 SST 布局，再跑 **V** 与 **F0**（F0 仍打开 **fork 源库** 或 **fork 灌的副本库** 需在设计里二选一并写死；建议 **F0/F* 始终对 fork 源库**，**V 只对 vanilla 副本**，三者通过「键值一致 + 同窗」对齐）。

2. **离线 SST 重打包（仅当 fork SST 官方可读时）**  
   - 若 Phase 0 已验证官方能读 fork SST，可用官方 `SstFileReader` + `SstFileWriter` 重写目录；否则不依赖此路径。

**验收**：在样本窗上，`V` 与 `F0` 的 **窗内 key 计数**（及可选 hash）一致；与现有 `-VerifyKVResults` 语义对齐。

---

## 5. Phase 2 — 统一 workload（与现有 12 cov 窗对齐）

- **窗 CSV**：`tools/st_validity_experiment_windows_wuxi_random12_cov_s42.csv`（及 `EXPERIMENTS_AND_SCRIPTS.md` §0.3 规则）。  
- **扫描语义**：与当前 `st_meta_read_bench` 的 `--full-scan-mode window` 一致 —— 全表迭代，user key 解码后对窗计数（**V** 与 **F0** 必须使用 **同一套** 段 key 解码逻辑；实现上可将 **仅解码 + 窗判定** 放到 **header-only 或极小共享源**，由 vanilla 与 fork 各编一次，避免行为漂移）。  
- **IO 统计**：V 与 F0/F* 均记录 `wall_us`、`block_read_count`、IOStats `bytes_read`（若官方 API 可接 PerfContext/IOStatsContext，与 fork 对齐字段名便于汇总）。

---

## 6. Phase 3 — 产出列（建议 TSV 扩展）

在现有 `st_prune_vs_full_baseline_sweep.ps1` 输出基础上增加（或并行写 `ablation_vanilla.tsv`）：

| 列 | 说明 |
|----|------|
| `vanilla_wall_us` | **V** 该窗壁钟 |
| `vanilla_block_read` / `vanilla_bytes_read` | 可选 |
| `fork_full_wall_us` | 现 `full_wall_us`（建议逐步改名为此列） |
| `prune_wall_us` | 保持 |
| `speedup_fork_full_to_prune` | `fork_full / prune` |
| `speedup_vanilla_to_prune` | `vanilla / prune` |
| `speedup_vanilla_to_fork_full` | 可选：衡量 fork 全表相对官方的开销 |

---

## 7. 工程落地顺序

**已落地（最小集）**

1. `rocks-demo/st_segment_window_scan_vanilla.cpp`：链接 **上游** `rocksdb_vanilla/build/rocksdb.lib`；窗内 E5/E6 解码在本文件内联，与 fork `st_meta_read_bench` 的 `window` 计数语义对齐。  
2. `tools/bootstrap_rocksdb_vanilla.ps1`：克隆官方 `facebook/rocksdb`（默认 tag **`v11.0.4`**，可用 `-Tag` 覆盖；**`v11.2.0` 不是上游公开 tag**）到 `rocksdb_vanilla/` 并编译 `rocksdb.lib`（需能访问 `github.com`；克隆失败会退出并写入 `rocksdb_vanilla/README_UPSTREAM.txt`）。无 Ninja 时脚本默认改用 **Visual Studio 17 2022** `-A x64` 生成 `build/Release/rocksdb.lib`。  
3. `tools/st_prune_vs_full_baseline_sweep.ps1`：支持 `-VanillaSegmentBenchExe`；每窗先跑 **V**；TSV 增加 `vanilla_wall_us` 等列；有 **V** 时 **`ratio_wall` = vanilla_wall / prune_wall**。  
4. `tools/aggregate_wuxi_ablation_runs.py`：行上若有 `vanilla_wall_us`，speedup 与 baseline 侧 QPS 用 **Σvanilla / Σprune**。  
5. `tools/run_wuxi_segment_ablation_vanilla.ps1`：**强制**已构建 `st_segment_window_scan_vanilla.exe` 后跑无锡三库三模式消融（**脚本仍偏旧**：与 **§1.1** 对齐时，应改为 **单一 Vanilla DB 路径** + 与 fork 三档对照的叙事，见 `EXPERIMENTS_AND_SCRIPTS.md` §0.1）。

**仍待扩展**：单一原生态灌库工具链与消融入口；Phase 0 打开性探测；将列名 `full_wall_us` 显式改为 `fork_full_wall_us`。

### 7.1 Phase 1 实操 — 原生态灌库 → 测 **查询时间**

**与 §1.1 一致的目标**：得到 **一个**（或少数明确约定个）**仅由官方 RocksDB API 写入** 的目录，其中 **user key / value** 与加工后轨迹语义一致；**不**要求与 fork 的 1/164/736 物理布局一一对应。

**推荐主路径**

1. 从 **加工数据**（如 `segments_meta.csv` + `segments_points.csv`）用 **链接 `rocksdb_vanilla` 的工具** 直接 `Put`（或经 `st_vanilla_kv_stream_ingest` 等）灌入 **空目录**；使用 **默认 `BlockBasedTable` + `BytewiseComparator`**，**不显式**复刻 fork 的 flush/compaction 实验矩阵，把 **SST 形态交给引擎**。
2. 灌完后可选一次 `CompactRange`（若希望稳定重复跑）；记录 **实际 SST 个数** 供论文描述即可。
3. 对 **该目录** 跑 `st_segment_window_scan_vanilla`（或等价扫描），在同一 **12 窗 CSV** 上记 **`vanilla_wall_us`**。

**过渡路径（与 §1.1 不完全一致）**：若暂时只能从 **已有 fork 库** 导出再 ingest，历史上可用 `st_fork_kv_stream_dump` + `st_vanilla_kv_stream_ingest`；`build_wuxi_vanilla_replica_dbs.ps1` 曾 **按三个 fork 源各建一个副本** —— 便于工程对齐，但 **不符合**「Vanilla 不做 1/164/736 三划分」的叙事时，应迁移到 **单次灌入单一原生态库**。

```text
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\build_wuxi_vanilla_replica_dbs.ps1
```

（上列为 **旧版三副本** 脚本，仅供过渡；缓存 `cache_wuxi_vanilla_wall_baseline.ps1` 的 `-RocksDbPathsCsv` 在 **§1.1** 下应指向 **一个** Vanilla 库路径重复与多 fork 行对照，或待脚本改版。）

### 7.2 离线 / 代理失败时（仅管道连通性，**不是**真正的 V）

若暂时无法 `git clone` 或构建 `rocksdb_vanilla`，可在 **rocks-demo** 配置时打开 CMake 选项 **`VANILLA_STANDIN_LINK_FORK_LIB=ON`**：仍会生成 `st_segment_window_scan_vanilla.exe`，但链接的是本仓库 **`../rocksdb/build/rocksdb.lib`（fork）**。运行时向 stderr 打印一条 **WARNING**。聚合脚本中的 `vanilla_wall_us` 等列**不得**解释为相对官方 RocksDB；仅用于跑通 `run_wuxi_segment_ablation_vanilla.ps1` 等流水线。

```text
cd rocks-demo\build
cmake .. -DCMAKE_BUILD_TYPE=Release -DVANILLA_STANDIN_LINK_FORK_LIB=ON
cmake --build . --config Release --target st_segment_window_scan_vanilla
```

---

## 8. 与旧表述的衔接

- **`full_wall_us`** 仍为 **Fork full（F0）**；**`vanilla_wall_us`** 为 **V**。有 Vanilla 时对外「相对官方」用 **Vanilla 为分母**（`ratio_wall` 与聚合已切换）。  
- 未构建 `st_segment_window_scan_vanilla.exe` 时，与旧行为一致（仅 fork full / prune）。

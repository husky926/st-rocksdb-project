# Manifest 与 SST 改造：分开说明与「消融式」证据

本文回答：**能否把 Manifest 侧与 SST 侧的改造分开，说明各自有效？**  
结论先说在前面：

- **工程实现上**：当前 **`ReadOptions::experimental_st_prune_scan`** **一个开关**同时驱动 **文件级（Version / Manifest 元数据）**、**块级（SST 主索引尾）**、**块内键级** 三条路径，**没有**单独的「只关文件级、只关块级」的官方 bench 开关。  
- **科学上仍可做「消融叙事」**：用 **`st_meta_sst_diag --window`** 把每个 SST 标成 **`file vs query: INTERSECTS / DISJOINT`**，再结合 **bench 数字**，把实验分成两类：  
  - **文件级帮不上忙**（所有相关 SST 与窗 **均相交**）时仍出现的收益 → 主要归因 **SST（索引块级 + 必要时块内键）**；  
  - **存在与窗文件级不相交** 的 SST 且 bench 显示 **几乎不读盘 / 不打开该文件** → **Manifest 持久化的文件级时空域 + LevelIterator 跳过 OpenTable** 起关键作用。

下面分层定义 → 往期实验对照表 → 如何向非专业人士一句话区分。

---

## 1. 三层机制分别指什么（与「Manifest / SST」的对应）

| 层 | 主要落点 | 读路径在干什么 | 「算 Manifest 还是 SST」 |
|----|----------|----------------|---------------------------|
| **L1 文件级** | **`FileMetaData::st_file_meta`** 经 **Manifest（VersionEdit / custom tag）** 持久化；来源与 SST 表属性 **`st_file_bounds`** 一致 | **`LevelIterator`**：若文件时空包络与查询窗 **不相交**，**不 `OpenTable`** 该 SST（含 range deletion 等保守例外） | **Manifest + Version 读路径**（元数据在 manifest；语义与 SST 聚合一致） |
| **L2 块级** | **SST 主索引**每条 value 上的 **时空尾**（块 MBR + 时间范围等） | **`BlockBasedTableIterator`**：索引前进时 **整块 data block** 与窗不相交则 **不读该块** | **纯 SST 结构 + 迭代器**（不依赖「是否已 OpenTable」之外的 manifest 字段做跳过，但 **必须先能打开该 SST**） |
| **L3 块内键级** | 仍在 **SST 内**，解码 **user key** 的 \((t,x,y)\) | **`Next()`** 路径上跳过 **窗外** 键，减少 **对外可见键数** 与部分值侧工作；**整块 IO 仍可能发生**（若块 MBR 仍与窗相交） | **SST 读路径 / 迭代器** |

**说明**：L1 依赖 **Manifest 里已有** `has_st_file_meta`；L2/L3 依赖建表时打开 **`experimental_spatio_temporal_meta_in_index_value`** 等选项，在 **SST 文件内部** 写入索引尾与属性。三者在本 fork 里 **默认一起开**，故 **完整效果** = 三层叠加。

---

## 2. 为什么不能简单叫「跑两次 bench 自动减一层」

- 若要做 **严格软件消融**（例如编译掉 `LevelIterator` 里的 `StFileDisjoint...`），需要 **改源码或加内部开关**；当前仓库 **未提供** `st_meta_read_bench` 的「仅块级 / 仅文件级」CLI。  
- **可行的「实验消融」**是：**选窗 + diag 判定文件级是否可能生效**，再解读 bench —— 这也是下面 **§3** 的做法，证据全部来自 **`Record.md` 已记载结果** 与 **`st_meta_sst_diag`** 语义。

---

## 3. 往期实验：按「谁在工作」分组（可写进汇报）

### 3.1 更偏 **SST（块级为主）** —— 文件级 **全部 INTERSECTS**

**现象**：`st_meta_sst_diag` 对 **每个 SST** 打出 **`file vs query window: INTERSECTS`**，说明 **Manifest 文件级无法整文件跳过**；但 **块级 `would skip` 很大**，bench 上 **`bytes_read` 仍显著低于宽窗**。

| 案例 | 库 / 窗（摘要） | diag 结论 | bench / 记录要点 | 归因（汇报用语） |
|------|-----------------|-----------|------------------|------------------|
| **Geolife 西向窗** | `verify_traj_st_full`，`west_x_both_intersect`（x∈[114,115.5] 等） | 两 SST **均为 INTERSECTS**；**000009** 块级 **skip 11670 / keep 1777**，**000011** **skip 0 / keep 5747** | **`bytes_read` 远低于宽窗**（约 **32MB vs 78.7MB** 量级，见 Record） | **SST 索引块级时空尾** 在 **文件仍须打开** 的前提下，**大量跳过 data block** |
| **Geolife 近 119°** | `x_near_119_boundary` | 两文件 **均 INTERSECTS**；**000011** **skip 5746 / keep 1** | **`bytes_read` 约 55MB** 量级，低于宽窗 | 同上，**块级**主导（一侧文件几乎整块不相交） |
| **Geolife 2×SST 宽/尖窗（块内过滤前）** | 宽窗与尖窗 | 文件级均 **INTERSECTS**；**仅 1 个 data block** 与两窗 **块级不相交** | **`prune_scan keys` 宽尖相同（约 1279138）**，**full−prune=76** 与 **跳 1 块** 一致 | **纯块级**时 **选择性极弱**（布局导致），用来解释 **为何后来需要块内键过滤** |
| **Compact 后西向反差** | `verify_traj_st_compact_work` + 西向 | 三文件 **均 INTERSECTS**；块级 skip **合计仅 3** | **`bytes_read` 回到宽窗量级** | **同窗不同布局 → 块级 skip 集合大变**；再次说明 **SST/块界** 决定块级收益，**不是 manifest 坏了** |

**汇报一句话**：*在「所有文件与查询窗在文件级包络上仍相交」的前提下，我们仍观察到读盘大幅下降，这只能来自 **打开 SST 之后** 的 **索引块级剪枝**（以及后续的块内键过滤对键数的塑造），与 **Manifest 整文件跳过**无关。*

---

### 3.2 更偏 **Manifest（文件级）+ 其余层叠加** —— 存在 **DISJOINT** 文件

**现象**：diag 中 **至少一个 SST** **`file vs query: DISJOINT`**；bench 常出现 **`keys≈0`、极低 `bytes_read`** 或 **明显少打开文件**。

| 案例 | 库 / 窗（摘要） | diag 结论 | bench / 记录要点 | 归因（汇报用语） |
|------|-----------------|-----------|------------------|------------------|
| **PKDD 东向窗** | `verify_pkdd_st` / `verify_pkdd_st_large`，`east_x_file_disjoint` | **6/6（或全库文件）DISJOINT**（数据经度在包络西，窗在东） | **E1**：`keys=0`，**极低 `bytes_read`**；**14M Phase A**：**`ratio_bytes≈0`，`prune_wall` 近 0** | **若无文件级跳过**，仍须 **逐个 OpenTable** 再靠块级收尾；此处 **整库文件与窗文件级不相交** → **LevelIterator 不打开这些 SST** 是 **接近零 IO** 的合理解释 |
| **Manifest 演示脚本** | `st_manifest_disjoint_demo.ps1`，窗 **x∈[120,122]** 等 | **`000011` 文件 DISJOINT**，`000009` INTERSECTS | **`prune_scan keys=1`**，**`bytes_read≈55MB`**，**`block_read` 远小于双文件全开** | **明确有一个 SST 在文件级被跳过**；另一半读盘来自 **仍相交文件** 内的块级 + 块内键 |
| **PKDD E3 宽窗** | 宽窗下多文件 | **5/6 INTERSECTS，1 个 SST 整文件 DISJOINT**（时间与窗上界组合） | 与 E1 **宽窗 IO** 叙述一致 | **文件级**解释「为何某一整文件可不进读路径」 |

**汇报一句话**：*当诊断显示 **整个 SST 的时空包络与查询窗不相交** 时，读路径可以 **根本不打开该文件**；这依赖 **Manifest 里持久化的文件级 ST 域**（与 SST 内聚合的 `st_file_bounds` 一致）。**东向 PKDD** 与 **演示脚本** 是这一类最干净的例子。*

---

### 3.3 **块内键过滤（SST）** —— 与 **bytes** 可脱钩

| 案例 | 要点 | 记录结论 |
|------|------|----------|
| **Geolife 宽窗 + 块内过滤上线前后** | 块级仍读 **所有相交块** | **`prune_scan keys`** 从 **~1279138** 降到 **~3803**；**`bytes_read` / `block_read` 可不变** | 说明 **L3** 主要改 **语义键数与 CPU/值侧路径**，**不单独等价于「读盘减半」**；与 L2 **整块 IO** 的边界要写清 |

---

## 4. 汇总表：「消融」汇报怎么说不夸大

| 想证明什么 | 推荐用的证据 | 不宜说的过头话 |
|------------|--------------|----------------|
| **SST（块级索引尾）有效** | **西向 / 近 119°**：**文件全 INTERSECTS** + **diag 块级 skip 巨大** + **bench bytes 降** | 不说成「仅靠 manifest」 |
| **Manifest（文件级元数据 + LevelIterator）有效** | **PKDD 东向**、**演示脚本 DISJOINT 文件**、**E3 单文件 DISJOINT** | 不说成「东向效果与 SST 无关」—— **DISJOINT 判定仍来自与 SST 一致的包络** |
| **块内键过滤（SST）有效** | **keys 数量级变化**（1279138→3803） | 不说「读盘必然同比例下降」—— **Record 已写明 bytes 可不变** |
| **布局敏感性** | **compact 后西向 bytes 回升** | 说明 **块级**依赖 **物理块界**，不是逻辑 bug |

---

## 5. 与「14.29M 整体实验」的关系

- **大规模 bench**（`prune_vs_full_pkdd_large_*.tsv`）报告的是 **B0 vs A 整体**（三层全开），**不能**在同一张表里自动拆成「百分之多少来自 manifest」。  
- **拆分叙事**应 **叠加** 本文 **§3** 的 **diag + 往期窗型**：例如对外说——  
  - *「**东向类**结果主要体现 **文件级**（整 SST 不进路径）；*  
  - ***西向/边界类**在 Geolife 上体现 **块级**在 **文件仍打开** 时仍能 **少读大量块**；*  
  - ***宽窗**上 **键数** 的大幅下降来自 **块内键过滤**。」*

---

## 6. 若以后要做「真·开关级消融」（可选工程）

1. 在 fork 内增加 **只禁用 LevelIterator 文件跳过** 的 debug 选项，保留块级/键级 → 在东向窗上应看到 **bytes 上升**（被迫 OpenTable + 走块级）。  
2. 或构造 **无 `has_st_file_meta` 的旧 manifest**（仅理论）对比 **同 SST 文件** —— 实现成本高，**一般审稿可用 §3 几何消融替代**。

---

## 7. 相关文档与工具

| 项 | 路径 / 命令 |
|----|-------------|
| **浏览器示意图 + 条形图（本页数字可视化）** | **`docs/st_manifest_vs_sst_ablation_charts.html`** |
| 块级 + 文件级 diag | `rocksdb/build/tools/st_meta_sst_diag.exe --window ...` |
| 东向演示 | `tools/st_manifest_disjoint_demo.ps1` |
| 硬对比 Phase A | `docs/st_rocksdb_hard_baseline_experiment.md` |
| 设计路线图 | `docs/sst_and_manifest_plan.md` |
| 流水账原文 | `Record.md`（检索「文件级」「块级」「west」「east」「DISJOINT」） |
| 14M 对外说明 | `docs/st_experiment_14m_explainer_and_design.md` |

---

*维护：若增加「仅文件级/仅块级」bench 开关，请在本文件 §2、§6 更新并补一组对比数字。*

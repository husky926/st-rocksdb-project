# 与「无剪枝 RocksDB 读路径」硬对比实验设计

## 目标

在 **同一数据库、同一二进制、同一查询窗** 下，量化：

- **基线（Baseline）**：**`ReadOptions.experimental_st_prune_scan.enable = false`**，**`SeekToFirst` + `Next` 扫完整 CF** —— 等价于 **未启用时空剪枝时的标准全表扫描**（仍为本 fork 的 SST/索引格式，含 ST index tail 的解码，但 **不进行文件级/块级/块内 ST 剪枝**）。
- **实验（Pruned）**：**`enable = true`** 且给定窗 —— 当前 **`st_meta_read_bench`** 的 **`prune_scan`** 路径。

由此得到 **`bytes_read`、`block_read_count`、`wall_us`** 的 **prune/full 比值**，直接回答：*「相对不做剪枝的全表遍历，我们要少读多少盘、少做多少块读？」*

> **说明**：这不是 **上游 facebook/rocksdb 未改源码的 exe** 直接 `Open` 你们带 ST 尾巴的 SST（格式不兼容）。**Phase A** 是 **同一 fork 内 ablation**，在论文中应表述为 **「相对无 ST 剪枝的迭代路径」**；**Phase B**（可选）再谈 **另建无 ST 表、vanilla 打开** 的工程对照。

---

## Phase A（必做）：`st_meta_read_bench` 单次双跑

工具已实现：

- **默认**（不加 `--no-full-scan` / `--no-prune-scan`）：先 **full_scan**，再 **prune_scan**，并打印 **`block_read_ratio(prune/full)`** 等。
- **`--no-prune-scan`**：仅 **full_scan**（用于只测基线 IO，或冷缓存下分进程测）。
- **`--no-full-scan`**：仅 **prune_scan**（现有 sweep 用法）。

**指标**（每次窗、每库各跑一轮；关注 **IOStatsContext delta** 行）：

| 标签 | 含义 |
|------|------|
| `full_scan` | 全表 keys 数、块读、**bytes_read**（回答该窗无关：基线 IO **与窗无关**，全表相同） |
| `prune_scan` | 窗内逻辑 keys、块读、**bytes_read** |

**指标解读**：**以 `IOStatsContext bytes_read` 为主**；`PerfContext block_read_count` 在 **full** 与 **prune** 之间 **不一定单调**（全表顺序读可能合并读、剪枝路径会多次打开 index/表，`block_read` 反而更大），与 **「谁从磁盘多读了字节」** 不完全等价。

**重要**：**`full_scan` 的 `bytes_read` 与查询窗无关**（每次扫全库）。因此：

- **横轴应理解为「查询窗」对 **prune** 的影响**；**full** 列在 **同一库重复跑** 时 **应近似常数**（缓存热后更小）。
- 论文/报告中推荐报告：**`prune_bytes / full_bytes`**（单次会话内同一次 bench 调用打印的比值最干净），以及 **`key_selectivity(prune/full)`**。

**一键扫多窗**（PKDD 或 Geolife 窗表）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\st_prune_vs_full_baseline_sweep.ps1 `
  -RocksDbPaths D:\Project\data\verify_pkdd_st `
  -WindowsCsv D:\Project\tools\st_validity_experiment_windows_pkdd.csv `
  -OutTsv D:\Project\data\experiments\prune_vs_full_pkdd.tsv
```

产出 TSV：`label, full_keys, full_block_read, full_bytes_read, full_wall_us, prune_keys, prune_block_read, prune_bytes_read, prune_wall_us, ratio_bytes, ratio_block_read, ratio_wall, key_selectivity`。

**柱状图（浏览器）**：**`docs/st_prune_vs_full_pkdd_charts.html`**（`ratio_bytes` 横向条形图 + 页内讲解）。

**随机窗（E5）**：削弱手选查询 —— **`docs/st_validity_experiment_design.md` §E5**、`tools/generate_random_query_windows.py`、`tools/run_random_prune_vs_full_pkdd.ps1`、`tools/summarize_prune_vs_full_tsv.py`。

---

## Phase B（可选）：与「无 ST 尾巴 SST」的 vanilla 对比

**前提**：用 **`st_meta_smoke` 不加 `--st-keys`** 等方式写入 **无 `experimental_spatio_temporal_meta_in_index_value` 尾巴** 的表（或关闭该选项建库），**键编码与 ST 库不同**，数据需 **同一 CSV 逻辑点** 可比对 **全表大小** 是否接近。

**限制**：vanilla **无法**在你们当前 **ST SST** 上验证；必须 **第二份库**。适合作为 **补充实验**，非本次 Phase A 替代。

---

## 成功标准（硬对比）

- **同一库、同一 bench 调用**下 **`prune_scan bytes_read << full_scan bytes_read`** 在 **选择性窗**（东向、尖窗、西向等）上 **可重复**。
- **宽窗**：**`prune_keys ≈ full_keys`** 时，**`ratio_bytes` 接近 1** 或仍 <1（块级仍可能略剪）—— 与机制一致即可，不要求「宽窗也十倍加速」。
- 结果写入 **`Record.md`**：**实验目的 / 结果 / 是否达预期 / 为什么**。

---

## 与此前「仅 prune」sweep 的关系

- **`st_validity_sweep.ps1`**：**`--no-full-scan`**，只测 **剪枝路径**，适合 **多样窗对比**。  
- **`st_prune_vs_full_baseline_sweep.ps1`**：**不测** `--no-full-scan`，每次窗触发 **full+prune**，专门服务 **相对无剪枝基线的倍数**。

---

*维护：若 `st_meta_read_bench` 输出格式变更，请同步更新 `st_prune_vs_full_baseline_sweep.ps1` 的正则解析。*

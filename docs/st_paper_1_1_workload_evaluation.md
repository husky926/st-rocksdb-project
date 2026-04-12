# 论文 §1.1 对齐：Workload 评估设计、实验协议与结果占位

本文档把 **`AGENT_HANDOFF.md` §1.1**（学术论文终极目标）落实为 **可写进论文「实验 / 评估」节的结构**：**主张**、**基线**、**数据集与规模**、**查询 workload**、**可复现协议**、**指标**、**已有结果**与**建议补跑项**。

---

## 1. 论文主张（对应 §1.1）

**要论证的结论（建议正文表述）**：在 **轨迹点级 ST 键** 的 RocksDB 部署中，引入 **Manifest / SST 时空元数据 + 读路径剪枝** 后，对 **一类时空范围查询 workload**，相对明确基线可 **稳定降低读放大与（在热缓存协议下）迭代延迟**；收益随 **查询窗与数据重叠度、LSM 文件切分** 变化，并在 **随机窗分布** 上呈现 **可报告的分布统计**（而非仅单个手工构造窗）。

**刻意不单独声称（除非另做实验）**：

- 已优于 **所有** 真实业务访问路径（点查、二级索引等）。
- 已优于 **上游未改动的 vanilla RocksDB** 打开同一份 SST（格式不兼容；见 Phase B）。
- 已在 **严格冷盘、多机** 上完成全文级统计检验。

---

## 2. 基线定义（论文方法段落可直接缩写）

| 代号 | 名称 | 实现 / 语义 |
|------|------|-------------|
| **B0：无剪枝全 CF 迭代** | `full_scan` | 本 fork，`ReadOptions.experimental_st_prune_scan` **关闭**，`SeekToFirst` + `Next` 扫 **整个 Column Family**。仍走正常 LSM 索引与 data block 读路径；**不按时空窗跳过文件/块/键**。与查询窗无关。 |
| **A：剪枝迭代** | `prune_scan` | 同上，但开启 **`experimental_st_prune_scan`** 并传入 **轴对齐 (t,x,y) 查询窗**；在已实现路径上可含 **文件级 / 块级 / 块内 key** 剪枝（以当前 fork 为准）。 |
| **B1：键空间范围扫描（可选扩展）** | *未在 `st_meta_read_bench` 中实现* | 将查询窗映射为 **user key 的字典序下界/上界**，`Seek(lower)` 起至超出上界止；**无 ST 元数据剪枝**。若 key 中 t/x/y 与字典序不完全一致，边界保守，可能 **≈ 全 CF**。实现需与 **0xE5 键编码** 一致；可作为未来工作或与 B0 并列讨论。 |
| **B2：Vanilla 库（可选）** | Phase B | 无 ST index tail 的平行建库；**键编码可能不同**，仅作补充对照。见 **`docs/st_rocksdb_hard_baseline_experiment.md`**。 |

**主文推荐主指标**：**`ratio_bytes = prune_bytes_read / B0_bytes_read`**（同进程、同窗、同库），辅以 **`key_selectivity = prune_keys / full_keys`**（B0 的 `full_keys` 即全 CF 键数）。

---

## 3. 数据集与规模（支撑「真实 / 规模」叙事）

| 数据集 | 加工脚本 / 目录 | 示例库路径 | 规模（示例） |
|--------|-----------------|------------|--------------|
| **Geolife 点列** | `data/processed/segments_points.csv` | `data/verify_traj_st_full` | ~**1.28M** keys（见 `Record.md`） |
| **PKDD（Porto）子集** | `tools/process_pkdd_train.py` → `data/processed/pkdd/` | `data/verify_pkdd_st` | 默认 **10 万轨迹** 点列；与 `PKDD_ENVELOPE` 一致 |

**多 SST 布局**：对同一逻辑数据做 **compact 拆文件**（如 `verify_traj_st_compact_work`），重复同窗实验，观察 **IO 趋势是否随布局变化仍合理**（**E2**）。

---

## 4. Workload 设计（与仓库实验一一对应）

### W1：设计查询窗集合（E1）

- **Geolife**：`tools/st_validity_experiment_windows.csv`（**12** 窗：宽、尖、文件级 DISJOINT、多几何等）。
- **PKDD**：`tools/st_validity_experiment_windows_pkdd.csv`。
- **工具**：`tools/st_validity_sweep.ps1`（`--no-full-scan`，多样窗 **`prune_scan` 行为**）；与 Phase A 组合时改用 **`st_prune_vs_full_baseline_sweep.ps1`**。

**论文写法**：**代表性手工窗** 覆盖 **高/中/低重叠** 与 **文件级 DISJOINT** 可触发情形。

### W2：多 LSM 布局（E2）

- **双库扫同一窗表**：`-RocksDbPathsCsv "db1,db2"`（注意 PowerShell 传参方式见 `AGENT_HANDOFF.md` §7）。
- **论文写法**：说明 **相同查询、不同 SST 切分** 下 **绝对 IO** 会变，但 **剪枝相对 B0 的比值 / 趋势** 与 **diag（INTERSECTS/DISJOINT）** 一致。

### W3：诊断 spot-check（E3）

- `st_meta_sst_diag --window` + **`st_manifest_disjoint_demo.ps1`**（东向 DISJOINT）。
- **论文写法**：**机制一致性**：bench 观测与 index / manifest 推断对齐。

### W4：Query trace（E4）

- 自建与 E1 **同列 CSV** 的窗序列，模拟 **业务查询 trace**；汇总 **Σ bytes_read**、总 **wall_us** 或 **吞吐**。
- **论文写法**：贴近 **「查询序列」** 而非单窗。

### W5：随机窗 + Phase A（E5）— **削弱「挑窗」**

- **生成**：`tools/generate_random_query_windows.py`（**PKDD envelope** 内均匀随机轴对齐盒；**`--seed`** 可复现；可选 **`wide_pkdd` 锚点**）。
- **一键**：`tools/run_random_prune_vs_full_pkdd.ps1 -RandomCount N -Seed S`。
- **汇总**：`tools/summarize_prune_vs_full_tsv.py <TSV>` → **min / p10 / p50 / p90 / max**。
- **论文写法**：报告 **随机窗上 `ratio_bytes` 分布**；讨论 **稀疏窗**（`key_selectivity≈0`）与 **高重叠尾**（`ratio_bytes→1`）并存。

### W6：分层 / 非空窗（建议补做，强化 §1.1）

- **分层**：按 **`key_selectivity` 或 `prune_keys`** 分桶报告分位数（避免「中位数极低」被误读为仅空白窗）。
- **非空窗**：拒绝采样使每窗 **`prune_keys ≥ K`**（需后处理 TSV 或生成器扩展）。

---

## 5. 可复现协议（审稿友好）

建议在论文「实验设置」中 **固定写明**：

1. **硬件 / OS / 文件系统**（至少机型与盘类型）。
2. **构建**：Release；`rocksdb` 与 `rocks-demo` **同一 `CMAKE_BUILD_TYPE`**。
3. **二进制**：`st_meta_read_bench`、`st_meta_sst_diag` 路径与 **commit hash**。
4. **DB 准备**：`st_meta_smoke` 参数（`--st-keys`、`--max-points`、CSV 路径）；库目录 **空目录起灌**。
5. **缓存协议**（至少二选一写清）：
   - **热缓存 / 稳态**：同进程内多窗顺序跑，**`fill_cache=false`** 下关注 **比值**；或  
   - **冷启动**：每次查询新进程 + 清 OS 缓存（若做，需 **多次重复取中位数**）。
6. **随机性**：E5 的 **`--seed`**、`N`、envelope 版本（PKDD 子集规模）。

**暂缓项**（原 §7）：全文 **重复跑方差**、**严格冷热对照** —— 若审稿要求再补。

---

## 6. 指标与图表清单

| 指标 | 含义 |
|------|------|
| `bytes_read`（IOStatsContext） | 主结果；**跨窗 B0 为常数** |
| `block_read_count` | 辅助；与 bytes **不一定单调** |
| `wall_us` | 延迟；受缓存影响大 |
| `prune_keys` / `key_selectivity` | 语义选择性 |

**建议图表**：

1. **手工窗**：`ratio_bytes` 条形图（Geolife / PKDD）；**E2** 分组柱或并排。
2. **E5**：`ratio_bytes` **CDF 或分位数表** + 直方图（见 `docs/st_prune_vs_full_random_n50_s42_charts.html` 类页面）。
3. **机制**：**E3** 示意图或表（文件 DISJOINT vs INTERSECTS）。

---

## 7. 已有结果（本仓库可引用）

### 7.1 PKDD：随机窗 E5（Phase A）

- **产物**：`data/experiments/prune_vs_full_pkdd_random_n50_s42.tsv`  
- **协议**：`N=50`，`seed=42`，**含 `wide_baseline_anchor`**；`summarize_prune_vs_full_tsv.py` 输出如下（**随机子集 50 窗**）：

**`ratio_bytes = prune_bytes / full_bytes`（越低越好）**

| 子集 | n | min | p10 | p50 | p90 | max |
|------|---|-----|-----|-----|-----|-----|
| `random_w*` only | 50 | 0.003112 | 0.003112 | **0.005873** | **0.180609** | **0.924688** |

**解读（可写入讨论）**：**中位数极低** 与 **envelope 内均匀随机** 导致大量 **稀疏相交** 窗一致；**p90 仍 ≪ 1** 说明尾部并非全部为 1；**max≈0.92** 表明存在 **随机大窗** 与数据 **高重叠**（与锚点 **`ratio_bytes≈0.89`** 同量级）。**`key_selectivity`** 在随机窗上 **p50=0**，需在文中 **并列说明** 或补 **W6 分层**。

### 7.2 Geolife / 块内过滤 / DISJOINT 演示

- **权威流水账**：`Record.md`（宽窗 **`prune_keys` 从 ~1.28M 降至 ~3803**、Manifest 东窗 **`keys=1`** 等）。
- **设计对照**：`docs/st_validity_experiment_design.md`（E1–E5）、`docs/st_rocksdb_hard_baseline_experiment.md`（Phase A/B）。

### 7.3 PKDD 大规模子集（300k 轨迹 / ~14.29M 键）+ Phase A

- **加工**：`process_pkdd_train.py --max-segments 300000 --out data/processed/pkdd_large`  
- **库**：`data/verify_pkdd_st_large`（`st_meta_smoke --st-keys`，**14288269** keys）  
- **设计窗 TSV**：`data/experiments/prune_vs_full_pkdd_large_design_windows.tsv`（**12** 窗，与 `st_validity_experiment_windows_pkdd.csv` 同款）  
- **随机窗**：`generate_random_query_windows.py --envelope pkdd_large_300k`；示例 **`n=25, seed=43`** → `data/experiments/prune_vs_full_pkdd_large_random_n25_s43.tsv`
- **浏览器图（条形 + 随机窗分桶）**：**`docs/st_prune_vs_full_pkdd_large_charts.html`**

**墙钟（`ratio_wall = prune_wall_us / full_wall_us`）**：设计窗 **ALL n=12**：**p50≈0.153，p90≈0.245**（**`east_x_file_disjoint`：prune≈24µs vs full≈2.83s**）。随机 **25** 窗：**p50≈0.0009，p90≈0.141**（中位数多为 **极稀相交** 窗）。

**读字节（`ratio_bytes`）**：设计窗 **p50≈0.287**；随机 **p50≈0.0019，p90≈0.318**。

*说明：同一会话内多窗顺序跑，**OS 页缓存偏热**；论文中应写明协议；若需冷盘需分进程/清缓存并重复取中位数。*

### 7.4 待你补全后写入论文的表格（检查清单）

- [ ] **E1/E2** 主表：每窗 **`ratio_bytes`、布局（2-SST vs compact）**（TSV 路径记入 `Record.md`）。
- [ ] **E5 多 seed**（如 42, 43, 44）或 **N=100**：报告 **p50/p90 区间**。
- [ ] **E4 trace**（若采用）：总 IO、总时间、与 **均匀抽窗** 对比一句。
- [ ] **W6**（若采用）：按 **`prune_keys`** 分层的分位数表。

---

## 8. 限制与诚实边界（讨论节建议段落）

1. **B0 不是「线上默认查询」**，而是 **无 ST 剪枝时整 CF 迭代的上界式基线**；更细 **B1 键范围扫描** 待实现或作为未来工作。
2. **随机窗均匀于 envelope** 不等价于 **真实出租车查询分布**；E4 trace 或 **加权随机** 可加强 §1.1。
3. **Phase B（vanilla）** 非本次必达；格式与键空间可能不可比。

---

## 9. 命令速查（复现）

```powershell
# E5 PKDD 随机窗 + Phase A + 汇总
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\run_random_prune_vs_full_pkdd.ps1 -RandomCount 50 -Seed 42

# 仅汇总已有 TSV
python D:\Project\tools\summarize_prune_vs_full_tsv.py D:\Project\data\experiments\prune_vs_full_pkdd_random_n50_s42.tsv

# PKDD 大规模库：设计窗 Phase A
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\st_prune_vs_full_baseline_sweep.ps1 `
  -RocksDbPaths D:\Project\data\verify_pkdd_st_large `
  -WindowsCsv D:\Project\tools\st_validity_experiment_windows_pkdd.csv `
  -OutTsv D:\Project\data\experiments\prune_vs_full_pkdd_large_design_windows.tsv

# 随机窗（先 python 生成 CSV，envelope 对齐 pkdd_large）
python D:\Project\tools\generate_random_query_windows.py --envelope pkdd_large_300k --count 25 --seed 43 `
  --include-anchor wide_pkdd --out D:\Project\data\experiments\random_windows_pkdd_large_n25_s43.csv
```

---

*维护：§1.1 实验补跑后，更新 **§7 表格** 与 **`Record.md`**；若新增 B1 bench，在本文件 **§2** 更新实现状态。*

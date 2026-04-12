# ST 改造：有效性实验设计（对齐 `AGENT_HANDOFF.md` §1.0 / §7）

## 目的

验证 **Manifest + SST index 尾 + 读路径剪枝** 在 **多样查询**、**不同 LSM 布局** 下是否仍出现 **与设计一致** 的现象（**IO、`prune_scan keys`、墙钟** 随 **窗几何 / 文件是否 DISJOINT** 合理变化）。  
**不要求**：多轮重复统计、严格冷/热协议、完整 ablation（见 AGENT **§7 暂缓**）。

## 实验 E1：多样查询窗（单库）

- **数据**：`data/verify_traj_st_full`（2×L0 SST，~128 万键）。  
- **窗集合**：`tools/st_validity_experiment_windows.csv`（**12** 个：宽窗基准、尖窗、东向文件级 DISJOINT、西向双相交、窄 y、多段 t、y 偏移、近 119° 边界、微盒等）。  
- **工具**：`st_meta_read_bench --no-full-scan`（仅 prune 路径）。  
- **一键**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\st_validity_sweep.ps1
```

可选把 TSV 落盘：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\st_validity_sweep.ps1 -OutTsv D:\Project\data\experiments\validity_sweep_full.tsv
```

- **记录**：将 **控制台摘要** 或 **TSV** 追加到 `Record.md`（日期 + 「E1」）。  
- **预期（定性）**：  
  - **`east_x_file_disjoint`**：`bytes_read` **低于** `wide_baseline`（少读一个 SST）；`keys` **可远小于** 宽窗（块内过滤 + 地理稀疏）。  
  - **`wide_baseline` vs `sharp_spatiotemporal`**：`keys` **锐减**；IO 可能仍接近（块级剪枝对尖窗未必多剪块）。  
  - **不同 t/y 切片**：`keys` **随窗变化**，无单一常数异常。

## 实验 E2：多 SST 布局（同窗子集）

- **数据**：`data/verify_traj_st_compact_work`（若不存在，用 `tools/copy_compact_traj_st.ps1` 从 full 复制并 compact，见 `Record.md`）。  
- **窗**：与 E1 **相同 CSV**（脚本对多个 **`-RocksDbPaths`** 各跑一遍；**勿用 `-Db`**，与 PowerShell **`-Debug`** 冲突）。  
- **一键**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\st_validity_sweep.ps1 `
  -RocksDbPathsCsv "D:\Project\data\verify_traj_st_full,D:\Project\data\verify_traj_st_compact_work" `
  -OutTsv D:\Project\data\experiments\validity_sweep_two_dbs.tsv
```

（**勿**在 `-File` 一行里写 `-RocksDbPaths @(...)`：外层 `powershell.exe` 会把第二个路径拆成独立记号，触发「无法将路径识别为 cmdlet」。若已在 **交互式 PowerShell** 里用 **`&` 调脚本**，仍可用 **`-RocksDbPaths @('a','b')`**。）

- **预期（定性）**：同一窗下 **`block_read_count` / `bytes_read`** 可因 **SST 个数与层** 与 **2-SST 原件** 不同；**相对关系**（例如东窗仍应 **较宽窗省 IO**）应 **保持趋势**。

## 实验 E3：文件级 / 块级对照（ spot-check）

不必对 12 窗全跑 diag；对 **2～3 个代表窗** 跑 **`st_meta_sst_diag --window`**，与 bench 对照：

| 代表窗 | 脚本 / 命令 |
|--------|-------------|
| 宽窗 + 尖窗 | `tools/st_diag_align_read_bench.ps1` |
| 东向 DISJOINT | `tools/st_manifest_disjoint_demo.ps1` |

确认 **`file vs query window: INTERSECTS / DISJOINT`** 与 E1/E2 中 **`bytes_read` 变化** 叙述一致。

## 实验 E4：Query trace（可选）

- 将窗写入 **CSV**（列与 `st_validity_experiment_windows.csv` 相同：`Label,TMin,TMax,XMin,XMax,YMin,YMax,Note`）。  
- 用 **`st_validity_sweep.ps1 -WindowsCsv <你的文件>`** 批量跑；**粗汇总** `sum(bytes_read)` / 总 `wall_us` 即可。

## 实验 E5：随机查询窗（削弱「手选窗利好 ST」质疑）

**动机**：E1/E2 的 **12 窗** 与 PKDD 窗表仍属 **人为设计**；与 **`full_scan` 的 Phase A 比值** 搭配时，审稿/答辩可质疑 **挑窗**。E5 在 **数据全局包络** 内 **均匀随机** 生成轴对齐窗（时间 + lon + lat），用 **同一 Phase A 协议** 扫一遍，报告 **`ratio_bytes` 分布**（min / p10 / p50 / p90 / max），并可选 **prepend 一条固定 wide 锚点** 与手设计对照。

- **生成**：`tools/generate_random_query_windows.py`  
  - **`--envelope pkdd_100k`**（默认）：与 **`data/processed/pkdd`**（10 万轨迹子集）一致。  
  - **`--envelope pkdd_large_300k`**：与 **`data/processed/pkdd_large`**（**30 万轨迹**，`process_pkdd_train.py --max-segments 300000`）实测包络一致，用于 **`verify_pkdd_st_large`**。  
  - **`--seed`** 固定可复现；**`--include-anchor wide_pkdd`** 首行写入与 **`st_validity_experiment_windows_pkdd.csv`** 同款的 **wide** 几何（label **`wide_baseline_anchor`**）。  
  - 可调：**`--min-t-span` / `--max-t-frac` / `--min-x-span` / `--max-x-frac`** 等，避免窗退化或过满。

- **扫窗**：`tools/st_prune_vs_full_baseline_sweep.ps1 -WindowsCsv <生成的 CSV>`（与 Phase A 相同）。

- **汇总**：`tools/summarize_prune_vs_full_tsv.py <产出的 TSV>`，输出 **全部分位** 与 **`random_w*` 子集**（排除锚点）的分位。

- **图（浏览器）**：**`docs/st_prune_vs_full_random_n50_s42_charts.html`**（与 **`prune_vs_full_pkdd_random_n50_s42.tsv`** 对应；重跑后需同步页内 **`ROWS`** 数据）。

- **一键（PKDD）**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\run_random_prune_vs_full_pkdd.ps1 -RandomCount 50 -Seed 42
```

（**`-RandomCount 100`** 可加大样本；**`-NoAnchor`** 则仅随机窗。）

- **记录**：TSV 路径 + **`summarize` 控制台输出** 写入 **`Record.md`**（「E5」）。  
- **读结果**：若 **p50 仍显著 &lt; 1** 且 **p90 不恒为 1**，说明 **非个别神窗** 才有收益；若 **大量窗 ratio≈1**，说明 **随机窗常与数据强相交**，与 **§1.1「普遍收益需 workload 建模」** 一致，应在文中 **并列叙述**。

## 成功标准（有效性，非论文终稿）

- **无崩溃**、**无解析失败**（TSV 中 `error` 列为空）。  
- **东向窗**相对 **宽窗** 出现 **可重复的 IO 下降**（同机、同二进制、单次跑即可）。  
- **多样窗**下 **`prune_scan keys` 有合理分布**，而非全库常数。  
- 与 **E3 diag** 无 **明显矛盾**（例如 diag 标 DISJOINT 而 bench 仍读满两文件 `bytes`，则需排查）。

---

## 附：PKDD（Porto 出租车）复现

- **加工**：`tools/process_pkdd_train.py` → `data/processed/pkdd/`（默认 **10 万轨迹**；全量见脚本 `--all-segments`）。  
- **窗 CSV**（12 列格式与 E1 相同）：**`tools/st_validity_experiment_windows_pkdd.csv`**（**勿与 Geolife 窗混用**）。  
- **灌库**：`st_meta_smoke --db data/verify_pkdd_st --csv data/processed/pkdd/segments_points.csv --st-keys --max-points -1`（**空目录**）。  
- **E1**：`st_validity_sweep.ps1 -RocksDbPaths <verify_pkdd_st> -WindowsCsv ...\st_validity_experiment_windows_pkdd.csv -OutTsv data/experiments/validity_sweep_pkdd_e1.tsv`  
- **E2**：`copy_compact_traj_st.ps1 -SourceDb ...\verify_pkdd_st -TargetDb ...\verify_pkdd_compact_work`，再 **`-RocksDbPathsCsv "verify_pkdd_st,verify_pkdd_compact_work"`** 与同一张 PKDD 窗表；示例产物：**`data/experiments/validity_sweep_pkdd_e2_two_dbs.tsv`**。  
- **E3**：`st_meta_sst_diag --window` 的 **6 个数** 与 **PKDD 窗**一致（**先 x_min y_min x_max y_max** 顺序同 Geolife）；详见 **`Record.md`「2026-04-06 — PKDD」**。  
- **注意**：`copy_compact_traj_st.ps1` 末尾自动 **diag** 仍使用 **Geolife 默认宽窗**；对 PKDD 库该段输出 **无效**，请用手动 **`--window`** 重跑 diag。
- **可视化**：**`docs/st_validity_visualization_pkdd.md`**（表 + Mermaid）；**`docs/st_validity_charts_pkdd.html`**（柱状图）。

---

## 附：与「无剪枝全表扫」硬对比（Phase A）

- **文档**：**`docs/st_rocksdb_hard_baseline_experiment.md`**  
- **脚本**：**`tools/st_prune_vs_full_baseline_sweep.ps1`**（同一 bench 进程内 **`full_scan` + `prune_scan`**，产出 **`ratio_bytes = prune_bytes / full_bytes`**）。  
- **说明**：基线为 **本 fork 内关闭 `experimental_st_prune_scan` 的全表迭代**；**full 的 `bytes_read` 与查询窗无关**，每窗重复测量用于 **缓存热化** 下的对比时，可关注 **`ratio_bytes` 趋势**。

---

---

## 论文 §1.1（Workload 评估成文）

- **完整设计 + 协议 + 可引用结果表 + 待补项**：**`docs/st_paper_1_1_workload_evaluation.md`**（与 **`AGENT_HANDOFF.md` §1.1** 对齐）。

## 对外说明（非专业人士 / 14.29M 实验）

- **B0、A、full_scan、prune、查询窗、Manifest/SST 改动、机制与「是否有效」**：**`docs/st_experiment_14m_explainer_and_design.md`**
- **Manifest vs SST 分层 + 往期实验消融叙事（diag + 东向/西向等）**：**`docs/st_manifest_vs_sst_ablation_evidence.md`**

*维护：窗表或脚本变更时同步本页与 `AGENT_HANDOFF.md` §7。*

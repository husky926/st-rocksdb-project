# Project 目录说明（整理用）

本文说明 `D:\Project` 顶层各目录职责，以及 `data/` 下常见内容。**权威进度与实验约定**仍以 `AGENT_HANDOFF.md`、`Record.md` 为准。

---

## 顶层目录

| 目录 / 文件 | 作用 |
|-------------|------|
| **`rocksdb/`** | **主 fork**：官方 RocksDB 源码 + 已合并的 **时空索引（ST）扩展**（index value 尾巴、`st_file_bounds`、读路径剪枝、`st_meta_sst_diag` 等）。**编译**在此目录的 `build/` 产出 `rocksdb.lib`、`st_meta_sst_diag.exe` 等。 |
| **`rocks-demo/`** | **示例与基准工程**：链上 `../rocksdb/build/rocksdb.lib`，提供 `st_meta_smoke`、`st_meta_read_bench`、`st_meta_compact_existing`、`traj_db_audit` 等 **可执行文件** 的源码与 `CMakeLists.txt`。业务逻辑、灌库、读基准多在这里实现。 |
| **`rocksdb-sst-ext/`** | **已删除（历史归档）**。原仓库仅存早期合并笔记与代码片段；实现已全部并入 `rocksdb/table/`。合并说明见 **`docs/rocksdb_index_builder_merge_notes.md`**。 |
| **`tools/`** | PowerShell / Python 脚本：`st_validity_sweep.ps1`、`process_trajectories.py`、`copy_compact_traj_st.ps1` 等。 |
| **`docs/`** | 设计说明、实验设计、可视化与**本文**。 |
| **`data/`** | 原始 zip、加工 CSV、**可再生**的 RocksDB 实验库（见下）。 |
| **`AGENT_HANDOFF.md`** | 给维护者 / AI 的交接：目标、工具表、实验路线 §7、`Record.md` 写法约定。 |
| **`Record.md`** | 实验流水账（目的 / 结果 / 是否符合预期 / 原因）。 |
| **`README.md`** | RocksDB 改造模块说明（与源码对照）。 |

---

## `rocks-demo` vs `rocksdb` 怎么分工？

- **`rocksdb`**：存储引擎与表格式；ST 相关 **C++ 核心**（`IndexValue`、builder、iterator、`version_set` 文件级剪枝等）。  
- **`rocks-demo`**：调用 RocksDB API 的 **独立 CMake 工程**，便于快速写 benchmark、smoke、审计，而不把大量实验代码堆在官方树里。

二者需 **同一构建类型（如 Release）** 链接，见 `AGENT_HANDOFF.md` §5。

---

## `data/` 目录

| 路径 | 作用 | 是否建议长期保留 |
|------|------|------------------|
| **`README.txt`** | `data/` 使用说明 | **保留** |
| **`processed/segments_points.csv`** | 轨迹点长表，供 `st_meta_smoke --csv --st-keys` | **保留**（或按需重跑 `process_trajectories.py` 再生） |
| **`processed/segments_meta.csv`** | 段级时间与 MBR 汇总 | **保留** |
| **`*.zip`** | Geolife / T-drive / Porto 等**原始数据** | **保留**（除非磁盘极紧张且可再从外网下载） |
| **`verify_traj_st_*`** | 用 `st_meta_smoke` 灌好的 **RocksDB 目录** | **可再生**，可不纳入备份；删后用命令重建 |
| **`experiments/verify_split_on`、`verify_split_off`** | `run_st_experiments.ps1` 生成的库 | **可再生** |
| **`experiments/*.tsv`** | sweep 结果摘要 | **建议保留**（体积小，便于对齐 `Record.md`） |
| **`bench_st_meta/`** | 早期 bench 的 CSV/SVG 等 | 视需要保留；无 DB 时体积很小 |

**重建全量 ST 库（示例）**（空目录、`st_meta_smoke` 已编译）：

```bat
st_meta_smoke.exe --db D:\Project\data\verify_traj_st_full --csv D:\Project\data\processed\segments_points.csv --st-keys --max-points -1
```

---

## 本次整理可能已删除的内容

为减少体积与混淆，以下类型目录/文件**若存在则可删、且可用脚本再生**：

- `data/verify_traj_st_full`、`verify_traj_st_compact_work`、`verify_traj_st_keys`
- `data/experiments/verify_split_on`、`verify_split_off`
- `experiment_logs/*.log`（`run_st_experiments.ps1` 可再生成）

若你克隆仓库后发现没有上述 DB 目录，按 `AGENT_HANDOFF.md` 与上表命令重建即可。

---

*维护：若新增顶层目录或移动实验产物默认路径，请同步更新本文件。*

# Build & Experiments (Windows)

**Experiment/script map (authoritative):** see [`EXPERIMENTS_AND_SCRIPTS.md`](../EXPERIMENTS_AND_SCRIPTS.md) at the repo root — **§0 pre-experiment standards** (Local/Global/L+G × 1/164/736 SST, 12 windows with no empty windows, vanilla RocksDB baseline definition), ablation definitions, Wuxi window CSV standards, `run_wuxi_segment_ablation_1_164_776.ps1`, 776/736 fallback, and output layout. This file focuses on **build steps** and **legacy DB recipes**; avoid duplicating the full script inventory here.

---

This repo contains:

- `rocksdb/`: RocksDB source (built as a library).
- `rocks-demo/`: small C++ tools/executables used to build DBs and run spatial-temporal (ST) pruning benchmarks.
- `tools/`: PowerShell/Python scripts to run repeatable experiments and produce TSV/HTML outputs.
- `data/`: datasets, processed inputs, generated RocksDB databases, and experiment outputs.

The instructions below target **Windows 10/11 + PowerShell + MSVC**.

---

## 0) Prerequisites

- Visual Studio (or Build Tools) with **C++ Desktop** workload
- CMake
- Ninja
- Python 3

Important:

- **Build type must match** between `rocksdb` and `rocks-demo` (both `Release` or both `Debug`).
  Mismatching build types can cause `DB::Open` crashes or subtle ABI/runtime issues.

---

## 1) Build RocksDB (library)

From a Visual Studio **Developer Command Prompt** (x64):

```bat
cd /d D:\Project\rocksdb
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build build --target rocksdb -j 8
```

Outputs (example):

- `D:\Project\rocksdb\build\rocksdb.lib`

---

## 2) Build `rocks-demo` tools (executables)

From the **same** Developer Command Prompt (x64), and **same** `CMAKE_BUILD_TYPE`:

```bat
cd /d D:\Project\rocks-demo
cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_FLAGS=/utf-8 -DCMAKE_C_FLAGS=/utf-8
cmake --build build --target st_meta_read_bench st_meta_smoke st_bucket_ingest_build st_meta_compact_existing -j 8
```

Outputs (example, under `rocks-demo/build/`):

- `st_meta_read_bench.exe`: benchmark runner (full scan vs prune scan + diagnostics)
- `st_meta_smoke.exe`: build a RocksDB from `segments_meta.csv` (segment-key workload)
- `st_bucket_ingest_build.exe`: build bucketed SST layout (e.g. `--bucket-sec 3600`)
- `st_meta_compact_existing.exe`: compact an existing DB to target SST size

If you run CMake/Ninja from plain PowerShell and see errors like `cannot open include file: 'algorithm'`,
you are missing the MSVC environment. Use the Developer Command Prompt or call `vcvars64.bat` before building.

---

## 3) Data layout

Typical inputs and outputs used by scripts:

- **Processed inputs**
  - `data/processed/wuxi/segments_meta.csv`: processed Wuxi trajectory segments metadata
  - (others under `data/processed/` for PKDD etc.)

- **Generated RocksDBs (two naming styles may coexist)**
  - **SST-count layout (default for `docs/st_ablation_wuxi_1sst_vs_manysst.html`):**
    - `data/verify_wuxi_segment_1sst` — **1** SST
    - `data/verify_wuxi_segment_164sst` — **164** SST
    - `data/verify_wuxi_segment_776sst` — target **776** SST (if missing, scripts may fall back to `verify_wuxi_segment_736sst` with a warning; see root tracking doc)
  - **Build-style names (still used by some scripts, e.g. dual-regime):**
    - `data/verify_wuxi_segment_manysst`: Wuxi DB with ~**164 SST** (many small SSTs)
    - `data/verify_wuxi_segment_bucket3600_sst`: Wuxi DB bucketed by 3600s (expected **736 SST**)
    - `data/verify_wuxi_segment_full`: optional single-SST baseline name (if you build it)

- **Experiment outputs**
  - `data/experiments/<exp_name>/ablation_*.tsv`: TSV results for plotting/HTML

---

## 4) Build DBs (Wuxi)

### 4.1 Build 164-SST DB (`verify_wuxi_segment_manysst`)

This builds a DB directly from processed segments, forcing many small SSTs:

```powershell
& "D:\Project\rocks-demo\build\st_meta_smoke.exe" `
  --db "D:\Project\data\verify_wuxi_segment_manysst" `
  --segment-meta-csv "D:\Project\data\processed\wuxi\segments_meta.csv" `
  --segment-points-csv "D:\Project\data\processed\wuxi\segments_points.csv" `
  --st-segment-keys `
  --max-points -1 `
  --flush-every 500 `
  --disable-auto-compactions `
  --write-buffer-mb 1
```

Segment values are **V2** (`segval` codec in `rocks-demo/segment_value_codec.hpp`): fixed header plus packed `(unix_s, lon, lat)` per point. Legacy 28-byte values (header only) are still readable but new ingests require **`--segment-points-csv`** aligned with meta rows (`segment_id`, matching `point_count`).

Count SST files:

```powershell
(Get-ChildItem -LiteralPath "D:\Project\data\verify_wuxi_segment_manysst" -Filter "*.sst" -File | Measure-Object).Count
```

Expected: `164`

### 4.2 Build 3600s-bucket DB (`verify_wuxi_segment_bucket3600_sst`)

This builds a DB where segments are flushed per **time bucket** (`t_start // bucket_sec`).

```powershell
& "D:\Project\rocks-demo\build\st_bucket_ingest_build.exe" `
  --segment-meta-csv "D:\Project\data\processed\wuxi\segments_meta.csv" `
  --segment-points-csv "D:\Project\data\processed\wuxi\segments_points.csv" `
  --out-sst-dir "D:\Project\data\wuxi_bucket_sst_tmp" `
  --target-db "D:\Project\data\verify_wuxi_segment_bucket3600_sst" `
  --bucket-sec 3600 `
  --reset-out-sst-dir `
  --reset-target-db
```

Count SST files:

```powershell
(Get-ChildItem -LiteralPath "D:\Project\data\verify_wuxi_segment_bucket3600_sst" -Filter "*.sst" -File | Measure-Object).Count
```

Expected: `736`

---

## 5) Experiment windows (12-window baseline)

**Preferred for validated comparisons:** `tools/st_validity_experiment_windows_wuxi_random12_cov_s42.csv` — 12 windows, each bench-checked on 1-SST DB with `full_keys >= 50` (see `tools/generate_wuxi_random_windows_validated.py`).

**Fallbacks:**

- `tools/st_validity_experiment_windows_wuxi_random12_s42.csv` — uniform random in dense envelope; **not** per-window key-validated
- `tools/st_validity_experiment_windows_wuxi.csv` — hand-picked 12 scenarios

CSV columns:

- `Label,TMin,TMax,XMin,XMax,YMin,YMax,Note`

---

## 6) Run ablation (Local / Global / Local+Global)

### 6.1 Core sweep script: `tools/st_prune_vs_full_baseline_sweep.ps1`

What it does:

- For each window in a CSV:
  - runs `st_meta_read_bench.exe` **full scan** (baseline)
  - runs `st_meta_read_bench.exe` **prune scan** (one prune mode)
  - parses output into one TSV row
- Optional: `-VerifyKVResults` enables **KV correctness check** (full vs prune in-window KV set).

Key parameters:

- `-RocksDbPaths` or `-RocksDbPathsCsv`: database directories
- `-WindowsCsv`: window set CSV
- `-PruneMode`: `sst`, `manifest`, `sst_manifest` (and others depending on code)
- `-OutTsv`: output path
- `-VerifyKVResults`: enable correctness check

Example (single mode):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Project\tools\st_prune_vs_full_baseline_sweep.ps1" `
  -RocksDbPathsCsv "D:\Project\data\verify_wuxi_segment_manysst,D:\Project\data\verify_wuxi_segment_bucket3600_sst" `
  -WindowsCsv "D:\Project\tools\st_validity_experiment_windows_wuxi.csv" `
  -PruneMode sst_manifest `
  -FullScanMode window `
  -OutTsv "D:\Project\data\experiments\wuxi_ablation\ablation_sst_manifest.tsv" `
  -VerifyKVResults
```

### 6.2 Three-mode wrapper: `tools/run_wuxi_dual_regime_full_ablation.ps1`

What it does:

- Invokes the sweep script three times for the same window set:
  - `manifest` (Global)
  - `sst` (Local)
  - `sst_manifest` (Local+Global)
- Writes:
  - `ablation_manifest.tsv`
  - `ablation_sst.tsv`
  - `ablation_sst_manifest.tsv`

Example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Project\tools\run_wuxi_dual_regime_full_ablation.ps1" `
  -WindowsCsv "D:\Project\tools\st_validity_experiment_windows_wuxi.csv" `
  -RocksDbPaths "D:\Project\data\verify_wuxi_segment_manysst","D:\Project\data\verify_wuxi_segment_bucket3600_sst" `
  -OutDir "D:\Project\data\experiments\wuxi_random12_ablation" `
  -VerifyKVResults
```

Note:

- If you see `Failed to create lock file .../LOCK`, you are running multiple processes against the same DB path.
  Run experiments **serially** per DB directory.

### 6.3 Three-mode wrapper (1 / 164 / 776 SST layout): `tools/run_wuxi_segment_ablation_1_164_776.ps1`

Runs `manifest`, `sst`, and `sst_manifest` for the default three DB paths (`verify_wuxi_segment_1sst`, `164sst`, `776sst`), with the same window CSV selection order as documented in the script header (cov CSV first). Writes `wuxi_ablation_run_meta.json` under the output directory; if `776sst` is absent and `736sst` is used, the default output folder name appends `_736sst_fallback`.

Example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Project\tools\run_wuxi_segment_ablation_1_164_776.ps1" -SummarizePooled
```

`tools/run_wuxi_segment_ablation_1_164_736.ps1` is a thin forwarder for backward compatibility.

**Post-run summary:**

```powershell
python D:\Project\tools\summarize_wuxi_ablation_three_modes.py `
  D:\Project\data\experiments\<run>\ablation_manifest.tsv `
  D:\Project\data\experiments\<run>\ablation_sst.tsv `
  D:\Project\data\experiments\<run>\ablation_sst_manifest.tsv --pooled --pooled-by-db
```

Experiment output layout notes: `data/experiments/README_wuxi_ablation_layout.txt`.

---

## 7) TSV fields (what to look at)

Each TSV row corresponds to a `(db, window)` pair.

Common fields:

- `full_wall_us`, `prune_wall_us`: wall time (microseconds)
- `ratio_wall`: `prune_wall_us / full_wall_us`
- `prune_file_skipped`, `prune_file_considered`: file-level pruning counts (Global effect)
- `prune_block_index_examined`, `prune_block_index_skipped_st_disjoint`: block-level pruning counts (Local effect)
- `kv_correct`, `kv_full_inwindow_kv`, `kv_prune_inwindow_kv`: correctness results when `-VerifyKVResults` is enabled

---

## 8) HTML report

The main HTML report used in this workspace is:

- `docs/st_ablation_wuxi_1sst_vs_manysst.html`

It is a static HTML file (no build step) containing **only an SVG bar chart** (no prose tables). Update bar heights/labels after re-running experiments; keep output directory, `pooled_p50_summary.txt`, and `wuxi_ablation_run_meta.json` in sync (see root `EXPERIMENTS_AND_SCRIPTS.md`).

---

## 9) “What is this file/script for?” quick map

Full inventory: [`EXPERIMENTS_AND_SCRIPTS.md`](../EXPERIMENTS_AND_SCRIPTS.md). Short list:

- `rocks-demo/st_meta_read_bench.cpp`
  - full scan vs prune scan benchmark; prints parseable single-line stats used by scripts

- `rocks-demo/st_meta_smoke.cpp`
  - build a RocksDB from `segments_meta.csv` (segment-key workload)

- `rocks-demo/st_bucket_ingest_build.cpp`
  - build bucketed time layout (e.g. 3600s buckets) to control SST time partitioning

- `tools/st_prune_vs_full_baseline_sweep.ps1`
  - iterate windows, run bench, produce TSV

- `tools/run_wuxi_segment_ablation_1_164_776.ps1`
  - primary Wuxi **1 / 164 / 776** SST three-mode ablation (736 fallback + meta JSON)

- `tools/run_wuxi_dual_regime_full_ablation.ps1`
  - run `manifest/sst/sst_manifest` for dual-regime windows (often `verify_wuxi_segment_manysst`)

- `tools/run_wuxi_random12_vm_p50_ablation.ps1`
  - random12 cov windows + calls segment ablation script

- `tools/summarize_wuxi_ablation_three_modes.py`
  - pooled / per-DB summaries from the three `ablation_*.tsv` files

- `tools/st_validity_experiment_windows_wuxi_random12_cov_s42.csv`
  - preferred 12-window set for validated Wuxi comparisons

- `tools/st_validity_experiment_windows_wuxi.csv`
  - hand-picked 12-window set


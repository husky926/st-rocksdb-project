# Method Notes

This document records the optimization methods implemented in this project, why they were added, and how to run them. It is the single source of truth for "what we changed and why".

## Terms

- Global prune: file-level pruning (MANIFEST/SST-level metadata).
- Local prune: block/key-level pruning inside SST.
- VM: virtual-merge path (`file_level_time_bucket_rtree_enable`), used to speed up forward scans by precomputing candidate SSTs.
- Auto: runtime decision to enable VM by query time span threshold.

## Motivation: query-scoped file access (not “walk every SST in the Version”)

Native RocksDB exposes a **Version** (LSM snapshot: which SSTs exist at each level), but the stock read path does not treat **spatio-temporal query windows** as a first-class filter on **which files must be opened or iterated**. For a windowed scan, we want the iterator to **consume only query-relevant file-level metadata** and to **avoid** `OpenTable` / full forward work on SSTs that cannot contribute keys under our ST predicate.

This is **not** “load half a Version struct from disk” (the in-memory `Version` / `FileMetaData` graph may still be present). It is **read-path scoping**: the set of SSTs actually **visited** for a query should shrink to a **candidate subset** derived from extended metadata (`st_file_meta`, skip masks, candidate index lists), instead of behaving like a full scan over **all** files in the snapshot.

That gap is why this fork adds manifest-side fields, `ReadOptions.experimental_st_prune_scan`, and `LevelIterator` forward-skip logic: **query-aware file-level pruning** that native RocksDB does not provide out of the box.

## Phase A: Three-state global decision

- Added three-state overlap result:
  - `kDisjoint`: skip file
  - `kIntersect`: keep normal local pruning
  - `kContains`: query fully covers file metadata bounds
- Result is propagated through `ReadOptions.experimental_st_prune_scan.file_level_overlap_result`.

## Phase B: Contains short-circuit (local path bypass)

- When file overlap is `kContains`, local ST work is disabled for that file:
  - `block_level_enable = false`
  - `key_level_enable = false`
- Additional physical fastpath in `BlockBasedTableIterator`:
  - detect `kContains` via `file_level_overlap_result`
  - skip `AdvanceIndexPastPrunedForward` calls
  - skip key-level forward-prune activation and checks
- Safety rule: no bypass of checksum or core InternalKey correctness semantics.

## Phase C: VM candidate list acceleration

- Added candidate SST list derived from VM skip mask:
  - `EnsureStCandidateFilesFromSkipMask()`
  - `NextForwardFileIndexSkippingStPrune()` uses `lower_bound` on candidate list.
- Benefit: reduce forward scan iterator churn on many-SST workloads.

## Phase D: VM controls in benchmark CLI

- Added CLI flags in `st_meta_read_bench`:
  - `--virtual-merge`
  - `--virtual-merge-auto`
  - `--vm-time-span-sec-threshold`
- Combination rule:
  - final VM enable = `manual || auto_hit`

## Phase E: Selective local pruning (dynamic gate)

- In `sst_manifest`, added dynamic key-level gate:
  - `--sst-manifest-adaptive-key-gate`
  - `--adaptive-overlap-threshold`
- Purpose: avoid "over-pruning overhead" in high-overlap cases (especially 736 SST), while preserving local filtering when useful.

## Current 736-focused best config

- `--prune-mode sst_manifest`
- `--virtual-merge --virtual-merge-auto --vm-time-span-sec-threshold 21600`
- `--sst-manifest-key-level 1 --sst-manifest-adaptive-key-gate --adaptive-overlap-threshold 0.5`
- `--time-bucket-count 736 --rtree-leaf-size 8`

Note: `manual_VM || auto_hit` makes **VM + Auto** redundant for the “enable bucket/R-tree path” decision when VM is always on. Prefer **either** explicit VM for short-window workloads **or** tune Auto threshold to match real query spans (see `EXPERIMENTS_AND_SCRIPTS.md` / Wuxi random12 cov windows).

## Refactoring directions (how we might evolve)

1. **Policy cleanup (VM vs Auto)**  
   Treat **Auto** as the sole gate when VM is off; treat **VM** as “force file-level bucket/R-tree path”. Avoid documenting “VM+Auto” as if they were two independent features—today they OR into one boolean (`st_meta_read_bench`).

2. **Stronger file-level skipping without more Local cost**  
   Keep investing in **cheap manifest-side predicates** (disjoint / intersect / contains) and **candidate list + jump** on large-SST-count DBs. Revisit disabled SIMD / time-mask fast paths in `NextForwardFileIndexSkippingStPrune` only after profiling shows iterator overhead dominates.

3. **Seek / reverse iteration**  
   Forward `Next` is the main optimized path; **Seek**-heavy workloads still need explicit semantics (documented elsewhere). Future work: consistent ST-aware skipping on seek if product requires it.

4. **“Whole Version” vs “partitioned by time”**  
   RocksDB **Version** is a compaction snapshot, not a business time partition. True “ignore other time eras” at **DB** granularity needs **multi-directory / multi-CF / routing** at the application layer, while this fork keeps improving **single-DB file-level** pruning under one Version.

5. **Naming**  
   Rename or document **VirtualMerge** so it does not imply “virtual SST merge”; in code it primarily **gates** `file_level_time_bucket_rtree_enable` and related prewarm hooks.

6. **Evaluation**  
   Separate **Vanilla** wall clock from **fork full** when arguing correctness vs speed; keep MBR vs point-level truth distinctions for segment keys (`EXPERIMENTS_AND_SCRIPTS.md` §0.1a).

## Repro command (736 only)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Project\tools\st_prune_vs_full_baseline_sweep.ps1" `
  -RocksDbPathsCsv "D:\Project\data\verify_wuxi_segment_736sst" `
  -WindowsCsv "D:\Project\tools\st_validity_experiment_windows_wuxi.csv" `
  -PruneMode sst_manifest `
  -SstManifestKeyLevel 1 -SstManifestAdaptiveKeyGate -AdaptiveOverlapThreshold 0.5 `
  -VirtualMerge -VirtualMergeAuto -VmTimeSpanSecThreshold 21600 `
  -TimeBucketCount 736 -RTreeLeafSize 8 `
  -FullScanMode window `
  -OutTsv "D:\Project\data\experiments\wuxi_736_focus\ablation_736_best_adapt05.tsv" `
  -VerifyKVResults
```

## Files touched (main)

- `rocksdb/include/rocksdb/options.h`
- `rocksdb/db/version_set.cc`
- `rocksdb/table/block_based/block_based_table_iterator.cc`
- `rocks-demo/st_meta_read_bench.cpp`
- `tools/st_prune_vs_full_baseline_sweep.ps1`
- `docs/BEST_736_CONFIG.md`
- `docs/st_ablation_wuxi_1sst_vs_manysst.html`

# 736 SST Best-Performance Config

This document tracks the current best-known runtime configuration for the 736-SST scenario.
Goal is simple: maximize speedup for `verify_wuxi_segment_736sst`.

## Scope

- Focus dataset: `D:\Project\data\verify_wuxi_segment_736sst`
- Focus mode: `sst_manifest`
- Priority metric: wall-time speedup (`sum(full_wall_us) / sum(prune_wall_us)`)
- Secondary metric: `prune QPS`

## Current Best Known Settings

Use this as the default 736-optimized profile:

- `--prune-mode sst_manifest`
- `--virtual-merge`
- `--virtual-merge-auto`
- `--vm-time-span-sec-threshold 21600`
- `--sst-manifest-key-level 1`
- `--sst-manifest-adaptive-key-gate`
- `--adaptive-overlap-threshold 0.5`
- `--time-bucket-count 736`
- `--rtree-leaf-size 8`
- `--full-scan-mode window`
- `--verify-kv-results`

Rationale:

- For 736 SST, global pruning is already strong, but some windows still benefit from key-level filtering.
- Adaptive key gate (`threshold=0.5`) keeps key-level where it helps and suppresses overhead where it hurts.

## Repro Command (Random 12 Windows, 736 only)

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\Project\tools\st_prune_vs_full_baseline_sweep.ps1" `
  -RocksDbPathsCsv "D:\Project\data\verify_wuxi_segment_736sst" `
  -WindowsCsv "D:\Project\tools\st_validity_experiment_windows_wuxi.csv" `
  -PruneMode sst_manifest `
  -SstManifestKeyLevel 1 -SstManifestAdaptiveKeyGate -AdaptiveOverlapThreshold 0.5 `
  -VirtualMerge -VirtualMergeAuto -VmTimeSpanSecThreshold 21600 `
  -TimeBucketCount 736 -RTreeLeafSize 8 `
  -FullScanMode window `
  -OutTsv "D:\Project\data\experiments\post_shortcircuit_validation\ablation_736_adapt05_post_shortcircuit.tsv" `
  -VerifyKVResults
```

## Last Recorded A/B Evidence

Source files (key-level on/off baseline):

- `D:\Project\data\experiments\sst_manifest_keylevel_ab\ab_key1.tsv`
- `D:\Project\data\experiments\sst_manifest_keylevel_ab\ab_key0.tsv`

Observed summary (736 SST):

- `key-level=1`: speedup `4.796x`, QPS `9.310 -> 44.654`
- `key-level=0`: speedup `6.081x`, QPS `10.273 -> 62.468`
- Delta (`key0` vs `key1`): `+26.79%` speedup

New adaptive sweep (VM+Auto, 736 only):

- `D:\Project\data\experiments\wuxi_736_adaptive_scan\ablation_736_key0.tsv`
- `D:\Project\data\experiments\wuxi_736_adaptive_scan\ablation_736_adapt_05.tsv`
- `D:\Project\data\experiments\wuxi_736_adaptive_scan\ablation_736_adapt_06.tsv`
- `D:\Project\data\experiments\wuxi_736_adaptive_scan\ablation_736_adapt_07.tsv`

Observed summary:

- `key0` (fixed off): speedup `6.010x`, prune QPS `80.283`
- `adaptive@0.5`: speedup `7.636x`, prune QPS `101.935`  **(best)**
- `adaptive@0.6`: speedup `6.912x`, prune QPS `92.081`
- `adaptive@0.7`: speedup `6.135x`, prune QPS `80.500`

Best delta vs key0:

- speedup: `+27.06%` (`7.636x` vs `6.010x`)
- prune QPS: `+26.97%` (`101.935` vs `80.283`)

Post short-circuit validation:

- `D:\Project\data\experiments\post_shortcircuit_validation\ablation_736_adapt05_post_shortcircuit.tsv`
- observed: speedup `7.652x`, prune QPS `82.285`, `kv_correct=12/12`

Note:

- The short-circuit pass remained effective and kept `adaptive@0.5` as the best 736-focused profile.

## Maintenance Rule

When a new 736 run beats current config:

1. Keep the exact command used.
2. Add the output TSV path.
3. Update the "Current Best Known Settings" section.
4. Update the evidence block with before/after delta.

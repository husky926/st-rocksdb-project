# Full ablation: st_meta_read_bench over Wuxi segment DBs (default **1 / 164 / third hourly multi-SST** paths).
# Third DB (**standard**) = `verify_wuxi_segment_bucket3600_sst`: segments partitioned by **event time** into
# **1-hour (3600s) buckets** via `st_bucket_ingest_build --bucket-sec 3600` (see tools\build_wuxi_segment_third_tier_hourly.ps1).
# Live `*.sst` count **N** is data-dependent (often ~700+). Legacy dirs `776sst` / `736sst` are optional fallbacks.
# Default windows (priority):
#   1) tools/st_validity_experiment_windows_wuxi_stratified12_n4m4w4.csv — **canonical** 12 windows (4 narrow + 4 medium + 4 wide),
#      bench-validated full_keys>=50 on 1-SST (validate_wuxi_windows_csv.py). See EXPERIMENTS_AND_SCRIPTS.md §0.3 / §2.2.
#   2) tools/st_validity_experiment_windows_wuxi_random12_cov_s42.csv — legacy random12 cov (seed 42).
#   3) tools/st_validity_experiment_windows_wuxi_random12_s42.csv — uniform random in dense envelope; NOT key-validated.
# Hand-picked 12 scenarios: pass -WindowsCsv tools/st_validity_experiment_windows_wuxi.csv
#
# Regenerate validated CSV (requires st_meta_read_bench + verify_wuxi_segment_1sst):
#   python tools/generate_wuxi_random_windows_validated.py --db D:\Project\data\verify_wuxi_segment_1sst ^
#     --bench D:\Project\rocks-demo\build\st_meta_read_bench.exe ^
#     --out tools/st_validity_experiment_windows_wuxi_random12_cov_s42.csv --count 12 --seed 42 --min-full-keys 50
#
# Default bench profile (VM + Auto + 736 buckets + adaptive key/block gates on sst_manifest):
#   matches vm_compare "vm_auto" style file-level index; adaptive gates reduce redundant block/key work.
# Minimal / old defaults: -VirtualMerge:$false -VirtualMergeAuto:$false -TimeBucketCount 32 ^
#   -SstManifestAdaptiveKeyGate:$false -SstManifestAdaptiveBlockGate:$false
#
# Prune modes: manifest | sst | sst_manifest
#
# **Default compare baseline = upstream Vanilla RocksDB** (not fork full):
#   - Vanilla opens **VanillaWallDbPathsCsv** paths (default: each fork dir + `_vanilla_replica` if that folder exists).
#   - Fork **st_meta_read_bench** still uses RocksDbPathsCsv. Build replicas: tools\build_wuxi_vanilla_replica_dbs.ps1
#   - If data\experiments\wuxi_vanilla_wall_cache.json exists, it is used automatically; **cache keys must use the same
#     paths as Vanilla wall DBs** (replica paths), not fork paths.
#   - Else st_segment_window_scan_vanilla.exe is invoked per window on the Vanilla wall path (slow).
#   - Only if neither exists: pass -AllowForkFullBaseline to allow fork full_wall_us only (legacy / debugging).
# Build cache: tools\cache_wuxi_vanilla_wall_baseline.ps1
# Full batch: tools\run_wuxi_vanilla_cached_ablation_batch.ps1
# **默认**对 fork 跑 full↔prune `--verify-kv-results`（含 Vanilla 基线时的额外交互）；`-SkipVerifyKVResults` 可关。
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\run_wuxi_segment_ablation_1_164_776.ps1
# Summarize p50 over all 12 windows:
#   python tools/summarize_wuxi_ablation_three_modes.py ...\ablation_manifest.tsv ...\ablation_sst.tsv ...\ablation_sst_manifest.tsv --pooled --pooled-by-db
# Or pass -SummarizePooled to this script after a successful run.
# After each run, **segment count audit** is written to ``ablation_segment_count_audit.txt``
# (``full_keys`` / ``prune_keys_in_window`` / ``vanilla_keys`` per window, cross-mode checks).
#
# Back-compat: tools/run_wuxi_segment_ablation_1_164_736.ps1 forwards to this file.

param(
  [string]$WindowsCsv = "",
  [string]$RocksDbPathsCsv = "D:\Project\data\verify_wuxi_segment_1sst,D:\Project\data\verify_wuxi_segment_164sst,D:\Project\data\verify_wuxi_segment_bucket3600_sst",
  [string]$OutDir = "",
  [switch]$SummarizePooled,
  [switch]$SkipVerifyKVResults,
  [int]$IteratorRepeat = 1,
  [bool]$VirtualMerge = $true,
  [bool]$VirtualMergeAuto = $true,
  [uint32]$VmTimeSpanSecThreshold = 21600,
  [uint32]$TimeBucketCount = 736,
  [uint32]$RTreeLeafSize = 8,
  [bool]$SstManifestAdaptiveKeyGate = $true,
  [bool]$SstManifestAdaptiveBlockGate = $true,
  [float]$AdaptiveOverlapThreshold = 0.6,
  [float]$AdaptiveBlockOverlapThreshold = 0.85,
  [string]$VanillaSegmentBench = "",
  [string]$VanillaWallCacheJson = "",
  [string]$VanillaWallDbPathsCsv = "",
  [switch]$RequireVanillaFromCache,
  [switch]$AllowForkFullBaseline
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
$Sweep = Join-Path $ToolsDir "st_prune_vs_full_baseline_sweep.ps1"
if (-not (Test-Path -LiteralPath $Sweep)) {
  throw "Missing: $Sweep"
}

$Stratified12 = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi_stratified12_n4m4w4.csv"
$Random12Cov = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi_random12_cov_s42.csv"
$Random12 = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi_random12_s42.csv"
$LegacyWindows = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi.csv"
if ([string]::IsNullOrWhiteSpace($WindowsCsv)) {
  if (Test-Path -LiteralPath $Stratified12) {
    $WindowsCsv = $Stratified12
  } elseif (Test-Path -LiteralPath $Random12Cov) {
    $WindowsCsv = $Random12Cov
  } elseif (Test-Path -LiteralPath $Random12) {
    $WindowsCsv = $Random12
  } else {
    $WindowsCsv = $LegacyWindows
  }
}
if (-not (Test-Path -LiteralPath $WindowsCsv)) {
  throw "Missing: $WindowsCsv"
}

. (Join-Path $ToolsDir "wuxi_resolve_third_tier_fork.ps1")
$dataRoot = [System.IO.Path]::GetFullPath((Join-Path $ToolsDir "..\data"))
$r3 = Get-WuxiResolvedThirdTierCsv -RocksDbPathsCsv $RocksDbPathsCsv -DataRoot $dataRoot
$RocksDbPathsCsv = $r3.RocksDbPathsCsv
$used736Fallback = ($r3.ResolvedThirdPath -match "verify_wuxi_segment_736sst$")

if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $fb = if ($r3.ThirdTierUsedPathFallback) { "_third_tier_path_fallback" } else { "" }
  $OutDir = Join-Path $ToolsDir "..\data\experiments\wuxi_ablation_1_164_hourly_${stamp}${fb}"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if ([string]::IsNullOrWhiteSpace($VanillaSegmentBench)) {
  $VanillaSegmentBench = Join-Path $ToolsDir "..\rocks-demo\build\st_segment_window_scan_vanilla.exe"
}
$vanillaPresent = Test-Path -LiteralPath $VanillaSegmentBench

$defaultCachePath = [System.IO.Path]::GetFullPath((Join-Path $ToolsDir "..\data\experiments\wuxi_vanilla_wall_cache.json"))
$useVanillaWallCache = $false
if (-not [string]::IsNullOrWhiteSpace($VanillaWallCacheJson)) {
  $useVanillaWallCache = $true
} elseif (Test-Path -LiteralPath $defaultCachePath) {
  $VanillaWallCacheJson = $defaultCachePath
  $useVanillaWallCache = $true
}

if ($useVanillaWallCache -and -not (Test-Path -LiteralPath $VanillaWallCacheJson)) {
  throw "VanillaWallCacheJson not found: $VanillaWallCacheJson (run tools\cache_wuxi_vanilla_wall_baseline.ps1)"
}
if ($RequireVanillaFromCache.IsPresent -and -not $useVanillaWallCache) {
  throw "RequireVanillaFromCache requires -VanillaWallCacheJson or the default cache file at data\experiments\wuxi_vanilla_wall_cache.json"
}

$haveVanilla = $useVanillaWallCache -or $vanillaPresent
if (-not $haveVanilla) {
  if ($AllowForkFullBaseline.IsPresent) {
    Write-Warning "AllowForkFullBaseline: no Vanilla cache/exe — TSV uses fork full only; not comparable to Vanilla baseline runs."
    $compareBaseline = "fork_full"
  } else {
    throw @"
Wuxi ablation uses upstream Vanilla RocksDB as the wall-clock baseline by default.
Fix one of:
  (1) Create data\experiments\wuxi_vanilla_wall_cache.json — tools\cache_wuxi_vanilla_wall_baseline.ps1
  (2) Build rocks-demo\build\st_segment_window_scan_vanilla.exe — tools\bootstrap_rocksdb_vanilla.ps1
  (3) Pass -AllowForkFullBaseline for legacy fork-full-only comparison (omit vanilla_* columns).
"@
  }
} else {
  $compareBaseline = "vanilla"
}

# Upstream Vanilla must open a readable DB (often *_vanilla_replica). Align 1:1 with RocksDbPathsCsv.
$effectiveVanillaWallDbCsv = ""
if ($compareBaseline -eq "vanilla") {
  $effectiveVanillaWallDbCsv = $VanillaWallDbPathsCsv
  if ([string]::IsNullOrWhiteSpace($effectiveVanillaWallDbCsv)) {
    $forkArr = @($RocksDbPathsCsv.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
    $vBuilt = New-Object System.Collections.Generic.List[string]
    foreach ($fp in $forkArr) {
      $fullFp = [System.IO.Path]::GetFullPath($fp)
      $dir = [System.IO.Path]::GetDirectoryName($fullFp)
      $leaf = [System.IO.Path]::GetFileName($fullFp)
      $rep = Join-Path $dir ($leaf + "_vanilla_replica")
      if (Test-Path -LiteralPath $rep) {
        $repFull = [System.IO.Path]::GetFullPath($rep)
        [void]$vBuilt.Add($repFull)
        Write-Host "Vanilla wall DB: $repFull (fork: $fullFp)" -ForegroundColor DarkGray
      } else {
        [void]$vBuilt.Add($fullFp)
        Write-Warning "No Vanilla replica at $rep — st_segment_window_scan_vanilla on fork SST often yields no wall_us. Build: tools\build_wuxi_vanilla_replica_dbs.ps1 ; or cache: tools\cache_wuxi_vanilla_wall_baseline.ps1 -RocksDbPathsCsv <replica paths>."
      }
    }
    $effectiveVanillaWallDbCsv = ($vBuilt -join ',')
  }
}

# When reading baseline from JSON cache, require cache hits (no silent fallback to fork full for ratio_wall).
$sweepRequireVanilla = $useVanillaWallCache -or $RequireVanillaFromCache.IsPresent

$forkParts = @($RocksDbPathsCsv.Split(",") | ForEach-Object { $_.Trim() })
$thirdFork = if ($forkParts.Count -ge 3) { $forkParts[2] } else { "" }
$thirdSstCount = 0
if ($thirdFork -ne "" -and (Test-Path -LiteralPath $thirdFork)) {
  $thirdSstCount = (Get-ChildItem -LiteralPath $thirdFork -Filter "*.sst" -File -ErrorAction SilentlyContinue | Measure-Object).Count
}
$meta = @{
  third_tier_semantic            = "hourly_3600s_bucket_ingest"
  third_tier_hourly_bucket_sec   = 3600
  third_tier_resolved_fork_path  = $thirdFork
  third_tier_live_sst_count      = $thirdSstCount
  third_tier_used_path_fallback  = [bool]$r3.ThirdTierUsedPathFallback
  third_tier_legacy_dir_name     = [bool]$r3.ThirdTierLegacyDirName
  used_736sst_fallback           = $used736Fallback
  rocks_db_paths_csv             = $RocksDbPathsCsv
  windows_csv                    = $WindowsCsv
  generated_utc                  = (Get-Date).ToUniversalTime().ToString("o")
  vanilla_segment_bench_exe    = $VanillaSegmentBench
  vanilla_segment_bench_present  = $vanillaPresent
  vanilla_wall_cache_json        = if ($useVanillaWallCache) { $VanillaWallCacheJson } else { "" }
  compare_baseline               = $compareBaseline
  vanilla_replaces_fork_full_in_tsv = ($compareBaseline -eq "vanilla")
  vanilla_wall_db_paths_csv      = $effectiveVanillaWallDbCsv
  require_vanilla_from_cache     = [bool]$RequireVanillaFromCache
  allow_fork_full_baseline       = [bool]$AllowForkFullBaseline
}
$metaPath = Join-Path $OutDir "wuxi_ablation_run_meta.json"
$meta | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $metaPath -Encoding utf8

$modes = @("manifest", "sst", "sst_manifest")
foreach ($mode in $modes) {
  $tsv = Join-Path $OutDir "ablation_$mode.tsv"
  Write-Host "=== ablation mode=$mode -> $tsv ===" -ForegroundColor Cyan
  $args = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Sweep,
    "-RocksDbPathsCsv", $RocksDbPathsCsv,
    "-WindowsCsv", $WindowsCsv,
    "-PruneMode", $mode,
    "-FullScanMode", "window",
    "-OutTsv", $tsv,
    "-TimeBucketCount", "$TimeBucketCount",
    "-RTreeLeafSize", "$RTreeLeafSize",
    "-AdaptiveOverlapThreshold", "$AdaptiveOverlapThreshold",
    "-AdaptiveBlockOverlapThreshold", "$AdaptiveBlockOverlapThreshold"
  )
  if (-not $SkipVerifyKVResults.IsPresent) {
    $args += "-VerifyKVResults"
  }
  if ($IteratorRepeat -gt 1) {
    $args += "-IteratorRepeat"; $args += "$IteratorRepeat"
  }
  if ($VirtualMerge) {
    $args += "-VirtualMerge"
  }
  if ($VirtualMergeAuto) {
    $args += "-VirtualMergeAuto"
    $args += "-VmTimeSpanSecThreshold"; $args += "$VmTimeSpanSecThreshold"
  }
  if ($SstManifestAdaptiveKeyGate) {
    $args += "-SstManifestAdaptiveKeyGate"
  }
  if ($SstManifestAdaptiveBlockGate) {
    $args += "-SstManifestAdaptiveBlockGate"
  }
  if ($useVanillaWallCache) {
    $args += "-VanillaWallCacheJson"
    $args += $VanillaWallCacheJson
  }
  if ($sweepRequireVanilla) {
    $args += "-RequireVanillaCache"
  }
  if (-not $useVanillaWallCache -and $vanillaPresent) {
    $args += "-VanillaSegmentBenchExe"
    $args += $VanillaSegmentBench
  }
  if ($compareBaseline -eq "vanilla") {
    $args += "-VanillaAsBaseline"
    $args += "-VanillaWallDbPathsCsv"
    $args += $effectiveVanillaWallDbCsv
  }
  & powershell @args
}

Write-Host "Done. Output under: $OutDir" -ForegroundColor Green

$auditPy = Join-Path $ToolsDir "summarize_wuxi_ablation_segment_counts.py"
if (Test-Path -LiteralPath $auditPy) {
  $auditJson = Join-Path $OutDir "ablation_segment_count_audit.json"
  Write-Host "=== Trajectory segment count audit (per-window full_keys / prune / vanilla) ===" -ForegroundColor Cyan
  & python $auditPy $OutDir --json $auditJson
  if ($LASTEXITCODE -ne 0) {
    Write-Warning "summarize_wuxi_ablation_segment_counts.py exited with code $LASTEXITCODE"
  }
}

$sumArgs = @(
  "`"$ToolsDir\summarize_wuxi_ablation_three_modes.py`"",
  "`"$OutDir\ablation_manifest.tsv`"",
  "`"$OutDir\ablation_sst.tsv`"",
  "`"$OutDir\ablation_sst_manifest.tsv`"",
  "--pooled",
  "--pooled-by-db"
)
$sumCmd = "python " + ($sumArgs -join " ")
Write-Host "Pooled p50: $sumCmd" -ForegroundColor DarkGray

if ($SummarizePooled.IsPresent) {
  $m = Join-Path $OutDir "ablation_manifest.tsv"
  $s = Join-Path $OutDir "ablation_sst.tsv"
  $b = Join-Path $OutDir "ablation_sst_manifest.tsv"
  if (-not ((Test-Path $m) -and (Test-Path $s) -and (Test-Path $b))) {
    throw "SummarizePooled: missing ablation_*.tsv under $OutDir"
  }
  $logPath = Join-Path $OutDir "pooled_p50_summary.txt"
  Write-Host "Writing $logPath" -ForegroundColor Cyan
  & python "$ToolsDir\summarize_wuxi_ablation_three_modes.py" $m $s $b --pooled --pooled-by-db --baseline $(if ($compareBaseline -eq 'vanilla') { 'vanilla' } else { 'fork_full' }) |
    Tee-Object -FilePath $logPath
}

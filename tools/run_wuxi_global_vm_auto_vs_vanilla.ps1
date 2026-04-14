# Global (manifest) only: compare Vanilla wall_us vs prune with
#   (1) VirtualMerge only  — always enables time-bucket R-tree file index when file_level on
#   (2) VirtualMergeAuto only, default VmTimeSpanSecThreshold (21600) — on random12_cov windows
#       (all spans ~15–21 min) Auto NEVER hits => R-tree OFF (linear file skip only)
#   (3) VirtualMergeAuto only, low threshold — forces Auto to enable R-tree on all windows
#
# Prereq: data/experiments/wuxi_vanilla_wall_cache.json (same replica paths as ablation batch)
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\run_wuxi_global_vm_auto_vs_vanilla.ps1

param(
  [string]$ParentOutDir = "",
  [string]$RocksDbPathsCsv = "D:\Project\data\verify_wuxi_segment_1sst,D:\Project\data\verify_wuxi_segment_164sst,D:\Project\data\verify_wuxi_segment_bucket3600_sst",
  [string]$WindowsCsv = "",
  [string]$VanillaWallCacheJson = "",
  [uint32]$TimeBucketCount = 736,
  [uint32]$RTreeLeafSize = 8,
  [uint32]$VmTimeSpanDefault = 21600,
  [uint32]$VmTimeSpanAutoLow = 1
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
$RootDir = Resolve-Path (Join-Path $ToolsDir "..")
$Sweep = Join-Path $ToolsDir "st_prune_vs_full_baseline_sweep.ps1"

. (Join-Path $ToolsDir "wuxi_resolve_third_tier_fork.ps1")
$dataRoot = [System.IO.Path]::GetFullPath((Join-Path $RootDir "data"))
$r3 = Get-WuxiResolvedThirdTierCsv -RocksDbPathsCsv $RocksDbPathsCsv -DataRoot $dataRoot
$RocksDbPathsCsv = $r3.RocksDbPathsCsv

$Stratified12 = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi_stratified12_n4m4w4.csv"
$Random12Cov = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi_random12_cov_s42.csv"
if ([string]::IsNullOrWhiteSpace($WindowsCsv)) {
  if (Test-Path -LiteralPath $Stratified12) { $WindowsCsv = $Stratified12 }
  else { $WindowsCsv = $Random12Cov }
}
if ([string]::IsNullOrWhiteSpace($VanillaWallCacheJson)) {
  $VanillaWallCacheJson = Join-Path $RootDir "data\experiments\wuxi_vanilla_wall_cache.json"
}

if ([string]::IsNullOrWhiteSpace($ParentOutDir)) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $ParentOutDir = Join-Path $RootDir "data\experiments\wuxi_global_vm_auto_vanilla_${stamp}"
}
New-Item -ItemType Directory -Force -Path $ParentOutDir | Out-Null

$forkArr = @($RocksDbPathsCsv.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
$vList = New-Object System.Collections.Generic.List[string]
foreach ($fp in $forkArr) {
  $fullFp = [System.IO.Path]::GetFullPath($fp)
  $dir = [System.IO.Path]::GetDirectoryName($fullFp)
  $leaf = [System.IO.Path]::GetFileName($fullFp)
  $rep = Join-Path $dir ($leaf + "_vanilla_replica")
  if (-not (Test-Path -LiteralPath $rep)) {
    throw "Missing Vanilla replica: $rep (build: tools\build_wuxi_vanilla_replica_dbs.ps1)"
  }
  [void]$vList.Add([System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $rep).Path))
}
$VanillaWallDbPathsCsv = ($vList -join ',')

$meta = @{
  purpose = "Global manifest: VM-only vs Auto-only vs Vanilla"
  rocks_db_paths_csv = $RocksDbPathsCsv
  vanilla_wall_db_paths_csv = $VanillaWallDbPathsCsv
  windows_csv = $WindowsCsv
  vanilla_wall_cache_json = $VanillaWallCacheJson
  time_bucket_count = $TimeBucketCount
  rtree_leaf_size = $RTreeLeafSize
  note_random12 = "Cov windows have time span ~900-1250s; Auto with threshold 21600 never enables R-tree."
}
$meta | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ParentOutDir "run_meta.json") -Encoding utf8

function Invoke-OneVariant {
  param(
    [string]$Name,
    [switch]$VirtualMerge,
    [switch]$VirtualMergeAuto,
    [uint32]$VmTimeSpanSecThreshold
  )
  $out = Join-Path $ParentOutDir "${Name}.tsv"
  Write-Host "=== $Name -> $out ===" -ForegroundColor Cyan
  $a = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Sweep,
    "-RocksDbPathsCsv", $RocksDbPathsCsv,
    "-WindowsCsv", $WindowsCsv,
    "-PruneMode", "manifest",
    "-FullScanMode", "window",
    "-OutTsv", $out,
    "-TimeBucketCount", "$TimeBucketCount",
    "-RTreeLeafSize", "$RTreeLeafSize",
    "-VanillaWallCacheJson", $VanillaWallCacheJson,
    "-RequireVanillaCache",
    "-VanillaAsBaseline",
    "-VanillaWallDbPathsCsv", $VanillaWallDbPathsCsv
  )
  if ($VirtualMerge) { $a += "-VirtualMerge" }
  if ($VirtualMergeAuto) {
    $a += "-VirtualMergeAuto"
    $a += "-VmTimeSpanSecThreshold"
    $a += "$VmTimeSpanSecThreshold"
  }
  & powershell @a
}

# 1) Manual VM always turns on R-tree (when file_level on)
Invoke-OneVariant -Name "global_vm_only" -VirtualMerge -VmTimeSpanSecThreshold $VmTimeSpanDefault

# 2) Auto-only with shipped threshold: on random12, span < 21600 => auto_hit false => NO R-tree
Invoke-OneVariant -Name "global_auto_only_threshold_default" -VirtualMergeAuto -VmTimeSpanSecThreshold $VmTimeSpanDefault

# 3) Auto-only with low threshold: all windows satisfy span >= 1 => R-tree ON (expect ~same as VM-only)
Invoke-OneVariant -Name "global_auto_only_threshold_low" -VirtualMergeAuto -VmTimeSpanSecThreshold $VmTimeSpanAutoLow

$sumPy = Join-Path $ToolsDir "summarize_global_variant_ratio_wall.py"
if (-not (Test-Path -LiteralPath $sumPy)) {
  Write-Warning "Missing $sumPy — skip pooled summary."
} else {
  & python $sumPy $ParentOutDir
}

Write-Host "Done. Output under: $ParentOutDir" -ForegroundColor Green

# Run strict ablation on Wuxi segment DB (164 SST), including a new
# manifest_timebucket_rtree mode with configurable bucket counts.
#
# Outputs one TSV per (bucket_count, mode) to OutDir.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\run_wuxi_manysst_ablation_timebucket_rtree.ps1
#
param(
  [string]$RocksDbPath = "",
  [string]$OutDir = "",
  [string]$WindowsCsv = "",
  [string]$SweepScript = "",
  [int[]]$BucketCounts = @(16, 32, 64),
  [uint32]$RTreeLeafSize = 8,
  [switch]$VerifyKVResults
)

$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
if ([string]::IsNullOrWhiteSpace($RocksDbPath)) {
  $RocksDbPath = Join-Path $ToolsDir "..\data\verify_wuxi_segment_manysst"
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $ToolsDir "..\data\experiments\wuxi_segment_manysst_timebucket_rtree"
}
if ([string]::IsNullOrWhiteSpace($WindowsCsv)) {
  $WindowsCsv = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi.csv"
}
if ([string]::IsNullOrWhiteSpace($SweepScript)) {
  $SweepScript = Join-Path $ToolsDir "st_prune_vs_full_baseline_sweep.ps1"
}

$ErrorActionPreference = "Stop"
$RocksDbPath = (Resolve-Path -LiteralPath $RocksDbPath).Path
$OutDir = (New-Item -ItemType Directory -Force -Path $OutDir).FullName

$kvSuffix = if ($VerifyKVResults.IsPresent) { "_verifykv" } else { "" }

Write-Host "Wuxi 164-SST ablation + time-bucket R-tree" -ForegroundColor Cyan
Write-Host "DB: $RocksDbPath"
Write-Host "Windows: $WindowsCsv"
Write-Host "Out: $OutDir"
Write-Host "BucketCounts: $($BucketCounts -join ',')  LeafSize: $RTreeLeafSize"
Write-Host ""

# Baseline modes (no bucket param)
$baseModes = @(
  @{ Name = "sst_manifest"; Out = "ablation_sst_manifest_window$kvSuffix.tsv" },
  @{ Name = "sst";          Out = "ablation_sst_window$kvSuffix.tsv" },
  @{ Name = "manifest";     Out = "ablation_manifest_window$kvSuffix.tsv" }
)

foreach ($m in $baseModes) {
  $outTsv = Join-Path $OutDir $m.Out
  Write-Host "=== PruneMode=$($m.Name) -> $($m.Out) ===" -ForegroundColor Yellow
  if ($VerifyKVResults.IsPresent) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $SweepScript `
      -RocksDbPaths $RocksDbPath `
      -WindowsCsv $WindowsCsv `
      -OutTsv $outTsv `
      -PruneMode $m.Name `
      -FullScanMode window `
      -VerifyKVResults
  } else {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $SweepScript `
      -RocksDbPaths $RocksDbPath `
      -WindowsCsv $WindowsCsv `
      -OutTsv $outTsv `
      -PruneMode $m.Name `
      -FullScanMode window
  }
  Write-Host ""
}

# Time-bucket R-tree modes (vary bucket_count)
foreach ($bc in $BucketCounts) {
  $tag = "b$bc"
  $outName = "ablation_manifest_timebucket_rtree_${tag}_window$kvSuffix.tsv"
  $outTsv = Join-Path $OutDir $outName
  Write-Host "=== PruneMode=manifest_timebucket_rtree bucket_count=$bc -> $outName ===" -ForegroundColor Yellow
  if ($VerifyKVResults.IsPresent) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $SweepScript `
      -RocksDbPaths $RocksDbPath `
      -WindowsCsv $WindowsCsv `
      -OutTsv $outTsv `
      -PruneMode manifest_timebucket_rtree `
      -FullScanMode window `
      -TimeBucketCount ([uint32]$bc) `
      -RTreeLeafSize $RTreeLeafSize `
      -VerifyKVResults
  } else {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $SweepScript `
      -RocksDbPaths $RocksDbPath `
      -WindowsCsv $WindowsCsv `
      -OutTsv $outTsv `
      -PruneMode manifest_timebucket_rtree `
      -FullScanMode window `
      -TimeBucketCount ([uint32]$bc) `
      -RTreeLeafSize $RTreeLeafSize
  }
  Write-Host ""
}

Write-Host "Summarize throughput (example):" -ForegroundColor Green
Write-Host "  python `"$ToolsDir\summarize_prune_modules_throughput.py`" ``"
Write-Host "    --tsv `"$OutDir\\ablation_sst_manifest_window$kvSuffix.tsv`" --label sst_manifest ``"
Write-Host "    --tsv `"$OutDir\\ablation_sst_window$kvSuffix.tsv`" --label sst ``"
Write-Host "    --tsv `"$OutDir\\ablation_manifest_window$kvSuffix.tsv`" --label manifest_aabb ``"
Write-Host "    --tsv `"$OutDir\\ablation_manifest_timebucket_rtree_b16_window$kvSuffix.tsv`" --label manifest_rtree_b16 ``"
Write-Host "    --tsv `"$OutDir\\ablation_manifest_timebucket_rtree_b32_window$kvSuffix.tsv`" --label manifest_rtree_b32 ``"
Write-Host "    --tsv `"$OutDir\\ablation_manifest_timebucket_rtree_b64_window$kvSuffix.tsv`" --label manifest_rtree_b64"


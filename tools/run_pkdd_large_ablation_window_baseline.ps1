# Re-run strict ablation (sst | manifest | sst_manifest) on PKDD ~14.29M with
# baseline = st_meta_read_bench --full-scan-mode window (same query as prune for key counts).
#
# Requires: rocks-demo\build\st_meta_read_bench.exe (with --full-scan-mode), verify_pkdd_st_large.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\run_pkdd_large_ablation_window_baseline.ps1
#
# Optional:
#   -RocksDbPath D:\path\to\verify_pkdd_st_large
#   -OutDir D:\Project\data\experiments

param(
  [string]$RocksDbPath = "",
  [string]$OutDir = "",
  [string]$WindowsCsv = "",
  [string]$SweepScript = "",
  [switch]$VerifyKVResults
)

$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
if ([string]::IsNullOrWhiteSpace($RocksDbPath)) {
  $RocksDbPath = Join-Path $ToolsDir "..\data\verify_pkdd_st_large"
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $ToolsDir "..\data\experiments"
}
if ([string]::IsNullOrWhiteSpace($WindowsCsv)) {
  $WindowsCsv = Join-Path $ToolsDir "st_validity_experiment_windows_pkdd.csv"
}
if ([string]::IsNullOrWhiteSpace($SweepScript)) {
  $SweepScript = Join-Path $ToolsDir "st_prune_vs_full_baseline_sweep.ps1"
}

$ErrorActionPreference = "Stop"
$RocksDbPath = (Resolve-Path -LiteralPath $RocksDbPath).Path
$OutDir = (New-Item -ItemType Directory -Force -Path $OutDir).FullName

$kvSuffix = if ($VerifyKVResults.IsPresent) { "_verifykv" } else { "" }
$modes = @(
  @{ Name = "sst_manifest"; Out = "prune_vs_full_pkdd_large_ablation_sst_manifest_window$kvSuffix.tsv" },
  @{ Name = "sst";          Out = "prune_vs_full_pkdd_large_ablation_sst_window$kvSuffix.tsv" },
  @{ Name = "manifest";     Out = "prune_vs_full_pkdd_large_ablation_manifest_window$kvSuffix.tsv" }
)

Write-Host "PKDD large ablation (FullScanMode=window, 12 design windows x 3 prune modes)" -ForegroundColor Cyan
Write-Host "DB: $RocksDbPath"
Write-Host "Out: $OutDir"
Write-Host ""

foreach ($m in $modes) {
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

Write-Host "Summarize throughput (optional):" -ForegroundColor Green
Write-Host "  python `"$ToolsDir\summarize_prune_modules_throughput.py`" ``"
Write-Host "    --tsv `"$(Join-Path $OutDir $($modes[0].Out))`" ``"
Write-Host "    --tsv `"$(Join-Path $OutDir $($modes[1].Out))`" ``"
Write-Host "    --tsv `"$(Join-Path $OutDir $($modes[2].Out))`" ``"
Write-Host "    --label sst_manifest_window --label sst_window --label manifest_window"
Write-Host ""
Write-Host "Update docs/st_manifest_vs_sst_ablation_charts.html with new numbers if needed."

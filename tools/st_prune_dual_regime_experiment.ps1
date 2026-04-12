# One-shot dual-regime experiment: narrow (latency) + wide (throughput) windows on Wuxi DB.
# 1) Runs st_prune_vs_full_baseline_sweep.ps1 with wuxi_dual_regime_windows.csv (Regime column).
# 2) Runs summarize_dual_regime_tsv.py on the TSV.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\st_prune_dual_regime_experiment.ps1
#   powershell ... -OutTsv D:\path\custom.tsv

param(
  [string]$WindowsCsv = "",
  [string[]]$RocksDbPaths = @("D:\Project\data\verify_wuxi_segment_manysst"),
  [string]$OutTsv = "",
  [string]$PruneMode = "sst_manifest"
)

$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
if ([string]::IsNullOrWhiteSpace($WindowsCsv)) {
  $WindowsCsv = Join-Path $ToolsDir "..\data\experiments\wuxi_dual_regime_windows.csv"
}
if ([string]::IsNullOrWhiteSpace($OutTsv)) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $OutTsv = Join-Path $ToolsDir "..\data\experiments\dual_regime_wuxi_$stamp.tsv"
}

$Sweep = Join-Path $ToolsDir "st_prune_vs_full_baseline_sweep.ps1"
$Py = Join-Path $ToolsDir "summarize_dual_regime_tsv.py"

Write-Host "Windows CSV: $WindowsCsv" -ForegroundColor Cyan
Write-Host "Out TSV:     $OutTsv" -ForegroundColor Cyan
Write-Host ""

& $Sweep -WindowsCsv $WindowsCsv -RocksDbPaths $RocksDbPaths -OutTsv $OutTsv -PruneMode $PruneMode -FullScanMode window

Write-Host ""
Write-Host "--- summarize by regime (narrow vs wide) ---" -ForegroundColor Cyan
python $Py $OutTsv

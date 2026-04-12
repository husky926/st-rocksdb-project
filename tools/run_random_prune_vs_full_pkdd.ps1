# One-shot: generate random windows (PKDD envelope) -> prune_vs_full sweep -> summarize.
# Reduces "hand-picked query favors ST" concern; see docs/st_validity_experiment_design.md §随机窗.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\run_random_prune_vs_full_pkdd.ps1
#   powershell ... -File ... -RandomCount 100 -Seed 42 -RocksDbPaths D:\Project\data\verify_pkdd_st

param(
  [int]$RandomCount = 50,
  [int]$Seed = 42,
  [string]$RocksDbPaths = "",
  [switch]$NoAnchor
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = (Get-Item -LiteralPath $MyInvocation.MyCommand.Path).DirectoryName
}
# PS 5.1: -LiteralPath 与 -Parent 不能同用；用 -Path（tools 路径一般无通配符）
$ProjRoot = Split-Path -Parent -Path $ToolsDir
$DataExp = Join-Path $ProjRoot "data\experiments"
$WinCsv = Join-Path $DataExp "random_windows_pkdd_n${RandomCount}_s${Seed}.csv"
$OutTsv = Join-Path $DataExp "prune_vs_full_pkdd_random_n${RandomCount}_s${Seed}.tsv"

$anchorArg = @()
if (-not $NoAnchor) {
  $anchorArg = @("--include-anchor", "wide_pkdd")
}

Write-Host "== generate random windows -> $WinCsv" -ForegroundColor Cyan
& python (Join-Path $ToolsDir "generate_random_query_windows.py") `
  --out $WinCsv --count $RandomCount --seed $Seed @anchorArg

if ([string]::IsNullOrWhiteSpace($RocksDbPaths)) {
  $RocksDbPaths = Join-Path $ProjRoot "data\verify_pkdd_st"
}

Write-Host "== prune_vs_full sweep (may take several minutes)" -ForegroundColor Cyan
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ToolsDir "st_prune_vs_full_baseline_sweep.ps1") `
  -RocksDbPaths $RocksDbPaths -WindowsCsv $WinCsv -OutTsv $OutTsv

Write-Host "== summarize $OutTsv" -ForegroundColor Cyan
& python (Join-Path $ToolsDir "summarize_prune_vs_full_tsv.py") $OutTsv

Write-Host ""
Write-Host "Done. Windows: $WinCsv  TSV: $OutTsv" -ForegroundColor Green

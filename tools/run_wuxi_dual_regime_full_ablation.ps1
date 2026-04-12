# Full 3-way ablation on wuxi_dual_regime_windows.csv (6 windows × Local / Global / Local+Global).
# Produces three TSVs under data/experiments/ for HTML / summarize_wuxi_ablation_three_modes.py
#
# Usage:
#   cd D:\Project\tools
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\run_wuxi_dual_regime_full_ablation.ps1

param(
  [string]$WindowsCsv = "",
  [string[]]$RocksDbPaths = @("D:\Project\data\verify_wuxi_segment_manysst"),
  [string]$OutDir = "",
  [switch]$VerifyKVResults
)

$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
if ([string]::IsNullOrWhiteSpace($WindowsCsv)) {
  $WindowsCsv = Join-Path $ToolsDir "..\data\experiments\wuxi_dual_regime_windows.csv"
}
# Nested PowerShell / quoting sometimes collapses -RocksDbPaths into a single string.
# Handle common forms:
# - "a,b"
# - "\"a\" \"b\"" (space-separated, quoted)
if ($RocksDbPaths.Count -eq 1) {
  $s = [string]$RocksDbPaths[0]
  if ($s -match ',') {
    $RocksDbPaths = @(
      $s.Split(',') | ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_.Length -gt 0 }
    )
  } elseif ($s -match '\"' -and $s -match '\s') {
    $RocksDbPaths = @(
      [regex]::Matches($s, '\"([^\"]+)\"') | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_.Length -gt 0 }
    )
  } elseif ($s -match '\s') {
    $RocksDbPaths = @(
      $s.Split(@(' ', "`t"), [System.StringSplitOptions]::RemoveEmptyEntries) |
        ForEach-Object { $_.Trim().Trim('"') } | Where-Object { $_.Length -gt 0 }
    )
  }
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $OutDir = Join-Path $ToolsDir "..\data\experiments\wuxi_dual_regime_ablation_$stamp"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$Sweep = Join-Path $ToolsDir "st_prune_vs_full_baseline_sweep.ps1"

$modes = @(
  @{ PruneMode = "manifest";      OutName = "ablation_manifest.tsv" },
  @{ PruneMode = "sst";           OutName = "ablation_sst.tsv" },
  @{ PruneMode = "sst_manifest";  OutName = "ablation_sst_manifest.tsv" }
)

Write-Host "OutDir: $OutDir" -ForegroundColor Cyan
foreach ($m in $modes) {
  $out = Join-Path $OutDir $m.OutName
  Write-Host "`n=== PruneMode=$($m.PruneMode) -> $out ===" -ForegroundColor Yellow
  if ($VerifyKVResults.IsPresent) {
    & $Sweep -WindowsCsv $WindowsCsv -RocksDbPaths $RocksDbPaths `
      -PruneMode $m.PruneMode -FullScanMode window -OutTsv $out -VerifyKVResults
  } else {
    & $Sweep -WindowsCsv $WindowsCsv -RocksDbPaths $RocksDbPaths `
      -PruneMode $m.PruneMode -FullScanMode window -OutTsv $out
  }
}

Write-Host "`nDone. Summarize with:" -ForegroundColor Green
Write-Host "  python $ToolsDir\summarize_wuxi_ablation_three_modes.py `"$OutDir\ablation_manifest.tsv`" `"$OutDir\ablation_sst.tsv`" `"$OutDir\ablation_sst_manifest.tsv`""

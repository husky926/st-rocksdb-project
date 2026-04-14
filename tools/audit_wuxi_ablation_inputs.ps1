# Sanity-check fork DBs + Vanilla replicas before Wuxi ablation / batch runs.
# Fails with exit 1 if a path is missing or SST layout looks inconsistent with tier names.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\audit_wuxi_ablation_inputs.ps1
#   powershell ... -RocksDbPathsCsv "D:\a,D:\b,D:\c"

param(
  [string]$RocksDbPathsCsv = "D:\Project\data\verify_wuxi_segment_1sst,D:\Project\data\verify_wuxi_segment_164sst,D:\Project\data\verify_wuxi_segment_bucket3600_sst",
  [string]$SegmentsMetaCsv = "D:\Project\data\processed\wuxi\segments_meta.csv",
  [int]$ExpectSegmentRows = 81768,
  [int]$MinMiddleTierSst = 8,
  [int]$MinThirdTierSst = 64
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
. (Join-Path $ToolsDir "wuxi_resolve_third_tier_fork.ps1")
$dataRoot = [System.IO.Path]::GetFullPath((Join-Path $ToolsDir "..\data"))
$r3 = Get-WuxiResolvedThirdTierCsv -RocksDbPathsCsv $RocksDbPathsCsv -DataRoot $dataRoot
$csv = $r3.RocksDbPathsCsv

function Count-Sst {
  param([string]$Dir)
  if (-not (Test-Path -LiteralPath $Dir)) { return -1 }
  return @((Get-ChildItem -LiteralPath $Dir -Filter "*.sst" -File -ErrorAction SilentlyContinue)).Count
}

$issues = New-Object System.Collections.Generic.List[string]
$forks = @($csv.Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 })
if ($forks.Count -ne 3) {
  $issues.Add("Expected 3 fork paths in RocksDbPathsCsv; got $($forks.Count).")
}

Write-Host "=== Wuxi ablation input audit ===" -ForegroundColor Cyan
Write-Host "Resolved RocksDbPathsCsv: $csv" -ForegroundColor DarkGray
if ($r3.ThirdTierUsedPathFallback) {
  Write-Warning "Third tier path fallback was used (see wuxi_resolve_third_tier_fork.ps1)."
}

$idx = 0
foreach ($fp in $forks) {
  $idx++
  $n = Count-Sst -Dir $fp
  $leaf = Split-Path -Leaf $fp
  Write-Host ("[{0}] {1}  ->  {2} SST" -f $idx, $leaf, $n)
  if ($n -lt 0) {
    $issues.Add("Missing fork DB: $fp")
    continue
  }
  if ($idx -eq 1 -and $n -ne 1) {
    $issues.Add("Tier 1 (1sst) expected exactly 1 live SST; got $n at $fp")
  }
  if ($idx -eq 2 -and $n -lt $MinMiddleTierSst) {
    $issues.Add(
      "Tier 2 ($leaf) has only $n SST — middle tier should be multi-SST (>=$MinMiddleTierSst). " +
      "Rebuild with st_meta_smoke --flush-every 500 (see docs/BUILD_AND_EXPERIMENTS.md §4.1) or use verify_wuxi_segment_manysst."
    )
  }
  if ($idx -eq 3 -and $n -lt $MinThirdTierSst) {
    $issues.Add(
      "Tier 3 ($leaf) has only $n SST — hourly bucket layout should yield many files (>=$MinThirdTierSst). " +
      "See tools/build_wuxi_segment_third_tier_hourly.ps1."
    )
  }
  $parent = Split-Path -Parent $fp
  $rep = Join-Path $parent ($leaf + "_vanilla_replica")
  $nr = Count-Sst -Dir $rep
  if ($nr -lt 0) {
    $issues.Add("Missing Vanilla replica: $rep")
  } else {
    Write-Host "     replica: $nr SST  ($([System.IO.Path]::GetFileName($rep)))" -ForegroundColor DarkGray
  }
}

if (Test-Path -LiteralPath $SegmentsMetaCsv) {
  $dataLines = (Get-Content -LiteralPath $SegmentsMetaCsv | Measure-Object -Line).Lines - 1
  Write-Host "segments_meta.csv data rows: $dataLines (expect $ExpectSegmentRows)" -ForegroundColor DarkGray
  if ($ExpectSegmentRows -gt 0 -and [math]::Abs($dataLines - $ExpectSegmentRows) -gt 2) {
    $issues.Add("segments_meta row count $dataLines differs from expected $ExpectSegmentRows (check CSV).")
  }
} else {
  $issues.Add("Missing $SegmentsMetaCsv")
}

Write-Host "`nTimeBucketCount hint: set ablation -TimeBucketCount to match third-tier live SST count ($(
  if ($forks.Count -ge 3) { Count-Sst -Dir $forks[2] } else { '?' }
)) for VM/time-bucket tuning (default script 736 is OK when N≈736)." -ForegroundColor DarkGray

if ($issues.Count -gt 0) {
  Write-Host "`nFAILED ($($issues.Count) issue(s)):" -ForegroundColor Red
  foreach ($x in $issues) { Write-Host "  - $x" -ForegroundColor Yellow }
  exit 1
}
Write-Host "`nOK — fork layout + replicas look consistent for ablation." -ForegroundColor Green
exit 0

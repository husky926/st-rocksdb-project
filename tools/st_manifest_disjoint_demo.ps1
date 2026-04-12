# Manifest-level ST prune demo on verify_traj_st_full (2 SST):
# 000011.sst file x_max ~ 119.416 -> query with x_min >= 120 is file-DISJOINT on that SST
# while 000009 still INTERSECTS (x up to ~145).
#
# Usage (if execution policy blocks .ps1):
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\st_manifest_disjoint_demo.ps1
#
param(
  [string]$Db = (Join-Path $PSScriptRoot "..\data\verify_traj_st_full"),
  [string]$Diag = (Join-Path $PSScriptRoot "..\rocksdb\build\tools\st_meta_sst_diag.exe"),
  [string]$Bench = (Join-Path $PSScriptRoot "..\rocks-demo\build\st_meta_read_bench.exe")
)

$ErrorActionPreference = "Stop"
foreach ($p in @($Diag, $Bench)) {
  if (-not (Test-Path -LiteralPath $p)) { Write-Error "Missing: $p" }
}
$ssts = (Get-ChildItem -LiteralPath $Db -Filter "*.sst" -File | Sort-Object Name).FullName
if ($ssts.Count -eq 0) { Write-Error "No .sst under $Db" }

# Same geometry as Record.md wide window except x shifted east of 000011 file x_max
$TMin = 1224600000; $TMax = 1224800000
$XMin = 120.0; $YMin = 39.9; $XMax = 122.0; $YMax = 40.1

Write-Host "=== st_meta_sst_diag (expect 000011: file DISJOINT) ==="
& $Diag --window $TMin $TMax $XMin $YMin $XMax $YMax @ssts
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "=== st_meta_read_bench --no-full-scan (same window) ==="
Write-Host "Compare: bytes_read / keys vs wide x=[116.2,116.4] baseline; block_read_count is cache-sensitive - run twice."
& $Bench --db $Db --no-full-scan `
  --prune-t-min $TMin --prune-t-max $TMax `
  --prune-x-min $XMin --prune-x-max $XMax `
  --prune-y-min $YMin --prune-y-max $YMax
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Run st_meta_sst_diag --window with the SAME geometry as st_meta_read_bench
# (wide = bench defaults; narrow = Record.md "尖窗" run).
# Requires: D:\Project\rocksdb\build\tools\st_meta_sst_diag.exe (see Record.md).

$ErrorActionPreference = "Stop"
$Diag = Join-Path $PSScriptRoot "..\rocksdb\build\tools\st_meta_sst_diag.exe"
if (-not (Test-Path -LiteralPath $Diag)) {
  Write-Error "Not found: $Diag  (cmake --build ... --target st_meta_sst_diag)"
}

$Ssts = @(
  (Join-Path $PSScriptRoot "..\data\verify_traj_st_full\000009.sst"),
  (Join-Path $PSScriptRoot "..\data\verify_traj_st_full\000011.sst")
)
foreach ($p in $Ssts) {
  if (-not (Test-Path -LiteralPath $p)) {
    Write-Error "Missing SST: $p"
  }
}

function Invoke-DiagWindow {
  param(
    [string]$Label,
    [uint32]$TMin,
    [uint32]$TMax,
    [double]$XMin,
    [double]$YMin,
    [double]$XMax,
    [double]$YMax
  )
  Write-Host ""
  Write-Host "======== $Label ========"
  Write-Host "st_meta_read_bench equivalent: --prune-t-min $TMin --prune-t-max $TMax --prune-x-min $XMin --prune-x-max $XMax --prune-y-min $YMin --prune-y-max $YMax"
  Write-Host "st_meta_sst_diag: --window T_MIN T_MAX X_MIN Y_MIN X_MAX Y_MAX"
  & $Diag --window $TMin $TMax $XMin $YMin $XMax $YMax @Ssts
  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# Wide window = st_meta_read_bench.cpp defaults (see Record.md)
Invoke-DiagWindow -Label "WIDE (bench defaults)" `
  -TMin 1224600000 -TMax 1224800000 `
  -XMin 116.2 -YMin 39.9 -XMax 116.4 -YMax 40.1

# Narrow window = Record.md 尖窗 Run1
Invoke-DiagWindow -Label "NARROW (Record sharp window)" `
  -TMin 1224730000 -TMax 1224730500 `
  -XMin 116.31 -YMin 39.984 -XMax 116.32 -YMax 39.986

Write-Host ""
Write-Host "Done. Compare 'would skip (disjoint ST)' per file + totals vs st_meta_read_bench prune_scan keys / IO."

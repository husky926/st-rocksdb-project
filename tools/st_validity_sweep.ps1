# Validity experiment sweep (§1.0): run st_meta_read_bench --no-full-scan for each window in CSV.
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\st_validity_sweep.ps1
#   (Do not use -Db: conflicts with PowerShell -Debug.) Use -RocksDbPaths:
#   powershell ... -File ... -RocksDbPaths D:\Project\data\verify_traj_st_compact_work
#   Multi-DB from cmd.exe / nested powershell -File: use COMMA string (NOT @(...) — breaks parsing):
#   powershell ... -File ... -RocksDbPathsCsv "D:\Project\data\verify_traj_st_full,D:\Project\data\verify_traj_st_compact_work"
#   Or from an INTERACTIVE PowerShell window only:
#   & D:\Project\tools\st_validity_sweep.ps1 -RocksDbPaths @('D:\...\full','D:\...\compact_work')
#
# Output: TSV lines to stdout (and optional -OutTsv path). Single run per config (no multi-repeat).

param(
  [Parameter(Mandatory = $false)]
  [string[]]$RocksDbPaths = $null,
  [string]$RocksDbPathsCsv = "",
  [string]$Bench = "",
  [string]$WindowsCsv = "",
  [string]$OutTsv = ""
)

# $PSScriptRoot is empty in some hosts (e.g. certain -File invocations); fall back to script path.
$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
if (-not [string]::IsNullOrWhiteSpace($RocksDbPathsCsv)) {
  $RocksDbPaths = @(
    $RocksDbPathsCsv.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 }
  )
}
if ($null -eq $RocksDbPaths -or $RocksDbPaths.Count -eq 0) {
  $RocksDbPaths = @(Join-Path $ToolsDir "..\data\verify_traj_st_full")
}
if ([string]::IsNullOrWhiteSpace($Bench)) {
  $Bench = Join-Path $ToolsDir "..\rocks-demo\build\st_meta_read_bench.exe"
}
if ([string]::IsNullOrWhiteSpace($WindowsCsv)) {
  $WindowsCsv = Join-Path $ToolsDir "st_validity_experiment_windows.csv"
}

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $Bench)) {
  Write-Error "Build first: $Bench"
}
if (-not (Test-Path -LiteralPath $WindowsCsv)) {
  Write-Error "Missing CSV: $WindowsCsv"
}

function Invoke-OneBench {
  param(
    [string]$DbPath,
    [string]$Label,
    [uint32]$TMin,
    [uint32]$TMax,
    [double]$XMin,
    [double]$XMax,
    [double]$YMin,
    [double]$YMax
  )
  if (-not (Test-Path -LiteralPath $DbPath)) {
    return [PSCustomObject]@{
      db            = $DbPath
      label         = $Label
      keys          = "-1"
      block_read    = "-1"
      wall_us       = "-1"
      bytes_read    = "-1"
      read_nanos    = "-1"
      data_miss     = "-1"
      index_miss    = "-1"
      error         = "db_missing"
    }
  }
  $args = @(
    "--db", $DbPath,
    "--no-full-scan",
    "--prune-t-min", "$TMin",
    "--prune-t-max", "$TMax",
    "--prune-x-min", "$XMin",
    "--prune-x-max", "$XMax",
    "--prune-y-min", "$YMin",
    "--prune-y-max", "$YMax"
  )
  $raw = & $Bench @args 2>&1 | Out-String
  $keys = ""; $br = ""; $wall = ""; $bytes = ""; $rn = ""; $dm = ""; $im = ""
  if ($raw -match 'prune_scan keys=(\d+) block_read_count=(\d+) wall_us=([\d.]+)') {
    $keys = $Matches[1]; $br = $Matches[2]; $wall = $Matches[3]
  }
  if ($raw -match 'prune_scan IOStatsContext delta: bytes_read=(\d+) read_nanos=(\d+)') {
    $bytes = $Matches[1]; $rn = $Matches[2]
  }
  if ($raw -match 'BLOCK_CACHE_DATA_MISS (\d+)') { $dm = $Matches[1] }
  if ($raw -match 'BLOCK_CACHE_INDEX_MISS (\d+)') { $im = $Matches[1] }
  $err = ""
  if ($keys -eq "") { $err = "parse_fail" }
  return [PSCustomObject]@{
    db            = $DbPath
    label         = $Label
    keys          = $keys
    block_read    = $br
    wall_us       = $wall
    bytes_read    = $bytes
    read_nanos    = $rn
    data_miss     = $dm
    index_miss    = $im
    error         = $err
  }
}

$rows = Import-Csv -LiteralPath $WindowsCsv
$all = @()
foreach ($dbPath in $RocksDbPaths) {
  foreach ($r in $rows) {
    Write-Host "=== $($r.Label) :: $dbPath ===" -ForegroundColor Cyan
    $o = Invoke-OneBench -DbPath $dbPath -Label $r.Label `
      -TMin ([uint32]$r.TMin) -TMax ([uint32]$r.TMax) `
      -XMin ([double]$r.XMin) -XMax ([double]$r.XMax) `
      -YMin ([double]$r.YMin) -YMax ([double]$r.YMax)
    $all += $o
  }
}

$header = "db`tlabel`tkeys`tblock_read`twall_us`tbytes_read`tread_nanos`tdata_miss`tindex_miss`terror"
$lines = @($header)
foreach ($o in $all) {
  $lines += "$($o.db)`t$($o.label)`t$($o.keys)`t$($o.block_read)`t$($o.wall_us)`t$($o.bytes_read)`t$($o.read_nanos)`t$($o.data_miss)`t$($o.index_miss)`t$($o.error)"
}
$text = $lines -join "`n"
Write-Host ""
Write-Host $text
if ($OutTsv -ne "") {
  $text | Set-Content -LiteralPath $OutTsv -Encoding utf8
  Write-Host "Wrote $OutTsv"
}

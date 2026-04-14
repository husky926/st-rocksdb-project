# Build Vanilla-readable replicas of Wuxi segment DBs (Phase 1 in docs/VANILLA_ROCKSDB_BASELINE.md).
# Fork opens source (tolerates fork SSTs), exports user keys + values; upstream RocksDB ingests into new dirs.
# After this, point cache_wuxi_vanilla_wall_baseline.ps1 -RocksDbPathsCsv at *_vanilla_replica paths
# (or replace ablation RocksDbPathsCsv) and st_segment_window_scan_vanilla measures real upstream read time.
#
# Requires: cmake-built st_fork_kv_stream_dump + st_vanilla_kv_stream_ingest (upstream rocksdb_vanilla.lib).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\build_wuxi_vanilla_replica_dbs.ps1
# Third tier defaults to verify_wuxi_segment_bucket3600_sst; override with -ForkThirdTierHourly or legacy -Fork736.

param(
  [string]$Fork1sst = "D:\Project\data\verify_wuxi_segment_1sst",
  [string]$Fork164 = "D:\Project\data\verify_wuxi_segment_164sst",
  # Third tier = hourly 3600s bucket ingest (canonical dir name). Legacy: Fork736 overrides this.
  [string]$ForkThirdTierHourly = "D:\Project\data\verify_wuxi_segment_bucket3600_sst",
  [string]$Fork736 = "",
  [string]$Suffix = "_vanilla_replica",
  [string]$WorkDir = "",
  [string]$BuildDir = ""
)

$ErrorActionPreference = "Stop"
$Root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
if ([string]::IsNullOrWhiteSpace($BuildDir)) {
  $BuildDir = Join-Path $Root "rocks-demo\build"
}
$BuildDir = [System.IO.Path]::GetFullPath($BuildDir)

function Resolve-Exe {
  param([string]$Name)
  $candidates = @(
    (Join-Path $BuildDir "Release\$Name"),
    (Join-Path $BuildDir "RelWithDebInfo\$Name"),
    (Join-Path $BuildDir $Name)
  )
  foreach ($p in $candidates) {
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $null
}

$DumpExe = Resolve-Exe "st_fork_kv_stream_dump.exe"
$IngestExe = Resolve-Exe "st_vanilla_kv_stream_ingest.exe"
if (-not $DumpExe) {
  throw "Missing st_fork_kv_stream_dump.exe under $BuildDir (cmake --build ... --target st_fork_kv_stream_dump)"
}
if (-not $IngestExe) {
  throw "Missing st_vanilla_kv_stream_ingest.exe. Build rocksdb_vanilla first (tools\bootstrap_rocksdb_vanilla.ps1), reconfigure rocks-demo, build target st_vanilla_kv_stream_ingest."
}

if ([string]::IsNullOrWhiteSpace($WorkDir)) {
  $WorkDir = Join-Path $Root "data\experiments\vanilla_replica_work"
}
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$WorkDir = [System.IO.Path]::GetFullPath($WorkDir)

function Replica-Path {
  param([string]$ForkPath)
  $parent = Split-Path -Parent $ForkPath
  $leaf = Split-Path -Leaf $ForkPath
  return Join-Path $parent ($leaf + $Suffix)
}

function Build-One {
  param(
    [string]$ForkPath,
    [string]$DumpTool,
    [string]$IngestTool,
    [string]$TempDir
  )
  if (-not (Test-Path -LiteralPath $ForkPath)) {
    Write-Warning "Skip missing fork DB: $ForkPath"
    return
  }
  $dest = Replica-Path $ForkPath
  $dumpFile = Join-Path $TempDir ([System.Guid]::NewGuid().ToString() + ".kvs")
  Write-Host "=== DUMP fork -> $dumpFile ===" -ForegroundColor Cyan
  Write-Host "  db=$ForkPath"
  & $DumpTool --db $ForkPath --out $dumpFile
  if ($LASTEXITCODE -ne 0) {
    throw "st_fork_kv_stream_dump failed (exit $LASTEXITCODE)"
  }
  if (Test-Path -LiteralPath $dest) {
    Write-Host "Removing existing $dest" -ForegroundColor Yellow
    Remove-Item -LiteralPath $dest -Recurse -Force
  }
  New-Item -ItemType Directory -Path $dest | Out-Null
  Write-Host "=== INGEST vanilla -> $dest ===" -ForegroundColor Cyan
  & $IngestTool --db $dest --in $dumpFile --compact
  if ($LASTEXITCODE -ne 0) {
    throw "st_vanilla_kv_stream_ingest failed (exit $LASTEXITCODE)"
  }
  Remove-Item -LiteralPath $dumpFile -Force -ErrorAction SilentlyContinue
  Write-Host "OK: $dest" -ForegroundColor Green
}

$forkThird = if (-not [string]::IsNullOrWhiteSpace($Fork736)) { $Fork736 } else { $ForkThirdTierHourly }

Build-One -ForkPath $Fork1sst -DumpTool $DumpExe -IngestTool $IngestExe -TempDir $WorkDir
Build-One -ForkPath $Fork164 -DumpTool $DumpExe -IngestTool $IngestExe -TempDir $WorkDir
Build-One -ForkPath $forkThird -DumpTool $DumpExe -IngestTool $IngestExe -TempDir $WorkDir

Write-Host ""
Write-Host "Next: run Vanilla wall cache against replicas, e.g." -ForegroundColor DarkGray
$v1 = Replica-Path $Fork1sst
$v164 = Replica-Path $Fork164
$vMulti = Replica-Path $forkThird
Write-Host "  powershell ...\cache_wuxi_vanilla_wall_baseline.ps1 -RocksDbPathsCsv `"$v1,$v164,$vMulti`" -OutJson D:\Project\data\experiments\wuxi_vanilla_wall_cache.json" -ForegroundColor DarkGray

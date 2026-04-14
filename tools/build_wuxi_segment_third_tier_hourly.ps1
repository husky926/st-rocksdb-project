# Build **third tier** Wuxi fork DB: segments partitioned by **event-time hour** (bucket_sec=3600).
# Output: `verify_wuxi_segment_bucket3600_sst` (semantic name). Live `*.sst` count follows data (often ~700+).
#
# Prerequisites: rocks-demo `st_bucket_ingest_build.exe`; `segments_meta.csv` + `segments_points.csv`.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\build_wuxi_segment_third_tier_hourly.ps1

param(
  [string]$SegmentMetaCsv = "",
  [string]$SegmentPointsCsv = "",
  [string]$OutSstDir = "",
  [string]$TargetDb = "",
  [int]$BucketSec = 3600,
  [string]$StBucketIngestBuildExe = ""
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
$Root = [System.IO.Path]::GetFullPath((Join-Path $ToolsDir ".."))
if ([string]::IsNullOrWhiteSpace($SegmentMetaCsv)) {
  $SegmentMetaCsv = Join-Path $Root "data\processed\wuxi\segments_meta.csv"
}
if ([string]::IsNullOrWhiteSpace($SegmentPointsCsv)) {
  $SegmentPointsCsv = Join-Path $Root "data\processed\wuxi\segments_points.csv"
}
if ([string]::IsNullOrWhiteSpace($OutSstDir)) {
  $OutSstDir = Join-Path $Root "data\wuxi_bucket_sst_tmp"
}
if ([string]::IsNullOrWhiteSpace($TargetDb)) {
  $TargetDb = Join-Path $Root "data\verify_wuxi_segment_bucket3600_sst"
}
if ([string]::IsNullOrWhiteSpace($StBucketIngestBuildExe)) {
  $StBucketIngestBuildExe = Join-Path $Root "rocks-demo\build\st_bucket_ingest_build.exe"
}
if (-not (Test-Path -LiteralPath $StBucketIngestBuildExe)) {
  throw "Missing $StBucketIngestBuildExe — cmake --build rocks-demo/build --target st_bucket_ingest_build"
}
if (-not (Test-Path -LiteralPath $SegmentMetaCsv)) {
  throw "Missing segment meta CSV: $SegmentMetaCsv"
}
if (-not (Test-Path -LiteralPath $SegmentPointsCsv)) {
  throw "Missing segment points CSV: $SegmentPointsCsv"
}

Write-Host "=== Third tier: hourly bucket ingest (bucket_sec=$BucketSec) -> $TargetDb ===" -ForegroundColor Cyan
& $StBucketIngestBuildExe `
  --segment-meta-csv $SegmentMetaCsv `
  --segment-points-csv $SegmentPointsCsv `
  --out-sst-dir $OutSstDir `
  --target-db $TargetDb `
  --bucket-sec $BucketSec `
  --reset-out-sst-dir `
  --reset-target-db
if ($LASTEXITCODE -ne 0) {
  throw "st_bucket_ingest_build failed (exit $LASTEXITCODE)"
}

$n = 0
if (Test-Path -LiteralPath $TargetDb) {
  $n = (Get-ChildItem -LiteralPath $TargetDb -Filter "*.sst" -File -ErrorAction SilentlyContinue | Measure-Object).Count
}
Write-Host "Live *.sst count under third-tier DB: $n (paper: report N + bucket_sec=$BucketSec; not ""776"" or ""736"" as exact counts)." -ForegroundColor Green
Write-Host "Next: build Vanilla replicas if needed: tools\build_wuxi_vanilla_replica_dbs.ps1 (third tier defaults to bucket3600_sst)" -ForegroundColor DarkGray

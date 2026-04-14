# One-shot workflow:
#  1) Build (or reuse) persisted Vanilla wall_us cache: 3 DBs × 12 windows × N repeats (default 10), median per cell.
#  2) Run Wuxi ablation M times (default 10) into parent\run_01 .. run_MM using ONLY the cache for vanilla columns
#     (-RequireVanillaFromCache so missing cache entries fail loudly in TSV).
#  3) python aggregate_wuxi_ablation_runs.py --parent <parent> --json aggregate.json
#  4) python refresh_wuxi_ablation_chart_html.py aggregate.json docs/st_ablation_wuxi_1sst_vs_manysst.html
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\run_wuxi_vanilla_cached_ablation_batch.ps1
#   （默认对消融开启 KV 验证；仅加速迭代时加 -SkipVerifyKVResults）
#
# Prerequisites: upstream-RocksDB-readable replicas for each fork DB (see tools/build_wuxi_vanilla_replica_dbs.ps1).
# Cache build uses *_vanilla_replica paths; ablation bench still uses fork verify_wuxi_segment_* paths.
# Pre-flight: tools\audit_wuxi_ablation_inputs.ps1 (164sst must be multi-SST, not 1 file).

param(
  [string]$ParentOutDir = "",
  [string]$VanillaCacheJson = "",
  [int]$VanillaRepeat = 10,
  [int]$AblationRuns = 10,
  [string]$WindowsCsv = "",
  [string]$RocksDbPathsCsv = "D:\Project\data\verify_wuxi_segment_1sst,D:\Project\data\verify_wuxi_segment_164sst,D:\Project\data\verify_wuxi_segment_bucket3600_sst",
  [string]$RefreshHtml = "",
  [switch]$SkipVerifyKVResults,
  [switch]$SkipBuildVanillaCache,
  [switch]$ForceBuildVanillaCache,
  [int]$TimeBucketCount = 736
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
$RootDir = Resolve-Path (Join-Path $ToolsDir "..")

function Resolve-ForkRocksDbPathsCsv {
  param([string]$Csv)
  . (Join-Path $PSScriptRoot "wuxi_resolve_third_tier_fork.ps1")
  $dataRoot = [System.IO.Path]::GetFullPath((Join-Path $RootDir "data"))
  $r = Get-WuxiResolvedThirdTierCsv -RocksDbPathsCsv $Csv -DataRoot $dataRoot
  return $r.RocksDbPathsCsv
}

function Get-VanillaReplicaPathsCsv {
  param([string]$ForkPathsCsvResolved)
  $parts = @(
    $ForkPathsCsvResolved.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 }
  )
  $reps = New-Object System.Collections.Generic.List[string]
  foreach ($fp in $parts) {
    $fullFp = [System.IO.Path]::GetFullPath($fp)
    $dir = [System.IO.Path]::GetDirectoryName($fullFp)
    $leaf = [System.IO.Path]::GetFileName($fullFp)
    $rep = Join-Path $dir ($leaf + "_vanilla_replica")
    if (-not (Test-Path -LiteralPath $rep)) {
      throw @"
Missing upstream Vanilla replica: $rep
Build replicas (fork dump -> st_vanilla_kv_stream_ingest), e.g.:
  powershell -NoProfile -ExecutionPolicy Bypass -File `"$ToolsDir\build_wuxi_vanilla_replica_dbs.ps1`"
Or set -RocksDbPathsCsv to fork paths that have sibling *_vanilla_replica directories.
"@
    }
    [void]$reps.Add(([System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $rep).Path)))
  }
  return ($reps -join ',')
}

$Stratified12 = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi_stratified12_n4m4w4.csv"
$Random12Cov = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi_random12_cov_s42.csv"
if ([string]::IsNullOrWhiteSpace($WindowsCsv)) {
  if (Test-Path -LiteralPath $Stratified12) {
    $WindowsCsv = $Stratified12
  } elseif (Test-Path -LiteralPath $Random12Cov) {
    $WindowsCsv = $Random12Cov
  }
}

$ForkRocksDbPathsCsv = Resolve-ForkRocksDbPathsCsv -Csv $RocksDbPathsCsv

if ([string]::IsNullOrWhiteSpace($VanillaCacheJson)) {
  $VanillaCacheJson = Join-Path $RootDir "data\experiments\wuxi_vanilla_wall_cache.json"
}
$VanillaCacheJson = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($VanillaCacheJson)

if ([string]::IsNullOrWhiteSpace($ParentOutDir)) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $ParentOutDir = Join-Path $RootDir "data\experiments\wuxi_ablation_vanilla_baseline_${stamp}"
}
$ParentOutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ParentOutDir)
New-Item -ItemType Directory -Force -Path $ParentOutDir | Out-Null

if ([string]::IsNullOrWhiteSpace($RefreshHtml)) {
  $RefreshHtml = Join-Path $RootDir "docs\st_ablation_wuxi_1sst_vs_manysst.html"
}
$RefreshHtml = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RefreshHtml)

$AblationScript = Join-Path $ToolsDir "run_wuxi_segment_ablation_1_164_776.ps1"
$CacheScript = Join-Path $ToolsDir "cache_wuxi_vanilla_wall_baseline.ps1"
if (-not (Test-Path -LiteralPath $AblationScript)) { throw "Missing: $AblationScript" }
if (-not (Test-Path -LiteralPath $CacheScript)) { throw "Missing: $CacheScript" }

$buildCache = $true
if ($SkipBuildVanillaCache -and (Test-Path -LiteralPath $VanillaCacheJson)) {
  $buildCache = $false
}
if ($ForceBuildVanillaCache) {
  $buildCache = $true
}

if ($buildCache) {
  $vanillaReplicaCsv = Get-VanillaReplicaPathsCsv -ForkPathsCsvResolved $ForkRocksDbPathsCsv
  Write-Host "=== Building Vanilla wall cache -> $VanillaCacheJson ($VanillaRepeat x median per window × 3 SST layouts) ===" -ForegroundColor Cyan
  Write-Host "    Vanilla DBs (upstream): $vanillaReplicaCsv" -ForegroundColor DarkGray
  $cargs = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $CacheScript,
    "-OutJson", $VanillaCacheJson,
    "-RepeatCount", "$VanillaRepeat",
    "-RocksDbPathsCsv", $vanillaReplicaCsv
  )
  if (-not [string]::IsNullOrWhiteSpace($WindowsCsv)) {
    $cargs += "-WindowsCsv"
    $cargs += $WindowsCsv
  }
  & powershell @cargs
} else {
  Write-Host "Skip Vanilla cache build (using $VanillaCacheJson)" -ForegroundColor DarkGray
}

Write-Host "=== Wuxi ablation x$AblationRuns under $ParentOutDir (Vanilla from cache only) ===" -ForegroundColor Cyan
for ($i = 1; $i -le $AblationRuns; $i++) {
  $sub = "run_{0:D2}" -f $i
  $runDir = Join-Path $ParentOutDir $sub
  $aargs = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $AblationScript,
    "-OutDir", $runDir,
    "-RocksDbPathsCsv", $ForkRocksDbPathsCsv,
    "-VanillaWallCacheJson", $VanillaCacheJson,
    "-RequireVanillaFromCache"
  )
  if (-not [string]::IsNullOrWhiteSpace($WindowsCsv)) {
    $aargs += "-WindowsCsv"
    $aargs += $WindowsCsv
  }
  if ($SkipVerifyKVResults.IsPresent) {
    $aargs += "-SkipVerifyKVResults"
  }
  if ($TimeBucketCount -gt 0) {
    $aargs += "-TimeBucketCount"
    $aargs += "$TimeBucketCount"
  }
  Write-Host "--- $sub ---" -ForegroundColor Yellow
  & powershell @aargs
}

$aggJson = Join-Path $ParentOutDir "aggregate.json"
Write-Host "=== aggregate -> $aggJson ===" -ForegroundColor Cyan
& python (Join-Path $ToolsDir "aggregate_wuxi_ablation_runs.py") `
  --parent $ParentOutDir `
  --json $aggJson `
  --min-full-keys 50 `
  --baseline vanilla

Write-Host "=== refresh HTML -> $RefreshHtml ===" -ForegroundColor Cyan
& python (Join-Path $ToolsDir "refresh_wuxi_ablation_chart_html.py") $aggJson $RefreshHtml

Write-Host "Done. Parent: $ParentOutDir" -ForegroundColor Green

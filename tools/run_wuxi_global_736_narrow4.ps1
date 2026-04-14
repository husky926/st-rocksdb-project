# Global (manifest) only on the **third** Wuxi fork DB (hourly bucket3600_sst; legacy 776/736 if present) × **4 narrow** windows.
# Bench profile matches EXPERIMENTS_AND_SCRIPTS.md §2.3 (VM + VMAuto + TimeBucketCount=736 + adaptive gates).
# Default: fork full↔prune KV verify + Vanilla wall baseline (cache or replica), same as main ablation.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\run_wuxi_global_736_narrow4.ps1
#   powershell ... -OutDir D:\Project\data\experiments\my_run -SkipVerifyKVResults

param(
  [string]$OutDir = "",
  [string]$WindowsCsv = "",
  [switch]$SkipVerifyKVResults,
  [string]$VanillaWallCacheJson = "",
  [string]$VanillaWallDbPathsCsv = "",
  [switch]$AllowForkFullBaseline
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
$RootDir = Resolve-Path (Join-Path $ToolsDir "..")
$Sweep = Join-Path $ToolsDir "st_prune_vs_full_baseline_sweep.ps1"
$Bench = Join-Path $ToolsDir "..\rocks-demo\build\st_meta_read_bench.exe"
$Narrow4 = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi_stratified12_narrow4.csv"

$dataRoot = [System.IO.Path]::GetFullPath((Join-Path $RootDir "data"))
. (Join-Path $ToolsDir "wuxi_resolve_third_tier_fork.ps1")
$csv3 = @(
  (Join-Path $dataRoot "verify_wuxi_segment_1sst"),
  (Join-Path $dataRoot "verify_wuxi_segment_164sst"),
  (Join-Path $dataRoot "verify_wuxi_segment_bucket3600_sst")
) -join ","
$r = Get-WuxiResolvedThirdTierCsv -RocksDbPathsCsv $csv3 -DataRoot $dataRoot
$DbPath = ($r.RocksDbPathsCsv.Split(",") | ForEach-Object { $_.Trim() })[2]
if (-not (Test-Path -LiteralPath $DbPath)) {
  throw "Third-tier fork DB missing. Build: tools\build_wuxi_segment_third_tier_hourly.ps1"
}

if ([string]::IsNullOrWhiteSpace($WindowsCsv)) {
  $WindowsCsv = $Narrow4
}
if (-not (Test-Path -LiteralPath $WindowsCsv)) {
  throw "Missing: $WindowsCsv"
}
if (-not (Test-Path -LiteralPath $Sweep)) { throw "Missing: $Sweep" }
if (-not (Test-Path -LiteralPath $Bench)) { throw "Build first: $Bench" }

if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $leaf = [System.IO.Path]::GetFileName($DbPath)
  $OutDir = Join-Path $RootDir "data\experiments\wuxi_global_narrow4_${leaf}_${stamp}"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$defaultCache = Join-Path $RootDir "data\experiments\wuxi_vanilla_wall_cache.json"
$useCache = $false
$cachePath = ""
if (-not [string]::IsNullOrWhiteSpace($VanillaWallCacheJson)) {
  $cachePath = $VanillaWallCacheJson
  $useCache = $true
} elseif (Test-Path -LiteralPath $defaultCache) {
  $cachePath = $defaultCache
  $useCache = $true
}

$vanillaExe = Join-Path $ToolsDir "..\rocks-demo\build\st_segment_window_scan_vanilla.exe"
$haveVanilla = $useCache -or (Test-Path -LiteralPath $vanillaExe)
if (-not $haveVanilla -and -not $AllowForkFullBaseline) {
  throw @"
Need Vanilla baseline: wuxi_vanilla_wall_cache.json or st_segment_window_scan_vanilla.exe
Or pass -AllowForkFullBaseline (no Vanilla; kv verify uses fork full only).
"@
}

$vanillaDb = ""
if ([string]::IsNullOrWhiteSpace($VanillaWallDbPathsCsv)) {
  $dir = [System.IO.Path]::GetDirectoryName($DbPath)
  $leaf = [System.IO.Path]::GetFileName($DbPath)
  $rep = Join-Path $dir ($leaf + "_vanilla_replica")
  if (Test-Path -LiteralPath $rep) {
    $vanillaDb = (Resolve-Path -LiteralPath $rep).Path
    Write-Host "Vanilla wall DB: $vanillaDb" -ForegroundColor DarkGray
  } else {
    $vanillaDb = $DbPath
    Write-Warning "No replica at $rep — using fork path for Vanilla columns (often empty wall_us)."
  }
} else {
  $vanillaDb = ($VanillaWallDbPathsCsv.Split(',')[0]).Trim()
}

$compareVanilla = -not $AllowForkFullBaseline
$meta = @{
  experiment      = "wuxi_global_third_tier_narrow4"
  fork_db         = $DbPath
  windows_csv     = $WindowsCsv
  prune_mode      = "manifest"
  vanilla_wall_db = $vanillaDb
  vanilla_cache   = if ($useCache) { $cachePath } else { "" }
  generated_utc   = (Get-Date).ToUniversalTime().ToString("o")
}
$meta | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutDir "wuxi_global_narrow4_meta.json") -Encoding utf8

$OutTsv = Join-Path $OutDir "global_manifest_narrow4.tsv"
$args = @(
  "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Sweep,
  "-RocksDbPaths", $DbPath,
  "-WindowsCsv", $WindowsCsv,
  "-Bench", $Bench,
  "-PruneMode", "manifest",
  "-FullScanMode", "window",
  "-OutTsv", $OutTsv,
  "-TimeBucketCount", "736",
  "-RTreeLeafSize", "8",
  "-VirtualMerge",
  "-VirtualMergeAuto",
  "-VmTimeSpanSecThreshold", "21600",
  "-SstManifestAdaptiveKeyGate",
  "-SstManifestAdaptiveBlockGate",
  "-AdaptiveOverlapThreshold", "0.6",
  "-AdaptiveBlockOverlapThreshold", "0.85"
)
if (-not $SkipVerifyKVResults.IsPresent) {
  $args += "-VerifyKVResults"
}
if ($useCache) {
  $args += "-VanillaWallCacheJson"
  $args += $cachePath
  $args += "-RequireVanillaCache"
}
if ($compareVanilla) {
  $args += "-VanillaAsBaseline"
  $args += "-VanillaWallDbPathsCsv"
  $args += $vanillaDb
}
if (-not $useCache -and (Test-Path -LiteralPath $vanillaExe)) {
  $args += "-VanillaSegmentBenchExe"
  $args += $vanillaExe
}

Write-Host "=== Global (manifest) narrow×4 -> $OutTsv ===" -ForegroundColor Cyan
Write-Host "  DB: $DbPath" -ForegroundColor DarkGray
& powershell @args

Write-Host "Done. Output: $OutDir" -ForegroundColor Green

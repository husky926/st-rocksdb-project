# Build a JSON cache of upstream Vanilla RocksDB segment-window wall_us (median over N repeats)
# for each (db path, window row) in the same Windows CSV used by the Wuxi ablation sweep.
# **If you change the canonical windows CSV** (e.g. switch to stratified12), rebuild this cache or
# Vanilla columns in sweep will miss / mismatch geometry vs old JSON.
# Ablation runs can pass -VanillaWallCacheJson to st_prune_vs_full_baseline_sweep.ps1 to skip re-invoking vanilla.exe.
# Use -RocksDbPathsCsv pointing at **Vanilla-readable** dirs (e.g. *_vanilla_replica), same strings as sweep's
# VanillaWallDbPathsCsv / run_wuxi auto replica paths — not fork-only paths if upstream cannot open them.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\cache_wuxi_vanilla_wall_baseline.ps1 `
#     -OutJson D:\Project\data\experiments\wuxi_vanilla_wall_cache.json

param(
  [string]$WindowsCsv = "",
  [string]$RocksDbPathsCsv = "D:\Project\data\verify_wuxi_segment_1sst,D:\Project\data\verify_wuxi_segment_164sst,D:\Project\data\verify_wuxi_segment_bucket3600_sst",
  [string]$VanillaSegmentBenchExe = "",
  [string]$OutJson = "",
  [int]$RepeatCount = 10
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}

if ([string]::IsNullOrWhiteSpace($VanillaSegmentBenchExe)) {
  $VanillaSegmentBenchExe = Join-Path $ToolsDir "..\rocks-demo\build\st_segment_window_scan_vanilla.exe"
}
if (-not (Test-Path -LiteralPath $VanillaSegmentBenchExe)) {
  throw "Missing vanilla bench: $VanillaSegmentBenchExe (build rocksdb_vanilla / bootstrap_rocksdb_vanilla.ps1)"
}

$Stratified12 = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi_stratified12_n4m4w4.csv"
$Random12Cov = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi_random12_cov_s42.csv"
$Random12 = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi_random12_s42.csv"
$LegacyWindows = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi.csv"
if ([string]::IsNullOrWhiteSpace($WindowsCsv)) {
  if (Test-Path -LiteralPath $Stratified12) { $WindowsCsv = $Stratified12 }
  elseif (Test-Path -LiteralPath $Random12Cov) { $WindowsCsv = $Random12Cov }
  elseif (Test-Path -LiteralPath $Random12) { $WindowsCsv = $Random12 }
  else { $WindowsCsv = $LegacyWindows }
}
if (-not (Test-Path -LiteralPath $WindowsCsv)) {
  throw "Missing: $WindowsCsv"
}

. (Join-Path $ToolsDir "wuxi_resolve_third_tier_fork.ps1")
$dataRoot = [System.IO.Path]::GetFullPath((Join-Path $ToolsDir "..\data"))
$r3 = Get-WuxiResolvedThirdTierCsv -RocksDbPathsCsv $RocksDbPathsCsv -DataRoot $dataRoot
$RocksDbPathsCsv = $r3.RocksDbPathsCsv
$used736Fallback = ($r3.ResolvedThirdPath -match "verify_wuxi_segment_736sst$")

$RocksDbPaths = @(
  $RocksDbPathsCsv.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 }
)
if ($RocksDbPaths.Count -eq 0) {
  throw "No RocksDb paths in RocksDbPathsCsv"
}

if ([string]::IsNullOrWhiteSpace($OutJson)) {
  $OutJson = Join-Path $ToolsDir "..\data\experiments\wuxi_vanilla_wall_cache.json"
}
# Avoid Split-Path -LiteralPath -Parent: some Windows PowerShell builds reject that parameter set.
$dir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($OutJson))
if (-not [string]::IsNullOrWhiteSpace($dir)) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
}

function Invoke-VanillaOnce {
  param(
    [string]$Exe,
    [string]$DbPath,
    [uint32]$TMin,
    [uint32]$TMax,
    [double]$XMin,
    [double]$XMax,
    [double]$YMin,
    [double]$YMax
  )
  $vargs = @(
    "--db", $DbPath,
    "--prune-t-min", "$TMin", "--prune-t-max", "$TMax",
    "--prune-x-min", "$XMin", "--prune-x-max", "$XMax",
    "--prune-y-min", "$YMin", "--prune-y-max", "$YMax"
  )
  # Start-Process + redirect files: reliably captures native stderr (exit 3/4 messages)
  # on Windows; piping 2>&1 often drops Iterator/Corruption lines.
  $so = [System.IO.Path]::GetTempFileName()
  $se = [System.IO.Path]::GetTempFileName()
  $exitCode = -1
  $vraw = ""
  try {
    $proc = Start-Process -FilePath $Exe -ArgumentList $vargs -Wait -PassThru `
      -NoNewWindow -RedirectStandardOutput $so -RedirectStandardError $se
    if ($null -ne $proc -and $null -ne $proc.ExitCode) {
      $exitCode = [int]$proc.ExitCode
    }
    $outTxt = if (Test-Path -LiteralPath $so) { [System.IO.File]::ReadAllText($so) } else { "" }
    $errTxt = if (Test-Path -LiteralPath $se) { [System.IO.File]::ReadAllText($se) } else { "" }
    $vraw = ($outTxt.Trim() + "`n" + $errTxt.Trim()).Trim()
  } catch {
    $vraw = "Start-Process failed: $($_.Exception.Message)"
    $exitCode = -1
  } finally {
    Remove-Item -LiteralPath $so -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $se -ErrorAction SilentlyContinue
  }
  if ($vraw -match 'vanilla_segment_scan keys=(\d+)\s+keys_scanned_total=(\d+)\s+block_read_count=(\d+)\s+wall_us=([\d.eE+-]+)') {
    return [PSCustomObject]@{
      ok = $true
      keys = $Matches[1]
      keys_scanned_total = $Matches[2]
      block_read = $Matches[3]
      wall_us = [double]$Matches[4]
      snippet = ($vraw -split "`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
    }
  }
  $one = ($vraw -split "`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
  if ([string]::IsNullOrWhiteSpace($one)) {
    if ($exitCode -eq 4) {
      $one = "exit=4: Iterator failed during full scan (upstream RocksDB hit bad/corrupt block or incompatible SST). Rebuild a Vanilla-readable replica: docs/VANILLA_ROCKSDB_BASELINE.md Phase 1."
    } elseif ($exitCode -eq 3) {
      $one = "exit=3: DB::Open failed (OPTIONS/version/comparator). See docs/VANILLA_ROCKSDB_BASELINE.md Phase 0/1."
    } else {
      $one = "no captured output (exit=$exitCode). See docs/VANILLA_ROCKSDB_BASELINE.md Phase 0/1."
    }
  }
  return [PSCustomObject]@{ ok = $false; keys = ""; keys_scanned_total = ""; block_read = ""; wall_us = [double]::NaN; snippet = $one }
}

function Median-Double {
  param([double[]]$Values)
  $v = @($Values | Where-Object { -not [double]::IsNaN($_) } | Sort-Object)
  if ($v.Count -eq 0) { return [double]::NaN }
  $m = [math]::Floor($v.Count / 2)
  if (($v.Count % 2) -eq 1) { return [double]$v[$m] }
  return ([double]$v[$m - 1] + [double]$v[$m]) / 2.0
}

$rows = Import-Csv -LiteralPath $WindowsCsv
$entries = @()

foreach ($dbPath in $RocksDbPaths) {
  if (-not (Test-Path -LiteralPath $dbPath)) {
    Write-Warning "Skip missing db: $dbPath"
    continue
  }
  $dbResolved = (Resolve-Path -LiteralPath $dbPath).Path
  foreach ($r in $rows) {
    $label = [string]$r.Label
    Write-Host "=== Vanilla cache: $label :: $dbResolved ($RepeatCount x) ===" -ForegroundColor Cyan
    $walls = New-Object System.Collections.Generic.List[double]
    $lastKeys = ""; $lastKst = ""; $lastBr = ""
    $fail = 0
    for ($i = 1; $i -le $RepeatCount; $i++) {
      $o = Invoke-VanillaOnce -Exe $VanillaSegmentBenchExe -DbPath $dbResolved `
        -TMin ([uint32]$r.TMin) -TMax ([uint32]$r.TMax) `
        -XMin ([double]$r.XMin) -XMax ([double]$r.XMax) `
        -YMin ([double]$r.YMin) -YMax ([double]$r.YMax)
      if ($o.ok) {
        $walls.Add([double]$o.wall_us)
        $lastKeys = [string]$o.keys
        $lastKst = [string]$o.keys_scanned_total
        $lastBr = [string]$o.block_read
      } else {
        $fail++
        Write-Warning "  run $i/$RepeatCount fail: $($o.snippet)"
      }
    }
    $med = Median-Double -Values ($walls.ToArray())
    $reg = ""
    if ($r.PSObject.Properties.Name -contains "Regime") {
      $reg = [string]$r.Regime
    }
    $entries += [PSCustomObject]@{
      db = $dbResolved
      label = $label
      regime = $reg
      repeat_count = $RepeatCount
      run_failures = $fail
      wall_us_runs = @($walls.ToArray())
      wall_us_median = if ([double]::IsNaN($med)) { $null } else { $med }
      keys = $lastKeys
      keys_scanned_total = $lastKst
      block_read = $lastBr
    }
    if ([double]::IsNaN($med)) {
      Write-Warning "No successful vanilla runs for $label @ $dbResolved (all $RepeatCount failed?)"
    }
  }
}

$payload = [PSCustomObject]@{
  version = 1
  kind = "wuxi_vanilla_wall_cache"
  generated_utc = (Get-Date).ToUniversalTime().ToString("o")
  used_736sst_fallback = $used736Fallback
  windows_csv = (Resolve-Path -LiteralPath $WindowsCsv).Path
  rocks_db_paths_csv = $RocksDbPathsCsv
  vanilla_segment_bench_exe = (Resolve-Path -LiteralPath $VanillaSegmentBenchExe).Path
  repeat_count = $RepeatCount
  entries = $entries
}

$payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutJson -Encoding utf8
Write-Host "Wrote $OutJson ($($entries.Count) entries)" -ForegroundColor Green

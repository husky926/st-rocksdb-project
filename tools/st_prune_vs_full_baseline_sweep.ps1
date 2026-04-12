# Phase A: for each query window run st_meta_read_bench with baseline + prune_scan.
# Default baseline: fork full scan (--full-scan-mode window).
# Optional -VanillaAsBaseline: skip fork full (--no-full-scan), run upstream Vanilla first,
# then copy Vanilla metrics into full_* columns (full_keys/full_wall_us/...) so ratios use Vanilla
# as the denominator instead of fork full_scan.
# Fork segment DBs often break upstream Vanilla iterator — use -VanillaWallDbPathsCsv (comma-aligned
# with -RocksDbPaths) pointing at *_vanilla_replica dirs, and/or VanillaWallCacheJson built on those paths.
# See docs/st_rocksdb_hard_baseline_experiment.md
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\st_prune_vs_full_baseline_sweep.ps1 `
#     -RocksDbPaths D:\Project\data\verify_pkdd_st `
#     -WindowsCsv D:\Project\tools\st_validity_experiment_windows_pkdd.csv `
#     -OutTsv D:\Project\data\experiments\prune_vs_full_pkdd.tsv
#
# Persisted upstream Vanilla wall clock (no per-row exe calls):
#   -VanillaWallCacheJson D:\Project\data\experiments\wuxi_vanilla_wall_cache.json
# Optional strict mode when using cache: -RequireVanillaCache (TSV error if cache miss / empty vanilla_wall_us).

param(
  [string[]]$RocksDbPaths = $null,
  [string]$RocksDbPathsCsv = "",
  [string]$Bench = "",
  [string]$WindowsCsv = "",
  [string]$OutTsv = "",
  [string]$PruneMode = "sst_manifest",
  [ValidateSet("window", "all_cf")]
  [string]$FullScanMode = "window",
  [switch]$VerifyKVResults,
  [uint32]$TimeBucketCount = 32,
  [uint32]$RTreeLeafSize = 8,
  [uint32]$SstManifestKeyLevel = 1,
  [switch]$SstManifestAdaptiveKeyGate,
  [switch]$SstManifestAdaptiveBlockGate,
  [float]$AdaptiveOverlapThreshold = 0.6,
  [float]$AdaptiveBlockOverlapThreshold = 0.85,
  [switch]$VirtualMerge,
  [switch]$VirtualMergeAuto,
  [uint32]$VmTimeSpanSecThreshold = 21600,
  [uint32]$VmContainsBatchPrewarm = 1,
  [uint32]$SstManifestKeyLevelBoundaryOnly = 0,
  [int]$IteratorRepeat = 1,
  [string]$VanillaSegmentBenchExe = "",
  [string]$VanillaWallCacheJson = "",
  [switch]$RequireVanillaCache,
  [switch]$VanillaAsBaseline,
  [string]$VanillaWallDbPathsCsv = ""
)

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
  $RocksDbPaths = @(Join-Path $ToolsDir "..\data\verify_pkdd_st")
}
if ([string]::IsNullOrWhiteSpace($Bench)) {
  $Bench = Join-Path $ToolsDir "..\rocks-demo\build\st_meta_read_bench.exe"
}
if ([string]::IsNullOrWhiteSpace($WindowsCsv)) {
  $WindowsCsv = Join-Path $ToolsDir "st_validity_experiment_windows_pkdd.csv"
}

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $Bench)) {
  Write-Error "Build first: $Bench"
}
if (-not (Test-Path -LiteralPath $WindowsCsv)) {
  Write-Error "Missing CSV: $WindowsCsv"
}

function Invoke-BenchPair {
  param(
    [string]$DbPath,
    [string]$Label,
    [string]$PruneMode,
    [string]$FullScanMode,
    [uint32]$TimeBucketCount,
    [uint32]$RTreeLeafSize,
    [uint32]$SstManifestKeyLevel,
    [switch]$SstManifestAdaptiveKeyGate,
    [switch]$SstManifestAdaptiveBlockGate,
    [float]$AdaptiveOverlapThreshold,
    [float]$AdaptiveBlockOverlapThreshold,
    [switch]$VirtualMerge,
    [switch]$VirtualMergeAuto,
    [uint32]$VmTimeSpanSecThreshold,
    [uint32]$VmContainsBatchPrewarm,
    [uint32]$SstManifestKeyLevelBoundaryOnly,
    [int]$IteratorRepeat,
    [uint32]$TMin,
    [uint32]$TMax,
    [double]$XMin,
    [double]$XMax,
    [double]$YMin,
    [double]$YMax,
    [string]$VanillaSegmentBenchExe = "",
    [switch]$RequireVanillaCache,
    [switch]$VanillaAsBaseline,
    [string]$VanillaWallDb = ""
  )
  if (-not (Test-Path -LiteralPath $DbPath)) {
    return [PSCustomObject]@{
      db = $DbPath; label = $Label; error = "db_missing"
      fk = ""; fst = ""; fbr = ""; fb = ""; fw = ""; pk = ""; pbr = ""; pb = ""; pw = ""
      rb = ""; rbr = ""; rw = ""; ks = ""
      kv_correct = ""; kv_full_inwindow_kv = ""; kv_prune_inwindow_kv = ""
      vanilla_wall_us = ""; vanilla_keys = ""; vanilla_keys_scanned_total = ""; vanilla_block_read = ""
    }
  }
  $vwPath = $DbPath
  if (-not [string]::IsNullOrWhiteSpace($VanillaWallDb)) {
    $vwPath = $VanillaWallDb.Trim()
  }
  $vkw = ""; $vk = ""; $vkst = ""; $vbr = ""
  $cacheHit = $null
  if ($null -ne $script:RocksVanillaWallLookup) {
    $cp = $vwPath
    try { $cp = (Resolve-Path -LiteralPath $vwPath).Path } catch { }
    $ck = "${cp}|${Label}"
    if ($script:RocksVanillaWallLookup.ContainsKey($ck)) {
      $cacheHit = $script:RocksVanillaWallLookup[$ck]
    }
  }
  if ($null -ne $cacheHit) {
    $wm = $cacheHit.wall_us_median
    if ($null -ne $wm -and "$wm" -ne "") {
      try {
        $vkw = [string]([double]$wm)
      } catch {
        $vkw = "$wm"
      }
    }
    $vk = [string]$cacheHit.keys
    $vkst = [string]$cacheHit.keys_scanned_total
    $vbr = [string]$cacheHit.block_read
  } elseif (-not [string]::IsNullOrWhiteSpace($VanillaSegmentBenchExe) -and (Test-Path -LiteralPath $VanillaSegmentBenchExe)) {
    if (-not (Test-Path -LiteralPath $vwPath)) {
      Write-Warning "Vanilla wall DB not found: $vwPath (fork db=$DbPath label=$Label)"
    }
    $vargs = @(
      "--db", $vwPath,
      "--prune-t-min", "$TMin", "--prune-t-max", "$TMax",
      "--prune-x-min", "$XMin", "--prune-x-max", "$XMax",
      "--prune-y-min", "$YMin", "--prune-y-max", "$YMax"
    )
    # Vanilla often exits non-zero on fork DBs (SST/options incompatibility); with $ErrorActionPreference=Stop
    # or PS7 PSNativeCommandUseErrorActionPreference that would terminate the whole sweep before TSV is written.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $prevNative = $null
    if ($PSVersionTable.PSVersion.Major -ge 7) {
      $prevNative = $PSNativeCommandUseErrorActionPreference
      $PSNativeCommandUseErrorActionPreference = $false
    }
    try {
      $cap = New-Object System.Collections.Generic.List[string]
      & $VanillaSegmentBenchExe @vargs 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
          $cap.Add($_.ToString().Trim())
        } else {
          $cap.Add(("$($_)").Trim())
        }
      } | Out-Null
      $vraw = ($cap -join "`n").Trim()
    } finally {
      $ErrorActionPreference = $prevEap
      if ($PSVersionTable.PSVersion.Major -ge 7) {
        $PSNativeCommandUseErrorActionPreference = $prevNative
      }
    }
    if ($vraw -match 'vanilla_segment_scan keys=(\d+)\s+keys_scanned_total=(\d+)\s+block_read_count=(\d+)\s+wall_us=([\d.eE+-]+)') {
      $vk = $Matches[1]; $vkst = $Matches[2]; $vbr = $Matches[3]; $vkw = $Matches[4]
    } elseif ($vraw -match 'Corruption:|DB::Open failed') {
      $one = ($vraw -split "`n" | Where-Object { $_.Trim() -ne '' } | Select-Object -First 1)
      Write-Warning "Vanilla bench failed (TSV still written; vanilla columns empty): $one"
    }
  }
  if ($VanillaAsBaseline.IsPresent -and [string]::IsNullOrWhiteSpace($vkw)) {
    Write-Warning "VanillaAsBaseline: no vanilla_wall_us (cache miss or exe failed on '$vwPath'). Use *_vanilla_replica paths via -VanillaWallDbPathsCsv or build data/experiments/wuxi_vanilla_wall_cache.json on those paths."
    return [PSCustomObject]@{
      db = $DbPath; label = $Label; error = "vanilla_as_baseline_unavailable"
      fk = ""; fst = ""; fbr = ""; fb = ""; fw = ""; pk = ""; pbr = ""; pb = ""; pw = ""
      rb = ""; rbr = ""; rw = ""; ks = ""
      kv_correct = ""; kv_full_inwindow_kv = ""; kv_prune_inwindow_kv = ""
      vanilla_wall_us = $vkw; vanilla_keys = $vk; vanilla_keys_scanned_total = $vkst; vanilla_block_read = $vbr
      prune_file_skipped = ""; prune_file_considered = ""; prune_file_missing_meta = ""
      prune_file_range_del_blocked = ""; prune_file_time_disjoint = ""; prune_file_space_disjoint = ""
      prune_block_index_examined = ""; prune_block_index_skipped_st_disjoint = ""; prune_block_index_stop_missing_meta = ""
      prune_key_examined = ""; prune_key_skipped_disjoint = ""
      pk_in_window = ""
    }
  }
  $args = @(
    "--db", $DbPath,
    "--prune-t-min", "$TMin",
    "--prune-t-max", "$TMax",
    "--prune-x-min", "$XMin",
    "--prune-x-max", "$XMax",
    "--prune-y-min", "$YMin",
    "--prune-y-max", "$YMax",
    "--prune-mode", $PruneMode,
    "--full-scan-mode", $FullScanMode
  )
  if ($PruneMode -eq "manifest_timebucket_rtree") {
    $args += @("--time-bucket-count", "$TimeBucketCount", "--rtree-leaf-size", "$RTreeLeafSize")
  }
  if ($PruneMode -eq "sst_manifest") {
    $args += @("--sst-manifest-key-level", "$SstManifestKeyLevel")
    if ($SstManifestAdaptiveKeyGate.IsPresent) {
      $args += "--sst-manifest-adaptive-key-gate"
      $args += @("--adaptive-overlap-threshold", "$AdaptiveOverlapThreshold")
    }
    if ($SstManifestAdaptiveBlockGate.IsPresent) {
      $args += "--sst-manifest-adaptive-block-gate"
      $args += @("--adaptive-block-overlap-threshold", "$AdaptiveBlockOverlapThreshold")
    }
    $args += @("--sst-manifest-key-level-boundary-only", "$SstManifestKeyLevelBoundaryOnly")
  }
  if ($VirtualMerge.IsPresent) {
    $args += "--virtual-merge"
    $args += @("--time-bucket-count", "$TimeBucketCount", "--rtree-leaf-size", "$RTreeLeafSize")
  }
  if ($VirtualMergeAuto.IsPresent) {
    $args += "--virtual-merge-auto"
    $args += @("--vm-time-span-sec-threshold", "$VmTimeSpanSecThreshold")
    $args += @("--time-bucket-count", "$TimeBucketCount", "--rtree-leaf-size", "$RTreeLeafSize")
  }
  $args += @("--vm-contains-batch-prewarm", "$VmContainsBatchPrewarm")
  if ($IteratorRepeat -gt 1) {
    $args += @("--iterator-repeat", "$IteratorRepeat")
  }
  if ($VanillaAsBaseline.IsPresent) {
    $args += "--no-full-scan"
  }
  if ($VerifyKVResults.IsPresent -and -not $VanillaAsBaseline) {
    $args += "--verify-kv-results"
  } elseif ($VerifyKVResults.IsPresent -and $VanillaAsBaseline) {
    if (-not $script:WarnedVerifyVanilla) {
      Write-Warning "VerifyKVResults ignored with -VanillaAsBaseline (fork full scan is skipped)."
      $script:WarnedVerifyVanilla = $true
    }
  }
  $raw = & $Bench @args 2>&1 | Out-String

  function Grab {
    param([string]$Text, [string]$Pattern)
    if ($Text -match $Pattern) { return $Matches[1] }
    return ""
  }

  $fk = ""; $fst = ""; $fbr = ""; $fw = ""
  if ($raw -match 'full_scan mode=\S+\s+keys=(\d+)\s+keys_scanned_total=(\d+)\s+block_read_count=(\d+)\s+wall_us=([\d.eE+-]+)') {
    $fk = $Matches[1]; $fst = $Matches[2]; $fbr = $Matches[3]; $fw = $Matches[4]
  } elseif ($raw -match 'full_scan mode=\S+\s+keys=(\d+)\s+block_read_count=(\d+)\s+wall_us=([\d.eE+-]+)') {
    $fk = $Matches[1]; $fbr = $Matches[2]; $fw = $Matches[3]
  }
  $fb = Grab $raw 'full_scan IOStatsContext delta: bytes_read=(\d+)'
  $pk = ""; $pbr = ""; $pw = ""; $pkinw = ""
  # st_meta_read_bench 2026-04: iterator_repeat + wall_us_total + keys(last_iter)
  if ($raw -match 'prune_scan iterator_repeat=\d+\s+keys\(last_iter\)=(\d+)\s+block_read_count=(\d+)\s+wall_us_total=([\d.eE+-]+)') {
    $pk = $Matches[1]; $pbr = $Matches[2]; $pw = $Matches[3]
  } elseif ($raw -match 'prune_scan keys=(\d+) block_read_count=(\d+) wall_us=([\d.eE+-]+)') {
    $pk = $Matches[1]; $pbr = $Matches[2]; $pw = $Matches[3]
  }
  $pkinw = Grab $raw 'keys_in_window\(last_iter\)=(\d+)'
  if ($pkinw -eq "") {
    $pkinw = Grab $raw 'prune_scan keys=\d+ block_read_count=\d+ wall_us=[\d.eE+-]+\s+keys_in_window=(\d+)'
  }
  $pb = Grab $raw 'prune_scan IOStatsContext delta: bytes_read=(\d+)'
  $pskip = Grab $raw 'prune_file_skipped=(\d+)'
  $pconsider = Grab $raw 'prune_file_diag considered=(\d+)'
  $pmissing = Grab $raw 'prune_file_diag considered=\d+\s+missing_meta=(\d+)'
  $prangedel = Grab $raw 'prune_file_diag considered=\d+\s+missing_meta=\d+\s+range_del_blocked=(\d+)'
  $ptime = Grab $raw 'prune_file_diag .*time_disjoint=(\d+)'
  $pspace = Grab $raw 'prune_file_diag .*space_disjoint=(\d+)'
  $pblk_ex = Grab $raw 'prune_block_diag index_examined=(\d+)'
  $pblk_skip = Grab $raw 'prune_block_diag index_examined=\d+\s+index_skipped_st_disjoint=(\d+)'
  $pblk_nometa = Grab $raw 'prune_block_diag index_examined=\d+\s+index_skipped_st_disjoint=\d+\s+index_stop_missing_meta=(\d+)'
  $pkey_ex = Grab $raw 'prune_key_diag keys_examined=(\d+)'
  $pkey_skip = Grab $raw 'prune_key_diag keys_examined=\d+\s+keys_skipped_disjoint=(\d+)'

  $rb = ""; $rbr = ""; $rw = ""; $ks = ""
  if ($raw -match 'key_selectivity\(in_window prune/full\)=([\d.eE+-]+)') { $ks = $Matches[1] }
  elseif ($raw -match 'key_selectivity\(prune/full\)=([\d.eE+-]+)') { $ks = $Matches[1] }
  if ($raw -match 'block_read_ratio\(prune/full\)=([\d.eE+-]+)') { $rbr = $Matches[1] }
  if ($raw -match 'wall_time_ratio\(prune/full\)=([\d.eE+-]+)') { $rw = $Matches[1] }

  # With -VanillaAsBaseline, full_* are filled from Vanilla (upstream) below; recompute ratios vs prune.
  if ($VanillaAsBaseline.IsPresent -and $vkw -ne "") {
    $fk = $vk; $fst = $vkst; $fbr = $vbr; $fw = $vkw
    $fb = ""
    try {
      if ($fk -ne "" -and $pkinw -ne "") {
        $ks = [string]([math]::Round([double]$pkinw / [double]$fk, 6))
      }
    } catch {}
    try {
      if ($fbr -ne "" -and $pbr -ne "") {
        $dfbr = [double]$fbr; $dpbr = [double]$pbr
        if ($dfbr -gt 0) { $rbr = [string]([math]::Round($dpbr / $dfbr, 6)) }
      }
    } catch {}
    try {
      $dvw = [double]$vkw; $dpw = [double]$pw
      if ($dpw -gt 0) { $rw = [string]([math]::Round($dvw / $dpw, 6)) }
    } catch {}
  } elseif ($vkw -ne "" -and $pw -ne "") {
    try {
      $dvw = [double]$vkw; $dpw = [double]$pw
      if ($dpw -gt 0) { $rw = [string]([math]::Round($dvw / $dpw, 6)) }
    } catch {}
  }

  $kv_correct = ""; $kv_full = ""; $kv_prune = ""
  if ($raw -match 'verify_kv_results correctness=(OK|FAIL) full_inwindow_kv=(\d+) prune_inwindow_kv=(\d+)') {
    $kv_correct = $Matches[1]
    $kv_full = $Matches[2]
    $kv_prune = $Matches[3]
  }
  if ($fk -ne "" -and $fb -ne "" -and $pb -ne "") {
    try {
      $dfb = [double]$fb; $dpb = [double]$pb
      if ($dfb -gt 0) { $rb = [string]([math]::Round($dpb / $dfb, 6)) }
    } catch {}
  }

  $err = ""
  if ($fk -eq "" -or $pk -eq "") { $err = "parse_fail" }
  if ($RequireVanillaCache -and [string]::IsNullOrWhiteSpace($vkw)) {
    $err = if ($err) { "${err};no_vanilla_baseline" } else { "no_vanilla_baseline" }
  }

  return [PSCustomObject]@{
    db = $DbPath; label = $Label; error = $err
    fk = $fk; fst = $fst; fbr = $fbr; fb = $fb; fw = $fw
    pk = $pk; pk_in_window = $pkinw; pbr = $pbr; pb = $pb; pw = $pw
    ratio_bytes = $rb; ratio_block_read = $rbr; ratio_wall = $rw; key_sel = $ks
    kv_correct = $kv_correct; kv_full_inwindow_kv = $kv_full; kv_prune_inwindow_kv = $kv_prune
    prune_file_skipped = $pskip
    prune_file_considered = $pconsider
    prune_file_missing_meta = $pmissing
    prune_file_range_del_blocked = $prangedel
    prune_file_time_disjoint = $ptime
    prune_file_space_disjoint = $pspace
    prune_block_index_examined = $pblk_ex
    prune_block_index_skipped_st_disjoint = $pblk_skip
    prune_block_index_stop_missing_meta = $pblk_nometa
    prune_key_examined = $pkey_ex
    prune_key_skipped_disjoint = $pkey_skip
    vanilla_wall_us = $vkw
    vanilla_keys = $vk
    vanilla_keys_scanned_total = $vkst
    vanilla_block_read = $vbr
  }
}

$script:RocksVanillaWallLookup = $null
if (-not [string]::IsNullOrWhiteSpace($VanillaWallCacheJson) -and (Test-Path -LiteralPath $VanillaWallCacheJson)) {
  try {
    $j = Get-Content -LiteralPath $VanillaWallCacheJson -Raw -Encoding utf8 | ConvertFrom-Json
    $script:RocksVanillaWallLookup = @{}
    foreach ($e in @($j.entries)) {
      $dbn = [string]$e.db
      try { $dbn = (Resolve-Path -LiteralPath $dbn).Path } catch { }
      $lab = [string]$e.label
      $k = "${dbn}|${lab}"
      $script:RocksVanillaWallLookup[$k] = $e
    }
    Write-Host "Vanilla wall cache: $($script:RocksVanillaWallLookup.Count) (db,label) keys <- $VanillaWallCacheJson" -ForegroundColor DarkGray
  } catch {
    Write-Warning "Failed to load VanillaWallCacheJson ($VanillaWallCacheJson): $_"
    $script:RocksVanillaWallLookup = $null
  }
}

$VanillaWallDbPathsArray = @()
if (-not [string]::IsNullOrWhiteSpace($VanillaWallDbPathsCsv)) {
  $VanillaWallDbPathsArray = @(
    $VanillaWallDbPathsCsv.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_.Length -gt 0 }
  )
}

$script:WarnedVerifyVanilla = $false
$rows = Import-Csv -LiteralPath $WindowsCsv
$all = @()
for ($di = 0; $di -lt $RocksDbPaths.Count; $di++) {
  $dbPath = $RocksDbPaths[$di]
  $vanillaWallDbOne = ""
  if ($VanillaWallDbPathsArray.Count -gt $di) {
    $vanillaWallDbOne = $VanillaWallDbPathsArray[$di]
  }
  foreach ($r in $rows) {
    $pairLabel = if ($VanillaAsBaseline) { "vanilla_baseline+prune" } else { "full+prune" }
    $vwNote = if ($vanillaWallDbOne -ne "") { " vanilla_db=$vanillaWallDbOne" } else { "" }
    Write-Host "=== $($r.Label) :: $dbPath ($pairLabel)$vwNote ===" -ForegroundColor Cyan
    $o = Invoke-BenchPair -DbPath $dbPath -Label $r.Label -VanillaWallDb $vanillaWallDbOne `
      -PruneMode $PruneMode -FullScanMode $FullScanMode `
      -TimeBucketCount $TimeBucketCount -RTreeLeafSize $RTreeLeafSize `
      -SstManifestKeyLevel $SstManifestKeyLevel `
      -SstManifestAdaptiveKeyGate:$SstManifestAdaptiveKeyGate `
      -SstManifestAdaptiveBlockGate:$SstManifestAdaptiveBlockGate `
      -AdaptiveOverlapThreshold $AdaptiveOverlapThreshold `
      -AdaptiveBlockOverlapThreshold $AdaptiveBlockOverlapThreshold `
      -VirtualMerge:$VirtualMerge -VirtualMergeAuto:$VirtualMergeAuto `
      -VmTimeSpanSecThreshold $VmTimeSpanSecThreshold `
      -VmContainsBatchPrewarm $VmContainsBatchPrewarm `
      -SstManifestKeyLevelBoundaryOnly $SstManifestKeyLevelBoundaryOnly `
      -IteratorRepeat $IteratorRepeat `
      -VanillaSegmentBenchExe $VanillaSegmentBenchExe `
      -RequireVanillaCache:$RequireVanillaCache `
      -VanillaAsBaseline:$VanillaAsBaseline `
      -TMin ([uint32]$r.TMin) -TMax ([uint32]$r.TMax) `
      -XMin ([double]$r.XMin) -XMax ([double]$r.XMax) `
      -YMin ([double]$r.YMin) -YMax ([double]$r.YMax)
    $reg = ""
    if ($r.PSObject.Properties.Name -contains "Regime") {
      $reg = [string]$r.Regime
    }
    $o | Add-Member -MemberType NoteProperty -Name "regime" -Value $reg -Force
    $all += $o
  }
}

$header = "db`tlabel`tregime`tfull_keys`tfull_keys_scanned_total`tfull_block_read`tfull_bytes_read`tfull_wall_us`tvanilla_wall_us`tvanilla_keys`tvanilla_keys_scanned_total`tvanilla_block_read`tprune_keys`tprune_keys_in_window`tprune_block_read`tprune_bytes_read`tprune_wall_us`tratio_bytes`tratio_block_read`tratio_wall`tkey_selectivity`tprune_file_skipped`tprune_file_considered`tprune_file_missing_meta`tprune_file_range_del_blocked`tprune_file_time_disjoint`tprune_file_space_disjoint`tprune_block_index_examined`tprune_block_index_skipped_st_disjoint`tprune_block_index_stop_missing_meta`tprune_key_examined`tprune_key_skipped_disjoint`tkv_correct`tkv_full_inwindow_kv`tkv_prune_inwindow_kv`terror"
$lines = @($header)
foreach ($o in $all) {
  $lines += "$($o.db)`t$($o.label)`t$($o.regime)`t$($o.fk)`t$($o.fst)`t$($o.fbr)`t$($o.fb)`t$($o.fw)`t$($o.vanilla_wall_us)`t$($o.vanilla_keys)`t$($o.vanilla_keys_scanned_total)`t$($o.vanilla_block_read)`t$($o.pk)`t$($o.pk_in_window)`t$($o.pbr)`t$($o.pb)`t$($o.pw)`t$($o.ratio_bytes)`t$($o.ratio_block_read)`t$($o.ratio_wall)`t$($o.key_sel)`t$($o.prune_file_skipped)`t$($o.prune_file_considered)`t$($o.prune_file_missing_meta)`t$($o.prune_file_range_del_blocked)`t$($o.prune_file_time_disjoint)`t$($o.prune_file_space_disjoint)`t$($o.prune_block_index_examined)`t$($o.prune_block_index_skipped_st_disjoint)`t$($o.prune_block_index_stop_missing_meta)`t$($o.prune_key_examined)`t$($o.prune_key_skipped_disjoint)`t$($o.kv_correct)`t$($o.kv_full_inwindow_kv)`t$($o.kv_prune_inwindow_kv)`t$($o.error)"
}
$text = $lines -join "`n"
Write-Host ""
Write-Host $text
if ($OutTsv -ne "") {
  $text | Set-Content -LiteralPath $OutTsv -Encoding utf8
  Write-Host "Wrote $OutTsv"
}

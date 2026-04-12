# Triple ablation: same query windows with --prune-mode manifest | sst | sst_manifest.
# Goal: measure whether Local+Global (sst_manifest) beats the better of the two single-layer modes.
#
# synergy_prune = min(prune_wall_manifest, prune_wall_sst) / prune_wall_both
#   > 1  => combined prune pass is faster than BOTH singles (strong 1+1>2 on wall clock).
#   < 1  => best single mode was faster than combined (need wider windows or Local/Global fixes).
#
# synergy_ratio = min(ratio_wall_m, ratio_wall_s) / ratio_wall_both  (ratio_wall = prune/full, lower is better)
#   > 1  => combined has better relative prune/full than the better single mode.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\st_prune_synergy_ablation.ps1 `
#     -WindowsCsv D:\Project\data\experiments\wuxi_single_window_bench.csv `
#     -RocksDbPaths @("D:\Project\data\verify_wuxi_segment_manysst") `
#     -OutTsv D:\Project\data\experiments\synergy_wuxi.tsv
#
# Optional: -NoFullScan runs only prune_scan for each mode (faster; baseline ratios omitted).

param(
  [string[]]$RocksDbPaths = $null,
  [string]$WindowsCsv = "",
  [string]$Bench = "",
  [string]$OutTsv = "",
  [ValidateSet("window", "all_cf")]
  [string]$FullScanMode = "window",
  [switch]$VerifyKVResults,
  [switch]$NoFullScan
)

$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
if ($null -eq $RocksDbPaths -or $RocksDbPaths.Count -eq 0) {
  $RocksDbPaths = @(Join-Path $ToolsDir "..\data\verify_wuxi_segment_manysst")
}
if ([string]::IsNullOrWhiteSpace($Bench)) {
  $Bench = Join-Path $ToolsDir "..\rocks-demo\build\st_meta_read_bench.exe"
}
if ([string]::IsNullOrWhiteSpace($WindowsCsv)) {
  $WindowsCsv = Join-Path $ToolsDir "..\data\experiments\wuxi_single_window_bench.csv"
}

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $Bench)) {
  Write-Error "Build first: $Bench"
}
if (-not (Test-Path -LiteralPath $WindowsCsv)) {
  Write-Error "Missing CSV: $WindowsCsv"
}

function Grab([string]$Text, [string]$Pattern) {
  if ($Text -match $Pattern) { return $Matches[1] }
  return ""
}

function Invoke-OneMode {
  param(
    [string]$DbPath,
    [string]$PruneMode,
    [string]$FullScanMode,
    [uint32]$TMin,
    [uint32]$TMax,
    [double]$XMin,
    [double]$XMax,
    [double]$YMin,
    [double]$YMax,
    [bool]$NoFull
  )
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
  if ($NoFull) { $args += "--no-full-scan" }
  if ($VerifyKVResults.IsPresent) { $args += "--verify-kv-results" }
  $raw = & $Bench @args 2>&1 | Out-String

  $fw = ""
  if ($raw -match 'full_scan mode=\S+\s+keys=(\d+)\s+keys_scanned_total=(\d+)\s+block_read_count=(\d+)\s+wall_us=([\d.eE+-]+)') {
    $fw = $Matches[4]
  } elseif ($raw -match 'full_scan mode=\S+\s+keys=(\d+)\s+block_read_count=(\d+)\s+wall_us=([\d.eE+-]+)') {
    $fw = $Matches[3]
  }
  $pw = ""
  if ($raw -match 'prune_scan keys=(\d+) block_read_count=(\d+) wall_us=([\d.eE+-]+)') {
    $pw = $Matches[3]
  }
  $rw = Grab $raw 'wall_time_ratio\(prune/full\)=([\d.eE+-]+)'
  if ($NoFull -or [string]::IsNullOrWhiteSpace($fw)) { $rw = "" }

  $err = ""
  if ([string]::IsNullOrWhiteSpace($pw)) { $err = "parse_fail_prune" }
  if (-not $NoFull -and [string]::IsNullOrWhiteSpace($fw)) { $err = "parse_fail_full" }

  return [PSCustomObject]@{ fw = $fw; pw = $pw; rw = $rw; error = $err; raw = $raw }
}

function Synergy-Val([string]$a, [string]$b, [string]$c) {
  if ([string]::IsNullOrWhiteSpace($a) -or [string]::IsNullOrWhiteSpace($b) -or [string]::IsNullOrWhiteSpace($c)) {
    return ""
  }
  try {
    $ma = [double]$a; $sa = [double]$b; $bo = [double]$c
    if ($ma -le 0 -or $sa -le 0 -or $bo -le 0) { return "" }
    $best = [math]::Min($ma, $sa)
    return [string]([math]::Round($best / $bo, 6))
  } catch {
    return ""
  }
}

function Synergy-Ratio([string]$rm, [string]$rs, [string]$rb) {
  if ([string]::IsNullOrWhiteSpace($rm) -or [string]::IsNullOrWhiteSpace($rs) -or [string]::IsNullOrWhiteSpace($rb)) {
    return ""
  }
  try {
    $a = [double]$rm; $b = [double]$rs; $c = [double]$rb
    if ($a -le 0 -or $b -le 0 -or $c -le 0) { return "" }
    $best = [math]::Min($a, $b)
    return [string]([math]::Round($best / $c, 6))
  } catch {
    return ""
  }
}

$rows = Import-Csv -LiteralPath $WindowsCsv
$out = @()
foreach ($dbPath in $RocksDbPaths) {
  foreach ($r in $rows) {
    $lab = $r.Label
    Write-Host "=== synergy triple :: $lab :: $dbPath ===" -ForegroundColor Cyan
    $TMin = [uint32]$r.TMin
    $TMax = [uint32]$r.TMax
    $XMin = [double]$r.XMin
    $XMax = [double]$r.XMax
    $YMin = [double]$r.YMin
    $YMax = [double]$r.YMax

    $om = Invoke-OneMode -DbPath $dbPath -PruneMode "manifest" -FullScanMode $FullScanMode `
      -TMin $TMin -TMax $TMax -XMin $XMin -XMax $XMax -YMin $YMin -YMax $YMax -NoFull:$NoFullScan
    $os = Invoke-OneMode -DbPath $dbPath -PruneMode "sst" -FullScanMode $FullScanMode `
      -TMin $TMin -TMax $TMax -XMin $XMin -XMax $XMax -YMin $YMin -YMax $YMax -NoFull:$NoFullScan
    $ob = Invoke-OneMode -DbPath $dbPath -PruneMode "sst_manifest" -FullScanMode $FullScanMode `
      -TMin $TMin -TMax $TMax -XMin $XMin -XMax $XMax -YMin $YMin -YMax $YMax -NoFull:$NoFullScan

    $err = @($om.error, $os.error, $ob.error) -join ";"
    if ($err -eq ";;") { $err = "" }

    $synP = Synergy-Val $om.pw $os.pw $ob.pw
    $synR = Synergy-Ratio $om.rw $os.rw $ob.rw

    $winner = ""
    try {
      $pm = [double]$om.pw; $ps = [double]$os.pw; $pb = [double]$ob.pw
      if ($pm -gt 0 -and $ps -gt 0 -and $pb -gt 0) {
        $mn = [math]::Min($pm, $ps)
        if ($pb -lt $mn - 0.0001) { $winner = "both" }
        elseif ([math]::Abs($pb - $mn) -lt 0.0001) { $winner = "tie_best_single" }
        elseif ($pm -le $ps) { $winner = "manifest" }
        else { $winner = "sst" }
      }
    } catch {}

    $out += [PSCustomObject]@{
      db            = $dbPath
      label         = $lab
      full_wall_us  = $ob.fw
      prune_wall_manifest = $om.pw
      prune_wall_sst      = $os.pw
      prune_wall_both     = $ob.pw
      ratio_wall_manifest = $om.rw
      ratio_wall_sst      = $os.rw
      ratio_wall_both     = $ob.rw
      synergy_prune       = $synP
      synergy_ratio       = $synR
      winner_prune        = $winner
      error               = $err
    }
  }
}

$header = "db`tlabel`tfull_wall_us`tprune_wall_manifest`tprune_wall_sst`tprune_wall_both`tratio_wall_manifest`tratio_wall_sst`tratio_wall_both`tsynergy_prune`tsynergy_ratio`twinner_prune`terror"
$lines = @($header)
foreach ($o in $out) {
  $lines += "$($o.db)`t$($o.label)`t$($o.full_wall_us)`t$($o.prune_wall_manifest)`t$($o.prune_wall_sst)`t$($o.prune_wall_both)`t$($o.ratio_wall_manifest)`t$($o.ratio_wall_sst)`t$($o.ratio_wall_both)`t$($o.synergy_prune)`t$($o.synergy_ratio)`t$($o.winner_prune)`t$($o.error)"
}
$text = $lines -join "`n"
Write-Host ""
Write-Host $text
if ($OutTsv -ne "") {
  $text | Set-Content -LiteralPath $OutTsv -Encoding utf8
  Write-Host "Wrote $OutTsv"
}

Write-Host ""
Write-Host "Interpret: synergy_prune = min(manifest,sst)/both  (>1 => combined faster than BOTH singles)." -ForegroundColor DarkGray
Write-Host "           synergy_ratio uses wall_time_ratio(prune/full); >1 => combined ratio better than best single." -ForegroundColor DarkGray

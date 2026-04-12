# Count per-window file-level skip potential from st_meta_sst_diag.
#
# Output columns:
#   label, total_sst, disjoint_files, intersects_files, disjoint_ratio
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\wuxi_manifest_file_skip_stats.ps1 `
#     -DbPath D:\Project\data\verify_wuxi_segment_manysst `
#     -WindowsCsv D:\Project\tools\st_validity_experiment_windows_wuxi.csv `
#     -OutTsv D:\Project\data\experiments\wuxi_segment_manysst\manifest_file_skip_stats.tsv

param(
  [string]$DbPath = "",
  [string]$WindowsCsv = "",
  [string]$DiagExe = "",
  [string]$OutTsv = ""
)

$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
if ([string]::IsNullOrWhiteSpace($DbPath)) {
  $DbPath = Join-Path $ToolsDir "..\data\verify_wuxi_segment_manysst"
}
if ([string]::IsNullOrWhiteSpace($WindowsCsv)) {
  $WindowsCsv = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi.csv"
}
if ([string]::IsNullOrWhiteSpace($DiagExe)) {
  $DiagExe = Join-Path $ToolsDir "..\rocksdb\build\tools\st_meta_sst_diag.exe"
}
if ([string]::IsNullOrWhiteSpace($OutTsv)) {
  $OutTsv = Join-Path $ToolsDir "..\data\experiments\wuxi_segment_manysst\manifest_file_skip_stats.tsv"
}

$ErrorActionPreference = "Stop"
if (-not (Test-Path -LiteralPath $DiagExe)) {
  Write-Error "Missing diag executable: $DiagExe"
}
if (-not (Test-Path -LiteralPath $DbPath)) {
  Write-Error "Missing DB path: $DbPath"
}
if (-not (Test-Path -LiteralPath $WindowsCsv)) {
  Write-Error "Missing windows CSV: $WindowsCsv"
}

$sst = Get-ChildItem -LiteralPath $DbPath -Filter *.sst -Recurse -File | Select-Object -ExpandProperty FullName
if ($null -eq $sst -or $sst.Count -eq 0) {
  Write-Error "No .sst files under $DbPath"
}

$rows = Import-Csv -LiteralPath $WindowsCsv
$out = @()
foreach ($r in $rows) {
  Write-Host "=== $($r.Label) ===" -ForegroundColor Cyan
  $args = @(
    "--window", "$($r.TMin)", "$($r.TMax)", "$($r.XMin)", "$($r.YMin)", "$($r.XMax)", "$($r.YMax)"
  ) + $sst
  $raw = & $DiagExe @args 2>&1 | Out-String
  $d = ([regex]::Matches($raw, 'file vs query window:\s+DISJOINT')).Count
  $i = ([regex]::Matches($raw, 'file vs query window:\s+INTERSECTS')).Count
  $total = $sst.Count
  $ratio = 0.0
  if ($total -gt 0) {
    $ratio = [math]::Round($d / $total, 6)
  }
  $out += [PSCustomObject]@{
    label = $r.Label
    total_sst = $total
    disjoint_files = $d
    intersects_files = $i
    disjoint_ratio = $ratio
  }
}

$header = "label`ttotal_sst`tdisjoint_files`tintersects_files`tdisjoint_ratio"
$lines = @($header)
foreach ($x in $out) {
  $lines += "$($x.label)`t$($x.total_sst)`t$($x.disjoint_files)`t$($x.intersects_files)`t$($x.disjoint_ratio)"
}
$text = $lines -join "`n"
$outDir = Split-Path -Parent $OutTsv
if (-not [string]::IsNullOrWhiteSpace($outDir)) {
  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}
$text | Set-Content -LiteralPath $OutTsv -Encoding utf8
Write-Host "`nWrote $OutTsv"
Write-Host $text


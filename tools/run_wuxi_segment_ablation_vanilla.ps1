# Wuxi 1/164/776 × three prune modes with **official RocksDB** wall baseline per window.
# Requires: rocks-demo\build\st_segment_window_scan_vanilla.exe (links rocksdb_vanilla\build\rocksdb.lib).
#
# One-shot:
#   1) Place upstream RocksDB in ..\rocksdb_vanilla (see rocksdb_vanilla\README_UPSTREAM.txt)
#   2) tools\bootstrap_rocksdb_vanilla.ps1
#   3) Reconfigure rocks-demo so CMake sees VANILLA_ROCKSDB_LIB, then build st_segment_window_scan_vanilla
#   4) powershell ... -File tools\run_wuxi_segment_ablation_vanilla.ps1 -OutDir data\experiments\...
#
param(
  [string]$OutDir = "",
  [switch]$VerifyKVResults,
  [switch]$SummarizePooled
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
$Vanilla = Join-Path $ToolsDir "..\rocks-demo\build\st_segment_window_scan_vanilla.exe"
if (-not (Test-Path -LiteralPath $Vanilla)) {
  throw @"
Missing vanilla baseline executable:
  $Vanilla

Build upstream RocksDB under rocksdb_vanilla, then rebuild rocks-demo:
  powershell -NoProfile -ExecutionPolicy Bypass -File $(Join-Path $ToolsDir 'bootstrap_rocksdb_vanilla.ps1')
  cd rocks-demo\build && cmake .. -DCMAKE_BUILD_TYPE=Release && cmake --build . --config Release --target st_segment_window_scan_vanilla

If GitHub is unreachable: unblock the exe only (fork-linked smoke, NOT official V):
  cd rocks-demo\build && cmake .. -DCMAKE_BUILD_TYPE=Release -DVANILLA_STANDIN_LINK_FORK_LIB=ON && cmake --build . --config Release --target st_segment_window_scan_vanilla
See docs/VANILLA_ROCKSDB_BASELINE.md
"@
}

$Main = Join-Path $ToolsDir "run_wuxi_segment_ablation_1_164_776.ps1"
$args = @(
  "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Main,
  "-VanillaSegmentBench", $Vanilla
)
if (-not [string]::IsNullOrWhiteSpace($OutDir)) {
  $args += "-OutDir"; $args += $OutDir
}
if ($VerifyKVResults.IsPresent) { $args += "-VerifyKVResults" }
if ($SummarizePooled.IsPresent) { $args += "-SummarizePooled" }
& powershell @args

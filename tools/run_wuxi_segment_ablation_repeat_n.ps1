# Repeat Wuxi 1/164/776 (736 fallback) three-mode ablation N times into BaseOutDir\run_01 .. run_NN.
# 主脚本默认开启 KV 验证；可选 -NoVerifyKVResults（= 传 -SkipVerifyKVResults）加速迭代。
#
# Example:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\run_wuxi_segment_ablation_repeat_n.ps1 -N 10 -BaseOutDir D:\Project\data\experiments\wuxi_ablation_10r_verifykv
#
# Then aggregate (mean speedup & QPS):
#   python D:\Project\tools\aggregate_wuxi_ablation_runs.py --parent D:\Project\data\experiments\wuxi_ablation_10r_verifykv --json D:\Project\data\experiments\wuxi_ablation_10r_verifykv\aggregate.json

param(
  [int]$N = 10,
  [string]$BaseOutDir = "",
  [switch]$NoVerifyKVResults,
  [switch]$SummarizePooled
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
$Main = Join-Path $ToolsDir "run_wuxi_segment_ablation_1_164_776.ps1"
if (-not (Test-Path -LiteralPath $Main)) {
  throw "Missing: $Main"
}
if ([string]::IsNullOrWhiteSpace($BaseOutDir)) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $BaseOutDir = Join-Path $ToolsDir "..\data\experiments\wuxi_ablation_${N}r_verifykv_$stamp"
}
New-Item -ItemType Directory -Force -Path $BaseOutDir | Out-Null

for ($i = 1; $i -le $N; $i++) {
  $sub = "{0:D2}" -f $i
  $OutDir = Join-Path $BaseOutDir "run_$sub"
  Write-Host "========== repeat $i / $N -> $OutDir ==========" -ForegroundColor Cyan
  $args = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Main,
    "-OutDir", $OutDir
  )
  if ($NoVerifyKVResults.IsPresent) {
    $args += "-SkipVerifyKVResults"
  }
  if ($SummarizePooled.IsPresent) {
    $args += "-SummarizePooled"
  }
  & powershell @args
}

Write-Host "Done. Runs under: $BaseOutDir" -ForegroundColor Green

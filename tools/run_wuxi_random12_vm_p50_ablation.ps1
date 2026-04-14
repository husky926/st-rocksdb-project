# 无锡 12 窗（优先 stratified12_n4m4w4.csv；否则 random12_cov）× 默认 1/164/776 SST（缺 776 目录时与主脚本相同回退 736）
# 配置：VM + VirtualMergeAuto + 736 buckets + 自适应 key/block gate（与 run_wuxi_segment_ablation_1_164_776 默认一致）
# 结束后汇总：--pooled + --pooled-by-db（全窗 p50 + 按库 p50）
#
# 需要：rocks-demo\build\st_meta_read_bench.exe（或 sweep 里 -Bench 指向的可执行文件）
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File D:\Project\tools\run_wuxi_random12_vm_p50_ablation.ps1
#   powershell ... -SkipVerifyKVResults   # 仅当要跳过 fork full↔prune KV 对拍时

param(
  [string]$OutDir = "",
  [switch]$SkipVerifyKVResults
)

$ErrorActionPreference = "Stop"
$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
$Main = Join-Path $ToolsDir "run_wuxi_segment_ablation_1_164_776.ps1"
$Stratified12 = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi_stratified12_n4m4w4.csv"
$Random12Cov = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi_random12_cov_s42.csv"
$Random12 = Join-Path $ToolsDir "st_validity_experiment_windows_wuxi_random12_s42.csv"
if (-not (Test-Path -LiteralPath $Main)) {
  throw "Missing: $Main"
}
$Win = $Stratified12
if (-not (Test-Path -LiteralPath $Win)) {
  $Win = $Random12Cov
}
if (-not (Test-Path -LiteralPath $Win)) {
  $Win = $Random12
}
if (-not (Test-Path -LiteralPath $Win)) {
  throw "Missing window CSV: run generate_wuxi_random_windows_validated.py or generate_random_query_windows_wuxi.py"
}

$args = @(
  "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Main,
  "-WindowsCsv", $Win,
  "-SummarizePooled"
)
if (-not [string]::IsNullOrWhiteSpace($OutDir)) {
  $args += "-OutDir"; $args += $OutDir
}
if ($SkipVerifyKVResults.IsPresent) {
  $args += "-SkipVerifyKVResults"
}
& powershell @args

# Deprecated filename — forwards to run_wuxi_segment_ablation_1_164_776.ps1 (default DB list uses 776sst; 736 fallback + meta unchanged).
$impl = Join-Path $PSScriptRoot "run_wuxi_segment_ablation_1_164_776.ps1"
if (-not (Test-Path -LiteralPath $impl)) {
  throw "Missing: $impl"
}
& $impl @args

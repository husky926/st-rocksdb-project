# Deprecated filename — forwards to run_wuxi_segment_ablation_1_164_776.ps1 (third tier = hourly bucket3600_sst; legacy 776/736 resolved by wuxi_resolve_third_tier_fork.ps1).
$impl = Join-Path $PSScriptRoot "run_wuxi_segment_ablation_1_164_776.ps1"
if (-not (Test-Path -LiteralPath $impl)) {
  throw "Missing: $impl"
}
& $impl @args

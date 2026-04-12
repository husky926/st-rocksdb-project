# Sweep prune time window (--prune-t-max) and append rows to one CSV for a selectivity curve.
# Requires st_meta_scan_bench (argv-v4) on PATH or pass -BenchExe.

param(
    [string]$BenchExe = "st_meta_scan_bench",
    [string]$Db = "D:/Project/data/bench_st_meta_prune_scan",
    [string]$Log = "D:/Project/data/bench_st_meta/eval_part_b_scan_sweep.csv",
    [int]$NumKeys = 80000,
    [int[]]$TMaxList = @(49, 99, 199, 399, 999)
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Log) | Out-Null
New-Item -ItemType Directory -Force -Path $Db | Out-Null

foreach ($tm in $TMaxList) {
    Write-Host "Run prune_t_max=$tm -> $Log"
    & $BenchExe --db $Db --num $NumKeys --log $Log --prune-t-min 0 --prune-t-max $tm
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host "Done. Plot key_selectivity vs on_time_us from $Log"

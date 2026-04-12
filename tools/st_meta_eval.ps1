# Two-part evaluation (see docs/sst_and_manifest_plan.md):
#   A - Index-tail overhead: st_meta_bench (no prune; plain keys; OFF vs ON same binary).
#   B - Block-summary benefit: st_meta_scan_bench (0xE5 keys + experimental_st_prune_scan).
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File D:\Project\tools\st_meta_eval.ps1
#   powershell ... -File ... -SkipA
#   powershell ... -File ... -SkipB

param(
    [switch]$SkipA,
    [switch]$SkipB
)

$ErrorActionPreference = "Stop"
$Root = "D:\Project"
$Build = Join-Path $Root "rocks-demo\build"
$MetaBench = Join-Path $Build "st_meta_bench.exe"
$ScanBench = Join-Path $Build "st_meta_scan_bench.exe"
$LogDir = Join-Path $Root "data\bench_st_meta"
$ScanLog = Join-Path $LogDir "eval_part_b_scan.csv"

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

function Require-Exe($path) {
    if (-not (Test-Path $path)) {
        Write-Host "Missing: $path"
        Write-Host "Build: cmake --build `"$Build`" --target st_meta_bench st_meta_scan_bench"
        exit 1
    }
}

if (-not $SkipA) {
    Require-Exe $MetaBench
    Write-Host ""
    Write-Host "========== A. Index tail overhead (no ReadOptions prune) =========="
    Write-Host "Tool: st_meta_bench - compares Put+Flush and random Get, OFF vs ON tail."
    Write-Host "Keys are plain decimal strings (no 0xE5); measures format + codec cost."
    Write-Host ""
    Push-Location $Build
    try {
        & $MetaBench
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } finally {
        Pop-Location
    }
}

if (-not $SkipB) {
    Require-Exe $ScanBench
    Write-Host ""
    Write-Host "========== B. Block-level ST summary benefit (selective forward scan) =========="
    Write-Host "Tool: st_meta_scan_bench - ST user keys, prune window vs full scan."
    Write-Host "Log: $ScanLog"
    Write-Host ""
    & $ScanBench --log $ScanLog
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host ""
Write-Host "Done. Interpretation:"
Write-Host "  A: ratio ON/OFF ~1 or small >1 = acceptable overhead for the index tail."
Write-Host "  B: fewer keys enumerated / lower scan time = benefit when query window is selective."

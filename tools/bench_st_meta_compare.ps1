# Compare st-meta index OFF vs ON using rocks-demo st_meta_bench (no gflags / no db_bench).
# Build first: cmake --build D:\Project\rocks-demo\build --target st_meta_bench

$ErrorActionPreference = "Stop"
$Root = "D:\Project"
$BenchExe = Join-Path $Root "rocks-demo\build\st_meta_bench.exe"
$OffDb = Join-Path $Root "data\bench_st_meta\db_off"
$OnDb = Join-Path $Root "data\bench_st_meta\db_on"

$Num = 300000
$Reads = 300000

if (-not (Test-Path $BenchExe)) {
    Write-Host "Missing $BenchExe"
    Write-Host "Build: cd /d $Root\rocks-demo\build && cmake --build . --target st_meta_bench"
    exit 1
}

# RocksDB creates the leaf db folder but not missing parents (e.g. bench_st_meta).
$BenchParent = Split-Path -Parent $OffDb
New-Item -ItemType Directory -Force -Path $BenchParent | Out-Null

& $BenchExe --num $Num --reads $Reads --db-off $OffDb --db-on $OnDb
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "Interpret: micros/op lower is better. Ratio ON/OFF > 1 means the SST index extension cost time."

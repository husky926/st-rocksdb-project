param(
  [int]$Rounds = 5,
  [string]$WindowsCsv = "D:\Project\tools\st_validity_experiment_windows_wuxi.csv",
  [string]$RocksDbPathsCsv = "D:\Project\data\verify_wuxi_segment_1sst,D:\Project\data\verify_wuxi_segment_164sst,D:\Project\data\verify_wuxi_segment_bucket3600_sst",
  [string]$OutDir = "",
  [uint32]$VmTimeSpanSecThreshold = 21600,
  [uint32]$TimeBucketCount = 736,
  [uint32]$RTreeLeafSize = 8,
  [switch]$VerifyKVResults
)

$ErrorActionPreference = "Stop"

$ToolsDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ToolsDir)) {
  $ToolsDir = Split-Path -LiteralPath $MyInvocation.MyCommand.Path -Parent
}
$Sweep = Join-Path $ToolsDir "st_prune_vs_full_baseline_sweep.ps1"
if (-not (Test-Path -LiteralPath $Sweep)) {
  throw "Missing sweep script: $Sweep"
}
if (-not (Test-Path -LiteralPath $WindowsCsv)) {
  throw "Missing windows CSV: $WindowsCsv"
}

. (Join-Path $ToolsDir "wuxi_resolve_third_tier_fork.ps1")
$dataRoot = [System.IO.Path]::GetFullPath((Join-Path $ToolsDir "..\data"))
$r3 = Get-WuxiResolvedThirdTierCsv -RocksDbPathsCsv $RocksDbPathsCsv -DataRoot $dataRoot
$RocksDbPathsCsv = $r3.RocksDbPathsCsv

if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
  $OutDir = "D:\Project\data\experiments\vm_compare_$stamp"
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

if ($Rounds -lt 1) {
  throw "Rounds must be >= 1"
}

$modes = @("manifest", "sst", "sst_manifest")
$variants = @(
  @{ Name = "vm_only"; Args = @("-VirtualMerge") },
  @{ Name = "vm_auto"; Args = @("-VirtualMerge", "-VirtualMergeAuto", "-VmTimeSpanSecThreshold", "$VmTimeSpanSecThreshold") }
)

foreach ($variant in $variants) {
  $variantDir = Join-Path $OutDir $variant.Name
  New-Item -ItemType Directory -Force -Path $variantDir | Out-Null

  1..$Rounds | ForEach-Object {
    $runId = $_
    $runDir = Join-Path $variantDir "run_$runId"
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null

    foreach ($mode in $modes) {
      Write-Host "[$($variant.Name)] run=$runId mode=$mode" -ForegroundColor Cyan
      $args = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $Sweep,
        "-RocksDbPathsCsv", $RocksDbPathsCsv,
        "-WindowsCsv", $WindowsCsv,
        "-PruneMode", $mode,
        "-TimeBucketCount", "$TimeBucketCount",
        "-RTreeLeafSize", "$RTreeLeafSize",
        "-FullScanMode", "window",
        "-OutTsv", (Join-Path $runDir "ablation_$mode.tsv")
      )
      $args += $variant.Args
      if ($VerifyKVResults.IsPresent) {
        $args += "-VerifyKVResults"
      }
      & powershell @args
    }
  }
}

$pyPath = Join-Path $OutDir "analyze_vm_compare.py"
$py = @'
import csv
import statistics
from pathlib import Path

OUT_ROOT = Path(r"__OUT_ROOT__")
MODES = ["manifest", "sst", "sst_manifest"]
VARIANTS = ["vm_only", "vm_auto"]

try:
    import matplotlib.pyplot as plt
    import numpy as np
except Exception as e:
    raise SystemExit(
        "Missing python deps for plotting. Install with: python -m pip install matplotlib numpy\n"
        f"Import error: {e}"
    )


def read_tsv(path: Path):
    with path.open("r", encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def agg_speed(rows):
    full = sum(float(r["full_wall_us"]) for r in rows if r["full_wall_us"])
    prune = sum(float(r["prune_wall_us"]) for r in rows if r["prune_wall_us"])
    return (full / prune) if prune > 0 else 0.0


def agg_prune_qps(rows):
    prune = sum(float(r["prune_wall_us"]) for r in rows if r["prune_wall_us"])
    return (len(rows) / (prune / 1e6)) if prune > 0 else 0.0


all_stats = []
for variant in VARIANTS:
    for run_dir in sorted((OUT_ROOT / variant).glob("run_*")):
        for mode in MODES:
            tsv = run_dir / f"ablation_{mode}.tsv"
            rows = read_tsv(tsv)
            dbs = sorted(set(r["db"] for r in rows))
            for db in dbs:
                sub = [r for r in rows if r["db"] == db]
                all_stats.append(
                    {
                        "variant": variant,
                        "mode": mode,
                        "db": db,
                        "speed": agg_speed(sub),
                        "prune_qps": agg_prune_qps(sub),
                    }
                )

summary = []
keys = sorted(set((x["mode"], x["db"]) for x in all_stats))
for mode, db in keys:
    row = {"mode": mode, "db": db}
    for v in VARIANTS:
        vals_speed = [
            x["speed"]
            for x in all_stats
            if x["variant"] == v and x["mode"] == mode and x["db"] == db
        ]
        vals_qps = [
            x["prune_qps"]
            for x in all_stats
            if x["variant"] == v and x["mode"] == mode and x["db"] == db
        ]
        row[f"{v}_speed_med"] = statistics.median(vals_speed) if vals_speed else 0.0
        row[f"{v}_qps_med"] = statistics.median(vals_qps) if vals_qps else 0.0
    summary.append(row)

print(
    "mode\tdb\tvm_only_speed_med\tvm_auto_speed_med\tdelta_speed%\t"
    "vm_only_prune_qps_med\tvm_auto_prune_qps_med\tdelta_qps%"
)
for r in summary:
    s0 = r["vm_only_speed_med"]
    s1 = r["vm_auto_speed_med"]
    q0 = r["vm_only_qps_med"]
    q1 = r["vm_auto_qps_med"]
    ds = ((s1 - s0) / s0 * 100.0) if s0 > 0 else 0.0
    dq = ((q1 - q0) / q0 * 100.0) if q0 > 0 else 0.0
    print(
        f"{r['mode']}\t{r['db']}\t{s0:.4f}\t{s1:.4f}\t{ds:+.2f}%\t"
        f"{q0:.3f}\t{q1:.3f}\t{dq:+.2f}%"
    )

csv_out = OUT_ROOT / "median_compare.csv"
with csv_out.open("w", encoding="utf-8", newline="") as f:
    w = csv.writer(f)
    w.writerow(
        [
            "mode",
            "db",
            "vm_only_speed_med",
            "vm_auto_speed_med",
            "delta_speed_pct",
            "vm_only_prune_qps_med",
            "vm_auto_prune_qps_med",
            "delta_qps_pct",
        ]
    )
    for r in summary:
        s0 = r["vm_only_speed_med"]
        s1 = r["vm_auto_speed_med"]
        q0 = r["vm_only_qps_med"]
        q1 = r["vm_auto_qps_med"]
        ds = ((s1 - s0) / s0 * 100.0) if s0 > 0 else 0.0
        dq = ((q1 - q0) / q0 * 100.0) if q0 > 0 else 0.0
        w.writerow(
            [
                r["mode"],
                r["db"],
                f"{s0:.6f}",
                f"{s1:.6f}",
                f"{ds:.4f}",
                f"{q0:.6f}",
                f"{q1:.6f}",
                f"{dq:.4f}",
            ]
        )

for mode in MODES:
    rows = [r for r in summary if r["mode"] == mode]
    rows.sort(key=lambda x: x["db"])
    labels = [Path(r["db"]).name for r in rows]
    y0 = [r["vm_only_speed_med"] for r in rows]
    y1 = [r["vm_auto_speed_med"] for r in rows]

    x = np.arange(len(labels))
    width = 0.35
    plt.figure(figsize=(8, 4))
    plt.bar(x - width / 2, y0, width=width, label="vm_only")
    plt.bar(x + width / 2, y1, width=width, label="vm+auto")
    plt.xticks(x, labels)
    plt.ylabel("Median speedup (sum full / sum prune)")
    plt.title(f"Median speedup by DB - {mode}")
    plt.legend()
    plt.tight_layout()
    plt.savefig(OUT_ROOT / f"plot_{mode}_median_speedup.png", dpi=160)
    plt.close()

print(f"\nWrote: {csv_out}")
print(f"Plots: {OUT_ROOT}\\plot_*_median_speedup.png")
'@

$py = $py.Replace("__OUT_ROOT__", $OutDir.Replace("\", "\\"))
$py | Set-Content -LiteralPath $pyPath -Encoding UTF8

Write-Host "Analyzing medians and plotting..." -ForegroundColor Yellow
& python $pyPath

Write-Host ""
Write-Host "Done. Output dir: $OutDir" -ForegroundColor Green
Write-Host "Median table: $OutDir\median_compare.csv"
Write-Host "Plots: $OutDir\plot_manifest_median_speedup.png, plot_sst_median_speedup.png, plot_sst_manifest_median_speedup.png"

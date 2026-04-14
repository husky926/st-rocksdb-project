#!/usr/bin/env python3
"""
Pathology report for Global (file-level) pruning: SST file ST bounds from
`rocksdb.experimental.st_file_bounds` via `st_meta_sst_diag.exe`.

Computes:
  - Per-SST file MBR (t, x, y) from tool output
  - Optional: per query window — intersect vs disjoint counts, sum of (x,y) intersection
    area with the window, time-overlap × xy-area proxy
  - Optional: sum over all unordered SST pairs of (x,y) intersection area (spatial overlap mass)

**Units:** ``sum_file_xy_area`` / per-window sums are **Δx·Δy** in stored coordinates. For Wuxi
segment DBs this is typically **lon/lat in degrees** → numeric values are **deg²** (a rectangular
product, not geodesic km²). Do **not** interpret as square kilometres without a projection.

**Single SST:** If ``sst_glob_count`` is 1, the directory is **not** a multi-hundred-SST bucket
layout; file-level MBR envelopes **all** keys in that file (often huge). See output
``layout_warning``.

This does NOT open RocksDB from Python; it shells to `st_meta_sst_diag` (Windows: build
`rocksdb` target `st_meta_sst_diag`).

Usage:
  python tools/wuxi_sst_file_mbr_pathology_report.py --db D:/Project/data/verify_wuxi_segment_736sst
  python tools/wuxi_sst_file_mbr_pathology_report.py --db ... \\
    --windows-csv tools/st_validity_experiment_windows_wuxi_stratified12_n4m4w4.csv \\
    --out-json report.json
  python tools/wuxi_sst_file_mbr_pathology_report.py --db ... --pairwise-spatial

See EXPERIMENTS_AND_SCRIPTS.md §2.4 / §3.4.
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class FileMBR:
    path: str
    name: str
    t_min: int
    t_max: int
    x_min: float
    x_max: float
    y_min: float
    y_max: float

    @property
    def area_xy(self) -> float:
        return max(0.0, self.x_max - self.x_min) * max(0.0, self.y_max - self.y_min)


def _default_diag_exe(project_root: Path) -> Path:
    return (
        project_root
        / "rocksdb"
        / "build"
        / "tools"
        / ("st_meta_sst_diag.exe" if sys.platform == "win32" else "st_meta_sst_diag")
    )


def _parse_diag_output(text: str) -> tuple[list[FileMBR], int]:
    """Parse concatenated st_meta_sst_diag stdout. Returns (mbrs, absent_count)."""
    mbrs: list[FileMBR] = []
    absent = 0
    current_path = ""
    # === path ===
    hdr = re.compile(r"^=== (.+) ===\s*$")
    # file ST bounds: t[1,2] x[3,4] y[5,6] bitmap=...
    bounds_re = re.compile(
        r"file ST bounds: t\[(\d+),\s*(\d+)\]\s+"
        r"x\[([-+eE\d.]+),([-+eE\d.]+)\]\s+y\[([-+eE\d.]+),([-+eE\d.]+)\]"
    )
    for line in text.splitlines():
        m = hdr.match(line.strip())
        if m:
            current_path = m.group(1).strip()
            continue
        if "file ST bounds property: (absent)" in line or "file ST bounds property: decode error" in line:
            absent += 1
            continue
        bm = bounds_re.search(line)
        if bm and current_path:
            p = Path(current_path)
            mbrs.append(
                FileMBR(
                    path=current_path,
                    name=p.name,
                    t_min=int(bm.group(1)),
                    t_max=int(bm.group(2)),
                    x_min=float(bm.group(3)),
                    x_max=float(bm.group(4)),
                    y_min=float(bm.group(5)),
                    y_max=float(bm.group(6)),
                )
            )
    return mbrs, absent


def _st_disjoint(f: FileMBR, t0: int, t1: int, x0: float, y0: float, x1: float, y1: float) -> bool:
    return (
        f.t_max < t0
        or f.t_min > t1
        or f.x_max < x0
        or f.x_min > x1
        or f.y_max < y0
        or f.y_min > y1
    )


def _xy_inter_area(
    ax0: float, ay0: float, ax1: float, ay1: float,
    bx0: float, by0: float, bx1: float, by1: float,
) -> float:
    ix0 = max(ax0, bx0)
    iy0 = max(ay0, by0)
    ix1 = min(ax1, bx1)
    iy1 = min(ay1, by1)
    return max(0.0, ix1 - ix0) * max(0.0, iy1 - iy0)


def _time_overlap_len(ft0: int, ft1: int, qt0: int, qt1: int) -> int:
    return max(0, min(ft1, qt1) - max(ft0, qt0))


def run_diag_on_ssts(
    diag_exe: Path,
    sst_paths: list[Path],
    batch_size: int,
    window: tuple[int, int, float, float, float, float] | None,
) -> str:
    chunks: list[str] = []
    for i in range(0, len(sst_paths), batch_size):
        batch = sst_paths[i : i + batch_size]
        cmd: list[str] = [str(diag_exe)]
        if window is not None:
            t0, t1, x0, y0, x1, y1 = window
            cmd += [
                "--window",
                str(t0),
                str(t1),
                str(x0),
                str(y0),
                str(x1),
                str(y1),
            ]
        cmd += [str(p) for p in batch]
        r = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if r.returncode != 0:
            sys.stderr.write(r.stderr or "")
            raise SystemExit(
                f"st_meta_sst_diag failed (code {r.returncode}) on batch starting {batch[0]}"
            )
        chunks.append(r.stdout)
    return "\n".join(chunks)


def load_windows_csv(path: Path) -> list[dict]:
    rows = []
    with path.open(encoding="utf-8-sig", newline="") as f:
        for r in csv.DictReader(f):
            rows.append(
                {
                    "label": r["Label"].strip(),
                    "t_min": int(r["TMin"]),
                    "t_max": int(r["TMax"]),
                    "x_min": float(r["XMin"]),
                    "x_max": float(r["XMax"]),
                    "y_min": float(r["YMin"]),
                    "y_max": float(r["YMax"]),
                }
            )
    return rows


def pairwise_xy_intersection_sum(mbrs: list[FileMBR]) -> float:
    n = len(mbrs)
    s = 0.0
    for i in range(n):
        a = mbrs[i]
        for j in range(i + 1, n):
            b = mbrs[j]
            s += _xy_inter_area(
                a.x_min, a.y_min, a.x_max, a.y_max,
                b.x_min, b.y_min, b.x_max, b.y_max,
            )
    return s


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", type=Path, required=True, help="RocksDB directory (live *.sst)")
    ap.add_argument(
        "--diag-exe",
        type=Path,
        default=None,
        help="st_meta_sst_diag executable (default: <repo>/rocksdb/build/tools/...)",
    )
    ap.add_argument("--batch-size", type=int, default=40, help="SST paths per diag invocation")
    ap.add_argument(
        "--windows-csv",
        type=Path,
        default=None,
        help="Optional: stratified / experiment windows CSV (Label,TMin,TMax,XMin,XMax,YMin,YMax)",
    )
    ap.add_argument(
        "--pairwise-spatial",
        action="store_true",
        help="O(n^2): sum of (x,y) intersection areas over all SST pairs (heavy diagnostic)",
    )
    ap.add_argument("--out-json", type=Path, default=None, help="Write full report JSON")
    args = ap.parse_args()

    db: Path = args.db.resolve()
    if not db.is_dir():
        raise SystemExit(f"Not a directory: {db}")

    root = Path(__file__).resolve().parents[1]
    diag = args.diag_exe or _default_diag_exe(root)
    if not diag.is_file():
        raise SystemExit(
            f"Missing {diag} — build: cmake --build rocksdb/build --target st_meta_sst_diag"
        )

    ssts = sorted(db.glob("*.sst"))
    if not ssts:
        raise SystemExit(f"No *.sst under {db}")

    text = run_diag_on_ssts(diag, ssts, args.batch_size, window=None)
    mbrs, absent_decl = _parse_diag_output(text)
    parsed_names = {m.name for m in mbrs}
    missing_meta_files = [p.name for p in ssts if p.name not in parsed_names]

    summary: dict = {
        "db": str(db),
        "sst_glob_count": len(ssts),
        "file_mbr_parsed_count": len(mbrs),
        "file_bounds_absent_or_decode_errors": absent_decl,
        "sst_files_without_parsed_bounds": missing_meta_files,
        "xy_extent_product_units": (
            "Δx·Δy in DB coordinates; Wuxi segment keys use lon≈x, lat≈y (degrees) → "
            "figures are deg² (not km²; not geodesic area)."
        ),
        "sum_file_xy_area": round(sum(m.area_xy for m in mbrs), 6),
        "mean_file_xy_area": round(
            sum(m.area_xy for m in mbrs) / len(mbrs), 6
        )
        if mbrs
        else 0.0,
    }

    if len(ssts) <= 1:
        summary["layout_warning"] = (
            "Only one *.sst in this directory — not a multi-SST bucket layout regardless of "
            "folder name (e.g. *_736sst). File-level MBR wraps the entire file; Global cannot "
            "skip between files. Rebuild with st_bucket_ingest_build --bucket-sec 3600 per "
            "docs/BUILD_AND_EXPERIMENTS.md §4.2, or restore from backup before heavy compact."
        )

    if args.pairwise_spatial and mbrs:
        summary["pairwise_xy_intersection_area_sum"] = round(
            pairwise_xy_intersection_sum(mbrs), 6
        )
        summary["pairwise_note"] = (
            "Sum over i<j of Area(MBR_i_xy ∩ MBR_j_xy); ignores time; "
            "large value ⇒ heavy spatial overlap of file-level envelopes."
        )

    windows_report: list[dict] = []
    if args.windows_csv:
        for w in load_windows_csv(args.windows_csv):
            t0, t1 = w["t_min"], w["t_max"]
            x0, x1 = w["x_min"], w["x_max"]
            y0, y1 = w["y_min"], w["y_max"]
            inter = 0
            disj = 0
            sum_xy_win = 0.0
            vol_proxy = 0.0
            for f in mbrs:
                if _st_disjoint(f, t0, t1, x0, y0, x1, y1):
                    disj += 1
                else:
                    inter += 1
                    axy = _xy_inter_area(
                        f.x_min, f.y_min, f.x_max, f.y_max, x0, y0, x1, y1
                    )
                    sum_xy_win += axy
                    dt = _time_overlap_len(f.t_min, f.t_max, t0, t1)
                    vol_proxy += float(dt) * axy
            windows_report.append(
                {
                    "label": w["label"],
                    "n_intersect_st": inter,
                    "n_disjoint_st": disj,
                    "n_total_mbr": len(mbrs),
                    "frac_intersect": round(inter / len(mbrs), 6) if mbrs else 0.0,
                    "sum_xy_intersection_with_window": round(sum_xy_win, 6),
                    "sum_time_sec_times_xy_inter_area": round(vol_proxy, 3),
                }
            )
        summary["windows_csv"] = str(args.windows_csv.resolve())
        summary["per_window"] = windows_report

    print(json.dumps(summary, indent=2, ensure_ascii=False))
    if args.out_json:
        args.out_json.parent.mkdir(parents=True, exist_ok=True)
        args.out_json.write_text(
            json.dumps(summary, indent=2, ensure_ascii=False), encoding="utf-8"
        )
        print(f"Wrote {args.out_json}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

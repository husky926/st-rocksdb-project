#!/usr/bin/env python3
"""
Generate spatial figure: point distribution + SST file MBRs + query windows,
plus east-west query matrix (longitude bars).

Inputs:
  - data/processed/segments_points.csv
  - tools/st_validity_experiment_windows.csv

SST file-level bounds (verify_traj_st_full L0) from Record.md st_meta_sst_diag:
  000009: t[1201959048,1246779915] x[0,145.014] y[0,68.0948]
  000011: t[1201959086,1372747803] x[-8.77824,119.416] y[0,51.0032]

Usage:
  python tools/plot_st_validity_spatial.py
  python tools/plot_st_validity_spatial.py --out docs/st_validity_spatial.png
"""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

# Optional heavy deps: matplotlib + numpy
try:
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle
except ImportError as e:
    raise SystemExit(
        "Need matplotlib. Install: pip install matplotlib"
    ) from e

try:
    import pandas as pd  # type: ignore
except ImportError:
    pd = None  # type: ignore


def _configure_font() -> None:
    """Windows / CJK: avoid missing-glyph boxes in titles and labels."""
    plt.rcParams["font.sans-serif"] = [
        "Microsoft YaHei",
        "SimHei",
        "Noto Sans CJK SC",
        "Arial Unicode MS",
        "DejaVu Sans",
    ]
    plt.rcParams["axes.unicode_minus"] = False


# SST st_file_bounds (lon≈x, lat≈y) — Record.md / st_meta_sst_diag on verify_traj_st_full
SST_FILES = (
    ("000009.sst", {"x": (0.0, 145.014), "y": (0.0, 68.0948)}),
    ("000011.sst", {"x": (-8.77824, 119.416), "y": (0.0, 51.0032)}),
)

# Queries to show on map + matrix (label -> color)
QUERY_STYLE = {
    "wide_baseline": "#1d4ed8",
    "east_x_file_disjoint": "#dc2626",
    "west_x_both_intersect": "#059669",
    "x_near_119_boundary": "#ca8a04",
    "sharp_spatiotemporal": "#7c3aed",
}


def load_windows(csv_path: Path) -> list[dict]:
    rows = []
    with csv_path.open(encoding="utf-8", newline="") as f:
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
                    "note": r.get("Note", ""),
                }
            )
    return rows


def load_points_sample(
    csv_path: Path,
    stride: int,
    t_min: int | None,
    t_max: int | None,
) -> tuple[list[float], list[float], list[float], list[float]]:
    """Returns (lon_all, lat_all, lon_win, lat_win) for optional time window highlight."""
    if pd is not None:
        df = pd.read_csv(csv_path, usecols=["lon", "lat", "unix_time_s"])
        sub = df.iloc[:: max(stride, 1)].copy()
        lon_a = sub["lon"].astype(float).tolist()
        lat_a = sub["lat"].astype(float).tolist()
        lon_w, lat_w = [], []
        if t_min is not None and t_max is not None:
            m = (df["unix_time_s"] >= t_min) & (df["unix_time_s"] <= t_max)
            win = df.loc[m]
            lon_w = win["lon"].astype(float).tolist()
            lat_w = win["lat"].astype(float).tolist()
        return lon_a, lat_a, lon_w, lat_w

    lon_a, lat_a = [], []
    lon_w, lat_w = [], []
    with csv_path.open(encoding="utf-8", newline="") as f:
        r = csv.DictReader(f)
        i = 0
        for row in r:
            i += 1
            if stride > 1 and i % stride != 0:
                continue
            lo = float(row["lon"])
            la = float(row["lat"])
            lon_a.append(lo)
            lat_a.append(la)
            if t_min is not None and t_max is not None:
                t = int(row["unix_time_s"])
                if t_min <= t <= t_max:
                    lon_w.append(lo)
                    lat_w.append(la)
    return lon_a, lat_a, lon_w, lat_w


def mbr_of_points(lon: list[float], lat: list[float]) -> tuple[float, float, float, float]:
    if not lon:
        return (0.0, 0.0, 0.0, 0.0)
    return (min(lon), max(lon), min(lat), max(lat))


def clip_rect_to_axes(
    xmin: float, xmax: float, ymin: float, ymax: float, ax_x0: float, ax_x1: float, ax_y0: float, ax_y1: float
) -> tuple[float, float, float, float]:
    x0 = max(xmin, ax_x0)
    x1 = min(xmax, ax_x1)
    y0 = max(ymin, ax_y0)
    y1 = min(ymax, ax_y1)
    if x0 >= x1 or y0 >= y1:
        return (ax_x0, ax_x1, ax_y0, ax_y1)
    return (x0, x1, y0, y1)


def main() -> None:
    _configure_font()
    ap = argparse.ArgumentParser()
    ap.add_argument(
        "--points",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "data" / "processed" / "segments_points.csv",
    )
    ap.add_argument(
        "--windows",
        type=Path,
        default=Path(__file__).resolve().parent / "st_validity_experiment_windows.csv",
    )
    ap.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "docs" / "st_validity_spatial.png",
    )
    ap.add_argument("--stride", type=int, default=80, help="Subsample all points: keep every Nth row")
    ap.add_argument(
        "--bench-t-min",
        type=int,
        default=1224600000,
        help="Highlight points in [t_min,t_max] (default = wide_baseline)",
    )
    ap.add_argument("--bench-t-max", type=int, default=1224800000)
    ap.add_argument("--dpi", type=int, default=150)
    args = ap.parse_args()

    windows = load_windows(args.windows)
    lon_bg, lat_bg, lon_hi, lat_hi = load_points_sample(
        args.points, args.stride, args.bench_t_min, args.bench_t_max
    )

    # Plot limits: Beijing band + east/west queries
    x_lim = (112.5, 122.8)
    y_lim = (39.75, 40.22)

    fig = plt.figure(figsize=(12, 10), constrained_layout=False)
    gs = fig.add_gridspec(2, 1, height_ratios=[2.2, 1.0], hspace=0.28)
    ax_map = fig.add_subplot(gs[0, 0])
    ax_mat = fig.add_subplot(gs[1, 0])

    # --- Map: background cloud
    ax_map.scatter(
        lon_bg,
        lat_bg,
        s=1,
        c="#94a3b8",
        alpha=0.35,
        rasterized=True,
        label=f"全部点（每 {args.stride} 取 1，约 {len(lon_bg):,} 点）",
    )
    # Bench time window points (dense)
    if lon_hi:
        ax_map.scatter(
            lon_hi,
            lat_hi,
            s=4,
            c="#0f172a",
            alpha=0.65,
            rasterized=True,
            label=f"时间窗 [{args.bench_t_min},{args.bench_t_max}] 内点（{len(lon_hi):,}）",
        )
        x0, x1, y0, y1 = mbr_of_points(lon_hi, lat_hi)
        rect = Rectangle(
            (x0, y0),
            x1 - x0,
            y1 - y0,
            linewidth=1.2,
            edgecolor="#0f172a",
            facecolor="none",
            linestyle="--",
            label="上述点的 MBR（数据）",
        )
        ax_map.add_patch(rect)

    # SST file-level MBR (clipped to view)
    for name, b in SST_FILES:
        x0, x1, y0, y1 = clip_rect_to_axes(
            b["x"][0], b["x"][1], b["y"][0], b["y"][1], x_lim[0], x_lim[1], y_lim[0], y_lim[1]
        )
        ax_map.add_patch(
            Rectangle(
                (x0, y0),
                x1 - x0,
                y1 - y0,
                linewidth=1.5,
                edgecolor="#64748b",
                facecolor="#cbd5e1",
                alpha=0.12,
                linestyle="-",
            )
        )
        ax_map.text(
            x0 + 0.02,
            y1 - 0.02,
            name + "\n(file st_file_bounds)",
            fontsize=8,
            color="#475569",
            verticalalignment="top",
        )

    # Query rectangles (selected labels)
    show_labels = list(QUERY_STYLE.keys())
    for w in windows:
        lab = w["label"]
        if lab not in QUERY_STYLE:
            continue
        c = QUERY_STYLE[lab]
        rw = w["x_max"] - w["x_min"]
        rh = w["y_max"] - w["y_min"]
        ax_map.add_patch(
            Rectangle(
                (w["x_min"], w["y_min"]),
                rw,
                rh,
                linewidth=1.8,
                edgecolor=c,
                facecolor=c,
                alpha=0.12,
                linestyle="-",
            )
        )
        ax_map.plot(
            [w["x_min"], w["x_max"], w["x_max"], w["x_min"], w["x_min"]],
            [w["y_min"], w["y_min"], w["y_max"], w["y_max"], w["y_min"]],
            color=c,
            lw=1.2,
            alpha=0.9,
        )
        # short label at center
        cx, cy = (w["x_min"] + w["x_max"]) / 2, (w["y_min"] + w["y_max"]) / 2
        short = {
            "wide_baseline": "wide",
            "east_x_file_disjoint": "east",
            "west_x_both_intersect": "west",
            "x_near_119_boundary": "x≈119",
            "sharp_spatiotemporal": "sharp",
        }.get(lab, lab[:8])
        ax_map.text(cx, cy, short, ha="center", va="center", fontsize=8, color=c, fontweight="bold")

    ax_map.set_xlim(x_lim)
    ax_map.set_ylim(y_lim)
    ax_map.set_xlabel("经度 lon (°E)")
    ax_map.set_ylabel("纬度 lat (°N)")
    ax_map.set_title(
        "ST 实验：轨迹点分布 + SST 文件级 MBR（浅灰填充）+ 代表查询窗（彩色框）"
    )
    ax_map.legend(loc="upper left", fontsize=8, framealpha=0.92)
    ax_map.set_aspect("equal", adjustable="box")
    ax_map.grid(True, alpha=0.25)

    # --- East-west query matrix: longitude span bars
    matrix_rows = [
        "wide_baseline",
        "east_x_file_disjoint",
        "west_x_both_intersect",
        "x_near_119_boundary",
        "sharp_spatiotemporal",
    ]
    y_pos = {lab: i for i, lab in enumerate(matrix_rows)}
    for w in windows:
        lab = w["label"]
        if lab not in y_pos:
            continue
        c = QUERY_STYLE.get(lab, "#334155")
        y = y_pos[lab]
        ax_mat.barh(
            y,
            w["x_max"] - w["x_min"],
            left=w["x_min"],
            height=0.62,
            color=c,
            alpha=0.55,
            edgecolor=c,
            linewidth=1,
        )
        ax_mat.text(
            w["x_max"] + 0.05,
            y,
            f"x∈[{w['x_min']:.2f},{w['x_max']:.2f}]",
            va="center",
            fontsize=8,
            color="#334155",
        )

    ax_mat.set_yticks(range(len(matrix_rows)))
    ax_mat.set_yticklabels(
        [
            "wide（基线）",
            "east（东向，文件级可 DISJOINT）",
            "west（西向，块级为主）",
            "x≈119（跨 119° 带）",
            "sharp（尖时空窗）",
        ]
    )
    ax_mat.set_xlabel("经度 lon (°E) — 东西向查询「矩阵」：每行对应一类窗的 x 范围")
    ax_mat.set_xlim(x_lim)
    ax_mat.set_ylim(-0.8, len(matrix_rows) - 0.2)
    ax_mat.axvline(119.4, color="#94a3b8", linestyle="--", lw=0.8, alpha=0.8)
    ax_mat.text(119.42, len(matrix_rows) - 0.5, "~000011 xmax", fontsize=7, color="#64748b")
    ax_mat.set_title("东西向查询矩阵：各行 = 实验窗；横条 = 该窗在经度上的覆盖区间")
    ax_mat.grid(True, axis="x", alpha=0.25)

    out = args.out
    out.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(out, dpi=args.dpi, bbox_inches="tight")
    plt.close(fig)
    print(f"Wrote {out.resolve()}")


if __name__ == "__main__":
    main()

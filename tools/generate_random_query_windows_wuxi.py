#!/usr/bin/env python3
"""
Generate random Wuxi spatiotemporal query windows.

Envelope defaults exclude wide timeline rows (wide_baseline, early/mid/late_t_slice)
so random boxes concentrate in the dense core day; this reduces empty windows
but does **not** guarantee in-window keys -- use generate_wuxi_random_windows_validated.py
with st_meta_read_bench for that.

Usage:
  python tools/generate_random_query_windows_wuxi.py --count 12 --seed 42 \
    --out tools/st_validity_experiment_windows_wuxi_random12_s42.csv
"""

from __future__ import annotations

import argparse
import csv
import random
from pathlib import Path


def load_wuxi_envelope(
    wuxi_csv: Path, exclude_labels: frozenset[str] | None = None
) -> dict[str, float]:
    rows = list(csv.DictReader(wuxi_csv.open(encoding="utf-8")))
    if not rows:
        raise SystemExit(f"Empty CSV: {wuxi_csv}")
    if exclude_labels:
        rows = [r for r in rows if (r.get("Label") or "").strip() not in exclude_labels]
    if len(rows) < 2:
        raise SystemExit(
            f"Need >=2 CSV rows after envelope exclude; got {len(rows)} from {wuxi_csv}"
        )
    t_min = min(int(r["TMin"]) for r in rows)
    t_max = max(int(r["TMax"]) for r in rows)
    x_min = min(float(r["XMin"]) for r in rows)
    x_max = max(float(r["XMax"]) for r in rows)
    y_min = min(float(r["YMin"]) for r in rows)
    y_max = max(float(r["YMax"]) for r in rows)
    return {
        "t_min": float(t_min),
        "t_max": float(t_max),
        "x_min": x_min,
        "x_max": x_max,
        "y_min": y_min,
        "y_max": y_max,
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--count", type=int, default=20)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument(
        "--wuxi-envelope-csv",
        type=Path,
        default=Path("d:/Project/tools/st_validity_experiment_windows_wuxi.csv"),
        help="CSV used to derive Wuxi envelope",
    )
    ap.add_argument(
        "--envelope-exclude-labels",
        type=str,
        default="wide_baseline,early_t_slice,mid_t_slice,late_t_slice",
        help="comma-separated Label values omitted from bbox (empty = use all rows)",
    )
    ap.add_argument("--min-t-span", type=int, default=600, help="min time window (seconds)")
    ap.add_argument("--max-t-frac", type=float, default=0.20, help="max time span fraction of envelope")
    ap.add_argument("--min-x-span", type=float, default=0.08, help="min lon span (deg)")
    ap.add_argument("--max-x-frac", type=float, default=0.35, help="max lon span fraction of envelope")
    ap.add_argument("--min-y-span", type=float, default=0.06, help="min lat span (deg)")
    ap.add_argument("--max-y-frac", type=float, default=0.35, help="max lat span fraction of envelope")
    args = ap.parse_args()

    ex = frozenset(
        x.strip()
        for x in args.envelope_exclude_labels.split(",")
        if x.strip()
    )
    env = load_wuxi_envelope(args.wuxi_envelope_csv, ex if ex else None)
    rng = random.Random(args.seed)

    t0, t1 = int(env["t_min"]), int(env["t_max"])
    x0, x1 = float(env["x_min"]), float(env["x_max"])
    y0, y1 = float(env["y_min"]), float(env["y_max"])

    tr = max(1, t1 - t0)
    xr = max(1e-9, x1 - x0)
    yr = max(1e-9, y1 - y0)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(
            f,
            fieldnames=["Label", "TMin", "TMax", "XMin", "XMax", "YMin", "YMax", "Note"],
        )
        w.writeheader()
        for i in range(args.count):
            t_span = rng.randint(
                args.min_t_span,
                max(args.min_t_span + 1, int(tr * args.max_t_frac)),
            )
            t_min = rng.randint(t0, max(t0, t1 - t_span))
            t_max = t_min + t_span

            xw = rng.uniform(max(args.min_x_span, xr * 0.01), max(args.min_x_span, xr * args.max_x_frac))
            yw = rng.uniform(max(args.min_y_span, yr * 0.01), max(args.min_y_span, yr * args.max_y_frac))
            xw = min(xw, xr * 0.95)
            yw = min(yw, yr * 0.95)
            x_min = rng.uniform(x0, x1 - xw)
            y_min = rng.uniform(y0, y1 - yw)

            w.writerow(
                {
                    "Label": f"random_w{i + 1:02d}_n{args.count}_s{args.seed}",
                    "TMin": t_min,
                    "TMax": t_max,
                    "XMin": round(x_min, 6),
                    "XMax": round(x_min + xw, 6),
                    "YMin": round(y_min, 6),
                    "YMax": round(y_min + yw, 6),
                    "Note": (
                        f"uniform random; n={args.count} seed={args.seed}; "
                        f"envelope_exclude={repr(sorted(ex)) if ex else 'none'}"
                    ),
                }
            )

    print(f"Wrote {args.count} rows -> {args.out.resolve()}")


if __name__ == "__main__":
    main()


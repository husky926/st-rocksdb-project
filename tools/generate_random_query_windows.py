#!/usr/bin/env python3
"""
Generate random spatiotemporal query windows (same CSV schema as st_validity_experiment_windows*.csv).

Default envelope matches PKDD subset in verify_pkdd_st (see data/processed/pkdd segments extent).

Usage:
  python tools/generate_random_query_windows.py --count 50 --seed 42 \\
    --out data/experiments/random_windows_pkdd_n50_seed42.csv
  python tools/generate_random_query_windows.py --count 20 --include-anchor wide_pkdd
"""

from __future__ import annotations

import argparse
import csv
import random
from pathlib import Path


# Envelope: data/processed/pkdd/segments_points.csv full extent (100k segments subset)
PKDD_ENVELOPE = {
    "t_min": 1372636853,
    "t_max": 1374483494,
    "x_min": -12.154527,
    "x_max": -6.958539,
    "y_min": 38.664981,
    "y_max": 45.657225,
}

# `process_pkdd_train.py --max-segments 300000` -> data/processed/pkdd_large (see Record.md)
PKDD_LARGE_300K_ENVELOPE = {
    "t_min": 1372636853,
    "t_max": 1378656304,
    "x_min": -12.154527,
    "x_max": -6.085845,
    "y_min": 38.564424,
    "y_max": 51.037119,
}

# Hand-tuned PKDD wide_baseline (same as st_validity_experiment_windows_pkdd.csv row 1)
ANCHOR_WIDE_PKDD = {
    "Label": "wide_baseline_anchor",
    "TMin": 1372637000,
    "TMax": 1374000000,
    "XMin": -8.72,
    "XMax": -8.52,
    "YMin": 41.08,
    "YMax": 41.22,
    "Note": "fixed anchor (not random); same as designed wide_baseline",
}


def rand_window(
    rng: random.Random,
    env: dict[str, float | int],
    min_t_span: int,
    max_t_frac: float,
    min_x_span: float,
    max_x_frac: float,
    min_y_span: float,
    max_y_frac: float,
) -> dict[str, object]:
    t0, t1 = int(env["t_min"]), int(env["t_max"])
    x0, x1 = float(env["x_min"]), float(env["x_max"])
    y0, y1 = float(env["y_min"]), float(env["y_max"])

    t_span = rng.randint(min_t_span, max(min_t_span + 1, int((t1 - t0) * max_t_frac)))
    t_min = rng.randint(t0, max(t0, t1 - t_span))
    t_max = t_min + t_span

    x_rng = x1 - x0
    y_rng = y1 - y0
    wx = rng.uniform(max(min_x_span, 1e-6), max(min_x_span, x_rng * max_x_frac))
    wy = rng.uniform(max(min_y_span, 1e-6), max(min_y_span, y_rng * max_y_frac))
    wx = min(wx, x_rng * 0.95)
    wy = min(wy, y_rng * 0.95)
    x_min = rng.uniform(x0, x1 - wx)
    y_min = rng.uniform(y0, y1 - wy)
    x_max = x_min + wx
    y_max = y_min + wy

    return {
        "TMin": t_min,
        "TMax": t_max,
        "XMin": round(x_min, 6),
        "XMax": round(x_max, 6),
        "YMin": round(y_min, 6),
        "YMax": round(y_max, 6),
    }


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--count", type=int, default=50)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument(
        "--envelope",
        choices=("pkdd_100k", "pkdd_large_300k"),
        default="pkdd_100k",
        help="Spatiotemporal bounding box for uniform random windows (pkdd_large_300k matches "
        "data/processed/pkdd_large after process_pkdd_train --max-segments 300000)",
    )
    ap.add_argument(
        "--include-anchor",
        choices=("none", "wide_pkdd"),
        default="none",
        help="Prepend one non-random wide window for cross-check vs hand-designed table",
    )
    ap.add_argument("--min-t-span", type=int, default=3600, help="min time window (seconds)")
    ap.add_argument(
        "--max-t-frac",
        type=float,
        default=0.25,
        help="max time span as fraction of envelope (t_max-t_min)",
    )
    ap.add_argument("--min-x-span", type=float, default=0.03, help="min lon span (deg)")
    ap.add_argument("--max-x-frac", type=float, default=0.45, help="max lon span as frac of envelope")
    ap.add_argument("--min-y-span", type=float, default=0.03, help="min lat span (deg)")
    ap.add_argument("--max-y-frac", type=float, default=0.45, help="max lat span as frac of envelope")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    env = PKDD_ENVELOPE if args.envelope == "pkdd_100k" else PKDD_LARGE_300K_ENVELOPE

    rows: list[dict[str, object]] = []
    if args.include_anchor == "wide_pkdd":
        rows.append(dict(ANCHOR_WIDE_PKDD))

    for i in range(args.count):
        w = rand_window(
            rng,
            env,
            min_t_span=args.min_t_span,
            max_t_frac=args.max_t_frac,
            min_x_span=args.min_x_span,
            max_x_frac=args.max_x_frac,
            min_y_span=args.min_y_span,
            max_y_frac=args.max_y_frac,
        )
        rows.append(
            {
                "Label": f"random_w{i+1:05d}_s{args.seed}",
                "Note": f"uniform random box; envelope={args.envelope}",
                **w,
            }
        )

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(
            f,
            fieldnames=[
                "Label",
                "TMin",
                "TMax",
                "XMin",
                "XMax",
                "YMin",
                "YMax",
                "Note",
            ],
        )
        w.writeheader()
        for r in rows:
            w.writerow(
                {
                    "Label": r["Label"],
                    "TMin": r["TMin"],
                    "TMax": r["TMax"],
                    "XMin": r["XMin"],
                    "XMax": r["XMax"],
                    "YMin": r["YMin"],
                    "YMax": r["YMax"],
                    "Note": r.get("Note", ""),
                }
            )

    print(f"Wrote {len(rows)} rows -> {args.out.resolve()}")


if __name__ == "__main__":
    main()

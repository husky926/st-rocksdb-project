#!/usr/bin/env python3
"""Summarize wall-time and throughput for prune-module ablation TSVs.

Each TSV row corresponds to one query window and includes:
  full_wall_us, prune_wall_us, ratio_wall, error (optional).

Throughput definition (workload of N independent queries):
  QPS = N / (sum_wall_us / 1e6)
"""

from __future__ import annotations

import argparse
import csv
import math
from dataclasses import dataclass
from pathlib import Path


def percentile(sorted_vals: list[float], p: float) -> float:
    """p in [0,100], linear interpolation."""
    if not sorted_vals:
        return float("nan")
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    k = (len(sorted_vals) - 1) * (p / 100.0)
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return sorted_vals[int(k)]
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)


@dataclass
class Summary:
    n: int
    avg_full_wall_us: float
    avg_prune_wall_us: float
    total_full_wall_s: float
    total_prune_wall_s: float
    qps_full: float
    qps_prune: float
    speedup_wall: float
    ratio_wall_p50: float
    ratio_wall_p90: float


def summarize_tsv(path: Path) -> Summary:
    rows: list[dict[str, str]] = []
    with path.open("r", encoding="utf-8") as f:
        reader = csv.DictReader(f, delimiter="\t")
        for r in reader:
            if r.get("error", "").strip():
                continue
            rows.append(r)

    if not rows:
        raise SystemExit(f"No valid rows in TSV: {path}")

    full_wall = [float(r["full_wall_us"]) for r in rows]
    prune_wall = [float(r["prune_wall_us"]) for r in rows]
    ratio_wall = [float(r["ratio_wall"]) for r in rows if r.get("ratio_wall", "").strip()]

    n = len(rows)
    sum_full = sum(full_wall)
    sum_prune = sum(prune_wall)
    avg_full = sum_full / n
    avg_prune = sum_prune / n
    qps_full = n / (sum_full / 1e6)
    qps_prune = n / (sum_prune / 1e6)
    speedup = (sum_full / sum_prune) if sum_prune else float("inf")

    ratio_wall.sort()
    p50 = percentile(ratio_wall, 50)
    p90 = percentile(ratio_wall, 90)

    return Summary(
        n=n,
        avg_full_wall_us=avg_full,
        avg_prune_wall_us=avg_prune,
        total_full_wall_s=sum_full / 1e6,
        total_prune_wall_s=sum_prune / 1e6,
        qps_full=qps_full,
        qps_prune=qps_prune,
        speedup_wall=speedup,
        ratio_wall_p50=p50,
        ratio_wall_p90=p90,
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tsv", action="append", required=True, help="TSV path (can repeat)")
    ap.add_argument("--label", action="append", default=[], help="Optional labels (same count as --tsv)")
    args = ap.parse_args()

    paths = [Path(p) for p in args.tsv]
    labels = args.label
    if labels and len(labels) != len(paths):
        raise SystemExit("--label count must match --tsv count (or omit --label).")

    for i, p in enumerate(paths):
        s = summarize_tsv(p)
        lab = labels[i] if i < len(labels) else p.name
        print(f"=== {lab} ===")
        print(f"windows={s.n}")
        print(f"avg_full_wall_us={s.avg_full_wall_us:.1f}  avg_prune_wall_us={s.avg_prune_wall_us:.1f}")
        print(f"total_full_wall_s={s.total_full_wall_s:.3f}  total_prune_wall_s={s.total_prune_wall_s:.3f}")
        print(f"throughput_full_qps={s.qps_full:.3f}  throughput_prune_qps={s.qps_prune:.3f}")
        print(f"speedup_wall={s.speedup_wall:.3f}x")
        print(f"ratio_wall p50={s.ratio_wall_p50:.4f}  p90={s.ratio_wall_p90:.4f}")
        print()


if __name__ == "__main__":
    main()


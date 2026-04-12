#!/usr/bin/env python3
"""Split prune_vs_full TSV by `regime` (e.g. narrow vs wide) and compare metrics.

Latency-oriented (narrow): lower prune_wall_us and ratio_wall per query is better.
Throughput-oriented (wide): same metrics under heavy scans; also report mean
prune_bytes_read as IO proxy when comparing regimes.

Requires column `regime` (from st_prune_vs_full_baseline_sweep.ps1 + dual-regime CSV).
If missing, all rows go to group '(unset)'.
"""

from __future__ import annotations

import argparse
import csv
import math
import sys
from collections import defaultdict
from pathlib import Path
from typing import Optional


def percentile(sorted_vals: list[float], p: float) -> float:
    if not sorted_vals:
        return float("nan")
    n = len(sorted_vals)
    if n == 1:
        return sorted_vals[0]
    k = (n - 1) * (p / 100.0)
    f = math.floor(k)
    c = math.ceil(k)
    if f == c:
        return sorted_vals[int(k)]
    return sorted_vals[f] + (sorted_vals[c] - sorted_vals[f]) * (k - f)


def fparse(s: str) -> Optional[float]:
    s = (s or "").strip()
    if not s:
        return None
    try:
        return float(s)
    except ValueError:
        return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("tsv", type=Path)
    args = ap.parse_args()

    by_regime: dict[str, list[dict[str, str]]] = defaultdict(list)
    with args.tsv.open(encoding="utf-8") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            if row.get("error", "").strip():
                continue
            r = (row.get("regime") or "").strip() or "(unset)"
            by_regime[r].append(row)

    if not by_regime:
        print("No rows.")
        return 1

    def summarize_group(name: str, rows: list[dict[str, str]]) -> None:
        pw = [fparse(r.get("prune_wall_us", "")) for r in rows]
        pw = [x for x in pw if x is not None]
        rw = [fparse(r.get("ratio_wall", "")) for r in rows]
        rw = [x for x in rw if x is not None]
        pb = [fparse(r.get("prune_bytes_read", "")) for r in rows]
        pb = [x for x in pb if x is not None]
        kinw = [fparse(r.get("prune_keys_in_window", "")) for r in rows]
        kinw = [x for x in kinw if x is not None]

        print(f"=== regime={name}  n_windows={len(rows)} ===")
        if pw:
            pw.sort()
            print(
                f"  prune_wall_us  min={pw[0]:.1f}  p50={percentile(pw, 50):.1f}  "
                f"p90={percentile(pw, 90):.1f}  max={pw[-1]:.1f}  (lower => faster prune pass)"
            )
        if rw:
            rw.sort()
            print(
                f"  ratio_wall     min={rw[0]:.4f}  p50={percentile(rw, 50):.4f}  "
                f"p90={percentile(rw, 90):.4f}  max={rw[-1]:.4f}  (lower => better vs full scan)"
            )
        if pb:
            print(f"  prune_bytes_read  mean={sum(pb)/len(pb):.0f}  max={max(pb):.0f}  (IO proxy)")
        if kinw:
            print(f"  keys_in_window    mean={sum(kinw)/len(kinw):.1f}  max={max(kinw):.0f}")
        print()

    # Prefer narrow first, wide second, then alphabetical
    order = []
    for k in ("narrow", "wide"):
        if k in by_regime:
            order.append(k)
    for k in sorted(by_regime.keys()):
        if k not in order:
            order.append(k)

    for k in order:
        summarize_group(k, by_regime[k])

    print(
        "Read: narrow ~ latency-sensitive selective queries; "
        "wide ~ throughput-heavy scans. Same sst_manifest stack; "
        "tune/adapt to keep both p50 ratio_wall low."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

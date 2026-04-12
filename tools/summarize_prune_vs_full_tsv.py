#!/usr/bin/env python3
"""Print distribution of ratio_bytes, ratio_wall, key_selectivity from prune_vs_full TSV.

If contribution columns are present (prune_file_considered, prune_block_index_examined, etc.),
also prints p50/p90 of derived skip rates (file / block index / key).
"""

from __future__ import annotations

import argparse
import csv
import math
import sys
from pathlib import Path
from typing import Optional


def percentile(sorted_vals: list[float], p: float) -> float:
    """p in [0,100]. Linear interpolation."""
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


def _is_wuxi_style_random_label(lab: str) -> bool:
    return lab.startswith("random_w") or lab.startswith("randcov_w")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("tsv", type=Path)
    args = ap.parse_args()

    ratios: list[float] = []
    wall_r: list[float] = []
    keys_sel: list[float] = []
    labels_random: list[float] = []
    labels_random_wall: list[float] = []
    file_skip_rate: list[float] = []
    block_skip_rate: list[float] = []
    key_skip_rate: list[float] = []
    for row in csv.DictReader(args.tsv.open(encoding="utf-8"), delimiter="\t"):
        if row.get("error", "").strip():
            continue
        rb = row.get("ratio_bytes", "").strip()
        rw = row.get("ratio_wall", "").strip()
        ks = row.get("key_selectivity", "").strip()
        lab = row.get("label", "")
        if rb:
            try:
                r = float(rb)
            except ValueError:
                pass
            else:
                ratios.append(r)
                if _is_wuxi_style_random_label(lab):
                    labels_random.append(r)
        if rw:
            try:
                wv = float(rw)
            except ValueError:
                pass
            else:
                wall_r.append(wv)
                if _is_wuxi_style_random_label(lab):
                    labels_random_wall.append(wv)
        if ks:
            try:
                keys_sel.append(float(ks))
            except ValueError:
                pass

        def _rate(num_s: str, den_s: str) -> Optional[float]:
            if not num_s or not den_s:
                return None
            try:
                num = float(num_s)
                den = float(den_s)
            except ValueError:
                return None
            if den <= 0:
                return None
            return num / den

        fc = row.get("prune_file_considered", "").strip()
        fs = row.get("prune_file_skipped", "").strip()
        r = _rate(fs, fc)
        if r is not None:
            file_skip_rate.append(r)

        bex = row.get("prune_block_index_examined", "").strip()
        bsk = row.get("prune_block_index_skipped_st_disjoint", "").strip()
        r = _rate(bsk, bex)
        if r is not None:
            block_skip_rate.append(r)

        kex = row.get("prune_key_examined", "").strip()
        ksk = row.get("prune_key_skipped_disjoint", "").strip()
        r = _rate(ksk, kex)
        if r is not None:
            key_skip_rate.append(r)

    ratios.sort()
    wall_r.sort()
    keys_sel.sort()
    labels_random.sort()
    labels_random_wall.sort()
    file_skip_rate.sort()
    block_skip_rate.sort()
    key_skip_rate.sort()

    def block(name: str, vals: list[float]) -> None:
        if not vals:
            print(f"{name}: (no values)")
            return
        print(f"{name}  n={len(vals)}")
        print(f"  min={vals[0]:.6f}  p10={percentile(vals, 10):.6f}  p50={percentile(vals, 50):.6f}  "
              f"p90={percentile(vals, 90):.6f}  max={vals[-1]:.6f}")

    print("=== ratio_bytes = prune_bytes_read / full_bytes_read (lower is better) ===")
    block("ALL rows", ratios)
    block("random_w* / randcov_w* only", labels_random)
    if wall_r:
        print()
        print("=== ratio_wall = prune_wall_us / full_wall_us (lower is better) ===")
        block("ALL rows", wall_r)
        block("random_w* / randcov_w* only", labels_random_wall)
    if keys_sel:
        print()
        print(
            "=== key_selectivity: window sweeps use prune_keys_in_window/full_keys (~1 when correct); "
            "column value is in_window ratio; all_cf sweeps still use prune_keys/full_keys ==="
        )
        block("ALL rows", keys_sel)

    if file_skip_rate or block_skip_rate or key_skip_rate:
        print()
        print(
            "=== contribution skip rates (from TSV columns; higher = more work avoided "
            "at that layer before/deeper work) ==="
        )
        if file_skip_rate:
            block(
                "file: prune_file_skipped / prune_file_considered",
                file_skip_rate,
            )
        if block_skip_rate:
            block(
                "block index: skipped_st_disjoint / index_examined",
                block_skip_rate,
            )
        if key_skip_rate:
            block(
                "key: skipped_disjoint / keys_examined",
                key_skip_rate,
            )

    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)

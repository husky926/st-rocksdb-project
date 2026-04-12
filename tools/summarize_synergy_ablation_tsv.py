#!/usr/bin/env python3
"""Summarize st_prune_synergy_ablation.ps1 output TSV.

synergy_prune = min(prune_wall_manifest, prune_wall_sst) / prune_wall_both
  > 1  : Local+Global prune path faster than BOTH single-layer modes (target "1+1>2").
  <= 1 : at least one single mode was no slower than combined on prune wall time.

synergy_ratio = min(ratio_wall_manifest, ratio_wall_sst) / ratio_wall_both
  (ratio_wall = prune/full wall_us; lower is better)
  > 1 : combined has better relative efficiency than best single mode.
"""

from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("tsv", type=Path)
    args = ap.parse_args()

    rows: list[dict[str, str]] = []
    with args.tsv.open(encoding="utf-8") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            if row.get("error", "").strip():
                continue
            rows.append(row)

    if not rows:
        print("No valid rows (or all errors).")
        return 1

    sp: list[float] = []
    sr: list[float] = []
    for row in rows:
        s = (row.get("synergy_prune") or "").strip()
        if s:
            try:
                sp.append(float(s))
            except ValueError:
                pass
        r = (row.get("synergy_ratio") or "").strip()
        if r:
            try:
                sr.append(float(r))
            except ValueError:
                pass

    def stats_line(name: str, vals: list[float]) -> None:
        if not vals:
            print(f"{name}: (no values)")
            return
        vals = sorted(vals)
        n = len(vals)
        mid = vals[n // 2] if n % 2 else (vals[n // 2 - 1] + vals[n // 2]) / 2
        print(f"{name}  n={n}  min={vals[0]:.4f}  p50={mid:.4f}  max={vals[-1]:.4f}")
        gt1 = sum(1 for x in vals if x > 1.0)
        print(f"  rows with value > 1: {gt1}/{n}  (target: synergy_prune>1 for clear 1+1>2)")

    print("=== synergy_prune (higher is better; >1 means combined beats best single) ===")
    stats_line("synergy_prune", sp)
    if sr:
        print()
        print("=== synergy_ratio (higher is better; >1 means combined ratio_wall beats best single) ===")
        stats_line("synergy_ratio", sr)

    print()
    print("Per-row:")
    for row in rows:
        lab = row.get("label", "")
        spv = row.get("synergy_prune", "")
        win = row.get("winner_prune", "")
        print(f"  {lab}: synergy_prune={spv}  winner={win}")

    return 0


if __name__ == "__main__":
    sys.exit(main())

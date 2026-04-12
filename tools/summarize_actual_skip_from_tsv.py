#!/usr/bin/env python3
"""Summarize actual skipped SST counts from our ablation TSV.

Reads column:
  prune_file_skipped

Ignores rows with non-empty `error`.
"""

from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path


@dataclass
class SkipSummary:
    n: int
    avg: float
    min: int
    max: int


def summarize(path: Path) -> SkipSummary:
    vals: list[int] = []
    with path.open("r", encoding="utf-8") as f:
        r = csv.DictReader(f, delimiter="\t")
        for row in r:
            if (row.get("error") or "").strip():
                continue
            s = (row.get("prune_file_skipped") or "").strip()
            if not s:
                continue
            vals.append(int(s))
    if not vals:
        raise SystemExit(f"No valid prune_file_skipped rows in {path}")
    return SkipSummary(
        n=len(vals),
        avg=sum(vals) / len(vals),
        min=min(vals),
        max=max(vals),
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tsv", action="append", required=True)
    ap.add_argument("--label", action="append", default=[])
    args = ap.parse_args()

    paths = [Path(p) for p in args.tsv]
    labels = args.label
    if labels and len(labels) != len(paths):
        raise SystemExit("--label count must match --tsv count (or omit --label).")

    for i, p in enumerate(paths):
        s = summarize(p)
        lab = labels[i] if i < len(labels) else p.name
        print(f"=== {lab} ===")
        print(f"windows={s.n}")
        print(f"avg_prune_file_skipped={s.avg:.3f}  min={s.min}  max={s.max}")
        print()


if __name__ == "__main__":
    main()


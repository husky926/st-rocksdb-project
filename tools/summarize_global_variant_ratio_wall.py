"""Summarize ratio_wall (Vanilla/prune wall time) from global_vm_auto_vs_vanilla TSVs."""
from __future__ import annotations

import argparse
import csv
import statistics
from pathlib import Path


def load_ratios(tsv: Path) -> dict[str, list[float]]:
    by_db: dict[str, list[float]] = {}
    with tsv.open(encoding="utf-8-sig") as f:
        r = csv.DictReader(f, delimiter="\t")
        for row in r:
            db = row.get("db", "").strip()
            rw = row.get("ratio_wall", "").strip()
            if not db or not rw:
                continue
            try:
                v = float(rw)
            except ValueError:
                continue
            by_db.setdefault(db, []).append(v)
    return by_db


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("parent", type=Path, help="Parent dir with global_*.tsv")
    args = ap.parse_args()
    parent: Path = args.parent
    files = sorted(parent.glob("global_*.tsv"))
    if not files:
        print(f"No global_*.tsv under {parent}")
        return

    print("### Pooled median ratio_wall (Vanilla wall / prune wall; higher => prune faster)\n")
    for tsv in files:
        by_db = load_ratios(tsv)
        print(f"## {tsv.name}\n")
        all_vals: list[float] = []
        for db in sorted(by_db.keys()):
            vals = by_db[db]
            med = statistics.median(vals) if vals else float("nan")
            all_vals.extend(vals)
            short = Path(db).name
            print(f"  {short}: median={med:.4f}  (n={len(vals)})")
        if all_vals:
            print(f"  **ALL**: median={statistics.median(all_vals):.4f}  (n={len(all_vals)})")
        print()


if __name__ == "__main__":
    main()

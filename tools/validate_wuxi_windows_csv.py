#!/usr/bin/env python3
"""Run st_meta_read_bench (full_scan window mode) for each row in a Wuxi windows CSV."""

from __future__ import annotations

import argparse
import csv
import re
import subprocess
import sys
from pathlib import Path


def bench_keys(
    bench: Path,
    db: Path,
    t_min: int,
    t_max: int,
    x_min: float,
    x_max: float,
    y_min: float,
    y_max: float,
) -> int | None:
    cmd = [
        str(bench),
        "--db",
        str(db),
        "--no-prune-scan",
        "--full-scan-mode",
        "window",
        "--prune-mode",
        "sst",
        "--prune-t-min",
        str(t_min),
        "--prune-t-max",
        str(t_max),
        "--prune-x-min",
        str(x_min),
        "--prune-x-max",
        str(x_max),
        "--prune-y-min",
        str(y_min),
        "--prune-y-max",
        str(y_max),
    ]
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=900,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        print(f"bench failed: {e}", file=sys.stderr)
        return None
    text = (proc.stdout or "") + "\n" + (proc.stderr or "")
    m = re.search(r"full_scan mode=window\s+keys=(\d+)", text)
    if not m:
        m = re.search(r"full_scan mode=\S+\s+keys=(\d+)", text)
    if not m:
        print(text[-3000:], file=sys.stderr)
        return None
    return int(m.group(1))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--csv", type=Path, required=True)
    ap.add_argument("--db", type=Path, required=True)
    ap.add_argument(
        "--bench",
        type=Path,
        default=Path("d:/Project/rocks-demo/build/st_meta_read_bench.exe"),
    )
    ap.add_argument("--min-keys", type=int, default=50)
    args = ap.parse_args()

    if not args.bench.is_file():
        print(f"Missing bench: {args.bench}", file=sys.stderr)
        return 1
    rows = list(csv.DictReader(args.csv.open(encoding="utf-8")))
    bad = 0
    print(f"{'Label':<28} {'keys':>8}  ok(>={args.min_keys})")
    for r in rows:
        label = (r.get("Label") or "").strip()
        k = bench_keys(
            args.bench,
            args.db,
            int(r["TMin"]),
            int(r["TMax"]),
            float(r["XMin"]),
            float(r["XMax"]),
            float(r["YMin"]),
            float(r["YMax"]),
        )
        if k is None:
            print(f"{label:<28} {'ERR':>8}  ?")
            bad += 1
            continue
        ok = k >= args.min_keys
        if not ok:
            bad += 1
        print(f"{label:<28} {k:>8}  {ok}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())

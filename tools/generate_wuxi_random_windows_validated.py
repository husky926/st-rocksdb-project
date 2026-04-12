#!/usr/bin/env python3
"""
Generate random Wuxi query windows and **reject** candidates until the baseline
full CF scan reports at least ``--min-full-keys`` ST keys inside the window.

Uses ``st_meta_read_bench --no-prune-scan`` (window mode) on a reference DB
(typically 1-SST segment) to read ``full_scan mode=window keys=``.

Envelope: by default excludes wide timeline rows from ``st_validity_experiment_windows_wuxi.csv``
(wide_baseline, early/mid/late_t_slice) so random boxes sit in the dense core
instead of the whole segment bbox.

Usage:
  python tools/generate_wuxi_random_windows_validated.py ^
    --db D:/Project/data/verify_wuxi_segment_1sst ^
    --bench D:/Project/rocks-demo/build/st_meta_read_bench.exe ^
    --out tools/st_validity_experiment_windows_wuxi_random12_cov_s42.csv ^
    --count 12 --seed 42 --min-full-keys 50
"""

from __future__ import annotations

import argparse
import csv
import random
import re
import subprocess
import sys
from pathlib import Path

# Rows that blow up the bbox to "whole segment / long timeline" and cause
# uniform-random empty windows; keep tight core-day + regional boxes.
DEFAULT_ENVELOPE_EXCLUDE_LABELS = frozenset(
    {"wide_baseline", "early_t_slice", "mid_t_slice", "late_t_slice"}
)


def load_wuxi_envelope(
    wuxi_csv: Path, exclude_labels: frozenset[str] | None
) -> dict[str, float]:
    rows = list(csv.DictReader(wuxi_csv.open(encoding="utf-8")))
    if exclude_labels:
        rows = [r for r in rows if (r.get("Label") or "").strip() not in exclude_labels]
    if len(rows) < 2:
        raise SystemExit(
            f"Need >=2 rows after envelope exclude; got {len(rows)} from {wuxi_csv}"
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


def bench_window_keys(
    bench: Path,
    db: Path,
    t_min: int,
    t_max: int,
    x_min: float,
    x_max: float,
    y_min: float,
    y_max: float,
) -> int | None:
    """Return baseline in-window ST key count, or None on parse/run failure."""
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
            timeout=600,
        )
    except (OSError, subprocess.TimeoutExpired) as e:
        print(f"bench run failed: {e}", file=sys.stderr)
        return None
    text = (proc.stdout or "") + "\n" + (proc.stderr or "")
    m = re.search(
        r"full_scan mode=window\s+keys=(\d+)",
        text,
    )
    if not m:
        m = re.search(r"full_scan mode=\S+\s+keys=(\d+)", text)
    if not m:
        print("Could not parse keys= from bench output:", file=sys.stderr)
        print(text[-4000:], file=sys.stderr)
        return None
    return int(m.group(1))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", type=Path, required=True)
    ap.add_argument("--db", type=Path, required=True, help="reference segment DB (1 SST recommended)")
    ap.add_argument(
        "--bench",
        type=Path,
        default=Path("d:/Project/rocks-demo/build/st_meta_read_bench.exe"),
    )
    ap.add_argument("--count", type=int, default=12)
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--min-full-keys", type=int, default=50)
    ap.add_argument("--max-attempts-per-window", type=int, default=8000)
    ap.add_argument(
        "--wuxi-envelope-csv",
        type=Path,
        default=Path("d:/Project/tools/st_validity_experiment_windows_wuxi.csv"),
    )
    ap.add_argument(
        "--envelope-exclude-labels",
        type=str,
        default=",".join(sorted(DEFAULT_ENVELOPE_EXCLUDE_LABELS)),
        help="comma-separated Label values to drop when computing bbox",
    )
    ap.add_argument("--min-t-span", type=int, default=600)
    ap.add_argument("--max-t-frac", type=float, default=0.35)
    ap.add_argument("--min-x-span", type=float, default=0.05)
    ap.add_argument("--max-x-frac", type=float, default=0.45)
    ap.add_argument("--min-y-span", type=float, default=0.04)
    ap.add_argument("--max-y-frac", type=float, default=0.45)
    args = ap.parse_args()

    if not args.bench.is_file():
        print(f"Missing bench: {args.bench}", file=sys.stderr)
        print("Build rocks-demo target st_meta_read_bench, or pass --bench.", file=sys.stderr)
        return 1
    if not args.db.is_dir():
        print(f"Missing db directory: {args.db}", file=sys.stderr)
        return 1

    exclude = frozenset(
        x.strip()
        for x in args.envelope_exclude_labels.split(",")
        if x.strip()
    )
    env = load_wuxi_envelope(args.wuxi_envelope_csv, exclude)
    rng = random.Random(args.seed)

    t0, t1 = int(env["t_min"]), int(env["t_max"])
    x0, x1 = float(env["x_min"]), float(env["x_max"])
    y0, y1 = float(env["y_min"]), float(env["y_max"])

    tr = max(1, t1 - t0)
    xr = max(1e-9, x1 - x0)
    yr = max(1e-9, y1 - y0)

    out_rows: list[dict[str, str]] = []
    for i in range(args.count):
        placed = False
        for attempt in range(args.max_attempts_per_window):
            t_span = rng.randint(
                args.min_t_span,
                max(args.min_t_span + 1, int(tr * args.max_t_frac)),
            )
            t_min = rng.randint(t0, max(t0, t1 - t_span))
            t_max = t_min + t_span

            xw = rng.uniform(
                max(args.min_x_span, xr * 0.01),
                max(args.min_x_span, xr * args.max_x_frac),
            )
            yw = rng.uniform(
                max(args.min_y_span, yr * 0.01),
                max(args.min_y_span, yr * args.max_y_frac),
            )
            xw = min(xw, xr * 0.95)
            yw = min(yw, yr * 0.95)
            x_min = rng.uniform(x0, x1 - xw)
            y_min = rng.uniform(y0, y1 - yw)
            x_max = x_min + xw
            y_max = y_min + yw

            keys = bench_window_keys(
                args.bench, args.db, t_min, t_max, x_min, x_max, y_min, y_max
            )
            if keys is None:
                return 1
            if keys >= args.min_full_keys:
                out_rows.append(
                    {
                        "Label": f"randcov_w{i + 1:02d}_n{args.count}_s{args.seed}_k{args.min_full_keys}",
                        "TMin": str(t_min),
                        "TMax": str(t_max),
                        "XMin": f"{x_min:.6f}",
                        "XMax": f"{x_max:.6f}",
                        "YMin": f"{y_min:.6f}",
                        "YMax": f"{y_max:.6f}",
                        "Note": (
                            f"bench-validated full_keys>={args.min_full_keys} on {args.db.name}; "
                            f"attempts={attempt + 1}; envelope_dense_excludes={sorted(exclude)!r}"
                        ),
                    }
                )
                print(
                    f"window {i + 1}/{args.count}: keys={keys} (attempts={attempt + 1})",
                    file=sys.stderr,
                )
                placed = True
                break
        if not placed:
            print(
                f"Failed to place window {i + 1} after {args.max_attempts_per_window} attempts. "
                f"Try lowering --min-full-keys, widening envelope, or increasing --max-t-frac.",
                file=sys.stderr,
            )
            return 1

    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(
            f,
            fieldnames=["Label", "TMin", "TMax", "XMin", "XMax", "YMin", "YMax", "Note"],
        )
        w.writeheader()
        w.writerows(out_rows)

    print(f"Wrote {len(out_rows)} validated rows -> {args.out.resolve()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

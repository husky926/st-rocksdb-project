#!/usr/bin/env python3
"""Aggregate three prune_vs_full TSVs (manifest / sst / sst_manifest) by regime.

Usage:
  python summarize_wuxi_ablation_three_modes.py manifest.tsv sst.tsv sst_manifest.tsv

Prints: markdown-ish table + optional --html-rows for pasting into docs.
"""

from __future__ import annotations

import argparse
import csv
import math
import sys
from pathlib import Path


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


def row_full_keys(r: dict[str, str]) -> int:
    try:
        return int((r.get("full_keys") or "").strip() or 0)
    except ValueError:
        return 0


def filter_min_full_keys(rows: list[dict[str, str]], min_full_keys: int) -> list[dict[str, str]]:
    if min_full_keys <= 0:
        return list(rows)
    return [r for r in rows if row_full_keys(r) >= min_full_keys]


def load_rows(path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    # utf-8-sig: TSVs from PowerShell Set-Content -Encoding utf8 carry a BOM on the first header.
    with path.open(encoding="utf-8-sig") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            if row.get("error", "").strip():
                continue
            rows.append(row)
    return rows


def rows_have_regime_labels(rows: list[dict[str, str]]) -> bool:
    """True if any row has non-empty Regime (narrow/wide/...). Wuxi cov CSVs often omit it."""
    return any((r.get("regime") or "").strip() for r in rows)


def wall_speedup_bundle(
    rows: list[dict[str, str]],
    min_full_keys: int = 0,
    *,
    baseline: str = "vanilla",
) -> dict[str, float]:
    """Wall-time speedups: baseline_wall_us / prune_wall_us.

    baseline:
      - ``vanilla``: use ``vanilla_wall_us`` (upstream RocksDB) per row; skip rows
        where it is empty (matches aggregate_wuxi_ablation_runs.py default).
      - ``fork_full``: use ``full_wall_us`` (fork full window scan).

    - sum_baseline_over_sum_prune: Σbaseline / Σprune (legacy key name
      sum_full_over_sum_prune kept for callers).
    - min_full_keys: if > 0, only include rows where ``full_keys`` meets threshold.
    - p50_full_over_prune: median of per-window (baseline_i / prune_i); name kept
      for backward compatibility.
    """
    rows = filter_min_full_keys(rows, min_full_keys)
    sum_full = 0.0
    sum_prune = 0.0
    per_window: list[float] = []
    ratio_walls: list[float] = []
    used = 0
    for r in rows:
        try:
            if baseline == "vanilla":
                bs = (r.get("vanilla_wall_us") or "").strip()
                if not bs:
                    continue
                fw = float(bs)
            else:
                fw = float((r.get("full_wall_us") or "").strip())
            pw = float((r.get("prune_wall_us") or "").strip())
        except ValueError:
            continue
        if pw <= 0 or fw < 0:
            continue
        sum_full += fw
        sum_prune += pw
        per_window.append(fw / pw)
        rs = (r.get("ratio_wall") or "").strip()
        if rs:
            try:
                ratio_walls.append(float(rs))
            except ValueError:
                pass
        used += 1

    per_window.sort()
    ratio_walls.sort()
    p50_fp = percentile(per_window, 50) if per_window else float("nan")
    p50_rw = percentile(ratio_walls, 50) if ratio_walls else float("nan")
    sum_sp = (
        (sum_full / sum_prune) if sum_prune > 0 else float("nan")
    )
    bad_inv = (1.0 / p50_rw) if p50_rw and p50_rw > 0 else float("nan")
    out = {
        "n": float(used),
        "sum_full_over_sum_prune": sum_sp,
        "p50_full_over_prune": p50_fp,
        "p50_ratio_wall": p50_rw,
        "inv_p50_ratio_wall": bad_inv,
    }
    if baseline == "vanilla" and used == 0 and rows:
        print(
            "WARNING: --baseline vanilla but no TSV rows have non-empty vanilla_wall_us; "
            "pooled ratios are nan. Build a Vanilla cache + ablation, or use --baseline fork_full.",
            file=sys.stderr,
        )
    return out


def regime_stats(rows: list[dict[str, str]], regime: str) -> dict[str, float]:
    if regime == "(all)":
        sub = list(rows)
    else:
        sub = [r for r in rows if (r.get("regime") or "").strip() == regime]

    def fvals(key: str) -> list[float]:
        out: list[float] = []
        for r in sub:
            s = (r.get(key) or "").strip()
            if not s:
                continue
            try:
                out.append(float(s))
            except ValueError:
                pass
        return out

    rw = sorted(fvals("ratio_wall"))
    pw = sorted(fvals("prune_wall_us"))
    p50_rw = percentile(rw, 50)
    p50_pw = percentile(pw, 50)
    sp = 1.0 / p50_rw if p50_rw and p50_rw > 0 else float("nan")
    return {
        "n": float(len(sub)),
        "p50_ratio_wall": p50_rw,
        "p50_prune_wall_us": p50_pw,
        "speedup_vs_full_proxy": sp,
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("manifest_tsv", type=Path)
    ap.add_argument("sst_tsv", type=Path)
    ap.add_argument("both_tsv", type=Path)
    ap.add_argument("--html-rows", action="store_true", help="print HTML table rows")
    ap.add_argument(
        "--pooled",
        action="store_true",
        help="print p50 over all rows (use when CSV has no Regime column, e.g. wuxi windows)",
    )
    ap.add_argument(
        "--pooled-by-db",
        action="store_true",
        help="like --pooled but one table per distinct db column (paths in TSV db field, e.g. 1sst/164sst/736sst)",
    )
    ap.add_argument(
        "--min-full-keys",
        type=int,
        default=None,
        metavar="K",
        help=(
            "when set with --pooled/--pooled-by-db, also print a filtered table: "
            "only rows with full_keys>=K (use 1 to drop empty-window rows, "
            "50 for 'dense hit' windows only)"
        ),
    )
    ap.add_argument(
        "--baseline",
        choices=("vanilla", "fork_full"),
        default="vanilla",
        help=(
            "Wall baseline for pooled sum/p50 tables: vanilla_wall_us (upstream) "
            "or full_wall_us (fork full). Default vanilla (Wuxi official compare)."
        ),
    )
    args = ap.parse_args()

    modes = [
        ("Global (manifest)", args.manifest_tsv),
        ("Local (sst)", args.sst_tsv),
        ("Local+Global", args.both_tsv),
    ]

    data: dict[str, dict[str, dict[str, float]]] = {}
    sample_rows: list[dict[str, str]] = []
    for label, path in modes:
        if not path.is_file():
            print(f"Missing: {path}", file=sys.stderr)
            return 1
        rows = load_rows(path)
        if not sample_rows:
            sample_rows = rows
        data[label] = {
            "narrow": regime_stats(rows, "narrow"),
            "wide": regime_stats(rows, "wide"),
        }

    if rows_have_regime_labels(sample_rows):
        print(
            "### By regime (p50 ratio_wall, p50 prune_wall_us; speedup ≈ 1/p50 ratio_wall)\n"
        )
        for reg in ("narrow", "wide"):
            print(f"**{reg}**\n")
            print("| Mode | p50 ratio_wall | p50 prune_wall (us) | speedup proxy |")
            print("|------|----------------|---------------------|---------------|")
            for mlabel, _ in modes:
                st = data[mlabel][reg]
                rw = st["p50_ratio_wall"]
                pw = st["p50_prune_wall_us"]
                sp = st["speedup_vs_full_proxy"]
                print(f"| {mlabel} | {rw:.4f} | {pw:.1f} | {sp:.2f}x |")
            print()
    else:
        print(
            "### By regime (skipped)\n\n"
            "TSV rows have **no `Regime` column** (or it is empty everywhere). "
            "The narrow/wide tables would be **all nan** — that is **not** a failed query. "
            "For Wuxi 12-window runs, use **`--pooled` / `--pooled-by-db`** below.\n"
        )

    bl = args.baseline
    sum_label = "sum(vanilla)/sum(prune)" if bl == "vanilla" else "sum(full)/sum(prune)"
    p50_label = "p50(vanilla/prune)" if bl == "vanilla" else "p50(full/prune)"

    def _print_wall_table(title: str, rows_by_mode: list[tuple[str, list[dict[str, str]]]], k: int) -> None:
        print(title + "\n")
        print(
            f"| Mode | n | {sum_label} | {p50_label} | p50 ratio_wall | "
            "1/p50(ratio) (!) |"
        )
        print(
            "|------|---|--------------------|-----------------|----------------|------------------|"
        )
        for mlabel, rows in rows_by_mode:
            b = wall_speedup_bundle(rows, min_full_keys=k, baseline=bl)
            n = int(b["n"])
            print(
                f"| {mlabel} | {n} | {b['sum_full_over_sum_prune']:.3f}x | "
                f"{b['p50_full_over_prune']:.3f}x | {b['p50_ratio_wall']:.4f} | "
                f"{b['inv_p50_ratio_wall']:.2f}x |"
            )
        print()

    if args.pooled:
        base_desc = (
            "**sum(vanilla_wall_us)/sum(prune_wall_us)** over listed rows (rows without "
            "vanilla_wall_us are skipped)."
            if bl == "vanilla"
            else "**sum(full_wall_us)/sum(prune_wall_us)** over listed rows. "
        )
        print(
            "### Pooled all windows (wall-time speedup; CSV without Regime)\n\n"
            f"{base_desc}"
            "Uniform-random windows often have **full_keys=0** (no ST point in the box) while "
            "the baseline still scans the whole CF, so the **all-rows** ratio is **not** "
            "comparable to legacy ~5-7x tables (hand-picked windows with sustained overlap).\n"
        )
        rb = [(ml, load_rows(p)) for ml, p in modes]
        _print_wall_table(
            "#### All windows (full_keys>=0) - can inflate with sparse random boxes",
            rb,
            0,
        )
        _print_wall_table("#### Windows with full_keys>=1 (non-empty query answers)", rb, 1)
        extra = [50, 100]
        if args.min_full_keys is not None:
            extra.append(args.min_full_keys)
        for k in sorted(set(extra)):
            if k <= 1:
                continue
            label = f"#### Windows with full_keys>={k} (dense-hit subset)"
            _print_wall_table(label, rb, k)

    if args.pooled_by_db:
        rows0 = load_rows(args.manifest_tsv)
        dbs = sorted({(r.get("db") or "").strip() for r in rows0 if (r.get("db") or "").strip()})

        def _db_sort_key(path: str) -> tuple[int, str]:
            p = path.lower()
            if "segment_1sst" in p:
                return (0, path)
            if "segment_164" in p:
                return (1, path)
            if "segment_776" in p or "segment_736" in p:
                return (2, path)
            return (9, path)

        dbs = sorted(dbs, key=_db_sort_key)
        if not dbs:
            print("No db column values in manifest TSV.", file=sys.stderr)
            return 1
        print(
            "### Per DB: 12 windows each (verify `*.sst` count on disk matches folder)\n\n"
            f"Baseline column: **{bl}**. Same caveat as pooled: **all-window** sum ratio blows up "
            "when many windows have **full_keys==0**. Compare **full_keys>=1** block to legacy reports.\n"
        )
        for db in dbs:
            print(f"**`{db}`**\n")
            rb = [
                (
                    mlabel,
                    [
                        r
                        for r in load_rows(path)
                        if (r.get("db") or "").strip() == db
                    ],
                )
                for mlabel, path in modes
            ]
            _print_wall_table(f"`{db}` - all windows", rb, 0)
            _print_wall_table(f"`{db}` - full_keys>=1", rb, 1)
            for k in (50, 100):
                _print_wall_table(f"`{db}` - full_keys>={k}", rb, k)
            if args.min_full_keys is not None and args.min_full_keys > 100:
                _print_wall_table(
                    f"`{db}` - full_keys>={args.min_full_keys}",
                    rb,
                    args.min_full_keys,
                )

    if args.html_rows:
        if not rows_have_regime_labels(sample_rows):
            print(
                "<!-- html-rows skipped: no Regime labels in TSV (use --pooled output instead) -->",
                file=sys.stderr,
            )
        else:
            for reg in ("narrow", "wide"):
                g = data["Global (manifest)"][reg]
                l = data["Local (sst)"][reg]
                b = data["Local+Global"][reg]
                print(
                    f'        <tr><td>{reg}</td><td>Global</td><td>{g["p50_ratio_wall"]:.4f}</td>'
                    f'<td>{g["p50_prune_wall_us"]:.1f}</td><td>{g["speedup_vs_full_proxy"]:.2f}x</td></tr>'
                )
                print(
                    f'        <tr><td>{reg}</td><td>Local</td><td>{l["p50_ratio_wall"]:.4f}</td>'
                    f'<td>{l["p50_prune_wall_us"]:.1f}</td><td>{l["speedup_vs_full_proxy"]:.2f}x</td></tr>'
                )
                print(
                    f'        <tr><td>{reg}</td><td>Local+Global</td><td>{b["p50_ratio_wall"]:.4f}</td>'
                    f'<td>{b["p50_prune_wall_us"]:.1f}</td><td>{b["speedup_vs_full_proxy"]:.2f}x</td></tr>'
                )

    return 0


if __name__ == "__main__":
    sys.exit(main())

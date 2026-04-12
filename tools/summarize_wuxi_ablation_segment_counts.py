#!/usr/bin/env python3
"""Audit per-query-window trajectory **segment** counts from Wuxi ablation TSVs.

Storage model: **one KV = one trajectory segment** (0xE6 user keys). In
``st_prune_vs_full_baseline_sweep`` output:

- ``full_keys`` — full-scan count of segment keys intersecting the window (ground truth).
- ``prune_keys_in_window`` — prune path count in window (should match ``full_keys`` when correct).
- ``vanilla_keys`` — upstream Vanilla bench count for the same window (when present).

This script prints min/max/mean, zero counts, and cross-checks that ``full_keys`` agrees
across the three prune modes for each (db, label). Use it to catch **0-hit windows** or
**nan-prone** aggregates before trusting wall-clock ratios.

Usage:
  python tools/summarize_wuxi_ablation_segment_counts.py D:\\Project\\data\\experiments\\wuxi_ablation_...
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path
from typing import Any


MODES = [
    ("Global (manifest)", "ablation_manifest.tsv"),
    ("Local (sst)", "ablation_sst.tsv"),
    ("Local+Global (sst_manifest)", "ablation_sst_manifest.tsv"),
]


def load_rows(path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with path.open(encoding="utf-8-sig") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            if row.get("error", "").strip():
                continue
            rows.append(row)
    return rows


def db_sort_key(path: str) -> tuple[int, str]:
    p = path.lower()
    if "segment_1sst" in p and "164" not in p:
        return (0, path)
    if "segment_164" in p:
        return (1, path)
    if "segment_776" in p or "segment_736" in p:
        return (2, path)
    return (9, path)


def parse_int(s: str) -> int | None:
    s = (s or "").strip()
    if not s:
        return None
    try:
        return int(float(s))
    except ValueError:
        return None


def stats(vals: list[int]) -> dict[str, float | int]:
    if not vals:
        return {"n": 0, "min": 0, "max": 0, "mean": float("nan"), "sum": 0}
    return {
        "n": len(vals),
        "min": min(vals),
        "max": max(vals),
        "mean": sum(vals) / len(vals),
        "sum": sum(vals),
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "ablation_dir",
        type=Path,
        help="Directory containing ablation_manifest.tsv, ablation_sst.tsv, ablation_sst_manifest.tsv",
    )
    ap.add_argument(
        "--min-full-keys",
        type=int,
        default=50,
        metavar="K",
        help="Report how many windows have full_keys < K (default 50, cov-CSV design point).",
    )
    ap.add_argument("--json", type=Path, default=None, help="Optional JSON summary path")
    args = ap.parse_args()
    d = args.ablation_dir.resolve()
    if not d.is_dir():
        print(f"Not a directory: {d}", file=sys.stderr)
        return 1

    loaded: dict[str, list[dict[str, str]]] = {}
    for label, fname in MODES:
        p = d / fname
        if not p.is_file():
            print(f"Missing: {p}", file=sys.stderr)
            return 1
        loaded[label] = load_rows(p)

    # Cross-mode full_keys consistency (manifest as reference).
    ref = MODES[0][0]
    ref_rows = loaded[ref]
    key_index: dict[tuple[str, str], dict[str, str]] = {}
    for r in ref_rows:
        k = ((r.get("db") or "").strip(), (r.get("label") or "").strip())
        if k[0] and k[1]:
            key_index[k] = r

    mismatches: list[str] = []
    for mlabel, _ in MODES[1:]:
        for r in loaded[mlabel]:
            k = ((r.get("db") or "").strip(), (r.get("label") or "").strip())
            if not k[0] or not k[1]:
                continue
            a = parse_int((key_index.get(k) or {}).get("full_keys", ""))
            b = parse_int(r.get("full_keys", ""))
            if a is not None and b is not None and a != b:
                mismatches.append(f"{k[0]} | {k[1]} | {ref} full_keys={a} vs {mlabel} full_keys={b}")

    lines: list[str] = []
    lines.append("### Trajectory segment count audit (one KV = one segment)\n")
    lines.append(
        "Column meanings: **full_keys** = full-scan segment count in window; "
        "**prune_keys_in_window** = prune path; **vanilla_keys** = upstream Vanilla (if run).\n"
    )
    if mismatches:
        lines.append("**WARNING: full_keys mismatch across prune modes** (should not happen):\n")
        for x in mismatches[:50]:
            lines.append(f"- {x}")
        if len(mismatches) > 50:
            lines.append(f"- ... and {len(mismatches) - 50} more\n")
        lines.append("")
    else:
        lines.append(
            "**Cross-check:** `full_keys` identical across Global/Local/L+G for all aligned rows.\n"
        )

    summary_json: dict[str, Any] = {
        "ablation_dir": str(d),
        "min_full_keys_threshold": args.min_full_keys,
        "full_keys_mismatches": len(mismatches),
        "by_mode": {},
    }

    for mlabel, fname in MODES:
        rows = loaded[mlabel]
        dbs = sorted({(r.get("db") or "").strip() for r in rows if (r.get("db") or "").strip()}, key=db_sort_key)
        mode_block: dict[str, Any] = {}
        lines.append(f"#### {mlabel}\n")
        lines.append("| db | windows | full_keys min | max | mean | sum | prune_in_win min | max | mean | vanilla min | max | mean | zeros(full) | <K |")
        lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for db in dbs:
            sub = [r for r in rows if (r.get("db") or "").strip() == db]
            fk = [x for x in (parse_int(r.get("full_keys")) for r in sub) if x is not None]
            pk = [x for x in (parse_int(r.get("prune_keys_in_window")) for r in sub) if x is not None]
            vk = [x for x in (parse_int(r.get("vanilla_keys")) for r in sub) if x is not None]
            sf = stats(fk)
            sp = stats(pk)
            sv = stats(vk) if vk else {"n": 0, "min": 0, "max": 0, "mean": float("nan"), "sum": 0}
            nzero = sum(1 for x in fk if x == 0)
            nlt = sum(1 for x in fk if x < args.min_full_keys)
            short = db.split("\\")[-1] if "\\" in db else db
            vm = f"{sv['mean']:.2f}" if vk and sv["n"] else "n/a"
            na = "n/a"
            lines.append(
                f"| `{short}` | {sf['n']} | {sf['min']} | {sf['max']} | {sf['mean']:.2f} | {sf['sum']} | "
                f"{sp['min']} | {sp['max']} | {sp['mean']:.2f} | "
                f"{(sv['min'] if vk else na)} | {(sv['max'] if vk else na)} | "
                f"{vm} | {nzero} | {nlt} |"
            )
            mode_block[db] = {
                "windows": int(sf["n"]),
                "full_keys": {k: sf[k] for k in ("min", "max", "mean", "sum", "n")},
                "prune_keys_in_window": {k: sp[k] for k in ("min", "max", "mean", "n")},
                "vanilla_keys": {k: sv[k] for k in ("min", "max", "mean", "n")}
                if vk
                else None,
                "full_keys_zero_windows": nzero,
                f"full_keys_lt_{args.min_full_keys}": nlt,
            }
        lines.append("")
        summary_json["by_mode"][mlabel] = mode_block

    # Per-label × db matrix (manifest only): full_keys per window.
    mr = loaded[MODES[0][0]]
    dbs_m = sorted({(r.get("db") or "").strip() for r in mr if (r.get("db") or "").strip()}, key=db_sort_key)
    labels = sorted({(r.get("label") or "").strip() for r in mr if (r.get("label") or "").strip()})
    hdr = "| label | " + " | ".join(f"`{Path(db).name}` fk" for db in dbs_m) + " |"
    sep = "|---|" + "|".join(["---:" for _ in dbs_m]) + "|"
    lines.append("#### Per-window `full_keys` (Global manifest)\n")
    lines.append(hdr)
    lines.append(sep)
    for lab in labels:
        cells = []
        for db in dbs_m:
            hit = [
                parse_int(r.get("full_keys"))
                for r in mr
                if (r.get("label") or "").strip() == lab and (r.get("db") or "").strip() == db
            ]
            hit = [x for x in hit if x is not None]
            cells.append(str(hit[0]) if hit else "n/a")
        lines.append(f"| {lab} | " + " | ".join(cells) + " |")
    lines.append("")

    text = "\n".join(lines)
    print(text)
    audit_path = d / "ablation_segment_count_audit.txt"
    audit_path.write_text(text, encoding="utf-8")
    print(f"\nWrote {audit_path}", file=sys.stderr)

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(summary_json, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"Wrote {args.json}", file=sys.stderr)

    if mismatches:
        print(
            f"WARNING: {len(mismatches)} full_keys mismatches across prune modes (see audit text).",
            file=sys.stderr,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Average speedup & QPS over multiple wuxi ablation output dirs (run_01 .. run_N).

For each run directory, expects ablation_manifest.tsv, ablation_sst.tsv, ablation_sst_manifest.tsv.

Default ``--baseline vanilla``: speedup = sum(vanilla_wall_us)/sum(prune_wall_us) (upstream RocksDB).
Use ``--baseline fork_full`` for legacy sum(full_wall_us)/sum(prune_wall_us) when vanilla columns
are empty.

QPS = 12 / (sum_wall_seconds) for the 12 windows in that db (sequential wall sum interpretation).

Outputs: markdown table, --json path, --html-table for docs/st_ablation_wuxi_1sst_vs_manysst.html
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from pathlib import Path


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
    if "segment_776" in p or "segment_736" in p or "bucket3600" in p:
        return (2, path)
    return (9, path)


def count_live_sst(db_path: str) -> int | None:
    try:
        p = Path(db_path)
        if p.is_dir():
            return sum(1 for _ in p.glob("*.sst"))
    except OSError:
        pass
    return None


def tier_label_for_db(db: str, idx: int, run_meta: dict) -> str:
    """Column title ``'{N} SST'`` from disk; third tier falls back to run_meta."""
    n = count_live_sst(db)
    if n is not None:
        return f"{n} SST"
    if idx == 2:
        m = run_meta.get("third_tier_live_sst_count")
        if isinstance(m, int) and m > 0:
            return f"{m} SST"
    return "? SST"


def short_db_label(path: str) -> str:
    n = count_live_sst(path)
    if n is not None:
        return f"{n} SST"
    return Path(path).name


MODES = [
    ("Global (manifest)", "ablation_manifest.tsv"),
    ("Local (sst)", "ablation_sst.tsv"),
    ("Local+Global (sst_manifest)", "ablation_sst_manifest.tsv"),
]


def load_optional_run_meta(run_dir: Path) -> dict:
    p = run_dir / "wuxi_ablation_run_meta.json"
    if not p.is_file():
        return {}
    try:
        return json.loads(p.read_text(encoding="utf-8-sig"))
    except json.JSONDecodeError:
        return {}


def one_run_stats(
    run_dir: Path, min_full_keys: int, *, baseline: str = "vanilla"
) -> tuple[dict[str, dict[str, dict[str, float | tuple[float, float] | str]]], str]:
    """Returns stats[mode_label][db_path] = {speedup, qps_full, qps_prune, kv_ok, kv_total}"""
    out: dict[str, dict[str, dict[str, float | tuple[float, float] | str]]] = {}

    for mlabel, fname in MODES:
        tsv = run_dir / fname
        if not tsv.is_file():
            return {}, f"missing {tsv}"
        rows = load_rows(tsv)
        dbs = sorted({(r.get("db") or "").strip() for r in rows if (r.get("db") or "").strip()}, key=db_sort_key)
        out[mlabel] = {}
        for db in dbs:
            sub = [
                r
                for r in rows
                if (r.get("db") or "").strip() == db
                and int((r.get("full_keys") or "0").strip() or 0) >= min_full_keys
            ]
            sf = sp = 0.0
            kv_ok = 0
            kv_fail = 0
            kv_empty = 0
            for r in sub:
                try:
                    vw = (r.get("vanilla_wall_us") or "").strip()
                    if baseline == "vanilla":
                        if not vw:
                            lab = (r.get("label") or "").strip()
                            return (
                                {},
                                f"missing vanilla_wall_us in {fname} db={db!r} label={lab!r} "
                                f"(use --baseline fork_full for legacy TSVs)",
                            )
                        sf += float(vw)
                    else:
                        if vw:
                            sf += float(vw)
                        else:
                            sf += float((r.get("full_wall_us") or "").strip())
                    sp += float((r.get("prune_wall_us") or "").strip())
                except ValueError:
                    continue
                kv = (r.get("kv_correct") or "").strip()
                if not kv:
                    kv_empty += 1
                elif kv.upper() == "OK":
                    kv_ok += 1
                else:
                    kv_fail += 1
            speedup = (sf / sp) if sp > 0 else float("nan")
            qf = (12.0 * 1_000_000.0 / sf) if sf > 0 else float("nan")
            qp = (12.0 * 1_000_000.0 / sp) if sp > 0 else float("nan")
            if kv_empty == len(sub):
                acc = "未验证"
            elif kv_fail > 0:
                acc = f"FAIL ({kv_fail})"
            elif kv_ok == len(sub) == 12:
                acc = "OK (12/12)"
            else:
                acc = f"{kv_ok}/{len(sub)} OK"
            out[mlabel][db] = {
                "speedup": speedup,
                "qps_pair": (qf, qp),
                "kv_label": acc,
                "n_rows": float(len(sub)),
            }

    return out, ""


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "run_dirs",
        nargs="*",
        type=Path,
        default=[],
        help="Directories each containing ablation_*.tsv (e.g. .../run_01 .../run_10)",
    )
    ap.add_argument(
        "--parent",
        type=Path,
        default=None,
        metavar="DIR",
        help="Collect all immediate subdirs named run_* under DIR (sorted by name)",
    )
    ap.add_argument("--min-full-keys", type=int, default=50)
    ap.add_argument(
        "--baseline",
        choices=("vanilla", "fork_full"),
        default="vanilla",
        help=(
            "Wall baseline for speedup/QPS: vanilla_wall_us (default, upstream RocksDB) "
            "or fork full_wall_us when vanilla is absent."
        ),
    )
    ap.add_argument("--json", type=Path, default=None, help="Write aggregated numbers as JSON")
    ap.add_argument("--html-table", type=Path, default=None, help="Append HTML table fragment to file")
    args = ap.parse_args()

    run_dirs: list[Path] = []
    if args.parent is not None:
        p = args.parent.resolve()
        if not p.is_dir():
            print(f"Not a directory: {p}", file=sys.stderr)
            return 1
        run_dirs = sorted(p.glob("run_*"), key=lambda x: x.name)
        run_dirs = [d for d in run_dirs if d.is_dir()]
    run_dirs.extend([d.resolve() for d in args.run_dirs if d.is_dir()])
    run_dirs = sorted(set(run_dirs), key=lambda x: str(x))
    if not run_dirs:
        print("No valid run directories.", file=sys.stderr)
        return 1

    per_run: list[dict[str, dict[str, dict[str, float | tuple[float, float] | str]]]] = []
    for d in run_dirs:
        st, err = one_run_stats(d, args.min_full_keys, baseline=args.baseline)
        if err:
            print(f"{d}: {err}", file=sys.stderr)
            return 1
        per_run.append(st)

    # Union of db paths from first run
    dbs = sorted(
        {db for st in per_run for db in st[MODES[0][0]].keys()},
        key=db_sort_key,
    )

    agg: dict[str, dict[str, dict[str, float | str]]] = {}
    for mlabel, _ in MODES:
        agg[mlabel] = {}
        for db in dbs:
            speeds = []
            qfs = []
            qps = []
            kv_labels: list[str] = []
            for st in per_run:
                cell = st.get(mlabel, {}).get(db)
                if not cell:
                    continue
                speeds.append(float(cell["speedup"]))  # type: ignore[arg-type]
                qf, qp = cell["qps_pair"]  # type: ignore[assignment]
                qfs.append(float(qf))
                qps.append(float(qp))
                kv_labels.append(str(cell["kv_label"]))
            if not speeds:
                continue
            uniq = sorted(set(kv_labels))
            if len(uniq) == 1 and uniq[0].startswith("OK"):
                kv_agg = f"{len(run_dirs)} 跑次均 {uniq[0]}"
            elif all("未验证" in x for x in kv_labels):
                kv_agg = "未验证"
            else:
                kv_agg = "; ".join(uniq[:4])
                if len(uniq) > 4:
                    kv_agg += "…"
            agg[mlabel][db] = {
                "speedup_mean": sum(speeds) / len(speeds),
                "qps_full_mean": sum(qfs) / len(qfs),
                "qps_prune_mean": sum(qps) / len(qps),
                "n_runs": len(speeds),
                "kv_note": kv_agg,
            }

    mode_kv: dict[str, str] = {}
    for mlabel, _ in MODES:
        cells: list[str] = []
        for st in per_run:
            for db in dbs:
                c = st.get(mlabel, {}).get(db)
                if not c:
                    continue
                cells.append(str(c["kv_label"]))
        if not cells:
            mode_kv[mlabel] = "—"
        elif all(x == "OK (12/12)" for x in cells):
            mode_kv[mlabel] = f"{len(run_dirs)} 跑次×3 库×12 窗 verify_kv 全 OK"
        elif any(x.startswith("FAIL") for x in cells):
            mode_kv[mlabel] = "存在 FAIL，见各 run 下 TSV"
        elif all(x == "未验证" for x in cells):
            mode_kv[mlabel] = "未验证（未开 -VerifyKVResults）"
        else:
            ok_runs = 0
            for st in per_run:
                labs = [
                    str(st.get(mlabel, {}).get(db, {}).get("kv_label", ""))
                    for db in dbs
                    if st.get(mlabel, {}).get(db)
                ]
                if len(labs) == 3 and all(x == "OK (12/12)" for x in labs):
                    ok_runs += 1
            mode_kv[mlabel] = (
                f"{ok_runs}/{len(per_run)} 跑次完整 verify_kv OK；"
                f"其余跑次未验证或缺行"
            )

    run_meta0 = load_optional_run_meta(run_dirs[0])
    tier_labs = [tier_label_for_db(db, i, run_meta0) for i, db in enumerate(dbs)]
    t1, t2, t3 = tier_labs[0], tier_labs[1], tier_labs[2]

    # Print markdown
    qps_hdr = (
        "QPS Vanilla → prune"
        if args.baseline == "vanilla"
        else "QPS baseline (full) → prune"
    )
    print(
        f"### Aggregated over **{len(run_dirs)}** runs "
        f"(full_keys>={args.min_full_keys}, baseline={args.baseline})\n"
    )
    hdr = (
        f"| 模式 | speedup ({t1}) | speedup ({t2}) | speedup ({t3}) | "
        f"{qps_hdr} ({t1}) | {qps_hdr} ({t2}) | {qps_hdr} ({t3}) | 准确性 |\n"
    )
    sep = "|------|----------------|-------------------|-------------------|---------------------------|-----------------------------|-----------------------------|--------|\n"

    lines = [hdr.rstrip(), sep.rstrip()]
    for mlabel, _ in MODES:
        label = mlabel.split("(")[0].strip()
        sp_parts: list[str] = []
        qps_cells: list[str] = []
        for db in dbs:
            a = agg.get(mlabel, {}).get(db)
            if not a:
                sp_parts.append("—")
                qps_cells.append("—")
                continue
            sm = float(a["speedup_mean"])
            sp_parts.append(f"{sm:.3f}×" if sm < 100 else f"{sm:.2f}×")
            qf = float(a["qps_full_mean"])
            qp = float(a["qps_prune_mean"])
            qps_cells.append(f"{qf:.2f} → {qp:.2f}")
        acc_final = mode_kv.get(mlabel, "—")
        line = (
            f"| {label} | {sp_parts[0]} | {sp_parts[1]} | {sp_parts[2]} | "
            f"{qps_cells[0]} | {qps_cells[1]} | {qps_cells[2]} | {acc_final} |"
        )
        lines.append(line)

    print("\n".join(lines))

    payload = {
        "n_runs": len(run_dirs),
        "min_full_keys": args.min_full_keys,
        "compare_baseline": args.baseline,
        "run_dirs": [str(d) for d in run_dirs],
        "aggregate": agg,
        "mode_kv": mode_kv,
        "run_meta": run_meta0,
        "tier_column_labels": tier_labs,
    }
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"\nWrote {args.json}", file=sys.stderr)

    if args.html_table:
        # Build standalone <table> block
        qh = "QPS Vanilla → prune" if args.baseline == "vanilla" else "QPS baseline → prune"
        h = (
            "<table>\n<thead><tr>"
            f"<th>模式</th><th>speedup ({t1})</th><th>speedup ({t2})</th><th>speedup ({t3})</th>"
            f"<th>{qh} ({t1})</th><th>{qh} ({t2})</th><th>{qh} ({t3})</th>"
            "<th>准确性</th></tr></thead>\n<tbody>\n"
        )
        body = ""
        for mlabel, _ in MODES:
            label = mlabel.split("(")[0].strip()
            body += "<tr>"
            body += f"<td>{label}</td>"
            for db in dbs:
                a = agg.get(mlabel, {}).get(db)
                if not a:
                    body += "<td>—</td>"
                    continue
                sm = float(a["speedup_mean"])
                body += f"<td>{sm:.3f}×</td>" if sm < 100 else f"<td>{sm:.2f}×</td>"
            for db in dbs:
                a = agg.get(mlabel, {}).get(db)
                if not a:
                    body += "<td>—</td>"
                    continue
                qf = float(a["qps_full_mean"])
                qp = float(a["qps_prune_mean"])
                body += f"<td>{qf:.2f} → {qp:.2f}</td>"
            body += f"<td>{mode_kv.get(mlabel, '—')}</td></tr>\n"
        h += body + "</tbody></table>\n"
        args.html_table.parent.mkdir(parents=True, exist_ok=True)
        args.html_table.write_text(h, encoding="utf-8")
        print(f"Wrote {args.html_table}", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
from __future__ import annotations

import csv
import glob
import math
from dataclasses import dataclass
from pathlib import Path


@dataclass
class RunStat:
    speedup: float
    qps_full: float
    qps_prune: float
    avg_skip: float
    ok_ratio: float


def mean_std(vals: list[float]) -> tuple[float, float]:
    if not vals:
        return float("nan"), float("nan")
    m = sum(vals) / len(vals)
    if len(vals) == 1:
        return m, 0.0
    v = sum((x - m) ** 2 for x in vals) / (len(vals) - 1)
    return m, math.sqrt(v)


def parse_tsv(path: Path) -> RunStat:
    rows = []
    with path.open("r", encoding="utf-8") as f:
        r = csv.DictReader(f, delimiter="\t")
        for row in r:
            if (row.get("error") or "").strip():
                continue
            rows.append(row)
    n = len(rows)
    if n == 0:
        raise RuntimeError(f"no valid rows in {path}")

    full = [float(x["full_wall_us"]) for x in rows]
    prune = [float(x["prune_wall_us"]) for x in rows]
    sum_full = sum(full)
    sum_prune = sum(prune)
    speedup = sum_full / sum_prune if sum_prune > 0 else float("inf")
    qps_full = n / (sum_full / 1e6)
    qps_prune = n / (sum_prune / 1e6)

    skips = [float((x.get("prune_file_skipped") or "0")) for x in rows]
    avg_skip = sum(skips) / n

    oks = [1.0 if (x.get("kv_correct") or "") == "OK" else 0.0 for x in rows]
    ok_ratio = sum(oks) / n

    return RunStat(speedup, qps_full, qps_prune, avg_skip, ok_ratio)


def summarize_group(pattern: str, label: str) -> None:
    files = sorted(glob.glob(pattern))
    if not files:
        print(f"=== {label} ===")
        print("no files")
        print()
        return
    stats = [parse_tsv(Path(p)) for p in files]

    sp_m, sp_s = mean_std([s.speedup for s in stats])
    qf_m, qf_s = mean_std([s.qps_full for s in stats])
    qp_m, qp_s = mean_std([s.qps_prune for s in stats])
    sk_m, sk_s = mean_std([s.avg_skip for s in stats])
    ok_m, ok_s = mean_std([s.ok_ratio for s in stats])

    print(f"=== {label} ===")
    print(f"runs={len(stats)}")
    print(f"speedup_wall mean±std = {sp_m:.3f} ± {sp_s:.3f}")
    print(f"qps_full mean±std    = {qf_m:.3f} ± {qf_s:.3f}")
    print(f"qps_prune mean±std   = {qp_m:.3f} ± {qp_s:.3f}")
    print(f"avg_skip_sst mean±std= {sk_m:.3f} ± {sk_s:.3f}")
    print(f"kv_ok_ratio mean±std = {ok_m:.3f} ± {ok_s:.3f}")
    print()


def main() -> None:
    groups = [
        (r"d:\Project\data\experiments\wuxi_segment_full\repeat_sst_full_r*_verifykv.tsv", "1SST Local"),
        (r"d:\Project\data\experiments\wuxi_segment_full\repeat_manifest_full_r*_verifykv.tsv", "1SST Global"),
        (r"d:\Project\data\experiments\wuxi_segment_full\repeat_sst_manifest_full_r*_verifykv.tsv", "1SST Local+Global"),
        (r"d:\Project\data\experiments\wuxi_segment_manysst\repeat_sst_many_r*_verifykv.tsv", "164SST Local"),
        (r"d:\Project\data\experiments\wuxi_segment_manysst\repeat_manifest_many_r*_verifykv.tsv", "164SST Global"),
        (r"d:\Project\data\experiments\wuxi_segment_manysst\repeat_sst_manifest_many_r*_verifykv.tsv", "164SST Local+Global"),
    ]
    for pattern, label in groups:
        summarize_group(pattern, label)


if __name__ == "__main__":
    main()


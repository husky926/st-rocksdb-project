#!/usr/bin/env python3
"""
Convert three datasets under Project/data into unified trajectory segment files.

Sources:
  - Geolife Trajectories 1.3: *.plt (one file = one segment)
  - T-drive Taxi Trajectories: release/taxi_log_2008_by_id/*.txt (split by time gap)
  - bull train (Porto): train(1).csv POLYLINE + TIMESTAMP (15s per polyline point)

Outputs (UTF-8 CSV) under --out (default: data/processed):
  - segments_points.csv   long format: one row per point
  - segments_meta.csv     one row per segment (bbox, time range, count)

No third-party deps (stdlib only).
"""

from __future__ import annotations

import argparse
import csv
import json
import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Iterator, List, Optional, Sequence, Tuple

# -----------------------------------------------------------------------------
# Geolife .plt
# -----------------------------------------------------------------------------


def parse_geolife_plt(path: Path) -> Tuple[List[Tuple[float, float, float, int]], str]:
    """
    Returns (points as (lat, lon, alt_ft, unix_s)), segment_key
    """
    text = path.read_text(encoding="utf-8", errors="replace").splitlines()
    if len(text) < 7:
        return [], path.stem
    pts: List[Tuple[float, float, float, int]] = []
    for line in text[6:]:
        line = line.strip()
        if not line:
            continue
        parts = line.split(",")
        if len(parts) < 7:
            continue
        lat, lon = float(parts[0]), float(parts[1])
        alt_ft = float(parts[3])
        date_s, time_s = parts[5].strip(), parts[6].strip()
        dt = datetime.strptime(f"{date_s} {time_s}", "%Y-%m-%d %H:%M:%S")
        unix = int(dt.replace(tzinfo=timezone.utc).timestamp())
        pts.append((lat, lon, alt_ft, unix))
    user_id = path.parent.parent.name
    seg_key = f"{user_id}/{path.stem}"
    return pts, seg_key


# -----------------------------------------------------------------------------
# T-drive: id, time, lon, lat
# -----------------------------------------------------------------------------


def parse_tdrive_file(path: Path, gap_s: int) -> List[List[Tuple[float, float, int]]]:
    """Split one taxi file into segments when consecutive time gap > gap_s."""
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    rows: List[Tuple[datetime, float, float]] = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        parts = line.split(",")
        if len(parts) < 4:
            continue
        try:
            ts = datetime.strptime(parts[1].strip(), "%Y-%m-%d %H:%M:%S")
        except ValueError:
            continue
        lon, lat = float(parts[2]), float(parts[3])
        rows.append((ts, lon, lat))
    if not rows:
        return []
    segments: List[List[Tuple[float, float, int]]] = []
    cur: List[Tuple[float, float, int]] = []
    prev_ts: Optional[datetime] = None
    for ts, lon, lat in rows:
        u = int(ts.replace(tzinfo=timezone.utc).timestamp())
        if prev_ts is not None and (ts - prev_ts).total_seconds() > gap_s:
            if cur:
                segments.append(cur)
            cur = []
        cur.append((lat, lon, u))
        prev_ts = ts
    if cur:
        segments.append(cur)
    return segments


# -----------------------------------------------------------------------------
# Porto train CSV (POLYLINE JSON, TIMESTAMP unix, TRIP_ID)
# -----------------------------------------------------------------------------


def parse_porto_polyline_row(
    trip_id: str, timestamp_unix: int, polyline_json: str, interval_s: int = 15
) -> List[Tuple[float, float, float, int]]:
    """
    Each coordinate pair is (lon, lat). Time at point i = TIMESTAMP + i * interval_s.
    alt unknown -> 0.0
    """
    try:
        coords = json.loads(polyline_json)
    except json.JSONDecodeError:
        return []
    pts: List[Tuple[float, float, float, int]] = []
    for i, pair in enumerate(coords):
        if not isinstance(pair, (list, tuple)) or len(pair) < 2:
            continue
        lon, lat = float(pair[0]), float(pair[1])
        t = timestamp_unix + i * interval_s
        pts.append((lat, lon, 0.0, t))
    return pts


# -----------------------------------------------------------------------------
# Writers
# -----------------------------------------------------------------------------


@dataclass
class SegmentRecord:
    segment_id: str
    dataset: str
    points: Sequence[Tuple[float, float, float, int]]  # lat, lon, alt_m, unix
    source_ref: str


def feet_to_m(ft: float) -> float:
    return ft * 0.3048


def write_outputs(
    segments: Iterable[SegmentRecord],
    out_dir: Path,
) -> Tuple[int, int]:
    out_dir.mkdir(parents=True, exist_ok=True)
    points_path = out_dir / "segments_points.csv"
    meta_path = out_dir / "segments_meta.csv"

    n_seg = 0
    n_pt = 0
    with points_path.open("w", newline="", encoding="utf-8") as fp, meta_path.open(
        "w", newline="", encoding="utf-8"
    ) as fm:
        wp = csv.writer(fp)
        wm = csv.writer(fm)
        wp.writerow(
            [
                "segment_id",
                "dataset",
                "point_index",
                "unix_time_s",
                "lon",
                "lat",
                "alt_m",
                "source_ref",
            ]
        )
        wm.writerow(
            [
                "segment_id",
                "dataset",
                "point_count",
                "t_start_unix",
                "t_end_unix",
                "lon_min",
                "lon_max",
                "lat_min",
                "lat_max",
                "source_ref",
            ]
        )

        for seg in segments:
            if not seg.points:
                continue
            n_seg += 1
            lons = [p[1] for p in seg.points]
            lats = [p[0] for p in seg.points]
            ts = [p[3] for p in seg.points]
            alts_m = [feet_to_m(p[2]) if seg.dataset == "geolife" else p[2] for p in seg.points]
            wm.writerow(
                [
                    seg.segment_id,
                    seg.dataset,
                    len(seg.points),
                    min(ts),
                    max(ts),
                    min(lons),
                    max(lons),
                    min(lats),
                    max(lats),
                    seg.source_ref,
                ]
            )
            for i, (lat, lon, alt_raw, t) in enumerate(seg.points):
                alt_m = feet_to_m(alt_raw) if seg.dataset == "geolife" else alt_raw
                wp.writerow(
                    [
                        seg.segment_id,
                        seg.dataset,
                        i,
                        t,
                        lon,
                        lat,
                        f"{alt_m:.3f}",
                        seg.source_ref,
                    ]
                )
                n_pt += 1

    return n_seg, n_pt


def iter_geolife(data_root: Path, limit_files: Optional[int]) -> Iterator[SegmentRecord]:
    base = data_root / "Geolife Trajectories 1.3"
    # handle nested "Geolife Trajectories 1.3" folder twice
    candidates = list(base.rglob("Trajectory/*.plt"))
    candidates.sort()
    if limit_files is not None:
        candidates = candidates[:limit_files]
    for plt in candidates:
        pts, key = parse_geolife_plt(plt)
        if not pts:
            continue
        seg_id = f"geolife:{key}"
        yield SegmentRecord(
            segment_id=seg_id,
            dataset="geolife",
            points=pts,
            source_ref=str(plt.relative_to(data_root)),
        )


def iter_tdrive(data_root: Path, limit_files: Optional[int], gap_s: int) -> Iterator[SegmentRecord]:
    base = data_root / "T-drive Taxi Trajectories" / "release" / "taxi_log_2008_by_id"
    files = sorted(base.glob("*.txt"), key=lambda p: int(p.stem) if p.stem.isdigit() else 0)
    if limit_files is not None:
        files = files[:limit_files]
    for fp in files:
        segs = parse_tdrive_file(fp, gap_s=gap_s)
        for idx, pts in enumerate(segs):
            if len(pts) < 2:
                continue
            # pts: lat, lon, unix — convert to full tuple with alt 0
            full = [(lat, lon, 0.0, u) for lat, lon, u in pts]
            seg_id = f"tdrive:{fp.stem}:{idx}"
            yield SegmentRecord(
                segment_id=seg_id,
                dataset="tdrive",
                points=full,
                source_ref=str(fp.relative_to(data_root)),
            )


def iter_porto(data_root: Path, max_rows: Optional[int]) -> Iterator[SegmentRecord]:
    csv_path = data_root / "bull train" / "train(1).csv"
    if not csv_path.exists():
        return
    with csv_path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f)
        for i, row in enumerate(reader):
            if max_rows is not None and i >= max_rows:
                break
            poly = row.get("POLYLINE") or row.get('"POLYLINE"')
            if not poly:
                continue
            poly = poly.strip().strip('"')
            ts_raw = row.get("TIMESTAMP") or row.get('"TIMESTAMP"')
            trip = row.get("TRIP_ID") or row.get('"TRIP_ID"')
            if not ts_raw or not trip:
                continue
            trip = str(trip).strip().strip('"')
            try:
                ts_unix = int(str(ts_raw).strip().strip('"'))
            except ValueError:
                continue
            pts = parse_porto_polyline_row(trip, ts_unix, poly, interval_s=15)
            if len(pts) < 2:
                continue
            seg_id = f"porto:{trip}"
            yield SegmentRecord(
                segment_id=seg_id,
                dataset="porto",
                points=pts,
                source_ref="bull train/train(1).csv",
            )


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--data-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "data",
        help="Folder containing the three dataset directories",
    )
    ap.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "data" / "processed",
        help="Output directory for CSVs",
    )
    ap.add_argument("--geolife-limit", type=int, default=300, help="Max .plt files (None=all)")
    ap.add_argument("--tdrive-limit", type=int, default=400, help="Max taxi txt files (None=all)")
    ap.add_argument(
        "--tdrive-gap-min",
        type=int,
        default=30,
        help="Split T-drive segment when gap exceeds this many minutes",
    )
    ap.add_argument("--porto-max-rows", type=int, default=5000, help="Max CSV rows from Porto train")
    ap.add_argument("--no-geolife", action="store_true")
    ap.add_argument("--no-tdrive", action="store_true")
    ap.add_argument("--no-porto", action="store_true")
    ap.add_argument("--all-geolife", action="store_true", help="Process all Geolife plt (slow)")
    ap.add_argument("--all-tdrive", action="store_true", help="Process all T-drive files (slow)")
    args = ap.parse_args()

    data_root = args.data_root.resolve()
    out_dir = args.out.resolve()
    gap_s = args.tdrive_gap_min * 60

    glim = None if args.all_geolife else args.geolife_limit
    tlim = None if args.all_tdrive else args.tdrive_limit

    segments: List[SegmentRecord] = []
    if not args.no_geolife:
        segments.extend(iter_geolife(data_root, glim))
    if not args.no_tdrive:
        segments.extend(iter_tdrive(data_root, tlim, gap_s))
    if not args.no_porto:
        segments.extend(iter_porto(data_root, args.porto_max_rows))

    n_seg, n_pt = write_outputs(segments, out_dir)
    print(f"Wrote {n_seg} segments, {n_pt} points -> {out_dir}")
    print("  segments_points.csv")
    print("  segments_meta.csv")


if __name__ == "__main__":
    main()

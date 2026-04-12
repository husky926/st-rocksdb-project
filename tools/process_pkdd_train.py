#!/usr/bin/env python3
"""
Stream PKDD 15 / Porto taxi train.csv from train.csv.zip into segments_points.csv + segments_meta.csv
(same schema as process_trajectories.py for st_meta_smoke --csv --st-keys).

POLYLINE: [[lon,lat],...]; time at point i = TIMESTAMP + i * 15 (seconds), per competition definition.

Usage:
  python tools/process_pkdd_train.py --train-zip data/pkdd-15-.../_extract/train.csv.zip --out data/processed/pkdd
  python tools/process_pkdd_train.py --train-zip ... --max-rows 5000   # smoke test
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import zipfile
from pathlib import Path
from typing import Iterator, List, Optional, Tuple


def parse_polyline(
    timestamp_unix: int, polyline_json: str, interval_s: int = 15
) -> List[Tuple[float, float, float, int]]:
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


def iter_segments_from_zip(
    train_zip: Path,
    max_csv_rows: Optional[int],
    max_segments: Optional[int],
    skip_missing: bool,
) -> Iterator[Tuple[str, List[Tuple[float, float, float, int]], str]]:
    n_out = 0
    with zipfile.ZipFile(train_zip) as z:
        inner = "train.csv"
        if inner not in z.namelist():
            raise SystemExit(f"Expected {inner} in zip, got {z.namelist()}")
        with z.open(inner) as raw:
            text = io.TextIOWrapper(raw, encoding="utf-8", newline="")
            reader = csv.DictReader(text)
            for i, row in enumerate(reader):
                if max_csv_rows is not None and i >= max_csv_rows:
                    break
                if max_segments is not None and n_out >= max_segments:
                    break
                miss = (row.get("MISSING_DATA") or "").strip().strip('"').lower()
                if skip_missing and miss == "true":
                    continue
                trip = (row.get("TRIP_ID") or "").strip().strip('"')
                poly = (row.get("POLYLINE") or "").strip().strip('"')
                ts_raw = (row.get("TIMESTAMP") or "").strip().strip('"')
                if not trip or not poly or not ts_raw:
                    continue
                try:
                    ts_unix = int(ts_raw)
                except ValueError:
                    continue
                pts = parse_polyline(ts_unix, poly, interval_s=15)
                if len(pts) < 2:
                    continue
                seg_id = f"pkdd:{trip}"
                n_out += 1
                yield seg_id, pts, str(train_zip)


def write_outputs(
    segments: Iterator[Tuple[str, List[Tuple[float, float, float, int]], str]],
    out_dir: Path,
) -> Tuple[int, int, float, float, float, float, int, int]:
    out_dir.mkdir(parents=True, exist_ok=True)
    points_path = out_dir / "segments_points.csv"
    meta_path = out_dir / "segments_meta.csv"
    n_seg = 0
    n_pt = 0
    lon_min_g = float("inf")
    lon_max_g = float("-inf")
    lat_min_g = float("inf")
    lat_max_g = float("-inf")
    t_min_g: Optional[int] = None
    t_max_g: Optional[int] = None

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

        for seg_id, points, source_ref in segments:
            lons = [p[1] for p in points]
            lats = [p[0] for p in points]
            ts = [p[3] for p in points]
            lon_min_g = min(lon_min_g, min(lons))
            lon_max_g = max(lon_max_g, max(lons))
            lat_min_g = min(lat_min_g, min(lats))
            lat_max_g = max(lat_max_g, max(lats))
            t0, t1 = min(ts), max(ts)
            t_min_g = t0 if t_min_g is None else min(t_min_g, t0)
            t_max_g = t1 if t_max_g is None else max(t_max_g, t1)

            wm.writerow(
                [
                    seg_id,
                    "pkdd",
                    len(points),
                    t0,
                    t1,
                    min(lons),
                    max(lons),
                    min(lats),
                    max(lats),
                    source_ref,
                ]
            )
            for j, (lat, lon, _alt, t) in enumerate(points):
                wp.writerow(
                    [
                        seg_id,
                        "pkdd",
                        j,
                        t,
                        lon,
                        lat,
                        "0.000",
                        source_ref,
                    ]
                )
            n_seg += 1
            n_pt += len(points)

    return (
        n_seg,
        n_pt,
        lon_min_g,
        lon_max_g,
        lat_min_g,
        lat_max_g,
        t_min_g or 0,
        t_max_g or 0,
    )


def stats_only(train_zip: Path, max_rows: Optional[int], skip_missing: bool) -> None:
    n_rows = 0
    n_seg_ok = 0
    n_pts = 0
    n_skip_miss = 0
    n_skip_bad = 0
    lx0, lx1 = float("inf"), float("-inf")
    ly0, ly1 = float("inf"), float("-inf")
    t0g: Optional[int] = None
    t1g: Optional[int] = None
    with zipfile.ZipFile(train_zip) as z:
        with z.open("train.csv") as raw:
            text = io.TextIOWrapper(raw, encoding="utf-8", newline="")
            reader = csv.DictReader(text)
            for i, row in enumerate(reader):
                if max_rows is not None and i >= max_rows:
                    break
                n_rows += 1
                miss = (row.get("MISSING_DATA") or "").strip().strip('"').lower()
                if skip_missing and miss == "true":
                    n_skip_miss += 1
                    continue
                trip = (row.get("TRIP_ID") or "").strip().strip('"')
                poly = (row.get("POLYLINE") or "").strip().strip('"')
                ts_raw = (row.get("TIMESTAMP") or "").strip().strip('"')
                if not trip or not poly or not ts_raw:
                    n_skip_bad += 1
                    continue
                try:
                    ts_unix = int(ts_raw)
                except ValueError:
                    n_skip_bad += 1
                    continue
                pts = parse_polyline(ts_unix, poly, interval_s=15)
                if len(pts) < 2:
                    n_skip_bad += 1
                    continue
                n_seg_ok += 1
                for lat, lon, _a, t in pts:
                    lx0, lx1 = min(lx0, lon), max(lx1, lon)
                    ly0, ly1 = min(ly0, lat), max(ly1, lat)
                    t0g = t if t0g is None else min(t0g, t)
                    t1g = t if t1g is None else max(t1g, t)
                n_pts += len(pts)
    print(
        f"csv_rows_read={n_rows} skipped_missing_data={n_skip_miss} skipped_bad_polyline={n_skip_bad} "
        f"segments_kept={n_seg_ok} points_total={n_pts}"
    )
    if t0g is not None:
        print(f"lon [{lx0:.6f}, {lx1:.6f}]  lat [{ly0:.6f}, {ly1:.6f}]")
        print(f"unix_time_s [{t0g}, {t1g}]")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--train-zip",
        type=Path,
        default=Path(__file__).resolve().parent.parent
        / "data"
        / "pkdd-15-predict-taxi-service-trajectory-i"
        / "_extract"
        / "train.csv.zip",
    )
    ap.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "data" / "processed" / "pkdd",
    )
    ap.add_argument(
        "--max-csv-rows",
        type=int,
        default=None,
        help="Stop after reading this many CSV lines (includes skipped rows)",
    )
    ap.add_argument(
        "--max-segments",
        type=int,
        default=100_000,
        help="Max trajectory segments to write (default 100000; full ~1.67M segments / ~83M points)",
    )
    ap.add_argument(
        "--all-segments",
        action="store_true",
        help="Write every valid trip (huge disk/time; use only if you need full PKDD train)",
    )
    ap.add_argument(
        "--no-skip-missing",
        action="store_true",
        help="Include rows with MISSING_DATA True (usually empty polyline)",
    )
    ap.add_argument(
        "--stats-only",
        action="store_true",
        help="Scan zip and print counts/bbox only (no CSV output)",
    )
    args = ap.parse_args()

    train_zip = args.train_zip.resolve()
    if not train_zip.is_file():
        raise SystemExit(f"Not found: {train_zip}")

    skip_missing = not args.no_skip_missing
    if args.stats_only:
        stats_only(train_zip, args.max_csv_rows, skip_missing)
        return

    cap_seg = None if args.all_segments else args.max_segments
    segs = iter_segments_from_zip(
        train_zip,
        max_csv_rows=args.max_csv_rows,
        max_segments=cap_seg,
        skip_missing=skip_missing,
    )
    n_seg, n_pt, lx0, lx1, ly0, ly1, t0, t1 = write_outputs(segs, args.out.resolve())
    print(f"Wrote {n_seg} segments, {n_pt} points -> {args.out}")
    print(f"  lon [{lx0:.6f}, {lx1:.6f}]  lat [{ly0:.6f}, {ly1:.6f}]")
    print(f"  unix_time_s [{t0}, {t1}]")


if __name__ == "__main__":
    main()

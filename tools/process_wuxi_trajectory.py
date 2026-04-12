#!/usr/bin/env python3
"""
Process Wuxi zipped daily trajectory CSVs into segment-level CSVs.

Input directory contains files like:
  20200718.zip ... 20200817.zip
Each zip includes one CSV with rows:
  id,经度,纬度,采集时间,方向,速度,纵向加速度,横向加速度,垂直加速度,横摆角速度

Notes:
- Source rows contain a dirty tab before first comma (e.g. "id<TAB>,lon,...").
  We normalize by removing tabs before CSV parsing.
- `id` is vehicle id (not segment id). Segments are split by time gap.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import io
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


CHINA_TZ = dt.timezone(dt.timedelta(hours=8))


def parse_time_to_unix(s: str) -> Optional[int]:
    s = s.strip()
    if not s:
        return None
    try:
        t = dt.datetime.strptime(s, "%Y-%m-%d %H:%M:%S").replace(tzinfo=CHINA_TZ)
    except ValueError:
        return None
    return int(t.timestamp())


def iter_zip_csv_rows(zip_path: Path):
    with zipfile.ZipFile(zip_path) as zf:
        csv_names = [n for n in zf.namelist() if n.lower().endswith(".csv")]
        if not csv_names:
            return
        name = sorted(csv_names)[0]
        raw = zf.open(name)

        # Try decoding in a robust order.
        text: Optional[io.TextIOWrapper] = None
        for enc in ("utf-8", "gb18030", "gbk"):
            try:
                raw.seek(0)
                text = io.TextIOWrapper(raw, encoding=enc, newline="")
                # Probe first line.
                _ = text.readline()
                text.seek(0)
                break
            except Exception:
                text = None
                continue
        if text is None:
            raw.seek(0)
            text = io.TextIOWrapper(raw, encoding="utf-8", errors="replace", newline="")

        reader = csv.reader((line.replace("\t", "") for line in text))
        header_skipped = False
        for row in reader:
            if not header_skipped:
                header_skipped = True
                continue
            # Expected columns (by index): 0=id,1=lon,2=lat,3=time,...
            if len(row) < 4:
                continue
            yield row, name


@dataclass
class SegmentState:
    seg_idx: int
    point_idx: int
    t_start: int
    t_end: int
    lon_min: float
    lon_max: float
    lat_min: float
    lat_max: float
    point_count: int
    source_ref: str


def segment_id(vehicle_id: str, seg_idx: int) -> str:
    return f"wuxi:{vehicle_id}:{seg_idx:06d}"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--in-dir",
        type=Path,
        default=Path("data/无锡轨迹数据集"),
        help="Directory containing daily zip files.",
    )
    ap.add_argument(
        "--out",
        type=Path,
        default=Path("data/processed/wuxi"),
        help="Output directory for segments_points.csv and segments_meta.csv",
    )
    ap.add_argument(
        "--gap-seconds",
        type=int,
        default=300,
        help="Split a new segment when same vehicle time gap exceeds this value.",
    )
    ap.add_argument(
        "--max-files",
        type=int,
        default=-1,
        help="For smoke test: process at most N zip files (-1 means all).",
    )
    ap.add_argument(
        "--max-rows-per-file",
        type=int,
        default=-1,
        help="For smoke test: process at most N rows per zip (-1 means all).",
    )
    args = ap.parse_args()

    in_dir = args.in_dir
    out_dir = args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    points_path = out_dir / "segments_points.csv"
    meta_path = out_dir / "segments_meta.csv"

    zip_files = sorted(in_dir.glob("*.zip"))
    if args.max_files >= 0:
        zip_files = zip_files[: args.max_files]
    if not zip_files:
        raise SystemExit(f"No zip files found in {in_dir}")

    states: dict[str, SegmentState] = {}
    seg_counter: dict[str, int] = {}

    rows_in = 0
    rows_out = 0
    rows_bad = 0
    lon_min_g = float("inf")
    lon_max_g = float("-inf")
    lat_min_g = float("inf")
    lat_max_g = float("-inf")
    t_min_g: Optional[int] = None
    t_max_g: Optional[int] = None

    def flush_segment(vehicle_id: str, st: SegmentState, wm: csv.writer):
        wm.writerow(
            [
                segment_id(vehicle_id, st.seg_idx),
                "wuxi",
                st.point_count,
                st.t_start,
                st.t_end,
                st.lon_min,
                st.lon_max,
                st.lat_min,
                st.lat_max,
                st.source_ref,
            ]
        )

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

        for zf in zip_files:
            per_file_rows = 0
            for row, inner_name in iter_zip_csv_rows(zf):
                rows_in += 1
                per_file_rows += 1
                if args.max_rows_per_file >= 0 and per_file_rows > args.max_rows_per_file:
                    break

                vehicle_id = row[0].strip()
                try:
                    lon = float(row[1])
                    lat = float(row[2])
                except ValueError:
                    rows_bad += 1
                    continue
                t_unix = parse_time_to_unix(row[3])
                if not vehicle_id or t_unix is None:
                    rows_bad += 1
                    continue

                # Global extent
                lon_min_g = min(lon_min_g, lon)
                lon_max_g = max(lon_max_g, lon)
                lat_min_g = min(lat_min_g, lat)
                lat_max_g = max(lat_max_g, lat)
                t_min_g = t_unix if t_min_g is None else min(t_min_g, t_unix)
                t_max_g = t_unix if t_max_g is None else max(t_max_g, t_unix)

                st = states.get(vehicle_id)
                src = f"{zf.name}/{inner_name}"

                if st is None:
                    seg_idx = seg_counter.get(vehicle_id, -1) + 1
                    seg_counter[vehicle_id] = seg_idx
                    st = SegmentState(
                        seg_idx=seg_idx,
                        point_idx=0,
                        t_start=t_unix,
                        t_end=t_unix,
                        lon_min=lon,
                        lon_max=lon,
                        lat_min=lat,
                        lat_max=lat,
                        point_count=0,
                        source_ref=src,
                    )
                    states[vehicle_id] = st
                else:
                    # Split when temporal gap exceeds threshold or goes backward.
                    if t_unix < st.t_end or (t_unix - st.t_end) > args.gap_seconds:
                        flush_segment(vehicle_id, st, wm)
                        seg_idx = seg_counter.get(vehicle_id, -1) + 1
                        seg_counter[vehicle_id] = seg_idx
                        st = SegmentState(
                            seg_idx=seg_idx,
                            point_idx=0,
                            t_start=t_unix,
                            t_end=t_unix,
                            lon_min=lon,
                            lon_max=lon,
                            lat_min=lat,
                            lat_max=lat,
                            point_count=0,
                            source_ref=src,
                        )
                        states[vehicle_id] = st

                sid = segment_id(vehicle_id, st.seg_idx)
                wp.writerow(
                    [
                        sid,
                        "wuxi",
                        st.point_idx,
                        t_unix,
                        f"{lon:.7f}",
                        f"{lat:.7f}",
                        "0.000",
                        src,
                    ]
                )
                rows_out += 1

                st.point_idx += 1
                st.point_count += 1
                st.t_end = max(st.t_end, t_unix)
                st.lon_min = min(st.lon_min, lon)
                st.lon_max = max(st.lon_max, lon)
                st.lat_min = min(st.lat_min, lat)
                st.lat_max = max(st.lat_max, lat)

        # flush all open segments
        for vid in sorted(states.keys()):
            flush_segment(vid, states[vid], wm)

    n_vehicle = len(seg_counter)
    n_segment = sum(v + 1 for v in seg_counter.values())

    print(f"in_dir={in_dir}")
    print(f"processed_zip_files={len(zip_files)}")
    print(f"rows_in={rows_in} rows_out={rows_out} rows_bad={rows_bad}")
    print(f"vehicles={n_vehicle} segments={n_segment}")
    print(
        "extent:"
        f" lon=[{lon_min_g:.7f},{lon_max_g:.7f}]"
        f" lat=[{lat_min_g:.7f},{lat_max_g:.7f}]"
        f" unix=[{t_min_g},{t_max_g}]"
    )
    print(f"wrote_points={points_path}")
    print(f"wrote_meta={meta_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())


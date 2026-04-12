#!/usr/bin/env python3
"""Print *.sst file counts for default Wuxi segment DB paths (sanity vs folder names)."""

from __future__ import annotations

from pathlib import Path

DEFAULTS = [
    Path(r"D:/Project/data/verify_wuxi_segment_1sst"),
    Path(r"D:/Project/data/verify_wuxi_segment_164sst"),
    Path(r"D:/Project/data/verify_wuxi_segment_776sst"),
    Path(r"D:/Project/data/verify_wuxi_segment_736sst"),
]


def main() -> None:
    for p in DEFAULTS:
        n = len(list(p.glob("*.sst"))) if p.is_dir() else -1
        print(f"{n:4d}  {p}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""
Bar chart for st_meta_bench OFF vs ON (micros/op). Stdlib only -> SVG.
Usage:
  python plot_st_meta_bench.py
  python plot_st_meta_bench.py --fill-off 7.3 --fill-on 6.33 --read-off 3.28 --read-on 3.17 --out D:/Project/data/bench_st_meta/chart.svg
"""

from __future__ import annotations

import argparse
from pathlib import Path


def svg_escape(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def main() -> None:
    ap = argparse.ArgumentParser(description="Plot st_meta_bench OFF vs ON as SVG")
    ap.add_argument("--fill-off", type=float, default=7.29713)
    ap.add_argument("--fill-on", type=float, default=6.33231)
    ap.add_argument("--read-off", type=float, default=3.28264)
    ap.add_argument("--read-on", type=float, default=3.16654)
    ap.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).resolve().parent.parent / "data" / "bench_st_meta" / "st_meta_bench_chart.svg",
    )
    args = ap.parse_args()

    W, H = 720, 420
    ml, mr, mt, mb = 72, 40, 48, 100
    plot_w = W - ml - mr
    plot_h = H - mt - mb

    series = [
        ("Put + Flush (micros/op)", args.fill_off, args.fill_on),
        ("Random Get (micros/op)", args.read_off, args.read_on),
    ]
    ymax = max(args.fill_off, args.fill_on, args.read_off, args.read_on) * 1.15

    def yscale(v: float) -> float:
        return mt + plot_h * (1.0 - v / ymax)

    # two groups, each 2 bars
    group_w = plot_w / 2
    bar_w = group_w * 0.28
    gap = group_w * 0.08
    off_color = "#2563eb"
    on_color = "#16a34a"

    parts: list[str] = []
    parts.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">')
    parts.append('<rect width="100%" height="100%" fill="#fafafa"/>')
    parts.append(
        f'<text x="{W/2}" y="28" text-anchor="middle" font-size="16" font-family="Segoe UI, sans-serif" fill="#111">'
        f"{svg_escape('st_meta_bench: OFF vs ON (lower is better)')}</text>"
    )

    # Y axis
    y0 = yscale(0)
    parts.append(
        f'<line x1="{ml}" y1="{mt}" x2="{ml}" y2="{y0}" stroke="#333" stroke-width="1"/>'
    )
    parts.append(f'<line x1="{ml}" y1="{y0}" x2="{W-mr}" y2="{y0}" stroke="#333" stroke-width="1"/>')

    for tick in (0, ymax / 2, ymax):
        ty = yscale(tick)
        parts.append(
            f'<line x1="{ml-4}" y1="{ty}" x2="{ml}" y2="{ty}" stroke="#666" stroke-width="1"/>'
        )
        parts.append(
            f'<text x="{ml-8}" y="{ty+4}" text-anchor="end" font-size="11" font-family="Segoe UI, sans-serif" fill="#444">{tick:.2f}</text>'
        )

    for gi, (label, v_off, v_on) in enumerate(series):
        gx = ml + gi * group_w + group_w * 0.1
        h_off = yscale(0) - yscale(v_off)
        h_on = yscale(0) - yscale(v_on)
        x_off = gx
        x_on = gx + bar_w + gap
        yo = yscale(v_off)
        yn = yscale(v_on)
        parts.append(
            f'<rect x="{x_off}" y="{yo}" width="{bar_w}" height="{h_off}" fill="{off_color}" rx="3"/>'
        )
        parts.append(
            f'<rect x="{x_on}" y="{yn}" width="{bar_w}" height="{h_on}" fill="{on_color}" rx="3"/>'
        )
        parts.append(
            f'<text x="{gx + bar_w + gap/2}" y="{y0 + 22}" text-anchor="middle" font-size="12" font-family="Segoe UI, sans-serif" fill="#111">{svg_escape(label)}</text>'
        )
        parts.append(
            f'<text x="{x_off + bar_w/2}" y="{yo - 6}" text-anchor="middle" font-size="10" fill="#1e3a8a">{v_off:.3f}</text>'
        )
        parts.append(
            f'<text x="{x_on + bar_w/2}" y="{yn - 6}" text-anchor="middle" font-size="10" fill="#14532d">{v_on:.3f}</text>'
        )

    leg_y = H - 36
    parts.append(
        f'<rect x="{ml}" y="{leg_y}" width="14" height="14" fill="{off_color}"/>'
        f'<text x="{ml+20}" y="{leg_y+12}" font-size="12" font-family="Segoe UI, sans-serif">OFF (st-meta false)</text>'
    )
    parts.append(
        f'<rect x="{ml+200}" y="{leg_y}" width="14" height="14" fill="{on_color}"/>'
        f'<text x="{ml+220}" y="{leg_y+12}" font-size="12" font-family="Segoe UI, sans-serif">ON (st-meta true)</text>'
    )

    parts.append("</svg>")
    svg = "\n".join(parts)

    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(svg, encoding="utf-8")
    print(f"Wrote {args.out}")
    print("Open the file in a browser or Edge to view the chart.")


if __name__ == "__main__":
    main()

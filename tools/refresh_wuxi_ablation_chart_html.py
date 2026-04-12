#!/usr/bin/env python3
"""Regenerate SVG bar chart in docs/st_ablation_wuxi_1sst_vs_manysst.html from aggregate JSON."""

from __future__ import annotations

import argparse
import html
import json
import re
import sys
from pathlib import Path


MODES = [
    "Global (manifest)",
    "Local (sst)",
    "Local+Global (sst_manifest)",
]


def db_sort_key(path: str) -> tuple[int, str]:
    p = path.lower()
    if "segment_1sst" in p and "164" not in p:
        return (0, path)
    if "segment_164" in p:
        return (1, path)
    if "segment_776" in p or "segment_736" in p:
        return (2, path)
    return (9, path)


def fmt_speedup(x: float) -> str:
    if x >= 100:
        return f"{x:.0f}×"
    if x >= 10:
        return f"{x:.1f}×"
    if x >= 1:
        s = f"{x:.2f}".rstrip("0").rstrip(".")
        return f"{s}×"
    return f"{x:.2f}×"


def build_svg_body(agg: dict) -> str:
    dbs = sorted({db for m in MODES for db in agg.get(m, {})}, key=db_sort_key)
    if len(dbs) != 3:
        raise SystemExit(f"expected 3 db paths, got {len(dbs)}")

    clusters = [
        {
            "title": "1 SST",
            "title_x": 230,
            "title_fill": "#1e3a8a",
            "fill": "#2563eb",
            "label_fill": "#1e3a8a",
            "xs": [139, 187, 235, 283],
            "lx": [158, 206, 254, 302],
        },
        {
            "title": "164 SST",
            "title_x": 610,
            "title_fill": "#115e59",
            "fill": "#0d9488",
            "label_fill": "#115e59",
            "xs": [519, 567, 615, 663],
            "lx": [538, 586, 634, 682],
        },
        {
            "title": "736 SST",
            "title_x": 990,
            "title_fill": "#5b21b6",
            "fill": "#7c3aed",
            "label_fill": "#5b21b6",
            "xs": [899, 947, 995, 1043],
            "lx": [918, 966, 1014, 1062],
        },
    ]

    parts: list[str] = []
    y_axis = """    <line x1="72" y1="52" x2="72" y2="302" stroke="#64748b" stroke-width="1.5"/>
    <text x="38" y="178" font-size="11" fill="#64748b" text-anchor="middle" transform="rotate(-90 38 178)">簇内相对高度</text>
    <g font-size="10" fill="#64748b" text-anchor="end">
      <line x1="68" y1="302" x2="1220" y2="302" stroke="#e2e8f0" stroke-width="1"/>
      <text x="64" y="306">0</text>
      <line x1="72" y1="252" x2="1220" y2="252" stroke="#f1f5f9" stroke-width="1"/>
      <text x="64" y="256">0.2</text>
      <line x1="72" y1="202" x2="1220" y2="202" stroke="#f1f5f9" stroke-width="1"/>
      <text x="64" y="206">0.4</text>
      <line x1="72" y1="152" x2="1220" y2="152" stroke="#f1f5f9" stroke-width="1"/>
      <text x="64" y="156">0.6</text>
      <line x1="72" y1="102" x2="1220" y2="102" stroke="#f1f5f9" stroke-width="1"/>
      <text x="64" y="106">0.8</text>
      <line x1="72" y1="52" x2="1220" y2="52" stroke="#f1f5f9" stroke-width="1"/>
      <text x="64" y="56">1.0</text>
    </g>
    <line x1="72" y1="302" x2="1180" y2="302" stroke="#94a3b8" stroke-width="2"/>"""

    parts.append(y_axis)
    parts.append(
        '    <g transform="translate(48, 0)" font-family="Segoe UI, Microsoft YaHei, sans-serif">'
    )

    for ci, db in enumerate(dbs):
        c = clusters[ci]
        ratios = [
            1.0,
            float(agg[MODES[0]][db]["speedup_mean"]),
            float(agg[MODES[1]][db]["speedup_mean"]),
            float(agg[MODES[2]][db]["speedup_mean"]),
        ]
        vmax = max(ratios)
        comment = f"<!-- {c['title']} vmax={vmax:.6f} mean over runs -->"
        parts.append(f"      {comment}")
        parts.append(
            f'      <text x="{c["title_x"]}" y="36" text-anchor="middle" '
            f'font-size="12" fill="{c["title_fill"]}" font-weight="600">{c["title"]}</text>'
        )
        parts.append('      <g font-size="9" fill="#475569">')
        for lx, lab in zip(
            c["lx"], ["Base", "Global", "Local", "L+G"], strict=True
        ):
            parts.append(
                f'        <text x="{lx}" y="318" text-anchor="middle">{lab}</text>'
            )
        parts.append("      </g>")

        hs = [250.0 * r / vmax for r in ratios]
        if hs[0] < 8.0:
            hs[0] = 8.0
        for xi, (x0, r, h) in enumerate(
            zip(c["xs"], ratios, hs, strict=True), start=1
        ):
            y = 302.0 - h
            fs = 10 if h > 120 else (9 if h > 40 else 8)
            ty = y - 6
            parts.append(
                f'      <rect x="{x0}" y="{y:.2f}" width="38" height="{h:.2f}" '
                f'fill="{c["fill"]}" stroke="#fff" stroke-width="1"/>'
            )
            parts.append(
                f'      <text x="{x0 + 19}" y="{ty:.0f}" font-size="{fs}" '
                f'text-anchor="middle" fill="{c["label_fill"]}">{fmt_speedup(r)}</text>'
            )

    parts.append("    </g>")
    return "\n".join(parts)


def _vanilla_ui_mode(payload: dict) -> str:
    """cache | live | fork_full — controls chart copy and QPS column titles."""
    rm = payload.get("run_meta") or {}
    if (rm.get("vanilla_wall_cache_json") or "").strip():
        return "cache"
    cb = str(payload.get("compare_baseline", "")).strip().lower()
    rcb = str(rm.get("compare_baseline", "") or "").strip().lower()
    if cb == "vanilla" or rcb == "vanilla":
        return "live"
    return "fork_full"


def _qps_column_titles(vanilla_mode: str) -> tuple[str, str, str]:
    if vanilla_mode in ("cache", "live"):
        return (
            "QPS Vanilla → prune (1 SST)",
            "QPS Vanilla → prune (164 SST)",
            "QPS Vanilla → prune (736 SST)",
        )
    return (
        "QPS baseline → prune (1 SST)",
        "QPS baseline → prune (164 SST)",
        "QPS baseline → prune (736 SST)",
    )


def build_summary_table_html(
    agg: dict,
    mode_kv: dict[str, str],
    n_runs: int,
    min_full_keys: int,
    vanilla_mode: str,
) -> str:
    dbs = sorted({db for m in MODES for db in agg.get(m, {})}, key=db_sort_key)
    q1, q2, q3 = _qps_column_titles(vanilla_mode)
    rows = ""
    for mlabel in MODES:
        label = mlabel.split("(")[0].strip()
        rows += "<tr><td>{}</td>".format(label)
        for db in dbs:
            a = agg.get(mlabel, {}).get(db)
            if not a:
                rows += "<td>—</td>"
                continue
            sm = float(a["speedup_mean"])
            rows += (
                f"<td>{sm:.3f}×</td>" if sm < 100 else f"<td>{sm:.2f}×</td>"
            )
        for db in dbs:
            a = agg.get(mlabel, {}).get(db)
            if not a:
                rows += "<td>—</td>"
                continue
            qf = float(a["qps_full_mean"])
            qp = float(a["qps_prune_mean"])
            rows += f"<td>{qf:.2f} → {qp:.2f}</td>"
        rows += f"<td>{mode_kv.get(mlabel, '—')}</td></tr>\n"

    if vanilla_mode == "cache":
        blurb = "<strong>Vanilla 基线</strong>（每窗 <strong>10 次</strong>中位，见缓存 JSON）"
    elif vanilla_mode == "live":
        blurb = "<strong>Vanilla 基线</strong>（上游 RocksDB 逐窗实测，见各 run TSV 中 <code>vanilla_wall_us</code>）"
    else:
        blurb = "<strong>fork full 基线</strong>（聚合使用 <code>--baseline fork_full</code>）"
    return (
        f'<p class="sub"><strong>汇总表</strong>：以下为 <strong>{n_runs} 次</strong>消融重复的算术平均 '
        f'（<code>full_keys≥{min_full_keys}</code>）；倍率分母为 {blurb}；准确性列为各模式下 verify_kv 汇总。</p>\n'
        '<table class="sumtbl">\n<thead><tr>'
        "<th>模式</th><th>speedup (1 SST)</th><th>speedup (164 SST)</th><th>speedup (736 SST)</th>"
        f"<th>{html.escape(q1)}</th><th>{html.escape(q2)}</th>"
        f"<th>{html.escape(q3)}</th><th>准确性</th></tr></thead>\n<tbody>\n"
        f"{rows}</tbody></table>\n"
    )


def build_lede_block(payload: dict) -> str:
    n = int(payload.get("n_runs", 0))
    min_k = int(payload.get("min_full_keys", 50))
    runs = payload.get("run_dirs") or []
    first = str(runs[0]).replace("\\", "/") if runs else ""
    rm = payload.get("run_meta") or {}
    vcache = (rm.get("vanilla_wall_cache_json") or "").strip()
    vmode = _vanilla_ui_mode(payload)
    parent = ""
    if runs:
        try:
            parent = str(Path(runs[0]).resolve().parent).replace("\\", "/")
        except OSError:
            parent = str(Path(runs[0]).parent).replace("\\", "/")

    if vmode == "cache" and vcache:
        vname = html.escape(Path(vcache).name)
        metric = (
            "<code>sum(vanilla_wall_us) / sum(prune_wall_us)</code>，其中 "
            "<strong>vanilla_wall_us</strong> 来自上游<strong>无改动的 Vanilla RocksDB</strong>，"
            "并对每 (库×窗) 预先测量 <strong>10 次</strong>取<strong>中位数</strong>写入缓存 "
            f"<code>{vname}</code>（路径见各 run 下 <code>wuxi_ablation_run_meta.json</code>）。"
        )
    elif vmode == "live":
        metric = (
            "<code>sum(vanilla_wall_us) / sum(prune_wall_us)</code>，其中 "
            "<strong>vanilla_wall_us</strong> 为上游<strong>无改动的 Vanilla RocksDB</strong> "
            "在同一查询窗下的壁钟（由各 run 的 sweep 写入 TSV，通常为逐窗调用 "
            "<code>st_segment_window_scan_vanilla.exe</code>）。"
        )
    else:
        metric = (
            "<code>sum(full_wall_us) / sum(prune_wall_us)</code>（fork 全量扫窗基线；"
            "聚合使用 <code>--baseline fork_full</code>）。"
        )

    p1 = (
        f'<p class="sub"><strong>指标</strong>：{metric}'
        f"每库 12 个 cov 窗（<code>full_keys≥{min_k}</code>）先按窗求和再相除。"
        f"<strong>Base</strong> 为 <strong>1.0×</strong>；其余柱为 Global / Local / L+G 的<strong>算术平均倍率</strong>"
        f"（<strong>{n} 次</strong>消融独立重复，每次均带 <code>-VerifyKVResults</code>）。"
        f"原始 TSV：<code>{html.escape(first)}</code> …；汇总：<code>aggregate.json</code>"
        f"{('（<code>' + html.escape(parent) + '</code>）') if parent else ''}。"
        f"多 SST 档为 776 目录缺失时的 <strong>736sst</strong> 回退。</p>"
    )
    p2 = (
        '<p class="sub"><strong>柱高</strong>：每簇按该簇四柱<strong>最大倍率</strong>归一化；'
        "柱顶标签为平均倍率。1 SST 上 Global 相对 Base 可略低于或略高于 1×（取决于重复与噪声）。"
        "736 簇 Base 柱设<strong>最小可视高度</strong>，数值仍以标签为准。</p>"
    )
    return f"{p1}\n  {p2}"


def mode_kv_from_payload(payload: dict) -> dict[str, str]:
    mk = payload.get("mode_kv")
    if isinstance(mk, dict):
        return {str(k): str(v) for k, v in mk.items()}
    return {}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("aggregate_json", type=Path)
    ap.add_argument("html_out", type=Path, nargs="?", default=None)
    args = ap.parse_args()
    html_out = args.html_out or Path("docs/st_ablation_wuxi_1sst_vs_manysst.html")
    data = json.loads(args.aggregate_json.read_text(encoding="utf-8"))
    agg = data["aggregate"]
    body = build_svg_body(agg)
    mode_kv = mode_kv_from_payload(data)
    if not mode_kv:
        dbs0 = sorted({db for m in MODES for db in agg.get(m, {})}, key=db_sort_key)
        db0 = dbs0[0] if dbs0 else ""
        for mlabel in MODES:
            mode_kv[mlabel] = str(agg.get(mlabel, {}).get(db0, {}).get("kv_note", "—"))
    vmode = _vanilla_ui_mode(data)
    table_html = build_summary_table_html(
        agg,
        mode_kv,
        int(data["n_runs"]),
        int(data.get("min_full_keys", 50)),
        vmode,
    )
    lede_html = build_lede_block(data)

    html = html_out.read_text(encoding="utf-8")

    lede_start = "<!-- WUXI_ABLATION_LEDE -->"
    lede_end = "<!-- /WUXI_ABLATION_LEDE -->"
    lede_block = f"{lede_start}\n  {lede_html}\n  {lede_end}"
    if lede_start in html and lede_end in html:
        # Use callable repl: lede_block may contain Windows paths; backslashes must not be
        # interpreted as re replacement escapes (e.g. \\P in D:\\Project).
        html, nle = re.subn(
            rf"{re.escape(lede_start)}[\s\S]*?{re.escape(lede_end)}",
            lambda _m: lede_block,
            html,
            count=1,
        )
        if nle != 1:
            print("LEDE replace failed", file=sys.stderr)
            return 1
    else:
        print(
            "Warning: WUXI_ABLATION_LEDE markers missing; skipping lede refresh",
            file=sys.stderr,
        )

    new_svg = (
        '<svg viewBox="0 0 1240 400" xmlns="http://www.w3.org/2000/svg">\n'
        f"{body}\n  </svg>"
    )
    html2, n = re.subn(
        r"<svg viewBox=\"0 0 1240 400\"[\s\S]*?</svg>",
        new_svg,
        html,
        count=1,
    )
    if n != 1:
        print("SVG replace failed", file=sys.stderr)
        return 1

    # Replace or insert summary table block
    marker_start = "<!-- WUXI_ABLATION_SUMMARY_TABLE -->"
    marker_end = "<!-- /WUXI_ABLATION_SUMMARY_TABLE -->"
    block = f"{marker_start}\n{table_html}{marker_end}"
    if marker_start in html2 and marker_end in html2:
        html2 = re.sub(
            rf"{re.escape(marker_start)}[\s\S]*?{re.escape(marker_end)}",
            block,
            html2,
            count=1,
        )
    else:
        needle = "  </svg>\n\n  <div class=\"legend\""
        if needle not in html2:
            print("Could not find insertion point before legend", file=sys.stderr)
            return 1
        html2 = html2.replace(needle, f"  </svg>\n\n  {block}\n\n  <div class=\"legend\"", 1)

    html_out.write_text(html2, encoding="utf-8")
    print(f"Updated {html_out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

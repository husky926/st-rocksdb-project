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
    if "segment_776" in p or "segment_736" in p or "bucket3600" in p:
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


def count_live_sst(db_path: str) -> int | None:
    """Count ``*.sst`` under fork DB path (same as audit / verify script)."""
    try:
        p = Path(db_path)
        if not p.is_dir():
            return None
        return sum(1 for _ in p.glob("*.sst"))
    except OSError:
        return None


def _is_second_tier_164_layout_db(db: str) -> bool:
    """Middle ablation tier: multi-SST via flush-every-500 (doc ~164 files)."""
    low = db.replace("\\", "/").lower()
    return "segment_164" in low or "segment_manysst" in low


def tier_column_labels(agg: dict, payload: dict) -> tuple[str, str, str]:
    """Labels for chart/table: 1st & 3rd use live ``*.sst`` count; 2nd is nominal **164 SST**."""
    tcl = payload.get("tier_column_labels")
    if isinstance(tcl, list) and len(tcl) == 3:
        return (str(tcl[0]), str(tcl[1]), str(tcl[2]))
    dbs = sorted({db for m in MODES for db in agg.get(m, {})}, key=db_sort_key)
    if len(dbs) != 3:
        raise SystemExit(f"expected 3 db paths, got {len(dbs)}")
    rm = payload.get("run_meta") or {}
    meta_third = rm.get("third_tier_live_sst_count")
    out: list[str] = []
    for i, db in enumerate(dbs):
        if _is_second_tier_164_layout_db(db):
            out.append("164 SST")
            continue
        n = count_live_sst(db)
        if n is not None:
            out.append(f"{n} SST")
        elif i == 2 and isinstance(meta_third, int) and meta_third > 0:
            out.append(f"{meta_third} SST")
        else:
            out.append("? SST")
    return (out[0], out[1], out[2])


def build_svg_body(agg: dict, *, cluster_titles: tuple[str, str, str]) -> str:
    dbs = sorted({db for m in MODES for db in agg.get(m, {})}, key=db_sort_key)
    if len(dbs) != 3:
        raise SystemExit(f"expected 3 db paths, got {len(dbs)}")

    clusters = [
        {
            "title": cluster_titles[0],
            "title_x": 230,
            "title_fill": "#1e3a8a",
            "fill": "#2563eb",
            "label_fill": "#1e3a8a",
            "xs": [139, 187, 235, 283],
            "lx": [158, 206, 254, 302],
        },
        {
            "title": cluster_titles[1],
            "title_x": 610,
            "title_fill": "#115e59",
            "fill": "#0d9488",
            "label_fill": "#115e59",
            "xs": [519, 567, 615, 663],
            "lx": [538, 586, 634, 682],
        },
        {
            "title": cluster_titles[2],
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


def _vanilla_cache_repeat_count(payload: dict) -> int | None:
    """Read repeat_count from vanilla wall cache JSON referenced by run_meta, if any."""
    rm = payload.get("run_meta") or {}
    p = (rm.get("vanilla_wall_cache_json") or "").strip()
    if not p:
        return None
    try:
        j = json.loads(Path(p).read_text(encoding="utf-8-sig"))
        rc = j.get("repeat_count")
        if isinstance(rc, int) and rc > 0:
            return rc
    except (OSError, json.JSONDecodeError, TypeError):
        return None
    return None


def _windows_12_blurb(rm: dict, min_k: int) -> str:
    """Describe the 12 windows from run_meta windows_csv path."""
    wcsv = str(rm.get("windows_csv") or "").strip()
    name = Path(wcsv).name if wcsv else ""
    esc = html.escape(name) if name else "（见 run_meta）"
    low = wcsv.lower()
    if "stratified12" in low:
        return (
            f"每库 12 个<strong>分层</strong>窗（<code>{esc}</code>；"
            f"<code>full_keys≥{min_k}</code>）"
        )
    if "random12_cov" in low or ("random12" in low and "cov" in low):
        return (
            f"每库 12 个 cov 窗（<code>{esc}</code>；<code>full_keys≥{min_k}</code>）"
        )
    return f"每库 12 个实验窗（<code>{esc}</code>；<code>full_keys≥{min_k}</code>）"


def _ablation_verify_blurb(payload: dict, n_runs: int) -> str:
    mk = payload.get("mode_kv")
    if isinstance(mk, dict) and mk:
        vals = [str(v) for v in mk.values()]
        if all("未验证" in v for v in vals):
            return (
                f"（<strong>{n_runs} 次</strong>消融；本次为 <strong>VanillaAsBaseline</strong>，"
                "<code>-VerifyKVResults</code> 未做 fork full↔prune 对拍，准确性列为未验证）。"
            )
    return (
        f"（<strong>{n_runs} 次</strong>消融独立重复，每次均带 <code>-VerifyKVResults</code>）。"
    )


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


def _qps_column_titles(
    vanilla_mode: str, col_labels: tuple[str, str, str]
) -> tuple[str, str, str]:
    a, b, c = col_labels
    if vanilla_mode in ("cache", "live"):
        return (
            f"QPS Vanilla → prune ({a})",
            f"QPS Vanilla → prune ({b})",
            f"QPS Vanilla → prune ({c})",
        )
    return (
        f"QPS baseline → prune ({a})",
        f"QPS baseline → prune ({b})",
        f"QPS baseline → prune ({c})",
    )


def build_summary_table_html(
    agg: dict,
    mode_kv: dict[str, str],
    n_runs: int,
    min_full_keys: int,
    vanilla_mode: str,
    vanilla_repeat_count: int | None = None,
    *,
    col_labels: tuple[str, str, str] = ("1 SST", "? SST", "? SST"),
) -> str:
    dbs = sorted({db for m in MODES for db in agg.get(m, {})}, key=db_sort_key)
    q1, q2, q3 = _qps_column_titles(vanilla_mode, col_labels)
    c1, c2, c3 = col_labels
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
        rc = vanilla_repeat_count if vanilla_repeat_count is not None else 10
        blurb = (
            f"<strong>Vanilla 基线</strong>（每窗 <strong>{rc} 次</strong>中位，见缓存 JSON）"
        )
    elif vanilla_mode == "live":
        blurb = "<strong>Vanilla 基线</strong>（上游 RocksDB 逐窗实测，见各 run TSV 中 <code>vanilla_wall_us</code>）"
    else:
        blurb = "<strong>fork full 基线</strong>（聚合使用 <code>--baseline fork_full</code>）"
    return (
        f'<p class="sub"><strong>汇总表</strong>：以下为 <strong>{n_runs} 次</strong>消融重复的算术平均 '
        f'（<code>full_keys≥{min_full_keys}</code>）；倍率分母为 {blurb}；准确性列为各模式下 verify_kv 汇总。</p>\n'
        '<table class="sumtbl">\n<thead><tr>'
        f"<th>模式</th><th>speedup ({html.escape(c1)})</th>"
        f"<th>speedup ({html.escape(c2)})</th>"
        f"<th>speedup ({html.escape(c3)})</th>"
        f"<th>{html.escape(q1)}</th><th>{html.escape(q2)}</th>"
        f"<th>{html.escape(q3)}</th><th>准确性</th></tr></thead>\n<tbody>\n"
        f"{rows}</tbody></table>\n"
    )


def build_h1_html(col_labels: tuple[str, str, str]) -> str:
    a, b, c = (html.escape(x) for x in col_labels)
    return (
        f"<h1>无锡消融：bench 验证 12 窗 × 三档 fork 库（{a} / {b} / {c}）。"
        f"第一档与第三档标题中的数字为对应目录 live <code>*.sst</code> 实测个数；"
        f"第二档 <strong>{b}</strong> 为实验约定档名（<code>verify_wuxi_segment_164sst</code>，"
        f"见 <code>EXPERIMENTS_AND_SCRIPTS.md</code> §2.1）。</h1>"
    )


def build_legend_html(col_labels: tuple[str, str, str]) -> str:
    a, b, c = (html.escape(x) for x in col_labels)
    return (
        '  <div class="legend" aria-label="图例">\n'
        f'    <span><span class="sw" style="background:#2563eb"></span> {a}'
        "（四柱同色：Base → Global → Local → L+G）</span>\n"
        f'    <span><span class="sw" style="background:#0d9488"></span> {b}'
        "（<code>verify_wuxi_segment_164sst</code>，<code>st_meta_smoke --flush-every 500</code>；"
        "文档期望约 164 个 live SST，compact 后目录内 <code>*.sst</code> 可能增多，表述仍以 <strong>164 档</strong>为准）</span>\n"
        f'    <span><span class="sw" style="background:#7c3aed"></span> {c}'
        "（<code>verify_wuxi_segment_bucket3600_sst</code>：<strong>3600s</strong> 事件时间分桶）</span>\n"
        "  </div>"
    )


def build_lede_block(payload: dict, col_labels: tuple[str, str, str]) -> str:
    n = int(payload.get("n_runs", 0))
    min_k = int(payload.get("min_full_keys", 50))
    runs = payload.get("run_dirs") or []
    first = str(runs[0]).replace("\\", "/") if runs else ""
    rm = payload.get("run_meta") or {}
    vcache = (rm.get("vanilla_wall_cache_json") or "").strip()
    vmode = _vanilla_ui_mode(payload)
    v_repeat = _vanilla_cache_repeat_count(payload)
    parent = ""
    if runs:
        try:
            parent = str(Path(runs[0]).resolve().parent).replace("\\", "/")
        except OSError:
            parent = str(Path(runs[0]).parent).replace("\\", "/")

    if vmode == "cache" and vcache:
        vname = html.escape(Path(vcache).name)
        rc_txt = str(v_repeat) if v_repeat is not None else "10"
        metric = (
            "<code>sum(vanilla_wall_us) / sum(prune_wall_us)</code>，其中 "
            "<strong>vanilla_wall_us</strong> 来自上游<strong>无改动的 Vanilla RocksDB</strong>，"
            f"并对每 (库×窗) 预先测量 <strong>{rc_txt} 次</strong>取<strong>中位数</strong>写入缓存 "
            f"<code>{vname}</code>（路径见各 run 下 <code>wuxi_ablation_run_meta.json</code>；"
            "缓存内亦有 <code>repeat_count</code>）。"
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

    win_blurb = _windows_12_blurb(rm if isinstance(rm, dict) else {}, min_k)
    verify_blurb = _ablation_verify_blurb(payload, n)
    if n == 1 and first:
        agg_ref = f"；汇总：<code>{html.escape(first.rstrip('/') + '/aggregate.json')}</code>"
    else:
        agg_ref = (
            f"；汇总：<code>aggregate.json</code>"
            f"{('（<code>' + html.escape(parent) + '</code>）') if parent else ''}"
        )
    c1, c2, c3 = (html.escape(x) for x in col_labels)
    p1 = (
        f'<p class="sub"><strong>指标</strong>：{metric}'
        f"{win_blurb}先按窗求和再相除。"
        f"<strong>Base</strong> 为 <strong>1.0×</strong>；其余柱为 Global / Local / L+G 的<strong>算术平均倍率</strong>"
        f"{verify_blurb}"
        f"原始 TSV：<code>{html.escape(first)}</code> …{agg_ref}。"
        f"三档 fork 路径见各 run 的 <code>wuxi_ablation_run_meta.json</code>；"
        f"柱簇标题与表头：<strong>{c1}</strong>、<strong>{c3}</strong> 为对应目录 live <code>*.sst</code> 实测个数；"
        f"<strong>{c2}</strong> 指 <code>verify_wuxi_segment_164sst</code>（<code>st_meta_smoke --flush-every 500</code>），"
        f"文档期望约 164 个 live SST，若经 compact 后目录内文件更多，图表与正文仍按约定称为 <strong>164 档</strong>。"
        f"第三档按 <strong>3600s</strong> 时间桶灌库（<code>verify_wuxi_segment_bucket3600_sst</code>；"
        f"历史名 <code>776sst</code>/<code>736sst</code> 仅为兼容；<strong>{c3}</strong> 中数字为实测 <code>N</code>）。</p>"
    )
    p2 = (
        '<p class="sub"><strong>柱高</strong>：每簇按该簇四柱<strong>最大倍率</strong>归一化；'
        f"柱顶标签为平均倍率。第一档（{c1}）上 Global 相对 Base 可略低于或略高于 1×（取决于重复与噪声）。"
        f"第三档（{c3}）簇 Base 柱设<strong>最小可视高度</strong>，数值仍以标签为准。</p>"
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
    col_labels = tier_column_labels(agg, data)
    body = build_svg_body(agg, cluster_titles=col_labels)
    mode_kv = mode_kv_from_payload(data)
    if not mode_kv:
        dbs0 = sorted({db for m in MODES for db in agg.get(m, {})}, key=db_sort_key)
        db0 = dbs0[0] if dbs0 else ""
        for mlabel in MODES:
            mode_kv[mlabel] = str(agg.get(mlabel, {}).get(db0, {}).get("kv_note", "—"))
    vmode = _vanilla_ui_mode(data)
    v_repeat = _vanilla_cache_repeat_count(data)
    table_html = build_summary_table_html(
        agg,
        mode_kv,
        int(data["n_runs"]),
        int(data.get("min_full_keys", 50)),
        vmode,
        vanilla_repeat_count=v_repeat,
        col_labels=col_labels,
    )
    lede_html = build_lede_block(data, col_labels)
    h1_html = build_h1_html(col_labels)
    legend_html = build_legend_html(col_labels)

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

    h1_start = "<!-- WUXI_ABLATION_H1 -->"
    h1_end = "<!-- /WUXI_ABLATION_H1 -->"
    h1_block = f"{h1_start}\n  {h1_html}\n  {h1_end}"
    if h1_start in html and h1_end in html:
        html, nh1 = re.subn(
            rf"{re.escape(h1_start)}[\s\S]*?{re.escape(h1_end)}",
            lambda _m: h1_block,
            html,
            count=1,
        )
        if nh1 != 1:
            print("H1 replace failed", file=sys.stderr)
            return 1
    else:
        print("Warning: WUXI_ABLATION_H1 markers missing; skipping h1 refresh", file=sys.stderr)

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

    leg_start = "<!-- WUXI_ABLATION_LEGEND -->"
    leg_end = "<!-- /WUXI_ABLATION_LEGEND -->"
    leg_block = f"{leg_start}\n{legend_html}\n  {leg_end}"
    if leg_start in html2 and leg_end in html2:
        html2, nleg = re.subn(
            rf"{re.escape(leg_start)}[\s\S]*?{re.escape(leg_end)}",
            lambda _m: leg_block,
            html2,
            count=1,
        )
        if nleg != 1:
            print("LEGEND replace failed", file=sys.stderr)
            return 1
    else:
        print(
            "Warning: WUXI_ABLATION_LEGEND markers missing; skipping legend refresh",
            file=sys.stderr,
        )

    html_out.write_text(html2, encoding="utf-8")
    print(f"Updated {html_out}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

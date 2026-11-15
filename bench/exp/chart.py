#!/usr/bin/env python3
"""把 bench.sh 产出的 results-<mode>.csv 画成 PNG：左柱状=达成 RPS，右折线=p99。"""
import argparse
import csv
import os

from PIL import Image, ImageDraw, ImageFont

# 必须能显示中文，否则图上全是方块；CI 里先 apt 装 fonts-noto-cjk
FONT_CANDIDATES = [
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
    r"C:\Windows\Fonts\msyh.ttc",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
]
C_FT = (47, 126, 216)
C_FRP = (217, 83, 79)
FG = (32, 32, 32)
GRAY = (120, 120, 120)
LIGHT = (228, 228, 228)


def load_font(size, bold=False):
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                continue
    return ImageFont.load_default()


def read(path):
    with open(path, newline="", encoding="utf-8") as fh:
        rows = [r for r in csv.DictReader(fh) if r.get("AchievedRps")]
    series = {}
    for row in rows:
        series.setdefault(row["Framework"], []).append(
            (int(row["TargetRps"]), float(row["AchievedRps"]), float(row["P99"]))
        )
    for key in series:
        series[key].sort()
    return series


def draw(csv_path, out_path, mode, levels):
    series = read(csv_path)
    frameworks = [f for f in ("ft", "frp") if f in series] or list(series)
    colors = {frameworks[0]: C_FT}
    if len(frameworks) > 1:
        colors[frameworks[1]] = C_FRP

    width, height = 1000, 620
    img = Image.new("RGB", (width, height), "white")
    d = ImageDraw.Draw(img)
    f_title, f_lbl, f_val, f_note = load_font(24, True), load_font(13), load_font(12, True), load_font(12)

    d.text((40, 24), f"FastTunnel vs frp · {mode.upper()} 模式", font=f_title, fill=FG)
    d.text((40, 58), f"目标档位 {levels} RPS  ·  128 并发  ·  每档先预热 10s 再测量 10s", font=f_note, fill=GRAY)

    left, right = 90, width - 40
    targets = sorted({t for rows in series.values() for (t, _, _) in rows})
    max_rps = max(1.0, max(a for rows in series.values() for (_, a, _) in rows)) * 1.18

    # ---- 上：柱状 ----
    top, bottom = 105, 360
    d.text((40, 80), "吞吐：达成 RPS（每秒请求数）→ 柱越高越好", font=f_lbl, fill=FG)
    for frac in range(0, 5):
        y = bottom - (bottom - top) * frac / 4
        d.line([(left, y), (right, y)], fill=LIGHT)
        d.text((left - 8, y - 7), f"{int(max_rps * frac / 4 / 1000)}k", font=f_lbl, fill=GRAY, anchor="ra")

    group = (right - left) / max(1, len(targets))
    bar = group * 0.28
    for i, target in enumerate(targets):
        cx = left + group * (i + 0.5)
        for j, fw in enumerate(frameworks):
            hit = [a for (t, a, _) in series[fw] if t == target]
            if not hit:
                continue
            value = hit[0]
            x0 = cx - bar - 3 + j * (bar + 6)
            y0 = bottom - (bottom - top) * value / max_rps
            d.rectangle([x0, y0, x0 + bar, bottom], fill=colors[fw])
            d.text(((x0 + x0 + bar) / 2, y0 - 17), f"{value/1000:.1f}k", font=f_val, fill=colors[fw], anchor="ma")
        d.text((cx, bottom + 6), f"{target//1000}k", font=f_lbl, fill=GRAY, anchor="ma")

    # ---- 下：p99 ----
    top2, bottom2 = 430, 560
    d.text((40, 402), "延迟：p99，单位毫秒（99% 的请求快于此值）→ 线越低越好", font=f_lbl, fill=FG)
    max_p99 = max(1.0, max(p for rows in series.values() for (_, _, p) in rows)) * 1.25
    for frac in range(0, 5):
        y = bottom2 - (bottom2 - top2) * frac / 4
        d.line([(left, y), (right, y)], fill=LIGHT)
        d.text((left - 8, y - 7), f"{max_p99 * frac / 4:.0f}", font=f_lbl, fill=GRAY, anchor="ra")

    for fw in frameworks:
        pts = []
        for i, target in enumerate(targets):
            hit = [p for (t, _, p) in series[fw] if t == target]
            if not hit:
                continue
            pts.append((left + group * (i + 0.5), bottom2 - (bottom2 - top2) * hit[0] / max_p99))
        if len(pts) > 1:
            d.line(pts, fill=colors[fw], width=3)
        for x, y in pts:
            d.ellipse([x - 4, y - 4, x + 4, y + 4], fill=colors[fw])

    # 图例
    lx = right - 210
    for idx, fw in enumerate(frameworks):
        y = 88 + idx * 18
        d.rectangle([lx, y, lx + 12, y + 12], fill=colors[fw])
        d.text((lx + 18, y - 2), fw, font=f_lbl, fill=FG)

    # ---- 底注：谁先掉队 ----
    notes = []
    for fw in frameworks:
        hit = series[fw]
        target = hit[-1][0]
        achieved = hit[-1][1]
        if achieved < target * 0.95:
            notes.append(f"{fw}: {target//1000}k 档只跑到 {achieved/1000:.1f}k（掉队）")
    footer = ("RPS = 每秒完成的请求数；" + (" / ".join(notes) if notes else "两侧均达成全部目标档位"))
    d.text((40, height - 34), footer, font=f_note, fill=GRAY)

    img.save(out_path, "PNG")
    print(f"chart => {out_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--mode", default="http")
    ap.add_argument("--levels", default="")
    args = ap.parse_args()
    draw(args.csv, args.out, args.mode, args.levels)


if __name__ == "__main__":
    main()

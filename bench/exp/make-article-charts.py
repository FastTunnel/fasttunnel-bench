#!/usr/bin/env python3
"""生成压测海报（以及可选的整套配图）。

数据直接取自 results/latest/results-{http,tcp}.csv（128 并发那一轮）。
默认输出 docs/article/poster.png；`--all` 时追加整套图表。
"""
import csv
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, "docs", "article")
FONT_CANDIDATES = [
    r"C:\Windows\Fonts\msyh.ttc",
    "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
    "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
]
FONT_PATH = next((f for f in FONT_CANDIDATES if os.path.exists(f)), FONT_CANDIDATES[0])

INK = "#1B1F24"
MUTED = "#667085"
FAINT = "#98A2B3"
GRID = "#E6E9EE"
AXIS = "#C7CDD6"
BG = "#FFFFFF"
PANEL = "#F5F7FA"
BORDER = "#E1E7EF"
FT = "#2F7ED8"
FT_SOFT = "#A9C9F0"
FRP = "#D9534F"
FRP_SOFT = "#EDB0AC"
NAVY = "#0D1624"

TARGETS = [5000, 10000, 20000, 30000, 40000, 50000]


class P:
    """2x 超采样画布：所有坐标/线宽/字号按逻辑像素传入。"""

    def __init__(self, w, h, bg=BG, ss=2):
        self.ss = ss
        self.W, self.H = w, h
        self.img = Image.new("RGB", (w * ss, h * ss), bg)
        self.d = ImageDraw.Draw(self.img)
        self._fonts = {}

    def f(self, size):
        key = int(round(size * self.ss))
        if key not in self._fonts:
            self._fonts[key] = ImageFont.truetype(FONT_PATH, key)
        return self._fonts[key]

    def text(self, x, y, s, size=20, fill=INK, anchor="la"):
        self.d.text((x * self.ss, y * self.ss), s, font=self.f(size), fill=fill, anchor=anchor)

    def tw(self, s, size):
        return self.d.textlength(s, font=self.f(size)) / self.ss

    def line(self, pts, fill, width=1):
        self.d.line(
            [(x * self.ss, y * self.ss) for x, y in pts],
            fill=fill,
            width=max(1, int(round(width * self.ss))),
        )

    def dash(self, p1, p2, fill, width=1, dash=8, gap=7):
        (x1, y1), (x2, y2) = p1, p2
        dist = math.hypot(x2 - x1, y2 - y1)
        if dist == 0:
            return
        ux, uy = (x2 - x1) / dist, (y2 - y1) / dist
        t = 0.0
        while t < dist:
            e = min(t + dash, dist)
            self.line(
                [(x1 + ux * t, y1 + uy * t), (x1 + ux * e, y1 + uy * e)],
                fill,
                width,
            )
            t = e + gap

    def rect(self, x0, y0, x1, y1, fill=None, outline=None, width=1):
        self.d.rectangle(
            [x0 * self.ss, y0 * self.ss, x1 * self.ss, y1 * self.ss],
            fill=fill,
            outline=outline,
            width=max(1, int(round(width * self.ss))) if outline else 1,
        )

    def rrect(self, x0, y0, x1, y1, r, fill=None, outline=None, width=1):
        self.d.rounded_rectangle(
            [x0 * self.ss, y0 * self.ss, x1 * self.ss, y1 * self.ss],
            radius=r * self.ss,
            fill=fill,
            outline=outline,
            width=max(1, int(round(width * self.ss))) if outline else 1,
        )

    def ellipse(self, x0, y0, x1, y1, fill=None, outline=None, width=1):
        self.d.ellipse(
            [x0 * self.ss, y0 * self.ss, x1 * self.ss, y1 * self.ss],
            fill=fill,
            outline=outline,
            width=max(1, int(round(width * self.ss))) if outline else 1,
        )

    def dot(self, x, y, r, color, outline=BG, ow=2):
        self.ellipse(x - r, y - r, x + r, y + r, fill=color, outline=outline, width=ow)

    def polygon(self, pts, fill):
        self.d.polygon([(x * self.ss, y * self.ss) for x, y in pts], fill=fill)

    def save(self, name):
        os.makedirs(OUT, exist_ok=True)
        path = os.path.join(OUT, name)
        self.img.resize((self.W, self.H), Image.LANCZOS).save(path, "PNG", optimize=True)
        print("saved", path)


def load(mode):
    path = os.path.join(ROOT, "results", "latest", f"results-{mode}.csv")
    rows = {}
    with open(path, newline="", encoding="utf-8-sig") as fh:
        for row in csv.DictReader(fh):
            if row.get("SuccessRps") or row.get("AchievedRps"):
                # 图上的吞吐一律用 SuccessRps（只数 200 响应）；旧 CSV 没这一列时退回 AchievedRps。
                row["AchievedRps"] = row.get("SuccessRps") or row["AchievedRps"]
                rows[(row["Framework"], int(row["TargetRps"]))] = row
    return rows


def series(rows, fw, key):
    return [float(rows[(fw, t)][key]) for t in TARGETS]


def fmt_int(v):
    return f"{v:,.0f}"


def fmt_k(v):
    return f"{v / 1000:.1f}K" if v >= 1000 else f"{v:.0f}"


def header(p, kicker, title, subtitle):
    p.text(96, 58, kicker, 19, MUTED)
    p.text(96, 88, title, 39, INK)
    p.text(96, 152, subtitle, 21, MUTED)


def legend(p, x, y, items):
    cx = x
    for kind, color, label in items:
        if kind == "square":
            p.rect(cx, y + 3, cx + 16, y + 19, fill=color)
            tx = cx + 24
        elif kind == "line":
            p.line([(cx, y + 11), (cx + 28, y + 11)], color, 4)
            p.dot(cx + 14, y + 11, 4, color, BG, 2)
            tx = cx + 36
        else:
            p.dash((cx, y + 11), (cx + 30, y + 11), color, 2, 6, 5)
            tx = cx + 38
        p.text(tx, y, label, 19, MUTED)
        cx = tx + p.tw(label, 19) + 34


def callout(p, label, big, detail, accent=FT):
    x0, y0, x1, y1 = 1180, 54, 1520, 182
    p.rrect(x0, y0, x1, y1, 14, fill="#F4F8FD", outline=BORDER, width=1)
    p.text(x0 + 24, y0 + 16, label, 17, MUTED)
    p.text(x0 + 24, y0 + 42, big, 42, accent)
    p.text(x0 + 24, y0 + 104, detail, 17, INK)


def footer(p, text, source=True):
    p.text(96, 906, text, 18, MUTED)
    if source:
        p.text(1520, 948, "数据：fasttunnel-bench / results-latest", 15, FAINT, anchor="ra")


def y_axis(p, left, right, top, bottom, ymax, ticks, formatter):
    for v in ticks:
        y = bottom - (bottom - top) * v / ymax
        p.line([(left, y), (right, y)], GRID, 1)
        p.text(left - 16, y, formatter(v), 19, MUTED, anchor="rm")
    p.line([(left, bottom), (right, bottom)], AXIS, 1)


def x_labels(p, centers, bottom):
    for cx, t in zip(centers, TARGETS):
        p.text(cx, bottom + 16, f"{t // 1000}K", 19, MUTED, anchor="ma")
    p.text((centers[0] + centers[-1]) / 2, bottom + 52, "目标 RPS", 17, FAINT, anchor="ma")


def group_centers(n, left=170, right=1520):
    gw = (right - left) / n
    return [left + gw * (i + 0.5) for i in range(n)], gw


def rich(p, x, y, parts, size=19):
    """同一段落里混排不同颜色的文字，用于突出 FastTunnel / frp 两个名字。"""
    for part in parts:
        text, color = part[0], part[1]
        s = part[2] if len(part) > 2 else size
        p.text(x, y, text, s, color)
        x += p.tw(text, s)
    return x


# ---------------------------------------------------------------- 02 HTTP 吞吐
def chart_http_throughput(rows):
    p = P(1600, 1000)
    rt = series(rows, "ft", "AchievedRps")
    rp = series(rows, "frp", "AchievedRps")
    header(
        p,
        "HTTP 模式 · 吞吐量",
        "HTTP 吞吐：从 5K 之后，差距一路拉大",
        "目标 5,000 → 50,000 RPS · 128 并发 · 每档预热 10s + 测量 10s · 4 核 / 15.6 GB",
    )
    legend(
        p,
        170,
        208,
        [("square", FT, "FastTunnel"), ("square", FRP, "frp type=http"), ("dash", "#AEB6C2", "目标 RPS")],
    )
    ratio = rt[-1] / rp[-1]
    callout(p, "HTTP · 50K 档", f"{ratio:.2f}×", f"{fmt_int(rt[-1])} vs {fmt_int(rp[-1])} RPS")

    L, R, T, B = 170, 1520, 280, 848
    ymax = 55000
    y_axis(p, L, R, T, B, ymax, [0, 10000, 20000, 30000, 40000, 50000], lambda v: f"{v // 1000}K")
    centers, gw = group_centers(len(TARGETS))

    def yv(v):
        return B - (B - T) * v / ymax

    for i, t in enumerate(TARGETS):
        y = yv(t)
        p.dash((centers[i] - gw / 2, y), (centers[i] + gw / 2, y), "#AEB6C2", 2, 7, 7)
        if i < len(TARGETS) - 1:
            p.dash(
                (centers[i] + gw / 2, y),
                (centers[i] + gw / 2, yv(TARGETS[i + 1])),
                "#AEB6C2",
                2,
                7,
                7,
            )

    bar_w, gap = 70, 14
    for i, cx in enumerate(centers):
        for j, (val, color) in enumerate(((rt[i], FT), (rp[i], FRP))):
            x0 = cx - bar_w - gap / 2 if j == 0 else cx + gap / 2
            y0 = yv(val)
            p.rect(x0, y0, x0 + bar_w, B, fill=color)
            p.text(x0 + bar_w / 2, y0 - 12, fmt_int(val), 18, color, anchor="mb")

    x_labels(p, centers, B)
    footer(p, "柱高＝实际达成 RPS；灰色阶梯＝目标 RPS。frp 在 10K 档后停在 5.5K–6.1K，FastTunnel 持续逼近目标。")
    p.save("02-http-throughput.png")


# ---------------------------------------------------------------- 03 HTTP P99
def chart_http_p99(rows):
    p = P(1600, 1000)
    ft = series(rows, "ft", "P99")
    fr = series(rows, "frp", "P99")
    header(
        p,
        "HTTP 模式 · P99 延迟",
        "10K 档起，frp 的 P99 抬升到 90ms 以上",
        "P99＝99% 请求的延迟上限，越低越好 · 对数刻度 · 128 并发 keep-alive",
    )
    legend(p, 170, 208, [("line", FT, "FastTunnel"), ("line", FRP, "frp type=http")])
    callout(
        p,
        "HTTP · 50K 档 P99",
        f"{fr[-1] / ft[-1]:.0f}×",
        f"FastTunnel {ft[-1]:.2f}ms · frp {fr[-1]:.2f}ms",
    )

    L, R, T, B = 170, 1520, 280, 848
    lo, hi = 0.3, 150.0
    log_lo, log_hi = math.log10(lo), math.log10(hi)

    def yv(v):
        return B - (B - T) * (math.log10(v) - log_lo) / (log_hi - log_lo)

    ticks = [0.3, 1, 3, 10, 30, 100]
    for v in ticks:
        y = yv(v)
        p.line([(L, y), (R, y)], GRID, 1)
        p.text(L - 16, y, f"{v:g}", 19, MUTED, anchor="rm")
    p.line([(L, B), (R, B)], AXIS, 1)
    centers, _ = group_centers(len(TARGETS))

    for vals, color in ((ft, FT), (fr, FRP)):
        pts = [(cx, yv(v)) for cx, v in zip(centers, vals)]
        p.line(pts, color, 4)
        for x, y in pts:
            p.dot(x, y, 7, color, BG, 2)

    for i, (cx, v) in enumerate(zip(centers, ft)):
        p.text(cx, yv(v) + 16, f"{v:.2f}", 18, FT, anchor="ma")

    p.text(centers[0] - 14, yv(fr[0]), f"{fr[0]:.2f}", 18, FRP, anchor="rm")
    p.text(centers[1] + 12, yv(fr[1]) - 14, f"{fr[1]:.1f}", 18, FRP, anchor="lm")
    for cx, v in zip(centers[2:], fr[2:]):
        p.text(cx, yv(v) + 16, f"{v:.1f}", 18, FRP, anchor="ma")

    # 把“数值悬崖”标出来
    p.dash((centers[1], yv(fr[1]) + 6), (centers[2], yv(fr[2]) + 6), FRP_SOFT, 2, 5, 6)
    p.text(centers[1] + 16, yv(fr[1]) + 46, "陡升", 17, FRP)

    x_labels(p, centers, B)
    footer(p, "对数刻度用于同时看清 0.9ms 与 116ms；frp 在 10K 档后的 P99 稳定在 91–116ms。")
    p.save("03-http-p99.png")


# ---------------------------------------------------------------- 04 TCP 吞吐
def chart_tcp_throughput(rows):
    p = P(1600, 1000)
    rt = series(rows, "ft", "AchievedRps")
    rp = series(rows, "frp", "AchievedRps")
    header(
        p,
        "TCP 模式 · 吞吐量",
        "20K 以内并驾齐驱，30K 后出现平台期",
        "虚线＝目标 RPS（理想达成）· 128 并发 · 共享 vCPU 环境 · 4 核 / 15.6 GB",
    )
    legend(p, 170, 208, [("line", FT, "FastTunnel"), ("line", FRP, "frp type=tcp"), ("dash", "#AEB6C2", "理想达成")])
    callout(p, "TCP · 50K 档", f"{rt[-1] / rp[-1]:.2f}×", f"{fmt_int(rt[-1])} vs {fmt_int(rp[-1])} RPS")

    L, R, T, B = 170, 1520, 280, 848
    ymax = 55000
    y_axis(p, L, R, T, B, ymax, [0, 10000, 20000, 30000, 40000, 50000], lambda v: f"{v // 1000}K")
    centers, _ = group_centers(len(TARGETS))

    def yv(v):
        return B - (B - T) * v / ymax

    p.dash(
        [(cx, yv(t)) for cx, t in zip(centers, TARGETS)],
        "#AEB6C2",
        2,
        7,
        7,
    )

    for vals, color in ((rt, FT), (rp, FRP)):
        pts = [(cx, yv(v)) for cx, v in zip(centers, vals)]
        p.line(pts, color, 4)
        for x, y in pts:
            p.dot(x, y, 7, color, BG, 2)

    for cx, v in zip(centers, rt):
        p.text(cx, yv(v) - 18, fmt_int(v), 18, FT, anchor="mb")
    for i, (cx, v) in enumerate(zip(centers, rp)):
        if i >= 2:
            p.text(cx, yv(v) + 18, fmt_int(v), 18, FRP, anchor="ma")

    p.text(centers[4], yv(25100) - 40, "≈25K 平台期", 20, FRP, anchor="ma")
    p.text(centers[0] + 6, yv(5000) - 42, "三条线重合", 17, MUTED)

    x_labels(p, centers, B)
    footer(p, "FastTunnel 在 40K 前基本贴合目标，50K 档达到 42,849；frp 在 30K 档后停在约 25K。")
    p.save("04-tcp-throughput.png")


# ---------------------------------------------------------------- 05 TCP P99
def chart_tcp_p99(rows):
    p = P(1600, 1000)
    ft = series(rows, "ft", "P99")
    fr = series(rows, "frp", "P99")
    header(
        p,
        "TCP 模式 · P99 延迟",
        "低负载 frp 更优，20K 之后 FastTunnel 反超",
        "P99 延迟（ms），越低越好 · 128 并发 · 全档位错误率 0.00%",
    )
    legend(p, 170, 208, [("line", FT, "FastTunnel"), ("line", FRP, "frp type=tcp")])
    cut = (fr[-1] - ft[-1]) / fr[-1] * 100
    callout(p, "TCP · 50K 档 P99", f"−{cut:.0f}%", f"FastTunnel {ft[-1]:.2f}ms · frp {fr[-1]:.2f}ms")

    L, R, T, B = 170, 1520, 280, 848
    ymax = 10.5
    y_axis(p, L, R, T, B, ymax, [0, 2, 4, 6, 8, 10], lambda v: f"{v:g}")
    centers, _ = group_centers(len(TARGETS))

    def yv(v):
        return B - (B - T) * v / ymax

    # 交叉点：10K→20K 两条线段
    t = (ft[1] - fr[1]) / ((fr[2] - fr[2] if False else (fr[2] - fr[1]) - (ft[2] - ft[1])))
    xc = centers[1] + (centers[2] - centers[1]) * t
    yc = yv(ft[1] + (ft[2] - ft[1]) * t)
    p.dash((xc, T + 24), (xc, B), "#DDE3EA", 2, 6, 7)
    p.text(xc, T + 4, "交叉", 16, FAINT, anchor="ma")

    for vals, color in ((ft, FT), (fr, FRP)):
        pts = [(cx, yv(v)) for cx, v in zip(centers, vals)]
        p.line(pts, color, 4)
        for x, y in pts:
            p.dot(x, y, 7, color, BG, 2)

    for i, (cx, v) in enumerate(zip(centers, ft)):
        if i < 2:
            p.text(cx, yv(v) - 16, f"{v:.2f}", 18, FT, anchor="mb")
        else:
            p.text(cx, yv(v) + 18, f"{v:.2f}", 18, FT, anchor="ma")
    p.text(centers[0] + 12, yv(fr[0]), f"{fr[0]:.2f}", 18, FRP, anchor="lm")
    p.text(centers[1], yv(fr[1]) + 20, f"{fr[1]:.2f}", 18, FRP, anchor="ma")
    for cx, v in zip(centers[2:], fr[2:]):
        p.text(cx, yv(v) - 16, f"{v:.2f}", 18, FRP, anchor="mb")

    x_labels(p, centers, B)
    footer(p, "5K–10K：frp 更低；20K 起两条线互换位置，50K 档 FastTunnel 为 5.69ms，frp 为 8.95ms。")
    p.save("05-tcp-p99.png")


# ---------------------------------------------------------------- 06 内存
def chart_memory(rows):
    p = P(1600, 1000)
    header(
        p,
        "资源占用 · 50K 目标档",
        "内存是这次唯一落后的维度",
        "服务端 + 客户端常驻内存 · 同一轮交替测量 · 单位 MB",
    )
    p.text(170, 208, "每根柱：下段＝服务端，上段＝客户端", 19, MUTED)
    callout(
        p,
        "TCP · 总内存",
        "3.4×",
        "FastTunnel 341.2 · frp 100.2 MB",
        accent="#B03A34",
    )

    L, R, T, B = 170, 1520, 280, 820
    ymax = 400
    y_axis(p, L, R, T, B, ymax, [0, 100, 200, 300, 400], lambda v: f"{v:g}")
    p.text(L + 6, T - 28, "MB", 17, FAINT)

    bars = [
        ("HTTP", "FastTunnel", rows[("ft", 50000)], FT, FT_SOFT, "#173A63"),
        ("HTTP", "frp", rows[("frp", 50000)], FRP, FRP_SOFT, "#6E2420"),
        ("TCP", "FastTunnel", rows[("ft", 50000)], FT, FT_SOFT, "#173A63"),
        ("TCP", "frp", rows[("frp", 50000)], FRP, FRP_SOFT, "#6E2420"),
    ]

    width, inner, gap = 150, 30, 140
    total = 4 * width + 3 * 0 + inner + gap + inner
    x = (L + R) / 2 - total / 2
    separators = []
    for idx, (mode, fw, row, dark, light, light_ink) in enumerate(bars):
        if idx in (1, 3):
            x += inner
        if idx == 2:
            separators.append((x - inner - gap / 2, mode))
            x += gap
        srv = float(row["ServerMemMB"])
        cli = float(row["ClientMemMB"])
        tot = srv + cli
        y_srv = B - (B - T) * srv / ymax
        y_tot = B - (B - T) * tot / ymax

        p.rect(x, y_srv, x + width, B, fill=dark)
        p.rect(x, y_tot, x + width, y_srv, fill=light)
        cx = x + width / 2

        if srv * (B - T) / ymax > 70:
            p.text(cx, y_srv + 8, "服务端", 16, "#DCE8F7", anchor="ma")
            p.text(cx, y_srv + 32, f"{srv:.1f}", 18, "#FFFFFF", anchor="ma")
        else:
            p.text(cx, y_srv + 8, f"服 {srv:.1f}", 16, "#FFFFFF", anchor="ma")

        if cli * (B - T) / ymax > 70:
            p.text(cx, y_tot + 8, "客户端", 16, light_ink, anchor="ma")
            p.text(cx, y_tot + 32, f"{cli:.1f}", 18, light_ink, anchor="ma")
        else:
            p.text(cx, y_tot + 8, f"客 {cli:.1f}", 16, light_ink, anchor="ma")

        p.text(cx, y_tot - 16, f"{tot:.1f} MB", 20, dark, anchor="mb")
        p.text(cx, B + 18, mode, 18, MUTED, anchor="ma")
        p.text(cx, B + 46, fw, 19, dark, anchor="ma")
        x += width

    for sx, _ in separators:
        p.line([(sx, T), (sx, B)], GRID, 1)

    footer(p, "HTTP 档：FastTunnel 287.2 / frp 262.3 MB；TCP 档：341.2 / 100.2 MB。FastTunnel 的内存占用更高。")
    p.save("06-memory.png")


# ---------------------------------------------------------------- 07 结论卡
def chart_summary(rows):
    W, H = 1600, 900
    p = P(W, H, "#F7F9FB")
    p.text(90, 58, "总结 · 50K 目标档", 19, MUTED)
    p.text(90, 92, "一页看懂这次测试", 42, INK)
    p.text(90, 158, "FastTunnel vs frp 0.72.0 · 128 并发 · 每档 10s 预热 + 10s 测量", 21, MUTED)

    cards = [
        (
            "HTTP 吞吐",
            f"{fmt_int(float(rows[('ft', 50000)]['AchievedRps']))}",
            f"{fmt_int(float(rows[('frp', 50000)]['AchievedRps']))}",
            "RPS",
            "FastTunnel 领先 7.47×",
            FT,
            "#EAF2FC",
        ),
        (
            "HTTP P99 延迟",
            f"{float(rows[('ft', 50000)]['P99']):.2f}",
            f"{float(rows[('frp', 50000)]['P99']):.2f}",
            "ms",
            "FastTunnel 低 94%",
            FT,
            "#EAF2FC",
        ),
        (
            "TCP 吞吐",
            f"{fmt_int(float(rows[('ft', 50000)]['AchievedRps']))}",
            f"{fmt_int(float(rows[('frp', 50000)]['AchievedRps']))}",
            "RPS",
            "FastTunnel 领先 1.71×",
            FT,
            "#EAF2FC",
        ),
        (
            "TCP 内存占用",
            f"{float(rows[('ft', 50000)]['TotalMemMB']):.1f}",
            f"{float(rows[('frp', 50000)]['TotalMemMB']):.1f}",
            "MB",
            "frp 低 71%，FastTunnel 3.4×",
            "#B03A34",
            "#FBEDEC",
        ),
    ]

    positions = [(90, 222), (810, 222), (90, 494), (810, 494)]
    for (x, y), (label, v1, v2, unit, tag, accent, tint) in zip(positions, cards):
        p.rrect(x, y, x + 700, y + 240, 18, fill=BG, outline=BORDER, width=1)
        p.text(x + 30, y + 24, label, 19, MUTED)
        p.text(x + 30, y + 62, v1, 50, accent)
        w1 = p.tw(v1, 50)
        p.text(x + 30 + w1 + 16, y + 82, "vs", 24, FAINT)
        p.text(x + 30 + w1 + 58, y + 74, v2, 34, MUTED)
        w2 = p.tw(v2, 34)
        p.text(x + 30 + w1 + 58 + w2 + 12, y + 88, unit, 19, MUTED)

        tw = p.tw(tag, 18)
        p.rrect(x + 30, y + 162, x + 30 + tw + 32, y + 202, 20, fill=tint)
        p.text(x + 46, y + 182, tag, 18, accent, anchor="lm")

    p.text(90, 790, "错误率：HTTP / TCP 全部 12 个档位均为 0.00%", 20, INK)
    p.text(90, 824, "共享 vCPU 环境，绝对数值仅作同一环境下的对比，不代表所有生产环境。", 18, MUTED)
    p.text(1510, 824, "HTTP 对比 frp type=http；TCP 对比 frp type=tcp", 16, FAINT, anchor="ra")
    p.save("07-summary.png")


# ---------------------------------------------------------------- 01 拓扑
def arrow(p, x0, y0, x1, y1, color, width=2, head=9):
    p.line([(x0, y0), (x1, y1)], color, width)
    ang = math.atan2(y1 - y0, x1 - x0)
    p.polygon(
        [
            (x1, y1),
            (x1 - head * math.cos(ang - 0.45), y1 - head * math.sin(ang - 0.45)),
            (x1 - head * math.cos(ang + 0.45), y1 - head * math.sin(ang + 0.45)),
        ],
        color,
    )


def chart_topology():
    p = P(1600, 760)
    p.text(96, 58, "测试方式 · 同一台机器", 19, MUTED)
    p.text(96, 88, "两条链路，同一套环境", 40, INK)
    p.text(
        96,
        152,
        "单机 loopback · 4 核 / 15.6 GB · 128 并发 keep-alive · 每档预热 10s + 测量 10s",
        21,
        MUTED,
    )

    # 压测端
    p.rrect(96, 300, 360, 500, 16, fill="#F4F7FB", outline=BORDER, width=1)
    p.text(228, 328, "压测客户端", 24, INK, anchor="ma")
    p.text(228, 366, "LoadRunner", 18, MUTED, anchor="ma")
    p.text(228, 404, "128 并发", 19, INK, anchor="ma")
    p.text(228, 432, "开环定速", 19, INK, anchor="ma")
    p.text(228, 466, "逐请求记录 P50 / P99", 16, MUTED, anchor="ma")

    # 源站
    p.rrect(1240, 300, 1504, 500, 16, fill="#F4F7FB", outline=BORDER, width=1)
    p.text(1372, 328, "源站", 24, INK, anchor="ma")
    p.text(1372, 366, "1KB 静态页", 18, MUTED, anchor="ma")
    p.text(1372, 404, "IIS / Kestrel", 19, INK, anchor="ma")
    p.text(1372, 432, "同机 loopback", 19, INK, anchor="ma")
    p.text(1372, 466, "无外部资源", 16, MUTED, anchor="ma")

    lanes = [
        (285, 390, FT, "#C9DCF5", "#EAF2FC", "FastTunnel", "Web（HTTP）/ Forwards（TCP）"),
        (410, 515, FRP, "#F0CFCD", "#FBEDEC", "frp 0.72.0", "type=http / type=tcp"),
    ]
    for y0, y1, color, edge, tint, name, mode in lanes:
        p.rrect(430, y0, 1170, y1, 16, fill=BG, outline=edge, width=1)
        p.rect(430, y0 + 18, 436, y1 - 18, fill=color)
        p.text(462, y0 + 18, name, 23, INK)
        p.text(462, y0 + 56, mode, 17, MUTED)

        cy = (y0 + y1) / 2
        p.rrect(720, cy - 26, 830, cy + 26, 10, fill=tint)
        p.text(775, cy, "服务端", 18, color, anchor="mm")
        p.rrect(950, cy - 26, 1060, cy + 26, 10, fill=tint)
        p.text(1005, cy, "客户端", 18, color, anchor="mm")
        p.dash((830, cy), (950, cy), color, 2, 6, 5)
        p.text(890, cy - 14, "隧道", 15, MUTED, anchor="mb")

        arrow(p, 360, 400, 430, cy, color, 2)
        arrow(p, 1170, cy, 1240, 400, color, 2)

    p.rrect(96, 590, 300, 630, 10, fill=BG, outline=BORDER, width=1)
    p.text(198, 610, "TLS 关闭", 17, MUTED, anchor="mm")
    p.rrect(316, 590, 556, 630, 10, fill=BG, outline=BORDER, width=1)
    p.text(436, 610, "访问日志关闭", 17, MUTED, anchor="mm")
    p.rrect(572, 590, 828, 630, 10, fill=BG, outline=BORDER, width=1)
    p.text(700, 610, "两侧同轮交替", 17, MUTED, anchor="mm")
    p.rrect(844, 590, 1080, 630, 10, fill=BG, outline=BORDER, width=1)
    p.text(962, 610, "错误率 0.00%", 17, MUTED, anchor="mm")

    p.text(96, 668, "阶梯档位：5K → 10K → 20K → 30K → 40K → 50K RPS", 19, INK)
    p.text(96, 704, "共享 vCPU 环境：绝对数值仅作同环境对比。", 17, MUTED)
    p.save("01-topology.png")


# ---------------------------------------------------------------- 00 封面
def cover(rows):
    W, H = 1080, 460
    p = P(W, H, NAVY)

    # 深色底 + 极淡网格
    for i in range(H):
        t = i / (H - 1)
        c = (int(13 + 5 * t), int(22 + 8 * t), int(36 + 14 * t))
        p.rect(0, i, W, i + 1, fill=c)
    for x in range(0, W, 60):
        p.line([(x, 0), (x, H)], "#16243A", 1)
    for y in range(0, H, 60):
        p.line([(0, y), (W, y)], "#16243A", 1)

    p.text(64, 56, "内网穿透 · 实测对照", 20, "#7F93AF")
    p.text(62, 96, "高并发之下，", 50, "#F4F7FC")
    p.text(62, 158, "差距", 50, "#5EA8FF")
    p.text(62 + p.tw("差距", 50) + 2, 158, "才真正显形", 50, "#F4F7FC")
    p.text(64, 238, "FastTunnel vs frp 0.72.0 · HTTP / TCP 阶梯压测", 20, "#AFC0D6")

    chips = ["5K → 50K RPS", "128 并发", "0% 错误"]
    cx = 64
    for label in chips:
        w = p.tw(label, 17) + 32
        p.rrect(cx, 330, cx + w, 368, 18, fill="#16253B", outline="#2A3C56", width=1)
        p.text(cx + 16, 349, label, 17, "#C9D7E8", anchor="lm")
        cx += w + 12

    # 右侧：HTTP 吞吐缩影
    x0, x1, y0, y1 = 650, 1016, 168, 352
    for i in range(1, 4):
        y = y0 + (y1 - y0) * i / 4
        p.line([(x0, y), (x1, y)], "#1D2C44", 1)

    rt = series(rows, "ft", "AchievedRps")
    rp = series(rows, "frp", "AchievedRps")
    cxs = [x0 + (x1 - x0) * (i + 0.5) / len(TARGETS) for i in range(len(TARGETS))]

    def yv(v):
        return y1 - (y1 - y0) * v / 50000

    p.dash([(cx, yv(t)) for cx, t in zip(cxs, TARGETS)], "#33445F", 2, 6, 6)
    p.line([(cx, yv(v)) for cx, v in zip(cxs, rt)], "#5EA8FF", 4)
    p.line([(cx, yv(v)) for cx, v in zip(cxs, rp)], "#E06B66", 4)
    for cx, v in zip(cxs, rt):
        p.dot(cx, yv(v), 4, "#5EA8FF", NAVY, 2)
    for cx, v in zip(cxs, rp):
        p.dot(cx, yv(v), 4, "#E06B66", NAVY, 2)

    p.text(x1, yv(rt[-1]) - 22, f"{rt[-1] / 1000:.1f}K", 19, "#5EA8FF", anchor="ra")
    p.text(x1, yv(rp[-1]) - 22, f"{rp[-1] / 1000:.1f}K", 19, "#E06B66", anchor="ra")
    p.text(x0, 120, "HTTP · 50K 档", 16, "#7F93AF")
    p.text(x1, 108, "7.47×", 38, "#5EA8FF", anchor="ra")
    p.text(x0, 384, "共享 vCPU · 数值仅作同环境对比", 14, "#5E718C")

    p.save("00-cover.png")


# ---------------------------------------------------------------- 海报
def poster(http, tcp):
    W, H = 1080, 1440
    p = P(W, H, NAVY)
    BLUE, RED = "#5EA8FF", "#E06B66"
    SUB, INK_L = "#AFC0D6", "#F4F7FC"

    for i in range(H):
        t = i / (H - 1)
        c = (int(13 + 5 * t), int(22 + 8 * t), int(36 + 14 * t))
        p.rect(0, i, W, i + 1, fill=c)
    for x in range(0, W, 60):
        p.line([(x, 0), (x, H)], "#16243A", 1)
    for y in range(0, H, 60):
        p.line([(0, y), (W, y)], "#16243A", 1)

    # 标题
    p.text(72, 64, "内网穿透 · 实测对照", 20, "#7F93AF")
    p.text(70, 104, "高并发之下，", 54, "#F4F7FC")
    p.text(70, 174, "差距", 54, "#5EA8FF")
    p.text(70 + p.tw("差距", 54) + 2, 174, "才真正显形", 54, "#F4F7FC")
    rich(
        p,
        72,
        254,
        [
            ("FastTunnel", BLUE, 27),
            (" vs ", "#8FA3BF", 22),
            ("frp 0.72.0", RED, 27),
            (" · HTTP / TCP 阶梯压测", SUB, 21),
        ],
    )
    p.line([(72, 324), (1008, 324)], "#22334C", 1)    # 主数字
    ft_rps = float(http[("ft", 50000)]["AchievedRps"])
    frp_rps = float(http[("frp", 50000)]["AchievedRps"])
    p.text(72, 358, "HTTP 吞吐 · 50K 目标档", 20, "#8FA3BF")
    p.text(68, 384, "7.47×", 132, BLUE)

    p.text(560, 362, "FastTunnel", 26, BLUE)
    p.text(560, 396, f"{ft_rps:,.0f} RPS", 34, INK_L)
    p.text(560, 462, "frp type=http", 26, RED)
    p.text(560, 496, f"{frp_rps:,.0f} RPS", 34, RED)
    rich(p, 560, 556, [("实际达成是 ", SUB, 19), ("frp", RED, 19), (" 的 7.47 倍。", SUB, 19)])

    # 小图：HTTP 吞吐
    p.text(72, 600, "HTTP 达成吞吐（RPS）", 19, "#8FA3BF")
    rich(p, 72, 628, [("frp", RED, 16), (" 平台期 ≈5.5K–6.1K", "#C7908C", 15)])

    lg = 21
    w1, w2 = p.tw("FastTunnel", lg), p.tw("frp", lg)
    x = 1008 - (20 + 9 + w1 + 30 + 20 + 9 + w2)
    p.rect(x, 601, x + 20, 623, fill=BLUE)
    p.text(x + 29, 612, "FastTunnel", lg, BLUE, anchor="lm")
    x2 = x + 20 + 9 + w1 + 30
    p.rect(x2, 601, x2 + 20, 623, fill=RED)
    p.text(x2 + 29, 612, "frp", lg, RED, anchor="lm")

    L, R, T, B = 132, 1008, 640, 900
    ymax = 55000
    for v in range(0, 50001, 10000):
        y = B - (B - T) * v / ymax
        p.line([(L, y), (R, y)], "#1E2D45", 1)
        p.text(L - 12, y, f"{v // 1000}K", 15, "#7F93AF", anchor="rm")
    p.line([(L, B), (R, B)], "#33445F", 1)

    gw = (R - L) / len(TARGETS)
    centers = [L + gw * (i + 0.5) for i in range(len(TARGETS))]
    bar_w = 46

    for i, t in enumerate(TARGETS):
        y = B - (B - T) * t / ymax
        p.dash((centers[i] - gw / 2, y), (centers[i] + gw / 2, y), "#3A4C69", 2, 6, 6)
        if i < len(TARGETS) - 1:
            p.dash(
                (centers[i] + gw / 2, y),
                (centers[i] + gw / 2, y - (B - T) * (TARGETS[i + 1] - t) / ymax),
                "#3A4C69",
                2,
                6,
                6,
            )

    for i, cx in enumerate(centers):
        ft = float(http[("ft", TARGETS[i])]["AchievedRps"])
        frp = float(http[("frp", TARGETS[i])]["AchievedRps"])
        y_ft = B - (B - T) * ft / ymax
        y_frp = B - (B - T) * frp / ymax
        p.rect(cx - bar_w - 4, y_ft, cx - 4, B, fill="#5EA8FF")
        p.rect(cx + 4, y_frp, cx + bar_w + 4, B, fill="#E06B66")
        p.text(cx - bar_w / 2 - 4, y_ft - 10, f"{ft / 1000:.1f}K", 16, "#5EA8FF", anchor="mb")
        if i == len(centers) - 1:
            p.text(cx + bar_w / 2 + 4, y_frp - 10, f"{frp / 1000:.1f}K", 16, "#E06B66", anchor="mb")
        p.text(cx, B + 14, f"{TARGETS[i] // 1000}K", 15, "#7F93AF", anchor="ma")

    # 三条补充结论
    p.line([(72, 966), (1008, 966)], "#22334C", 1)
    tcp_ratio = float(tcp[("ft", 50000)]["AchievedRps"]) / float(tcp[("frp", 50000)]["AchievedRps"])
    ft_p99 = float(http[("ft", 50000)]["P99"])
    frp_p99 = float(http[("frp", 50000)]["P99"])
    ft_mem = float(tcp[("ft", 50000)]["TotalMemMB"])
    frp_mem = float(tcp[("frp", 50000)]["TotalMemMB"])

    ft_tcp = float(tcp[("ft", 50000)]["AchievedRps"])
    rp_tcp = float(tcp[("frp", 50000)]["AchievedRps"])
    tiles = [
        (
            "TCP 吞吐 · 50K 档",
            f"{tcp_ratio:.2f}×",
            "FastTunnel 更高",
            BLUE,
            [
                [("FastTunnel", BLUE), (f" {ft_tcp:,.0f} RPS", INK_L)],
                [("frp", RED), (f" {rp_tcp:,.0f} RPS", INK_L)],
            ],
        ),
        (
            "HTTP P99 · 50K 档",
            f"{frp_p99 / ft_p99:.1f}×",
            "FastTunnel 更低",
            BLUE,
            [
                [("FastTunnel", BLUE), (f" {ft_p99:.2f}ms", INK_L)],
                [("frp", RED), (f" {frp_p99:.2f}ms", INK_L)],
            ],
        ),
        (
            "TCP 内存 · 唯一落后项",
            f"{ft_mem / frp_mem:.1f}×",
            "FastTunnel 更高",
            "#E8C07A",
            [
                [("FastTunnel", BLUE), (f" {ft_mem:.1f} MB", INK_L)],
                [("frp", RED), (f" {frp_mem:.1f} MB", INK_L)],
            ],
        ),
    ]
    for i, (label, value, qual, accent, details) in enumerate(tiles):
        x0 = 72 + i * (296 + 24)
        p.rrect(x0, 998, x0 + 296, 1150, 16, fill="#121F33", outline="#24344D", width=1)
        p.text(x0 + 20, 1014, label, 15, "#8FA3BF")
        p.text(x0 + 20, 1040, value, 36, accent)
        p.text(x0 + 30 + p.tw(value, 36), 1058, qual, 18, SUB, anchor="lm")
        y = 1096
        for parts in details:
            rich(p, x0 + 20, y, parts, 16)
            y += 24

    # 页脚
    p.line([(72, 1190), (1008, 1190)], "#22334C", 1)
    p.text(72, 1208, "5K → 50K RPS · 128 并发 · 每档预热 10s + 测量 10s", 18, "#AFC0D6")
    p.text(72, 1244, "4 核 / 15.6 GB · 全档位错误率 0.00% · 共享 vCPU 环境", 18, "#AFC0D6")
    p.text(72, 1288, "绝对值仅作同一环境下的对比，不代表所有生产环境。", 16, "#6F829C")
    p.text(72, 1352, "FastTunnel · 持续打磨，持续进步", 20, "#5EA8FF")
    p.text(1008, 1356, "github.com/FastTunnel/fasttunnel-bench", 15, "#5E718C", anchor="ra")

    p.save("poster.png")


def main():
    http = load("http")
    tcp = load("tcp")
    if "--all" in sys.argv:
        chart_topology()
        chart_http_throughput(http)
        chart_http_p99(http)
        chart_tcp_throughput(tcp)
        chart_tcp_p99(tcp)
        chart_memory(tcp)
        chart_summary(http)
        cover(http)
    poster(http, tcp)


if __name__ == "__main__":
    main()
#!/usr/bin/env python3
"""把 bench.sh 采集的 CSV 变成 Markdown 报告（阶梯 / 多轮交替两种模式）。

口径说明（与 bench/LoadRunner 输出一致）：
  SuccessRps  只数 200 响应 —— 跨框架对比看这一列
  AchievedRps 数所有拿到响应的请求，含隧道自己返回的非 200
  LateSend    发送时刻晚于计划 5ms 以上的请求占比；要和 SuccessRps 一起读——
              成功速率达标时它只说明发送被排后（闭环自限速），没达标才是真的没压上去
"""
import argparse
import csv
import os
import statistics
import sys

HEADER = ["Framework", "TargetRps", "Connections", "Round", "SuccessRps", "AchievedRps",
          "ErrorRate", "LateSend", "ConnectFails", "P50", "P99", "P999", "MiBps", "LossRate",
          "ServerCores", "ClientCores", "TotalCores", "ServerMemMB", "ClientMemMB", "TotalMemMB"]

# 落后中位数超过这个比例算「节奏落后」；成功速率低于目标 95% 算「掉队」
LATE_THRESHOLD = 5.0
ACHIEVE_RATIO = 0.95


def read_rows(path):
    with open(path, newline="", encoding="utf-8") as fh:
        rows = [row for row in csv.DictReader(fh)]
    if rows and "SuccessRps" not in rows[0]:
        # 旧 CSV 只有 AchievedRps（含非 200）：照它算，但标题要注明口径，别和新一轮混着比
        for row in rows:
            row["SuccessRps"] = row.get("AchievedRps", "")
            row.setdefault("LateSend", "")
            row["__legacy_metric"] = "1"
    return rows


def is_legacy(rows):
    return bool(rows) and rows[0].get("__legacy_metric")


def num(value, digits=1):
    try:
        return f'{float(value):.{digits}f}'
    except (TypeError, ValueError):
        return "-"


def f(value):
    try:
        return float(value)
    except (TypeError, ValueError):
        return 0.0


def median(rows, key, digits=1):
    values = []
    for row in rows:
        try:
            values.append(float(row[key]))
        except (KeyError, TypeError, ValueError):
            pass
    return num(statistics.median(values), digits) if values else "-"


def group_state(group):
    """按中位数分两种状态：(掉队, 节奏落后)。

    掉队 = 成功 RPS 没到目标 95%，这一档的吞吐和延迟都不能引用。
    节奏落后 = 吞吐达标但发送被排在计划之后（闭环自限速，恒定偏移也会全量命中），
    吞吐可引用，p99 是限速后的观测值、偏乐观。
    """
    target = f(group[0].get("TargetRps"))
    late = f(median(group, "LateSend")) > LATE_THRESHOLD
    shortfall = target > 0 and f(median(group, "SuccessRps")) < target * ACHIEVE_RATIO
    return shortfall, (late and not shortfall)


def pct(text):
    """给已经是数字的单元格补百分号；缺失值保持单独的 -，不要写成 -%。"""
    return text if text == "-" else text + "%"


def header_lines(args, rows):
    lines = [f'# FastTunnel vs frp 穿透压测 · {args.mode_name} 模式', ""]
    if is_legacy(rows):
        lines += ["> ⚠ 这份 CSV 是改造前的旧数据：没有 SuccessRps / LateSend 列，"
                  "下面的「成功 RPS」实际是 AchievedRps（含隧道自己返回的非 200），落后列空。", ""]
    lines += [f'- 目标 RPS：{args.levels}',
              f'- 并发连接：{"随档位自适应（目标 RPS / 50，上限 1024）" if args.auto_connections == "1" else f"固定 {args.connections}"}',
              f'- 轮数：{args.rounds}（奇偶轮交换两侧先后）',
              f'- frp 连接池：{"双侧调平到 " + args.frp_pool + "（非出厂配置）" if args.frp_pool != "0" else "出厂默认（frpc poolCount=1 / frps maxPoolCount=5）"}', ""]
    lines += ["> **成功 RPS** 只数 200 响应，跨框架对比看这一列；**达成 RPS** 含隧道自己返回的非 200。",
              "> **落后** 不为 0 只说明发送被排在计划之后：成功 RPS 同时达标的话吞吐仍可引用（p99 偏乐观），"
              "没达标就是这一档没压上去，两组数字都不能引用。", ""]
    if args.mode_name == "udp":
        lines += ["> UDP 模式下 RPS = **PPS**（每秒数据报），200 响应 = 收到内容匹配的有效 echo；"
                  "**错误率 ≈ 丢包率**（没收到 echo 的数据报占比），延迟是逐包 RTT。", ""]
    return lines


def has_loss(rows, args):
    """只有 UDP 模式显示丢包率列。

    bench.sh 三种模式共用一张 CSV 表头（都带 LossRate 列，HTTP/TCP 恒为 0），
    所以除了列是否存在，还要看 mode-name，避免给 HTTP/TCP 报告挂一列无意义的 0%。
    """
    return args.mode_name == "udp" and bool(rows) and "LossRate" in rows[0]


def render_ladder(rows, args):
    lines = header_lines(args, rows)
    extra = " 丢包率 |" if has_loss(rows, args) else ""
    sep_extra = "---|" if has_loss(rows, args) else ""
    lines += [f"| 框架 | 目标 RPS | 并发 | 成功 RPS | 达成 RPS | 错误率 | 落后 | MiB/s | p50 | p99 |{extra} 服务端内存(MB) | 客户端内存(MB) |",
              f"|---|---|---|---|---|---|---|---|---|---|{sep_extra}---|---|"]
    for row in rows:
        loss_cell = f" {pct(num(row.get('LossRate'), 2))} |" if has_loss(rows, args) else ""
        lines.append(f"| {row['Framework']} | {row['TargetRps']} | {row['Connections']} | "
                     f"{num(row['SuccessRps'])} | {num(row['AchievedRps'])} | "
                     f"{pct(num(row['ErrorRate'], 2))} | {pct(num(row.get('LateSend'), 2))} | "
                     f"{num(row.get('MiBps'), 2)} | {num(row['P50'], 3)} | {num(row['P99'], 3)} |{loss_cell} "
                     f"{num(row['ServerMemMB'])} | {num(row['ClientMemMB'])} |")

    by_level = {}
    for row in rows:
        by_level.setdefault(row["TargetRps"], {})[row["Framework"]] = row
    if any(len(v) > 1 for v in by_level.values()):
        lines += ["", "## 同档位对比（成功 RPS 口径）", "",
                  "| 目标 RPS | FastTunnel 成功 | frp 成功 | FastTunnel p99 | frp p99 | FastTunnel 错误率 | frp 错误率 | FastTunnel 落后 | frp 落后 |",
                  "|---|---|---|---|---|---|---|---|---|"]
        for level in sorted(by_level, key=lambda x: int(x)):
            ft = by_level[level].get("ft", {})
            frp = by_level[level].get("frp", {})
            lines.append(f"| {level} | {num(ft.get('SuccessRps', ''))} | {num(frp.get('SuccessRps', ''))} | "
                         f"{num(ft.get('P99', ''), 3)} | {num(frp.get('P99', ''), 3)} | "
                         f"{pct(num(ft.get('ErrorRate', ''), 2))} | {pct(num(frp.get('ErrorRate', ''), 2))} | "
                         f"{pct(num(ft.get('LateSend', ''), 2))} | {pct(num(frp.get('LateSend', ''), 2))} |")
    return lines


def render_compare(rows, args):
    lines = header_lines(args, rows)
    grouped = {}
    for row in rows:
        grouped.setdefault((row["Framework"], row["TargetRps"]), []).append(row)

    extra = " 丢包率(中位) |" if has_loss(rows, args) else ""
    sep_extra = "---|" if has_loss(rows, args) else ""
    lines += [f"| 框架 | 目标 RPS | 并发 | 轮数 | 成功 RPS(中位) | 达成 RPS(中位) | 错误率 | 落后 | p50 | p99 |{extra} 服务端+客户端内存(MB) |",
              f"|---|---|---|---|---|---|---|---|---|---|{sep_extra}---|"]
    for (framework, level) in sorted(grouped, key=lambda k: (k[0], int(k[1]))):
        group = grouped[(framework, level)]
        loss_cell = f" {pct(median(group, 'LossRate', 2))} |" if has_loss(rows, args) else ""
        lines.append(f"| {framework} | {level} | {group[0]['Connections']} | {len(group)} | "
                     f"{median(group, 'SuccessRps')} | {median(group, 'AchievedRps')} | "
                     f"{pct(median(group, 'ErrorRate', 2))} | {pct(median(group, 'LateSend', 2))} | "
                     f"{median(group, 'P50', 3)} | {median(group, 'P99', 3)} |{loss_cell} "
                     f"{median(group, 'TotalMemMB')} |")

    states = {key: group_state(group) for key, group in grouped.items()}
    short = [key for key, (shortfall, _) in states.items() if shortfall]
    lag = [key for key, (_, behind) in states.items() if behind]
    if short:
        lines += ["", "## 未压满的档位（成功 RPS 没到目标 95%，这些行的吞吐与 p99 都不能当结论）", "",
                  "| 框架 | 目标 RPS | 并发 | 轮数 | 成功 RPS(中位) | 落后(中位) |",
                  "|---|---|---|---|---|---|"]
        for (framework, level) in sorted(short, key=lambda x: (x[0], int(x[1]))):
            group = grouped[(framework, level)]
            lines.append(f"| {framework} | {level} | {group[0]['Connections']} | {len(group)} | "
                         f"{median(group, 'SuccessRps')} | {pct(median(group, 'LateSend', 2))} |")
        lines += ["", "> 实际发压 ≈ 并发数 ÷ 平均延迟。要测真实上限就加大并发（`--auto-connections 1` 已默认开启），"
                  "只把目标 RPS 往上抬是压不上去的。"]
    if lag:
        lines += ["", "## 节奏落后的档位（吞吐已达目标，但发送被排在计划之后）", "",
                  "| 框架 | 目标 RPS | 并发 | 轮数 | 成功 RPS(中位) | 落后(中位) | p99 |",
                  "|---|---|---|---|---|---|---|"]
        for (framework, level) in sorted(lag, key=lambda x: (x[0], int(x[1]))):
            group = grouped[(framework, level)]
            lines.append(f"| {framework} | {level} | {group[0]['Connections']} | {len(group)} | "
                         f"{median(group, 'SuccessRps')} | {pct(median(group, 'LateSend', 2))} | "
                         f"{median(group, 'P99', 3)} |")
        lines += ["", "> 这一类是闭环发压自己限了速（并发 ÷ 延迟刚好够上目标，或启动偏移一直没过阈值）："
                  "**成功 RPS 可以引用，p99 是限速之后的观测值、偏乐观**。"]
    return lines


def main():
    # Windows 控制台默认 GBK，报告里的中文和符号会直接抛 UnicodeEncodeError
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", required=True)
    parser.add_argument("--mode", choices=["ladder", "compare"], default="ladder")
    parser.add_argument("--mode-name", default="http", help="http / tcp / udp，只用于报告标题和口径说明")
    parser.add_argument("--levels", default="")
    parser.add_argument("--connections", default="")
    parser.add_argument("--rounds", default="1")
    parser.add_argument("--auto-connections", default="1")
    parser.add_argument("--frp-pool", default="0")
    parser.add_argument("--out", required=True)
    parser.add_argument("--report", default="")
    args = parser.parse_args()

    rows = read_rows(args.csv)
    if not rows:
        raise SystemExit("CSV 为空，压测没有产生结果")

    body = render_ladder(rows, args) if args.mode == "ladder" else render_compare(rows, args)
    text = "\n".join(body) + "\n"

    os.makedirs(args.out, exist_ok=True)
    report_path = args.report or os.path.join(args.out, "report.md")
    with open(report_path, "w", encoding="utf-8") as fh:
        fh.write(text)

    print(text)
    print(f"报告：{report_path}")


if __name__ == "__main__":
    main()

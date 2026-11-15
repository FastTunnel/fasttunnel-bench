#!/usr/bin/env python3
"""把 bench.sh 采集的 CSV 变成 Markdown 报告（阶梯 / 多轮对照两种模式）。"""
import argparse
import csv
import os
import statistics

HEADER = ["Framework", "TargetRps", "Connections", "AchievedRps", "ErrorRate",
          "P50", "P99", "P999", "MiBps", "TotalCores", "ServerMemMB", "ClientMemMB", "TotalMemMB"]


def read_rows(path):
    with open(path, newline="", encoding="utf-8") as fh:
        return [row for row in csv.DictReader(fh)]


def num(value, digits=1):
    try:
        return f'{float(value):.{digits}f}'
    except (TypeError, ValueError):
        return "-"


def median(rows, key, digits=1):
    values = []
    for row in rows:
        try:
            values.append(float(row[key]))
        except (KeyError, TypeError, ValueError):
            pass
    return num(statistics.median(values), digits) if values else "-"


def render_ladder(rows, args):
    lines = [f'# FastTunnel vs frp 穿透压测（阶梯）', "",
             f'- 目标 RPS：{args.levels}', f'- 并发连接：{args.connections}', ""]
    lines += ["| 框架 | 目标 RPS | 达成 RPS | 错误率 | p50 | p99 | 服务端内存(MB) | 客户端内存(MB) |",
              "|---|---|---|---|---|---|---|---|"]
    for row in rows:
        lines.append(f"| {row['Framework']} | {row['TargetRps']} | {num(row['AchievedRps'])} | "
                     f"{num(row['ErrorRate'], 2)}% | {num(row['P50'], 3)} | {num(row['P99'], 3)} | "
                     f"{num(row['ServerMemMB'])} | {num(row['ClientMemMB'])} |")

    by_level = {}
    for row in rows:
        by_level.setdefault(row["TargetRps"], {})[row["Framework"]] = row
    if any(len(v) > 1 for v in by_level.values()):
        lines += ["", "## 同档位对比", "",
                  "| 目标 RPS | FastTunnel 达成 | frp 达成 | FastTunnel p99 | frp p99 | FastTunnel 错误率 | frp 错误率 |",
                  "|---|---|---|---|---|---|---|"]
        for level in sorted(by_level, key=lambda x: int(x)):
            ft = by_level[level].get("ft", {})
            frp = by_level[level].get("frp", {})
            lines.append(f"| {level} | {num(ft.get('AchievedRps', ''))} | {num(frp.get('AchievedRps', ''))} | "
                         f"{num(ft.get('P99', ''), 3)} | {num(frp.get('P99', ''), 3)} | "
                         f"{num(ft.get('ErrorRate', ''), 2)}% | {num(frp.get('ErrorRate', ''), 2)}% |")
    return lines


def render_compare(rows, args):
    lines = [f'# FastTunnel vs frp(type=tcp) 多轮交替对照', "",
             f'- 目标 RPS：{args.levels}，并发 {args.connections}，{args.rounds} 轮交替', ""]
    grouped = {}
    for row in rows:
        grouped.setdefault((row["Framework"], row["TargetRps"]), []).append(row)

    lines += ["| 框架 | 目标 RPS | 轮数 | 达成 RPS(中位) | 错误率 | p50 | p99 | 服务端+客户端内存(MB) |",
              "|---|---|---|---|---|---|---|---|"]
    for (framework, level) in sorted(grouped, key=lambda k: (k[0], int(k[1]))):
        group = grouped[(framework, level)]
        lines.append(f"| {framework} | {level} | {len(group)} | {median(group, 'AchievedRps')} | "
                     f"{median(group, 'ErrorRate', 2)}% | {median(group, 'P50', 3)} | {median(group, 'P99', 3)} | "
                     f"{median(group, 'TotalMemMB')} |")
    return lines


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--csv", required=True)
    parser.add_argument("--mode", choices=["ladder", "compare"], default="ladder")
    parser.add_argument("--levels", default="")
    parser.add_argument("--connections", default="")
    parser.add_argument("--rounds", default="1")
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

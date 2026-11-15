# fasttunnel-bench

Reproducible **HTTP tunneling benchmark**: FastTunnel vs [frp](https://github.com/fatedier/frp) 0.72.0,
same origin (IIS static page), same load generator, same machine.

可复现的**内网穿透性能对照基准**：FastTunnel 与 frp 0.72.0，同一源站、同一压测工具、同一台机器。

## Headline results / 主要结论

Single machine, loopback, IIS:8080 static 1KB page, 256 keep-alive connections, TLS off and logging off on both sides.
（单机 loopback，IIS:8080 静态页，256 并发 keep-alive，两侧关闭 TLS 与日志）

| Target | FastTunnel | frp `type=http` | frp `type=tcp` |
|---|---|---|---|
| 5 000 RPS | 4 999.6 · 0% err · p99 2.3ms | 4 999.2 · 0% · p99 17.9ms | 4 978 · 0% · p99 3.4ms |
| 10 000 RPS | **9 991.5 · 0% · p99 5.1ms** | 7 781.3 · 2.8% · p99 397ms | 9 953 · 0% · p99 12.8ms |
| machine ceiling | **≈ 43 000 RPS** | — | ≈ 34 000 RPS |

- Neither side errors out; beyond capacity they saturate (achieved stops tracking target, latency rises).
- frp's `type=http` (vhost) is the weak spot: at high concurrency it opens ~one work connection **per request**
  (debug log: 12 510 requests → 12 891 new work connections in 5s).
- frp's `type=tcp` is roughly on par with FastTunnel at 10K; its ceiling and memory efficiency are lower.
- frp memory is ~1.25–1.4× higher (private bytes, server+client).

Full write-up: [`docs/report-final.md`](docs/report-final.md) · tweet drafts: [`docs/tweet.md`](docs/tweet.md) ·
raw samples: [`results/`](results/) · chart: [`docs/tweet-chart.png`](docs/tweet-chart.png)

## 多轮中位数（本机 16 核，256 并发，交替 3 轮）

| 目标 RPS | FastTunnel 达成 · p50 · p99 · 内存 | frp(tcp) 达成 · p50 · p99 · 内存 |
|---|---|---|
| 5 000 | 4 984.5 · 0.89ms · 5.1ms · 177 MB | 4 983.3 · 1.11ms · 3.0ms · 236 MB |
| 10 000 | 9 970.1 · 1.55ms · 6.1ms · 182 MB | 9 967.8 · 2.08ms · 5.7ms · 230 MB |
| 30 000 | 29 947.7 · 3.70ms · 9.2ms · 173 MB | 29 921.3 · 5.31ms · 7.4ms · 243 MB |
| 60 000 | **42 692.6** · 5.68ms · 12.2ms · 217 MB | 33 864.5 · 7.46ms · 11.2ms · 248 MB |
| 90 000 | **43 138.3** · 5.63ms · 10.6ms · 206 MB | 33 051.6 · 7.52ms · 13.7ms · 248 MB |

- ≤30K：两条链路都能精确达成目标、0 错误；FastTunnel 的 **p50 低 20~30%**，frp 的 p99 略好（噪声量级）。
- ≥60K：FastTunnel 仍能顶到 ~43K，frp(tcp) 停在 ~33K —— **上限差约 25%~30%**，这一档才是真正的差距。
- 内存：frp 两侧合计 230~248 MB，FastTunnel 172~217 MB，约 **1.2~1.4 倍**。

## CI / 自动压测（GitHub Actions）

`.github/workflows/bench.yml`：**手动触发**（Actions → `bench` → Run workflow），可配 RPS 阶梯 / 并发 / 轮数。
跑完自动把结果发成 **issue**（同名标签的既有 issue 追加评论，不刷屏），原始数据作为 artifact 上传。

> 托管 runner 是共享 vCPU，存在 steal 与邻居噪声：CI 结果只用于"能跑通 + 相对趋势"，
> 正式数字请在本机按上面的步骤跑。

## 被测版本 / What is measured

本文的本机快照数字来自 **v3 分支的优化版本**（mux 重写、管道泵等）源码构建；
CI 默认下载**官方 Release 包**测试（`--ft-release v3.4.0`），保证测的就是用户下载到的那份，
需要复算本文数字时用 `--fasttunnel-root <FastTunnel 源码目录>` 切回源码构建。frp 为 0.72.0 官方二进制。

## 最新结果 / Latest results

CI 每次运行都会刷新这两张图（横轴=目标 RPS 档位，柱=达成吞吐，线=p99 延迟）。
图里的 `RPS` = Requests Per Second（每秒请求数），**柱越高越好、线越低越好**。

**HTTP 模式**：FastTunnel Web(vhost) vs frp `type=http`

![http](https://raw.githubusercontent.com/FastTunnel/fasttunnel-bench/main/results/latest/chart-http.png)

**TCP 模式**：FastTunnel Forwards vs frp `type=tcp`

![tcp](https://raw.githubusercontent.com/FastTunnel/fasttunnel-bench/main/results/latest/chart-tcp.png)

> 数据来自 GitHub Actions 的 4 vCPU 共享 runner（`ubuntu-latest`），
> 两侧使用同一种代理方式、先预热再测量；绝对数值仅供趋势参考，
> 权威数据请在有独立资源的机器上跑同一套脚本。每次运行的明细报告见
> [issues（label: bench-report）](https://github.com/FastTunnel/fasttunnel-bench/issues?q=label%3Abench-report)。

## Platforms / 平台

- **Linux（主平台 / CI）**：同一套 PowerShell 7（`pwsh`）脚本即可跑；没有 IIS 时自动使用内置 Kestrel 源站，
  frp 自动取 `linux_amd64` 包，无需管理员权限。GitHub Actions 默认 `ubuntu-latest`。
- **Windows（本地）**：脚本同样可用；`bench/exp/setup-iis-admin.ps1` 提供 IIS:8080 + hosts 的真实源站/本地 DNS。

## Requirements / 依赖

- Windows (IIS + hosts need admin; the built-in Kestrel origin does not)
- .NET 10 SDK
- PowerShell (Windows PowerShell 5.1 or PowerShell 7)
- A FastTunnel source checkout (this repo does **not** vendor it)

## Quick start / 快速开始

```powershell
# 0) get both repos side by side / 两个仓库放同级目录
git clone https://github.com/FastTunnel/FastTunnel.git
git clone https://github.com/FastTunnel/fasttunnel-bench.git

cd fasttunnel-bench

# 1) (optional, admin) deploy IIS:8080 page + hosts entries; writes out/exp/env.json
powershell -ExecutionPolicy Bypass -File bench\exp\setup-iis-admin.ps1

# 2) publish FastTunnel + build the load generator, then run 5K/10K on both tunnels
powershell -ExecutionPolicy Bypass -File bench\exp\run-experiment.ps1 -LevelsCsv 5000,10000

# 3) frp fairness check: pre-create work connections to match concurrency
powershell -ExecutionPolicy Bypass -File bench\exp\run-experiment.ps1 -Frameworks frp -LevelsCsv 5000,10000 -FrpPoolCount 256

# 4) FastTunnel vs frp(type=tcp), with CPU + memory, interleaved
powershell -ExecutionPolicy Bypass -File bench\exp\compare-tcp.ps1 -LevelsCsv 5000,10000,30000,60000,90000

# 5) chart for a post
python bench\exp\make-tweet-chart.py
```

FastTunnel path resolution: `-FastTunnelRoot <path>` → env `FASTTUNNEL_ROOT` → sibling `../FastTunnel`.

## Layout / 目录

```
bench/LoadRunner/      load generator (open-loop pacing, per-request latency, Host header override)
bench/exp/             orchestration + IIS setup + charts
  setup-iis-admin.ps1  deploy IIS page + hosts (admin, idempotent, rollback script included)
  run-experiment.ps1   staircase for ft / frp(http), CPU + memory + report.md + chart.svg
  compare-tcp.ps1      ft vs frp(type=tcp), interleaved, CPU + memory
  make-charts.ps1      SVG charts from results.csv
  make-tweet-chart.py  PNG chart (1200×800) for social posts
docs/                  report, tweet drafts, chart
results/               archived raw measurements from the runs above
out/                   generated (gitignored): published binaries, frp download, logs, csvin
```

## Metrics / 指标口径

| Metric | Meaning |
|---|---|
| AchievedRps | completed 200 responses in the measurement window / window seconds |
| ErrorRate | non-200 + connection errors + timeouts / attempts |
| p50/p99/p99.9 | per-request latency, measured from the moment the request bytes are written |
| LateSendRatio | share of requests whose send time was >5ms behind schedule (saturation signal) |
| ServerCores/ClientCores | average CPU cores of the tunnel processes during the level |
| ServerMemMB/ClientMemMB | **private bytes** (not RSS peak) at the end of the level |
| SelfCores | CPU used by the load generator itself (so you can tell "tunnel slow" from "generator maxed") |

## Fairness notes / 公平性说明

1. Both sides: **TLS off**, **logging off** (Serilog `Fatal` vs frp `log.level=error`, `log.to=disable`).
2. frp's `transport.tcpMux` is **on by default** in 0.72.0 — verified from logs (`accept new mux stream`).
3. frp's `transport.poolCount` defaults to **5**; HTTP proxies need one work connection per user connection,
   so at 256 concurrency you must raise it. The report shows both "default" and "tuned" columns.
4. Same origin, same Host header, same connection count, same RPS ladder; key comparisons are interleaved
   within one session to cancel machine drift.
5. The load generator runs on the same machine as the tunnels; `SelfCores` is recorded for that reason.

## Caveats / 局限

- Loopback only: no RTT, loss, MTU or NAT effects; absolute numbers do not predict wide-area performance.
- The origin is a 1KB static page: "small response, high RPS" only; large-file throughput is a different axis.
- frp is used with stock defaults except where noted; FastTunnel is built from the linked checkout.
- Run-to-run variance is ±10–15%; use interleaved multi-round medians for conclusions.

## License

Apache-2.0 (same as FastTunnel).

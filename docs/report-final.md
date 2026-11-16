# FastTunnel vs frp 0.72.0：本地 HTTP 穿透性能对照报告

> 单机 loopback 对照实验。结论只对本机这套条件成立，用于横向比较两条链路的设计与实现差异，
> 不代表公网、跨地区或不同内核参数下的绝对性能。

> ⚠ **2026-11-16 口径修订**：本文的数字是修订**前**采集的，仍然可复现，但有三处读法限制：
> ① 「达成 RPS」当时含隧道自己返回的非 200，现在拆成了 `SuccessRps` / `AchievedRps`；
> ② 当时只写了 frpc 的 `transport.poolCount`，frps 侧 `maxPoolCount` 仍是默认 **5**，
>    服务端用 `min()` 夹回，所以标着「poolCount=256」的行实际是**池=5**；
> ③ 3.2 / 3.2b 的 FastTunnel 侧跑的是 Web(vhost)，与 frp `type=tcp` 不同层，不能当 TCP 对照。
> 新口径见仓库根 README 的 [Metric revision](../README.md#metric-revision--口径修订2026-11-16)，
> 新数据以 CI 最新图为准。

## 一、一句话结论

**同为 HTTP 穿透，FastTunnel 在 10K RPS 下仍 0 错误、p99 5ms，frp 的 `type=http` 掉到 78% 吞吐 +
2.8% 错误、p99 397ms；但把 frp 换成 `type=tcp` 后两者基础转发能力接近，差距出现在高并发段
（本机上限：FastTunnel ≈ 43K RPS，frp-tcp ≈ 34K RPS），frp 内存占用高 1.25~1.4 倍。**

上面这句里有三处要用修订后的口径重读：frp 那两行是「池实际被夹在 5」的成绩（原厂默认也是 5，
所以这不算人为卡死，但必须写明）；43K / 34K 是 256 固定并发闭环发压下的**发压上限**，不是链路上限；
**frp `type=http` 在 10K 档的塌陷，2026-11-16 用同一份配置在内置源站上没复现**（见第四节第 3 条）。

## 二、测试方法

| 项 | 设置 |
|---|---|
| 源站 | 本机 IIS:8080，静态页 `bench/exp/www/index.html`（约 1KB，无外部资源） |
| 本地 DNS | hosts 写入 `bench.ftbench.net` / `bench.frpbench.net` → 127.0.0.1 |
| FastTunnel | 发布版 Server/Client；BinPort 17270；明文 ws 控制通道 + 明文 TCP mux |
| frp | 0.72.0 官方 windows_amd64（SHA-256 与官方 checksums 一致）；bindPort 17000；HTTP vhost 17080 / TCP 17090 |
| 加密 | 两侧都**关闭 TLS**（fasttunnel `Tls.Enabled=false`；frp `transport.tls.enable=false`） |
| 日志 | 两侧都降到最低（fasttunnel Serilog `Fatal`；frp `log.level=error`、`log.to=disable`） |
| 压测 | 自建开环定速工具（目标 RPS 精确发射、逐请求记延迟、指定 Host 头）；每条连接一个线程 + 阻塞 I/O，压测机自身开销单独统计 |
| 机器 | 16 逻辑核，Windows；发压与被测同机 |
| 口径 | 每级预热 2~3s + 测量 5~9s；**同一轮内两侧交替**执行以抵消机器漂移 |

公平性上做过的两处修正（都在报告里保留）：

1. **frp 的预建 work connection 池默认极小**：frpc `transport.poolCount` 默认 **1**，frps
   `transport.maxPoolCount` 默认 **5**，且服务端取 `min()` 夹住客户端值（`server/control.go`）。
   HTTP 代理需要「每条用户连接一条 work connection」，池不放开就压 256 并发等于让 frp 每请求现拨。
   当时那组「调平到 256」只写了客户端，**服务端仍夹在 5**，所以 1435 RPS/84% 错误 → 4941 RPS/0.58%
   的提升实际是 **池 1 → 池 5**，不是 256；表中「poolCount=256」的行请按「池=5」读。
   脚本已改为两侧同时写（`-FrpPoolCount` / `--frp-pool`），并用 debug 日志复核过 work connection 数。
2. **确认 frp 0.72 默认已开 mux**（日志 `accept new mux stream`，work connection 是 yamux 流），
   不存在"frp 每条连接新 TCP、fasttunnel 走 mux"这种不对等。也因为这个，`netstat` 数不到
   frp 的 work connection，要看连接数得先关 mux 或读 debug 日志。

## 三、结果

### 3.1 HTTP 穿透（frp 的默认用法，5K / 10K）

| 目标 | 框架 | 达成 RPS | 错误率 | p50 | p99 |
|---|---|---|---|---|---|
| 5000 | FastTunnel | 4999.6 | 0% | 0.215ms | **2.30ms** |
| 5000 | frp（客户端 poolCount=256 → 实际 5） | 4999.2 | 0% | 0.239ms | 17.9ms |
| 10000 | FastTunnel | **9991.5** | **0%** | 0.257ms | **5.10ms** |
| 10000 | frp（客户端 poolCount=256 → 实际 5） | 7781.3 | 2.80% | 0.392ms | 397ms |
| 10000 | frp（出厂默认，池=5） | 4564.5 | 6.04% | 8.80ms | 761ms |

> 两行 frp 都只改了客户端，服务端 `maxPoolCount` 一直是 5，所以它们实际是 **池=min(256,5)=5** 与
> **池=min(1,5)=1** 的对照，不是「256 vs 5」；上面 1435 → 4941 的提升同样是这个 1 → 5 效应。
> 真正的双侧调平（池 ≥ 并发）对照请用新脚本重跑。

### 3.2 frp 换成 `type=tcp` 后（256 并发，同轮交替，含内存）

> ⚠ 这张表**不是** TCP 对照：frp 侧是 `type=tcp` 裸端口转发，FastTunnel 侧仍是 Web(vhost)
> （HTTP 层代理）。两侧不在同一层，只能读成「ft 的 HTTP 穿透 vs frp 的裸 TCP」。
> 对称版本（FastTunnel `Forwards` vs frp `type=tcp`）请用新的 `compare-tcp.ps1` 重跑。

| 目标 RPS | FastTunnel | FT p50/p99 | FT 内存(服/客) | frp-tcp | frp p50/p99 | frp 内存(服/客) |
|---|---|---|---|---|---|---|
| 5 000 | 4 973 | 1.34 / 7.9ms | 58.8 / 83.5 MB | 4 978 | 1.27 / 3.4ms | 100.6 / 94.9 MB |
| 10 000 | 9 975 | 2.00 / 10.0ms | 73.3 / 107.2 MB | 9 953 | 2.14 / 12.8ms | 122.7 / 111.1 MB |
| 30 000 | 29 907 | 5.32 / 11.1ms | 85.2 / 110.4 MB | 29 995 | 6.93 / 10.0ms | 126.2 / 117.0 MB |
| 60 000 | **42 131** | 5.80 / 9.6ms | 89.2 / 112.2 MB | 32 132 | 7.69 / 16.0ms | 125.5 / 120.5 MB |
| 90 000 | **42 862** | 5.74 / 9.8ms | 92.4 / 83.8 MB | 33 783 | 7.43 / 10.1ms | 126.9 / 116.4 MB |

### 3.2b 多轮中位数（交替 3 轮，256 并发，本机 16 核）

> ⚠ 同 3.2：FastTunnel 侧是 Web(vhost)，不是 Forwards；且当时没有「落后」列，
> 60K/90K 两行撞的是发压上限，不是链路上限。

| 目标 RPS | FastTunnel 达成 / p50 / p99 / 内存 | frp(tcp) 达成 / p50 / p99 / 内存 |
|---|---|---|
| 5 000 | 4 984.5 / 0.89ms / 5.1ms / 177 MB | 4 983.3 / 1.11ms / 3.0ms / 236 MB |
| 10 000 | 9 970.1 / 1.55ms / 6.1ms / 182 MB | 9 967.8 / 2.08ms / 5.7ms / 230 MB |
| 30 000 | 29 947.7 / 3.70ms / 9.2ms / 173 MB | 29 921.3 / 5.31ms / 7.4ms / 243 MB |
| 60 000 | **42 692.6** / 5.68ms / 12.2ms / 217 MB | 33 864.5 / 7.46ms / 11.2ms / 248 MB |
| 90 000 | **43 138.3** / 5.63ms / 10.6ms / 206 MB | 33 051.6 / 7.52ms / 13.7ms / 248 MB |

说明：≤30K 两者都能吃满目标速率且 0 错误，差异主要在 p50（FastTunnel 低 20~30%）；
≥60K 两列分别停在 ~43K / ~33K —— 但这是**同一个发压机在两种延迟下的闭环上限**
（256 ÷ p50），不是链路本身的上限，需要按新口径（并发自适应 + 看「落后」列）重测才能引用。

### 3.3 FastTunnel 的上限在哪

> ⚠ 下面第一条的 42~43K 是**固定 256 并发闭环发压时的发压上限**（256 ÷ ~6ms ≈ 43K），
> 不是链路吞吐上限；修订后脚本默认让并发随档位放大（`-AutoConnections`），重测的数才是链路数。

- 上限 ≈ **42~43K RPS**（最近一轮同轮交替测得；早前单独跑出现过 45~46K，属 ±10~15% 的运行间波动），此时服务端+客户端+发压机合计约 9.4~10 核 / 16 核；
- 直连源站可到 80K RPS（0 错误），**源站与压测工具都不是瓶颈**；
- 128 / 256 / 512 连接分别得到 36K / 44.5K / 44.0K，而 p50 随连接数线性上升（3.4 → 5.5 → 11.3ms），
  即 `达成 ≈ 连接数 / p50`，被同一个串行资源卡住 → 单条 mux 会话的串行处理（一个读取循环 + 一把写锁）。
  要突破需要「每客户端多会话」。
- 同一个 `达成 ≈ 连接数 / p50` 关系也说明：闭环发压下这一列同时受发压机约束，
  所以 512 连接并没有把 44K 再往上推 —— 判据是报表里的「落后」列，不为 0 就是没压上去。

### 3.4 为什么 frp 的 HTTP 模式会塌

同一份 frp、同 10K/256，只换代理类型：

| frp 配置 | 达成 RPS | 错误率 | p99 |
|---|---|---|---|
| `type=tcp` | 9 997.7 | 0% | 7.6ms |
| `type=http`（vhost） | 7 781.3 | 2.80% | 397ms |

debug 日志证据：`type=http` 下 5 秒内 12 510 个完成请求，frps 记录 `new work connection registered`
**12 891** 次 —— 平均**每个请求都在新建 work connection**；而低速（4 连接/200 RPS）时 600 请求只用 10 条。
即 HTTP vhost 在高并发下无法把 work connection 稳定复用，退化成每请求一次握手拨号。
注意这份日志采集时池被服务端夹在 5（见第二节第 1 条），"每请求新建"里有多少是池不够、多少是 vhost
路径本身不复用，要靠双侧调平后的同一份 debug 日志重新区分。

## 四、结论

1. **Go 不慢，frp 的 mux/转发内核不慢**：`type=tcp` 下 10K RPS 只比 FastTunnel 低一点（p99 7.6ms vs 5.1ms）。
2. **两者都不会"报错崩掉"**：全程 0 错误，超限表现为「达成速率停止跟随目标 + 延迟抬升」，是平滑饱和。
3. **HTTP 穿透场景 FastTunnel 明显更强（旧数据，未复现）**：10K 档 0 错误 / p99 5ms，frp 2.8% 错误 / p99 397ms。
   但 2026-11-16 用内置 Kestrel 源站按**同一份 frp 配置**（frpc poolCount=256、frps 出厂 maxPoolCount=5、
   type=http、10K/256）单跑一遍得到 **9997.9 RPS / 0% 错误 / p99 4.27ms** —— 旧表那档没有复现。
   所以「frp 的 HTTP 模式在高并发下必塌」目前是**待复核**，只当单次观测写在这里；
   同轮把服务端池放到 256 反而更差（10 859 RPS、0.96% 错误、p99 179ms、n=1，可能是顺序效应）。
   要下结论请用 `run-experiment.ps1 -Rounds 3` 在同一个源站上重跑。
4. **高并发上限 FastTunnel 更高**：≈43K vs ≈34K RPS —— 见 3.2b 的警告，这两个数是固定 256 并发
   闭环发压下的发压上限（256 ÷ p50），只能读成「同并发下 FastTunnel 的 p50 更低」；
   **内存 frp 更高**：约 1.25~1.4 倍。
5. **frp 的前提要说两遍**：`poolCount`（frpc）和 `maxPoolCount`（frps）必须一起调到并发数，
   只调客户端会被服务端 `min()` 夹回 5；否则会误判成"frp 只能跑 1.4K"，或误以为已经调平过。

## 五、局限

- 单机 loopback，没有公网 RTT、丢包、MTU、NAT 影响；真实链路下 mux/窗口/拥塞控制的作用会不同。
- 源站是静态 1KB 页面，只覆盖"小响应 + 高 RPS"这一类负载；大文件吞吐是另一个维度。
- frp 只用官方默认参数；TLS/日志按上文降到最低，`poolCount` 那一处当时只写了客户端、实际被服务端
  夹在 5（等于只做了 1 → 5），未做其它调优。
- 吞吐当时统一记成「达成 RPS」（含非 200），也没有「落后」列：错误响应会算进吞吐，过载档的 p99
  偏乐观（排队时间没进样本）。这两处现在是 `SuccessRps` / `AchievedRps` + `LateSend` 分开的。
- 压测工具与被测同机，CPU 会互相争抢；报告中用 `SelfCores` 标注了发压机开销。
- 测量存在 ±10~15% 的运行间波动，因此关键对比都采用「同轮交替 + 多轮取中位」。

## 六、复现

```powershell
# 1) 管理员：部署 IIS:8080 页面 + hosts（可回滚）
powershell -File bench\exp\setup-iis-admin.ps1

# 2) HTTP 模式阶梯（两侧）
powershell -File bench\exp\run-experiment.ps1 -LevelsCsv 5000,10000

# 3) frp 双侧调平后的 HTTP 对照（现在同时写 frpc poolCount 与 frps maxPoolCount）
#    默认 -AutoConnections 会把并发随档位放大，池不够时脚本会自动上调并打一行提示
powershell -File bench\exp\run-experiment.ps1 -Frameworks frp -LevelsCsv 5000,10000 -FrpPoolCount 256

# 4) FastTunnel(Forwards) vs frp(type=tcp)，两侧同一层，含 CPU/内存，交替 3 轮
powershell -File bench\exp\compare-tcp.ps1 -LevelsCsv 5000,10000,30000,60000,90000

# 4b) 想复现本文旧表的固定 256 并发口径（注意那是发压上限，不是链路上限）
powershell -File bench\exp\compare-tcp.ps1 -AutoConnections:$false -Connections 256 -LevelsCsv 5000,10000

# 5) 出图（推文用）
python bench\exp\make-tweet-chart.py
```

产物：`out/exp/report.md`（脚本自动生成）、`bench/exp/results-5k-10k.md`（逐节结论）、
`out/exp/compare-tcp/compare-tcp.csv`（原始数据）、`bench/exp/tweet-chart.png`（配图）。

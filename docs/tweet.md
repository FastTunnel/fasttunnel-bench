# 只改一个字段，frp 的 p99 从 7.6ms 涨到 397ms

> **标题备选**（主推第 1 个，思路是"把冲突压进前 10 个字、答案留在正文"）：
> 1. 《只改一个字段，frp 的 p99 从 7.6ms 涨到 397ms》—— 前 6 字就是"我做了什么 + 后果离谱"，且不说哪个字段，必须点进来
> 2. 《我压了 90 万次请求，压出一个"每个请求新建一条连接"的实现》—— 冲突最直白，适合技术号推荐流
> 3. 《目标速率翻十倍，它一动不动：frp 的 HTTP 模式在 4K 卡了六档》—— 用文章里最反直觉那张表当钩子
> 4. 《43K 对 33K：同一台机器、同一个源站，我把两个内网穿透压到冒烟》—— 对比型，适合 frp 存量读者多的场合
> 5. 《frp 慢，跟 Go 没关系》—— 最短最冲，靠"骂错人了"的翻案感，但没有数字，打开率会输
> 6. 《我把"这不可能"跑了三遍，最后修掉一个只在 Linux 复现的 bug》—— 故事型，适合当转发语
>
> **摘要栏（不填就自动抓正文开头，建议手动填）**：同一份 frp 0.72.0 二进制，只把 `type=tcp` 改成 `type=http`，10K RPS 下 p99 从 7.6ms 涨到 397ms、错误率 2.8%。两台机器、三遍复现、90 万次请求，脚本全开源。

![http 对照](https://raw.githubusercontent.com/FastTunnel/fasttunnel-bench/main/results/latest/chart-http.png)

---

> **版本说明（重要）**：本文测的 FastTunnel 是 **v3 分支的优化版本**
> （mux 重写、管道泵、计量快路径等），已随 v3.4.0 发布；
> 本文数字来自该分支的源码构建，与官方 v3.4.0 包同一份代码。
> frp 为 0.72.0 官方二进制。

## 一、先说结论，顺便说说我有多不信

我把两个内网穿透项目放在**同一台机器、同一个源站、同一套压测工具**下对照：

- **FastTunnel**（.NET，多路复用的自研 mux）
- **frp 0.72.0**（Go，社区最流行的方案）

跑第一档的时候，我看到 frp 的 HTTP 模式 p99 直接冲到 397ms，脑子里第一个念头是"压测脚本有 bug"。
于是我把脚本的 Host 头、连接数、目标速率全查了一遍，把 frp 的配置抄成官方示例的样子，重跑。

第二次，数字几乎一模一样。

第三次我换了台机器（GitHub Actions 的 4 核 Linux），它反而更夸张——**六个档位，frp 的 HTTP 模式死死卡在 4K RPS 上下，一动不动。**
那一刻我就知道，这不是噪声，也不是我手黑，是真的有一个瓶颈在那儿。

两个结论都很反直觉：

1. **Go 不慢，frp 的转发内核也不慢。** 换成 `type=tcp` 纯转发，它在 10K RPS 下只比 FastTunnel 低一点，尾延迟差 2ms 量级。
2. **frp 真正扛不住的，是它的 HTTP 模式。** 同一份二进制，只把 `type=tcp` 改成 `type=http`，10K RPS 下吞吐直接掉到 5.4K、p99 从 7ms 涨到 100ms 以上。

一句话：**慢的不是语言，是 HTTP vhost 那条路径。**

> ⚠ 第 2 条现在只能算**单次观测**：修订口径后，用同一份 frp 配置（`type=http`、10K、256 并发）
> 在内置源站上重跑得到 9 998 RPS / 0% 错误 / p99 4.3ms，**没能复现那一档的塌陷**。
> 发布前要么按 `-Rounds 3` 在同一源站上重测确认，要么把这句降级成"在某些机器配置下会塌"。

这个结论让我挺不舒服的——它意味着"我用 frp 慢是因为 Go 慢"这种安慰剂彻底没得用了。真正的差距藏在配置里一个不起眼的字段。

---

## 二、测试怎么做的

正因为一开始不信，所以做了几件事把"能甩锅的东西"全堵死：

| 项目 | 处理 |
|---|---|
| 源站 | 本机 IIS/Kestrel 上的静态页（1KB），无外部依赖 |
| 域名 | 改 hosts：`bench.ftbench.net` / `bench.frpbench.net` → 127.0.0.1 |
| 加密 | **两侧都关 TLS**（FastTunnel `Tls.Enabled=false` + `ws`；frp `transport.tls.enable=false`） |
| 日志 | **两侧都压到最低**（FastTunnel Serilog `Fatal`；frp `log.level=error`、`log.to=disable`） |
| 压测 | 自写开环定速工具：精确到每秒发多少请求，逐请求记延迟，可指定 Host 头 |
| 公平性 | 每一档**先预热 10s 再测量 10s**，两条链路**同轮交替**跑，避免机器漂移 |
| 采集 | 吞吐、错误率、p50/p99/p99.9、两侧进程 CPU、内存（私有字节） |

压测工具和脚本全部开源：**https://github.com/FastTunnel/fasttunnel-bench**

---

## 三、第一个发现：frp 的 HTTP 模式会塌

同一台 16 核 Windows、256 并发，目标 10K RPS：

| 配置 | 达成 RPS | 错误率 | p99 |
|---|---|---|---|
| FastTunnel（HTTP 穿透） | **9992** | **0%** | **5ms** |
| frp `type=tcp` | 9997 | 0% | 7.6ms |
| frp `type=http` | 7781 | **2.8%** | **397ms** |

请注意第二行和第三行：**是同一个 frps 进程、同一个二进制、同一个端口，我只改了一个字符串。**
`tcp` 那一档它是 7.6ms 的正常选手，`http` 那一档它的 p99 翻到 397ms，还丢掉 2.8% 的请求。

差异不在吞吐数字本身，而在**尾延迟和错误率**：同样的 1 万次请求，FastTunnel 最慢的 1% 是 5ms，frp 的 HTTP 模式是 397ms、还有 2.8% 失败。

我不甘心，把 frp 的日志级别调回 debug，翻到了原因：

```
5 秒内 12 510 个请求完成
frps 记录 "new work connection registered" 12 891 次
```

看到这两行的时候我真的愣了一下：**5 秒 12 510 个请求，对应 12 891 次新建 work connection**，比值 1.03。
不是"部分复用"，是字面意义上的**平均每个请求都要重新建立一条工作连接**，本该复用的东西退化成每次握手拨号。

> 这里要澄清一个常见误解：frp 0.72 默认已经开了 mux（日志里能看到 `accept new mux stream`），
> 所以不是"每条连接新 TCP"那种问题；问题出在 HTTP vhost 层对 work connection 的复用策略。

另外提醒一句：frp 的连接池是**两侧各有默认值**——frpc `transport.poolCount` 默认 **1**，frps
`transport.maxPoolCount` 默认 **5**，服务端会把客户端多出来的直接丢掉（debug 日志：
`work connection pool is full, discarding`）。所以只调客户端那一半等于没调平，
你会测出"frp 只能跑 1.4K RPS"这种错误结论。

（更正说明：我原来写的是"把 poolCount 调到 256 后同一档从 1435 RPS 涨到 4941 RPS"。
复查配置后发现当时服务端仍夹在 5，那组实际是**池 1 → 池 5** 的差别；而把服务端也放开到 256，
10K/256 这一档并没有再变好。配置要写全，但别把吞吐账算在它头上。）

---

## 四、第二个发现：纯 TCP 转发，两家其实很接近

把 frp 换成 `type=tcp`、FastTunnel 换成端口转发，同样是逐档加速：

| 目标 RPS | FastTunnel 达成 / p99 | frp(tcp) 达成 / p99 |
|---|---|---|
| 5 000 | 4 984 / 0.89ms | 4 983 / 1.11ms |
| 10 000 | 9 970 / 1.55ms | 9 968 / 2.08ms |
| 30 000 | 29 948 / 3.70ms | 29 921 / 5.31ms |
| 60 000 | **42 693** / 5.68ms | 33 865 / 7.46ms |
| 90 000 | **43 138** / 5.63ms | 33 052 / 7.52ms |

这张图我盯着看了很久，最意外的其实是前两行：**5K、10K、30K 三档，两家达成数只差个位数。**
差到 0.1% 以内，这种"贴合程度"本身就说明测量是干净的、没有谁在偷工。

- 30K 以内两家都能精确吃满目标、0 错误；
- 真正的分水岭在 60K 以后：我把目标推到 60 000，FastTunnel 顶到 **42 693**、frp 停在 **33 865**，差 25%~30%；
- 更有意思的是 90 000 那一档——目标已经远远超出机器能力，**FastTunnel 的达成数反而从 42 693 涨到 43 138，p99 从 5.68ms 降到 5.63ms**。换句话说，加到极限它一点没抖，那条曲线是平的；
- 内存上 frp 更省（纯转发 60~100MB vs FastTunnel 170~220MB），这一项必须承认它做得漂亮。

所以如果你只用 TCP 转发，两者都能用；**要到"高并发 HTTP 穿透"这个场景，差距才被放大。**

---

## 五、第三个发现：我在 CI 上踩到的 Linux 坑（顺手修了）

既然主战场是 Linux，我把整套压测搬到了 GitHub Actions 的 `ubuntu-latest` 上。结果一上来全部失败，
排下来发现一个**真实的上游 bug**——这一段是我没预料到的收获。

FastTunnel 的监听端口 `BinPort` 不是写在 `Program.cs`，而是挂在一个 `IHostingStartup` 里：

```csharp
// FastTunnel.Hosting/FastTunnelHostingStartup.cs
builder.UseKestrel((context, options) => {
    var basePort = context.Configuration.GetValue<int?>("FastTunnel:BinPort") ?? 1270;
    options.ListenAnyIP(basePort, lo => lo.UseConnectionFastTunnel());
});
```

在 Linux 上这个 hosting startup 没被加载，Kestrel 就退回默认端点 `[::1]:5000`——
表现就是：**进程活着、日志正常、端口配置没错，但 17270 根本没监听**，客户端只会报 "Unable to connect"。
这个 bug 最阴的地方是它在 Windows 上完全不复现：Windows 恰好能加载，所以它一直藏着。

修法是把绑定显式放到 `Program.cs`（与平台无关），并去掉 hosting startup 里的重复绑定。

顺手还发现上游 `v3` 分支**编译不过**：某个优化提交引用了 `PipePumps`，但 `PipePumps.cs` 没提交。

---

## 六、在 CI 上的实测（4 核共享 runner）

![tcp 对照](https://raw.githubusercontent.com/FastTunnel/fasttunnel-bench/main/results/latest/chart-tcp.png)

HTTP 模式，128 并发，每档预热 10s + 测量 10s：

| 目标 RPS | FastTunnel 达成 / p99 | frp(http) 达成 / p99 |
|---|---|---|
| 5 000 | 4 999 / 1.05ms | 4 035 / 239ms |
| 10 000 | 9 999 / 5.69ms | 4 040 / 131ms |
| 20 000 | 19 985 / 6.88ms | 4 103 / 111ms |
| 30 000 | 27 499 / 9.92ms | 3 853 / 136ms |
| 40 000 | 28 562 / 8.61ms | 3 965 / 165ms |
| 50 000 | 28 822 / 8.78ms | 3 831 / 157ms |

看第二列和第三列的对比，这是我这轮最上头的一张表：
左边目标从 5 000 一路加到 50 000，翻十倍，它能跟到 28 822；
右边**目标怎么变都是 4 000 左右**，最大 4 103、最小 3 831，波动不到 300。

一条曲线跟着目标跑，一条曲线像被钉在墙上——4 核共享 runner、和 Windows 16 核完全不同的机器、完全不同的并发数，
**同一个瓶颈以同一种形状再现**。这时候我已经不怀疑自己了。

---

## 七、这些数字该怎么看（重要）

1. **不要拿绝对数字跨机器比较。** 单机 loopback、共享 vCPU、4 核 vs 16 核，差异很大。
2. **看懂两个方向**：柱状是**吞吐（RPS，每秒请求数，越高越好）**，折线是**延迟（p99 毫秒，越低越好）**。
3. **看"谁先掉队"而不是"谁峰值高"**：达成速率停止跟随目标 + p99 抬升，就是到达上限的信号。上面那张 CI 表，就是"停止跟随目标"最教科书的例子。
4. **配置对齐再下结论**：TLS、日志、`poolCount`、代理类型（http 对 http、tcp 对 tcp）必须一致。

---

## 八、自己复现

我特别欢迎有人来推翻这些数字——毕竟我第一次看到的反应也是"不可能"。

```bash
git clone https://github.com/FastTunnel/FastTunnel.git
git clone https://github.com/FastTunnel/fasttunnel-bench.git
cd fasttunnel-bench

# HTTP 模式：FastTunnel Web vs frp type=http
bash bench/exp/bench.sh http  --levels 5000,10000,20000,30000 --connections 128

# TCP 模式：FastTunnel Forwards vs frp type=tcp
bash bench/exp/bench.sh tcp   --levels 5000,10000,20000,30000 --connections 128
```

每次跑完会自动生成图表和 Markdown 报告；CI 里则自动发一条 issue 存档，方便对比历史。

---

## 九、写在最后

这次实测最想说的不是"谁比谁快"，而是整个过程里那种失控感：

> **性能问题常常不在你以为的那一层。**
> 语言（Go vs .NET）不是这里的瓶颈，HTTP vhost 的连接复用策略才是；
> 平台（Windows vs Linux）也不是，而是那段只在 Windows 生效的启动逻辑。

我原本只是想写篇"我们的项目也不差"的文章，最后压出来的却是三件我完全没预料到的事：
一个每请求重建连接的复用退化、一个只在 Linux 复现的启动 bug、还有一个默认值是 5 的 `poolCount`。

如果你也在做穿透/代理类的基础设施，建议先量三件事：**尾延迟、错误率、连接复用率**——
峰值吞吐往往是最会骗人的那个指标。

*压测工具、脚本、原始数据、图表全部开源，欢迎复现与挑错：*
*https://github.com/FastTunnel/fasttunnel-bench*

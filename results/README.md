# 归档的原始测量数据

`latest/` 由 CI 每次运行刷新：`chart-http.png`、`chart-tcp.png` 两图 + 两侧的
`results-http.csv`、`results-tcp.csv`。同一份数据也贴在对应的 issue 里
（[label: bench-report](https://github.com/FastTunnel/fasttunnel-bench/issues?q=label%3Abench-report)）。
CSV 各列含义见仓库根 README 的「指标口径」。

CI 出来的原始 JSON（每档一份）和隧道日志作为 artifact 上传到对应的 run，不落在仓库里；
本机跑出来的原始数据默认写在 `out/exp/results/`，同样不入库。

## 注意

- 数据来自单机 loopback，运行间波动约 ±10~15%；只认同轮交替 + 多轮中位的比较，
  不要拿单次绝对值跨机器对比。
- CI 的 runner 是共享 vCPU，同一份代码不同 run 的上限可以差很多（实测 29K~50K），
  CI 数字只用来看「能跑通 + 同一次 run 内两侧的差距」。

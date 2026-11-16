# FastTunnel（Forwards 端口转发） vs frp（type=tcp）逐级对照：吞吐、延迟、错误率、CPU、内存
#
# 为什么单独一个脚本：主实验脚本跑的是 http 代理（FastTunnel Web vhost vs frp type=http）；
# 这里两侧都走「裸 TCP 端口转发」这条对称路径：
#   FastTunnel：服务端 EnableForward + 客户端 Forwards，服务端监听 RemotePort
#   frp      ：type=tcp + remotePort，frps 监听 remotePort
# 之前这个脚本复用主实验的 Webs(vhost) 配置，测的其实是「ft 的 HTTP 穿透 vs frp 的裸 TCP」，
# 两侧不在同一层，不能叫 TCP 对照。现在两侧代理方式一致，端口也各自独立。
#
# 另外需要「两个框架交替测」以抵消机器漂移，同时采集进程内存（私有字节 / 峰值工作集）。
#
# 用法：
#   powershell -File bench\exp\compare-tcp.ps1
#   powershell -File bench\exp\compare-tcp.ps1 -LevelsCsv 5000,10000,30000,60000,90000 -Rounds 3
#   powershell -File bench\exp\compare-tcp.ps1 -FrpStockPool        # 用 frp 出厂默认池（对照用）
#   powershell -File bench\exp\compare-tcp.ps1 -AutoConnections:$false -Connections 256  # 固定并发（复现旧表口径）
#
# 前置：先跑过 run-experiment.ps1（或任何 dotnet publish），本脚本复用 out\exp\ft-server、ft-client 里的二进制。

param(
    [string]$LevelsCsv = '5000,10000,30000,60000,90000',
    [int]$Connections = 256,
    # 默认开：并发随档位放大（目标 RPS / 50）。关掉就退回固定 -Connections。
    # 闭环发压下 实际发压 ≈ 并发 ÷ 延迟，固定 256 并发时高档位根本压不满，
    # 两侧都只是撞在发压机上，测出来的"上限差"没有意义。
    [switch]$AutoConnections = $true,
    [int]$MaxAutoConnections = 1024,
    # 默认 3 轮：本机运行间波动 ±10~15%，单轮数字不足以支撑结论；奇偶轮还会交换两侧顺序。
    [int]$Rounds = 3,
    [double]$Warmup = 2,
    [double]$Duration = 5,
    [int]$FrpRemotePort = 17190,
    # frp 预建 work connection：默认按并发数双侧调平（frpc poolCount + frps maxPoolCount）。
    # 只调客户端没用：frps 的 transport.maxPoolCount 默认 5，会把客户端夹回 5。
    [switch]$FrpStockPool,
    [ValidateSet('Fatal', 'Error', 'Warning', 'Information', 'Debug')]
    [string]$LogLevel = 'Fatal',
    # 源站端口；0 = 自动（env.json > 探测 8080 上的基准页 > 内置 Kestrel 18080）
    [int]$OriginPort = 0
)

$ErrorActionPreference = 'Stop'

# 跨平台定义（curl 名称、可执行后缀、frp 平台包、后台进程启动）
. (Join-Path $PSScriptRoot 'platform.ps1')

$levels = @($LevelsCsv -split '[,\s;]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
$benchRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent   # 本仓库根目录
$exp = Join-P $benchRoot 'out\exp'
$run = Join-P $exp 'run'
$runner = Join-P $benchRoot "bench\LoadRunner\bin\Release\net10.0\FastTunnel.LoadRunner$ExeSuffix"
$frpBin = Join-P $exp "frp\frp_0.72.0_$FrpOsTag"
$outDir = Join-P $exp 'compare-tcp'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

# 与 run-experiment 的端口错开，避免上一阶段残留的 TIME_WAIT 导致 bind 失败
$ftBinPort = 17370        # FastTunnel 控制通道（客户端拨入）
$ftFwdPort = 17390        # FastTunnel 服务端为 Forwards 监听的端口 = 压测入口
$frpBind = 17100          # frps 控制通道
$ftHost = 'bench.ftbench.net'
$token = 'BENCH_TOKEN'

# 每个档位的并发：闭环发压下 实际发压 ≈ 并发 ÷ 延迟，所以并发必须跟着目标 RPS 放大，
# 否则高档位只是撞在发压机上（跑到的数字是 256 ÷ 6ms，不是链路上限）。
function Get-LevelConnections([int]$Level) {
    if (-not $AutoConnections) { return $Connections }
    [math]::Min($MaxAutoConnections, [math]::Max(64, [int]($Level / 50)))
}

# frp 的连接池是启动时写进配置的，只能按本轮会用到的最大并发调平
$maxConns = [int](($levels | ForEach-Object { Get-LevelConnections $_ } | Measure-Object -Maximum).Maximum)
$frpPool = if ($FrpStockPool) { 0 } else { $maxConns }

function Write-Utf8NoBom([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
}

# 清掉上一轮残留的隧道进程，避免端口占用把本轮打成误报
Clear-StaleBenchProcesses

# --- 源站：env.json / 探测 8080 / 内置 Kestrel ---
$originProcess = $null
$OriginPath = '/index.html'
$envFile = Join-P $exp 'env.json'

if ($OriginPort -eq 0 -and (Test-Path $envFile)) {
    $OriginPort = [int](Get-Content $envFile -Raw | ConvertFrom-Json).OriginPort
}

if ($OriginPort -eq 0) {
    foreach ($candidate in @('/index.html', '/bench/index.html')) {
        $body = (& $CurlExe -s --noproxy '*' --max-time 3 "http://127.0.0.1:8080$candidate" 2>$null | Out-String)
        if ($body -match 'benchmark target') {
            $OriginPort = 8080
            $OriginPath = $candidate
            break
        }
    }
}

if ($OriginPort -eq 0) {
    $OriginPort = 18080
    $originProcess = Start-BgProcess $runner -ArgumentList @('serve', '--port', '18080') `
        -RedirectStandardOutput (Join-P $outDir 'origin.log') -RedirectStandardError (Join-P $outDir 'origin.err')
    Start-Sleep -Milliseconds 900
    Write-Host '==> 未找到源站，已启动内置 Kestrel：http://127.0.0.1:18080' -ForegroundColor Cyan
}

Write-Host "==> 源站端口：$OriginPort$OriginPath" -ForegroundColor Cyan

# --- FastTunnel 配置：端口转发（Forwards），不是 Web vhost ---
# 这里手写 JSON 而不是 ConvertTo-Json 往返：后者会把单元素数组写成对象，客户端可能绑不上。
$ftServerDir = Join-P $outDir 'ft-server'
$ftClientDir = Join-P $outDir 'ft-client'
New-Item -ItemType Directory -Path (Join-P $ftServerDir 'config') -Force | Out-Null
New-Item -ItemType Directory -Path $ftClientDir -Force | Out-Null

$bansFile = (Join-P $outDir 'bans.json') -replace '\\', '/'
$auditFile = (Join-P $outDir 'audit.jsonl') -replace '\\', '/'

Write-Utf8NoBom (Join-P $ftServerDir 'config\appsettings.json') @"
{
  ""Serilog"": { ""MinimumLevel"": { ""Default"": ""$LogLevel"", ""Override"": { ""Microsoft"": ""Warning"" } }, ""WriteTo"": [] },
  ""FastTunnel"": {
    ""BinPort"": $ftBinPort,
    ""WebDomain"": ""ftbench.net"",
    ""EnableForward"": true,
    ""EnableMux"": true,
    ""EnforceSingleSession"": false,
    ""Tls"": { ""Enabled"": false, ""AutoGenerate"": false },
    ""Tokens"": [ ""$token"" ],
    ""Bandwidth"": { ""DefaultBytesPerSecond"": 0, ""BurstSeconds"": 1, ""PerProxy"": {}, ""PerClient"": {} },
    ""Ops"": { ""PublicEndpoints"": false },
    ""Abuse"": {
      ""Ban"": { ""StateFile"": ""$bansFile"" },
      ""Audit"": { ""FilePath"": ""$auditFile"" }
    }
  }
}
"@

Write-Utf8NoBom (Join-P $ftClientDir 'appsettings.json') @"
{
  ""Serilog"": { ""MinimumLevel"": { ""Default"": ""$LogLevel"", ""Override"": { ""Microsoft"": ""Warning"" } }, ""WriteTo"": [] },
  ""FastTunnel"": {
    ""Server"": { ""ServerAddr"": ""127.0.0.1"", ""ServerPort"": $ftBinPort, ""Protocol"": ""ws"", ""AllowUntrustedCertificate"": true },
    ""Token"": ""$token"",
    ""EnableMux"": true,
    ""MuxTransport"": ""tcp"",
    ""Webs"": [],
    ""Forwards"": [ { ""LocalIp"": ""127.0.0.1"", ""LocalPort"": $OriginPort, ""RemotePort"": $ftFwdPort } ]
  }
}
"@

# --- frp 配置：type=tcp，服务端监听 remotePort ---
$frpsPoolLine = if ($frpPool -gt 0) { "transport.maxPoolCount = $frpPool" } else { '' }
$frpcPoolLine = if ($frpPool -gt 0) { "transport.poolCount = $frpPool" } else { '' }

Write-Utf8NoBom (Join-P $outDir 'frps.toml') @"
bindPort = $frpBind
log.to = "disable"
log.level = "error"
transport.tls.force = false
$frpsPoolLine
"@

Write-Utf8NoBom (Join-P $outDir 'frpc.toml') @"
serverAddr = "127.0.0.1"
serverPort = $frpBind

log.to = "disable"
log.level = "error"

transport.tls.enable = false
$frpcPoolLine

[[proxies]]
name = "tcp-bench"
type = "tcp"
localIP = "127.0.0.1"
localPort = $OriginPort
remotePort = $FrpRemotePort
"@

if ($frpPool -gt 0) {
    Write-Host "==> frp 连接池双侧调平：poolCount=$frpPool / maxPoolCount=$frpPool" -ForegroundColor Cyan
} else {
    Write-Host '==> frp 连接池用出厂默认（frpc poolCount=1，frps maxPoolCount=5）' -ForegroundColor Yellow
}

$connDesc = if ($AutoConnections) { "随档位自适应（64~$MaxAutoConnections，目标 RPS / 50；最大 $maxConns）" } else { "固定 $Connections" }
Write-Host "==> 并发：$connDesc" -ForegroundColor Cyan

# --- 启动两条链路（都在同一个源站后面） ---
Write-Host '==> 启动 FastTunnel(Forwards) 与 frp(type=tcp)' -ForegroundColor Cyan

# 上一轮刚被 kill 的进程可能还占着端口，先等它们真正释放，否则服务端 bind 失败会被误判成"隧道没起来"
foreach ($p in @($ftBinPort, $ftFwdPort, $frpBind, $FrpRemotePort)) { Wait-PortFree -Port $p }

$ftServer = Start-BgProcess (Join-P $exp "ft-server\FastTunnel.Server$ExeSuffix") `
    -WorkingDirectory $ftServerDir `
    -RedirectStandardOutput (Join-P $outDir 'ft-server.log') -RedirectStandardError (Join-P $outDir 'ft-server.err')
Start-Sleep -Milliseconds 1200
$ftClient = Start-BgProcess (Join-P $exp "ft-client\FastTunnel.Client$ExeSuffix") `
    -WorkingDirectory $ftClientDir `
    -RedirectStandardOutput (Join-P $outDir 'ft-client.log') -RedirectStandardError (Join-P $outDir 'ft-client.err')

$frps = Start-BgProcess (Join-P $frpBin ('frps' + $ExeSuffix)) -ArgumentList @('-c', (Join-P $outDir 'frps.toml')) `
    -WorkingDirectory $outDir `
    -RedirectStandardOutput (Join-P $outDir 'frps.log') -RedirectStandardError (Join-P $outDir 'frps.err')
Start-Sleep -Milliseconds 800
$frpc = Start-BgProcess (Join-P $frpBin ('frpc' + $ExeSuffix)) -ArgumentList @('-c', (Join-P $outDir 'frpc.toml')) `
    -WorkingDirectory $outDir `
    -RedirectStandardOutput (Join-P $outDir 'frpc.log') -RedirectStandardError (Join-P $outDir 'frpc.err')

Start-Sleep -Seconds 5

# 就绪探测要重试：CI 上建连 + 首次登录需要几秒，固定 sleep 会误判
foreach ($probe in @(@{ Port = $ftFwdPort; Name = 'FastTunnel Forwards' }, @{ Port = $FrpRemotePort; Name = 'frp type=tcp' })) {
    $deadline = (Get-Date).AddSeconds(60)
    $code = ''
    while ((Get-Date) -lt $deadline) {
        $code = (& $CurlExe -s -o NUL -w '%{http_code}' --noproxy '*' --max-time 5 -H "Host: $ftHost" "http://127.0.0.1:$($probe.Port)$OriginPath" 2>$null | Out-String).Trim()
        if ($code -eq '200') { break }
        Start-Sleep -Milliseconds 500
    }

    Write-Host "    $($probe.Name) port $($probe.Port) -> HTTP $code"
    if ($code -ne '200') {
        foreach ($logf in @('ft-server.log', 'ft-server.err', 'ft-client.log', 'ft-client.err', 'frps.err', 'frpc.err')) {
            $p = Join-P $outDir $logf
            if (Test-Path $p) {
                Write-Host "    --- $logf ---" -ForegroundColor DarkYellow
                Get-Content $p -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
            }
        }
        throw "$($probe.Name) 端口 $($probe.Port) 未就绪"
    }
}

$rows = @()

function Measure-Round {
    param([string]$Framework, [int]$Port, [int]$Level, [int]$Conns, [System.Diagnostics.Process]$Server, [System.Diagnostics.Process]$Client)

    $outFile = Join-P $outDir ("{0}-{1}-r{2}.json" -f $Framework, $Level, $script:round)

    $serverCpuBefore = $Server.TotalProcessorTime
    $clientCpuBefore = $Client.TotalProcessorTime

    $runnerArgs = @('--connect', "127.0.0.1:$Port", '--host', $ftHost, '--path', $OriginPath,
        '--rps', "$Level", '--connections', "$Conns", '--warmup', "$Warmup", '--duration', "$Duration",
        '--out', $outFile, '--label', "$Framework-$Level")

    & $runner @runnerArgs | Out-Null
    $result = Get-Content $outFile -Raw | ConvertFrom-Json

    $Server.Refresh(); $Client.Refresh()
    $elapsed = [math]::Max(0.001, $result.DurationSeconds + $Warmup)

    [pscustomobject]@{
        Framework    = $Framework
        Round        = $script:round
        TargetRps    = $Level
        Connections  = $Conns
        SuccessRps   = $result.SuccessRps
        AchievedRps  = $result.AchievedRps
        ErrorRate    = [math]::Round($result.ErrorRate * 100, 3)
        LateSend     = [math]::Round($result.LateSendRatio * 100, 2)
        ConnectFails = $result.ConnectFailures
        P50          = $result.LatencyMs.P50
        P99          = $result.LatencyMs.P99
        ServerCores  = [math]::Round(($Server.TotalProcessorTime - $serverCpuBefore).TotalSeconds / $elapsed, 2)
        ClientCores  = [math]::Round(($Client.TotalProcessorTime - $clientCpuBefore).TotalSeconds / $elapsed, 2)
        # 私有字节：进程真实占用（不含可共享的映射）；峰值工作集：历史峰值，反映瞬时水位
        ServerMemMB  = [math]::Round($Server.PrivateMemorySize64 / 1MB, 1)
        ClientMemMB  = [math]::Round($Client.PrivateMemorySize64 / 1MB, 1)
        TotalMemMB   = [math]::Round(($Server.PrivateMemorySize64 + $Client.PrivateMemorySize64) / 1MB, 1)
        ServerPeakMB = [math]::Round($Server.PeakWorkingSet64 / 1MB, 1)
        ClientPeakMB = [math]::Round($Client.PeakWorkingSet64 / 1MB, 1)
    }
}

try {
    for ($script:round = 1; $script:round -le $Rounds; $script:round++) {
        # 奇偶轮交换顺序，抵消"谁先跑谁吃亏"的偏置
        $order = if ($script:round % 2 -eq 1) { @('ft', 'frp-tcp') } else { @('frp-tcp', 'ft') }

        foreach ($level in $levels) {
            $conns = Get-LevelConnections $level
            foreach ($framework in $order) {
                if ($framework -eq 'ft') {
                    $row = Measure-Round -Framework 'ft' -Port $ftFwdPort -Level $level -Conns $conns -Server $ftServer -Client $ftClient
                }
                else {
                    $row = Measure-Round -Framework 'frp-tcp' -Port $FrpRemotePort -Level $level -Conns $conns -Server $frps -Client $frpc
                }

                $rows += $row
                Write-Host ("    {0,-8} r{1} {2,7} RPS / {3,5} 并发 -> 成功 {4,8}  达成 {5,8}  错误 {6,6}%  落后 {7,6}%  p50 {8,7}  p99 {9,8}  内存 {10,6}/{11,6} MB" -f `
                    $row.Framework, $row.Round, $level, $conns, $row.SuccessRps, $row.AchievedRps, $row.ErrorRate, $row.LateSend,
                    $row.P50, $row.P99, $row.ServerMemMB, $row.ClientMemMB)
            }
        }
    }
}
finally {
    foreach ($proc in @($frpc, $frps, $ftClient, $ftServer, $originProcess)) {
        if ($proc) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    }
}

$csv = Join-P $outDir 'compare-tcp.csv'
$rows | Export-Csv $csv -NoTypeInformation -Encoding utf8

Write-Host ''
Write-Host '================ 结果（内存=私有字节，服务端/客户端） ================' -ForegroundColor Green
$rows | Format-Table Framework, Round, TargetRps, Connections, SuccessRps, AchievedRps, ErrorRate, LateSend, P50, P99, ServerCores, ClientCores, ServerMemMB, ClientMemMB, TotalMemMB -AutoSize

# 多轮中位数：机器噪声大时，用中位数而不是单次值下结论
function Get-Median([double[]]$values) {
    $sorted = @($values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    return $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)]
}

Write-Host ''
Write-Host '================ 多轮中位数（每个档位） ================' -ForegroundColor Green
$summary = @()
foreach ($group in ($rows | Group-Object Framework, TargetRps | Sort-Object { $_.Group[0].Framework }, { [int] $_.Group[0].TargetRps })) {
    $g = $group.Group
    $summary += [pscustomobject]@{
        Framework    = $g[0].Framework
        TargetRps    = $g[0].TargetRps
        Connections  = $g[0].Connections
        Rounds       = $g.Count
        SuccessRps   = [math]::Round((Get-Median ($g.SuccessRps)), 1)
        AchievedRps  = [math]::Round((Get-Median ($g.AchievedRps)), 1)
        ErrorRate    = [math]::Round((Get-Median ($g.ErrorRate)), 3)
        LateSend     = [math]::Round((Get-Median ($g.LateSend)), 2)
        P50          = [math]::Round((Get-Median ($g.P50)), 3)
        P99          = [math]::Round((Get-Median ($g.P99)), 3)
        ServerCores  = [math]::Round((Get-Median ($g.ServerCores)), 2)
        ClientCores  = [math]::Round((Get-Median ($g.ClientCores)), 2)
        TotalMemMB   = [math]::Round((Get-Median ($g.TotalMemMB)), 1)
    }
}

$summary | Format-Table Framework, TargetRps, Connections, Rounds, SuccessRps, AchievedRps, ErrorRate, LateSend, P50, P99, ServerCores, ClientCores, TotalMemMB -AutoSize
$medianCsv = Join-P $outDir 'compare-tcp-median.csv'
$summary | Export-Csv $medianCsv -NoTypeInformation -Encoding utf8

# 未压满的档位单独提示：落后比例>0 说明这一档的 p99 偏乐观，达成率不等于能力上限
$behind = @($summary | Where-Object { [double]$_.LateSend -gt 5 -or [double]$_.SuccessRps -lt [double]$_.TargetRps * 0.95 })
if ($behind.Count -gt 0) {
    Write-Host ''
    Write-Host '================ 以下档位没有真正压满（p99 不能当结论） ================' -ForegroundColor Yellow
    $behind | Format-Table Framework, TargetRps, Connections, SuccessRps, LateSend -AutoSize
    Write-Host '    实际发压 ≈ 并发 ÷ 延迟。要测真实上限就加大 -MaxAutoConnections（默认已随档位放大），或减少档位。' -ForegroundColor Yellow
}

Write-Host "中位数 CSV：$medianCsv"
Write-Host "CSV：$csv"

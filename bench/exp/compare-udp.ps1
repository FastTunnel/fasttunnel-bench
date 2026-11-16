# FastTunnel（Forwards UDP 端口转发） vs frp（type=udp）逐级对照：吞吐、延迟、丢包、错误率、CPU、内存
#
# 两侧都走「公网 UDP 数据报 → 隧道 → 内网 UDP echo 源站 → 回包」这条对称路径：
#   FastTunnel：服务端 EnableForward + 客户端 Forwards[].Protocol=UDP，服务端监听 RemotePort
#   frp      ：type=udp + remotePort，frps 监听 remotePort
# 两者都指向同一个内置 UDP echo 源站（18081），保证「同一源站、同一压测工具、同一口径」。
#
# 与 compare-tcp.ps1 的差异只在协议层：发压用 LoadRunner 的 udpload 子命令（逐包 seq + RTT + 丢包），
# 就绪探测用 udpping（curl 探不到 UDP）。报表多一列丢包率。
#
# 用法：
#   powershell -File bench\exp\compare-udp.ps1
#   powershell -File bench\exp\compare-udp.ps1 -LevelsCsv 2000,5000,10000 -Rounds 3
#
# 前置：先跑过 run-experiment.ps1（或任何 dotnet publish），本脚本复用 out\exp\ft-server、ft-client 的二进制，
#       并会自己构建 LoadRunner（含 UDP 子命令）。

param(
    [string]$LevelsCsv = '5000,10000,30000,60000',
    [int]$Connections = 256,
    # 默认开：并发随档位放大（目标 PPS / 50）。闭环发压下 实际发压 ≈ 并发 ÷ 延迟，
    # 固定并发时高档位根本压不满，两侧都只是撞在发压机上。
    [switch]$AutoConnections = $true,
    [int]$MaxAutoConnections = 1024,
    [int]$Rounds = 3,
    [double]$Warmup = 2,
    [double]$Duration = 5,
    [int]$TimeoutMs = 1000,
    [int]$PayloadSize = 128,
    # 端口与 compare-tcp 错开，避免残留 TIME_WAIT / UDP 会话串扰
    [int]$FtBinPort = 17371,
    [int]$FtUdpPort = 17391,
    [int]$FrpBindPort = 17101,
    [int]$FrpUdpPort = 17191,
    [int]$UdpOriginPort = 18082,
    [ValidateSet('Fatal', 'Error', 'Warning', 'Information', 'Debug')]
    [string]$LogLevel = 'Fatal'
)

$ErrorActionPreference = 'Stop'

# 跨平台定义（curl 名称、可执行后缀、后台进程启动）
. (Join-Path $PSScriptRoot 'platform.ps1')

$levels = @($LevelsCsv -split '[,\s;]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
$benchRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent   # 本仓库根目录
$exp = Join-P $benchRoot 'out\exp'
$run = Join-P $exp 'run'
$runner = Join-P $benchRoot "bench\LoadRunner\bin\Release\net10.0\FastTunnel.LoadRunner$ExeSuffix"
$frpBin = Join-P $exp "frp\frp_0.72.0_$FrpOsTag"
$outDir = Join-P $exp 'compare-udp'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$token = 'BENCH_TOKEN'

# 构建 LoadRunner：带 UDP 子命令的版本是这次新加的，单独跑本脚本时也要能用
Write-Host '==> 构建 LoadRunner（含 UDP 子命令）' -ForegroundColor Cyan
dotnet build (Join-P $benchRoot 'bench\LoadRunner\LoadRunner.csproj') -c Release --nologo -v q | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'LoadRunner 构建失败' }

function Get-LevelConnections([int]$Level) {
    if (-not $AutoConnections) { return $Connections }
    [math]::Min($MaxAutoConnections, [math]::Max(64, [int]($Level / 50)))
}

function Write-Utf8NoBom([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
}

# 清掉上一轮残留的隧道/发压进程，避免端口占用把本轮打成误报
Clear-StaleBenchProcesses

# --- 内置 UDP echo 源站：两侧隧道共享 ---
$originProcess = Start-BgProcess $runner -ArgumentList @('serve-udp', '--port', "$UdpOriginPort") `
    -RedirectStandardOutput (Join-P $outDir 'origin-udp.log') -RedirectStandardError (Join-P $outDir 'origin-udp.err')
Start-Sleep -Milliseconds 900
Write-Host "==> UDP echo 源站：127.0.0.1:$UdpOriginPort" -ForegroundColor Cyan

# --- FastTunnel 配置：Forwards UDP ---
$ftServerDir = Join-P $outDir 'ft-server'
$ftClientDir = Join-P $outDir 'ft-client'
New-Item -ItemType Directory -Path (Join-P $ftServerDir 'config') -Force | Out-Null
New-Item -ItemType Directory -Path $ftClientDir -Force | Out-Null

$bansFile = (Join-P $outDir 'bans.json') -replace '\\', '/'
$auditFile = (Join-P $outDir 'audit.jsonl') -replace '\\', '/'

Write-Utf8NoBom (Join-P $ftServerDir 'config\appsettings.json') @"
{
  "Serilog": { "MinimumLevel": { "Default": "$LogLevel", "Override": { "Microsoft": "Warning" } }, "WriteTo": [] },
  "FastTunnel": {
    "BinPort": $FtBinPort,
    "WebDomain": "ftbench.net",
    "EnableForward": true,
    "EnableMux": true,
    "EnforceSingleSession": false,
    "Tls": { "Enabled": false, "AutoGenerate": false },
    "Tokens": [ "$token" ],
    "Bandwidth": { "DefaultBytesPerSecond": 0, "BurstSeconds": 1, "PerProxy": {}, "PerClient": {} },
    "Ops": { "PublicEndpoints": false },
    "Abuse": {
      "Ban": { "StateFile": "$bansFile" },
      "Audit": { "FilePath": "$auditFile" }
    }
  }
}
"@

Write-Utf8NoBom (Join-P $ftClientDir 'appsettings.json') @"
{
  "Serilog": { "MinimumLevel": { "Default": "$LogLevel", "Override": { "Microsoft": "Warning" } }, "WriteTo": [] },
  "FastTunnel": {
    "Server": { "ServerAddr": "127.0.0.1", "ServerPort": $FtBinPort, "Protocol": "ws", "AllowUntrustedCertificate": true },
    "Token": "$token",
    "EnableMux": true,
    "MuxTransport": "tcp",
    "Webs": [],
    "Forwards": [ { "LocalIp": "127.0.0.1", "LocalPort": $UdpOriginPort, "RemotePort": $FtUdpPort, "Protocol": "UDP" } ]
  }
}
"@

# --- frp 配置：type=udp ---
Write-Utf8NoBom (Join-P $outDir 'frps.toml') @"
bindPort = $FrpBindPort
log.to = "disable"
log.level = "error"
transport.tls.force = false
"@

Write-Utf8NoBom (Join-P $outDir 'frpc.toml') @"
serverAddr = "127.0.0.1"
serverPort = $FrpBindPort
log.to = "disable"
log.level = "error"
transport.tls.enable = false

[[proxies]]
name = "udp-bench"
type = "udp"
localIP = "127.0.0.1"
localPort = $UdpOriginPort
remotePort = $FrpUdpPort
"@

$connDesc = if ($AutoConnections) { "随档位自适应（64~$MaxAutoConnections，目标 PPS / 50）" } else { "固定 $Connections" }
Write-Host "==> 并发：$connDesc" -ForegroundColor Cyan

# --- 启动两条链路 ---
Write-Host '==> 启动 FastTunnel(Forwards UDP) 与 frp(type=udp)' -ForegroundColor Cyan
foreach ($p in @($FtBinPort, $FtUdpPort, $FrpBindPort, $FrpUdpPort)) { Wait-PortFree -Port $p }

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

# UDP 就绪探测（curl 探不到 UDP）：udpping 发一个带 magic 的数据报，等回声
foreach ($probe in @(@{ Port = $FtUdpPort; Name = 'FastTunnel UDP' }, @{ Port = $FrpUdpPort; Name = 'frp type=udp' })) {
    $ready = $false
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        & $runner udpping --host 127.0.0.1 --port "$($probe.Port)" --timeout 2000 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Milliseconds 500
    }
    Write-Host "    $($probe.Name) UDP $($probe.Port) -> $(if ($ready) { 'echo ok' } else { '无回声' })"
    if (-not $ready) {
        foreach ($logf in @('ft-server.log', 'ft-server.err', 'ft-client.log', 'ft-client.err', 'frps.err', 'frpc.err')) {
            $p = Join-P $outDir $logf
            if (Test-Path $p) {
                Write-Host "    --- $logf ---" -ForegroundColor DarkYellow
                Get-Content $p -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
            }
        }
        throw "$($probe.Name) UDP 端口 $($probe.Port) 未就绪"
    }
}

$rows = @()

function Measure-Round {
    param([string]$Framework, [int]$Port, [int]$Level, [int]$Conns, [System.Diagnostics.Process]$Server, [System.Diagnostics.Process]$Client)

    $outFile = Join-P $outDir ("{0}-{1}-r{2}.json" -f $Framework, $Level, $script:round)

    $serverCpuBefore = $Server.TotalProcessorTime
    $clientCpuBefore = $Client.TotalProcessorTime

    & $runner udpload --connect "127.0.0.1:$Port" --rps "$Level" --connections "$Conns" `
        --warmup "$Warmup" --duration "$Duration" --timeout "$TimeoutMs" --payload-size "$PayloadSize" `
        --out $outFile --label "$Framework-$Level" | Out-Null
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
        LossRate     = [math]::Round($result.LossRate * 100, 3)
        LateSend     = [math]::Round($result.LateSendRatio * 100, 2)
        ConnectFails = $result.ConnectFailures
        P50          = $result.LatencyMs.P50
        P99          = $result.LatencyMs.P99
        ServerCores  = [math]::Round(($Server.TotalProcessorTime - $serverCpuBefore).TotalSeconds / $elapsed, 2)
        ClientCores  = [math]::Round(($Client.TotalProcessorTime - $clientCpuBefore).TotalSeconds / $elapsed, 2)
        ServerMemMB  = [math]::Round($Server.PrivateMemorySize64 / 1MB, 1)
        ClientMemMB  = [math]::Round($Client.PrivateMemorySize64 / 1MB, 1)
        TotalMemMB   = [math]::Round(($Server.PrivateMemorySize64 + $Client.PrivateMemorySize64) / 1MB, 1)
    }
}

try {
    for ($script:round = 1; $script:round -le $Rounds; $script:round++) {
        $order = if ($script:round % 2 -eq 1) { @('ft', 'frp-udp') } else { @('frp-udp', 'ft') }
        foreach ($level in $levels) {
            $conns = Get-LevelConnections $level
            foreach ($framework in $order) {
                if ($framework -eq 'ft') {
                    $row = Measure-Round -Framework 'ft' -Port $FtUdpPort -Level $level -Conns $conns -Server $ftServer -Client $ftClient
                }
                else {
                    $row = Measure-Round -Framework 'frp-udp' -Port $FrpUdpPort -Level $level -Conns $conns -Server $frps -Client $frpc
                }
                $rows += $row
                Write-Host ("    {0,-8} r{1} {2,7} PPS / {3,5} 并发 -> 成功 {4,8}  达成 {5,8}  丢包 {6,6}%  落后 {7,6}%  p50 {8,7}  p99 {9,8}  内存 {10,6}/{11,6} MB" -f `
                    $row.Framework, $row.Round, $level, $conns, $row.SuccessRps, $row.AchievedRps, $row.LossRate, $row.LateSend,
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

$csv = Join-P $outDir 'compare-udp.csv'
$rows | Export-Csv $csv -NoTypeInformation -Encoding utf8

Write-Host ''
Write-Host '================ 结果（内存=私有字节，服务端/客户端） ================' -ForegroundColor Green
$rows | Format-Table Framework, Round, TargetRps, Connections, SuccessRps, AchievedRps, LossRate, LateSend, P50, P99, ServerCores, ClientCores, ServerMemMB, ClientMemMB, TotalMemMB -AutoSize

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
        LossRate     = [math]::Round((Get-Median ($g.LossRate)), 3)
        LateSend     = [math]::Round((Get-Median ($g.LateSend)), 2)
        P50          = [math]::Round((Get-Median ($g.P50)), 3)
        P99          = [math]::Round((Get-Median ($g.P99)), 3)
        ServerCores  = [math]::Round((Get-Median ($g.ServerCores)), 2)
        ClientCores  = [math]::Round((Get-Median ($g.ClientCores)), 2)
        TotalMemMB   = [math]::Round((Get-Median ($g.TotalMemMB)), 1)
    }
}

$summary | Format-Table Framework, TargetRps, Connections, Rounds, SuccessRps, AchievedRps, LossRate, LateSend, P50, P99, ServerCores, ClientCores, TotalMemMB -AutoSize
$medianCsv = Join-P $outDir 'compare-udp-median.csv'
$summary | Export-Csv $medianCsv -NoTypeInformation -Encoding utf8

$behind = @($summary | Where-Object { [double]$_.LateSend -gt 5 -or [double]$_.SuccessRps -lt [double]$_.TargetRps * 0.95 })
if ($behind.Count -gt 0) {
    Write-Host ''
    Write-Host '================ 以下档位没有真正压满（p99 不能当结论） ================' -ForegroundColor Yellow
    $behind | Format-Table Framework, TargetRps, Connections, SuccessRps, LateSend -AutoSize
    Write-Host '    实际发压 ≈ 并发 ÷ 延迟。要测真实上限就加大 -MaxAutoConnections，或减少档位。' -ForegroundColor Yellow
}

Write-Host "中位数 CSV：$medianCsv"
Write-Host "CSV：$csv"

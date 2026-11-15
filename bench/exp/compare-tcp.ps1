# FastTunnel（HTTP 穿透） vs frp（type=tcp）逐级对照：吞吐、延迟、错误率、CPU、内存
#
# 为什么单独一个脚本：主实验脚本只跑 frp 的 http 代理；这里要跑 frp 的 tcp 代理，
# 并且需要「两个框架交替测」以抵消机器漂移，同时采集进程内存（私有字节 / 峰值工作集）。
#
# 用法：
#   powershell -File bench\exp\compare-tcp.ps1
#   powershell -File bench\exp\compare-tcp.ps1 -LevelsCsv 5000,10000,30000,60000,90000 -Rounds 2

param(
    [string]$LevelsCsv = '5000,10000,30000,60000,90000',
    [int]$Connections = 256,
    [int]$Rounds = 1,
    [double]$Warmup = 2,
    [double]$Duration = 5,
    [int]$FrpRemotePort = 17190,
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
$ftPort = 17370
$frpBind = 17100

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

Write-Host "==> 源站端口：$OriginPort" -ForegroundColor Cyan

# 让 FastTunnel 指向同一个源站、并改用本脚本的独立端口。
# 这里用文本替换而不是 JSON 往返：ConvertTo-Json 会把单元素 Webs 数组写成对象，客户端可能绑不上。
$clientCfgPath = Join-P $run 'ft-client\appsettings.json'
$serverCfgPath = Join-P $run 'ft-server\config\appsettings.json'

if (Test-Path $clientCfgPath) {
    $raw = Get-Content $clientCfgPath -Raw
    $raw = $raw -replace '"ServerPort":\s*\d+', "`"ServerPort`": $ftPort"
    $raw = $raw -replace '"LocalPort":\s*\d+', "`"LocalPort`": $OriginPort"
    Write-Utf8NoBom $clientCfgPath $raw
}

if (Test-Path $serverCfgPath) {
    $rawServer = Get-Content $serverCfgPath -Raw
    $rawServer = $rawServer -replace '"BinPort":\s*\d+', "`"BinPort`": $ftPort"
    Write-Utf8NoBom $serverCfgPath $rawServer
}

# --- 启动两条链路（都在同一个源站后面） ---
Write-Host '==> 启动 FastTunnel 与 frp(tcp)' -ForegroundColor Cyan

# 上一轮刚被 kill 的进程可能还占着端口，先等它们真正释放，否则服务端 bind 失败会被误判成"隧道没起来"
Wait-PortFree -Port $ftPort
Wait-PortFree -Port $frpBind
Wait-PortFree -Port $FrpRemotePort

$ftServer = Start-BgProcess (Join-P $exp "ft-server\FastTunnel.Server$ExeSuffix") `
    -WorkingDirectory (Join-P $run 'ft-server') `
    -RedirectStandardOutput (Join-P $outDir 'ft-server.log') -RedirectStandardError (Join-P $outDir 'ft-server.err')
Start-Sleep -Milliseconds 1200
$ftClient = Start-BgProcess (Join-P $exp "ft-client\FastTunnel.Client$ExeSuffix") `
    -WorkingDirectory (Join-P $run 'ft-client') `
    -RedirectStandardOutput (Join-P $outDir 'ft-client.log') -RedirectStandardError (Join-P $outDir 'ft-client.err')

Write-Utf8NoBom (Join-P $outDir 'frps.toml') "bindPort=$frpBind`nlog.to=`"disable`"`ntransport.tls.force=false`n"
Write-Utf8NoBom (Join-P $outDir 'frpc.toml') @"
serverAddr = "127.0.0.1"
serverPort = $frpBind

log.to = "disable"

transport.tls.enable = false
transport.poolCount = $Connections

[[proxies]]
name = "tcp-bench"
type = "tcp"
localIP = "127.0.0.1"
localPort = $OriginPort
remotePort = $FrpRemotePort
"@

$frps = Start-BgProcess (Join-P $frpBin ('frps' + $ExeSuffix)) -ArgumentList @('-c', (Join-P $outDir 'frps.toml')) `
    -WorkingDirectory $outDir `
    -RedirectStandardOutput (Join-P $outDir 'frps.log') -RedirectStandardError (Join-P $outDir 'frps.err')
Start-Sleep -Milliseconds 800
$frpc = Start-BgProcess (Join-P $frpBin ('frpc' + $ExeSuffix)) -ArgumentList @('-c', (Join-P $outDir 'frpc.toml')) `
    -WorkingDirectory $outDir `
    -RedirectStandardOutput (Join-P $outDir 'frpc.log') -RedirectStandardError (Join-P $outDir 'frpc.err')

Start-Sleep -Seconds 5

# 就绪探测要重试：CI 上建连 + 首次登录需要几秒，固定 sleep 会误判
$probePath = $OriginPath
if (Test-Path $envFile) {
    $probePath = [string](Get-Content $envFile -Raw | ConvertFrom-Json).OriginPath
}
if (-not $probePath) { $probePath = '/index.html' }

foreach ($probe in @(@{ Port = $ftPort; Host = 'bench.ftbench.net' }, @{ Port = $FrpRemotePort; Host = 'bench.ftbench.net' })) {
    $deadline = (Get-Date).AddSeconds(60)
    $code = ''
    while ((Get-Date) -lt $deadline) {
        $code = (& $CurlExe -s -o NUL -w '%{http_code}' --noproxy '*' --max-time 5 -H "Host: $($probe.Host)" "http://127.0.0.1:$($probe.Port)$probePath" 2>$null | Out-String).Trim()
        if ($code -eq '200') { break }
        Start-Sleep -Milliseconds 500
    }

    Write-Host "    port $($probe.Port) -> HTTP $code"
    if ($code -ne '200') { throw "端口 $($probe.Port) 未就绪" }
}

$rows = @()

function Measure-Round {
    param([string]$Framework, [int]$Port, [int]$Level, [System.Diagnostics.Process]$Server, [System.Diagnostics.Process]$Client)

    $outFile = Join-P $outDir ("{0}-{1}-r{2}.json" -f $Framework, $Level, $script:round)

    $serverCpuBefore = $Server.TotalProcessorTime
    $clientCpuBefore = $Client.TotalProcessorTime

    $runnerArgs = @('--connect', "127.0.0.1:$Port", '--host', 'bench.ftbench.net', '--path', '/bench/index.html',
        '--rps', "$Level", '--connections', "$Connections", '--warmup', "$Warmup", '--duration', "$Duration",
        '--out', $outFile, '--label', "$Framework-$Level")

    & $runner @runnerArgs | Out-Null
    $result = Get-Content $outFile -Raw | ConvertFrom-Json

    $Server.Refresh(); $Client.Refresh()
    $elapsed = [math]::Max(0.001, $result.DurationSeconds + $Warmup)

    [pscustomobject]@{
        Framework   = $Framework
        Round       = $script:round
        TargetRps   = $Level
        Connections = $Connections
        AchievedRps = $result.AchievedRps
        ErrorRate   = [math]::Round($result.ErrorRate * 100, 3)
        P50         = $result.LatencyMs.P50
        P99         = $result.LatencyMs.P99
        ServerCores = [math]::Round(($Server.TotalProcessorTime - $serverCpuBefore).TotalSeconds / $elapsed, 2)
        ClientCores = [math]::Round(($Client.TotalProcessorTime - $clientCpuBefore).TotalSeconds / $elapsed, 2)
        # 私有字节：进程真实占用（不含可共享的映射）；峰值工作集：历史峰值，反映瞬时水位
        ServerMemMB = [math]::Round($Server.PrivateMemorySize64 / 1MB, 1)
        ClientMemMB = [math]::Round($Client.PrivateMemorySize64 / 1MB, 1)
        TotalMemMB  = [math]::Round(($Server.PrivateMemorySize64 + $Client.PrivateMemorySize64) / 1MB, 1)
        ServerPeakMB = [math]::Round($Server.PeakWorkingSet64 / 1MB, 1)
        ClientPeakMB = [math]::Round($Client.PeakWorkingSet64 / 1MB, 1)
    }
}

try {
    for ($script:round = 1; $script:round -le $Rounds; $script:round++) {
        # 奇偶轮交换顺序，抵消"谁先跑谁吃亏"的偏置
        $order = if ($script:round % 2 -eq 1) { @('ft', 'frp-tcp') } else { @('frp-tcp', 'ft') }

        foreach ($level in $levels) {
            foreach ($framework in $order) {
                if ($framework -eq 'ft') {
                    $row = Measure-Round -Framework 'ft' -Port $ftPort -Level $level -Server $ftServer -Client $ftClient
                }
                else {
                    $row = Measure-Round -Framework 'frp-tcp' -Port $FrpRemotePort -Level $level -Server $frps -Client $frpc
                }

                $rows += $row
                Write-Host ("    {0,-8} r{1} {2,7} RPS -> 达成 {3,8}  错误 {4,6}%  p50 {5,7}  p99 {6,8}  内存 {7,6}/{8,6} MB" -f `
                    $row.Framework, $row.Round, $level, $row.AchievedRps, $row.ErrorRate, $row.P50, $row.P99, $row.ServerMemMB, $row.ClientMemMB)
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
$rows | Format-Table Framework, Round, TargetRps, AchievedRps, ErrorRate, P50, P99, ServerCores, ClientCores, ServerMemMB, ClientMemMB, TotalMemMB -AutoSize

# 多轮中位数：机器噪声大时，用中位数而不是单次值下结论
function Get-Median([double[]]$values) {
    $sorted = @($values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    return $sorted[[int][math]::Floor(($sorted.Count - 1) / 2)]
}

Write-Host ''
Write-Host '================ 多轮中位数（每个档位） ================' -ForegroundColor Green
$summary = @()
foreach ($group in ($rows | Group-Object Framework, TargetRps | Sort-Object Name)) {
    $g = $group.Group
    $summary += [pscustomobject]@{
        Framework   = $g[0].Framework
        TargetRps   = $g[0].TargetRps
        Rounds      = $g.Count
        AchievedRps = [math]::Round((Get-Median ($g.AchievedRps)), 1)
        ErrorRate   = [math]::Round((Get-Median ($g.ErrorRate)), 3)
        P50         = [math]::Round((Get-Median ($g.P50)), 3)
        P99         = [math]::Round((Get-Median ($g.P99)), 3)
        ServerCores = [math]::Round((Get-Median ($g.ServerCores)), 2)
        ClientCores = [math]::Round((Get-Median ($g.ClientCores)), 2)
        TotalMemMB  = [math]::Round((Get-Median ($g.TotalMemMB)), 1)
    }
}

$summary | Format-Table Framework, TargetRps, Rounds, AchievedRps, ErrorRate, P50, P99, ServerCores, ClientCores, TotalMemMB -AutoSize
$medianCsv = Join-P $outDir 'compare-tcp-median.csv'
$summary | Export-Csv $medianCsv -NoTypeInformation -Encoding utf8
Write-Host "中位数 CSV：$medianCsv"
Write-Host "CSV：$csv"

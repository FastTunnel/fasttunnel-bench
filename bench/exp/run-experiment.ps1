# FastTunnel vs frp v0.72.0 本地 HTTP 穿透对照压测
#
# 源站：默认读 bench\out\exp\env.json（由 setup-iis-admin.ps1 生成，指向 IIS:8080）；
#       没有 env.json 时自动拉起内置静态源站（127.0.0.1:18080）用于验证链路。
# 被测：FastTunnel（mux 数据面）与 frp v0.72.0（http 类型），两侧都关闭 TLS、日志降到指定级别。
# 压测：自家 FastTunnel.LoadRunner，定速档位，每级记录 成功/达成 RPS、错误率、落后比例、延迟分位。
#
# 用法：
#   powershell -File bench\exp\run-experiment.ps1
#   powershell -File bench\exp\run-experiment.ps1 -LevelsCsv 5000,10000,15000 -Duration 15
#   powershell -File bench\exp\run-experiment.ps1 -Frameworks ft -LogLevel Debug   # 排查链路
#   powershell -File bench\exp\run-experiment.ps1 -Frameworks frp -FrpPoolCount 256  # frp 双侧调平
#   powershell -File bench\exp\run-experiment.ps1 -AutoConnections:$false -Connections 256  # 固定并发
#
# 产物：bench\out\exp\results\*.json、results.csv、report.md

param(
    [string]$OriginHost = '127.0.0.1',
    [int]$OriginPort = 0,
    [string]$OriginPath = '',
    [string]$LevelsCsv = '5000,10000,15000,20000,25000,30000',
    [int]$Connections = 256,
    # 默认开启：连接数随档位放大。关掉它就退回固定 -Connections。
    # 为什么默认开：每条连接收完响应才发下一条，实际发压 ≈ 并发 ÷ 延迟。
    # 固定并发下高档位会"自己压不满"，p99 好看只是因为没发出去的那部分不进样本。
    [switch]$AutoConnections = $true,
    [int]$MaxAutoConnections = 1024,
    [double]$Warmup = 3,
    [double]$Duration = 9,
    [string[]]$Frameworks = @('ft', 'frp'),
    [double]$MaxErrorRate = 0.20,
    [ValidateSet('Fatal', 'Error', 'Warning', 'Information', 'Debug')]
    [string]$LogLevel = 'Fatal',
    # frp 的预建 work connection 数量（frpc 的 transport.poolCount）。0 = 不写，用 frp 默认值（1）。
    # 同时写 frps 的 transport.maxPoolCount：frps 默认只放行 5 条，
    # 只调客户端会被服务端夹回 5，"调平"等于没调（frp 源码 server/control.go 取 min）。
    [int]$FrpPoolCount = 0,
    # FastTunnel 源码仓库路径；不传则读环境变量 FASTTUNNEL_ROOT，再退回"与基准仓库同级"的 ./FastTunnel
    [string]$FastTunnelRoot = '',
    [switch]$SkipPublish)

$ErrorActionPreference = 'Stop'

# 跨平台定义（curl 名称、可执行后缀、frp 平台包、后台进程启动）
. (Join-Path $PSScriptRoot 'platform.ps1')

# -LevelsCsv 用逗号分隔字符串传：PowerShell 的 -File 模式会把 "5000,10000" 当成带千位分隔符的数字
$Levels = @($LevelsCsv -split '[,\s;]+' | Where-Object { $_ } | ForEach-Object { [int]$_ })
if ($Levels.Count -eq 0) { throw '-LevelsCsv 为空' }

# 池默认走出厂配置（frpc 1 / frps 5）。实测（本机配对 + CI run #45）把双侧池调到并发数
# 并没有让 frp 的 http 模式变好，反而更差，所以这里只提示、不擅自改用户传进来的值。
$frpPoolNote = ''
if ($FrpPoolCount -gt 0) {
    $maxLevelConns = if ($AutoConnections) {
        [int](($Levels | ForEach-Object { [math]::Min($MaxAutoConnections, [math]::Max(64, [int]($_ / 50))) }) | Measure-Object -Maximum).Maximum
    } else { $Connections }
    if ($FrpPoolCount -lt $maxLevelConns) {
        $frpPoolNote = "（本轮最大并发 $maxLevelConns，未调平）"
        Write-Host "==> frp 连接池 $FrpPoolCount 小于本轮最大并发 $maxLevelConns：多出来的 work connection 会被 frps 丢弃，要完全调平请传更大的 -FrpPoolCount" -ForegroundColor Yellow
    }
}

$expDir = $PSScriptRoot
$benchRoot = Split-Path (Split-Path $expDir -Parent) -Parent   # 本仓库根目录

if (-not $FastTunnelRoot) { $FastTunnelRoot = $env:FASTTUNNEL_ROOT }
if (-not $FastTunnelRoot) { $FastTunnelRoot = Join-P (Split-Path $benchRoot -Parent) 'FastTunnel' }
if (-not (Test-Path $FastTunnelRoot)) {
    throw "找不到 FastTunnel 源码仓库：$FastTunnelRoot。请用 -FastTunnelRoot 指定，或设置环境变量 FASTTUNNEL_ROOT。"
}
$repoRoot = (Resolve-Path $FastTunnelRoot).Path   # FastTunnel 源码根（只用来发布 Server/Client）
$outDir = Join-P $benchRoot 'out\exp'
$resultsDir = Join-P $outDir 'results'
$runDir = Join-P $outDir 'run'
$frpDir = Join-P $outDir "frp\frp_0.72.0_$FrpOsTag"
$runner = Join-P $benchRoot "bench\LoadRunner\bin\Release\net10.0\FastTunnel.LoadRunner$ExeSuffix"

$ftServerPort = 17270
$frpBindPort = 17000
$frpHttpPort = 17080
$ftHost = 'bench.ftbench.net'
$frpHost = 'bench.frpbench.net'
$ftDomain = 'ftbench.net'
$ftSub = 'bench'

New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

function Write-Step([string]$text) { Write-Host "==> $text" -ForegroundColor Cyan }
function Write-Ok([string]$text) { Write-Host "    $text" -ForegroundColor DarkGray }

# 配置文件必须是无 BOM 的 UTF-8：frp 的 TOML 解析器会把 BOM 当成非法字符
function Write-Utf8NoBom([string]$path, [string]$text) {
    [System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
}

function Show-LogTail([string]$path, [int]$lines = 12) {
    if (-not (Test-Path $path)) { return }
    Write-Host "    --- $path ---" -ForegroundColor DarkYellow
    Get-Content $path -Tail $lines -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
}

# 清掉上一轮残留的隧道进程，避免端口占用把本轮打成误报
Clear-StaleBenchProcesses

# ---------------- 0. 源站 ----------------
$envFile = Join-P $outDir 'env.json'
$originProcess = $null

if (Test-Path $envFile) {
    $envInfo = Get-Content $envFile -Raw | ConvertFrom-Json
    if ($OriginPort -eq 0) { $OriginPort = [int]$envInfo.OriginPort }
    if (-not $OriginPath) { $OriginPath = [string]$envInfo.OriginPath }
    Write-Step "源站来自 env.json：http://${OriginHost}:$OriginPort$OriginPath（mode=$($envInfo.Mode)）"
}

if ($OriginPort -eq 0 -and -not (Test-Path $envFile)) {
    # 用户可能手动配好了 IIS（没跑 setup 脚本）：先探测 8080 上是不是已经部署了我们的页面
    foreach ($candidate in @('/index.html', '/bench/index.html')) {
        $body = (& $CurlExe -s --noproxy '*' --max-time 3 "http://127.0.0.1:8080$candidate" 2>$null | Out-String)
        if ($body -match 'benchmark target') {
            $OriginPort = 8080
            $OriginPath = $candidate
            Write-Step "探测到本机 8080 已部署源站页面：http://127.0.0.1:8080$candidate（按 IIS 源站计）"
            break
        }
    }
}

if ($OriginPort -eq 0) {
    $OriginPort = 18080
    $OriginPath = '/index.html'

    # 首次运行（例如 CI 全新 checkout）时压测工具还没构建，先补一次构建
    if (-not (Test-Path $runner)) {
        Write-Step '构建压测工具（内置源站模式需要）'
        dotnet build (Join-P $benchRoot 'bench\LoadRunner\LoadRunner.csproj') -c Release --nologo -v q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'LoadRunner 构建失败（内置源站模式）' }
    }

    $originProcess = Start-BgProcess -FilePath $runner `
        -ArgumentList @('serve', '--port', "$OriginPort") `
        `
        -RedirectStandardOutput (Join-P $runDir 'origin.log') `
        -RedirectStandardError (Join-P $runDir 'origin.err')
    Start-Sleep -Milliseconds 800
    Write-Step "未找到 env.json，使用内置源站 127.0.0.1:$OriginPort$OriginPath（仅用于链路验证）"
}

if (-not $OriginPath) { $OriginPath = '/index.html' }

# ---------------- 1. 准备二进制 ----------------
if (-not $SkipPublish) {
    Write-Step '发布 FastTunnel Release / 构建压测工具'
    dotnet publish (Join-P $repoRoot 'FastTunnel.Server\FastTunnel.Server.csproj') -c Release `
        -o (Join-P $outDir 'ft-server') --nologo -v q -p:GeneratePackageOnBuild=false | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'FastTunnel.Server 发布失败' }

    dotnet publish (Join-P $repoRoot 'FastTunnel.Client\FastTunnel.Client.csproj') -c Release `
        -o (Join-P $outDir 'ft-client') --nologo -v q -p:GeneratePackageOnBuild=false | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'FastTunnel.Client 发布失败' }

    dotnet build (Join-P $benchRoot 'bench\LoadRunner\LoadRunner.csproj') -c Release --nologo -v q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'LoadRunner 构建失败' }
}

if (-not (Test-Path (Join-P $frpDir ('frps' + $ExeSuffix)))) {
    Write-Step "下载 frp v0.72.0（$FrpOsTag）"
    $archive = Join-P $outDir "download\frp_0.72.0_$FrpOsTag$FrpArchiveExt"
    New-Item -ItemType Directory -Path (Split-Path $archive -Parent) -Force | Out-Null
    Invoke-WebRequest -Uri "https://github.com/fatedier/frp/releases/download/v0.72.0/frp_0.72.0_$FrpOsTag$FrpArchiveExt" `
        -OutFile $archive -UseBasicParsing
    Expand-FrpArchive -ArchivePath $archive -Destination (Join-P $outDir 'frp')
}

# ---------------- 2. 生成配置 ----------------
function New-FastTunnelConfigs {
    param([string]$ServerDir, [string]$ClientDir)

    New-Item -ItemType Directory -Path (Join-P $ServerDir 'config') -Force | Out-Null
    New-Item -ItemType Directory -Path $ClientDir -Force | Out-Null

    # 日志降到 $LogLevel：正常压测期间不产生任何日志格式化/落盘
    $serverConfig = [ordered]@{
        Serilog    = @{ MinimumLevel = @{ Default = $LogLevel; Override = @{ Microsoft = 'Warning' } }; WriteTo = @() }
        FastTunnel = [ordered]@{
            BinPort              = $ftServerPort
            WebDomain            = $ftDomain
            EnableForward        = $false
            EnableMux            = $true
            EnforceSingleSession = $false
            Tls                  = @{ Enabled = $false; AutoGenerate = $false }
            Tokens               = @('BENCH_TOKEN')
            Bandwidth            = @{ DefaultBytesPerSecond = 0; BurstSeconds = 1; PerProxy = @{}; PerClient = @{} }
            Ops                  = @{ PublicEndpoints = $false }
            Abuse                = @{
                Ban   = @{ StateFile = (Join-P $runDir 'bans.json') }
                Audit = @{ FilePath = (Join-P $runDir 'audit.jsonl'); MemoryCapacity = 100 }
            }
        }
    }

    Write-Utf8NoBom (Join-P $ServerDir 'config\appsettings.json') ($serverConfig | ConvertTo-Json -Depth 10)

    $clientConfig = [ordered]@{
        Serilog    = @{ MinimumLevel = @{ Default = $LogLevel; Override = @{ Microsoft = 'Warning' } }; WriteTo = @() }
        FastTunnel = [ordered]@{
            Server       = [ordered]@{
                ServerAddr                = '127.0.0.1'
                ServerPort                = $ftServerPort
                Protocol                  = 'ws'   # 明文控制通道：与 frp 关闭 TLS 对齐
                AllowUntrustedCertificate = $true
            }
            Token        = 'BENCH_TOKEN'
            EnableMux    = $true
            MuxTransport = 'tcp'
            Webs         = @(@{ LocalIp = '127.0.0.1'; LocalPort = $OriginPort; SubDomain = $ftSub })
            Forwards     = @()
        }
    }

    Write-Utf8NoBom (Join-P $ClientDir 'appsettings.json') ($clientConfig | ConvertTo-Json -Depth 10)
}

function New-FrpConfigs {
    param([string]$Dir)

    New-Item -ItemType Directory -Path $Dir -Force | Out-Null

    $frpPoolLine = if ($FrpPoolCount -gt 0) { "transport.poolCount = $FrpPoolCount" } else { '' }

    # frps 侧必须同步放开上限：默认 maxPoolCount=5 会把客户端的 poolCount 夹到 5
    $frpsMaxPoolLine = if ($FrpPoolCount -gt 0) { "transport.maxPoolCount = $FrpPoolCount" } else { '' }

    $frps = @"
bindPort = $frpBindPort
vhostHTTPPort = $frpHttpPort

log.to = "disable"
log.level = "error"

transport.tls.force = false
$frpsMaxPoolLine
"@

    $frpc = @"
serverAddr = "127.0.0.1"
serverPort = $frpBindPort

log.to = "disable"
log.level = "error"

transport.tls.enable = false
$frpPoolLine

[[proxies]]
name = "bench-http"
type = "http"
localIP = "127.0.0.1"
localPort = $OriginPort
customDomains = ["$frpHost"]
"@

    Write-Utf8NoBom (Join-P $Dir 'frps.toml') $frps
    Write-Utf8NoBom (Join-P $Dir 'frpc.toml') $frpc
}

New-FastTunnelConfigs -ServerDir (Join-P $runDir 'ft-server') -ClientDir (Join-P $runDir 'ft-client')
New-FrpConfigs -Dir (Join-P $runDir 'frp')

# ---------------- 3. 工具函数 ----------------
function Assert-PortFree([int]$port, [string]$label) {
    # 跨平台：能连上就说明有人占用。先等一段时间，上一个实例可能刚被 kill
    try {
        Wait-PortFree -Port $port -TimeoutSeconds 20
    }
    catch {
        throw "端口 $port（$label）已被占用：请先停止占用进程，否则本次压测会打到旧实例上。"
    }
}

function Assert-ProcessAlive([System.Diagnostics.Process]$proc, [string]$label, [string]$logPath) {
    Start-Sleep -Milliseconds 700
    if ($proc.HasExited) {
        Write-Host "    [失败] $label 启动后立即退出（退出码 $($proc.ExitCode)）" -ForegroundColor Red
        Show-LogTail $logPath 20
        throw "$label 启动失败"
    }
}

function Wait-HttpOk {
    param([string]$Url, [string]$HostHeader, [double]$TimeoutSeconds = 60)

    # 用 curl 而不是 Invoke-WebRequest：后者会走系统代理/受限头处理，
    # 对「指定 Host 头访问 127.0.0.1」这种探测并不可靠（曾导致把代理的 404 当成隧道未就绪）。
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $code = ''

    while ((Get-Date) -lt $deadline) {
        $code = (& $CurlExe -s -o NUL -w '%{http_code}' --noproxy '*' --max-time 5 `
                -H "Host: $HostHeader" $Url 2>$null | Out-String).Trim()
        if ($code -eq '200') { return $true }
        Start-Sleep -Milliseconds 400
    }

    Write-Host "    最后一次探测：HTTP '$code'  URL=$Url  Host=$HostHeader" -ForegroundColor Yellow
    return $false
}

function Run-Level {
    param(
        [string]$Framework,
        [int]$Rps,
        [int]$Conns,
        [int]$Port,
        [string]$HostHeader,
        [System.Diagnostics.Process]$ServerProc,
        [System.Diagnostics.Process]$ClientProc
    )

    $outFile = Join-P $resultsDir ("{0}-rps{1}.json" -f $Framework, $Rps)
    if (Test-Path $outFile) { Remove-Item $outFile -Force }

    $serverCpuBefore = $null
    $clientCpuBefore = $null
    if ($ServerProc) { $ServerProc.Refresh(); $serverCpuBefore = $ServerProc.TotalProcessorTime }
    if ($ClientProc) { $ClientProc.Refresh(); $clientCpuBefore = $ClientProc.TotalProcessorTime }

    # 装了 hosts（本地 DNS）就用主机名解析；没装就退化成「连 127.0.0.1 + 指定 Host 头」，
    # 对虚拟主机路由来说两者等价，报告里会标注这次用的是哪种。
    $endpoint = @('--host', $HostHeader, '--port', "$Port")
    try {
        [System.Net.Dns]::GetHostAddresses($HostHeader) | Out-Null
    }
    catch {
        $endpoint = @('--connect', "127.0.0.1:$Port", '--host', $HostHeader)
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $exit = -1

    try {
        & $runner @endpoint --path $OriginPath `
            --rps $Rps --connections $Conns --warmup $Warmup --duration $Duration `
            --out $outFile --label "$Framework-$Rps" | Out-Null
        $exit = $LASTEXITCODE
    }
    catch {
        Write-Host "    [警告] 压测进程异常：$($_.Exception.Message)" -ForegroundColor Yellow
    }

    $sw.Stop()

    if (-not (Test-Path $outFile)) {
        # 压测工具没产出结果（参数错误 / 进程崩溃）：记一条失败行继续，不要中断整轮实验
        return [pscustomobject]@{
            Label           = "$Framework-$Rps"
            TargetRps       = $Rps
            AchievedRps     = 0
            SuccessRps      = 0
            AttemptedRps    = 0
            ErrorRate       = 1
            LateSendRatio   = 1
            ThroughputMiBps = 0
            Attempts        = 0
            Responses       = 0
            Success         = 0
            Errors          = 0
            ConnectFailures = 0
            LatencyMs       = [pscustomobject]@{ Mean = 0; P50 = 0; P90 = 0; P99 = 0; P999 = 0; Max = 0 }
            ServerCores     = $null
            ClientCores     = $null
            ExitCode        = $exit
        }
    }

    $result = Get-Content $outFile -Raw | ConvertFrom-Json

    $serverCores = $null
    $clientCores = $null
    if ($ServerProc) {
        $ServerProc.Refresh()
        $serverCores = [math]::Round(($ServerProc.TotalProcessorTime - $serverCpuBefore).TotalSeconds / $sw.Elapsed.TotalSeconds, 2)
    }

    if ($ClientProc) {
        $ClientProc.Refresh()
        $clientCores = [math]::Round(($ClientProc.TotalProcessorTime - $clientCpuBefore).TotalSeconds / $sw.Elapsed.TotalSeconds, 2)
    }

    $result | Add-Member -NotePropertyName ServerCores -NotePropertyValue $serverCores -Force
    $result | Add-Member -NotePropertyName ClientCores -NotePropertyValue $clientCores -Force

    # 内存：私有字节（进程真实占用）+ 峰值工作集（瞬时水位）。
    # 取该级结束时的稳态值，两侧口径一致。
    $serverMem = $null
    $clientMem = $null
    $serverPeak = $null
    $clientPeak = $null

    if ($ServerProc) {
        $ServerProc.Refresh()
        $serverMem = [math]::Round($ServerProc.PrivateMemorySize64 / 1MB, 1)
        $serverPeak = [math]::Round($ServerProc.PeakWorkingSet64 / 1MB, 1)
    }

    if ($ClientProc) {
        $ClientProc.Refresh()
        $clientMem = [math]::Round($ClientProc.PrivateMemorySize64 / 1MB, 1)
        $clientPeak = [math]::Round($ClientProc.PeakWorkingSet64 / 1MB, 1)
    }

    $result | Add-Member -NotePropertyName ServerMemMB -NotePropertyValue $serverMem -Force
    $result | Add-Member -NotePropertyName ClientMemMB -NotePropertyValue $clientMem -Force
    $result | Add-Member -NotePropertyName TotalMemMB -NotePropertyValue $(
        if ($null -ne $serverMem -and $null -ne $clientMem) { [math]::Round($serverMem + $clientMem, 1) } else { $null }) -Force
    $result | Add-Member -NotePropertyName ServerPeakMB -NotePropertyValue $serverPeak -Force
    $result | Add-Member -NotePropertyName ClientPeakMB -NotePropertyValue $clientPeak -Force
    $result | Add-Member -NotePropertyName ExitCode -NotePropertyValue $exit -Force
    $result | ConvertTo-Json -Depth 6 | Set-Content -Path $outFile -Encoding utf8

    return $result
}

# ---------------- 4. 逐个框架跑阶梯 ----------------
$all = @()

try {
    foreach ($framework in $Frameworks) {
        Write-Step "===== 被测对象：$framework ====="

        $serverProc = $null
        $clientProc = $null

        if ($framework -eq 'ft') {
            $serverExe = Join-P $outDir "ft-server\FastTunnel.Server$ExeSuffix"
            $clientExe = Join-P $outDir "ft-client\FastTunnel.Client$ExeSuffix"

            Assert-PortFree $ftServerPort 'FastTunnel 服务端'
            $serverProc = Start-BgProcess -FilePath $serverExe -WorkingDirectory (Join-P $runDir 'ft-server') `
                -RedirectStandardOutput (Join-P $runDir 'ft-server.log') -RedirectStandardError (Join-P $runDir 'ft-server.err')
            Assert-ProcessAlive $serverProc 'FastTunnel 服务端' (Join-P $runDir 'ft-server.err')
            Start-Sleep -Milliseconds 800
            $clientProc = Start-BgProcess -FilePath $clientExe -WorkingDirectory (Join-P $runDir 'ft-client') `
                -RedirectStandardOutput (Join-P $runDir 'ft-client.log') -RedirectStandardError (Join-P $runDir 'ft-client.err')
            Assert-ProcessAlive $clientProc 'FastTunnel 客户端' (Join-P $runDir 'ft-client.err')

            $entryPort = $ftServerPort
            $entryHost = $ftHost
        }
        elseif ($framework -eq 'frp') {
            $frpsExe = Join-P $frpDir ('frps' + $ExeSuffix)
            $frpcExe = Join-P $frpDir ('frpc' + $ExeSuffix)

            Assert-PortFree $frpBindPort 'frps bindPort'
            Assert-PortFree $frpHttpPort 'frps vhostHTTPPort'
            $serverProc = Start-BgProcess -FilePath $frpsExe -WorkingDirectory (Join-P $runDir 'frp') `
                -ArgumentList @('-c', (Join-P $runDir 'frp\frps.toml')) `
                -RedirectStandardOutput (Join-P $runDir 'frps.log') -RedirectStandardError (Join-P $runDir 'frps.err')
            Assert-ProcessAlive $serverProc 'frps' (Join-P $runDir 'frps.err')
            Start-Sleep -Milliseconds 800
            $clientProc = Start-BgProcess -FilePath $frpcExe -WorkingDirectory (Join-P $runDir 'frp') `
                -ArgumentList @('-c', (Join-P $runDir 'frp\frpc.toml')) `
                -RedirectStandardOutput (Join-P $runDir 'frpc.log') -RedirectStandardError (Join-P $runDir 'frpc.err')
            Assert-ProcessAlive $clientProc 'frpc' (Join-P $runDir 'frpc.err')

            $entryPort = $frpHttpPort
            $entryHost = $frpHost
        }
        else {
            Write-Host "未知框架 $framework，跳过" -ForegroundColor Yellow
            continue
        }

        try {
            $ready = Wait-HttpOk -Url "http://127.0.0.1:$entryPort$OriginPath" -HostHeader $entryHost -TimeoutSeconds 60
            if (-not $ready) {
                Write-Host "    [失败] $framework 隧道 60s 内没有就绪" -ForegroundColor Red
                Show-LogTail (Join-P $runDir 'ft-server.log')
                Show-LogTail (Join-P $runDir 'ft-server.err')
                Show-LogTail (Join-P $runDir 'ft-client.log')
                Show-LogTail (Join-P $runDir 'ft-client.err')
                Show-LogTail (Join-P $runDir 'frps.err')
                Show-LogTail (Join-P $runDir 'frpc.err')
                continue
            }

            Write-Ok "隧道就绪：http://$entryHost`:$entryPort$OriginPath"

            foreach ($level in $Levels) {
                # -AutoConnections：连接数随档位放大，让"单连接节奏"远大于服务时间，
                # 这样测到的延迟才是"按目标速率发压时的用户延迟"，而不是排队等槽位的时间。
                # 默认开启；用 -AutoConnections:$false 回到固定 -Connections。
                $conns = if ($AutoConnections) { [math]::Min($MaxAutoConnections, [math]::Max(64, [int]($level / 50))) } else { $Connections }

                Write-Host ("    --- {0} 目标 {1} RPS / 连接数 {2} ---" -f $framework, $level, $conns)
                $result = Run-Level -Framework $framework -Rps $level -Port $entryPort -HostHeader $entryHost `
                    -ServerProc $serverProc -ClientProc $clientProc -Conns $conns

                $all += [pscustomobject]@{
                    Framework   = $framework
                    TargetRps   = $result.TargetRps
                    Connections = $result.Connections
                    SuccessRps  = $result.SuccessRps
                    AchievedRps = $result.AchievedRps
                    # 与 bench.sh / report.py 一致：CSV 里的错误率、落后比例都用百分数（不是 0~1）
                    ErrorRate   = [math]::Round($result.ErrorRate * 100, 4)
                    LateSend    = [math]::Round($result.LateSendRatio * 100, 4)
                    P50         = $result.LatencyMs.P50
                    P90         = $result.LatencyMs.P90
                    P99         = $result.LatencyMs.P99
                    P999        = $result.LatencyMs.P999
                    Max         = $result.LatencyMs.Max
                    MiBps       = $result.ThroughputMiBps
                    ServerCores = $result.ServerCores
                    ClientCores = $result.ClientCores
                    LoadCores   = $result.SelfCores
                    ServerMem   = $result.ServerMemMB
                    ClientMem   = $result.ClientMemMB
                    TotalMem    = $result.TotalMemMB
                    Attempts    = $result.Attempts
                    Responses   = $result.Responses
                    Success     = $result.Success
                    Errors      = $result.Errors
                    ConnectFails= $result.ConnectFailures
                }

                Write-Ok ("成功 {0} RPS / 达成 {1} RPS / 错误率 {2:P2} / 落后 {3:P1} / p50 {4}ms / p99 {5}ms / p99.9 {6}ms" -f `
                    $result.SuccessRps, $result.AchievedRps, $result.ErrorRate, $result.LateSendRatio,
                    $result.LatencyMs.P50, $result.LatencyMs.P99, $result.LatencyMs.P999)

                if ($result.ErrorRate -gt $MaxErrorRate) {
                    Write-Host ("    [中止] 错误率 {0:P1} 超过阈值 {1:P0}，该框架不再往上加压" -f $result.ErrorRate, $MaxErrorRate) -ForegroundColor Yellow
                    break
                }
            }
        }
        finally {
            foreach ($proc in @($clientProc, $serverProc)) {
                if ($proc) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
            }

            Start-Sleep -Milliseconds 500
        }
    }
}
finally {
    if ($originProcess) { Stop-Process -Id $originProcess.Id -Force -ErrorAction SilentlyContinue }
}

# ---------------- 5. 汇总 ----------------
$csv = Join-P $outDir 'results.csv'
$all | Export-Csv -Path $csv -NoTypeInformation -Encoding utf8

$report = Join-P $outDir 'report.md'
$lines = @()
$lines += '# FastTunnel vs frp v0.72.0 本地 HTTP 穿透对照压测'
$lines += ''
$lines += "- 时间：$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
$lines += "- 源站：http://${OriginHost}:$OriginPort$OriginPath"

$modeDesc = if ($AutoConnections) { "随档位自适应（64~$MaxAutoConnections，目标 RPS / 50）" } else { "固定 $Connections" }
$lines += "- 压测：定速档位 $($Levels -join ' / ') RPS，连接数 $modeDesc，预热 ${Warmup}s，测量 ${Duration}s"
$lines += '- 两个框架均为明文：fasttunnel 用 ws 控制通道 + 明文 mux；frp 设 transport.tls.enable=false'
if ($FrpPoolCount -gt 0) {
    $lines += "- frp 连接池已双侧调平：frpc transport.poolCount = $FrpPoolCount，frps transport.maxPoolCount = $FrpPoolCount$frpPoolNote"
} else {
    $lines += '- frp 连接池为默认值（frpc poolCount=1，frps maxPoolCount=5）；如需调平请加 -FrpPoolCount'
}
$lines += ''
$lines += '![对比图](chart.svg)'
$lines += "- 日志：两侧都降到 $LogLevel（frp 为 log.level=error / log.to=disable）"
$lines += ''
$lines += '> 口径：**成功 RPS** 只数 200 响应，跨框架对比看这一列；**达成 RPS** 含隧道自己返回的非 200；'
$lines += '> **落后** 是发送时刻晚于计划 5ms 以上的请求占比，落后高说明这一档没真正压上去，此时 p99 偏低不可当结论。'
$lines += ''
$lines += '| 框架 | 目标 RPS | 连接数 | 成功 RPS | 达成 RPS | 错误率 | 落后 | p50(ms) | p90(ms) | p99(ms) | p99.9(ms) | 最大(ms) | MiB/s | 服务端核 | 客户端核 | 压测机核 | 服务端内存(MB) | 客户端内存(MB) |'
$lines += '|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|'
foreach ($row in $all) {
    $lines += ("| {0} | {1} | {2} | {3} | {4} | {5}% | {6}% | {7} | {8} | {9} | {10} | {11} | {12} | {13} | {14} | {15} | {16} | {17} |" -f `
        $row.Framework, $row.TargetRps, $row.Connections, $row.SuccessRps, $row.AchievedRps, ('{0:N2}' -f $row.ErrorRate), ('{0:N1}' -f $row.LateSend),
        $row.P50, $row.P90, $row.P99, $row.P999, $row.Max, $row.MiBps,
        $row.ServerCores, $row.ClientCores, $row.LoadCores, $row.ServerMem, $row.ClientMem)
}

$lines += ''
$lines += '## 同档位对比（成功 RPS 口径）'
$lines += ''
$lines += '| 目标 RPS | FastTunnel 成功 | frp 成功 | FastTunnel p99 | frp p99 | FastTunnel 错误率 | frp 错误率 | FastTunnel 落后 | frp 落后 |'
$lines += '|---|---|---|---|---|---|---|---|---|'
foreach ($level in $Levels) {
    $ft = $all | Where-Object { $_.Framework -eq 'ft' -and $_.TargetRps -eq $level } | Select-Object -First 1
    $frp = $all | Where-Object { $_.Framework -eq 'frp' -and $_.TargetRps -eq $level } | Select-Object -First 1
    if (-not $ft -and -not $frp) { continue }

    $lines += ("| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |" -f `
        $level,
        $(if ($ft) { $ft.SuccessRps } else { '-' }),
        $(if ($frp) { $frp.SuccessRps } else { '-' }),
        $(if ($ft) { $ft.P99 } else { '-' }),
        $(if ($frp) { $frp.P99 } else { '-' }),
        $(if ($ft) { '{0:N2}%' -f $ft.ErrorRate } else { '-' }),
        $(if ($frp) { '{0:N2}%' -f $frp.ErrorRate } else { '-' }),
        $(if ($ft) { '{0:N1}%' -f $ft.LateSend } else { '-' }),
        $(if ($frp) { '{0:N1}%' -f $frp.LateSend } else { '-' }))
}

# 饱和判定：成功速率不到目标 95% 或落后超过 5% 的档位，说明这一档没压上去
$saturated = @($all | Where-Object { [double]$_.SuccessRps -lt [double]$_.TargetRps * 0.95 -or [double]$_.LateSend -gt 5 })
if ($saturated.Count -gt 0) {
    $lines += ''
    $lines += '## 未压满的档位（这些行的 p99 不能当结论）'
    $lines += ''
    $lines += '| 框架 | 目标 RPS | 连接数 | 成功 RPS | 落后 | 说明 |'
    $lines += '|---|---|---|---|---|---|'
    foreach ($row in $saturated) {
        $why = if ([double]$row.LateSend -gt 5) { '发压机落后于计划，排队时间未计入延迟' } else { '实际成功速率低于目标（并发 ÷ 延迟 封顶）' }
        $lines += ("| {0} | {1} | {2} | {3} | {4}% | {5} |" -f $row.Framework, $row.TargetRps, $row.Connections, $row.SuccessRps, ('{0:N1}' -f $row.LateSend), $why)
    }
    $lines += ''
    $lines += '> 想测真实上限：加大 -MaxAutoConnections，或换更少的被测端开销；只要「落后」不为 0，这一档的延迟数字就偏乐观。'
}

$lines | Set-Content -Path $report -Encoding utf8

# 画对比图（失败不影响数据）
try {
    & (Join-P $PSScriptRoot 'make-charts.ps1') -CsvPath $csv -OutPath (Join-P $outDir 'chart.svg') | Out-Null
}
catch {
    Write-Host "    [警告] 图表生成失败：$($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ''
Write-Host '================ 结果 ================' -ForegroundColor Green
$all | Format-Table Framework, TargetRps, Connections, SuccessRps, AchievedRps, ErrorRate, LateSend, P50, P99, P999, MiBps, ServerCores, ClientCores -AutoSize
Write-Host "原始数据：$resultsDir"
Write-Host "CSV：$csv"
Write-Host "报告：$report"

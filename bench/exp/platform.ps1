# 跨平台公共定义：Windows 与 Linux 共用同一套编排脚本，差异都收在这里。
# 用法：在脚本开头 . (Join-Path $PSScriptRoot 'platform.ps1')

$IsWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
    [System.Runtime.InteropServices.OSPlatform]::Windows)

# 可执行文件后缀与 frp 发布包命名
$ExeSuffix = if ($IsWindowsHost) { '.exe' } else { '' }
$FrpOsTag = if ($IsWindowsHost) { 'windows_amd64' } else { 'linux_amd64' }
$FrpArchiveExt = if ($IsWindowsHost) { '.zip' } else { '.tar.gz' }

# Windows PowerShell 5.1 里 curl 是 Invoke-WebRequest 的别名，必须显式用 curl.exe；
# Linux 上就是 curl。
$CurlExe = if ($IsWindowsHost) { 'curl.exe' } else { 'curl' }

# Linux 上 Start-Process 没有 -WindowStyle 参数，统一走这个包装
function Start-BgProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        # 兼容 Start-Process 的参数名
        [Alias('ArgumentList')][string[]]$Arguments = @(),
        [string]$WorkingDirectory,
        # 兼容 Start-Process 的参数名，调用处不用改写
        [Alias('RedirectStandardOutput')][string]$StdOut,
        [Alias('RedirectStandardError')][string]$StdErr,
        [switch]$PassThru,
        [string]$WindowStyle
    )

    $params = @{ FilePath = $FilePath; PassThru = $true }

    if ($Arguments -and $Arguments.Count -gt 0) { $params.ArgumentList = $Arguments }
    if ($WorkingDirectory) { $params.WorkingDirectory = $WorkingDirectory }
    if ($StdOut) { $params.RedirectStandardOutput = $StdOut }
    if ($StdErr) { $params.RedirectStandardError = $StdErr }
    if ($IsWindowsHost) { $params.WindowStyle = 'Hidden' }

    return Start-Process @params
}

# 端口是否已被占用（有进程在 listen）。跨平台，不依赖 Get-NetTCPConnection。
function Test-PortOpen {
    param([int]$Port)

    $client = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $client.Connect('127.0.0.1', $Port)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($client) { $client.Dispose() }
    }
}

# 跨平台路径拼接：Windows 允许 /，Linux 只认 /，所以统一把子路径的分隔符归一化。
# 用法与 Join-Path 一致（两个参数）。
function Join-P {
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Child
    )

    $normalized = $Child -replace '\\', '/'
    return [System.IO.Path]::Combine($Parent, $normalized)
}

# frp 二进制名（frps/frpc，Windows 带 .exe）
function Get-FrpBinary {
    param([string]$FrpDir, [string]$Name)
    return Join-Path $FrpDir ($Name + $ExeSuffix)
}

# 解压 frp 发布包（zip 或 tar.gz）
function Expand-FrpArchive {
    param([string]$ArchivePath, [string]$Destination)

    # 目标目录必须先存在：tar -C 不会自己创建
    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    if ($ArchivePath.EndsWith('.zip')) {
        Expand-Archive -Path $ArchivePath -DestinationPath $Destination -Force
    }
    else {
        & tar -xzf $ArchivePath -C $Destination
        if ($LASTEXITCODE -ne 0) { throw "解压失败：$ArchivePath" }
    }
}

# 等待端口释放：上一个实例刚被 kill 时端口可能还没释放，直接 bind 会失败
function Wait-PortFree {
    param([int]$Port, [double]$TimeoutSeconds = 30)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-PortOpen -Port $Port)) { return }
        Start-Sleep -Milliseconds 300
    }

    throw "端口 $Port 在 ${TimeoutSeconds}s 内没有释放，请先停止占用进程。"
}

# 清掉上一次运行残留的进程：脚本异常退出时 finally 可能没跑到，
# 残留监听会让下一轮直接 bind 失败（CI 上表现为"隧道起不来"）。
function Clear-StaleBenchProcesses {
    foreach ($name in @('FastTunnel.Server', 'FastTunnel.Client', 'frps', 'frpc', 'FastTunnel.LoadRunner')) {
        $procs = @(Get-Process -Name $name -ErrorAction SilentlyContinue)
        foreach ($proc in $procs) {
            try { Stop-Process -Id $proc.Id -Force -ErrorAction Stop } catch { }
        }
        if ($procs.Count -gt 0) { Start-Sleep -Milliseconds 200 }
    }
}

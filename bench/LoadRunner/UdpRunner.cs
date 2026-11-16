// Licensed under the Apache License, Version 2.0 (the "License").
// You may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//     https://github.com/FastTunnel/FastTunnel/edit/v2/LICENSE
// Copyright (c) 2019 Gui.H

using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text.Json;
using System.Threading;

namespace FastTunnel.LoadRunner;

/// <summary>
/// UDP 对照压测的三件套：
///   serve-udp  内网 UDP echo 源站（两侧隧道都指向它）
///   udpping    UDP 就绪探测（发一个数据报，等回声）
///   udpload    定速 UDP 负载生成器（每 worker 一个 socket，闭环 echo）
///
/// 为什么要自己写而不是 iperf：需要「按目标 PPS 精确发压」+「逐包 RTT」+
/// 「把丢包和延迟分开」+「输出和 HTTP 模式同结构的 JSON」，这样 CSV / 报表 / 图表
/// 可以和 HTTP / TCP 复用同一套口径。
///
/// 语义与 HTTP 模式刻意保持一致（闭环 + 定速）：
/// - 一条 worker = 一个 UDP socket = 一个公网来源端点 = 隧道上的一条会话
///   （FastTunnel UdpProxyListener / frp udp session 都按来源端点建会话）。
/// - 每个数据报带 [magic][seq][sendTicks][filler]，回声原样返回。
///   收到 seq/sendTicks 都匹配的回声才算成功；超时算丢包。
/// - 吞吐 SuccessRps 只数有效回声（可比口径），ErrorRate ≈ 丢包率，
///   LateSendRatio 是定速落后（饱和信号），延迟是逐包 RTT 分位。
/// </summary>
internal static class UdpRunner
{
    // 数据报头：[magic 4][seq 8][sendTicks 8]，其后是填充到固定长度的 filler
    private const int HeaderSize = 20;
    private static readonly byte[] Magic = { (byte)'F', (byte)'U', (byte)'D', (byte)'P' };
    private const int DefaultPayloadSize = 128;

    // ==================== serve-udp：内网 UDP echo 源站 ====================

    public static int RunEcho(string[] args)
    {
        var port = 18081;
        for (var i = 1; i < args.Length; i++)
        {
            if (args[i] == "--port" && i + 1 < args.Length)
            {
                port = int.Parse(args[++i], CultureInfo.InvariantCulture);
            }
        }

        using var udp = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
        udp.Bind(new IPEndPoint(IPAddress.Any, port));
        var buffer = new byte[65535];
        var remote = (EndPoint)new IPEndPoint(IPAddress.Any, 0);

        Console.WriteLine($"udp echo listening on 0.0.0.0:{port}");
        Console.Out.Flush();

        while (true)
        {
            try
            {
                var n = udp.ReceiveFrom(buffer, ref remote);
                udp.SendTo(buffer, 0, n, SocketFlags.None, remote);
            }
            catch (SocketException)
            {
                // 偶发的 ICMP port unreachable 会打断 ReceiveFrom，忽略继续
            }
            catch (ObjectDisposedException)
            {
                break;
            }
        }
#pragma warning disable CS0162
        return 0;
#pragma warning restore CS0162
    }

    // ==================== udpping：UDP 就绪探测 ====================

    public static int RunPing(string[] args)
    {
        var address = IPAddress.Loopback;
        var port = 0;
        var timeoutMs = 2000;

        for (var i = 1; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--host":
                    address = IPAddress.Parse(args[++i]);
                    break;
                case "--port":
                    port = int.Parse(args[++i], CultureInfo.InvariantCulture);
                    break;
                case "--timeout":
                    timeoutMs = int.Parse(args[++i], CultureInfo.InvariantCulture);
                    break;
            }
        }

        if (port <= 0)
        {
            Console.Error.WriteLine("udpping 需要 --port");
            return 2;
        }

        var payload = BuildDatagram(1, Stopwatch.GetTimestamp(), DefaultPayloadSize);
        using var udp = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp)
        {
            ReceiveTimeout = timeoutMs,
            SendTimeout = timeoutMs,
        };

        try
        {
            udp.Connect(new IPEndPoint(address, port));
            var start = Stopwatch.GetTimestamp();
            udp.Send(payload);
            var buf = new byte[65535];
            while (true)
            {
                var n = udp.Receive(buf);
                if (IsEchoOf(buf, n, 1))
                {
                    var rtt = (Stopwatch.GetTimestamp() - start) * 1000.0 / Stopwatch.Frequency;
                    Console.WriteLine($"udp echo ok from {address}:{port} rtt={rtt:F3}ms");
                    return 0;
                }
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"udp echo 失败 {address}:{port}: {ex.Message}");
            return 1;
        }
    }

    // ==================== udpload：定速 UDP 负载生成器 ====================

    public static int RunLoad(string[] args)
    {
        UdpLoadOptions options;
        try
        {
            options = UdpLoadOptions.Parse(args);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.Message);
            Console.Error.WriteLine(UdpLoadOptions.Usage);
            return 2;
        }

        NativeMethods.TimeBeginPeriod(1);
        try
        {
            var result = Run(options);
            var json = JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true });
            if (options.OutPath != null)
            {
                File.WriteAllText(options.OutPath, json);
            }
            Console.WriteLine(json);
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 1;
        }
        finally
        {
            NativeMethods.TimeEndPeriod(1);
        }
    }

    private static UdpLoadResult Run(UdpLoadOptions options)
    {
        var pacer = new UdpPacer(options.Rps);
        using var stop = new CancellationTokenSource();
        var token = stop.Token;
        var runStart = Stopwatch.GetTimestamp();

        var workers = new UdpWorker[options.Connections];
        var threads = new Thread[options.Connections];
        for (var i = 0; i < workers.Length; i++)
        {
            workers[i] = new UdpWorker(i, options, pacer, token, runStart);
            threads[i] = new Thread(workers[i].Run)
            {
                IsBackground = true,
                Name = $"udpload-{i}",
            };
        }

        foreach (var thread in threads) thread.Start();

        var measureEnd = options.Warmup + options.Duration;
        var wall = Stopwatch.StartNew();
        var cpuBefore = Process.GetCurrentProcess().TotalProcessorTime;

        while (wall.Elapsed.TotalSeconds < measureEnd && !token.IsCancellationRequested)
        {
            Thread.Sleep(10);
        }

        var measuredSeconds = Math.Max(0.001, wall.Elapsed.TotalSeconds - options.Warmup);
        var cpuSeconds = (Process.GetCurrentProcess().TotalProcessorTime - cpuBefore).TotalSeconds;
        stop.Cancel();

        foreach (var thread in threads) thread.Join(TimeSpan.FromSeconds(15));

        var result = Summarize(options, workers, measuredSeconds);
        result.SelfCpuSeconds = Math.Round(cpuSeconds, 2);
        result.SelfCores = Math.Round(cpuSeconds / measuredSeconds, 2);
        return result;
    }

    private static UdpLoadResult Summarize(UdpLoadOptions options, UdpWorker[] workers, double measureSeconds)
    {
        var samples = new List<UdpSample>(1 << 16);
        foreach (var worker in workers) worker.CollectSamples(samples);

        var latencies = new List<double>(samples.Count);
        var attempts = 0;
        var responded = 0;
        var success = 0;
        var scheduled = 0;
        long bytes = 0;
        var lateSends = 0;
        var windowStart = options.Warmup;
        var windowEnd = options.Warmup + options.Duration;

        for (var i = 0; i < samples.Count; i++)
        {
            var sample = samples[i];
            if (sample.AtSeconds < windowStart || sample.AtSeconds >= windowEnd) continue;

            attempts++;
            if (sample.Scheduled)
            {
                scheduled++;
                if (sample.LateByMs > 5) lateSends++;
            }
            if (!sample.Responded) continue; // 丢包：进错误/丢包计数，不进延迟

            responded++;
            latencies.Add(sample.LatencyMs);
            bytes += sample.Bytes;
            if (sample.Ok) success++;
        }

        var sorted = latencies.ToArray();
        Array.Sort(sorted);

        var lossCount = attempts - responded;
        return new UdpLoadResult
        {
            Label = options.Label,
            TargetRps = options.Rps,
            Connections = options.Connections,
            WarmupSeconds = options.Warmup,
            DurationSeconds = Math.Round(measureSeconds, 2),
            Attempts = attempts,
            Responses = responded,
            Success = success,
            Errors = attempts - success,
            ConnectFailures = lossCount,
            LossCount = lossCount,
            LossRate = attempts == 0 ? 0 : Math.Round((double)lossCount / attempts, 6),
            ErrorRate = attempts == 0 ? 1 : Math.Round((double)(attempts - success) / attempts, 6),
            AttemptedRps = Math.Round(attempts / measureSeconds, 1),
            AchievedRps = Math.Round(responded / measureSeconds, 1),
            SuccessRps = Math.Round(success / measureSeconds, 1),
            ThroughputMiBps = Math.Round(bytes / 1024d / 1024d / measureSeconds, 3),
            LateSendRatio = scheduled == 0 ? 0 : Math.Round((double)lateSends / scheduled, 4),
            LatencyMs = new UdpLatencyStats
            {
                Mean = sorted.Length == 0 ? 0 : Math.Round(sorted.Average(), 3),
                P50 = Percentile(sorted, 0.50),
                P90 = Percentile(sorted, 0.90),
                P99 = Percentile(sorted, 0.99),
                P999 = Percentile(sorted, 0.999),
                Max = sorted.Length == 0 ? 0 : Math.Round(sorted[^1], 3),
            },
        };
    }

    private static double Percentile(double[] sorted, double percentile)
    {
        if (sorted.Length == 0) return 0;
        var index = Math.Clamp((int)Math.Ceiling(percentile * sorted.Length) - 1, 0, sorted.Length - 1);
        return Math.Round(sorted[index], 3);
    }

    // ==================== 数据报编解码 ====================

    private static byte[] BuildDatagram(long seq, long ticks, int payloadSize)
    {
        var size = Math.Max(HeaderSize, payloadSize);
        var buf = new byte[size];
        Magic.CopyTo(buf, 0);
        BinaryPrimitives.WriteInt64LittleEndian(buf.AsSpan(4, 8), seq);
        BinaryPrimitives.WriteInt64LittleEndian(buf.AsSpan(12, 8), ticks);
        // 确定性填充，便于回声校验内容没被隧道改写
        for (var i = HeaderSize; i < size; i++) buf[i] = (byte)(i * 31 + 7);
        return buf;
    }

    /// <summary>
    /// 回声是否是指定 seq 的数据报。seq 唯一标识本次在途数据报，足够配对；
    /// RTT 用本地记录的 sendTicks（下方 Worker 的 start）计算，比回声里的时间戳更准。
    /// 内容是否被隧道改写由 VerifyFiller 另外校验。
    /// </summary>
    private static bool IsEchoOf(byte[] buf, int n, long seq)
    {
        if (n < HeaderSize) return false;
        if (buf[0] != Magic[0] || buf[1] != Magic[1] || buf[2] != Magic[2] || buf[3] != Magic[3]) return false;
        var echoedSeq = BinaryPrimitives.ReadInt64LittleEndian(buf.AsSpan(4, 8));
        return echoedSeq == seq;
    }

    // ==================== 定速 ====================

    private sealed class UdpPacer
    {
        private readonly long _intervalTicks;
        private readonly long _startTicks;
        private long _slot;

        public UdpPacer(int rps)
        {
            _intervalTicks = Math.Max(1, Stopwatch.Frequency / Math.Max(1, rps));
            _startTicks = Stopwatch.GetTimestamp() + Stopwatch.Frequency / 5;
        }

        public long NextDueTicks() => _startTicks + Interlocked.Increment(ref _slot) * _intervalTicks;

        public static void WaitUntil(long dueTicks, CancellationToken token)
        {
            while (true)
            {
                var remaining = dueTicks - Stopwatch.GetTimestamp();
                if (remaining <= 0 || token.IsCancellationRequested) return;
                var ms = remaining * 1000.0 / Stopwatch.Frequency;
                if (ms >= 1) Thread.Sleep((int)ms);
                else Thread.Sleep(0);
            }
        }
    }

    // ==================== worker ====================

    private readonly struct UdpSample
    {
        public UdpSample(bool ok, bool responded, bool scheduled, double latencyMs, int bytes, double lateByMs, double atSeconds)
        {
            Ok = ok;
            Responded = responded;
            Scheduled = scheduled;
            LatencyMs = latencyMs;
            Bytes = bytes;
            LateByMs = lateByMs;
            AtSeconds = atSeconds;
        }
        public bool Ok { get; }
        public bool Responded { get; }
        public bool Scheduled { get; }
        public double LatencyMs { get; }
        public int Bytes { get; }
        public double LateByMs { get; }
        public double AtSeconds { get; }
    }

    private sealed class UdpWorker
    {
        private const int ReceiveSlackMs = 2; // 收到 seq 之后再多给一点时间收同包的迟到副本，忽略即可

        private readonly int _id;
        private readonly UdpLoadOptions _options;
        private readonly UdpPacer _pacer;
        private readonly CancellationToken _token;
        private readonly long _runStartTicks;
        private readonly List<UdpSample> _samples = new(8192);

        public UdpWorker(int id, UdpLoadOptions options, UdpPacer pacer, CancellationToken token, long runStartTicks)
        {
            _id = id;
            _options = options;
            _pacer = pacer;
            _token = token;
            _runStartTicks = runStartTicks;
        }

        public void CollectSamples(List<UdpSample> target)
        {
            lock (_samples) target.AddRange(_samples);
        }

        private double AtSeconds(long ticks) => (ticks - _runStartTicks) * 1.0 / Stopwatch.Frequency;

        public void Run()
        {
            // 让各来源端点错开建会话，避免同一瞬间把隧道的会话表打满
            Thread.Sleep(Math.Min(300, _id * 600 / Math.Max(1, _options.Connections)));

            Socket? socket = null;
            try
            {
                socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp)
                {
                    ReceiveTimeout = _options.TimeoutMs,
                    SendTimeout = _options.TimeoutMs,
                };
                socket.Connect(new IPEndPoint(_options.ConnectAddress, _options.ConnectPort));

                var buf = new byte[65535];
                var seq = 0L;

                while (!_token.IsCancellationRequested)
                {
                    var due = _pacer.NextDueTicks();
                    UdpPacer.WaitUntil(due, _token);
                    if (_token.IsCancellationRequested) break;

                    var lateBy = (Stopwatch.GetTimestamp() - due) * 1000.0 / Stopwatch.Frequency;
                    var start = Stopwatch.GetTimestamp();
                    seq++;
                    var payload = BuildDatagram(seq, start, _options.PayloadSize);
                    var responded = false;
                    var ok = false;
                    var bytes = 0;

                    try
                    {
                        socket.Send(payload);

                        // 直到拿到本次 seq 的回声或超时；期间可能收到上一次超时包的迟到回声，丢弃。
                        // socket.ReceiveTimeout 给出硬性上界，deadline 再兜一层：
                        // 连续丢弃错序回声时不能每次都重新等满一个完整超时。
                        var deadline = NowMs() + _options.TimeoutMs;
                        while (true)
                        {
                            var n = socket.Receive(buf);
                            if (IsEchoOf(buf, n, seq))
                            {
                                responded = true;
                                ok = VerifyFiller(buf, n, payload);
                                bytes = n;
                                break;
                            }
                            if (NowMs() >= deadline) break; // 迟到/错序的回声，算丢包
                        }

                        var latency = (Stopwatch.GetTimestamp() - start) * 1000.0 / Stopwatch.Frequency;
                        Record(new UdpSample(ok, responded, true, latency, bytes, lateBy, AtSeconds(start)));
                    }
                    catch (SocketException)
                    {
                        // 超时未收到回声 = 丢包
                        var latency = (Stopwatch.GetTimestamp() - start) * 1000.0 / Stopwatch.Frequency;
                        Record(new UdpSample(false, false, true, latency, 0, lateBy, AtSeconds(start)));
                        // socket 仍可复用（UDP 无连接状态），继续下一个数据报
                    }
                    catch (Exception)
                    {
                        var latency = (Stopwatch.GetTimestamp() - start) * 1000.0 / Stopwatch.Frequency;
                        Record(new UdpSample(false, responded, true, latency, 0, lateBy, AtSeconds(start)));
                        try { socket.Dispose(); } catch { }
                        socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp)
                        {
                            ReceiveTimeout = _options.TimeoutMs,
                            SendTimeout = _options.TimeoutMs,
                        };
                        socket.Connect(new IPEndPoint(_options.ConnectAddress, _options.ConnectPort));
                    }
                }
            }
            finally
            {
                try { socket?.Dispose(); } catch { }
            }
        }

        private static long NowMs() => Stopwatch.GetTimestamp() * 1000 / Stopwatch.Frequency;

        private static bool VerifyFiller(byte[] echoed, int n, byte[] sent)
        {
            if (n != sent.Length) return false;
            for (var i = HeaderSize; i < n; i++)
            {
                if (echoed[i] != sent[i]) return false;
            }
            return true;
        }

        private void Record(UdpSample sample)
        {
            lock (_samples) _samples.Add(sample);
        }
    }

    // ==================== 参数与结果 ====================

    private sealed class UdpLoadOptions
    {
        public string Label = "udpload";
        public IPAddress ConnectAddress = IPAddress.Loopback;
        public int ConnectPort = 0;
        public int Rps = 1000;
        public int Connections = 64;
        public double Warmup = 2;
        public double Duration = 5;
        public int TimeoutMs = 1000;
        public int PayloadSize = DefaultPayloadSize;
        public string? OutPath;

        public const string Usage =
            "用法: FastTunnel.LoadRunner udpload --connect 127.0.0.1:17290 --rps 5000 --connections 256 " +
            "--warmup 2 --duration 5 [--timeout 1000] [--payload-size 128] [--out result.json] [--label 名称]";

        public static UdpLoadOptions Parse(string[] args)
        {
            var options = new UdpLoadOptions();
            for (var i = 1; i < args.Length; i++)
            {
                var name = args[i];
                string Next() => i + 1 < args.Length ? args[++i] : throw new ArgumentException($"{name} 缺少取值");
                switch (name)
                {
                    case "--connect":
                        var connect = Next();
                        var separator = connect.LastIndexOf(':');
                        options.ConnectAddress = IPAddress.Parse(connect[..separator]);
                        options.ConnectPort = int.Parse(connect[(separator + 1)..], CultureInfo.InvariantCulture);
                        break;
                    case "--rps":
                        options.Rps = int.Parse(Next(), CultureInfo.InvariantCulture);
                        break;
                    case "--connections":
                        options.Connections = int.Parse(Next(), CultureInfo.InvariantCulture);
                        break;
                    case "--warmup":
                        options.Warmup = double.Parse(Next(), CultureInfo.InvariantCulture);
                        break;
                    case "--duration":
                        options.Duration = double.Parse(Next(), CultureInfo.InvariantCulture);
                        break;
                    case "--timeout":
                        options.TimeoutMs = int.Parse(Next(), CultureInfo.InvariantCulture);
                        break;
                    case "--payload-size":
                        options.PayloadSize = int.Parse(Next(), CultureInfo.InvariantCulture);
                        break;
                    case "--out":
                        options.OutPath = Next();
                        break;
                    case "--label":
                        options.Label = Next();
                        break;
                    default:
                        throw new ArgumentException($"未知参数 {name}");
                }
            }

            if (options.Rps <= 0 || options.Connections <= 0 || options.Duration <= 0 || options.ConnectPort <= 0)
            {
                throw new ArgumentException("rps / connections / duration / --connect 端口 必须大于 0");
            }
            if (options.PayloadSize < HeaderSize) options.PayloadSize = DefaultPayloadSize;
            return options;
        }
    }

    private sealed class UdpLoadResult
    {
        public string Label { get; set; } = string.Empty;
        public int TargetRps { get; set; }
        public int Connections { get; set; }
        public double WarmupSeconds { get; set; }
        public double DurationSeconds { get; set; }
        public int Attempts { get; set; }
        public int Responses { get; set; }
        public int Success { get; set; }
        public int Errors { get; set; }
        /// <summary>没收到回声的数据报数（UDP 里就是丢包数）。</summary>
        public int ConnectFailures { get; set; }
        public int LossCount { get; set; }
        public double LossRate { get; set; }
        public double ErrorRate { get; set; }
        public double AttemptedRps { get; set; }
        public double AchievedRps { get; set; }
        public double SuccessRps { get; set; }
        public double ThroughputMiBps { get; set; }
        public double LateSendRatio { get; set; }
        public double SelfCpuSeconds { get; set; }
        public double SelfCores { get; set; }
        public UdpLatencyStats LatencyMs { get; set; } = new();
    }

    private sealed class UdpLatencyStats
    {
        public double Mean { get; set; }
        public double P50 { get; set; }
        public double P90 { get; set; }
        public double P99 { get; set; }
        public double P999 { get; set; }
        public double Max { get; set; }
    }
}

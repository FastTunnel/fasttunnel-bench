#!/usr/bin/env bash
# FastTunnel 对照压测（Linux 主平台）
#
# 三种模式，双方使用同一种代理方式，避免"拿 ft 的 http 比 frp 的 tcp"这种错位：
#   http : FastTunnel Web(vhost) vs frp type=http
#   tcp  : FastTunnel Forwards(TCP) vs frp type=tcp
#   udp  : FastTunnel Forwards(UDP) vs frp type=udp
#
#   ./bench.sh http --levels 5000,10000,20000 --connections 128
#   ./bench.sh tcp  --levels 5000,10000,20000 --connections 128 --rounds 3
#   ./bench.sh udp  --levels 5000,10000,20000 --connections 128 --rounds 3
#
# 两套隧道同时在线，按 轮次 → 档位 → 框架 交替执行（奇偶轮交换先后），
# 这样单轮内的机器漂移会平摊到两侧，而不是"ft 全跑完再跑 frp"。
#
# 只依赖：bash、dotnet、curl、tar、python3（解析压测 JSON）、ss（排障）
set -euo pipefail

MODE="http"
LEVELS="5000,10000,20000"
CONNECTIONS="128"
WARMUP="3"
DURATION="10"
PREWARM="10"
ROUNDS="1"
# 每条连接收完响应才发下一条，实际发压 ≈ 并发 ÷ 延迟；固定并发压不到高档位，
# p99 会偏乐观。默认让并发随档位放大（目标 RPS / 50，上限 1024）。
AUTO_CONNS="1"
MAX_AUTO_CONNS="1024"
# frp 连接池：0 = 出厂默认（frpc poolCount=1 / frps maxPoolCount=5），和用户在官网下到的那份一致；
# auto = 双侧调平到本轮最大并发，数字 = 双侧都写这个值。调平实测并没有让 frp 变好（见下面 pool_need 处注释），
# 所以只在显式做这个实验时才传。
FRP_POOL="0"
FRAMEWORKS="ft,frp"
FASTTUNNEL_ROOT="${FASTTUNNEL_ROOT:-}"
FT_RELEASE=""
BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${BENCH_ROOT}/out/exp"

FT_BIN_PORT=17270
FT_FWD_PORT=17290
FT_UDP_PORT=17291
FRP_BIND_PORT=17000
FRP_HTTP_PORT=17080
FRP_TCP_PORT=17090
FRP_UDP_PORT=17091
ORIGIN_PORT=18080
UDP_ORIGIN_PORT=18081

FT_HOST="bench.ftbench.net"
FT_DOMAIN="ftbench.net"
FRP_HOST="bench.frpbench.net"
TOKEN="BENCH_TOKEN"
PAGE_PATH="/index.html"
LOG_LEVEL="Information"

while [[ $# -gt 0 ]]; do
    case "$1" in
        http|tcp|udp) MODE="$1"; shift ;;
        --levels) LEVELS="$2"; shift 2 ;;
        --connections) CONNECTIONS="$2"; shift 2 ;;
        --warmup) WARMUP="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --prewarm) PREWARM="$2"; shift 2 ;;
        --rounds) ROUNDS="$2"; shift 2 ;;
        --auto-connections) AUTO_CONNS="$2"; shift 2 ;;
        --max-auto-connections) MAX_AUTO_CONNS="$2"; shift 2 ;;
        --frameworks) FRAMEWORKS="$2"; shift 2 ;;
        --frp-pool) FRP_POOL="$2"; shift 2 ;;
        --log-level) LOG_LEVEL="$2"; shift 2 ;;
        --fasttunnel-root) FASTTUNNEL_ROOT="$2"; shift 2 ;;
        --ft-release) FT_RELEASE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "未知参数：$1" >&2; exit 2 ;;
    esac
done

# 只有走源码构建时才需要 FastTunnel 源码目录；用官方 Release 包时不需要
if [[ -z "${FASTTUNNEL_ROOT}" && -z "${FT_RELEASE}" ]]; then
    FASTTUNNEL_ROOT="$(cd "${BENCH_ROOT}/../FastTunnel" && pwd)" || {
        echo "找不到 FastTunnel 源码，请用 --fasttunnel-root 指定" >&2; exit 1; }
fi

RUN_DIR="${OUT}/run"
RUNNER="${BENCH_ROOT}/bench/LoadRunner/bin/Release/net10.0/FastTunnel.LoadRunner"
FRP_DIR="${OUT}/frp/frp_0.72.0_linux_amd64"
mkdir -p "${OUT}" "${RUN_DIR}" "${OUT}/results"

log()  { printf '\033[36m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31m[失败] %s\033[0m\n' "$*" >&2; }

PIDS=()
ORIGIN_PID=""
FT_SERVER_PID=""
FT_CLIENT_PID=""
FRPS_PID=""
FRPC_PID=""
cleanup() { for pid in "${PIDS[@]:-}"; do kill -9 "${pid}" 2>/dev/null || true; done; }
trap cleanup EXIT

prepare() {
    log "构建压测工具"
    if ! dotnet build "${BENCH_ROOT}/bench/LoadRunner/LoadRunner.csproj" -c Release --nologo -v q \
            > "${RUN_DIR}/build-runner.log" 2>&1; then
        tail -n 30 "${RUN_DIR}/build-runner.log" >&2; exit 1
    fi

    if [[ -n "${FT_RELEASE}" ]]; then
        # 用官方 Release 包，保证测的就是用户下载到的那份
        FT_SERVER_BIN="${OUT}/ft-release/FastTunnel-linux-x64/server/FastTunnel.Server"
        FT_CLIENT_BIN="${OUT}/ft-release/FastTunnel-linux-x64/client/FastTunnel.Client"
        if [[ ! -x "${FT_SERVER_BIN:-}" ]]; then
            log "下载 FastTunnel ${FT_RELEASE}（GitHub Release）"
            local zip="${OUT}/download/FastTunnel-linux-x64.zip"
            mkdir -p "${OUT}/download" "${OUT}/ft-release"
            curl -fsSL -o "${zip}" \
                "https://github.com/FastTunnel/FastTunnel/releases/download/${FT_RELEASE}/FastTunnel-linux-x64.zip" || {
                fail "下载失败：${FT_RELEASE}"; exit 1; }
            # 用 python3 解压，避免 runner 上没有 unzip
            python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
                "${zip}" "${OUT}/ft-release"
            # zip 顶层目录名不固定，直接按文件名找二进制；
            # 只取无后缀的 apphost（*.dll/*.pdb 同名），用 -print -quit 避免 head 提前退出触发 pipefail
            FT_SERVER_BIN="$(find "${OUT}/ft-release" -type f -name 'FastTunnel.Server' -print -quit)"
            FT_CLIENT_BIN="$(find "${OUT}/ft-release" -type f -name 'FastTunnel.Client' -print -quit)"
            if [[ -z "${FT_SERVER_BIN}" || -z "${FT_CLIENT_BIN}" ]]; then
                fail "解压后没找到二进制，目录内容："
                find "${OUT}/ft-release" -maxdepth 3 | head -n 30 >&2
                exit 1
            fi
        fi
        chmod +x "${FT_SERVER_BIN}" "${FT_CLIENT_BIN}"
    else
        log "发布 FastTunnel（源码构建）"
        FT_SERVER_BIN="${OUT}/ft-server/FastTunnel.Server"
        FT_CLIENT_BIN="${OUT}/ft-client/FastTunnel.Client"
        if ! dotnet publish "${FASTTUNNEL_ROOT}/FastTunnel.Server/FastTunnel.Server.csproj" \
                -c Release -o "${OUT}/ft-server" --nologo -v q > "${RUN_DIR}/publish-server.log" 2>&1; then
            tail -n 40 "${RUN_DIR}/publish-server.log" >&2; fail "FastTunnel.Server 发布失败"; exit 1
        fi
        if ! dotnet publish "${FASTTUNNEL_ROOT}/FastTunnel.Client/FastTunnel.Client.csproj" \
                -c Release -o "${OUT}/ft-client" --nologo -v q > "${RUN_DIR}/publish-client.log" 2>&1; then
            tail -n 40 "${RUN_DIR}/publish-client.log" >&2; fail "FastTunnel.Client 发布失败"; exit 1
        fi
    fi

    if [[ ! -x "${FRP_DIR}/frps" ]]; then
        log "下载 frp v0.72.0（linux_amd64）"
        local archive="${OUT}/download/frp_0.72.0_linux_amd64.tar.gz"
        mkdir -p "$(dirname "${archive}")" "${OUT}/frp"
        curl -fsSL -o "${archive}" \
            "https://github.com/fatedier/frp/releases/download/v0.72.0/frp_0.72.0_linux_amd64.tar.gz"
        tar -xzf "${archive}" -C "${OUT}/frp"
    fi

    chmod +x "${OUT}/ft-server/FastTunnel.Server" "${OUT}/ft-client/FastTunnel.Client" \
             "${FRP_DIR}/frps" "${FRP_DIR}/frpc" 2>/dev/null || true
}

write_configs() {
    mkdir -p "${RUN_DIR}/ft-server/config" "${RUN_DIR}/ft-client" "${RUN_DIR}/frp"

    local enable_forward="false"
    local webs="[]"
    local forwards="[]"
    if [[ "${MODE}" == "tcp" ]]; then
        enable_forward="true"
        forwards="[ { \"LocalPort\": ${ORIGIN_PORT}, \"LocalIp\": \"127.0.0.1\", \"RemotePort\": ${FT_FWD_PORT} } ]"
    elif [[ "${MODE}" == "udp" ]]; then
        # UDP 转发：Forwards[].Protocol=UDP，服务端 LoginHandler 自动起 UdpProxyListener 监听 RemotePort。
        # 内网目标指向 UDP echo 源站（18081），两侧隧道共享同一个源站。
        enable_forward="true"
        forwards="[ { \"LocalPort\": ${UDP_ORIGIN_PORT}, \"LocalIp\": \"127.0.0.1\", \"RemotePort\": ${FT_UDP_PORT}, \"Protocol\": \"UDP\" } ]"
    else
        webs="[ { \"LocalPort\": ${ORIGIN_PORT}, \"LocalIp\": \"127.0.0.1\", \"SubDomain\": \"bench\" } ]"
    fi

    # frp 的连接池开关必须写在 [[proxies]] 之前：TOML 里那会落进代理表，
    # 而 frp 的 per-proxy transport 没有 poolCount 字段，strict 模式（默认开）直接报错退出。
    local frpc_pool_line=""
    local frps_maxpool_line=""
    if [[ "${FRP_POOL}" != "0" && -n "${FRP_POOL}" ]]; then
        frpc_pool_line="transport.poolCount = ${FRP_POOL}"
        # frps 默认只放行 5 条 work connection（transport.maxPoolCount），
        # 不同步放开就等于把客户端的 poolCount 夹回 5。
        frps_maxpool_line="transport.maxPoolCount = ${FRP_POOL}"
    fi

    cat > "${RUN_DIR}/ft-server/config/appsettings.json" <<JSON
{
  "Serilog": { "MinimumLevel": { "Default": "${LOG_LEVEL}", "Override": { "Microsoft": "Warning" } }, "WriteTo": [] },
  "FastTunnel": {
    "BinPort": ${FT_BIN_PORT},
    "WebDomain": "${FT_DOMAIN}",
    "EnableForward": ${enable_forward},
    "EnableMux": true,
    "EnforceSingleSession": false,
    "Tls": { "Enabled": false, "AutoGenerate": false },
    "Tokens": [ "${TOKEN}" ],
    "Ops": { "PublicEndpoints": false },
    "Abuse": {
      "Ban": { "StateFile": "${RUN_DIR}/bans.json" },
      "Audit": { "FilePath": "${RUN_DIR}/audit.jsonl", "MemoryCapacity": 100 }
    }
  }
}
JSON

    cat > "${RUN_DIR}/ft-client/appsettings.json" <<JSON
{
  "Serilog": { "MinimumLevel": { "Default": "${LOG_LEVEL}", "Override": { "Microsoft": "Warning" } }, "WriteTo": [] },
  "FastTunnel": {
    "Server": {
      "ServerAddr": "127.0.0.1",
      "ServerPort": ${FT_BIN_PORT},
      "Protocol": "ws",
      "AllowUntrustedCertificate": true
    },
    "Token": "${TOKEN}",
    "EnableMux": true,
    "MuxTransport": "tcp",
    "Webs": ${webs},
    "Forwards": ${forwards}
  }
}
JSON

    # 日志口径与 FastTunnel 侧对齐：两侧都不落盘。
    # 之前 frp 是 log.to=console + info，每条 work connection 都要格式化+写文件，
    # 那是把 frp 的日志开销算进了被测成本。
    cat > "${RUN_DIR}/frp/frps.toml" <<TOML
bindPort = ${FRP_BIND_PORT}
vhostHTTPPort = ${FRP_HTTP_PORT}
log.to = "disable"
log.level = "error"
transport.tls.force = false
${frps_maxpool_line}
TOML

    cat > "${RUN_DIR}/frp/frpc.toml" <<TOML
serverAddr = "127.0.0.1"
serverPort = ${FRP_BIND_PORT}
log.to = "disable"
log.level = "error"
transport.tls.enable = false
${frpc_pool_line}
TOML

    if [[ "${MODE}" == "tcp" ]]; then
        cat >> "${RUN_DIR}/frp/frpc.toml" <<TOML

[[proxies]]
name = "bench-tcp"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${ORIGIN_PORT}
remotePort = ${FRP_TCP_PORT}
TOML
    elif [[ "${MODE}" == "udp" ]]; then
        cat >> "${RUN_DIR}/frp/frpc.toml" <<TOML

[[proxies]]
name = "bench-udp"
type = "udp"
localIP = "127.0.0.1"
localPort = ${UDP_ORIGIN_PORT}
remotePort = ${FRP_UDP_PORT}
TOML
    else
        cat >> "${RUN_DIR}/frp/frpc.toml" <<TOML

[[proxies]]
name = "bench-http"
type = "http"
localIP = "127.0.0.1"
localPort = ${ORIGIN_PORT}
customDomains = [ "${FRP_HOST}" ]
TOML
    fi
}

start_origin() {
    if [[ "${MODE}" == "udp" ]]; then
        log "启动内置 UDP echo 源站 127.0.0.1:${UDP_ORIGIN_PORT}"
        "${RUNNER}" serve-udp --port "${UDP_ORIGIN_PORT}" > "${RUN_DIR}/origin-udp.log" 2>&1 &
        PIDS+=($!)
        ORIGIN_PID=$!
    else
        log "启动内置源站 http://127.0.0.1:${ORIGIN_PORT}"
        "${RUNNER}" serve --port "${ORIGIN_PORT}" > "${RUN_DIR}/origin.log" 2>&1 &
        PIDS+=($!)
        ORIGIN_PID=$!
    fi
    sleep 1
}

start_ft() {
    ( cd "${RUN_DIR}/ft-server" && exec "${FT_SERVER_BIN}" >> "${RUN_DIR}/ft-server.log" 2>&1 ) &
    FT_SERVER_PID=$!
    PIDS+=("${FT_SERVER_PID}")
    sleep 1
    ( cd "${RUN_DIR}/ft-client" && exec "${FT_CLIENT_BIN}" >> "${RUN_DIR}/ft-client.log" 2>&1 ) &
    FT_CLIENT_PID=$!
    PIDS+=("${FT_CLIENT_PID}")
}

start_frp() {
    "${FRP_DIR}/frps" -c "${RUN_DIR}/frp/frps.toml" >> "${RUN_DIR}/frps.log" 2>&1 &
    FRPS_PID=$!
    PIDS+=("${FRPS_PID}")
    sleep 1
    "${FRP_DIR}/frpc" -c "${RUN_DIR}/frp/frpc.toml" >> "${RUN_DIR}/frpc.log" 2>&1 &
    FRPC_PID=$!
    PIDS+=("${FRPC_PID}")
}

# 就绪探测：失败时打印全量监听表 + 日志尾巴
wait_ready() {
    local port="$1" host="$2" name="$3" deadline code
    deadline=$(( SECONDS + 60 ))
    while (( SECONDS < deadline )); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' --max-time 5 \
                    -H "Host: ${host}" "http://127.0.0.1:${port}${PAGE_PATH}" || true)
        [[ "${code}" == "200" ]] && { log "${name} 就绪（${port}）"; return 0; }
        sleep 1
    done

    fail "${name} 未就绪：${port} 上 HTTP=${code}"
    echo '--- ss -ltnp（全量）---'
    ss -ltnp 2>/dev/null || echo '(ss 不可用)'
    # 隧道日志已经不落盘（与 FastTunnel 侧口径对齐），配置写错时只能靠 verify 报出来
    for bin in frps frpc; do
        exe="${FRP_DIR}/${bin}"
        cfg="${RUN_DIR}/frp/${bin}.toml"
        [[ -x "${exe}" && -f "${cfg}" ]] || continue
        echo "--- ${bin} verify ${cfg} ---"
        "${exe}" verify -c "${cfg}" 2>&1 | tail -n 5 || true
    done
    for f in "${RUN_DIR}"/ft-server.log "${RUN_DIR}"/ft-client.log "${RUN_DIR}"/frps.log "${RUN_DIR}"/frpc.log; do
        [[ -s "$f" ]] && { echo "--- $(basename "$f") ---"; tail -n 15 "$f"; }
    done
    return 1
}

# UDP 就绪探测：curl 走 TCP，探不到 UDP 监听；用 udpload 工具带的 echo 探针。
wait_ready_udp() {
    local port="$1" name="$2" deadline code
    deadline=$(( SECONDS + 60 ))
    while (( SECONDS < deadline )); do
        if "${RUNNER}" udpping --host 127.0.0.1 --port "${port}" --timeout 2000 >/dev/null 2>&1; then
            log "${name} 就绪（UDP ${port}）"
            return 0
        fi
        sleep 1
    done
    fail "${name} 未就绪：UDP ${port} 没有回声"
    echo '--- ss -lnup（UDP 监听）---'
    ss -lnup 2>/dev/null || echo '(ss 不可用)'
    for f in "${RUN_DIR}"/ft-server.log "${RUN_DIR}"/ft-client.log "${RUN_DIR}"/frps.log "${RUN_DIR}"/frpc.log; do
        [[ -s "$f" ]] && { echo "--- $(basename "$f") ---"; tail -n 15 "$f"; }
    done
    return 1
}

proc_rss_mb() { awk '/VmRSS/{printf "%.1f", $2/1024}' "/proc/$1/status" 2>/dev/null || echo 0; }
proc_cpu_ticks() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }

# 组装一次发压的 runner 参数：HTTP/TCP 用默认的请求-响应压测，UDP 走 udpload 子命令。
# 结果 JSON 的字段对齐（SuccessRps/AchievedRps/LatencyMs/...），下面的 python 解析两边通用。
load_once_args() {
    local port="$1" host="$2" level="$3" conns="$4" warmup="$5" duration="$6" out="$7" label="$8"
    if [[ "${MODE}" == "udp" ]]; then
        printf '%s\0' udpload --connect "127.0.0.1:${port}" --rps "${level}" --connections "${conns}" \
            --warmup "${warmup}" --duration "${duration}" --payload-size 128 \
            --out "${out}" --label "${label}"
    else
        printf '%s\0' --connect "127.0.0.1:${port}" --host "${host}" --path "${PAGE_PATH}" \
            --rps "${level}" --connections "${conns}" --warmup "${warmup}" --duration "${duration}" \
            --out "${out}" --label "${label}"
    fi
}

# 该档实际用的并发数：自适应时按目标速率放大，固定模式就返回 --connections
conns_for() {
    local level="$1" want
    [[ "${AUTO_CONNS}" == "1" ]] || { echo "${CONNECTIONS}"; return; }
    want=$(( level / 50 ))
    (( want < 64 )) && want=64
    (( want > MAX_AUTO_CONNS )) && want=${MAX_AUTO_CONNS}
    echo "${want}"
}

run_once() {
    local framework="$1" port="$2" host="$3" level="$4" server_pid="$5" client_pid="$6" round="$7" conns="$8"
    local out="${OUT}/results/${framework}-${level}-r${round}.json"
    local cpu_s0 cpu_s1 cpu_c0 cpu_c1 rss_s rss_c hz
    cpu_s0=$(proc_cpu_ticks "${server_pid}")
    cpu_c0=$(proc_cpu_ticks "${client_pid}")

    mapfile -d '' -t runner_args < <(load_once_args "${port}" "${host}" "${level}" "${conns}" \
        "${WARMUP}" "${DURATION}" "${out}" "${framework}-${level}")
    "${RUNNER}" "${runner_args[@]}" >/dev/null

    cpu_s1=$(proc_cpu_ticks "${server_pid}")
    cpu_c1=$(proc_cpu_ticks "${client_pid}")
    rss_s=$(proc_rss_mb "${server_pid}")
    rss_c=$(proc_rss_mb "${client_pid}")
    hz=$(getconf CLK_TCK)

    python3 - "${out}" "${framework}" "${level}" "${conns}" "${round}" \
        "$((cpu_s1-cpu_s0))" "$((cpu_c1-cpu_c0))" "${hz}" "${rss_s}" "${rss_c}" "${WARMUP}" <<'PY'
import json, sys
path, fw, level, conns, rnd, ticks_s, ticks_c, hz, rss_s, rss_c, warmup = sys.argv[1:12]
d = json.load(open(path))
dur = max(0.001, float(d.get("DurationSeconds", 0)) + float(warmup))
print(",".join([
    fw, level, conns, rnd,
    # 成功 RPS 只数 200，跨框架对比看这一列；达成 RPS 含隧道自己返回的非 200
    f'{d.get("SuccessRps", 0):.1f}',
    f'{d.get("AchievedRps", 0):.1f}',
    f'{d.get("ErrorRate", 0) * 100:.2f}',
    f'{d.get("LateSendRatio", 0) * 100:.2f}',
    str(d.get("ConnectFailures", 0)),
    f'{d.get("LatencyMs", {}).get("P50", 0):.3f}',
    f'{d.get("LatencyMs", {}).get("P99", 0):.3f}',
    f'{d.get("LatencyMs", {}).get("P999", 0):.3f}',
    # 键名是 ThroughputMiBps：之前写成 MiBps，这一列恒为 0
    f'{d.get("ThroughputMiBps", 0):.3f}',
    # 丢包率只对 UDP 有意义；HTTP/TCP 的 JSON 没有这个字段，默认 0
    f'{d.get("LossRate", 0) * 100:.2f}',
    # CPU 拆服务端/客户端；TotalCores 保留为合计，兼容 report.py 的旧列
    f'{int(ticks_s) / int(hz) / dur:.2f}',
    f'{int(ticks_c) / int(hz) / dur:.2f}',
    f'{(int(ticks_s) + int(ticks_c)) / int(hz) / dur:.2f}',
    rss_s, rss_c, f'{float(rss_s) + float(rss_c):.1f}',
]))
PY
}

prewarm() {
    local framework="$1" port="$2" host="$3" server_pid="$4" client_pid="$5" conns="$6"
    [[ "${PREWARM}" == "0" ]] && return 0
    local burst="${first_level}"
    (( burst > 2000 )) && burst=2000
    log "预热 ${framework}：${burst} RPS × ${PREWARM}s（JIT/连接池/GC 先跑热）"
    mapfile -d '' -t runner_args < <(load_once_args "${port}" "${host}" "${burst}" "${conns}" \
        "1" "${PREWARM}" "${OUT}/results/${framework}-prewarm.json" "${framework}-prewarm")
    "${RUNNER}" "${runner_args[@]}" >/dev/null || true
}

prepare

# frp 的连接池语义（2026-11-16 本机配对 + CI run #45 取证）：
# - 出厂默认 frpc poolCount=1 / frps maxPoolCount=5，服务端会丢弃多余的 work connection
#   （frps debug 日志 `work connection pool is full, discarding`）；
# - 但把双侧池调到并发数（--frp-pool auto）并不让 frp 变好：http 模式下每档落后 100%、
#   RSS 冲到 4020 MB，同一次运行的 tcp 模式同样池只有 394 MB、p50 0.185ms。
# 所以默认走出厂配置（用户装完就是这份），调平只当显式实验。
pool_need=${CONNECTIONS}
for level in ${LEVELS//,/ }; do
    want=$(conns_for "${level}")
    (( want > pool_need )) && pool_need=${want}
done
if [[ "${FRP_POOL}" == "auto" ]]; then
    FRP_POOL=${pool_need}
    log "frp 连接池显式双侧调平到本轮最大并发 ${FRP_POOL}（出厂默认是 1 / 5）"
elif [[ "${FRP_POOL}" != "0" && "${FRP_POOL}" != "auto" ]] && (( FRP_POOL < pool_need )); then
    log "frp 连接池 ${FRP_POOL} 小于本轮最大并发 ${pool_need}（按传入值原样测；要完全调平用 --frp-pool auto）"
fi

write_configs
start_origin

# 两套隧道同时在线：交替测的时候不能被"谁刚启动"影响
start_ft
start_frp

if [[ "${MODE}" == "tcp" ]]; then
    ft_entry_port="${FT_FWD_PORT}"
    frp_entry_port="${FRP_TCP_PORT}"
elif [[ "${MODE}" == "udp" ]]; then
    ft_entry_port="${FT_UDP_PORT}"
    frp_entry_port="${FRP_UDP_PORT}"
else
    ft_entry_port="${FT_BIN_PORT}"
    frp_entry_port="${FRP_HTTP_PORT}"
fi

# 裸 TCP 转发不做虚拟主机路由，两侧都发同一个 Host 头，保证请求字节一致（UDP 用不到 Host）
frp_entry_host="${FRP_HOST}"
[[ "${MODE}" == "tcp" ]] && frp_entry_host="${FT_HOST}"

if [[ "${MODE}" == "udp" ]]; then
    wait_ready_udp "${ft_entry_port}" "FastTunnel(${MODE})" || exit 1
    wait_ready_udp "${frp_entry_port}" "frp(${MODE})" || exit 1
else
    wait_ready "${ft_entry_port}" "${FT_HOST}" "FastTunnel(${MODE})" || exit 1
    wait_ready "${frp_entry_port}" "${frp_entry_host}" "frp(${MODE})" || exit 1
fi

CSV="${OUT}/results-${MODE}.csv"
echo 'Framework,TargetRps,Connections,Round,SuccessRps,AchievedRps,ErrorRate,LateSend,ConnectFails,P50,P99,P999,MiBps,LossRate,ServerCores,ClientCores,TotalCores,ServerMemMB,ClientMemMB,TotalMemMB' > "${CSV}"

first_level="${LEVELS%%,*}"
prewarm ft "${ft_entry_port}" "${FT_HOST}" "${FT_SERVER_PID}" "${FT_CLIENT_PID}" "$(conns_for "${first_level}")"
prewarm frp "${frp_entry_port}" "${frp_entry_host}" "${FRPS_PID}" "${FRPC_PID}" "$(conns_for "${first_level}")"

for (( round = 1; round <= ROUNDS; round++ )); do
    # 奇偶轮交换先后，抵消"谁先跑谁吃亏"的偏置
    if (( round % 2 == 1 )); then order=(ft frp); else order=(frp ft); fi

    for level in ${LEVELS//,/ }; do
        conns=$(conns_for "${level}")
        for fw in "${order[@]}"; do
            if [[ "${fw}" == "ft" ]]; then
                line=$(run_once ft "${ft_entry_port}" "${FT_HOST}" "${level}" "${FT_SERVER_PID}" "${FT_CLIENT_PID}" "${round}" "${conns}")
            else
                line=$(run_once frp "${frp_entry_port}" "${frp_entry_host}" "${level}" "${FRPS_PID}" "${FRPC_PID}" "${round}" "${conns}")
            fi
            echo "${line}" | tee -a "${CSV}"
        done
    done
done

report_mode="ladder"
(( ROUNDS > 1 )) && report_mode="compare"

python3 "${BENCH_ROOT}/bench/exp/report.py" --csv "${CSV}" --mode "${report_mode}" \
        --levels "${LEVELS}" --connections "${CONNECTIONS}" --rounds "${ROUNDS}" \
        --auto-connections "${AUTO_CONNS}" --frp-pool "${FRP_POOL}" --mode-name "${MODE}" \
        --out "${OUT}" --report "${OUT}/report-${MODE}.md"

log "完成：${MODE} 模式，${ROUNDS} 轮，结果在 ${OUT}"

#!/usr/bin/env bash
# FastTunnel 对照压测（Linux 主平台）
#
# 两种模式，双方使用同一种代理方式，避免"拿 ft 的 http 比 frp 的 tcp"这种错位：
#   http : FastTunnel Web(vhost) vs frp type=http
#   tcp  : FastTunnel Forwards(TCP) vs frp type=tcp
#
#   ./bench.sh http --levels 5000,10000,20000 --connections 128
#   ./bench.sh tcp  --levels 5000,10000,20000 --connections 128
#
# 只依赖：bash、dotnet、curl、tar、python3（解析压测 JSON）、ss（排障）
set -euo pipefail

MODE="http"
LEVELS="5000,10000,20000"
CONNECTIONS="128"
WARMUP="3"
DURATION="10"
PREWARM="10"
FRP_POOL="0"
FRAMEWORKS="ft,frp"
FASTTUNNEL_ROOT="${FASTTUNNEL_ROOT:-}"
FT_RELEASE=""
BENCH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="${BENCH_ROOT}/out/exp"

FT_BIN_PORT=17270
FT_FWD_PORT=17290
FRP_BIND_PORT=17000
FRP_HTTP_PORT=17080
FRP_TCP_PORT=17090
ORIGIN_PORT=18080

FT_HOST="bench.ftbench.net"
FT_DOMAIN="ftbench.net"
FRP_HOST="bench.frpbench.net"
TOKEN="BENCH_TOKEN"
PAGE_PATH="/index.html"
LOG_LEVEL="Information"

while [[ $# -gt 0 ]]; do
    case "$1" in
        http|tcp) MODE="$1"; shift ;;
        --levels) LEVELS="$2"; shift 2 ;;
        --connections) CONNECTIONS="$2"; shift 2 ;;
        --warmup) WARMUP="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --prewarm) PREWARM="$2"; shift 2 ;;
        --frameworks) FRAMEWORKS="$2"; shift 2 ;;
        --frp-pool) FRP_POOL="$2"; shift 2 ;;
        --log-level) LOG_LEVEL="$2"; shift 2 ;;
        --fasttunnel-root) FASTTUNNEL_ROOT="$2"; shift 2 ;;
        --ft-release) FT_RELEASE="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
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
    else
        webs="[ { \"LocalPort\": ${ORIGIN_PORT}, \"LocalIp\": \"127.0.0.1\", \"SubDomain\": \"bench\" } ]"
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

    cat > "${RUN_DIR}/frp/frps.toml" <<TOML
bindPort = ${FRP_BIND_PORT}
vhostHTTPPort = ${FRP_HTTP_PORT}
log.to = "console"
log.level = "info"
transport.tls.force = false
TOML

    cat > "${RUN_DIR}/frp/frpc.toml" <<TOML
serverAddr = "127.0.0.1"
serverPort = ${FRP_BIND_PORT}
log.to = "console"
log.level = "info"
transport.tls.enable = false
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

    if [[ "${FRP_POOL}" != "0" && -n "${FRP_POOL}" ]]; then
        echo "transport.poolCount = ${FRP_POOL}" >> "${RUN_DIR}/frp/frpc.toml"
    fi
}

start_origin() {
    log "启动内置源站 http://127.0.0.1:${ORIGIN_PORT}"
    "${RUNNER}" serve --port "${ORIGIN_PORT}" > "${RUN_DIR}/origin.log" 2>&1 &
    PIDS+=($!)
    ORIGIN_PID=$!
    sleep 1
}

start_ft() {
    ( cd "${RUN_DIR}/ft-server" && exec "${FT_SERVER_BIN}" >> "${RUN_DIR}/ft-server.log" 2>&1 ) &
    PIDS+=($!)
    sleep 1
    ( cd "${RUN_DIR}/ft-client" && exec "${FT_CLIENT_BIN}" >> "${RUN_DIR}/ft-client.log" 2>&1 ) &
    PIDS+=($!)
}

start_frp() {
    "${FRP_DIR}/frps" -c "${RUN_DIR}/frp/frps.toml" >> "${RUN_DIR}/frps.log" 2>&1 &
    PIDS+=($!)
    sleep 1
    "${FRP_DIR}/frpc" -c "${RUN_DIR}/frp/frpc.toml" >> "${RUN_DIR}/frpc.log" 2>&1 &
    PIDS+=($!)
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
    for f in "${RUN_DIR}"/ft-server.log "${RUN_DIR}"/ft-client.log "${RUN_DIR}"/frps.log "${RUN_DIR}"/frpc.log; do
        [[ -s "$f" ]] && { echo "--- $(basename "$f") ---"; tail -n 15 "$f"; }
    done
    return 1
}

proc_rss_mb() { awk '/VmRSS/{printf "%.1f", $2/1024}' "/proc/$1/status" 2>/dev/null || echo 0; }
proc_cpu_ticks() { awk '{print $14+$15}' "/proc/$1/stat" 2>/dev/null || echo 0; }

run_once() {
    local framework="$1" port="$2" host="$3" level="$4" server_pid="$5" client_pid="$6" tag="$7"
    local out="${OUT}/results/${framework}-${level}-${tag}.json"
    local cpu0 cpu1 rss_s rss_c hz
    cpu0=$(( $(proc_cpu_ticks "${server_pid}") + $(proc_cpu_ticks "${client_pid}") ))

    "${RUNNER}" --connect "127.0.0.1:${port}" --host "${host}" --path "${PAGE_PATH}" \
        --rps "${level}" --connections "${CONNECTIONS}" \
        --warmup "${WARMUP}" --duration "${DURATION}" \
        --out "${out}" --label "${framework}-${level}" >/dev/null

    cpu1=$(( $(proc_cpu_ticks "${server_pid}") + $(proc_cpu_ticks "${client_pid}") ))
    rss_s=$(proc_rss_mb "${server_pid}")
    rss_c=$(proc_rss_mb "${client_pid}")
    hz=$(getconf CLK_TCK)

    python3 - "${out}" "${framework}" "${level}" "${CONNECTIONS}" "$((cpu1-cpu0))" "${hz}" "${rss_s}" "${rss_c}" "${WARMUP}" <<'PY'
import json, sys
path, fw, level, conns, ticks, hz, rss_s, rss_c, warmup = sys.argv[1:10]
d = json.load(open(path))
dur = max(0.001, float(d.get("DurationSeconds", 0)) + float(warmup))
print(",".join([
    fw, level, conns,
    f'{d.get("AchievedRps", 0):.1f}',
    f'{d.get("ErrorRate", 0) * 100:.2f}',
    f'{d.get("LatencyMs", {}).get("P50", 0):.3f}',
    f'{d.get("LatencyMs", {}).get("P99", 0):.3f}',
    f'{d.get("LatencyMs", {}).get("P999", 0):.3f}',
    f'{d.get("MiBps", 0):.3f}',
    f'{int(ticks) / int(hz) / dur:.2f}',
    rss_s, rss_c, f'{float(rss_s) + float(rss_c):.1f}',
]))
PY
}

prewarm() {
    local framework="$1" port="$2" host="$3" server_pid="$4" client_pid="$5"
    [[ "${PREWARM}" == "0" ]] && return 0
    local burst="${first_level}"
    (( burst > 2000 )) && burst=2000
    log "预热 ${framework}：${burst} RPS × ${PREWARM}s（JIT/连接池/GC 先跑热）"
    "${RUNNER}" --connect "127.0.0.1:${port}" --host "${host}" --path "${PAGE_PATH}" \
        --rps "${burst}" --connections "${CONNECTIONS}" \
        --warmup 1 --duration "${PREWARM}" \
        --out "${OUT}/results/${framework}-prewarm.json" --label "${framework}-prewarm" >/dev/null || true
}

prepare
write_configs
start_origin

CSV="${OUT}/results-${MODE}.csv"
echo 'Framework,TargetRps,Connections,AchievedRps,ErrorRate,P50,P99,P999,MiBps,TotalCores,ServerMemMB,ClientMemMB,TotalMemMB' > "${CSV}"

first_level="${LEVELS%%,*}"

for fw in ${FRAMEWORKS//,/ }; do
    if [[ "${fw}" == "ft" ]]; then
        start_ft
        if [[ "${MODE}" == "tcp" ]]; then
            entry_port="${FT_FWD_PORT}"
        else
            entry_port="${FT_BIN_PORT}"
        fi
        wait_ready "${entry_port}" "${FT_HOST}" "FastTunnel(${MODE})" || exit 1
        server_pid=${PIDS[-2]}; client_pid=${PIDS[-1]}
        entry_host="${FT_HOST}"
    else
        start_frp
        if [[ "${MODE}" == "tcp" ]]; then
            entry_port="${FRP_TCP_PORT}"
        else
            entry_port="${FRP_HTTP_PORT}"
        fi
        wait_ready "${entry_port}" "${FRP_HOST}" "frp(${MODE})" || exit 1
        server_pid=${PIDS[-2]}; client_pid=${PIDS[-1]}
        entry_host="${FRP_HOST}"
        [[ "${MODE}" == "tcp" ]] && entry_host="${FT_HOST}"
    fi

    prewarm "${fw}" "${entry_port}" "${entry_host}" "${server_pid}" "${client_pid}"

    for level in ${LEVELS//,/ }; do
        line=$(run_once "${fw}" "${entry_port}" "${entry_host}" "${level}" "${server_pid}" "${client_pid}" "run")
        echo "${line}" | tee -a "${CSV}"
        echo "${line}" >> "${OUT}/results/${fw}-${level}.csv"
    done

    for pid in "${PIDS[@]}"; do
        [[ "${pid}" == "${ORIGIN_PID}" ]] && continue
        kill -9 "${pid}" 2>/dev/null || true
    done
    PIDS=("${ORIGIN_PID}")
    sleep 1
done

python3 "${BENCH_ROOT}/bench/exp/report.py" --csv "${CSV}" --mode ladder \
        --levels "${LEVELS}" --connections "${CONNECTIONS}" --out "${OUT}" \
        --report "${OUT}/report-${MODE}.md"

log "完成：${MODE} 模式，结果在 ${OUT}"

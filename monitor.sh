#!/usr/bin/env bash
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/monitor.conf}"

# -----------------------------
# Defaults
# -----------------------------
SERVER_IP=""
SERVER_PORT="8080"
SERVER_PATH="/metrics"
USE_HTTPS="0"
AGENT_ID="$(hostname 2>/dev/null || echo "unknown")"
AUTH_TOKEN=""
ENABLE_EXTERNAL_IP="1"
SSH_PORT="22"
INTERVAL="10"

# -----------------------------
# Config
# -----------------------------
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi

    : "${SERVER_IP:?SERVER_IP is required in monitor.conf}"
    : "${SERVER_PORT:?SERVER_PORT is required in monitor.conf}"

    SERVER_PATH="${SERVER_PATH:-/metrics}"
    USE_HTTPS="${USE_HTTPS:-0}"
    AGENT_ID="${AGENT_ID:-$(hostname 2>/dev/null || echo "unknown")}"
    AUTH_TOKEN="${AUTH_TOKEN:-}"
    ENABLE_EXTERNAL_IP="${ENABLE_EXTERNAL_IP:-1}"
    SSH_PORT="${SSH_PORT:-22}"
    INTERVAL="${INTERVAL:-10}"

    case "$SERVER_PATH" in
        /*) ;;
        *) SERVER_PATH="/$SERVER_PATH" ;;
    esac

    if [[ "$USE_HTTPS" == "1" ]]; then
        ENDPOINT="https://${SERVER_IP}:${SERVER_PORT}${SERVER_PATH}"
    else
        ENDPOINT="http://${SERVER_IP}:${SERVER_PORT}${SERVER_PATH}"
    fi
}

# -----------------------------
# Helpers
# -----------------------------
json_escape() {
    local s=${1-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\b'/\\b}
    s=${s//$'\f'/\\f}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

human_uptime() {
    local seconds="$1"
    local days hours mins
    days=$((seconds / 86400))
    hours=$(((seconds % 86400) / 3600))
    mins=$(((seconds % 3600) / 60))
    printf '%dd %02dh %02dm' "$days" "$hours" "$mins"
}

build_json_array_from_lines() {
    local input="$1"
    local line first=1 out="["

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if (( first )); then
            first=0
        else
            out+=','
        fi
        out+="\"$(json_escape "$line")\""
    done <<< "$input"

    out+="]"
    printf '%s' "$out"
}

build_top_cpu_json() {
    local line first=1 out="[" pid cmd cpu
    while read -r pid cmd cpu; do
        [[ -z "${pid:-}" ]] && continue
        if (( first )); then
            first=0
        else
            out+=','
        fi
        out+="{\"pid\":$pid,\"command\":\"$(json_escape "$cmd")\",\"cpu\":$cpu}"
    done < <(ps -eo pid=,comm=,%cpu= --sort=-%cpu 2>/dev/null | head -n 5)

    out+="]"
    printf '%s' "$out"
}

build_top_mem_json() {
    local line first=1 out="[" pid cmd mem rss
    while read -r pid cmd mem rss; do
        [[ -z "${pid:-}" ]] && continue
        if (( first )); then
            first=0
        else
            out+=','
        fi
        out+="{\"pid\":$pid,\"command\":\"$(json_escape "$cmd")\",\"mem\":$mem,\"rss_kb\":$rss}"
    done < <(ps -eo pid=,comm=,%mem=,rss= --sort=-%mem 2>/dev/null | head -n 5)

    out+="]"
    printf '%s' "$out"
}

post_json() {
    local payload="$1"

    command -v curl >/dev/null 2>&1 || return 0

    local curl_args=(
        --silent --show-error --fail
        --connect-timeout 3
        --max-time 7
        -X POST
        -H "Content-Type: application/json"
        --data "$payload"
    )

    if [[ -n "$AUTH_TOKEN" ]]; then
        curl_args+=(-H "Authorization: Bearer ${AUTH_TOKEN}")
    fi

    curl "${curl_args[@]}" "$ENDPOINT" >/dev/null 2>&1
}

# -----------------------------
# Static info
# -----------------------------
collect_static_info() {
    HOSTNAME_FQDN="$(hostname 2>/dev/null || echo "unknown")"
    HOSTNAME_SHORT="${HOSTNAME_FQDN%%.*}"

    OS_NAME="unknown"
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_NAME="${PRETTY_NAME:-${NAME:-unknown}}"
    fi

    KERNEL_RELEASE="$(uname -r 2>/dev/null || echo "unknown")"
    ARCHITECTURE="$(uname -m 2>/dev/null || echo "unknown")"
    CPU_MODEL="$(awk -F': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)"
    CPU_CORES="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"

    INTERNAL_IPS="$(hostname -I 2>/dev/null || true)"
    DEFAULT_IFACE="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5; exit}')"

    DNS_SERVERS=""
    if [[ -r /etc/resolv.conf ]]; then
        while read -r key value _; do
            [[ "$key" == "nameserver" ]] && DNS_SERVERS+="${value} "
        done < /etc/resolv.conf
        DNS_SERVERS="${DNS_SERVERS%" "}"
    fi

    EXTERNAL_IP="unavailable"
    if [[ "$ENABLE_EXTERNAL_IP" == "1" ]] && command -v curl >/dev/null 2>&1; then
        EXTERNAL_IP="$(curl -4 -fsS --max-time 2 https://api.ipify.org 2>/dev/null || true)"
        [[ -n "$EXTERNAL_IP" ]] || EXTERNAL_IP="unavailable"
    fi
}

print_static_info() {
    clear
    echo "=================================================="
    echo "BOOTSTRAP INFORMATION"
    echo "=================================================="
    echo "Agent ID      : $AGENT_ID"
    echo "Hostname      : $HOSTNAME_FQDN"
    echo "Short name    : $HOSTNAME_SHORT"
    echo "OS            : $OS_NAME"
    echo "Kernel        : $KERNEL_RELEASE"
    echo "Architecture  : $ARCHITECTURE"
    echo "CPU Model     : ${CPU_MODEL:-unknown}"
    echo "CPU Cores     : $CPU_CORES"
    echo "Default iface : ${DEFAULT_IFACE:-unknown}"
    echo "Internal IPs  : ${INTERNAL_IPS:-unavailable}"
    echo "External IP   : $EXTERNAL_IP"
    echo "DNS servers   : ${DNS_SERVERS:-unavailable}"
    echo "Endpoint      : $ENDPOINT"
    echo
}

build_bootstrap_json() {
    printf '{'
    printf '"type":"bootstrap",'
    printf '"agent_id":"%s",' "$(json_escape "$AGENT_ID")"
    printf '"hostname":"%s",' "$(json_escape "$HOSTNAME_FQDN")"
    printf '"short_hostname":"%s",' "$(json_escape "$HOSTNAME_SHORT")"
    printf '"os":"%s",' "$(json_escape "$OS_NAME")"
    printf '"kernel":"%s",' "$(json_escape "$KERNEL_RELEASE")"
    printf '"architecture":"%s",' "$(json_escape "$ARCHITECTURE")"
    printf '"cpu_model":"%s",' "$(json_escape "${CPU_MODEL:-unknown}")"
    printf '"cpu_cores":%s,' "$CPU_CORES"
    printf '"default_iface":"%s",' "$(json_escape "${DEFAULT_IFACE:-unknown}")"
    printf '"internal_ips":"%s",' "$(json_escape "${INTERNAL_IPS:-}")"
    printf '"external_ip":"%s",' "$(json_escape "$EXTERNAL_IP")"
    printf '"dns_servers":"%s"' "$(json_escape "${DNS_SERVERS:-}")"
    printf '}'
}

# -----------------------------
# State init
# -----------------------------
init_cpu_state() {
    local cpu user nice system idle iowait irq softirq steal guest guest_nice
    read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat

    PREV_CPU_TOTAL=$((user + nice + system + idle + iowait + irq + softirq + steal))
    PREV_CPU_IDLE=$((idle + iowait))

    PREV_CORE_TOTALS=()
    PREV_CORE_IDLES=()

    while read -r cpu user nice system idle iowait irq softirq steal guest guest_nice; do
        [[ "$cpu" =~ ^cpu[0-9]+$ ]] || continue
        idx="${cpu#cpu}"
        PREV_CORE_TOTALS[$idx]=$((user + nice + system + idle + iowait + irq + softirq + steal))
        PREV_CORE_IDLES[$idx]=$((idle + iowait))
    done < /proc/stat
}

init_network_state() {
    if [[ -z "${DEFAULT_IFACE:-}" ]] && command -v ip >/dev/null 2>&1; then
        DEFAULT_IFACE="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5; exit}')"
    fi

    if [[ -n "${DEFAULT_IFACE:-}" && -r "/sys/class/net/$DEFAULT_IFACE/statistics/rx_bytes" ]]; then
        PREV_RX_BYTES=$(<"/sys/class/net/$DEFAULT_IFACE/statistics/rx_bytes")
        PREV_TX_BYTES=$(<"/sys/class/net/$DEFAULT_IFACE/statistics/tx_bytes")
    else
        PREV_RX_BYTES=0
        PREV_TX_BYTES=0
    fi
}

# -----------------------------
# Dynamic metrics
# -----------------------------
collect_dynamic_metrics() {
    local cpu user nice system idle iowait irq softirq steal guest guest_nice
    local total idle_total diff_total diff_idle
    local idx

    read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    CPU_TOTAL_TICKS=$((user + nice + system + idle + iowait + irq + softirq + steal))
    CPU_IDLE_TICKS=$((idle + iowait))
    diff_total=$((CPU_TOTAL_TICKS - PREV_CPU_TOTAL))
    diff_idle=$((CPU_IDLE_TICKS - PREV_CPU_IDLE))

    if (( diff_total > 0 )); then
        CPU_TOTAL_PCT=$((100 * (diff_total - diff_idle) / diff_total))
    else
        CPU_TOTAL_PCT=0
    fi

    PREV_CPU_TOTAL=$CPU_TOTAL_TICKS
    PREV_CPU_IDLE=$CPU_IDLE_TICKS

    CPU_CORES_PCTS=()
    while read -r cpu user nice system idle iowait irq softirq steal guest guest_nice; do
        [[ "$cpu" =~ ^cpu[0-9]+$ ]] || continue
        idx="${cpu#cpu}"
        total=$((user + nice + system + idle + iowait + irq + softirq + steal))
        idle_total=$((idle + iowait))

        local prev_total="${PREV_CORE_TOTALS[$idx]:-0}"
        local prev_idle="${PREV_CORE_IDLES[$idx]:-0}"

        if (( prev_total > 0 )); then
            diff_total=$((total - prev_total))
            diff_idle=$((idle_total - prev_idle))
            if (( diff_total > 0 )); then
                CPU_CORES_PCTS[$idx]=$((100 * (diff_total - diff_idle) / diff_total))
            else
                CPU_CORES_PCTS[$idx]=0
            fi
        else
            CPU_CORES_PCTS[$idx]=0
        fi

        PREV_CORE_TOTALS[$idx]=$total
        PREV_CORE_IDLES[$idx]=$idle_total
    done < /proc/stat

    local mem_total mem_avail swap_total swap_free
    mem_total=0
    mem_avail=0
    swap_total=0
    swap_free=0

    while read -r key value unit; do
        case "$key" in
            MemTotal:) mem_total=$value ;;
            MemAvailable:) mem_avail=$value ;;
            SwapTotal:) swap_total=$value ;;
            SwapFree:) swap_free=$value ;;
        esac
    done < /proc/meminfo

    MEM_TOTAL_KB=$mem_total
    MEM_AVAILABLE_KB=$mem_avail
    MEM_USED_KB=$((mem_total - mem_avail))
    if (( mem_total > 0 )); then
        MEM_PCT=$((100 * MEM_USED_KB / mem_total))
    else
        MEM_PCT=0
    fi

    SWAP_TOTAL_KB=$swap_total
    SWAP_FREE_KB=$swap_free
    SWAP_USED_KB=$((swap_total - swap_free))
    if (( swap_total > 0 )); then
        SWAP_PCT=$((100 * SWAP_USED_KB / swap_total))
    else
        SWAP_PCT=0
    fi

    read -r LOAD_1M LOAD_5M LOAD_15M _ < /proc/loadavg

    UPTIME_SECONDS="${UPTIME_SECONDS:-0}"
    if read -r UPTIME_SECONDS _ < /proc/uptime; then
        UPTIME_SECONDS="${UPTIME_SECONDS%.*}"
    fi
    UPTIME_HUMAN="$(human_uptime "$UPTIME_SECONDS")"

    TEMP_C="N/A"
    for tfile in /sys/class/thermal/thermal_zone*/temp; do
        [[ -r "$tfile" ]] || continue
        raw_temp="$(<"$tfile")"
        [[ "$raw_temp" =~ ^[0-9]+$ ]] || continue
        TEMP_C=$((raw_temp / 1000))
        break
    done

    if command -v ss >/dev/null 2>&1; then
        TCP_TOTAL="$(ss -antH 2>/dev/null | awk 'END {print NR+0}')"
        TCP_ESTABLISHED="$(ss -antH state established 2>/dev/null | awk 'END {print NR+0}')"
        SSH_CONNECTIONS_RAW="$(ss -tnpH state established 2>/dev/null | awk '/sshd/ {print}')"
        SSH_CONNECTIONS_COUNT="$(printf '%s\n' "$SSH_CONNECTIONS_RAW" | awk 'END {print NR+0}')"
    else
        TCP_TOTAL=0
        TCP_ESTABLISHED=0
        SSH_CONNECTIONS_RAW=""
        SSH_CONNECTIONS_COUNT=0
    fi

    if command -v df >/dev/null 2>&1; then
        INODE_PCT="$(df -iP / 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5+0}')"
        INODE_PCT="${INODE_PCT:-0}"
    else
        INODE_PCT=0
    fi

    if [[ -n "${DEFAULT_IFACE:-}" && -r "/sys/class/net/$DEFAULT_IFACE/statistics/rx_bytes" ]]; then
        RX_NOW=$(<"/sys/class/net/$DEFAULT_IFACE/statistics/rx_bytes")
        TX_NOW=$(<"/sys/class/net/$DEFAULT_IFACE/statistics/tx_bytes")
        RX_BPS=$(((RX_NOW - PREV_RX_BYTES) / INTERVAL))
        TX_BPS=$(((TX_NOW - PREV_TX_BYTES) / INTERVAL))
        PREV_RX_BYTES=$RX_NOW
        PREV_TX_BYTES=$TX_NOW
    else
        RX_BPS=0
        TX_BPS=0
    fi

    LOGGED_USERS_RAW="$(who 2>/dev/null || true)"
    LOGGED_USERS_COUNT="$(printf '%s\n' "$LOGGED_USERS_RAW" | awk 'END {print NR+0}')"

    LAST_SSH_INACTIVE_RAW="$(last -i -F 2>/dev/null | awk '!/still logged in/ && !/wtmp begins/ {print; exit}')"

    TOP_CPU_JSON="$(build_top_cpu_json)"
    TOP_MEM_JSON="$(build_top_mem_json)"
}

# -----------------------------
# Console
# -----------------------------
render_console() {
    clear
    echo "=================================================="
    echo "LIVE MONITOR"
    echo "=================================================="
    echo "Agent ID      : $AGENT_ID"
    echo "Hostname      : $HOSTNAME_FQDN"
    echo "Endpoint      : $ENDPOINT"
    echo "Timestamp     : $(date '+%Y-%m-%d %H:%M:%S')"
    echo
    echo "CPU total     : ${CPU_TOTAL_PCT}%"
    echo "CPU per core   :"
    local i
    for i in "${!CPU_CORES_PCTS[@]}"; do
        printf '  core %-2s    : %s%%\n' "$i" "${CPU_CORES_PCTS[$i]}"
    done
    echo
    echo "RAM           : ${MEM_PCT}% (${MEM_USED_KB} KB used / ${MEM_TOTAL_KB} KB total)"
    echo "SWAP          : ${SWAP_PCT}% (${SWAP_USED_KB} KB used / ${SWAP_TOTAL_KB} KB total)"
    echo "Load average  : ${LOAD_1M} ${LOAD_5M} ${LOAD_15M}"
    echo "Uptime        : ${UPTIME_HUMAN}"
    echo "Temperature   : ${TEMP_C} C"
    echo
    echo "Network iface : ${DEFAULT_IFACE:-unknown}"
    echo "RX / TX       : ${RX_BPS} B/s / ${TX_BPS} B/s"
    echo
    echo "TCP total     : ${TCP_TOTAL}"
    echo "TCP ESTAB     : ${TCP_ESTABLISHED}"
    echo "SSH conns     : ${SSH_CONNECTIONS_COUNT}"
    echo "Inode usage   : ${INODE_PCT}%"
    echo
    echo "Logged users  : ${LOGGED_USERS_COUNT}"
    echo "${LOGGED_USERS_RAW:-none}"
    echo
    echo "Active SSH conns:"
    echo "${SSH_CONNECTIONS_RAW:-none}"
    echo
    echo "Last inactive SSH session:"
    echo "${LAST_SSH_INACTIVE_RAW:-none}"
    echo
    echo "Top CPU processes:"
    printf '%s\n' "$TOP_CPU_JSON" | sed 's/},{/},\n{/g'
    echo
    echo "Top memory processes:"
    printf '%s\n' "$TOP_MEM_JSON" | sed 's/},{/},\n{/g'
    echo "=================================================="
}

# -----------------------------
# JSON payloads
# -----------------------------
build_metrics_json() {
    local cpu_cores_json="[" first=1 i

    for i in "${!CPU_CORES_PCTS[@]}"; do
        if (( first )); then
            first=0
        else
            cpu_cores_json+=','
        fi
        cpu_cores_json+="${CPU_CORES_PCTS[$i]}"
    done
    cpu_cores_json+="]"

    local logged_users_json active_ssh_json
    logged_users_json="$(build_json_array_from_lines "$LOGGED_USERS_RAW")"
    active_ssh_json="$(build_json_array_from_lines "$SSH_CONNECTIONS_RAW")"

    printf '{'
    printf '"type":"metrics",'
    printf '"agent_id":"%s",' "$(json_escape "$AGENT_ID")"
    printf '"hostname":"%s",' "$(json_escape "$HOSTNAME_FQDN")"
    printf '"timestamp":"%s",' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    printf '"cpu":{'
    printf '"total_pct":%s,' "$CPU_TOTAL_PCT"
    printf '"cores_pct":%s' "$cpu_cores_json"
    printf '},'

    printf '"memory":{'
    printf '"used_kb":%s,' "$MEM_USED_KB"
    printf '"total_kb":%s,' "$MEM_TOTAL_KB"
    printf '"percent":%s' "$MEM_PCT"
    printf '},'

    printf '"swap":{'
    printf '"used_kb":%s,' "$SWAP_USED_KB"
    printf '"total_kb":%s,' "$SWAP_TOTAL_KB"
    printf '"percent":%s' "$SWAP_PCT"
    printf '},'

    printf '"load":{'
    printf '"1m":"%s",' "$(json_escape "$LOAD_1M")"
    printf '"5m":"%s",' "$(json_escape "$LOAD_5M")"
    printf '"15m":"%s"' "$(json_escape "$LOAD_15M")"
    printf '},'

    printf '"uptime_seconds":%s,' "$UPTIME_SECONDS"
    printf '"uptime_human":"%s",' "$(json_escape "$UPTIME_HUMAN")"
    printf '"temperature_c":"%s",' "$(json_escape "$TEMP_C")"

    printf '"network":{'
    printf '"iface":"%s",' "$(json_escape "${DEFAULT_IFACE:-}")"
    printf '"rx_bps":%s,' "$RX_BPS"
    printf '"tx_bps":%s' "$TX_BPS"
    printf '},'

    printf '"tcp":{'
    printf '"total":%s,' "$TCP_TOTAL"
    printf '"established":%s' "$TCP_ESTABLISHED"
    printf '},'

    printf '"inode_percent":%s,' "$INODE_PCT"
    printf '"logged_users_count":%s,' "$LOGGED_USERS_COUNT"
    printf '"logged_users":%s,' "$logged_users_json"
    printf '"active_ssh_connections_count":%s,' "$SSH_CONNECTIONS_COUNT"
    printf '"active_ssh_connections":%s,' "$active_ssh_json"
    printf '"last_inactive_ssh_raw":"%s",' "$(json_escape "$LAST_SSH_INACTIVE_RAW")"
    printf '"top_cpu":%s,' "$TOP_CPU_JSON"
    printf '"top_memory":%s' "$TOP_MEM_JSON"
    printf '}'
}

build_bootstrap_payload() {
    local internal_ips_json
    internal_ips_json="$(build_json_array_from_lines "$INTERNAL_IPS")"

    printf '{'
    printf '"type":"bootstrap",'
    printf '"agent_id":"%s",' "$(json_escape "$AGENT_ID")"
    printf '"hostname":"%s",' "$(json_escape "$HOSTNAME_FQDN")"
    printf '"short_hostname":"%s",' "$(json_escape "$HOSTNAME_SHORT")"
    printf '"os":"%s",' "$(json_escape "$OS_NAME")"
    printf '"kernel":"%s",' "$(json_escape "$KERNEL_RELEASE")"
    printf '"architecture":"%s",' "$(json_escape "$ARCHITECTURE")"
    printf '"cpu_model":"%s",' "$(json_escape "${CPU_MODEL:-unknown}")"
    printf '"cpu_cores":%s,' "$CPU_CORES"
    printf '"default_iface":"%s",' "$(json_escape "${DEFAULT_IFACE:-}")"
    printf '"internal_ips":%s,' "$internal_ips_json"
    printf '"external_ip":"%s",' "$(json_escape "$EXTERNAL_IP")"
    printf '"dns_servers":"%s",' "$(json_escape "${DNS_SERVERS:-}")"
    printf '"endpoint":"%s"' "$(json_escape "$ENDPOINT")"
    printf '}'
}

# -----------------------------
# Main
# -----------------------------
main() {
    load_config
    collect_static_info
    print_static_info

    local bootstrap_json
    bootstrap_json="$(build_bootstrap_payload)"
    post_json "$bootstrap_json" || true

    init_cpu_state
    init_network_state

    trap 'echo; echo "Stopped."; exit 0' INT TERM

    while true; do
        collect_dynamic_metrics
        render_console

        local metrics_json
        metrics_json="$(build_metrics_json)"
        post_json "$metrics_json" || true

        sleep "$INTERVAL"
    done
}

main "$@"

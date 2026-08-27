#!/usr/bin/env bash
set -uo pipefail

CONFIG_DEFAULT="/root/gost-ecmp-pathlock/cn/mtcp.conf"
CONFIG_KEYS=(
    ROUTE_ID UNIT ANCHOR_UNIT WATCHDOG_UNIT CHAIN_NAME ANCHOR_SERVICE
    DST PORT BUSINESS_PORT BUSINESS_PORTS ANCHOR_HOST ANCHOR_PORT
    ACCEPT_RTT_MS
    LIVE_RTT_WARN_MS LIVE_RTT_CRIT_MS LIVE_RTT_WARN_HOLD_SEC
    LIVE_RTT_CRIT_HOLD_SEC LIVE_RTT_RECOVER_MS LIVE_RTT_RECOVER_HOLD_SEC
    PREWARM_MAX_DRAWS RECOVERY_PREWARM_DRAWS DEGRADED_RETRY_DRAWS
    PREWARM_NO_SESSION_ATTEMPTS PREWARM_CONNECT_WAIT_SEC PREWARM_STABLE_REQUIRED
    PREWARM_STABLE_INTERVAL_SEC PREWARM_KILL_WAIT_SEC PREWARM_TOTAL_TIMEOUT_SEC
    ANCHOR_START_TIMEOUT_SEC ANCHOR_STABLE_REQUIRED ANCHOR_STABLE_INTERVAL_SEC
    ANCHOR_RETRY_SEC DEGRADED_RETRY_SEC DEGRADED_BUSY_DEFER_SEC BUSINESS_IDLE_HOLD_SEC
    WATCH_INTERVAL_SEC ZERO_GRACE_SEC REMOTE_PROBE_INTERVAL_SEC
    REMOTE_PROBE_TIMEOUT_SEC REMOTE_PROBE_ATTEMPTS DOWN_RETRY_SEC
    DATA_PROBE_ENABLED DATA_PROBE_INTERVAL_SEC DATA_PROBE_TIMEOUT_SEC
    DATA_PROBE_FAIL_THRESHOLD DATA_PROBE_RESTART_WINDOW_SEC DATA_PROBE_RESTART_MAX
    DATA_PROBE_BREAKER_OPEN_SEC
    STUCK_RESTART_AFTER_SEC RESTART_COOLDOWN_SEC MULTI_CONFIRM_COUNT
    PROCESS_RECOVERY_GRACE_SEC PROCESS_RECOVERY_INTERVAL_SEC PROCESS_RECOVERY_WINDOW_SEC PROCESS_RECOVERY_MAX
    PROCESS_BREAKER_OPEN_SEC
    STATE_DIR STATE_FILE STATUS_JSON EVENT_FILE RETENTION_SEC
)

load_config() {
    local cfg="${1:-$CONFIG_DEFAULT}"
    [[ -r "$cfg" ]] || { echo "config not readable: $cfg" >&2; return 1; }

    # watchdog 会重复加载配置；先清空已知键，避免删除配置项后继续沿用旧值。
    unset "${CONFIG_KEYS[@]}"
    # shellcheck disable=SC1090
    source "$cfg" || { echo "config invalid: $cfg" >&2; return 1; }

    ROUTE_ID="${ROUTE_ID:-${ANCHOR_UNIT:-route}}"
    ROUTE_ID="${ROUTE_ID%.service}"
    ROUTE_ID="${ROUTE_ID//[^A-Za-z0-9_-]/_}"
    [[ "$ROUTE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || {
        echo "invalid ROUTE_ID in config: $cfg" >&2
        return 1
    }
    CHAIN_NAME="${CHAIN_NAME:-chain-mtcp-$ROUTE_ID}"
    ANCHOR_SERVICE="${ANCHOR_SERVICE:-mtcp-anchor-$ROUTE_ID}"
    [[ "$CHAIN_NAME" =~ ^chain-mtcp-[A-Za-z0-9_-]+$ ]] || {
        echo "invalid CHAIN_NAME in config: $cfg" >&2
        return 1
    }
    [[ "$ANCHOR_SERVICE" =~ ^mtcp-anchor-[A-Za-z0-9_-]+$ ]] || {
        echo "invalid ANCHOR_SERVICE in config: $cfg" >&2
        return 1
    }

    local required
    for required in UNIT ANCHOR_UNIT DST PORT BUSINESS_PORT ANCHOR_HOST ANCHOR_PORT ACCEPT_RTT_MS; do
        if [[ -z "${!required:-}" ]]; then
            echo "$required missing in config: $cfg" >&2
            return 1
        fi
    done

    STATE_DIR="${STATE_DIR:-/root/gost-ecmp-pathlock/cn/state}"
    STATE_FILE="${STATE_FILE:-${STATE_DIR}/runtime.state}"
    STATUS_JSON="${STATUS_JSON:-${STATE_DIR}/status.json}"
    EVENT_FILE="${EVENT_FILE:-${STATE_DIR}/events.jsonl}"
    RETENTION_SEC="${RETENTION_SEC:-86400}"

    BUSINESS_PORTS="${BUSINESS_PORTS:-$BUSINESS_PORT}"
    BUSINESS_PORTS="${BUSINESS_PORTS//,/ }"
    local port seen=" " normalized="" found_primary=no
    for port in $BUSINESS_PORTS; do
        if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
            echo "invalid port in BUSINESS_PORTS: $port" >&2
            return 1
        fi
        [[ "$port" == "$ANCHOR_PORT" ]] && {
            echo "BUSINESS_PORTS must not contain ANCHOR_PORT: $port" >&2
            return 1
        }
        [[ "$port" == "$BUSINESS_PORT" ]] && found_primary=yes
        if [[ "$seen" != *" $port "* ]]; then
            normalized="${normalized:+$normalized }$port"
            seen+="$port "
        fi
    done
    [[ -n "$normalized" && "$found_primary" == yes ]] || {
        echo "BUSINESS_PORTS must include BUSINESS_PORT ($BUSINESS_PORT)" >&2
        return 1
    }
    BUSINESS_PORTS="$normalized"

    DATA_PROBE_ENABLED="${DATA_PROBE_ENABLED:-yes}"
    DATA_PROBE_INTERVAL_SEC="${DATA_PROBE_INTERVAL_SEC:-15}"
    DATA_PROBE_TIMEOUT_SEC="${DATA_PROBE_TIMEOUT_SEC:-3}"
    DATA_PROBE_FAIL_THRESHOLD="${DATA_PROBE_FAIL_THRESHOLD:-3}"
    DATA_PROBE_RESTART_WINDOW_SEC="${DATA_PROBE_RESTART_WINDOW_SEC:-600}"
    DATA_PROBE_RESTART_MAX="${DATA_PROBE_RESTART_MAX:-3}"
    DATA_PROBE_BREAKER_OPEN_SEC="${DATA_PROBE_BREAKER_OPEN_SEC:-600}"
    BUSINESS_IDLE_HOLD_SEC="${BUSINESS_IDLE_HOLD_SEC:-15}"
    PROCESS_RECOVERY_GRACE_SEC="${PROCESS_RECOVERY_GRACE_SEC:-10}"
    PROCESS_RECOVERY_INTERVAL_SEC="${PROCESS_RECOVERY_INTERVAL_SEC:-60}"
    PROCESS_RECOVERY_WINDOW_SEC="${PROCESS_RECOVERY_WINDOW_SEC:-600}"
    PROCESS_RECOVERY_MAX="${PROCESS_RECOVERY_MAX:-3}"
    PROCESS_BREAKER_OPEN_SEC="${PROCESS_BREAKER_OPEN_SEC:-600}"
    case "$DATA_PROBE_ENABLED" in
      yes|no) ;;
      *) echo "DATA_PROBE_ENABLED must be yes or no in config: $cfg" >&2; return 1 ;;
    esac
    local probe_key
    for probe_key in DATA_PROBE_INTERVAL_SEC DATA_PROBE_TIMEOUT_SEC DATA_PROBE_FAIL_THRESHOLD \
      DATA_PROBE_RESTART_WINDOW_SEC DATA_PROBE_RESTART_MAX DATA_PROBE_BREAKER_OPEN_SEC \
      BUSINESS_IDLE_HOLD_SEC PROCESS_RECOVERY_GRACE_SEC PROCESS_RECOVERY_INTERVAL_SEC PROCESS_RECOVERY_WINDOW_SEC \
      PROCESS_RECOVERY_MAX PROCESS_BREAKER_OPEN_SEC; do
        if [[ ! "${!probe_key}" =~ ^[1-9][0-9]*$ ]]; then
            echo "$probe_key must be a positive integer in config: $cfg" >&2
            return 1
        fi
    done
    mkdir -p "$STATE_DIR"
}

ensure_mtcp_runtime_dir() {
    local runtime_dir="${1:-${MTCP_RUNTIME_DIR:-/run/gost-ecmp-pathlock}}" canonical
    [[ "$runtime_dir" == /* && "$runtime_dir" != / && ! -L "$runtime_dir" ]] || {
        echo "invalid MTCP runtime directory: $runtime_dir" >&2
        return 1
    }
    if [[ -e "$runtime_dir" && ! -d "$runtime_dir" ]]; then
        echo "MTCP runtime path is not a directory: $runtime_dir" >&2
        return 1
    fi
    if [[ ! -d "$runtime_dir" ]]; then
        (umask 077; mkdir -p -- "$runtime_dir") || return 1
    fi
    canonical="$(cd -P -- "$runtime_dir" 2>/dev/null && pwd -P)" || return 1
    [[ "$canonical" == "$runtime_dir" ]] || {
        echo "MTCP runtime directory must be canonical: $canonical" >&2
        return 1
    }
    case "$canonical" in
        /bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
            echo "MTCP runtime directory is too broad: $canonical" >&2
            return 1
            ;;
    esac
    printf '%s\n' "$runtime_dir"
}

now_epoch() { date +%s; }
now_text() { date '+%F %T'; }

json_escape() {
    local s="${1:-}"
    s=${s//\\/\\\\}; s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

prune_events() {
    local now cutoff tmp
    now="$(now_epoch)"; cutoff=$((now - RETENTION_SEC))
    [[ -f "$EVENT_FILE" ]] || return 0
    tmp="${EVENT_FILE}.tmp.$$"
    awk -v cutoff="$cutoff" '
      { if (match($0, /"epoch":[0-9]+/)) { e=substr($0,RSTART+8,RLENGTH-8)+0; if (e>=cutoff) print $0 } }
    ' "$EVENT_FILE" > "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$EVENT_FILE"
}

log_event() {
    local state="${1:-UNKNOWN}" event="${2:-EVENT}" reason="${3:-}"
    local pid="${4:-0}" sport="${5:-}" minrtt="${6:-}" rtt="${7:-}" extra="${8:-}"
    local epoch ts
    epoch="$(now_epoch)"; ts="$(now_text)"
    printf '{"epoch":%s,"ts":"%s","state":"%s","event":"%s","reason":"%s","pid":%s,"sport":"%s","minrtt_ms":"%s","rtt_ms":"%s","extra":"%s"}\n' \
      "$epoch" "$(json_escape "$ts")" "$(json_escape "$state")" "$(json_escape "$event")" "$(json_escape "$reason")" \
      "${pid:-0}" "$(json_escape "$sport")" "$(json_escape "$minrtt")" "$(json_escape "$rtt")" "$(json_escape "$extra")" >> "$EVENT_FILE"
}

get_unit_main_pid() {
    local unit="$1" pid
    pid="$(systemctl show -p MainPID --value "$unit" 2>/dev/null || true)"
    case "$pid" in ''|*[!0-9]*) echo 0 ;; *) echo "$pid" ;; esac
}
# UNIT 由 load_config 从实例配置加载。
# shellcheck disable=SC2153
get_main_pid() { get_unit_main_pid "$UNIT"; }
get_anchor_pid() { get_unit_main_pid "$ANCHOR_UNIT"; }
service_is_active() { systemctl is-active --quiet "$UNIT"; }
anchor_is_active() { systemctl is-active --quiet "$ANCHOR_UNIT"; }

get_gost_outer_sports() {
    local pid="$1"
    (( pid > 0 )) || return 0
    ss -ntpH "dst ${DST}:${PORT}" 2>/dev/null |
      awk -v needle="pid=${pid}," '$1=="ESTAB" && index($0,needle) { ep=$4; sub(/^.*:/,"",ep); print ep }'
}
get_gost_outer_count() { get_gost_outer_sports "$1" | awk 'END {print NR+0}'; }
get_single_sport() {
    local -a sports=()
    mapfile -t sports < <(get_gost_outer_sports "$1")
    (( ${#sports[@]} == 1 )) || return 1
    printf '%s\n' "${sports[0]}"
}

get_tcp_info() {
    local sport="$1" raw minrtt="" rtt=""
    raw="$(ss -tinH "dst ${DST}:${PORT} sport = :${sport}" 2>/dev/null | tr '\n' ' ')"
    [[ "$raw" =~ minrtt:([0-9.]+) ]] && minrtt="${BASH_REMATCH[1]}"
    [[ "$raw" =~ rtt:([0-9.]+)/[0-9.]+ ]] && rtt="${BASH_REMATCH[1]}"
    printf '%s|%s\n' "$minrtt" "$rtt"
}

is_lt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a<b)}'; }
is_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }

get_business_conn_count() {
    local pid="$1"
    (( pid > 0 )) || { echo 0; return; }
    # 单次抓取避免逐端口查询之间的时间差；只统计当前 GOST PID 的本地业务入口。
    ss -ntpH state established 2>/dev/null |
      awk -v needle="pid=${pid}," -v ports="$BUSINESS_PORTS" '
        BEGIN { nports=split(ports,p,/ +/); for (i=1;i<=nports;i++) wanted[p[i]]=1 }
        index($0,needle) {
          ep=$4; sub(/^.*:/,"",ep)
          if (wanted[ep]) n++
        }
        END { print n+0 }
      '
}

get_anchor_conn_count() {
    local apid="$1"
    (( apid > 0 )) || { echo 0; return; }
    ss -ntpH "dst ${ANCHOR_HOST}:${ANCHOR_PORT}" 2>/dev/null |
      awk -v needle="pid=${apid}," '$1=="ESTAB" && index($0,needle){n++} END{print n+0}'
}

anchor_is_established() {
    local apid count
    apid="$(get_anchor_pid)"; (( apid > 0 )) || return 1
    count="$(get_anchor_conn_count "$apid")"
    [[ "$count" == "1" ]]
}

stop_anchor() {
    systemctl stop "$ANCHOR_UNIT" >/dev/null 2>&1 || true
}

start_anchor() {
    systemctl reset-failed "$ANCHOR_UNIT" >/dev/null 2>&1 || true
    systemctl start "$ANCHOR_UNIT" >/dev/null 2>&1
}

ensure_anchor() {
    local deadline stable=0 apid count
    start_anchor || return 1
    deadline=$((SECONDS + ${ANCHOR_START_TIMEOUT_SEC:-8}))
    while (( SECONDS < deadline )); do
        apid="$(get_anchor_pid)"
        count="$(get_anchor_conn_count "$apid")"
        if (( apid > 0 && count == 1 )); then
            ((stable++))
            if (( stable >= ${ANCHOR_STABLE_REQUIRED:-2} )); then return 0; fi
        else
            stable=0
        fi
        sleep "${ANCHOR_STABLE_INTERVAL_SEC:-1}"
    done
    return 1
}

remote_tcp_reachable() {
    local i attempts="${REMOTE_PROBE_ATTEMPTS:-2}"
    for ((i=1;i<=attempts;i++)); do
        if timeout "${REMOTE_PROBE_TIMEOUT_SEC:-2}" bash -c "exec 3<>/dev/tcp/${DST}/${PORT}" >/dev/null 2>&1; then return 0; fi
        sleep 0.2
    done
    return 1
}

# 经本地 Anchor 入口建立一个新的 logical stream，并验证 payload 能沿当前
# chain-mtcp -> outer -> Remote echo endpoint 完成一次双向传输。
data_plane_probe() {
    local host="${ANCHOR_HOST:-127.0.0.1}"
    local port="${ANCHOR_PORT:-12001}"
    local timeout_sec="${DATA_PROBE_TIMEOUT_SEC:-3}"

    timeout "$timeout_sec" bash -c '
        exec 3<>"/dev/tcp/${1}/${2}" || exit 1
        printf "P" >&3 || exit 1
        reply=""
        IFS= read -r -n 1 reply <&3 || exit 1
        [[ "$reply" == "P" ]]
    ' _ "$host" "$port" >/dev/null 2>&1
}

kill_outer_sport() {
    local pid="$1" sport="$2" current count
    count="$(get_gost_outer_count "$pid")"; [[ "$count" == "1" ]] || return 1
    current="$(get_single_sport "$pid" 2>/dev/null || true)"; [[ "$current" == "$sport" ]] || return 1
    ss -K "dst ${DST}:${PORT} sport = :${sport}" >/dev/null 2>&1
}

wait_outer_gone() {
    local pid="$1" old_sport="$2" timeout_sec="$3" deadline current
    deadline=$((SECONDS + timeout_sec))
    while (( SECONDS < deadline )); do
        current="$(get_single_sport "$pid" 2>/dev/null || true)"
        [[ -z "$current" || "$current" != "$old_sport" ]] && return 0
        sleep 0.1
    done
    return 1
}

kill_route_outers() {
    local pid="$1" sport killed=0
    local -a sports=()
    (( pid > 0 )) || return 1
    mapfile -t sports < <(get_gost_outer_sports "$pid")
    (( ${#sports[@]} > 0 )) || return 1
    for sport in "${sports[@]}"; do
        if ss -K "dst ${DST}:${PORT} sport = :${sport}" >/dev/null 2>&1; then
            killed=$((killed + 1))
        fi
    done
    (( killed == ${#sports[@]} ))
}

wait_route_sports_gone() {
    local pid="$1" timeout_sec="$2" deadline current old found
    shift 2
    local -a old_sports=("$@") current_sports=()
    deadline=$((SECONDS + timeout_sec))
    while (( SECONDS < deadline )); do
        mapfile -t current_sports < <(get_gost_outer_sports "$pid")
        found=0
        for old in "${old_sports[@]}"; do
            for current in "${current_sports[@]}"; do
                [[ "$current" == "$old" ]] && found=1
            done
        done
        (( found == 0 )) && return 0
        sleep 0.1
    done
    return 1
}

write_status_json() {
    local state="${1:-UNKNOWN}" reason="${2:-}" pid="${3:-0}" sport="${4:-}"
    local minrtt="${5:-}" rtt="${6:-}" outer="${7:-0}" remote="${8:-unknown}"
    local data_plane="${9:-unknown}" data_failures="${10:-0}"
    local apid acount business astate tmp epoch ts
    local data_breaker process_breaker
    [[ "$data_failures" =~ ^[0-9]+$ ]] || data_failures=0
    apid="$(get_anchor_pid)"; acount="$(get_anchor_conn_count "$apid")"
    business="$(get_business_conn_count "$pid")"
    data_breaker="${DATA_PROBE_BREAKER_STATE:-closed}"
    process_breaker="${PROCESS_BREAKER_STATE:-closed}"
    if (( apid > 0 && acount == 1 )); then astate="up"; elif (( apid > 0 )); then astate="starting"; else astate="down"; fi
    epoch="$(now_epoch)"; ts="$(now_text)"; tmp="${STATUS_JSON}.tmp.$$"
    printf '{"epoch":%s,"ts":"%s","state":"%s","reason":"%s","route":"%s","unit":"%s","dst":"%s","port":%s,"business_ports":"%s","pid":%s,"outer_count":%s,"sport":"%s","minrtt_ms":"%s","rtt_ms":"%s","remote_reachable":"%s","data_plane_reachable":"%s","data_probe_failures":%s,"data_probe_breaker":"%s","process_breaker":"%s","anchor_unit":"%s","anchor_state":"%s","anchor_pid":%s,"anchor_connections":%s,"business_connections":%s}\n' \
      "$epoch" "$(json_escape "$ts")" "$(json_escape "$state")" "$(json_escape "$reason")" "$(json_escape "$ROUTE_ID")" "$(json_escape "$UNIT")" \
      "$(json_escape "$DST")" "$PORT" "$(json_escape "$BUSINESS_PORTS")" "${pid:-0}" "${outer:-0}" "$(json_escape "$sport")" "$(json_escape "$minrtt")" "$(json_escape "$rtt")" \
      "$(json_escape "$remote")" "$(json_escape "$data_plane")" "$data_failures" "$(json_escape "$data_breaker")" \
      "$(json_escape "$process_breaker")" "$(json_escape "$ANCHOR_UNIT")" "$astate" \
      "${apid:-0}" "${acount:-0}" "${business:-0}" > "$tmp"
    mv -f "$tmp" "$STATUS_JSON"
}

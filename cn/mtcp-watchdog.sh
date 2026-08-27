#!/usr/bin/env bash
set -uo pipefail

DEFAULT_CONFIG="${MTCP_CONFIG:-/root/gost-ecmp-pathlock/cn/mtcp.conf}"
CONFIG="${1:-$DEFAULT_CONFIG}"
ADOPT_MODE=0
if [[ "${1:-}" == "--adopt" ]]; then
    CONFIG="$DEFAULT_CONFIG"
    ADOPT_MODE=1
elif [[ "${2:-}" == "--adopt" ]]; then
    ADOPT_MODE=1
fi

LIB="${MTCP_LIB:-/root/gost-ecmp-pathlock/cn/mtcp-lib.sh}"
PREWARM="${MTCP_PREWARM:-/root/gost-ecmp-pathlock/cn/mtcp-prewarm.sh}"
# shellcheck disable=SC1090
source "$LIB"
load_config "$CONFIG" || exit 1

LOCK_ID="${ROUTE_ID:-${UNIT%.service}}"
LOCK_ID="${LOCK_ID//[^A-Za-z0-9_.@-]/_}"
RUNTIME_DIR="$(ensure_mtcp_runtime_dir)" || exit 1
LOCK="$RUNTIME_DIR/${LOCK_ID}.watchdog.lock"
exec {LOCKFD}>"$LOCK"
if ! flock -n "$LOCKFD"; then
    if (( ADOPT_MODE == 1 )); then
        echo "cannot adopt: watchdog lock is held for $UNIT" >&2
        exit 75
    fi
    exit 0
fi

BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"

# PROCESS recovery 属于共享 GOST，而不是任一线路。状态保存在项目专属的
# /run/gost-ecmp-pathlock namespace，并由 UNIT 派生出的全局锁保护。
PROCESS_RECOVERY_LOCK_FILE=""
PROCESS_RECOVERY_STATE_FILE=""
PROCESS_RECOVERY_EPOCHS=""
PROCESS_BREAKER_STATE="closed"
PROCESS_BREAKER_UNTIL=0
PROCESS_BREAKER_LOGGED=0
LAST_PROCESS_RECOVERY=0

reset_data_probe_state() {
    LAST_DATA_PROBE=0
    DATA_PROBE_FAILS=0
    DATA_PLANE_OK="unknown"
    DATA_PROBE_SPORT=""
}

reset_runtime_state() {
    SAVED_BOOT_ID=""
    STATE="INIT"; REASON=""; LAST_PID=0; LAST_NONZERO_PID=0; LAST_SPORT=""
    ZERO_SINCE=0; WARN_SINCE=0; CRIT_SINCE=0; RECOVER_SINCE=0
    LAST_REMOTE_PROBE=0; REMOTE_OK="unknown"; LAST_RESTART=0; MULTI_SEEN=0
    LAST_DEGRADED_RETRY=0; LAST_RECOVERY_ATTEMPT=0; LAST_ANCHOR_RETRY=0; LAST_PRUNE=0
    BUSINESS_IDLE_SINCE=0
    DATA_PROBE_RESTART_EPOCHS=""; DATA_PROBE_BREAKER_STATE="closed"
    DATA_PROBE_BREAKER_UNTIL=0; DATA_PROBE_BREAKER_LOGGED=0
    PROCESS_HEALTHY_SINCE=0; PROCESS_DOWN_SINCE=0
    reset_data_probe_state
    HAVE_RUNTIME=0
}

reset_runtime_state

load_runtime_state() {
    local saved_boot_id
    [[ -r "$STATE_FILE" ]] || return 1

    # 先检查首行 boot ID，避免跨重启状态在校验前污染当前进程变量。
    saved_boot_id="$(awk -F"'" 'NR == 1 && $1 == "SAVED_BOOT_ID=" { print $2; exit }' "$STATE_FILE" 2>/dev/null || true)"
    [[ -n "$saved_boot_id" && "$saved_boot_id" == "$BOOT_ID" ]] || return 1

    # shellcheck disable=SC1090
    if ! source "$STATE_FILE"; then
        reset_runtime_state
        return 1
    fi
    if [[ "${SAVED_BOOT_ID:-}" != "$BOOT_ID" ]]; then
        reset_runtime_state
        return 1
    fi
    : "${LAST_DATA_PROBE:=0}"
    : "${DATA_PROBE_FAILS:=0}"
    : "${DATA_PLANE_OK:=unknown}"
    : "${DATA_PROBE_SPORT:=}"
    : "${BUSINESS_IDLE_SINCE:=0}"
    : "${DATA_PROBE_RESTART_EPOCHS:=}"
    : "${DATA_PROBE_BREAKER_STATE:=closed}"
    : "${DATA_PROBE_BREAKER_UNTIL:=0}"
    : "${DATA_PROBE_BREAKER_LOGGED:=0}"
    : "${PROCESS_HEALTHY_SINCE:=0}"
    : "${PROCESS_DOWN_SINCE:=0}"
    if [[ ! "$LAST_DATA_PROBE" =~ ^[0-9]+$ || ! "$DATA_PROBE_FAILS" =~ ^[0-9]+$ ]] ||
       [[ "$DATA_PLANE_OK" != "yes" && "$DATA_PLANE_OK" != "no" && "$DATA_PLANE_OK" != "unknown" ]] ||
       [[ -n "$DATA_PROBE_SPORT" && ! "$DATA_PROBE_SPORT" =~ ^[0-9]+$ ]]; then
        reset_data_probe_state
    fi
    if [[ ! "$BUSINESS_IDLE_SINCE" =~ ^[0-9]+$ || ! "$DATA_PROBE_BREAKER_UNTIL" =~ ^[0-9]+$ ||
          ! "$DATA_PROBE_BREAKER_LOGGED" =~ ^[01]$ ||
          ! "$PROCESS_HEALTHY_SINCE" =~ ^[0-9]+$ || ! "$PROCESS_DOWN_SINCE" =~ ^[0-9]+$ ]] ||
       [[ "$DATA_PROBE_RESTART_EPOCHS" =~ [^0-9\ ] ]] ||
       [[ "$DATA_PROBE_BREAKER_STATE" != "closed" && "$DATA_PROBE_BREAKER_STATE" != "open" ]]; then
        BUSINESS_IDLE_SINCE=0
        DATA_PROBE_RESTART_EPOCHS=""; DATA_PROBE_BREAKER_STATE="closed"
        DATA_PROBE_BREAKER_UNTIL=0; DATA_PROBE_BREAKER_LOGGED=0
        PROCESS_HEALTHY_SINCE=0; PROCESS_DOWN_SINCE=0
    fi
    HAVE_RUNTIME=1
    return 0
}

save_runtime_state() {
    local tmp="${STATE_FILE}.tmp.$$"; umask 077
    cat > "$tmp" <<STATEEOF
SAVED_BOOT_ID='$BOOT_ID'
STATE='$STATE'
REASON='$REASON'
LAST_PID='$LAST_PID'
LAST_NONZERO_PID='$LAST_NONZERO_PID'
LAST_SPORT='$LAST_SPORT'
ZERO_SINCE='$ZERO_SINCE'
WARN_SINCE='$WARN_SINCE'
CRIT_SINCE='$CRIT_SINCE'
RECOVER_SINCE='$RECOVER_SINCE'
LAST_REMOTE_PROBE='$LAST_REMOTE_PROBE'
REMOTE_OK='$REMOTE_OK'
LAST_RESTART='$LAST_RESTART'
MULTI_SEEN='$MULTI_SEEN'
LAST_DEGRADED_RETRY='$LAST_DEGRADED_RETRY'
LAST_RECOVERY_ATTEMPT='$LAST_RECOVERY_ATTEMPT'
LAST_ANCHOR_RETRY='$LAST_ANCHOR_RETRY'
LAST_PRUNE='$LAST_PRUNE'
BUSINESS_IDLE_SINCE='$BUSINESS_IDLE_SINCE'
LAST_DATA_PROBE='$LAST_DATA_PROBE'
DATA_PROBE_FAILS='$DATA_PROBE_FAILS'
DATA_PLANE_OK='$DATA_PLANE_OK'
DATA_PROBE_SPORT='$DATA_PROBE_SPORT'
DATA_PROBE_RESTART_EPOCHS='$DATA_PROBE_RESTART_EPOCHS'
DATA_PROBE_BREAKER_STATE='$DATA_PROBE_BREAKER_STATE'
DATA_PROBE_BREAKER_UNTIL='$DATA_PROBE_BREAKER_UNTIL'
DATA_PROBE_BREAKER_LOGGED='$DATA_PROBE_BREAKER_LOGGED'
PROCESS_HEALTHY_SINCE='$PROCESS_HEALTHY_SINCE'
PROCESS_DOWN_SINCE='$PROCESS_DOWN_SINCE'
STATEEOF
    mv -f "$tmp" "$STATE_FILE"
}

prune_epoch_list() {
    local epochs="$1" cutoff="$2" epoch kept=""
    for epoch in $epochs; do
        (( epoch >= cutoff )) && kept="${kept:+$kept }$epoch"
    done
    printf '%s\n' "$kept"
}

init_process_recovery_paths() {
    local shared_id runtime_dir canonical
    shared_id="${UNIT%.service}"
    shared_id="${shared_id//[^A-Za-z0-9_.@-]/_}"
    runtime_dir="${MTCP_PROCESS_RUNTIME_DIR:-${MTCP_RUNTIME_DIR:-/run/gost-ecmp-pathlock}}"
    [[ "$runtime_dir" == /* && "$runtime_dir" != / && ! -L "$runtime_dir" ]] || return 1
    [[ ! -e "$runtime_dir" || -d "$runtime_dir" ]] || return 1
    if [[ ! -d "$runtime_dir" ]]; then
        (umask 077; mkdir -p -- "$runtime_dir") || return 1
    fi
    canonical="$(cd -P -- "$runtime_dir" 2>/dev/null && pwd -P)" || return 1
    [[ "$canonical" == "$runtime_dir" ]] || return 1
    case "$canonical" in
        /bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
            return 1
            ;;
    esac
    PROCESS_RECOVERY_LOCK_FILE="$runtime_dir/${shared_id}.process-recovery.lock"
    PROCESS_RECOVERY_STATE_FILE="$runtime_dir/${shared_id}.process-recovery.state"
}

reset_process_recovery_state() {
    PROCESS_RECOVERY_EPOCHS=""
    PROCESS_BREAKER_STATE="closed"
    PROCESS_BREAKER_UNTIL=0
    PROCESS_BREAKER_LOGGED=0
    LAST_PROCESS_RECOVERY=0
}

load_process_recovery_state() {
    local process_state_boot_id=""
    reset_process_recovery_state
    [[ -n "$PROCESS_RECOVERY_STATE_FILE" && -r "$PROCESS_RECOVERY_STATE_FILE" ]] || return 1

    process_state_boot_id="$(awk -F"'" 'NR == 1 && $1 == "PROCESS_STATE_BOOT_ID=" { print $2; exit }' \
        "$PROCESS_RECOVERY_STATE_FILE" 2>/dev/null || true)"
    [[ -n "$process_state_boot_id" && "$process_state_boot_id" == "$BOOT_ID" ]] || return 1

    # 专属 runtime 目录中的文件由 root Watchdog 以 0600 原子写入，只包含下列受校验字段。
    # shellcheck disable=SC1090
    if ! source "$PROCESS_RECOVERY_STATE_FILE"; then
        reset_process_recovery_state
        return 1
    fi
    if [[ "${PROCESS_STATE_BOOT_ID:-}" != "$BOOT_ID" ||
          ! "$PROCESS_BREAKER_UNTIL" =~ ^[0-9]+$ ||
          ! "$PROCESS_BREAKER_LOGGED" =~ ^[01]$ ||
          ! "$LAST_PROCESS_RECOVERY" =~ ^[0-9]+$ ]] ||
       [[ "$PROCESS_RECOVERY_EPOCHS" =~ [^0-9\ ] ]] ||
       [[ "$PROCESS_BREAKER_STATE" != "closed" && "$PROCESS_BREAKER_STATE" != "open" ]]; then
        reset_process_recovery_state
        return 1
    fi
    return 0
}

save_process_recovery_state() {
    local runtime_dir tmp
    runtime_dir="$(dirname "$PROCESS_RECOVERY_STATE_FILE")"
    mkdir -p "$runtime_dir" || return 1
    umask 077
    tmp="$(mktemp "${PROCESS_RECOVERY_STATE_FILE}.tmp.XXXXXX")" || return 1
    if ! cat > "$tmp" <<STATEEOF
PROCESS_STATE_BOOT_ID='$BOOT_ID'
PROCESS_RECOVERY_EPOCHS='$PROCESS_RECOVERY_EPOCHS'
PROCESS_BREAKER_STATE='$PROCESS_BREAKER_STATE'
PROCESS_BREAKER_UNTIL='$PROCESS_BREAKER_UNTIL'
PROCESS_BREAKER_LOGGED='$PROCESS_BREAKER_LOGGED'
LAST_PROCESS_RECOVERY='$LAST_PROCESS_RECOVERY'
STATEEOF
    then
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$PROCESS_RECOVERY_STATE_FILE"; then
        rm -f "$tmp"
        return 1
    fi
}

close_data_probe_breaker() {
    if [[ "$DATA_PROBE_BREAKER_STATE" != "closed" || -n "$DATA_PROBE_RESTART_EPOCHS" ]]; then
        log_event "$STATE" "DATA_PROBE_BREAKER_CLOSED" "DATA_PLANE" "$LAST_PID" "$LAST_SPORT"
    fi
    DATA_PROBE_RESTART_EPOCHS=""; DATA_PROBE_BREAKER_STATE="closed"
    DATA_PROBE_BREAKER_UNTIL=0; DATA_PROBE_BREAKER_LOGGED=0
}

allow_data_probe_restart() {
    local now="$1" cutoff count half_open=0
    if [[ "$DATA_PROBE_BREAKER_STATE" == "open" ]]; then
        if (( now < DATA_PROBE_BREAKER_UNTIL )); then
            if (( DATA_PROBE_BREAKER_LOGGED == 0 )); then
                log_event "FAULT" "DATA_PROBE_BREAKER_SUPPRESSED" "DATA_PROBE" "$LAST_PID" "$LAST_SPORT" "" "" \
                    "until=$DATA_PROBE_BREAKER_UNTIL"
                DATA_PROBE_BREAKER_LOGGED=1
            fi
            return 1
        fi
        # 熔断时间到期只放行一次试探；若数据面仍坏，下一轮仍会被抑制。
        DATA_PROBE_RESTART_EPOCHS=""
        DATA_PROBE_BREAKER_STATE="closed"; DATA_PROBE_BREAKER_UNTIL=0; DATA_PROBE_BREAKER_LOGGED=0
        half_open=1
        log_event "FAULT" "DATA_PROBE_BREAKER_HALF_OPEN" "DATA_PROBE" "$LAST_PID" "$LAST_SPORT"
    fi

    cutoff=$((now - DATA_PROBE_RESTART_WINDOW_SEC))
    DATA_PROBE_RESTART_EPOCHS="$(prune_epoch_list "$DATA_PROBE_RESTART_EPOCHS" "$cutoff")"
    count=0; [[ -n "$DATA_PROBE_RESTART_EPOCHS" ]] && count="$(wc -w <<< "$DATA_PROBE_RESTART_EPOCHS" | tr -d ' ')"
    if (( count >= DATA_PROBE_RESTART_MAX )); then
        DATA_PROBE_BREAKER_STATE="open"; DATA_PROBE_BREAKER_UNTIL=$((now + DATA_PROBE_BREAKER_OPEN_SEC))
        DATA_PROBE_BREAKER_LOGGED=0
        log_event "FAULT" "DATA_PROBE_BREAKER_OPEN" "DATA_PROBE" "$LAST_PID" "$LAST_SPORT" "" "" \
            "attempts=$count window=${DATA_PROBE_RESTART_WINDOW_SEC}s until=$DATA_PROBE_BREAKER_UNTIL"
        return 1
    fi

    DATA_PROBE_RESTART_EPOCHS="${DATA_PROBE_RESTART_EPOCHS:+$DATA_PROBE_RESTART_EPOCHS }$now"
    count=$((count + 1))
    if (( half_open == 1 )); then
        DATA_PROBE_BREAKER_STATE="open"; DATA_PROBE_BREAKER_UNTIL=$((now + DATA_PROBE_BREAKER_OPEN_SEC))
        DATA_PROBE_BREAKER_LOGGED=0
        log_event "FAULT" "DATA_PROBE_BREAKER_REARMED" "DATA_PROBE" "$LAST_PID" "$LAST_SPORT" "" "" \
            "half_open_attempt=yes until=$DATA_PROBE_BREAKER_UNTIL"
    elif (( count >= DATA_PROBE_RESTART_MAX )); then
        DATA_PROBE_BREAKER_STATE="open"; DATA_PROBE_BREAKER_UNTIL=$((now + DATA_PROBE_BREAKER_OPEN_SEC))
        DATA_PROBE_BREAKER_LOGGED=0
        log_event "FAULT" "DATA_PROBE_BREAKER_ARMED" "DATA_PROBE" "$LAST_PID" "$LAST_SPORT" "" "" \
            "attempts=$count window=${DATA_PROBE_RESTART_WINDOW_SEC}s until=$DATA_PROBE_BREAKER_UNTIL"
    fi
    return 0
}

close_process_breaker() {
    local now="${1:-$(now_epoch)}" expected_pid="${2:-${LAST_PID:-0}}" current_pid
    init_process_recovery_paths || return 1
    # fd 9 专用于短生命周期的共享 PROCESS lock；启动时的 route lock 由
    # Bash 动态分配到 >=10，不会与它冲突。
    exec 9>"$PROCESS_RECOVERY_LOCK_FILE" || return 1
    if ! flock -n 9; then
        exec 9>&-
        return 1
    fi

    # 只允许已持续健康的调用方关闭共享 breaker；同时要求最后一次全局
    # recovery 已经过完整 interval，避免漏看短暂 DOWN 的线路过早清空预算。
    current_pid="$(get_main_pid)"
    if ! service_is_active || (( current_pid <= 0 )) || [[ "$current_pid" != "$expected_pid" ]]; then
        exec 9>&-
        return 1
    fi
    load_process_recovery_state || true
    if [[ "$PROCESS_BREAKER_STATE" == "closed" && -z "$PROCESS_RECOVERY_EPOCHS" ]]; then
        exec 9>&-
        return 0
    fi
    if (( LAST_PROCESS_RECOVERY > 0 && now - LAST_PROCESS_RECOVERY < PROCESS_RECOVERY_INTERVAL_SEC )); then
        exec 9>&-
        return 1
    fi

    # load/interval 判断期间若 systemd 已换代，再次 fail closed；下一轮会重置健康基线。
    current_pid="$(get_main_pid)"
    if ! service_is_active || [[ "$current_pid" != "$expected_pid" ]]; then
        exec 9>&-
        return 1
    fi
    log_event "$STATE" "PROCESS_BREAKER_CLOSED" "PROCESS" "$LAST_PID" "$LAST_SPORT"
    reset_process_recovery_state
    if ! save_process_recovery_state; then
        log_event "FAULT" "PROCESS_RECOVERY_STATE_WRITE_FAILED" "PROCESS" "$LAST_PID" "$LAST_SPORT"
        exec 9>&-
        return 2
    fi
    exec 9>&-
    return 0
}

allow_process_recovery() {
    local now="$1" cutoff count half_open=0
    if (( LAST_PROCESS_RECOVERY > 0 && now - LAST_PROCESS_RECOVERY < PROCESS_RECOVERY_INTERVAL_SEC )); then
        return 1
    fi
    if [[ "$PROCESS_BREAKER_STATE" == "open" ]]; then
        if (( now < PROCESS_BREAKER_UNTIL )); then
            if (( PROCESS_BREAKER_LOGGED == 0 )); then
                log_event "FAULT" "PROCESS_BREAKER_SUPPRESSED" "PROCESS" 0 "" "" "" "until=$PROCESS_BREAKER_UNTIL"
                PROCESS_BREAKER_LOGGED=1
            fi
            return 1
        fi
        PROCESS_RECOVERY_EPOCHS=""
        PROCESS_BREAKER_STATE="closed"; PROCESS_BREAKER_UNTIL=0; PROCESS_BREAKER_LOGGED=0
        half_open=1
        log_event "FAULT" "PROCESS_BREAKER_HALF_OPEN" "PROCESS" 0
    fi
    cutoff=$((now - PROCESS_RECOVERY_WINDOW_SEC))
    PROCESS_RECOVERY_EPOCHS="$(prune_epoch_list "$PROCESS_RECOVERY_EPOCHS" "$cutoff")"
    count=0; [[ -n "$PROCESS_RECOVERY_EPOCHS" ]] && count="$(wc -w <<< "$PROCESS_RECOVERY_EPOCHS" | tr -d ' ')"
    if (( count >= PROCESS_RECOVERY_MAX )); then
        PROCESS_BREAKER_STATE="open"; PROCESS_BREAKER_UNTIL=$((now + PROCESS_BREAKER_OPEN_SEC))
        PROCESS_BREAKER_LOGGED=0
        log_event "FAULT" "PROCESS_BREAKER_OPEN" "PROCESS" 0 "" "" "" \
            "attempts=$count window=${PROCESS_RECOVERY_WINDOW_SEC}s until=$PROCESS_BREAKER_UNTIL"
        return 1
    fi
    LAST_PROCESS_RECOVERY="$now"
    PROCESS_RECOVERY_EPOCHS="${PROCESS_RECOVERY_EPOCHS:+$PROCESS_RECOVERY_EPOCHS }$now"
    count=$((count + 1))
    if (( half_open == 1 )); then
        PROCESS_BREAKER_STATE="open"; PROCESS_BREAKER_UNTIL=$((now + PROCESS_BREAKER_OPEN_SEC))
        PROCESS_BREAKER_LOGGED=0
        log_event "FAULT" "PROCESS_BREAKER_REARMED" "PROCESS" 0 "" "" "" \
            "half_open_attempt=yes until=$PROCESS_BREAKER_UNTIL"
    elif (( count >= PROCESS_RECOVERY_MAX )); then
        PROCESS_BREAKER_STATE="open"; PROCESS_BREAKER_UNTIL=$((now + PROCESS_BREAKER_OPEN_SEC))
        PROCESS_BREAKER_LOGGED=0
        log_event "FAULT" "PROCESS_BREAKER_ARMED" "PROCESS" 0 "" "" "" \
            "attempts=$count window=${PROCESS_RECOVERY_WINDOW_SEC}s until=$PROCESS_BREAKER_UNTIL"
    fi
    return 0
}

recover_process_rate_limited() {
    local now="$1"
    init_process_recovery_paths || return 2
    exec 9>"$PROCESS_RECOVERY_LOCK_FILE" || return 2
    if ! flock -n 9; then
        exec 9>&-
        return 1
    fi

    # 锁内按顺序完成复查、共享状态读取、预算判断、attempt 落盘和 restart。
    # 因此后拿锁的其他线路会看到同一份 interval/window/max 预算，而不只是
    # 被阻止并发 restart。
    if service_is_active && (( $(get_main_pid) > 0 )); then
        exec 9>&-
        return 0
    fi
    load_process_recovery_state || true
    if ! allow_process_recovery "$now"; then
        if ! save_process_recovery_state; then
            log_event "FAULT" "PROCESS_RECOVERY_STATE_WRITE_FAILED" "PROCESS" 0
            exec 9>&-
            return 2
        fi
        exec 9>&-
        return 1
    fi
    # attempt 必须先持久化再执行 restart；即使 restart 失败或 Watchdog 被终止，
    # 下一条线路也不能拿到一套新的预算。
    if ! save_process_recovery_state; then
        log_event "FAULT" "PROCESS_RECOVERY_STATE_WRITE_FAILED" "PROCESS" 0
        exec 9>&-
        return 2
    fi

    log_event "DOWN" "PROCESS_RECOVERY_ATTEMPT" "PROCESS" 0 "" "" "" \
        "attempts=$(wc -w <<< "$PROCESS_RECOVERY_EPOCHS" | tr -d ' ')"
    systemctl reset-failed "$UNIT" >/dev/null 2>&1 || true
    if ! systemctl restart "$UNIT"; then
        log_event "FAULT" "PROCESS_RECOVERY_FAILED" "PROCESS" 0
        exec 9>&-
        return 2
    fi
    log_event "DOWN" "PROCESS_RECOVERY_STARTED" "PROCESS" 0
    exec 9>&-
    return 0
}

set_state() {
    local new_state="$1" new_reason="$2" pid="${3:-0}" sport="${4:-}" minrtt="${5:-}" rtt="${6:-}" outer="${7:-0}"
    if [[ "$STATE" != "$new_state" || "$REASON" != "$new_reason" ]]; then
        STATE="$new_state"; REASON="$new_reason"
        log_event "$STATE" "STATE_CHANGE" "$REASON" "$pid" "$sport" "$minrtt" "$rtt"
    else
        STATE="$new_state"; REASON="$new_reason"
    fi
    write_status_json "$STATE" "$REASON" "$pid" "$sport" "$minrtt" "$rtt" "$outer" "$REMOTE_OK" \
        "$DATA_PLANE_OK" "$DATA_PROBE_FAILS"
}

reset_route_rate_limited() {
    local reason="$1" now pid count
    local -a old_sports=()
    now="$(now_epoch)"
    if (( LAST_RESTART > 0 && now - LAST_RESTART < ${RESTART_COOLDOWN_SEC:-300} )); then
        log_event "FAULT" "ROUTE_RESET_SKIPPED_COOLDOWN" "$reason" "$LAST_PID" "$LAST_SPORT"
        return 1
    fi
    if [[ "$reason" == "DATA_PLANE_STALE_OUTER" ]] && ! allow_data_probe_restart "$now"; then
        return 3
    fi
    LAST_RESTART="$now"
    stop_anchor
    pid="$(get_main_pid)"
    count="$(get_gost_outer_count "$pid")"
    log_event "FAULT" "RESET_ROUTE_OUTER" "$reason" "$pid" "$LAST_SPORT" "" "" \
        "route=$ROUTE_ID count=$count endpoint=$DST:$PORT"

    # 只关闭本线路唯一 Remote endpoint 对应的 outer；共享 GOST 及其他线路不动。
    # count=0 时清理状态并让下一轮 Anchor 重新触发拨号，不升级为全局 restart。
    if (( count > 0 )); then
        mapfile -t old_sports < <(get_gost_outer_sports "$pid")
        if ! kill_route_outers "$pid" ||
           ! wait_route_sports_gone "$pid" "${PREWARM_KILL_WAIT_SEC:-2}" "${old_sports[@]}"; then
            log_event "FAULT" "RESET_ROUTE_OUTER_FAILED" "$reason" "$pid" "$LAST_SPORT" "" "" \
                "route=$ROUTE_ID count=$(get_gost_outer_count "$pid")"
            return 2
        fi
    else
        log_event "DOWN" "RESET_ROUTE_NO_OUTER" "$reason" "$pid" "" "" "" "route=$ROUTE_ID"
    fi

    LAST_SPORT=""; ZERO_SINCE=0; MULTI_SEEN=0
    reset_data_probe_state
    return 0
}

# v1 的 prewarm 已经负责：建立候选 Anchor -> 测 minrtt -> 慢路重抽 -> 成功后直接留下 Anchor。
run_select() {
    local mode="${1:-normal}" cause="${2:-SELECT}" rc pid count sport info minrtt rtt
    reset_data_probe_state
    MTCP_PREWARM_MODE="$mode" "$PREWARM" "$CONFIG"; rc=$?

    case "$rc" in
      0|10)
        pid="$(get_main_pid)"; count="$(get_gost_outer_count "$pid")"
        if (( pid <= 0 || count != 1 )) || ! anchor_is_established; then
            STATE="FAULT"; REASON="SELECT_VERIFY_FAILED"
            log_event "FAULT" "SELECT_VERIFY_FAILED" "$REASON" "$pid" "" "" "" "rc=$rc count=$count cause=$cause"
            return 32
        fi
        sport="$(get_single_sport "$pid" 2>/dev/null || true)"
        info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
        LAST_PID="$pid"; LAST_NONZERO_PID="$pid"; LAST_SPORT="$sport"; ZERO_SINCE=0; REMOTE_OK="yes"; LAST_ANCHOR_RETRY=0
        if (( rc == 0 )); then
            STATE="FAST"; REASON="PATH"; LAST_DEGRADED_RETRY=0
            log_event "FAST" "ANCHOR_BOUND" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "cause=$cause"
        else
            STATE="DEGRADED"; REASON="PATH"; LAST_DEGRADED_RETRY="$(now_epoch)"
            log_event "DEGRADED" "ANCHOR_BOUND_SLOW" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "cause=$cause"
        fi
        write_status_json "$STATE" "$REASON" "$pid" "$sport" "$minrtt" "$rtt" 1 "$REMOTE_OK" \
            "$DATA_PLANE_OK" "$DATA_PROBE_FAILS"
        return "$rc"
        ;;
      11)
        pid="$(get_main_pid)"; count="$(get_gost_outer_count "$pid")"
        sport="$(get_single_sport "$pid" 2>/dev/null || true)"
        info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
        STATE="DEGRADED"; REASON="ANCHOR"; LAST_PID="$pid"; LAST_SPORT="$sport"; LAST_ANCHOR_RETRY="$(now_epoch)"
        write_status_json "$STATE" "$REASON" "$pid" "$sport" "$minrtt" "$rtt" "$count" "$REMOTE_OK" \
            "$DATA_PLANE_OK" "$DATA_PROBE_FAILS"
        return 11
        ;;
      20)
        STATE="DOWN"; REASON="NO_OUTER"
        return 20
        ;;
      75) return 75 ;;
      *)
        STATE="FAULT"; REASON="PREWARM_RC_${rc}"
        log_event "FAULT" "SELECT_PREWARM_FAILED" "$REASON" "$(get_main_pid)" "" "" "" "cause=$cause"
        reset_route_rate_limited "$REASON" || true
        return "$rc"
        ;;
    esac
}

process_pid_changed() {
    local current_pid="$1" now="$2"
    [[ "$LAST_PID" != "$current_pid" ]] || return 1
    # PROCESS 健康窗口必须绑定同一个 MainPID；即使短暂 DOWN 被轮询漏掉，
    # 新 PID 也不能继承旧 PID 已累计的健康时间。
    PROCESS_HEALTHY_SINCE="$now"
    return 0
}

adopt_current() {
    local pid count sport info minrtt rtt
    pid="$(get_main_pid)"; count="$(get_gost_outer_count "$pid")"
    if (( pid <= 0 || count != 1 )); then echo "cannot adopt: pid=$pid outer_count=$count" >&2; return 1; fi
    if ! anchor_is_established; then echo "cannot adopt: anchor is not established" >&2; return 1; fi
    sport="$(get_single_sport "$pid")"; info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
    [[ -n "$minrtt" ]] || { echo "cannot adopt: minrtt unavailable" >&2; return 1; }
    if ! is_lt "$minrtt" "$ACCEPT_RTT_MS"; then
        log_event "DEGRADED" "ADOPT_REFUSED_SLOW" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "accept<$ACCEPT_RTT_MS"
        echo "cannot adopt: minrtt=${minrtt}ms is not FAST (<${ACCEPT_RTT_MS}ms)" >&2
        return 2
    fi
    LAST_PID="$pid"; LAST_NONZERO_PID="$pid"; LAST_SPORT="$sport"; ZERO_SINCE=0; REMOTE_OK="yes"; STATE="FAST"; REASON="PATH"
    reset_data_probe_state
    log_event "FAST" "ADOPT_EXISTING_FAST" "PATH" "$pid" "$sport" "$minrtt" "$rtt"
    write_status_json "$STATE" "$REASON" "$pid" "$sport" "$minrtt" "$rtt" 1 "$REMOTE_OK" \
        "$DATA_PLANE_OK" "$DATA_PROBE_FAILS"
    save_runtime_state
}

init_process_recovery_paths || { echo "cannot initialize shared PROCESS recovery state" >&2; exit 1; }
load_process_recovery_state || true
if (( ADOPT_MODE == 1 )); then
    adopt_current
    exit $?
fi

load_runtime_state || true
# 兼容升级前 route-local runtime.state 中残留的 PROCESS_* 字段；共享快照优先。
load_process_recovery_state || true

while true; do
    load_config "$CONFIG" || { sleep 5; continue; }
    init_process_recovery_paths || { sleep 5; continue; }
    load_process_recovery_state || true
    now="$(now_epoch)"
    if (( now - LAST_PRUNE >= 3600 )); then prune_events; LAST_PRUNE="$now"; fi

    pid="$(get_main_pid)"
    if (( pid <= 0 )) || ! service_is_active; then
        stop_anchor
        (( LAST_PID > 0 )) && LAST_NONZERO_PID="$LAST_PID"
        LAST_PID=0; LAST_SPORT=""; ZERO_SINCE=0
        PROCESS_HEALTHY_SINCE=0
        (( PROCESS_DOWN_SINCE == 0 )) && PROCESS_DOWN_SINCE="$now"
        reset_data_probe_state
        DATA_PLANE_OK="no"
        set_state "DOWN" "PROCESS" "$pid" "" "" "" 0
        if (( now - PROCESS_DOWN_SINCE >= PROCESS_RECOVERY_GRACE_SEC )); then
            recover_process_rate_limited "$now" || true
            # 非持锁线路也立即读取 winner 已写入的 attempt/breaker 快照。
            load_process_recovery_state || true
        fi
        if [[ "$PROCESS_BREAKER_STATE" == "open" ]]; then
            set_state "FAULT" "PROCESS_BREAKER" "$pid" "" "" "" 0
        else
            set_state "DOWN" "PROCESS" "$pid" "" "" "" 0
        fi
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    fi

    PROCESS_DOWN_SINCE=0

    # 无可用 runtime（首次部署/重启 watchdog 且状态被清理/跨 reboot）：当前 PID
    # 从本轮开始累计健康时间，并明确记录 COLD_START，不冒充 GOST 重启。
    if (( HAVE_RUNTIME == 0 )); then
        PROCESS_HEALTHY_SINCE="$now"
        log_event "DOWN" "WATCHDOG_COLD_START" "INIT" "$pid"
        LAST_PID="$pid"; LAST_NONZERO_PID="$pid"; LAST_SPORT=""; ZERO_SINCE=0; MULTI_SEEN=0; REMOTE_OK="unknown"
        reset_data_probe_state
        if remote_tcp_reachable; then
            REMOTE_OK="yes"; run_select normal "COLD_START" || true
        else
            REMOTE_OK="no"; set_state "DOWN" "REMOTE" "$pid" "" "" "" 0
        fi
        HAVE_RUNTIME=1
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    fi

    # 必须先识别 PID 换代并重置健康基线，再判断是否可以关闭 PROCESS breaker。
    # 这样 Restart=always 的短暂 DOWN 即使落在两个轮询之间，也不会继承旧 PID 的窗口。
    if process_pid_changed "$pid" "$now"; then
        old_pid="$LAST_NONZERO_PID"
        (( old_pid > 0 )) || old_pid="$LAST_PID"
        stop_anchor
        LAST_PID="$pid"; LAST_NONZERO_PID="$pid"; LAST_SPORT=""; ZERO_SINCE=0; MULTI_SEEN=0
        reset_data_probe_state
        log_event "DOWN" "GOST_PID_CHANGED" "PROCESS" "$pid" "" "" "" "old_pid=$old_pid"
        if remote_tcp_reachable; then
            REMOTE_OK="yes"; run_select normal "GOST_PID_CHANGED" || true
        else
            REMOTE_OK="no"; set_state "DOWN" "REMOTE" "$pid" "" "" "" 0
        fi
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    fi

    if (( PROCESS_HEALTHY_SINCE == 0 )); then
        PROCESS_HEALTHY_SINCE="$now"
    elif (( now - PROCESS_HEALTHY_SINCE >= PROCESS_RECOVERY_INTERVAL_SEC )); then
        close_process_breaker "$now" "$pid" || true
    fi

    count="$(get_gost_outer_count "$pid")"

    if (( count > 1 )); then
        reset_data_probe_state
        DATA_PLANE_OK="no"
        ((MULTI_SEEN++)); set_state "FAULT" "MULTI_OUTER" "$pid" "" "" "" "$count"
        if (( MULTI_SEEN >= ${MULTI_CONFIRM_COUNT:-2} )); then reset_route_rate_limited "MULTI_OUTER" || true; fi
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    else
        MULTI_SEEN=0
    fi

    if (( count == 0 )); then
        WARN_SINCE=0; CRIT_SINCE=0; RECOVER_SINCE=0; LAST_SPORT=""
        reset_data_probe_state
        DATA_PLANE_OK="no"
        stop_anchor
        if (( ZERO_SINCE == 0 )); then
            ZERO_SINCE="$now"
            log_event "DOWN" "OUTER_DISAPPEARED" "NO_OUTER" "$pid"
        fi

        if (( now - ZERO_SINCE < ${ZERO_GRACE_SEC:-5} )); then
            if [[ "$REMOTE_OK" == "no" ]]; then
                set_state "DOWN" "REMOTE" "$pid" "" "" "" 0
            else
                set_state "DOWN" "NO_OUTER" "$pid" "" "" "" 0
            fi
            save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
        fi

        if (( now - LAST_REMOTE_PROBE >= ${REMOTE_PROBE_INTERVAL_SEC:-15} )); then
            LAST_REMOTE_PROBE="$now"; old_remote="$REMOTE_OK"
            if remote_tcp_reachable; then
                REMOTE_OK="yes"
                [[ "$old_remote" == "yes" ]] || log_event "DOWN" "REMOTE_TCP_UP" "REMOTE" "$pid"
            else
                REMOTE_OK="no"
                [[ "$old_remote" == "no" ]] || log_event "DOWN" "REMOTE_TCP_DOWN" "REMOTE" "$pid"
            fi
        fi

        if [[ "$REMOTE_OK" == "no" ]]; then
            set_state "DOWN" "REMOTE" "$pid" "" "" "" 0
            save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
        fi

        if [[ "$REMOTE_OK" != "yes" ]]; then
            set_state "DOWN" "NO_OUTER" "$pid" "" "" "" 0
            save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
        fi

        if (( LAST_RECOVERY_ATTEMPT == 0 || now - LAST_RECOVERY_ATTEMPT >= ${DOWN_RETRY_SEC:-15} )); then
            LAST_RECOVERY_ATTEMPT="$now"
            log_event "DOWN" "RECOVERY_SELECT" "REMOTE_UP" "$pid"
            run_select recovery "REMOTE_RECOVERY" || true
        fi

        if (( ZERO_SINCE > 0 && now - ZERO_SINCE >= ${STUCK_RESTART_AFTER_SEC:-60} )) && [[ "$REMOTE_OK" == "yes" ]]; then
            reset_route_rate_limited "REMOTE_UP_BUT_NO_OUTER" || true
        fi
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    fi

    # outer == 1。ESTAB 只证明 socket 仍存在，不能据此推断 Remote 或 MTCP 数据面健康。
    ZERO_SINCE=0; LAST_RECOVERY_ATTEMPT=0
    sport="$(get_single_sport "$pid" 2>/dev/null || true)"
    [[ -n "$sport" ]] || { save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue; }
    info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
    business="$(get_business_conn_count "$pid")"

    if [[ -z "$LAST_SPORT" ]]; then
        LAST_SPORT="$sport"
        reset_data_probe_state
        run_select normal "INITIAL_NO_SPORT" || true
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    fi

    if [[ "$LAST_SPORT" != "$sport" ]]; then
        old_sport="$LAST_SPORT"
        log_event "DOWN" "SESSION_CHANGED" "NEW_SPORT" "$pid" "$sport" "$minrtt" "$rtt" "old=$old_sport business=$business"
        LAST_SPORT="$sport"
        reset_data_probe_state
        run_select recovery "SESSION_CHANGED" || true
        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
    fi

    # Anchor 自己掉了：优先重新挂回当前 outer，不因辅助组件故障主动重抽。
    if ! anchor_is_established; then
        if (( LAST_ANCHOR_RETRY == 0 || now - LAST_ANCHOR_RETRY >= ${ANCHOR_RETRY_SEC:-60} )); then
            LAST_ANCHOR_RETRY="$now"; before_sport="$sport"
            if ensure_anchor; then
                after_count="$(get_gost_outer_count "$pid")"
                after_sport="$(get_single_sport "$pid" 2>/dev/null || true)"
                if (( after_count == 1 )) && [[ "$after_sport" == "$before_sport" ]]; then
                    LAST_ANCHOR_RETRY=0
                    reset_data_probe_state
                    log_event "$STATE" "ANCHOR_RESTORED" "ANCHOR" "$pid" "$sport" "$minrtt" "$rtt"
                else
                    stop_anchor
                    log_event "DOWN" "ANCHOR_RESTORE_SESSION_CHANGED" "NEW_SPORT" "$pid" "$after_sport" "" "" "old=$before_sport count=$after_count"
                    run_select recovery "ANCHOR_CHANGED_SESSION" || true
                    save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
                fi
            else
                stop_anchor
                set_state "DEGRADED" "ANCHOR" "$pid" "$sport" "$minrtt" "$rtt" 1
                save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
            fi
        else
            set_state "DEGRADED" "ANCHOR" "$pid" "$sport" "$minrtt" "$rtt" 1
            save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
        fi
    fi

    # Data Plane Probe：outer=1 只能说明内核仍保留 ESTAB socket；只有通过
    # Anchor echo 回路收发 payload，才能证明当前 MTCP mux/outer 仍可用。
    if [[ "$DATA_PROBE_ENABLED" == "no" ]]; then
        if (( LAST_DATA_PROBE != 0 || DATA_PROBE_FAILS != 0 )) || \
           [[ "$DATA_PLANE_OK" != "unknown" || -n "$DATA_PROBE_SPORT" ]]; then
            reset_data_probe_state
        fi
        # 显式关闭新探测时保持旧版 outer=1 的兼容语义。
        close_data_probe_breaker
        REMOTE_OK="yes"
    else
        probe_threshold="$DATA_PROBE_FAIL_THRESHOLD"

        # 连续失败只对同一条 outer session 有效。
        if [[ -n "$DATA_PROBE_SPORT" && "$DATA_PROBE_SPORT" != "$sport" ]]; then
            reset_data_probe_state
        fi

        # 已确认整条 CN -> Remote 网络不可达时，只按 Remote 探测节奏等待；
        # Remote 恢复后再做一次 Data Probe，避免断网期间堆积超时 logical stream。
        if [[ "$DATA_PLANE_OK" == "no" && "$REMOTE_OK" == "no" ]] && \
           (( DATA_PROBE_FAILS >= probe_threshold )); then
            if (( LAST_REMOTE_PROBE == 0 || now - LAST_REMOTE_PROBE >= ${REMOTE_PROBE_INTERVAL_SEC:-15} )); then
                LAST_REMOTE_PROBE="$now"
                if remote_tcp_reachable; then
                    REMOTE_OK="yes"
                    log_event "DOWN" "REMOTE_TCP_UP" "REMOTE" "$pid" "$sport" "$minrtt" "$rtt" \
                        "data_probe_failures=$DATA_PROBE_FAILS"

                    LAST_DATA_PROBE="$now"
                    DATA_PROBE_SPORT="$sport"
                    if data_plane_probe; then
                        previous_failures="$DATA_PROBE_FAILS"
                        DATA_PROBE_FAILS=0
                        DATA_PLANE_OK="yes"
                        close_data_probe_breaker
                        log_event "$STATE" "DATA_PROBE_RECOVERED" "DATA_PLANE" \
                            "$pid" "$sport" "$minrtt" "$rtt" "previous_failures=$previous_failures"
                    else
                        log_event "FAULT" "DATA_PROBE_FAILED" "DATA_PLANE" \
                            "$pid" "$sport" "$minrtt" "$rtt" \
                            "fail=$DATA_PROBE_FAILS/$probe_threshold after_remote_recovery=yes"
                        set_state "FAULT" "STALE_OUTER" "$pid" "$sport" "$minrtt" "$rtt" 1
                        log_event "FAULT" "STALE_OUTER_CONFIRMED" "DATA_PLANE" \
                            "$pid" "$sport" "$minrtt" "$rtt" \
                            "data_probe_failures=$DATA_PROBE_FAILS remote_tcp=up"
                        reset_route_rate_limited "DATA_PLANE_STALE_OUTER"
                        restart_rc=$?
                        if (( restart_rc == 3 )); then
                            set_state "FAULT" "DATA_PROBE_BREAKER" "$pid" "$sport" "$minrtt" "$rtt" 1
                        fi
                        save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
                    fi
                fi
            fi

            if [[ "$REMOTE_OK" == "no" ]]; then
                set_state "DOWN" "REMOTE" "$pid" "$sport" "$minrtt" "$rtt" 1
                save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
            fi
        fi

        if (( LAST_DATA_PROBE == 0 || now - LAST_DATA_PROBE >= DATA_PROBE_INTERVAL_SEC )); then
            LAST_DATA_PROBE="$now"
            DATA_PROBE_SPORT="$sport"

            if data_plane_probe; then
                if (( DATA_PROBE_FAILS > 0 )) || [[ "$DATA_PLANE_OK" == "no" ]]; then
                    log_event "$STATE" "DATA_PROBE_RECOVERED" "DATA_PLANE" \
                        "$pid" "$sport" "$minrtt" "$rtt" "previous_failures=$DATA_PROBE_FAILS"
                fi
                DATA_PROBE_FAILS=0
                DATA_PLANE_OK="yes"
                REMOTE_OK="yes"
                close_data_probe_breaker
            else
                DATA_PLANE_OK="no"
                if (( DATA_PROBE_FAILS < probe_threshold )); then
                    DATA_PROBE_FAILS=$((DATA_PROBE_FAILS + 1))
                fi
                log_event "DEGRADED" "DATA_PROBE_FAILED" "DATA_PLANE" \
                    "$pid" "$sport" "$minrtt" "$rtt" \
                    "fail=$DATA_PROBE_FAILS/$probe_threshold"

                if (( DATA_PROBE_FAILS < probe_threshold )); then
                    set_state "DEGRADED" "DATA_PLANE" "$pid" "$sport" "$minrtt" "$rtt" 1
                    save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
                fi

                LAST_REMOTE_PROBE="$now"
                old_remote="$REMOTE_OK"
                if remote_tcp_reachable; then
                    REMOTE_OK="yes"
                    [[ "$old_remote" == "yes" ]] || \
                        log_event "DOWN" "REMOTE_TCP_UP" "REMOTE" "$pid" "$sport" "$minrtt" "$rtt"
                    set_state "FAULT" "STALE_OUTER" "$pid" "$sport" "$minrtt" "$rtt" 1
                    log_event "FAULT" "STALE_OUTER_CONFIRMED" "DATA_PLANE" \
                        "$pid" "$sport" "$minrtt" "$rtt" \
                        "data_probe_failures=$DATA_PROBE_FAILS remote_tcp=up"
                    reset_route_rate_limited "DATA_PLANE_STALE_OUTER"
                    restart_rc=$?
                    if (( restart_rc == 3 )); then
                        set_state "FAULT" "DATA_PROBE_BREAKER" "$pid" "$sport" "$minrtt" "$rtt" 1
                    fi
                else
                    REMOTE_OK="no"
                    [[ "$old_remote" == "no" ]] || \
                        log_event "DOWN" "REMOTE_TCP_DOWN" "REMOTE" "$pid" "$sport" "$minrtt" "$rtt" \
                            "data_probe_failures=$DATA_PROBE_FAILS"
                    set_state "DOWN" "REMOTE" "$pid" "$sport" "$minrtt" "$rtt" 1
                fi
                save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
            fi
        fi

        # 探测失败状态优先于 PATH/LIVE_RTT，避免下方状态机误覆盖为 FAST。
        if [[ "$DATA_PLANE_OK" == "no" ]]; then
            if [[ "$REMOTE_OK" == "no" ]]; then
                set_state "DOWN" "REMOTE" "$pid" "$sport" "$minrtt" "$rtt" 1
            elif (( DATA_PROBE_FAILS >= probe_threshold )); then
                set_state "FAULT" "STALE_OUTER" "$pid" "$sport" "$minrtt" "$rtt" 1
            else
                set_state "DEGRADED" "DATA_PLANE" "$pid" "$sport" "$minrtt" "$rtt" 1
            fi
            save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
        fi
    fi

    LAST_SPORT="$sport"; LAST_PID="$pid"; LAST_NONZERO_PID="$pid"

    if [[ -z "$minrtt" ]]; then
        base_state="DEGRADED"; base_reason="TCP_INFO"
    elif is_lt "$minrtt" "$ACCEPT_RTT_MS"; then
        base_state="FAST"; base_reason="PATH"
    else
        base_state="DEGRADED"; base_reason="PATH"
    fi

    if [[ "$base_state" == "DEGRADED" ]]; then
        if (( LAST_DEGRADED_RETRY == 0 )); then LAST_DEGRADED_RETRY="$now"; fi
        if (( now - LAST_DEGRADED_RETRY >= ${DEGRADED_RETRY_SEC:-900} )); then
            if (( business == 0 )); then
                if (( BUSINESS_IDLE_SINCE == 0 )); then
                    BUSINESS_IDLE_SINCE="$now"
                elif (( now - BUSINESS_IDLE_SINCE >= BUSINESS_IDLE_HOLD_SEC )); then
                    LAST_DEGRADED_RETRY="$now"
                    log_event "DEGRADED" "DEGRADED_RETRY_IDLE" "PATH" "$pid" "$sport" "$minrtt" "$rtt" \
                        "idle_for=$((now - BUSINESS_IDLE_SINCE))s ports=$BUSINESS_PORTS"
                    run_select degraded-retry "DEGRADED_IDLE_RETRY" || true
                    BUSINESS_IDLE_SINCE=0
                    save_runtime_state; sleep "${WATCH_INTERVAL_SEC:-5}"; continue
                fi
            else
                BUSINESS_IDLE_SINCE=0
                LAST_DEGRADED_RETRY=$((now - ${DEGRADED_RETRY_SEC:-900} + ${DEGRADED_BUSY_DEFER_SEC:-60}))
                log_event "DEGRADED" "DEGRADED_RETRY_DEFER_BUSY" "PATH" "$pid" "$sport" "$minrtt" "$rtt" \
                    "business=$business ports=$BUSINESS_PORTS"
            fi
        fi
    else
        LAST_DEGRADED_RETRY=0; BUSINESS_IDLE_SINCE=0
    fi

    # LIVE RTT 只做状态化，不主动 kill 当前 outer。
    if [[ "$REASON" == "LIVE_RTT_WARN" || "$REASON" == "LIVE_RTT_CRIT" ]]; then
        if [[ -n "$rtt" ]] && is_lt "$rtt" "${LIVE_RTT_RECOVER_MS:-80}"; then
            if (( RECOVER_SINCE == 0 )); then RECOVER_SINCE="$now"; fi
            if (( now - RECOVER_SINCE >= ${LIVE_RTT_RECOVER_HOLD_SEC:-30} )); then
                WARN_SINCE=0; CRIT_SINCE=0; RECOVER_SINCE=0
                set_state "$base_state" "$base_reason" "$pid" "$sport" "$minrtt" "$rtt" 1
            else
                set_state "DEGRADED" "$REASON" "$pid" "$sport" "$minrtt" "$rtt" 1
            fi
        else
            RECOVER_SINCE=0
            if [[ -n "$rtt" ]] && is_ge "$rtt" "${LIVE_RTT_CRIT_MS:-250}"; then REASON="LIVE_RTT_CRIT"; fi
            set_state "DEGRADED" "$REASON" "$pid" "$sport" "$minrtt" "$rtt" 1
        fi
    elif [[ -n "$rtt" ]] && is_ge "$rtt" "${LIVE_RTT_CRIT_MS:-250}"; then
        WARN_SINCE=0; RECOVER_SINCE=0; (( CRIT_SINCE == 0 )) && CRIT_SINCE="$now"
        if (( now - CRIT_SINCE >= ${LIVE_RTT_CRIT_HOLD_SEC:-120} )); then set_state "DEGRADED" "LIVE_RTT_CRIT" "$pid" "$sport" "$minrtt" "$rtt" 1
        else set_state "$base_state" "RTT_TRANSIENT" "$pid" "$sport" "$minrtt" "$rtt" 1; fi
    elif [[ -n "$rtt" ]] && is_ge "$rtt" "${LIVE_RTT_WARN_MS:-120}"; then
        CRIT_SINCE=0; RECOVER_SINCE=0; (( WARN_SINCE == 0 )) && WARN_SINCE="$now"
        if (( now - WARN_SINCE >= ${LIVE_RTT_WARN_HOLD_SEC:-30} )); then set_state "DEGRADED" "LIVE_RTT_WARN" "$pid" "$sport" "$minrtt" "$rtt" 1
        else set_state "$base_state" "RTT_TRANSIENT" "$pid" "$sport" "$minrtt" "$rtt" 1; fi
    else
        WARN_SINCE=0; CRIT_SINCE=0; RECOVER_SINCE=0
        set_state "$base_state" "$base_reason" "$pid" "$sport" "$minrtt" "$rtt" 1
    fi

    save_runtime_state
    sleep "${WATCH_INTERVAL_SEC:-5}"
done

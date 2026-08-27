#!/usr/bin/env bash
set -uo pipefail

CONFIG="${1:-/root/gost-ecmp-pathlock/cn/mtcp.conf}"
LIB="${MTCP_LIB:-/root/gost-ecmp-pathlock/cn/mtcp-lib.sh}"
# shellcheck disable=SC1090
source "$LIB"
load_config "$CONFIG" || exit 30

MODE="${MTCP_PREWARM_MODE:-normal}"
case "$MODE" in
  degraded-retry) MAX_DRAWS="${DEGRADED_RETRY_DRAWS:-4}" ;;
  recovery)       MAX_DRAWS="${RECOVERY_PREWARM_DRAWS:-8}" ;;
  *)              MAX_DRAWS="${PREWARM_MAX_DRAWS:-12}" ;;
esac

LOCK_ID="${ROUTE_ID:-${UNIT%.service}}"
LOCK_ID="${LOCK_ID//[^A-Za-z0-9_.@-]/_}"
RUNTIME_DIR="$(ensure_mtcp_runtime_dir)" || exit 30
LOCK="$RUNTIME_DIR/${LOCK_ID}.prewarm.lock"
exec {LOCKFD}>"$LOCK"
flock -n "$LOCKFD" || exit 75

abort_degraded_retry_if_busy() {
    local phase="$1" pid business count sport info minrtt rtt
    [[ "$MODE" == "degraded-retry" ]] || return 1
    pid="$(get_main_pid)"
    business="$(get_business_conn_count "$pid")"
    (( business > 0 )) || return 1

    # Watchdog 的 idle 判断与真正切路之间存在时间窗。这里是 destructive
    # action 前的最后一道闸：一旦业务出现，恢复/保持 Anchor 并保留当前 outer。
    ensure_anchor || true
    count="$(get_gost_outer_count "$pid")"
    sport="$(get_single_sport "$pid" 2>/dev/null || true)"
    info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
    write_status_json "DEGRADED" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "$count" "yes"
    log_event "DEGRADED" "PREWARM_ABORT_BUSY" "PATH" "$pid" "$sport" "$minrtt" "$rtt" \
        "mode=$MODE phase=$phase business=$business"
    exit 10
}

# v1：Anchor 本身负责建立候选 outer 并在成功后直接留下。
# 抽慢路时先 stop Anchor，再 kill 当前唯一 outer；避免自动重连竞争。
abort_degraded_retry_if_busy "before_initial_anchor_stop"
stop_anchor

start_epoch="$(now_epoch)"
attempt=0
no_session_attempts=0
stable=0
candidate_sport=""

while (( $(now_epoch) - start_epoch < ${PREWARM_TOTAL_TIMEOUT_SEC:-120} )); do
    pid="$(get_main_pid)"
    if (( pid <= 0 )) || ! service_is_active; then
        stop_anchor
        write_status_json "DOWN" "PROCESS" "$pid" "" "" "" 0 "unknown"
        log_event "DOWN" "PREWARM_PROCESS_DOWN" "PROCESS" "$pid"
        exit 20
    fi

    count="$(get_gost_outer_count "$pid")"
    if (( count > 1 )); then
        stop_anchor
        write_status_json "FAULT" "MULTI_OUTER" "$pid" "" "" "" "$count" "unknown"
        log_event "FAULT" "PREWARM_MULTI_OUTER" "MULTI_OUTER" "$pid" "" "" "" "count=$count"
        exit 30
    fi

    # 没有 outer：启动 Anchor。Anchor 会主动发送 1 Byte，触发默认 Relay 并保持 logical stream。
    if (( count == 0 )); then
        stable=0; candidate_sport=""
        if ! ensure_anchor; then
            stop_anchor
            ((no_session_attempts++))
            log_event "DOWN" "PREWARM_ANCHOR_START_RETRY" "ANCHOR" "$pid" "" "" "" "attempt=$no_session_attempts/${PREWARM_NO_SESSION_ATTEMPTS:-5}"
            if (( no_session_attempts >= ${PREWARM_NO_SESSION_ATTEMPTS:-5} )); then
                write_status_json "DOWN" "NO_OUTER" "$pid" "" "" "" 0 "unknown"
                log_event "DOWN" "PREWARM_NO_OUTER" "NO_OUTER" "$pid"
                exit 20
            fi
            sleep 1
            continue
        fi
        sleep "${PREWARM_CONNECT_WAIT_SEC:-2}"
        continue
    fi

    no_session_attempts=0
    sport="$(get_single_sport "$pid" 2>/dev/null || true)"
    [[ -n "$sport" ]] || { sleep 0.2; continue; }

    # 若 outer 已存在但 Anchor 尚未挂上，先挂 Anchor；这不会新建第二条 outer，成功后再确认。
    if ! anchor_is_established; then
        if ! ensure_anchor; then
            stop_anchor
            info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
            write_status_json "DEGRADED" "ANCHOR" "$pid" "$sport" "$minrtt" "$rtt" 1 "yes"
            log_event "DEGRADED" "PREWARM_ANCHOR_FAILED" "ANCHOR" "$pid" "$sport" "$minrtt" "$rtt"
            exit 11
        fi
        sleep "${ANCHOR_STABLE_INTERVAL_SEC:-1}"
        count="$(get_gost_outer_count "$pid")"
        (( count == 1 )) || continue
        sport="$(get_single_sport "$pid" 2>/dev/null || true)"
        [[ -n "$sport" ]] || continue
    fi

    if [[ "$candidate_sport" != "$sport" ]]; then
        candidate_sport="$sport"
        stable=0
        ((attempt++))
    fi

    info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
    [[ -n "$minrtt" ]] || { stable=0; sleep 0.3; continue; }

    if is_lt "$minrtt" "$ACCEPT_RTT_MS"; then
        ((stable++))
        write_status_json "FAST" "PATH" "$pid" "$sport" "$minrtt" "$rtt" 1 "yes"
        if (( stable >= ${PREWARM_STABLE_REQUIRED:-2} )); then
            # 成功时 Anchor 已经在线，因此没有“prewarm 成功后 outer 空窗期”。
            count="$(get_gost_outer_count "$pid")"
            current="$(get_single_sport "$pid" 2>/dev/null || true)"
            if (( count == 1 )) && [[ "$current" == "$sport" ]] && anchor_is_established; then
                log_event "FAST" "PREWARM_SUCCESS" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "mode=$MODE attempt=$attempt/$MAX_DRAWS"
                exit 0
            fi
            stable=0
            continue
        fi
        sleep "${PREWARM_STABLE_INTERVAL_SEC:-1}"
        continue
    fi

    stable=0
    if (( attempt >= MAX_DRAWS )); then
        # 抽卡额度耗尽：保留最后一条可用慢路，并保持 Anchor，业务优先。
        write_status_json "DEGRADED" "PATH" "$pid" "$sport" "$minrtt" "$rtt" 1 "yes"
        log_event "DEGRADED" "PREWARM_KEEP_SLOW" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "mode=$MODE attempt=$attempt/$MAX_DRAWS"
        exit 10
    fi

    log_event "DEGRADED" "PREWARM_REJECT_SLOW" "PATH" "$pid" "$sport" "$minrtt" "$rtt" "mode=$MODE attempt=$attempt/$MAX_DRAWS"

    # 先停 Anchor；如果 outer 因最后一个 logical stream 消失而自己释放，就无需再 ss -K。
    abort_degraded_retry_if_busy "before_anchor_stop"
    stop_anchor
    sleep 0.1

    pid2="$(get_main_pid)"
    [[ "$pid2" == "$pid" ]] || exit 30
    count2="$(get_gost_outer_count "$pid")"
    if (( count2 == 0 )); then
        candidate_sport=""; stable=0
        continue
    fi
    if (( count2 > 1 )); then
        write_status_json "FAULT" "MULTI_OUTER" "$pid" "" "" "" "$count2" "unknown"
        log_event "FAULT" "PREWARM_MULTI_AFTER_ANCHOR_STOP" "MULTI_OUTER" "$pid" "" "" "" "count=$count2"
        exit 30
    fi

    sport2="$(get_single_sport "$pid" 2>/dev/null || true)"
    if [[ "$sport2" != "$sport" ]]; then
        # session 已自行换代；把新 sport 当下一张卡，不猜不杀。
        candidate_sport=""; stable=0
        continue
    fi

    abort_degraded_retry_if_busy "before_outer_kill"

    if ! kill_outer_sport "$pid" "$sport"; then
        # 再看一次：若恰好自然消失，按成功清理处理；否则才是故障。
        count3="$(get_gost_outer_count "$pid")"
        if (( count3 == 0 )); then candidate_sport=""; continue; fi
        write_status_json "FAULT" "KILL_FAILED" "$pid" "$sport" "$minrtt" "$rtt" "$count3" "unknown"
        log_event "FAULT" "PREWARM_KILL_FAILED" "KILL_FAILED" "$pid" "$sport" "$minrtt" "$rtt"
        exit 31
    fi

    if ! wait_outer_gone "$pid" "$sport" "${PREWARM_KILL_WAIT_SEC:-2}"; then
        write_status_json "FAULT" "KILL_TIMEOUT" "$pid" "$sport" "$minrtt" "$rtt" 1 "unknown"
        log_event "FAULT" "PREWARM_KILL_TIMEOUT" "KILL_TIMEOUT" "$pid" "$sport" "$minrtt" "$rtt"
        exit 31
    fi

    candidate_sport=""; stable=0
    # 下一轮由 Anchor 建立新的候选 outer。
done

pid="$(get_main_pid)"; count="$(get_gost_outer_count "$pid")"
if (( count == 1 )); then
    sport="$(get_single_sport "$pid" 2>/dev/null || true)"
    if ! anchor_is_established; then ensure_anchor || true; fi
    info="$(get_tcp_info "$sport")"; minrtt="${info%%|*}"; rtt="${info#*|}"
    write_status_json "DEGRADED" "PREWARM_TIMEOUT" "$pid" "$sport" "$minrtt" "$rtt" 1 "unknown"
    log_event "DEGRADED" "PREWARM_TIMEOUT_KEEP_CURRENT" "PREWARM_TIMEOUT" "$pid" "$sport" "$minrtt" "$rtt" "attempt=$attempt/$MAX_DRAWS"
    exit 10
fi
stop_anchor
write_status_json "DOWN" "PREWARM_TIMEOUT" "$pid" "" "" "" "$count" "unknown"
log_event "DOWN" "PREWARM_TIMEOUT_NO_OUTER" "PREWARM_TIMEOUT" "$pid"
exit 20

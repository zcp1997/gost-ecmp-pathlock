#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok - $*"; }
file_mode() {
    if stat -c '%a' "$1" 2>/dev/null; then
        return
    fi
    stat -f '%Lp' "$1"
}

for shell_file in install.sh standalone-install.sh scripts/generate-standalone.sh cn/compile-config.sh \
    ecmp-test.sh cn/mtcp-lib.sh cn/mtcp-prewarm.sh cn/mtcp-watchdog.sh; do
    bash -n "$shell_file"
done
pass "all shell files parse"

(
    ecmp_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/ecmp-test.XXXXXX")"
    trap 'rm -rf "$ecmp_test_dir"' EXIT
    cat > "$ecmp_test_dir/ss" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SS_CALL_LOG"
case "$*" in
  "-Hntie state established")
    cat <<'SS'
0 0 192.0.2.10:40000 103.201.131.7:22 uid:0 ino:111 sk:1
 cubic rtt:99/1 minrtt:99
0 0 192.0.2.10:41000 103.201.131.7:22 uid:0 ino:222 sk:2
 bbr rtt:33.5/1 minrtt:33.319
ESTAB 0 0 192.0.2.10:42000 103.201.131.7:22 uid:0 ino:333 sk:3
 bbr rtt:34/1 minrtt:34
SS
    ;;
  *"src 192.0.2.10 sport = :41000 dst 103.201.131.7 dport = :22"*)
    cat <<'SS'
ESTAB 0 0 192.0.2.10:41000 103.201.131.7:22 ino:222
 bbr rtt:33.5/1 minrtt:33.319
SS
    ;;
  *) exit 1 ;;
esac
MOCK
    chmod +x "$ecmp_test_dir/ss"
    export SS_CALL_LOG="$ecmp_test_dir/ss-calls.log"
    SS_BIN="$ecmp_test_dir/ss"
    # shellcheck disable=SC1091
    source ecmp-test.sh

    [[ "$(socket_inode_from_link 'socket:[222]')" == 222 ]] || fail "socket inode parsing failed"
    if socket_inode_from_link 'pipe:[222]' >/dev/null; then fail "non-socket FD was accepted"; fi
    endpoints="$(get_socket_endpoints 222)"
    [[ "$endpoints" == "192.0.2.10:41000 103.201.131.7:22" ]] || \
        fail "ECMP test misparsed state-filtered ss output: $endpoints"
    [[ "$(get_socket_endpoints 333)" == "192.0.2.10:42000 103.201.131.7:22" ]] || \
        fail "ECMP test misparsed regular ss output"
    [[ "$(get_minrtt_for_flow 192.0.2.10:41000 103.201.131.7:22)" == 33.319 ]] || \
        fail "ECMP test read minrtt from the wrong flow"
    grep -Fq 'src 192.0.2.10 sport = :41000 dst 103.201.131.7 dport = :22' "$SS_CALL_LOG" || \
        fail "ECMP test did not query the complete TCP four-tuple"
)
! grep -q 'grep -m1.*minrtt\|10\\\.[0-9]' ecmp-test.sh || fail "unsafe ECMP lookup remains"
pass "ECMP sampler binds TCP_INFO reads to the current FD and four-tuple"

scripts/generate-standalone.sh --check >/dev/null
pass "standalone embedded payload matches canonical files"

grep -Fqx '    auther: mtcp-auth' remote/remote.yaml || fail "Remote Relay authenticator is missing"
grep -Fqx '          file: /root/gost-ecmp-pathlock/cn/instances/default/mtcp.auth' cn/cn.yaml || \
    fail "CN Relay connector auth is missing"
grep -Fqx '      addr: backend.example.invalid:1' cn/cn.yaml || \
    fail "canonical CN template does not use a non-routable backend placeholder"
! grep -Fq '127.0.0.1:2345' cn/cn.yaml || \
    fail "canonical CN template still silently targets the old default backend"
grep -Fq 'bash "$PROJECT_ROOT/standalone-install.sh" cn' install.sh || \
    fail "traditional installer does not delegate to the shared CN implementation"
! grep -Eq '^[[:space:]]*password:' remote/remote.yaml cn/cn.yaml || fail "plaintext password embedded in YAML"
grep -Fqx 'ExecStart=/root/gost-ecmp-pathlock/cn/gost -D -C /root/gost-ecmp-pathlock/cn/runtime.yaml' \
    cn/gost-ecmp-pathlock.service || fail "canonical CN unit does not use the aggregate config"
pass "canonical installs use file-backed Relay auth and one aggregate GOST config"

compile_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/pathlock-compile.XXXXXX")"
cn/compile-config.sh "$compile_test_dir/runtime.yaml" cn/cn.yaml
[[ "$(grep -c '^services:$' "$compile_test_dir/runtime.yaml")" == 1 && \
   "$(grep -c '^chains:$' "$compile_test_dir/runtime.yaml")" == 1 ]] || \
    fail "route compiler did not emit one aggregate document"
if cn/compile-config.sh "$compile_test_dir/duplicate.yaml" cn/cn.yaml cn/cn.yaml >/dev/null 2>&1; then
    fail "route compiler accepted duplicate services, chains, and Remote endpoints"
fi
sed -e 's/default/jp/g' -e 's/:12000/:12100/g' -e 's/:12001/:12101/g' \
    -e 's/remote\.example\.invalid:6600/198.51.100.20:6601/g' cn/cn.yaml > "$compile_test_dir/jp.yaml"
cn/compile-config.sh "$compile_test_dir/two-routes.yaml" cn/cn.yaml "$compile_test_dir/jp.yaml"
awk '
    !changed && $0 == "    chain: chain-mtcp-default" {
        print "    chain: chain-mtcp-jp"
        changed=1
        next
    }
    { print }
' cn/cn.yaml > "$compile_test_dir/cross-route.yaml"
if cn/compile-config.sh "$compile_test_dir/cross-route-runtime.yaml" \
    "$compile_test_dir/cross-route.yaml" "$compile_test_dir/jp.yaml" >/dev/null 2>&1; then
    fail "route compiler accepted a service wired to another route's existing chain"
fi
rm -rf "$compile_test_dir"
pass "route compiler enforces aggregate uniqueness and fragment ownership"

[[ "$(bash standalone-install.sh --version)" == *"v2.2.1" ]] || \
    fail "standalone version was not bumped for lifecycle transaction hardening"
help_output="$(bash standalone-install.sh --help)"
[[ "$help_output" == *"打开统一管理菜单"* && "$help_output" == *"CN_INSTANCE"* && \
   "$help_output" == *"instance remove"* && "$help_output" == *"uninstall"* && \
   "$help_output" == *"NO_COLOR"* ]] || fail "standalone help misses management or automation commands"
pipe_help="$(bash -s -- --help < standalone-install.sh)"
[[ "$pipe_help" == *"打开统一管理菜单"* ]] || fail "piped standalone help failed"
pass "standalone supports the management menu plus file and piped execution"

(
    integration_dir="$(mktemp -d "${TMPDIR:-/tmp}/standalone-integration.XXXXXX")"
    integration_dir="$(cd -P "$integration_dir" && pwd -P)"
    trap 'rm -rf "$integration_dir"' EXIT
    mkdir -p "$integration_dir/bin" "$integration_dir/systemd" "$integration_dir/systemctl-state"
    cat > "$integration_dir/bin/systemctl-mock" <<MOCK
#!/usr/bin/env bash
set -u
state_dir='$integration_dir/systemctl-state'
systemd_dir='$integration_dir/systemd'
wants_dir="\$systemd_dir/multi-user.target.wants"
command_name="\${1:-}"; shift || true
case "\$command_name" in
  is-active)
    [[ "\${1:-}" == --quiet ]] && shift
    unit="\${1:-missing}"
    [[ "\${MOCK_FAIL_IS_ACTIVE:-0}" != 1 ]] || exit 1
    [[ ! -f "\$state_dir/\$unit" ]] || exit 0
    [[ -e "\$systemd_dir/\$unit" || -L "\$systemd_dir/\$unit" ]] && exit 3
    exit 4
    ;;
  enable)
    mkdir -p "\$wants_dir"
    for unit in "\$@"; do
      [[ "\$unit" == -* ]] && continue
      ln -sfn "\$systemd_dir/\$unit" "\$wants_dir/\$unit"
    done
    [[ "\${MOCK_FAIL_ENABLE:-0}" != 1 ]]
    ;;
  disable)
    [[ "\${MOCK_FAIL_DISABLE:-0}" != 1 ]] || exit 1
    for unit in "\$@"; do
      [[ "\$unit" == -* ]] && continue
      rm -f "\$wants_dir/\$unit"
    done
    ;;
  restart)
    [[ "\${MOCK_FAIL_RESTART:-0}" == 1 ]] && exit 1
    if [[ -n "\${MOCK_FAIL_RESTART_ONCE_FILE:-}" && ! -e "\$MOCK_FAIL_RESTART_ONCE_FILE" ]]; then
      touch "\$MOCK_FAIL_RESTART_ONCE_FILE"
      exit 1
    fi
    for unit in "\$@"; do
      touch "\$state_dir/\$unit"
      [[ "\${MOCK_FAIL_RESTART_UNIT:-}" != "\$unit" ]] || exit 1
    done
    ;;
  stop)
    [[ "\${MOCK_FAIL_STOP:-0}" == 1 ]] && exit 1
    for unit in "\$@"; do rm -f "\$state_dir/\$unit"; done
    ;;
  show) echo 0 ;;
  list-units)
    for state in "\$state_dir"/*.service; do
      [[ -f "\$state" ]] || continue
      printf '%s loaded active running mock\n' "\$(basename "\$state")"
    done
    ;;
  list-unit-files)
    for file in "\$systemd_dir"/*.service; do
      [[ -e "\$file" || -L "\$file" ]] || continue
      printf '%s enabled\n' "\$(basename "\$file")"
    done
    ;;
  daemon-reload)
    if [[ -n "\${MOCK_FAIL_DAEMON_RELOAD_ONCE_FILE:-}" && ! -e "\$MOCK_FAIL_DAEMON_RELOAD_ONCE_FILE" ]]; then
      touch "\$MOCK_FAIL_DAEMON_RELOAD_ONCE_FILE"
      exit 1
    fi
    [[ "\${MOCK_FAIL_DAEMON_RELOAD:-0}" != 1 ]]
    ;;
  *) exit 0 ;;
esac
MOCK
    chmod +x "$integration_dir/bin/systemctl-mock"
    cat > "$integration_dir/bin/flock" <<'MOCK'
#!/usr/bin/env bash
[[ -z "${MOCK_FLOCK_LOG:-}" ]] || printf '%s\n' "${PATHLOCK_LOCK_KIND:-unknown}" >> "$MOCK_FLOCK_LOG"
if [[ "${MOCK_FAIL_MANAGER_LOCK:-0}" == 1 && "${PATHLOCK_LOCK_KIND:-}" == manager ]]; then
    exit 1
fi
exit 0
MOCK
    chmod +x "$integration_dir/bin/flock"
    for mock_command in timeout socat; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$integration_dir/bin/$mock_command"
        chmod +x "$integration_dir/bin/$mock_command"
    done
    cat > "$integration_dir/bin/ss" <<'MOCK'
#!/usr/bin/env bash
if [[ -n "${MOCK_BUSY_PORT:-}" && "$*" == *"sport = :$MOCK_BUSY_PORT"* && "$*" == *established* ]]; then
    echo "0 0 127.0.0.1:$MOCK_BUSY_PORT 198.51.100.10:40000"
fi
exit 0
MOCK
    chmod +x "$integration_dir/bin/ss"
    PATH="$integration_dir/bin:$PATH"

    # 只加载 standalone 的函数区，避免执行 main 和后面的嵌入 payload。
    awk '$0 == "main \"$@\"" { exit } { print }' standalone-install.sh > "$integration_dir/core.sh"
    # shellcheck disable=SC1090
    source "$integration_dir/core.sh"
    trap 'rm -rf "$integration_dir"' EXIT
    EMBEDDED_SOURCE="$ROOT_DIR/standalone-install.sh"
    INSTALL_BASE="$integration_dir/install"
    PATHLOCK_RUNTIME_DIR="$integration_dir/run"
    PATHLOCK_LEGACY_RUNTIME_DIR="$integration_dir/legacy-run"
    mkdir -p "$PATHLOCK_RUNTIME_DIR" "$PATHLOCK_LEGACY_RUNTIME_DIR"
    export MTCP_AUTH_PASSWORD="PathLock-Integration#2026"
    valid_mtcp_auth_password "$MTCP_AUTH_PASSWORD" || fail "valid MTCP password was rejected"
    if valid_mtcp_auth_password "too-short"; then fail "short MTCP password was accepted"; fi
    if valid_mtcp_auth_password "contains whitespace"; then fail "MTCP password with spaces was accepted"; fi
    SYSTEMD_DIR="$integration_dir/systemd"
    SYSTEMCTL_BIN="$integration_dir/bin/systemctl-mock"
    download_gost() {
        local mock_version="${MOCK_GOST_VERSION:-v1}" mock_rc=0
        mkdir -p "$2"
        [[ "$mock_version" == invalid ]] && mock_rc=1
        cat > "$2/gost" <<MOCK
#!/usr/bin/env bash
# mock-gost-$mock_version
config=""
while (( \$# > 0 )); do
    if [[ "\$1" == -C ]]; then
        shift
        config="\${1:-}"
    fi
    shift || true
done
if [[ -n "\$config" && "\$config" != *.yaml ]]; then
    echo "Unsupported Config Type \"\${config##*.}\"" >&2
    exit 1
fi
exit $mock_rc
MOCK
        chmod +x "$2/gost"
    }

    # 使用真实 prompt_read 覆盖嵌套 helper 的动态作用域场景；过去输入虽然
    # 成功读取，却被 prompt_read 自己的 local value 吞掉并触发 set -u。
    printf 'Q\n45199\n' > "$integration_dir/prompt-input"
    exec 7< "$integration_dir/prompt-input"
    PROMPT_FD=7; PROMPT_FD_READY=1
    real_menu_choice=""; real_prompt_port=""
    ui_menu_choice real_menu_choice "测试菜单: "
    ui_prompt_port real_prompt_port "测试端口: " 12000
    exec 7<&-
    PROMPT_FD=0; PROMPT_FD_READY=0
    [[ "$real_menu_choice" == Q && "$real_prompt_port" == 45199 ]] || \
        fail "real prompt input was not returned through nested UI helpers"

    prompt_read() {
        local output_var="$1"
        printf -v "$output_var" '%s' "${PROMPTS[$PROMPT_INDEX]}"
        PROMPT_INDEX=$((PROMPT_INDEX + 1))
    }

    NO_COLOR=1
    ui_init
    (( UI_COLOR_ENABLED == 0 )) || fail "NO_COLOR did not disable ANSI colors"
    [[ -z "$UI_GREEN" && -z "$UI_RED" && -z "$UI_BLUE" ]] || fail "ANSI codes remain under NO_COLOR"
    unset NO_COLOR
    ui_init
    badge_output="$(ui_status_badge FAST)"
    [[ "$badge_output" == *"● FAST"* && "$badge_output" != *$'\033'* ]] || \
        fail "non-TTY status badge is not plain text"

    PATHLOCK_INTERACTIVE_MENU=1
    PROMPTS=(not-a-port 45199); PROMPT_INDEX=0
    ui_prompt_output="$integration_dir/ui-prompt.out"
    ui_prompt_port ui_test_port "测试端口: " 12000 >"$ui_prompt_output" 2>&1 || \
        fail "interactive port prompt did not retry"
    [[ "$ui_test_port" == 45199 && "$PROMPT_INDEX" == 2 ]] || \
        fail "interactive port prompt did not consume invalid then valid input"
    grep -q '端口必须是 1-65535' "$ui_prompt_output" || fail "invalid port did not show a UI error"
    set +e
    ( PATHLOCK_INTERACTIVE_MENU=0; PROMPTS=(not-a-port); PROMPT_INDEX=0
      ui_prompt_port ignored "测试端口: " 12000 ) >/dev/null 2>&1
    automation_invalid_port_rc=$?
    set -e
    (( automation_invalid_port_rc != 0 )) || fail "automation mode stopped failing fast on invalid input"

    PROMPTS=("bad host" "" not-a-port 24567); PROMPT_INDEX=0
    backend_prompt_output="$integration_dir/backend-prompt.out"
    prompt_backend_addr prompted_backend "测试后端" >"$backend_prompt_output" 2>&1 || \
        fail "backend prompt did not retry invalid host or port"
    [[ "$prompted_backend" == "127.0.0.1:24567" && "$PROMPT_INDEX" == 4 ]] || \
        fail "backend prompt did not apply the localhost default and explicit port"
    grep -q '后端地址无效' "$backend_prompt_output" && \
        grep -q '端口必须是 1-65535' "$backend_prompt_output" || \
        fail "backend prompt did not explain invalid input"
    PROMPTS=(2001:db8::1 8443); PROMPT_INDEX=0
    prompt_backend_addr prompted_backend "测试后端" >/dev/null 2>&1 || \
        fail "backend prompt rejected an IPv6 host"
    [[ "$prompted_backend" == "[2001:db8::1]:8443" ]] || \
        fail "backend prompt did not bracket an IPv6 host"
    set +e
    ( PATHLOCK_INTERACTIVE_MENU=0; PROMPTS=("bad host"); PROMPT_INDEX=0
      prompt_backend_addr ignored "测试后端" ) >/dev/null 2>&1
    automation_invalid_backend_rc=$?
    set -e
    (( automation_invalid_backend_rc != 0 )) || \
        fail "automation mode did not fail fast on an invalid backend host"

    ui_failure_tmp="$integration_dir/ui-failure.tmp"
    ui_test_failure() {
        : > "$ui_failure_tmp"
        CLEANUP_PATHS+=("$ui_failure_tmp")
        die "模拟用户输入错误"
    }
    PROMPTS=(""); PROMPT_INDEX=0
    ui_action_output="$integration_dir/ui-action.out"
    set +e
    ui_run_action "测试操作" "主菜单" ui_test_failure >"$ui_action_output" 2>&1
    ui_action_rc=$?
    set -e
    (( ui_action_rc == 0 )) || fail "menu action failure escaped to the whole manager"
    [[ "$PROMPT_INDEX" == 1 ]] || fail "failed menu action did not pause before returning"
    grep -q '测试操作 失败' "$ui_action_output" || fail "failed menu action did not render an error"
    [[ ! -e "$ui_failure_tmp" ]] || fail "isolated menu action leaked temporary files"

    # action 不能作为 if 条件执行，否则 Bash 会悄悄禁用整个调用链的 errexit。
    ui_errexit_before="$integration_dir/ui-errexit.before"
    ui_errexit_after="$integration_dir/ui-errexit.after"
    ui_test_errexit() {
        : > "$ui_errexit_before"
        false
        : > "$ui_errexit_after"
    }
    PROMPTS=(""); PROMPT_INDEX=0
    ui_errexit_output="$integration_dir/ui-errexit.out"
    set +e
    ui_run_action "errexit 测试" "主菜单" ui_test_errexit >"$ui_errexit_output" 2>&1
    ui_errexit_rc=$?
    set -e
    (( ui_errexit_rc == 0 )) || fail "menu errexit test escaped to the manager"
    [[ -e "$ui_errexit_before" && ! -e "$ui_errexit_after" ]] || \
        fail "menu action ignored an unhandled command failure"
    grep -q 'errexit 测试 失败' "$ui_errexit_output" || \
        fail "menu action did not report an errexit failure"

    relay_card_output="$integration_dir/relay-card.out"
    ui_relay_change_card "新增" jp :12002 127.0.0.1:2347 chain-mtcp-jp 7 \
        >"$relay_card_output" 2>&1
    grep -q '即将新增端口转发' "$relay_card_output" && grep -q '当前存在 7 条活跃业务连接' "$relay_card_output" || \
        fail "destructive Relay summary card is incomplete"
    PATHLOCK_INTERACTIVE_MENU=0

    mkdir -p "$INSTALL_BASE/cn"
    set +e
    ( export MOCK_FAIL_MANAGER_LOCK=1
      PROMPTS=(); PROMPT_INDEX=0
      install_cn >/dev/null 2>&1 )
    lifecycle_lock_rc=$?
    set -e
    (( lifecycle_lock_rc != 0 )) || fail "CN install ignored the global lifecycle lock"
    [[ ! -e "$INSTALL_BASE/cn/config.lock" ]] || \
        fail "CN config lock was acquired before the global lifecycle lock"

    # 首次安装在 enable 之后失败时，artifact rollback 还必须撤销新 unit 的
    # Wants symlink；仅删除 unit 文件会留下 broken enable 状态。
    first_main_link="$SYSTEMD_DIR/multi-user.target.wants/gost-mtcp.service"
    first_watchdog_link="$SYSTEMD_DIR/multi-user.target.wants/gost-mtcp-firstfail-watchdog.service"
    set +e
    ( export MOCK_FAIL_RESTART=1
      PROMPTS=(firstfail 192.0.2.50 6650 45090 "" 25090 45091 40); PROMPT_INDEX=0
      install_cn >/dev/null 2>&1 )
    first_install_failure_rc=$?
    set -e
    (( first_install_failure_rc != 0 )) || fail "first-install restart failure simulation unexpectedly succeeded"
    [[ ! -e "$first_main_link" && ! -L "$first_main_link" ]] || \
        fail "failed first install left gost-mtcp.service enabled"
    [[ ! -e "$first_watchdog_link" && ! -L "$first_watchdog_link" ]] || \
        fail "failed first install left its new Watchdog enabled"
    [[ ! -e "$SYSTEMD_DIR/gost-mtcp.service" ]] || \
        fail "failed first install left the shared main unit file"
    [[ ! -e "$SYSTEMD_DIR/gost-mtcp-firstfail-watchdog.service" ]] || \
        fail "failed first install left the new Watchdog unit file"

    cat > "$INSTALL_BASE/cn/mtcp.conf" <<'LEGACY'
UNIT="gost-mtcp-jp.service"
BUSINESS_PORT="45100"
ANCHOR_PORT="45101"
LEGACY
    awk '
      # 模拟升级前没有 connector.auth 的旧版 YAML，验证安装器会补上鉴权且保留 Relay。
      skip_old_auth && /^          / { next }
      skip_old_auth { skip_old_auth=0 }
      /^        auth:[[:space:]]*$/ { skip_old_auth=1; next }
      /^- name:[[:space:]]*mtcp-anchor([A-Za-z0-9_-]*)?[[:space:]]*$/ && !inserted {
        print "# standalone-relay: relay-45104"
        print "- name: relay-45104"
        print "  addr: :45104"
        print "  handler:"
        print "    type: tcp"
        print "    chain: chain-mtcp-default"
        print "  listener:"
        print "    type: tcp"
        print "  forwarder:"
        print "    nodes:"
        print "    - name: backend-45104"
        print "      addr: 127.0.0.1:2347"
        print ""
        inserted=1
      }
      { print }
    ' cn/cn.yaml > "$INSTALL_BASE/cn/cn.yaml"
    PROMPTS=(jp 45.142.125.253 5201 45100 "" 24500 45101 40); PROMPT_INDEX=0
    install_cn >/dev/null
    grep -q 'name: relay-45104' "$INSTALL_BASE/cn/instances/jp/cn.yaml" || \
        fail "legacy Relay was not preserved during migration"
    grep -q '^BUSINESS_PORTS="45100 45104"$' "$INSTALL_BASE/cn/instances/jp/mtcp.conf" || \
        fail "legacy Relay was not included in BUSINESS_PORTS"
    unset CN_INSTANCE CN_YAML_PATH CN_MTCP_CONFIG_PATH
    resolve_cn_relay_context
    [[ "$CN_RELAY_YAML" == "$INSTALL_BASE/cn/instances/jp/cn.yaml" ]] || \
        fail "Relay resolver preferred legacy flat config after migration"
    PROMPTS=(us 198.51.100.20 6600 45102 10.0.0.20 24502 45103 45); PROMPT_INDEX=0
    install_cn >/dev/null

    jp="$INSTALL_BASE/cn/instances/jp"
    us="$INSTALL_BASE/cn/instances/us"
    [[ -f "$jp/cn.yaml" && -f "$jp/mtcp.conf" && -f "$jp/mtcp.auth" && -d "$jp/state" ]] || \
        fail "jp instance or auth file missing"
    [[ -f "$us/cn.yaml" && -f "$us/mtcp.conf" && -f "$us/mtcp.auth" && -d "$us/state" ]] || \
        fail "us instance or auth file missing"
    [[ "$(file_mode "$jp/mtcp.auth")" == 600 ]] || fail "CN auth file permissions are not 0600"
    grep -Fqx "mtcp $MTCP_AUTH_PASSWORD" "$jp/mtcp.auth" || fail "CN auth credentials are incorrect"
    grep -Fqx "          file: '$jp/mtcp.auth'" "$jp/cn.yaml" || fail "CN connector auth path was not rendered"
    ! grep -Fq "$MTCP_AUTH_PASSWORD" "$jp/cn.yaml" || fail "CN password leaked into YAML"
    grep -q 'DST="45.142.125.253"' "$jp/mtcp.conf" || fail "jp config was overwritten"
    grep -q 'DST="198.51.100.20"' "$us/mtcp.conf" || fail "us config is incorrect"
    grep -Fqx 'UNIT="gost-mtcp.service"' "$jp/mtcp.conf" || fail "jp does not use shared GOST unit"
    grep -Fqx 'UNIT="gost-mtcp.service"' "$us/mtcp.conf" || fail "us does not use shared GOST unit"
    [[ -f "$SYSTEMD_DIR/gost-mtcp.service" ]] || fail "shared GOST unit missing"
    [[ ! -e "$SYSTEMD_DIR/gost-mtcp-jp.service" && ! -e "$SYSTEMD_DIR/gost-mtcp-us.service" ]] || \
        fail "per-route GOST main units still exist"
    grep -Fqx "ExecStart=$INSTALL_BASE/cn/gost -D -C $INSTALL_BASE/cn/runtime.yaml" \
        "$SYSTEMD_DIR/gost-mtcp.service" || fail "shared unit does not use aggregate YAML"
    grep -Fq -- '- name: chain-mtcp-jp' "$INSTALL_BASE/cn/runtime.yaml" || fail "aggregate misses jp chain"
    grep -Fq -- '- name: chain-mtcp-us' "$INSTALL_BASE/cn/runtime.yaml" || fail "aggregate misses us chain"
    grep -Fq -- '- name: tcp-entry-jp' "$INSTALL_BASE/cn/runtime.yaml" || fail "aggregate misses jp service"
    grep -Fq -- '- name: tcp-entry-us' "$INSTALL_BASE/cn/runtime.yaml" || fail "aggregate misses us service"
    grep -Fqx '      addr: 127.0.0.1:24500' "$jp/cn.yaml" || \
        fail "jp primary forwarding did not use the default backend host and configured port"
    grep -Fqx '      addr: 10.0.0.20:24502' "$us/cn.yaml" || \
        fail "us primary forwarding did not use the configured backend host and port"
    ! grep -Fq 'backend.example.invalid' "$INSTALL_BASE/cn/runtime.yaml" || \
        fail "aggregate retained the canonical backend placeholder"
    grep -Fqx "ExecStart=$INSTALL_BASE/cn/mtcp-watchdog.sh $jp/mtcp.conf" \
        "$SYSTEMD_DIR/gost-mtcp-jp-watchdog.service" || fail "watchdog unit does not use isolated state config"

    cp -p "$us/mtcp.conf" "$integration_dir/us.mtcp.conf.policy-backup"
    sed -i.bak 's/^PROCESS_RECOVERY_MAX=.*/PROCESS_RECOVERY_MAX="5"/' "$us/mtcp.conf"
    rm -f "$us/mtcp.conf.bak"
    set +e
    policy_failure_output="$(
      PROMPTS=(policyfail 203.0.113.33 6703 45126 "" 25126 45127 45); PROMPT_INDEX=0
      install_cn 2>&1
    )"
    policy_failure_rc=$?
    set -e
    (( policy_failure_rc != 0 )) || fail "inconsistent route-local PROCESS policy was accepted"
    [[ "$policy_failure_output" == *"共享 PROCESS recovery 参数不一致"* ]] || \
        fail "PROCESS policy mismatch did not fail for the expected reason"
    mv -f "$integration_dir/us.mtcp.conf.policy-backup" "$us/mtcp.conf"
    ! grep -Fq 'chain-mtcp-policyfail' "$INSTALL_BASE/cn/runtime.yaml" || \
        fail "PROCESS policy mismatch modified aggregate runtime"

    # 正式 shared artifacts 必须在全部 validation 前保持不变，并在 commit 后的
    # service failure 中与 route/runtime/units 一起回滚。
    shared_marker="# preserved-shared-artifact-v1"
    shared_scripts=(mtcp-lib.sh mtcp-prewarm.sh mtcp-watchdog.sh compile-config.sh)
    for shared_script in "${shared_scripts[@]}"; do
        printf '%s\n' "$shared_marker" >> "$INSTALL_BASE/cn/$shared_script"
    done
    grep -Fq '# mock-gost-v1' "$INSTALL_BASE/cn/gost" || fail "unexpected initial mock GOST version"

    set +e
    ( export MOCK_GOST_VERSION=invalid
      PROMPTS=(validationfail 203.0.113.30 6700 45120 "" 25120 45121 45); PROMPT_INDEX=0
      install_cn >/dev/null 2>&1 )
    validation_failure_rc=$?
    set -e
    (( validation_failure_rc != 0 )) || fail "invalid staged GOST unexpectedly passed validation"
    for shared_script in "${shared_scripts[@]}"; do
        grep -Fqx "$shared_marker" "$INSTALL_BASE/cn/$shared_script" || \
            fail "$shared_script changed before candidate validation completed"
    done
    grep -Fq '# mock-gost-v1' "$INSTALL_BASE/cn/gost" || \
        fail "formal GOST changed before candidate validation completed"
    ! grep -Fq 'chain-mtcp-validationfail' "$INSTALL_BASE/cn/runtime.yaml" || \
        fail "failed validation leaked into aggregate runtime"

    stale_controls="$integration_dir/stale-controls"
    mkdir -p "$stale_controls/instances/old"
    cat > "$stale_controls/instances/old/mtcp.conf" <<'STALE'
WATCHDOG_UNIT="removed-watchdog.service"
ANCHOR_UNIT="removed-anchor.service"
STALE
    ( export MOCK_FAIL_STOP=1; stop_cn_route_controls "$stale_controls" 1 ) || \
        fail "already-inactive stale control units blocked the shared transaction"
    set +e
    ( export MOCK_FAIL_STOP=1 MOCK_FAIL_IS_ACTIVE=1
      stop_cn_route_controls "$stale_controls" 1 ) >/dev/null 2>&1
    control_query_failure_rc=$?
    set -e
    (( control_query_failure_rc != 0 )) || \
        fail "strict control stop treated a systemd status query error as inactive"

    set +e
    ( export MOCK_GOST_VERSION=v2 MOCK_FAIL_STOP=1
      PROMPTS=(stopfail 203.0.113.32 6702 45124 "" 25124 45125 45); PROMPT_INDEX=0
      install_cn >/dev/null 2>&1 )
    shared_stop_failure_rc=$?
    set -e
    (( shared_stop_failure_rc != 0 )) || fail "route-control stop failure simulation unexpectedly succeeded"
    for shared_script in "${shared_scripts[@]}"; do
        grep -Fqx "$shared_marker" "$INSTALL_BASE/cn/$shared_script" || \
            fail "$shared_script changed even though route controls did not stop"
    done
    grep -Fq '# mock-gost-v1' "$INSTALL_BASE/cn/gost" || \
        fail "formal GOST changed even though route controls did not stop"
    ! grep -Fq 'chain-mtcp-stopfail' "$INSTALL_BASE/cn/runtime.yaml" || \
        fail "failed route-control stop leaked into aggregate runtime"

    set +e
    ( export MOCK_GOST_VERSION=v2 MOCK_FAIL_DAEMON_RELOAD=1
      PROMPTS=(reloadfail 203.0.113.34 6704 45128 "" 25128 45129 45); PROMPT_INDEX=0
      install_cn >/dev/null 2>&1 )
    shared_reload_failure_rc=$?
    set -e
    (( shared_reload_failure_rc != 0 )) || fail "daemon-reload failure simulation unexpectedly succeeded"
    for shared_script in "${shared_scripts[@]}"; do
        grep -Fqx "$shared_marker" "$INSTALL_BASE/cn/$shared_script" || \
            fail "$shared_script was not restored after daemon-reload failure"
    done
    grep -Fq '# mock-gost-v1' "$INSTALL_BASE/cn/gost" || \
        fail "GOST binary was not restored after daemon-reload failure"
    ! grep -Fq 'chain-mtcp-reloadfail' "$INSTALL_BASE/cn/runtime.yaml" || \
        fail "daemon-reload failure leaked into aggregate runtime"

    set +e
    ( export MOCK_GOST_VERSION=v2 MOCK_FAIL_ENABLE=1
      PROMPTS=(enablefail 203.0.113.35 6705 45130 "" 25130 45131 45); PROMPT_INDEX=0
      install_cn >/dev/null 2>&1 )
    shared_enable_failure_rc=$?
    set -e
    (( shared_enable_failure_rc != 0 )) || fail "systemd enable failure simulation unexpectedly succeeded"
    for shared_script in "${shared_scripts[@]}"; do
        grep -Fqx "$shared_marker" "$INSTALL_BASE/cn/$shared_script" || \
            fail "$shared_script was not restored after systemd enable failure"
    done
    grep -Fq '# mock-gost-v1' "$INSTALL_BASE/cn/gost" || \
        fail "GOST binary was not restored after systemd enable failure"
    ! grep -Fq 'chain-mtcp-enablefail' "$INSTALL_BASE/cn/runtime.yaml" || \
        fail "systemd enable failure leaked into aggregate runtime"

    watchfail_unit="gost-mtcp-watchfail-watchdog.service"
    watchfail_link="$SYSTEMD_DIR/multi-user.target.wants/$watchfail_unit"
    set +e
    ( export MOCK_GOST_VERSION=v2 MOCK_FAIL_RESTART_UNIT="$watchfail_unit"
      PROMPTS=(watchfail 203.0.113.36 6706 45132 "" 25132 45133 45); PROMPT_INDEX=0
      install_cn >/dev/null 2>&1 )
    watchdog_restart_failure_rc=$?
    set -e
    (( watchdog_restart_failure_rc != 0 )) || fail "new Watchdog restart failure simulation unexpectedly succeeded"
    [[ ! -e "$watchfail_link" && ! -L "$watchfail_link" ]] || \
        fail "failed CN transaction left its new Watchdog enabled"
    [[ ! -e "$SYSTEMD_DIR/$watchfail_unit" ]] || \
        fail "failed CN transaction left its new Watchdog unit file"
    [[ ! -e "$INSTALL_BASE/cn/instances/watchfail/mtcp.conf" ]] || \
        fail "failed CN transaction left its new route config"
    ! grep -Fq 'chain-mtcp-watchfail' "$INSTALL_BASE/cn/runtime.yaml" || \
        fail "new Watchdog restart failure leaked into aggregate runtime"
    for shared_script in "${shared_scripts[@]}"; do
        grep -Fqx "$shared_marker" "$INSTALL_BASE/cn/$shared_script" || \
            fail "$shared_script was not restored after new Watchdog restart failure"
    done
    grep -Fq '# mock-gost-v1' "$INSTALL_BASE/cn/gost" || \
        fail "GOST binary was not restored after new Watchdog restart failure"

    set +e
    ( export MOCK_GOST_VERSION=v2 MOCK_FAIL_RESTART=1
      PROMPTS=(restartfail 203.0.113.31 6701 45122 "" 25122 45123 45); PROMPT_INDEX=0
      install_cn >/dev/null 2>&1 )
    shared_restart_failure_rc=$?
    set -e
    (( shared_restart_failure_rc != 0 )) || fail "shared restart failure simulation unexpectedly succeeded"
    for shared_script in "${shared_scripts[@]}"; do
        grep -Fqx "$shared_marker" "$INSTALL_BASE/cn/$shared_script" || \
            fail "$shared_script was not restored with the shared transaction"
    done
    grep -Fq '# mock-gost-v1' "$INSTALL_BASE/cn/gost" || \
        fail "GOST binary was not restored with the shared transaction"
    ! grep -Fq 'chain-mtcp-restartfail' "$INSTALL_BASE/cn/runtime.yaml" || \
        fail "failed shared commit was not removed from aggregate runtime"

    config_listing="$(list_installed_configurations)"
    [[ "$config_listing" == *"线路 jp"* && "$config_listing" == *"线路 us"* && \
       "$config_listing" == *"端口路径"* && "$config_listing" == *"127.0.0.1:24500"* && \
       "$config_listing" == *"10.0.0.20:24502"* && "$config_listing" != *"127.0.0.1:2345"* ]] || \
        fail "management menu did not list user-configured routes and port paths"
    PROMPTS=(02); PROMPT_INDEX=0
    selected_yaml=""; selected_config=""
    route_selector_output="$integration_dir/route-selector.out"
    select_cn_route selected_yaml selected_config "测试线路选择" >"$route_selector_output" || fail "route selection failed"
    [[ "$selected_yaml" == "$us/cn.yaml" && "$selected_config" == "$us/mtcp.conf" ]] || \
        fail "route selector did not return the selected instance"
    grep -q '\[1\] jp' "$route_selector_output" && grep -q 'Remote   45.142.125.253:5201' "$route_selector_output" || \
        fail "route selector is not rendered as a detailed list"
    unset CN_INSTANCE CN_YAML_PATH CN_MTCP_CONFIG_PATH
    PROMPTS=(2); PROMPT_INDEX=0
    relay_list_output="$(manage_cn_relays list)"
    [[ "$relay_list_output" == *"tcp-entry-us"* ]] || \
        fail "Relay manager still requires CN_INSTANCE for multiple routes"

    mkdir -p "$jp/state"
    printf '%s\n' '{"state":"FAST","reason":"PATH","route":"jp","minrtt_ms":"33.2","rtt_ms":"34.8","outer_count":1,"remote_reachable":"yes","data_plane_reachable":"yes","business_connections":0}' \
        > "$jp/state/status.json"
    printf '%s\n' '{"event":"PREWARM_SUCCESS","route":"jp"}' > "$jp/state/events.jsonl"
    tail_mock_dir="$integration_dir/tail-mock"
    mkdir -p "$tail_mock_dir"
    cat > "$tail_mock_dir/tail" <<'MOCK'
#!/usr/bin/env bash
kill -INT "$UI_TAIL_PARENT"
sleep 2
: > "$UI_TAIL_LEAK"
MOCK
    chmod +x "$tail_mock_dir/tail"
    tail_follow_output="$integration_dir/tail-follow.out"
    tail_leak="$integration_dir/tail-follow.leak"
    set +e
    PATH="$tail_mock_dir:$PATH" UI_TAIL_LEAK="$tail_leak" bash -c '
      source "$1"
      export UI_TAIL_PARENT=$$
      ui_init
      ui_follow_log "$2"
      echo manager-survived
    ' _ "$integration_dir/core.sh" "$jp/state/events.jsonl" >"$tail_follow_output" 2>&1
    tail_follow_rc=$?
    set -e
    (( tail_follow_rc == 0 )) && [[ ! -e "$tail_leak" ]] && grep -q 'manager-survived' "$tail_follow_output" || \
        fail "Ctrl-C from tail -f escaped or terminated the standalone manager"

    PROMPTS=(1 1 b); PROMPT_INDEX=0
    log_output="$(view_cn_route_logs)"
    [[ "$log_output" == *'"event":"PREWARM_SUCCESS"'* && "$log_output" == *"minRTT"* && \
       "$log_output" == *"33.2 ms"* ]] || fail "status/log menu did not show summary and route events"
    PATHLOCK_INTERACTIVE_MENU=1
    PROMPTS=(2 "" q); PROMPT_INDEX=0
    main_menu_output="$(interactive_main_menu)"
    [[ "$main_menu_output" == *"GOST ECMP PathLock Manager"* && \
       "$main_menu_output" == *"[1]  安装 / 新增线路"* && \
       "$main_menu_output" == *"[5]  删除 CN 线路实例"* && \
       "$main_menu_output" == *"[6]  完全卸载 PathLock"* && \
       "$main_menu_output" == *"线路 jp"* && "$main_menu_output" == *"已退出"* ]] || \
        fail "top-level management dashboard did not expose all management actions"
    PROMPTS=(invalid q); PROMPT_INDEX=0
    invalid_menu_output="$integration_dir/invalid-menu.out"
    interactive_main_menu >"$invalid_menu_output" 2>&1
    [[ "$PROMPT_INDEX" == 2 ]] && grep -q '无效选择: invalid' "$invalid_menu_output" || \
        fail "invalid menu choice still requires an extra Enter"
    PATHLOCK_INTERACTIVE_MENU=0

    set +e
    ( PROMPTS=(duplicate 45.142.125.253 5201 45110 "" 25110 45111 40); PROMPT_INDEX=0; install_cn >/dev/null 2>&1 )
    duplicate_endpoint_rc=$?
    set -e
    (( duplicate_endpoint_rc != 0 )) || fail "duplicate Remote endpoint was accepted in shared GOST"
    set +e
    ( export MOCK_BUSY_PORT=45100; unset CN_FORCE_RESTART; require_cn_restart_window "$INSTALL_BASE/cn" gost-mtcp.service ) \
        >/dev/null 2>&1
    busy_guard_rc=$?
    set -e
    (( busy_guard_rc != 0 )) || fail "shared GOST restart guard ignored active business"
    ( export MOCK_BUSY_PORT=45100 CN_FORCE_RESTART=1; require_cn_restart_window "$INSTALL_BASE/cn" gost-mtcp.service ) \
        >/dev/null 2>&1 || fail "CN_FORCE_RESTART did not override active-business guard"
    ( export MOCK_BUSY_PORT=45100; unset CN_FORCE_RESTART; PATHLOCK_INTERACTIVE_MENU=1
      CN_RESTART_CONFIRMED_COUNT=""; PROMPTS=(y); PROMPT_INDEX=0
      require_cn_restart_window "$INSTALL_BASE/cn" gost-mtcp.service ) >/dev/null 2>&1 || \
        fail "management menu could not explicitly confirm an active-business restart"
    ( export MOCK_BUSY_PORT=45100; unset CN_FORCE_RESTART; PATHLOCK_INTERACTIVE_MENU=1
      CN_RESTART_CONFIRMED_COUNT=1; PROMPTS=(); PROMPT_INDEX=0
      require_cn_restart_window "$INSTALL_BASE/cn" gost-mtcp.service ) >/dev/null 2>&1 || \
        fail "Relay confirmation card caused a duplicate active-business prompt"

    CN_RELAY_YAML="$jp/cn.yaml"; CN_RELAY_CONFIG="$jp/mtcp.conf"; CN_RELAY_DIR="$jp"
    CN_ROUTE_ID="jp"; CN_RELAY_UNIT="gost-mtcp.service"
    CN_RELAY_WATCHDOG_UNIT="gost-mtcp-jp-watchdog.service"
    CN_RELAY_CHAIN_NAME="chain-mtcp-jp"; CN_RELAY_ANCHOR_SERVICE="mtcp-anchor-jp"
    CN_PRIMARY_PORT=45100; CN_ANCHOR_PORT=45101
    CN_ROOT="$INSTALL_BASE/cn"; CN_RUNTIME_YAML="$CN_ROOT/runtime.yaml"
    CN_COMPILE_SCRIPT="$CN_ROOT/compile-config.sh"

    set +e
    ( PROMPTS=(45108 "" 2351 tcp-entry); PROMPT_INDEX=0
      add_cn_relay >/dev/null 2>&1 )
    reserved_relay_name_rc=$?
    set -e
    (( reserved_relay_name_rc != 0 )) || fail "Relay manager accepted a migration-reserved service name"
    ! grep -q '45108' "$CN_RELAY_YAML" || fail "reserved Relay service name modified route YAML"

    # 之前的持久 restart 故障注入会让回滚的 best-effort restart 也失败；
    # 恢复基线，确保下面严格验证的是“活跃控制单元 stop 失败”。
    "$SYSTEMCTL_BIN" restart gost-mtcp.service \
        gost-mtcp-jp-watchdog.service gost-mtcp-us-watchdog.service
    strict_stop_candidate="$(mktemp "$jp/.relay-strict-stop-test.XXXXXX")"
    awk '
      /^- name:[[:space:]]*mtcp-anchor-jp[[:space:]]*$/ && !inserted {
        print "# standalone-relay: relay-45107"
        print "- name: relay-45107"
        print "  addr: :45107"
        print "  handler:"
        print "    type: tcp"
        print "    chain: chain-mtcp-jp"
        print "  listener:"
        print "    type: tcp"
        print "  forwarder:"
        print "    nodes:"
        print "    - name: backend-45107"
        print "      addr: 127.0.0.1:2350"
        print ""
        inserted=1
      }
      { print }
    ' "$CN_RELAY_YAML" > "$strict_stop_candidate"
    strict_stop_source_signature="$(cksum "$CN_RELAY_YAML")"
    set +e
    ( export MOCK_FAIL_STOP=1
      apply_cn_relay_yaml "$strict_stop_candidate" "strict stop integration test" \
        "$strict_stop_source_signature" >/dev/null 2>&1 )
    relay_stop_failure_rc=$?
    set -e
    (( relay_stop_failure_rc != 0 )) || fail "Relay update ignored active control units that failed to stop"
    ! grep -q '45107' "$CN_RELAY_YAML" || fail "failed Relay stop modified route YAML"
    ! grep -q '45107' "$CN_RUNTIME_YAML" || fail "failed Relay stop modified aggregate YAML"

    relay_candidate="$(mktemp "$jp/.relay-test.XXXXXX")"
    awk '
      /^- name:[[:space:]]*mtcp-anchor-jp[[:space:]]*$/ && !inserted {
        print "# standalone-relay: relay-45106"
        print "- name: relay-45106"
        print "  addr: :45106"
        print "  handler:"
        print "    type: tcp"
        print "    chain: chain-mtcp-jp"
        print "  listener:"
        print "    type: tcp"
        print "  forwarder:"
        print "    nodes:"
        print "    - name: backend-45106"
        print "      addr: 127.0.0.1:2349"
        print ""
        inserted=1
      }
      { print }
    ' "$CN_RELAY_YAML" > "$relay_candidate"
    relay_source_signature="$(cksum "$CN_RELAY_YAML")"
    apply_cn_relay_yaml "$relay_candidate" "relay integration test" "$relay_source_signature" >/dev/null
    grep -q '^BUSINESS_PORTS="45100 45104 45106"$' "$CN_RELAY_CONFIG" || \
        fail "Relay manager did not synchronize BUSINESS_PORTS"

    # 候选配置基于旧 fragment 生成后，另一个管理器若已经提交了更新，旧候选
    # 必须 fail closed，不能把并发更新静默覆盖掉。
    stale_relay_candidate="$(mktemp "$jp/.relay-stale-test.XXXXXX")"
    cp -p "$CN_RELAY_YAML" "$stale_relay_candidate"
    stale_relay_source_signature="$(cksum "$CN_RELAY_YAML")"
    printf '%s\n' '# concurrent-relay-update' >> "$CN_RELAY_YAML"
    set +e
    ( apply_cn_relay_yaml "$stale_relay_candidate" "stale Relay candidate" \
        "$stale_relay_source_signature" >/dev/null 2>&1 )
    stale_relay_rc=$?
    set -e
    (( stale_relay_rc != 0 )) || fail "stale Relay candidate overwrote a concurrent fragment update"
    grep -Fqx '# concurrent-relay-update' "$CN_RELAY_YAML" || \
        fail "stale Relay rejection lost the concurrent fragment update"
    sed -i.bak '/^# concurrent-relay-update$/d' "$CN_RELAY_YAML"
    rm -f "$CN_RELAY_YAML.bak"

    failed_candidate="$(mktemp "$jp/.relay-failure-test.XXXXXX")"
    awk '
      /^- name:[[:space:]]*mtcp-anchor-jp[[:space:]]*$/ && !inserted {
        print "# standalone-relay: relay-45105"
        print "- name: relay-45105"
        print "  addr: :45105"
        print "  handler:"
        print "    type: tcp"
        print "    chain: chain-mtcp-jp"
        print "  listener:"
        print "    type: tcp"
        print "  forwarder:"
        print "    nodes:"
        print "    - name: backend-45105"
        print "      addr: 127.0.0.1:2348"
        print ""
        inserted=1
      }
      { print }
    ' "$CN_RELAY_YAML" > "$failed_candidate"
    failed_source_signature="$(cksum "$CN_RELAY_YAML")"
    set +e
    ( export MOCK_FAIL_RESTART=1
      apply_cn_relay_yaml "$failed_candidate" "forced failure" "$failed_source_signature" >/dev/null 2>&1 )
    relay_failure_rc=$?
    set -e
    (( relay_failure_rc != 0 )) || fail "Relay failure simulation unexpectedly succeeded"
    ! grep -q '45105' "$CN_RELAY_YAML" || fail "Relay YAML rollback failed"
    ! grep -q '45105' "$CN_RUNTIME_YAML" || fail "aggregate YAML rollback failed"
    grep -q '^BUSINESS_PORTS="45100 45104 45106"$' "$CN_RELAY_CONFIG" || fail "Relay config rollback failed"

    set +e
    ( PROMPTS=(jp); PROMPT_INDEX=0; install_cn >/dev/null 2>&1 )
    reinstall_rc=$?
    set -e
    (( reinstall_rc != 0 )) || fail "active CN reinstall was not refused"

    cp -p "$us/mtcp.conf" "$integration_dir/us.mtcp.conf.unit-guard"
    sed -i.bak 's/^WATCHDOG_UNIT=.*/WATCHDOG_UNIT="sshd.service"/' "$us/mtcp.conf"
    rm -f "$us/mtcp.conf.bak"
    set +e
    ( PROMPTS=(y); PROMPT_INDEX=0; remove_cn_instance us >/dev/null 2>&1 )
    hostile_unit_guard_rc=$?
    set -e
    (( hostile_unit_guard_rc != 0 )) || fail "instance removal trusted a foreign systemd unit from config"
    mv -f "$integration_dir/us.mtcp.conf.unit-guard" "$us/mtcp.conf"

    mkdir -p "$INSTALL_BASE/cn/instances/orphan"
    printf '%s\n' 'ROUTE_ID="orphan"' > "$INSTALL_BASE/cn/instances/orphan/mtcp.conf"
    set +e
    ( PROMPTS=(y); PROMPT_INDEX=0; remove_cn_instance us >/dev/null 2>&1 )
    orphan_guard_rc=$?
    set -e
    (( orphan_guard_rc != 0 )) || fail "instance removal ignored an orphaned remaining config"
    [[ -d "$us" ]] || fail "orphan guard ran after deleting the requested instance"
    rm -rf "$INSTALL_BASE/cn/instances/orphan"

    PROMPTS=(n); PROMPT_INDEX=0
    remove_cn_instance us >/dev/null 2>&1 || fail "cancelled instance removal returned an error"
    [[ -d "$us" ]] && grep -Fq 'chain-mtcp-us' "$INSTALL_BASE/cn/runtime.yaml" || \
        fail "cancelled instance removal modified the us route"

    remove_once="$integration_dir/remove-instance-restart.failed-once"
    set +e
    ( export MOCK_FAIL_RESTART_ONCE_FILE="$remove_once"
      PROMPTS=(y); PROMPT_INDEX=0
      remove_cn_instance us >/dev/null 2>&1 )
    remove_rollback_rc=$?
    set -e
    (( remove_rollback_rc != 0 )) || fail "instance removal restart failure unexpectedly succeeded"
    [[ -d "$us" && -f "$SYSTEMD_DIR/gost-mtcp-us-anchor.service" && \
       -f "$SYSTEMD_DIR/gost-mtcp-us-watchdog.service" ]] || \
        fail "failed instance removal did not restore us files and units"
    grep -Fq 'chain-mtcp-us' "$INSTALL_BASE/cn/runtime.yaml" || \
        fail "failed instance removal did not restore aggregate runtime"
    [[ -f "$integration_dir/systemctl-state/gost-mtcp.service" && \
       -f "$integration_dir/systemctl-state/gost-mtcp-us-watchdog.service" ]] || \
        fail "failed instance removal did not restore running services"

    printf '%s\n' removal-log > "$us/state/remove-me.jsonl"
    touch "$PATHLOCK_RUNTIME_DIR/us.prewarm.lock" \
        "$PATHLOCK_RUNTIME_DIR/us.watchdog.lock"
    PROMPTS=(y); PROMPT_INDEX=0
    remove_cn_instance us >/dev/null
    [[ ! -e "$us" ]] || fail "instance removal retained the us directory or logs"
    ! grep -Fq 'chain-mtcp-us' "$INSTALL_BASE/cn/runtime.yaml" || \
        fail "instance removal retained us in aggregate runtime"
    grep -Fq 'chain-mtcp-jp' "$INSTALL_BASE/cn/runtime.yaml" || \
        fail "instance removal dropped the remaining jp route"
    [[ ! -e "$SYSTEMD_DIR/gost-mtcp-us-anchor.service" && \
       ! -e "$SYSTEMD_DIR/gost-mtcp-us-watchdog.service" && \
       ! -L "$SYSTEMD_DIR/multi-user.target.wants/gost-mtcp-us-watchdog.service" ]] || \
        fail "instance removal retained us systemd artifacts"
    [[ -f "$integration_dir/systemctl-state/gost-mtcp.service" && \
       -f "$integration_dir/systemctl-state/gost-mtcp-jp-watchdog.service" ]] || \
        fail "remaining route services did not restart after instance removal"
    [[ ! -e "$PATHLOCK_RUNTIME_DIR/us.prewarm.lock" && \
       ! -e "$PATHLOCK_RUNTIME_DIR/us.watchdog.lock" ]] || \
        fail "instance removal retained route runtime locks"

    source_tree="$integration_dir/source-tree"
    mkdir -p "$source_tree/cn"
    cp cn/mtcp.conf "$source_tree/cn/mtcp.conf"
    old_install_base="$INSTALL_BASE"
    INSTALL_BASE="$source_tree" PATHLOCK_SOURCE_TREE=1 \
        ensure_cn_port_available 12000 "$source_tree/cn/instances/default/mtcp.conf" gost-mtcp.service \
        gost-ecmp-pathlock.service || fail "source-tree canonical template was treated as a live route"
    INSTALL_BASE="$old_install_base"
    unset PATHLOCK_SOURCE_TREE

    source_cleanup="$integration_dir/source-cleanup"
    mkdir -p "$source_cleanup"
    cp install.sh standalone-install.sh "$source_cleanup/"
    cp -R scripts cn remote "$source_cleanup/"
    mkdir -p "$source_cleanup/cn/instances/demo/state"
    : > "$source_cleanup/cn/gost"
    : > "$source_cleanup/cn/runtime.yaml"
    : > "$source_cleanup/cn/instances/demo/state/events.jsonl"
    : > "$source_cleanup/remote/gost"
    : > "$source_cleanup/remote/mtcp.auth"
    printf '%s\n' '# modified installed script' > "$source_cleanup/cn/mtcp-lib.sh"
    printf '%s\n' '# modified remote config' > "$source_cleanup/remote/remote.yaml"
    INSTALL_BASE="$source_cleanup"
    remove_pathlock_installed_data || fail "source-tree uninstall cleanup failed"
    [[ ! -e "$source_cleanup/cn/instances" && ! -e "$source_cleanup/cn/gost" && \
       ! -e "$source_cleanup/remote/gost" && ! -e "$source_cleanup/remote/mtcp.auth" ]] || \
        fail "source-tree cleanup retained generated installation data"
    cmp -s cn/cn.yaml "$source_cleanup/cn/cn.yaml" && \
        cmp -s cn/mtcp-lib.sh "$source_cleanup/cn/mtcp-lib.sh" && \
        cmp -s remote/remote.yaml "$source_cleanup/remote/remote.yaml" || \
        fail "source-tree cleanup did not preserve and restore canonical sources"
    [[ -f "$source_cleanup/install.sh" && -f "$source_cleanup/standalone-install.sh" ]] || \
        fail "source-tree cleanup deleted installer sources"
    INSTALL_BASE="$old_install_base"

    touch "$PATHLOCK_RUNTIME_DIR/jp.prewarm.lock" \
        "$PATHLOCK_RUNTIME_DIR/jp.watchdog.lock" \
        "$PATHLOCK_RUNTIME_DIR/gost-mtcp.process-recovery.lock" \
        "$PATHLOCK_RUNTIME_DIR/gost-mtcp.process-recovery.state" \
        "$PATHLOCK_LEGACY_RUNTIME_DIR/gost-pathlock-jp-prewarm.lock" \
        "$PATHLOCK_LEGACY_RUNTIME_DIR/gost-pathlock-jp-watchdog.lock" \
        "$PATHLOCK_LEGACY_RUNTIME_DIR/gost-mtcp-process-recovery.lock" \
        "$PATHLOCK_LEGACY_RUNTIME_DIR/gost-mtcp-process-recovery.state" \
        "$PATHLOCK_LEGACY_RUNTIME_DIR/gost-mtcp-foreign-process-recovery.state"
    PROMPTS=(y); PROMPT_INDEX=0
    remove_cn_instance jp >/dev/null
    [[ ! -e "$jp" && ! -e "$INSTALL_BASE/cn/runtime.yaml" ]] || \
        fail "last-instance removal retained jp data or aggregate runtime"
    [[ ! -e "$SYSTEMD_DIR/gost-mtcp.service" && \
       ! -e "$SYSTEMD_DIR/gost-mtcp-jp-anchor.service" && \
       ! -e "$SYSTEMD_DIR/gost-mtcp-jp-watchdog.service" && \
       ! -L "$SYSTEMD_DIR/multi-user.target.wants/gost-mtcp.service" ]] || \
        fail "last-instance removal retained CN systemd units"
    [[ ! -e "$PATHLOCK_RUNTIME_DIR/jp.prewarm.lock" && \
       ! -e "$PATHLOCK_RUNTIME_DIR/gost-mtcp.process-recovery.state" && \
       ! -e "$PATHLOCK_LEGACY_RUNTIME_DIR/gost-pathlock-jp-watchdog.lock" && \
       ! -e "$PATHLOCK_LEGACY_RUNTIME_DIR/gost-mtcp-process-recovery.state" ]] || \
        fail "last-instance removal retained route or shared runtime state"
    [[ -e "$PATHLOCK_LEGACY_RUNTIME_DIR/gost-mtcp-foreign-process-recovery.state" ]] || \
        fail "runtime cleanup used a cross-project gost-mtcp wildcard"

    set +e
    ( export MOCK_FAIL_RESTART=1
      PROMPTS=(45199); PROMPT_INDEX=0
      install_remote >/dev/null 2>&1 )
    first_remote_failure_rc=$?
    set -e
    (( first_remote_failure_rc != 0 )) || fail "first Remote restart failure unexpectedly succeeded"
    [[ ! -e "$INSTALL_BASE/remote/gost" && ! -e "$INSTALL_BASE/remote/remote.yaml" && \
       ! -e "$INSTALL_BASE/remote/mtcp.auth" && \
       ! -e "$SYSTEMD_DIR/gost-mtcp-remote.service" && \
       ! -e "$SYSTEMD_DIR/gost-mtcp-remote-anchor.service" && \
       ! -L "$SYSTEMD_DIR/multi-user.target.wants/gost-mtcp-remote.service" && \
       ! -L "$SYSTEMD_DIR/multi-user.target.wants/gost-mtcp-remote-anchor.service" ]] || \
        fail "failed first Remote transaction leaked artifacts or enable links"

    PROMPTS=(45200); PROMPT_INDEX=0
    install_remote >/dev/null
    remote_auth="$INSTALL_BASE/remote/mtcp.auth"
    grep -q 'addr: :45200' "$INSTALL_BASE/remote/remote.yaml" || fail "Remote port render failed"
    grep -Fqx '    auther: mtcp-auth' "$INSTALL_BASE/remote/remote.yaml" || fail "Remote Relay auth is missing"
    grep -Fqx "    path: '$remote_auth'" "$INSTALL_BASE/remote/remote.yaml" || fail "Remote auth path was not rendered"
    grep -Fqx "mtcp $MTCP_AUTH_PASSWORD" "$remote_auth" || fail "Remote auth credentials are incorrect"
    [[ "$(file_mode "$remote_auth")" == 600 ]] || fail "Remote auth file permissions are not 0600"
    ! grep -Fq "$MTCP_AUTH_PASSWORD" "$INSTALL_BASE/remote/remote.yaml" || fail "Remote password leaked into YAML"
    grep -Fqx "ExecStart=$INSTALL_BASE/remote/gost -D -C $INSTALL_BASE/remote/remote.yaml" \
        "$SYSTEMD_DIR/gost-mtcp-remote.service" || fail "Remote unit render failed"
    grep -Fq "ExecStart=$integration_dir/bin/socat " "$SYSTEMD_DIR/gost-mtcp-remote-anchor.service" || \
        fail "Remote endpoint unit did not use detected socat"
    ui_init
    remote_dashboard="$(ui_main_dashboard)"
    [[ "$remote_dashboard" == *"Remote 服务 : ● RUNNING"* && \
       "$remote_dashboard" == *"Remote 监听 : :45200"* ]] || \
        fail "main dashboard does not show the installed Remote service and listener"
    set +e
    ( PROMPTS=(); PROMPT_INDEX=0; install_remote >/dev/null 2>&1 )
    remote_reinstall_rc=$?
    set -e
    (( remote_reinstall_rc != 0 )) || fail "active Remote reinstall was not refused"

    # 停止后的 Remote 重装必须仍是完整事务：候选校验或 systemd 提交失败时，
    # binary、配置、凭据、units 和原 enable 状态全部恢复，且旧服务保持停止。
    "$SYSTEMCTL_BIN" stop gost-mtcp-remote-anchor.service gost-mtcp-remote.service
    remote_snapshot="$integration_dir/remote-snapshot"
    mkdir -p "$remote_snapshot"
    cp -p "$INSTALL_BASE/remote/gost" "$remote_snapshot/gost"
    cp -p "$INSTALL_BASE/remote/remote.yaml" "$remote_snapshot/remote.yaml"
    cp -p "$remote_auth" "$remote_snapshot/mtcp.auth"
    cp -p "$SYSTEMD_DIR/gost-mtcp-remote.service" "$remote_snapshot/main.service"
    cp -p "$SYSTEMD_DIR/gost-mtcp-remote-anchor.service" "$remote_snapshot/anchor.service"
    assert_remote_snapshot() {
        cmp -s "$remote_snapshot/gost" "$INSTALL_BASE/remote/gost" &&
        cmp -s "$remote_snapshot/remote.yaml" "$INSTALL_BASE/remote/remote.yaml" &&
        cmp -s "$remote_snapshot/mtcp.auth" "$remote_auth" &&
        cmp -s "$remote_snapshot/main.service" "$SYSTEMD_DIR/gost-mtcp-remote.service" &&
        cmp -s "$remote_snapshot/anchor.service" "$SYSTEMD_DIR/gost-mtcp-remote-anchor.service"
    }

    set +e
    ( export MOCK_GOST_VERSION=invalid
      PROMPTS=(45201); PROMPT_INDEX=0
      install_remote >/dev/null 2>&1 )
    remote_validation_rc=$?
    set -e
    (( remote_validation_rc != 0 )) && assert_remote_snapshot || \
        fail "invalid Remote candidate modified formal artifacts"

    remote_reload_once="$integration_dir/remote-daemon-reload.failed-once"
    set +e
    ( export MOCK_GOST_VERSION=v2 MOCK_FAIL_DAEMON_RELOAD_ONCE_FILE="$remote_reload_once"
      PROMPTS=(45202); PROMPT_INDEX=0
      install_remote >/dev/null 2>&1 )
    remote_reload_rc=$?
    set -e
    (( remote_reload_rc != 0 )) && assert_remote_snapshot || \
        fail "Remote daemon-reload failure did not restore old artifacts"

    remote_restart_once="$integration_dir/remote-restart.failed-once"
    set +e
    ( export MOCK_GOST_VERSION=v2 MOCK_FAIL_RESTART_ONCE_FILE="$remote_restart_once" \
        MOCK_FAIL_DISABLE=1
      PROMPTS=(45203); PROMPT_INDEX=0
      install_remote >/dev/null 2>&1 )
    remote_restart_failure_rc=$?
    set -e
    (( remote_restart_failure_rc != 0 )) && assert_remote_snapshot || \
        fail "Remote restart failure did not restore old artifacts"
    [[ -L "$SYSTEMD_DIR/multi-user.target.wants/gost-mtcp-remote.service" &&
       -L "$SYSTEMD_DIR/multi-user.target.wants/gost-mtcp-remote-anchor.service" ]] || \
        fail "Remote rollback did not restore the original enable state"
    [[ ! -e "$integration_dir/systemctl-state/gost-mtcp-remote.service" &&
       ! -e "$integration_dir/systemctl-state/gost-mtcp-remote-anchor.service" ]] || \
        fail "Remote rollback restarted services that were stopped before the transaction"
    ! compgen -G "$INSTALL_BASE/remote/.remote-update.*" >/dev/null || \
        fail "successful Remote rollback leaked its transaction backup"
    "$SYSTEMCTL_BIN" restart gost-mtcp-remote.service gost-mtcp-remote-anchor.service

    PROMPTS=(cleanup 203.0.113.60 6760 45210 "" 25210 45211 40); PROMPT_INDEX=0
    install_cn >/dev/null
    [[ -e "$INSTALL_BASE/cn/instances/cleanup/cn.yaml" && \
       -e "$SYSTEMD_DIR/gost-mtcp-cleanup-watchdog.service" ]] || \
        fail "full-uninstall fixture did not install a CN route"

    mkdir -p "$INSTALL_BASE/cn/state"
    printf '%s\n' stale-log > "$INSTALL_BASE/cn/state/events.jsonl"
    stale_project_unit="gost-ecmp-pathlock-stale-watchdog.service"
    printf '%s\n' 'Description=GOST ECMP PathLock stale watchdog' > "$SYSTEMD_DIR/$stale_project_unit"
    "$SYSTEMCTL_BIN" enable "$stale_project_unit"
    "$SYSTEMCTL_BIN" restart "$stale_project_unit"
    external_mtcp_unit="gost-mtcp-external.service"
    printf '%s\n' 'Description=External MTCP Service' > "$SYSTEMD_DIR/$external_mtcp_unit"
    "$SYSTEMCTL_BIN" enable "$external_mtcp_unit"
    "$SYSTEMCTL_BIN" restart "$external_mtcp_unit"
    cat > "$INSTALL_BASE/cn/mtcp.conf" <<EOF
DST="192.0.2.99"
UNIT="$external_mtcp_unit"
ANCHOR_UNIT="external-anchor.service"
WATCHDOG_UNIT="external-watchdog.service"
EOF
    touch "$PATHLOCK_RUNTIME_DIR/stale.watchdog.lock"

    collect_project_systemd_units 2>/dev/null
    unit_content_signature_before="$(project_systemd_unit_signature)"
    printf '%s\n' '# concurrent same-name unit rewrite' >> "$SYSTEMD_DIR/$stale_project_unit"
    collect_project_systemd_units 2>/dev/null
    unit_content_signature_after="$(project_systemd_unit_signature)"
    [[ "$unit_content_signature_before" != "$unit_content_signature_after" ]] || \
        fail "uninstall signature ignored same-name unit content changes"
    printf '%s\n' 'Description=GOST ECMP PathLock stale watchdog' > "$SYSTEMD_DIR/$stale_project_unit"

    unset PATHLOCK_UNINSTALL_CONFIRM
    PROMPTS=("not confirmed"); PROMPT_INDEX=0
    uninstall_pathlock >/dev/null 2>&1 || fail "cancelled full uninstall returned an error"
    [[ -d "$INSTALL_BASE/remote" && -e "$SYSTEMD_DIR/gost-mtcp-remote.service" ]] || \
        fail "cancelled full uninstall modified installed components"

    set +e
    ( export MOCK_FAIL_STOP=1 PATHLOCK_UNINSTALL_CONFIRM=DELETE_ALL
      uninstall_pathlock >/dev/null 2>&1 )
    uninstall_stop_failure_rc=$?
    set -e
    (( uninstall_stop_failure_rc != 0 )) || fail "full uninstall ignored a service stop failure"
    [[ -d "$INSTALL_BASE/remote" && -e "$SYSTEMD_DIR/gost-mtcp-remote.service" ]] || \
        fail "failed service stop allowed full uninstall to delete data or units"

    set +e
    ( INSTALL_BASE=/opt PATHLOCK_UNINSTALL_CONFIRM=DELETE_ALL
      uninstall_pathlock >/dev/null 2>&1 )
    unsafe_uninstall_rc=$?
    set -e
    (( unsafe_uninstall_rc != 0 )) || fail "full uninstall accepted an unsafe INSTALL_BASE"
    [[ -e "$SYSTEMD_DIR/gost-mtcp-remote.service" ]] || \
        fail "unsafe INSTALL_BASE validation ran after systemd deletion"

    ln -s "$INSTALL_BASE" "$integration_dir/install-link"
    set +e
    ( INSTALL_BASE="$integration_dir/install-link" PATHLOCK_UNINSTALL_CONFIRM=DELETE_ALL
      uninstall_pathlock >/dev/null 2>&1 )
    symlink_uninstall_rc=$?
    set -e
    rm -f "$integration_dir/install-link"
    (( symlink_uninstall_rc != 0 )) || fail "full uninstall accepted a symlinked INSTALL_BASE"
    [[ -e "$SYSTEMD_DIR/gost-mtcp-remote.service" ]] || \
        fail "symlinked INSTALL_BASE validation ran after systemd deletion"

    ln -s "$SYSTEMD_DIR" "$integration_dir/systemd-link"
    set +e
    ( SYSTEMD_DIR="$integration_dir/systemd-link" PATHLOCK_UNINSTALL_CONFIRM=DELETE_ALL
      uninstall_pathlock >/dev/null 2>&1 )
    symlink_systemd_rc=$?
    set -e
    rm -f "$integration_dir/systemd-link"
    (( symlink_systemd_rc != 0 )) || fail "full uninstall accepted a symlinked SYSTEMD_DIR"
    [[ -e "$SYSTEMD_DIR/gost-mtcp-remote.service" ]] || \
        fail "symlinked SYSTEMD_DIR validation ran after systemd deletion"

    PATHLOCK_UNINSTALL_CONFIRM=DELETE_ALL uninstall_pathlock >/dev/null
    [[ ! -e "$INSTALL_BASE/cn" && ! -e "$INSTALL_BASE/remote" ]] || \
        fail "full uninstall retained configs, credentials, state, or logs"
    [[ ! -e "$SYSTEMD_DIR/gost-mtcp-remote.service" && \
       ! -e "$SYSTEMD_DIR/gost-mtcp-remote-anchor.service" && \
       ! -e "$SYSTEMD_DIR/$stale_project_unit" ]] || \
        fail "full uninstall retained PathLock systemd units"
    ! compgen -G "$SYSTEMD_DIR/gost-ecmp-pathlock*.service" >/dev/null || \
        fail "full uninstall retained legacy PathLock systemd units"
    [[ -e "$SYSTEMD_DIR/$external_mtcp_unit" && \
       -e "$integration_dir/systemctl-state/$external_mtcp_unit" ]] || \
        fail "full uninstall deleted an unrelated gost-mtcp-prefixed service"

    # 名字与 PathLock 当前/历史命名完全相同或相似，也不能替代 unit 内容中的
    # ownership 证据。用空安装目录再次执行真实 uninstall，确认它们仍在运行。
    external_collision_units=(
        gost-mtcp.service
        gost-mtcp-backup-watchdog.service
        gost-mtcp-backup-anchor.service
    )
    for unit in "${external_collision_units[@]}"; do
        cat > "$SYSTEMD_DIR/$unit" <<'EOF'
[Unit]
Description=External service
[Service]
ExecStart=/somewhere/not/pathlock
EOF
        "$SYSTEMCTL_BIN" enable "$unit"
        "$SYSTEMCTL_BIN" restart "$unit"
    done
    PATHLOCK_UNINSTALL_CONFIRM=DELETE_ALL uninstall_pathlock >/dev/null
    for unit in "${external_collision_units[@]}"; do
        [[ -e "$SYSTEMD_DIR/$unit" && -e "$integration_dir/systemctl-state/$unit" ]] || \
            fail "full uninstall claimed an external same-name unit: $unit"
    done
    collect_project_systemd_units
    (( ${#PROJECT_SYSTEMD_UNITS[@]} == 0 )) || \
        fail "full uninstall still discovers project-owned systemd units"
    [[ ! -e "$PATHLOCK_RUNTIME_DIR/stale.watchdog.lock" ]] || \
        fail "full uninstall retained runtime lock files"
)
pass "standalone CLI handles install, route removal, full uninstall, isolation, and rollback"

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mtcp-tests.XXXXXX")"
tmp_dir="$(cd -P "$tmp_dir" && pwd -P)"
trap 'rm -rf "$tmp_dir"' EXIT
cp cn/mtcp.conf "$tmp_dir/mtcp.conf"
sed -i.bak 's/^BUSINESS_PORTS=.*/BUSINESS_PORTS="12000,12002 12000"/' "$tmp_dir/mtcp.conf"
rm -f "$tmp_dir/mtcp.conf.bak"
sed -i.bak "s|/root/gost-ecmp-pathlock/cn/state|$tmp_dir/state|g" "$tmp_dir/mtcp.conf"
rm -f "$tmp_dir/mtcp.conf.bak"

# shellcheck disable=SC1091
source cn/mtcp-lib.sh
load_config "$tmp_dir/mtcp.conf"
[[ "$BUSINESS_PORTS" == "12000 12002" ]] || fail "BUSINESS_PORTS normalization failed: $BUSINESS_PORTS"

ss() {
    cat <<'SS'
ESTAB 0 0 127.0.0.1:12000 198.51.100.1:40000 users:(("gost",pid=77,fd=1))
ESTAB 0 0 127.0.0.1:12002 198.51.100.2:40001 users:(("gost",pid=77,fd=2))
ESTAB 0 0 127.0.0.1:12003 198.51.100.3:40002 users:(("gost",pid=77,fd=3))
ESTAB 0 0 127.0.0.1:12002 198.51.100.4:40003 users:(("gost",pid=88,fd=4))
SS
}
[[ "$(get_business_conn_count 77)" == 2 ]] || fail "multi-port connection count is incorrect"
pass "BUSINESS_PORTS counts all configured ports for only the target GOST PID"

cp "$tmp_dir/mtcp.conf" "$tmp_dir/legacy.conf"
sed -i.bak '/^BUSINESS_PORTS=/d' "$tmp_dir/legacy.conf"
rm -f "$tmp_dir/legacy.conf.bak"
load_config "$tmp_dir/legacy.conf"
[[ "$BUSINESS_PORTS" == "$BUSINESS_PORT" ]] || fail "legacy BUSINESS_PORT fallback failed"
pass "legacy single-port configs remain compatible"

grep -q 'PREWARM_ABORT_BUSY.*before_outer_kill\|abort_degraded_retry_if_busy "before_outer_kill"' cn/mtcp-prewarm.sh || \
    fail "prewarm final busy barrier missing"
grep -q 'DATA_PROBE_BREAKER_REARMED' cn/mtcp-watchdog.sh || fail "data probe half-open breaker missing"
grep -q 'PROCESS_RECOVERY_ATTEMPT' cn/mtcp-watchdog.sh || fail "process recovery missing"
grep -q 'RESET_ROUTE_OUTER' cn/mtcp-watchdog.sh || fail "route-local outer reset missing"
route_reset_body="$(awk '/^reset_route_rate_limited\(\)/ { emit=1 } /^run_select\(\)/ { exit } emit { print }' cn/mtcp-watchdog.sh)"
[[ "$route_reset_body" == *"kill_route_outers"* ]] || fail "route reset does not kill only route outers"
[[ "$route_reset_body" != *'systemctl restart "$UNIT"'* ]] || fail "route fault still restarts shared GOST"
pass "destructive paths isolate route outers and retain recovery breakers"

awk '/^process_pid_changed\(\)/ { emit=1 } /^adopt_current\(\)/ { exit } emit { print }' \
    cn/mtcp-watchdog.sh > "$tmp_dir/process-health.sh"
(
    # shellcheck disable=SC1090
    source "$tmp_dir/process-health.sh"
    LAST_PID=100
    PROCESS_HEALTHY_SINCE=1000
    process_pid_changed 200 1032 || fail "a new GOST PID was not detected"
    [[ "$PROCESS_HEALTHY_SINCE" == 1032 ]] || \
        fail "a new GOST PID inherited the old PID health window"
    (( 1060 - PROCESS_HEALTHY_SINCE < 60 )) || \
        fail "a 28-second-old replacement PID was treated as healthy for 60 seconds"
    LAST_PID=200
    if process_pid_changed 200 1060; then fail "an unchanged GOST PID was reported as changed"; fi
    [[ "$PROCESS_HEALTHY_SINCE" == 1032 ]] || fail "same-PID polling reset the health window"
)
awk '
    /^while true; do/ { active=1 }
    active && /if process_pid_changed / { changed=NR }
    active && /close_process_breaker / { closed=NR }
    active && /count="\$\(get_gost_outer_count/ { exit }
    END { exit !(changed > 0 && closed > changed) }
' cn/mtcp-watchdog.sh || fail "PROCESS breaker can close before PID-change handling"
grep -Fq 'close_process_breaker "$now" "$pid"' cn/mtcp-watchdog.sh || \
    fail "PROCESS breaker close does not carry the stable PID into the lock"
grep -Fq '[[ "$current_pid" != "$expected_pid" ]]' cn/mtcp-watchdog.sh || \
    fail "PROCESS breaker close does not recheck the expected PID under lock"
pass "PROCESS breaker health requires one stable MainPID for the full interval"

awk '/^prune_epoch_list\(\)/ { emit=1 } /^set_state\(\)/ { exit } emit { print }' \
    cn/mtcp-watchdog.sh > "$tmp_dir/breakers.sh"
(
    # shellcheck disable=SC1090
    source "$tmp_dir/breakers.sh"
    log_event() { :; }
    STATE=FAULT; LAST_PID=77; LAST_SPORT=23456
    DATA_PROBE_RESTART_WINDOW_SEC=600; DATA_PROBE_RESTART_MAX=3; DATA_PROBE_BREAKER_OPEN_SEC=600
    DATA_PROBE_RESTART_EPOCHS=""; DATA_PROBE_BREAKER_STATE=closed
    DATA_PROBE_BREAKER_UNTIL=0; DATA_PROBE_BREAKER_LOGGED=0
    allow_data_probe_restart 100
    allow_data_probe_restart 160
    allow_data_probe_restart 220
    [[ "$DATA_PROBE_BREAKER_STATE" == open && "$DATA_PROBE_BREAKER_UNTIL" == 820 ]] || \
        fail "data breaker did not arm after three attempts"
    if allow_data_probe_restart 300; then fail "open data breaker allowed a restart"; fi
    allow_data_probe_restart 821
    [[ "$DATA_PROBE_BREAKER_STATE" == open && "$DATA_PROBE_BREAKER_UNTIL" == 1421 ]] || \
        fail "data breaker half-open attempt was not rearmed"
    close_data_probe_breaker
    [[ "$DATA_PROBE_BREAKER_STATE" == closed && -z "$DATA_PROBE_RESTART_EPOCHS" ]] || \
        fail "healthy data probe did not close breaker"

    PROCESS_RECOVERY_INTERVAL_SEC=60; PROCESS_RECOVERY_WINDOW_SEC=600
    PROCESS_RECOVERY_MAX=3; PROCESS_BREAKER_OPEN_SEC=600
    PROCESS_RECOVERY_EPOCHS=""; PROCESS_BREAKER_STATE=closed
    PROCESS_BREAKER_UNTIL=0; PROCESS_BREAKER_LOGGED=0; LAST_PROCESS_RECOVERY=0
    allow_process_recovery 100
    if allow_process_recovery 120; then fail "process recovery interval was ignored"; fi
    allow_process_recovery 160
    allow_process_recovery 220
    [[ "$PROCESS_BREAKER_STATE" == open && "$PROCESS_BREAKER_UNTIL" == 820 ]] || \
        fail "process breaker did not arm after three attempts"
)
pass "data-plane and process breakers enforce window, open, and half-open behavior"

(
    # 模拟三个独立 Watchdog：每次清空进程内变量，但共用同一 /run 替代目录。
    # 第二个 Watchdog 必须读到第一个已经落盘的 interval/window budget。
    # shellcheck disable=SC1090
    source "$tmp_dir/breakers.sh"
    log_event() { :; }
    service_is_active() { return 1; }
    get_main_pid() { echo 0; }
    if ! command -v flock >/dev/null 2>&1; then
        flock() { return 0; }
    fi
    systemctl() {
        if [[ "${1:-}" == restart ]]; then
            printf '%s\n' "${2:-missing}" >> "$MTCP_PROCESS_RUNTIME_DIR/restarts.log"
        fi
        return 0
    }

    MTCP_PROCESS_RUNTIME_DIR="$tmp_dir/shared-process"
    mkdir -p "$MTCP_PROCESS_RUNTIME_DIR"
    BOOT_ID="test-boot-id"
    UNIT="gost-mtcp.service"
    STATE=DOWN; LAST_PID=0; LAST_SPORT=""
    PROCESS_RECOVERY_INTERVAL_SEC=60; PROCESS_RECOVERY_WINDOW_SEC=600
    PROCESS_RECOVERY_MAX=3; PROCESS_BREAKER_OPEN_SEC=600
    init_process_recovery_paths
    [[ "$PROCESS_RECOVERY_LOCK_FILE" == "$MTCP_PROCESS_RUNTIME_DIR/gost-mtcp.process-recovery.lock" && \
       "$PROCESS_RECOVERY_STATE_FILE" == "$MTCP_PROCESS_RUNTIME_DIR/gost-mtcp.process-recovery.state" ]] || \
        fail "PROCESS recovery escaped the dedicated runtime namespace"

    reset_process_recovery_state
    recover_process_rate_limited 100
    reset_process_recovery_state
    if recover_process_rate_limited 120; then
        fail "a second watchdog bypassed the shared process recovery interval"
    fi
    reset_process_recovery_state
    recover_process_rate_limited 160
    reset_process_recovery_state
    recover_process_rate_limited 220
    reset_process_recovery_state
    if recover_process_rate_limited 280; then
        fail "a later watchdog bypassed the shared open process breaker"
    fi

    [[ "$(wc -l < "$MTCP_PROCESS_RUNTIME_DIR/restarts.log" | tr -d ' ')" == 3 ]] || \
        fail "shared process budget did not cap restart attempts globally"
    grep -Fqx "PROCESS_RECOVERY_EPOCHS='100 160 220'" "$PROCESS_RECOVERY_STATE_FILE" || \
        fail "shared process recovery epochs were not persisted"
    grep -Fqx "PROCESS_BREAKER_STATE='open'" "$PROCESS_RECOVERY_STATE_FILE" || \
        fail "shared process breaker did not persist its open state"
    [[ "$(file_mode "$PROCESS_RECOVERY_STATE_FILE")" == 600 ]] || \
        fail "shared process recovery state permissions are not 0600"
)
pass "all route watchdogs share one locked PROCESS recovery budget"

! grep -Fq 'while ((p=index(s,a))>0) s=' standalone-install.sh || \
    fail "watchdog unit literal replacement can rescan its own replacement forever"
awk '
    /^[[:space:]]*function repl\(text, old, replacement/ { emit=1 }
    emit { print }
    emit && /^        }$/ { exit }
' standalone-install.sh > "$tmp_dir/watchdog-unit-repl.awk"
cat >> "$tmp_dir/watchdog-unit-repl.awk" <<'AWK'
BEGIN {
    old="/root/gost-ecmp-pathlock/cn"
    replacement="/tmp/prefix" old
    input="Environment=\"MTCP_LIB=" old "/mtcp-lib.sh\""
    expected="Environment=\"MTCP_LIB=" replacement "/mtcp-lib.sh\""
    if (repl(input, old, replacement) != expected) exit 1
}
AWK
awk -f "$tmp_dir/watchdog-unit-repl.awk" /dev/null || \
    fail "watchdog unit literal replacement mishandled an INSTALL_BASE containing the canonical path"
pass "watchdog unit rendering consumes only the original template text"

git diff --check
pass "patch has no whitespace errors"

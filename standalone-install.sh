#!/usr/bin/env bash
set -euo pipefail

# gost-ecmp-pathlock 自包含安装器
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/.../standalone-install.sh | bash -s remote
#   curl -fsSL https://raw.githubusercontent.com/.../standalone-install.sh | bash -s cn
#
# 或下载后直接进入菜单（也保留 cn/remote/relay 命令用于自动化）：
#   wget https://raw.githubusercontent.com/.../standalone-install.sh
#   bash standalone-install.sh

VERSION="2.2.2"
INSTALL_BASE="${INSTALL_BASE:-/opt/gost-mtcp}"
GOST_VERSION="${GOST_VERSION:-v3.2.6}"
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
PATHLOCK_RUNTIME_DIR="${PATHLOCK_RUNTIME_DIR:-/run/gost-ecmp-pathlock}"
PATHLOCK_MANAGER_LOCK_OPEN=0
EMBEDDED_SOURCE=""
PROMPT_FD=0
PROMPT_FD_READY=0
PATHLOCK_INTERACTIVE_MENU=0
MTCP_AUTH_USERNAME="mtcp"
CN_RESTART_CONFIRMED_COUNT=""
UI_COLOR_ENABLED=0
UI_RESET=""; UI_BLUE=""; UI_GREEN=""; UI_YELLOW=""; UI_RED=""; UI_DIM=""; UI_BOLD=""
declare -a CLEANUP_PATHS=()
declare -a DISCOVERED_CN_YAMLS=()
declare -a DISCOVERED_CN_CONFIGS=()
declare -a PROJECT_SYSTEMD_UNITS=()

cleanup() {
    local status=$? path
    for path in "${CLEANUP_PATHS[@]:-}"; do
        if [[ -n "$path" && ( -f "$path" || -d "$path" ) ]]; then
            rm -rf -- "$path" || true
        fi
    done
    return "$status"
}

trap cleanup EXIT

ui_init() {
    UI_COLOR_ENABLED=0
    UI_RESET=""; UI_BLUE=""; UI_GREEN=""; UI_YELLOW=""; UI_RED=""; UI_DIM=""; UI_BOLD=""
    if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
        UI_COLOR_ENABLED=1
        UI_RESET=$'\033[0m'; UI_BLUE=$'\033[34m'; UI_GREEN=$'\033[32m'
        UI_YELLOW=$'\033[33m'; UI_RED=$'\033[31m'; UI_DIM=$'\033[2m'; UI_BOLD=$'\033[1m'
    fi
}

ui_clear() {
    (( PATHLOCK_INTERACTIVE_MENU == 1 )) && [[ -t 1 ]] && printf '\033[2J\033[H'
    return 0
}

ui_box_row() {
    local text="$1" width=54 padding left right
    padding=$((width - ${#text}))
    if (( padding < 0 )); then padding=0; fi
    left=$((padding / 2)); right=$((padding - left))
    printf '%b║%*s%s%*s║%b\n' "$UI_BLUE" "$left" "" "$text" "$right" "" "$UI_RESET"
}

ui_header() {
    local subtitle="${1:-}"
    printf '%b\n' "${UI_BLUE}╔══════════════════════════════════════════════════════╗${UI_RESET}"
    ui_box_row "GOST ECMP PathLock Manager"
    ui_box_row "v${VERSION}"
    printf '%b\n' "${UI_BLUE}╚══════════════════════════════════════════════════════╝${UI_RESET}"
    [[ -z "$subtitle" ]] || printf '\n%b%s%b\n' "${UI_BOLD}${UI_BLUE}" "$subtitle" "$UI_RESET"
}

ui_success() { printf '%b✓%b %s\n' "$UI_GREEN" "$UI_RESET" "$*"; }
ui_warn() { printf '%b⚠%b %s\n' "$UI_YELLOW" "$UI_RESET" "$*" >&2; }
ui_error() { printf '%b✗%b %s\n' "$UI_RED" "$UI_RESET" "$*" >&2; }

ui_status_badge() {
    local value="${1:-UNKNOWN}" state color
    state="${value%%/*}"
    case "$state" in
        FAST|RUNNING|UP|OK|yes) color="$UI_GREEN" ;;
        DEGRADED|WARN|WARNING|STARTING) color="$UI_YELLOW" ;;
        DOWN|FAULT|STOPPED|FAILED|FAIL|no) color="$UI_RED" ;;
        *) color="$UI_DIM" ;;
    esac
    printf '%b● %s%b' "$color" "$value" "$UI_RESET"
}

ui_pause() {
    local target="${1:-主菜单}" dummy
    (( PATHLOCK_INTERACTIVE_MENU == 1 )) || return 0
    echo
    prompt_read dummy "按 Enter 返回${target}..." || true
}

ui_menu_choice() {
    local output_var="$1" prompt="${2:-请选择 › }" value
    prompt_read value "$prompt" || return 1
    printf -v "$output_var" '%s' "$value"
}

ui_prompt_port() {
    local output_var="$1" prompt="$2" default_value="${3:-}" value
    while :; do
        prompt_read value "$prompt" || return 1
        value="${value:-$default_value}"
        if valid_port "$value"; then
            printf -v "$output_var" '%s' "$((10#$value))"
            return 0
        fi
        if (( PATHLOCK_INTERACTIVE_MENU == 0 )); then
            die "端口必须是 1-65535 之间的数字"
        fi
        ui_error "端口必须是 1-65535 之间的数字"
    done
}

ui_confirm() {
    local answer prompt="${1:-请选择 [y/N] › }"
    while :; do
        ui_menu_choice answer "$prompt" || return 1
        case "$answer" in
            y|Y|yes|YES) return 0 ;;
            n|N|no|NO|"") return 1 ;;
            *)
                (( PATHLOCK_INTERACTIVE_MENU == 1 )) || return 1
                ui_error "请输入 Y 或 N"
                ;;
        esac
    done
}

ui_run_action() {
    local label="$1" return_target="$2" rc had_errexit=0
    shift 2

    # 不能把 action 子 shell 直接放进 `if (...)`：Bash 会在条件上下文中关闭
    # errexit，令安装函数里依赖 `set -e` 的失败被忽略并继续提交。
    [[ $- == *e* ]] && had_errexit=1
    set +e
    (
        set -e
        # 子操作隔离执行，但重新挂载 cleanup；只清理本次操作创建的临时文件，
        # 不触碰父菜单为 piped execution 保存的 EMBEDDED_SOURCE。
        CLEANUP_PATHS=()
        trap cleanup EXIT
        "$@"
    )
    rc=$?
    (( had_errexit == 0 )) || set -e

    if (( rc != 0 )); then
        ui_error "$label 失败（exit ${rc}）"
    fi
    ui_pause "$return_target"
    return 0
}

ui_relay_change_card() {
    local action="$1" route="$2" listen="$3" backend="$4" chain="$5" active="$6"
    echo
    printf '%b────────────────── 即将%s端口转发 ──────────────────%b\n' "$UI_BLUE" "$action" "$UI_RESET"
    printf '\n  线路         %s\n' "$route"
    printf '  CN 监听      %s\n' "$listen"
    printf '  Remote 后端  %s\n' "$backend"
    printf '  Chain        %s\n\n' "$chain"
    ui_warn "此操作会重启共享 GOST"
    if (( active > 0 )); then
        ui_warn "当前存在 $active 条活跃业务连接"
        ui_warn "重启将同时中断所有线路现有连接"
    else
        printf '  %b当前活跃连接：0%b\n' "$UI_DIM" "$UI_RESET"
    fi
    printf '%b──────────────────────────────────────────────────────%b\n\n' "$UI_BLUE" "$UI_RESET"
}

ui_instance_remove_card() {
    local route="$1" remote="$2" ports="$3" instance_dir="$4" remaining="$5" active="$6"
    echo
    printf '%b────────────────── 即将删除 CN 实例 ──────────────────%b\n' "$UI_RED" "$UI_RESET"
    printf '\n  线路实例     %s\n' "$route"
    printf '  Remote       %s\n' "$remote"
    printf '  业务端口     %s\n' "$ports"
    printf '  实例目录     %s\n' "$instance_dir"
    printf '  删除后剩余   %s 条线路\n\n' "$remaining"
    ui_warn "实例配置、鉴权文件、状态与 JSONL 日志将被永久删除"
    if (( remaining > 0 )); then
        ui_warn "共享 GOST 会重启，所有线路现有连接都将中断并重建"
    else
        ui_warn "这是最后一条线路；共享 CN 服务也会被停止并删除"
    fi
    (( active == 0 )) || ui_warn "当前共有 $active 条活跃业务连接"
    printf '%b──────────────────────────────────────────────────────%b\n\n' "$UI_RED" "$UI_RESET"
}

ui_uninstall_card() {
    local base="$1" unit_count="$2" source_tree="$3"
    echo
    printf '%b────────────────────── 完全卸载 ──────────────────────%b\n' "$UI_RED" "$UI_RESET"
    printf '\n  安装目录     %s\n' "$base"
    printf '  systemd 单元 %s 个\n' "$unit_count"
    if (( source_tree == 1 )); then
        printf '  源码目录     保留仓库，只清除安装产物并恢复模板\n'
    else
        printf '  运行数据     删除 CN / Remote 全部安装目录\n'
    fi
    echo
    ui_warn "所有 PathLock 服务、配置、凭据、状态与 JSONL 日志都会被删除"
    ui_warn "此操作不可回滚；管理脚本及 systemd 的共享 journal 历史不会删除"
    printf '%b──────────────────────────────────────────────────────%b\n\n' "$UI_RED" "$UI_RESET"
}

ui_json_value() {
    local line="$1" key="$2" value
    value="$(printf '%s\n' "$line" | sed -n "s/.*\"${key}\":\"\([^\"]*\)\".*/\1/p")"
    if [[ -z "$value" ]]; then
        value="$(printf '%s\n' "$line" | sed -n "s/.*\"${key}\":\([-0-9.][0-9.]*\).*/\1/p")"
    fi
    printf '%s\n' "$value"
}

ui_follow_log() {
    local event_file="$1" tail_pid=""
    # tail 在独立进程中运行；菜单临时接管 SIGINT，只终止 tail，不退出 manager。
    trap 'if [[ -n "${tail_pid:-}" ]]; then kill "$tail_pid" >/dev/null 2>&1 || true; fi' INT
    tail -n 20 -f "$event_file" &
    tail_pid=$!
    wait "$tail_pid" 2>/dev/null || true
    trap - INT
    ui_success "已停止实时跟踪"
}

ui_route_status_panel() {
    local status_file="$1" line state reason minrtt rtt outer remote data business
    if [[ ! -r "$status_file" ]]; then
        ui_warn "状态尚未生成: $status_file"
        return 0
    fi
    line="$(tail -n 1 "$status_file" 2>/dev/null || true)"
    state="$(ui_json_value "$line" state)"; state="${state:-UNKNOWN}"
    reason="$(ui_json_value "$line" reason)"; reason="${reason:--}"
    minrtt="$(ui_json_value "$line" minrtt_ms)"; minrtt="${minrtt:--}"
    rtt="$(ui_json_value "$line" rtt_ms)"; rtt="${rtt:--}"
    outer="$(ui_json_value "$line" outer_count)"; outer="${outer:-0}"
    remote="$(ui_json_value "$line" remote_reachable)"; remote="${remote:-unknown}"
    data="$(ui_json_value "$line" data_plane_reachable)"; data="${data:-unknown}"
    business="$(ui_json_value "$line" business_connections)"; business="${business:-0}"
    case "$remote" in yes) remote="UP" ;; no) remote="DOWN" ;; *) remote="UNKNOWN" ;; esac
    case "$data" in yes) data="OK" ;; no) data="FAIL" ;; *) data="UNKNOWN" ;; esac

    printf '  %s\n' "$(ui_status_badge "$state")"
    printf '  %-10s %s\n' "Reason" "$reason"
    printf '  %-10s %s ms\n' "minRTT" "$minrtt"
    printf '  %-10s %s ms\n' "RTT" "$rtt"
    printf '  %-10s %s\n' "Outer" "$outer"
    printf '  %-10s %s\n' "Remote" "$(ui_status_badge "$remote")"
    printf '  %-10s %s\n' "DataPlane" "$(ui_status_badge "$data")"
    printf '  %-10s %s\n' "Business" "$business"
}

ui_main_dashboard() {
    local route_count main_unit="gost-mtcp.service" service_state="STOPPED"
    local route_remote="未配置" config dst port
    local remote_yaml="$INSTALL_BASE/remote/remote.yaml" remote_addr="未配置"
    local remote_unit="gost-mtcp-remote.service" remote_state="NOT INSTALLED"
    discover_cn_routes
    route_count="${#DISCOVERED_CN_CONFIGS[@]}"
    if (( route_count > 0 )); then
        config="${DISCOVERED_CN_CONFIGS[0]}"
        main_unit="$(read_config_value "$config" UNIT 2>/dev/null || true)"
        main_unit="${main_unit:-gost-mtcp.service}"
        dst="$(read_config_value "$config" DST 2>/dev/null || true)"
        port="$(read_config_value "$config" PORT 2>/dev/null || true)"
        route_remote="${dst:-未知}:${port:-未知}"
        (( route_count > 1 )) && route_remote+=" (+$((route_count - 1)))"
    fi
    "$SYSTEMCTL_BIN" is-active --quiet "$main_unit" >/dev/null 2>&1 && service_state="RUNNING"

    if [[ -r "$remote_yaml" ]]; then
        remote_addr="$(awk '
            /^- name:[[:space:]]*mtcp-server[[:space:]]*$/ { found=1; next }
            found && /^  addr:[[:space:]]*/ { sub(/^  addr:[[:space:]]*/, ""); print; exit }
            found && /^- name:[[:space:]]*/ { exit }
        ' "$remote_yaml")"
        remote_addr="${remote_addr:-未知}"
        remote_state="STOPPED"
        "$SYSTEMCTL_BIN" is-active --quiet "$remote_unit" >/dev/null 2>&1 && remote_state="RUNNING"
    fi

    ui_header
    echo
    printf '  CN 共享服务 : %s\n' "$(ui_status_badge "$service_state")"
    printf '  已配置线路  : %s\n' "$route_count"
    printf '  线路 Remote : %b%s%b\n' "$UI_DIM" "$route_remote" "$UI_RESET"
    echo
    printf '  Remote 服务 : %s\n' "$(ui_status_badge "$remote_state")"
    printf '  Remote 监听 : %b%s%b\n' "$UI_DIM" "$remote_addr" "$UI_RESET"
    printf '\n  %b────────────────────────────────────────────────────%b\n' "$UI_DIM" "$UI_RESET"
}

show_banner() {
    ui_init
    ui_header "基于单 GOST 进程 + 多 MTCP 线路的 ECMP 路径管理"
}

show_usage() {
    cat <<'USAGE'
用法：
  bash standalone-install.sh             打开统一管理菜单
  bash standalone-install.sh list        列出已有配置与端口路径
  bash standalone-install.sh logs        选择线路并查看 JSONL 日志
  bash standalone-install.sh cn          直接安装 CN 端
  bash standalone-install.sh remote      直接安装 Remote 端
  bash standalone-install.sh relay       选择线路并管理端口转发
  bash standalone-install.sh relay list  选择线路并列出端口转发
  bash standalone-install.sh relay add   选择线路并增加端口转发
  bash standalone-install.sh relay remove [服务名]
                                        选择线路并删除端口转发
  bash standalone-install.sh instance remove [线路别名]
                                        删除一个 CN 线路实例
  bash standalone-install.sh uninstall  完全卸载全部 PathLock 运行组件
  bash standalone-install.sh --help      查看帮助

环境变量：
  INSTALL_BASE               安装目录（默认 /opt/gost-mtcp）
  GOST_VERSION               GOST 版本（默认 v3.2.6）
  GITHUB_PROXY_PREFIX        GitHub 镜像前缀（CN 默认 https://ghfast.top/）
  CN_YAML_PATH               自动化 Relay 管理使用的 cn.yaml 路径（可选）
  CN_MTCP_CONFIG_PATH        自动化 Relay 管理使用的 mtcp.conf 路径（可选）
  CN_INSTANCE                自动化 Relay 管理使用的线路别名（可选；菜单无需设置）
  MTCP_AUTH_PASSWORD         自动化安装用鉴权密码（两端相同，交互安装建议不设置）
  CN_FORCE_RESTART=1         有活跃业务时仍允许重启共享 GOST
  PATHLOCK_UNINSTALL_CONFIRM=DELETE_ALL
                             自动化确认完全卸载（危险；交互时请勿设置）
  NO_COLOR=1                 禁用交互菜单 ANSI 颜色（非 TTY 会自动禁用）

示例：
  # 日常管理：安装、配置清单、端口转发和日志都从这里进入
  bash standalone-install.sh

  # 自动化仍可直接指定角色
  bash standalone-install.sh remote
  bash standalone-install.sh cn

  # CN 端强制直连 GitHub
  GITHUB_PROXY_PREFIX= bash standalone-install.sh cn

  # 单命令安装（交互输入会直接读取当前终端）
  curl -fsSL https://example.com/install.sh | bash -s cn
USAGE
}

die() {
    echo "错误: $*" >&2
    exit 1
}

check_root() {
    [[ "$EUID" -eq 0 ]] || die "需要 root 权限，请使用 sudo 或 su"
}

check_command() {
    local cmd="$1"
    command -v "$cmd" &>/dev/null || die "缺少命令: $cmd"
}

ensure_pathlock_runtime_dir() {
    local canonical
    [[ "$PATHLOCK_RUNTIME_DIR" == /* && "$PATHLOCK_RUNTIME_DIR" != / &&
       ! -L "$PATHLOCK_RUNTIME_DIR" ]] || {
        echo "拒绝使用不安全或为符号链接的 PathLock 运行目录: $PATHLOCK_RUNTIME_DIR" >&2
        return 1
    }
    if [[ -e "$PATHLOCK_RUNTIME_DIR" && ! -d "$PATHLOCK_RUNTIME_DIR" ]]; then
        echo "PathLock 运行目录存在但不是目录: $PATHLOCK_RUNTIME_DIR" >&2
        return 1
    fi
    if [[ ! -d "$PATHLOCK_RUNTIME_DIR" ]]; then
        (umask 077; mkdir -p -- "$PATHLOCK_RUNTIME_DIR") || return 1
    fi
    canonical="$(cd -P -- "$PATHLOCK_RUNTIME_DIR" 2>/dev/null && pwd -P)" || return 1
    [[ "$canonical" == "$PATHLOCK_RUNTIME_DIR" ]] || {
        echo "PathLock 运行目录必须使用规范绝对路径: $canonical" >&2
        return 1
    }
    case "$canonical" in
        /bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
            echo "拒绝使用过于宽泛的 PathLock 运行目录: $canonical" >&2
            return 1
            ;;
    esac
}

# 固定锁顺序与 FD：7=lifecycle、8=CN config；交互终端保留 FD 9。
acquire_pathlock_manager_lock() {
    local lock_file
    (( PATHLOCK_MANAGER_LOCK_OPEN == 0 )) || die "内部错误：lifecycle lock 被重复获取"
    ensure_pathlock_runtime_dir || die "无法准备 PathLock lifecycle lock 目录"
    lock_file="$PATHLOCK_RUNTIME_DIR/manager.lock"
    [[ ! -L "$lock_file" && ( ! -e "$lock_file" || -f "$lock_file" ) ]] || \
        die "拒绝使用不安全的 lifecycle lock: $lock_file"
    (umask 077; : >> "$lock_file") || die "无法创建 lifecycle lock: $lock_file"
    chmod 0600 "$lock_file" || die "无法收紧 lifecycle lock 权限: $lock_file"
    exec 7>>"$lock_file" || die "无法打开 lifecycle lock: $lock_file"
    if ! PATHLOCK_LOCK_KIND=manager flock -n 7; then
        exec 7>&-
        die "另一项 PathLock 安装、配置或卸载操作正在进行"
    fi
    PATHLOCK_MANAGER_LOCK_OPEN=1
}

release_pathlock_manager_lock() {
    (( PATHLOCK_MANAGER_LOCK_OPEN == 1 )) || return 0
    exec 7>&-
    PATHLOCK_MANAGER_LOCK_OPEN=0
}

# bash 从管道或 process substitution 读取脚本时，$0 不是可重复读取的普通文件。
# main 执行时脚本尾部尚未被解释，先保存嵌入区，供后续多次提取。
prepare_embedded_source() {
    local script_source="${BASH_SOURCE[0]:-}" tmp_source

    if [[ -n "$script_source" && -f "$script_source" ]]; then
        EMBEDDED_SOURCE="$script_source"
        return
    fi

    tmp_source="$(mktemp)"
    CLEANUP_PATHS+=("$tmp_source")
    if [[ -n "$script_source" && -r "$script_source" ]]; then
        sed -n '/^### BEGIN /,$p' "$script_source" > "$tmp_source"
    else
        sed -n '/^### BEGIN /,$p' <&0 > "$tmp_source"
    fi
    grep -q '^### BEGIN REMOTE_YAML ###$' "$tmp_source" || \
        die "无法读取安装器内嵌文件；请重新下载安装脚本"
    EMBEDDED_SOURCE="$tmp_source"
}

prepare_prompt_input() {
    (( PROMPT_FD_READY == 0 )) || return 0
    if [[ -r /dev/tty && -w /dev/tty ]] && exec 9<>/dev/tty; then
        PROMPT_FD=9
    else
        PROMPT_FD=0
    fi
    PROMPT_FD_READY=1
}

prompt_read() {
    local output_var="$1" prompt="$2"
    prepare_prompt_input
    # 直接让 read 写入调用方变量。这里不能再声明 local value：Bash 的动态
    # 作用域会让 `prompt_read value` 写回本函数自身，调用方仍保持 unset。
    IFS= read -r -u "$PROMPT_FD" -p "$prompt" "$output_var" || return 1
}

prompt_secret() {
    local output_var="$1" prompt="$2"
    prepare_prompt_input
    IFS= read -r -s -u "$PROMPT_FD" -p "$prompt" "$output_var" || return 1
    printf '\n' >&2
}

valid_mtcp_auth_password() {
    local password="${1-}"

    (( ${#password} >= 12 && ${#password} <= 128 )) || return 1
    [[ "$password" =~ ^[A-Za-z0-9._~!@#%+=:,/-]+$ ]]
}

get_mtcp_auth_password() {
    local output_var="$1" prompt="$2" password confirmation

    if [[ -n "${MTCP_AUTH_PASSWORD+x}" ]]; then
        password="$MTCP_AUTH_PASSWORD"
        valid_mtcp_auth_password "$password" || \
            die "MTCP_AUTH_PASSWORD 无效：长度须为 12-128，只能包含字母、数字及 ._~!@#%+=:,/-"
    else
        while :; do
            prompt_secret password "$prompt: " || die "未输入 MTCP 鉴权密码"
            if ! valid_mtcp_auth_password "$password"; then
                echo "密码长度须为 12-128，只能包含字母、数字及 ._~!@#%+=:,/-，请重新输入。" >&2
                continue
            fi
            prompt_secret confirmation "请再次输入以确认: " || die "未确认 MTCP 鉴权密码"
            if [[ "$password" != "$confirmation" ]]; then
                echo "两次输入的密码不一致，请重新输入。" >&2
                continue
            fi
            break
        done
    fi

    printf -v "$output_var" '%s' "$password"
}

write_mtcp_auth_file() {
    local destination="$1" password="$2"

    (umask 077; printf '%s %s\n' "$MTCP_AUTH_USERNAME" "$password" > "$destination")
    chmod 0600 "$destination"
}

# 从脚本末尾提取嵌入的文件
extract_embedded() {
    local marker="$1"
    sed -n "/^### BEGIN ${marker} ###$/,/^### END ${marker} ###$/p" "$EMBEDDED_SOURCE" |
        sed '1d;$d' | sed '${/^$/d;}'
}

select_install_role() {
    local output_var="$1" choice role confirm redraw=1
    while :; do
        if (( redraw == 1 )); then
            ui_clear
            ui_header "安装 / 新增线路"
            cat <<'MENU'

  [1]  CN      中国大陆入口端（接收业务、路径优选）
  [2]  Remote  境外中转端（监听 MTCP、连接后端）

  [B]  返回主菜单

  建议先安装 Remote，再安装 CN。
MENU
        fi
        redraw=1
        ui_menu_choice choice "请选择 › " || return 1
        case "$choice" in
            1) role="cn" ;;
            2) role="remote" ;;
            b|B|back|q|Q) return 1 ;;
            "") redraw=0; continue ;;
            *) ui_error "无效选择: $choice"; redraw=0; continue ;;
        esac
        ui_menu_choice confirm "确认安装 $role 端？[Y/n] › " || return 1
        case "${confirm:-y}" in
            y|Y|yes|YES|"") printf -v "$output_var" '%s' "$role"; return 0 ;;
            *) ui_warn "已取消" ;;
        esac
    done
}

download_release_file() {
    local direct_url="$1" output="$2" proxy_url

    if [[ -n "$GITHUB_PROXY_PREFIX" ]]; then
        proxy_url="${GITHUB_PROXY_PREFIX%/}/${direct_url}"
        if curl -fsSL --retry 2 --connect-timeout 10 -o "$output" "$proxy_url"; then
            return 0
        fi
        echo "镜像下载失败，尝试直连 GitHub ..." >&2
    fi

    curl -fsSL --retry 2 --connect-timeout 10 -o "$output" "$direct_url"
}

download_gost() {
    local role="$1" dest_dir="$2"

    # CN 默认使用镜像，Remote 默认直连
    if [[ "$role" == "cn" && -z "${GITHUB_PROXY_PREFIX+x}" ]]; then
        GITHUB_PROXY_PREFIX="https://ghfast.top/"
    else
        GITHUB_PROXY_PREFIX="${GITHUB_PROXY_PREFIX:-}"
    fi

    local arch os version release_tag tarball base_url checksum_entry
    arch="$(uname -m)"
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7l) arch="armv7" ;;
        *) die "不支持的架构: $arch" ;;
    esac

    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    [[ "$os" == "linux" ]] || die "仅支持 Linux"

    version="${GOST_VERSION#v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || \
        die "GOST_VERSION 格式无效: $GOST_VERSION"
    release_tag="v${version}"
    tarball="gost_${version}_${os}_${arch}.tar.gz"
    base_url="https://github.com/go-gost/gost/releases/download/${release_tag}"

    echo "下载 GOST ${release_tag} ..."
    local tmp_dir
    tmp_dir="$(mktemp -d)"
    CLEANUP_PATHS+=("$tmp_dir")

    download_release_file "${base_url}/${tarball}" "$tmp_dir/$tarball" || \
        die "下载失败: $tarball"
    download_release_file "${base_url}/checksums.txt" "$tmp_dir/checksums.txt" || \
        die "下载 checksums.txt 失败"

    echo "校验 SHA256..."
    (
        cd "$tmp_dir"
        checksum_entry="$(awk -v file="$tarball" '$2 == file || $2 == "*" file { print; exit }' checksums.txt)"
        [[ -n "$checksum_entry" ]] || die "checksums.txt 中缺少 $tarball"
        if command -v sha256sum &>/dev/null; then
            printf '%s\n' "$checksum_entry" | sha256sum -c - || die "校验失败"
        elif command -v shasum &>/dev/null; then
            printf '%s\n' "$checksum_entry" | shasum -a 256 -c - || die "校验失败"
        else
            die "缺少 sha256sum 或 shasum"
        fi
    )

    echo "解压..."
    tar -xzf "$tmp_dir/$tarball" -C "$tmp_dir"
    local gost_tmp
    gost_tmp="$(mktemp "$dest_dir/.gost.XXXXXX")"
    CLEANUP_PATHS+=("$gost_tmp")
    install -m 755 "$tmp_dir/gost" "$gost_tmp"
    mv -f "$gost_tmp" "$dest_dir/gost"
    echo "✓ GOST 已安装到 $dest_dir/gost"
}

valid_ipv4() {
    local value="$1" octet
    local -a octets
    IFS=. read -r -a octets <<< "$value"
    (( ${#octets[@]} == 4 )) || return 1
    for octet in "${octets[@]}"; do
        [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

normalize_ipv4() {
    local value="$1"
    local -a octets
    IFS=. read -r -a octets <<< "$value"
    printf '%d.%d.%d.%d\n' "$((10#${octets[0]}))" "$((10#${octets[1]}))" \
        "$((10#${octets[2]}))" "$((10#${octets[3]}))"
}

normalize_backend_host() {
    local value="$1"

    if valid_ipv4 "$value"; then
        normalize_ipv4 "$value"
    elif [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        printf '%s\n' "$value"
    elif [[ "$value" =~ ^\[[0-9A-Fa-f:]+\]$ ]]; then
        printf '%s\n' "$value"
    elif [[ "$value" == *:* && "$value" =~ ^[0-9A-Fa-f:]+$ ]]; then
        printf '[%s]\n' "$value"
    else
        return 1
    fi
}

prompt_backend_addr() {
    local output_var="$1" label="${2:-Remote 后端}"
    local host normalized_host target_port rendered

    while :; do
        prompt_read host "${label}地址 [127.0.0.1]: " || return 1
        host="${host:-127.0.0.1}"
        if normalized_host="$(normalize_backend_host "$host")"; then
            break
        fi
        if (( PATHLOCK_INTERACTIVE_MENU == 0 )); then
            die "后端地址无效，请使用 IPv4、主机名或 IPv6 地址"
        fi
        ui_error "后端地址无效，请使用 IPv4、主机名或 IPv6 地址"
    done

    ui_prompt_port target_port "${label}端口: " || return 1
    rendered="${normalized_host}:${target_port}"
    validate_backend_addr "$rendered" || return 1
    printf -v "$output_var" '%s' "$rendered"
}

ensure_units_inactive() {
    local label="$1" unit
    shift
    local -a active=()
    for unit in "$@"; do
        "$SYSTEMCTL_BIN" is-active --quiet "$unit" >/dev/null 2>&1 && active+=("$unit")
    done
    if (( ${#active[@]} > 0 )); then
        die "$label 仍在运行（${active[*]}）。为避免运行进程与新配置错配，请先停止这些 unit 后再重装"
    fi
}

valid_systemd_service_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9_.@-]+\.service$ ]]
}

systemd_unit_artifact_exists() {
    local unit="$1" link
    [[ -e "$SYSTEMD_DIR/$unit" || -L "$SYSTEMD_DIR/$unit" ]] && return 0
    for link in "$SYSTEMD_DIR"/*.target.wants/"$unit" "$SYSTEMD_DIR"/*.target.requires/"$unit"; do
        [[ -e "$link" || -L "$link" ]] && return 0
    done
    return 1
}

stop_systemd_units_strict() {
    local label="$1" unit stop_rc active_rc failed=0
    shift
    for unit in "$@"; do
        valid_systemd_service_name "$unit" || continue
        stop_rc=0
        "$SYSTEMCTL_BIN" stop "$unit" >/dev/null 2>&1 || stop_rc=$?
        active_rc=0
        "$SYSTEMCTL_BIN" is-active --quiet "$unit" >/dev/null 2>&1 || active_rc=$?
        case "$active_rc" in
            0)
                echo "$label 停止后仍在运行: ${unit}（systemctl stop exit ${stop_rc}）" >&2
                failed=1
                ;;
            3|4) ;;
            *)
                echo "无法确认 $label 状态: ${unit}（systemctl is-active exit ${active_rc}，stop exit ${stop_rc}）" >&2
                failed=1
                ;;
        esac
    done
    (( failed == 0 ))
}

remove_systemd_unit_artifacts() {
    local unit="$1" link failed=0
    valid_systemd_service_name "$unit" || return 1
    "$SYSTEMCTL_BIN" disable "$unit" >/dev/null 2>&1 || true
    rm -f -- "$SYSTEMD_DIR/$unit" || failed=1
    for link in "$SYSTEMD_DIR"/*.target.wants/"$unit" "$SYSTEMD_DIR"/*.target.requires/"$unit"; do
        [[ -e "$link" || -L "$link" ]] || continue
        rm -f -- "$link" || failed=1
    done
    (( failed == 0 ))
}

ensure_cn_port_available() {
    local wanted="$1" current_config="$2" _target_unit="$3" legacy_unit="${4:-}"
    local config configured_unit values value current_owns=0
    if [[ -f "$current_config" ]]; then
        values="$(awk -F= '
            $1 == "BUSINESS_PORT" || $1 == "BUSINESS_PORTS" || $1 == "ANCHOR_PORT" {
                value=substr($0,index($0,"=")+1); gsub(/^[\047\042]|[\047\042]$/, "", value); print value
            }
        ' "$current_config")"
        values="${values//,/ }"
        for value in $values; do [[ "$value" == "$wanted" ]] && current_owns=1; done
    fi
    for config in "$INSTALL_BASE"/cn/instances/*/mtcp.conf "$INSTALL_BASE"/cn/mtcp.conf; do
        [[ -f "$config" && "$config" != "$current_config" ]] || continue
        if [[ "${PATHLOCK_SOURCE_TREE:-0}" == 1 && "$config" == "$INSTALL_BASE/cn/mtcp.conf" ]]; then
            [[ "$(read_config_value "$config" DST 2>/dev/null || true)" == "remote.example.invalid" ]] && continue
        fi
        configured_unit="$(read_config_value "$config" UNIT 2>/dev/null || true)"
        # 只跳过正在迁移的旧版平铺线路。共享架构下所有新实例的 UNIT 相同，
        # 绝不能再按 UNIT 跳过，否则会漏掉其他线路的端口冲突。
        [[ -n "$legacy_unit" && "$configured_unit" == "$legacy_unit" &&
           "$config" == "$INSTALL_BASE/cn/mtcp.conf" ]] && continue
        values="$(awk -F= '
            $1 == "BUSINESS_PORT" || $1 == "BUSINESS_PORTS" || $1 == "ANCHOR_PORT" {
                value=substr($0,index($0,"=")+1); gsub(/^[\047\042]|[\047\042]$/, "", value); print value
            }
        ' "$config")"
        values="${values//,/ }"
        for value in $values; do
            [[ "$value" == "$wanted" ]] && die "本机端口 $wanted 已被另一条线路配置占用: $config"
        done
    done
    if (( current_owns == 0 )) && ss -ltnH "sport = :$wanted" 2>/dev/null | grep -q .; then
        die "本机端口 $wanted 已被其他进程监听"
    fi
}

render_cn_route_yaml() {
    local source="$1" destination="$2" route="$3" remote_addr="$4"
    local business_addr="$5" business_backend="$6" anchor_addr="$7" auth_file="$8"

    awk -v route="$route" -v remote_addr="$remote_addr" -v business_addr="$business_addr" \
        -v business_backend="$business_backend" -v anchor_addr="$anchor_addr" -v auth_file="$auth_file" '
        function yaml_quote(value) {
            gsub(/\047/, "\047\047", value)
            return "\047" value "\047"
        }
        function indentation(value) {
            match(value, /[^ ]/)
            return RSTART > 0 ? RSTART - 1 : length(value)
        }
        BEGIN {
            primary_name="tcp-entry-" route
            anchor_name="mtcp-anchor-" route
            chain_name="chain-mtcp-" route
            hop_name="remote-" route
            node_name="remote-mtcp-" route
            print "# pathlock-route: " route
        }
        {
            line=$0
            if (line ~ /^# pathlock-route:[[:space:]]*/) next

            if (skip_connector_auth) {
                if (line ~ /^[[:space:]]*$/) next
                if (indentation(line) > 8) next
                skip_connector_auth=0
            }

            if (line ~ /^services:[[:space:]]*$/) {
                section="services"
            } else if (line ~ /^chains:[[:space:]]*$/) {
                section="chains"
                current_service=""
            }

            if (section == "services" && line ~ /^- name:[[:space:]]*/) {
                name=line
                sub(/^- name:[[:space:]]*/, "", name)
                sub(/[[:space:]]+$/, "", name)
                if (name == "tcp-entry" || name == "tcp-entry-default" || name == primary_name) {
                    line="- name: " primary_name
                    current_service="primary"
                    primary_seen++
                } else if (name == "mtcp-anchor" || name == "mtcp-anchor-default" || name == anchor_name) {
                    line="- name: " anchor_name
                    current_service="anchor"
                    anchor_seen++
                } else {
                    current_service="relay"
                }
            }
            if (section == "services" && current_service != "" && line ~ /^  addr:[[:space:]]*/) {
                if (current_service == "primary") {
                    line="  addr: " business_addr
                    primary_addr_seen++
                } else if (current_service == "anchor") {
                    line="  addr: " anchor_addr
                    anchor_addr_seen++
                }
            }
            if (section == "services" && current_service == "primary" &&
                line ~ /^      addr:[[:space:]]*/) {
                line="      addr: " business_backend
                primary_backend_seen++
            }
            if (section == "services" && (line ~ /^    chain:[[:space:]]*chain-mtcp[[:space:]]*$/ ||
                line ~ /^    chain:[[:space:]]*chain-mtcp-default[[:space:]]*$/ ||
                line == "    chain: " chain_name)) {
                line="    chain: " chain_name
            }

            if (section == "chains" && (line ~ /^- name:[[:space:]]*chain-mtcp[[:space:]]*$/ ||
                line ~ /^- name:[[:space:]]*chain-mtcp-default[[:space:]]*$/ ||
                line == "- name: " chain_name)) {
                line="- name: " chain_name
                chain_seen++
            }
            if (section == "chains" && (line ~ /^  - name:[[:space:]]*remote[[:space:]]*$/ ||
                line ~ /^  - name:[[:space:]]*remote-default[[:space:]]*$/ ||
                line == "  - name: " hop_name)) {
                line="  - name: " hop_name
            }
            if (section == "chains" && (line ~ /^    - name:[[:space:]]*remote-mtcp[[:space:]]*$/ ||
                line ~ /^    - name:[[:space:]]*remote-mtcp-default[[:space:]]*$/ ||
                line == "    - name: " node_name)) {
                line="    - name: " node_name
                in_remote_node=1
                remote_node_seen++
                in_connector=0
            } else if (section == "chains" && line ~ /^    - name:[[:space:]]*/) {
                in_remote_node=0
                in_connector=0
            }
            if (in_remote_node && line ~ /^      addr:[[:space:]]*/) {
                line="      addr: " remote_addr
                remote_addr_seen++
            }
            if (in_remote_node && line ~ /^      connector:[[:space:]]*$/) {
                in_connector=1
                connector_seen++
            } else if (in_connector && line ~ /^      [^ ]/) {
                in_connector=0
            }
            if (in_connector && line ~ /^        auth:[[:space:]]*$/) {
                skip_connector_auth=1
                next
            }
            if (in_connector && line ~ /^        type:[[:space:]]*relay[[:space:]]*$/) {
                print line
                print "        auth:"
                print "          file: " yaml_quote(auth_file)
                auth_seen++
                next
            }
            print line
        }
        END {
            if (primary_seen != 1 || anchor_seen != 1 || primary_addr_seen != 1 ||
                primary_backend_seen != 1 || anchor_addr_seen != 1 || chain_seen != 1 ||
                remote_node_seen != 1 || remote_addr_seen != 1 || connector_seen != 1 ||
                auth_seen != 1) exit 42
        }
    ' "$source" > "$destination"
}

compile_cn_runtime_candidate() {
    local cn_dir="$1" target_fragment="$2" candidate_fragment="$3" output="$4"
    local compiler="${5:-$cn_dir/compile-config.sh}" path found=0
    local -a fragments=()

    for path in "$cn_dir"/instances/*/cn.yaml; do
        [[ -f "$path" ]] || continue
        if [[ "$path" == "$target_fragment" ]]; then
            fragments+=("$candidate_fragment")
            found=1
        elif grep -q '^# pathlock-route:[[:space:]]*' "$path"; then
            fragments+=("$path")
        else
            echo "提示: 暂不纳入尚未迁移的旧线路 $(basename "$(dirname "$path")")；请随后重装该线路。" >&2
        fi
    done
    (( found == 1 )) || fragments+=("$candidate_fragment")
    (( ${#fragments[@]} > 0 )) || die "没有可编译的 CN 线路配置"
    [[ -x "$compiler" ]] || die "CN 配置编译器不可执行: $compiler"
    "$compiler" "$output" "${fragments[@]}"
}

cn_process_policy_value() {
    local config="$1" key="$2" default_value="$3" value
    if ! value="$(awk -F= -v wanted="$key" '
        $1 == wanted {
            value=substr($0,index($0,"=")+1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            gsub(/^[\047\042]|[\047\042]$/, "", value)
            found++
        }
        END {
            if (found > 1) exit 42
            if (found == 1) print value
        }
    ' "$config")"; then
        echo "$config 中 $key 重复定义" >&2
        return 1
    fi
    value="${value:-$default_value}"
    if [[ ! "$value" =~ ^[1-9][0-9]*$ ]]; then
        echo "$config 中 $key 必须是正整数" >&2
        return 1
    fi
    printf '%s\n' "$value"
}

cn_process_policy_signature() {
    local config="$1" grace interval window maximum open
    [[ -r "$config" ]] || { echo "PROCESS recovery 配置不可读: $config" >&2; return 1; }
    grace="$(cn_process_policy_value "$config" PROCESS_RECOVERY_GRACE_SEC 10)" || return 1
    interval="$(cn_process_policy_value "$config" PROCESS_RECOVERY_INTERVAL_SEC 60)" || return 1
    window="$(cn_process_policy_value "$config" PROCESS_RECOVERY_WINDOW_SEC 600)" || return 1
    maximum="$(cn_process_policy_value "$config" PROCESS_RECOVERY_MAX 3)" || return 1
    open="$(cn_process_policy_value "$config" PROCESS_BREAKER_OPEN_SEC 600)" || return 1
    printf '%s|%s|%s|%s|%s\n' "$grace" "$interval" "$window" "$maximum" "$open"
}

validate_cn_process_policy_consistency() {
    local cn_dir="$1" target_config="${2:-}" candidate_config="${3:-}"
    local config source policy baseline="" baseline_source="" candidate_seen=0

    for config in "$cn_dir"/instances/*/mtcp.conf; do
        [[ -f "$config" ]] || continue
        if [[ -n "$candidate_config" && "$config" == "$target_config" ]]; then
            source="$candidate_config"
            candidate_seen=1
        else
            source="$config"
        fi
        policy="$(cn_process_policy_signature "$source")" || return 1
        if [[ -z "$baseline" ]]; then
            baseline="$policy"
            baseline_source="$source"
        elif [[ "$policy" != "$baseline" ]]; then
            echo "共享 PROCESS recovery 参数不一致: $source [$policy] != $baseline_source [$baseline]" >&2
            return 1
        fi
    done

    if [[ -n "$candidate_config" && "$candidate_seen" == 0 ]]; then
        policy="$(cn_process_policy_signature "$candidate_config")" || return 1
        if [[ -n "$baseline" && "$policy" != "$baseline" ]]; then
            echo "共享 PROCESS recovery 参数不一致: $candidate_config [$policy] != $baseline_source [$baseline]" >&2
            return 1
        fi
    fi
    return 0
}

stop_cn_route_controls() {
    local cn_dir="$1" strict="${2:-0}" config anchor watchdog unit stop_rc active_rc failed=0
    for config in "$cn_dir"/instances/*/mtcp.conf; do
        [[ -r "$config" ]] || continue
        anchor="$(read_config_value "$config" ANCHOR_UNIT 2>/dev/null || true)"
        watchdog="$(read_config_value "$config" WATCHDOG_UNIT 2>/dev/null || true)"
        for unit in "$watchdog" "$anchor"; do
            [[ "$unit" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || continue
            stop_rc=0
            "$SYSTEMCTL_BIN" stop "$unit" >/dev/null 2>&1 || stop_rc=$?
            active_rc=0
            "$SYSTEMCTL_BIN" is-active --quiet "$unit" >/dev/null 2>&1 || active_rc=$?
            case "$active_rc" in
                0)
                    if (( strict == 1 )); then
                        echo "控制单元停止后仍在运行: ${unit}（systemctl stop exit ${stop_rc}）" >&2
                        failed=1
                    fi
                    ;;
                3|4)
                    # inactive/failed 或 unit 不存在，都已满足“未运行”。
                    ;;
                *)
                    # D-Bus/systemd 查询异常不能被当作 inactive；严格事务必须 fail closed。
                    if (( strict == 1 )); then
                        echo "无法确认控制单元状态: ${unit}（systemctl is-active exit ${active_rc}，stop exit ${stop_rc}）" >&2
                        failed=1
                    fi
                    ;;
            esac
        done
    done
    (( failed == 0 ))
}

cn_active_business_count() {
    local cn_dir="$1" config values port count=0 seen=" " current
    for config in "$cn_dir"/instances/*/mtcp.conf; do
        [[ -r "$config" ]] || continue
        values="$(read_config_value "$config" BUSINESS_PORTS 2>/dev/null || true)"
        [[ -n "$values" ]] || values="$(read_config_value "$config" BUSINESS_PORT 2>/dev/null || true)"
        values="${values//,/ }"
        for port in $values; do
            valid_port "$port" || continue
            [[ "$seen" != *" $port "* ]] || continue
            seen+="$port "
            current="$(ss -Hnt state established "sport = :$port" 2>/dev/null | awk 'END { print NR+0 }')"
            count=$((count + current))
        done
    done
    printf '%s\n' "$count"
}

require_cn_restart_window() {
    local cn_dir="$1" main_unit="$2" active
    "$SYSTEMCTL_BIN" is-active --quiet "$main_unit" >/dev/null 2>&1 || return 0
    active="$(cn_active_business_count "$cn_dir")"
    (( active == 0 )) && return 0
    if [[ "$PATHLOCK_INTERACTIVE_MENU" == 1 && "$CN_RESTART_CONFIRMED_COUNT" =~ ^[0-9]+$ &&
          "$CN_RESTART_CONFIRMED_COUNT" == "$active" ]]; then
        ui_warn "已确认中断 $active 条活跃业务连接"
        return 0
    fi
    if [[ "${CN_FORCE_RESTART:-0}" != 1 ]]; then
        if [[ "$PATHLOCK_INTERACTIVE_MENU" == 1 ]]; then
            ui_warn "检测到 $active 条活跃业务连接"
            ui_warn "本次变更会重启共享 GOST，并中断所有线路现有连接"
            if ui_confirm "确认现在中断并继续？[y/N] › "; then
                CN_RESTART_CONFIRMED_COUNT="$active"
                return 0
            fi
            die "操作已取消，配置未修改"
        fi
        die "检测到 $active 条活跃业务连接，默认拒绝重启共享 GOST；确认可中断后使用 CN_FORCE_RESTART=1 重试"
    fi
    ui_warn "CN_FORCE_RESTART=1，将中断 $active 条活跃业务连接"
}

start_cn_route_watchdogs() {
    local cn_dir="$1" config watchdog
    for config in "$cn_dir"/instances/*/mtcp.conf; do
        [[ -r "$config" ]] || continue
        watchdog="$(read_config_value "$config" WATCHDOG_UNIT 2>/dev/null || true)"
        [[ "$watchdog" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || continue
        [[ -e "$SYSTEMD_DIR/$watchdog" || -L "$SYSTEMD_DIR/$watchdog" ]] || continue
        if ! "$SYSTEMCTL_BIN" enable "$watchdog" >/dev/null 2>&1; then
            echo "无法启用 Watchdog unit: $watchdog" >&2
            return 1
        fi
        "$SYSTEMCTL_BIN" restart "$watchdog" || return 1
    done
}

install_remote() {
    echo; echo "==> 开始安装 Remote 端"; echo
    check_command curl; check_command tar; check_command "$SYSTEMCTL_BIN"; check_command socat
    check_command flock

    local remote_dir="$INSTALL_BASE/remote" main_unit="gost-mtcp-remote.service"
    local anchor_unit="gost-mtcp-remote-anchor.service" mtcp_port socat_bin
    local auth_file auth_password stage_dir config_candidate auth_candidate main_tmp anchor_tmp
    local backup_dir commit_ok=1 failure_stage=""
    local main_was_enabled=0 anchor_was_enabled=0
    if [[ "${PATHLOCK_SOURCE_TREE:-0}" == 1 ]]; then
        main_unit="gost-ecmp-pathlock-remote.service"
        anchor_unit="gost-ecmp-pathlock-remote-anchor-endpoint.service"
    fi

    acquire_pathlock_manager_lock
    ensure_units_inactive "Remote" "$main_unit" "$anchor_unit"
    mkdir -p "$remote_dir" "$SYSTEMD_DIR"
    socat_bin="$(command -v socat)"

    while :; do
        ui_prompt_port mtcp_port "Remote MTCP 监听端口 [6600]: " 6600 || die "未输入 MTCP 端口"
        [[ "$mtcp_port" != 12346 ]] && break
        (( PATHLOCK_INTERACTIVE_MENU == 1 )) || die "12346 被 Anchor endpoint 占用"
        ui_error "12346 被 Anchor endpoint 占用，请选择其他端口"
    done
    get_mtcp_auth_password auth_password "请设置 Remote MTCP 鉴权密码"
    auth_file="$remote_dir/mtcp.auth"

    # Remote 与 CN 使用同一事务原则：所有候选文件先在隔离目录中生成、用候选
    # GOST 校验，再一次性提交；systemd 任一步失败都恢复旧 artifacts 与 enable 状态。
    stage_dir="$(mktemp -d "$remote_dir/.remote-candidate.XXXXXX")"
    CLEANUP_PATHS+=("$stage_dir")
    download_gost remote "$stage_dir"
    config_candidate="$stage_dir/remote.yaml"
    auth_candidate="$stage_dir/mtcp.auth"
    write_mtcp_auth_file "$auth_candidate" "$auth_password"
    extract_embedded REMOTE_YAML | awk -v addr=":$mtcp_port" -v auth_file="$auth_file" '
        function yaml_quote(value) {
            gsub(/\047/, "\047\047", value)
            return "\047" value "\047"
        }
        {
            line = $0
            if (line ~ /^authers:[[:space:]]*$/) {
                in_authers = 1; in_service = 0; in_handler = 0; authers_seen++
            } else if (!in_authers && line ~ /^- name:[[:space:]]*/) {
                in_service = (line ~ /^- name:[[:space:]]*mtcp-server[[:space:]]*$/)
                in_handler = 0
                if (in_service) service_seen++
            } else if (in_authers && line ~ /^- name:[[:space:]]*/) {
                in_mtcp_auther = (line ~ /^- name:[[:space:]]*mtcp-auth[[:space:]]*$/)
                if (in_mtcp_auther) mtcp_auther_seen++
            }
            if (in_service && line ~ /^  addr:[[:space:]]*/) {
                sub(/addr:.*/, "addr: " addr, line); listen_updated++
            }
            if (in_service && line ~ /^  handler:[[:space:]]*$/) {
                in_handler = 1
            } else if (in_handler && line ~ /^  [^ ]/) {
                in_handler = 0
            }
            if (in_handler && line ~ /^    auther:[[:space:]]*/) next
            if (in_handler && line ~ /^    type:[[:space:]]*relay[[:space:]]*$/) {
                print line
                print "    auther: mtcp-auth"
                auth_ref_updated++
                next
            }
            if (in_mtcp_auther && line ~ /^    path:[[:space:]]*/) {
                line = "    path: " yaml_quote(auth_file); auth_path_updated++
            }
            print line
        }
        END {
            if (service_seen != 1 || listen_updated != 1 || auth_ref_updated != 1 ||
                authers_seen != 1 || mtcp_auther_seen != 1 || auth_path_updated != 1) exit 42
        }
    ' > "$config_candidate" || die "canonical Remote 监听或鉴权配置结构不符合预期"
    chmod 0644 "$config_candidate"
    "$stage_dir/gost" -C "$config_candidate" -O yaml >/dev/null || \
        die "Remote 候选配置未通过候选 GOST 解析校验"

    main_tmp="$(mktemp "$SYSTEMD_DIR/.${main_unit}.XXXXXX")"
    anchor_tmp="$(mktemp "$SYSTEMD_DIR/.${anchor_unit}.XXXXXX")"
    CLEANUP_PATHS+=("$main_tmp" "$anchor_tmp")
    extract_embedded REMOTE_MAIN_SERVICE | sed \
        -e "s|/root/gost-ecmp-pathlock/remote|$remote_dir|g" \
        > "$main_tmp"
    extract_embedded REMOTE_ANCHOR_SERVICE | sed \
        -e "s|gost-ecmp-pathlock-remote.service|$main_unit|g" \
        -e "s|/usr/bin/socat|$socat_bin|g" \
        > "$anchor_tmp"
    chmod 0644 "$main_tmp" "$anchor_tmp"
    grep -Fqx "WorkingDirectory=$remote_dir" "$main_tmp" &&
        grep -Fqx "ExecStart=$remote_dir/gost -D -C $remote_dir/remote.yaml" "$main_tmp" || \
        die "Remote main unit 渲染校验失败"
    grep -Fq "ExecStart=$socat_bin " "$anchor_tmp" || die "Remote Anchor unit 渲染校验失败"

    backup_dir="$(mktemp -d "$remote_dir/.remote-update.XXXXXX")" || die "无法创建 Remote 事务备份目录"
    remote_backup_one() {
        local path="$1" key="$2"
        if [[ -e "$path" || -L "$path" ]]; then
            cp -p "$path" "$backup_dir/$key" || return 1
            : > "$backup_dir/$key.exists"
        fi
    }
    remote_restore_one() {
        local path="$1" key="$2"
        if [[ -e "$backup_dir/$key.exists" ]]; then
            cp -p "$backup_dir/$key" "$path" || return 1
        else
            rm -f -- "$path" || return 1
        fi
    }
    remote_unit_enabled_artifact() {
        local unit="$1" link
        for link in "$SYSTEMD_DIR"/*.target.wants/"$unit" "$SYSTEMD_DIR"/*.target.requires/"$unit"; do
            [[ -e "$link" || -L "$link" ]] && return 0
        done
        return 1
    }
    remote_remove_enable_artifacts() {
        local unit="$1" link failed=0
        for link in "$SYSTEMD_DIR"/*.target.wants/"$unit" "$SYSTEMD_DIR"/*.target.requires/"$unit"; do
            [[ -e "$link" || -L "$link" ]] || continue
            rm -f -- "$link" || failed=1
        done
        (( failed == 0 ))
    }
    remote_rollback() {
        local ok=1
        stop_systemd_units_strict "Remote rollback" "$anchor_unit" "$main_unit" \
            >/dev/null 2>&1 || ok=0
        "$SYSTEMCTL_BIN" disable "$anchor_unit" "$main_unit" >/dev/null 2>&1 || true
        remote_remove_enable_artifacts "$main_unit" || ok=0
        remote_remove_enable_artifacts "$anchor_unit" || ok=0
        remote_restore_one "$remote_dir/gost" gost || ok=0
        remote_restore_one "$remote_dir/remote.yaml" remote-yaml || ok=0
        remote_restore_one "$auth_file" remote-auth || ok=0
        remote_restore_one "$SYSTEMD_DIR/$main_unit" main-unit || ok=0
        remote_restore_one "$SYSTEMD_DIR/$anchor_unit" anchor-unit || ok=0
        "$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || ok=0
        if (( main_was_enabled == 1 )); then
            "$SYSTEMCTL_BIN" enable "$main_unit" >/dev/null 2>&1 || ok=0
        else
            "$SYSTEMCTL_BIN" disable "$main_unit" >/dev/null 2>&1 || ok=0
        fi
        if (( anchor_was_enabled == 1 )); then
            "$SYSTEMCTL_BIN" enable "$anchor_unit" >/dev/null 2>&1 || ok=0
        else
            "$SYSTEMCTL_BIN" disable "$anchor_unit" >/dev/null 2>&1 || ok=0
        fi
        (( ok == 1 ))
    }

    remote_unit_enabled_artifact "$main_unit" && main_was_enabled=1
    remote_unit_enabled_artifact "$anchor_unit" && anchor_was_enabled=1
    if ! remote_backup_one "$remote_dir/gost" gost ||
       ! remote_backup_one "$remote_dir/remote.yaml" remote-yaml ||
       ! remote_backup_one "$auth_file" remote-auth ||
       ! remote_backup_one "$SYSTEMD_DIR/$main_unit" main-unit ||
       ! remote_backup_one "$SYSTEMD_DIR/$anchor_unit" anchor-unit; then
        rm -rf -- "$backup_dir"
        die "无法备份 Remote 事务所需 artifacts"
    fi

    if ! mv -f "$stage_dir/gost" "$remote_dir/gost" ||
       ! mv -f "$config_candidate" "$remote_dir/remote.yaml" ||
       ! mv -f "$auth_candidate" "$auth_file" ||
       ! mv -f "$main_tmp" "$SYSTEMD_DIR/$main_unit" ||
       ! mv -f "$anchor_tmp" "$SYSTEMD_DIR/$anchor_unit"; then
        commit_ok=0; failure_stage="提交 Remote artifacts"
    fi
    if (( commit_ok == 1 )) && ! "$SYSTEMCTL_BIN" daemon-reload; then
        commit_ok=0; failure_stage="systemd daemon-reload"
    fi
    if (( commit_ok == 1 )) && ! "$SYSTEMCTL_BIN" enable "$main_unit" "$anchor_unit"; then
        commit_ok=0; failure_stage="systemd enable"
    fi
    if (( commit_ok == 1 )) && ! "$SYSTEMCTL_BIN" restart "$main_unit" "$anchor_unit"; then
        commit_ok=0; failure_stage="systemd restart"
    fi
    if (( commit_ok == 1 )) &&
       { ! "$SYSTEMCTL_BIN" is-active --quiet "$main_unit" ||
         ! "$SYSTEMCTL_BIN" is-active --quiet "$anchor_unit"; }; then
        commit_ok=0; failure_stage="服务健康检查"
    fi

    if (( commit_ok == 0 )); then
        echo "Remote 安装失败（${failure_stage}），正在回滚。" >&2
        if remote_rollback; then
            rm -rf -- "$backup_dir"
            die "Remote 更新未生效，旧 artifacts 与 enable 状态已恢复"
        fi
        die "Remote 更新失败且自动回滚不完整；保留现场: $backup_dir"
    fi

    rm -rf -- "$backup_dir" "$stage_dir"
    release_pathlock_manager_lock
    cat <<DONE

============================================================
  Remote 端安装完成
============================================================
MTCP 监听端口: $mtcp_port    Relay 鉴权: 已启用
配置文件: $remote_dir/remote.yaml
鉴权文件: ${auth_file}（权限 0600）
服务: $main_unit, $anchor_unit
下一步: 安装 CN 时输入本次设置的同一密码
重要: 仍应只允许 CN 公网 IP 访问 $mtcp_port/tcp
============================================================
DONE
}

install_cn() {
    echo; echo "==> 开始安装 CN 端（共享 GOST）"; echo
    check_command curl; check_command tar; check_command "$SYSTEMCTL_BIN"
    check_command ss; check_command flock; check_command timeout

    local cn_dir="$INSTALL_BASE/cn" runtime_yaml main_unit="gost-mtcp.service"
    local remote_alias remote_ip remote_port business_port business_backend anchor_port
    local rtt_threshold auth_password
    local route_prefix anchor_unit watchdog_unit legacy_main_unit instance_dir state_dir auth_file
    local anchor_service chain_name
    local yaml_template yaml_tmp conf_tmp auth_tmp runtime_tmp runtime_stage compile_tmp
    local lib_tmp prewarm_tmp watchdog_tmp main_tmp anchor_tmp watchdog_unit_tmp
    local business_ports legacy_unit config other_dst other_port migration_stamp candidate_script
    local shared_stage backup_dir restart_ok=0

    cn_dir="$INSTALL_BASE/cn"
    runtime_yaml="$cn_dir/runtime.yaml"
    acquire_pathlock_manager_lock
    mkdir -p "$cn_dir/instances" "$SYSTEMD_DIR"
    exec 8>"$cn_dir/config.lock"
    PATHLOCK_LOCK_KIND=config flock -n 8 || die "另一项 CN 配置操作正在进行"
    validate_cn_process_policy_consistency "$cn_dir" || \
        die "已安装线路的共享 PROCESS recovery 参数不一致；请统一后再安装或升级"

    echo "配置参数:"; echo
    while :; do
        prompt_read remote_alias "Remote 线路别名（如 de、us，回车=default）: " || die "未输入线路别名"
        remote_alias="${remote_alias:-default}"
        if [[ ! "$remote_alias" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]; then
            (( PATHLOCK_INTERACTIVE_MENU == 1 )) || die "线路别名无效"
            ui_error "线路别名只能包含字母、数字、下划线和连字符，长度不超过 32"
            continue
        fi
        case "$remote_alias" in
            anchor|watchdog|*-anchor|*-watchdog)
                (( PATHLOCK_INTERACTIVE_MENU == 1 )) || die "线路别名使用了保留后缀"
                ui_error "线路别名使用了保留后缀"; continue
                ;;
        esac
        break
    done

    route_prefix="gost-mtcp"
    [[ "$remote_alias" != default ]] && route_prefix="gost-mtcp-$remote_alias"
    anchor_unit="$route_prefix-anchor.service"
    watchdog_unit="$route_prefix-watchdog.service"
    legacy_main_unit="$route_prefix.service"
    if [[ "${PATHLOCK_SOURCE_TREE:-0}" == 1 ]]; then
        legacy_main_unit="gost-ecmp-pathlock.service"
        [[ "$remote_alias" != default ]] && legacy_main_unit="gost-ecmp-pathlock-$remote_alias.service"
    fi
    instance_dir="$cn_dir/instances/$remote_alias"
    state_dir="$instance_dir/state"
    auth_file="$instance_dir/mtcp.auth"
    anchor_service="mtcp-anchor-$remote_alias"
    chain_name="chain-mtcp-$remote_alias"

    # 共享主进程允许保持运行；目标线路自己的控制单元和旧版独立主进程必须先停。
    ensure_units_inactive "CN 线路 $remote_alias" "$watchdog_unit" "$anchor_unit"
    if [[ "$legacy_main_unit" != "$main_unit" ]]; then
        ensure_units_inactive "旧版 CN 线路 $remote_alias" "$legacy_main_unit"
    fi
    mkdir -p "$state_dir"

    while :; do
        prompt_read remote_ip "Remote IPv4 地址: " || die "未输入 Remote IPv4 地址"
        valid_ipv4 "$remote_ip" && break
        ui_error "IPv4 地址无效，请重新输入"
    done
    remote_ip="$(normalize_ipv4 "$remote_ip")"
    ui_prompt_port remote_port "Remote MTCP 端口 [6600]: " 6600 || die "未输入 Remote MTCP 端口"
    get_mtcp_auth_password auth_password "请输入 Remote 安装时设置的 MTCP 鉴权密码"
    ui_prompt_port business_port "CN 业务监听端口 [12000]: " 12000 || die "未输入 CN 业务监听端口"
    prompt_backend_addr business_backend "Remote 后端" || die "未输入 Remote 后端地址或端口"
    while :; do
        ui_prompt_port anchor_port "CN Anchor 监听端口 [12001]: " 12001 || die "未输入 CN Anchor 监听端口"
        [[ "$business_port" != "$anchor_port" ]] && break
        (( PATHLOCK_INTERACTIVE_MENU == 1 )) || die "业务端口不能与 Anchor 端口相同"
        ui_error "Anchor 端口不能与业务端口相同"
    done
    while :; do
        prompt_read rtt_threshold "RTT 快路阈值（ms）[40]: " || die "未输入 RTT 阈值"
        rtt_threshold="${rtt_threshold:-40}"
        [[ "$rtt_threshold" =~ ^[0-9]+([.][0-9]+)?$ ]] && break
        (( PATHLOCK_INTERACTIVE_MENU == 1 )) || die "RTT 阈值无效"
        ui_error "RTT 阈值必须是非负数字"
    done

    # 单进程下 socket 归属依赖 PID + Remote endpoint；相同 DST:PORT 无法安全区分线路。
    for config in "$cn_dir"/instances/*/mtcp.conf; do
        [[ -r "$config" && "$config" != "$instance_dir/mtcp.conf" ]] || continue
        other_dst="$(read_config_value "$config" DST 2>/dev/null || true)"
        other_port="$(read_config_value "$config" PORT 2>/dev/null || true)"
        if [[ "$other_dst" == "$remote_ip" && "$other_port" == "$remote_port" ]]; then
            die "Remote endpoint $remote_ip:$remote_port 已被 $(basename "$(dirname "$config")") 使用；共享进程要求每条线路 endpoint 唯一"
        fi
    done
    ensure_cn_port_available "$business_port" "$instance_dir/mtcp.conf" "$main_unit" "$legacy_main_unit"
    ensure_cn_port_available "$anchor_port" "$instance_dir/mtcp.conf" "$main_unit" "$legacy_main_unit"
    require_cn_restart_window "$cn_dir" "$main_unit"

    # GOST 与所有公共脚本先进入隔离 staging。正式路径在候选 runtime、units、
    # shell 语法和真实 GOST 解析全部通过前保持不变，避免 old process + new files。
    shared_stage="$(mktemp -d "$cn_dir/.shared-candidate.XXXXXX")"
    CLEANUP_PATHS+=("$shared_stage")
    download_gost cn "$shared_stage"

    lib_tmp="$shared_stage/mtcp-lib.sh"
    prewarm_tmp="$shared_stage/mtcp-prewarm.sh"
    watchdog_tmp="$shared_stage/mtcp-watchdog.sh"
    compile_tmp="$shared_stage/compile-config.sh"
    extract_embedded CN_LIB | sed "s|/root/gost-ecmp-pathlock/cn|$cn_dir|g" > "$lib_tmp"
    extract_embedded CN_PREWARM | sed "s|/root/gost-ecmp-pathlock/cn|$cn_dir|g" > "$prewarm_tmp"
    extract_embedded CN_WATCHDOG | sed "s|/root/gost-ecmp-pathlock/cn|$cn_dir|g" > "$watchdog_tmp"
    extract_embedded CN_COMPILE > "$compile_tmp"
    chmod 0755 "$lib_tmp" "$prewarm_tmp" "$watchdog_tmp" "$compile_tmp"
    for candidate_script in "$lib_tmp" "$prewarm_tmp" "$watchdog_tmp" "$compile_tmp"; do
        bash -n "$candidate_script" || die "候选 CN 公共脚本未通过 shell 语法校验: $candidate_script"
    done

    yaml_template="$(mktemp "$instance_dir/.cn.template.XXXXXX")"
    yaml_tmp="$(mktemp "$instance_dir/.cn.yaml.XXXXXX")"
    conf_tmp="$(mktemp "$instance_dir/.mtcp.conf.XXXXXX")"
    auth_tmp="$(mktemp "$instance_dir/.mtcp.auth.XXXXXX")"
    # GOST 依据配置文件的最终扩展名判断输入格式。不能把 mktemp 的随机后缀
    # 直接交给 `gost -C`，否则会被当成未知配置类型。
    runtime_stage="$(mktemp -d "$cn_dir/.runtime-candidate.XXXXXX")"
    runtime_tmp="$runtime_stage/runtime.yaml"
    CLEANUP_PATHS+=("$yaml_template" "$yaml_tmp" "$conf_tmp" "$auth_tmp" "$runtime_stage")
    write_mtcp_auth_file "$auth_tmp" "$auth_password"

    legacy_unit="$(read_config_value "$cn_dir/mtcp.conf" UNIT 2>/dev/null || true)"
    if [[ "${PATHLOCK_SOURCE_TREE:-0}" == 1 &&
          "$(read_config_value "$cn_dir/mtcp.conf" DST 2>/dev/null || true)" == "remote.example.invalid" ]]; then
        legacy_unit=""
    fi
    if [[ -r "$instance_dir/cn.yaml" ]]; then
        cp -p "$instance_dir/cn.yaml" "$yaml_template"
    elif [[ "$legacy_unit" == "$legacy_main_unit" && -r "$cn_dir/cn.yaml" ]]; then
        cp -p "$cn_dir/cn.yaml" "$yaml_template"
        echo "检测到旧版平铺配置，正在迁移到共享 GOST 并保留现有 Relay。"
    else
        extract_embedded CN_YAML > "$yaml_template"
    fi

    render_cn_route_yaml "$yaml_template" "$yaml_tmp" "$remote_alias" \
        "$remote_ip:$remote_port" ":$business_port" "$business_backend" \
        "127.0.0.1:$anchor_port" "$auth_file" || \
        die "CN 线路 fragment 的监听、后端、链或鉴权结构不符合预期"

    business_ports="$(cn_business_ports "$yaml_tmp" "$chain_name" "$anchor_service")"
    [[ " $business_ports " == *" $business_port "* ]] || \
        die "迁移后的线路 fragment 未包含主业务端口 $business_port"
    [[ " $business_ports " != *" $anchor_port "* ]] || \
        die "迁移后的业务端口错误包含 Anchor 端口 $anchor_port"

    extract_embedded CN_MTCP_CONF | awk -v route="$remote_alias" -v main="$main_unit" \
        -v anchor_unit="$anchor_unit" -v watchdog_unit="$watchdog_unit" \
        -v chain_name="$chain_name" -v anchor_service="$anchor_service" \
        -v remote="$remote_ip" -v remote_port="$remote_port" -v business="$business_port" \
        -v business_ports="$business_ports" -v anchor_port="$anchor_port" \
        -v rtt="$rtt_threshold" -v state="$state_dir" '
        BEGIN {
            v["ROUTE_ID"]=route; v["UNIT"]=main; v["ANCHOR_UNIT"]=anchor_unit
            v["WATCHDOG_UNIT"]=watchdog_unit; v["CHAIN_NAME"]=chain_name
            v["ANCHOR_SERVICE"]=anchor_service; v["DST"]=remote; v["PORT"]=remote_port
            v["BUSINESS_PORT"]=business; v["BUSINESS_PORTS"]=business_ports
            v["ANCHOR_HOST"]="127.0.0.1"; v["ANCHOR_PORT"]=anchor_port
            v["ACCEPT_RTT_MS"]=rtt; v["STATE_DIR"]=state
            v["STATE_FILE"]=state "/runtime.state"; v["STATUS_JSON"]=state "/status.json"
            v["EVENT_FILE"]=state "/events.jsonl"
        }
        { key=$0; sub(/=.*/, "", key); if (key in v) { print key "=\"" v[key] "\""; seen[key]++; next } print }
        END { for (key in v) if (seen[key] != 1) exit 42 }
    ' > "$conf_tmp" || die "canonical CN Watchdog 配置结构不符合预期"
    chmod 0644 "$yaml_tmp" "$conf_tmp"
    validate_cn_process_policy_consistency "$cn_dir" "$instance_dir/mtcp.conf" "$conf_tmp" || \
        die "候选线路与现有线路的共享 PROCESS recovery 参数不一致"

    compile_cn_runtime_candidate "$cn_dir" "$instance_dir/cn.yaml" "$yaml_tmp" "$runtime_tmp" \
        "$compile_tmp" || \
        die "无法生成共享 GOST 配置；请检查线路归属、名称、监听端口和 chain 是否冲突"
    "$shared_stage/gost" -C "$runtime_tmp" -O yaml >/dev/null || \
        die "共享 GOST 配置未通过候选 GOST 解析校验"

    main_tmp="$(mktemp "$SYSTEMD_DIR/.gost-mtcp.XXXXXX")"
    anchor_tmp="$(mktemp "$SYSTEMD_DIR/.${route_prefix}-anchor.XXXXXX")"
    watchdog_unit_tmp="$(mktemp "$SYSTEMD_DIR/.${route_prefix}-watchdog.XXXXXX")"
    CLEANUP_PATHS+=("$main_tmp" "$anchor_tmp" "$watchdog_unit_tmp")
    extract_embedded CN_MAIN_SERVICE | awk -v cn="$cn_dir" -v runtime="$runtime_yaml" '
        /^WorkingDirectory=/ { print "WorkingDirectory=" cn; next }
        /^ExecStartPre=\/usr\/bin\/test -x / { print "ExecStartPre=/usr/bin/test -x " cn "/gost"; next }
        /^ExecStartPre=\/usr\/bin\/test -r / { print "ExecStartPre=/usr/bin/test -r " runtime; next }
        /^ExecStart=/ { print "ExecStart=" cn "/gost -D -C " runtime; next }
        { print }
    ' > "$main_tmp"
    extract_embedded CN_ANCHOR_SERVICE | sed \
        -e "s|gost-ecmp-pathlock.service|$main_unit|g" \
        -e "s|/dev/tcp/127.0.0.1/12001|/dev/tcp/127.0.0.1/$anchor_port|g" > "$anchor_tmp"
    extract_embedded CN_WATCHDOG_SERVICE | awk -v canonical="gost-ecmp-pathlock.service" -v main="$main_unit" \
        -v root="/root/gost-ecmp-pathlock/cn" -v cn="$cn_dir" -v wd="$instance_dir" \
        -v config="$instance_dir/mtcp.conf" '
        function repl(text, old, replacement, pos, result) {
            result=""
            while ((pos=index(text,old)) > 0) {
                result=result substr(text,1,pos-1) replacement
                text=substr(text,pos+length(old))
            }
            return result text
        }
        { line=repl($0,canonical,main); line=repl(line,root "/mtcp.conf",config); line=repl(line,root,cn)
          if (line ~ /^WorkingDirectory=/) line="WorkingDirectory=" wd; print line }
    ' > "$watchdog_unit_tmp"
    chmod 0644 "$main_tmp" "$anchor_tmp" "$watchdog_unit_tmp"

    backup_dir="$(mktemp -d "$cn_dir/.shared-update.XXXXXX")"
    CLEANUP_PATHS+=("$backup_dir")
    backup_one() {
        local path="$1" key="$2"
        if [[ -e "$path" || -L "$path" ]]; then
            cp -p "$path" "$backup_dir/$key"
            : > "$backup_dir/$key.exists"
        fi
    }
    restore_one() {
        local path="$1" key="$2"
        if [[ -e "$backup_dir/$key.exists" ]]; then
            cp -p "$backup_dir/$key" "$path"
        else
            rm -f "$path"
        fi
    }
    disable_new_cn_units() {
        # enable 的状态不在 artifact 备份中。若 unit 原本不存在，失败事务必须
        # 在删除候选 unit 前撤销可能已创建（即使 enable 最终返回失败）的 Wants symlink。
        if [[ ! -e "$backup_dir/main-unit.exists" ]]; then
            "$SYSTEMCTL_BIN" disable "$main_unit" >/dev/null 2>&1 || true
        fi
        if [[ ! -e "$backup_dir/watchdog-unit.exists" ]]; then
            "$SYSTEMCTL_BIN" disable "$watchdog_unit" >/dev/null 2>&1 || true
        fi
    }
    backup_one "$cn_dir/gost" shared-gost
    backup_one "$cn_dir/mtcp-lib.sh" shared-lib
    backup_one "$cn_dir/mtcp-prewarm.sh" shared-prewarm
    backup_one "$cn_dir/mtcp-watchdog.sh" shared-watchdog
    backup_one "$cn_dir/compile-config.sh" shared-compiler
    backup_one "$instance_dir/cn.yaml" route-yaml
    backup_one "$instance_dir/mtcp.conf" route-conf
    backup_one "$auth_file" route-auth
    backup_one "$runtime_yaml" runtime-yaml
    backup_one "$SYSTEMD_DIR/$main_unit" main-unit
    backup_one "$SYSTEMD_DIR/$anchor_unit" anchor-unit
    backup_one "$SYSTEMD_DIR/$watchdog_unit" watchdog-unit

    echo "正在停止各线路控制单元并重启唯一共享 GOST；现有线路连接会中断。"
    if ! stop_cn_route_controls "$cn_dir" 1; then
        start_cn_route_watchdogs "$cn_dir" >/dev/null 2>&1 || true
        die "无法停止全部线路控制单元；正式 shared artifacts 尚未修改"
    fi
    if ! mv -f "$shared_stage/gost" "$cn_dir/gost" ||
       ! mv -f "$lib_tmp" "$cn_dir/mtcp-lib.sh" ||
       ! mv -f "$prewarm_tmp" "$cn_dir/mtcp-prewarm.sh" ||
       ! mv -f "$watchdog_tmp" "$cn_dir/mtcp-watchdog.sh" ||
       ! mv -f "$compile_tmp" "$cn_dir/compile-config.sh" ||
       ! mv -f "$auth_tmp" "$auth_file" ||
       ! mv -f "$yaml_tmp" "$instance_dir/cn.yaml" ||
       ! mv -f "$conf_tmp" "$instance_dir/mtcp.conf" ||
       ! mv -f "$runtime_tmp" "$runtime_yaml" ||
       ! mv -f "$main_tmp" "$SYSTEMD_DIR/$main_unit" ||
       ! mv -f "$anchor_tmp" "$SYSTEMD_DIR/$anchor_unit" ||
       ! mv -f "$watchdog_unit_tmp" "$SYSTEMD_DIR/$watchdog_unit"; then
        restore_one "$cn_dir/gost" shared-gost
        restore_one "$cn_dir/mtcp-lib.sh" shared-lib
        restore_one "$cn_dir/mtcp-prewarm.sh" shared-prewarm
        restore_one "$cn_dir/mtcp-watchdog.sh" shared-watchdog
        restore_one "$cn_dir/compile-config.sh" shared-compiler
        restore_one "$instance_dir/cn.yaml" route-yaml
        restore_one "$instance_dir/mtcp.conf" route-conf
        restore_one "$auth_file" route-auth
        restore_one "$runtime_yaml" runtime-yaml
        restore_one "$SYSTEMD_DIR/$main_unit" main-unit
        restore_one "$SYSTEMD_DIR/$anchor_unit" anchor-unit
        restore_one "$SYSTEMD_DIR/$watchdog_unit" watchdog-unit
        "$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || true
        "$SYSTEMCTL_BIN" restart "$main_unit" >/dev/null 2>&1 || true
        start_cn_route_watchdogs "$cn_dir" >/dev/null 2>&1 || true
        die "无法提交共享 CN artifacts 与配置；已尝试恢复原状态"
    fi

    # daemon-reload 也属于提交事务；若它失败，不能越过回滚直接退出或继续启动。
    if "$SYSTEMCTL_BIN" daemon-reload &&
       "$SYSTEMCTL_BIN" enable "$main_unit"; then
        if "$SYSTEMCTL_BIN" restart "$main_unit" && "$SYSTEMCTL_BIN" is-active --quiet "$main_unit" &&
           start_cn_route_watchdogs "$cn_dir"; then
            restart_ok=1
        fi
    fi

    if (( restart_ok != 1 )); then
        echo "共享 GOST 更新失败，正在回滚 binary、公共脚本、线路、聚合配置和 systemd unit。" >&2
        stop_cn_route_controls "$cn_dir"
        disable_new_cn_units
        restore_one "$cn_dir/gost" shared-gost
        restore_one "$cn_dir/mtcp-lib.sh" shared-lib
        restore_one "$cn_dir/mtcp-prewarm.sh" shared-prewarm
        restore_one "$cn_dir/mtcp-watchdog.sh" shared-watchdog
        restore_one "$cn_dir/compile-config.sh" shared-compiler
        restore_one "$instance_dir/cn.yaml" route-yaml
        restore_one "$instance_dir/mtcp.conf" route-conf
        restore_one "$auth_file" route-auth
        restore_one "$runtime_yaml" runtime-yaml
        restore_one "$SYSTEMD_DIR/$main_unit" main-unit
        restore_one "$SYSTEMD_DIR/$anchor_unit" anchor-unit
        restore_one "$SYSTEMD_DIR/$watchdog_unit" watchdog-unit
        "$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || true
        "$SYSTEMCTL_BIN" restart "$main_unit" >/dev/null 2>&1 || true
        start_cn_route_watchdogs "$cn_dir" >/dev/null 2>&1 || true
        die "共享 GOST 更新未生效，已尝试恢复整套旧 artifacts 与配置"
    fi

    if [[ "$legacy_main_unit" != "$main_unit" ]]; then
        "$SYSTEMCTL_BIN" disable "$legacy_main_unit" >/dev/null 2>&1 || true
        rm -f "$SYSTEMD_DIR/$legacy_main_unit"
        "$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || true
    fi
    if [[ "$legacy_unit" == "$legacy_main_unit" ]]; then
        migration_stamp="$(date +%Y%m%d-%H%M%S)"
        [[ -f "$cn_dir/cn.yaml" ]] && mv -f "$cn_dir/cn.yaml" "$cn_dir/cn.yaml.migrated.$migration_stamp"
        [[ -f "$cn_dir/mtcp.conf" ]] && mv -f "$cn_dir/mtcp.conf" "$cn_dir/mtcp.conf.migrated.$migration_stamp"
        if [[ "${PATHLOCK_SOURCE_TREE:-0}" == 1 ]]; then
            extract_embedded CN_YAML > "$cn_dir/cn.yaml"
            extract_embedded CN_MTCP_CONF > "$cn_dir/mtcp.conf"
            chmod 0644 "$cn_dir/cn.yaml" "$cn_dir/mtcp.conf"
        fi
    fi

    exec 8>&-
    release_pathlock_manager_lock
    cat <<DONE

============================================================
  CN 线路安装完成（共享单 GOST 进程）
============================================================
线路: $remote_alias    Remote: $remote_ip:$remote_port    MTCP 鉴权: 已启用
默认端口转发: :$business_port -> $business_backend
RTT 阈值: ${rtt_threshold}ms
线路 fragment: $instance_dir/cn.yaml
共享运行配置: $runtime_yaml
鉴权文件: ${auth_file}（权限 0600）
共享服务: $main_unit
线路控制: $anchor_unit, $watchdog_unit
后续管理: bash standalone-install.sh（选择“管理线路端口转发”）
============================================================
DONE
}

valid_port() {
    local value="${1:-}" number
    [[ "$value" =~ ^[0-9]+$ && ${#value} -le 5 ]] || return 1
    number=$((10#$value))
    (( number >= 1 && number <= 65535 ))
}

read_config_value() {
    local file="$1" key="$2"
    awk -F= -v wanted="$key" '
        $1 == wanted {
            value = substr($0, index($0, "=") + 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            gsub(/^[\047\042]|[\047\042]$/, "", value)
            print value
            exit
        }
    ' "$file"
}

add_project_systemd_unit() {
    local unit="$1" existing
    valid_systemd_service_name "$unit" || return 0
    for existing in "${PROJECT_SYSTEMD_UNITS[@]:-}"; do
        [[ -n "$existing" ]] || continue
        [[ "$existing" == "$unit" ]] && return 0
    done
    PROJECT_SYSTEMD_UNITS+=("$unit")
}

systemd_unit_belongs_to_pathlock() {
    local unit="$1" path="${2:-}" description candidate canonical_path checked_path=""
    valid_systemd_service_name "$unit" || return 1
    canonical_path="$SYSTEMD_DIR/$unit"

    # 名字只能用于发现候选，不能作为 ownership 证据。尤其 gost-mtcp.service
    # 与 gost-mtcp-*-{anchor,watchdog}.service 都可能由同机其他项目使用。
    # 只要磁盘 artifact 存在，其当前内容就是最高权威；内容不匹配或不可读时
    # 必须 fail closed，不能再用 systemd 尚未 daemon-reload 的旧 Description 认领。
    for candidate in "$canonical_path" "$path"; do
        [[ -n "$candidate" ]] || continue
        [[ "$candidate" != "$checked_path" ]] || continue
        checked_path="$candidate"
        if [[ -e "$candidate" || -L "$candidate" ]]; then
            [[ -r "$candidate" ]] || return 1
            if grep -Fq 'GOST ECMP PathLock' "$candidate" ||
               grep -Fq -- "$INSTALL_BASE/" "$candidate"; then
                return 0
            fi
            return 1
        fi
    done

    # 仅用于“磁盘 unit 已不存在、systemd 仍保留 loaded unit”的清理场景。
    description="$("$SYSTEMCTL_BIN" show -p Description --value "$unit" 2>/dev/null || true)"
    [[ "$description" == *"GOST ECMP PathLock"* ]]
}

project_systemd_unit_signature() {
    local unit path target checksum description
    for unit in "${PROJECT_SYSTEMD_UNITS[@]:-}"; do
        [[ -n "$unit" ]] || continue
        path="$SYSTEMD_DIR/$unit"
        target=""
        checksum="missing"
        [[ ! -L "$path" ]] || target="$(readlink "$path" 2>/dev/null || true)"
        [[ ! -r "$path" ]] || checksum="$(cksum "$path")"
        description="$("$SYSTEMCTL_BIN" show -p Description --value "$unit" 2>/dev/null || true)"
        printf '%s\t%s\t%s\t%s\n' "$unit" "$target" "$checksum" "$description"
    done | LC_ALL=C sort
}

collect_project_systemd_units() {
    local config key unit path dst
    local -a known_units=(
        gost-mtcp.service
        gost-mtcp-remote.service
        gost-mtcp-remote-anchor.service
        gost-ecmp-pathlock.service
        gost-ecmp-pathlock-anchor.service
        gost-ecmp-pathlock-watchdog.service
        gost-ecmp-pathlock-remote.service
        gost-ecmp-pathlock-remote-anchor-endpoint.service
    )
    PROJECT_SYSTEMD_UNITS=()

    for config in "$INSTALL_BASE"/cn/instances/*/mtcp.conf "$INSTALL_BASE"/cn/mtcp.conf; do
        [[ -r "$config" ]] || continue
        if [[ "$config" == "$INSTALL_BASE/cn/mtcp.conf" ]]; then
            dst="$(read_config_value "$config" DST 2>/dev/null || true)"
            [[ -n "$dst" && "$dst" != remote.example.invalid ]] || continue
        fi
        for key in UNIT ANCHOR_UNIT WATCHDOG_UNIT; do
            unit="$(read_config_value "$config" "$key" 2>/dev/null || true)"
            valid_systemd_service_name "$unit" || continue
            systemd_unit_belongs_to_pathlock "$unit" "$SYSTEMD_DIR/$unit" || {
                echo "忽略配置中不属于 PathLock 的 systemd 单元: $unit ($config)" >&2
                continue
            }
            if systemd_unit_artifact_exists "$unit" ||
               "$SYSTEMCTL_BIN" is-active --quiet "$unit" >/dev/null 2>&1; then
                add_project_systemd_unit "$unit"
            fi
        done
    done

    for path in "$SYSTEMD_DIR"/gost-mtcp*.service "$SYSTEMD_DIR"/gost-ecmp-pathlock*.service \
        "$SYSTEMD_DIR"/*.target.wants/gost-mtcp*.service \
        "$SYSTEMD_DIR"/*.target.wants/gost-ecmp-pathlock*.service \
        "$SYSTEMD_DIR"/*.target.requires/gost-mtcp*.service \
        "$SYSTEMD_DIR"/*.target.requires/gost-ecmp-pathlock*.service; do
        [[ -e "$path" || -L "$path" ]] || continue
        unit="$(basename "$path")"
        systemd_unit_belongs_to_pathlock "$unit" "$path" || continue
        add_project_systemd_unit "$unit"
    done
    while IFS= read -r unit; do
        systemd_unit_belongs_to_pathlock "$unit" || continue
        add_project_systemd_unit "$unit"
    done < <(
        {
            "$SYSTEMCTL_BIN" list-units --all --type=service --no-legend --no-pager 2>/dev/null || true
            "$SYSTEMCTL_BIN" list-unit-files --type=service --no-legend --no-pager 2>/dev/null || true
        } | awk '
            {
                unit=$1
                if (unit == "●") unit=$2
                if (unit ~ /^(gost-mtcp|gost-ecmp-pathlock).*\.service$/) print unit
            }
        '
    )
    for unit in "${known_units[@]}"; do
        systemd_unit_belongs_to_pathlock "$unit" "$SYSTEMD_DIR/$unit" || continue
        if systemd_unit_artifact_exists "$unit" ||
           "$SYSTEMCTL_BIN" is-active --quiet "$unit" >/dev/null 2>&1; then
            add_project_systemd_unit "$unit"
        fi
    done
}

is_pathlock_source_tree() {
    [[ -f "$INSTALL_BASE/install.sh" && -f "$INSTALL_BASE/standalone-install.sh" &&
       -f "$INSTALL_BASE/scripts/generate-standalone.sh" && -f "$INSTALL_BASE/cn/cn.yaml" &&
       ! -L "$INSTALL_BASE/cn" && ! -L "$INSTALL_BASE/remote" && ! -L "$INSTALL_BASE/scripts" ]]
}

restore_embedded_source_file() {
    local marker="$1" destination="$2" mode="$3" tmp
    mkdir -p "$(dirname "$destination")" || return 1
    tmp="$(mktemp "$(dirname "$destination")/.restore-$(basename "$destination").XXXXXX")" || return 1
    if ! extract_embedded "$marker" > "$tmp" || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        return 1
    fi
    chmod "$mode" "$tmp" || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$destination"
}

purge_pathlock_runtime_locks() {
    local runtime_dir="$PATHLOCK_RUNTIME_DIR" legacy_dir="${PATHLOCK_LEGACY_RUNTIME_DIR:-/run}"
    local config route unit shared_id path

    # 新版状态全部位于项目专属目录，因此只在这个 namespace 内使用 glob；
    # manager.lock 必须保留到 lifecycle 事务释放，避免出现两个 lock inode。
    if [[ -d "$runtime_dir" && ! -L "$runtime_dir" ]]; then
        for path in "$runtime_dir"/*.prewarm.lock "$runtime_dir"/*.watchdog.lock \
            "$runtime_dir"/*.process-recovery.lock "$runtime_dir"/*.process-recovery.state \
            "$runtime_dir"/*.tmp.*; do
            [[ -e "$path" || -L "$path" ]] || continue
            rm -f -- "$path" || return 1
        done
    fi

    # 兼容升级时只按已安装配置推导并清理旧版 /run 文件；禁止 gost-mtcp*
    # 这类宽泛 glob，以免跨项目删除同名状态。
    [[ -d "$legacy_dir" && ! -L "$legacy_dir" ]] || return 0
    for config in "$INSTALL_BASE"/cn/instances/*/mtcp.conf "$INSTALL_BASE"/cn/mtcp.conf; do
        [[ -r "$config" ]] || continue
        route="$(read_config_value "$config" ROUTE_ID 2>/dev/null || true)"
        [[ -n "$route" ]] || route="$(basename "$(dirname "$config")")"
        if [[ "$route" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; then
            rm -f -- "$legacy_dir/gost-pathlock-${route}-prewarm.lock" \
                "$legacy_dir/gost-pathlock-${route}-watchdog.lock" || return 1
        fi
        unit="$(read_config_value "$config" UNIT 2>/dev/null || true)"
        valid_systemd_service_name "$unit" || continue
        shared_id="${unit%.service}"
        shared_id="${shared_id//[^A-Za-z0-9_.@-]/_}"
        rm -f -- "$legacy_dir/${shared_id}-process-recovery.lock" \
            "$legacy_dir/${shared_id}-process-recovery.state" || return 1
    done
}

validate_systemd_cleanup_dir() {
    local canonical
    [[ "$SYSTEMD_DIR" == /* && -d "$SYSTEMD_DIR" && ! -L "$SYSTEMD_DIR" ]] || {
        echo "拒绝使用不安全或为符号链接的 SYSTEMD_DIR: $SYSTEMD_DIR" >&2
        return 1
    }
    canonical="$(cd -P -- "$SYSTEMD_DIR" 2>/dev/null && pwd -P)" || return 1
    [[ "$canonical" == "$SYSTEMD_DIR" ]] || {
        echo "SYSTEMD_DIR 必须使用规范绝对路径: $canonical" >&2
        return 1
    }
}

validate_pathlock_cleanup_base() {
    local parent leaf canonical_parent canonical
    [[ "$INSTALL_BASE" == /* && "$INSTALL_BASE" != / && ! -L "$INSTALL_BASE" ]] || {
        echo "拒绝清理不安全或为符号链接的 INSTALL_BASE: $INSTALL_BASE" >&2
        return 1
    }
    if [[ -d "$INSTALL_BASE" ]]; then
        canonical="$(cd -P -- "$INSTALL_BASE" 2>/dev/null && pwd -P)" || return 1
    elif [[ -e "$INSTALL_BASE" ]]; then
        echo "INSTALL_BASE 存在但不是目录: $INSTALL_BASE" >&2
        return 1
    else
        parent="$(dirname "$INSTALL_BASE")"
        leaf="$(basename "$INSTALL_BASE")"
        [[ -d "$parent" && "$leaf" != . && "$leaf" != .. ]] || return 1
        canonical_parent="$(cd -P -- "$parent" 2>/dev/null && pwd -P)" || return 1
        canonical="$canonical_parent/$leaf"
    fi
    [[ "$canonical" == "$INSTALL_BASE" ]] || {
        echo "INSTALL_BASE 必须使用无 ..、尾斜杠或符号链接的规范绝对路径: $canonical" >&2
        return 1
    }
    case "$canonical" in
        /bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
            echo "拒绝清理过于宽泛的 INSTALL_BASE: $canonical" >&2
            return 1
            ;;
    esac
}

remove_pathlock_installed_data() {
    local cn_dir="$INSTALL_BASE/cn" remote_dir="$INSTALL_BASE/remote" path failed=0
    validate_pathlock_cleanup_base || return 1
    if [[ -f "$INSTALL_BASE/install.sh" && -f "$INSTALL_BASE/standalone-install.sh" &&
          ( -L "$cn_dir" || -L "$remote_dir" || -L "$INSTALL_BASE/scripts" ) ]]; then
        echo "源码布局包含符号链接目录，拒绝执行清理: $INSTALL_BASE" >&2
        return 1
    fi

    if is_pathlock_source_tree; then
        rm -rf -- "$cn_dir/instances" || failed=1
        rm -f -- "$cn_dir/gost" "$cn_dir/runtime.yaml" "$cn_dir/config.lock" \
            "$remote_dir/gost" "$remote_dir/mtcp.auth" || failed=1
        rm -f -- "$cn_dir"/cn.yaml.migrated.* "$cn_dir"/mtcp.conf.migrated.* \
            "$cn_dir"/runtime.yaml.bak.* "$cn_dir"/runtime.yaml.failed.* || failed=1
        for path in "$cn_dir"/.shared-candidate.* "$cn_dir"/.runtime-candidate.* \
            "$cn_dir"/.runtime-relay-candidate.* "$cn_dir"/.shared-update.* \
            "$cn_dir"/.instance-remove-* "$remote_dir"/.remote-candidate.* \
            "$remote_dir"/.remote-update.* "$remote_dir"/.remote.yaml.* \
            "$remote_dir"/.mtcp.auth.* "$remote_dir"/.gost.*; do
            [[ -e "$path" || -L "$path" ]] || continue
            rm -rf -- "$path" || failed=1
        done
        if [[ -d "$cn_dir/state" ]]; then
            for path in "$cn_dir/state"/* "$cn_dir/state"/.[!.]* "$cn_dir/state"/..?*; do
                [[ -e "$path" || -L "$path" ]] || continue
                [[ "$(basename "$path")" == .gitkeep ]] && continue
                rm -rf -- "$path" || failed=1
            done
        fi
        restore_embedded_source_file CN_YAML "$cn_dir/cn.yaml" 0644 || failed=1
        restore_embedded_source_file CN_MTCP_CONF "$cn_dir/mtcp.conf" 0644 || failed=1
        restore_embedded_source_file CN_COMPILE "$cn_dir/compile-config.sh" 0755 || failed=1
        restore_embedded_source_file CN_LIB "$cn_dir/mtcp-lib.sh" 0755 || failed=1
        restore_embedded_source_file CN_PREWARM "$cn_dir/mtcp-prewarm.sh" 0755 || failed=1
        restore_embedded_source_file CN_WATCHDOG "$cn_dir/mtcp-watchdog.sh" 0755 || failed=1
        restore_embedded_source_file REMOTE_YAML "$remote_dir/remote.yaml" 0644 || failed=1
    else
        rm -rf -- "$cn_dir" "$remote_dir" || failed=1
        rmdir "$INSTALL_BASE" >/dev/null 2>&1 || true
    fi
    (( failed == 0 ))
}

# 输出：service_name<TAB>listen_addr<TAB>backend_addr<TAB>chain_name。
cn_relay_rows() {
    local yaml="$1"
    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function flush_service() {
            if (service_name != "") {
                printf "%s\t%s\t%s\t%s\n", service_name, listen_addr, backend_addr, chain_name
            }
            service_name = ""
            listen_addr = ""
            backend_addr = ""
            chain_name = ""
            address_count = 0
        }
        /^services:[[:space:]]*$/ { in_services = 1; next }
        /^chains:[[:space:]]*$/ { flush_service(); in_services = 0; exit }
        in_services && /^- name:[[:space:]]*/ {
            flush_service()
            service_name = $0
            sub(/^- name:[[:space:]]*/, "", service_name)
            service_name = trim(service_name)
            next
        }
        in_services && service_name != "" && /^[[:space:]]+addr:[[:space:]]*/ {
            value = $0
            sub(/^[[:space:]]+addr:[[:space:]]*/, "", value)
            value = trim(value)
            address_count++
            if (address_count == 1) listen_addr = value
            else if (address_count == 2) backend_addr = value
        }
        in_services && service_name != "" && /^[[:space:]]+chain:[[:space:]]*/ {
            chain_name = $0
            sub(/^[[:space:]]+chain:[[:space:]]*/, "", chain_name)
            chain_name = trim(chain_name)
        }
        END { if (in_services) flush_service() }
    ' "$yaml"
}

discover_cn_routes() {
    local config yaml dst
    DISCOVERED_CN_YAMLS=()
    DISCOVERED_CN_CONFIGS=()

    for config in "$INSTALL_BASE"/cn/instances/*/mtcp.conf; do
        [[ -r "$config" ]] || continue
        yaml="$(dirname "$config")/cn.yaml"
        [[ -r "$yaml" ]] || continue
        DISCOVERED_CN_YAMLS+=("$yaml")
        DISCOVERED_CN_CONFIGS+=("$config")
    done

    # 只有没有新版 instance 时才展示旧平铺布局，避免迁移后误改归档前的旧配置。
    if (( ${#DISCOVERED_CN_YAMLS[@]} == 0 )); then
        for yaml in "$INSTALL_BASE/cn/cn.yaml" "$INSTALL_BASE/cn.yaml"; do
            [[ -r "$yaml" ]] || continue
            config="$(dirname "$yaml")/mtcp.conf"
            [[ -r "$config" ]] || continue
            dst="$(read_config_value "$config" DST 2>/dev/null || true)"
            [[ "$dst" != "remote.example.invalid" ]] || continue
            DISCOVERED_CN_YAMLS+=("$yaml")
            DISCOVERED_CN_CONFIGS+=("$config")
            break
        done
    fi
}

cn_route_state_summary() {
    local config="$1" status_file line state reason
    status_file="$(read_config_value "$config" STATUS_JSON 2>/dev/null || true)"
    [[ -n "$status_file" ]] || status_file="$(dirname "$config")/state/status.json"
    if [[ ! -r "$status_file" ]]; then
        printf '未生成'
        return
    fi
    line="$(tail -n 1 "$status_file" 2>/dev/null || true)"
    state="$(printf '%s\n' "$line" | sed -n 's/.*"state":"\([^"]*\)".*/\1/p')"
    reason="$(printf '%s\n' "$line" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p')"
    [[ -n "$state" ]] || state="UNKNOWN"
    if [[ -n "$reason" ]]; then printf '%s/%s' "$state" "$reason"; else printf '%s' "$state"; fi
}

list_installed_configurations() {
    local remote_yaml remote_addr index yaml config route dst port ports state state_display
    local chain anchor primary name listen backend service_chain kind count

    if (( PATHLOCK_INTERACTIVE_MENU == 1 )); then
        ui_clear
        ui_header "线路与端口"
    else
        echo
        echo "================ 已有配置与端口路径 ================"
    fi
    remote_yaml="$INSTALL_BASE/remote/remote.yaml"
    if [[ -r "$remote_yaml" ]]; then
        remote_addr="$(awk '
            /^- name:[[:space:]]*mtcp-server[[:space:]]*$/ { found=1; next }
            found && /^  addr:[[:space:]]*/ { value=$0; sub(/^  addr:[[:space:]]*/, "", value); print value; exit }
            found && /^- name:[[:space:]]*/ { exit }
        ' "$remote_yaml")"
        echo
        echo "Remote 端"
        echo "  MTCP 监听 : ${remote_addr:-未知}"
        echo "  配置文件  : $remote_yaml"
        echo "  鉴权文件  : $INSTALL_BASE/remote/mtcp.auth"
    else
        echo
        echo "Remote 端：未发现已安装配置"
    fi

    discover_cn_routes
    if (( ${#DISCOVERED_CN_YAMLS[@]} == 0 )); then
        echo
        ui_warn "CN 线路：未发现已安装配置"
        if (( PATHLOCK_INTERACTIVE_MENU == 0 )); then echo "======================================================"; fi
        echo
        return 0
    fi

    echo
    echo "CN 线路（共享服务: gost-mtcp.service）"
    for (( index=0; index<${#DISCOVERED_CN_YAMLS[@]}; index++ )); do
        yaml="${DISCOVERED_CN_YAMLS[$index]}"
        config="${DISCOVERED_CN_CONFIGS[$index]}"
        route="$(read_config_value "$config" ROUTE_ID 2>/dev/null || true)"
        [[ -n "$route" ]] || route="$(basename "$(dirname "$config")")"
        dst="$(read_config_value "$config" DST 2>/dev/null || true)"
        port="$(read_config_value "$config" PORT 2>/dev/null || true)"
        ports="$(read_config_value "$config" BUSINESS_PORTS 2>/dev/null || true)"
        [[ -n "$ports" ]] || ports="$(read_config_value "$config" BUSINESS_PORT 2>/dev/null || true)"
        state="$(cn_route_state_summary "$config")"
        chain="$(read_config_value "$config" CHAIN_NAME 2>/dev/null || true)"
        anchor="$(read_config_value "$config" ANCHOR_SERVICE 2>/dev/null || true)"
        primary="$(read_config_value "$config" BUSINESS_PORT 2>/dev/null || true)"

        state_display="$(ui_status_badge "$state")"
        printf '\n  [%d] 线路 %s\n' "$((index + 1))" "$route"
        printf '      Remote    : %s:%s\n' "${dst:-未知}" "${port:-未知}"
        printf '      业务端口  : %s\n' "${ports:-未知}"
        printf '      当前状态  : %s\n' "$state_display"
        printf '      cn.yaml   : %s\n' "$yaml"
        printf '      mtcp.conf : %s\n' "$config"
        printf '      端口路径：\n'
        count=0
        while IFS=$'\t' read -r name listen backend service_chain; do
            [[ -n "$name" ]] || continue
            if [[ "$name" == "$anchor" ]]; then
                kind="anchor"
            elif [[ "$listen" == ":$primary" ]]; then
                kind="primary"
            elif [[ "$service_chain" == "$chain" ]]; then
                kind="relay"
            else
                kind="other"
            fi
            printf '        %-7s %-22s -> %-28s via %s\n' "$kind" "$listen" "${backend:--}" "${service_chain:--}"
            count=$((count + 1))
        done < <(cn_relay_rows "$yaml")
        (( count > 0 )) || echo "        （未解析到 service）"
    done
    echo
    if (( PATHLOCK_INTERACTIVE_MENU == 0 )); then echo "======================================================"; fi
    echo
}

select_cn_route() {
    local output_yaml_var="$1" output_config_var="$2" title="${3:-请选择 CN 线路}"
    local choice index config route dst port ports state state_display

    discover_cn_routes
    if (( ${#DISCOVERED_CN_YAMLS[@]} == 0 )); then
        ui_error "未发现已安装的 CN 线路，请先从主菜单执行安装 / 新增线路"
        ui_pause "主菜单"
        return 1
    fi

    if (( PATHLOCK_INTERACTIVE_MENU == 1 )); then
        ui_clear
        ui_header "$title"
    else
        echo
        echo "${title}："
    fi
    for (( index=0; index<${#DISCOVERED_CN_YAMLS[@]}; index++ )); do
        config="${DISCOVERED_CN_CONFIGS[$index]}"
        route="$(read_config_value "$config" ROUTE_ID 2>/dev/null || true)"
        [[ -n "$route" ]] || route="$(basename "$(dirname "$config")")"
        dst="$(read_config_value "$config" DST 2>/dev/null || true)"
        port="$(read_config_value "$config" PORT 2>/dev/null || true)"
        ports="$(read_config_value "$config" BUSINESS_PORTS 2>/dev/null || true)"
        [[ -n "$ports" ]] || ports="$(read_config_value "$config" BUSINESS_PORT 2>/dev/null || true)"
        state="$(cn_route_state_summary "$config")"
        state_display="$(ui_status_badge "$state")"
        printf '\n  [%d] %s\n' "$((index + 1))" "$route"
        printf '      Remote   %s:%s\n' "${dst:-未知}" "${port:-未知}"
        printf '      端口     %s\n' "${ports:-未知}"
        printf '      状态     %s\n' "$state_display"
    done
    echo
    echo "  [B] 返回"

    while :; do
        ui_menu_choice choice "请选择 › " || return 1
        case "$choice" in b|B|back|q|Q) return 1 ;; esac
        if [[ "$choice" =~ ^[0-9]+$ ]] &&
           (( 10#$choice >= 1 && 10#$choice <= ${#DISCOVERED_CN_YAMLS[@]} )); then
            index=$((10#$choice - 1))
            printf -v "$output_yaml_var" '%s' "${DISCOVERED_CN_YAMLS[$index]}"
            printf -v "$output_config_var" '%s' "${DISCOVERED_CN_CONFIGS[$index]}"
            return 0
        fi
        ui_error "无效选择: $choice"
    done
}

resolve_cn_relay_context() {
    local explicit_yaml="${1:-${CN_YAML_PATH:-}}"
    local explicit_config="${2:-${CN_MTCP_CONFIG_PATH:-}}"
    if [[ -n "$explicit_yaml" ]]; then
        CN_RELAY_YAML="$explicit_yaml"
    elif [[ -n "${CN_INSTANCE:-}" ]]; then
        [[ "$CN_INSTANCE" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || die "CN_INSTANCE 无效"
        CN_RELAY_YAML="$INSTALL_BASE/cn/instances/$CN_INSTANCE/cn.yaml"
    else
        discover_cn_routes
        (( ${#DISCOVERED_CN_YAMLS[@]} == 1 )) || die "无法唯一确定 CN 线路，请从菜单中选择"
        CN_RELAY_YAML="${DISCOVERED_CN_YAMLS[0]}"
    fi
    if [[ -n "$explicit_config" ]]; then
        CN_RELAY_CONFIG="$explicit_config"
    else
        CN_RELAY_CONFIG="$(dirname "$CN_RELAY_YAML")/mtcp.conf"
    fi
    CN_RELAY_DIR="$(dirname "$CN_RELAY_YAML")"
    [[ -r "$CN_RELAY_YAML" ]] || die "CN 配置不存在: $CN_RELAY_YAML"
    [[ -r "$CN_RELAY_CONFIG" ]] || die "CN Watchdog 配置不存在: $CN_RELAY_CONFIG"

    CN_ROUTE_ID="$(read_config_value "$CN_RELAY_CONFIG" ROUTE_ID)"
    CN_RELAY_UNIT="$(read_config_value "$CN_RELAY_CONFIG" UNIT)"
    CN_RELAY_WATCHDOG_UNIT="$(read_config_value "$CN_RELAY_CONFIG" WATCHDOG_UNIT)"
    CN_RELAY_CHAIN_NAME="$(read_config_value "$CN_RELAY_CONFIG" CHAIN_NAME)"
    CN_RELAY_ANCHOR_SERVICE="$(read_config_value "$CN_RELAY_CONFIG" ANCHOR_SERVICE)"
    CN_PRIMARY_PORT="$(read_config_value "$CN_RELAY_CONFIG" BUSINESS_PORT)"
    CN_ANCHOR_PORT="$(read_config_value "$CN_RELAY_CONFIG" ANCHOR_PORT)"
    CN_ROOT="$INSTALL_BASE/cn"
    CN_RUNTIME_YAML="$CN_ROOT/runtime.yaml"
    CN_COMPILE_SCRIPT="$CN_ROOT/compile-config.sh"
    [[ "$CN_ROUTE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || \
        die "mtcp.conf 中 ROUTE_ID 无效"
    [[ "$CN_RELAY_UNIT" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || \
        die "mtcp.conf 中 UNIT 无效: ${CN_RELAY_UNIT:-<空>}"
    [[ "$CN_RELAY_WATCHDOG_UNIT" =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || \
        die "mtcp.conf 中 WATCHDOG_UNIT 无效"
    [[ "$CN_RELAY_CHAIN_NAME" =~ ^chain-mtcp-[A-Za-z0-9_-]+$ ]] || \
        die "mtcp.conf 中 CHAIN_NAME 无效"
    [[ "$CN_RELAY_ANCHOR_SERVICE" =~ ^mtcp-anchor-[A-Za-z0-9_-]+$ ]] || \
        die "mtcp.conf 中 ANCHOR_SERVICE 无效"
    valid_port "$CN_PRIMARY_PORT" || die "mtcp.conf 中 BUSINESS_PORT 无效"
    valid_port "$CN_ANCHOR_PORT" || die "mtcp.conf 中 ANCHOR_PORT 无效"
    [[ -x "$CN_COMPILE_SCRIPT" ]] || die "共享配置编译器不存在: $CN_COMPILE_SCRIPT"
    "$SYSTEMCTL_BIN" cat "$CN_RELAY_UNIT" >/dev/null 2>&1 || \
        die "systemd unit 不存在: ${CN_RELAY_UNIT}（请先修正 mtcp.conf 的 UNIT）"
}

cn_business_ports() {
    local yaml="$1" wanted_chain="${2:-${CN_RELAY_CHAIN_NAME:-chain-mtcp-default}}"
    local anchor_service="${3:-${CN_RELAY_ANCHOR_SERVICE:-mtcp-anchor-default}}"
    local name listen backend chain port ports="" seen=" "
    while IFS=$'\t' read -r name listen backend chain; do
        [[ "$name" != "$anchor_service" && "$chain" == "$wanted_chain" ]] || continue
        [[ "$listen" =~ ^:([0-9]+)$ ]] || continue
        port="${BASH_REMATCH[1]}"
        valid_port "$port" || continue
        if [[ "$seen" != *" $port "* ]]; then
            ports="${ports:+$ports }$port"; seen+="$port "
        fi
    done < <(cn_relay_rows "$yaml")
    printf '%s\n' "$ports"
}

list_cn_relays() {
    local name listen backend chain kind count=0
    printf '\n%-24s %-18s %-28s %s\n' "SERVICE" "LISTEN" "BACKEND" "TYPE"
    printf '%-24s %-18s %-28s %s\n' "------------------------" "------------------" \
        "----------------------------" "-------"
    while IFS=$'\t' read -r name listen backend chain; do
        [[ -n "$name" ]] || continue
        if [[ "$name" == "$CN_RELAY_ANCHOR_SERVICE" || "$listen" == "127.0.0.1:$CN_ANCHOR_PORT" ]]; then
            kind="anchor"
        elif [[ "$listen" == ":$CN_PRIMARY_PORT" ]]; then
            kind="primary"
        elif [[ "$chain" == "$CN_RELAY_CHAIN_NAME" ]]; then
            kind="relay"
        else
            kind="other"
        fi
        printf '%-24s %-18s %-28s %s\n' "$name" "$listen" "${backend:--}" "$kind"
        count=$((count + 1))
    done < <(cn_relay_rows "$CN_RELAY_YAML")
    (( count > 0 )) || echo "未找到 services 配置。"
    echo
}

validate_backend_addr() {
    local value="$1" port
    if [[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:([0-9]+)$ ]]; then
        port="${BASH_REMATCH[1]}"
    elif [[ "$value" =~ ^\[[0-9A-Fa-f:]+\]:([0-9]+)$ ]]; then
        port="${BASH_REMATCH[1]}"
    else
        return 1
    fi
    valid_port "$port"
}

validate_cn_relay_yaml() {
    local yaml="$1" name listen backend chain anchor_count=0 primary_count=0
    local seen_names=$'\n' seen_listens=$'\n'

    while IFS=$'\t' read -r name listen backend chain; do
        [[ -n "$name" && -n "$listen" ]] || return 1
        [[ "$seen_names" != *$'\n'"$name"$'\n'* ]] || return 1
        [[ "$seen_listens" != *$'\n'"$listen"$'\n'* ]] || return 1
        seen_names+="$name"$'\n'
        seen_listens+="$listen"$'\n'
        [[ "$name" == "$CN_RELAY_ANCHOR_SERVICE" ]] && anchor_count=$((anchor_count + 1))
        [[ "$listen" == ":$CN_PRIMARY_PORT" ]] && primary_count=$((primary_count + 1))
        if [[ "$chain" == "$CN_RELAY_CHAIN_NAME" && -z "$backend" ]]; then return 1; fi
    done < <(cn_relay_rows "$yaml")

    (( anchor_count == 1 && primary_count == 1 )) || return 1
    grep -Fqx -- "- name: $CN_RELAY_CHAIN_NAME" "$yaml"
}

apply_cn_relay_yaml() {
    local candidate="$1" action="$2" source_signature="${3:-}"
    local backup failed config_backup config_failed current_signature
    local runtime_candidate runtime_candidate_dir runtime_backup runtime_failed
    local config_candidate ports stamp restart_ok=0

    check_command cksum
    check_command flock
    [[ -n "$source_signature" ]] || die "缺少 Relay 源配置签名，拒绝提交候选配置"
    CLEANUP_PATHS+=("$candidate")
    acquire_pathlock_manager_lock
    exec 8>"$CN_ROOT/config.lock"
    PATHLOCK_LOCK_KIND=config flock -n 8 || { rm -f "$candidate"; die "另一项 CN 配置操作正在进行"; }
    current_signature="$(cksum "$CN_RELAY_YAML")" || die "无法重新读取线路 fragment"
    if [[ "$current_signature" != "$source_signature" ]]; then
        rm -f "$candidate"
        exec 8>&-
        release_pathlock_manager_lock
        die "线路配置在确认期间发生变化，请重新操作"
    fi
    if ! validate_cn_relay_yaml "$candidate"; then
        rm -f "$candidate"
        die "生成的线路 fragment 未通过结构检查，原配置未修改"
    fi

    ports="$(cn_business_ports "$candidate" "$CN_RELAY_CHAIN_NAME" "$CN_RELAY_ANCHOR_SERVICE")"
    [[ " $ports " == *" $CN_PRIMARY_PORT "* ]] || {
        rm -f "$candidate"
        die "生成的 BUSINESS_PORTS 未包含主业务端口，原配置未修改"
    }
    [[ " $ports " != *" $CN_ANCHOR_PORT "* ]] || {
        rm -f "$candidate"
        die "生成的 BUSINESS_PORTS 错误包含 Anchor 端口，原配置未修改"
    }

    config_candidate="$(mktemp "$CN_RELAY_DIR/.mtcp.conf.relay.XXXXXX")"
    runtime_candidate_dir="$(mktemp -d "$CN_ROOT/.runtime-relay-candidate.XXXXXX")"
    runtime_candidate="$runtime_candidate_dir/runtime.yaml"
    CLEANUP_PATHS+=("$config_candidate" "$runtime_candidate_dir")
    if ! awk -v ports="$ports" '
        /^BUSINESS_PORTS=/ { print "BUSINESS_PORTS=\"" ports "\""; updated=1; next }
        { print }
        END { if (!updated) print "BUSINESS_PORTS=\"" ports "\"" }
    ' "$CN_RELAY_CONFIG" > "$config_candidate"; then
        rm -f "$candidate" "$config_candidate" "$runtime_candidate"
        die "无法生成 BUSINESS_PORTS 配置，原配置未修改"
    fi
    if ! validate_cn_process_policy_consistency "$CN_ROOT" "$CN_RELAY_CONFIG" "$config_candidate"; then
        rm -f "$candidate" "$config_candidate" "$runtime_candidate"
        die "各线路共享 PROCESS recovery 参数不一致，原配置未修改"
    fi
    if ! compile_cn_runtime_candidate "$CN_ROOT" "$CN_RELAY_YAML" "$candidate" "$runtime_candidate" ||
       ! "$CN_ROOT/gost" -C "$runtime_candidate" -O yaml >/dev/null; then
        rm -f "$candidate" "$config_candidate" "$runtime_candidate"
        die "聚合配置校验失败；可能存在跨线路服务名、端口或 chain 冲突"
    fi
    require_cn_restart_window "$CN_ROOT" "$CN_RELAY_UNIT"

    stamp="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"
    backup="${CN_RELAY_YAML}.bak.$stamp"
    failed="${CN_RELAY_YAML}.failed.$stamp"
    config_backup="${CN_RELAY_CONFIG}.bak.$stamp"
    config_failed="${CN_RELAY_CONFIG}.failed.$stamp"
    runtime_backup="${CN_RUNTIME_YAML}.bak.$stamp"
    runtime_failed="${CN_RUNTIME_YAML}.failed.$stamp"
    cp -p "$CN_RELAY_YAML" "$backup"
    cp -p "$CN_RELAY_CONFIG" "$config_backup"
    [[ -f "$CN_RUNTIME_YAML" ]] && cp -p "$CN_RUNTIME_YAML" "$runtime_backup"
    chmod 0644 "$candidate" "$config_candidate" "$runtime_candidate"
    if ! stop_cn_route_controls "$CN_ROOT" 1; then
        rm -f "$backup" "$config_backup" "$runtime_backup"
        start_cn_route_watchdogs "$CN_ROOT" >/dev/null 2>&1 || true
        die "无法停止全部线路控制单元；原配置未修改"
    fi

    if ! mv -f "$candidate" "$CN_RELAY_YAML" ||
       ! mv -f "$config_candidate" "$CN_RELAY_CONFIG" ||
       ! mv -f "$runtime_candidate" "$CN_RUNTIME_YAML"; then
        cp -p "$backup" "$CN_RELAY_YAML" >/dev/null 2>&1 || true
        cp -p "$config_backup" "$CN_RELAY_CONFIG" >/dev/null 2>&1 || true
        [[ -f "$runtime_backup" ]] && cp -p "$runtime_backup" "$CN_RUNTIME_YAML"
        rm -f "$candidate" "$config_candidate" "$runtime_candidate"
        start_cn_route_watchdogs "$CN_ROOT" >/dev/null 2>&1 || true
        die "无法原子替换线路与聚合配置；已尝试恢复"
    fi

    echo "正在重启共享 ${CN_RELAY_UNIT}；所有线路现有连接会中断并重新 Prewarm。"
    if "$SYSTEMCTL_BIN" restart "$CN_RELAY_UNIT" &&
       "$SYSTEMCTL_BIN" is-active --quiet "$CN_RELAY_UNIT" &&
       start_cn_route_watchdogs "$CN_ROOT"; then
        restart_ok=1
    fi

    if (( restart_ok == 1 )); then
        exec 8>&-
        release_pathlock_manager_lock
        ui_success "$action"
        echo "Watchdog BUSINESS_PORTS 已同步为: $ports"
        echo "聚合配置已更新: $CN_RUNTIME_YAML"
        echo "备份: $backup, $config_backup, $runtime_backup"
        return 0
    fi

    echo "共享 GOST 重启失败，正在回滚线路与聚合配置。" >&2
    cp -p "$CN_RELAY_YAML" "$failed"
    cp -p "$CN_RELAY_CONFIG" "$config_failed"
    cp -p "$CN_RUNTIME_YAML" "$runtime_failed"
    cp -p "$backup" "$CN_RELAY_YAML"
    cp -p "$config_backup" "$CN_RELAY_CONFIG"
    if [[ -f "$runtime_backup" ]]; then
        cp -p "$runtime_backup" "$CN_RUNTIME_YAML"
    else
        rm -f "$CN_RUNTIME_YAML"
    fi
    "$SYSTEMCTL_BIN" restart "$CN_RELAY_UNIT" >/dev/null 2>&1 || true
    start_cn_route_watchdogs "$CN_ROOT" >/dev/null 2>&1 || true
    exec 8>&-
    release_pathlock_manager_lock
    die "Relay 修改未生效；已回滚。失败配置: $failed, $config_failed, $runtime_failed"
}

add_cn_relay() {
    local listen_port backend service_name default_name active source_signature
    local existing_name existing_listen existing_backend existing_chain candidate
    CN_RESTART_CONFIRMED_COUNT=""
    source_signature="$(cksum "$CN_RELAY_YAML")" || die "无法读取线路 fragment"

    while :; do
        prompt_read listen_port "新增 CN 监听端口（例如 12002）: " || die "未输入监听端口"
        valid_port "$listen_port" && break
        echo "端口必须是 1-65535 之间的数字。" >&2
    done
    listen_port=$((10#$listen_port))
    [[ "$listen_port" != "$CN_PRIMARY_PORT" ]] || die "$listen_port 是受保护的主业务端口"
    [[ "$listen_port" != "$CN_ANCHOR_PORT" ]] || die "$listen_port 是受保护的 Anchor 端口"

    prompt_backend_addr backend "Remote 后端" || die "未输入 Remote 后端地址或端口"
    default_name="relay-$CN_ROUTE_ID-$listen_port"
    while :; do
        prompt_read service_name "Relay 服务名 [$default_name]: " || die "未输入服务名"
        service_name="${service_name:-$default_name}"
        if [[ ! "$service_name" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; then
            (( PATHLOCK_INTERACTIVE_MENU == 1 )) || die "服务名只能包含字母、数字、下划线和连字符"
            ui_error "服务名只能包含字母、数字、下划线和连字符"
            continue
        fi
        case "$service_name" in
            tcp-entry|tcp-entry-default|"tcp-entry-$CN_ROUTE_ID"|mtcp-anchor|mtcp-anchor-default|"$CN_RELAY_ANCHOR_SERVICE")
                (( PATHLOCK_INTERACTIVE_MENU == 1 )) || \
                    die "$service_name 是安装器保留服务名"
                ui_error "$service_name 是安装器保留服务名"
                continue
                ;;
        esac
        break
    done

    while IFS=$'\t' read -r existing_name existing_listen existing_backend existing_chain; do
        [[ "$existing_name" != "$service_name" ]] || die "服务名已存在: $service_name"
        [[ "$existing_listen" != ":$listen_port" ]] || die "监听端口已在 cn.yaml 中使用: $listen_port"
    done < <(cn_relay_rows "$CN_RELAY_YAML")
    if command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :$listen_port" 2>/dev/null | grep -q .; then
        die "本机端口已被其他进程监听: $listen_port"
    fi

    active="$(cn_active_business_count "$CN_ROOT")"
    ui_relay_change_card "新增" "$CN_ROUTE_ID" ":$listen_port" "$backend" "$CN_RELAY_CHAIN_NAME" "$active"
    if ! ui_confirm "请选择 [y/N] › "; then
        ui_warn "已取消，配置未修改"
        return 0
    fi
    CN_RESTART_CONFIRMED_COUNT="$active"

    candidate="$(mktemp "$CN_RELAY_DIR/.cn.yaml.relay.XXXXXX")"
    if ! awk -v relay_name="$service_name" -v listen_port="$listen_port" \
        -v backend_name="backend-$listen_port" -v backend_addr="$backend" \
        -v chain_name="$CN_RELAY_CHAIN_NAME" -v anchor_service="$CN_RELAY_ANCHOR_SERVICE" '
        function emit_relay() {
            print "# standalone-relay: " relay_name
            print "- name: " relay_name
            print "  addr: :" listen_port
            print "  handler:"
            print "    type: tcp"
            print "    chain: " chain_name
            print "  listener:"
            print "    type: tcp"
            print "  forwarder:"
            print "    nodes:"
            print "    - name: " backend_name
            print "      addr: " backend_addr
            print ""
        }
        $0 == "- name: " anchor_service && !inserted {
            emit_relay()
            inserted = 1
        }
        { print }
        END { if (!inserted) exit 42 }
    ' "$CN_RELAY_YAML" > "$candidate"; then
        rm -f "$candidate"
        die "没有找到 ${CN_RELAY_ANCHOR_SERVICE}，拒绝修改未知结构的线路 fragment"
    fi
    apply_cn_relay_yaml "$candidate" "已增加 :$listen_port -> $backend" "$source_signature"
}

remove_cn_relay() {
    local requested="${1:-}" name listen backend chain line candidate active source_signature
    local -a candidates=()
    CN_RESTART_CONFIRMED_COUNT=""
    source_signature="$(cksum "$CN_RELAY_YAML")" || die "无法读取线路 fragment"

    while IFS=$'\t' read -r name listen backend chain; do
        [[ "$name" == "$CN_RELAY_ANCHOR_SERVICE" || "$listen" == ":$CN_PRIMARY_PORT" || \
           "$listen" == "127.0.0.1:$CN_ANCHOR_PORT" ]] && continue
        [[ "$chain" == "$CN_RELAY_CHAIN_NAME" ]] || continue
        candidates+=("$name"$'\t'"$listen"$'\t'"$backend"$'\t'"$chain")
    done < <(cn_relay_rows "$CN_RELAY_YAML")
    (( ${#candidates[@]} > 0 )) || die "没有可删除的额外 Relay"

    if [[ -z "$requested" ]]; then
        echo "可删除的 Relay："
        local index=1 choice
        for line in "${candidates[@]}"; do
            IFS=$'\t' read -r name listen backend chain <<< "$line"
            printf '  %d) %s  %s -> %s\n' "$index" "$name" "$listen" "$backend"
            index=$((index + 1))
        done
        while :; do
            ui_menu_choice choice "请选择 › " || die "未选择 Relay"
            if [[ "$choice" =~ ^[0-9]+$ ]] &&
               (( 10#$choice >= 1 && 10#$choice <= ${#candidates[@]} )); then
                requested="${candidates[$((10#$choice - 1))]%%$'\t'*}"
                break
            fi
            (( PATHLOCK_INTERACTIVE_MENU == 1 )) || die "选择无效"
            ui_error "选择无效: $choice"
        done
    fi

    line=""
    for candidate in "${candidates[@]}"; do
        [[ "${candidate%%$'\t'*}" == "$requested" ]] && { line="$candidate"; break; }
    done
    [[ -n "$line" ]] || die "未找到可删除 Relay: $requested"
    IFS=$'\t' read -r name listen backend chain <<< "$line"

    active="$(cn_active_business_count "$CN_ROOT")"
    ui_relay_change_card "删除" "$CN_ROUTE_ID" "$listen" "$backend" "$chain" "$active"
    if ! ui_confirm "请选择 [y/N] › "; then
        ui_warn "已取消，配置未修改"
        return 0
    fi
    CN_RESTART_CONFIRMED_COUNT="$active"

    candidate="$(mktemp "$CN_RELAY_DIR/.cn.yaml.relay.XXXXXX")"
    if ! awk -v target="$name" '
        $0 == "# standalone-relay: " target { next }
        /^- name:[[:space:]]*/ {
            current = $0
            sub(/^- name:[[:space:]]*/, "", current)
            sub(/[[:space:]]+$/, "", current)
            if (current == target) {
                skipping = 1
                found = 1
                next
            }
            skipping = 0
        }
        /^chains:[[:space:]]*$/ { skipping = 0 }
        !skipping { print }
        END { if (!found) exit 42 }
    ' "$CN_RELAY_YAML" > "$candidate"; then
        rm -f "$candidate"
        die "删除失败，cn.yaml 未修改"
    fi
    apply_cn_relay_yaml "$candidate" "已删除 ${name}（$listen -> ${backend}）" "$source_signature"
}

manage_cn_relays() {
    local action="${1:-}" target="${2:-}" route_yaml="${3:-}" route_config="${4:-}" choice redraw=1
    check_command awk
    check_command cksum
    check_command flock
    check_command "$SYSTEMCTL_BIN"

    if [[ -z "$route_yaml" && -z "${CN_YAML_PATH:-}" && -z "${CN_INSTANCE:-}" ]]; then
        discover_cn_routes
        if (( ${#DISCOVERED_CN_YAMLS[@]} > 1 )); then
            select_cn_route route_yaml route_config "请选择要管理端口转发的线路" || return 0
        elif (( ${#DISCOVERED_CN_YAMLS[@]} == 0 )); then
            echo "未发现已安装的 CN 线路，请先执行全新安装。" >&2
            return 1
        fi
    fi
    resolve_cn_relay_context "$route_yaml" "$route_config"

    case "$action" in
        list) list_cn_relays ;;
        add) add_cn_relay ;;
        remove|delete|rm) remove_cn_relay "$target" ;;
        "")
            while :; do
                if (( redraw == 1 )); then
                    ui_clear
                    ui_header "端口转发 · $CN_ROUTE_ID"
                    printf '\n  %b配置: %s%b\n' "$UI_DIM" "$CN_RELAY_YAML" "$UI_RESET"
                    list_cn_relays
                    cat <<'RELAY_MENU'
  [1]  增加端口转发
  [2]  删除端口转发
  [3]  刷新列表

  [B]  返回线路选择
RELAY_MENU
                fi
                redraw=1
                ui_menu_choice choice "请选择 › " || return 0
                case "$choice" in
                    1) ui_run_action "新增端口转发" "端口转发" add_cn_relay ;;
                    2) ui_run_action "删除端口转发" "端口转发" remove_cn_relay ;;
                    3) ;;
                    b|B|back|q|Q|quit|exit) return 0 ;;
                    *) ui_error "无效选择: $choice"; redraw=0 ;;
                esac
            done
            ;;
        *) die "未知 Relay 操作: ${action}（支持 list/add/remove）" ;;
    esac
}

manage_selected_cn_route() {
    local route_yaml route_config
    while :; do
        route_yaml=""; route_config=""
        select_cn_route route_yaml route_config "请选择要管理端口转发的线路" || return 0
        manage_cn_relays "" "" "$route_yaml" "$route_config"
    done
}

find_cn_route_by_id() {
    local output_yaml_var="$1" output_config_var="$2" requested="$3"
    local index config route matched_yaml="" matched_config="" matches=0
    discover_cn_routes
    for (( index=0; index<${#DISCOVERED_CN_CONFIGS[@]}; index++ )); do
        config="${DISCOVERED_CN_CONFIGS[$index]}"
        route="$(read_config_value "$config" ROUTE_ID 2>/dev/null || true)"
        [[ -n "$route" ]] || route="$(basename "$(dirname "$config")")"
        [[ "$route" == "$requested" ]] || continue
        matched_yaml="${DISCOVERED_CN_YAMLS[$index]}"
        matched_config="$config"
        matches=$((matches + 1))
    done
    (( matches == 1 )) || return 1
    printf -v "$output_yaml_var" '%s' "$matched_yaml"
    printf -v "$output_config_var" '%s' "$matched_config"
}

purge_cn_instance_runtime_locks() {
    local route="$1" shared_unit="${2:-}" runtime_dir="$PATHLOCK_RUNTIME_DIR"
    local legacy_dir="${PATHLOCK_LEGACY_RUNTIME_DIR:-/run}" shared_id
    if [[ -d "$runtime_dir" && ! -L "$runtime_dir" ]]; then
        rm -f -- "$runtime_dir/${route}.prewarm.lock" \
            "$runtime_dir/${route}.watchdog.lock" || return 1
    fi
    if [[ -d "$legacy_dir" && ! -L "$legacy_dir" ]]; then
        rm -f -- "$legacy_dir/gost-pathlock-${route}-prewarm.lock" \
            "$legacy_dir/gost-pathlock-${route}-watchdog.lock" || return 1
    fi
    if [[ -n "$shared_unit" ]]; then
        shared_id="${shared_unit%.service}"
        shared_id="${shared_id//[^A-Za-z0-9_.@-]/_}"
        if [[ -d "$runtime_dir" && ! -L "$runtime_dir" ]]; then
            rm -f -- "$runtime_dir/${shared_id}.process-recovery.lock" \
                "$runtime_dir/${shared_id}.process-recovery.state" || return 1
        fi
        if [[ -d "$legacy_dir" && ! -L "$legacy_dir" ]]; then
            rm -f -- "$legacy_dir/${shared_id}-process-recovery.lock" \
                "$legacy_dir/${shared_id}-process-recovery.state" || return 1
        fi
    fi
}

remove_cn_instance() {
    local requested="${1:-}" route_yaml="" route_config="" route instance_dir expected_dir canonical_instance
    local cn_dir="$INSTALL_BASE/cn" runtime_yaml="$INSTALL_BASE/cn/runtime.yaml"
    local main_unit anchor_unit watchdog_unit expected_anchor_unit expected_watchdog_unit route_prefix
    local dst remote_port ports active remaining_count
    local config fragment other_main other_anchor other_watchdog other_route other_prefix marker_route
    local target_signature current_signature candidate_dir="" runtime_candidate=""
    local backup_dir quarantine_root quarantine commit_ok=1 rollback_ok=1 cleanup_ok=1 failure_stage=""
    local -a remaining_yamls=()

    check_command awk
    check_command cksum
    check_command flock
    check_command "$SYSTEMCTL_BIN"
    validate_pathlock_cleanup_base || die "INSTALL_BASE 不适合执行实例删除"
    validate_systemd_cleanup_dir || die "SYSTEMD_DIR 不适合执行实例删除"

    if [[ -n "$requested" ]]; then
        [[ "$requested" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || die "CN 线路别名无效: $requested"
        find_cn_route_by_id route_yaml route_config "$requested" || die "未找到 CN 线路实例: $requested"
    else
        select_cn_route route_yaml route_config "请选择要彻底删除的 CN 线路实例" || return 0
    fi

    route="$(read_config_value "$route_config" ROUTE_ID 2>/dev/null || true)"
    [[ -n "$route" ]] || route="$(basename "$(dirname "$route_config")")"
    [[ "$route" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || die "实例 ROUTE_ID 无效"
    instance_dir="$(dirname "$route_config")"
    expected_dir="$cn_dir/instances/$route"
    canonical_instance="$(cd -P -- "$instance_dir" 2>/dev/null && pwd -P)" || die "实例目录不可访问"
    [[ "$instance_dir" == "$expected_dir" && "$canonical_instance" == "$instance_dir" &&
       "$route_config" == "$expected_dir/mtcp.conf" && "$route_yaml" == "$expected_dir/cn.yaml" &&
       -f "$route_config" && -f "$route_yaml" && ! -L "$instance_dir" &&
       ! -L "$route_config" && ! -L "$route_yaml" ]] || \
        die "只允许删除无符号链接的 instances/<线路> 新版布局，拒绝路径: $instance_dir"

    main_unit="$(read_config_value "$route_config" UNIT 2>/dev/null || true)"
    anchor_unit="$(read_config_value "$route_config" ANCHOR_UNIT 2>/dev/null || true)"
    watchdog_unit="$(read_config_value "$route_config" WATCHDOG_UNIT 2>/dev/null || true)"
    route_prefix="gost-mtcp"
    [[ "$route" == default ]] || route_prefix="gost-mtcp-$route"
    expected_anchor_unit="$route_prefix-anchor.service"
    expected_watchdog_unit="$route_prefix-watchdog.service"
    [[ "$main_unit" == gost-mtcp.service ]] || die "新版实例 UNIT 必须是 gost-mtcp.service"
    [[ "$anchor_unit" == "$expected_anchor_unit" ]] || die "实例 ANCHOR_UNIT 与 ROUTE_ID 不匹配"
    [[ "$watchdog_unit" == "$expected_watchdog_unit" ]] || die "实例 WATCHDOG_UNIT 与 ROUTE_ID 不匹配"
    [[ "$(awk '/^# pathlock-route:[[:space:]]*/ { sub(/^# pathlock-route:[[:space:]]*/, ""); print; exit }' "$route_yaml")" == "$route" ]] || \
        die "实例 route marker 与 ROUTE_ID 不一致"
    dst="$(read_config_value "$route_config" DST 2>/dev/null || true)"
    remote_port="$(read_config_value "$route_config" PORT 2>/dev/null || true)"
    ports="$(read_config_value "$route_config" BUSINESS_PORTS 2>/dev/null || true)"
    [[ -n "$ports" ]] || ports="$(read_config_value "$route_config" BUSINESS_PORT 2>/dev/null || true)"
    target_signature="$(cksum "$route_config" "$route_yaml")" || die "无法读取待删除实例"

    for config in "$cn_dir"/instances/*/mtcp.conf; do
        [[ -f "$config" && "$config" != "$route_config" ]] || continue
        [[ ! -L "$config" && ! -L "$(dirname "$config")" ]] || \
            die "剩余线路包含符号链接，拒绝删除: $config"
        fragment="$(dirname "$config")/cn.yaml"
        [[ -f "$fragment" && ! -L "$fragment" ]] || die "发现缺少或链接到外部的 cn.yaml: $config"
    done
    for fragment in "$cn_dir"/instances/*/cn.yaml; do
        [[ -f "$fragment" && "$fragment" != "$route_yaml" ]] || continue
        [[ ! -L "$fragment" && ! -L "$(dirname "$fragment")" ]] || \
            die "剩余线路包含符号链接，拒绝删除: $fragment"
        config="$(dirname "$fragment")/mtcp.conf"
        [[ -f "$config" && ! -L "$config" ]] || die "发现缺少或链接到外部的 mtcp.conf: $fragment"
        grep -q '^# pathlock-route:[[:space:]]*' "$fragment" || \
            die "发现未知结构的剩余线路 fragment，拒绝删除: $fragment"
        remaining_yamls+=("$fragment")
    done
    remaining_count="${#remaining_yamls[@]}"
    active="$(cn_active_business_count "$cn_dir")"
    ui_instance_remove_card "$route" "${dst:-未知}:${remote_port:-未知}" "${ports:-未知}" \
        "$instance_dir" "$remaining_count" "$active"
    if ! ui_confirm "确认永久删除实例 ${route}？[y/N] › "; then
        ui_warn "已取消，实例未修改"
        return 0
    fi

    acquire_pathlock_manager_lock
    exec 8>"$cn_dir/config.lock"
    PATHLOCK_LOCK_KIND=config flock -n 8 || die "另一项 CN 配置操作正在进行"
    [[ -f "$route_config" && -f "$route_yaml" && ! -L "$instance_dir" &&
       ! -L "$route_config" && ! -L "$route_yaml" &&
       "$(cd -P -- "$instance_dir" 2>/dev/null && pwd -P)" == "$instance_dir" ]] || \
        die "实例在确认后发生变化，请重新操作"
    current_signature="$(cksum "$route_config" "$route_yaml")" || die "无法重新读取待删除实例"
    [[ "$current_signature" == "$target_signature" ]] || die "实例在确认后已被修改，请重新操作"

    # 锁内重新构造剩余 fragment，并验证共享 unit 与实例 unit 没有冲突。
    remaining_yamls=()
    for config in "$cn_dir"/instances/*/mtcp.conf; do
        [[ -f "$config" && "$config" != "$route_config" ]] || continue
        [[ ! -L "$config" && ! -L "$(dirname "$config")" ]] || \
            die "剩余线路包含符号链接，拒绝删除: $config"
        fragment="$(dirname "$config")/cn.yaml"
        [[ -f "$fragment" && ! -L "$fragment" ]] || die "发现缺少或链接到外部的 cn.yaml: $config"
    done
    for fragment in "$cn_dir"/instances/*/cn.yaml; do
        [[ -f "$fragment" && "$fragment" != "$route_yaml" ]] || continue
        [[ ! -L "$fragment" && ! -L "$(dirname "$fragment")" ]] || \
            die "剩余线路包含符号链接，拒绝删除: $fragment"
        grep -q '^# pathlock-route:[[:space:]]*' "$fragment" || \
            die "发现未知结构的剩余线路 fragment，拒绝删除: $fragment"
        config="$(dirname "$fragment")/mtcp.conf"
        [[ -f "$config" && ! -L "$config" ]] || die "剩余线路缺少或链接到外部的 mtcp.conf: $fragment"
        other_main="$(read_config_value "$config" UNIT 2>/dev/null || true)"
        other_anchor="$(read_config_value "$config" ANCHOR_UNIT 2>/dev/null || true)"
        other_watchdog="$(read_config_value "$config" WATCHDOG_UNIT 2>/dev/null || true)"
        other_route="$(read_config_value "$config" ROUTE_ID 2>/dev/null || true)"
        marker_route="$(awk '/^# pathlock-route:[[:space:]]*/ { sub(/^# pathlock-route:[[:space:]]*/, ""); print; exit }' "$fragment")"
        [[ "$other_main" == "$main_unit" ]] || die "剩余线路使用不同共享 UNIT: $config"
        [[ "$other_route" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ && "$marker_route" == "$other_route" ]] || \
            die "剩余线路 ROUTE_ID 与 route marker 不一致: $config"
        other_prefix="gost-mtcp"
        [[ "$other_route" == default ]] || other_prefix="gost-mtcp-$other_route"
        [[ "$other_anchor" == "$other_prefix-anchor.service" &&
           "$other_watchdog" == "$other_prefix-watchdog.service" ]] || \
            die "剩余线路控制 unit 与 ROUTE_ID 不匹配: $config"
        [[ "$other_anchor" != "$other_watchdog" && "$other_anchor" != "$anchor_unit" &&
           "$other_anchor" != "$watchdog_unit" && "$other_watchdog" != "$anchor_unit" &&
           "$other_watchdog" != "$watchdog_unit" ]] || \
            die "剩余线路与待删除实例共用了控制 unit: $config"
        remaining_yamls+=("$fragment")
    done
    remaining_count="${#remaining_yamls[@]}"

    if (( remaining_count > 0 )); then
        [[ -x "$cn_dir/compile-config.sh" && -x "$cn_dir/gost" ]] || \
            die "缺少共享配置编译器或 GOST，无法安全删除实例"
        candidate_dir="$(mktemp -d "$cn_dir/.instance-remove-candidate.XXXXXX")"
        runtime_candidate="$candidate_dir/runtime.yaml"
        CLEANUP_PATHS+=("$candidate_dir")
        "$cn_dir/compile-config.sh" "$runtime_candidate" "${remaining_yamls[@]}" || \
            die "删除实例后的聚合配置生成失败，原实例未修改"
        "$cn_dir/gost" -C "$runtime_candidate" -O yaml >/dev/null || \
            die "删除实例后的聚合配置未通过 GOST 校验，原实例未修改"
    fi

    backup_dir="$(mktemp -d "$cn_dir/.instance-remove-backup.${route}.XXXXXX")" || \
        die "无法创建实例删除备份目录"
    quarantine_root="$(mktemp -d "$cn_dir/.instance-remove-quarantine.${route}.XXXXXX")" || {
        rm -rf -- "$backup_dir"
        die "无法创建实例删除隔离目录"
    }
    quarantine="$quarantine_root/instance"
    route_remove_backup_one() {
        local path="$1" name="$2"
        if [[ -e "$path" || -L "$path" ]]; then
            cp -p "$path" "$backup_dir/$name" || return 1
            : > "$backup_dir/$name.exists"
        fi
    }
    route_remove_restore_one() {
        local path="$1" name="$2"
        if [[ -e "$backup_dir/$name.exists" ]]; then
            cp -p "$backup_dir/$name" "$path" || return 1
        else
            rm -f -- "$path" || return 1
        fi
    }
    if ! route_remove_backup_one "$runtime_yaml" runtime-yaml ||
       ! route_remove_backup_one "$SYSTEMD_DIR/$main_unit" main-unit ||
       ! route_remove_backup_one "$SYSTEMD_DIR/$anchor_unit" anchor-unit ||
       ! route_remove_backup_one "$SYSTEMD_DIR/$watchdog_unit" watchdog-unit; then
        rm -rf -- "$backup_dir" "$quarantine_root"
        die "无法备份实例删除事务所需的 runtime 或 systemd unit"
    fi

    if ! stop_cn_route_controls "$cn_dir" 1; then
        rm -rf -- "$backup_dir" "$quarantine_root"
        start_cn_route_watchdogs "$cn_dir" >/dev/null 2>&1 || true
        die "无法停止全部线路控制单元；实例未修改"
    fi
    if (( remaining_count == 0 )) && ! stop_systemd_units_strict "共享 CN 服务" "$main_unit"; then
        rm -rf -- "$backup_dir" "$quarantine_root"
        "$SYSTEMCTL_BIN" restart "$main_unit" >/dev/null 2>&1 || true
        start_cn_route_watchdogs "$cn_dir" >/dev/null 2>&1 || true
        die "无法停止最后一条线路的共享 CN 服务；实例未修改"
    fi

    if ! mv "$instance_dir" "$quarantine"; then
        commit_ok=0; failure_stage="隔离实例目录"
    fi
    if (( commit_ok == 1 )); then
        if (( remaining_count > 0 )); then
            if ! mv -f "$runtime_candidate" "$runtime_yaml"; then
                commit_ok=0; failure_stage="替换聚合配置"
            fi
        elif ! rm -f -- "$runtime_yaml"; then
            commit_ok=0; failure_stage="删除聚合配置"
        fi
    fi
    if (( commit_ok == 1 )) &&
       ! remove_systemd_unit_artifacts "$anchor_unit"; then
        commit_ok=0; failure_stage="删除 Anchor unit"
    fi
    if (( commit_ok == 1 )) &&
       ! remove_systemd_unit_artifacts "$watchdog_unit"; then
        commit_ok=0; failure_stage="删除 Watchdog unit"
    fi
    if (( commit_ok == 1 && remaining_count == 0 )) &&
       ! remove_systemd_unit_artifacts "$main_unit"; then
        commit_ok=0; failure_stage="删除共享 main unit"
    fi
    if (( commit_ok == 1 )) && ! "$SYSTEMCTL_BIN" daemon-reload; then
        commit_ok=0; failure_stage="systemd daemon-reload"
    fi
    if (( commit_ok == 1 && remaining_count > 0 )); then
        if ! "$SYSTEMCTL_BIN" enable "$main_unit" ||
           ! "$SYSTEMCTL_BIN" restart "$main_unit" ||
           ! "$SYSTEMCTL_BIN" is-active --quiet "$main_unit" ||
           ! start_cn_route_watchdogs "$cn_dir"; then
            commit_ok=0; failure_stage="恢复剩余线路"
        fi
    fi

    if (( commit_ok == 0 )); then
        echo "删除实例失败（${failure_stage}），正在回滚。" >&2
        if [[ -d "$quarantine" && ! -e "$instance_dir" ]]; then
            mv "$quarantine" "$instance_dir" || rollback_ok=0
        elif [[ -d "$quarantine" ]]; then
            rollback_ok=0
        fi
        route_remove_restore_one "$runtime_yaml" runtime-yaml || rollback_ok=0
        route_remove_restore_one "$SYSTEMD_DIR/$main_unit" main-unit || rollback_ok=0
        route_remove_restore_one "$SYSTEMD_DIR/$anchor_unit" anchor-unit || rollback_ok=0
        route_remove_restore_one "$SYSTEMD_DIR/$watchdog_unit" watchdog-unit || rollback_ok=0
        "$SYSTEMCTL_BIN" daemon-reload >/dev/null 2>&1 || rollback_ok=0
        if [[ -e "$SYSTEMD_DIR/$main_unit" || -L "$SYSTEMD_DIR/$main_unit" ]]; then
            "$SYSTEMCTL_BIN" enable "$main_unit" >/dev/null 2>&1 || rollback_ok=0
            "$SYSTEMCTL_BIN" restart "$main_unit" >/dev/null 2>&1 || rollback_ok=0
            "$SYSTEMCTL_BIN" is-active --quiet "$main_unit" >/dev/null 2>&1 || rollback_ok=0
            start_cn_route_watchdogs "$cn_dir" >/dev/null 2>&1 || rollback_ok=0
        fi
        exec 8>&-
        [[ -z "$candidate_dir" ]] || rm -rf -- "$candidate_dir"
        if (( rollback_ok == 1 )); then
            rm -rf -- "$backup_dir" "$quarantine_root"
            die "实例删除未生效，原配置与服务已恢复"
        fi
        die "实例删除失败且自动回滚不完整；保留现场: $backup_dir $quarantine_root"
    fi

    if ! rm -rf -- "$quarantine_root"; then cleanup_ok=0; fi
    if ! rm -rf -- "$backup_dir"; then cleanup_ok=0; fi
    if [[ -n "$candidate_dir" ]] && ! rm -rf -- "$candidate_dir"; then cleanup_ok=0; fi
    exec 8>&-
    if (( remaining_count == 0 )); then
        purge_cn_instance_runtime_locks "$route" "$main_unit" || cleanup_ok=0
    else
        purge_cn_instance_runtime_locks "$route" || cleanup_ok=0
    fi
    (( cleanup_ok == 1 )) || die "实例已从运行配置删除，但残留文件清理失败，请检查 $quarantine_root"
    release_pathlock_manager_lock

    ui_success "已彻底删除 CN 实例 $route"
    if (( remaining_count > 0 )); then
        echo "共享 GOST 已重启，剩余 $remaining_count 条线路正在重新建立连接。"
    else
        echo "最后一条 CN 线路已删除，共享 CN systemd 服务已一并移除。"
    fi
}

uninstall_pathlock() {
    local source_tree=0 answer unit failed=0 cn_dir="$INSTALL_BASE/cn"
    local lock_open=0 confirmed_unit_signature current_unit_signature

    check_command "$SYSTEMCTL_BIN"
    check_command cksum
    check_command flock
    check_command sort
    validate_pathlock_cleanup_base || die "INSTALL_BASE 不适合执行完全卸载"
    validate_systemd_cleanup_dir || die "SYSTEMD_DIR 不适合执行完全卸载"
    is_pathlock_source_tree && source_tree=1
    collect_project_systemd_units
    confirmed_unit_signature="$(project_systemd_unit_signature)"
    ui_uninstall_card "$INSTALL_BASE" "${#PROJECT_SYSTEMD_UNITS[@]}" "$source_tree"
    if (( ${#PROJECT_SYSTEMD_UNITS[@]} > 0 )); then
        echo "  将删除的项目 systemd 单元："
        for unit in "${PROJECT_SYSTEMD_UNITS[@]}"; do
            printf '    - %s\n' "$unit"
        done
        echo
    fi

    if [[ "${PATHLOCK_UNINSTALL_CONFIRM:-}" != DELETE_ALL ]]; then
        prompt_read answer "请输入 DELETE ALL 确认完全卸载: " || {
            ui_warn "未确认，未执行卸载"
            return 0
        }
        if [[ "$answer" != "DELETE ALL" ]]; then
            ui_warn "确认文字不匹配，未执行卸载"
            return 0
        fi
    else
        ui_warn "已通过 PATHLOCK_UNINSTALL_CONFIRM=DELETE_ALL 确认完全卸载"
    fi

    acquire_pathlock_manager_lock
    if [[ -d "$cn_dir" ]]; then
        exec 8>"$cn_dir/config.lock"
        PATHLOCK_LOCK_KIND=config flock -n 8 || die "另一项 CN 配置操作正在进行"
        lock_open=1
    fi
    collect_project_systemd_units
    current_unit_signature="$(project_systemd_unit_signature)"
    if [[ "$current_unit_signature" != "$confirmed_unit_signature" ]]; then
        (( lock_open == 0 )) || exec 8>&-
        die "确认期间 PathLock systemd 单元集合发生变化，请检查后重新执行卸载"
    fi

    if ! stop_systemd_units_strict "PathLock systemd 单元" "${PROJECT_SYSTEMD_UNITS[@]:-}"; then
        (( lock_open == 0 )) || exec 8>&-
        die "仍有 PathLock 服务无法确认停止；未删除安装数据"
    fi

    for unit in "${PROJECT_SYSTEMD_UNITS[@]:-}"; do
        [[ -n "$unit" ]] || continue
        remove_systemd_unit_artifacts "$unit" || failed=1
    done
    if ! "$SYSTEMCTL_BIN" daemon-reload; then
        failed=1
    fi
    for unit in "${PROJECT_SYSTEMD_UNITS[@]:-}"; do
        [[ -n "$unit" ]] || continue
        if systemd_unit_artifact_exists "$unit" ||
           "$SYSTEMCTL_BIN" is-active --quiet "$unit" >/dev/null 2>&1; then
            echo "systemd 单元仍有残留: $unit" >&2
            failed=1
        fi
    done
    collect_project_systemd_units
    if (( ${#PROJECT_SYSTEMD_UNITS[@]} > 0 )); then
        echo "卸载提交前又发现 PathLock systemd 单元: ${PROJECT_SYSTEMD_UNITS[*]}" >&2
        failed=1
    fi
    if (( failed != 0 )); then
        (( lock_open == 0 )) || exec 8>&-
        die "systemd 单元清理不完整；安装数据暂未删除，可修复 systemd 后重试"
    fi

    if ! purge_pathlock_runtime_locks; then
        (( lock_open == 0 )) || exec 8>&-
        die "systemd 单元已删除，但 PathLock 运行状态清理失败"
    fi
    if ! remove_pathlock_installed_data; then
        (( lock_open == 0 )) || exec 8>&-
        die "systemd 单元已删除，但安装目录清理失败: $INSTALL_BASE"
    fi
    (( lock_open == 0 )) || exec 8>&-
    release_pathlock_manager_lock

    ui_success "PathLock 已完全卸载"
    echo "已删除项目 systemd 单元、运行组件、配置、凭据、状态与 JSONL 日志。"
    if (( source_tree == 1 )); then
        echo "源码仓库和安装脚本已保留，配置模板已恢复，可用于重新安装。"
    else
        echo "安装器脚本自身已保留，可直接用于重新安装。"
    fi
    echo "说明：systemd journal 是全机共享存储；未清空全局 journal，因为这会影响其他服务。"
}

view_cn_route_logs() {
    local route_yaml route_config route event_file status_file choice redraw=1
    select_cn_route route_yaml route_config "请选择要查看状态 / 日志的线路" || return 0
    route="$(read_config_value "$route_config" ROUTE_ID 2>/dev/null || true)"
    [[ -n "$route" ]] || route="$(basename "$(dirname "$route_config")")"
    event_file="$(read_config_value "$route_config" EVENT_FILE 2>/dev/null || true)"
    status_file="$(read_config_value "$route_config" STATUS_JSON 2>/dev/null || true)"
    [[ -n "$event_file" ]] || event_file="$(dirname "$route_config")/state/events.jsonl"
    [[ -n "$status_file" ]] || status_file="$(dirname "$route_config")/state/status.json"

    while :; do
        if (( redraw == 1 )); then
            if (( PATHLOCK_INTERACTIVE_MENU == 1 )); then
                ui_clear
                ui_header "状态与日志 · $route"
            else
                echo
                echo "线路 $route · 状态与日志"
            fi
            echo
            echo "  当前状态"
            echo "  ───────────────────────────────────"
            ui_route_status_panel "$status_file"
            printf '\n  %b事件: %s%b\n' "$UI_DIM" "$event_file" "$UI_RESET"
            cat <<'LOG_MENU'

  [1]  最近 50 条事件
  [2]  实时跟踪日志（Ctrl-C 停止）
  [3]  查看原始 status.json

  [B]  返回主菜单
LOG_MENU
        fi
        redraw=1
        ui_menu_choice choice "请选择 › " || return 0
        case "$choice" in
            1)
                if [[ -r "$event_file" ]]; then
                    echo; tail -n 50 "$event_file"; echo
                else
                    ui_error "日志尚未生成: $event_file"
                fi
                ui_pause "状态与日志"
                ;;
            2)
                if [[ -r "$event_file" ]]; then
                    ui_warn "正在跟踪 ${event_file}，按 Ctrl-C 返回"
                    ui_follow_log "$event_file"
                else
                    ui_error "日志尚未生成: $event_file"
                fi
                ui_pause "状态与日志"
                ;;
            3)
                if [[ -r "$status_file" ]]; then
                    echo; tail -n 1 "$status_file"; echo
                else
                    ui_error "状态尚未生成: $status_file"
                fi
                ui_pause "状态与日志"
                ;;
            b|B|back|q|Q|quit|exit) return 0 ;;
            *) ui_error "无效选择: $choice"; redraw=0 ;;
        esac
    done
}

interactive_main_menu() {
    local choice install_role redraw=1
    ui_init
    while :; do
        if (( redraw == 1 )); then
            ui_clear
            ui_main_dashboard
            cat <<'MAIN_MENU'

  [1]  安装 / 新增线路
  [2]  查看线路与端口
  [3]  管理端口转发
  [4]  运行状态 / 日志
  [5]  删除 CN 线路实例
  [6]  完全卸载 PathLock

  [Q]  退出
MAIN_MENU
        fi
        redraw=1
        ui_menu_choice choice "请选择操作 › " || return 0
        case "$choice" in
            1)
                install_role=""
                if select_install_role install_role; then
                    case "$install_role" in
                        cn) ui_run_action "CN 线路安装" "主菜单" install_cn ;;
                        remote) ui_run_action "Remote 安装" "主菜单" install_remote ;;
                    esac
                fi
                ;;
            2) list_installed_configurations; ui_pause "主菜单" ;;
            3) manage_selected_cn_route ;;
            4) view_cn_route_logs ;;
            5) ui_run_action "删除 CN 线路实例" "主菜单" remove_cn_instance ;;
            6) ui_run_action "完全卸载 PathLock" "主菜单" uninstall_pathlock ;;
            q|Q|quit|exit) ui_success "已退出"; return 0 ;;
            "") redraw=0 ;;
            *) ui_error "无效选择: $choice"; redraw=0 ;;
        esac
    done
}

main() {
    local selected_mode="" relay_action="" relay_target="" instance_action="" instance_target=""

    prepare_embedded_source

    case "${1:-}" in
        --help|-h)
            show_usage
            exit 0
            ;;
        --version|-v)
            echo "gost-ecmp-pathlock standalone installer v${VERSION}"
            exit 0
            ;;
        cn|remote)
            selected_mode="$1"
            ;;
        relay)
            selected_mode="relay"
            relay_action="${2:-}"
            relay_target="${3:-}"
            ;;
        instance|route)
            selected_mode="instance"
            instance_action="${2:-remove}"
            instance_target="${3:-}"
            ;;
        uninstall|purge)
            selected_mode="uninstall"
            ;;
        list|configs)
            selected_mode="list"
            ;;
        logs|log)
            selected_mode="logs"
            ;;
        "")
            selected_mode="menu"
            ;;
        *)
            echo "错误: 无效参数 '$1'" >&2
            show_usage
            exit 1
            ;;
    esac

    check_root

    case "$selected_mode" in
        menu) PATHLOCK_INTERACTIVE_MENU=1; interactive_main_menu ;;
        remote) install_remote ;;
        cn) install_cn ;;
        relay) manage_cn_relays "$relay_action" "$relay_target" ;;
        instance)
            case "$instance_action" in
                remove|delete|rm) remove_cn_instance "$instance_target" ;;
                *) die "未知 instance 操作: ${instance_action}（仅支持 remove）" ;;
            esac
            ;;
        uninstall) uninstall_pathlock ;;
        list) list_installed_configurations ;;
        logs) view_cn_route_logs ;;
    esac
}

main "$@"
exit $?

# ============================================================
# 以下内容由 scripts/generate-standalone.sh 从 cn/ 与 remote/ 生成。
# ============================================================
# === GENERATED EMBEDDED FILES: DO NOT EDIT ===

### BEGIN REMOTE_YAML ###
services:
- name: mtcp-server
  addr: :6600
  handler:
    type: relay
    # GOST v3.2.6 的 MTCP listener 不消费 listener.auth；
    # 在 Relay 协议层校验每条 logical stream，未认证请求无法转发。
    auther: mtcp-auth
  listener:
    type: mtcp
    metadata:
      mux.version: 2
      mux.keepaliveDisabled: false
      mux.keepaliveInterval: 10s
      mux.keepaliveTimeout: 30s
      mux.maxFrameSize: 32768
      mux.maxReceiveBuffer: 33554432
      mux.maxStreamBuffer: 4194304

authers:
- name: mtcp-auth
  file:
    path: /root/gost-ecmp-pathlock/remote/mtcp.auth

### END REMOTE_YAML ###

### BEGIN REMOTE_MAIN_SERVICE ###
[Unit]
Description=GOST ECMP PathLock Remote Server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=/root/gost-ecmp-pathlock/remote
ExecStartPre=/usr/bin/test -x /root/gost-ecmp-pathlock/remote/gost
ExecStartPre=/usr/bin/test -r /root/gost-ecmp-pathlock/remote/remote.yaml
ExecStart=/root/gost-ecmp-pathlock/remote/gost -D -C /root/gost-ecmp-pathlock/remote/remote.yaml
Restart=always
RestartSec=2
TimeoutStopSec=15
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target

### END REMOTE_MAIN_SERVICE ###

### BEGIN REMOTE_ANCHOR_SERVICE ###
[Unit]
Description=GOST ECMP PathLock Remote Anchor Endpoint
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/socat -d -d TCP-LISTEN:12346,bind=127.0.0.1,reuseaddr,fork EXEC:/bin/cat
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target

### END REMOTE_ANCHOR_SERVICE ###

### BEGIN CN_YAML ###
# pathlock-route: default
services:
- name: tcp-entry-default
  addr: :12000
  handler:
    type: tcp
    chain: chain-mtcp-default
  listener:
    type: tcp
  forwarder:
    nodes:
    - name: backend
      # 安装时必须由用户指定端口；后端地址默认使用 Remote 本机 127.0.0.1。
      addr: backend.example.invalid:1

# 专用 MTCP 锚定入口，仅监听本机。
# Anchor 会主动发送 1 Byte 触发默认 Relay 首包逻辑，因此共享 connector 保持原始默认行为。
- name: mtcp-anchor-default
  addr: 127.0.0.1:12001
  handler:
    type: tcp
    chain: chain-mtcp-default
  listener:
    type: tcp
  forwarder:
    nodes:
    - name: anchor
      addr: 127.0.0.1:12346

chains:
- name: chain-mtcp-default
  hops:
  - name: remote-default
    nodes:
    - name: remote-mtcp-default
      addr: remote.example.invalid:6600
      connector:
        type: relay
        # 与 Remote handler 的 mtcp-auth 对应；凭据从安装器生成的 0600 文件读取。
        auth:
          file: /root/gost-ecmp-pathlock/cn/instances/default/mtcp.auth
      dialer:
        type: mtcp
        metadata:
          mux.version: 2
          mux.keepaliveDisabled: false
          mux.keepaliveInterval: 10s
          mux.keepaliveTimeout: 30s
          mux.maxFrameSize: 32768
          mux.maxReceiveBuffer: 33554432
          mux.maxStreamBuffer: 4194304

### END CN_YAML ###

### BEGIN CN_MTCP_CONF ###
# GOST MTCP Remote v1 configuration
# watchdog 每轮重新 source，本文件中的阈值修改后无需重启 watchdog。

# ---- shared GOST / route identity ----
# 所有线路共享 UNIT 指向的唯一 GOST 进程；Anchor 与 Watchdog 仍按线路隔离。
ROUTE_ID="default"
UNIT="gost-ecmp-pathlock.service"
ANCHOR_UNIT="gost-ecmp-pathlock-anchor.service"
WATCHDOG_UNIT="gost-ecmp-pathlock-watchdog.service"
CHAIN_NAME="chain-mtcp-default"
ANCHOR_SERVICE="mtcp-anchor-default"
DST="remote.example.invalid"
PORT="6600"
BUSINESS_PORT="12000"
# 以空格或逗号分隔。BUSINESS_PORT 是主入口，必须包含在本列表中。
BUSINESS_PORTS="12000"
ANCHOR_HOST="127.0.0.1"
ANCHOR_PORT="12001"

# ---- ECMP 新 session 准入 ----
ACCEPT_RTT_MS="40"

# ---- 运行中 RTT 监控：只告警，不因当前 RTT 高主动 kill ----
LIVE_RTT_WARN_MS="120"
LIVE_RTT_CRIT_MS="250"
LIVE_RTT_WARN_HOLD_SEC="30"
LIVE_RTT_CRIT_HOLD_SEC="120"
LIVE_RTT_RECOVER_MS="80"
LIVE_RTT_RECOVER_HOLD_SEC="30"

# ---- prewarm / 抽卡 ----
PREWARM_MAX_DRAWS="12"
RECOVERY_PREWARM_DRAWS="8"
DEGRADED_RETRY_DRAWS="4"
PREWARM_NO_SESSION_ATTEMPTS="5"
PREWARM_CONNECT_WAIT_SEC="2"
PREWARM_STABLE_REQUIRED="2"
PREWARM_STABLE_INTERVAL_SEC="1"
PREWARM_KILL_WAIT_SEC="2"
PREWARM_TOTAL_TIMEOUT_SEC="120"

# ---- Anchor ----
# Anchor 本身就是候选 session 的建立者和最终锚定者：
# start Anchor -> 主动发 1 Byte -> 建立 outer -> 检测 minrtt -> 慢则 stop+kill -> 重抽；快则直接留下。
ANCHOR_START_TIMEOUT_SEC="8"
ANCHOR_STABLE_REQUIRED="2"
ANCHOR_STABLE_INTERVAL_SEC="1"
ANCHOR_RETRY_SEC="60"

# ---- DEGRADED(PATH) 自动恢复 ----
DEGRADED_RETRY_SEC="900"
DEGRADED_BUSY_DEFER_SEC="60"
BUSINESS_IDLE_HOLD_SEC="15"

# ---- watchdog / recovery ----
WATCH_INTERVAL_SEC="5"
ZERO_GRACE_SEC="5"
REMOTE_PROBE_INTERVAL_SEC="15"
REMOTE_PROBE_TIMEOUT_SEC="2"
REMOTE_PROBE_ATTEMPTS="2"
# 通过本地 Anchor 入口发送并收回 1 Byte，验证当前 MTCP outer 的真实双向数据面。
DATA_PROBE_ENABLED="yes"
DATA_PROBE_INTERVAL_SEC="15"
DATA_PROBE_TIMEOUT_SEC="3"
DATA_PROBE_FAIL_THRESHOLD="3"
# 10 分钟内最多允许 3 次 stale-outer 重启；达到上限后熔断 10 分钟。
DATA_PROBE_RESTART_WINDOW_SEC="600"
DATA_PROBE_RESTART_MAX="3"
DATA_PROBE_BREAKER_OPEN_SEC="600"
DOWN_RETRY_SEC="15"
STUCK_RESTART_AFTER_SEC="60"
RESTART_COOLDOWN_SEC="60"
MULTI_CONFIRM_COUNT="2"
# GOST 因 systemd StartLimit 等原因停止时，低频尝试 reset-failed + restart。
# PROCESS breaker/budget 属于共享 UNIT，状态写入 /run/gost-ecmp-pathlock/gost-mtcp.process-recovery.state；
# 所有线路必须使用完全一致的 effective 参数；CN 配置事务发现漂移会 fail closed。
PROCESS_RECOVERY_GRACE_SEC="10"
PROCESS_RECOVERY_INTERVAL_SEC="60"
PROCESS_RECOVERY_WINDOW_SEC="600"
PROCESS_RECOVERY_MAX="3"
PROCESS_BREAKER_OPEN_SEC="600"

# ---- state / retention ----
STATE_DIR="/root/gost-ecmp-pathlock/cn/state"
STATE_FILE="/root/gost-ecmp-pathlock/cn/state/runtime.state"
STATUS_JSON="/root/gost-ecmp-pathlock/cn/state/status.json"
EVENT_FILE="/root/gost-ecmp-pathlock/cn/state/events.jsonl"
RETENTION_SEC="86400"

### END CN_MTCP_CONF ###

### BEGIN CN_COMPILE ###
#!/usr/bin/env bash
set -euo pipefail

# 将每条线路各自的 cn.yaml fragment 合并为一份供唯一 GOST 进程读取的配置。
# 用法: compile-config.sh OUTPUT ROUTE_FRAGMENT...
OUTPUT="${1:-}"
[[ -n "$OUTPUT" ]] || { echo "usage: $0 OUTPUT ROUTE_FRAGMENT..." >&2; exit 2; }
shift
(( $# > 0 )) || { echo "at least one route fragment is required" >&2; exit 2; }

seen_routes=" "
for fragment in "$@"; do
    [[ -r "$fragment" ]] || { echo "route fragment not readable: $fragment" >&2; exit 1; }
    route="$(awk '/^# pathlock-route:[[:space:]]*/ { sub(/^# pathlock-route:[[:space:]]*/, ""); print; exit }' "$fragment")"
    [[ "$route" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || {
        echo "invalid or missing route marker: $fragment" >&2
        exit 1
    }
    [[ "$seen_routes" != *" $route "* ]] || { echo "duplicate route id: $route" >&2; exit 1; }
    seen_routes+="$route "

    # Fragment 是线路故障域的边界：它只能定义并引用自己的 chain，且必须
    # 包含本线路唯一的 Anchor。不能仅因聚合配置里存在另一线路的 chain 就放行。
    awk -v route="$route" -v source="$fragment" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        function fail(message) {
            printf "%s: %s\n", source, message > "/dev/stderr"
            failed = 1
        }
        function finish_service() {
            if (current_service == "") return
            if (service_chain_count != 1) {
                fail("service " current_service " must reference exactly one " expected_chain)
            }
            current_service = ""
            service_chain_count = 0
        }
        BEGIN {
            expected_chain = "chain-mtcp-" route
            expected_anchor = "mtcp-anchor-" route
        }
        /^services:[[:space:]]*$/ {
            finish_service()
            section = "services"
            services_sections++
            next
        }
        /^chains:[[:space:]]*$/ {
            finish_service()
            section = "chains"
            chains_sections++
            next
        }
        section == "services" && /^- name:[[:space:]]*/ {
            finish_service()
            value = $0
            sub(/^- name:[[:space:]]*/, "", value)
            current_service = trim(value)
            service_count++
            if (current_service == expected_anchor) anchor_count++
            next
        }
        section == "services" && current_service != "" && /^[[:space:]]+chain:[[:space:]]*/ {
            value = $0
            sub(/^[[:space:]]+chain:[[:space:]]*/, "", value)
            value = trim(value)
            service_chain_count++
            if (value != expected_chain) {
                fail("service " current_service " references foreign chain " value "; expected " expected_chain)
            }
            next
        }
        section == "chains" && /^- name:[[:space:]]*/ {
            value = $0
            sub(/^- name:[[:space:]]*/, "", value)
            value = trim(value)
            chain_count++
            if (value == expected_chain) {
                expected_chain_count++
            } else {
                fail("fragment defines foreign chain " value "; expected " expected_chain)
            }
            next
        }
        END {
            finish_service()
            if (services_sections != 1 || chains_sections != 1) {
                fail("must contain exactly one services section and one chains section")
            }
            if (service_count == 0) fail("contains no services")
            if (anchor_count != 1) fail("must contain exactly one " expected_anchor)
            if (chain_count != 1 || expected_chain_count != 1) {
                fail("must define exactly one " expected_chain)
            }
            exit failed
        }
    ' "$fragment" || exit 1
done

output_dir="$(dirname "$OUTPUT")"
mkdir -p "$output_dir"
tmp="$(mktemp "$output_dir/.runtime.yaml.compile.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

emit_section() {
    local wanted="$1" fragment route
    shift
    for fragment in "$@"; do
        route="$(awk '/^# pathlock-route:[[:space:]]*/ { sub(/^# pathlock-route:[[:space:]]*/, ""); print; exit }' "$fragment")"
        [[ -n "$route" ]] || { echo "route marker missing: $fragment" >&2; return 1; }
        printf '  # route: %s\n' "$route"
        awk -v wanted="$wanted" -v source="$fragment" '
            /^services:[[:space:]]*$/ { services++; section="services"; next }
            /^chains:[[:space:]]*$/ { chains++; section="chains"; next }
            /^[A-Za-z][A-Za-z0-9_.-]*:[[:space:]]*$/ &&
                $0 !~ /^services:/ && $0 !~ /^chains:/ { section="other" }
            section == wanted { print }
            END {
                if (services != 1 || chains != 1) {
                    print "invalid route fragment sections: " source > "/dev/stderr"
                    exit 42
                }
            }
        ' "$fragment"
    done
}

{
    echo "# Generated by cn/compile-config.sh. Do not edit; edit instances/*/cn.yaml instead."
    echo "services:"
    emit_section services "$@"
    echo
    echo "chains:"
    emit_section chains "$@"
} > "$tmp"

# GOST 的 service/chain 名称及监听地址在聚合配置内必须唯一；同时确认每个
# service 引用的 chain 都存在，避免重启后才暴露拼装错误。
awk '
    function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        return value
    }
    function remember(kind, value, key) {
        value = trim(value)
        key = kind SUBSEP value
        if (value == "" || seen[key]++) {
            printf "duplicate or empty %s: %s\n", kind, value > "/dev/stderr"
            failed = 1
        }
        return value
    }
    /^services:[[:space:]]*$/ { section="services"; next }
    /^chains:[[:space:]]*$/ { section="chains"; next }
    section == "services" && /^- name:[[:space:]]*/ {
        value=$0; sub(/^- name:[[:space:]]*/, "", value)
        current_service=remember("service", value)
        service_count++
        have_listen=0
        next
    }
    section == "services" && current_service != "" && /^  addr:[[:space:]]*/ && !have_listen {
        value=$0; sub(/^  addr:[[:space:]]*/, "", value); value=trim(value)
        if (listen_seen[value]++) {
            printf "duplicate service listen address: %s\n", value > "/dev/stderr"
            failed = 1
        }
        have_listen=1
        next
    }
    section == "services" && /^[[:space:]]+chain:[[:space:]]*/ {
        value=$0; sub(/^[[:space:]]+chain:[[:space:]]*/, "", value)
        refs[trim(value)]=1
        next
    }
    section == "chains" && /^- name:[[:space:]]*/ {
        value=$0; sub(/^- name:[[:space:]]*/, "", value)
        value=remember("chain", value)
        chains[value]=1
        chain_count++
        next
    }
    section == "chains" && /^      addr:[[:space:]]*/ {
        value=$0; sub(/^      addr:[[:space:]]*/, "", value); value=trim(value)
        if (remote_seen[value]++) {
            printf "duplicate Remote endpoint (route isolation would be ambiguous): %s\n", value > "/dev/stderr"
            failed=1
        }
        next
    }
    END {
        if (service_count == 0 || chain_count == 0) failed=1
        for (name in refs) {
            if (!(name in chains)) {
                printf "service references missing chain: %s\n", name > "/dev/stderr"
                failed=1
            }
        }
        exit failed
    }
' "$tmp"

chmod 0644 "$tmp"
mv -f "$tmp" "$OUTPUT"
trap - EXIT

### END CN_COMPILE ###

### BEGIN CN_MAIN_SERVICE ###
[Unit]
Description=GOST ECMP PathLock Shared Data Plane
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=/root/gost-ecmp-pathlock/cn
ExecStartPre=/usr/bin/test -x /root/gost-ecmp-pathlock/cn/gost
ExecStartPre=/usr/bin/test -r /root/gost-ecmp-pathlock/cn/runtime.yaml
ExecStart=/root/gost-ecmp-pathlock/cn/gost -D -C /root/gost-ecmp-pathlock/cn/runtime.yaml
Restart=always
RestartSec=2
TimeoutStopSec=15
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target

### END CN_MAIN_SERVICE ###

### BEGIN CN_ANCHOR_SERVICE ###
[Unit]
Description=GOST ECMP PathLock Anchor Stream
After=gost-ecmp-pathlock.service
Requires=gost-ecmp-pathlock.service
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=/
# 默认 Relay 不改 nodelay。Anchor 主动发送 1 Byte，随后持续读取，长期占住一个 logical stream。
ExecStart=/bin/bash -c 'exec 3<>/dev/tcp/127.0.0.1/12001; printf "A" >&3; exec cat <&3 >/dev/null'
Restart=always
RestartSec=5
TimeoutStopSec=5
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal

# 故意没有 [Install]：不要 enable。
# 只允许 prewarm/watchdog 控制，以免开机时抢先锚定未经优选的 outer。

### END CN_ANCHOR_SERVICE ###

### BEGIN CN_WATCHDOG_SERVICE ###
[Unit]
Description=GOST ECMP PathLock Watchdog
After=network-online.target gost-ecmp-pathlock.service
Wants=network-online.target gost-ecmp-pathlock.service
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
Type=simple
WorkingDirectory=/root/gost-ecmp-pathlock/cn
Environment="MTCP_LIB=/root/gost-ecmp-pathlock/cn/mtcp-lib.sh"
Environment="MTCP_PREWARM=/root/gost-ecmp-pathlock/cn/mtcp-prewarm.sh"
ExecStartPre=/usr/bin/test -r /root/gost-ecmp-pathlock/cn/mtcp.conf
ExecStartPre=/usr/bin/test -x /root/gost-ecmp-pathlock/cn/mtcp-watchdog.sh
ExecStart=/root/gost-ecmp-pathlock/cn/mtcp-watchdog.sh /root/gost-ecmp-pathlock/cn/mtcp.conf
Restart=always
RestartSec=2
TimeoutStopSec=10
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target

### END CN_WATCHDOG_SERVICE ###

### BEGIN CN_LIB ###
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

### END CN_LIB ###

### BEGIN CN_PREWARM ###
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

### END CN_PREWARM ###

### BEGIN CN_WATCHDOG ###
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

### END CN_WATCHDOG ###
